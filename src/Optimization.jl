"""
Creates an optimization model.
"""
function create_network_model(supply_chain, optimizer, bigM=1_000_000; single_source=false, evergreen=true, use_direct_model=false)
    check_model(supply_chain)

    times = 1:supply_chain.horizon
    products = supply_chain.products
    customers = supply_chain.customers
    storages = supply_chain.storages
    suppliers = supply_chain.suppliers
    plants = supply_chain.plants
    plants_storages = [x for x in union(plants, storages)]
    lanes = supply_chain.lanes

    m = Model(optimizer)
    if use_direct_model
        m = direct_model(HiGHS.Optimizer())#; bridge_constraints = false)
    end
    set_string_names_on_creation(m, false)

    @variable(m, total_profits)

    @variable(m, total_revenues >= 0)
    @variable(m, total_revenues_per_period[times] >= 0)

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
    @constraint(m, [s=storages, t=times; !isinf(s.maximum_overall_throughput)], sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) <= s.maximum_overall_throughput)
    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(received[p, l, t] for p in products, l in get_lanes_in(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(received[p, l, s, t] for p in products, l in get_lanes_in(supply_chain, s)) <= bigM * opened[s, t])

    @constraint(m, [p=products, s=storages, t=times; !isinf(get_maximum_storage(s, p))], stored_at_end[p, s, t] <= get_maximum_storage(s, p))
    
    ##@constraint(m, [s=plants_storages; s.must_be_opened_at_end], opened[s, supply_chain.horizon] == 1)
    ##@constraint(m, [s=plants_storages; s.must_be_closed_at_end], opened[s, supply_chain.horizon] == 0)

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
                                                                            + sum(get_arrivals(p, l, s, t) for l in get_lanes_in(supply_chain, s))
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
    @constraint(m, [p=products, s=plants; !has_bom(s, p)], sum(produced[p, s, :]) == 0)
    @constraint(m, [p=products, s=plants, t=times], sum(produced[p2, s, t] * get_bom(s, p2, p) for p2 in products if has_bom(s, p2, p); init=0.0) == sum(received[p, l, s, t] for l in get_lanes_in(supply_chain, s)))

    @constraint(m, [p=products, c=customers, t=times], sum(received[p, l, c, t] for l in get_lanes_in(supply_chain, c)) + sum(get_arrivals(p, l, c, t) for l in get_lanes_in(supply_chain, c)) == get_demand(supply_chain, c, p, t) - lost_sales[p, c, t])

    @constraint(m, [p=products, c=customers], sum(lost_sales[p, c, t] for t in times) <= (1 - get_service_level(supply_chain, c, p)) * sum(get_demand(supply_chain, c, p, t) for t in times))

    @constraint(m, [t=times], total_transportation_costs_per_period[t] == sum(sent[p, l, t] * l.unit_cost for p in products, l in lanes))
    @constraint(m, total_transportation_costs == sum(total_transportation_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_fixed_costs_per_period[t] == sum(opened[s, t] * s.fixed_cost for s in plants_storages))
    @constraint(m, total_fixed_costs == sum(total_fixed_costs_per_period[t] for t in times))

    @constraint(m, [t=times], total_holding_costs_per_period[t] == sum(stored_at_end[p, s, t] * get(s.unit_holding_cost, p, 0.0) for p in products, s in storages))
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

    @constraint(m, [t=times], total_revenues_per_period[t] == sum((get_sales_price(supply_chain, c, p, t) * (get_demand(supply_chain, c, p, t) - lost_sales[p, c, t])) for p in products for c in customers))
    @constraint(m, total_revenues == sum(supply_chain.discount_factor ^ (t-1) * total_revenues_per_period[t] for t in times))

    @constraint(m, total_costs == sum(supply_chain.discount_factor ^ (t-1) * total_costs_per_period[t] for t in times))

    @constraint(m, total_profits == total_revenues - total_costs)

    return m
end