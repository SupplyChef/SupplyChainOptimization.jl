using Documenter
using SupplyChainOptimization

makedocs(
    sitename = "SupplyChainOptimization",
    format = Documenter.HTML(),
    modules = [SupplyChainOptimization],
    pages = ["index.md",
            "Examples" => ["optimization flows.md", "optimization locations.md", "multi-period optimization.md", "adding special constraints.md", "inventory movements.md"],
            "Internals" => ["optimization model.md"],
            "API" => ["reference.md"],
            "Sponsor" => ["sponsor.md"]
            ]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
#=deploydocs(
    repo = "<repository url>"
)=#
