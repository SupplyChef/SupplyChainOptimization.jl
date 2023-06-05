
using HiGHS
using JuMP
using SupplyChainOptimization

@test begin
    Seattle = Location(47.608013, -122.335167)

    sc = SupplyChain(26)

    ordering_cost = 100

    product = Product("Product 1"; unit_holding_cost=0.01)
    add_product!(sc, product)

    supplier = Supplier("Supplier 1", Seattle)
    add_product!(supplier, product; unit_cost=0.0)
    add_supplier!(sc, supplier)

    storage = Storage("Storage 1", Seattle; 
                fixed_cost= 0, 
                initial_opened=true)
    add_product!(storage, product; additional_stock_cover=0, initial_inventory=nothing)
    add_storage!(sc, storage)

    customer = Customer("Customer 1", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product; demand=[100.0 for i in 1:sc.horizon])

    lane = Lane(supplier, storage; minimum_quantity=1.0)
    add_lane!(sc, lane)
    add_lane!(sc, Lane(storage, customer; minimum_quantity=1.0))

    SupplyChainOptimization.create_network_optimization_model!(sc, HiGHS.Optimizer)
    @objective(sc.optimization_model, Min, sum(sc.optimization_model[:used][lane, t] * ordering_cost for t in 1:sc.horizon) +
                                        sum(sc.optimization_model[:stored_at_end][product, storage, t-1] * product.unit_holding_cost for t in 1:sc.horizon) )
    SupplyChainOptimization.optimize_network_optimization_model!(sc)

    println(objective_value(sc.optimization_model))
    objective_value(sc.optimization_model) ≈ 355.9999999999983
end

@test begin
    Seattle = Location(47.608013, -122.335167)

    sc = SupplyChain(26)

    ordering_cost = 100

    product = Product("Product 1"; unit_holding_cost=0.01)
    add_product!(sc, product)

    supplier = Supplier("Supplier 1", Seattle)
    add_product!(supplier, product; unit_cost=0.0)
    add_supplier!(sc, supplier)

    storage = Storage("Storage 1", Seattle; 
                fixed_cost= 0, 
                initial_opened=true)
    add_product!(storage, product; additional_stock_cover=0, initial_inventory=nothing)
    add_storage!(sc, storage)

    customer = Customer("Customer 1", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product; demand=[100.0 for i in 1:sc.horizon])

    lane = Lane(supplier, storage; minimum_quantity=1.0, fixed_cost=ordering_cost)
    add_lane!(sc, lane)
    add_lane!(sc, Lane(storage, customer; minimum_quantity=1.0))

    SupplyChainOptimization.optimize_network!(sc)
    println(objective_value(sc.optimization_model))

    plot_inventory(sc, storage, product)
    objective_value(sc.optimization_model) ≈ 355.9999999999983
end