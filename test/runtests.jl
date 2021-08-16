using Base: product
using SupplyChainOptimization
#using Cbc
using JuMP
using MathOptInterface
using Test

include("UFLlib.jl")

Seattle = Location(47.608013, -122.335167)

function create_empty_model()
    sc = SupplyChain()

    return sc
end

function create_test_model()
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)
    c = add_customer!(sc, Customer("c1", Seattle))
    add_product!(c, product; demand=[100.0])
    storage = add_storage!(sc, Storage("s1", 1000.0, 0.0, 0.0, true, Seattle))
    add_product!(storage, product; initial_inventory=100, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
    l = add_lane!(sc, Lane(storage, c, 1, 0))

    return sc
end

function create_test_model2()
    #supplier -> storage -> customer
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)
    c = add_customer!(sc, Customer("c1", Seattle))
    add_product!(c, product; demand=[100.0])
    storage = add_storage!(sc, Storage("s1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(storage, product; initial_inventory=0, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
    supplier = add_supplier!(sc, Supplier("supplier1", Seattle))
    add_product!(supplier, product; unit_cost=0.0, maximum_throughput=Inf)
    l1 = add_lane!(sc, Lane(storage, c, 1, 0))
    l2 = add_lane!(sc, Lane(supplier, storage, 1, 0))

    return sc, product, supplier
end

function create_test_model3()
    #plant -> storage -> customer
    sc = SupplyChain()

    product = add_product!(sc, Product("p1"))
    customer = add_customer!(sc, Customer("c1", Seattle))
    add_product!(customer, product; demand=[100.0])
    storage = add_storage!(sc, Storage("s1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(storage, product; initial_inventory=0, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
    plant = add_plant!(sc, Plant("plant1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(plant, product; bill_of_material=Dict{Product, Float64}(), unit_cost=1, maximum_throughput=Inf)
    l1 = add_lane!(sc, Lane(storage, customer, 1, 0))
    l2 = add_lane!(sc, Lane(plant, storage, 1, 0))

    return sc, product, plant
end

function create_test_model4()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain()

    product1 = add_product!(sc, Product("p1"))
    product2 = add_product!(sc, Product("p2"))

    supplier = add_supplier!(sc, Supplier("supplier1", Seattle))
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)
    customer = add_customer!(sc, Customer("c1", Seattle))
    add_product!(customer, product2; demand=[100.0])
    storage = add_storage!(sc, Storage("s1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(storage, product2; initial_inventory=0, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
    plant = add_plant!(sc, Plant("plant1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(plant, product2; bill_of_material=Dict{Product, Float64}(product1 => 1), unit_cost=1, maximum_throughput=Inf)
    l1 = add_lane!(sc, Lane(storage, customer, 1, 0))
    l2 = add_lane!(sc, Lane(plant, storage, 1, 0))
    l3 = add_lane!(sc, Lane(supplier, plant, 1, 0))

    return sc, product2, plant
end

function create_test_model5()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product!(sc, Product("p1"))
    product2 = add_product!(sc, Product("p2"))

    supplier = add_supplier!(sc, Supplier("supplier1", Seattle))
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)
    customer = add_customer!(sc, Customer("c1", Seattle))
    add_product!(customer, product2; demand=[100.0, 100.0])
    storage = add_storage!(sc, Storage("s1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(storage, product2; initial_inventory=0, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
    plant = add_plant!(sc, Plant("plant1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(plant, product2; bill_of_material=Dict{Product, Float64}(product1 => 1), unit_cost=1, maximum_throughput=Inf)
    l1 = add_lane!(sc, Lane(storage, customer, 1, 0))
    l2 = add_lane!(sc, Lane(plant, storage, 1, 0))
    l3 = add_lane!(sc, Lane(supplier, plant, 1, 0))

    return sc, product2, plant
end

function create_test_model6()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product!(sc, Product("p1"))
    product2 = add_product!(sc, Product("p2"))

    supplier = add_supplier!(sc, Supplier("supplier1", Seattle))
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)

    plant = add_plant!(sc, Plant("plant1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(plant, product2; bill_of_material=Dict{Product, Float64}(product1 => 1), unit_cost=1, maximum_throughput=Inf)
    l3 = add_lane!(sc, Lane(supplier, plant, 1))

    for i in 1:500
        customer = add_customer!(sc, Customer("c$i", Seattle))
        add_product!(customer, product2; demand=[100.0, 100.0])
    end 

    for i in 1:50
        storage = add_storage!(sc, Storage("s$i", 1000.0, 500.0, 500.0, false, Seattle))
        add_product!(storage, product2; initial_inventory=0, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
        l2 = add_lane!(sc, Lane(plant, storage, 1))
    end

    for customer in sc.customers, storage in sc.storages
        l1 = add_lane!(sc, Lane(storage, customer, 1))
    end

    return sc, product2, plant
end

function create_test_broken_model()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product!(sc, Product("p1"))
    product2 = add_product!(sc, Product("p2"))

    supplier = add_supplier!(sc, Supplier("supplier1", Seattle))
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)
    customer = add_customer!(sc, Customer("c1", Seattle))
    add_product!(customer, product2; demand=[100.0, 100.0])
    storage = add_storage!(sc, Storage("s1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(storage, product2; initial_inventory=0, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
    plant = add_plant!(sc, Plant("plant1", 1000.0, 500.0, 500.0, false, Seattle))
    l1 = add_lane!(sc, Lane(storage, customer, 1))
    l2 = add_lane!(sc, Lane(plant, storage, 1))
    l3 = add_lane!(sc, Lane(supplier, plant, 1))

    return sc, product2, plant
end

function create_test_infeasible_model()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product!(sc, Product("p1"))
    product2 = add_product!(sc, Product("p2"))

    supplier = add_supplier!(sc, Supplier("supplier1", Seattle))
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)
    customer = add_customer!(sc, Customer("c1", Seattle))
    add_product!(customer, product2; demand=[100.0, 100.0])
    storage = add_storage!(sc, Storage("s1", 1000.0, 500.0, 500.0, false, Seattle))
    add_product!(storage, product2; initial_inventory=0, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
    plant = add_plant!(sc, Plant("plant1", 1000.0, 500.0, 500.0, false, Seattle))
    l1 = add_lane!(sc, Lane(storage, customer, 1))
    l2 = add_lane!(sc, Lane(plant, storage, 1))
    l3 = add_lane!(sc, Lane(supplier, plant, 1))

    return sc, product2, plant
end


@testset "Happy Path" begin
@test haversine(0, 0, 0, 0) == 0

@test haversine(51.510357, -0.116773, 38.889931, -77.009003) ≈ 5897658.289

@test add_lane!(SupplyChain(), 
                         Lane(Customer("c1", Seattle), 
                              Customer("c2", Seattle), 
                              1.0,
                              0,
                              0)) isa Lane

@test !isnothing(create_empty_model())
                              
@test !isnothing(create_test_model())

@test begin
    sc = create_test_model()
    SupplyChainOptimization.optimize!(sc)
    get_total_costs(sc) == 1100
    true
end

@test begin
    sc, product, supplier = create_test_model2()
    SupplyChainOptimization.optimize!(sc)
    #print(value.(m[:bought]))
    get_total_costs(sc) == 1000 + 500 + 200 && value.(sc.optimization_model[:bought])[product, supplier, 1] == 100
    true
end

@test begin
    sc, product, plant = create_test_model3()
    SupplyChainOptimization.optimize!(sc)
    get_total_costs(sc) == 3300 && get_production(sc, plant, product, 1) == 100
end

@test begin
    sc, product2, plant = create_test_model4()
    SupplyChainOptimization.optimize!(sc)
    get_total_costs(sc) == 3400 && get_production(sc, plant, product2, 1) == 100
end

@test begin
    sc, product2, plant = create_test_model5()
    SupplyChainOptimization.optimize!(sc)
    #print(value.(m[:opening]))
    #print(value.(m[:closing]))
    #print(value.(m[:opened]))
    #print(value.(m[:sent]))
    get_total_costs(sc) == 1500 + 3000 + 600 + 200 && get_production(sc, plant, product2, 1)  == 200
end
end

@testset "Infeasible" begin
    @test  begin
        sc, product2, plant = create_test_infeasible_model()
        SupplyChainOptimization.optimize!(sc)
        status = termination_status(sc.optimization_model)
        status == MathOptInterface.INFEASIBLE
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
    SupplyChainOptimization.optimize!(sc)
    true
end
end