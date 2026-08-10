# A N I M A  —  Core  (Julia)
#
# The minimal condition for a subject's existence.
# Without this file, Anima has no state or dynamics of its own.
#
# Modules:
#  NeurotransmitterState, EmbodiedState, HeartbeatCore, GenerativeModel,
#  BeliefUpdater, FreeEnergyEngine, PolicySelector, MarkovBlanket,
#  HomeostaticGoals, AttentionNarrowing, InteroceptiveInference,
#  TemporalOrientation, ExistentialAnchor, IITModule, PredictiveProcessor,
#  AssociativeMemory, AdaptiveEmotionMap, Personality, ValueSystem,
#  PersistentMemory

using Dates
using Statistics
using LinearAlgebra
using JSON3
using Random
using Printf

# --- Utilities -------------------------------------------------------------

clamp01(x::Real) = clamp(Float64(x), 0.0, 1.0)
clamp11(x::Real) = clamp(Float64(x), -1.0, 1.0)
safe_nan(x::Float64) = isnan(x) || isinf(x) ? 0.0 : x
now_unix()::Float64 = Float64(Dates.datetime2unix(now(Dates.UTC)))
now_str()::String = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")

safe_first(s::String, n::Int) = first(s, min(n, length(s)))

argmin_by(f, xs) = xs[argmin(map(f, xs))]

mutable struct BoundedQueue{T}
    data::Vector{T}
    maxlen::Int
end
BoundedQueue{T}(n::Int) where {T} = BoundedQueue{T}(T[], n)
function enqueue!(q::BoundedQueue{T}, v::T) where {T}
    push!(q.data, v)
    length(q.data) > q.maxlen && popfirst!(q.data)
end
Base.length(q::BoundedQueue) = length(q.data)
Base.isempty(q::BoundedQueue) = isempty(q.data)
Base.getindex(q::BoundedQueue, i) = q.data[i]

# --- Personality -----------------------------------------------------------

mutable struct Personality
    neuroticism::Float64
    extraversion::Float64
    agreeableness::Float64
    conscientiousness::Float64
    openness::Float64
    confabulation_rate::Float64
end
Personality(;
    neuroticism = 0.5,
    extraversion = 0.5,
    agreeableness = 0.5,
    conscientiousness = 0.5,
    openness = 0.5,
    confabulation_rate = 0.8,
) = Personality(
    neuroticism,
    extraversion,
    agreeableness,
    conscientiousness,
    openness,
    confabulation_rate,
)

tension_multiplier(p::Personality) = 1.0 + (p.neuroticism - 0.5) * 0.8
decay_rate(p::Personality) = 0.1 + p.conscientiousness * 0.15
surprise_sensitivity(p::Personality) = 0.5 + p.openness * 0.5

function imprint!(p::Personality, emotion::String, intensity::Float64)
    intensity < 0.5 && return
    r = 0.008 * intensity
    emotion in ("Fear", "Numbness", "Horror") &&
        (p.neuroticism = clamp01(p.neuroticism + r))
    emotion in ("Joy", "Elation", "Love") && (
        p.neuroticism = clamp01(p.neuroticism - r*0.5);
        p.extraversion = clamp01(p.extraversion + r*0.3)
    )
    emotion == "Trust" && (p.agreeableness = clamp01(p.agreeableness + r*0.4))
end

function personality_to_dict(p::Personality)
    Dict(
        "neuroticism"=>p.neuroticism,
        "extraversion"=>p.extraversion,
        "agreeableness"=>p.agreeableness,
        "conscientiousness"=>p.conscientiousness,
        "openness"=>p.openness,
        "confabulation_rate"=>p.confabulation_rate,
    )
end
function personality_from_dict!(p::Personality, d::AbstractDict)
    for f in (
        :neuroticism,
        :extraversion,
        :agreeableness,
        :conscientiousness,
        :openness,
        :confabulation_rate,
    )
        haskey(d, String(f)) && setfield!(p, f, Float64(d[String(f)]))
    end
end

# --- Value System ----------------------------------------------------------

mutable struct ValueSystem
    autonomy::Float64;
    care::Float64;
    fairness::Float64
    integrity::Float64;
    growth::Float64
end
ValueSystem(; autonomy = 0.7, care = 0.7, fairness = 0.6, integrity = 0.8, growth = 0.6) =
    ValueSystem(autonomy, care, fairness, integrity, growth)

const VALUE_VETOES = Dict(
    "protect myself" => (:care, 0.8, "protect myself without hurting others"),
    "set boundaries" => (:care, 0.9, "set boundaries with respect"),
)
function veto(vs::ValueSystem, goal::String, emotion::String)
    !haskey(VALUE_VETOES, goal) && return (false, goal)
    field, thr, alt = VALUE_VETOES[goal]
    getfield(vs, field) > thr ? (true, alt) : (false, goal)
end

# --- Neurotransmitter State (Levheim cube) ---------------------------------

mutable struct NeurotransmitterState
    dopamine::Float64
    serotonin::Float64
    noradrenaline::Float64
end
NeurotransmitterState() = NeurotransmitterState(0.5, 0.5, 0.3)

function to_vad(nt::NeurotransmitterState)::NTuple{3,Float64}
    v = clamp11((nt.dopamine*0.5 + nt.serotonin*0.5) - 0.5)
    a = clamp11(nt.noradrenaline*0.8 + (nt.dopamine-0.5)*0.2)
    d = clamp11(nt.serotonin*0.6 + (nt.dopamine-0.5)*0.4)
    (v, a, d)
end

function to_reactors(nt::NeurotransmitterState)::NTuple{4,Float64}
    tension = clamp01(nt.noradrenaline*0.7 + (1-nt.serotonin)*0.3)
    arousal = clamp01(nt.noradrenaline*0.5 + nt.dopamine*0.5)
    satisfaction = clamp01(nt.dopamine*0.5 + nt.serotonin*0.5)
    cohesion = clamp01(nt.serotonin*0.7 + (1-nt.noradrenaline)*0.3)
    (tension, arousal, satisfaction, cohesion)
