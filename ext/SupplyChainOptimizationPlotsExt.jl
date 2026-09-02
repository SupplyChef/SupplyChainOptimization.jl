# Package extension: loaded automatically once both PlotlyJS and Plots are
# `using`'d alongside SupplyChainOptimization. Split out from
# SupplyChainOptimizationPlotlyJSExt because movie_network is the only
# function that needs Plots (for Animation/mp4) on top of PlotlyJS -
# everything else only needs PlotlyJS. Keeping it separate means a consumer
# with just PlotlyJS loaded still gets plot_network/plot_costs/etc.; Plots
# is only required for this one video-export feature.
module SupplyChainOptimizationPlotsExt

using SupplyChainOptimization
using PlotlyJS: savefig
using Plots: Animation, buildanimation, mp4

"""
    movie_network

Makes a movie of the network evolution.
"""
function SupplyChainOptimization.movie_network(supply_chain, file_path;
                        geography="usa",
                        showlegend=true,
                        excluded_nodes=[],
                        groups=[(supply_chain.storages, "storage", "square", "blue", 1.0), (supply_chain.plants, "plant", "triangle-up", "red", 1.0)])
    ps = [SupplyChainOptimization.plot_network(supply_chain, i;
                        geography=geography,
                        showlegend=showlegend,
                        excluded_nodes=excluded_nodes,
                        groups=groups) for i in 1:supply_chain.horizon]

    mktempdir() do dir
        fnames = String[]
        for (i, p) in enumerate(ps)
            fname = lpad(i, 6, "0") * ".png"
            push!(fnames, fname)
            savefig(p, joinpath(dir, fname), width=700, height=500, scale=1)
        end

        anim = Animation(dir, fnames)
        mp4(anim, file_path; fps=1)
    end
end

end # module
