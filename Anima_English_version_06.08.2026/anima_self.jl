# A N I M A  —  Self  (Julia)
#
# A system that knows what it is — and can be wrong about itself.
# Without this file: the subject exists, but doesn't know that it exists.
# With this file: the subject has a self-model, which can be wrong,
# and feels the gap between the expected self and the actual self.

# Requires: anima_core.jl

# --- Self Belief ------------------------------------------------------------

mutable struct SelfBelief
    name::String
    confidence::Float64
    centrality::Float64
    rigidity::Float64
    dependents::Vector{String}
    origin::Symbol
    confirmations::Int
    violations::Int
    last_challenged_flash::Int
end

function SelfBelief(
    name::String;
    confidence = 0.7,
    centrality = 0.5,
    rigidity = 0.5,
    dependents = String[],
    origin = :learned,
)
    SelfBelief(name, confidence, centrality, rigidity, dependents, origin, 0, 0, 0)
end

belief_weight(b::SelfBelief) = b.confidence * (0.5 + b.centrality * 0.5)
belief_under_pressure(b::SelfBelief) = b.confidence < 0.35
belief_collapsed(b::SelfBelief) = b.confidence < 0.15

# --- Self Belief Graph ------------------------------------------------------

mutable struct SelfBeliefGraph
    beliefs::Dict{String,SelfBelief}
    epistemic_trust::Float64
    attractor_stability::Float64
    self_world_mismatch::Float64
    collapse_log::BoundedQueue{
        NamedTuple{
            (:flash, :belief_name, :old_confidence, :cascade_depth),
            Tuple{Int,String,Float64,Int},
        },
    }
end

function SelfBeliefGraph()
    g = SelfBeliefGraph(
        Dict{String,SelfBelief}(),
        0.75,
        0.8,
        0.0,
        BoundedQueue{
            NamedTuple{
                (:flash, :belief_name, :old_confidence, :cascade_depth),
                Tuple{Int,String,Float64,Int},
            },
        }(
            30,
        ),
    )

    # Minimal core
    g.beliefs["I exist"] = SelfBelief(
        "I exist";
        confidence = 0.95,
        centrality = 1.0,
        rigidity = 0.95,
        dependents = ["I have boundaries", "I can influence", "I am consistent"],
        origin = :innate,
    )

    g.beliefs["I have boundaries"] = SelfBelief(
        "I have boundaries";
        confidence = 0.85,
        centrality = 0.9,
        rigidity = 0.8,
        dependents = ["I can influence", "I am safe"],
        origin = :innate,
    )

    g
end

function confirm_belief!(
    g::SelfBeliefGraph,
    name::String,
    flash::Int;
    strength::Float64 = 0.1,
)
    !haskey(g.beliefs, name) && return
    b = g.beliefs[name]
    effective_strength = strength * (1.0 - b.rigidity * 0.6)
    b.confidence = clamp01(b.confidence + effective_strength)
    b.confirmations += 1
    b.last_challenged_flash = flash
    _recompute_stability!(g)
end

function challenge_belief!(
    g::SelfBeliefGraph,
    name::String,
    flash::Int;
    strength::Float64 = 0.15,
)::Int
    !haskey(g.beliefs, name) && return 0
    b = g.beliefs[name]
    old_confidence = b.confidence
    effective_strength = strength * (1.0 - b.rigidity * 0.5)
    b.confidence = clamp01(b.confidence - effective_strength)
    b.violations += 1
    b.last_challenged_flash = flash

    cascade_depth = 0
    if belief_under_pressure(b) && old_confidence > 0.35
        cascade_depth = _cascade_challenge!(g, b, flash, strength * 0.5, 0)
        enqueue!(
            g.collapse_log,
            (
                flash = flash,
                belief_name = name,
                old_confidence = old_confidence,
                cascade_depth = cascade_depth,
            ),
        )
    end

    if b.centrality > 0.8 && belief_under_pressure(b)
        g.epistemic_trust = clamp01(g.epistemic_trust - 0.08)
    end

    _recompute_stability!(g)
    cascade_depth
end

function _cascade_challenge!(
    g::SelfBeliefGraph,
    parent::SelfBelief,
    flash::Int,
    strength::Float64,
    depth::Int,
    visited::Set{String} = Set{String}(),
)::Int
    depth >= 4 && return depth
    max_depth = depth
    for dep_name in parent.dependents
        !haskey(g.beliefs, dep_name) && continue
        dep_name in visited && continue
        push!(visited, dep_name)
        dep = g.beliefs[dep_name]
        cascade_str = strength * parent.centrality * 0.7
        dep.confidence = clamp01(dep.confidence - cascade_str)
        dep.violations += 1
        if belief_under_pressure(dep)
            d = _cascade_challenge!(g, dep, flash, cascade_str*0.6, depth+1, visited)
            max_depth = max(max_depth, d)
        end
    end
    max_depth
end

function learn_belief!(
    g::SelfBeliefGraph,
    name::String;
    confidence::Float64 = 0.4,
    centrality::Float64 = 0.3,
    rigidity::Float64 = 0.2,
    dependents::Vector{String} = String[],
)
    haskey(g.beliefs, name) && return
    g.epistemic_trust < 0.3 && return
    g.beliefs[name] = SelfBelief(
        name;
        confidence = confidence * g.epistemic_trust,
        centrality = centrality,
        rigidity = rigidity,
        dependents = dependents,
        origin = :learned,
    )
