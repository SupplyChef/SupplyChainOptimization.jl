using Base: product
using SupplyChainOptimization
#using Cbc
using JuMP
using Test

include("Models.jl")

include("Inventory.jl")
#include("UFLlib.jl")

include("UnitTests.jl")

@testset "Happy Path" begin
                              
@test !isnothing(create_model_storage_customer())

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.optimize_network!(sc)

    get_total_costs(sc) == 1100 &&
    get_total_fixed_costs(sc) == 1000 &&
    get_total_transportation_costs(sc) == 100
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.optimize_network!(sc)

    get_shipments(sc, first(sc.storages), first(sc.products)) == 100 &&
    is_opened(sc, first(sc.storages)) &&
    !is_opening(sc, first(sc.storages)) &&
    !is_closing(sc, first(sc.storages)) &&
    get_inventory_at_start(sc, first(sc.storages), first(sc.products), 1) == 100 &&
    get_inventory_at_end(sc, first(sc.storages), first(sc.products), 1) == 0
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.optimize_network!(sc)
    plot_costs(sc)
    true
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.optimize_network!(sc)
    plot_flows(sc)
    true
end

@test begin
    sc = create_model_storage_customer()
    SupplyChainOptimization.optimize_network!(sc)
    plot_network(sc)
    true
end

@test begin
    sc, product, supplier = create_model_supplier_storage_customer()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 1000 + 500 + 200 && 
    get_shipments(sc, supplier, product, 1) == 100
end

@test begin
    sc = create_model_plant_storage_customer()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 3400 && 
    get_production(sc, first(sc.plants), first(sc.products), 1) == 100
end

@test begin
    sc, product2, plant = create_test_model4()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 3400 && 
    get_production(sc, plant, product2, 1) == 100
end

@test begin
    sc, product2, plant = create_test_model5()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 1500 + 3000 + 600 + 200 && get_production(sc, plant, product2, 1)  == 200
end

@test begin
    sc = create_test_model7()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 10
end
end

@testset "Infeasible" begin
    @test  begin
        sc, product2, plant = create_test_infeasible_model()
        SupplyChainOptimization.optimize_network!(sc)
        status = termination_status(sc.optimization_model)
        #println(status)
        #println(value.(sc.optimization_model[:produced]))
        #println(value.(sc.optimization_model[:sent]))
        status == JuMP.INFEASIBLE
    end
end

@testset "Invalid" begin
    #@test_throws ArgumentError begin
    #    sc, product2, plant = create_test_broken_model()
    #    SupplyChainOptimization.optimize!(sc)
    #    status = termination_status(sc.optimization_model)
    #end
end

@testset "Scaling" begin
    @test begin
        sc, product2, plant = create_test_model6()
        SupplyChainOptimization.optimize_network!(sc)
        true
    end
end