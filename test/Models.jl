
Seattle = Location(47.608013, -122.335167)

function create_model_storage_customer()
    #storage -> customer
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)

    c = Customer("c1", Seattle)
    add_customer!(sc, c)
    add_demand!(sc, c, product; demand=[100.0])
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=10.0, closing_cost=10.0, initial_opened=true)
    add_storage!(sc, storage)
    add_product!(storage, product; initial_inventory=100)
    
    add_lane!(sc, Lane(storage, c; unit_cost=1.0))

    return sc
end

function create_model_supplier_storage_customer()
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

function create_model_plant_storage_customer(;horizon=1, customer_count=1, product_unit_holding_cost=0.0, lane_fixed_cost = 100.0, lane_can_ship = nothing)
    #plant -> storage -> customer
    sc = SupplyChain(horizon)

    product = Product("p1"; unit_holding_cost=product_unit_holding_cost)
    add_product!(sc, product)
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=Inf, initial_opened=false)
    add_storage!(sc, storage)
    add_product!(storage, product)
    
    plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=Inf, initial_opened=false)
    add_plant!(sc, plant)
    add_product!(plant, product; bill_of_material=Dict{Product, Float64}(), unit_cost=1, maximum_throughput=Inf)

    for i in 1:customer_count
        customer = Customer("c$i", Seattle)
        add_customer!(sc, customer)
        add_demand!(sc, customer, product; demand=repeat([100.0], horizon))
        add_lane!(sc, Lane(storage, customer; fixed_cost=10.0, unit_cost=1.0))
    end
    
    add_lane!(sc, Lane(plant, storage; unit_cost=1.0, fixed_cost=lane_fixed_cost, can_ship=lane_can_ship))

    return sc
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

function create_test_model6(; horizon=2, customer_count=500, storage_count=50)
    #supplier -> plant -> storage -> customer
    sc = SupplyChain(horizon)

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

    for i in 1:customer_count
        customer = Customer("c$i", Seattle)
        add_customer!(sc, customer)
        add_demand!(sc, customer, product2; demand=repeat([100.0], horizon))
    end 

    for i in 1:storage_count
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

function create_test_model7()
    #storage -> customer
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)

    c = Customer("c1", Seattle)
    add_customer!(sc, c)
    add_demand!(sc, c, product; demand=[100.0], service_level=0.0)
    
    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=10.0, closing_cost=10.0, initial_opened=true)
    add_storage!(sc, storage)
    add_product!(storage, product; initial_inventory=100)
    
    add_lane!(sc, Lane(storage, c; unit_cost=1.0))

    return sc
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
    #add_demand!(sc, customer, product2; demand=[100.0, 100.0])

    storage = Storage("s1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_storage!(sc, storage)
    add_product!(storage, product2)
    plant = Plant("plant1", Seattle; fixed_cost=1000.0, opening_cost=500.0, closing_cost=500.0, initial_opened=false)
    add_product!(plant, product2; bill_of_material=Dict(product1 => 1.0))
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
    #add_product!(plant, product2; bill_of_material=Dict(product1 => 1.0))
    add_plant!(sc, plant)
    
    add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
    add_lane!(sc, Lane(plant, storage; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, plant; unit_cost=1.0))

    return sc, product2, plant
end
