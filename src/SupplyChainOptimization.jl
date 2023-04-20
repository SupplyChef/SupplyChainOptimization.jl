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
end

"""
    optimize_network!(supply_chain::SupplyChain, optimizer=HiGHS.Optimizer)

Optimizes the supply chain.
"""
function optimize_network!(supply_chain, optimizer=HiGHS.Optimizer; log=false, time_limit=3600.0, single_source=false, evergreen=true)
    create_network_optimization_model!(supply_chain, optimizer; single_source=false, evergreen=true)
    #set_optimizer_attribute(supply_chain.optimization_model, "mip_heuristic_effort", 0.35)
    set_attribute(supply_chain.optimization_model, "log_to_console", log)
    set_attribute(supply_chain.optimization_model, "time_limit", time_limit)
    optimize_network_optimization_model!(supply_chain)
end

"""
Creates an optimization model.
"""
function create_network_optimization_model!(supply_chain, optimizer; single_source=false, evergreen=true)
    supply_chain.optimization_model = create_network_optimization_model(supply_chain, optimizer; single_source=single_source, evergreen=evergreen)
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
function create_network_optimization_model(supply_chain, optimizer, bigM=100_000; single_source=false, evergreen=true)
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
    set_string_names_on_creation(m, false)

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

    @variable(m, lost_sales[products, customers, times] >= 0)

    @variable(m, bought[products, suppliers, times] >= 0)

    @variable(m, produced[products, plants, times] >= 0)

    @variable(m, stored_at_end[products, storages, 0:supply_chain.horizon] >= 0)

    @variable(m, used[l=lanes, times; l.minimum_quantity > 0 || l.fixed_cost > 0], Bin)
    @variable(m, sent[products, lanes, times] >= 0)
    @variable(m, received[products, l=lanes, d=l.destinations, times] >= 0)

    if single_source
        @variable(m, serviced_by[products, storages, customers, times], Bin)
        @constraint(m, [p=products, c=customers, t=times], sum(serviced_by[p, s, c, t] for s in storages) <= 1)
        @constraint(m, [p=products, s=storages, c=customers, t=times], sum(received[p, l, c, t] for l in get_lanes_between(supply_chain, s, c)) <= bigM * serviced_by[p, s, c, t])
    end

    @constraint(m, [p=products, s=storages; haskey(s.initial_inventory, p)], stored_at_end[p, s, 0] == s.initial_inventory[p])
    if evergreen
        @constraint(m, [p=products, s=storages; !haskey(s.initial_inventory, p)], stored_at_end[p, s, 0] <= stored_at_end[p, s, supply_chain.horizon])
    end

    @constraint(m, [p=products, l=lanes, t=times], sum(received[p, l, l.destinations[i], t + l.times[i]] for i in 1:length(l.destinations) if t + l.times[i] <= supply_chain.horizon) == sent[p, l, t])

    @constraint(m, [l=lanes], sum(sent[p, l, t] for p in products, t in times if !can_ship(l, t)) == 0)
    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0 || l.fixed_cost > 0], sum(sent[p, l, t] for p in products) <= bigM * used[l, t])
    @constraint(m, [l=lanes, t=times; l.minimum_quantity > 0], sum(sent[p, l, t] for p in products) >= l.minimum_quantity * used[l, t])

    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) <= bigM * opened[s, t])
    @constraint(m, [p=products, s=plants_storages, c=customers, t=times], sum(received[p, l, c, t] for l in get_lanes_between(supply_chain, s, c)) 
        <= get_demand(supply_chain, c, p, t) * sum(opened[l.origin, get_sent_time(l, c, t)] for l in get_lanes_between(supply_chain, s, c) if get_sent_time(l, c, t) > 0))
    @constraint(m, [p=products, s=storages, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))
    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(received[p, l, t] for p in products, l in get_lanes_in(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(received[p, l, s, t] for p in products, l in get_lanes_in(supply_chain, s)) <= bigM * opened[s, t])

    @constraint(m, [p=products, s=storages, t=times; !isinf(get_maximum_storage(s, p))], stored_at_end[p, s, t] <= get_maximum_storage(s, p))
    
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

    @constraint(m, [s=plants_storages; isinf(s.opening_cost)], sum(opening[s, t] for t in times) == 0)
    @constraint(m, [s=plants_storages; isinf(s.closing_cost)], sum(closing[s, t] for t in times) == 0)

    @constraint(m, [p=products, s=storages, t=times], stored_at_end[p, s, t] == stored_at_end[p, s, t-1] 
                                                                            + sum(received[p, l, s, t] for l in get_lanes_in(supply_chain, s))
                                                                            + sum(get_arrivals(l, s, t) for l in get_lanes_in(supply_chain, s))
                                                                            - sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s))
                                                                            )
    @constraint(m, [p=products, s=storages, t=times; get_additional_stock_cover(s, p) > 0], stored_at_end[p, s, t] >= get_additional_stock_cover(s, p) * sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))

    @constraint(m, [p=products, s=suppliers, t=times], bought[p, s, t] == sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))
    @constraint(m, [p=products, s=suppliers, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))

    #@constraint(m, [p=products, s=plants, t=times], closed[s, t] => { produced[p, s, t] == 0 })
    for s in plants, p in products
        if haskey(s.time, p)
            @constraint(m, [t=times, ti=t:min(t+s.time[p], supply_chain.horizon)], produced[p, s, t] <= bigM * opened[s, ti])
        else
            @constraint(m, sum(produced[p, s, :]) == 0)
            @constraint(m, sum(sum(sent[p, l, :]) for l in get_lanes_out(supply_chain, s)) == 0)
        end
    end
    @constraint(m, [p=products, s=plants, t=times; haskey(s.time, p) && (t + s.time[p] <= supply_chain.horizon)], produced[p, s, t] == sum(sent[p, l, t + s.time[p]] for l in get_lanes_out(supply_chain, s)))
    @constraint(m, [p=products, s=plants, t=times; !isinf(get_maximum_throughput(s, p))], sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)) <= get_maximum_throughput(s, p))
    @constraint(m, [p=products, s=plants; !has_bom(s, p)], sum(produced[p, s, :]; init=0.0) == 0)
    @constraint(m, [p=products, s=plants, t=times], sum(produced[p2, s, t] * get_bom(s, p2, p) for p2 in products if has_bom(s, p2, p); init=0.0) == sum(received[p, l, s, t] for l in get_lanes_in(supply_chain, s)))

    @constraint(m, [p=products, c=customers, t=times], sum(received[p, l, c, t] for l in get_lanes_in(supply_chain, c)) + sum(get_arrivals(l, c, t) for l in get_lanes_in(supply_chain, c)) == get_demand(supply_chain, c, p, t) - lost_sales[p, c, t])

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
                       sum(sum(received[p, l, s, t] * s.unit_handling_cost[p] for l in get_lanes_in(supply_chain, s)) for p in products for s in storages if haskey(s.unit_handling_cost, p)) +
                       sum(bought[p, s, t] * s.unit_cost[p] for p in products, s in suppliers if haskey(s.unit_cost, p)) +
                       sum(produced[p, s, t] * s.unit_cost[p] for p in products, s in plants if haskey(s.unit_cost, p)) +
                       sum(l.fixed_cost * used[l, t] for l in lanes if l.fixed_cost > 0) +
                       total_holding_costs_per_period[t])

    @constraint(m, total_costs == sum(supply_chain.discount_factor ^ (t-1) * total_costs_per_period[t] for t in times))

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
