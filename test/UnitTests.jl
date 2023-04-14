function create_empty_model()
    sc = SupplyChain()

    return sc
end

@testset "Modeling" begin
    @test haversine(0, 0, 0, 0) == 0
    
    @test haversine(51.510357, -0.116773, 38.889931, -77.009003) ≈ 5897658.289
    
    @test add_lane!(SupplyChain(), 
                             Lane(Customer("c1", Seattle), 
                                  Customer("c2", Seattle);
                                  unit_cost=1.0,
                                  minimum_quantity=0,
                                  time=0)) isa Lane
    
    @test !isnothing(create_empty_model())
end