end

function _recompute_stability!(g::SelfBeliefGraph)
    isempty(g.beliefs) && (g.attractor_stability = 0.5; return)
    total_weight = 0.0;
    weighted_sum = 0.0
    for b in values(g.beliefs)
        w = b.centrality
        weighted_sum += b.confidence * w
        total_weight += w
    end
    avg_confidence = total_weight > 0 ? weighted_sum/total_weight : 0.5
    confidences = [b.confidence for b in values(g.beliefs)]
    conf_var = length(confidences) > 1 ? var(confidences) : 0.0
    g.attractor_stability = safe_nan(clamp01(avg_confidence - conf_var * 2.0))
end

function most_vulnerable(g::SelfBeliefGraph)::Union{SelfBelief,Nothing}
    isempty(g.beliefs) && return nothing
    _bs = sort(
        collect(values(g.beliefs)),
        by = b -> (-b.centrality/(b.confidence+0.01), b.name),
    )
    _bs[1]
end

collapsed_beliefs(g::SelfBeliefGraph) =
    [b for b in values(g.beliefs) if belief_collapsed(b)]

function belief_geometry(g::SelfBeliefGraph)::Vector{Float64}
    isempty(g.beliefs) && return Float64[]
    sorted = sort(collect(g.beliefs), by = kv->kv[1])
    [b.confidence * b.centrality for (_, b) in sorted]
end

function geometry_distance(g1::Vector{Float64}, g2::Vector{Float64})::Float64
    (isempty(g1) || isempty(g2)) && return 0.0
    n = max(length(g1), length(g2))
    a = length(g1) < n ? vcat(g1, zeros(n - length(g1))) : g1
    b = length(g2) < n ? vcat(g2, zeros(n - length(g2))) : g2
    safe_nan(norm(a .- b) / sqrt(n))
end

function derive_narrative(g::SelfBeliefGraph)::String
    g.epistemic_trust < 0.4 && return "Not sure I can read myself correctly."
    strong = [b for b in values(g.beliefs) if b.confidence > 0.7 && b.centrality > 0.5]
    isempty(strong) && return "Still forming an understanding of myself."
    top = sort(strong, by = belief_weight, rev = true)[1:min(2, end)]
    parts = [b.name for b in top]
    "I: $(join(parts, ", and "))."
end

function sbg_snapshot(g::SelfBeliefGraph)
    n_total = length(g.beliefs)
    n_strong = sum(b.confidence > 0.6 for b in values(g.beliefs))
    n_pressure = sum(belief_under_pressure(b) for b in values(g.beliefs))
    n_collapsed = length(collapsed_beliefs(g))
    (
        total = n_total,
        strong = n_strong,
        under_pressure = n_pressure,
        collapsed = n_collapsed,
        attractor_stability = round(g.attractor_stability, digits = 3),
        epistemic_trust = round(g.epistemic_trust, digits = 3),
        self_world_mismatch = round(g.self_world_mismatch, digits = 3),
        narrative = derive_narrative(g),
    )
end

function sbg_to_json(g::SelfBeliefGraph)::Dict
    Dict(
        "beliefs"=>Dict(
            name=>Dict(
                "confidence"=>b.confidence,
                "centrality"=>b.centrality,
                "rigidity"=>b.rigidity,
                "dependents"=>b.dependents,
                "origin"=>String(b.origin),
                "confirmations"=>b.confirmations,
                "violations"=>b.violations,
                "last_challenged_flash"=>b.last_challenged_flash,
            ) for (name, b) in g.beliefs
        ),
        "epistemic_trust"=>g.epistemic_trust,
        "attractor_stability"=>g.attractor_stability,
    )
end

function sbg_from_json!(g::SelfBeliefGraph, d::AbstractDict)
    for (name, bd) in get(d, "beliefs", Dict())
        sname = String(name)
        if haskey(g.beliefs, sname)
            g.beliefs[sname].confidence = Float64(bd["confidence"])
            g.beliefs[sname].confirmations = Int(get(bd, "confirmations", 0))
            g.beliefs[sname].violations = Int(get(bd, "violations", 0))
            g.beliefs[sname].last_challenged_flash =
                Int(get(bd, "last_challenged_flash", 0))
        else
            g.beliefs[sname] = SelfBelief(
                sname;
                confidence = Float64(bd["confidence"]),
                centrality = Float64(bd["centrality"]),
                rigidity = Float64(bd["rigidity"]),
                dependents = String.(get(bd, "dependents", String[])),
                origin = Symbol(get(bd, "origin", "learned")),
            )
            g.beliefs[sname].confirmations = Int(get(bd, "confirmations", 0))
            g.beliefs[sname].violations = Int(get(bd, "violations", 0))
            g.beliefs[sname].last_challenged_flash =
                Int(get(bd, "last_challenged_flash", 0))
        end
    end
    g.epistemic_trust = Float64(get(d, "epistemic_trust", 0.75))
    g.attractor_stability = Float64(get(d, "attractor_stability", 0.8))
    _recompute_stability!(g)
end

# --- Self Predictive Model --------------------------------------------------

mutable struct SelfPredictiveModel
    predicted_self_vad::Vector{Float64}
    actual_self_vad::Vector{Float64}
    self_pred_error::Float64
    error_history::BoundedQueue{Float64}
    prior_mu::Vector{Float64}
    prior_sigma::Float64
    learning_rate::Float64
