module SupplyChainOptimization

include("Modeling.jl")
include("Visualization.jl")

using Base: Bool, product
using JuMP
using HiGHS

export SupplyChain, 
      Product, 
      Customer, 
      Storage, 
      Supplier, 
      Plant, 
      Lane, 
      Location,
      add_lane!,
      add_product!,
      add_customer!,
      add_storage!,
      add_supplier!,
      add_plant!,
      optimize!,
      get_total_costs,
      get_production,
      haversine,
      plot_nodes,
      plot_flows,
      plot_costs


function get_demand(customer, product, time)
    if(haskey(customer.demand, product))
        return customer.demand[product][time]
    else
        return 0
    end
end

function get_lanes_in(supply_chain, node)
    if(haskey(supply_chain.lanes_in, node))
        return supply_chain.lanes_in[node]
    else
        return Lane[]
    end
end

function get_lanes_out(supply_chain, node)
    if(haskey(supply_chain.lanes_out, node))
        return supply_chain.lanes_out[node]
    end
    return Lane[]
end

function get_bom(production, output, input)
    if(haskey(production.bill_of_material, output))
        if(haskey(production.bill_of_material[output], input))
            return production.bill_of_material[output][input]
        end
    end
    return 0
end

function get_maximum_throughput(node, product)
    if(haskey(node.maximum_throughput, product))
        return node.maximum_throughput[product]
    else
        return 0
    end
end

function get_safety_stock_cover(node, product)
    if(haskey(node.safety_stock_cover, product))
        return node.safety_stock_cover[product]
    else
        return 0
    end
end

function check_model(supply_chain)
    for production in supply_chain.plants
        for product in supply_chain.products
            if(haskey(production.bill_of_material, product) && !haskey(production.unit_cost, product)) || 
            (!haskey(production.bill_of_material, product) && haskey(production.unit_cost, product))
                throw(ArgumentError("Production $production must have the same produts in its BillOfMaterial and its UnitCost."))
            end
        end
    end
end

"""
Optimizes the supply chain.
"""
function optimize!(supply_chain, optimizer=HiGHS.Optimizer)
    create_optimization_model!(supply_chain, optimizer)
    set_optimizer_attribute(supply_chain.optimization_model, "mip_heuristic_effort", 0.35)
    optimize_optimization_model!(supply_chain)
end

"""
Creates an optimization model.
"""
function create_optimization_model!(supply_chain, optimizer)
    supply_chain.optimization_model = create_optimization_model(supply_chain, optimizer)
    set_optimizer_attribute(supply_chain.optimization_model, "primal_feasibility_tolerance", 1e-5)
end

"""
Optimizes an optimization model.
"""
function optimize_optimization_model!(supply_chain)
    JuMP.optimize!(supply_chain.optimization_model)
end

