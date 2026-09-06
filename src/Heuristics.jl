"""
Solves a relaxed variant of the network model (facility lifecycle binaries `opened`/
`opening`/`closing` relaxed to `[0, 1]` continuous; `used`/`serviced_by` left binary)
and returns rounded 0/1 values for every facility's `opened[s, t]`, keyed by `(s, t)`,
usable as a warm start for the real MIP. `opening`/`closing` aren't returned - they're
tightly forced by `opened[s, t-1]`/`opened[s, t]` in the real model's own constraints,
so a start value for `opened` alone is enough for HiGHS to pick them up quickly.

Returns `nothing` if the relaxed model itself doesn't solve to a usable solution
(e.g. infeasible data) - the caller should just skip the warm start in that case
rather than fail the whole optimize.
"""
function _relaxed_opened_values(supply_chain, objective::Symbol, optimizer, bigM; single_source, evergreen, use_direct_model, time_limit)
    m = objective == :min_cost ?
        create_network_cost_minimization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, relax=true) :
        create_network_profit_maximization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, relax=true)
    set_attribute(m, "log_to_console", false)
    # `used`/`serviced_by` stay binary even under relax=true (see create_network_model),
    # so this is still a MIP, just a smaller one - it needs its own time limit or it
    # could run as long as the real solve would have on a genuinely hard instance.
    isnothing(time_limit) || JuMP.set_time_limit_sec(m, time_limit)
    JuMP.optimize!(m)
    JuMP.has_values(m) || return nothing

    plants_storages = [x for x in union(supply_chain.plants, supply_chain.storages)]
    return Dict((s, t) => round(Int, clamp(JuMP.value(m[:opened][s, t]), 0, 1)) for s in plants_storages, t in 1:supply_chain.horizon)
end

"""
    warm_start_from_relaxation!(supply_chain, objective, optimizer=HiGHS.Optimizer; bigM, single_source, evergreen, use_direct_model)

Solves the model's LP-ish relaxation (see `_relaxed_opened_values`) and, if it
produces a usable solution, sets it as the start value for `opened` on
`supply_chain.optimization_model` (which must already be built - this only sets
start values, it doesn't optimize the real model). `opening`/`closing` are derived
from consecutive `opened` values and given a start value too, since deriving them
is essentially free and it further speeds up HiGHS locking in the facility
lifecycle. Returns `true` if a warm start was applied, `false` otherwise.
"""
function warm_start_from_relaxation!(supply_chain, objective::Symbol, optimizer=HiGHS.Optimizer; bigM=1_000_000, single_source=false, evergreen=true, use_direct_model=false)
    m = supply_chain.optimization_model
    opened_val = _relaxed_opened_values(supply_chain, objective, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, time_limit=JuMP.time_limit_sec(m))
    isnothing(opened_val) && return false

    plants_storages = [x for x in union(supply_chain.plants, supply_chain.storages)]
    horizon = supply_chain.horizon

    for s in plants_storages
        prev = Int(s.initial_opened)
        for t in 1:horizon
            cur = opened_val[(s, t)]
            JuMP.set_start_value(m[:opened][s, t], cur)
            JuMP.set_start_value(m[:opening][s, t], max(0, cur - prev))
            JuMP.set_start_value(m[:closing][s, t], max(0, prev - cur))
            prev = cur
        end
    end
    return true
end