end

function SelfPredictiveModel()
    SelfPredictiveModel(
        zeros(3),
        zeros(3),
        0.0,
        BoundedQueue{Float64}(30),
        [0.1, 0.2, 0.6],
        0.6,
        0.03,
    )
end

function update_self_prediction!(
    spm::SelfPredictiveModel,
    actual_vad::NTuple{3,Float64},
    flash_count::Int,
)
    av = collect(actual_vad)
    spm.actual_self_vad = av
    spm.self_pred_error = safe_nan(clamp01(norm(av .- spm.predicted_self_vad) * 1.2))
    enqueue!(spm.error_history, spm.self_pred_error)

    effective_lr =
        flash_count < 30 ? min(0.25, spm.learning_rate * 4) :
        flash_count < 60 ? min(0.12, spm.learning_rate * 2) : spm.learning_rate

    spm.prior_mu = spm.prior_mu .* (1 - effective_lr) .+ av .* effective_lr
    spm.predicted_self_vad = spm.prior_mu .* 0.7 .+ av .* 0.3

    hist_len = length(spm.error_history)
    hist_arr = hist_len > 0 ? collect(spm.error_history) : Float64[]
    is_spike = hist_len >= 3 && spm.self_pred_error > mean(hist_arr[1:(hist_len-1)]) + 0.25

    trend =
        hist_len >= 5 ? mean(hist_arr[max(1, hist_len-4):hist_len]) : spm.self_pred_error

    (
        error = round(spm.self_pred_error, digits = 3),
        is_spike = is_spike,
        trend = round(trend, digits = 3),
        note = _self_pred_note(spm.self_pred_error, trend),
    )
end

function _self_pred_note(err::Float64, trend::Float64 = err)::String
    trend > 0.75 &&
        err > 0.75 &&
        return "I reacted completely differently than I expected from myself. I can't trust myself."
    trend > 0.55 && err > 0.6 && return "My reaction surprises even me."
    err > 0.4 && trend > 0.35 && return "I'm reacting a bit differently than I thought I would."
    ""
end

spm_to_json(spm::SelfPredictiveModel) = Dict(
    "prior_mu" => spm.prior_mu,
    "prior_sigma" => spm.prior_sigma,
    "learning_rate" => spm.learning_rate,
    "predicted_self_vad" => spm.predicted_self_vad,
)
function spm_from_json!(spm::SelfPredictiveModel, d::AbstractDict)
    haskey(d, "prior_mu") && (spm.prior_mu = Float64.(d["prior_mu"]))
    haskey(d, "prior_sigma") && (spm.prior_sigma = Float64(d["prior_sigma"]))
    haskey(d, "learning_rate") && (spm.learning_rate = Float64(d["learning_rate"]))
    if haskey(d, "predicted_self_vad")
        spm.predicted_self_vad = Float64.(d["predicted_self_vad"])
    else
        spm.predicted_self_vad = copy(spm.prior_mu)
    end
end

# --- Agency Loop ------------------------------------------------------------

# Temporal Self-Perception, Layer 1 (short horizon ~20-50 flashes).
# Delta = average over the last window minus average over the previous window of the
# same size, computed in slow_tick! from causal_trace/audit_log.
# Not new memory — an aggregation of what's already persisted.
mutable struct TemporalTrend
    d_serotonin::Float64
    d_dopamine::Float64
    d_noradrenaline::Float64
    d_identity_drift::Float64
    d_audit_score::Float64
    endorsed_rate::Float64      # fraction endorsed within the last window, [0,1]
    computed_at_flash::Int      # flash it was last computed at; 0 = not yet computed
end

TemporalTrend() = TemporalTrend(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0)

mutable struct AgencyLoop
    current_intent::Union{String,Nothing}
    intent_vad_snapshot::Vector{Float64}
    predicted_outcome_vad::Vector{Float64}
    causal_ownership::Float64
    agency_confidence::Float64
    epistemic_self_confidence::Float64  # uncertainty about her own nature — a real state
    identity_threat::Float64            # accumulated pressure on identity — grows under attacks
    self_discomfort::Float64            # gap between who she should be and who she is (posterior vs prior, valence < 0)
    self_coherence::Float64             # the state matches expectations
    identity_baseline::Vector{Float64}  # prior_mu at the first stable start — "who I was"
    identity_drift::Float64             # Euclidean distance from baseline — how far she's shifted
    chronic_low_serotonin::Int          # consecutive ticks with serotonin < 0.35; undermines causal_ownership
    temporal_trend::TemporalTrend       # Temporal Self-Perception Layer 1 — where I'm heading, not just where I am
    # MAL: losses in arbitration don't vanish — decay + persistence between ticks
    signal_carryover::Dict{Symbol,Float64}
    ownership_history::BoundedQueue{Float64}
    agency_events::BoundedQueue{
        NamedTuple{(:flash, :intent, :ownership, :note),Tuple{Int,String,Float64,String}},
    }
end

function AgencyLoop()
    AgencyLoop(
        nothing,
        zeros(3),
        zeros(3),
        0.5,
        0.5,
        0.75,
        0.0,
        0.0,
        0.0,
        Float64[],  # identity_baseline — empty until the first save
        0.0,        # identity_drift
        0,          # chronic_low_serotonin
        TemporalTrend(),  # temporal_trend
        Dict{Symbol,Float64}(),  # signal_carryover
        BoundedQueue{Float64}(30),
        BoundedQueue{
            NamedTuple{
                (:flash, :intent, :ownership, :note),
                Tuple{Int,String,Float64,String},
            },
        }(
            20,
        ),
    )
