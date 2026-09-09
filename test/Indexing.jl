@testset "Indexing - correctness" begin

# create_network_model declares opened/opening/closing/lost_sales/bought/produced/
# sent/serviced_by over integer ranges (get_product_index/get_storage_index/
# get_plant_index/get_supplier_index/get_customer_index/get_lane_index/
# get_plant_storage_index - see that function's own comment for why), instead of
# indexing them directly by the Product/Storage/Plant/Supplier/Customer/Lane
# objects. A bug that mixed up which integer position belongs to which
# facility/product wouldn't necessarily change the computed optimum on a fixture
# with only one plant/supplier or cost-symmetric storages/customers - every
# fixture elsewhere in this test suite is one of those. This one isn't: two
# fully parallel chains, distinctly costed (unit and fixed costs both ~10-100x
# apart) at every step, and uncapacitated, so any index mixup that routed even
# part of the flow through the "expensive" chain - or opened plant2/storage2
# unnecessarily - pushes the total well past 600, comfortably clear of the
# true optimum (routing everything through the cheap chain alone, with the
# expensive one fully closed).

@test begin
    f = create_model_asymmetric_multi_facility()
    SupplyChainOptimization.minimize_cost!(f.sc)

    get_total_costs(f.sc) < 600.0 &&
        # All flow through the cheap chain...
        get_shipments(f.sc, f.supplier1, f.raw, 1) == 100.0 &&
        get_production(f.sc, f.plant1, f.finished, 1) == 100.0 &&
        is_opened(f.sc, f.plant1, 1) &&
        is_opened(f.sc, f.storage1, 1) &&
        get_shipments(f.sc, f.storage1, f.finished, 1) == 100.0 &&
        # ...none through the expensive one.
        get_shipments(f.sc, f.supplier2, f.raw, 1) == 0.0 &&
        get_production(f.sc, f.plant2, f.finished, 1) == 0.0 &&
        !is_opened(f.sc, f.plant2, 1) &&
        !is_opened(f.sc, f.storage2, 1) &&
        get_shipments(f.sc, f.storage2, f.finished, 1) == 0.0
end

@test begin
    # Same fixture and expected routing under the :warm_start heuristic
    # (Heuristics.jl's own opened/opening/closing/serviced_by accesses go
    # through the same integer indices - see warm_start_from_relaxation!'s
    # fallback branch) - the heuristic only seeds the incumbent, so the final
    # objective on an instance this small must still land in the same range.
    f = create_model_asymmetric_multi_facility()
    SupplyChainOptimization.minimize_cost!(f.sc; heuristic=:warm_start)
    get_total_costs(f.sc) < 600.0
end

end

@testset "Indexing - model construction performance" begin

# A regression canary, not a tight benchmark: create_test_model6's default size
# (2 products, 1 supplier, 1 plant, 50 storages, 500 customers - ~25k lanes) is
# big enough that going back to struct-keyed (DenseAxisArray-backed)
# opened/opening/closing/lost_sales/bought/produced/sent/serviced_by would show
# up here as a large slowdown - see create_network_model's own comment for what
# those containers cost when indexed by anything other than a 1:n integer
# range. Measures model *construction* only (no optimizer time_limit involved,
# no solve) so it isolates exactly what the renumbering changed. The bound is
# deliberately generous so this stays green on a slow/loaded CI runner; it's
# meant to catch a gross regression, not to track incremental speedups (see
# benchmark/run_benchmarks.jl for that).

@test begin
    sc, product2, plant = create_test_model6()
    elapsed = @elapsed SupplyChainOptimization.create_network_cost_minimization_model!(sc, HiGHS.Optimizer)
    println("[performance] create_test_model6 model construction: $(round(elapsed; digits=2))s")
    elapsed < 30.0
end

end
