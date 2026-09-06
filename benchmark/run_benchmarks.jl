# Manual benchmark harness - NOT part of `Pkg.test()` (deliberately slow).
# Run with: `julia --project=. benchmark/run_benchmarks.jl`
#
# Compares, at a fixed time limit, the model's default behavior (which always
# includes the tightened bigM from src/Optimization.jl - that change isn't
# behind a flag, since it's provably never worse) against the two opt-in
# heuristics (:warm_start, :relax_and_fix) and a raised mip_heuristic_effort,
# on synthetic instances sized to actually leave a gap at the time limit (see
# generate_instance.jl for why test/UFLlib.jl's instances can't show this).
#
# Records gap-at-timeout, wall time, and the best objective found for each
# config, and prints a markdown table. Extend INSTANCES/CONFIGS below to add
# more scale points or heuristic settings once real results suggest where to
# push further.

using SupplyChainOptimization
using SupplyChainModeling
using HiGHS
using JuMP
using Dates

include("generate_instance.jl")

const TIME_LIMIT = 120.0

const INSTANCES = [
    ("small", () -> generate_instance(; horizon=6, customer_count=40, storage_count=10, plant_count=2)),
    ("medium", () -> generate_instance(; horizon=12, customer_count=150, storage_count=30, plant_count=3)),
]

const CONFIGS = [
    ("baseline", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT)),
    ("warm_start", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, heuristic=:warm_start)),
    ("relax_and_fix", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, heuristic=:relax_and_fix)),
    ("heuristic_effort", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, mip_heuristic_effort=0.2)),
]

function relative_gap(model)
    try
        gap = JuMP.relative_gap(model)
        return isfinite(gap) ? gap : NaN
    catch
        return NaN
    end
end

function run()
    rows = []
    for (iname, ibuilder) in INSTANCES
        for (cname, solve!) in CONFIGS
            sc = ibuilder()
            start = Dates.now()
            solve!(sc)
            elapsed = Dates.value(Dates.now() - start) / 1000.0
            push!(rows, (instance=iname, config=cname, status=string(termination_status(sc.optimization_model)),
                          gap=relative_gap(sc.optimization_model), objective=get_total_costs(sc), seconds=elapsed))
        end
    end

    println("| instance | config | status | gap | objective | seconds |")
    println("|---|---|---|---|---|---|")
    for r in rows
        gap_str = isnan(r.gap) ? "n/a" : string(round(100 * r.gap; digits=2), "%")
        println("| $(r.instance) | $(r.config) | $(r.status) | $gap_str | $(round(r.objective; digits=1)) | $(round(r.seconds; digits=1)) |")
    end
    return rows
end

run()
