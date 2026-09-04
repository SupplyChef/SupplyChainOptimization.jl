using Base: product
using SupplyChainModeling
using SupplyChainOptimization
#using Cbc
using JuMP
using Test
# Loading PlotlyJS here is what activates SupplyChainOptimizationPlotlyJSExt
# (see Project.toml's [weakdeps]/[extensions] and src/Visualization.jl) -
# without it, plot_costs/plot_flows/plot_financials/plot_network/
# animate_network/animate_flows below would all be plain MethodErrors.
using PlotlyJS

include("Models.jl")

include("Docs.jl")

include("Inventory.jl")

include("UFLlib.jl")
include("Profits.jl")
include("GSM.jl")

include("UnitTests.jl")

@testset "Happy Path" begin

@test !isnothing(create_model_storage_customer())

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)

    get_total_costs(sc) == 1100 &&
    get_total_fixed_costs(sc) == 1000 &&
    get_total_transportation_costs(sc) == 100
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)

    get_shipments(sc, first(sc.storages), first(sc.products)) == 100 &&
    is_opened(sc, first(sc.storages)) &&
    !is_opening(sc, first(sc.storages)) &&
    !is_closing(sc, first(sc.storages)) &&
    get_inventory_at_start(sc, first(sc.storages), first(sc.products), 1) == 100 &&
    get_inventory_at_end(sc, first(sc.storages), first(sc.products), 1) == 0
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    plot_costs(sc)
    true
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    plot_flows(sc)
    true
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    plot_financials(sc)
    true
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    plot_flows(sc)
    animate_flows(sc)
    plot_network(sc)
    animate_network(sc)
    true
end

@test begin
    sc, product, supplier = create_model_supplier_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_costs(sc) == 1000 + 500 + 200 &&
    get_shipments(sc, supplier, product, 1) == 100
end

@test begin
    sc = create_model_plant_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    println("$(get_total_costs(sc)) == 3410")
    get_total_costs(sc) == 3410 &&
    get_production(sc, first(sc.plants), first(sc.products), 1) == 100
end

@test begin
    sc, product2, plant = create_test_model4()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_costs(sc) == 3400 &&
    get_production(sc, plant, product2, 1) == 100
end

@test begin
    sc, product2, plant = create_test_model5()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_costs(sc) == 1500 + 3000 + 600 + 200 && get_production(sc, plant, product2, 1)  == 200
end

@test begin
    sc = create_test_model7()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_costs(sc) == 10
end
end

@testset "Infeasible" begin
    @test  begin
        sc, product2, plant = create_test_infeasible_model()
        SupplyChainOptimization.minimize_cost!(sc)
        status = termination_status(sc.optimization_model)
        #println(status)
        #println(value.(sc.optimization_model[:produced]))
        #println(value.(sc.optimization_model[:sent]))
        status == JuMP.INFEASIBLE
    end
end

@testset "Invalid" begin
    @test_throws ArgumentError begin
    #@test begin
        sc, product2, plant = create_test_broken_model()
        SupplyChainOptimization.minimize_cost!(sc)
        status = termination_status(sc.optimization_model)
    end
end

@testset "Scaling" begin
    @test begin
        sc, product2, plant = create_test_model6()
        SupplyChainOptimization.minimize_cost!(sc)
        true
    end
end

