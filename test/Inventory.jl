using Dates

"""
    eoq_quantity(demand_rate, ordering_cost, holding_cost_rate)

    Computes the economic ordering quantity that minimizes overall costs (ordering costs + holding costs) while meeting  demand.
"""
function eoq_quantity(demand_rate, ordering_cost, holding_cost_rate)
    return sqrt((2 * demand_rate * ordering_cost) / (holding_cost_rate))
end

"""
    eoq_quantity(demand_rate, ordering_cost, holding_cost_rate, backlog_cost_rate)

    Computes the economic ordering quantity that minimizes overall costs (ordering costs + holding costs) while meeting  demand.
"""
function eoq_quantity(demand_rate, ordering_cost, holding_cost_rate, backlog_cost_rate)
    return sqrt((2 * demand_rate * ordering_cost) / (holding_cost_rate) * (holding_cost_rate + backlog_cost_rate) / backlog_cost_rate)
end

@testset "Inventory" begin
    
    @test begin
        start = Dates.now()
        sc = create_model_plant_storage_customer(;horizon=400, product_unit_holding_cost = 0.1, lane_fixed_cost = 10_000, lane_can_ship = repeat([true, false, false, false], 100))

        product = first(sc.products)

        lane = first(filter(l -> isa(l.origin, Plant), sc.lanes))
        
        SupplyChainOptimization.minimize_cost!(sc)
    
        #println(value.(sc.optimization_model[:used]))
        println([get_shipments(sc, lane, product, t) for t in 1:100])
        println(eoq_quantity(100, 10_000, 0.1))
        println("$(start - Dates.now())")
        true
    end

    @test begin
        start = Dates.now()
        sc = create_model_plant_storage_customer(;horizon=40, customer_count=100)

        product = first(sc.products)

        SupplyChainOptimization.minimize_cost!(sc)
    
        #println(value.(sc.optimization_model[:used]))
        println("$(start - Dates.now())")
        true
    end

    @test begin
        start = Dates.now()

        horizon = 400
        #plant -> storage -> customer
        sc = SupplyChain(horizon)

        product = Product("p1")
        add_product!(sc, product)

        customer1 = Customer("c1", Seattle)
        add_customer!(sc, customer1)
        add_demand!(sc, customer1, product, repeat([100.0], horizon))

        customer2 = Customer("c2", Seattle)
        add_customer!(sc, customer2)
        add_demand!(sc, customer2, product, repeat([100.0], horizon))

        storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=Inf, initial_opened=false)
        add_storage!(sc, storage)
        add_product!(storage, product; unit_holding_cost=0.01)

        plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=Inf, initial_opened=false)
        add_plant!(sc, plant)
        add_product!(plant, product; bill_of_material=Dict{Product, Float64}(), unit_cost=1, maximum_throughput=Inf)

        lane = Lane(storage, [customer1, customer2]; unit_cost=1.0)
        add_lane!(sc, lane)
        lane2 = Lane(plant, storage; fixed_cost=0, unit_cost=1.0)
        add_lane!(sc, lane2)

        SupplyChainOptimization.minimize_cost!(sc)

        #println([get_shipments(sc, lane, customer1, product, t) for t in 1:horizon])
        #println([get_shipments(sc, lane, customer2, product, t) for t in 1:horizon]) 
        #println([get_shipments(sc, lane2, product, t) for t in 1:horizon])
    
        println("$(start - Dates.now())")
        [get_shipments(sc, lane, customer1, product, t) for t in 1:horizon] == repeat([100.0], horizon) &&
        [get_shipments(sc, lane, customer2, product, t) for t in 1:horizon] == repeat([100.0], horizon) && 
        [get_shipments(sc, lane2, product, t) for t in 1:horizon] == repeat([200.0], horizon)
    end

    @test begin
        start = Dates.now()

        horizon = 400
        #plant -> storage -> customer
        sc = SupplyChain(horizon)

        product = Product("p1")
        add_product!(sc, product)

        customer1 = Customer("c1", Seattle)
        add_customer!(sc, customer1)
        add_demand!(sc, customer1, product, repeat([100.0], horizon))

        customer2 = Customer("c2", Seattle)
        add_customer!(sc, customer2)
        add_demand!(sc, customer2, product, repeat([100.0], horizon))

        storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=Inf, initial_opened=false)
        add_storage!(sc, storage)
        add_product!(storage, product; unit_holding_cost=0.01)

        plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=Inf, initial_opened=false)
        add_plant!(sc, plant)
        add_product!(plant, product; bill_of_material=Dict{Product, Float64}(), unit_cost=1, maximum_throughput=Inf)

        lane = Lane(storage, [customer1, customer2]; unit_cost=1.0, initial_arrivals=Dict(product => repeat([[50, 50]], horizon)))
        add_lane!(sc, lane)
        lane2 = Lane(plant, storage; fixed_cost=0.0, unit_cost=1.0)
        add_lane!(sc, lane2)

        SupplyChainOptimization.minimize_cost!(sc)
    
        #println([get_shipments(sc, lane, customer1, product, t) for t in 1:horizon])
        #println([get_shipments(sc, lane, customer2, product, t) for t in 1:horizon]) 
        #println([get_shipments(sc, lane2, product, t) for t in 1:horizon])

        println("$(start - Dates.now())")
        [get_shipments(sc, lane, customer1, product, t) for t in 1:horizon] == repeat([50.0], horizon) &&
        [get_shipments(sc, lane, customer2, product, t) for t in 1:horizon] == repeat([50.0], horizon) 
        [get_shipments(sc, lane2, product, t) for t in 1:horizon] == repeat([100.0], horizon)
    end
end