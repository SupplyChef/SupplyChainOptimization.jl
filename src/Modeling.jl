"""
The geographical location of a node of the supply chain. 
The location is defined by its latitude and longitude.
"""
struct Location
    latitude::Float64
    longitude::Float64
    name

    function Location(latitude, longitude)
        return new(latitude, longitude, nothing)
    end

    function Location(latitude, longitude, name)
        return new(latitude, longitude, name)
    end
end

"""
A node of the suppl chain.
"""
abstract type Node end

"""
A product.
"""
struct Product
    name::String

    function Product(name::String)
        return new(name)
    end
end

Base.:(==)(x::Product, y::Product) = x.name == y.name 
Base.:hash(x::Product) = hash(x.name)
show(io, x::Product) = print(io, x.name)

"""
A transportation lane between two nodes of the supply chain.
"""
struct Lane
    origin::Node
    destination::Node
    unit_cost::Float64
    minimum_quantity::Float64
    time::Int

    function Lane(origin, destination, unit_cost, minimum_quantity, time)
        return new(origin, destination, unit_cost, minimum_quantity, time)
    end

    function Lane(origin, destination, unit_cost, time)
        return new(origin, destination, unit_cost, 0, time)
    end

    function Lane(origin, destination, unit_cost)
        return new(origin, destination, unit_cost, 0, 0)
    end
end

"""
A customer.
"""
struct Customer <: Node
    name::String

    demand::Dict{Product, Array{Float64, 1}}
    location::Location

    function Customer(name::String, location::Location)
        return new(name, Dict{Product, Array{Float64, 1}}(), location)
    end
end

function add_product!(customer::Customer, product::Product; demand::Array{Float64, 1})
    customer.demand[product] = demand
end

Base.:(==)(x::Customer, y::Customer) = x.name == y.name 
Base.:hash(x::Customer) = hash(x.name)
show(io, x::Customer) = print(io, x.name)

"""
A supplier.
"""
struct Supplier <: Node
    name::String

    unit_cost::Dict{Product, Float64}

    maximum_throughput::Dict{Product, Float64}

    location::Location

    function Supplier(name::String, location::Location)
        return new(name, Dict{Product, Float64}(), Dict{Product, Float64}(), location)
    end
end

function add_product!(supplier::Supplier, product; unit_cost, maximum_throughput)
    supplier.unit_cost[product] = unit_cost
    supplier.maximum_throughput[product] = maximum_throughput
end

Base.:(==)(x::Supplier, y::Supplier) = x.name == y.name 
Base.:hash(x::Supplier) = hash(x.name)
show(io, x::Supplier) = print(io, x.name)

"""
A storage location.
"""
struct Storage <: Node
    name::String

    fixed_cost::Float64
    
    opening_cost::Float64
    closing_cost::Float64

    initial_opened::Bool
    initial_inventory::Dict{Product, Float64}

    unit_handling_cost::Dict{Product, Float64}

    maximum_throughput::Dict{Product, Float64}

    safety_stock_cover::Dict{Product, Float64}

    location::Location

    function Storage(name::String, fixed_cost::Float64, opening_cost::Float64, closing_cost::Float64, 
                     initial_opened::Bool,
                     location::Location)
        return new(name,
                   fixed_cost, opening_cost, closing_cost, 
                   initial_opened, 
                   Dict{Product, Float64}(), Dict{Product, Float64}(), Dict{Product, Float64}(), Dict{Product, Float64}(), 
                   location)
    end
end

function add_product!(storage::Storage, product; initial_inventory, unit_handling_cost, maximum_throughput, safety_stock_cover)
    storage.initial_inventory[product] = initial_inventory
    storage.unit_handling_cost[product] = unit_handling_cost
    storage.maximum_throughput[product] = maximum_throughput
    storage.safety_stock_cover[product] = safety_stock_cover
end

Base.:(==)(x::Storage, y::Storage) = x.name == y.name 
Base.:hash(x::Storage) = hash(x.name)
show(io, x::Storage) = print(io, x.name)

"""
A plant.
"""
struct Plant <: Node
    name::String

    fixed_cost::Float64

    opening_cost::Float64
    closing_cost::Float64

    initial_opened::Bool

    bill_of_material::Dict{Product, Dict{Product, Float64}}
    unit_cost::Dict{Product, Float64}

    maximum_throughput::Dict{Product, Float64}
    
    location::Location

    function Plant(name::String, fixed_cost::Float64, opening_cost::Float64, closing_cost::Float64, initial_opened::Bool, location::Location)
        return new(name, fixed_cost, opening_cost, closing_cost, initial_opened, Dict{Product, Dict{Product, Float64}}(), Dict{Product, Float64}(), Dict{Product, Float64}(), location)
    end
end

function add_product!(plant::Plant, product; bill_of_material::Dict{Product, Float64}, unit_cost, maximum_throughput)
    plant.bill_of_material[product] = bill_of_material
    plant.unit_cost[product] = unit_cost
    plant.maximum_throughput[product] = maximum_throughput
end

Base.:(==)(x::Plant, y::Plant) = x.name == y.name 
Base.:hash(x::Plant) = hash(x.name)
show(io, x::Plant) = print(io, x.name)

"""
The supply chain.
"""
mutable struct SupplyChain
    horizon::Int
    products::Set{Product}
    storages::Set{Storage}
    suppliers::Set{Supplier}
    customers::Set{Customer}
    plants::Set{Plant}
    lanes::Set{Lane}

    lanes_in::Dict{Node, Array{Lane, 1}}
    lanes_out::Dict{Node, Array{Lane, 1}}

    optimization_model

    function SupplyChain(horizon=1)
        sc = new(horizon, 
                 Set{Product}(), 
                 Set{Storage}(),
                 Set{Supplier}(),
                 Set{Customer}(), 
                 Set{Plant}(), 
                 Set{Lane}(), 
                 Dict{Node, Array{Lane, 1}}(), 
                 Dict{Node, Array{Lane, 1}}(),
                 nothing)
        return sc
    end
end

function add_product!(supply_chain, product)
    push!(supply_chain.products, product)
    return product
end

function add_customer!(supply_chain, customer)
    push!(supply_chain.customers, customer)
    return customer
end

function add_supplier!(supply_chain, supplier)
    push!(supply_chain.suppliers, supplier)
    return supplier
end

function add_storage!(supply_chain, storage)
    push!(supply_chain.storages, storage)
    return storage
end

function add_plant!(supply_chain, plant)
    push!(supply_chain.plants, plant)
    return plant
end

function add_lane!(supply_chain, lane)
    push!(supply_chain.lanes, lane)

    if !haskey(supply_chain.lanes_in, lane.destination)
        supply_chain.lanes_in[lane.destination] = Array{Lane, 1}()
    end
    push!(supply_chain.lanes_in[lane.destination] , lane)

    if !haskey(supply_chain.lanes_out, lane.origin)
        supply_chain.lanes_out[lane.origin] = Array{Lane, 1}()
    end
    push!(supply_chain.lanes_out[lane.origin] , lane)
    return lane
end
