import Pkg; 
Pkg.add("CSV")
Pkg.add("DataFrames")
Pkg.add("JuMP")
Pkg.add("HiGHS")
Pkg.add("SupplyChainModeling")

using Documenter
using SupplyChainOptimization

makedocs(
    sitename = "SupplyChainOptimization",
    format = Documenter.HTML(),
    modules = [SupplyChainOptimization],
    checkdocs = :exports, # every exported symbol must have a docstring, and only exported symbols may be @docs'd - see docs/src/reference.md
    pages = ["index.md",
            "Examples" => ["optimization flows.md", "optimization locations.md", "multi-period optimization.md", "adding special constraints.md", "inventory movements.md", "maturation scheduling.md"],
            "Internals" => ["optimization model.md"],
            "API" => ["reference.md"],
            "Sponsor" => ["sponsor.md"]
            ]
)

deploydocs(;
    repo="https://github.com/SupplyChef/SupplyChainOptimization.jl",
    devbranch = "main"
)