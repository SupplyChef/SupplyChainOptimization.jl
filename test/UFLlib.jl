using SupplyChainOptimization
using Dates

function parse_simple_data(file_name)
    lines = readlines(file_name)
    m = match(r"(?<facility_count>\d+)\s+(?<customer_count>\d+)\s+0", lines[2])
    facility_count = parse(Int, m[:facility_count])
    customer_count = parse(Int, m[:customer_count])

    sc = SupplyChain()
    product = Product("p1")

    add_product!(sc, product)

    customers = []
    for f in 1:customer_count
        customer = Customer("c$f", Location(0, 0))
        add_customer!(sc, customer)
        add_demand!(sc, customer, product; demand=[1.0])
        push!(customers, customer)
    end

    for f in 1:facility_count
        data = [parse(Float64, c.match) for c in eachmatch(r"\d+", lines[2+f])]
        storage = Storage("s$f", Location(0, 0); fixed_cost=data[2], opening_cost=0.0, closing_cost=0.0, initial_opened=false)
        add_product!(storage, product; initial_inventory=customer_count, unit_handling_cost=0.0)
        add_storage!(sc, storage)

        for c in 1:customer_count
            lane = Lane(storage, customers[c]; unit_cost=data[2+c])
            add_lane!(sc, lane)
        end
    end

    return sc
end

function parse_orlib_data_uncap(file_name)
    numbers = split(read(file_name, String))
    number_index = 1

    facility_count = parse(Int, numbers[number_index])
    number_index += 1
    customer_count = parse(Int, numbers[number_index])
    number_index += 1

    sc = SupplyChain()
    product = Product("p1")

    add_product!(sc, product)

    facilities = []
    for f in 1:facility_count
        number_index += 1
        #println(numbers[number_index])
        storage = Storage("s$f", Location(0, 0); fixed_cost=parse(Float64, numbers[number_index]), opening_cost=0.0, closing_cost=Inf, initial_opened=false)
        number_index += 1
        add_product!(storage, product; initial_inventory=customer_count, unit_handling_cost=0.0)
        add_storage!(sc, storage)
        push!(facilities, storage)
    end

    for c in 1:customer_count
        #println(numbers[number_index])
        demand = parse(Float64, numbers[number_index])
        number_index += 1
        customer = Customer("c$c", Location(0, 0))
        add_customer!(sc, customer)
        add_demand!(sc, customer, product; demand=[1.0])
        
        for f in 1:facility_count
            #println(numbers[number_index])
            lane = Lane(facilities[f], customer; unit_cost=parse(Float64, numbers[number_index]))
            number_index += 1
            add_lane!(sc, lane)
        end
    end

    return sc
end

function parse_orlib_data_cap(file_name, capacity=nothing)
    if isnothing(capacity)
        numbers = split(read(file_name, String))
    else
        numbers = split(replace(read(file_name, String), "capacity"=>capacity))
    end
    number_index = 1

    facility_count = parse(Int, numbers[number_index])
    number_index += 1
    customer_count = parse(Int, numbers[number_index])
    number_index += 1

    sc = SupplyChain()
    product = Product("p1")

    add_product!(sc, product)

    facilities = []
    for f in 1:facility_count
        inventory = parse(Float64, numbers[number_index])
        number_index += 1
        storage = Storage("s$f", Location(0, 0); fixed_cost=parse(Float64, numbers[number_index]), opening_cost=0.0, closing_cost=0.0, initial_opened=false)
        number_index += 1
        add_product!(storage, product; initial_inventory=inventory, unit_handling_cost=0.0)
        add_storage!(sc, storage)
        push!(facilities, storage)
    end

    for c in 1:customer_count
        #println(numbers[number_index])
        demand = parse(Float64, numbers[number_index])
        number_index += 1
        customer = Customer("c$c", Location(0, 0))
        add_customer!(sc, customer)
        add_demand!(sc, customer, product; demand=[demand])

        for f in 1:facility_count
            #println(numbers[number_index])
            lane = Lane(facilities[f], customer; unit_cost=parse(Float64, numbers[number_index]) / demand)
            number_index += 1
            add_lane!(sc, lane)
        end
    end

    return sc
