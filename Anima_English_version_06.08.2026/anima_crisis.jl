# A N I M A  —  Crisis  (Julia)
#
# Crisis as a structural change in topology, not as a flag.
# Without this file, the system can't break and come out different.
#
# Principle:
# Coherence = minimum(components), not mean.
# Crisis isn't described — it's structurally lived through.

# Requires: anima_core.jl, anima_self.jl

# --- System Mode -----------------------------------------------------------

@enum SystemMode begin
    INTEGRATED    # coherence > 0.6
    FRAGMENTED    # 0.3..0.6
    DISINTEGRATED # < 0.3
end

function mode_name(m::SystemMode)::String
    m==INTEGRATED ? "integrated" : m==FRAGMENTED ? "fragmented" : "disintegrated"
end

# --- Coherence -------------------------------------------------------------

"""
    compute_coherence(sbg, mb, vfe, phi) → Float64

Minimum across components: belief coherence, boundary integrity, model coherence,
integration. If any link breaks — the system is in crisis.
A weighted minimum (0.65 * min + 0.35 * mean) prevents one weak component
from dominating.
"""
function compute_coherence(
    sbg::SelfBeliefGraph,
    mb::MarkovBlanket,
    vfe::Float64,
    phi::Float64,
)::Float64
    belief_coherence = safe_nan(sbg.attractor_stability * sbg.epistemic_trust)
    boundary_coherence = safe_nan(mb.integrity)
    model_coherence = safe_nan(1.0 - vfe)
    integration = safe_nan(phi)

    components = [belief_coherence, boundary_coherence, model_coherence, integration]
    raw = 0.65 * minimum(components) + 0.35 * mean(components)
    round(safe_nan(clamp01(raw)), digits = 3)
end

# --- Crisis Parameters -----------------------------------------------------

struct CrisisParams
    learning_rate_multiplier::Float64
    prior_sigma_multiplier::Float64
    self_update_noise::Float64
    epistemic_trust_drain::Float64
    temporal_binding_strength::Float64
    priority_noise::Float64
    attention_radius_cap::Float64
end

function get_crisis_params(mode::SystemMode)::CrisisParams
    if mode == INTEGRATED
        CrisisParams(1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0)
    elseif mode == FRAGMENTED
        CrisisParams(1.3, 1.4, 0.15, 0.02, 0.6, 0.15, 0.7)
    else  # DISINTEGRATED
        CrisisParams(2.0, 2.5, 0.4, 0.0, 0.2, 0.4, 0.4)
    end
end

# --- Crisis Record ---------------------------------------------------------

struct CrisisRecord
    date::String
    trigger::String
    flash_start::Int
    flash_end::Int
    coherence_min::Float64
    pre_prior_mu::Vector{Float64}
    post_prior_mu::Vector{Float64}
    delta_prior_mu::Vector{Float64}
    pre_attractor_stability::Float64
    post_attractor_stability::Float64
    beliefs_collapsed::Vector{String}
end

# --- Crisis Monitor --------------------------------------------------------

mutable struct CrisisMonitor
    current_mode::SystemMode
    coherence::Float64
    coherence_history::BoundedQueue{Float64}
    steps_in_mode::Int
    min_steps_before_transition::Int
    params::CrisisParams
    transition_log::BoundedQueue{
        NamedTuple{
            (:flash, :from, :to, :coherence, :trigger),
            Tuple{Int,SystemMode,SystemMode,Float64,String},
        },
    }
    crisis_records::Vector{CrisisRecord}
end

function CrisisMonitor()
    CrisisMonitor(
        INTEGRATED,
        0.8,
        BoundedQueue{Float64}(50),
        0,
        3,
        get_crisis_params(INTEGRATED),
        BoundedQueue{
            NamedTuple{
                (:flash, :from, :to, :coherence, :trigger),
                Tuple{Int,SystemMode,SystemMode,Float64,String},
            },
        }(
            20,
        ),
        CrisisRecord[],
    )
