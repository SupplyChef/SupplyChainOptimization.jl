# Captures enough of a variable's original bound state to restore it exactly later.
# JuMP.fix(x, v; force=true) permanently discards any pre-existing bounds, and JuMP.unfix does
# not restore them - deliberately avoided here in favor of directly saving/restoring
# lower_bound/upper_bound (or their absence), so a variable that started unbounded above (like
# an Int >= 0 variable with no explicit upper bound) ends up unbounded above again, not stuck
# at whatever bound pinning last set.
struct _VariableBounds
    has_lower::Bool
    lower::Float64
    has_upper::Bool
    upper::Float64
end

function _capture_bounds(v)
    has_lower = has_lower_bound(v)
    has_upper = has_upper_bound(v)
    return _VariableBounds(has_lower, has_lower ? lower_bound(v) : -Inf, has_upper, has_upper ? upper_bound(v) : Inf)
end

function _restore_bounds!(v, bounds::_VariableBounds)
    if bounds.has_lower
        set_lower_bound(v, bounds.lower)
    elseif has_lower_bound(v)
        delete_lower_bound(v)
    end
    if bounds.has_upper
        set_upper_bound(v, bounds.upper)
    elseif has_upper_bound(v)
        delete_upper_bound(v)
    end
end

# Pins a variable to a single value by tightening both bounds to it, rather than JuMP.fix (see
# _VariableBounds above for why). Rounds first: an incumbent binary/integer value read back
# from a solver is occasionally e.g. 0.999999997 rather than exactly 1.0, which would otherwise
# pin against the variable's own binary/integer domain by a hair and risk a spurious
# infeasibility.
function _pin!(v, value)
    rounded = round(value)
    set_lower_bound(v, rounded)
    set_upper_bound(v, rounded)
end

# Picks n elements of collection at random, without replacement, using Base's global RNG (via
# plain rand(1:n) - no `using Random` needed, matching how SupplyChainSimulation.jl's own
# bboptimize does its own random search without importing Random either).
function _random_sample(collection, n)
    pool = collect(collection)
    n = min(n, length(pool))
    selected = eltype(pool)[]
    for _ in 1:n
        index = rand(1:length(pool))
        push!(selected, pool[index])
        deleteat!(pool, index)
    end
    return selected
end

