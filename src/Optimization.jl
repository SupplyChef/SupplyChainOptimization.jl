"""
Creates an optimization model.
"""
function create_network_model(supply_chain, optimizer, bigM=1_000_000; single_source=false, evergreen=true, use_direct_model=false, relax=false, tighten_bigM=true)
    check_model(supply_chain)

    times = 1:supply_chain.horizon

    # get_product_index/get_storage_index/get_lane_index (SupplyChainModeling) cache a
    # (Vector, Dict{T,Int64}) pairing on supply_chain itself - the same one
    # SupplyChainSimulation.jl's State uses to back its hot fields with plain Arrays
    # instead of Dicts keyed by the struct itself. get_customer_index/get_supplier_index/
    # get_plant_index/get_plant_storage_index (Modeling.jl) build the same pairing for
    # the collections the modeling package doesn't index itself (get_location_index
    # deliberately excludes plants - see its docstring).
    #
    # opened/opening/closing/lost_sales/bought/produced/sent/serviced_by below are
    # declared over the resulting 1:n integer ranges instead of the struct collections
    # directly: JuMP only uses a plain, type-stable Array container when every axis is
    # a 1:n range, and falls back to a generic DenseAxisArray - keyed via a per-axis
    # Dict{Any,Int} lookup on every single access - for anything else (a Vector of
    # Lanes/Storages/...). That generic getindex path profiled as the dominant cost of
    # building a mid-sized model, well above HiGHS's own solve time.
    #
    # received/used/overflow/stored_at_end deliberately stay struct-keyed: received's
    # destination axis depends on the lane it's on, and used/overflow are only defined
    # for a subset of (lane, period)/(product, storage, period) combinations - JuMP
    # already has to fall back to a Dict-backed SparseAxisArray for those regardless of
    # the keys' types, so renumbering wouldn't remove the getindex overhead the way it
    # does for the fully-rectangular containers above. stored_at_end additionally has a
    # "period 0" axis (0:horizon) that starts below 1, which forces DenseAxisArray on
    # its own even if the other two axes were integers.
    products_index = get_product_index(supply_chain)
    storages_index = get_storage_index(supply_chain)
    customers_index = get_customer_index(supply_chain)
    suppliers_index = get_supplier_index(supply_chain)
    plants_index = get_plant_index(supply_chain)
    plants_storages_index = get_plant_storage_index(supply_chain)
    lanes_index = get_lane_index(supply_chain)

    products, pidx = products_index.items, products_index.index
    storages, sidx = storages_index.items, storages_index.index
    customers, cidx = customers_index.items, customers_index.index
    suppliers, supidx = suppliers_index.items, suppliers_index.index
    plants, plidx = plants_index.items, plants_index.index
    plants_storages, psidx = plants_storages_index.items, plants_storages_index.index
    lanes, lidx = lanes_index.items, lanes_index.index

    np, ns, nc = length(products), length(storages), length(customers)
    nsup, npl, nps, nl = length(suppliers), length(plants), length(plants_storages), length(lanes)

    # get_lanes_out/get_lanes_in/get_lanes_between (SupplyChainModeling) are called
    # from ~17 sites below, many inside a per-(facility, time) or
    # per-(product, facility, time) comprehension - tens of thousands of calls on a
    # mid-sized instance. If each call scans the full lane list (typical for a
    # "lanes for this facility" query with no cache), that's O(facilities x times x
    # total_lanes) just to *build* the model, before HiGHS ever runs and outside
    # time_limit's control entirely - this is what showed up as model-construction
    # time dominating a profile, not solve time. Precompute the adjacency once
    # instead; same lanes, same order, just not re-scanned per call.
    _lanes_out_of = Dict{Any,Vector{Lane}}()
    _lanes_into = Dict{Any,Vector{Lane}}()
    for l in lanes
        push!(get!(() -> Lane[], _lanes_out_of, l.origin), l)
        for d in l.destinations
            push!(get!(() -> Lane[], _lanes_into, d), l)
        end
    end
    _lanes_out(x) = get(_lanes_out_of, x, Lane[])
    _lanes_in(x) = get(_lanes_into, x, Lane[])
    _lanes_between(o, d) = [l for l in _lanes_out(o) if d in l.destinations]

    # Same idea as the lane adjacency cache above, applied to the other calls that
    # get repeated needlessly below: get_maximum_storage/get_maximum_throughput/
    # get_additional_stock_cover/get_overflow_cost all take a (product, facility) pair
    # but not `t`, yet several call sites live inside a [..., t=times] (or [t=times])
    # constraint/variable and so were being recalled once per period - and
    # get_maximum_storage in particular is computed independently at 3 separate call
    # sites (the overflow variable's own condition, the storage-capacity constraint,
    # and the overflow-cost sum) for the same (p, s). Computing each one once per
    # (product, facility) up front turns every one of those into a Dict lookup.
    _max_storage = Dict((p, s) => get_maximum_storage(s, p) for p in products, s in storages)
    _max_throughput = Dict((p, x) => get_maximum_throughput(x, p) for p in products, x in Iterators.flatten((storages, suppliers, plants)))
    _additional_stock_cover = Dict((p, s) => get_additional_stock_cover(s, p) for p in products, s in storages)
    _overflow_cost = Dict((p, s) => get_overflow_cost(s, p) for p in products, s in storages if !isinf(_max_storage[(p, s)]))

    # l.fixed_cost > 0 doesn't depend on t either, but was being tested against every
    # lane on every one of the `times` iterations below instead of once overall.
    _fixed_cost_lanes = [l for l in lanes if l.fixed_cost > 0]

    # Ad-valorem tariff cost per (product, lane, destination) for a lane leaving a
    # Plant or Supplier directly: rate * declared value, a constant since it doesn't
    # depend on any decision variable - so it folds into the objective the same way
    # l.unit_cost does, no new variable needed. Declared value is the shipping node's
    # own unit_cost for that product (production cost at a Plant, purchase cost at a
    # Supplier) - the one case where "where did this unit come from" is known
    # statically rather than needing the stored_by_origin overlay below (a Storage can
    # blend units from several countries, a Plant/Supplier can't). Empty whenever the
    # supply chain has no tariffs, so this never runs the O(products x lanes x
    # destinations) loop below for callers not using tariffs.
    _country(loc::Union{Location, Missing}) = ismissing(loc) ? nothing : loc.country
    _country_of_node(node) = _country(node.location)
    _tariff_unit_cost = Dict{Tuple{Product, Lane, ConcreteNode}, Float64}()
    if !isempty(supply_chain.tariffs)
        for l in lanes
            if l.origin isa Plant || l.origin isa Supplier
                origin_country = _country_of_node(l.origin)
                if !isnothing(origin_country)
                    for d in l.destinations
                        destination_country = _country_of_node(d)
                        isnothing(destination_country) && continue
                        for p in products
                            declared_value = get(l.origin.unit_cost, p, 0.0)
                            declared_value <= 0.0 && continue
                            rate = get_tariff_rate(supply_chain, origin_country, destination_country, p)
                            rate <= 0.0 && continue
                            _tariff_unit_cost[(p, l, d)] = rate * declared_value
                        end
                    end
                end
            end
        end
    end

    # Re-export tariffs: a Storage's inventory can blend units bought/produced in
    # several countries, so a lane leaving a Storage can't be tariffed from a single
    # static origin the way a Plant/Supplier-origin lane above can. Rather than
    # replacing stored_at_end/sent/received with a (product, origin_country)-indexed
    # version everywhere (which would ripple into Heuristics.jl/GSM.jl/Querying.jl/
    # Visualization.jl and fragment their public (product, ...) API for every caller,
    # tariffed or not), this adds a parallel "by origin" breakdown - stored_by_origin/
    # sent_by_origin/received_by_origin below - that mirrors the existing storage
    # balance/dispatch-split constraints one-for-one and ties back to the real
    # variables with a sum-over-origins-equals-the-real-quantity constraint. The real
    # variables and every constraint on them above are untouched; this whole block is
    # only ever non-empty for products that actually have a tariff configured, so it's
    # a no-op for every other product/caller.
    #
    # `nothing` is included as an origin_country: it's the "unknown provenance"
    # bucket for initial_inventory, get_arrivals, and any Plant/Supplier without a
    # country set - get_tariff_rate never charges a tariff against it (see its
    # isnothing checks), so unknown-provenance inventory is simply never taxed on
    # re-export rather than erroring or guessing.
    #
    # Declared value for a re-exported unit is the average unit_cost for that product
    # across every Plant/Supplier in its origin country - the same idea as the
    # Plant/Supplier-origin case above, but averaged since a country can have several
    # sources at different costs and the cohort tracking below doesn't (yet) preserve
    # which specific source a unit came from, only which country.
    _tariff_relevant_products = if isempty(supply_chain.tariffs)
        Product[]
    elseif any(isnothing(t.product) for t in supply_chain.tariffs)
        products
    else
        unique(Product[t.product for t in supply_chain.tariffs if !isnothing(t.product)])
    end

    _origin_countries = Union{Nothing, String}[nothing]
    if !isempty(_tariff_relevant_products)
        for x in Iterators.flatten((plants, suppliers))
            oc = _country_of_node(x)
            isnothing(oc) || push!(_origin_countries, oc)
        end
        unique!(_origin_countries)
    end

    _declared_value_by_origin = Dict{Tuple{Product, String}, Float64}()
    if !isempty(_tariff_relevant_products)
        for p in _tariff_relevant_products
            by_country = Dict{String, Vector{Float64}}()
            for x in Iterators.flatten((plants, suppliers))
                oc = _country_of_node(x)
                (isnothing(oc) || !haskey(x.unit_cost, p)) && continue
                push!(get!(() -> Float64[], by_country, oc), x.unit_cost[p])
            end
            for (oc, source_values) in by_country
                _declared_value_by_origin[(p, oc)] = sum(source_values) / length(source_values)
            end
        end
    end

    _cohort_tariff_unit_cost = Dict{Tuple{Product, Lane, ConcreteNode, String}, Float64}()
    if !isempty(_tariff_relevant_products)
        for l in lanes
            if l.origin isa Storage
                for d in l.destinations
                    destination_country = _country_of_node(d)
                    isnothing(destination_country) && continue
                    for p in _tariff_relevant_products
                        haskey(l.origin.unit_handling_cost, p) || continue
                        for oc in _origin_countries
                            isnothing(oc) && continue
                            declared_value = get(_declared_value_by_origin, (p, oc), 0.0)
                            declared_value <= 0.0 && continue
                            rate = get_tariff_rate(supply_chain, oc, destination_country, p)
                            rate <= 0.0 && continue
                            _cohort_tariff_unit_cost[(p, l, d, oc)] = rate * declared_value
                        end
                    end
                end
            end
        end
    end

    m = Model(optimizer)
    if use_direct_model
        m = direct_model(HiGHS.Optimizer())#; bridge_constraints = false)
    end
    set_string_names_on_creation(m, false)

    # A flow of product p anywhere in the network can never exceed the total
    # demand for p summed over every customer and every period: whatever
    # isn't eventually delivered is lost_sales, not extra flow. That's a
    # valid (if loose - it ignores which period/lane a unit could actually
    # reach) upper bound on any single sent/received/produced quantity, and
    # for realistic demand magnitudes it's far tighter than a flat bigM.
    # Products that are only ever consumed as BOM inputs (never demanded
    # directly) have total_demand == 0, so effective_bigM below falls back
    # to the caller's bigM for those - safe, just not tightened.
    total_demand = Dict(p => sum(get_demand(supply_chain, c, p, t) for c in customers, t in times; init=0.0) for p in products)
    total_demand_all_products = sum(values(total_demand); init=0.0)

    # Never loosens the caller-supplied bigM - only tightens it when a
    # finite, positive structural bound is available - so this can't cut
    # off a feasible/optimal solution that the flat bigM would have allowed.
    # tighten_bigM=false reproduces the pre-tightening flat-bigM behavior
    # exactly, so callers (see benchmark/run_benchmarks.jl) can A/B the
    # tightening's effect within a single run instead of needing a separate
    # checkout of an earlier commit.
    effective_bigM(bound) = tighten_bigM && isfinite(bound) && bound > 0 ? min(bigM, bound) : bigM

    @variable(m, total_profits)

    @variable(m, total_revenues >= 0)
    @variable(m, total_revenues_per_period[times] >= 0)

    @variable(m, total_costs >= 0)
    @variable(m, total_transportation_costs >= 0)
    @variable(m, total_fixed_costs >= 0)
    @variable(m, total_holding_costs >= 0)

    @variable(m, total_costs_per_period[times] >= 0)
    @variable(m, total_transportation_costs_per_period[times] >= 0)
    @variable(m, total_opening_costs_per_period[times] >= 0)
    @variable(m, total_closing_costs_per_period[times] >= 0)
    @variable(m, total_buying_costs_per_period[times] >= 0)
    @variable(m, total_fixed_costs_per_period[times] >= 0)
    @variable(m, total_holding_costs_per_period[times] >= 0)
    @variable(m, total_overflow_costs >= 0)
    @variable(m, total_overflow_costs_per_period[times] >= 0)
    @variable(m, total_tariff_costs >= 0)
    @variable(m, total_tariff_costs_per_period[times] >= 0)

    if !relax
        @variable(m, opened[1:nps, times], Bin)
        @variable(m, opening[1:nps, times], Bin)
        @variable(m, closing[1:nps, times], Bin)
    else
        @variable(m, 0 <= opened[1:nps, times] <= 1)
        @variable(m, 0 <= opening[1:nps, times] <= 1)
        @variable(m, 0 <= closing[1:nps, times] <= 1)
    end

    @variable(m, lost_sales[1:np, 1:nc, times] >= 0)

    @variable(m, bought[1:np, 1:nsup, times] >= 0)

    @variable(m, produced[1:np, 1:npl, times] >= 0)

    @variable(m, stored_at_end[products, storages, 0:supply_chain.horizon] >= 0)

    if !relax
        @variable(m, used[l=lanes, times; l.minimum_quantity > 0 || l.fixed_cost > 0], Bin)
    else
        @variable(m, 0 <= used[l=lanes, times; l.minimum_quantity > 0 || l.fixed_cost > 0] <= 1)
    end
    @variable(m, sent[1:np, 1:nl, times] >= 0)
    @variable(m, received[products, l=lanes, d=l.destinations, times] >= 0)

    # The "by origin" overlay described above stored_at_end/sent/received's
    # declarations near the top of this function - only ever non-empty for
    # products with a configured tariff (see _tariff_relevant_products).
    @variable(m, stored_by_origin[p=_tariff_relevant_products, s=storages, oc=_origin_countries, t=0:supply_chain.horizon; haskey(s.unit_handling_cost, p)] >= 0)
    @variable(m, sent_by_origin[p=_tariff_relevant_products, l=lanes, oc=_origin_countries, times; l.origin isa Storage && haskey(l.origin.unit_handling_cost, p)] >= 0)
    @variable(m, received_by_origin[p=_tariff_relevant_products, l=lanes, d=l.destinations, oc=_origin_countries, times; l.origin isa Storage && haskey(l.origin.unit_handling_cost, p)] >= 0)

    # Inventory beyond a storage's maximum_units: allowed (not infeasible), like lost_sales
    # for demand, but costed via overflow_unit_cost instead of bounded by a policy cap -
    # capacity is an economic tradeoff here, not a hard business promise.
    @variable(m, overflow[p=products, s=storages, t=times; !isinf(_max_storage[(p, s)])] >= 0)

    if single_source
        if !relax
            @variable(m, serviced_by[1:np, 1:ns, 1:nc, times], Bin)
        else
            @variable(m, 0 <= serviced_by[1:np, 1:ns, 1:nc, times] <= 1)
        end
        @constraint(m, [p=products, c=customers, t=times], sum(serviced_by[pidx[p], sidx[s], cidx[c], t] for s in storages) <= 1)
        @constraint(m, [p=products, s=storages, c=customers, t=times], sum(received[p, l, c, t] for l in _lanes_between(s, c)) <= effective_bigM(get_demand(supply_chain, c, p, t)) * serviced_by[pidx[p], sidx[s], cidx[c], t])
    end

    @constraint(m, [p=products, s=storages; haskey(s.initial_inventory, p)], stored_at_end[p, s, 0] == s.initial_inventory[p])
    if evergreen
        @constraint(m, [p=products, s=storages; !haskey(s.initial_inventory, p)], stored_at_end[p, s, 0] <= stored_at_end[p, s, supply_chain.horizon])
    end

    # Cohort mirror of the two constraints just above: initial inventory has no known
    # origin, so it all starts in the `nothing` ("unknown") bucket.
    @constraint(m, [p=_tariff_relevant_products, s=storages; haskey(s.unit_handling_cost, p) && haskey(s.initial_inventory, p)], stored_by_origin[p, s, nothing, 0] == s.initial_inventory[p])
    @constraint(m, [p=_tariff_relevant_products, s=storages, oc=_origin_countries; haskey(s.unit_handling_cost, p) && haskey(s.initial_inventory, p) && !isnothing(oc)], stored_by_origin[p, s, oc, 0] == 0.0)
    if evergreen
        @constraint(m, [p=_tariff_relevant_products, s=storages, oc=_origin_countries; haskey(s.unit_handling_cost, p) && !haskey(s.initial_inventory, p)], stored_by_origin[p, s, oc, 0] <= stored_by_origin[p, s, oc, supply_chain.horizon])
    end

    @constraint(m, [p=products, l=lanes, t=times], sum(received[p, l, l.destinations[i], t + l.times[i]] for i in 1:length(l.destinations) if t + l.times[i] <= supply_chain.horizon) == sent[pidx[p], lidx[l], t])

    # Cohort mirror of the dispatch/arrival split just above, restricted to lanes
    # leaving a Storage (the only origin type that needs a per-origin breakdown -
    # see _tariff_unit_cost/_cohort_tariff_unit_cost above for why Plant/Supplier
    # origins don't).
    @constraint(m, [p=_tariff_relevant_products, l=lanes, oc=_origin_countries, t=times; l.origin isa Storage && haskey(l.origin.unit_handling_cost, p)],
                    sum(received_by_origin[p, l, l.destinations[i], oc, t + l.times[i]] for i in 1:length(l.destinations) if t + l.times[i] <= supply_chain.horizon) == sent_by_origin[p, l, oc, t])
    @constraint(m, [p=_tariff_relevant_products, l=lanes, t=times; l.origin isa Storage && haskey(l.origin.unit_handling_cost, p)],
                    sum(sent_by_origin[p, l, oc, t] for oc in _origin_countries) == sent[pidx[p], lidx[l], t])

    @constraint(m, [l=lanes], sum(sent[pidx[p], lidx[l], t] for p in products, t in times if !can_ship(l, t)) == 0)
    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0 || l.fixed_cost > 0], sum(sent[pidx[p], lidx[l], t] for p in products) <= effective_bigM(total_demand_all_products) * used[l, t])
    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0], sum(sent[pidx[p], lidx[l], t] for p in products) >= l.minimum_quantity * used[l, t])

    @constraint(m, [s=storages, t=times], sum(sent[pidx[p], lidx[l], t] for p in products, l in _lanes_out(s)) <= effective_bigM(min(total_demand_all_products, s.maximum_overall_throughput)) * opened[psidx[s], t])
    # get_sent_time(l, l.destinations[1], t) depends only on (l, t), not p - precompute it
    # once per (l, t) instead of recomputing it for every product in both the condition and
    # the body below.
    single_customer_lane_sent_time = Dict((l, t) => get_sent_time(l, l.destinations[1], t)
                                           for l in lanes, t in times
                                           if length(l.destinations) == 1 && isa(l.destinations[1], Customer))
    @constraint(m, [p=products, l=lanes, t=times; get(single_customer_lane_sent_time, (l, t), 0) > 0],
                    received[p, l, l.destinations[1], t] <= get_demand(supply_chain, l.destinations[1], p, t) * opened[psidx[l.origin], single_customer_lane_sent_time[(l, t)]])
    @constraint(m, [p=products, s=storages, t=times; !isinf(_max_throughput[(p, s)])], sum(sent[pidx[p], lidx[l], t] for l in _lanes_out(s)) <= _max_throughput[(p, s)] * opened[psidx[s], t])
    @constraint(m, [s=storages, t=times; !isinf(s.maximum_overall_throughput)], sum(sent[pidx[p], lidx[l], t] for p in products, l in _lanes_out(s)) <= s.maximum_overall_throughput * opened[psidx[s], t])
    @constraint(m, [s=storages, t=times], sum(received[p, l, s, t] for p in products, l in _lanes_in(s)) <= effective_bigM(min(total_demand_all_products, s.maximum_overall_throughput)) * opened[psidx[s], t])

    @constraint(m, [p=products, s=storages, t=times; !isinf(_max_storage[(p, s)])], stored_at_end[p, s, t] <= _max_storage[(p, s)] * opened[psidx[s], t] + overflow[p, s, t])

    @constraint(m, [s=plants_storages; s.must_be_opened_at_end], opened[psidx[s], supply_chain.horizon] == 1)
    @constraint(m, [s=plants_storages; s.must_be_closed_at_end], opened[psidx[s], supply_chain.horizon] == 0)

    @constraint(m, [s=plants_storages], opening[psidx[s], 1] >= opened[psidx[s], 1] + (1 - s.initial_opened) - 1)
    @constraint(m, [s=plants_storages], opening[psidx[s], 1] <= opened[psidx[s], 1])
    @constraint(m, [s=plants_storages], opening[psidx[s], 1] <= 1 - s.initial_opened)

    @constraint(m, [s=plants_storages, t=times; t > 1], opening[psidx[s], t] >= opened[psidx[s], t] + (1 - opened[psidx[s], t-1]) - 1)
    @constraint(m, [s=plants_storages, t=times; t > 1], opening[psidx[s], t] <= opened[psidx[s], t])
    @constraint(m, [s=plants_storages, t=times; t > 1], opening[psidx[s], t] <= 1 - opened[psidx[s], t-1])

    @constraint(m, [s=plants_storages], closing[psidx[s], 1] >= (1 - opened[psidx[s], 1]) + s.initial_opened - 1)
    @constraint(m, [s=plants_storages], closing[psidx[s], 1] <= 1 - opened[psidx[s], 1])
    @constraint(m, [s=plants_storages], closing[psidx[s], 1] <= s.initial_opened)

    @constraint(m, [s=plants_storages, t=times; t > 1], closing[psidx[s], t] >= (1 - opened[psidx[s], t]) + opened[psidx[s], t-1] - 1)
    @constraint(m, [s=plants_storages, t=times; t > 1], closing[psidx[s], t] <= 1 - opened[psidx[s], t])
    @constraint(m, [s=plants_storages, t=times; t > 1], closing[psidx[s], t] <= opened[psidx[s], t-1])

    @constraint(m, [s=plants_storages; isinf(s.opening_cost)], sum(opening[psidx[s], t] for t in times) == 0)
    @constraint(m, [s=plants_storages; isinf(s.closing_cost)], sum(closing[psidx[s], t] for t in times) == 0)

    @constraint(m, [p=products, s=storages, t=times], stored_at_end[p, s, t] == stored_at_end[p, s, t-1]
                                                                            + sum(received[p, l, s, t] for l in _lanes_in(s))
                                                                            + sum(get_arrivals(p, l, s, t) for l in _lanes_in(s))
                                                                            - sum(sent[pidx[p], lidx[l], t] for l in _lanes_out(s))
                                                                            )
    @constraint(m, [p=products, s=storages, t=times; _additional_stock_cover[(p, s)] > 0], stored_at_end[p, s, t] >= _additional_stock_cover[(p, s)] * sum(sent[pidx[p], lidx[l], t] for l in _lanes_out(s)))

    # Cohort mirror of the storage balance just above: same inflows/outflows, split
    # by origin_country instead of summed. A Plant/Supplier inflow is attributed
    # entirely to that node's own (static) country - only a Storage inflow needs the
    # received_by_origin variable, since only a Storage can blend more than one
    # origin together. Anything else - get_arrivals (no origin data), and, in
    # principle, a lane whose origin is neither a Plant/Supplier nor a Storage (e.g. a
    # Customer, which ConcreteNode allows even though no fixture creates one) - is
    # attributed to the `nothing` ("unknown") bucket, same as initial_inventory above,
    # so this constraint always ties to the real balance exactly regardless of what's
    # in the network.
    @constraint(m, [p=_tariff_relevant_products, s=storages, oc=_origin_countries, t=times; haskey(s.unit_handling_cost, p)],
                    stored_by_origin[p, s, oc, t] == stored_by_origin[p, s, oc, t-1]
                                                    + sum(received[p, l, s, t] for l in _lanes_in(s) if (l.origin isa Plant || l.origin isa Supplier) && _country_of_node(l.origin) == oc)
                                                    + sum(received_by_origin[p, l, s, oc, t] for l in _lanes_in(s) if l.origin isa Storage && haskey(l.origin.unit_handling_cost, p))
                                                    + (isnothing(oc) ? sum(received[p, l, s, t] for l in _lanes_in(s) if !(l.origin isa Plant || l.origin isa Supplier || l.origin isa Storage)) : 0.0)
                                                    + (isnothing(oc) ? sum(get_arrivals(p, l, s, t) for l in _lanes_in(s)) : 0.0)
                                                    - sum(sent_by_origin[p, l, oc, t] for l in _lanes_out(s))
                                                    )
    # Ties the cohort breakdown back to the real stored_at_end - the whole point of
    # the overlay: stored_by_origin can never drift from the actual inventory it's
    # tracking the composition of.
    @constraint(m, [p=_tariff_relevant_products, s=storages, t=0:supply_chain.horizon; haskey(s.unit_handling_cost, p)],
                    sum(stored_by_origin[p, s, oc, t] for oc in _origin_countries) == stored_at_end[p, s, t])

    @constraint(m, [p=products, s=suppliers, t=times], bought[pidx[p], supidx[s], t] == sum(sent[pidx[p], lidx[l], t] for l in _lanes_out(s)))
    @constraint(m, [p=products, s=suppliers, t=times; !isinf(_max_throughput[(p, s)])], sum(sent[pidx[p], lidx[l], t] for l in _lanes_out(s)) <= _max_throughput[(p, s)])

    for s in plants, p in products
        pi_, si_ = pidx[p], plidx[s]
        if haskey(s.time, p)
            bigM_p_s = effective_bigM(min(total_demand[p], _max_throughput[(p, s)]))
            @constraint(m, [t=times, ti=t:min(t+s.time[p], supply_chain.horizon)], produced[pi_, si_, t] <= bigM_p_s * opened[psidx[s], ti])
        else
            @constraint(m, sum(produced[pi_, si_, :]) == 0)
            @constraint(m, sum(sum(sent[pi_, lidx[l], :]) for l in _lanes_out(s)) == 0)
        end
    end
    @constraint(m, [p=products, s=plants, t=times; haskey(s.time, p) && (t + s.time[p] <= supply_chain.horizon)], produced[pidx[p], plidx[s], t] == sum(sent[pidx[p], lidx[l], t + s.time[p]] for l in _lanes_out(s)))
    @constraint(m, [p=products, s=plants, t=times; !isinf(_max_throughput[(p, s)])], sum(sent[pidx[p], lidx[l], t] for l in _lanes_out(s)) <= _max_throughput[(p, s)])
    @constraint(m, [p=products, s=plants; !has_bom(s, p)], sum(produced[pidx[p], plidx[s], :]) == 0)
    @constraint(m, [p=products, s=plants, t=times], sum(produced[pidx[p2], plidx[s], t] * get_bom(s, p2, p) for p2 in products if has_bom(s, p2, p); init=0.0) == sum(received[p, l, s, t] for l in _lanes_in(s)))

    @constraint(m, [p=products, c=customers, t=times], sum(received[p, l, c, t] for l in _lanes_in(c)) + sum(get_arrivals(p, l, c, t) for l in _lanes_in(c)) == get_demand(supply_chain, c, p, t) - lost_sales[pidx[p], cidx[c], t])

    @constraint(m, [p=products, c=customers], sum(lost_sales[pidx[p], cidx[c], t] for t in times) <= (1 - get_service_level(supply_chain, c, p)) * sum(get_demand(supply_chain, c, p, t) for t in times))

    @constraint(m, [t=times], total_transportation_costs_per_period[t] == sum(sent[pidx[p], lidx[l], t] * l.unit_cost for p in products, l in lanes))
    @constraint(m, total_transportation_costs == sum(total_transportation_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_fixed_costs_per_period[t] == sum(opened[psidx[s], t] * s.fixed_cost for s in plants_storages))
    @constraint(m, total_fixed_costs == sum(total_fixed_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_holding_costs_per_period[t] == sum(stored_at_end[p, s, t] * get(s.unit_holding_cost, p, 0.0) for p in products, s in storages))
    @constraint(m, total_holding_costs == sum(total_holding_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_overflow_costs_per_period[t] == sum(overflow[p, s, t] * _overflow_cost[(p, s)] for p in products, s in storages if !isinf(_max_storage[(p, s)]); init=0.0))
    @constraint(m, total_overflow_costs == sum(total_overflow_costs_per_period[t] for t in times))

    # Summed directly over _tariff_unit_cost's (sparse) keys rather than over the full
    # (products, lanes, destinations) cross product, same reasoning as
    # total_overflow_costs_per_period above - most (p, l, d) triples have no tariff.
    @constraint(m, [t=times], total_tariff_costs_per_period[t] == sum(received[p, l, d, t] * coef for ((p, l, d), coef) in _tariff_unit_cost; init=0.0)
                                                                 + sum(received_by_origin[p, l, d, oc, t] * coef for ((p, l, d, oc), coef) in _cohort_tariff_unit_cost; init=0.0))
    @constraint(m, total_tariff_costs == sum(total_tariff_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_buying_costs_per_period[t] == sum(bought[pidx[p], supidx[s], t] * s.unit_cost[p] for p in products, s in suppliers if haskey(s.unit_cost, p); init=0.0))
    @constraint(m, [t=times], total_opening_costs_per_period[t] == sum(opening[psidx[s], t] * s.opening_cost for s in plants_storages if !isinf(s.opening_cost); init=0.0))
    @constraint(m, [t=times], total_closing_costs_per_period[t] == sum(closing[psidx[s], t] * s.closing_cost for s in plants_storages if !isinf(s.closing_cost); init=0.0))

    @constraint(m, [t=times], total_costs_per_period[t] == total_transportation_costs_per_period[t] +
                       total_fixed_costs_per_period[t] +
                       total_opening_costs_per_period[t] +
                       total_closing_costs_per_period[t] +
                       sum(sum(received[p, l, s, t] * s.unit_handling_cost[p] for l in _lanes_in(s)) for p in products for s in storages if haskey(s.unit_handling_cost, p)) +
                       total_buying_costs_per_period[t] +
                       sum(produced[pidx[p], plidx[s], t] * s.unit_cost[p] for p in products, s in plants if haskey(s.unit_cost, p)) +
                       sum(l.fixed_cost * used[l, t] for l in _fixed_cost_lanes) +
                       total_holding_costs_per_period[t] +
                       total_overflow_costs_per_period[t] +
                       total_tariff_costs_per_period[t])

    @constraint(m, [t=times], total_revenues_per_period[t] == sum((get_sales_price(supply_chain, c, p, t) * (get_demand(supply_chain, c, p, t) - lost_sales[pidx[p], cidx[c], t])) for p in products for c in customers))
    @constraint(m, total_revenues == sum(supply_chain.discount_factor ^ (t-1) * total_revenues_per_period[t] for t in times))

    @constraint(m, total_costs == sum(supply_chain.discount_factor ^ (t-1) * total_costs_per_period[t] for t in times))

    @constraint(m, total_profits == total_revenues - total_costs)

    return m
end
