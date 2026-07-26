# Matheuristics

Large, real-world instances of either [`minimize_cost!`](@ref)/[`maximize_profits!`](@ref)'s
network design problem or [`create_maturation_scheduling_model`](@ref)'s scheduling problem can
be too slow to solve to proven optimality directly. [`matheuristic_optimize!`](@ref) is a
generic large-neighborhood-search matheuristic that works on *any* solved JuMP model - it
repeatedly pins most integer/binary variables to their current best values, re-optimizes the
rest, and keeps any improvement.

```julia
using SupplyChainModeling
using SupplyChainOptimization

sc = SupplyChain(1)

product = Product("Product 1")
add_product!(sc, product)

customer = Customer("Customer 1", Location(47.6, -122.3))
add_customer!(sc, customer)
add_demand!(sc, customer, product, [100.0])

storage = Storage("Storage 1", Location(47.6, -122.3); fixed_cost=1000.0, initial_opened=true)
add_product!(storage, product; initial_inventory=100.0)
add_storage!(sc, storage)

add_lane!(sc, Lane(storage, customer; unit_cost=1.0))

minimize_cost!(sc; time_limit=30.0)  # a first, possibly time-limited solve

matheuristic_optimize!(sc.optimization_model; iterations=200, fix_fraction=0.9)

get_total_costs(sc)
```

It applies equally to the maturation-scheduling model:

```julia
m = create_maturation_scheduling_model(sc; transport_cost_per_distance=1.0)
JuMP.optimize!(m)
matheuristic_optimize!(m; iterations=200, neighborhood=:local_branching, local_branching_k=20)
```

This is a model-agnostic default, not a replacement for a problem-aware heuristic: it has no
idea what a `y` or `r` variable means, only that some of them are integer/binary. A hand-tuned,
domain-aware neighborhood - like the clustering-and-relatedness matheuristic in the IPPDP paper
this package's maturation-scheduling model is based on (Gbéya, Darvish, Renaud and Coelho (2026),
CIRRELT-2026-10) - will typically still beat this on any one problem. Reach for
[`matheuristic_optimize!`](@ref) as a solid starting point on a large instance, or when writing a
problem-specific search isn't (yet) worth the investment.
