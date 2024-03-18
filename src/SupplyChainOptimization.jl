module SupplyChainOptimization

using SupplyChainModeling

include("Modeling.jl")
include("Querying.jl")
include("Visualization.jl")
include("Optimization.jl")

using Base: Bool, product
using JuMP
using HiGHS

export minimize_cost!,
      maximize_profits!,
      get_total_profits,
      get_total_costs,
      get_total_fixed_costs,
      get_total_transportation_costs,
      get_production,
      get_shipments,
      get_receipts,
      get_inventory_at_start,
      get_inventory_at_end,
      is_opened,
      is_opening,
      is_closing,
      haversine,
      plot_flows,
      plot_costs,
      plot_network,
      plot_inventory

function check_model(supply_chain)
    for production in supply_chain.plants
        for product in supply_chain.products
            if (haskey(production.bill_of_material, product) && !haskey(production.unit_cost, product)) || 
            (!haskey(production.bill_of_material, product) && haskey(production.unit_cost, product)) ||
            (haskey(production.bill_of_material, product) && !haskey(production.time, product)) ||
            (!haskey(production.bill_of_material, product) && haskey(production.time, product))
                throw(ArgumentError("Production $production must have the same products in its bill_of_material, its unit_cost and its time data."))
            end
        end
    end

    for customer in supply_chain.customers
        if isempty(filter(d -> d.customer == customer, supply_chain.demand))
            throw(ArgumentError("Customer $customer does not have demand."))
        end
    end
end

"""
    minimize_cost!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer)

Optimizes the supply chain for cost. The service level should be set to one to force the optimizer to serve all customers.
"""
function minimize_cost!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer; log=false, time_limit=3600.0, single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
    create_network_cost_minimization_model!(supply_chain, optimizer; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, bigM=bigM)
    #set_optimizer_attribute(supply_chain.optimization_model, "mip_heuristic_effort", 0.35)
    set_attribute(supply_chain.optimization_model, "log_to_console", log)
    set_attribute(supply_chain.optimization_model, "time_limit", time_limit)
    optimize_network_optimization_model!(supply_chain)
end

"""
    maximize_profits!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer)

Optimizes the supply chain for profits. The service level should be set to zero to let the optimizer decide which customers to serve.
"""
function maximize_profits!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer; log=false, time_limit=3600.0, single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
    create_network_profit_maximization_model!(supply_chain, optimizer; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, bigM=bigM)
    #set_optimizer_attribute(supply_chain.optimization_model, "mip_heuristic_effort", 0.35)
    set_attribute(supply_chain.optimization_model, "log_to_console", log)
    set_attribute(supply_chain.optimization_model, "time_limit", time_limit)
    optimize_network_optimization_model!(supply_chain)
end

# """
#     evaluate_disruption!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer)

# Optimizes the supply chain for profits given that a supplier cannot provide a product.
# """
# function evaluate_disruption!(supply_chain::SupplyChain, supplier::Supplier, product::Product, optimizer=HiGHS.Optimizer; log=false, time_limit=3600.0, single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
#     supplier.maximum_throughput[product] = 0.0
#     create_network_profit_maximization_model!(supply_chain, optimizer; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, bigM=bigM)
#     #set_optimizer_attribute(supply_chain.optimization_model, "mip_heuristic_effort", 0.35)
#     set_attribute(supply_chain.optimization_model, "log_to_console", log)
#     set_attribute(supply_chain.optimization_model, "time_limit", time_limit)
#     optimize_network_optimization_model!(supply_chain)
# end

# """
#     evaluate_recovery!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer)

# Optimizes the supply chain for profits given that a product has been exhausted from the supply chain.
# """
# function evaluate_recovery!(supply_chain::SupplyChain, product::Product, optimizer=HiGHS.Optimizer; log=false, time_limit=3600.0, single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
#     #TODO!
#     create_network_profit_maximization_model!(supply_chain, optimizer; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, bigM=bigM)
#     #set_optimizer_attribute(supply_chain.optimization_model, "mip_heuristic_effort", 0.35)
#     set_attribute(supply_chain.optimization_model, "log_to_console", log)
#     set_attribute(supply_chain.optimization_model, "time_limit", time_limit)
#     optimize_network_optimization_model!(supply_chain)
# end

"""
Creates an optimization model.
"""
function create_network_cost_minimization_model!(supply_chain, optimizer; single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
    supply_chain.optimization_model = create_network_cost_minimization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model)
    set_optimizer_attribute(supply_chain.optimization_model, "primal_feasibility_tolerance", 1e-5)
end

"""
Creates an optimization model.
"""
function create_network_profit_maximization_model!(supply_chain, optimizer; single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
    supply_chain.optimization_model = create_network_profit_maximization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model)
    set_optimizer_attribute(supply_chain.optimization_model, "primal_feasibility_tolerance", 1e-5)
end


"""
Optimizes an optimization model.
"""
function optimize_network_optimization_model!(supply_chain)
    JuMP.optimize!(supply_chain.optimization_model)
end

function create_network_cost_minimization_model(supply_chain, optimizer, bigM=1_000_000; single_source=false, evergreen=true, use_direct_model=false)
    m = create_network_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model)
    @objective(m, Min, 1.0 * m[:total_costs])
    return m
end

function create_network_profit_maximization_model(supply_chain, optimizer, bigM=1_000_000; single_source=false, evergreen=true, use_direct_model=false)
    m = create_network_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model)
    @objective(m, Max, 1.0 * m[:total_profits])
    return m
end

"""
Computes the great circle distance between two locations. The distance is expressed in meter.
"""
function haversine(location1::Location, location2::Location)
    return haversine(location1.latitude, location1.longitude, location2.latitude, location2.longitude)
end

function haversine(lat1, lon1, lat2, lon2)
    R = 6371e3

    Δlat = lat2 - lat1
    Δlon = lon2 - lon1

    return 2 * R * asin(sqrt(sind(Δlat / 2) ^ 2 + cosd(lat1) * cosd(lat2) * sind(Δlon / 2) ^ 2))
end

end # module
