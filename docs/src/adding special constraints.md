# Adding Special Constraints
SupplyChainOptimization contains many built-in concepts that enable the modeling of many scenarios. In some special cases specific constraints may need to be considered that are not part of the built-in concepts. SupplyChainOptimization allows for the direct manipulation of the optimization model to add these constraints.

!!! warning "Beware!"

    Directly manipulating the optimization model requires advanced mathematical modeling knowledge and is not recommended unless absolutely necessary.

When the `optimize_network!` function is called it calls two other functions: `create_network_optimization_model!` and `optimize_network_optimization_model!`.
`create_network_optimization_model!` creates an optimization model and stores it in the supply chain `optimization_model` attribute (see [Optimization Model](@ref)). This process is seamless and usually operates behind the scene. However there are cases where knowning about this process can be helpful. One such case is if a specific constraint needs to be added to the optimization model. 

In the example below we will use the same setup as in the multi-period network optimization example (see [Multi-period Optimization](@ref)).
The one difference is that we now want to control how many nodes can be opened in each time period. Such a constraint may be needed in real-life because the real-estate team, labor team or supply management team cannot handle too many opening at the same time. We will modify the usual call to the optimizer and break it into three parts: the creation of the optimization model, the addition of the constraint on openings, the call to the optimizer.

```
SupplyChainOptimization.create_network_optimization_model!(sc, HiGHS.Optimizer)

@constraint(sc.optimization_model, sum(sc.optimization_model[:opening][:,1]) == 2)
@constraint(sc.optimization_model, sum(sc.optimization_model[:opening][:,2]) == 1)
@constraint(sc.optimization_model, sum(sc.optimization_model[:opening][:,3]) == 1)

SupplyChainOptimization.optimize_network_optimization_model!(sc)
```

In the first period we allow two opening (we need at least a plant and a storage location). In the subsequent periods, we allow one opening per period. A list of available variables in the optimization model is provided in the [Optimization Model](@ref) section.

The full code is as below. Notice the use of JuMP, the optimization library, to add the additional constraints.

```
using CSV
using DataFrames
using JuMP
using HiGHS
using SupplyChainModeling
using SupplyChainOptimization


nm = tempname()
url = "https://raw.githubusercontent.com/plotly/datasets/master/2014_us_cities.csv"
download(url, nm)
us_cities = CSV.read(nm, DataFrame)
rm(nm)

sort!(us_cities, [:pop], rev=true)

sc = SupplyChain(3)

product1 = Product("Product 1")
product2 = Product("Product 2")
add_product!(sc, product1)
add_product!(sc, product2)

for r in eachrow(first(us_cities, 10))
    supplier = Supplier("Supplier $(r.name)", Location(r.lat + 0.2, r.lon - 0.2, r.name))
    add_product!(supplier, product1; unit_cost=1.0)
    add_supplier!(sc, supplier)
end

for r in eachrow(first(us_cities, 10))
    plant = Plant("Plant $(r.name)", Location(r.lat - 0.2, r.lon - 0.2, r.name); 
            fixed_cost= 6_000_000 + r.pop / 2, 
            initial_opened=false)
    add_product!(plant, product2; bill_of_material=Dict{Product, Float64}(product1 => 1.0), unit_cost=1.0)
    add_plant!(sc, plant)
end

for r in eachrow(first(us_cities, 10))
    storage = Storage("Storage $(r.name)", Location(r.lat + 0.2, r.lon + 0.2, r.name); 
            fixed_cost= 2_000_000 + r.pop / 2, 
            initial_opened=false)
    add_product!(storage, product2; initial_inventory=0, unit_holding_cost=0.01)
    add_storage!(sc, storage)
end

for (i, r) in enumerate(eachrow(first(us_cities, 100)))
    customer = Customer("customer $i", Location(r.lat, r.lon, r.name))
    add_customer!(sc, customer)
    add_demand!(sc, customer, product2; demand=[r.pop / 8_000 for i in 1:3])
end

for s in sc.suppliers, p in sc.plants
    add_lane!(sc, Lane(s, p; unit_cost=haversine(s.location, p.location) / 750))
end

for p in sc.plants, s in sc.storages
    add_lane!(sc, Lane(p, s; unit_cost=haversine(p.location, s.location) / 750))
end

for c in sc.customers, s in sc.storages
    add_lane!(sc, Lane(s, c; unit_cost=haversine(s.location, c.location) / 250))
end

SupplyChainOptimization.create_network_optimization_model!(sc, HiGHS.Optimizer)

@constraint(sc.optimization_model, sum(sc.optimization_model[:opening][:,1]) == 2)
@constraint(sc.optimization_model, sum(sc.optimization_model[:opening][:,2]) == 1)
@constraint(sc.optimization_model, sum(sc.optimization_model[:opening][:,3]) == 1)

SupplyChainOptimization.optimize_network_optimization_model!(sc)
```