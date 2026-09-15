function create_model_supplier_storage_customer_tariff(; rate=0.2, register_tariff=true)
    #supplier (CN) -> storage (US) -> customer (US), unit_cost=10 at the supplier
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)

    us = Location(47.608013, -122.335167; country="US")
    cn = Location(31.230416, 121.473701; country="CN")

    c = Customer("c1", us)
    add_customer!(sc, c)
    add_demand!(sc, c, product, [100.0])

    storage = Storage("s1", us; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
    add_storage!(sc, storage)
    add_product!(storage, product)

    supplier = Supplier("supplier1", cn)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=10.0, maximum_throughput=Inf)

    add_lane!(sc, Lane(storage, c; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, storage; unit_cost=1.0))

    if register_tariff
        add_tariff!(sc, Tariff("CN", "US", rate))
    end

    return sc, product, supplier, storage
end

function create_model_supplier_storage_reexport_tariff(; rate=0.3, register_tariff=true)
    #supplier (CN) -> storage (US, no CN->US tariff) -> customer (DE, tariffed re-export)
    sc = SupplyChain()

    product = Product("p1")
    add_product!(sc, product)

    us = Location(47.608013, -122.335167; country="US")
    cn = Location(31.230416, 121.473701; country="CN")
    de = Location(52.520008, 13.404954; country="DE")

    c = Customer("c1", de)
    add_customer!(sc, c)
    add_demand!(sc, c, product, [100.0])

    storage = Storage("s1", us; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
    add_storage!(sc, storage)
    add_product!(storage, product)

    supplier = Supplier("supplier1", cn)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=10.0, maximum_throughput=Inf)

    add_lane!(sc, Lane(storage, c; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, storage; unit_cost=1.0))

    if register_tariff
        add_tariff!(sc, Tariff("CN", "DE", rate))
    end

    return sc, product, supplier, storage
end

@testset "Tariffs" begin

@test begin
    # 100 units bought at unit_cost=10 from a CN supplier, tariffed 20% into the US:
    # tariff cost = 0.2 * 10.0 * 100 = 200, on top of the untariffed 1200
    # (buying 1000 + the two unit_cost=1.0 lanes' transportation 100 each) from
    # create_model_supplier_storage_customer in Profits.jl.
    sc, product, supplier, storage = create_model_supplier_storage_customer_tariff()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_tariff_costs(sc) == 200.0 &&
        get_total_costs(sc) == 1000.0 + 100.0 + 100.0 + 200.0 &&
        get_shipments(sc, supplier, product, 1) == 100.0
end

@test begin
    # A registered tariff with rate 0.0 costs nothing - same total as no tariff at all.
    sc_zero, _, _, _ = create_model_supplier_storage_customer_tariff(; rate=0.0)
    sc_none, _, _, _ = create_model_supplier_storage_customer_tariff(; register_tariff=false)
    SupplyChainOptimization.minimize_cost!(sc_zero)
    SupplyChainOptimization.minimize_cost!(sc_none)
    get_total_tariff_costs(sc_zero) == 0.0 &&
        get_total_costs(sc_zero) == get_total_costs(sc_none)
end

@test begin
    # No countries assigned anywhere in the network: existing (pre-tariff) models
    # must solve identically to before this feature existed.
    sc, _, _ = create_model_supplier_storage_customer()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_tariff_costs(sc) == 0.0 &&
        get_total_costs(sc) == 1000 + 500 + 200
end

@test begin
    # No CN->US tariff is registered on the inbound leg, only CN->DE on the storage's
    # re-export leg - this exercises the stored_by_origin overlay (Storage isn't a
    # Plant/Supplier, so it can't be priced by _tariff_unit_cost alone). With only one
    # supplying country in the whole network there's no ambiguity for the solver to
    # exploit: every unit re-exported must be tagged CN, so the tariff is forced to
    # 0.3 * 10.0 (CN's declared value) * 100 = 300, on top of the untariffed 1200
    # (buying 1000 + the two unit_cost=1.0 lanes' transportation 100 each).
    sc, product, supplier, storage = create_model_supplier_storage_reexport_tariff()
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_tariff_costs(sc) == 300.0 &&
        get_total_costs(sc) == 1000.0 + 100.0 + 100.0 + 300.0
end

@test begin
    # Same shape, but with no tariff registered at all - the stored_by_origin overlay
    # must be a true no-op (0 tariff cost, same total as the untariffed baseline) when
    # a supply chain doesn't use tariffs, not just when it has no cross-border flow.
    sc, product, supplier, storage = create_model_supplier_storage_reexport_tariff(; register_tariff=false)
    SupplyChainOptimization.minimize_cost!(sc)
    get_total_tariff_costs(sc) == 0.0 &&
        get_total_costs(sc) == 1000.0 + 100.0 + 100.0
end

end
