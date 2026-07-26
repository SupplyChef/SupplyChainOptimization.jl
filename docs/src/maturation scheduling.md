# Maturation Scheduling

Some supply chains don't move a fixed product between fixed-lead-time nodes - they *grow* it.
A poultry farm holds chicks until they reach a target slaughter weight; a cheesemaker holds
wheels until they reach a target age; a distillery holds barrels until the spirit reaches a
target proof. In each case, how long you hold the batch is itself a decision, one that trades
off against a quality/weight target and against a delivery commitment (a quota) at the other
end.

[`create_maturation_scheduling_model`](@ref) solves this problem: given a set of
`MaturationSource`s (each holding at most one batch per planning horizon, "all-in-all-out")
and a set of `QuotaSink`s (each with a soft periodic delivery target), it chooses each
source's start day, ship day, and destination sink to minimize transportation cost, value-deviation
penalties, and quota-deviation penalties. Both types are defined in
[SupplyChainModeling.jl](https://SupplyChef.github.io/SupplyChainModeling.jl/dev).

This generalizes the integrated poultry production-distribution problem (IPPDP) of Gbéya, Darvish,
Renaud and Coelho (2026), "Integrated Poultry Production-Distribution Optimization", CIRRELT-2026-10.

## Example

Two farms feed a single slaughterhouse with a daily quota. Each farm can only ship once per
horizon, and birds must ship within a target weight band or be sold at a penalty to an
alternative market.

```julia
using SupplyChainModeling
using SupplyChainOptimization

sc = SupplyChain(30)

bird = Product("bird")
add_product!(sc, bird)

for (name, location) in [("Farm A", Location(46.8, -71.2)), ("Farm B", Location(46.5, -71.9))]
    farm = MaturationSource(name, location; capacity=10_000, changeover_periods=3)
    add_product!(farm, bird; initial_value=45.0, maturation_rate=60.0, target_value=2250.0,
                             acceptable_deviation_under=0.1, acceptable_deviation_over=0.1,
                             extended_deviation_under=0.05, extended_deviation_over=0.05,
                             underrun_unit_penalty=0.001, overrun_unit_penalty=0.001)
    add_maturation_source!(sc, farm)
end

slaughterhouse = QuotaSink("Slaughterhouse", Location(46.8, -71.2))
add_product!(slaughterhouse, bird; quota=15_000, underproduction_unit_penalty=1.0, overproduction_unit_penalty=1.0)
add_quota_sink!(sc, slaughterhouse)

# Hatcheries typically don't deliver on Wednesdays, Saturdays or Sundays, and slaughterhouses
# don't run on weekends - is_start_day/is_delivery_day encode that without touching the model.
is_weekday_except_wednesday(t) = !(t % 7 in (0, 3, 4))
is_weekday(t) = !(t % 7 in (0, 1))

optimize_maturation_schedule!(sc; transport_cost_per_distance=1.0, distance=haversine_km,
                              is_start_day=is_weekday_except_wednesday, is_delivery_day=is_weekday)

for farm in sc.maturation_sources
    schedule = get_maturation_schedule(sc, farm, bird)
    println("$farm: starts day $(schedule.start_day), ships day $(schedule.ship_day) to $(schedule.sink)")
end
```

## Generalizing beyond poultry

Nothing in `MaturationSource` or `QuotaSink` is poultry-specific, and nothing about the batch's
value even has to *grow*. `MaturationSource`'s `add_product!` has two forms: a convenience form
(`capacity`, `maturation_rate`, `target_value`, acceptable/extended deviation bands) for the
common case of value rising linearly toward a target - the shape this poultry example, aging
cheese, or a distillery barrel all share - and a fully custom form taking arbitrary
`value_function`/`feasible_duration`/`duration_penalty` functions of duration.

That custom form is what lets `MaturationSource` also express classical perishable/shelf-life
inventory (constant value, unsellable past a fixed age) rather than just harvest-scheduling-style
curves - the two families of problems the operations-research literature usually treats
separately turn out to be the same object with a different curve shape. See
`MaturationSource`'s own docstring for the literature connection, and its `add_product!`
docstring for a shelf-life example.

`QuotaSink`'s `quota`/`underproduction_unit_penalty`/`overproduction_unit_penalty` describe any
soft periodic delivery target - a supply-managed quota, a contractual minimum order commitment,
or any other target a business would rather miss (at a cost) than treat as a hard constraint.
