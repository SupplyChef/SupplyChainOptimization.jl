@testset "Progress callback" begin
    # HiGHS's MIP logging cadence is internal/timing-based - a fast solve
    # isn't guaranteed to trigger even one callback, so this doesn't assert
    # `calls` is nonempty, only that a callback being registered doesn't
    # change/break a normal solve, and that any calls that did happen carry
    # sane values (all(f, []) is vacuously true, so this passes either way).
    #
    # node_count/running_time are checked for non-negativity, but NOT
    # primal_bound/dual_bound for finiteness - HiGHS legitimately reports
    # these as +-Inf on early callbacks, before a first incumbent is found
    # or a first dual bound is proven. That's correct HiGHS behavior passed
    # through unmodified by _register_progress_callback! (a pure passthrough
    # of data_out's fields), not something to assert against.
    sc = create_model_plant_storage_customer(;horizon=40, customer_count=100)
    calls = Any[]
    SupplyChainOptimization.maximize_profits!(sc; progress_callback = (node_count, primal, dual, gap, running_time) ->
        push!(calls, (node_count, primal, dual, gap, running_time)))
    @test all(c -> c[1] >= 0, calls)
    @test all(c -> c[5] >= 0, calls)

    @test begin
        # An exception inside progress_callback must never break the solve -
        # HiGHS's C callback boundary can't safely propagate a Julia
        # exception through it, so _register_progress_callback! catches and
        # logs instead. Uses the same larger model as above to give this a
        # real chance of actually firing the callback (and hitting the
        # exception) during the solve, not just structurally asserting it.
        sc = create_model_plant_storage_customer(;horizon=40, customer_count=100)
        SupplyChainOptimization.maximize_profits!(sc; progress_callback = (args...) -> error("boom"))
        termination_status(sc.optimization_model) in (JuMP.OPTIMAL, JuMP.TIME_LIMIT)
    end

    @test begin
        # progress_callback is a no-op for a non-HiGHS optimizer path - this
        # repo doesn't exercise one directly, but service_level=0 model with
        # optimizer left at its HiGHS default plus an explicit no-solver
        # check inside _register_progress_callback! covers the real risk
        # here (JuMP.solver_name erroring or misidentifying HiGHS).
        sc = create_model_storage_customer()
        SupplyChainOptimization.minimize_cost!(sc; progress_callback = (args...) -> nothing)
        termination_status(sc.optimization_model) == JuMP.OPTIMAL
    end
end
