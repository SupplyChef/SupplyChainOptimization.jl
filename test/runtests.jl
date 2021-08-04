using Base: product
using SupplyChainOptimization
#using Cbc
import HiGHS
using JuMP
using MathOptInterface
using Test

Seattle = Location(47.608013, -122.335167)

function create_empty_model()
    sc = SupplyChain()

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m
end

function create_test_model()
    sc = SupplyChain()

    p = Product()
    add_product(sc, p)
    c = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(p => [100.0]), Seattle))
    s = add_storage(sc, Storage(1000, 0, 0, true, Dict{Product, Float64}(p => 100.0), Seattle))
    l = add_lane(sc, Lane(s, c, 1, 0))

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m
end

function create_test_model2()
    #supplier -> storage -> customer
    sc = SupplyChain()

    product = Product()
    add_product(sc, product)
    c = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(product => [100.0]), Seattle))
    storage = add_storage(sc, Storage(1000, 500, 500, false, Dict{Product, Float64}(product => 0.0), Seattle))
    supplier = add_supplier(sc, Supplier(Dict{Product, Float64}(product =>0.0), Seattle))
    l1 = add_lane(sc, Lane(storage, c, 1, 0))
    l2 = add_lane(sc, Lane(supplier, storage, 1, 0))

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m, product, supplier
end

function create_test_model3()
    #plant -> storage -> customer
    sc = SupplyChain()

    product = add_product(sc, Product())
    customer = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(product => [100.0]), Seattle))
    storage = add_storage(sc, Storage(1000, 500, 500, false, Dict{Product, Float64}(product => 0.0), Seattle))
    plant = add_production(sc, Production(1000, 500, 500, false, 
                                            Dict{Product, Dict{Product, Float64}}(product => Dict{Product, Float64}()),
                                            Dict{Product, Float64}(product => 1), Seattle))
    l1 = add_lane(sc, Lane(storage, customer, 1, 0))
    l2 = add_lane(sc, Lane(plant, storage, 1, 0))

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m, product, plant
end

function create_test_model4()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain()

    product1 = add_product(sc, Product())
    product2 = add_product(sc, Product())

    supplier = add_supplier(sc, Supplier(Dict{Product, Float64}(product1 =>0.0), Seattle))
    customer = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(product2 => [100.0]), Seattle))
    storage = add_storage(sc, Storage(1000, 500, 500, false, Dict{Product, Float64}(product2 => 0.0), Seattle))
    plant = add_production(sc, Production(1000, 500, 500, false, 
                                            Dict{Product, Dict{Product, Float64}}(product2 => Dict{Product, Float64}(product1 => 1)),
                                            Dict{Product, Float64}(product2 => 1), Seattle))
    l1 = add_lane(sc, Lane(storage, customer, 1, 0))
    l2 = add_lane(sc, Lane(plant, storage, 1, 0))
    l3 = add_lane(sc, Lane(supplier, plant, 1, 0))

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m, product2, plant
end

function create_test_model5()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product(sc, Product())
    product2 = add_product(sc, Product())

    supplier = add_supplier(sc, Supplier(Dict{Product, Float64}(product1 => 0.0), Seattle))
    customer = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(product2 => [100.0, 100.0]), Seattle))
    storage = add_storage(sc, Storage(1000, 500, 500, false, Dict{Product, Float64}(product2 => 0.0), Seattle))
    plant = add_production(sc, Production(1000, 500, 500, false, 
                                            Dict{Product, Dict{Product, Float64}}(product2 => Dict{Product, Float64}(product1 => 1)),
                                            Dict{Product, Float64}(product2 => 1), Seattle))
    l1 = add_lane(sc, Lane(storage, customer, 1, 0))
    l2 = add_lane(sc, Lane(plant, storage, 1, 0))
    l3 = add_lane(sc, Lane(supplier, plant, 1, 0))

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m, product2, plant
end

function create_test_model6()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product(sc, Product())
    product2 = add_product(sc, Product())

    supplier = add_supplier(sc, Supplier(Dict{Product, Float64}(product1 => 0.0), Seattle))

    plant = add_production(sc, Production(1000, 500, 500, false, 
                                            Dict{Product, Dict{Product, Float64}}(product2 => Dict{Product, Float64}(product1 => 1)),
                                            Dict{Product, Float64}(product2 => 1), Seattle))
    l3 = add_lane(sc, Lane(supplier, plant, 1))

    for i in 1:500
        customer = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(product2 => [100.0, 100.0]), Seattle))
    end 

    for i in 1:50
        storage = add_storage(sc, Storage(1000, 500, 500, false, Dict{Product, Float64}(product2 => 0.0), Seattle))
        l2 = add_lane(sc, Lane(plant, storage, 1))
    end

    for customer in sc.customers, storage in sc.storages
        l1 = add_lane(sc, Lane(storage, customer, 1))
    end

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m, product2, plant
end

