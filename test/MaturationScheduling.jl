@testset "MaturationScheduling" begin

# --- pure helper functions (no solve needed) ---

@test begin
    # target 100, +/-10% acceptable, +/-10% further extended -> acceptable [90,110],
    # sellable-but-off-target [80,90) and (110,120], unsellable outside [80,120].
    product = Product("batch")
    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100)
    add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1,
                                  underrun_unit_penalty=2.0, overrun_unit_penalty=3.0)

    !SupplyChainOptimization.is_feasible_duration(source, product, 7) &&   # value=70, below even the extended range
    SupplyChainOptimization.is_feasible_duration(source, product, 8) &&   # value=80, sellable underrun
    SupplyChainOptimization.get_duration_penalty(source, product, 8) ≈ 2.0 * abs(100.0 - 80.0) &&
    SupplyChainOptimization.is_feasible_duration(source, product, 9) &&   # value=90, ideal (boundary)
    SupplyChainOptimization.get_duration_penalty(source, product, 9) == 0.0 &&
    SupplyChainOptimization.is_feasible_duration(source, product, 10) &&  # value=100, ideal
    SupplyChainOptimization.get_duration_penalty(source, product, 10) == 0.0 &&
    SupplyChainOptimization.is_feasible_duration(source, product, 11) &&  # value=110, ideal (boundary)
    SupplyChainOptimization.is_feasible_duration(source, product, 12) &&  # value=120, sellable overrun
    SupplyChainOptimization.get_duration_penalty(source, product, 12) ≈ 3.0 * abs(100.0 - 120.0) &&
    !SupplyChainOptimization.is_feasible_duration(source, product, 13)  # value=130, unsellable
end

@test begin
    # feasible_exits should exclude start days at/before unavailable_periods, and only pair a
    # start day u with ship days t that are feasible per the source's curve.
    product = Product("batch")
    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100, unavailable_periods=3)
    add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1)

    pairs = SupplyChainOptimization.feasible_exits(source, product, 1:5, 1:20)
    # No pair should ever start at u<=3 (the unavailable/sanitation period).
    all(u > 3 for (u, t) in pairs) &&
        (4, 13) in pairs &&   # u=4, duration=9 -> value=90 -> ideal (boundary)
        (4, 12) in pairs      # u=4, duration=8 -> value=80 -> sellable underrun
end

@test begin
    # A source that already holds a batch (initial_inventory > 0) must have day 1 available as
    # a start day even though it's within the (otherwise blocking) unavailable_periods window.
    product = Product("batch")
    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100, unavailable_periods=5)
    add_product!(source, product; initial_value=90.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1,
                                  initial_inventory=100.0)

    pairs = SupplyChainOptimization.feasible_exits(source, product, 1:10, 1:10)
    any(u == 1 for (u, t) in pairs)
end

@test_throws ArgumentError begin
    sc = SupplyChain(20)
    product = Product("batch")
    other_product = Product("unregistered")
    add_product!(sc, product)

    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100)
    add_product!(source, other_product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                        acceptable_deviation_under=0.1, acceptable_deviation_over=0.1)
    add_maturation_source!(sc, source)

    sink = QuotaSink("k1", Location(0.0, 0.0))
    add_product!(sink, product; quota=100.0)
    add_quota_sink!(sc, sink)

    create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0)
end

# --- solved instances ---

# A single source/sink, a single delivery day: fully hand-computable. distance=1, cost_per_km=1,
# capacity=100 -> shipping costs 100; not shipping costs the quota shortfall penalty (100 units *
# underproduction_unit_penalty=5 -> 500), so the optimizer should always prefer to ship. Among
# feasible ship durations (only 8 or 9, since the single delivery day t=10 bounds u<10), duration 9
# (u=1) lands exactly at the acceptable boundary (value=90, zone 0, zero deviation penalty) and
# strictly dominates duration 8's zone-1 (penalized) option at the same transport cost.
@test begin
    sc = SupplyChain(20)
    product = Product("batch")
    add_product!(sc, product)

    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100)
    add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1,
                                  underrun_unit_penalty=1.0, overrun_unit_penalty=1.0)
    add_maturation_source!(sc, source)

    sink = QuotaSink("k1", Location(0.0, 0.0))
    add_product!(sink, product; quota=100.0, underproduction_unit_penalty=5.0, overproduction_unit_penalty=5.0)
    add_quota_sink!(sc, sink)

    m = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0,
                                           distance=(a, b) -> 1.0, is_delivery_day=t -> t == 10)
    JuMP.optimize!(m)
    sc.optimization_model = m

    schedule = get_maturation_schedule(sc, source, product)

    termination_status(m) == OPTIMAL &&
        objective_value(m) ≈ 100.0 &&
        schedule.start_day == 1 &&
        schedule.ship_day == 10 &&
        schedule.sink == sink &&
        get_quota_shortfall(sc, sink, product, 10) ≈ 0.0 &&
        get_quota_excess(sc, sink, product, 10) ≈ 0.0
end