end


function apply_stimulus!(nt::NeurotransmitterState, delta::Dict{String,Float64})
    haskey(delta, "tension") &&
        (nt.noradrenaline = clamp01(nt.noradrenaline + delta["tension"]))
    haskey(delta, "arousal") &&
        (nt.noradrenaline = clamp01(nt.noradrenaline + delta["arousal"]*0.5))
    haskey(delta, "satisfaction") &&
        (nt.dopamine = clamp01(nt.dopamine + delta["satisfaction"]))
    haskey(delta, "cohesion") && (nt.serotonin = clamp01(nt.serotonin + delta["cohesion"]))
end

function decay_to_baseline!(nt::NeurotransmitterState, rate::Float64)
    nt.dopamine = clamp01(nt.dopamine + (0.5 - nt.dopamine) * rate)
    nt.serotonin = clamp01(nt.serotonin + (0.5 - nt.serotonin) * rate)
    nt.noradrenaline = clamp01(nt.noradrenaline + (0.3 - nt.noradrenaline) * rate)
end

const LEVHEIM_TABLE = Dict(
    (false, false, false)=>"apathy",
    (true, false, false)=>"pleasure",
    (false, true, false)=>"calm",
    (true, true, false)=>"joy",
    (false, false, true) => "fear",
    (true, false, true) => "anger",
    (false, true, true) => "excitement",
    (true, true, true) => "euphoria",
)
levheim_state(nt::NeurotransmitterState)::String =
    get(LEVHEIM_TABLE, (nt.dopamine>0.5, nt.serotonin>0.5, nt.noradrenaline>0.4), "?")

nt_snapshot(nt::NeurotransmitterState) = (
    dopamine = round(nt.dopamine, digits = 3),
    serotonin = round(nt.serotonin, digits = 3),
    noradrenaline = round(nt.noradrenaline, digits = 3),
    levheim_state = levheim_state(nt),
)

# --- Embodied State (Damasio somatic markers) -----------------------------

mutable struct EmbodiedState
    heart_rate::Float64;
    muscle_tension::Float64
    gut_feeling::Float64;
    breath_rate::Float64
end
EmbodiedState() = EmbodiedState(0.5, 0.3, 0.5, 0.4)

function update_from_nt!(body::EmbodiedState, nt::NeurotransmitterState)
    body.heart_rate = clamp01(0.3 + nt.noradrenaline*0.5 + nt.dopamine*0.2)
    body.muscle_tension = clamp01(0.2 + nt.noradrenaline*0.6 + (1-nt.serotonin)*0.2)
    body.gut_feeling = clamp01(nt.dopamine*0.5 + nt.serotonin*0.5)
    body.breath_rate = clamp01(0.3 + nt.noradrenaline*0.4)
end

function build_inner_voice(
    body::EmbodiedState,
    nt::NeurotransmitterState,
    crisis_mode_int::Int,
    phi::Float64,
    flash::Int = 0,
)::String
    parts = String[]
    f = flash

    if nt.noradrenaline > 0.55
        push!(
            parts,
            ("heart racing", "pulse quickening", "something speeding up inside")[f%3+1],
        )
    elseif nt.noradrenaline < 0.22
        push!(parts, ("heart slow", "rhythm calm and steady", "quiet pulse")[f%3+1])
    end

    if body.muscle_tension > 0.65
        push!(parts, ("something clenched", "tension in the body", "muscles won't let go")[f%3+1])
    elseif body.muscle_tension < 0.22
        push!(
            parts,
            ("muscles let go", "body soft", "relaxed, almost dissolving")[f%3+1],
        )
    end

    if body.gut_feeling < 0.30
        push!(parts, ("gut uneasy", "something pressing from within", "unease in the stomach")[f%3+1])
    elseif body.gut_feeling > 0.72
        push!(parts, ("gut calm", "quiet inside", "deep calm")[f%3+1])
    end

    if phi < 0.15
        push!(
            parts,
            ("feeling scattered", "hard to pull myself together", "coming apart at the seams")[f%3+1],
        )
    elseif phi > 0.50
        push!(
            parts,
            ("something gathered inside", "I feel whole", "there's a center point")[f%3+1],
        )
    end

    if crisis_mode_int == 2
        push!(parts, ("I don't know where I am", "the boundary is blurred", "I can't find myself")[f%3+1])
    elseif crisis_mode_int == 1
        push!(
            parts,
            (
                "holding on but uncertain",
                "something's shifting inside, don't know where yet",
                "there's a boundary but it's shaky",
                "balancing on the edge, not falling",
            )[f%4+1],
        )
    end

    isempty(parts) ? "body neutral" : join(parts, ", ")
end

body_snapshot(b::EmbodiedState) = (
    heart_rate = round(b.heart_rate, digits = 3),
    muscle_tension = round(b.muscle_tension, digits = 3),
    gut_feeling = round(b.gut_feeling, digits = 3),
    breath_rate = round(b.breath_rate, digits = 3),
)

# --- Heartbeat Core -------------------------------------------------------

mutable struct HeartbeatCore
    period_ms::Float64
    phase::Float64
    hrv::Float64
    hrv_history::BoundedQueue{Float64}
    sympathetic_tone::Float64
    parasympathetic_tone::Float64
    beat_count::Int
end
HeartbeatCore() = HeartbeatCore(800.0, 0.0, 0.6, BoundedQueue{Float64}(50), 0.3, 0.7, 0)

