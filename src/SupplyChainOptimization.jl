module SupplyChainOptimization

include("Modeling.jl")
include("Querying.jl")
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
      Demand,
      Node,
      add_lane!,
      add_product!,
      add_customer!,
      add_storage!,
      add_supplier!,
      add_demand!,
      add_plant!,
      optimize_network!,
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


function get_demand(supply_chain, customer, product, time)
    for demand in supply_chain.demand
        if demand.customer == customer && demand.product == product
            return demand.demand[time]
        end
    end
    return 0
end

function get_service_level(supply_chain, customer, product)
    for demand in supply_chain.demand
        if demand.customer == customer && demand.product == product
            return demand.service_level
        end
    end
    return 1.0
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

function get_additional_stock_cover(node, product)
    if(haskey(node.additional_stock_cover, product))
        return node.additional_stock_cover[product]
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
    optimize_network!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer)

Optimizes the supply chain.
"""
function optimize_network!(supply_chain, optimizer=HiGHS.Optimizer)
    create_network_optimization_model!(supply_chain, optimizer)
    set_optimizer_attribute(supply_chain.optimization_model, "mip_heuristic_effort", 0.35)
    optimize_network_optimization_model!(supply_chain)
end

"""
Creates an optimization model.
"""
function create_network_optimization_model!(supply_chain, optimizer)
    supply_chain.optimization_model = create_network_optimization_model(supply_chain, optimizer)
    set_optimizer_attribute(supply_chain.optimization_model, "primal_feasibility_tolerance", 1e-5)
end

"""
Optimizes an optimization model.
"""
function optimize_network_optimization_model!(supply_chain)
    JuMP.optimize!(supply_chain.optimization_model)
end

"""
Creates an optimization model.
"""
function create_network_optimization_model(supply_chain, optimizer, bigM=100_000)
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
    @variable(m, total_holding_costs >= 0)

    @variable(m, total_costs_per_period[times] >= 0)
    @variable(m, total_transportation_costs_per_period[times] >= 0)
    @variable(m, total_fixed_costs_per_period[times] >= 0)
    @variable(m, total_holding_costs_per_period[times] >= 0)

    @variable(m, opened[plants_storages, times], Bin)
    @variable(m, opening[plants_storages, times], Bin)
    @variable(m, closing[plants_storages, times], Bin)

    #@variable(m, serviced_by[products, storages, customers, times], Bin)

    @variable(m, lost_sales[products, customers, times] >= 0)

    @variable(m, bought[products, suppliers, times] >= 0)

    @variable(m, produced[products, plants, times] >= 0)

    @variable(m, stored_at_start[products, storages, times] >= 0)
    @variable(m, stored_at_end[products, storages, times] >= 0)

    @variable(m, used[lanes, times], Bin)
    @variable(m, sent[products, lanes, times] >= 0)
    @variable(m, received[products, lanes, times] >= 0)

    #single source constraint
    #@constraint(m, [p=products, c=customers, t=times], sum(serviced_by[p, s, c, t] for s in storages) <= 1)
    #@constraint(m, [p=products, s=storages, c=customers, t=times], sum(received[p, l, t] for l in get_lanes_in(supply_chain, c) if l.origin == s) <= bigM * serviced_by[p, s, c, t])

    @constraint(m, [p=products, s=storages; haskey(s.initial_inventory, p)], stored_at_start[p, s, 1] == s.initial_inventory[p])
    @constraint(m, [p=products, s=storages; !haskey(s.initial_inventory, p)], stored_at_start[p, s, 1] <= stored_at_end[p, s, supply_chain.horizon])

    @constraint(m, [p=products, l=lanes, t=times; t > l.time], received[p, l, t] == sent[p, l, t - l.time])
    @constraint(m, [p=products, l=lanes, t=times; t <= l.time], received[p, l, t] == 0)

    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0], sum(sent[p, l, t] for p in products) <= bigM * used[l, t])
    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0], sum(sent[p, l, t] for p in products) >= l.minimum_quantity * used[l, t])

    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) <= bigM * opened[s, t])
    @constraint(m, [p=products, s=storages, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))
    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(received[p, l, t] for p in products, l in get_lanes_in(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(received[p, l, t] for p in products, l in get_lanes_in(supply_chain, s)) <= bigM * opened[s, t])

    @constraint(m, [s=plants_storages], opening[s, 1] >= opened[s, 1] + (1 - s.initial_opened) - 1)
    @constraint(m, [s=plants_storages], opening[s, 1] <= opened[s, 1])
    @constraint(m, [s=plants_storages], opening[s, 1] <= 1 - s.initial_opened)

    @constraint(m, [s=plants_storages, t=times; t > 1], opening[s, t] >= opened[s, t] + (1 - opened[s, t-1]) - 1)
    @constraint(m, [s=plants_storages, t=times; t > 1], opening[s, t] <= opened[s, t])
    @constraint(m, [s=plants_storages, t=times; t > 1], opening[s, t] <= 1 - opened[s, t-1])

    @constraint(m, [s=plants_storages], closing[s, 1] >= (1 - opened[s, 1]) + s.initial_opened - 1)
    @constraint(m, [s=plants_storages], closing[s, 1] <= 1 - opened[s, 1])
    @constraint(m, [s=plants_storages], closing[s, 1] <= s.initial_opened)

    @constraint(m, [s=plants_storages, t=times; t > 1], closing[s, t] >= (1 - opened[s, t]) + opened[s, t-1] - 1)
    @constraint(m, [s=plants_storages, t=times; t > 1], closing[s, t] <= 1 - opened[s, t])
    @constraint(m, [s=plants_storages, t=times; t > 1], closing[s, t] <= opened[s, t-1])

    @constraint(m, [s=plants_storages, t=times; isinf(s.opening_cost)], opending[s, t] == 0)
    @constraint(m, [s=plants_storages, t=times; isinf(s.closing_cost)], closing[s, t] == 0)

    @constraint(m, [p=products, s=storages, t=times], stored_at_end[p, s, t] == stored_at_start[p, s, t] 
                                                                            + sum(received[p, l, t] for l in get_lanes_in(supply_chain, s))
                                                                            - sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s))
                                                                            )
    @constraint(m, [p=products, s=storages, t=times; t > 1], stored_at_start[p, s, t] == stored_at_end[p, s, t - 1])
    @constraint(m, [p=products, s=storages, t=times], stored_at_end[p, s, t] >= get_additional_stock_cover(s, p) * sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))

    @constraint(m, [p=products, s=suppliers, t=times], bought[p, s, t] == sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))
    @constraint(m, [p=products, s=suppliers, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))

    #@constraint(m, [p=products, s=plants, t=times], closed[s, t] => { produced[p, s, t] == 0 })
    @constraint(m, [p=products, s=plants, t=times], produced[p, s, t] <= bigM * opened[s, t])
    @constraint(m, [p=products, s=plants, t=times; !haskey(s.bill_of_material, p)], produced[p, s, t] == 0)
    @constraint(m, [p=products, s=plants, t=times; haskey(s.time, p) && (t + s.time[p] <= supply_chain.horizon)], produced[p, s, t] == sum(sent[p, l, t + s.time[p]] for l in get_lanes_out(supply_chain, s)))
    @constraint(m, [p=products, s=plants, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))
    @constraint(m, [p=products, s=plants, t=times], sum(produced[p2, s, t] * get_bom(s, p2, p) for p2 in products) == sum(received[p, l, t] for l in get_lanes_in(supply_chain, s)))

    @constraint(m, [p=products, c=customers, t=times], sum(received[p, l, t] for l in get_lanes_in(supply_chain, c)) == get_demand(supply_chain, c, p, t) - lost_sales[p, c, t])

    @constraint(m, [p=products, c=customers], sum(lost_sales[p, c, t] for t in times) <= (1 - get_service_level(supply_chain, c, p)) * sum(get_demand(supply_chain, c, p, t) for t in times))

    @constraint(m, [t=times], total_transportation_costs_per_period[t] == sum(sent[p, l, t] * l.unit_cost for p in products, l in lanes))
    @constraint(m, total_transportation_costs == sum(total_transportation_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_fixed_costs_per_period[t] == sum(opened[s, t] * s.fixed_cost for s in plants_storages))
    @constraint(m, total_fixed_costs == sum(total_fixed_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_holding_costs_per_period[t] == sum(stored_at_end[p, s, t] * p.unit_holding_cost for p in products, s in storages))
    @constraint(m, total_holding_costs == sum(total_holding_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_costs_per_period[t] == total_transportation_costs_per_period[t] + 
                       total_fixed_costs_per_period[t] + 
                       sum(opening[s, t] * s.opening_cost for s in plants_storages if !isinf(s.opening_cost)) + 
                       sum(closing[s, t] * s.closing_cost for s in plants_storages if !isinf(s.closing_cost)) + 
                       sum(sum(received[p, l, t] * s.unit_handling_cost[p] for l in get_lanes_in(supply_chain, s)) for p in products for s in storages if haskey(s.unit_handling_cost, p)) +
                       sum(bought[p, s, t] * s.unit_cost[p] for p in products, s in suppliers if haskey(s.unit_cost, p)) +
                       sum(produced[p, s, t] * s.unit_cost[p] for p in products, s in plants if haskey(s.unit_cost, p)) +
                       total_holding_costs)

    @constraint(m, total_costs == sum(total_costs_per_period[t] for t in times))

    @objective(m, Min, 1.0 * total_costs)

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
