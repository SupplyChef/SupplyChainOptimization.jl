"""
Solves a full linear relaxation of the network model (all binary variables relaxed
to `[0, 1]` continuous) and partitions facility decisions:
- Definite Open (`x >= 0.8`): fixed open (1)
- Definite Closed (`x <= 0.05`): fixed closed (0)
- Undecided (`0.05 < x < 0.8`): left as binary variables in the sub-MIP.

Then solves a fast sub-MIP with undecided facilities left binary, allowing the solver
to optimize fixed costs versus flow costs without over-opening warehouses.

Returns `(sub_model=m_sub, status=status)` if successful, or `nothing` if no
usable solution was found.
"""
function _relaxed_solution_hints(supply_chain, objective::Symbol, optimizer, bigM; single_source, evergreen, use_direct_model, tighten_bigM=true, time_limit, log=false)
    m = objective == :min_cost ?
        create_network_cost_minimization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, tighten_bigM=tighten_bigM, relax=true) :
        create_network_profit_maximization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, tighten_bigM=tighten_bigM, relax=true)
    set_attribute(m, "log_to_console", false)
    isnothing(time_limit) || JuMP.set_time_limit_sec(m, time_limit)
    if log
        n_binary_relaxed = count(JuMP.is_binary, JuMP.all_variables(m))
        n_binary_real = count(JuMP.is_binary, JuMP.all_variables(supply_chain.optimization_model))
        println("[warm_start] relaxed model: $n_binary_relaxed binary vars (real model: $n_binary_real)")
    end
    start = time()
    JuMP.optimize!(m)
    elapsed = time() - start
    if !JuMP.has_values(m)
        log && println("[warm_start] relaxed solve found NO solution in $(round(elapsed; digits=1))s (status: $(JuMP.termination_status(m))) - skipping warm start")
        return nothing
    end
    log && println("[warm_start] relaxed solve found objective $(JuMP.objective_value(m)) in $(round(elapsed; digits=1))s (status: $(JuMP.termination_status(m)))")

    plants_storages_index = get_plant_storage_index(supply_chain)
    plants_storages, psidx = plants_storages_index.items, plants_storages_index.index
    horizon = supply_chain.horizon
    lp_opened = Dict((s, t) => clamp(JuMP.value(m[:opened][psidx[s], t]), 0.0, 1.0) for s in plants_storages, t in 1:horizon)

    status = Dict{Tuple{Any,Int},Symbol}()
    for s in plants_storages, t in 1:horizon
        val = lp_opened[(s, t)]
        if val >= 0.8
            status[(s, t)] = :open
        elseif val <= 0.05
            status[(s, t)] = :closed
        else
            status[(s, t)] = :undecided
        end
    end

    # Aggregate Capacity Safeguard: ensure open + undecided capacity covers period demand
    customers = supply_chain.customers
    horizon_range = 1:horizon
    products = [p for p in supply_chain.products if any(get_demand(supply_chain, c, p, t) > 0 for c in customers, t in horizon_range)]
    if !isempty(products)
        min_service_level = minimum(get_service_level(supply_chain, c, p) for c in customers, p in products; init=1.0)
        capacity = Dict(s => sum(get_maximum_throughput(s, p) for p in products; init=0.0) for s in plants_storages)
        by_lp_desc = sort(plants_storages; by=s -> capacity[s], rev=true)

        n_promoted = 0
        for t in 1:horizon
            required = min_service_level * sum(get_demand(supply_chain, c, p, t) for c in customers, p in products; init=0.0)
            available = sum(capacity[s] for s in plants_storages if status[(s, t)] in (:open, :undecided); init=0.0)
            available >= required && continue
            for s in by_lp_desc
                status[(s, t)] in (:open, :undecided) && continue
                status[(s, t)] = :undecided
                n_promoted += 1
                available += capacity[s]
                available >= required && break
            end
        end
        log && n_promoted > 0 && println("[warm_start] capacity safeguard promoted $n_promoted closed facility-periods to candidate set")
    end

    n_open = count(==(:open), values(status))
    n_closed = count(==(:closed), values(status))
    n_undecided = count(==(:undecided), values(status))
    log && println("[warm_start] facility decisions: $n_open fixed open, $n_closed fixed closed, $n_undecided undecided (binary in sub-MIP)")

    # Polish step: construct and solve sub-MIP with undecided facilities left binary
    m_sub = objective == :min_cost ?
        create_network_cost_minimization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, tighten_bigM=tighten_bigM, relax=false) :
        create_network_profit_maximization_model(supply_chain, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, tighten_bigM=tighten_bigM, relax=false)
    set_attribute(m_sub, "log_to_console", false)

    for s in plants_storages, t in 1:horizon
        st = status[(s, t)]
        if st == :open
            JuMP.fix(m_sub[:opened][psidx[s], t], 1; force=true)
        elseif st == :closed
            JuMP.fix(m_sub[:opened][psidx[s], t], 0; force=true)
        end
    end

    rem_time = isnothing(time_limit) ? nothing : max(1.0, time_limit - elapsed)
    isnothing(rem_time) || JuMP.set_time_limit_sec(m_sub, rem_time)

    sub_start = time()
    JuMP.optimize!(m_sub)
    sub_elapsed = time() - sub_start

    # Fallback: if sub-MIP is infeasible, unfix closed facilities and retry
    if !JuMP.has_values(m_sub)
        log && println("[warm_start] sub-MIP with fixed closed facilities found NO solution in $(round(sub_elapsed; digits=1))s - running fallback with all facilities available")
        for s in plants_storages, t in 1:horizon
            if status[(s, t)] == :closed
                JuMP.unfix(m_sub[:opened][psidx[s], t])
                JuMP.set_binary(m_sub[:opened][psidx[s], t])
            end
        end
        rem_time2 = isnothing(time_limit) ? nothing : max(1.0, time_limit - (elapsed + sub_elapsed))
        isnothing(rem_time2) || JuMP.set_time_limit_sec(m_sub, rem_time2)
        sub_start = time()
        JuMP.optimize!(m_sub)
        sub_elapsed += time() - sub_start
    end

    if !JuMP.has_values(m_sub)
        log && println("[warm_start] sub-MIP polish found NO solution - skipping warm start")
        return nothing
    end

    log && println("[warm_start] sub-MIP polish found feasible solution with objective $(JuMP.objective_value(m_sub)) in $(round(sub_elapsed; digits=1))s")

    return (sub_model=m_sub, status=status)