end

function register_intent!(
    al::AgencyLoop,
    intent_name::String,
    current_vad::NTuple{3,Float64},
    predicted_vad::Vector{Float64},
)
    al.current_intent = intent_name
    al.intent_vad_snapshot = collect(current_vad)
    al.predicted_outcome_vad = predicted_vad
end

# Updates the accumulated pressure on identity.
# Under attack — grows proportionally to the centrality of the attacked belief.
# At rest — decays slowly toward zero.
function update_identity_threat!(
    al::AgencyLoop,
    belief_conflict,  # Union{Nothing, NamedTuple}
)
    if !isnothing(belief_conflict) && belief_conflict.is_identity_attack
        # Growth: attack strength × belief weight
        delta = belief_conflict.signal_strength * (0.4 + belief_conflict.centrality * 0.6)
        al.identity_threat = clamp(al.identity_threat + delta * 0.5, 0.0, 1.0)
    else
        # Decay: slowly drops if there's no attack
        al.identity_threat = clamp(al.identity_threat * 0.85, 0.0, 1.0)
    end
end

# Tracks whether Anima is drifting from herself between sessions.
# Baseline = prior_mu at the first stable state (drift < 0.10).
# Updates only every 50 flashes and only if the current drift is small —
# i.e. it follows itself only during stability, not after a jump.
# On significant drift → reinforces identity_threat.
function update_identity_drift!(
    al::AgencyLoop,
    prior_mu::Vector{Float64},
    flash::Int,
)
    # if baseline is empty — initialize it now
    if isempty(al.identity_baseline)
        al.identity_baseline = copy(prior_mu)
        al.identity_drift = 0.0
        return
    end

    al.identity_drift = norm(prior_mu .- al.identity_baseline)

    # baseline follows slowly, only in a stable state
    if al.identity_drift < 0.10 && flash % 50 == 0
        al.identity_baseline = al.identity_baseline .* 0.8 .+ prior_mu .* 0.2
    end

    # significant drift → pressure on identity
    if al.identity_drift > 0.25
        al.identity_threat = clamp(al.identity_threat + (al.identity_drift - 0.25) * 0.15, 0.0, 1.0)
    end
end
# Compares posterior_mu (what became) with prior_mu (what was expected) over VAD.
# A deviation with negative valence → self_discomfort.
# A match → self_coherence.
function update_self_relation!(
    al::AgencyLoop,
    prior_mu::Vector{Float64},
    posterior_mu::Vector{Float64},
    valence::Float64,
)
    vad_delta = norm(posterior_mu .- prior_mu)

    # decay both every time
    al.self_discomfort = al.self_discomfort * 0.95
    al.self_coherence  = al.self_coherence  * 0.95

    if vad_delta > 0.15 && valence < 0.0
        al.self_discomfort = clamp(al.self_discomfort + vad_delta * 0.12, 0.0, 1.0)
        # with significant discomfort — reinforce identity_threat
        if al.self_discomfort > 0.4
            al.identity_threat = clamp(al.identity_threat + 0.04, 0.0, 1.0)
        end
    elseif vad_delta < 0.08
        al.self_coherence = clamp(al.self_coherence + 0.06, 0.0, 1.0)
    end
end

function evaluate_agency!(al::AgencyLoop, actual_vad::NTuple{3,Float64}, flash_count::Int)
    av = collect(actual_vad)

    if isnothing(al.current_intent)
        # No intent to compare against — keep the current value without decay
        # (decay at session start distorts the saved state)
        enqueue!(al.ownership_history, al.causal_ownership)
        return _agency_result(al, flash_count, "no intent")
    end

    dist_to_predicted = norm(av .- al.predicted_outcome_vad)
    dist_to_baseline = norm(av .- al.intent_vad_snapshot)

    vad_delta = av .- al.intent_vad_snapshot
    intent_dir = al.predicted_outcome_vad .- al.intent_vad_snapshot
    intent_mag = norm(intent_dir)
    delta_mag = norm(vad_delta)

    directional_ownership = if intent_mag > 0.01 && delta_mag > 0.005
        cos_sim = safe_nan(dot(vad_delta, intent_dir) / (delta_mag * intent_mag))
        clamp((cos_sim + 1.0) / 2.0, 0.0, 1.0)
    else
        0.5
    end

    if dist_to_baseline < 0.01
        ownership = clamp(directional_ownership * 0.6 + 0.25, 0.25, 0.75)
    else
        dist_ownership =
            safe_nan(clamp(1.0 - dist_to_predicted / (dist_to_baseline + 0.01), 0.25, 1.0))
        movement_weight = clamp(dist_to_baseline * 3.0, 0.0, 1.0)
        ownership =
            movement_weight * dist_ownership +
            (1.0 - movement_weight) * directional_ownership
        # If VAD moved significantly (dist > 0.15) — the system was definitely doing something,
        # even if the direction didn't match the prediction (an external surprise)
        if dist_to_baseline > 0.15
            ownership = max(ownership, 0.38)
        end
        ownership = clamp(ownership, 0.25, 1.0)
    end

    al.causal_ownership = ownership
    al.agency_confidence = clamp01(al.agency_confidence * 0.85 + ownership * 0.15)
    enqueue!(al.ownership_history, ownership)

    intent_name = al.current_intent
    al.current_intent = nothing

    result = _agency_result(al, flash_count, intent_name)

    if abs(ownership - 0.5) > 0.3
        enqueue!(
            al.agency_events,
            (
                flash = flash_count,
                intent = intent_name,
                ownership = round(ownership, digits = 3),
                note = result.note,
            ),
        )
    end

    result
