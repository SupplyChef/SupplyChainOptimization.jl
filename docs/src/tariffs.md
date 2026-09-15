# Tariffs

Ad-valorem tariffs let you price import duties into a network optimization
run, so the optimizer weighs a cheaper overseas supplier against the tariff
it triggers, the same way it already weighs unit cost against transportation
cost.

## Declaring countries

A tariff is charged when a unit crosses from one customs territory into
another, so the first step is telling `SupplyChainModeling` which country
each `Location` sits in via the `country` keyword (an ISO 3166-1 alpha-2
code, e.g. `"US"`, `"CN"`, `"DE"`):

```
us = Location(47.608013, -122.335167; country="US")
cn = Location(31.230416, 121.473701; country="CN")
```

A `Location` with no `country` set (the default) never triggers a tariff -
existing models that don't use this feature solve exactly as before.

## Registering a tariff

`add_tariff!` registers an ad-valorem rate (a fraction of declared value,
e.g. `0.2` for 20%) between two countries, optionally scoped to a single
product:

```
using SupplyChainModeling
using SupplyChainOptimization

sc = SupplyChain()

product = Product("p1")
add_product!(sc, product)

us = Location(47.608013, -122.335167; country="US")
cn = Location(31.230416, 121.473701; country="CN")

customer = Customer("c1", us)
add_customer!(sc, customer)
add_demand!(sc, customer, product, [100.0])

storage = Storage("s1", us; fixed_cost=0.0, opening_cost=0.0, closing_cost=0.0, initial_opened=true)
add_storage!(sc, storage)
add_product!(storage, product)

supplier = Supplier("supplier1", cn)
add_supplier!(sc, supplier)
add_product!(supplier, product; unit_cost=10.0)

add_lane!(sc, Lane(storage, customer; unit_cost=1.0))
add_lane!(sc, Lane(supplier, storage; unit_cost=1.0))

# 20% ad-valorem tariff on anything crossing from CN into US.
add_tariff!(sc, Tariff("CN", "US", 0.2))

minimize_cost!(sc)

get_total_tariff_costs(sc)  # 0.2 * 10.0 (declared value) * 100 (units) == 200.0
```

Passing `product` to `Tariff` (`Tariff("CN", "US", 0.2; product=product)`)
scopes the rate to that product only; every other product moving CN->US is
untariffed. A `Tariff` with `product=nothing` (the default) applies to every
product crossing that border, and a more specific per-product `Tariff`
between the same two countries takes precedence over it.

A lane whose origin and destination resolve to the same country - or where
either side has no `country` set - never incurs a tariff, and a supply
chain that never calls `add_tariff!` solves identically to one without this
feature at all: `get_total_tariff_costs` returns `0.0` and the objective is
unaffected.

## Declared value

The tariff charged per unit is `rate * declared_value`, where `declared_value`
is the unit's cost basis at the border: a `Supplier`'s `unit_cost` or a
`Plant`'s `unit_cost` for product leaving that node, whichever the crossing
lane departs from.

## Re-exports through a Storage

A `Storage` blends inventory bought or produced in different countries, so a
lane leaving a `Storage` can't always be tariffed from a single declared
origin the way a lane leaving a `Supplier`/`Plant` can. The model tracks
inventory by country of origin internally for any product with a tariff
registered, so a re-export - product that entered a `Storage` from one
country and ships back out crossing into a third - is tariffed against the
country it actually originated from, not the `Storage`'s own location:

```
us = Location(47.608013, -122.335167; country="US")
cn = Location(31.230416, 121.473701; country="CN")
de = Location(52.520008, 13.404954; country="DE")

# ... supplier1 (CN) -> storage (US) -> customer (DE) ...

# No CN->US tariff, so the inbound leg is untariffed - but re-exporting from
# the US storage into DE is, because the goods themselves originated in CN.
add_tariff!(sc, Tariff("CN", "DE", 0.3))
```

This per-origin tracking is only built for products that actually have a
tariff registered somewhere in the network - a supply chain with no tariffs
pays no overhead for it (see the "Internals" page for the modeling
details).

## Reading tariff costs back

- `get_total_tariff_costs(sc)` - total tariff cost across the whole horizon,
  after optimizing.
- `get_financials(sc)`'s `Tariff_Costs` column - the same total, broken out
  per period, alongside `Transportation_Costs`/`Holding_Costs`/`Buying_Costs`/etc.
