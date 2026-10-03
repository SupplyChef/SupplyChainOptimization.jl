# supplier (unit_cost=10) -> storage (lane time 1) -> customer, demand of 100 units in period 3 sold at 25.
function create_model_cash(; terms=PaymentTerms(), cost_of_capital=0.0, cash_budget=Inf, horizon=3, freight=0.0, service_level=1.0)
    sc = SupplyChain(horizon; cost_of_capital=cost_of_capital, cash_budget=cash_budget)

    product = Product("p1")
    add_product!(sc, product)

    c = Customer("c1")
    add_customer!(sc, c)
    add_demand!(sc, c, product, [0.0, 0.0, 100.0]; sales_price=25.0, service_level=service_level)

    storage = Storage("s1")
    add_storage!(sc, storage)
    add_product!(storage, product)

    supplier = Supplier("supplier1"; payment_terms=terms)
    add_supplier!(sc, supplier)
    add_product!(supplier, product; unit_cost=10.0)

    add_lane!(sc, Lane(storage, c; unit_cost=0.0))
    add_lane!(sc, Lane(supplier, storage; unit_cost=freight, time=1))

    return sc
end

@testset "Cash" begin

@testset "cash curve: purchases out, sales in, peak is the most tied up" begin
    sc = create_model_cash()
    SupplyChainOptimization.maximize_profits!(sc)
    @test sum(get_cash_out(sc)) ≈ 1000.0
    @test sum(get_cash_in(sc)) ≈ 2500.0
    @test get_peak_cash_outlay(sc) ≈ 1000.0
    @test get_total_capital_costs(sc) == 0.0
    @test get_cumulative_net_cash_out(sc)[end] ≈ -1500.0   # the margin
end

@testset "freight is cash out" begin
    sc = create_model_cash(freight=2.0)
    SupplyChainOptimization.maximize_profits!(sc)
    @test sum(get_cash_out(sc)) ≈ 1200.0
end

@testset "cost of capital is part of the costs, on the money tied up" begin
    sc = create_model_cash(cost_of_capital=0.01)
    SupplyChainOptimization.maximize_profits!(sc)
    capital = get_total_capital_costs(sc)
    @test capital > 0.0
    @test capital ≈ 0.01 * sum(max.(get_cumulative_net_cash_out(sc), 0.0))
    # buying (10 * 100) plus capital costs are all the costs there are (discount_factor is 1)
    @test get_total_costs(sc) ≈ 1000.0 + capital
    # the cheapest plan buys as late as possible, so that less is tied up for less time
    @test capital ≈ 0.01 * 1000.0 * 1   # bought in period 2, paid for in period 2, sold in period 3
end

@testset "later payment ties up less capital" begin
    full = create_model_cash(cost_of_capital=0.01)
    SupplyChainOptimization.maximize_profits!(full)
    deposit = create_model_cash(cost_of_capital=0.01, terms=PaymentTerms(deposit_share=0.3, balance_offset=1))
    SupplyChainOptimization.maximize_profits!(deposit)
    @test sum(get_cash_out(deposit)) ≈ 1000.0
    @test get_total_capital_costs(deposit) < get_total_capital_costs(full)
    # 30% in the period of the purchase (2), the balance in the period of sales (3)
    @test get_cash_out(deposit) ≈ [0.0, 300.0, 700.0]
end

@testset "a balance due after the horizon is not cash out" begin
    sc = create_model_cash(terms=PaymentTerms(deposit_share=0.3, balance_offset=5))
    SupplyChainOptimization.maximize_profits!(sc)
    @test sum(get_cash_out(sc)) ≈ 300.0
end

@testset "cash budget limits the cumulative net cash out" begin
    sc = create_model_cash(cash_budget=600.0, service_level=0.0)
    SupplyChainOptimization.maximize_profits!(sc)
    @test get_peak_cash_outlay(sc) <= 600.0 + 1e-6
    # only 60 of the 100 units demanded can be funded
    @test sum(get_cash_out(sc)) ≈ 600.0
    @test sum(get_cash_in(sc)) ≈ 1500.0

    unlimited = create_model_cash(cash_budget=Inf, service_level=0.0)
    SupplyChainOptimization.maximize_profits!(unlimited)
    @test get_total_profits(unlimited) > get_total_profits(sc)

    # the budget is a hard limit: demand that must be served (service_level=1.0) but cannot be funded
    # makes the model infeasible
    infeasible = create_model_cash(cash_budget=600.0)
    SupplyChainOptimization.maximize_profits!(infeasible)
    @test JuMP.termination_status(infeasible.optimization_model) in (JuMP.INFEASIBLE, JuMP.INFEASIBLE_OR_UNBOUNDED)
end

end
