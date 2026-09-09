@testset "Heuristics - warm start" begin

# A warm start only seeds the incumbent - on an instance small enough to solve to
# full optimality either way, the *final* reported objective must be identical
# with or without it.

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc; heuristic=:warm_start)
    get_total_costs(sc) == 1100
end

@test begin
    sc = create_model_plant_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc; heuristic=:warm_start)
    get_total_costs(sc) == 3410
end

@test begin
    sc, product2, plant = create_test_model5()
    SupplyChainOptimization.maximize_profits!(sc; heuristic=:warm_start)
    sc2, product2_2, plant2 = create_test_model5()
    SupplyChainOptimization.maximize_profits!(sc2)
    get_total_profits(sc) ≈ get_total_profits(sc2)
end

@test begin
    # warm_start_from_relaxation! itself, called directly on an already-built model
    # (rather than through the heuristic= kwarg), must produce a usable start value
    # without erroring, and without disturbing the objective once solved.
    sc = create_model_plant_storage_customer()
    SupplyChainOptimization.create_network_cost_minimization_model!(sc, HiGHS.Optimizer)
    JuMP.set_silent(sc.optimization_model)
    SupplyChainOptimization.warm_start_from_relaxation!(sc, :min_cost)
    JuMP.optimize!(sc.optimization_model)
    get_total_costs(sc) == 3410
end

end

@testset "Heuristics - relax and fix" begin

@test begin
    # A multi-period instance - relax-and-fix's rolling window only makes sense
    # (and only has more than one window to roll through) once horizon > 1.
    sc, product2, plant = create_test_model5()
    SupplyChainOptimization.maximize_profits!(sc; heuristic=:relax_and_fix, relax_and_fix_window_size=1)
    termination_status(sc.optimization_model) == JuMP.OPTIMAL
end

@test begin
    sc, product2, plant = create_test_model5()
    SupplyChainOptimization.maximize_profits!(sc; heuristic=:relax_and_fix, relax_and_fix_window_size=1)
    sc2, product2_2, plant2 = create_test_model5()
    SupplyChainOptimization.maximize_profits!(sc2)
    get_total_profits(sc) ≈ get_total_profits(sc2)
end

@test begin
    sc = create_model_plant_storage_customer(; horizon=4, customer_count=3)
    SupplyChainOptimization.minimize_cost!(sc; heuristic=:relax_and_fix, relax_and_fix_window_size=2)
    termination_status(sc.optimization_model) == JuMP.OPTIMAL
end

end

@testset "Heuristics - invalid" begin

@test_throws ArgumentError begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc; heuristic=:bogus)
end

end
