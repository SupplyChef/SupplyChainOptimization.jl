"""
Checks that every product referenced by a `MaturationSource` or `QuotaSink` is registered on
the supply chain, mirroring `check_model`'s checks for plants/customers.
"""
function check_maturation_model(supply_chain)
    for source in supply_chain.maturation_sources
        for product in keys(source.value_function)
            if !(product in supply_chain.products)
                throw(ArgumentError("MaturationSource $source has product $product that is not in the supply chain's products."))
            end
        end
    end
    for sink in supply_chain.quota_sinks
        for product in keys(sink.quota)
            if !(product in supply_chain.products)
                throw(ArgumentError("QuotaSink $sink has product $product that is not in the supply chain's products."))
            end
        end
    end
end

# A source may start a new batch of product on day u if u is past its mandatory turnaround
# (unavailable_periods), OR u is day 1 and the source already holds a batch of product
# (initial_inventory[product] > 0) - day 1 is then a bookkeeping reference for that
# in-progress batch (see feasible_exits's docstring in Modeling.jl), not a new scheduling
# choice, so it is exempt from the turnaround gate.
function _is_valid_start(source, product, u)
    return u > source.unavailable_periods || (u == 1 && get(source.initial_inventory, product, 0.0) > 0)
end

"""
    create_maturation_scheduling_model(supply_chain, optimizer=HiGHS.Optimizer; transport_cost_per_distance,
                                       distance=haversine, is_start_day=t -> true, is_delivery_day=t -> true)

Builds the mixed-integer linear program for the integrated maturation-scheduling and
distribution problem: assigning each `MaturationSource`'s single batch a start day, a ship day
(among the days its resulting value falls in an acceptable or extended-but-sellable range), and
a `QuotaSink` destination, minimizing the sum of distance-based transportation cost,
value-deviation penalties, and quota-deviation penalties.

This is the IPPDP of Gbéya, Darvish, Renaud and Coelho (2026), "Integrated Poultry
Production-Distribution Optimization", CIRRELT-2026-10, generalized from a single poultry
product/global target to arbitrary products and per-source targets (see `MaturationSource`
and `QuotaSink`).

`transport_cost_per_distance` is the cost per unit of `distance` (default [`haversine`](@ref),
which returns meters - see also [`haversine_km`](@ref)) between a source and a sink, applied
per unit of the source's shipped batch (`MaturationSource.capacity`).

`is_start_day`/`is_delivery_day` restrict which days of the horizon (`1:supply_chain.horizon`)
batches may start or ship on respectively - e.g. to exclude weekends/holidays. Both default to
allowing every day.

`integer_quota_deviation` (default `true`, matching the paper's `q_st^+, q_st^- ∈ Z_+`) makes
the quota over/underproduction variables integer - correct when `capacity`/`quota` count
discrete units (e.g. birds), but a trap for continuous-valued capacities (mass, currency-like
units): an integer deviation can never exactly reconcile a fractional quota shortfall/excess,
making the model infeasible by construction regardless of what ships. Pass `false` when
`capacity`/`quota` aren't inherently integer.

Call `JuMP.optimize!` on the returned model (or use [`optimize_maturation_schedule!`](@ref)),
then query results with [`get_maturation_schedule`](@ref), [`get_quota_shortfall`](@ref) and
[`get_quota_excess`](@ref).
"""
function create_maturation_scheduling_model(supply_chain, optimizer=HiGHS.Optimizer; transport_cost_per_distance::Real,
                                            distance=haversine, is_start_day=t -> true, is_delivery_day=t -> true,
                                            integer_quota_deviation::Bool=true)
    check_maturation_model(supply_chain)

    sources = supply_chain.maturation_sources
    sinks = supply_chain.quota_sinks
    products = supply_chain.products

    T = 1:supply_chain.horizon
    U = [t for t in T if is_start_day(t)]
    V = [t for t in T if is_delivery_day(t)]

    m = Model(optimizer)
    set_string_names_on_creation(m, false)

    # Precomputed alongside the (sparse, filtered) @variable containers below, and registered
    # on the model (m[:y_index]/m[:r_index]) so query functions (get_maturation_schedule) can
    # iterate the exact set of valid keys as a plain Vector of tuples, rather than relying on
    # JuMP.Containers.SparseAxisArray's own iteration protocol.
    y_index = [(b, p, u, t) for b in sources, p in products, u in U, t in V
               if has_product(b, p) && t > u && _is_valid_start(b, p, u) && is_feasible_duration(b, p, t - u)]
    r_index = [(b, p, s, t) for b in sources, p in products, s in sinks, t in V if has_product(b, p)]

    # y[b,p,u,t]: a batch of p starts at source b on day u and ships on day t.
    @variable(m, y[b=sources, p=products, u=U, t=V;
                   has_product(b, p) && t > u && _is_valid_start(b, p, u) && is_feasible_duration(b, p, t - u)], Bin)

    # r[b,p,s,t]: source b's batch of p ships to sink s on day t.
    @variable(m, r[b=sources, p=products, s=sinks, t=V; has_product(b, p)], Bin)

    # q_plus/q_minus: sink s's over/under-quota deviation for p on day t. Int by default
    # (matching the paper's Z_+ domain); see integer_quota_deviation's docstring for why that's
    # unsafe for continuous-valued capacities/quotas.
    if integer_quota_deviation
        @variable(m, q_plus[s=sinks, p=products, t=V; has_product(s, p)] >= 0, Int)
        @variable(m, q_minus[s=sinks, p=products, t=V; has_product(s, p)] >= 0, Int)
    else
        @variable(m, q_plus[s=sinks, p=products, t=V; has_product(s, p)] >= 0)
        @variable(m, q_minus[s=sinks, p=products, t=V; has_product(s, p)] >= 0)
    end

    m[:y_index] = y_index
    m[:r_index] = r_index

    # Named to match the paper's own four-way objective breakdown (Figure 2's OF_d, OF_w,
    # OF_q+, OF_q-) - see get_total_deviation_costs/get_total_overproduction_costs/
    # get_total_underproduction_costs below for the query-side counterparts.
    @expression(m, total_transportation_costs,
        sum(transport_cost_per_distance * distance(b.location, s.location) * b.capacity * r[b, p, s, t]
            for b in sources, p in products, s in sinks, t in V if has_product(b, p);
            init=0.0))

    @expression(m, total_deviation_costs,
        sum(b.capacity * get_duration_penalty(b, p, t - u) * y[b, p, u, t]
            for b in sources, p in products, u in U, t in V
            if has_product(b, p) && t > u && _is_valid_start(b, p, u) && is_feasible_duration(b, p, t - u);
            init=0.0))

    @expression(m, total_overproduction_costs,
        sum(s.overproduction_unit_penalty[p] * q_plus[s, p, t] for s in sinks, p in products, t in V if has_product(s, p); init=0.0))

    @expression(m, total_underproduction_costs,
        sum(s.underproduction_unit_penalty[p] * q_minus[s, p, t] for s in sinks, p in products, t in V if has_product(s, p); init=0.0))

    @expression(m, total_quota_deviation_costs, total_overproduction_costs + total_underproduction_costs)

    # total_costs (and reusing the transportation-cost expression's name) is deliberate: it lets
    # the existing get_total_costs/get_total_transportation_costs from Querying.jl (written for
    # create_network_model) work unchanged against a maturation-scheduling model's
    # supply_chain.optimization_model too, rather than needing their own re-declared copies here.
    @expression(m, total_costs, total_transportation_costs + total_deviation_costs + total_quota_deviation_costs)

    @objective(m, Min, total_costs)

    # (8) Deliveries to each sink meet its quota up to a penalized deviation.
    @constraint(m, [s=sinks, p=products, t=V; has_product(s, p)],
        sum(b.capacity * r[b, p, s, t] for b in sources if has_product(b, p); init=0.0) == s.quota[p] - q_minus[s, p, t] + q_plus[s, p, t])

    # (9) Each source ships at most once across the whole horizon (all-in-all-out, across every product it can hold).
    @constraint(m, [b=sources],
        sum(r[b, p, s, t] for p in products, s in sinks, t in V if has_product(b, p); init=0.0) <= 1)

    # (10) A source's shipment on day t equals the batch that was scheduled to exit on day t, if any.
    @constraint(m, [b=sources, p=products, t=V; has_product(b, p)],
        sum(r[b, p, s, t] for s in sinks; init=0.0) ==
        sum(y[b, p, u, t] for u in U if _is_valid_start(b, p, u) && t > u && is_feasible_duration(b, p, t - u); init=0.0))

    # (11) Each source starts at most one batch across the whole horizon (across every product it can hold).
    @constraint(m, [b=sources],
        sum(y[b, p, u, t] for p in products, u in U, t in V
            if has_product(b, p) && _is_valid_start(b, p, u) && t > u && is_feasible_duration(b, p, t - u);
            init=0.0) <= 1)

    # (13) A source that already holds a batch of a product must ship it during the horizon.
    @constraint(m, [b=sources, p=products; has_product(b, p) && get(b.initial_inventory, p, 0.0) > 0],
        sum(y[b, p, 1, t] for t in V if t > 1 && is_feasible_duration(b, p, t - 1); init=0.0) == 1)

    return m