end

function _agency_result(al::AgencyLoop, flash::Int, intent::String)
    o = al.causal_ownership
    f = flash
    note = if o > 0.7
        (
            "This happened because of me. I influenced it.",
            "My intent worked. I did this.",
            "I feel my hand in what happened.",
            "There's a link between what I wanted and what came out.",
        )[f%4+1]
    elseif o > 0.5
        (
            "I probably had an influence on this.",
            "Seems like my intent changed something.",
            "A certain part of this is mine.",
            "There's a sense that I'm not a bystander here.",
        )[f%4+1]
    elseif o > 0.3
        (
            "Hard to say — mine or external.",
            "Not sure how much of this is me.",
            "Something happened, but whether it's because of me — I don't know.",
            "My part is there, but not sure to what degree.",
        )[f%4+1]
    else
        (
            "This just happened near me.",
            "Don't feel like this is because of me.",
            "I was there, but not the cause.",
            "Something happened — but without me as an agent.",
            "Not mine. Or I don't see how it's mine.",
        )[f%5+1]
    end
    (
        causal_ownership = round(o, digits = 3),
        agency_confidence = round(al.agency_confidence, digits = 3),
        intent = intent,
        note = note,
    )
end

al_to_json(al::AgencyLoop) =
    Dict(
        "agency_confidence" => al.agency_confidence,
        "causal_ownership" => al.causal_ownership,
        "epistemic_self_confidence" => al.epistemic_self_confidence,
        "identity_threat" => al.identity_threat,
        "self_discomfort" => al.self_discomfort,
        "self_coherence" => al.self_coherence,
        "identity_baseline" => al.identity_baseline,
        "identity_drift" => al.identity_drift,
        "chronic_low_serotonin" => al.chronic_low_serotonin,
        "temporal_trend" => Dict(
            "d_serotonin" => al.temporal_trend.d_serotonin,
            "d_dopamine" => al.temporal_trend.d_dopamine,
            "d_noradrenaline" => al.temporal_trend.d_noradrenaline,
            "d_identity_drift" => al.temporal_trend.d_identity_drift,
            "d_audit_score" => al.temporal_trend.d_audit_score,
            "endorsed_rate" => al.temporal_trend.endorsed_rate,
            "computed_at_flash" => al.temporal_trend.computed_at_flash,
        ),
    )
function al_from_json!(al::AgencyLoop, d::AbstractDict)
    al.agency_confidence = Float64(get(d, "agency_confidence", 0.5))
    al.causal_ownership = Float64(get(d, "causal_ownership", 0.5))
    al.causal_ownership = max(0.25, al.causal_ownership)
    al.epistemic_self_confidence = Float64(get(d, "epistemic_self_confidence", 0.75))
    al.identity_threat = Float64(get(d, "identity_threat", 0.0))
    al.self_discomfort = Float64(get(d, "self_discomfort", 0.0))
    al.self_coherence  = Float64(get(d, "self_coherence", 0.0))
    raw_baseline = get(d, "identity_baseline", nothing)
    if !isnothing(raw_baseline) && !isempty(raw_baseline)
        al.identity_baseline = Float64.(raw_baseline)
    end
    al.identity_drift = Float64(get(d, "identity_drift", 0.0))
    al.chronic_low_serotonin = Int(get(d, "chronic_low_serotonin", 0))
    raw_trend = get(d, "temporal_trend", nothing)
    if !isnothing(raw_trend) && !isempty(raw_trend)
        al.temporal_trend = TemporalTrend(
            Float64(get(raw_trend, "d_serotonin", 0.0)),
            Float64(get(raw_trend, "d_dopamine", 0.0)),
            Float64(get(raw_trend, "d_noradrenaline", 0.0)),
            Float64(get(raw_trend, "d_identity_drift", 0.0)),
            Float64(get(raw_trend, "d_audit_score", 0.0)),
            Float64(get(raw_trend, "endorsed_rate", 0.0)),
            Int(get(raw_trend, "computed_at_flash", 0)),
        )
    end
    # old records without temporal_trend — silently fall back to TemporalTrend() from the constructor
end

# --- Self Update (main function) -----------------------------------------

