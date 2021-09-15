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
A node of the supply chain.
"""
abstract type Node 
end

"""
A product.
"""
struct Product
    name::String
    unit_holding_cost::Float64

    """
    Creates a new product.
    """
    function Product(name::String; unit_holding_cost::Float64=0.0)
        return new(name, unit_holding_cost)
    end
end

Base.:(==)(x::Product, y::Product) = x.name == y.name 
Base.hash(x::Product, h::UInt64) = hash(x.name, h)
Base.show(io::IO, x::Product) = print(io, x.name)

"""
A transportation lane between two nodes of the supply chain.
"""
struct Lane
    origin::Node
    destination::Node
    unit_cost::Float64
    minimum_quantity::Float64
    time::Int

    function Lane(origin, destination; unit_cost=0.0, minimum_quantity=0.0, time::Int=0)
        return new(origin, destination, unit_cost, minimum_quantity, time)
    end
end

"""
A customer.
"""
struct Customer <: Node
    name::String

    location::Location

    function Customer(name::String, location::Location)
        return new(name, location)
    end
end

"""
    add_product!(customer::Customer, product::Product; demand::Array{Float64, 1})

Indicates that a customer needs a product.

The keyword arguments are:
 - `demand`: the amount of unit of product needed for each time period.

"""
function add_product!(customer::Customer, product::Product; demand::Array{Float64, 1})
    customer.demand[product] = demand
end

Base.:(==)(x::Customer, y::Customer) = x.name == y.name 
Base.hash(x::Customer, h::UInt64) = hash(x.name, h)
Base.show(io::IO, x::Customer) = print(io, x.name)

"""
A supplier.
"""
struct Supplier <: Node
    name::String

    unit_cost::Dict{Product, Float64}

    maximum_throughput::Dict{Product, Float64}

    location::Location

    """
    Creates a new supplier.
    """
    function Supplier(name::String, location::Location)
        return new(name, Dict{Product, Float64}(), Dict{Product, Float64}(), location)
    end
end

"""
    add_product!(supplier::Supplier, product::Product; unit_cost::Float64, maximum_throughput::Float64)

Indicates that a supplier can provide a product.

The keyword arguments are:
 - `unit_cost`: the cost per unit of the product from this supplier.
 - `maximum_throughput`: the maximum number of units that can be provided in each time period.

"""
function add_product!(supplier::Supplier, product; unit_cost::Real, maximum_throughput::Real=Inf)
    supplier.unit_cost[product] = unit_cost
    supplier.maximum_throughput[product] = maximum_throughput
end

Base.:(==)(x::Supplier, y::Supplier) = x.name == y.name 
Base.hash(x::Supplier, h::UInt64) = hash(x.name, h)
Base.show(io::IO, x::Supplier) = print(io, x.name)

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

    additional_stock_cover::Dict{Product, Float64}

    location::Location

    """
    Creates a new storage location.
    """
    function Storage(name::String, location::Location; fixed_cost::Real=0.0, opening_cost::Real=0.0, closing_cost::Real=Inf, 
                     initial_opened::Bool=true)
        return new(name,
                   fixed_cost, opening_cost, closing_cost, 
                   initial_opened, 
                   Dict{Product, Float64}(), Dict{Product, Float64}(), Dict{Product, Float64}(), Dict{Product, Float64}(), 
                   location)
    end
end

function add_product!(storage::Storage, product; initial_inventory::Union{Real, Nothing}=0, unit_handling_cost::Real=0, maximum_throughput::Real=Inf, additional_stock_cover::Real=0.0)
    if !isnothing(initial_inventory)
        storage.initial_inventory[product] = initial_inventory
    end
    storage.unit_handling_cost[product] = unit_handling_cost
    storage.maximum_throughput[product] = maximum_throughput
    storage.additional_stock_cover[product] = additional_stock_cover
end

Base.:(==)(x::Storage, y::Storage) = x.name == y.name 
Base.hash(x::Storage, h::UInt64) = hash(x.name, h)
Base.show(io::IO, x::Storage) = print(io, x.name)

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
    time::Dict{Product, Int}

    maximum_throughput::Dict{Product, Float64}
    
    location::Location

    """
    Creates a new plant.
    """
    function Plant(name::String, location::Location; fixed_cost::Real=0.0, opening_cost::Real=0.0, closing_cost::Real=Inf, initial_opened::Bool=true)
        return new(name, fixed_cost, opening_cost, closing_cost, initial_opened, Dict{Product, Dict{Product, Float64}}(), Dict{Product, Float64}(), Dict{Product, Float64}(), Dict{Product, Float64}(), location)
    end
end

"""
    add_product!(plant::Plant, product::Product; bill_of_material::Dict{Product, Float64}, unit_cost, maximum_throughput)