end

@testset "UFLlib" begin 
@test begin 
    start = Dates.now()
    sc = parse_simple_data(raw"..\data\BildeKrarup\B\B1.1")
    SupplyChainOptimization.optimize_network!(sc)
    println("B1.1 $(Dates.now() - start) $(get_total_costs(sc)) == 23468")
    get_total_costs(sc) ≈ 23468
end

@test begin 
    start = Dates.now()
    sc = parse_simple_data(raw"..\data\BildeKrarup\B\B1.2")
    SupplyChainOptimization.optimize_network!(sc)
    println("B1.2 $(Dates.now() - start) $(get_total_costs(sc)) == 22119")
    get_total_costs(sc) ≈ 22119
end 

@test begin
    start = Dates.now()
    sc = parse_orlib_data_uncap(raw"..\data\ORLIB\ORLIB-cap\40\cap41.txt")
    SupplyChainOptimization.optimize_network!(sc)
    println("cap41 $(Dates.now() - start) $(get_total_costs(sc)) == 932615.75")
    get_total_costs(sc) ≈ 932615.75
end 

@test begin
    start = Dates.now()
    sc = parse_orlib_data_cap(raw"..\data\ORLIB\ORLIB-cap\40\cap41.txt")
    SupplyChainOptimization.optimize_network!(sc)
    println("cap41 $(Dates.now() - start) $(get_total_costs(sc)) == 1040444.375")
    get_total_costs(sc) ≈ 1040444.375
end 

@test begin
    start = Dates.now()
    sc = parse_orlib_data_uncap(raw"..\data\ORLIB\ORLIB-cap\90\cap91.txt")
    SupplyChainOptimization.optimize_network!(sc)
    println("cap91 $(Dates.now() - start) $(get_total_costs(sc)) == 796648.4375")
    get_total_costs(sc) ≈ 796648.4375
end

@test begin
    sc = parse_orlib_data_cap(raw"..\data\ORLIB\ORLIB-cap\90\cap91.txt")
    SupplyChainOptimization.optimize_network!(sc)
    println("$(get_total_costs(sc)) ==  796648.438")
    get_total_costs(sc) ≈ 796648.438
end

@test begin
    start = Dates.now()
    sc = parse_orlib_data_uncap(raw"..\data\ORLIB\ORLIB-uncap\a-c\capa.txt")
    SupplyChainOptimization.optimize_network!(sc)
    println("capa $(Dates.now() - start) $(get_total_costs(sc)) == 17156454.47830")
    get_total_costs(sc) ≈ 17156454.47830
end

# @test begin
#     sc = parse_orlib_data_cap(raw"..\data\ORLIB\ORLIB-uncap\a-c\capa.txt", 8000)
#     SupplyChainOptimization.optimize_network!(sc)
#     println("$(get_total_costs(sc)) == 19240822.449")
#     get_total_costs(sc) ≈ 19240822.449
# end

@test begin
    start = Dates.now()
    sc = parse_orlib_data_uncap(raw"..\data\ORLIB\ORLIB-uncap\a-c\capb.txt")
    SupplyChainOptimization.optimize_network!(sc)
    println("capb $(Dates.now() - start) $(get_total_costs(sc)) == 12979071.58143")
    get_total_costs(sc) ≈ 12979071.58143
end

@test begin
    start = Dates.now()
    sc = parse_orlib_data_cap(raw"..\data\ORLIB\ORLIB-uncap\a-c\capb.txt", 8000)
    SupplyChainOptimization.optimize_network!(sc)
    println("capb $(Dates.now() - start) $(get_total_costs(sc)) == 13082516.496")
    get_total_costs(sc) ≈ 13082516.496
end
end