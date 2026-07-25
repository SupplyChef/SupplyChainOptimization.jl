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

# maturation_zone/feasible_exits below implement Figure 1 and equations (1)-(6) of Gbéya,
# Darvish, Renaud and Coelho (2026), "Integrated Poultry Production-Distribution
# Optimization", CIRRELT-2026-10, generalized from a single global target/deviation to
# per-(MaturationSource, Product) values (see MaturationSource.add_product!).

# Returns the four value thresholds delimiting the three sellable zones (and the
# unsellable region beyond them) around a MaturationSource's target_value for a product.
function _maturation_zone_bounds(source, product)
    W = source.target_value[product]
    lower_extended = (1 - source.acceptable_deviation_under[product] - source.extended_deviation_under[product]) * W
    lower_acceptable = (1 - source.acceptable_deviation_under[product]) * W
    upper_acceptable = (1 + source.acceptable_deviation_over[product]) * W
    upper_extended = (1 + source.acceptable_deviation_over[product] + source.extended_deviation_over[product]) * W
    return (lower_extended, lower_acceptable, upper_acceptable, upper_extended)
end

"""
    maturation_zone(source, product, duration)

Classifies a batch's value after being held `duration` periods into one of three zones: `0`
(ideal/on-target), `1` (below target but still sellable, e.g. to an alternative market), `2`
(above target but still sellable). Returns `nothing` if the value falls outside even the
extended-sellable range, meaning a batch cannot ship at that duration.
"""
function maturation_zone(source, product, duration)
    value = get_maturity_value(source, product, duration)
    lower_extended, lower_acceptable, upper_acceptable, upper_extended = _maturation_zone_bounds(source, product)
    if lower_acceptable <= value <= upper_acceptable
        return 0
    elseif lower_extended <= value < lower_acceptable
        return 1
    elseif upper_acceptable < value <= upper_extended
        return 2
    else
        return nothing
    end
end

"""
    feasible_exits(source, product, U, V)

For a `MaturationSource`/product, computes every feasible `(start_day, ship_day, zone)` triple
given candidate start days `U` and candidate ship days `V`: `zone` is `0`, `1`, or `2` (see
`maturation_zone`). Start days at or before `source.unavailable_periods` are excluded (the
source cannot begin a new batch during its mandatory turnaround). If the source already holds
a batch of `product` (`initial_inventory[product] > 0`), day `1` is always included as a start
day regardless of `U` or `unavailable_periods`: `initial_value` already reflects that batch's
*current* value as of day 1 of the horizon, so day 1 is a bookkeeping reference for an
in-progress batch rather than a new scheduling choice.
"""
function feasible_exits(source, product, U, V)
    fresh_starts = [u for u in U if u > source.unavailable_periods]
    u_candidates = get(source.initial_inventory, product, 0.0) > 0 ? union(fresh_starts, (1,)) : fresh_starts

    triples = Tuple{Int, Int, Int}[]
    for u in u_candidates, t in V
        t <= u && continue
        zone = maturation_zone(source, product, t - u)
        isnothing(zone) && continue
        push!(triples, (u, t, zone))
    end
    return triples
end