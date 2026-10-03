# Lane.lead_times: lead time by departure period, so a shipment's arrival
# period depends on when it departs. supplier -> storage (lane "ls") -> customer;
# only period 3 has demand (10 units), so the storage has to be supplied by then.
function create_model_lead_times(; lead_times=nothing, horizon=4, time=2)
    sc = SupplyChain(horizon)
    product = Product("p1")
    add_product!(sc, product)

    customer = Customer("c1", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product, [t == 3 ? 10.0 : 0.0 for t in 1:horizon]; lost_sales_cost=100.0, service_level=0.0)

    storage = Storage("s1", Seattle; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
    add_storage!(sc, storage)
    add_product!(storage, product)

    supplier = Supplier("supplier1", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=0.0, maximum_throughput=Inf)

    ls = Lane(supplier, storage; id="ls", unit_cost=1.0, time=time, lead_times=lead_times)
    add_lane!(sc, ls)
    add_lane!(sc, Lane(storage, customer; unit_cost=0.0))
    return sc, product, ls
end

@testset "Lead times by departure period" begin
    # Nominal: a shipment takes 2 periods, so the one needed at 3 leaves at 1.
    @test begin
        sc, product, ls = create_model_lead_times()
        SupplyChainOptimization.minimize_cost!(sc)
        isapprox(get_shipments(sc, ls, product, 1), 10.0; atol=1e-6) &&
            isapprox(get_shipments(sc, ls, product, 2), 0.0; atol=1e-6) &&
            isapprox(get_total_costs(sc), 10.0; atol=1e-6)
    end

    # A shipment leaving at 1 takes 3 periods (too late) while one leaving at 2 takes 1: ship at 2.
    @test begin
        sc, product, ls = create_model_lead_times(lead_times=[3, 1, 1, 1])
        SupplyChainOptimization.minimize_cost!(sc)
        isapprox(get_shipments(sc, ls, product, 1), 0.0; atol=1e-6) &&
            isapprox(get_shipments(sc, ls, product, 2), 10.0; atol=1e-6) &&
            isapprox(get_total_costs(sc), 10.0; atol=1e-6)
    end

    # Overtaking: departures at 1 and 2 both arrive at 3, so the supply can come from either.
    @test begin
        sc, product, ls = create_model_lead_times(lead_times=[2, 1, 1, 1])
        SupplyChainOptimization.minimize_cost!(sc)
        isapprox(get_shipments(sc, ls, product, 1) + get_shipments(sc, ls, product, 2), 10.0; atol=1e-6) &&
            isapprox(get_total_costs(sc), 10.0; atol=1e-6)
    end

    # Every departure arrives too late (or after the horizon): nothing ships and the demand is lost.
    @test begin
        sc, product, ls = create_model_lead_times(lead_times=[3, 3, 3, 3])
        SupplyChainOptimization.minimize_cost!(sc)
        isapprox(get_shipments(sc, ls, product, 1), 0.0; atol=1e-6) &&
            isapprox(get_shipments(sc, ls, product, 2), 0.0; atol=1e-6) &&
            isapprox(sum(get_lost_sales(sc, c, product, t) for c in sc.customers, t in 1:4), 10.0; atol=1e-6)
    end

    # lead_times equal to the nominal time give the nominal model's answer.
    @test begin
        sc, product, ls = create_model_lead_times(lead_times=[2, 2, 2, 2])
        SupplyChainOptimization.minimize_cost!(sc)
        isapprox(get_shipments(sc, ls, product, 1), 10.0; atol=1e-6) && isapprox(get_total_costs(sc), 10.0; atol=1e-6)
    end

    # Lanes with several destinations are not supported yet.
    @test_throws ArgumentError begin
        sc = SupplyChain(2)
        product = Product("p1")
        add_product!(sc, product)
        supplier = Supplier("supplier1", Seattle)
        add_supplier!(sc, supplier)
        add_product!(supplier, product; unit_cost=0.0)
        s1 = Storage("s1", Seattle); s2 = Storage("s2", Seattle)
        add_storage!(sc, s1); add_storage!(sc, s2)
        add_product!(s1, product); add_product!(s2, product)
        add_lane!(sc, Lane(supplier, [s1, s2]; times=[1, 1], lead_times=[[1, 1], [1, 1]]))
        SupplyChainOptimization.minimize_cost!(sc)
    end
    # Tariffs are tracked by origin along storage-to-storage hops too (stored_by_origin overlay), so
    # lead_times on such a lane must give the same costs as the equivalent nominal lane.
    function tariff_costs(; time=1, lead_times=nothing)
        sc = SupplyChain(3)
        product = Product("p1")
        add_product!(sc, product)
        us = Location(47.608013, -122.335167; country="US")
        cn = Location(31.230416, 121.473701; country="CN")
        de = Location(52.520008, 13.404954; country="DE")
        customer = Customer("c1", de)
        add_customer!(sc, customer)
        add_demand!(sc, customer, product, [0.0, 0.0, 100.0])
        s1 = Storage("s1", us; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
        s2 = Storage("s2", us; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
        add_storage!(sc, s1); add_storage!(sc, s2)
        add_product!(s1, product); add_product!(s2, product)
        supplier = Supplier("supplier1", cn)
        add_supplier!(sc, supplier)
        add_product!(supplier, product; unit_cost=10.0, maximum_throughput=Inf)
        add_lane!(sc, Lane(supplier, s1; unit_cost=1.0))
        add_lane!(sc, Lane(s1, s2; id="mid", unit_cost=1.0, time=time, lead_times=lead_times))
        add_lane!(sc, Lane(s2, customer; unit_cost=1.0))
        add_tariff!(sc, Tariff("CN", "DE", 0.3))
        SupplyChainOptimization.minimize_cost!(sc)
        return get_total_tariff_costs(sc), get_total_costs(sc)
    end
    @test begin
        nominal = tariff_costs()
        nominal[1] == 300.0 &&
            tariff_costs(lead_times=[1, 1, 1]) == nominal &&
            tariff_costs(lead_times=[2, 1, 1]) == nominal      # departures 1 and 2 both arrive at 3
    end
end