"""
    solve_relax_and_fix!(supply_chain, objective, optimizer=HiGHS.Optimizer; bigM, single_source, evergreen, use_direct_model, window_size=3, time_limit_per_window=nothing)

Rolling-horizon relax-and-fix matheuristic over the facility `opened` decisions:
relaxes `opened[s, t]` to continuous for every period, then slides a `window_size`-period
window of real binaries across the horizon, solving and permanently `fix`ing each
window's rounded decisions before moving on. `opening`/`closing`/`used`/`serviced_by`
are left exactly as JuMP created them throughout - `opening`/`closing` get pinned
automatically by the real model's own constraints once the `opened` values on either
side of them are fixed, and `used`/`serviced_by` don't need relaxing since their
combinatorics are local to a single (lane, period)/(customer, period) pair.

Once every period is fixed, the resulting solve's *entire* solution (every variable,
not just `opened`) is captured and handed back to the real, fully-binary model as a
start value - not a permanent fix - so the caller's subsequent full-MIP solve (the
one `minimize_cost!`/`maximize_profits!` runs right after this) can still improve on
it within its own time budget.

`time_limit_per_window` bounds each window's sub-solve; when `nothing` (the default)
it's computed by splitting the model's current time limit evenly across the windows
plus one extra share reserved for that final full-MIP polish solve, so total wall
time stays roughly within the caller's original `time_limit` instead of multiplying
it by the number of windows. The model's original time limit is restored before
returning either way.

Returns `true` if at least one window solved to a usable solution, `false` otherwise
(e.g. the very first window was infeasible) - the real model is left untouched in
that case, so the caller's normal solve proceeds without a warm start.
"""
function solve_relax_and_fix!(supply_chain, objective::Symbol, optimizer=HiGHS.Optimizer; bigM=1_000_000, single_source=false, evergreen=true, use_direct_model=false, window_size=3, time_limit_per_window=nothing)
    m = supply_chain.optimization_model
    plants_storages = [x for x in union(supply_chain.plants, supply_chain.storages)]
    horizon = supply_chain.horizon
    n_windows = cld(horizon, window_size)

    original_time_limit = JuMP.time_limit_sec(m)
    per_window = something(time_limit_per_window, isnothing(original_time_limit) ? nothing : original_time_limit / (n_windows + 1))
    isnothing(per_window) || JuMP.set_time_limit_sec(m, per_window)
    JuMP.set_silent(m)

    for s in plants_storages, t in 1:horizon
        JuMP.unset_binary(m[:opened][s, t])
        JuMP.set_lower_bound(m[:opened][s, t], 0)
        JuMP.set_upper_bound(m[:opened][s, t], 1)
    end

    # Captured after each successful window solve, overwritten every time - so
    # once the loop stops (by finishing the horizon or hitting an infeasible/
    # timed-out window), this holds the *last* fully-consistent solution found,
    # not whatever (possibly solution-less) state the final `optimize!` call
    # left behind.
    snapshot = nothing
    window_start = 1
    while window_start <= horizon
        window = window_start:min(window_start + window_size - 1, horizon)
        for s in plants_storages, t in window
            JuMP.set_binary(m[:opened][s, t])
        end

        JuMP.optimize!(m)
        JuMP.has_values(m) || break

        snapshot = Dict(v => JuMP.value(v) for v in JuMP.all_variables(m))
        for s in plants_storages, t in window
            JuMP.fix(m[:opened][s, t], round(Int, clamp(JuMP.value(m[:opened][s, t]), 0, 1)); force=true)
        end
        window_start += window_size
    end

    for s in plants_storages, t in 1:horizon
        JuMP.is_fixed(m[:opened][s, t]) && JuMP.unfix(m[:opened][s, t])
        JuMP.is_binary(m[:opened][s, t]) || JuMP.set_binary(m[:opened][s, t])
    end
    if !isnothing(snapshot)
        for (v, val) in snapshot
            JuMP.set_start_value(v, val)
        end
    end

    isnothing(original_time_limit) ? JuMP.unset_time_limit_sec(m) : JuMP.set_time_limit_sec(m, original_time_limit)
    JuMP.unset_silent(m)
    return !isnothing(snapshot)
end

"""
Dispatches `minimize_cost!`/`maximize_profits!`'s `heuristic` kwarg. `:none` is a
no-op (default, unchanged behavior); `:warm_start` and `:relax_and_fix` prime
`supply_chain.optimization_model` (already built, with the caller's attributes
already set) with a start value before the caller's normal `JuMP.optimize!` runs.
"""
function apply_heuristic!(supply_chain, heuristic::Symbol, objective::Symbol, optimizer; single_source, evergreen, use_direct_model, bigM, window_size)
    if heuristic == :none
        return false
    elseif heuristic == :warm_start
        return warm_start_from_relaxation!(supply_chain, objective, optimizer; bigM=bigM, single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model)
    elseif heuristic == :relax_and_fix
        return solve_relax_and_fix!(supply_chain, objective, optimizer; bigM=bigM, single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, window_size=window_size)
    else
        throw(ArgumentError("unknown heuristic $(repr(heuristic)) (expected :none, :warm_start, or :relax_and_fix)"))
    end
end