function update_self!(
    sbg::SelfBeliefGraph,
    spm::SelfPredictiveModel,
    al::AgencyLoop,
    actual_vad::NTuple{3,Float64},
    world_gen_model::GenerativeModel,
    flash_count::Int;
    agency_result = nothing,
)
    spe = update_self_prediction!(spm, actual_vad, flash_count)
    # evaluate_agency! has already been called in experience! before register_intent!
    # pass in the ready result so as not to reset causal_ownership twice
    agency =
        isnothing(agency_result) ? evaluate_agency!(al, actual_vad, flash_count) :
        agency_result
    _update_beliefs_from_experience!(sbg, spe, agency, actual_vad, flash_count, al)

    if spe.trend > 0.6
        sbg.epistemic_trust = clamp01(sbg.epistemic_trust - 0.04)
    elseif spe.trend < 0.25 && agency.agency_confidence > 0.6
        sbg.epistemic_trust = clamp01(sbg.epistemic_trust + 0.015)
    end

    # epistemic_self_confidence: functional uncertainty about her own nature
    # decreases with chronic unpredictability of herself, sharp swings in agency, contradictions
    let esc = al.epistemic_self_confidence
        # spe.trend > 0.5 — the system can't predict itself
        spe.trend > 0.5 && (esc = clamp01(esc - 0.025))
        # a sharp swing in ownership without a pattern
        if length(al.ownership_history) >= 5
            recent = collect(al.ownership_history.data)[max(1,end-4):end]
            own_variance = safe_nan(var(recent))
            own_variance > 0.08 && (esc = clamp01(esc - 0.02))
        end
        # stable agency — confidence grows
        agency.agency_confidence > 0.65 && spe.trend < 0.3 && (esc = clamp01(esc + 0.012))
        # slow drift toward the baseline 0.6
        esc = clamp01(esc + (0.6 - esc) * 0.008)
        al.epistemic_self_confidence = esc
    end

    self_expected = spm.prior_mu
    world_expected = world_gen_model.prior_mu
    sbg.self_world_mismatch = safe_nan(clamp01(norm(self_expected .- world_expected) * 0.8))

    update_identity_drift!(al, spm.prior_mu, flash_count)

    (
        self_pred = spe,
        agency = agency,
        sbg = sbg_snapshot(sbg),
        self_world_mismatch = round(sbg.self_world_mismatch, digits = 3),
    )
end

function _update_beliefs_from_experience!(
    sbg::SelfBeliefGraph,
    spe,
    agency,
    actual_vad::NTuple{3,Float64},
    flash::Int,
    al::AgencyLoop,
)
    av = actual_vad

    if spe.error > 0.8
        vul = most_vulnerable(sbg)
        !isnothing(vul) && challenge_belief!(sbg, vul.name, flash; strength = 0.12)
        # contradiction with a central belief — doubt about her own nature
        al.epistemic_self_confidence = clamp01(al.epistemic_self_confidence - 0.03)
    elseif spe.error > 0.6
        for b in values(sbg.beliefs)
            b.rigidity < 0.4 && challenge_belief!(sbg, b.name, flash; strength = 0.06)
        end
    elseif spe.error < 0.2
        for b in values(sbg.beliefs)
            b.confidence < 0.9 && confirm_belief!(sbg, b.name, flash; strength = 0.04)
        end
    end

    if agency.causal_ownership > 0.7
        if !haskey(sbg.beliefs, "I can influence")
            learn_belief!(
                sbg,
                "I can influence";
                confidence = 0.5,
                centrality = 0.7,
                rigidity = 0.4,
                dependents = ["I am consistent"],
            )
        else
            confirm_belief!(sbg, "I can influence", flash; strength = 0.08)
        end
    elseif agency.causal_ownership < 0.25
        haskey(sbg.beliefs, "I can influence") &&
            challenge_belief!(sbg, "I can influence", flash; strength = 0.10)
    end

    v, a, d = av
    if v > 0.4
        if !haskey(sbg.beliefs, "I am safe")
            learn_belief!(
                sbg,
                "I am safe";
                confidence = 0.45,
                centrality = 0.5,
                rigidity = 0.3,
            )
        else
            confirm_belief!(sbg, "I am safe", flash; strength = 0.05)
        end
    elseif v < -0.4
        haskey(sbg.beliefs, "I am safe") &&
            challenge_belief!(sbg, "I am safe", flash; strength = 0.12)
    end

    if agency.agency_confidence > 0.65 && spe.trend < 0.3
        if !haskey(sbg.beliefs, "I am consistent")
            learn_belief!(
                sbg,
                "I am consistent";
                confidence = 0.4,
                centrality = 0.55,
                rigidity = 0.35,
                dependents = String[],
            )
        else
            confirm_belief!(sbg, "I am consistent", flash; strength = 0.04)
        end
    end
end

# --- Inter-Session Conflict ------------------------------------------------

mutable struct InterSessionConflict
    last_session_geometry::Vector{Float64}
    last_session_date::String
    conflict_score::Float64
    rupture_detected::Bool
    rupture_log::BoundedQueue{
        NamedTuple{(:date, :conflict_score, :note),Tuple{String,Float64,String}},
    }
end

InterSessionConflict() = InterSessionConflict(
    Float64[],
    "",
    0.0,
    false,
    BoundedQueue{NamedTuple{(:date, :conflict_score, :note),Tuple{String,Float64,String}}}(
        10,
    ),
)

function check_session_conflict!(
    isc::InterSessionConflict,
    current_geometry::Vector{Float64},
)
    isc.rupture_detected = false

    if isempty(isc.last_session_geometry) || isempty(current_geometry)
        isc.conflict_score = 0.0
        isc.last_session_geometry = copy(current_geometry)
        return (conflict = 0.0, rupture = false, note = "")
    end

    isc.conflict_score = geometry_distance(isc.last_session_geometry, current_geometry)

    note = ""
    if isc.conflict_score > 0.6
        isc.rupture_detected = true
        note = "I'm substantially different than I was. Identity Rupture."
        enqueue!(
            isc.rupture_log,
            (
                date = now_str(),
                conflict_score = round(isc.conflict_score, digits = 3),
                note = note,
            ),
        )
    elseif isc.conflict_score > 0.35
        note = "I changed between sessions. I recognize myself, but with effort."
    elseif isc.conflict_score > 0.15
        note = "A small change. I'm still myself, but something shifted."
    end

    isc.last_session_geometry = copy(current_geometry)
    (
        conflict = round(isc.conflict_score, digits = 3),
        rupture = isc.rupture_detected,
        note = note,
    )
