# Reference

## Types
```@docs
SupplyChain
Location
Node
Product
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
add_lane!
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
get_inventory_at_start
get_inventory_at_end
get_production
get_receipts
get_shipments
is_opened
is_opening
is_closing
```

## Visualization
```@docs
plot_network
plot_flows
plot_costs
plot_inventory
```