Indicates that a plant can produce a product.

The keyword arguments are:
 - `bill_of_material`: the amount of other product needed to produce one unit of the product. This dictionary can be empty if there are no other products needed.
 - `unit_cost`: the cost of producing one unit of product.
 - `maximum_throughput`: the maximum amount of product that can be produced in a time period.
 - `time`: the production lead time.

"""
function add_product!(plant::Plant, product; bill_of_material::Dict{Product, Float64}, unit_cost, maximum_throughput::Real=Inf, time::Int=0)
    plant.bill_of_material[product] = bill_of_material
    plant.unit_cost[product] = unit_cost
    plant.maximum_throughput[product] = maximum_throughput
    plant.time[product] = time
end

Base.:(==)(x::Plant, y::Plant) = x.name == y.name 
Base.hash(x::Plant, h::UInt64) = hash(x.name, h)
Base.show(io::IO, x::Plant) = print(io, x.name)

"""
The demand a customer has for a product.
"""
struct Demand
    customer::Customer
    product::Product
    probability::Float64
    demand::Array{Float64, 1}
    service_level::Float64

    function Demand(customer::Customer, product::Product, demand::Array{Float64, 1}, service_level)
        return new(customer, product, 1.0, demand, service_level)
    end
end

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
    demand::Set{Demand}

    lanes_in::Dict{Node, Array{Lane, 1}}
    lanes_out::Dict{Node, Array{Lane, 1}}

    optimization_model

    """
    Creates a new supply chain.
    """
    function SupplyChain(horizon=1)
        sc = new(horizon, 
                 Set{Product}(), 
                 Set{Storage}(),
                 Set{Supplier}(),
                 Set{Customer}(), 
                 Set{Plant}(), 
                 Set{Lane}(), 
                 Set{Demand}(),
                 Dict{Node, Array{Lane, 1}}(), 
                 Dict{Node, Array{Lane, 1}}(),
                 nothing)
        return sc
    end
end

"""
    add_demand!(supply_chain, customer, product; demand::Array{Float64, 1}, service_level=1.0)

Adds customer demand for a product. The demand is specified for each time period.

The keyword arguments are:
 - `demand`: the amount of product demanded for each time period.
 - `service_level`: indicates how many lost sales are allowed as a ratio of demand. No demand can be lost if the service level is 1.0 and all demand can be lost if the service level is 0.0. 

"""
function add_demand!(supply_chain, customer, product; demand::Array{Float64, 1}, service_level=1.0)
    if service_level < 0.0 || service_level > 1.0
        throw(DomainError("service_level must be between 0.0 and 1.0 inclusive"))
    end
    add_demand!(supply_chain, Demand(customer, product, demand, service_level))
end

"""
    add_demand!(supply_chain, demand)

Adds demand to the supply chain.
"""
function add_demand!(supply_chain, demand)
    push!(supply_chain.demand, demand)
end

"""
    add_product!(supply_chain, product)

Adds a product to the supply chain.
"""
function add_product!(supply_chain, product)
    push!(supply_chain.products, product)
    return product
end

"""
    add_customer!(supply_chain, customer)

Adds a customer to the supply chain.
"""
function add_customer!(supply_chain, customer)
    push!(supply_chain.customers, customer)
    return customer
end

"""
    add_supplier!(supply_chain, supplier)

Adds a supplier to the supply chain.
"""
function add_supplier!(supply_chain, supplier)
    push!(supply_chain.suppliers, supplier)
    return supplier
end

"""
    add_storage!(supply_chain, storage)

Adds a storage location to the supply chain.
"""
function add_storage!(supply_chain, storage)
    push!(supply_chain.storages, storage)
    return storage
end

"""
    add_plant!(supply_chain, plant)

Adds a plant to the supply chain.
"""
function add_plant!(supply_chain, plant)
    push!(supply_chain.plants, plant)
    return plant
end

"""
    add_lane!(supply_chain, lane)

Adds a transportation lane to the supply chain.
"""
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
