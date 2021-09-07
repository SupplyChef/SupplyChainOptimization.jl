# Reference

## Types
```@docs
SupplyChain
Location
Node
Customer
Lane
Plant
Storage
Supplier
Demand
```

## Modeling
```@docs
add_plant!
add_supplier!
add_storage!
add_customer!
add_product!
add_demand!
haversine
```

## Optimization
```@docs
optimize_network!
```

## Querying Results
```@docs
get_total_costs
get_total_fixed_costs
get_total_transportation_costs
```

## Visualization
```@docs
plot_network
plot_flows
plot_costs
```