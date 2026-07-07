using Statistics

@testset "GSM" begin

@test begin
    # Reference values for the standard normal quantile function, checked against
    # well-known textbook z-scores, to catch any transcription error in the Acklam
    # rational-approximation coefficients.
    isapprox(SupplyChainOptimization._standard_normal_quantile(0.5), 0.0; atol=1e-6) &&
    isapprox(SupplyChainOptimization._standard_normal_quantile(0.975), 1.959963985; atol=1e-6) &&
    isapprox(SupplyChainOptimization._standard_normal_quantile(0.95), 1.644853627; atol=1e-6) &&
    isapprox(SupplyChainOptimization._standard_normal_quantile(0.90), 1.281551566; atol=1e-6)
end

@test begin
    # Serial chain Supplier -> DC -> Customer, single feasible outgoing service time at DC
    # (maximum_customer_wait=0 and DC's own lead time forces S_DC=0), so this mainly checks
    # the basic plumbing (sigma from demand variance, service-time propagation, safety
    # stock formula) rather than a real optimization choice.
    product = Product("p1")

    sc = SupplyChain(10)
    add_product!(sc, product)

    supplier = Supplier("Sup", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=1.0)

    dc = Storage("DC", Seattle; initial_opened=true)
    add_storage!(sc, dc)
    add_product!(dc, product; unit_holding_cost=2.0)

    customer = Customer("Cust", Seattle)
    add_customer!(sc, customer)
    demand = [10.0, 12.0, 8.0, 14.0, 9.0, 11.0, 13.0, 7.0, 10.0, 12.0]
    add_demand!(sc, customer, product, demand)

    add_lane!(sc, Lane(supplier, dc; unit_cost=1.0, time=3))
    add_lane!(sc, Lane(dc, customer; unit_cost=1.0))

    result = compute_safety_stock_gsm(sc, product; service_level=0.95)

    z = SupplyChainOptimization._standard_normal_quantile(0.95)
    expected_sigma = std(demand)
    expected_nrt = 0 + 3 - 0 # SI_DC=0 (supplier root) + lead_time 3 - S_DC=0 (forced, maximum_customer_wait=0)
    expected_safety_stock = z * expected_sigma * sqrt(expected_nrt)

    get_outgoing_service_time(result, dc) == 0 &&
    get_net_replenishment_time(result, dc) == expected_nrt &&
    isapprox(get_safety_stock(result, dc), expected_safety_stock; rtol=1e-6) &&
    isapprox(get_total_safety_stock_cost(result, sc), expected_safety_stock * 2.0; rtol=1e-6)
end

@test begin
    # Branching tree: Supplier -> Central -> {East, West} -> {CustE, CustW}. East/West are
    # forced to S=0 (maximum_customer_wait=0), leaving S_Central as the only genuinely free
    # variable (in 0:2) - brute-force search that range directly (bypassing the DP) and
    # confirm compute_safety_stock_gsm finds the same true minimum-cost total, and that
    # sigma at Central reflects the risk-pooling (variance-sum) aggregation.
    product = Product("p1")

    sc = SupplyChain(10)
    add_product!(sc, product)

    supplier = Supplier("Sup", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=1.0)

    central = Storage("Central", Seattle; initial_opened=true)
    add_storage!(sc, central)
    add_product!(central, product; unit_holding_cost=1.0)

    east = Storage("East", Seattle; initial_opened=true)
    add_storage!(sc, east)
    add_product!(east, product; unit_holding_cost=3.0)

    west = Storage("West", Seattle; initial_opened=true)
    add_storage!(sc, west)
    add_product!(west, product; unit_holding_cost=2.0)

    custE = Customer("CustE", Seattle)
    add_customer!(sc, custE)
    demandE = [20.0, 22.0, 18.0, 24.0, 19.0, 21.0, 23.0, 17.0, 20.0, 22.0]
    add_demand!(sc, custE, product, demandE)

    custW = Customer("CustW", Seattle)
    add_customer!(sc, custW)
    demandW = [15.0, 17.0, 13.0, 19.0, 14.0, 16.0, 18.0, 12.0, 15.0, 17.0]
    add_demand!(sc, custW, product, demandW)

    add_lane!(sc, Lane(supplier, central; unit_cost=1.0, time=2))
    add_lane!(sc, Lane(central, east; unit_cost=1.0, time=1))
    add_lane!(sc, Lane(central, west; unit_cost=1.0, time=1))
    add_lane!(sc, Lane(east, custE; unit_cost=1.0))
    add_lane!(sc, Lane(west, custW; unit_cost=1.0))

    service_level = 0.95
    result = compute_safety_stock_gsm(sc, product; service_level=service_level)

    z = SupplyChainOptimization._standard_normal_quantile(service_level)
    sigma_east = std(demandE)
    sigma_west = std(demandW)
    sigma_central = sqrt(sigma_east^2 + sigma_west^2)

    # Brute force over the one genuinely free variable, S_central in 0:2 (East/West are
    # forced to S=0 independent of S_central).
    brute_force_best = Inf
    for s_central in 0:2
        nrt_central = 0 + 2 - s_central
        nrt_east = s_central + 1 - 0
        nrt_west = s_central + 1 - 0
        cost = 1.0 * z * sigma_central * sqrt(nrt_central) +
               3.0 * z * sigma_east * sqrt(nrt_east) +
               2.0 * z * sigma_west * sqrt(nrt_west)
        brute_force_best = min(brute_force_best, cost)
    end

    dp_total = get_total_safety_stock_cost(result, sc)

    get_outgoing_service_time(result, east) == 0 &&
    get_outgoing_service_time(result, west) == 0 &&
    isapprox(get_safety_stock(result, central), sigma_central * z * sqrt(get_net_replenishment_time(result, central)); rtol=1e-6) &&
    isapprox(dp_total, brute_force_best; rtol=1e-6)
