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

function get_sent_time(lane, destination, receipt_time)
    index = findfirst(d -> d == destination, lane.destinations)
    transit_time = lane.times[index]
    sent_time = receipt_time - transit_time
    return sent_time
end