"""
    matheuristic_optimize!(model::JuMP.Model; iterations=10, fix_fraction=0.8, neighborhood=:fix,
                           local_branching_k=20, time_limit_per_iteration=nothing)

A model-agnostic large-neighborhood-search matheuristic for MILP models built with JuMP.
Repeatedly destroys part of the current incumbent solution and re-solves the reduced problem,
keeping any improvement - large real-world MILPs (like [`minimize_cost!`](@ref)/
[`maximize_profits!`](@ref)'s network design problem, or
[`create_maturation_scheduling_model`](@ref)'s scheduling problem) can be too slow to solve to
proven optimality directly, but re-solving with most of the incumbent held fixed is typically
fast, and repeating this thousands of times finds much better solutions than stopping the direct
solve early.

Unlike a problem-specific matheuristic (e.g. the IPPDP paper this package's maturation-scheduling
model is based on uses a domain-aware clustering construction plus Shaw-relatedness removal
operators - see Gbéya, Darvish, Renaud and Coelho (2026), CIRRELT-2026-10), this function only
looks at `model`'s variables and their current values: it works on *any* JuMP model that already
has a feasible solution, with zero knowledge of what the variables mean. That genericity is also
its ceiling - a hand-tuned, problem-aware neighborhood (like the paper's) will typically still
beat this on any one problem; this is meant as a solid, reusable default, not a replacement for
one.

`model` must already have (or be able to find, via an initial `JuMP.optimize!` if it hasn't been
solved yet) at least one feasible solution - there is nothing to build a neighborhood *around*
otherwise. If `model` has no integer/binary variables at all, or no feasible solution can be
found, `model` is returned unchanged.

Two neighborhoods are available via `neighborhood`:
- `:fix` (the default, a RINS-style destroy operator): each iteration, a random
  `fix_fraction` of the integer/binary variables are pinned to their best-known values and the
  rest are re-optimized freely.
- `:local_branching` (Fischetti and Lodi, 2003): each iteration restricts the solution to
  differ from the best-known one in at most `local_branching_k` binary variables (a Hamming-ball
  neighborhood), leaving every variable itself free to move. Falls back to `:fix` if `model` has
  no binary variables (local branching's flip-counting constraint only applies to those).

`time_limit_per_iteration`, if given, is applied as a best-effort `"time_limit"` solver
attribute before each iteration's re-solve (silently ignored if the underlying solver doesn't
support that attribute name) - since each iteration only needs *a* feasible, hopefully-improving
solution, not a proof of optimality, bounding how long any single iteration can run keeps the
overall search moving instead of stalling on one hard sub-problem.

`model` is left, on return, re-solved at the best solution found (with every variable's bounds
restored to what they were before this function was called - the pinning done internally is not
left in place).
"""
function matheuristic_optimize!(model; iterations::Int=10, fix_fraction::Real=0.8, neighborhood::Symbol=:fix,
                                local_branching_k::Int=20, time_limit_per_iteration::Union{Nothing, Real}=nothing)
    neighborhood in (:fix, :local_branching) || throw(ArgumentError("matheuristic_optimize!: neighborhood must be :fix or :local_branching, got $(repr(neighborhood))"))
    0.0 <= fix_fraction <= 1.0 || throw(ArgumentError("matheuristic_optimize!: fix_fraction must be between 0 and 1, got $fix_fraction"))

    if !has_values(model)
        JuMP.optimize!(model)
    end
    if !has_values(model)
        return model
    end

    all_vars = JuMP.all_variables(model)
    discrete_vars = [v for v in all_vars if is_binary(v) || is_integer(v)]
    if isempty(discrete_vars)
        return model
    end
    binary_vars = [v for v in discrete_vars if is_binary(v)]

    original_bounds = Dict(v => _capture_bounds(v) for v in discrete_vars)

    is_minimization = objective_sense(model) == JuMP.MOI.MIN_SENSE
    improves(new_value, old_value) = is_minimization ? new_value < old_value : new_value > old_value

    best_objective = objective_value(model)
    best_values = Dict(v => value(v) for v in all_vars)

    if !isnothing(time_limit_per_iteration)
        try
            set_attribute(model, "time_limit", Float64(time_limit_per_iteration))
        catch
            # Best-effort: not every solver exposes a "time_limit" string attribute. Falling
            # back to running each iteration to completion is safe, just potentially slower.
        end
    end

    local_branching_constraint = nothing
    use_local_branching = neighborhood == :local_branching && !isempty(binary_vars)

    for _ in 1:iterations
        for v in discrete_vars
            _restore_bounds!(v, original_bounds[v])
        end
        if !isnothing(local_branching_constraint)
            delete(model, local_branching_constraint)
            local_branching_constraint = nothing
        end

        if use_local_branching
            ones = [v for v in binary_vars if best_values[v] > 0.5]
            zeros = [v for v in binary_vars if best_values[v] <= 0.5]
            local_branching_constraint = @constraint(model,
                sum(1 - v for v in ones; init=0.0) + sum(v for v in zeros; init=0.0) <= local_branching_k)
        else
            n_fix = round(Int, fix_fraction * length(discrete_vars))
            for v in _random_sample(discrete_vars, n_fix)
                _pin!(v, best_values[v])
            end
        end

        JuMP.optimize!(model)

        if has_values(model)
            candidate_objective = objective_value(model)
            if improves(candidate_objective, best_objective)
                best_objective = candidate_objective
                for v in all_vars
                    best_values[v] = value(v)
                end
            end
        end
    end

    # Restore every variable's bounds *before* the final solve below, not after: JuMP marks a
    # model "modified since last optimize!" the moment a bound changes, which invalidates the
    # cached solution - restoring bounds after the final optimize! would leave has_values/
    # objective_value/value unusable (OptimizeNotCalled()) for the caller. Restoring first and
    # solving last means this function's very last model-touching action is optimize! itself.
    for v in discrete_vars
        _restore_bounds!(v, original_bounds[v])
    end
    if !isnothing(local_branching_constraint)
        delete(model, local_branching_constraint)
    end

    # Original bounds are always a relaxation of whatever was pinned during the search, so
    # best_values remains feasible here - warm-starting from it means this final solve can only
    # match or improve on best_objective, never regress, even under a tight time limit.
    for v in all_vars
        set_start_value(v, best_values[v])
    end
    JuMP.optimize!(model)

    return model
end
