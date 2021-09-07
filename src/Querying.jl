"""
    get_total_costs(supply_chain::SupplyChain)

Gets the total costs of operating the supply chain.
"""
function get_total_costs(supply_chain::SupplyChain)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:total_costs])
end

"""
    get_total_fixed_costs(supply_chain::SupplyChain)

Gets the total fixed costs of operating the supply chain.
"""
function get_total_fixed_costs(supply_chain::SupplyChain)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:total_fixed_costs])
end

"""
    get_total_transportation_costs(supply_chain::SupplyChain)

Gets the total transportation costs of operating the supply chain.
"""
function get_total_transportation_costs(supply_chain::SupplyChain)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:total_transportation_costs])
end

"""
Gets the amount of a given product produced at a given plant during a given period.
"""
function get_production(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:produced][product, plant, period])
end

"""
Gets the amount of a given product received at a given storage location at a given period.
"""
function get_receipts(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:received][product, storage, period])
end

"""
Gets the amount of a given product sent from a given storage location at a given period.
"""
function get_shipments(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return sum(value(supply_chain.optimization_model[:sent][product, l, period]) for l in get_lanes_out(supply_chain, storage))
end

"""
Gets the amount of a given product sent from a given plant  at a given period.
"""
function get_shipments(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return sum(value(supply_chain.optimization_model[:sent][product, l, period]) for l in get_lanes_out(supply_chain, plant))
end

"""
Gets the amount of a given product shipped from a given supplier at a given period.
"""
function get_shipments(supply_chain::SupplyChain, supplier::Supplier, product::Product, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:bought][product, supplier, period])
end

"""
Gets the amount of a given product sent on a lane at a given period.
"""
function get_shipments(supply_chain::SupplyChain, lane::Lane, product::Product, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:sent][product, lane, period])
end

"""
Gets whether a given storage location is opened during a given period.
"""
function is_opened(supply_chain::SupplyChain, storage::Storage, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:opened][storage, period]) ≈ 1.0
end

"""
Gets whether a given plant is opened during a given period.
"""
function is_opened(supply_chain::SupplyChain, plant::Plant, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:opened][plant, period]) ≈ 1.0
end

"""
Gets whether a given storage location is opening during a given period.
"""
function is_opening(supply_chain::SupplyChain, storage::Storage, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:opening][storage, period]) ≈ 1.0
end

"""
Gets whether a given storage location is closing during a given period.
"""
function is_closing(supply_chain::SupplyChain, storage::Storage, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:closing][storage, period]) ≈ 1.0
end
