module SupplyChainOptimization

using Base: Bool, product
using JuMP

export SupplyChain, Product, Customer, Storage, Supplier, Production, Lane, Location

export add_lane,
       add_product,
       add_customer,
       add_storage,
       add_supplier,
       add_production,
       create_optimization_model

struct Location
    Latitude::Float64
    Longitude::Float64
end

abstract type Node end

struct Product

end

struct Lane
    source::Node
    destination::Node
    unit_cost::Float64
    minimum_quantity::Float64
    time::Int

    function Lane(source, destination, unit_cost, minimum_quantity, time)
        return new(source, destination, unit_cost, minimum_quantity, time)
    end

    function Lane(source, destination, unit_cost, time)
        return new(source, destination, unit_cost, 0, time)
    end

    function Lane(source, destination, unit_cost)
        return new(source, destination, unit_cost, 0, 0)
    end
end

struct Customer <: Node
    demand::Dict{Product, Array{Float64, 1}}
    location::Location
end

struct Supplier <: Node
    price::Dict{Product, Float64}
    location::Location
end

struct Storage <: Node
    fixed_cost::Float64
    
    opening_cost::Float64
    closing_cost::Float64

    initial_opened::Bool
    initial_inventory::Dict{Product, Float64}

    location::Location
end

struct Production <: Node
    fixed_cost::Float64

    opening_cost::Float64
    closing_cost::Float64

    initial_opened::Bool

    bill_of_material::Dict{Product, Dict{Product, Float64}}
    unit_cost::Dict{Product, Float64}
    
    location::Location
end

struct SupplyChain
    horizon::Int
    products::Set{Product}
    storages::Set{Storage}
    suppliers::Set{Supplier}
    customers::Set{Customer}
    productions::Set{Production}
    lanes::Set{Lane}

    lanes_in::Dict{Node, Array{Lane, 1}}
    lanes_out::Dict{Node, Array{Lane, 1}}

    function SupplyChain(horizon=1)
        sc = new(horizon, 
                 Set{Product}(), 
                 Set{Storage}(),
                 Set{Supplier}(),
                 Set{Customer}(), 
                 Set{Production}(), 
                 Set{Lane}(), 
                 Dict{Node, Array{Lane, 1}}(), 
                 Dict{Node, Array{Lane, 1}}())
        return sc
    end
end

function add_product(supply_chain, product)
    push!(supply_chain.products, product)
    return product
end

function add_customer(supply_chain, customer)
    push!(supply_chain.customers, customer)
    return customer
end

function add_supplier(supply_chain, supplier)
    push!(supply_chain.suppliers, supplier)
    return supplier
end

function add_storage(supply_chain, storage)
    push!(supply_chain.storages, storage)
    return storage
end

function add_production(supply_chain, production)
    push!(supply_chain.productions, production)
    return production
end

function add_lane(supply_chain, lane)
    push!(supply_chain.lanes, lane)

    if !haskey(supply_chain.lanes_in, lane.destination)
        supply_chain.lanes_in[lane.destination] = Array{Lane, 1}()
    end
    push!(supply_chain.lanes_in[lane.destination] , lane)

    if !haskey(supply_chain.lanes_out, lane.source)
        supply_chain.lanes_out[lane.source] = Array{Lane, 1}()
    end
    push!(supply_chain.lanes_out[lane.source] , lane)
    return lane
end

function get_demand(customer, product, time)
    if(haskey(customer.demand, product))
        return customer.demand[product][time]
    else
        return 0
    end
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

function check_model(supply_chain)
    for production in supply_chain.productions
        for product in supply_chain.products
            if(haskey(production.bill_of_material, product) && !haskey(production.unit_cost, product)) || 
            (!haskey(production.bill_of_material, product) && haskey(production.unit_cost, product))
                throw(ArgumentError("Production $production must have the same produts in its BillOfMaterial and its UnitCost."))
            end
        end
    end
end

