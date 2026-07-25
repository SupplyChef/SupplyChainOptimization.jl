@testset "MaturationScheduling" begin

# --- pure helper functions (no solve needed) ---

@test begin
    # target 100, +/-10% acceptable, +/-10% further extended -> acceptable [90,110],
    # sellable-but-off-target [80,90) and (110,120], unsellable outside [80,120].
    product = Product("batch")
    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100)
    add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1)

    SupplyChainOptimization.maturation_zone(source, product, 7) === nothing &&   # value=70, below even the extended range
    SupplyChainOptimization.maturation_zone(source, product, 8) == 1 &&   # value=80, sellable underrun
    SupplyChainOptimization.maturation_zone(source, product, 9) == 0 &&   # value=90, ideal (boundary)
    SupplyChainOptimization.maturation_zone(source, product, 10) == 0 &&  # value=100, ideal
    SupplyChainOptimization.maturation_zone(source, product, 11) == 0 &&  # value=110, ideal (boundary)
    SupplyChainOptimization.maturation_zone(source, product, 12) == 2 &&  # value=120, sellable overrun
    SupplyChainOptimization.maturation_zone(source, product, 13) === nothing  # value=130, unsellable
end

@test begin
    # feasible_exits should exclude start days at/before unavailable_periods, and only pair a
    # start day u with ship days t giving a sellable (non-nothing) zone.
    product = Product("batch")
    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100, unavailable_periods=3)
    add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1)

    triples = SupplyChainOptimization.feasible_exits(source, product, 1:5, 1:20)
    # No triple should ever start at u<=3 (the unavailable/sanitation period).
    all(u > 3 for (u, t, zone) in triples) &&
        (4, 13, 0) in triples &&   # u=4, duration=9 -> value=90 -> zone 0 (ideal, boundary)
        (4, 12, 1) in triples      # u=4, duration=8 -> value=80 -> zone 1 (sellable underrun)
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

    triples = SupplyChainOptimization.feasible_exits(source, product, 1:10, 1:10)
    any(u == 1 for (u, t, zone) in triples)
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

end