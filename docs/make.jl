using Documenter
using SupplyChainOptimization

makedocs(
    sitename = "SupplyChainOptimization",
    format = Documenter.HTML(),
    modules = [SupplyChainOptimization]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
#=deploydocs(
    repo = "<repository url>"
)=#
