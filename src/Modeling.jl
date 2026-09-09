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
    index = findfirst(==(destination), lane.destinations)
    transit_time = lane.times[index]
    sent_time = receipt_time - transit_time
    return sent_time
end

# SupplyChainModeling.jl caches and exports get_storage_index/get_product_index/
# get_location_index/get_lane_index - the same (Vector, Dict{T,Int64}) pairing
# SupplyChainSimulation.jl's State uses to turn a Storage/Product/location/Lane
# into a dense integer index for plain Array access instead of a Dict keyed by
# the struct itself. create_network_model (Optimization.jl) reuses those four
# directly, but customers/suppliers/plants and plants ∪ storages aren't indexed
# by the modeling package itself (get_location_index deliberately excludes
# plants - see its docstring there), so the four functions below build the same
# kind of IndexedCollection locally, for the same reason.
#
# Unlike SupplyChainModeling's own four, these aren't cached on `supply_chain` -
# there's no field to invalidate on add_plant!/add_customer!/add_supplier! there
# - so every call rebuilds the Vector+Dict pair. That's O(n) in the number of
# customers/suppliers/plants, trivial next to anything that indexes with the
# result (model construction, or a query over the solved model), and it keeps
# the mapping a pure function of supply_chain.customers/suppliers/plants/
# storages: called twice on an unchanged supply_chain (e.g. once building the
# real model, once building a warm-start sub-model in Heuristics.jl), it
# returns the identical Vector ordering both times, which is exactly the
# property those two independently-built models' variable containers need to
# stay consistent with each other.
function _index_collection(items)
    v = collect(items)
    return IndexedCollection(v, Dict(x => i for (i, x) in enumerate(v)))
end

get_customer_index(supply_chain) = _index_collection(supply_chain.customers)
get_supplier_index(supply_chain) = _index_collection(supply_chain.suppliers)
get_plant_index(supply_chain) = _index_collection(supply_chain.plants)
get_plant_storage_index(supply_chain) = _index_collection(union(supply_chain.plants, supply_chain.storages))