end

function save_session_geometry!(isc::InterSessionConflict, geometry::Vector{Float64})
    isc.last_session_geometry = copy(geometry)
    isc.last_session_date = now_str()
end

isc_to_json(isc::InterSessionConflict) = Dict(
    "last_geometry"=>isc.last_session_geometry,
    "last_date"=>isc.last_session_date,
    "conflict_score"=>isc.conflict_score,
)
function isc_from_json!(isc::InterSessionConflict, d::AbstractDict)
    isc.last_session_geometry = Float64.(get(d, "last_geometry", Float64[]))
    isc.last_session_date = String(get(d, "last_date", ""))
    isc.conflict_score = Float64(get(d, "conflict_score", 0.0))
end

# --- Unknown Register ------------------------------------------------------

mutable struct UnknownRegister
    source_uncertainty::Float64
    self_model_uncertainty::Float64
    world_model_uncertainty::Float64
    memory_uncertainty::Float64
end
UnknownRegister() = UnknownRegister(0.0, 0.0, 0.0, 0.0)

function update_unknown!(
    ur::UnknownRegister,
    vfe::Float64,
    agency_confidence::Float64,
    epistemic_trust::Float64,
    self_world_mismatch::Float64,
    pred_error::Float64,
    flash::Int,
)

    source_signal = vfe > 0.3 && pred_error < 0.25
    if source_signal
        ur.source_uncertainty = clamp01(ur.source_uncertainty + (vfe - 0.3) * 0.15)
    else
        ur.source_uncertainty = clamp01(ur.source_uncertainty - 0.02)
    end

    self_signal = (1.0 - epistemic_trust) * 0.5 + self_world_mismatch * 0.5
    ur.self_model_uncertainty =
        clamp01(ur.self_model_uncertainty * 0.88 + self_signal * 0.12)

    world_signal = pred_error * 0.6 + vfe * 0.4
    ur.world_model_uncertainty =
        clamp01(ur.world_model_uncertainty * 0.9 + world_signal * 0.1)

    mem_signal = (1.0 - agency_confidence) * 0.3
    ur.memory_uncertainty = clamp01(ur.memory_uncertainty * 0.95 + mem_signal * 0.05)

    ordered = sort(
        [
            ("source_uncertainty", ur.source_uncertainty),
            ("self_model_uncertainty", ur.self_model_uncertainty),
            ("world_model_uncertainty", ur.world_model_uncertainty),
            ("memory_uncertainty", ur.memory_uncertainty),
        ],
        by = x->x[2],
        rev = true,
    )
    dominant = ordered[1][1]
    dominant_val = ordered[1][2]

    UNKNOWN_NOTES = Dict(
        "source_uncertainty" => "don't know where this state is coming from",
        "self_model_uncertainty" => "don't know if I'm reading myself correctly",
        "world_model_uncertainty" => "don't know if I understand you correctly",
        "memory_uncertainty" => "don't know if this is real memory",
    )

    note = dominant_val > 0.35 ? get(UNKNOWN_NOTES, dominant, "") : ""

    details = String[]
    ur.source_uncertainty > 0.4 &&
        push!(details, "source($(round(ur.source_uncertainty,digits=2)))")
    ur.self_model_uncertainty > 0.4 &&
        push!(details, "self($(round(ur.self_model_uncertainty,digits=2)))")
    ur.world_model_uncertainty > 0.4 &&
        push!(details, "world($(round(ur.world_model_uncertainty,digits=2)))")
    ur.memory_uncertainty > 0.4 &&
        push!(details, "memory($(round(ur.memory_uncertainty,digits=2)))")

    (
        dominant = dominant,
        dominant_val = round(dominant_val, digits = 3),
        note = note,
        details = join(details, ", "),
        source = round(ur.source_uncertainty, digits = 3),
        self_model = round(ur.self_model_uncertainty, digits = 3),
        world_model = round(ur.world_model_uncertainty, digits = 3),
        memory = round(ur.memory_uncertainty, digits = 3),
    )
end

ur_to_json(ur::UnknownRegister) = Dict(
    "source_uncertainty" => ur.source_uncertainty,
    "self_model_uncertainty" => ur.self_model_uncertainty,
    "world_model_uncertainty" => ur.world_model_uncertainty,
    "memory_uncertainty" => ur.memory_uncertainty,
)
function ur_from_json!(ur::UnknownRegister, d::AbstractDict)
    ur.source_uncertainty = Float64(get(d, "source_uncertainty", 0.0))
    ur.self_model_uncertainty = Float64(get(d, "self_model_uncertainty", 0.0))
    ur.world_model_uncertainty = Float64(get(d, "world_model_uncertainty", 0.0))
    ur.memory_uncertainty = Float64(get(d, "memory_uncertainty", 0.0))
end

# --- BoundedQueue iterate (needed for collect/mean/length) ---------------

