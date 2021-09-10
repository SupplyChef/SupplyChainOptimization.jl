using Base: product
using SupplyChainOptimization
#using Cbc
using JuMP
using MathOptInterface
using Test

include("UFLlib.jl")

Seattle = Location(47.608013, -122.335167)

include("UnitTests.jl")

function create_test_model()
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)

    c = Customer("c1", Seattle)
    add_customer!(sc, c)
    add_demand!(sc, c, product; demand=[100.0])
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
    add_storage!(sc, storage)
    add_product!(storage, product; initial_inventory=100)
    
    add_lane!(sc, Lane(storage, c; unit_cost=1.0))

    return sc
end

function create_test_model2()
    #supplier -> storage -> customer
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)

    c = Customer("c1", Seattle)
    add_customer!(sc, c)
    add_demand!(sc, c, product; demand=[100.0])
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_storage!(sc, storage)
    add_product!(storage, product)
    
    supplier = Supplier("supplier1", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=0.0, maximum_throughput=Inf)
    
    add_lane!(sc, Lane(storage, c; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, storage; unit_cost=1.0))

    return sc, product, supplier
end

function create_test_model3()
    #plant -> storage -> customer
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)
    
    customer = Customer("c1", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product; demand=[100.0])
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_storage!(sc, storage)
    add_product!(storage, product)
    
    plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_plant!(sc, plant)
    add_product!(plant, product; bill_of_material=Dict{Product, Float64}(), unit_cost=1, maximum_throughput=Inf)
    
    add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
    add_lane!(sc, Lane(plant, storage; unit_cost=1.0))

    return sc, product, plant
end

function create_test_model4()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain()

    product1 = add_product!(sc, Product("p1"))
    product2 = add_product!(sc, Product("p2"))

    supplier = Supplier("supplier1", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)
    
    customer = Customer("c1", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product2; demand=[100.0])
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_storage!(sc, storage)
    add_product!(storage, product2)
    
    plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_plant!(sc, plant)
    add_product!(plant, product2; bill_of_material=Dict{Product, Float64}(product1 => 1), unit_cost=1, maximum_throughput=Inf)
    
    add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
    add_lane!(sc, Lane(plant, storage; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, plant; unit_cost=1.0))

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
    add_demand!(sc, customer, product2; demand=[100.0, 100.0])
    storage = add_storage!(sc, Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false))
    add_product!(storage, product2)
    plant = add_plant!(sc, Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false))
    add_product!(plant, product2; bill_of_material=Dict{Product, Float64}(product1 => 1), unit_cost=1, maximum_throughput=Inf)
    add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
    add_lane!(sc, Lane(plant, storage; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, plant; unit_cost=1.0))

    return sc, product2, plant
end

function create_test_model6()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = Product("p1")
    product2 = Product("p2")
    add_product!(sc, product1)
    add_product!(sc, product2)

    supplier = Supplier("supplier1", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)

    plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_plant!(sc, plant)
    add_product!(plant, product2; bill_of_material=Dict{Product, Float64}(product1 => 1), unit_cost=1, maximum_throughput=Inf)
    add_lane!(sc, Lane(supplier, plant; unit_cost=1.0))

    for i in 1:500
        customer = Customer("c$i", Seattle)
        add_customer!(sc, customer)
        add_demand!(sc, customer, product2; demand=[100.0, 100.0])
    end 

    for i in 1:50
        storage = Storage("s$i", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
        add_storage!(sc, storage)
        add_product!(storage, product2)
        add_lane!(sc, Lane(plant, storage; unit_cost=1.0))
    end

    for customer in sc.customers, storage in sc.storages
        add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
    end

    return sc, product2, plant
end

function create_test_broken_model()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = Product("p1")
    product2 = Product("p2")
    add_product!(sc, product1)
    add_product!(sc, product2)

    supplier = Supplier("supplier1", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)

    customer = Customer("c1", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product2; demand=[100.0, 100.0])

    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_storage!(sc, storage)
    add_product!(storage, product2)
    plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_plant!(sc, plant)
    
    add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
    add_lane!(sc, Lane(plant, storage; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, plant; unit_cost=1.0))

    return sc, product2, plant
end

function create_test_infeasible_model()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product!(sc, Product("p1"))
    product2 = add_product!(sc, Product("p2"))

    supplier = Supplier("supplier1", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product1; unit_cost=0.0, maximum_throughput=Inf)
    
    customer = Customer("c1", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product2; demand=[100.0, 100.0])
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_storage!(sc, storage)
    add_product!(storage, product2)
    
    plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_plant!(sc, plant)
    
    add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
    add_lane!(sc, Lane(plant, storage; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, plant; unit_cost=1.0))

    return sc, product2, plant
end


@testset "Happy Path" begin
                              
@test !isnothing(create_test_model())

@test begin
    sc = create_test_model()
    SupplyChainOptimization.optimize_network!(sc)
    all(is_opened(sc, storage) for storage in sc.storages) == 1 &&
    get_total_costs(sc) == 1100 &&
    get_total_fixed_costs(sc) == 1000 &&
    get_total_transportation_costs(sc) == 100
end

@test begin
    sc = create_test_model()
    SupplyChainOptimization.optimize_network!(sc)
    plot_costs(sc)
    true
end

@test begin
    sc = create_test_model()
    SupplyChainOptimization.optimize_network!(sc)
    plot_flows(sc)
    true
end

@test begin
    sc = create_test_model()
    SupplyChainOptimization.optimize_network!(sc)
    plot_network(sc)
    true
end

@test begin
    sc, product, supplier = create_test_model2()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 1000 + 500 + 200 && value.(sc.optimization_model[:bought])[product, supplier, 1] == 100
end

@test begin
    sc, product, plant = create_test_model3()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 3300 && get_production(sc, plant, product, 1) == 100
end

@test begin
    sc, product2, plant = create_test_model4()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 3400 && get_production(sc, plant, product2, 1) == 100
end

@test begin
    sc, product2, plant = create_test_model5()
    SupplyChainOptimization.optimize_network!(sc)
    get_total_costs(sc) == 1500 + 3000 + 600 + 200 && get_production(sc, plant, product2, 1)  == 200
end
end

@testset "Infeasible" begin
    @test  begin
        sc, product2, plant = create_test_infeasible_model()
        SupplyChainOptimization.optimize_network!(sc)
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
        SupplyChainOptimization.optimize_network!(sc)
        true
    end
end