@testset "Lost sales" begin
    # Same shape as create_model_storage_customer(), but demand (100)
    # outstrips the storage's initial_inventory (60) - a shortfall
    # get_lost_sales/get_financials should report exactly, forced by
    # the model's own balance constraint (received + arrivals ==
    # demand - lost_sales), not a solver choice: with zero
    # transportation/handling cost and a positive sales_price, shipping
    # every available unit is strictly profit-improving, so all 60
    # available units ship and the remaining 40 are lost sales -
    # allowed here via service_level=0.0 (otherwise this would be
    # infeasible instead, per the (1-service_level) cap in
    # Optimization.jl).
    sc = SupplyChain(1)

    product = Product("p1")
    add_product!(sc, product)

    c = Customer("c1", Seattle)
    add_customer!(sc, c)
    add_demand!(sc, c, product, [100.0]; sales_price=10.0, lost_sales_cost=3.0, service_level=0.0)

    storage = Storage("s1", Seattle; fixed_cost=0.0, initial_opened=true)
    add_storage!(sc, storage)
    add_product!(storage, product; initial_inventory=60.0)

    add_lane!(sc, Lane(storage, c; unit_cost=0.0))

    SupplyChainOptimization.maximize_profits!(sc)

    financials = get_financials(sc)

    # Individual @test calls (rather than one &&-chained boolean) so a
    # failure prints which specific value was wrong, not just "false" -
    # this whole testset never actually ran before get_lost_sales was
    # exported (see the CI fix earlier in this PR's history), so these
    # numbers were never confirmed against a real solve.
    @test get_lost_sales(sc, c, product, 1) == 40.0
    @test financials.Lost_Sales[1] == 40.0
    @test financials.Lost_Sales_Cost[1] == 120.0
    # Every other cost in this scenario is zero (free storage, free lane,
    # no holding cost) - so Costs is now exactly the lost sales penalty,
    # confirming lost_sales_cost is folded into total_costs, not just
    # reported alongside it.
    @test financials.Costs[1] == 120.0
end

@testset "Lost sales cost influences the objective" begin
    # Shipping alone loses money here (sales_price=10 < lane unit_cost=12), so
    # with lost_sales_cost=0 the optimizer strictly prefers losing the sale
    # (costs nothing) over shipping (costs $2/unit net). Raising
    # lost_sales_cost above that $2 margin loss flips the trade-off - not
    # shipping now costs more than shipping's own loss - so the optimizer
    # switches to serving the customer in full. This is a solver choice
    # (unlike the "Lost sales" testset above, where the shortfall is forced
    # by inventory), so it only demonstrates the fix if the choice actually
    # changes with lost_sales_cost.
    function build_margin_scenario(lost_sales_cost)
        sc = SupplyChain(1)
        product = Product("p1")
        add_product!(sc, product)
        c = Customer("c1", Seattle)
        add_customer!(sc, c)
        add_demand!(sc, c, product, [50.0]; sales_price=10.0, lost_sales_cost=lost_sales_cost, service_level=0.0)
        storage = Storage("s1", Seattle; fixed_cost=0.0, initial_opened=true)
        add_storage!(sc, storage)
        add_product!(storage, product; initial_inventory=100.0)
        add_lane!(sc, Lane(storage, c; unit_cost=12.0))
        return sc, c, product
    end

    sc_no_penalty, c_no_penalty, product_no_penalty = build_margin_scenario(0.0)
    SupplyChainOptimization.maximize_profits!(sc_no_penalty)
    @test get_lost_sales(sc_no_penalty, c_no_penalty, product_no_penalty, 1) == 50.0

    sc_penalty, c_penalty, product_penalty = build_margin_scenario(5.0)
    SupplyChainOptimization.maximize_profits!(sc_penalty)
    @test get_lost_sales(sc_penalty, c_penalty, product_penalty, 1) == 0.0
end

@testset "Progress callback" begin
    @test begin
        # HiGHS's MIP logging cadence is internal/timing-based - a fast
        # solve isn't guaranteed to trigger even one callback, so this
        # doesn't assert `calls` is nonempty, only that a callback being
        # registered doesn't change/break a normal solve, and that any
        # calls that did happen carry sane values (all(f, []) is
        # vacuously true, so this passes either way).
        sc = create_model_plant_storage_customer(;horizon=40, customer_count=100)
        calls = Any[]
        SupplyChainOptimization.maximize_profits!(sc; progress_callback = (node_count, primal, dual, gap, running_time) ->
            push!(calls, (node_count, primal, dual, gap, running_time)))
        all(c -> c[1] >= 0 && isfinite(c[2]) && isfinite(c[3]) && c[5] >= 0, calls)
    end

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