using PlotlyJS
using JuMP

function plot_network(supply_chain)
    
end

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
Plots the flows of products in the supply chain. 
"""
function plot_flows(supply_chain, geography, period=1)

    traces = AbstractTrace[]
    for l in supply_chain.lanes
        if sum(value(supply_chain.optimization_model[:sent][p,l,period]) for p in supply_chain.products) > 0
            push!(traces,
                scattergeo(;lat=[l.origin.location.latitude, l.destination.location.latitude],
                            lon=[l.origin.location.longitude, l.destination.location.longitude],
                            hoverinfo="text",
                            text="$(l.origin.location.name) - $(l.destination.location.name)",
                            name="$(l.origin.location.name) - $(l.destination.location.name)",
                            mode="lines")
            )
        end
    end

    geo = attr(scope=geography,
                showland=true,)
         
    layout = Layout(;title="Supply chain flows", showlegend=true, geo=geo)
    Plot(traces, layout)
end

"""
Plots the nodes of the supply chain on a map.

The geography must be one of: "world" | "usa" | "europe" | "asia" | "africa" | "north america" | "south america".
"""
function plot_nodes(supply_chain, geography)
    trace1 = scattergeo(;lat=[s.location.latitude for s in supply_chain.storages],
                        lon=[s.location.longitude for s in supply_chain.storages],
                        hoverinfo="text",
                        text=[s.location.name for s in supply_chain.storages],
                        marker_line_color="black", 
                        name="storages")
    trace2 = scattergeo(;lat=[s.location.latitude for s in supply_chain.customers],
                        lon=[s.location.longitude for s in supply_chain.customers],
                        hoverinfo="text",
                        text=[s.location.name for s in supply_chain.customers],
                        marker_line_color="blue", 
                        name="customers")
    trace3 = scattergeo(;lat=[s.location.latitude for s in supply_chain.plants],
                        lon=[s.location.longitude for s in supply_chain.plants],
                        hoverinfo="text",
                        text=[s.location.name for s in supply_chain.plants],
                        marker_line_color="red", 
                        name="plants")
    trace4 = scattergeo(;lat=[s.location.latitude for s in supply_chain.suppliers],
                        lon=[s.location.longitude for s in supply_chain.suppliers],
                        hoverinfo="text",
                        text=[s.location.name for s in supply_chain.suppliers],
                        marker_line_color="green", 
                        name="suppliers")
    geo = attr(scope=geography,
               showland=true,)

    layout = Layout(;title="Supply chain nodes", showlegend=true, geo=geo)
    Plot([trace1, trace2, trace3, trace4], layout)
end
