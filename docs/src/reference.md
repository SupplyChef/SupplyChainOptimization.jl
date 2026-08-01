# Reference

## Optimization

```@docs
minimize_cost!
maximize_profits!
SupplyChainOptimization.create_network_cost_minimization_model
SupplyChainOptimization.create_network_profit_maximization_model
SupplyChainOptimization.create_network_cost_minimization_model!
SupplyChainOptimization.create_network_profit_maximization_model!
SupplyChainOptimization.optimize_network_optimization_model!
SupplyChainOptimization.create_network_model
haversine
haversine_km
```

## Maturation Scheduling (IPPDP)

```@docs
create_maturation_scheduling_model
optimize_maturation_schedule!
get_maturation_schedule
get_quota_shortfall
get_quota_excess
get_total_deviation_costs
get_total_overproduction_costs
get_total_underproduction_costs
get_total_quota_deviation_costs
```

## Matheuristics

```@docs
matheuristic_optimize!
```

## Querying Results

```@docs
get_financials
get_total_profits
get_total_costs
get_total_fixed_costs
get_total_transportation_costs
get_inventory_at_start
get_inventory_at_end
get_overflow
get_production
get_receipts
get_shipments
is_opened
is_opening
is_closing
```

## Safety Stock Placement (GSM)

```@docs
compute_safety_stock_gsm
GSMResult
get_incoming_service_time
get_outgoing_service_time
get_net_replenishment_time
get_safety_stock
get_total_safety_stock_cost
```

## Visualization

```@docs
plot_network
plot_flows
plot_costs
plot_financials
plot_inventory
animate_network
animate_flows
movie_network
```