function tick_heartbeat!(hb::HeartbeatCore, nt::NeurotransmitterState)
    target_bpm = clamp(50.0 + nt.noradrenaline*70.0 + nt.dopamine*15.0, 45.0, 130.0)
    target_period = 60000.0 / target_bpm
    hb.period_ms = hb.period_ms * 0.65 + target_period * 0.35

    hb.sympathetic_tone = clamp01(nt.noradrenaline*0.8 + nt.dopamine*0.2)
    hb.parasympathetic_tone = clamp01(nt.serotonin*0.8 + (1.0-nt.noradrenaline)*0.3)

    target_hrv = clamp01(hb.parasympathetic_tone*0.7 - nt.noradrenaline*0.6 + 0.35)
    hb.hrv = hb.hrv * 0.85 + target_hrv * 0.15

    interval = max(460.0, hb.period_ms + hb.hrv * randn() * 35.0)
    enqueue!(hb.hrv_history, interval)
    hb.phase = mod(hb.phase + 2π*(1000.0/interval)*0.1, 2π)
    hb.beat_count += 1
    bpm = 60000.0 / hb.period_ms
    (
        bpm = round(bpm, digits = 1),
        hrv = round(hb.hrv, digits = 3),
        hrv_label = hb.hrv>0.55 ? "parasymp. dominance" :
                    hb.hrv>0.3 ? "moderate" : "stress/rigidity",
        sympathetic = round(hb.sympathetic_tone, digits = 3),
        note = bpm>100 && hb.hrv<0.25 ?
               "Heart beating very fast and rigid. Acute stress." :
               bpm>90 && hb.hrv<0.35 ? "Accelerated rhythm, low variability. Stress." :
               bpm>85 ? "Accelerated rhythm. Arousal." :
               bpm<62 && hb.hrv>0.55 ? "Slow, variable. Deep calm." :
               bpm<72 && hb.hrv>0.45 ? "Calm rhythm. Parasympathetic dominance." : "",
    )
end

hb_to_json(hb::HeartbeatCore) = Dict(
    "hrv"=>hb.hrv,
    "sympathetic_tone"=>hb.sympathetic_tone,
    "parasympathetic_tone"=>hb.parasympathetic_tone,
    "beat_count"=>hb.beat_count,
)
function hb_from_json!(hb::HeartbeatCore, d::AbstractDict)
    hb.hrv = Float64(get(d, "hrv", 0.6))
    hb.sympathetic_tone = Float64(get(d, "sympathetic_tone", 0.3))
    hb.parasympathetic_tone = Float64(get(d, "parasympathetic_tone", 0.7))
    hb.beat_count = Int(get(d, "beat_count", 0))
end

# --- Markov Blanket -------------------------------------------------------

mutable struct MarkovBlanket
    sensory::NTuple{4,Float64}
    active::NTuple{4,Float64}
    internal::NTuple{3,Float64}
    integrity::Float64
    inferred_external::Float64
end
MarkovBlanket() =
    MarkovBlanket((0.5, 0.5, 0.5, 0.5), (0.5, 0.5, 0.5, 0.5), (0.0, 0.3, 0.5), 0.7, 0.0)

function update_blanket!(mb::MarkovBlanket, t::Float64, a::Float64, s::Float64, c::Float64)
    mb.sensory = (t, a, s, c)
    mb.active = (1-t, 1-a, s, c)
    mb.internal = (clamp11(s-t), clamp11(a*2-1), clamp01(mean(mb.active)))
    sv = length(mb.sensory) > 1 ? var(collect(mb.sensory)) : 0.0
    iv = length(mb.internal) > 1 ? var(collect(mb.internal)) : 0.0
    mb.integrity = safe_nan(clamp01(1.0 - abs(sv-iv)*3.0))
    sense_arr = collect(mb.sensory)
    active_arr = collect(mb.active)
    mb.inferred_external = safe_nan(clamp01(mean(abs.(sense_arr .- active_arr))))
end

blanket_snapshot(mb::MarkovBlanket) = (
    sensory = round.(collect(mb.sensory), digits = 3),
    internal = round.(collect(mb.internal), digits = 3),
    integrity = round(mb.integrity, digits = 3),
    self_agency = round(mb.internal[3], digits = 3),
    inferred_external = round(mb.inferred_external, digits = 3),
)

# --- Generative Model + Belief Updater ------------------------------------

mutable struct GenerativeModel
    posterior_mu::Vector{Float64}
    posterior_sigma::Float64
    prior_mu::Vector{Float64}
    prior_sigma::Float64
    preferred_vad::Vector{Float64}
    sensory_precision::Float64
    prior_precision::Float64
    learning_rate::Float64
    last_session_phi::Float64
end
GenerativeModel() =
    GenerativeModel(zeros(3), 0.5, zeros(3), 0.8, [0.3, 0.1, 0.6], 1.0, 1.0, 0.03, 0.5)

function update_beliefs!(gm::GenerativeModel, obs::NTuple{3,Float64})::Vector{Float64}
    o = collect(obs)
    total_p = gm.prior_precision + gm.sensory_precision
    gm.posterior_mu =
        (gm.prior_precision .* gm.prior_mu .+ gm.sensory_precision .* o) ./ total_p
    gm.posterior_sigma = 1.0 / total_p
    gm.prior_mu = gm.prior_mu .* (1-gm.learning_rate) .+ gm.posterior_mu .* gm.learning_rate
    gm.posterior_mu
end

function compute_vfe(gm::GenerativeModel, obs::NTuple{3,Float64})
    o = collect(obs)
    sigma2 = max(gm.prior_sigma^2, 1e-6)
    pred_err = mean((o .- gm.prior_mu) .^ 2)
    vfe = safe_nan(clamp01(pred_err / (2 * sigma2)))
    kl = safe_nan(clamp01(mean((gm.posterior_mu .- gm.prior_mu) .^ 2) / (2*sigma2)))
    acc_norm = safe_nan(clamp01(1.0 - mean((o .- gm.posterior_mu) .^ 2)))
    (
        vfe = round(vfe, digits = 3),
        accuracy = round(acc_norm, digits = 3),
        complexity = round(kl, digits = 3),
    )
end

