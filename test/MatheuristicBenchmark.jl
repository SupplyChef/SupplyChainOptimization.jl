using Dates

# A synthetic instance at roughly the scale the CIRRELT-2026-10 paper itself found hard for a
# direct commercial solver - small UFLlib instances elsewhere in this test suite solve to proven
# optimality in a fraction of a second, which proves matheuristic_optimize! doesn't regress but
# says nothing about whether it actually helps. A first attempt at 60 farms/1 sink also turned
# out too easy (HiGHS proved optimality in well under a second - see the commit history for
# that result): the paper's own difficulty comes less from farm count alone than from splitting
# the assignment across multiple slaughterhouses, so num_sinks matters at least as much as
# num_farms here.
function _random_maturation_benchmark_instance(num_farms::Int, num_sinks::Int, horizon::Int)
    sc = SupplyChain(horizon)
    product = Product("bird")
    add_product!(sc, product)

    target_value = 22500.0
    initial_value = 45.0
    # A duration uniformly drawn from [24, 32] days (within the paper's 3-5 week breeding
    # window) fixes the growth rate needed to land exactly on target_value at that duration -
    # guarantees every farm has a real, reachable ideal window within the horizon, rather than
    # risking an unsatisfiable random instance that would make the comparison meaningless.
    # Capacities are integer-valued (birds are countable units, matching the paper's own
    # instance generator) so quotas below - and every multiple of them constraint (8) sums -
    # come out integer too. create_maturation_scheduling_model's q_plus/q_minus are integer by
    # default (see its integer_quota_deviation docstring): a fractional quota target could never
    # be reconciled exactly by an integer deviation, making the model infeasible by construction
    # regardless of what ships - the trap this instance is built to avoid, not work around.
    for f in 1:num_farms
        target_duration = 24.0 + rand() * 8.0
        growth_rate = (target_value - initial_value) / target_duration
        capacity = Float64(rand(4000:32000))
        farm = MaturationSource("farm$f", Location(45.0 + rand(), -73.0 + rand()); capacity=capacity)
        add_product!(farm, product; initial_value=initial_value, maturation_rate=growth_rate, target_value=target_value,
                                    acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                    extended_deviation_under=0.05, extended_deviation_over=0.05,
                                    underrun_unit_penalty=0.0007, overrun_unit_penalty=0.001)
        add_maturation_source!(sc, farm)
    end

    # Roughly mirrors the paper's own 50/30/20-style split across slaughterhouses, generalized
    # to any num_sinks: shares decrease geometrically and are renormalized to sum to 1.
    raw_shares = [0.6^(i - 1) for i in 1:num_sinks]
    shares = raw_shares ./ sum(raw_shares)
    total_capacity = sum(f.capacity for f in sc.maturation_sources)
    for (i, share) in enumerate(shares)
        sink = QuotaSink("slaughterhouse$i", Location(45.5 + rand(), -73.5 + rand()))
        add_product!(sink, product; quota=round(share * total_capacity / horizon),
                                    underproduction_unit_penalty=1.0, overproduction_unit_penalty=1.0)
        add_quota_sink!(sc, sink)
    end

    return sc
end

@testset "MatheuristicBenchmark" begin

@test begin
    num_farms, num_sinks, horizon = 200, 3, 63
    sc = _random_maturation_benchmark_instance(num_farms, num_sinks, horizon)

    direct_time_limit = 30.0
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
    SupplyChainOptimization.matheuristic_optimize!(m_heuristic; iterations=5, fix_fraction=0.85, time_limit_per_iteration=6.0)
    heuristic_elapsed = Dates.now() - heuristic_start
    heuristic_objective = has_values(m_heuristic) ? objective_value(m_heuristic) : Inf

    println("--- Matheuristic benchmark ($num_farms farms, $num_sinks sinks, $horizon-day horizon) ---")
    println("Direct solve:      objective=$direct_objective, gap=$direct_gap, time=$direct_elapsed (time_limit=$(direct_time_limit)s)")
    println("Matheuristic:       objective=$heuristic_objective, time=$heuristic_elapsed (5 iterations x 6s + initial solve)")
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