end

"""
    warm_start_from_relaxation!(supply_chain, objective, optimizer=HiGHS.Optimizer; bigM, single_source, evergreen, use_direct_model, relaxation_time_fraction=0.3)

Solves the LP relaxation and a fast polishing sub-MIP (see `_relaxed_solution_hints`)
to produce a complete, guaranteed-feasible solution. Sets these values as warm start
initial values on `supply_chain.optimization_model`. Returns `true` if a warm start
was applied, `false` otherwise.
"""
function warm_start_from_relaxation!(supply_chain, objective::Symbol, optimizer=HiGHS.Optimizer; bigM=1_000_000, single_source=false, evergreen=true, use_direct_model=false, tighten_bigM=true, relaxation_time_fraction=0.3, log=false)
    m = supply_chain.optimization_model
    total_time_limit = JuMP.time_limit_sec(m)
    relaxation_budget = isnothing(total_time_limit) ? nothing : total_time_limit * relaxation_time_fraction

    start = time()
    hints = _relaxed_solution_hints(supply_chain, objective, optimizer, bigM; single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, tighten_bigM=tighten_bigM, time_limit=relaxation_budget, log=log)
    elapsed = time() - start

    if !isnothing(total_time_limit)
        remaining = max(1.0, total_time_limit - elapsed)
        JuMP.set_time_limit_sec(m, remaining)
        log && println("[warm_start] relaxation used $(round(elapsed; digits=1))s of the $(total_time_limit)s budget - $(round(remaining; digits=1))s left for the real solve")
    end

    isnothing(hints) && return false

    vars_sub = JuMP.all_variables(hints.sub_model)
    vars_real = JuMP.all_variables(m)

    if length(vars_sub) == length(vars_real)
        for (v_sub, v_real) in zip(vars_sub, vars_real)
            if JuMP.has_values(hints.sub_model)
                JuMP.set_start_value(v_real, JuMP.value(v_sub))
            end
        end
    else
        plants_storages_index = get_plant_storage_index(supply_chain)
        plants_storages, psidx = plants_storages_index.items, plants_storages_index.index
        horizon = supply_chain.horizon
        for s in plants_storages, t in 1:horizon
            si = psidx[s]
            JuMP.set_start_value(m[:opened][si, t], JuMP.value(hints.sub_model[:opened][si, t]))
            JuMP.set_start_value(m[:opening][si, t], JuMP.value(hints.sub_model[:opening][si, t]))
            JuMP.set_start_value(m[:closing][si, t], JuMP.value(hints.sub_model[:closing][si, t]))
        end
        for l in supply_chain.lanes, t in 1:horizon
            if (l.minimum_quantity > 0 || l.fixed_cost > 0) && haskey(hints.sub_model[:used], (l, t))
                JuMP.set_start_value(m[:used][l, t], JuMP.value(hints.sub_model[:used][l, t]))
            end
        end
        if single_source
            pidx = get_product_index(supply_chain).index
            sidx = get_storage_index(supply_chain).index
            cidx = get_customer_index(supply_chain).index
            for p in supply_chain.products, s in supply_chain.storages, c in supply_chain.customers, t in 1:horizon
                pi_, si_, ci_ = pidx[p], sidx[s], cidx[c]
                JuMP.set_start_value(m[:serviced_by][pi_, si_, ci_, t], JuMP.value(hints.sub_model[:serviced_by][pi_, si_, ci_, t]))
            end
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
plus one extra share reserved for that final full-MIP polish solve. Before returning,
the model's time limit is set to whatever's left of the *original* budget after the
window phase (not restored to the full original), so total wall time - window phase
plus the caller's subsequent real solve - stays within the caller's original
`time_limit` instead of using it twice.