function create_optimization_model(supply_chain, optimizer)
    check_model(supply_chain)

    times = 1:supply_chain.horizon
    products = supply_chain.products
    customers = supply_chain.customers
    storages = supply_chain.storages
    suppliers = supply_chain.suppliers
    productions = supply_chain.productions
    productions_storages = union(productions, storages)
    lanes = supply_chain.lanes

    m = Model(optimizer)

    @variable(m, opened[productions_storages, times], Bin)
    @variable(m, opening[productions_storages, times], Bin)
    @variable(m, closing[productions_storages, times], Bin)

    @variable(m, bought[products, suppliers, times] >= 0)

    @variable(m, produced[products, productions, times] >= 0)

    @variable(m, stored_at_start[products, storages, times] >= 0)
    @variable(m, stored_at_end[products, storages, times] >= 0)

    @variable(m, sent[products, lanes, times] >= 0)
    @variable(m, received[products, lanes, times] >= 0)

    @constraint(m, [p=products, s=storages], stored_at_start[p, s, 1] == get!(s.initial_inventory, p, 0))

    @constraint(m, [p=products, l=lanes, t=times; t > l.time], received[p, l, t] == sent[p, l, t - l.time])
    @constraint(m, [p=products, l=lanes, t=times; t <= l.time], received[p, l, t] == 0)

    @constraint(m, [l=lanes, t=times], sum(sent[p, l, t] for p in products) >= l.minimum_quantity)

    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(sent[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) <= 1000000 * opened[s, t])
    #@constraint(m, [s=storages, t=times], !opened[s, t] => { sum(received[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) == 0 })
    @constraint(m, [s=storages, t=times], sum(received[p, l, t] for p in products, l in get_lanes_out(supply_chain, s)) <= 1000000 * opened[s, t])

    @constraint(m, [s=productions_storages], opening[s, 1] >= (opened[s, 1] - s.initial_opened))
    @constraint(m, [s=productions_storages, t=times; t > 1], opening[s, t] >= opened[s, t] - opened[s, t-1])

    @constraint(m, [s=productions_storages], closing[s, 1] >= -(opened[s, 1] - s.initial_opened))
    @constraint(m, [s=productions_storages, t=times; t > 1], closing[s, t] >= -(opened[s, t] - opened[s, t-1]))

    @constraint(m, [p=products, s=storages, t=times], stored_at_end[p, s, t] == stored_at_start[p, s, t] 
                                                                            + sum(received[p, l, t] for l in get_lanes_in(supply_chain, s))
                                                                            - sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s))
                                                                            )
    @constraint(m, [p=products, s=storages, t=times; t > 1], stored_at_start[p, s, t] == stored_at_end[p, s, t - 1])

    @constraint(m, [p=products, s=suppliers, t=times], bought[p, s, t] == sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))

    #@constraint(m, [p=products, s=productions, t=times], closed[s, t] => { produced[p, s, t] == 0 })
    @constraint(m, [p=products, s=productions, t=times], produced[p, s, t] <= 1000000 * opened[s, t])
    @constraint(m, [p=products, s=productions, t=times; !haskey(s.bill_of_material, p)], produced[p, s, t] == 0)
    @constraint(m, [p=products, s=productions, t=times], produced[p, s, t] == sum(sent[p, l, t] for l in get_lanes_out(supply_chain, s)))
    @constraint(m, [p=products, s=productions, t=times], sum(produced[p2, s, t] * get_bom(s, p2, p) for p2 in products) == sum(received[p, l, t] for l in get_lanes_in(supply_chain, s)))

    @constraint(m, [p=products, c=customers, t=times], sum(received[p, l, t] for l in get_lanes_in(supply_chain, c)) >= get_demand(c, p, t))

    @objective(m, Min, sum(sent[p, l, t] * l.unit_cost for p in products, l in lanes, t in times) + 
                       sum(opened[s, t] * s.fixed_cost for s in productions_storages, t in times) + 
                       sum(opening[s, t] * s.opening_cost for s in productions_storages, t in times) + 
                       sum(closing[s, t] * s.closing_cost for s in productions_storages, t in times) + 
                       sum(bought[p, s, t] * s.price[p] for p in products, s in suppliers, t in times if haskey(s.price, p)) +
                       sum(produced[p, s, t] * s.unit_cost[p] for p in products, s in productions, t in times if haskey(s.unit_cost, p)))

    return m
end

end # module