"""
Creates an optimization model.
"""
function create_optimization_model(supply_chain, optimizer, bigM=100_000)
    check_model(supply_chain)

    times = 1:supply_chain.horizon
    products = supply_chain.products
    customers = supply_chain.customers
    storages = supply_chain.storages
    suppliers = supply_chain.suppliers
    plants = supply_chain.plants
    plants_storages = [x for x in union(plants, storages)]
    lanes = supply_chain.lanes

    m = Model(optimizer)#; bridge_constraints = false)

    @variable(m, total_costs >= 0)
    @variable(m, total_transportation_costs >= 0)
    @variable(m, total_fixed_costs >= 0)

    @variable(m, total_costs_per_period[times] >= 0)
    @variable(m, total_transportation_costs_per_period[times] >= 0)
    @variable(m, total_fixed_costs_per_period[times] >= 0)

    @variable(m, opened[plants_storages, times], Bin)
    @variable(m, opening[plants_storages, times], Bin)
    @variable(m, closing[plants_storages, times], Bin)

    @variable(m, bought[products, suppliers, times] >= 0)

    @variable(m, produced[products, plants, times] >= 0)

    @variable(m, stored_at_start[products, storages, times] >= 0)
    @variable(m, stored_at_end[products, storages, times] >= 0)

    @variable(m, sent[products, lanes, times] >= 0)
    @variable(m, received[products, lanes, times] >= 0)

    @constraint(m, [p=products, s=storages], stored_at_start[p, s, 1] == get!(s.initial_inventory, p, 0))

    @constraint(m, [p=products, l=lanes, t=times; t > l.time], received[p, l, t] == sent[p, l, t - l.time])
    @constraint(m, [p=products, l=lanes, t=times; t <= l.time], received[p, l, t] == 0)

    #this should be zero or min
    #@constraint(m, [l=lanes, t=times; l.minimum_quantity > 0], sum(sent[p, l, t] for p in products) >= l.minimum_quantity)

    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) <= bigM * opened[s, t])
    @constraint(m, [p=products, s=storages, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))
    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(received[p, l, t] for p in products, l in get_lanes_in(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(received[p, l, t] for p in products, l in get_lanes_in(supply_chain, s)) <= bigM * opened[s, t])

    @constraint(m, [s=plants_storages], opening[s, 1] >= (opened[s, 1] - s.initial_opened))
    @constraint(m, [s=plants_storages, t=times; t > 1], opening[s, t] >= opened[s, t] - opened[s, t-1])

    @constraint(m, [s=plants_storages], closing[s, 1] >= -(opened[s, 1] - s.initial_opened))
    @constraint(m, [s=plants_storages, t=times; t > 1], closing[s, t] >= -(opened[s, t] - opened[s, t-1]))

    @constraint(m, [p=products, s=storages, t=times], stored_at_end[p, s, t] == stored_at_start[p, s, t] 
                                                                            + sum(received[p, l, t] for l in get_lanes_in(supply_chain, s))
                                                                            - sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s))
                                                                            )
    @constraint(m, [p=products, s=storages, t=times; t > 1], stored_at_start[p, s, t] == stored_at_end[p, s, t - 1])
    @constraint(m, [p=products, s=storages, t=times], stored_at_end[p, s, t] >= get_safety_stock_cover(s, p) * sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))

    @constraint(m, [p=products, s=suppliers, t=times], bought[p, s, t] == sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))
    @constraint(m, [p=products, s=suppliers, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))

    #@constraint(m, [p=products, s=plants, t=times], closed[s, t] => { produced[p, s, t] == 0 })
    @constraint(m, [p=products, s=plants, t=times], produced[p, s, t] <= bigM * opened[s, t])
    @constraint(m, [p=products, s=plants, t=times; !haskey(s.bill_of_material, p)], produced[p, s, t] == 0)
    @constraint(m, [p=products, s=plants, t=times], produced[p, s, t] == sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))
    @constraint(m, [p=products, s=plants, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))
    @constraint(m, [p=products, s=plants, t=times], sum(produced[p2, s, t] * get_bom(s, p2, p) for p2 in products) == sum(received[p, l, t] for l in get_lanes_in(supply_chain, s)))

    @constraint(m, [p=products, c=customers, t=times], sum(received[p, l, t] for l in get_lanes_in(supply_chain, c)) == get_demand(c, p, t))

    @constraint(m, [t=times], total_transportation_costs_per_period[t] == sum(sent[p, l, t] * l.unit_cost for p in products, l in lanes))
    @constraint(m, total_transportation_costs == sum(total_transportation_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_fixed_costs_per_period[t] == sum(opened[s, t] * s.fixed_cost for s in plants_storages))
    @constraint(m, total_fixed_costs == sum(total_fixed_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_costs_per_period[t] == total_transportation_costs_per_period[t] + 
                       total_fixed_costs_per_period[t] + 
                       sum(opening[s, t] * s.opening_cost for s in plants_storages) + 
                       sum(closing[s, t] * s.closing_cost for s in plants_storages) + 
                       sum(sum(received[p, l, t] * s.unit_handling_cost[p] for l in get_lanes_in(supply_chain, s)) for p in products for s in storages if haskey(s.unit_handling_cost, p)) +
                       sum(bought[p, s, t] * s.unit_cost[p] for p in products, s in suppliers if haskey(s.unit_cost, p)) +
                       sum(produced[p, s, t] * s.unit_cost[p] for p in products, s in plants if haskey(s.unit_cost, p)))

    @constraint(m, total_costs == sum(total_costs_per_period[t] for t in times))

    @objective(m, Min, 1.0 * total_costs)

    return m
end

"""
Gets the total costs of operating the supply chain.
"""
function get_total_costs(supply_chain::SupplyChain)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:total_costs])
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
    return value(supply_chain.optimization_model[:sent][product, storage, period])
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
Gets whether a given storage location is opened during a given period.
"""
function is_opened(supply_chain::SupplyChain, storage::Storage, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:opened][storage, period])
end

"""
Gets whether a given storage location is opening during a given period.
"""
function is_opening(supply_chain::SupplyChain, storage::Storage, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:opening][storage, period])
end

"""
Gets whether a given storage location is closing during a given period.
"""
function is_closing(supply_chain::SupplyChain, storage::Storage, period=1)
    if isnothing(supply_chain.optimization_model) || (termination_status(supply_chain.optimization_model) != JuMP.MathOptInterface.OPTIMAL)
        throw(ErrorException("The optimize! function must be called first."))
    end
    return value(supply_chain.optimization_model[:closing][storage, period])
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
