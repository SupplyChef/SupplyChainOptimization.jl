using HiGHS

@testset "Matheuristics" begin

# A tiny 0/1 knapsack with a hand-verified optimum: values [10,6,4,3,1], weights [6,5,4,3,1],
# capacity 10. Best subset by exhaustive check is {item 1, item 3} (weight 6+4=10, value
# 10+4=14) - HiGHS solves this to proven optimality on its own single solve already, so this
# mainly checks that matheuristic_optimize! does not *regress* an already-optimal solution, and
# that it correctly restores bounds afterward (item 5's variable is deliberately given only a
# lower bound, matching how q_plus/q_minus are declared in MaturationScheduling.jl, to exercise
# the "originally unbounded above" restore path).
function build_knapsack()
    values = [10.0, 6.0, 4.0, 3.0, 1.0]
    weights = [6.0, 5.0, 4.0, 3.0, 1.0]
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, x[1:4], Bin)
    @variable(m, x5 >= 0, Int)
    set_upper_bound(x5, 1)
    @constraint(m, sum(weights[i] * x[i] for i in 1:4) + weights[5] * x5 <= 10)
    @objective(m, Max, sum(values[i] * x[i] for i in 1:4) + values[5] * x5)
    return m, x5
end

@test begin
    m, x5 = build_knapsack()
    JuMP.optimize!(m)

    has_upper_before = has_upper_bound(x5)  # true: manually set above, unlike q_plus/q_minus's own declarations

    SupplyChainOptimization.matheuristic_optimize!(m; iterations=5, fix_fraction=0.5)

    objective_value(m) ≈ 14.0 && has_upper_bound(x5) == has_upper_before
end

@test begin
    m, x5 = build_knapsack()
    JuMP.optimize!(m)
    SupplyChainOptimization.matheuristic_optimize!(m; iterations=5, neighborhood=:local_branching, local_branching_k=2)
    objective_value(m) ≈ 14.0
end

# The lower-bound-only variable (matching q_plus/q_minus's own `>= 0, Int` declaration, no
# explicit upper bound) must come back with no upper bound after matheuristic_optimize! - not
# stuck at whatever value pinning last set it to.
@test begin
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, y >= 0, Int)
    @constraint(m, y <= 7.4)
    @objective(m, Max, y)
    JuMP.optimize!(m)

    SupplyChainOptimization.matheuristic_optimize!(m; iterations=3)

    value(y) ≈ 7.0 && !has_upper_bound(y) && has_lower_bound(y) && lower_bound(y) == 0.0
end

@test_throws ArgumentError begin
    m, _ = build_knapsack()
    JuMP.optimize!(m)
    SupplyChainOptimization.matheuristic_optimize!(m; neighborhood=:bogus)
end

@test_throws ArgumentError begin
    m, _ = build_knapsack()
    JuMP.optimize!(m)
    SupplyChainOptimization.matheuristic_optimize!(m; fix_fraction=1.5)
end

# A pure LP (no integer/binary variables at all) has no neighborhood to explore - the model
# should come back unchanged rather than erroring.
@test begin
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, 0 <= z <= 5)
    @objective(m, Max, z)
    JuMP.optimize!(m)

    SupplyChainOptimization.matheuristic_optimize!(m; iterations=3)
    objective_value(m) ≈ 5.0
end

# Smoke tests against this package's own model types - matheuristic_optimize! must not make
# either model type's solution worse than the direct solve found on its own.
@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    direct_cost = get_total_costs(sc)

    SupplyChainOptimization.matheuristic_optimize!(sc.optimization_model; iterations=3)

    objective_value(sc.optimization_model) <= direct_cost + 1e-6
end

@test begin
    sc = SupplyChain(20)
    product = Product("batch")
    add_product!(sc, product)

    source = MaturationSource("s1", Location(0.0, 0.0); capacity=100)
    add_product!(source, product; initial_value=0.0, maturation_rate=10.0, target_value=100.0,
                                  acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                                  extended_deviation_under=0.1, extended_deviation_over=0.1)
    add_maturation_source!(sc, source)

    sink = QuotaSink("k1", Location(0.0, 0.0))
    add_product!(sink, product; quota=100.0, underproduction_unit_penalty=5.0, overproduction_unit_penalty=5.0)
    add_quota_sink!(sc, sink)

    m = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=1.0,
                                           distance=(a, b) -> 1.0, is_delivery_day=t -> t == 10)
    JuMP.optimize!(m)
    direct_objective = objective_value(m)

    SupplyChainOptimization.matheuristic_optimize!(m; iterations=3)

    objective_value(m) <= direct_objective + 1e-6
end

end