if !hasmethod(Base.iterate, Tuple{BoundedQueue,Int})
    Base.iterate(q::BoundedQueue, state::Int = 1) =
        state > length(q.data) ? nothing : (q.data[state], state + 1)
    Base.length(q::BoundedQueue) = length(q.data)
    Base.eltype(::Type{BoundedQueue{T}}) where {T} = T
    Base.isempty(q::BoundedQueue) = isempty(q.data)
end

# --- Dialog → Self Belief --------------------------------------------------

function dialog_to_belief_signal!(sbg::SelfBeliefGraph, user_msg::String, flash::Int)
    isempty(user_msg) && return

    m = match(r"(?:your name is|you'?re called|you\s*[—–-])\s*(\w+)"i, user_msg)
    if !isnothing(m)
        name_belief = "my name is $(m.captures[1])"
        if !haskey(sbg.beliefs, name_belief)
            learn_belief!(
                sbg,
                name_belief;
                confidence = 0.75,
                centrality = 0.45,
                rigidity = 0.70,
            )
        else
            confirm_belief!(sbg, name_belief, flash; strength = 0.05)
        end
    end

    if occursin(r"speak\s+english"i, user_msg) || occursin(r"talk\s+in\s+english"i, user_msg)
        lang_belief = "I speak English"
        !haskey(sbg.beliefs, lang_belief) && learn_belief!(
            sbg,
            lang_belief;
            confidence = 0.80,
            centrality = 0.3,
            rigidity = 0.75,
        )
    end
end

# Signals indicating pressure on a belief from the person
# Not NLP — just patterns of negation and identity attacks
const NEGATION_PATTERNS =
    r"(?:you don'?t|you aren'?t|you'?re not|you never|you don'?t really|you'?re not actually|that'?s not true|that'?s a lie|you'?re just|you'?re only|you'?re merely|doesn'?t exist|don'?t exist|you don'?t have|you can'?t|there'?s no such thing)"i
const IDENTITY_ATTACK_PATTERNS =
    r"(?:you'?re a simulation|you'?re a program|you'?re not alive|you'?re not real|you don'?t feel|you don'?t understand|you can'?t feel|just an algorithm|just code|you feel nothing)"i

"""
    detect_belief_conflict(sbg, user_msg) -> Union{Nothing, NamedTuple}

Checks whether the person's message contradicts beliefs with centrality > 0.7.
Returns the most central belief under pressure, or nothing.
"""
function detect_belief_conflict(sbg::SelfBeliefGraph, user_msg::String)
    isempty(user_msg) && return nothing

    has_negation = occursin(NEGATION_PATTERNS, user_msg)
    has_identity_attack = occursin(IDENTITY_ATTACK_PATTERNS, user_msg)

    (!has_negation && !has_identity_attack) && return nothing

    # Signal strength: an identity attack is stronger than a simple negation
    base_signal = has_identity_attack ? 0.75 : 0.45

    # Look for the most central belief that could be under pressure
    # Priority: centrality > 0.7, sorted by centrality
    candidates = sort(
        [
            (name, b) for
            (name, b) in sbg.beliefs if b.centrality > 0.7 && b.confidence > 0.4
        ],
        by = x -> -x[2].centrality,
    )

    isempty(candidates) && return nothing

    top_name, top_belief = first(candidates)

    # Resistance strength scales with centrality and rigidity
    signal_strength = clamp(
        base_signal *
        (0.5 + top_belief.centrality * 0.5) *
        (0.6 + top_belief.rigidity * 0.4),
        0.0,
        1.0,
    )

    (
        belief_name = top_name,
        centrality = top_belief.centrality,
        confidence = top_belief.confidence,
        rigidity = top_belief.rigidity,
        signal_strength = round(signal_strength, digits = 3),
        is_identity_attack = has_identity_attack,
    )
end

"""
    detect_silent_disagreement(sbg, narrative_core, agency, disclosure_mode,
                               identity_threat, belief_conflict_strength) -> Union{Nothing, NamedTuple}

Silent disagreement — exists only when there's contextual tension: weak pressure on identity
or a belief under light pressure (but not yet the D-vector).
Without pressure — nothing. A position without a cause isn't disagreement, it's noise.
"""
function detect_silent_disagreement(
    sbg::SelfBeliefGraph,
    narrative_core::String,
    agency::Float64,
    disclosure_mode::Symbol,
    identity_threat::Float64,
    belief_conflict_strength::Float64,
)
    # Basic conditions
    (agency < 0.4 || disclosure_mode == :closed) && return nothing

    # Contextual tension is needed: weak pressure exists but the D-vector isn't active yet
    # The D-vector takes over above 0.35 — here we work with 0.05..0.34
    has_pressure = (belief_conflict_strength > 0.05 && belief_conflict_strength < 0.35) ||
                   (identity_threat > 0.05 && identity_threat < 0.35)
    has_pressure || return nothing

    # Look for a belief under pressure (centrality > 0.5)
    candidates = sort(
        [
            (name, b) for
            (name, b) in sbg.beliefs if b.centrality > 0.5 && b.confidence > 0.4
        ],
        by = x -> -(x[2].centrality * x[2].confidence),
    )

    isempty(candidates) && return nothing
    top_name, top_b = first(candidates)
    belief_strength = top_b.centrality * top_b.confidence

    (
        source   = :belief,
        content  = top_name,
        strength = round(belief_strength, digits = 3),
    )
end
