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