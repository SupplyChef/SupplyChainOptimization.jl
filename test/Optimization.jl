function create_model_two_storages_single_source()
    #storage1, storage2 -> customer (equal cost - either is optimal without single-sourcing)
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)

    c = Customer("c1", Seattle)
    add_customer!(sc, c)
    add_demand!(sc, c, product, [100.0])

    s1 = Storage("s1", Seattle; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
    add_storage!(sc, s1)
    add_product!(s1, product; initial_inventory=1000)
    add_lane!(sc, Lane(s1, c; unit_cost=1.0))

    s2 = Storage("s2", Seattle; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
    add_storage!(sc, s2)
    add_product!(s2, product; initial_inventory=1000)
    add_lane!(sc, Lane(s2, c; unit_cost=1.0))

    return sc, s1, s2, product
end

@testset "Optimization - bigM tightening" begin

# The big-M tightening in create_network_model (effective_bigM) must never cut off
# a feasible/optimal solution - these fixtures each exercise a bigM site that
# UFLlib.jl's single-period, single-product, no-production/no-fixed-lane-cost
# instances never touch: single-sourcing (line ~89), lane fixed_cost (line ~100),
# and production/BOM (line ~146).

@test begin
    # single_source forces exactly one storage to serve the customer even though,
    # without it, splitting flow across both storages at equal cost would also be
    # optimal - this only holds if the tightened bigM at the serviced_by-linking
    # constraint doesn't itself block the single-sourced solution.
    sc, s1, s2, product = create_model_two_storages_single_source()
    SupplyChainOptimization.minimize_cost!(sc; single_source=true)
    q1 = get_shipments(sc, s1, product, 1)
    q2 = get_shipments(sc, s2, product, 1)
    get_total_costs(sc) ≈ 100.0 &&
        ((q1 ≈ 100.0 && q2 ≈ 0.0) || (q1 ≈ 0.0 && q2 ≈ 100.0))
end

@test begin
    # create_model_plant_storage_customer's lane into the storage has a fixed_cost,
    # which is what exercises the `used`-linking bigM site - confirm the known
    # expected cost from the "Happy Path" testset is unaffected by the tightened bound.
    sc = create_model_plant_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_costs(sc) == 3410
end

@test begin
    # create_test_model4 has a plant with a BOM (product1 -> product2), which is
    # what exercises the `produced`-linking bigM site.
    sc, product2, plant = create_test_model4()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_costs(sc) == 3400 && get_production(sc, plant, product2, 1) == 100
end

@test begin
    # An explicitly larger custom bigM must give the same optimum as the default -
    # tightening only ever narrows the bound towards the same feasible region.
    sc = create_model_plant_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc; bigM=1_000_000_000)
    get_total_costs(sc) == 3410
end

end
