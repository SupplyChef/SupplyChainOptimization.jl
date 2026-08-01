using Dates

# Reproduces the instance-generation recipe of Section 6.1 of Gbéya, Darvish, Renaud and Coelho
# (2026), "Integrated Poultry Production-Distribution Optimization", CIRRELT-2026-10, using only
# this package's public, generic constructs (MaturationSource, QuotaSink,
# create_maturation_scheduling_model) - not a poultry-specific code path. Every parameter below
# is taken directly from the paper's own text; two points aren't fully pinned down there and are
# called out explicitly rather than silently guessed:
#   1. Day 1 of the horizon is assumed to be a Monday (the paper doesn't say) for the
#      Wednesday/Saturday/Sunday exclusions used to build U and V.
#   2. The single-slaughterhouse quota derivation ("multiply the average available capacity per
#      delivery day by a factor randomly selected from (0.1, 0.8); if the result exceeds the
#      maximum farm capacity, it is set as the quota; otherwise a random number between 0.1 and
#      0.5 is applied to adjust it") is reconstructed from prose, not a formula, and the second
#      branch in particular is ambiguous about direction; this uses the closest faithful reading
#      while still enforcing the paper's own explicit requirement ("the quota must exceed the
#      farm capacities").
# Since a different random draw was used, this does not - and does not claim to - reproduce the
# paper's own reported figures exactly (which aren't available from this session's copy of the
# paper past Section 6.2 anyway). What it does demonstrate is that the same instance-generation
# recipe, expressed purely through public MaturationSource/QuotaSink/
# create_maturation_scheduling_model calls, produces a feasible, sensibly-decomposed solution
# directly comparable in *structure* to the paper's own Figure 2 (OF = OF_d + OF_w + OF_q+ + OF_q-).
function _paper_instance(num_farms::Int, num_sinks::Int, weeks::Int)
    horizon = weeks * 7
    sc = SupplyChain(horizon)
    bird = Product("bird")
    add_product!(sc, bird)

    delta_under, delta_over = 0.1, 0.1
    xi_under, xi_over = 0.05, 0.05
    W = 22500.0     # target weight, dg
    phi = 380.0     # initial weight, dg
    g1, g2 = 0.0007, 0.001

    day_of_week(t) = (t - 1) % 7   # 0=Mon, ..., 5=Sat, 6=Sun (day 1 assumed Monday - see header)
    is_start_day(t) = !(day_of_week(t) in (2, 5, 6))   # exclude Wed, Sat, Sun
    is_delivery_day(t) = !(day_of_week(t) in (5, 6))   # exclude Sat, Sun

    v_start_candidate = ceil(Int, 7 * weeks / 2.5)
    v_start = first(t for t in v_start_candidate:horizon if is_delivery_day(t))
    is_paper_delivery_day(t) = t >= v_start && is_delivery_day(t)
    min_v = v_start

    alpha = (W * (1 - delta_under - xi_under) - phi) / min_v
    beta = (W * (1 + delta_over + xi_over) - phi) / min_v

    farms_in_cleaning = Set(_random_sample_indices(num_farms, round(Int, 0.1 * num_farms)))

    for f in 1:num_farms
        capacity = Float64(rand(4000:32000))
        growth_rate = Float64(rand(ceil(Int, alpha):floor(Int, beta)))
        unavailable = f in farms_in_cleaning ? rand(1:max(weeks - 1, 1)) : 0
        farm = MaturationSource("farm$f", Location(rand(0:270), rand(0:270)); capacity=capacity, unavailable_periods=unavailable)
        add_product!(farm, bird; initial_value=phi, maturation_rate=growth_rate, target_value=W,
                                 acceptable_deviation_under=delta_under, acceptable_deviation_over=delta_over,
                                 extended_deviation_under=xi_under, extended_deviation_over=xi_over,
                                 underrun_unit_penalty=g1, overrun_unit_penalty=g2)
        add_maturation_source!(sc, farm)
    end

    total_capacity = sum(f.capacity for f in sc.maturation_sources)
    max_capacity = maximum(f.capacity for f in sc.maturation_sources)
    num_delivery_days = count(is_paper_delivery_day, 1:horizon)
    average_capacity_per_delivery_day = total_capacity / num_delivery_days

    # 50/30/20-style geometric split for multi-sink instances, single sink gets the whole quota.
    raw_shares = [0.6^(i - 1) for i in 1:num_sinks]
    shares = raw_shares ./ sum(raw_shares)

    for (i, share) in enumerate(shares)
        candidate = average_capacity_per_delivery_day * share * (0.1 + rand() * 0.7)
        quota = candidate > max_capacity * share ? candidate : max_capacity * share * (1.1 + rand() * 0.4)
        sink = QuotaSink("slaughterhouse$i", Location(rand(0:50), rand(0:150)))
        add_product!(sink, bird; quota=round(quota), underproduction_unit_penalty=1.0, overproduction_unit_penalty=1.0)
        add_quota_sink!(sc, sink)
    end

    return sc, is_start_day, is_paper_delivery_day
