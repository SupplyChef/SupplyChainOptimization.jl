# Synthetic multi-period capacitated network design instances, sized to actually
# stress HiGHS's primal heuristics - unlike test/UFLlib.jl (single-period,
# single-product, no capacities, no lane fixed costs), these are meant to *not*
# close to zero gap in a handful of seconds, so gap-at-timeout is something to
# compare across tiers/heuristics in the first place. Extends the same pattern
# test/Models.jl's create_test_model6 already used for its "Scaling" test, adding
# per-storage capacity (maximum_throughput) and lane fixed costs (both drive the
# bigM-linked constraints tightened in src/Optimization.jl) plus randomized costs
# (a fully symmetric cost structure makes ties trivial to "solve" and hides gap
# behavior).
#
# Run standalone: `julia --project=. benchmark/generate_instance.jl` just
# smoke-tests instance construction; see run_benchmarks.jl for actual solves.

using SupplyChainModeling
using Random

"""
    generate_instance(; horizon, customer_count, storage_count, plant_count,
                         storage_capacity, seed)

`supplier(s) -> plant(s) -> storage(s) -> customer(s)`, one product, multi-period.
`plant_count` plants each produce the single product from a raw input bought from
a dedicated supplier (so a BOM/production bigM site is exercised too). Every
storage has finite `maximum_throughput` and every storage->customer lane has a
`fixed_cost`, so both tightened bigM sites (see src/Optimization.jl) are active.
"""
function generate_instance(; horizon=12, customer_count=150, storage_count=30, plant_count=3,
                              storage_capacity=400.0, seed=42)
    rng = Random.MersenneTwister(seed)
    sc = SupplyChain(horizon)

    raw = add_product!(sc, Product("raw"))
    finished = add_product!(sc, Product("finished"))

    plants = Plant[]
    for i in 1:plant_count
        supplier = add_supplier!(sc, Supplier("supplier$i", Location(0, 0)))
        add_product!(supplier, raw; unit_cost=1.0 + rand(rng), maximum_throughput=Inf)

        plant = add_plant!(sc, Plant("plant$i", Location(0, 0);
            fixed_cost=5_000.0, opening_cost=20_000.0, closing_cost=20_000.0, initial_opened=(i == 1)))
        add_product!(plant, finished; bill_of_material=Dict(raw => 1.0), unit_cost=2.0 + rand(rng),
            maximum_throughput=storage_capacity * 5)
        add_lane!(sc, Lane(supplier, plant; unit_cost=0.5 + 0.2 * rand(rng)))
        push!(plants, plant)
    end

    storages = Storage[]
    for i in 1:storage_count
        storage = add_storage!(sc, Storage("storage$i", Location(0, 0);
            fixed_cost=1_000.0 + 500.0 * rand(rng), opening_cost=8_000.0, closing_cost=8_000.0, initial_opened=false))
        add_product!(storage, finished; unit_holding_cost=0.05, maximum_throughput=storage_capacity)
        for plant in plants
            add_lane!(sc, Lane(plant, storage; unit_cost=0.3 + 0.3 * rand(rng)))
        end
        push!(storages, storage)
    end

    for i in 1:customer_count
        customer = add_customer!(sc, Customer("customer$i", Location(0, 0)))
        demand = [30.0 + 40.0 * rand(rng) for _ in 1:horizon]
        add_demand!(sc, customer, finished, demand; service_level=0.95)
        for storage in storages
            add_lane!(sc, Lane(storage, customer; unit_cost=0.2 + 0.8 * rand(rng), fixed_cost=50.0))
        end
    end

    return sc
end

if abspath(PROGRAM_FILE) == @__FILE__
    sc = generate_instance(; horizon=4, customer_count=10, storage_count=5, plant_count=1)
    println("Built instance: $(length(sc.customers)) customers, $(length(sc.storages)) storages, $(length(sc.plants)) plants, horizon=$(sc.horizon)")
end