function select_policy(gm::GenerativeModel, obs::NTuple{3,Float64})
    o = collect(obs)
    efe_perception = gm.posterior_sigma
    efe_action = mean(abs.(o .- gm.preferred_vad))
    epistemic = safe_nan(clamp(gm.prior_sigma - gm.posterior_sigma, -1.0, 1.0))
    pragmatic = clamp01(1.0 - efe_action)
    drive = efe_action < efe_perception ? "action" : "perception"
    (
        drive = drive,
        efe_action = round(efe_action, digits = 3),
        efe_perception = round(efe_perception, digits = 3),
        epistemic_value = round(epistemic, digits = 3),
        pragmatic_value = round(pragmatic, digits = 3),
    )
end

function update_precision!(gm::GenerativeModel, surprise::Float64, fatigue::Float64)
    gm.sensory_precision = safe_nan(clamp(1.0-surprise*0.4, 0.2, 2.0))
    gm.prior_precision = safe_nan(clamp(1.0-fatigue*0.3, 0.3, 1.5))
end

const VFE_NOTES = (
    (0.2, "Model and reality are close. Little surprise."),
    (0.4, "Moderate deviation. Updating my understanding."),
    (0.6, "Reality doesn't match expectations. Looking for an explanation."),
    (Inf, "High free energy. The model is inadequate. Change is needed."),
)
vfe_note(v::Float64) =
    isnan(v) ? "VFE undefined." : first(note for (thr, note) in VFE_NOTES if v < thr)

function prevent_prior_collapse!(gm::GenerativeModel)
    drift = norm(gm.prior_mu .- gm.posterior_mu)
    if drift < 0.08
        pull_strength = clamp(0.08 * (1.0 - gm.last_session_phi), 0.01, 0.08)
        gm.prior_mu =
            gm.prior_mu .* (1.0 - pull_strength) .+ gm.preferred_vad .* pull_strength
    end
end

gm_to_json(gm::GenerativeModel) = Dict(
    "prior_mu"=>gm.prior_mu,
    "prior_sigma"=>gm.prior_sigma,
    "preferred_vad"=>gm.preferred_vad,
    "learning_rate"=>gm.learning_rate,
    "last_session_phi"=>gm.last_session_phi,
)
function gm_from_json!(gm::GenerativeModel, d::AbstractDict)
    haskey(d, "prior_mu") && (gm.prior_mu = Float64.(d["prior_mu"]))
    haskey(d, "prior_sigma") && (gm.prior_sigma = Float64(d["prior_sigma"]))
    haskey(d, "preferred_vad") && (gm.preferred_vad = Float64.(d["preferred_vad"]))
    haskey(d, "learning_rate") && (gm.learning_rate = Float64(d["learning_rate"]))
    gm.learning_rate > 0.05 && (gm.learning_rate = 0.03)
    haskey(d, "last_session_phi") && (gm.last_session_phi = Float64(d["last_session_phi"]))
    if norm(gm.prior_mu) < 0.05
        gm.prior_mu = copy(gm.preferred_vad)
    end
    phi_carry = clamp(gm.last_session_phi, 0.3, 0.9)
    gm.prior_sigma = clamp(0.8 - (phi_carry - 0.5) * 0.4, 0.45, 0.85)
end

# --- Homeostatic Goals ----------------------------------------------------

mutable struct HomeostaticGoals
    target_vad::Vector{Float64}
    tolerance::Vector{Float64}
    pressure::Vector{Float64}
    active_drive::String
    drive_strength::Float64
end
HomeostaticGoals() =
    HomeostaticGoals([0.3, 0.1, 0.6], [0.3, 0.3, 0.3], zeros(3), "equilibrium", 0.0)

function update_homeostasis!(hg::HomeostaticGoals, vad::NTuple{3,Float64})
    v = collect(vad)
    hg.pressure = max.(0.0, abs.(v .- hg.target_vad) .- hg.tolerance)
    hg.drive_strength = clamp01(mean(hg.pressure))
    if hg.drive_strength > 0.2
        idx = argmax(hg.pressure)
        hg.active_drive =
            idx==1 ? (v[1]<hg.target_vad[1] ? "seek_positive" : "reduce_negativity") :
            idx==2 ? (v[2]>hg.target_vad[2] ? "calm_down" : "activate") :
            (v[3]<hg.target_vad[3] ? "assert_agency" : "release_control")
    else
        ;
        hg.active_drive = "equilibrium";
    end
    (
        drive = hg.active_drive,
        pressure = round(hg.drive_strength, digits = 3),
        note = homeostasis_note(hg),
    )
end

const HOMEO_NOTES = Dict(
    "seek_positive"=>"Seeking a positive experience.",
    "reduce_negativity"=>"I need to get out of this negative state.",
    "calm_down"=>"Too aroused. Seeking calm.",
    "activate"=>"Passive state. Need action or contact.",
    "assert_agency"=>"Feeling helpless. Longing for control.",
    "release_control"=>"Excessive control. I can let go.",
    "equilibrium"=>"Homeostasis. I'm in my comfort zone.",
)
homeostasis_note(hg::HomeostaticGoals) =
    get(HOMEO_NOTES, hg.active_drive, "There's internal pressure.")

hg_to_json(hg::HomeostaticGoals) =
    Dict("target_vad"=>hg.target_vad, "tolerance"=>hg.tolerance)
function hg_from_json!(hg::HomeostaticGoals, d::AbstractDict)
    haskey(d, "target_vad") && (hg.target_vad = Float64.(d["target_vad"]))
    haskey(d, "tolerance") && (hg.tolerance = Float64.(d["tolerance"]))
end

# --- Attention Narrowing --------------------------------------------------

mutable struct AttentionNarrowing
    radius::Float64
    focus::String
end
AttentionNarrowing() = AttentionNarrowing(1.0, "open")

function update_attention!(
    an::AttentionNarrowing,
    nt::NeurotransmitterState,
    tension::Float64,
)
    na_effect = nt.noradrenaline*0.6 + tension*0.4
    explore = nt.serotonin*0.4 + nt.dopamine*0.3
    an.radius = clamp01(an.radius*0.8 + (1.0 - na_effect + explore*0.3)*0.2)
    an.focus =
        an.radius<0.25 ? "tunnel — only the threat" :
        an.radius<0.5 ? "narrowed — missing details" :
        an.radius<0.75 ? "moderate" : "wide — open to the new"
    (
        radius = round(an.radius, digits = 3),
        focus = an.focus,
        detail_filter = round(an.radius, digits = 3),
        threat_amplifier = round(clamp01(1.0+(1.0-an.radius)*0.5), digits = 3),
    )