function create_test_broken_model()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product(sc, Product())
    product2 = add_product(sc, Product())

    supplier = add_supplier(sc, Supplier(Dict{Product, Float64}(product1 => 0.0), Seattle))
    customer = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(product2 => [100.0, 100.0]), Seattle))
    storage = add_storage(sc, Storage(1000, 500, 500, false, Dict{Product, Float64}(product2 => 0.0), Seattle))
    plant = add_production(sc, Production(1000, 500, 500, false, 
                                            Dict{Product, Dict{Product, Float64}}(),
                                            #Dict{Product, Dict{Product, Float64}}(product2 => Dict{Product, Float64}(product1 => 1)),
                                            Dict{Product, Float64}(product2 => 1), Seattle))
    l1 = add_lane(sc, Lane(storage, customer, 1))
    l2 = add_lane(sc, Lane(plant, storage, 1))
    l3 = add_lane(sc, Lane(supplier, plant, 1))

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m, product2, plant
end


function create_test_infeasible_model()
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(2)

    product1 = add_product(sc, Product())
    product2 = add_product(sc, Product())

    supplier = add_supplier(sc, Supplier(Dict{Product, Float64}(product1 => 0.0), Seattle))
    customer = add_customer(sc, Customer(Dict{Product, Array{Float64, 1}}(product2 => [100.0, 100.0]), Seattle))
    storage = add_storage(sc, Storage(1000, 500, 500, false, Dict{Product, Float64}(product2 => 0.0), Seattle))
    plant = add_production(sc, Production(1000, 500, 500, false, 
                                            Dict{Product, Dict{Product, Float64}}(),
                                            Dict{Product, Float64}(), Seattle))
    l1 = add_lane(sc, Lane(storage, customer, 1))
    l2 = add_lane(sc, Lane(plant, storage, 1))
    l3 = add_lane(sc, Lane(supplier, plant, 1))

    m  = create_optimization_model(sc, HiGHS.Optimizer)

    return m, product2, plant
end


@testset "Happy Path" begin
@test add_lane(SupplyChain(), 
                         Lane(Customer(Dict{Product, Array{Float64, 1}}(), Seattle), 
                              Customer(Dict{Product, Array{Float64, 1}}(), Seattle), 
                              1.0,
                              0,
                              0)) isa Lane

@test !isnothing(create_empty_model())
                              
@test !isnothing(create_test_model())

@test begin
    m = create_test_model()
    optimize!(m)
    objective_value(m) == 1100
    true
end

@test begin
    m, product, supplier = create_test_model2()
    optimize!(m)
    #print(value.(m[:bought]))
    objective_value(m) == 1000 + 500 + 200 && value.(m[:bought])[product, supplier, 1] == 100
    true
end

@test begin
    m, product, plant = create_test_model3()
    optimize!(m)
    objective_value(m) == 3300 && value.(m[:produced])[product, plant, 1] == 100
end

@test begin
    m, product2, plant = create_test_model4()
    optimize!(m)
    objective_value(m) == 3400 && value.(m[:produced])[product2, plant, 1] == 100
end

@test begin
    m, product2, plant = create_test_model5()
    optimize!(m)
    #print(value.(m[:opening]))
    #print(value.(m[:closing]))
    #print(value.(m[:opened]))
    #print(value.(m[:sent]))
    objective_value(m) == 1500 + 3000 + 600 + 200 && value.(m[:produced])[product2, plant, 1] == 200
end
end

@testset "Infeasible" begin
    @test  begin
        m, product2, plant = create_test_infeasible_model()
        optimize!(m)
        status = termination_status(m)
        status == MathOptInterface.INFEASIBLE
    end
end

@testset "Invalid" begin
@test_throws ArgumentError begin
    m, product2, plant = create_test_broken_model()
    optimize!(m)
    status = termination_status(m)
end
end

@testset "Scaling" begin
@test begin
    m, product2, plant = create_test_model6()
    optimize!(m)
    true
end
end