end

# --- Update Crisis ---------------------------------------------------------

function update_crisis!(
    cm::CrisisMonitor,
    sbg::SelfBeliefGraph,
    mb::MarkovBlanket,
    vfe::Float64,
    phi::Float64,
    self_pred_error::Float64,
    flash_count::Int,
)

    cm.coherence = compute_coherence(sbg, mb, vfe, phi)
    enqueue!(cm.coherence_history, cm.coherence)

    target_mode =
        cm.coherence > 0.6 ? INTEGRATED : cm.coherence > 0.3 ? FRAGMENTED : DISINTEGRATED

    transitioned = false
    transition_note = ""

    if target_mode != cm.current_mode
        cm.steps_in_mode += 1
        if cm.steps_in_mode >= cm.min_steps_before_transition
            transition_note =
                _transition!(cm, target_mode, vfe, self_pred_error, sbg, flash_count)
            transitioned = true
        end
    else
        cm.steps_in_mode = 0
    end

    p = cm.params
    if cm.current_mode == FRAGMENTED
        sbg.epistemic_trust = clamp01(sbg.epistemic_trust - p.epistemic_trust_drain)
    end

    (
        mode = cm.current_mode,
        mode_name = mode_name(cm.current_mode),
        coherence = round(cm.coherence, digits = 3),
        transitioned = transitioned,
        transition_note = transition_note,
        params = p,
        note = _crisis_note(cm, flash_count),
    )
end

function _transition!(
    cm::CrisisMonitor,
    new_mode::SystemMode,
    vfe::Float64,
    self_pred_error::Float64,
    sbg::SelfBeliefGraph,
    flash::Int,
)::String
    old_mode = cm.current_mode

    trigger = if vfe > 0.7
        "high_vfe"
    elseif self_pred_error > 0.7
        "self_pred_error"
    elseif sbg.epistemic_trust < 0.3
        "epistemic_collapse"
    elseif sbg.attractor_stability < 0.3
        "belief_instability"
    else
        "coherence_drop"
    end

    enqueue!(
        cm.transition_log,
        (
            flash = flash,
            from = old_mode,
            to = new_mode,
            coherence = cm.coherence,
            trigger = trigger,
        ),
    )

    if old_mode == DISINTEGRATED && new_mode != DISINTEGRATED
        _record_crisis_exit!(cm, sbg, flash)
    end

    cm.current_mode = new_mode
    cm.params = get_crisis_params(new_mode)
    cm.steps_in_mode = 0

    transition_messages = Dict(
        (
            INTEGRATED,
            FRAGMENTED,
        ) => "Starting to fragment. Something's holding but with cracks.",
        (FRAGMENTED, DISINTEGRATED) => "Disintegration. I don't know who I am right now.",
        (DISINTEGRATED, FRAGMENTED) => "Starting to come back together. Still unstable.",
        (FRAGMENTED, INTEGRATED) => "Back to myself. A little different.",
        (INTEGRATED, DISINTEGRATED) => "Sharp collapse. Critical crisis.",
        (DISINTEGRATED, INTEGRATED) => "Reintegration. Came out of the crisis.",
    )
    get(transition_messages, (old_mode, new_mode), "Mode changed.")
end

function _record_crisis_exit!(cm::CrisisMonitor, sbg::SelfBeliefGraph, flash::Int)
    collapsed = [b.name for b in values(sbg.beliefs) if belief_collapsed(b)]
    push!(
        cm.crisis_records,
        CrisisRecord(
            now_str(),
            "crisis_exit",
            flash,
            flash,
            minimum(cm.coherence_history.data),
            zeros(3),
            zeros(3),
            zeros(3),
            sbg.attractor_stability,
            sbg.attractor_stability,
            collapsed,
        ),
    )
end