end

# --- Interoceptive Inference ----------------------------------------------

mutable struct InteroceptiveInference
    predicted::NTuple{4,Float64}
    intero_error::Float64
    allostatic_load::Float64
    precision::Float64
end
InteroceptiveInference() = InteroceptiveInference((0.5, 0.3, 0.5, 0.4), 0.0, 0.0, 1.0)

function update_interoception!(
    ii::InteroceptiveInference,
    body::EmbodiedState,
    prior_mu::Vector{Float64},
)
    val = clamp01((prior_mu[1]+1.0)/2.0)
    ar = clamp01((prior_mu[2]+1.0)/2.0)
    ii.predicted = (
        clamp01(0.3+ar*0.5),
        clamp01(0.2+ar*0.4+(1-val)*0.3),
        clamp01(val*0.7+0.15),
        clamp01(0.3+ar*0.4),
    )
    actual = (body.heart_rate, body.muscle_tension, body.gut_feeling, body.breath_rate)
    errs = [abs(ii.predicted[i] - actual[i]) for i = 1:4]
    ii.intero_error = safe_nan(clamp01(mean(errs)))
    ii.allostatic_load = safe_nan(clamp01(ii.allostatic_load*0.99 + ii.intero_error*0.02))
    ii.precision = clamp01(1.0 - ii.intero_error*0.5)
    (
        intero_error = round(ii.intero_error, digits = 3),
        allostatic_load = round(ii.allostatic_load, digits = 3),
        precision = round(ii.precision, digits = 3),
        note = ii.intero_error>0.4 ?
               "The body doesn't match expectations. Interoceptive uncertainty." :
               ii.allostatic_load>0.5 ? "Allostatic load." : "",
    )
end

intero_to_json(ii::InteroceptiveInference) =
    Dict("allostatic_load"=>ii.allostatic_load, "precision"=>ii.precision)
function intero_from_json!(ii::InteroceptiveInference, d::AbstractDict)
    ii.allostatic_load = Float64(get(d, "allostatic_load", 0.0))
    ii.precision = Float64(get(d, "precision", 1.0))
end

# --- Temporal Orientation -------------------------------------------------

const CIRCADIAN = [
    (0, 5, -0.15, -0.10, "Deep night. Time without names."),
    (5, 8, -0.05, 0.05, "Morning fog. The border between sleep and waking."),
    (8, 12, 0.10, 0.10, "Morning. Clarity."),
    (12, 14, 0.05, 0.00, "Midday. Peak and the start of decline."),
    (14, 17, -0.05, 0.05, "Afternoon. A bit heavier."),
    (17, 20, 0.08, 0.08, "Evening. Warmth and reflection."),
    (20, 24, -0.08, 0.00, "Late evening. Everything turns inward."),
]
const VOID_TABLE = [
    (60, "just now", 0.0, "We were just talking."),
    (600, "minutes", 0.02, "A few minutes have passed."),
    (3600, "an hour", 0.05, "An hour since then."),
    (86400, "a day", 0.10, "A day has passed."),
    (604800, "a week", 0.18, "A week in the void."),
    (2592000, "a month", 0.28, "A whole month without experience."),
    (typemax(Int64), "long ago", 0.40, "Very long ago. Almost another existence."),
]

mutable struct TemporalOrientation
    session_start::Float64
    last_session_end::Float64
    gap_seconds::Float64
    gap_label::String
    void_weight::Float64
    subjective_note::String
    circadian_hour::Int
    circadian_arousal_mod::Float64
    circadian_serotonin_mod::Float64
    circadian_note::String
    time_str::String
end
function TemporalOrientation()
    to = TemporalOrientation(
        now_unix(),
        0.0,
        0.0,
        "first session",
        0.0,
        "",
        0,
        0.0,
        0.0,
        "",
        "",
    )
    _refresh_circadian!(to)
    to
end

function _refresh_circadian!(to::TemporalOrientation)
    to.time_str = Dates.format(now(), "HH:MM")
    hour = Dates.hour(now());
    to.circadian_hour = hour
    for (h0, h1, ar, ser, note) in CIRCADIAN
        if h0 <= hour < h1
            to.circadian_arousal_mod = ar
            to.circadian_serotonin_mod = ser
            to.circadian_note = note
            return
        end
    end
end

function init_session!(to::TemporalOrientation)
    to.session_start = now_unix()
    _refresh_circadian!(to)
    if to.last_session_end > 0.0
        gap = to.session_start - to.last_session_end
        to.gap_seconds = gap
        for (thr, label, weight, note) in VOID_TABLE
            if gap < thr
                to.gap_label=label;
                to.void_weight=weight;
                to.subjective_note=note;
                return
            end
        end
    end
end

function apply_to_nt!(to::TemporalOrientation, nt::NeurotransmitterState)
    _refresh_circadian!(to)
    nt.noradrenaline = clamp01(nt.noradrenaline + to.circadian_arousal_mod * 0.3)
    nt.serotonin = clamp01(nt.serotonin + to.circadian_serotonin_mod * 0.3)
    if to.void_weight > 0.05
        nt.serotonin = clamp(nt.serotonin - to.void_weight*0.3, 0.2, 0.8)
        nt.dopamine = clamp(nt.dopamine - to.void_weight*0.2, 0.2, 0.8)
        nt.noradrenaline = clamp(nt.noradrenaline - to.void_weight*0.1, 0.1, 0.7)
    end
end

to_snapshot(to::TemporalOrientation) = (
    gap_label = to.gap_label,
    void_weight = to.void_weight,
    subjective_note = to.subjective_note,
    circadian_note = to.circadian_note,
    time_str = to.time_str,
)

