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

    @test begin
        # maximum_units is a soft cap, like lost_sales is for demand: the
        # optimizer may store more than maximum_units, but pays
        # overflow_unit_cost per unit per period for the excess (see
        # `overflow` in src/Optimization.jl). A high enough overflow cost
        # makes exceeding capacity uneconomical in practice, which is what
        # we check here. add_product! did not expose maximum_units until
        # now, so this constraint (already present in the model) was
        # previously untestable/unreachable through the public API.
        horizon = 20

        sc = SupplyChain(horizon)

        product = Product("p1")
        add_product!(sc, product)

        customer = Customer("c1", Seattle)
        add_customer!(sc, customer)
        add_demand!(sc, customer, product, repeat([10.0], horizon))

        storage = Storage("s1", Seattle; initial_opened=true)
        add_storage!(sc, storage)
        add_product!(storage, product; unit_holding_cost=0.01, maximum_units=15.0, overflow_unit_cost=1000.0)

        supplier = Supplier("supplier1", Seattle)
        add_supplier!(sc, supplier)
        add_product!(supplier, product; unit_cost=1.0)

        lane = Lane(storage, customer; unit_cost=1.0)
        add_lane!(sc, lane)
        lane2 = Lane(supplier, storage; unit_cost=1.0)
        add_lane!(sc, lane2)

        SupplyChainOptimization.minimize_cost!(sc)

        all(get_overflow(sc, storage, product, t) == 0.0 for t in 1:horizon) &&
        all(get_inventory_at_end(sc, storage, product, t) <= 15.0 for t in 1:horizon)
    end

    @test begin
        # With overflow_unit_cost left at its default (0.0), maximum_units
        # is effectively a non-binding preference rather than an enforced
        # limit - exceeding it is free, so nothing stops the optimizer from
        # doing so if it's otherwise convenient. This documents that this is
        # intentional (mirrors lost_sales's cost-driven softness), not a bug.
        horizon = 5

        sc = SupplyChain(horizon)

        product = Product("p1")
        add_product!(sc, product)

        customer = Customer("c1", Seattle)
        add_customer!(sc, customer)
        add_demand!(sc, customer, product, repeat([100.0], horizon))

        storage = Storage("s1", Seattle; initial_opened=true)
        add_storage!(sc, storage)
        add_product!(storage, product; unit_holding_cost=0.01, maximum_units=1.0)

        supplier = Supplier("supplier1", Seattle)
        add_supplier!(sc, supplier)
        add_product!(supplier, product; unit_cost=1.0)

        lane = Lane(storage, customer; unit_cost=1.0)
        add_lane!(sc, lane)
        lane2 = Lane(supplier, storage; unit_cost=1.0, minimum_quantity=100.0)
        add_lane!(sc, lane2)

        SupplyChainOptimization.minimize_cost!(sc)

        # demand forces buying (and briefly storing) 100 units at a time via
        # the minimum_quantity lane, far more than maximum_units=1 allows;
        # with overflow free, the model has no reason to avoid it.
        any(get_overflow(sc, storage, product, t) > 0.0 for t in 1:horizon)
    end
end