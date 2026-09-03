# PlotlyJS and Plots are weak dependencies (see Project.toml's
# [weakdeps]/[extensions]): pulling them in unconditionally made this
# package unresolvable alongside anything depending on a modern JSON.jl
# (PlotlyJS 0.18.x needs JSON 0.20-0.21; e.g. Oxygen.jl needs JSON 1.x - no
# version satisfies both, so any consumer needing both would fail to
# resolve at all, not just at plot time).
#
# The actual implementations live in
# ext/SupplyChainOptimizationPlotlyJSExt.jl, which Julia loads
# automatically once both PlotlyJS and Plots are `using`'d alongside this
# package - no special syntax needed by the caller beyond having both
# loaded. These are just stub declarations: they keep the names part of
# this package's own export/API surface and documented, regardless of
# whether the extension is active. Calling one before both packages are
# loaded raises a plain `MethodError`.

"""
    plot_inventory(supply_chain, storage, product)

Plots the amount of inventory of a product on-hand at a storage location at the beginning of each period.

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function plot_inventory end

"""
    plot_network(supply_chain, period=1; geography="usa", showlegend=true)

Plots the nodes of the supply chain on a map.

The geography must be one of: "world" | "usa" | "europe" | "asia" | "africa" | "north america" | "south america".

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function plot_network end

"""
    plot_costs(supply_chain)

Plots the costs of operating the supply chain.

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function plot_costs end

"""
    plot_financials(supply_chain; max_time=supply_chain.horizon)

Plots the financial results of operating the supply chain.

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function plot_financials end

"""
    plot_flows(supply_chain, period=1; geography="usa", showlegend=true)

Plots the flows of products in the supply chain.

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function plot_flows end

"""
    animate_network

Creates an animation of the network through time.

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function animate_network end

"""
    animate_flows; geography="usa", showlegend=true, excluded_origins=[])

Creates an animation of the product flows through time.

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function animate_flows end

"""
    movie_network

Makes a movie of the network evolution.

Requires `PlotlyJS` and `Plots` to be loaded (see this file's top-of-file note).
"""
function movie_network end
