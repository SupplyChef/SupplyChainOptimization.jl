using SupplyChainOptimization

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
        customer = Customer("c$f",Location(0, 0))
        add_product!(customer, product; demand=[1.0])
        add_customer!(sc, customer)
        push!(customers, customer)
    end

    for f in 1:facility_count
        data = [parse(Float64, c.match) for c in eachmatch(r"\d+", lines[2+f])]
        storage = Storage("s$f", data[2], 0.0, 0.0, false, Location(0, 0))
        add_product!(storage, product; initial_inventory=customer_count, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
        add_storage!(sc, storage)

        for c in 1:customer_count
            lane = Lane(storage, customers[c], data[2+c])
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
        storage = Storage("s$f",parse(Float64, numbers[number_index]), 0.0, 0.0, false, Location(0, 0))
        number_index += 1
        add_product!(storage, product; initial_inventory=customer_count, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
        add_storage!(sc, storage)
        push!(facilities, storage)
    end

    for c in 1:customer_count
        #println(numbers[number_index])
        demand = parse(Float64, numbers[number_index])
        number_index += 1
        customer = Customer("c$c", Location(0, 0))
        add_product!(customer, product; demand=[1.0])
        add_customer!(sc, customer)
        
        for f in 1:facility_count
            #println(numbers[number_index])
            lane = Lane(facilities[f], customer, parse(Float64, numbers[number_index]))
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
        storage = Storage("s$f", parse(Float64, numbers[number_index]), 0.0, 0.0, false, Location(0, 0))
        number_index += 1
        add_product!(storage, product; initial_inventory=inventory, unit_handling_cost=0.0, maximum_throughput=Inf, safety_stock_cover=0.0)
        add_storage!(sc, storage)
        push!(facilities, storage)
    end

    for c in 1:customer_count
        #println(numbers[number_index])
        demand = parse(Float64, numbers[number_index])
        number_index += 1
        customer = Customer("c$c", Location(0, 0))
        add_product!(customer, product; demand=[demand])
        add_customer!(sc, customer)
        
        for f in 1:facility_count
            #println(numbers[number_index])
            lane = Lane(facilities[f], customer, parse(Float64, numbers[number_index]) / customer.demand[product][1])
            number_index += 1
            add_lane!(sc, lane)
        end
    end

    return sc
end

@test begin
    sc = parse_simple_data(raw"..\data\BildeKrarup\B\B1.1")
    SupplyChainOptimization.optimize!(sc)
    true
end

@test begin
    sc = parse_orlib_data_uncap(raw"..\data\ORLIB\ORLIB-cap\40\cap41.txt")
    SupplyChainOptimization.optimize!(sc)
    true
end