# Two sources, each half the quota: both must ship (on the same day, since it's the only
# delivery day) for the quota to be met without penalty - verifies constraint (8) sums shipments
# from every source, and constraints (9)/(11) still let each source ship independently at most
# once.
@test begin
    sc = SupplyChain(20)
    product = Product("batch")
    add_product!(sc, product)

    for name in ("s1", "s2")
        source = MaturationSource(name, Location(0.0, 0.0); capacity=50)
        add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                      acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                      extended_deviation_under=0.1, extended_deviation_over=0.1)
        add_maturation_source!(sc, source)
    end

    sink = QuotaSink("k1", Location(0.0, 0.0))
    add_product!(sink, product; quota=100.0, underproduction_unit_penalty=5.0, overproduction_unit_penalty=5.0)
    add_quota_sink!(sc, sink)

    m = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=0.1,
                                           distance=(a, b) -> 1.0, is_delivery_day=t -> t == 10)
    JuMP.optimize!(m)
    sc.optimization_model = m

    s1 = first(s for s in sc.maturation_sources if s.name == "s1")
    s2 = first(s for s in sc.maturation_sources if s.name == "s2")
    schedule1 = get_maturation_schedule(sc, s1, product)
    schedule2 = get_maturation_schedule(sc, s2, product)

    termination_status(m) == OPTIMAL &&
        !isnothing(schedule1) && !isnothing(schedule2) &&
        schedule1.ship_day == 10 && schedule2.ship_day == 10 &&
        get_quota_shortfall(sc, sink, product, 10) ≈ 0.0 &&
        get_quota_excess(sc, sink, product, 10) ≈ 0.0
end

# A source with an in-progress batch (initial_inventory > 0) must ship it during the horizon
# (constraint 13), even though unavailable_periods would otherwise block it from starting.
@test begin
    sc = SupplyChain(20)
    product = Product("batch")
    add_product!(sc, product)

    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100, unavailable_periods=15)
    add_product!(source, product; initial_value=90.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1,
                                  initial_inventory=100.0)
    add_maturation_source!(sc, source)

    sink = QuotaSink("k1", Location(0.0, 0.0))
    add_product!(sink, product; quota=100.0, underproduction_unit_penalty=1000.0, overproduction_unit_penalty=1000.0)
    add_quota_sink!(sc, sink)

    m = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0, distance=(a, b) -> 1.0)
    JuMP.optimize!(m)
    sc.optimization_model = m

    schedule = get_maturation_schedule(sc, source, product)

    termination_status(m) == OPTIMAL && !isnothing(schedule) && schedule.start_day == 1
end

# The advanced, fully-custom add_product! form (a classical shelf-life curve: constant value,
# sellable only within a fixed age window, no partial-quality penalty) works through the full
# MILP exactly like the linear/%-band form - proving MaturationSource's generalization beyond
# harvest-scheduling-shaped curves end-to-end, not just at the level of the pure helper
# functions tested above.
@test begin
    sc = SupplyChain(10)
    product = Product("cheese")
    add_product!(sc, product)

    source = MaturationSource("cave1", Location(0.0, 0.0); capacity=50)
    add_product!(source, product,
                 duration -> 1.0,                # value_function: constant once ready
                 duration -> 2 <= duration <= 5,  # feasible_duration: sellable ages 2 to 5
                 duration -> 0.0)                 # duration_penalty: no partial-quality penalty
    add_maturation_source!(sc, source)

    sink = QuotaSink("shop1", Location(0.0, 0.0))
    add_product!(sink, product; quota=50.0, underproduction_unit_penalty=10.0, overproduction_unit_penalty=10.0)
    add_quota_sink!(sc, sink)

    m = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0,
                                           distance=(a, b) -> 1.0, is_delivery_day=t -> t == 6)
    JuMP.optimize!(m)
    sc.optimization_model = m

    schedule = get_maturation_schedule(sc, source, product)

    termination_status(m) == OPTIMAL &&
        objective_value(m) ≈ 50.0 &&
        !isnothing(schedule) &&
        schedule.ship_day == 6 &&
        2 <= schedule.ship_day - schedule.start_day <= 5
end

# integer_quota_deviation=true (the default) requires quota/capacity to be integer-valued: an
# integer q_plus/q_minus can never exactly reconcile a fractional target, so a fractional
# capacity/quota makes the model infeasible regardless of what ships. integer_quota_deviation=
# false lifts that restriction.
@test begin
    sc = SupplyChain(20)
    product = Product("batch")
    add_product!(sc, product)

    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100.5)
    add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1)
    add_maturation_source!(sc, source)

    sink = QuotaSink("k1", Location(0.0, 0.0))
    add_product!(sink, product; quota=100.5, underproduction_unit_penalty=1.0, overproduction_unit_penalty=1.0)
    add_quota_sink!(sc, sink)

    m_integer = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0,
                                                    distance=(a, b) -> 1.0, is_delivery_day=t -> t == 10)
    JuMP.optimize!(m_integer)

    m_continuous = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0,
                                                       distance=(a, b) -> 1.0, is_delivery_day=t -> t == 10,
                                                       integer_quota_deviation=false)
    JuMP.optimize!(m_continuous)

    termination_status(m_integer) == INFEASIBLE && termination_status(m_continuous) == OPTIMAL
end

end