end

"""
    optimize_maturation_schedule!(supply_chain, optimizer=HiGHS.Optimizer; transport_cost_per_distance,
                                  distance=haversine, is_start_day=t -> true, is_delivery_day=t -> true,
                                  integer_quota_deviation=true, log=false, time_limit=3600.0)

Builds (see [`create_maturation_scheduling_model`](@ref)) and solves the maturation-scheduling
model for `supply_chain`, storing the result on `supply_chain.optimization_model` for
[`get_maturation_schedule`](@ref), [`get_quota_shortfall`](@ref) and [`get_quota_excess`](@ref).
"""
function optimize_maturation_schedule!(supply_chain, optimizer=HiGHS.Optimizer; transport_cost_per_distance::Real,
                                       distance=haversine, is_start_day=t -> true, is_delivery_day=t -> true,
                                       integer_quota_deviation::Bool=true,
                                       log::Bool=false, time_limit::Real=3600.0)
    m = create_maturation_scheduling_model(supply_chain, optimizer; transport_cost_per_distance=transport_cost_per_distance,
                                           distance=distance, is_start_day=is_start_day, is_delivery_day=is_delivery_day,
                                           integer_quota_deviation=integer_quota_deviation)
    set_attribute(m, "time_limit", time_limit)
    set_attribute(m, "log_to_console", log)
    supply_chain.optimization_model = m
    JuMP.optimize!(m)
    return m
