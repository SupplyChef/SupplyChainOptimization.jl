module SupplyChainOptimization

using SupplyChainModeling
using Base: Bool, product
using JuMP
using HiGHS

# `using JuMP` above has to come before these includes, not after: Optimization.jl's
# functions use JuMP macros (@variable, @constraint, @objective, ...) in their bodies,
# and macro expansion happens at parse time (during `include`), unlike ordinary
# function calls which resolve names lazily at call time. This used to work by
# accident - Visualization.jl (included just before Optimization.jl) had its own
# `using JuMP`, which made JuMP's macros available module-wide from that point on.
# Once Visualization.jl stopped needing JuMP itself (PlotlyJS/Plots became weak
# deps - see that file and ext/), that accidental ordering broke Optimization.jl's
# precompilation. Don't reintroduce a `using JuMP` inside one of the included files
# as a fix - it worked once by luck, not by design.
include("Modeling.jl")
include("Querying.jl")
include("Visualization.jl")
include("Optimization.jl")
include("GSM.jl")

export minimize_cost!,
      maximize_profits!,
      get_financials,
      get_total_profits,
      get_total_costs,
      get_total_fixed_costs,
      get_total_transportation_costs,
      get_production,
      get_shipments,
      get_receipts,
      get_inventory_at_start,
      get_inventory_at_end,
      get_overflow,
      is_opened,
      is_opening,
      is_closing,
      haversine,
      plot_flows,
      plot_costs,
      animate_flows,
      plot_financials,
      plot_network,
      animate_network,
      movie_network,
      plot_inventory,
      compute_safety_stock_gsm,
      GSMResult,
      get_incoming_service_time,
      get_outgoing_service_time,
      get_net_replenishment_time,
      get_safety_stock,
      get_total_safety_stock_cost

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
    set_attribute(supply_chain.optimization_model, "time_limit", time_limit)
    set_attribute(supply_chain.optimization_model, "log_to_console", log)
    optimize_network_optimization_model!(supply_chain)
end

"""
    maximize_profits!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer)

Optimizes the supply chain for profits. The service level should be set to zero to let the optimizer decide which customers to serve.
"""
function maximize_profits!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer; log=false, time_limit=3600.0, single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
    create_network_profit_maximization_model!(supply_chain, optimizer; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, bigM=bigM)
    set_attribute(supply_chain.optimization_model, "time_limit", time_limit)
    set_attribute(supply_chain.optimization_model, "log_to_console", log)
    optimize_network_optimization_model!(supply_chain)
end

"""
Creates an optimization model for cost minimization.
"""
function create_network_cost_minimization_model!(supply_chain, optimizer; single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000)
    supply_chain.optimization_model = create_network_cost_minimization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model)
end

"""
Creates an optimization model for profit maximization.
"""
function create_network_profit_maximization_model!(supply_chain, optimizer; single_source=false, evergreen=true, use_direct_model=false, bigM=1_000_000, relax=false, last_period_only=false)
    supply_chain.optimization_model = create_network_profit_maximization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, relax=relax, last_period_only=last_period_only)
end


"""
Optimizes an optimization model.
"""
function optimize_network_optimization_model!(supply_chain)
    JuMP.optimize!(supply_chain.optimization_model)
end

"""
Creates an optimization model for cost minimization.
"""
function create_network_cost_minimization_model(supply_chain, optimizer, bigM=1_000_000; single_source=false, evergreen=true, use_direct_model=false)
    m = create_network_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model)
    @objective(m, Min, 1.0 * m[:total_costs])
    return m
end

"""
Creates an optimization model for profit maximization.
"""
function create_network_profit_maximization_model(supply_chain, optimizer, bigM=1_000_000; single_source=false, evergreen=true, use_direct_model=false, relax=false, last_period_only=false)
    m = create_network_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, relax=relax)
    if last_period_only
        @objective(m, Max, 1.0 * m[:total_revenues_per_period][supply_chain.horizon] - m[:total_costs_per_period][supply_chain.horizon])
    else
        @objective(m, Max, 1.0 * m[:total_profits])
    end
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