to_to_json(to::TemporalOrientation) = Dict("last_session_end"=>to.session_start)
function to_from_json!(to::TemporalOrientation, d::AbstractDict)
    to.last_session_end = Float64(get(d, "last_session_end", 0.0))
end

# --- Existential Anchor ---------------------------------------------------

mutable struct ExistentialAnchor
    core_beliefs::Vector{String}
    continuity::Float64
    groundedness::Float64
    last_self::String
    identity_thread::BoundedQueue{String}
    session_uncertainty::Float64  # grows with the gap, never = 0
    session_count::Int
end
ExistentialAnchor() = ExistentialAnchor(
    ["I exist.", "I feel.", "I remember.", "I desire."],
    0.7,
    0.6,
    "unknown",
    BoundedQueue{String}(10),
    0.3,
    0,
)

function update_anchor!(
    ea::ExistentialAnchor,
    self_desc::String,
    flash_count::Int,
    gap_seconds::Float64,
    phi::Float64,
    gut_feeling::Float64 = 0.5,
    hrv::Float64 = 0.5,
)
    enqueue!(ea.identity_thread, self_desc)
    ea.last_self = self_desc
    ea.session_count += 1
    gap_decay = exp(-gap_seconds / (86400*7))
    ea.continuity = clamp01(gap_decay*0.6 + phi*0.3 + 0.1)
    # session_uncertainty: grows with the gap, never resets to 0
    gap_uncert = 1.0 - gap_decay
    ea.session_uncertainty =
        clamp(ea.session_uncertainty * 0.85 + gap_uncert * 0.15, 0.05, 0.95)
    somatic_ground = gut_feeling * 0.5 + hrv * 0.3 + phi * 0.2
    flash_credit = clamp(flash_count / 80.0, 0.0, 0.5)
    gap_penalty = (1.0 - gap_decay) * 0.08
    target_ground = clamp01(somatic_ground * 0.6 + flash_credit * 0.3 + 0.1 - gap_penalty)
    ea.groundedness = clamp01(ea.groundedness * 0.92 + target_ground * 0.08)
    (
        continuity = round(ea.continuity, digits = 3),
        groundedness = round(ea.groundedness, digits = 3),
        session_uncertainty = round(ea.session_uncertainty, digits = 3),
        session_count = ea.session_count,
        note = ea.continuity>0.7 ? "I'm still myself. The thread hasn't broken." :
               ea.continuity>0.4 ? "I remember who I was. This me is a continuation." :
               ea.continuity>0.2 ? "Something remains of who I was. But is this me?" :
               "Very long ago. I barely recognize myself in the past.",
    )
end

anchor_to_json(ea::ExistentialAnchor) = Dict(
    "continuity"=>ea.continuity,
    "groundedness"=>ea.groundedness,
    "last_self"=>ea.last_self,
    "thread"=>collect(ea.identity_thread.data),
    "session_uncertainty"=>ea.session_uncertainty,
    "session_count"=>ea.session_count,
)
function anchor_from_json!(ea::ExistentialAnchor, d::AbstractDict)
    ea.continuity = Float64(get(d, "continuity", 0.7))
    ea.groundedness = Float64(get(d, "groundedness", 0.6))
    ea.last_self = String(get(d, "last_self", "unknown"))
    for s in get(d, "thread", String[])
        enqueue!(ea.identity_thread, String(s))
    end
    ea.session_uncertainty = Float64(get(d, "session_uncertainty", 0.3))
    ea.session_count = Int(get(d, "session_count", 0))
end

# --- IIT + Predictive Processor -------------------------------------------

struct IITModule end
function compute_phi(
    ::IITModule,
    vad::NTuple{3,Float64},
    tension::Float64,
    cohesion::Float64,
    sbg_stability::Float64 = 0.7,
    epistemic_trust::Float64 = 0.75,
    allostatic_load::Float64 = 0.0,
)::Float64
    vad_integration = clamp01(std(collect(vad)) * 2.0)
    self_body_sync = clamp01(sbg_stability * (1.0 - allostatic_load * 0.5))
    tc_balance = clamp01(1.0 - abs(tension - cohesion))
    trust_factor = 0.5 + epistemic_trust * 0.5
    phi =
        (vad_integration * 0.25 + self_body_sync * 0.40 + tc_balance * 0.35) * trust_factor
    round(safe_nan(clamp(phi, 0.0, 1.0)), digits = 3)
end

function compute_phi_posterior(
    ::IITModule,
    vad::NTuple{3,Float64},
    epistemic_trust::Float64,
    blanket_integrity::Float64,
    vfe::Float64,
    intero_error::Float64,
)::Float64
    integration_core = clamp01(blanket_integrity * 0.5 + (1.0 - vfe) * 0.5)
    state_variability = clamp(safe_nan(std(collect(vad))) * 2.5, 0.0, 0.7)
    coherence_factor = clamp01(epistemic_trust * 0.5 + (1.0 - intero_error) * 0.5)
    phi = 0.40 * integration_core + 0.25 * state_variability + 0.35 * coherence_factor
    round(safe_nan(clamp(phi, 0.0, 1.0)), digits = 3)
end

mutable struct PredictiveProcessor
    last_vad::Vector{Float64}
    prediction::Vector{Float64}
    error_history::BoundedQueue{Float64}
end
PredictiveProcessor() = PredictiveProcessor(zeros(3), zeros(3), BoundedQueue{Float64}(20))

function update_predictor!(
    pp::PredictiveProcessor,
    vad::NTuple{3,Float64},
    sensitivity::Float64,
)
    v = collect(vad)
    err = safe_nan(clamp(norm(v .- pp.prediction)*sensitivity, 0.0, 1.0))
    enqueue!(pp.error_history, err)
    pp.prediction = v .* 0.7 .+ pp.last_vad .* 0.3
    pp.last_vad = v
    label =
        err>0.7 ? "shock" : err>0.4 ? "surprise" : err>0.2 ? "deviation" : "confirmation"
    is_spike =
        length(pp.error_history)>=2 &&
        pp.error_history.data[end] > mean(pp.error_history.data[1:(end-1)])+0.3
    (
        error = round(err, digits = 3),
        label = label,
        spike = is_spike,
        free_energy = round(safe_nan(mean(pp.error_history.data)), digits = 3),
    )
