@testset "Profits" begin
    @test begin 
        start = Dates.now()
        sc = parse_simple_data(raw"..\data\BildeKrarup\B\B1.1")
        SupplyChainOptimization.maximize_profits!(sc)
        println("B1.1 $(Dates.now() - start) $(get_total_profits(sc)) == -23468")
        get_total_profits(sc) ≈ -23468
    end
end