end

"""
    get_maturation_schedule(supply_chain, source::MaturationSource, product)

After solving a maturation-scheduling model (see [`create_maturation_scheduling_model`](@ref)),
gets the `(start_day, ship_day, sink)` chosen for `source`'s batch of `product`, or `nothing` if
`source` did not ship a batch of `product` (e.g. it never held one).
"""
function get_maturation_schedule(supply_chain, source::MaturationSource, product)
    m = supply_chain.optimization_model
    y = m[:y]
    for (b, p, u, t) in m[:y_index]
        if b == source && p == product && value(y[b, p, u, t]) > 0.5
            r = m[:r]
            for (rb, rp, rs, rt) in m[:r_index]
                if rb == source && rp == product && rt == t && value(r[rb, rp, rs, rt]) > 0.5
                    return (start_day=u, ship_day=t, sink=rs)
                end
            end
            return (start_day=u, ship_day=t, sink=nothing)
        end
    end
    return nothing
end

"""
    get_quota_shortfall(supply_chain, sink::QuotaSink, product, period)

Gets the number of units by which deliveries of `product` to `sink` fell short of its quota
during `period`, after solving (see [`create_maturation_scheduling_model`](@ref)).
"""
function get_quota_shortfall(supply_chain, sink::QuotaSink, product, period)
    return value(supply_chain.optimization_model[:q_minus][sink, product, period])
end

"""
    get_quota_excess(supply_chain, sink::QuotaSink, product, period)

Gets the number of units by which deliveries of `product` to `sink` exceeded its quota during
`period`, after solving (see [`create_maturation_scheduling_model`](@ref)).
"""
function get_quota_excess(supply_chain, sink::QuotaSink, product, period)
    return value(supply_chain.optimization_model[:q_plus][sink, product, period])
end

"""
    get_total_deviation_costs(supply_chain)

Gets the total value-deviation penalty across every shipped batch, after solving (see
[`create_maturation_scheduling_model`](@ref)) - the `OF_w` component of the paper's own
objective breakdown (Figure 2). `get_total_transportation_costs` and `get_total_costs` (from
`Querying.jl`, written for [`minimize_cost!`](@ref)/[`maximize_profits!`](@ref)'s network model)
work unchanged against a maturation-scheduling model too.
"""
function get_total_deviation_costs(supply_chain)
    return value(supply_chain.optimization_model[:total_deviation_costs])
end

"""
    get_total_overproduction_costs(supply_chain)

Gets the total overproduction (over-quota) penalty across every sink and period, after solving
(see [`create_maturation_scheduling_model`](@ref)) - the `OF_q+` component of the paper's own
objective breakdown (Figure 2).
"""
function get_total_overproduction_costs(supply_chain)
    return value(supply_chain.optimization_model[:total_overproduction_costs])
end

"""
    get_total_underproduction_costs(supply_chain)

Gets the total underproduction (under-quota) penalty across every sink and period, after solving
(see [`create_maturation_scheduling_model`](@ref)) - the `OF_q-` component of the paper's own
objective breakdown (Figure 2).
"""
function get_total_underproduction_costs(supply_chain)
    return value(supply_chain.optimization_model[:total_underproduction_costs])
end

"""
    get_total_quota_deviation_costs(supply_chain)

Gets the total quota-deviation penalty (over- and under-production combined) across every sink
and period, after solving (see [`create_maturation_scheduling_model`](@ref)) - equivalent to
`get_total_overproduction_costs(supply_chain) + get_total_underproduction_costs(supply_chain)`.
"""
function get_total_quota_deviation_costs(supply_chain)
    return value(supply_chain.optimization_model[:total_quota_deviation_costs])
end