Returns `true` if at least one window solved to a usable solution, `false` otherwise
(e.g. the very first window was infeasible) - the real model is left untouched in
that case, so the caller's normal solve proceeds without a warm start.
"""
function solve_relax_and_fix!(supply_chain, objective::Symbol, optimizer=HiGHS.Optimizer; bigM=1_000_000, single_source=false, evergreen=true, use_direct_model=false, window_size=3, time_limit_per_window=nothing, log=false)
    m = supply_chain.optimization_model
    plants_storages_index = get_plant_storage_index(supply_chain)
    plants_storages, psidx = plants_storages_index.items, plants_storages_index.index
    horizon = supply_chain.horizon
    n_windows = cld(horizon, window_size)

    original_time_limit = JuMP.time_limit_sec(m)
    per_window = something(time_limit_per_window, isnothing(original_time_limit) ? nothing : original_time_limit / (n_windows + 1))
    isnothing(per_window) || JuMP.set_time_limit_sec(m, per_window)
    JuMP.set_silent(m)
    log && println("[relax_and_fix] $n_windows windows of size $window_size, $(isnothing(per_window) ? "no" : round(per_window; digits=1)) s/window budget")

    for s in plants_storages, t in 1:horizon
        JuMP.unset_binary(m[:opened][psidx[s], t])
        JuMP.set_lower_bound(m[:opened][psidx[s], t], 0)
        JuMP.set_upper_bound(m[:opened][psidx[s], t], 1)
    end

    # Captured after each successful window solve, overwritten every time - so
    # once the loop stops (by finishing the horizon or hitting an infeasible/
    # timed-out window), this holds the *last* fully-consistent solution found,
    # not whatever (possibly solution-less) state the final `optimize!` call
    # left behind.
    snapshot = nothing
    total_elapsed = 0.0
    window_start = 1
    while window_start <= horizon
        window = window_start:min(window_start + window_size - 1, horizon)
        for s in plants_storages, t in window
            JuMP.set_binary(m[:opened][psidx[s], t])
        end

        wstart = time()
        JuMP.optimize!(m)
        welapsed = time() - wstart
        total_elapsed += welapsed
        if !JuMP.has_values(m)
            log && println("[relax_and_fix] window $window: NO solution in $(round(welapsed; digits=1))s (status: $(JuMP.termination_status(m))) - stopping, falling back to whatever was fixed so far")
            break
        end
        log && println("[relax_and_fix] window $window: objective $(JuMP.objective_value(m)) in $(round(welapsed; digits=1))s (status: $(JuMP.termination_status(m)))")

        # Read every value first, then write (fix) - interleaving JuMP.value
        # reads with model-modifying calls in the same loop invalidates JuMP's
        # cached solution mid-loop (JuMP warns and then OptimizeNotCalled()s
        # on the very next value() call), so `fix` below reads from this
        # already-fully-populated snapshot instead of calling JuMP.value again.
        snapshot = Dict(v => JuMP.value(v) for v in JuMP.all_variables(m))
        for s in plants_storages, t in window
            JuMP.fix(m[:opened][psidx[s], t], round(Int, clamp(snapshot[m[:opened][psidx[s], t]], 0, 1)); force=true)
        end
        window_start += window_size
    end
    log && println("[relax_and_fix] ", isnothing(snapshot) ? "no window ever produced a usable solution - no warm start applied" : "warm start captured from the last successful window")

    for s in plants_storages, t in 1:horizon
        JuMP.is_fixed(m[:opened][psidx[s], t]) && JuMP.unfix(m[:opened][psidx[s], t])
        JuMP.is_binary(m[:opened][psidx[s], t]) || JuMP.set_binary(m[:opened][psidx[s], t])
    end
    if !isnothing(snapshot)
        for (v, val) in snapshot
            JuMP.set_start_value(v, val)
        end
    end

    # Give the caller's subsequent real solve whatever's left of the original
    # budget, not the full original again - restoring the full amount here is
    # what silently let this heuristic use up to ~2x the caller's time_limit
    # (the window phase's own time plus a second full share for the real solve).
    if isnothing(original_time_limit)
        JuMP.unset_time_limit_sec(m)
    else
        remaining = max(1.0, original_time_limit - total_elapsed)
        JuMP.set_time_limit_sec(m, remaining)
        log && println("[relax_and_fix] windows used $(round(total_elapsed; digits=1))s of the $(original_time_limit)s budget - $(round(remaining; digits=1))s left for the real solve")
    end
    JuMP.unset_silent(m)
    return !isnothing(snapshot)
end

"""
Dispatches `minimize_cost!`/`maximize_profits!`'s `heuristic` kwarg. `:none` is a
no-op (default, unchanged behavior); `:warm_start` and `:relax_and_fix` prime
`supply_chain.optimization_model` (already built, with the caller's attributes
already set) with a start value before the caller's normal `JuMP.optimize!` runs.
"""
function apply_heuristic!(supply_chain, heuristic::Symbol, objective::Symbol, optimizer; single_source, evergreen, use_direct_model, bigM, tighten_bigM=true, window_size, log=false)
    if heuristic == :none
        return false
    elseif heuristic == :warm_start
        return warm_start_from_relaxation!(supply_chain, objective, optimizer; bigM=bigM, single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, tighten_bigM=tighten_bigM, log=log)
    elseif heuristic == :relax_and_fix
        return solve_relax_and_fix!(supply_chain, objective, optimizer; bigM=bigM, single_source=single_source, evergreen=evergreen, use_direct_model=use_direct_model, window_size=window_size, log=log)
    else
        throw(ArgumentError("unknown heuristic $(repr(heuristic)) (expected :none, :warm_start, or :relax_and_fix)"))
    end
end
