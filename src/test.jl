using JuMP
using HiGHS

struct Product
    name::String
end

struct Facility
    name::String
    fixed_cost::Float64
end

struct Customer
    name::String
    demand::Dict{Product, Int64}
end

struct Lane
    facility::Facility
    customer::Customer
    unit_cost::Float64
    minimum::Int64
end

Base.:(==)(x::Product, y::Product) = x.name == y.name
Base.:(==)(x::Customer, y::Customer) = x.name == y.name
Base.:(==)(x::Facility, y::Facility) = x.name == y.name
Base.:(==)(x::Lane, y::Lane) = (x.customer == y.customer) && (x.facility == y.facility)

Base.:hash(x::Product) = hash(x.name)
Base.:hash(x::Customer) = hash(x.name)
Base.:hash(x::Facility) = hash(x.name)
Base.:hash(x::Lane) = hash(x.customer, hash(x.facility))

Base.:show(io::IOContext{IOBuffer}, x::Product) = print(io, "$(x.name)")
Base.:show(io::IOContext{IOBuffer}, x::Facility) = print(io, "$(x.name)")
Base.:show(io::IOContext{IOBuffer}, x::Customer) = print(io, "$(x.name)")
Base.:show(io::IOContext{IOBuffer}, x::Lane) = print(io, "$(x.facility.name) $(x.customer.name)")

function create_model()
    m = Model(HiGHS.Optimizer, bridge_constraints=false)

    customer_count = 1000
    facility_count = 500

    products = Set([Product("p1")])
    facilities = Set([Facility("f$i", rand(10000:50000)) for i in 1:facility_count])
    customers = Set([Customer("c$i", Dict{Product, Int}(p => rand(1:100))) for i in 1:customer_count, p in products])
    lanes = Set([Lane(f, c, rand(1:100), rand(0:1)) for f in facilities, c in customers])

    #@variable(m, 0 <= opened[facilities] <= 1, Int)
    @variable(m, opened[facilities], Bin)
    @variable(m, sent[products,lanes] >= 0)
    #@variable(m, 0 <= used[lanes] <= 1, Int)
    @variable(m, used[lanes], Bin)

    @constraint(m, [p=products,c=customers], sum(sent[p, l] for l in lanes if l.customer == c) >= c.demand[p])
    @constraint(m, [p=products,f=facilities], sum(sent[p, l] for l in lanes if l.facility == f) <= 1_000_000 * opened[f])
    @constraint(m, [l=lanes], sum(sent[p, l] for p in products) >= l.minimum * used[l])
    @constraint(m, [l=lanes], sum(sent[p, l] for p in products) <= 1_000_000 * used[l])

    @objective(m, Min, sum(f.fixed_cost * opened[f] for f in facilities) + sum(l.unit_cost * sent[p, l] for l in lanes, p in products))

    return m
end

m = create_model()
#optimize!(m)
