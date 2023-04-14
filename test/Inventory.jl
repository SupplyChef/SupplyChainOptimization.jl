using Dates

"""
    eoq_quantity(demand_rate, ordering_cost, holding_cost_rate)

    Computes the economic ordering quantity that minimizes overall costs (ordering costs + holding costs) while meeting  demand.
"""
function eoq_quantity(demand_rate, ordering_cost, holding_cost_rate)
    return sqrt((2 * demand_rate * ordering_cost) / (holding_cost_rate))
end

"""
    eoq_quantity(demand_rate, ordering_cost, holding_cost_rate, backlog_cost_rate)

    Computes the economic ordering quantity that minimizes overall costs (ordering costs + holding costs) while meeting  demand.
"""
function eoq_quantity(demand_rate, ordering_cost, holding_cost_rate, backlog_cost_rate)
    return sqrt((2 * demand_rate * ordering_cost) / (holding_cost_rate) * (holding_cost_rate + backlog_cost_rate) / backlog_cost_rate)
end

@testset "Inventory" begin
    
    @test begin
        start = Dates.now()
        sc = create_model_plant_storage_customer(400)

        product = first(sc.products)
        product.unit_holding_cost = 0.1

        lane = first(filter(l -> isa(l.origin, Plant), sc.lanes))
        lane.fixed_cost = 10_000
        lane.can_ship = repeat([true, false, false, false], 100)

        SupplyChainOptimization.optimize_network!(sc; log=true)
    
        #println(value.(sc.optimization_model[:used]))
        println([get_shipments(sc, lane, product, t) for t in 1:100])
        println(eoq_quantity(100, 10_000, 0.1))
        println("$(start - Dates.now())")
        true
    end
end