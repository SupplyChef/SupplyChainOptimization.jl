using Statistics

# Approximates the inverse CDF (quantile function) of the standard normal distribution,
# using Peter Acklam's rational approximation (relative error < 1.15e-9 over (0,1)). Kept
# as a small self-contained helper rather than adding Distributions.jl as a dependency for
# a single function. Not exported - internal to GSM's z-score computation.
function _standard_normal_quantile(p::Real)
    if p <= 0.0 || p >= 1.0
        throw(DomainError(p, "p must be strictly between 0.0 and 1.0"))
    end

    a1 = -3.969683028665376e+01
    a2 =  2.209460984245205e+02
    a3 = -2.759285104469687e+02
    a4 =  1.383577518672690e+02
    a5 = -3.066479806614716e+01
    a6 =  2.506628277459239e+00

    b1 = -5.447609879822406e+01
    b2 =  1.615858368580409e+02
    b3 = -1.556989798598866e+02
    b4 =  6.680131188771972e+01
    b5 = -1.328068155288572e+01

    c1 = -7.784894002430293e-03
    c2 = -3.223964580411365e-01
    c3 = -2.400758277161838e+00
    c4 = -2.549732539343734e+00
    c5 =  4.374664141464968e+00
    c6 =  2.938163982698783e+00

    d1 =  7.784695709041462e-03
    d2 =  3.224671290700398e-01
    d3 =  2.445134137142996e+00
    d4 =  3.754408661907416e+00

    p_low = 0.02425
    p_high = 1 - p_low

    if p < p_low
        q = sqrt(-2 * log(p))
        return (((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) /
               ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
    elseif p <= p_high
        q = p - 0.5
        r = q * q
        return (((((a1 * r + a2) * r + a3) * r + a4) * r + a5) * r + a6) * q /
               (((((b1 * r + b2) * r + b3) * r + b4) * r + b5) * r + 1)
    else
        q = sqrt(-2 * log(1 - p))
        return -(((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6) /
                ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
    end
end

"""
The result of a Guaranteed Service Model (GSM) safety-stock placement run: for each node,
the guaranteed incoming/outgoing service times and the resulting safety stock.
"""
struct GSMResult
    product::Product
    service_level::Float64
    z::Float64
    incoming_service_time::Dict{Node, Int64}
    outgoing_service_time::Dict{Node, Int64}
    safety_stock::Dict{Node, Float64}
end

"""
    get_incoming_service_time(result::GSMResult, node::Node)

Gets the guaranteed incoming service time (the time node's upstream suppliers promise it) computed by [`compute_safety_stock_gsm`](@ref).
"""
function get_incoming_service_time(result::GSMResult, node::Node)
    return get(result.incoming_service_time, node, 0)
end

"""
    get_outgoing_service_time(result::GSMResult, node::Node)

Gets the guaranteed outgoing service time (the time node promises its downstream customers) computed by [`compute_safety_stock_gsm`](@ref).
"""
function get_outgoing_service_time(result::GSMResult, node::Node)
    return get(result.outgoing_service_time, node, 0)
end

"""
    get_net_replenishment_time(result::GSMResult, node::Node)

Gets the net replenishment time (incoming service time + lead time - outgoing service time) - the
number of periods node must cover demand from its own safety stock.
"""
function get_net_replenishment_time(result::GSMResult, node::Node)
    return get(result.incoming_service_time, node, 0) - get(result.outgoing_service_time, node, 0)
end

"""
    get_safety_stock(result::GSMResult, node::Node)

Gets the safety stock GSM places at node, computed by [`compute_safety_stock_gsm`](@ref).
"""
function get_safety_stock(result::GSMResult, node::Node)
    return get(result.safety_stock, node, 0.0)
end

"""
    get_total_safety_stock_cost(result::GSMResult, supply_chain::SupplyChain)

Gets the total holding cost of the safety stock GSM places across the network.
"""
function get_total_safety_stock_cost(result::GSMResult, supply_chain::SupplyChain)
    total = 0.0
    for storage in supply_chain.storages
        total += get_safety_stock(result, storage) * get(storage.unit_holding_cost, result.product, 0.0)
    end
    return total
end

"""
    compute_safety_stock_gsm(supply_chain::SupplyChain, product::Product; service_level::Real=0.95, maximum_customer_wait::Real=0)

Computes optimal safety-stock placement for `product` across `supply_chain` using the
Graves & Willems (2000) Guaranteed Service Model (GSM): for each node, finds an
incoming/outgoing service-time pair that minimizes total safety-stock holding cost,
subject to a common target `service_level` (converted to a z-score) and guaranteed-service
consistency across the network (a node cannot promise faster service than what its own
incoming service time and lead time allow).

`maximum_customer_wait` is the number of periods a customer is willing to wait, measured
at the storage(s) serving them directly (0 means that storage must have inventory ready to
ship the moment an order arrives). It does not separately account for the transit time of
the final lane from that storage to the customer, which is a fixed delay layered on top and
doesn't affect which safety-stock placement is cost-optimal.

This is a tree-structured (single-sourced) implementation, matching the scope of the
original Graves & Willems (2000) algorithm: every storage/supplier may have at most one
upstream lane for `product`, and plants/production (bill-of-material) are not yet
supported, since both introduce the merge points that the general-acyclic-network
extension (Humair & Willems, 2011) is needed for. Both raise a clear `ArgumentError`
rather than silently producing a wrong answer.
"""
function compute_safety_stock_gsm(supply_chain::SupplyChain, product::Product; service_level::Real=0.95, maximum_customer_wait::Real=0)
    if service_level <= 0.0 || service_level >= 1.0
        throw(DomainError(service_level, "service_level must be strictly between 0.0 and 1.0"))
    end
    if maximum_customer_wait < 0
        throw(DomainError(maximum_customer_wait, "maximum_customer_wait must be non-negative"))
    end

    for plant in supply_chain.plants
        if haskey(plant.unit_cost, product)
            throw(ArgumentError("compute_safety_stock_gsm does not yet support production/bill-of-material networks (plant $plant produces $product) - only pure distribution networks (supplier -> storage -> ... -> customer)."))
        end
    end

    relevant_nodes = Set{Node}()
    for s in supply_chain.storages
        haskey(s.unit_holding_cost, product) && push!(relevant_nodes, s)
    end
    for s in supply_chain.suppliers
        haskey(s.unit_cost, product) && push!(relevant_nodes, s)
    end

    children = Dict{Node, Vector{Node}}(n => Node[] for n in relevant_nodes)
    lead_time = Dict{Node, Int64}(n => 0 for n in relevant_nodes)
    parent_count = Dict{Node, Int64}(n => 0 for n in relevant_nodes)
    direct_customer_variance = Dict{Node, Float64}(n => 0.0 for n in relevant_nodes)
    serves_customer_directly = Dict{Node, Bool}(n => false for n in relevant_nodes)

    parents = Dict{Node, Set{Node}}(n => Set{Node}() for n in relevant_nodes)
    seen_customers = Dict{Node, Set{Customer}}(n => Set{Customer}() for n in relevant_nodes)
    customer_servers = Dict{Customer, Set{Node}}()

    for lane in supply_chain.lanes
        origin = lane.origin
        if !(origin in relevant_nodes)
            continue
        end
        for destination in get_destinations(lane)
            if destination isa Customer
                destination in seen_customers[origin] && continue
                demands = filter(d -> d.customer == destination && d.product == product, supply_chain.demand)
                if !isempty(demands)
                    push!(seen_customers[origin], destination)
                    serves_customer_directly[origin] = true
                    direct_customer_variance[origin] += var(first(demands).demand)
                    push!(get!(customer_servers, destination, Set{Node}()), origin)
                end
            elseif destination in relevant_nodes
                if !(origin in parents[destination])
                    push!(parents[destination], origin)
                    push!(children[origin], destination)
                    lead_time[destination] = get_leadtime(lane, destination)
                    parent_count[destination] = length(parents[destination])
                end
            end
        end
    end

    for (node, count) in parent_count
        if count > 1
            throw(ArgumentError("compute_safety_stock_gsm currently supports tree-structured (single-sourced) networks only - $node is fed by $count distinct predecessors for $product. General acyclic networks (Humair & Willems, 2011) are not yet supported."))
        end
    end
    for (customer, servers) in customer_servers
        if length(servers) > 1
            throw(ArgumentError("compute_safety_stock_gsm currently supports single-sourced customers only - $customer is served by $(length(servers)) distinct nodes for $product. General acyclic networks (Humair & Willems, 2011) are not yet supported."))
        end
    end

    roots = Node[n for n in relevant_nodes if get(parent_count, n, 0) == 0]

    reachable = Set{Node}()
    to_visit = Node[roots...]
    while !isempty(to_visit)
        node = pop!(to_visit)
        node in reachable && continue
        push!(reachable, node)
        append!(to_visit, children[node])
    end
    if length(reachable) != length(relevant_nodes)
        throw(ArgumentError("compute_safety_stock_gsm requires an acyclic network reachable from a single-sourced root for $product - the network for $product contains a cycle or a disconnected component, which is not yet supported."))
    end

    holding_cost = Dict{Node, Float64}(n => (n isa Storage ? get(n.unit_holding_cost, product, 0.0) : 0.0) for n in relevant_nodes)
    max_outgoing = Dict{Node, Union{Int64, Nothing}}(n => (serves_customer_directly[n] ? Int(maximum_customer_wait) : nothing) for n in relevant_nodes)

    sigma = Dict{Node, Float64}()
    function compute_sigma!(node)
        haskey(sigma, node) && return sigma[node]
        variance = direct_customer_variance[node]
        for child in children[node]
            variance += compute_sigma!(child)^2
        end
        sigma[node] = sqrt(variance)
        return sigma[node]
    end
    for root in roots
        compute_sigma!(root)
    end

    z = _standard_normal_quantile(service_level)

    memo = Dict{Tuple{Node, Int64}, Tuple{Float64, Int64}}()
    function cost_to_go!(node, incoming::Int64)
        key = (node, incoming)
        haskey(memo, key) && return memo[key][1]

        upper = incoming + lead_time[node]
        if !isnothing(max_outgoing[node])
            upper = min(upper, max_outgoing[node])
        end

        best_cost = Inf
        best_outgoing = 0
        for outgoing in 0:upper
            net_replenishment_time = incoming + lead_time[node] - outgoing
            own_cost = holding_cost[node] * z * sigma[node] * sqrt(net_replenishment_time)
            children_cost = 0.0
            for child in children[node]
                children_cost += cost_to_go!(child, outgoing)
            end
            total_cost = own_cost + children_cost
            if total_cost < best_cost
                best_cost = total_cost
                best_outgoing = outgoing
            end
        end

        memo[key] = (best_cost, best_outgoing)
        return best_cost
    end

    for root in roots
        cost_to_go!(root, 0)
    end

    incoming_service_time = Dict{Node, Int64}()
    outgoing_service_time = Dict{Node, Int64}()
    function assign!(node, incoming::Int64)
        incoming_service_time[node] = incoming
        _, outgoing = memo[(node, incoming)]
        outgoing_service_time[node] = outgoing
        for child in children[node]
            assign!(child, outgoing)
        end
    end
    for root in roots
        assign!(root, 0)
    end

    safety_stock = Dict{Node, Float64}()
    for node in relevant_nodes
        net_replenishment_time = incoming_service_time[node] + lead_time[node] - outgoing_service_time[node]
        safety_stock[node] = z * sigma[node] * sqrt(net_replenishment_time)
    end

    return GSMResult(product, Float64(service_level), z, incoming_service_time, outgoing_service_time, safety_stock)
end