end

@test begin
    # A storage fed by two distinct suppliers for the same product is a merge point -
    # not yet supported (Humair & Willems territory), must raise ArgumentError rather
    # than silently produce a wrong answer.
    product = Product("p1")
    sc = SupplyChain(10)
    add_product!(sc, product)

    supplier1 = Supplier("Sup1", Seattle)
    add_supplier!(sc, supplier1)
    add_product!(supplier1, product; unit_cost=1.0)

    supplier2 = Supplier("Sup2", Seattle)
    add_supplier!(sc, supplier2)
    add_product!(supplier2, product; unit_cost=1.0)

    dc = Storage("DC", Seattle; initial_opened=true)
    add_storage!(sc, dc)
    add_product!(dc, product; unit_holding_cost=1.0)

    customer = Customer("Cust", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product, repeat([10.0], 10))

    add_lane!(sc, Lane(supplier1, dc; unit_cost=1.0))
    add_lane!(sc, Lane(supplier2, dc; unit_cost=1.0))
    add_lane!(sc, Lane(dc, customer; unit_cost=1.0))

    try
        compute_safety_stock_gsm(sc, product)
        false
    catch e
        e isa ArgumentError
    end
end

@test begin
    # A customer served directly by two distinct storages for the same product is also
    # a merge point at the demand-facing edge - must raise ArgumentError too.
    product = Product("p1")
    sc = SupplyChain(10)
    add_product!(sc, product)

    supplier = Supplier("Sup", Seattle)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=1.0)

    dc1 = Storage("DC1", Seattle; initial_opened=true)
    add_storage!(sc, dc1)
    add_product!(dc1, product; unit_holding_cost=1.0)

    dc2 = Storage("DC2", Seattle; initial_opened=true)
    add_storage!(sc, dc2)
    add_product!(dc2, product; unit_holding_cost=1.0)

    customer = Customer("Cust", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product, repeat([10.0], 10))

    add_lane!(sc, Lane(supplier, dc1; unit_cost=1.0))
    add_lane!(sc, Lane(supplier, dc2; unit_cost=1.0))
    add_lane!(sc, Lane(dc1, customer; unit_cost=1.0))
    add_lane!(sc, Lane(dc2, customer; unit_cost=1.0))

    try
        compute_safety_stock_gsm(sc, product)
        false
    catch e
        e isa ArgumentError
    end
end

@test begin
    # Production/BOM networks aren't yet supported - a plant producing the product must
    # raise ArgumentError rather than silently ignoring the production stage.
    product = Product("p1")
    sc = SupplyChain(10)
    add_product!(sc, product)

    plant = Plant("Plant", Seattle; initial_opened=true)
    add_plant!(sc, plant)
    add_product!(plant, product; bill_of_material=Dict{Product, Float64}(), unit_cost=1.0)

    dc = Storage("DC", Seattle; initial_opened=true)
    add_storage!(sc, dc)
    add_product!(dc, product; unit_holding_cost=1.0)

    customer = Customer("Cust", Seattle)
    add_customer!(sc, customer)
    add_demand!(sc, customer, product, repeat([10.0], 10))

    add_lane!(sc, Lane(plant, dc; unit_cost=1.0))
    add_lane!(sc, Lane(dc, customer; unit_cost=1.0))

    try
        compute_safety_stock_gsm(sc, product)
        false
    catch e
        e isa ArgumentError
    end
end

end
