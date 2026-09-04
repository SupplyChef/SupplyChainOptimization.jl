using DataFrames

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
    return sum(value(supply_chain.optimization_model[:sent][product, l, period]) for l in get_lanes_out(supply_chain, storage); init=0.0)
end

"""
    get_shipments(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)

Gets the amount of a given product sent from a given plant at a given period.
"""
function get_shipments(supply_chain::SupplyChain, plant::Plant, product::Product, period=1)
    check(supply_chain)
    return sum(value(supply_chain.optimization_model[:sent][product, l, period]) for l in get_lanes_out(supply_chain, plant); init=0.0)
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
    get_shipments(supply_chain::SupplyChain, customer::Customer, product::Product, period=1)

Gets the amount of a given product received by a given customer at a given period.
"""
function get_shipments(supply_chain::SupplyChain, customer::Customer, product::Product, period=1)
    check(supply_chain)
    return sum(value(supply_chain.optimization_model[:received][product, l, customer, period]) for l in get_lanes_in(supply_chain, customer); init=0.0)
end

"""
    get_lost_sales(supply_chain::SupplyChain, customer::Customer, product::Product, period=1)

Gets the amount of demand for a given product at a given customer that went
unmet (lost) during a given period. Bounded by `add_demand!`'s
`service_level` over the whole horizon - see `get_financials` for the
associated `lost_sales_cost` in dollar terms.
"""
function get_lost_sales(supply_chain::SupplyChain, customer::Customer, product::Product, period=1)
    check(supply_chain)
    return value(supply_chain.optimization_model[:lost_sales][product, customer, period])
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

"""
Gets the amount of inventory of a product held beyond a storage's maximum_units
(in temporary/overflow storage) at the end of a period.
"""
function get_overflow(supply_chain::SupplyChain, storage::Storage, product::Product, period=1)
    check(supply_chain)
    overflow = supply_chain.optimization_model[:overflow]
    if !haskey(overflow, (product, storage, period))
        return 0.0
    end
    return value(overflow[product, storage, period])
end

function check(supply_chain)
    if isnothing(supply_chain.optimization_model) ||
        !((termination_status(supply_chain.optimization_model) == JuMP.OPTIMAL) || (primal_status(supply_chain.optimization_model) == JuMP.FEASIBLE_POINT) || has_values(supply_chain.optimization_model))
        throw(ErrorException("The optimize_network! function must be called first."))
    end
end

"""
    get_financials(supply_chain; max_time=supply_chain.horizon)

Gets the financial results of operating the supply chain.

(Moved here from Visualization.jl: unlike everything else in that file, this
doesn't touch PlotlyJS/Plots at all, so it stays available without the
`ext/SupplyChainOptimizationPlotlyJSExt` package extension - see that file
and Visualization.jl for why the split exists.)

`Lost_Sales_Cost` (each unmet unit's `lost_sales_cost` from `add_demand!`,
summed) *is* included in `Costs`/`Profits` above - it's folded into
`total_costs_per_period` in Optimization.jl alongside the physical operating
costs, so don't sum it in again when working from these columns. `Lost_Sales`
(the unmet quantity itself) has no cost dimension and is reported purely for
visibility.
"""
function get_financials(supply_chain; max_time=supply_chain.horizon)
    profits = collect(value.(supply_chain.optimization_model[:total_revenues_per_period]))[1:max_time].-collect(value.(supply_chain.optimization_model[:total_costs_per_period]))[1:max_time]
    cum_profits = cumsum(profits, dims=1)

    lost_sales_by_period(t) = sum(value(supply_chain.optimization_model[:lost_sales][p, c, t]) for p in supply_chain.products for c in supply_chain.customers; init=0.0)
    lost_sales_cost_by_period(t) = sum(value(supply_chain.optimization_model[:lost_sales][p, c, t]) * get_lost_sales_cost(supply_chain, c, p) for p in supply_chain.products for c in supply_chain.customers; init=0.0)

    DataFrame((Horizon = 1:max_time,
               Profits = profits,
               Cumulative_Profits = cum_profits,
               Revenues = collect(value.(supply_chain.optimization_model[:total_revenues_per_period]))[1:max_time],
               Costs = collect(value.(supply_chain.optimization_model[:total_costs_per_period]))[1:max_time],
               Transportation_Costs = collect(value.(supply_chain.optimization_model[:total_transportation_costs_per_period]))[1:max_time],
               Holding_Costs = collect(value.(supply_chain.optimization_model[:total_holding_costs_per_period]))[1:max_time],
               Buying_Costs = collect(value.(supply_chain.optimization_model[:total_buying_costs_per_period]))[1:max_time],
               Warehouses_Fixed_Costs = [sum(value(supply_chain.optimization_model[:opened][w,t]) * w.fixed_cost for w in supply_chain.storages) for t in 1:max_time],
               Opening_Costs = collect(value.(supply_chain.optimization_model[:total_opening_costs_per_period]))[1:max_time],
               Closing_Costs = collect(value.(supply_chain.optimization_model[:total_closing_costs_per_period]))[1:max_time],
               Lost_Sales = [lost_sales_by_period(t) for t in 1:max_time],
               Lost_Sales_Cost = [lost_sales_cost_by_period(t) for t in 1:max_time]))
end