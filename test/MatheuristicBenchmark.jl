using Dates

# A synthetic instance at roughly the scale the CIRRELT-2026-10 paper itself found hard for a
# direct commercial solver (tens of farms, a multi-week horizon) - small UFLlib instances
# elsewhere in this test suite solve to proven optimality in a fraction of a second, which
# proves matheuristic_optimize! doesn't regress but says nothing about whether it actually
# helps. This is deliberately sized to be non-trivial under a short, CI-friendly time budget.
function _random_maturation_benchmark_instance(num_farms::Int, horizon::Int)
    sc = SupplyChain(horizon)
    product = Product("bird")
    add_product!(sc, product)

    target_value = 22500.0
    initial_value = 45.0
    # A duration uniformly drawn from [24, 32] days (within the paper's 3-5 week breeding
    # window) fixes the growth rate needed to land exactly on target_value at that duration -
    # guarantees every farm has a real, reachable ideal window within the horizon, rather than
    # risking an unsatisfiable random instance that would make the comparison meaningless.
    for f in 1:num_farms
        target_duration = 24.0 + rand() * 8.0
        growth_rate = (target_value - initial_value) / target_duration
        capacity = 4000.0 + rand() * (32000.0 - 4000.0)
        farm = MaturationSource("farm$f", Location(45.0 + rand(), -73.0 + rand()); capacity=capacity)
        add_product!(farm, product; initial_value=initial_value, maturation_rate=growth_rate, target_value=target_value,
                                    acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                    extended_deviation_under=0.05, extended_deviation_over=0.05,
                                    underrun_unit_penalty=0.0007, overrun_unit_penalty=0.001)
        add_maturation_source!(sc, farm)
    end

    total_capacity = sum(f.capacity for f in sc.maturation_sources)
    sink = QuotaSink("slaughterhouse1", Location(45.5, -73.5))
    add_product!(sink, product; quota=total_capacity / horizon, underproduction_unit_penalty=1.0, overproduction_unit_penalty=1.0)
    add_quota_sink!(sc, sink)

    return sc
end

@testset "MatheuristicBenchmark" begin

@test begin
    sc = _random_maturation_benchmark_instance(60, 42)

    direct_time_limit = 20.0
    m_direct = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0, distance=haversine_km)
    set_attribute(m_direct, "time_limit", direct_time_limit)
    set_silent(m_direct)
    direct_start = Dates.now()
    JuMP.optimize!(m_direct)
    direct_elapsed = Dates.now() - direct_start
    direct_objective = has_values(m_direct) ? objective_value(m_direct) : Inf
    direct_gap = try
        relative_gap(m_direct)
    catch
        NaN
    end

    m_heuristic = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0, distance=haversine_km)
    set_silent(m_heuristic)
    heuristic_start = Dates.now()
    SupplyChainOptimization.matheuristic_optimize!(m_heuristic; iterations=4, fix_fraction=0.85, time_limit_per_iteration=6.0)
    heuristic_elapsed = Dates.now() - heuristic_start
    heuristic_objective = has_values(m_heuristic) ? objective_value(m_heuristic) : Inf

    println("--- Matheuristic benchmark (60 farms, 42-day horizon) ---")
    println("Direct solve:      objective=$direct_objective, gap=$direct_gap, time=$direct_elapsed (time_limit=$(direct_time_limit)s)")
    println("Matheuristic:       objective=$heuristic_objective, time=$heuristic_elapsed (4 iterations x 6s + initial solve)")
    if isfinite(direct_objective) && isfinite(heuristic_objective)
        pct = 100 * (direct_objective - heuristic_objective) / direct_objective
        println("Matheuristic vs direct: $(round(pct; digits=2))% $(pct >= 0 ? "better" : "worse")")
    end

    # A correctness floor, not a performance gate (shared CI hardware timing is too noisy for a
    # strict performance assertion to be anything but flaky) - both approaches must at least
    # find *a* feasible solution on an instance built to be satisfiable by construction.
    isfinite(direct_objective) && isfinite(heuristic_objective)
end

end
