"""
    get_total_costs(supply_chain::SupplyChain)

Gets the total costs of operating the supply chain.
"""
function get_total_costs(supply_chain::SupplyChain)
    check(supply_chain)
    return value(supply_chain.optimization_model[:total_costs])
end

"""
    get_total_profits(supply_chain::SupplyChain)

Gets the total profits of operating the supply chain.
"""
function get_total_profits(supply_chain::SupplyChain)
    check(supply_chain)
    return value(supply_chain.optimization_model[:total_profits])
end

"""
    get_total_fixed_costs(supply_chain::SupplyChain)

Gets the total fixed costs of operating the supply chain.
"""
function get_total_fixed_costs(supply_chain::SupplyChain)
    check(supply_chain)
    return value(supply_chain.optimization_model[:total_fixed_costs])
end

"""
    get_total_transportation_costs(supply_chain::SupplyChain)

Gets the total transportation costs of operating the supply chain.
"""
function get_total_transportation_costs(supply_chain::SupplyChain)
    check(supply_chain)
    return value(supply_chain.optimization_model[:total_transportation_costs])
end

"""
    get_production(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)

Gets the amount of a given product produced at a given plant during a given period.
"""
function get_production(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:produced][product, plant, period])
end

"""
    get_receipts(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)

Gets the amount of a given product received at a given storage location at a given period.
"""
function get_receipts(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:received][product, storage, period])
end

"""
    get_shipments(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)

Gets the amount of a given product sent from a given storage location at a given period.
"""
function get_shipments(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)
    check(supply_chain)
    return sum(value(supply_chain.optimization_model[:sent][product, l, period]) for l in get_lanes_out(supply_chain, storage))
end

"""
    get_shipments(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)

Gets the amount of a given product sent from a given plant  at a given period.
"""
function get_shipments(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)
    check(supply_chain)
    return sum(value(supply_chain.optimization_model[:sent][product, l, period]) for l in get_lanes_out(supply_chain, plant))
end

"""
    get_shipments(supply_chain::SupplyChain, supplier::Supplier, product::Product, period=1)

Gets the amount of a given product shipped from a given supplier at a given period.
"""
function get_shipments(supply_chain::SupplyChain, supplier::Supplier, product::Product, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:bought][product, supplier, period])
end

"""
    get_shipments(supply_chain::SupplyChain, lane::Lane, product::Product, period=1)

Gets the amount of a given product sent on a lane at a given period.
"""
function get_shipments(supply_chain::SupplyChain, lane::Lane, product::Product, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:sent][product, lane, period])
end

"""
    get_shipments(supply_chain::SupplyChain, lane::Lane, destination, product::Product, period=1)

Gets the amount of a given product sent on a lane at a given period.
"""
function get_shipments(supply_chain::SupplyChain, lane::Lane, destination, product::Product, period=1)
    check(supply_chain)
    index = findfirst(d -> d == destination, lane.destinations)
    if isnothing(index) || period + lane.times[index] > supply_chain.horizon
        return 0
    end
    return value(supply_chain.optimization_model[:received][product, lane, destination, period + lane.times[index]])
end

"""
    is_opened(supply_chain::SupplyChain, storage::Storage, period=1)

Gets whether a given storage location is opened during a given period.
"""
function is_opened(supply_chain::SupplyChain, storage::Storage, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:opened][storage, period]) ≈ 1.0
end

"""
    is_opened(supply_chain::SupplyChain, plant::Plant, period=1)

Gets whether a given plant is opened during a given period.
"""
function is_opened(supply_chain::SupplyChain, plant::Plant, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:opened][plant, period]) ≈ 1.0
end

"""
Gets whether a given storage location is opening during a given period.
"""
function is_opening(supply_chain::SupplyChain, storage::Storage, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:opening][storage, period]) ≈ 1.0
end

"""
Gets whether a given storage location is closing during a given period.
"""
function is_closing(supply_chain::SupplyChain, storage::Storage, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:closing][storage, period]) ≈ 1.0
end

"""
Gets the inventory of a product stored at the start of a period.
"""
function get_inventory_at_start(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:stored_at_end][product, storage, period-1]) 
end

"""
Gets the inventory of a product stored at the end of a period.
"""
function get_inventory_at_end(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:stored_at_end][product, storage, period]) 
end

function check(supply_chain)
    if isnothing(supply_chain.optimization_model) || 
        !((termination_status(supply_chain.optimization_model) == JuMP.OPTIMAL) || (primal_status(supply_chain.optimization_model) == JuMP.FEASIBLE_POINT))
        throw(ErrorException("The optimize_network! function must be called first."))
    end
end