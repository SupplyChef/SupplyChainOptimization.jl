# Manual benchmark harness - NOT part of `Pkg.test()` (deliberately slow).
# Run with: `julia --project=. benchmark/run_benchmarks.jl`
#
# Compares, at a fixed time limit: the tightened-bigM formulation switched
# off (tighten_bigM=false, i.e. the flat bigM=1_000_000 behavior from before
# this branch - see src/Optimization.jl's effective_bigM) against baseline
# (tightening on, the new default) and the two opt-in heuristics
# (:warm_start, :relax_and_fix) plus a raised mip_heuristic_effort, on
# synthetic instances sized to actually leave a gap at the time limit (see
# generate_instance.jl for why test/UFLlib.jl's instances can't show this).
# tighten_bigM=false makes the no_tightening/baseline pair a same-run,
# same-instance A/B test of the big-M tightening's isolated effect, instead
# of needing a separate checkout of an earlier commit.
#
# Records gap-at-timeout, wall time, and the best objective found for each
# config, and prints a markdown table. INSTANCES varies structure (capacity
# pressure, lane fixed-cost density, single- vs multi-period, horizon length),
# not just scale, so a difference in results is attributable to a specific
# axis - see generate_instance.jl's docstring for what each kwarg controls.
# Extend INSTANCES/CONFIGS below to add more axes or heuristic settings once
# real results suggest where to push further.
#
# Every config is given the SAME TIME_LIMIT as a total wall-clock budget, for
# an apples-to-apples comparison - warm_start/relax_and_fix used to silently
# spend up to ~2x TIME_LIMIT (a full share for their own sub-solve(s) *plus*
# an untouched full share for the final real solve), which made their results
# look better than a fair comparison would show. Both now cap their own
# sub-solve time and hand the real solve only what's left of TIME_LIMIT - see
# warm_start_from_relaxation!/solve_relax_and_fix!'s docstrings.
#
# 6 instances x 5 configs at up to TIME_LIMIT each (plus model-build overhead) -
# still takes a while, budget well over half an hour for a full run.

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
    # Each variant below changes exactly one structural axis from "small",
    # so a difference in results is attributable to that axis rather than a
    # scale change. Same TIME_LIMIT/CONFIGS as small/medium for comparability.
    ("small_uncapacitated", () -> generate_instance(; horizon=6, customer_count=40, storage_count=10, plant_count=2, capacity_headroom=100.0)),
    ("small_sparse_fixed_cost", () -> generate_instance(; horizon=6, customer_count=40, storage_count=10, plant_count=2, lane_fixed_cost_probability=0.15)),
    ("small_single_period", () -> generate_instance(; horizon=1, customer_count=40, storage_count=10, plant_count=2)),
    ("medium_long_horizon", () -> generate_instance(; horizon=24, customer_count=150, storage_count=30, plant_count=3)),
]

const CONFIGS = [
    ("no_tightening", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, tighten_bigM=false, log=true)),
    ("baseline", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, log=true)),
    ("warm_start", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, heuristic=:warm_start, log=true)),
    ("relax_and_fix", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, heuristic=:relax_and_fix, log=true)),
    ("heuristic_effort", sc -> SupplyChainOptimization.minimize_cost!(sc; time_limit=TIME_LIMIT, mip_heuristic_effort=0.2, log=true)),
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
            # One config erroring (e.g. termination_status/has_values never
            # became true - no incumbent found in time, or a real
            # infeasibility) shouldn't cost every other row in the run; a
            # bad row and an explicit note about it is more useful here than
            # losing an hour of solves to one failure.
            try
                solve!(sc)
                elapsed = Dates.value(Dates.now() - start) / 1000.0
                push!(rows, (instance=iname, config=cname, status=string(termination_status(sc.optimization_model)),
                              gap=relative_gap(sc.optimization_model), objective=get_total_costs(sc), seconds=elapsed))
            catch e
                elapsed = Dates.value(Dates.now() - start) / 1000.0
                status = try
                    string(termination_status(sc.optimization_model))
                catch
                    "ERROR"
                end
                println("[$iname/$cname] failed after $(round(elapsed; digits=1))s (status: $status): $e")
                push!(rows, (instance=iname, config=cname, status=status, gap=NaN, objective=NaN, seconds=elapsed))
            end
        end
    end

    println("| instance | config | status | gap | objective | seconds |")
    println("|---|---|---|---|---|---|")
    for r in rows
        gap_str = isnan(r.gap) ? "n/a" : string(round(100 * r.gap; digits=2), "%")
        obj_str = isnan(r.objective) ? "n/a" : string(round(r.objective; digits=1))
        println("| $(r.instance) | $(r.config) | $(r.status) | $gap_str | $obj_str | $(round(r.seconds; digits=1)) |")
    end
    return rows
end

run()
