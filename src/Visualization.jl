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
    return hcat([plot_network(supply_chain, p; geography=geography, showlegend=showlegend) for p in 1:supply_chain.horizon])
end

"""
    plot_network(supply_chain, period=1; geography="usa", showlegend=true)

Plots the nodes of the supply chain on a map.

The geography must be one of: "world" | "usa" | "europe" | "asia" | "africa" | "north america" | "south america".
"""
function plot_network(supply_chain, period=1; 
                      geography="usa", 
                      showlegend=true, 
                      title="Supply chain network", 
                      excluded_nodes=[], 
                      groups=[(supply_chain.storages, "storage", "square", "blue", 1.0), 
                              (supply_chain.plants, "plant", "triangle-up", "red", 1.0)])
    traces = AbstractTrace[]

    for group in groups
        first = true
        for element in group[1]
            if in(element, excluded_nodes)
                continue
            end
            if is_opened(supply_chain, element, period)
                push!(traces,
                    scattergeo(;lat=[element.location.latitude],
                                lon=[element.location.longitude],
                                legendgroup=group[2],
                                showlegend=first,
                                hoverinfo="text",
                                text="$(element.name)",
                                name=group[2],
                                mode="makers",
                                marker_symbol=group[3],
                                marker_size=10,
                                marker_color=group[4],
                                marker_opacity=group[5])
                )
                first = false
            end
        end
    end

    first = true
    for supplier in supply_chain.suppliers
        if in(supplier, excluded_nodes)
            continue
        end
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
         
    layout = Layout(;title=title, showlegend=showlegend, geo=geo)
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
                 y=[value(supply_chain.optimization_model[:total_opening_costs_per_period][t]) for t in 1:supply_chain.horizon],
                 name="Opening Costs")
    trace4 = bar(;x=1:supply_chain.horizon,
                 y=[value(supply_chain.optimization_model[:total_costs_per_period][t])  - 
                    (value(supply_chain.optimization_model[:total_fixed_costs_per_period][t]) +
                     value(supply_chain.optimization_model[:total_transportation_costs_per_period][t]) + 
                     value(supply_chain.optimization_model[:total_opening_costs_per_period][t])
                     ) for t in 1:supply_chain.horizon],
                 name="Other Costs")
    
    layout = Layout(;barmode="stack", 
                    xaxis_title="Period", xaxis_tick0=1, xaxis_dtick=1, xaxis_rangemode="nonnegative",
                    yaxis_title="Cost (\$)")
    Plot([trace1, trace2, trace3, trace4], layout)
end

"""
    plot_flows(supply_chain, period=1; geography="usa", showlegend=true)

Plots the flows of products in the supply chain. 
"""
function plot_flows(supply_chain, period=1; geography="usa", showlegend=true, excluded_origins=[], origin_colors = Dict{Node, String}())

    colors = ["red", "blue", "green", "orange", "black", "purple"]

    color_index = length(origin_colors)

    traces = AbstractTrace[]
    for l in supply_chain.lanes #sort(collect(supply_chain.lanes), by=l->string(l.origin.location.name, l.destination.location.name))
        if in(l.origin, excluded_origins)
            continue
        end
        for d in l.destinations
            if sum(get_shipments(supply_chain, l, d, p, period) for p in supply_chain.products) > 2e-10
                if l.origin in keys(origin_colors)
                    color = origin_colors[l.origin]
                else
                    color_index = mod1(color_index + 1, length(colors))
                    color = colors[color_index]
                    push!(origin_colors, l.origin => color)
                end
            
                push!(traces,
                    scattergeo(;lat=[l.origin.location.latitude, d.location.latitude],
                                lon=[l.origin.location.longitude, d.location.longitude],
                                hoverinfo="text",
                                text="$(l.origin.location.name) - $(d.location.name)",
                                name="$(l.origin.location.name) - $(d.location.name)",
                                mode="lines",
                                line_color=color)
                )
            end
        end
    end

    geo = attr(scope=geography,
                showland=true,)
         
    layout = Layout(;title="Supply chain flows", showlegend=showlegend, geo=geo)
    Plot(traces, layout)
end

