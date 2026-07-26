function get_sales_price(supply_chain, customer, product, time)
    if haskey(supply_chain.demand_for, (customer, product))
        return first(supply_chain.demand_for[(customer, product)]).sales_price
    end
    return 0
end

function get_service_level(supply_chain, customer, product)
    if haskey(supply_chain.demand_for, (customer, product))
        return first(supply_chain.demand_for[(customer, product)]).service_level
    end
    return 1.0
end

function has_bom(production, output)
    if(haskey(production.bill_of_material, output))
        return true
    end
    return false
end

function has_bom(production, output, input)
    if(haskey(production.bill_of_material, output))
        if(haskey(production.bill_of_material[output], input))
            return true
        end
    end
    return false
end

function get_bom(production, output, input)
    if(haskey(production.bill_of_material, output))
        if(haskey(production.bill_of_material[output], input))
            return production.bill_of_material[output][input]
        end
    end
    return Inf
end

function get_additional_stock_cover(node, product)
    if(haskey(node.additional_stock_cover, product))
        return node.additional_stock_cover[product]
    else
        return 0
    end
end

function get_sent_time(lane, destination, receipt_time)
    index = findfirst(d -> d == destination, lane.destinations)
    transit_time = lane.times[index]
    sent_time = receipt_time - transit_time
    return sent_time
end

# is_feasible_duration/get_duration_penalty/feasible_exits below drive the maturation-scheduling
# model purely off a MaturationSource's registered age-value curve (see
# MaturationSource.add_product!) - no assumption of linearity or any particular curve shape, so
# they work identically whether that curve was built via the linear/%-band convenience form or
# a fully custom one (e.g. a classical shelf-life curve).

"""
    is_feasible_duration(source, product, duration)

Checks whether a batch of `product` at `source` may ship after being held `duration` periods,
per the source's registered feasibility curve (see `MaturationSource.add_product!`).
"""
function is_feasible_duration(source, product, duration)
    return source.feasible_duration[product](duration)
end

"""
    get_duration_penalty(source, product, duration)

Gets the per-unit cost of shipping a batch of `product` at `source` after being held `duration`
periods, per the source's registered penalty curve (zero within its ideal range).
"""
function get_duration_penalty(source, product, duration)
    return source.duration_penalty[product](duration)
end

"""
    feasible_exits(source, product, U, V)

For a `MaturationSource`/product, computes every feasible `(start_day, ship_day)` pair given
candidate start days `U` and candidate ship days `V` (see [`is_feasible_duration`](@ref)). Start
days at or before `source.unavailable_periods` are excluded (the source cannot begin a new batch
during its mandatory turnaround). If the source already holds a batch of `product`
(`initial_inventory[product] > 0`), day `1` is always included as a start day regardless of `U`
or `unavailable_periods`: the batch's registered value at duration `0` already reflects its
*current* value as of day 1 of the horizon, so day 1 is a bookkeeping reference for an
in-progress batch rather than a new scheduling choice.
"""
function feasible_exits(source, product, U, V)
    fresh_starts = [u for u in U if u > source.unavailable_periods]
    u_candidates = get(source.initial_inventory, product, 0.0) > 0 ? union(fresh_starts, (1,)) : fresh_starts

    pairs = Tuple{Int, Int}[]
    for u in u_candidates, t in V
        t <= u && continue
        is_feasible_duration(source, product, t - u) && push!(pairs, (u, t))
    end
    return pairs
end