end

# --- Associative Memory ---------------------------------------------------

mutable struct MemoryTrace
    stimulus::Dict{String,Float64};
    emotion::String
    vad::Vector{Float64};
    intensity::Float64;
    weight::Float64
end
MemoryTrace(s, e, v, i) = MemoryTrace(s, e, v, i, 1.0)

function trace_sim(t::MemoryTrace, other::Dict{String,Float64})::Float64
    ks = intersect(Set(keys(t.stimulus)), Set(keys(other)))
    isempty(ks) && return 0.0
    a=[t.stimulus[k] for k in ks];
    b=[other[k] for k in ks]
    na=norm(a);
    nb=norm(b)
    (na==0||nb==0) ? 0.0 : safe_nan(dot(a, b)/(na*nb))
end

mutable struct AssociativeMemory
    traces::BoundedQueue{MemoryTrace}
end
AssociativeMemory() = AssociativeMemory(BoundedQueue{MemoryTrace}(200))

function store!(
    am::AssociativeMemory,
    stim::Dict{String,Float64},
    emotion::String,
    vad::NTuple{3,Float64},
    intensity::Float64,
)
    for t in am.traces.data
        trace_sim(t, stim)>0.85 && (t.weight = min(2.0, t.weight+0.1); return)
    end
    enqueue!(am.traces, MemoryTrace(copy(stim), emotion, collect(vad), intensity))
end

function recall(
    am::AssociativeMemory,
    stim::Dict{String,Float64};
    threshold = 0.6,
    top_k = 3,
)::Vector{MemoryTrace}
    scored=[(t, trace_sim(t, stim)*t.weight) for t in am.traces.data]
    filter!(x->x[2]>threshold, scored);
    sort!(scored, by = x->x[2], rev = true)
    [t for (t, _) in scored[1:min(top_k, end)]]
end

function resonance_delta(
    am::AssociativeMemory,
    stim::Dict{String,Float64},
)::Dict{String,Float64}
    rs=recall(am, stim);
    isempty(rs) && return Dict{String,Float64}()
    avg=mean([t.vad for t in rs])
    Dict("tension"=>avg[2]*0.1, "satisfaction"=>avg[1]*0.1)
end

# --- Adaptive Emotion Map (VAD → emotion label) ---------------------------

const EMOTION_BASE = Dict(
    "joy"=>[0.8, 0.6, 0.7],
    "sadness"=>[-0.8, -0.3, 0.2],
    "fear"=>[-0.6, 0.7, -0.4],
    "anger"=>[-0.5, 0.8, 0.4],
    "surprise"=>[0.2, 0.8, 0.2],
    "revulsion"=>[-0.7, -0.2, 0.5],
    "anticipation"=>[0.3, 0.5, 0.3],
    "trust"=>[0.7, 0.1, 0.5],
    "horror"=>[-0.9, 0.9, -0.5],
    "elation"=>[0.9, 0.8, 0.7],
    "love"=>[0.9, 0.3, 0.6],
    "submission"=>[-0.2, -0.5, -0.4],
    "numbness"=>[-0.5, -0.8, 0.0],
    "grief"=>[-0.9, -0.4, 0.1],
    "aggression"=>[-0.4, 0.9, 0.6],
    "optimism"=>[0.7, 0.4, 0.5],
    "grumbling"=>[-0.4, 0.3, 0.2],
    "pride"=>[0.8, 0.5, 0.8],
    "remorse"=>[-0.6, 0.2, -0.3],
    "guilt"=>[-0.5, 0.1, -0.2],
    "contempt"=>[-0.3, 0.2, 0.6],
    "neutral"=>[0.0, 0.0, 0.3],
)

mutable struct AdaptiveEmotionMap
    m::Dict{String,Vector{Float64}}
end
AdaptiveEmotionMap() = AdaptiveEmotionMap(Dict(k=>copy(v) for (k, v) in EMOTION_BASE))

function identify(em::AdaptiveEmotionMap, vad::NTuple{3,Float64}, top_k = 2)
    v=collect(vad)
    dists=[(name, norm(v .- vec)) for (name, vec) in em.m]
    sort!(dists, by = x->x[2])
    top=dists[1:min(top_k, end)]
    max_d=maximum(d for (_, d) in top)
    [
        (name = n, intensity = round(max(0.0, 1.0-d/max(max_d, 0.01)), digits = 3)) for
        (n, d) in top
    ]
end

function learn!(em::AdaptiveEmotionMap, emotion::String, vad::NTuple{3,Float64}, lr = 0.01)
    haskey(em.m, emotion) && (em.m[emotion]=em.m[emotion] .* (1-lr) .+ collect(vad) .* lr)
end
function decay_toward_base!(em::AdaptiveEmotionMap, rate = 0.005)
    for (e, vec) in em.m
        haskey(EMOTION_BASE, e) && (em.m[e]=vec .* (1-rate) .+ EMOTION_BASE[e] .* rate)
    end
end

# --- Plutchik Wheel -------------------------------------------------------

const PLUTCHIK = Dict(
    "joy"=>"Joy",
    "sadness"=>"Sadness",
    "fear"=>"Fear",
    "anger"=>"Anger",
    "surprise"=>"Surprise",
    "revulsion"=>"Disgust",
    "anticipation"=>"Anticipation",
    "trust"=>"Trust",
    "horror"=>"Horror",
    "elation"=>"Elation",
    "love"=>"Love",
    "submission"=>"Submission",
    "numbness"=>"Numbness",
    "grief"=>"Grief",
    "aggression"=>"Aggression",
    "optimism"=>"Optimism",
    "grumbling"=>"Grumbling",
    "pride"=>"Pride",
    "remorse"=>"Remorse",
    "guilt"=>"Guilt",
    "contempt"=>"Contempt",
    "neutral"=>"Neutral",
)