function animate_network(supply_chain; 
                         geography="usa", 
                         showlegend=true, 
                         excluded_nodes=[],
                         groups=[(supply_chain.storages, "storage", "square", "blue", 1.0), 
                              (supply_chain.plants, "plant", "triangle-up", "red", 1.0)])
    origin_colors = Dict{Node, String}()
    ps = [plot_network(supply_chain, i; geography=geography, showlegend=showlegend, excluded_nodes=excluded_nodes, groups=groups) for i in 1:supply_chain.horizon]

    #generate the initial frame
    trace = [scattergeo() for i in 1:length(getfield(ps[supply_chain.horizon], :data))]

    #store all frames in a vector
    frames = PlotlyFrame[
        frame(
            data = getfield(ps[k], :data), 
            layout = attr(title_text = "Period $k"), #update title
            name = "frame_$k", #update frame name
            traces = collect(1:length(getfield(ps[k], :data)))
        ) for k = 1:supply_chain.horizon
    ]

    #define the slider for manually viewing the frames
    sliders_attr = [
        attr(
            active = 0,
            minorticklen = 0,
            pad_t = 10,
            steps = [
                attr(
                    method = "animate",
                    label = "Period $k",
                    args = [
                        ["frame_$k"], #match the name of the frame again
                        attr(
                            mode = "immediate",
                            transition = attr(duration = 0),
                            frame = attr(duration = 5, redraw = true),
                        ),
                    ],
                ) for k = 1:supply_chain.horizon
            ],
        ),
    ]

    #define the displaying time per played frame (in milliseconds)
    dt_frame = 250

    #define the play and pause buttons
    buttons_attr = [
        attr(
            label = "Play",
            method = "animate",
            args = [
                nothing,
                attr(
                    fromcurrent = true,
                    transition = (duration = dt_frame,),
                    frame = attr(duration = dt_frame, redraw = true),
                ),
            ],
        ),
        attr(
            label = "Pause",
            method = "animate",
            args = [
                [nothing],
                attr(
                    mode = "immediate",
                    fromcurrent = true,
                    transition = attr(duration = dt_frame),
                    frame = attr(duration = dt_frame, redraw = true),
                ),
            ],
        ),
    ]

    #layout for the plot
    layout = Layout(
        width = 1500,
        height = 1000,
        margin_b = 90,
        # add buttons to play the animation
        updatemenus = [
            attr(
                x = 0.5,
                y = 0,
                yanchor = "top",
                xanchor = "center",
                showactive = true,
                direction = "left",
                type = "buttons",
                pad = attr(t = 90, r = 10),
                buttons = buttons_attr,
            ),
        ],
        #add the sliders
        sliders = sliders_attr,

        showlegend=showlegend,
        geo = attr(scope=geography,
                    showland=true,),
    )

    #save the plot and show it
    plotdata = Plot(trace, layout, frames)
    return plotdata
end

function animate_flows(supply_chain; geography="usa", showlegend=true, excluded_origins=[])
    origin_colors = Dict{Node, String}()
    ps = [plot_flows(supply_chain, i; geography=geography, showlegend=showlegend, excluded_origins=excluded_origins, origin_colors=origin_colors) for i in 1:supply_chain.horizon]

    #generate the initial frame
    trace = [scattergeo() for i in 1:length(getfield(ps[supply_chain.horizon], :data))]

    #store all frames in a vector
    frames = PlotlyFrame[
        frame(
            data = getfield(ps[k], :data), 
            layout = attr(title_text = "Period $k"), #update title
            name = "frame_$k", #update frame name
            traces = collect(1:length(getfield(ps[k], :data)))
        ) for k = 1:supply_chain.horizon
    ]

    #define the slider for manually viewing the frames
    sliders_attr = [
        attr(
            active = 0,
            minorticklen = 0,
            pad_t = 10,
            steps = [
                attr(
                    method = "animate",
                    label = "Period $k",
                    args = [
                        ["frame_$k"], #match the name of the frame again
                        attr(
                            mode = "immediate",
                            transition = attr(duration = 0),
                            frame = attr(duration = 5, redraw = true),
                        ),
                    ],
                ) for k = 1:supply_chain.horizon
            ],
        ),
    ]

    #define the displaying time per played frame (in milliseconds)
    dt_frame = 250

    #define the play and pause buttons
    buttons_attr = [
        attr(
            label = "Play",
            method = "animate",
            args = [
                nothing,
                attr(
                    fromcurrent = true,
                    transition = (duration = dt_frame,),
                    frame = attr(duration = dt_frame, redraw = true),
                ),
            ],
        ),
        attr(
            label = "Pause",
            method = "animate",
            args = [
                [nothing],
                attr(
                    mode = "immediate",
                    fromcurrent = true,
                    transition = attr(duration = dt_frame),
                    frame = attr(duration = dt_frame, redraw = true),
                ),
            ],
        ),
    ]

    #layout for the plot
    layout = Layout(
        width = 1500,
        height = 1000,
        margin_b = 90,
        # add buttons to play the animation
        updatemenus = [
            attr(
                x = 0.5,
                y = 0,
                yanchor = "top",
                xanchor = "center",
                showactive = true,
                direction = "left",
                type = "buttons",
                pad = attr(t = 90, r = 10),
                buttons = buttons_attr,
            ),
        ],
        #add the sliders
        sliders = sliders_attr,

        showlegend=showlegend,
        geo = attr(scope=geography,
                    showland=true,),
    )

    #save the plot and show it
    plotdata = Plot(trace, layout, frames)
    return plotdata
end