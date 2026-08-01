import Pkg;
Pkg.add("CSV")
Pkg.add("DataFrames")
Pkg.add("JuMP")
Pkg.add("HiGHS")
# docs/ is a separate Pkg environment from the package root, so the root Project.toml's
# [sources] override (see the comment there) isn't inherited here - a plain
# Pkg.add("SupplyChainModeling") resolves the registry's latest release (0.2.8, stale relative
# to main), so it's pinned to the git source explicitly here too, matching
# .github/workflows/ci.yml.
Pkg.add(url="https://github.com/SupplyChef/SupplyChainModeling.jl", rev="main")

using Documenter
using SupplyChainOptimization

makedocs(
    sitename = "SupplyChainOptimization",
    format = Documenter.HTML(),
    modules = [SupplyChainOptimization],
    checkdocs = :exports, # every exported symbol must have a docstring, and only exported symbols may be @docs'd - see docs/src/reference.md
    pages = ["index.md",
            "Examples" => ["optimization flows.md", "optimization locations.md", "multi-period optimization.md", "adding special constraints.md", "inventory movements.md", "maturation scheduling.md", "matheuristics.md"],
            "Internals" => ["optimization model.md"],
            "API" => ["reference.md"],
            "Sponsor" => ["sponsor.md"]
            ]
)

deploydocs(;
    repo="https://github.com/SupplyChef/SupplyChainOptimization.jl",
    devbranch = "main"
)