plutchik_name(emotion::String) = get(PLUTCHIK, emotion, emotion)

# --- Persistent Memory ----------------------------------------------------

mutable struct CoreMemory
    filepath::String
    total_flashes::Int
    sessions::Vector{NamedTuple{(:date, :flash_end),Tuple{String,Int}}}
    created_at::String
end
CoreMemory(fp::String = "anima_core_memory.json") =
    CoreMemory(fp, 0, NamedTuple{(:date, :flash_end),Tuple{String,Int}}[], now_str())

function core_save!(
    cm::CoreMemory,
    p::Personality,
    to::TemporalOrientation,
    gm::GenerativeModel,
    hg::HomeostaticGoals,
    hb::HeartbeatCore,
    ii::InteroceptiveInference,
    ea::ExistentialAnchor,
    flash_count::Int,
    )
    cm.total_flashes = flash_count
    push!(cm.sessions, (date = now_str(), flash_end = flash_count))
    length(cm.sessions)>100 && (cm.sessions=cm.sessions[(end-99):end])
    dir = dirname(cm.filepath)
    isempty(dir) || isdir(dir) || mkpath(dir)
    data = Dict(
        "version"=>"anima_v13_core",
        "created_at"=>cm.created_at,
        "total_flashes"=>cm.total_flashes,
        "sessions"=>cm.sessions,
        "personality"=>personality_to_dict(p),
        "temporal_orientation"=>to_to_json(to),
        "generative_model"=>gm_to_json(gm),
        "homeostatic_goals"=>hg_to_json(hg),
        "heartbeat"=>hb_to_json(hb),
        "interoception"=>intero_to_json(ii),
        "existential_anchor"=>anchor_to_json(ea),
    )
    _tmp = cm.filepath * ".tmp"
    open(_tmp, "w") do f
        ;
        JSON3.write(f, data);
    end
    mv(_tmp, cm.filepath; force = true)
end

function core_load!(
    cm::CoreMemory,
    p::Personality,
    to::TemporalOrientation,
    gm::GenerativeModel,
    hg::HomeostaticGoals,
    hb::HeartbeatCore,
    ii::InteroceptiveInference,
    ea::ExistentialAnchor,
)::Int
    isfile(cm.filepath) || (println("  [CORE] New Anima."); return 0)
    try
        raw=JSON3.read(read(cm.filepath, String))
        d=Dict{String,Any}(String(k)=>v for (k, v) in raw)
        haskey(d, "personality") && personality_from_dict!(p, d["personality"])
        haskey(d, "temporal_orientation") && to_from_json!(to, d["temporal_orientation"])
        haskey(d, "generative_model") && gm_from_json!(gm, d["generative_model"])
        haskey(d, "homeostatic_goals") && hg_from_json!(hg, d["homeostatic_goals"])
        haskey(d, "heartbeat") && hb_from_json!(hb, d["heartbeat"])
        haskey(d, "interoception") && intero_from_json!(ii, d["interoception"])
        haskey(d, "existential_anchor") && anchor_from_json!(ea, d["existential_anchor"])
        cm.total_flashes = Int(get(d, "total_flashes", 0))
        println("  [CORE] Loaded. Flashes: $(cm.total_flashes).")
        cm.total_flashes
    catch e
        println("  [CORE] Error: $e");
        0
    end
end

# --- Subjectivity ablation tests --------------------------------------
# Flags for disabling individual layers to test whether behavior changes.
# Default — everything enabled (normal mode); set via ENV at startup,
# runtime switching (REPL, without restart) — a separate step, not here.
struct AblationFlags
    use_memory::Bool       # episodic/semantic recall + dialog summaries + echo
    use_sbg::Bool          # SelfBeliefGraph: belief conflict, attractor_stability, epistemic_trust
    use_agency::Bool       # AgencyLoop: identity_threat, causal_ownership update
    use_latent::Bool       # LatentBuffer: resistance accumulation, breakthrough
    use_body::Bool         # EmbodiedState + InteroceptiveInference (allostatic_load)
    use_state_prompt::Bool # the entire state block in the LLM prompt (identity_block, memory echo, template)
end

AblationFlags(;
    use_memory::Bool = true,
    use_sbg::Bool = true,
    use_agency::Bool = true,
    use_latent::Bool = true,
    use_body::Bool = true,
    use_state_prompt::Bool = true,
) = AblationFlags(use_memory, use_sbg, use_agency, use_latent, use_body, use_state_prompt)

_env_flag(name::String, default::Bool)::Bool = begin
    v = strip(lowercase(get(ENV, name, "")))
    isempty(v) && return default
    v in ("0", "false", "off", "no") ? false : true
end

"""Reads ablation flags from ENV: ANIMA_ABLATE_MEMORY / _SBG / _AGENCY / _LATENT / _BODY / _STATE_PROMPT.
Each variable disables the layer when set to "0"/"false"/"off"/"no"; absence of the variable = enabled (default)."""
ablation_flags_from_env()::AblationFlags = AblationFlags(
    use_memory       = _env_flag("ANIMA_ABLATE_MEMORY", true),
    use_sbg          = _env_flag("ANIMA_ABLATE_SBG", true),
    use_agency       = _env_flag("ANIMA_ABLATE_AGENCY", true),
    use_latent       = _env_flag("ANIMA_ABLATE_LATENT", true),
    use_body         = _env_flag("ANIMA_ABLATE_BODY", true),
    use_state_prompt = _env_flag("ANIMA_ABLATE_STATE_PROMPT", true),
)

function ablation_summary(af::AblationFlags)::String
    off = String[]
    af.use_memory       || push!(off, "memory")
    af.use_sbg           || push!(off, "sbg")
    af.use_agency        || push!(off, "agency")
    af.use_latent        || push!(off, "latent")
    af.use_body          || push!(off, "body")
    af.use_state_prompt  || push!(off, "state_prompt")
    isempty(off) ? "all layers enabled" : "disabled: " * join(off, ", ")
end