end

function _random_sample_indices(n, k)
    pool = collect(1:n)
    k = min(k, n)
    selected = Int[]
    for _ in 1:k
        index = rand(1:length(pool))
        push!(selected, pool[index])
        deleteat!(pool, index)
    end
    return selected
end

# Plane-coordinate Euclidean distance, rounded to the nearest km - the paper's farms/
# slaughterhouses are placed on an abstract 270x270 / 50x150 grid, not real latitude/longitude,
# so haversine (spherical) doesn't apply; distance is a plain function argument to
# create_maturation_scheduling_model precisely so callers can supply whatever geometry fits
# their own data, without the model itself assuming anything about it.
function _euclidean_km(location1::Location, location2::Location)
    return round(sqrt((location1.latitude - location2.latitude)^2 + (location1.longitude - location2.longitude)^2))
end

@testset "PaperReplication" begin

@test begin
    num_farms, num_sinks, weeks = 60, 1, 6
    sc, is_start_day, is_delivery_day = _paper_instance(num_farms, num_sinks, weeks)

    # transport_cost_per_distance=1.0 (matching the underrun/overrun quota penalties' scale of
    # $1/bird) was tried first and made every instance degenerate: a bird's transport cost is
    # distance * transport_cost_per_distance * capacity, and on this 270x270 grid distances run
    # into the hundreds, so shipping anywhere cost far more per bird than just eating the $1/bird
    # quota underproduction penalty - the solver's global optimum was to never ship a single
    # batch (OF_d=OF_w=0, all cost dumped into OF_q-). Scaling by the grid's own diagonal
    # (~382 units) keeps a bird's transport cost below $1 for any farm-sink pair in this instance,
    # so shipping is never structurally dominated regardless of distance, and the replication
    # exercises the model's actual start/ship timing and quota trade-offs instead of a trivial
    # all-zero solution.
    transport_cost_per_distance = 1.0 / 400.0
    m = create_maturation_scheduling_model(sc, HiGHS.Optimizer; transport_cost_per_distance=transport_cost_per_distance,
                                           distance=_euclidean_km, is_start_day=is_start_day, is_delivery_day=is_delivery_day)
    set_silent(m)
    # A hard time limit is not just courtesy here: once transport cost stopped being trivially
    # dominated (see above), this instance became genuinely hard for HiGHS's B&B, and one CI run
    # left unbounded churned for over two hours before HiGHS's own RINS/RENS sub-MIP heuristics
    # segfaulted (a HiGHS-internal crash, not a bug in this package's model). Bounding the solve
    # avoids both the multi-hour CI run and, empirically, the crash - HiGHS returns its best
    # incumbent (has_values may still be true under TIME_LIMIT).
    set_attribute(m, "time_limit", 60.0)
    JuMP.optimize!(m)
    sc.optimization_model = m

    solved = has_values(m)

    if solved
        of = get_total_costs(sc)
        of_d = get_total_transportation_costs(sc)
        of_w = get_total_deviation_costs(sc)
        of_q_plus = get_total_overproduction_costs(sc)
        of_q_minus = get_total_underproduction_costs(sc)

        println("--- Paper replication (IPPDP-$num_farms-$num_sinks-$weeks style instance) ---")
        println("OF=$of (OF_d=$of_d, OF_w=$of_w, OF_q+=$of_q_plus, OF_q-=$of_q_minus)")
        println("status=$(termination_status(m)), consistent with breakdown: $(isapprox(of, of_d + of_w + of_q_plus + of_q_minus; rtol=1e-6))")
    end

    # Structural checks, not a numeric match to the paper's own (unreproducible, different-seed)
    # figures: the instance must be solvable, the reported total must equal its own reported
    # components (exactly like the paper's Figure 2), and at least one farm must actually ship -
    # guarding against a regression back to the all-zero-shipment degeneracy described above.
    solved &&
        isapprox(get_total_costs(sc), get_total_transportation_costs(sc) + get_total_deviation_costs(sc) + get_total_quota_deviation_costs(sc); rtol=1e-6) &&
        get_total_transportation_costs(sc) > 0
end

end