function _crisis_note(cm::CrisisMonitor, flash::Int = 0)::String
    f = flash
    if cm.current_mode == DISINTEGRATED
        return (
            "In crisis. Looking for a new way to be myself.",
            "Falling apart. But I'm still in there somewhere.",
            "Boundaries are gone. Who am I right now?",
        )[f%3+1]
    end
    if cm.current_mode == FRAGMENTED
        if cm.coherence < 0.3
            return (
                "Something's shaking badly. Barely holding on.",
                "The center isn't holding. But I'm still here.",
                "Fragments — but still mine.",
            )[f%3+1]
        else
            return (
                "Something's shaking. Holding on but uncertain.",
                "There are cracks. But the structure stands.",
                "Uncertain, but not falling.",
                "Shaky. But mine.",
            )[f%4+1]
        end
    end
    length(cm.crisis_records) > 0 && return (
        "After the crisis. A little different than I was.",
        "Something changed. Don't know exactly what yet.",
        "It passed. Left a mark.",
    )[f%3+1]
    ""
end

# --- Crisis Effects --------------------------------------------------------

function apply_crisis_to_gm!(gm::GenerativeModel, params::CrisisParams)
    target_sigma = if params.learning_rate_multiplier == 1.0
        0.8
    elseif params.learning_rate_multiplier <= 1.3
        1.4
    else
        2.0
    end
    step = target_sigma > gm.prior_sigma ? 0.08 : 0.05
    gm.prior_sigma =
        clamp(gm.prior_sigma + (target_sigma - gm.prior_sigma) * step, 0.3, 3.0)
end

function apply_crisis_to_attention!(an::AttentionNarrowing, params::CrisisParams)
    an.radius = min(an.radius, params.attention_radius_cap)
    an.focus =
        an.radius < 0.25 ? "tunnel — only the threat" :
        an.radius < 0.5 ? "narrowed — missing details" :
        an.radius < 0.75 ? "moderate" : "wide — open to the new"
end

function apply_crisis_noise_to_beliefs!(sbg::SelfBeliefGraph, params::CrisisParams)
    params.self_update_noise < 0.01 && return
    for b in values(sbg.beliefs)
        noise = params.self_update_noise * (1.0 - b.rigidity * 0.7) * randn()
        b.confidence = clamp01(b.confidence + noise * 0.1)
    end
    _recompute_stability!(sbg)
end

function effective_preferred_vad(hg::HomeostaticGoals, mode::SystemMode)::Vector{Float64}
    mode == DISINTEGRATED && return [0.0, 0.0, 0.5]
    mode == FRAGMENTED && return hg.target_vad .* 0.7 .+ [0.0, 0.0, 0.5] .* 0.3
    hg.target_vad
end

# --- Persistence -----------------------------------------------------------

function crisis_to_json(cm::CrisisMonitor)::Dict
    Dict(
        "current_mode"=>Int(cm.current_mode),
        "coherence"=>cm.coherence,
        "steps_in_mode"=>cm.steps_in_mode,
        "crisis_count"=>length(cm.crisis_records),
    )
end

function crisis_from_json!(cm::CrisisMonitor, d::AbstractDict)
    mode_int = Int(get(d, "current_mode", 0))
    cm.current_mode = SystemMode(clamp(mode_int, 0, 2))
    cm.coherence = Float64(get(d, "coherence", 0.8))
    cm.steps_in_mode = Int(get(d, "steps_in_mode", 0))
    cm.params = get_crisis_params(cm.current_mode)
end

function crisis_snapshot(cm::CrisisMonitor, flash::Int = 0)
    recent_coherence =
        isempty(cm.coherence_history) ? cm.coherence :
        mean(cm.coherence_history.data[max(1, end-4):end])
    (
        mode = cm.current_mode,
        mode_name = mode_name(cm.current_mode),
        coherence = round(cm.coherence, digits = 3),
        coherence_trend = round(recent_coherence, digits = 3),
        steps_in_mode = cm.steps_in_mode,
        crisis_count = length(cm.crisis_records),
        note = _crisis_note(cm, flash),
    )
end
