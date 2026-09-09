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

    @constraint(m, [p=products, l=lanes, t=times], sum(received[p, l, l.destinations[i], t + l.times[i]] for i in 1:length(l.destinations) if t + l.times[i] <= supply_chain.horizon) == sent[pidx[p], lidx[l], t])

    @constraint(m, [l=lanes], sum(sent[pidx[p], lidx[l], t] for p in products, t in times if !can_ship(l, t)) == 0)
    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0 || l.fixed_cost > 0], sum(sent[pidx[p], lidx[l], t] for p in products) <= effective_bigM(total_demand_all_products) * used[l, t])
    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0], sum(sent[pidx[p], lidx[l], t] for p in products) >= l.minimum_quantity * used[l, t])

    @constraint(m, [s=storages, t=times], sum(sent[pidx[p], lidx[l], t] for p in products, l in _lanes_out(s)) <= effective_bigM(min(total_demand_all_products, s.maximum_overall_throughput)) * opened[sidx[s], t])
    # get_sent_time(l, l.destinations[1], t) depends only on (l, t), not p - precompute it
    # once per (l, t) instead of recomputing it for every product in both the condition and
    # the body below.
    single_customer_lane_sent_time = Dict((l, t) => get_sent_time(l, l.destinations[1], t)
                                           for l in lanes, t in times
                                           if length(l.destinations) == 1 && isa(l.destinations[1], Customer))
    @constraint(m, [p=products, l=lanes, t=times; get(single_customer_lane_sent_time, (l, t), 0) > 0],
                    received[p, l, l.destinations[1], t] <= get_demand(supply_chain, l.destinations[1], p, t) * opened[psidx[l.origin], single_customer_lane_sent_time[(l, t)]])
    @constraint(m, [p=products, s=storages, t=times; !isinf(_max_throughput[(p, s)])], sum(sent[pidx[p], lidx[l], t] for l in _lanes_out(s)) <= _max_throughput[(p, s)] * opened[sidx[s], t])
    @constraint(m, [s=storages, t=times; !isinf(s.maximum_overall_throughput)], sum(sent[pidx[p], lidx[l], t] for p in products, l in _lanes_out(s)) <= s.maximum_overall_throughput * opened[sidx[s], t])
    @constraint(m, [s=storages, t=times], sum(received[p, l, s, t] for p in products, l in _lanes_in(s)) <= effective_bigM(min(total_demand_all_products, s.maximum_overall_throughput)) * opened[sidx[s], t])

    @constraint(m, [p=products, s=storages, t=times; !isinf(_max_storage[(p, s)])], stored_at_end[p, s, t] <= _max_storage[(p, s)] * opened[sidx[s], t] + overflow[p, s, t])

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
                       total_overflow_costs_per_period[t])

    @constraint(m, [t=times], total_revenues_per_period[t] == sum((get_sales_price(supply_chain, c, p, t) * (get_demand(supply_chain, c, p, t) - lost_sales[pidx[p], cidx[c], t])) for p in products for c in customers))
    @constraint(m, total_revenues == sum(supply_chain.discount_factor ^ (t-1) * total_revenues_per_period[t] for t in times))

    @constraint(m, total_costs == sum(supply_chain.discount_factor ^ (t-1) * total_costs_per_period[t] for t in times))

    @constraint(m, total_profits == total_revenues - total_costs)

    return m
end
