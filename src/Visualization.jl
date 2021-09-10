using PlotlyJS
using JuMP

"""
    plot_inventory(supply_chain, storage, product)

Plots the amount of inventory of a product on-hand at a storage location at the beginning of each period. 
"""
function plot_inventory(supply_chain, storage, product)
    return Plot(scatter(;x=1:supply_chain.horizon, y=[get_inventory_at_end(supply_chain, storage, product, t) for t in 1:supply_chain.horizon], mode="lines+markers"))
end

function plot_networks(supply_chain; geography="usa", showlegend=true)
    return hcat([plot_network(supply_chain, p) for p in 1:supply_chain.horizon])
end

"""
    plot_network(supply_chain, period=1; geography="usa", showlegend=true)

Plots the nodes of the supply chain on a map.

The geography must be one of: "world" | "usa" | "europe" | "asia" | "africa" | "north america" | "south america".
"""
function plot_network(supply_chain, period=1; geography="usa", showlegend=true)
    traces = AbstractTrace[]
    first = true
    for storage in supply_chain.storages
        if is_opened(supply_chain, storage, period)
            push!(traces,
                scattergeo(;lat=[storage.location.latitude],
                            lon=[storage.location.longitude],
                            legendgroup="storage",
                            showlegend=first,
                            hoverinfo="text",
                            text="$(storage.name)",
                            name="storages",
                            mode="makers",
                            marker_symbol="square",
                            marker_size=10,
                            marker_color="blue")
            )
            first = false
        end
    end

    first = true
    for plant in supply_chain.plants
        if is_opened(supply_chain, plant, period)
            push!(traces,
                scattergeo(;lat=[plant.location.latitude],
                            lon=[plant.location.longitude],
                            legendgroup="plant",
                            showlegend=first,
                            hoverinfo="text",
                            text="$(plant.name)",
                            name="plants",
                            mode="makers",
                            marker_symbol="triangle-up",
                            marker_size=10,
                            marker_color="red")
            )
            first = false
        end
    end

    first = true
    for supplier in supply_chain.suppliers
        if sum(get_shipments(supply_chain, supplier, p, period) for p in supply_chain.products) > 1e-10
            push!(traces,
                scattergeo(;lat=[supplier.location.latitude],
                            lon=[supplier.location.longitude],
                            legendgroup="supplier",
                            showlegend=first,
                            hoverinfo="text",
                            text="$(supplier.name)",
                            name="suppliers",
                            mode="makers",
                            marker_symbol="circle",
                            marker_size=10,
                            marker_color="yellow")
            )
            first = false
        end
    end

    for (i, customer) in enumerate(supply_chain.customers)
        push!(traces,
            scattergeo(;lat=[customer.location.latitude],
                        lon=[customer.location.longitude],
                        legendgroup="customer",
                        showlegend=(i==1),
                        hoverinfo="text",
                        text="$(customer.name)",
                        name="customers",
                        mode="makers",
                        marker_symbol="circle",
                        marker_color="green",
                        marker_opacity=0.35)
        )
    end

    geo = attr(scope=geography,
                showland=true,)
         
    layout = Layout(;title="Supply chain network", showlegend=showlegend, geo=geo)
    return Plot(traces, layout)
end

"""
    plot_costs(supply_chain)

Plots the costs of operating the supply chain. 
"""
function plot_costs(supply_chain)
    trace1 = bar(;x=1:supply_chain.horizon,
                 y=[value(supply_chain.optimization_model[:total_fixed_costs_per_period][t]) for t in 1:supply_chain.horizon],
                 name="Fixed Costs")
    trace2 = bar(;x=1:supply_chain.horizon,
                 y=[value(supply_chain.optimization_model[:total_transportation_costs_per_period][t]) for t in 1:supply_chain.horizon],
                 name="Transportation Costs")
    trace3 = bar(;x=1:supply_chain.horizon,
                 y=[value(supply_chain.optimization_model[:total_costs_per_period][t])  - value(supply_chain.optimization_model[:total_fixed_costs_per_period][t]) - value(supply_chain.optimization_model[:total_transportation_costs_per_period][t]) for t in 1:supply_chain.horizon],
                 name="Other Costs")
    
    layout = Layout(;barmode="stack", 
                    xaxis_title="Period", xaxis_tick0=1, xaxis_dtick=1, xaxis_rangemode="nonnegative",
                    yaxis_title="Cost (\$)")
    Plot([trace1, trace2, trace3], layout)
end

"""
    plot_flows(supply_chain, period=1; geography="usa", showlegend=true)

Plots the flows of products in the supply chain. 
"""
function plot_flows(supply_chain, period=1; geography="usa", showlegend=true)

    colors = ["red", "blue", "green", "orange", "black", "purple"]

    origin_colors = Dict{Node, String}()
    color_index = 0

    traces = AbstractTrace[]
    for l in sort(collect(supply_chain.lanes), by=l->string(l.origin.location.name, l.destination.location.name))
        if sum(get_shipments(supply_chain, l, p, period) for p in supply_chain.products) > 1e-10
            if l.origin in keys(origin_colors)
                color = origin_colors[l.origin]
            else
                color_index = mod1(color_index + 1, length(colors))
                color = colors[color_index]
                push!(origin_colors, l.origin => color)
            end
        
            push!(traces,
                scattergeo(;lat=[l.origin.location.latitude, l.destination.location.latitude],
                            lon=[l.origin.location.longitude, l.destination.location.longitude],
                            hoverinfo="text",
                            text="$(l.origin.location.name) - $(l.destination.location.name)",
                            name="$(l.origin.location.name) - $(l.destination.location.name)",
                            mode="lines",
                            line_color=color)
            )
        end
    end

    geo = attr(scope=geography,
                showland=true,)
         
    layout = Layout(;title="Supply chain flows", showlegend=showlegend, geo=geo)
    Plot(traces, layout)
end