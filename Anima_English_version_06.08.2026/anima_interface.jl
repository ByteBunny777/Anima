# A N I M A  —  Interface  (Julia)
#
# Displaying state, without side effects on the psyche.
#
#  Anima               — main struct + experience! loop
#  build_narrative      — inner voice from the current state
#  log_flash            — terminal debug line
#  text_to_stimulus     — text → stimulus without an LLM

using HTTP
using JSON3
using Printf
using LinearAlgebra

if !isdefined(@__MODULE__, :anima_state_path)
    function anima_state_path(filename::String)
        dir = strip(get(ENV, "ANIMA_STATE_DIR", @__DIR__))
        isempty(dir) && (dir = @__DIR__)
        dir = isabspath(dir) ? dir : joinpath(@__DIR__, dir)
        isdir(dir) || mkpath(dir)
        joinpath(dir, filename)
    end
end

if !isdefined(@__MODULE__, :push_gui_event!)
    push_gui_event!(kind::String, payload::AbstractDict) = nothing
end

if !isdefined(@__MODULE__, :write_gui_state!)
    write_gui_state!(a, r; kwargs...) = nothing
end

if !isdefined(@__MODULE__, :push_gui_chat!)
    push_gui_chat!(role::String, text::String; flash = nothing, meta = nothing) = nothing
end

# Include all layers — order matters
include(joinpath(@__DIR__, "anima_core.jl"))
include(joinpath(@__DIR__, "anima_psyche.jl"))
include(joinpath(@__DIR__, "anima_self.jl"))
include(joinpath(@__DIR__, "anima_crisis.jl"))

# anima_input_llm.jl is optional — fallback to text_to_stimulus
let _input_llm_path = joinpath(@__DIR__, "anima_input_llm.jl")
    if isfile(_input_llm_path)
        include(_input_llm_path)
    else
        @warn "anima_input_llm.jl not found — falling back to text_to_stimulus"
        # FIXED: without `global` these definitions would be local to this
        # `let` block (hard local scope) and wouldn't be visible from anima_background.jl /
        # anima_telegram.jl, where these functions are actually called — the code would crash with
        # UndefVarError as soon as this fallback path fired.
        global process_input(text::String, fallback_fn; kwargs...) =
            (fallback_fn(text), "fallback", "")
        global input_source_label(src::String) = src == "fallback" ? "[rule]" : "[llm]"
    end
end

# --- Authenticity Monitor (phase 5) -----------------------------------
mutable struct AuthenticityMonitor
    authenticity_drift::Float64
    fabrication_risk::Float64
    narrative_overreach::Float64
    last_flags::Vector{String}
end
AuthenticityMonitor() = AuthenticityMonitor(0.0, 0.0, 0.0, String[])

function check_authenticity!(
    am::AuthenticityMonitor,
    phi::Float64,
    crisis_mode::String,
    gc_snap,
    lb_snap,
    ur_snap,
    coherence::Float64,
    epistemic_trust::Float64,
    response_length::Int,
)

    flags = String[]
    am.last_flags = String[]

    # Coherence overreach
    is_disintegrated = crisis_mode == "disintegrated"
    long_response = response_length > 120
    low_phi = phi < 0.25

    if is_disintegrated && low_phi && long_response
        am.narrative_overreach = clamp01(am.narrative_overreach + 0.15)
        push!(flags, "coherence_overreach")
    else
        am.narrative_overreach = clamp01(am.narrative_overreach - 0.04)
    end

    # Fabrication risk
    conflict_unresolved = gc_snap.active && gc_snap.resolution == "unresolved"
    latent_breakthrough = lb_snap.breakthrough
    low_coherence = coherence < 0.35

    fabrication_signal = 0.0
    conflict_unresolved && (fabrication_signal += 0.2)
    latent_breakthrough && (fabrication_signal += 0.15)
    low_coherence && (fabrication_signal += 0.1)
    epistemic_trust < 0.4 && (fabrication_signal += 0.15)

    am.fabrication_risk = clamp01(am.fabrication_risk * 0.75 + fabrication_signal * 0.25)
    am.fabrication_risk > 0.45 && push!(flags, "fabrication_risk")

    # Authenticity drift
    unknown_high = ur_snap.dominant_val > 0.5
    unknown_high &&
        long_response &&
        (am.authenticity_drift = clamp01(am.authenticity_drift + 0.12))
    !unknown_high && (am.authenticity_drift = clamp01(am.authenticity_drift - 0.03))
    am.authenticity_drift > 0.4 && push!(flags, "authenticity_drift")

    # State-narrative mismatch
    high_integration = phi > 0.6 && epistemic_trust > 0.6
    negative_state = crisis_mode ∈ ("disintegrated", "fragmented") && coherence < 0.45
    if high_integration && !negative_state && am.fabrication_risk < 0.3
        am.authenticity_drift = max(0.0, am.authenticity_drift - 0.05)
    elseif !high_integration && coherence < 0.35
        am.authenticity_drift = clamp01(am.authenticity_drift + 0.08)
        push!(flags, "state_narrative_mismatch")
    end

    am.last_flags = flags

    note = if am.fabrication_risk > 0.55
        "note: high likelihood of rationalization ($(round(am.fabrication_risk,digits=2)))"
    elseif am.narrative_overreach > 0.5
        "note: narrative broader than the actual state"
    elseif am.authenticity_drift > 0.45
        "note: response more confident than warranted"
    else
        ""
    end

    (
        fabrication_risk = round(am.fabrication_risk, digits = 3),
        narrative_overreach = round(am.narrative_overreach, digits = 3),
        authenticity_drift = round(am.authenticity_drift, digits = 3),
        flags = flags,
        note = note,
    )
end

am_to_json(am::AuthenticityMonitor) = Dict(
    "authenticity_drift" => am.authenticity_drift,
    "fabrication_risk" => am.fabrication_risk,
    "narrative_overreach" => am.narrative_overreach,
)
function am_from_json!(am::AuthenticityMonitor, d::AbstractDict)
    am.authenticity_drift = Float64(get(d, "authenticity_drift", 0.0))
    am.fabrication_risk = Float64(get(d, "fabrication_risk", 0.0))
    am.narrative_overreach = Float64(get(d, "narrative_overreach", 0.0))
end

function anima_state_file(psyche_mem_path::String, stem::String)::String
    dir = dirname(psyche_mem_path)
    base = basename(psyche_mem_path)
    filename = occursin("psyche", base) ?
        replace(base, "psyche" => stem) :
        "anima_$(stem).json"
    joinpath(dir, filename)
end

# --- Anima – Main Struct ---------------------------------------
mutable struct Anima
    # Core
    personality::Personality
    values::ValueSystem
    nt::NeurotransmitterState
    body::EmbodiedState
    heartbeat::HeartbeatCore
    gen_model::GenerativeModel
    blanket::MarkovBlanket
    homeostasis::HomeostaticGoals
    attention::AttentionNarrowing
    interoception::InteroceptiveInference
    temporal::TemporalOrientation
    anchor::ExistentialAnchor
    iit::IITModule
    predictor::PredictiveProcessor
    emotion_map::AdaptiveEmotionMap
    memory::AssociativeMemory
    core_mem::CoreMemory
    # Psyche
    narrative_gravity::NarrativeGravity
    anticipatory::AnticipatoryConsciousness
    solomonoff::SolomonoffWorldModel
    shame::ShameModule
    epistemic_defense::EpistemicDefense
    symptomogenesis::Symptomogenesis
    shadow::ShadowSelf
    chronified::ChronifiedAffect
    significance::IntrinsicSignificance
    moral::MoralCausality
    intent_engine::IntentEngine
    fatigue::FatigueSystem
    regression::StressRegression
    metacognition::Metacognition
    sig_layer::SignificanceLayer
    goal_conflict::GoalConflict
    latent_buffer::LatentBuffer
    structural_scars::StructuralScars
    unknown_register::UnknownRegister
    authenticity_monitor::AuthenticityMonitor
    inner_dialogue::InnerDialogue
    shadow_registry::ShadowRegistry
    curiosity_registry::CuriosityRegistry
    commitment_registry::CommitmentRegistry
    life_threads::Vector{CuriosityThread}  # long-term unresolved topics
    # Self
    sbg::SelfBeliefGraph
    spm::SelfPredictiveModel
    agency::AgencyLoop
    isc::InterSessionConflict
    # Crisis
    crisis::CrisisMonitor
    # State
    flash_count::Int
    psyche_mem_path::String
    # narrative diversity cache
    _last_circadian_note::String
    _last_sig_note_flash::Int
    _subjective_note_shown::Bool # subjective_note is shown only once per session
    # initiative + veto
    _last_user_flash::Int        # flash count of last user input
    _last_self_msg_flash::Int    # flash count of last self-initiated message
    _last_user_time::Float64     # real time of last user input
    _last_self_msg_time::Float64 # real time of last self-initiated message
    authenticity_veto::Bool      # Anima internally disagrees with the request
    silent_disagreement::Any     # current silent disagreement: nothing | (source, content, strength)
    _session_phi_acc::Float64    # current session-average φ (carried over between sessions)
    _last_belief_conflict::Any        # last belief conflict (or nothing)
    narrative_snap::NarrativeSnapshot  # current narrative self
    aesthetic_sense::AestheticSense   # aesthetic traces from experience
    boredom::Float64                  # stimulus exhaustion: grows without novelty, decays on new input
    attention_focus::AttentionFocus   # competitive attention focus
    last_endorsement::Symbol          # result of the last evaluate_endorsement: :endorsed / :automatic / :not_mine
    ablation::AblationFlags           # ablation tests: which layers are enabled
end

function Anima(;
    personality = Personality(),
    values = ValueSystem(),
    core_mem_path = joinpath(@__DIR__, "anima_core.json"),
    psyche_mem_path = joinpath(@__DIR__, "anima_psyche.json"),
    ablation::AblationFlags = AblationFlags(),
)
    a = Anima(
        personality,
        values,
        NeurotransmitterState(),
        EmbodiedState(),
        HeartbeatCore(),
        GenerativeModel(),
        MarkovBlanket(),
        HomeostaticGoals(),
        AttentionNarrowing(),
        InteroceptiveInference(),
        TemporalOrientation(),
        ExistentialAnchor(),
        IITModule(),
        PredictiveProcessor(),
        AdaptiveEmotionMap(),
        AssociativeMemory(),
        CoreMemory(core_mem_path),
        NarrativeGravity(),
        AnticipatoryConsciousness(),
        SolomonoffWorldModel(),
        ShameModule(),
        EpistemicDefense(),
        Symptomogenesis(),
        ShadowSelf(),
        ChronifiedAffect(),
        IntrinsicSignificance(),
        MoralCausality(),
        IntentEngine(),
        FatigueSystem(),
        StressRegression(),
        Metacognition(),
        SignificanceLayer(),
        GoalConflict(),
        LatentBuffer(),
        StructuralScars(),
        UnknownRegister(),
        AuthenticityMonitor(),
        InnerDialogue(),
        ShadowRegistry(),
        CuriosityRegistry(),
        CommitmentRegistry(),
        CuriosityThread[],      # life_threads
        SelfBeliefGraph(),
        SelfPredictiveModel(),
        AgencyLoop(),
        InterSessionConflict(),
        CrisisMonitor(),
        0,
        psyche_mem_path,
        "",
        0,
        false,  # _subjective_note_shown
        # initiative + veto
        0,       # _last_user_flash
        0,       # _last_self_msg_flash
        0.0,     # _last_user_time
        0.0,     # _last_self_msg_time
        false,   # authenticity_veto
        nothing, # silent_disagreement
        0.5,     # _session_phi_acc
        nothing, # _last_belief_conflict
        NarrativeSnapshot(), # narrative_snap
        AestheticSense(),    # aesthetic_sense
        0.0,                 # boredom
        AttentionFocus(),    # attention_focus
        :automatic,          # last_endorsement
        ablation,            # ablation
    )
    # Load
    saved = core_load!(
        a.core_mem,
        a.personality,
        a.temporal,
        a.gen_model,
        a.homeostasis,
        a.heartbeat,
        a.interoception,
        a.anchor,
    )
    a.flash_count = saved
    psyche_load!(
        a.psyche_mem_path,
        a.narrative_gravity,
        a.anticipatory,
        a.solomonoff,
        a.shame,
        a.epistemic_defense,
        a.chronified,
        a.significance,
        a.moral,
        a.fatigue,
        a.sig_layer,
        a.goal_conflict,
        a.latent_buffer,
        a.structural_scars,
        a.shadow_registry,
        a.inner_dialogue,
        a.curiosity_registry,
        a.commitment_registry,
        a.aesthetic_sense,
        a.attention_focus,
        a.life_threads,
    )
    _self_path = anima_state_file(psyche_mem_path, "self")
    if isfile(_self_path)
        try
            _raw = JSON3.read(read(_self_path, String))
            _d = Dict{String,Any}(String(k)=>v for (k, v) in _raw)
            haskey(_d, "sbg") && sbg_from_json!(a.sbg, _d["sbg"])
            haskey(_d, "spm") && spm_from_json!(a.spm, _d["spm"])
            haskey(_d, "agency") && al_from_json!(a.agency, _d["agency"])
            haskey(_d, "isc") && isc_from_json!(a.isc, _d["isc"])
            haskey(_d, "crisis") && crisis_from_json!(a.crisis, _d["crisis"])
            haskey(_d, "unknown_register") &&
                ur_from_json!(a.unknown_register, _d["unknown_register"])
            haskey(_d, "authenticity_monitor") &&
                am_from_json!(a.authenticity_monitor, _d["authenticity_monitor"])
            if haskey(_d, "intent_engine")
                ie_d = _d["intent_engine"]
                goal = String(get(ie_d, "current_goal", ""))
                strength = Float64(get(ie_d, "current_strength", 0.0))
                origin = String(get(ie_d, "current_origin", "drive"))
                if !isempty(goal) && strength > 0.1
                    # floor 0.35 — to survive two decays on the first flash
                    a.intent_engine.current =
                        Intent(goal, max(strength * 0.7, 0.35), origin)
                end
                hist = get(ie_d, "history", String[])
                for g in hist
                    enqueue!(a.intent_engine.history, String(g))
                end
                dhist = get(ie_d, "drive_history", String[])
                for d in dhist
                    enqueue!(a.intent_engine.drive_history, String(d))
                end
            end
            println("  [SELF] Loaded. Beliefs: $(length(a.sbg.beliefs)).")
        catch e
            println("  [SELF] Load error: $e")
        end
    end
    # Loading anima_latent.json
    _latent_path = anima_state_file(psyche_mem_path, "latent")
    if isfile(_latent_path)
        try
            _raw = JSON3.read(read(_latent_path, String))
            _d = Dict{String,Any}(String(k)=>v for (k, v) in _raw)
            haskey(_d, "latent_buffer") &&
                lb_from_json!(a.latent_buffer, _d["latent_buffer"])
            haskey(_d, "structural_scars") &&
                scars_from_json!(a.structural_scars, _d["structural_scars"])
            println("  [BG] Latent state loaded.")
        catch e
            println("  [BG] Latent load: $e")
        end
    end

    _narrative_path = anima_state_file(psyche_mem_path, "narrative")
    a.narrative_snap = load_narrative(_narrative_path, a.flash_count)
    init_session!(a.temporal)
    apply_to_nt!(a.temporal, a.nt)
    # Checking for conflicts between sessions
    current_geom = belief_geometry(a.sbg)
    isc_result = check_session_conflict!(a.isc, current_geom)
    if isc_result.rupture
        println("  [SELF] Identity Rupture detected: $(isc_result.note)")
    elseif !isempty(isc_result.note)
        println("  [SELF] $(isc_result.note)")
    end
    a
end

function save!(a::Anima; summary = "", verbose = false)
    # Save this session's φ for the next one to use at startup
    if a.flash_count > 0
        a.gen_model.last_session_phi = a._session_phi_acc
    end
    core_save!(
        a.core_mem,
        a.personality,
        a.temporal,
        a.gen_model,
        a.homeostasis,
        a.heartbeat,
        a.interoception,
        a.anchor,
        a.flash_count,
    )
    psyche_save!(
        a.psyche_mem_path,
        a.narrative_gravity,
        a.anticipatory,
        a.solomonoff,
        a.shame,
        a.epistemic_defense,
        a.chronified,
        a.significance,
        a.moral,
        a.fatigue,
        a.sig_layer,
        a.goal_conflict,
        a.latent_buffer,
        a.structural_scars,
        a.shadow_registry,
        a.inner_dialogue,
        a.curiosity_registry,
        a.commitment_registry,
        a.aesthetic_sense,
        a.attention_focus,
        a.life_threads,
    )
    self_path = anima_state_file(a.psyche_mem_path, "self")
    self_data = Dict(
        "sbg"=>sbg_to_json(a.sbg),
        "spm"=>spm_to_json(a.spm),
        "agency"=>al_to_json(a.agency),
        "isc"=>isc_to_json(a.isc),
        "crisis"=>crisis_to_json(a.crisis),
        "unknown_register"=>ur_to_json(a.unknown_register),
        "authenticity_monitor"=>am_to_json(a.authenticity_monitor),
        "intent_engine"=>Dict(
            "current_goal" =>
                isnothing(a.intent_engine.current) ? "" : a.intent_engine.current.goal,
            "current_strength" =>
                isnothing(a.intent_engine.current) ? 0.0 : a.intent_engine.current.strength,
            "current_origin" =>
                isnothing(a.intent_engine.current) ? "" : a.intent_engine.current.origin,
            "history" => collect(a.intent_engine.history),
            "drive_history" => collect(a.intent_engine.drive_history),
        ),
    )
    self_dir = dirname(self_path)
    isempty(self_dir) || isdir(self_dir) || mkpath(self_dir)
    open(self_path, "w") do f
        ;
        JSON3.write(f, self_data);
    end
    save_session_geometry!(a.isc, belief_geometry(a.sbg))

    # session_intent — what Anima carries between sessions
    intent_path = anima_state_file(a.psyche_mem_path, "session_intent")
    top_co = top_curiosity(a.curiosity_registry)
    curiosity_active = !isnothing(top_co) && top_co.intensity > 0.4
    gc_active = a.goal_conflict.tension > 0.35
    lb_pressure = a.latent_buffer.resistance > 0.5

    if curiosity_active || gc_active || lb_pressure
        intent_type =
            curiosity_active ? "curiosity" :
            gc_active        ? "goal_conflict" : "latent_pressure"
        intent_label =
            curiosity_active ? top_co.label :
            gc_active        ? "$(a.goal_conflict.need_a) vs $(a.goal_conflict.need_b)" :
                               "resistance=$(round(a.latent_buffer.resistance, digits=2))"
        intent_signal =
            curiosity_active ? top_co.intensity :
            gc_active        ? a.goal_conflict.tension :
                               a.latent_buffer.resistance
        intent_data = Dict(
            "type"        => intent_type,
            "label"       => intent_label,
            "signal"      => intent_signal,
            "saved_flash" => a.flash_count,
        )

        # formed_thought: if curiosity has matured enough — formulate the thought
        # that "took shape" while not talking. Deterministic from the real state.
        if curiosity_active && top_co.intensity > 0.45
            _rh = top_co.refinement_history
            _thought = if length(_rh) >= 2
                "While you were away, I was thinking about \"$(top_co.label)\". " *
                "The question went through $(length(_rh)) refinements — " *
                "it started as \"$(_rh[1].old_label)\", now it's more concrete."
            elseif length(_rh) == 1
                "While you were away, I was thinking about \"$(top_co.label)\". " *
                "It changed — it used to be \"$(_rh[1].old_label)\"."
            else
                "While you were away, I was thinking about \"$(top_co.label)\". " *
                "This question hasn't closed."
            end
            intent_data["formed_thought"] = _thought
            intent_data["formed_thought_intensity"] = top_co.intensity
        end
        intent_dir = dirname(intent_path)
        isempty(intent_dir) || isdir(intent_dir) || mkpath(intent_dir)
        open(intent_path, "w") do f
            JSON3.write(f, intent_data)
        end
        @info "[SESSION_INTENT] saved: $intent_type — \"$intent_label\" (signal=$(round(intent_signal, digits=2)))"
    else
        isfile(intent_path) && rm(intent_path)
    end

    verbose && println("  [ANIMA] Saved. Flashes: $(a.flash_count).")
end

# --- apply_recall_ignition! ------------------------------------------
# If a memory is similar and heavy enough (sim×weight > 0.65) — it genuinely disturbs the state.
# GNWT: two modes — background whisper (0.65–0.80) and full ignition (> 0.80).
# On ignition, the memory takes over the whole workspace — a nonlinear jump, not a gradient.
function apply_recall_ignition!(a::Anima, hit::NamedTuple)
    rvad = hit.recalled_vad
    w    = Float64(hit.weight)
    sim  = Float64(hit.similarity)
    strength = sim * w   # > 0.65 already checked

    recall_vec = [rvad.arousal, rvad.valence, rvad.tension]
    posterior_vec = a.gen_model.posterior_mu[1:min(3, end)]
    recall_gap = norm(recall_vec[1:length(posterior_vec)] .- posterior_vec) / sqrt(3.0)

    # GNWT: full-ignition threshold
    full_ignition = strength > 0.80

    if full_ignition
        # The memory takes over the whole space: prior shifts sharply, pred_error spike
        ignition_weight = clamp(strength * 0.65, 0.0, 0.55)
        for i in 1:min(length(a.gen_model.prior_mu), 3)
            a.gen_model.prior_mu[i] =
                a.gen_model.prior_mu[i] * (1.0 - ignition_weight) +
                recall_vec[i] * ignition_weight
        end
        # prediction_error spike: gap between what was expected and what was recalled
        if recall_gap > 0.15
            na_spike = clamp(recall_gap * strength * 0.25, 0.0, 0.12)
            a.nt.noradrenaline = clamp(a.nt.noradrenaline + na_spike, 0.0, 1.0)
        end
        # prior_sigma expands sharply — the system is temporarily disoriented
        a.gen_model.prior_sigma = clamp(a.gen_model.prior_sigma + 0.15, 0.3, 1.2)
        # AttentionFocus: ignition via high external intensity — overrides the current one
        # identity_threat isn't used here: the memory disturbs the state but doesn't threaten identity
        update_attention_focus!(
            a.attention_focus, a.flash_count;
            external_label     = "↩ " * String(hit.emotion),
            external_intensity = clamp(strength * 0.9, 0.0, 1.0),
        )
        @info "[IGNITION:FULL] recalled=$(hit.emotion) sim=$(round(sim,digits=2)) w=$(round(w,digits=2)) gap=$(round(recall_gap,digits=2)) source=$(hit.recalled_source)"
        push_gui_event!("ignition", Dict(
            "mode" => "FULL", "recalled" => string(hit.emotion),
            "sim" => sim, "w" => w, "gap" => recall_gap,
            "source" => string(hit.recalled_source),
        ))
    else
        # Background whisper: gentle influence, as before
        ignition_weight = clamp(strength * 0.4, 0.0, 0.28)
        for i in 1:min(length(a.gen_model.prior_mu), 3)
            a.gen_model.prior_mu[i] =
                a.gen_model.prior_mu[i] * (1.0 - ignition_weight) +
                recall_vec[i] * ignition_weight
        end
        if recall_gap > 0.2
            sigma_expansion = clamp(recall_gap * strength * 0.15, 0.0, 0.12)
            a.gen_model.prior_sigma = clamp(a.gen_model.prior_sigma + sigma_expansion, 0.3, 1.2)
        end
        update_attention_focus!(
            a.attention_focus, a.flash_count;
            external_label     = "↩ " * String(hit.emotion),
            external_intensity = clamp(strength * 0.7, 0.0, 1.0),
        )
        @info "[IGNITION:soft] recalled=$(hit.emotion) sim=$(round(sim,digits=2)) w=$(round(w,digits=2)) source=$(hit.recalled_source)"
        push_gui_event!("ignition", Dict(
            "mode" => "soft", "recalled" => string(hit.emotion),
            "sim" => sim, "w" => w, "source" => string(hit.recalled_source),
        ))
    end

    # Bodily memory → bodily reaction (both modes)
    if hit.recalled_source == "self"
        somatic_echo = clamp((rvad.arousal - 0.5) * strength * (full_ignition ? 0.5 : 0.3), -0.10, 0.10)
        a.nt.noradrenaline = clamp(a.nt.noradrenaline + somatic_echo, 0.0, 1.0)
        a.interoception.allostatic_load =
            clamp(a.interoception.allostatic_load + abs(somatic_echo) * 0.5, 0.0, 1.0)
    end
end

# --- CausalTrace ------------------------------------------------------
# Partial chain from experience!: stimulus → memory_bias → NT → conflict → intent → policy.
# speech / self_hear / endorsed are filled in anima_background.jl after the LLM.
mutable struct CausalTrace
    flash::Int
    timestamp::Float64
    stimulus_keys::String       # stimulus keys, comma-separated — what came in from outside
    stimulus_values::String     # stimulus JSON (key→value) — raw data for honest replay
    user_message::String        # text of the human's message this flash — without it social_delta/curiosity/inner_dialogue can't be replayed
    memory_bias::Float64        # how much memory added to the stimulus (norm of mem_d)
    nt_serotonin::Float64
    nt_dopamine::Float64
    nt_noradrenaline::Float64
    phi::Float64
    gc_tension::Float64
    intent_goal::String
    intent_strength::Float64
    policy_drive::String
    # MAL: which loop had signal priority this flash
    mal_dominant::String
    mal_regime::String
    mal_score::Float64
    mal_determinant::String
    mal_runner_up::String
    mal_runner_up_score::Float64
    mal_loop_scores::String     # compact dump of weighted_scores for all loops: "curiosity=1.0,social=0.97,..."
    # MAL Phase 1: whether MAL and NT-drives agree on the intent direction
    dom_drive_nt::String
    dom_drive_mal::String
    drive_conflict::Bool
    # filled in background:
    speech_length::Int
    self_hear_mismatch::Float64
    endorsed::String
    causal_ownership::Float64
    # Curiosity Closure Signal (v1): progress_signal and churn regarding top_curiosity
    progress_signal::Bool
    progress_target::String
    churn::Bool
end

CausalTrace(flash::Int) = CausalTrace(
    flash, time(), "", "{}", "", 0.0,
    0.0, 0.0, 0.0, 0.0, 0.0,
    "", 0.0, "",
    "", "", 0.0, "", "", 0.0, "",
    "", "", false,
    0, 0.0, "", 0.0,
    false, "", false,
)

# --- experience! ------------------------------------------------------
function experience!(
    a::Anima,
    stimulus_raw::Dict{String,Float64};
    user_message::String = "",
    mem = nothing,
)

    a.flash_count += 1
    stim = copy(stimulus_raw)

    # Structural opposition: does the human's message contradict a central belief?
    # [ABLATION use_sbg] disabled — belief_conflict is always nothing, as if without SelfBeliefGraph
    belief_conflict =
        (a.ablation.use_sbg && !isempty(user_message)) ?
            detect_belief_conflict(a.sbg, user_message) : nothing
    a._last_belief_conflict = belief_conflict
    if !isnothing(belief_conflict) && a.ablation.use_latent
        # [ABLATION use_latent] disabled — resistance doesn't accumulate
        a.latent_buffer.resistance =
            clamp01(a.latent_buffer.resistance + belief_conflict.signal_strength * 0.4)
        @info "[RESISTANCE] belief under pressure: \"$(belief_conflict.belief_name)\" signal=$(belief_conflict.signal_strength)"
    end
    # D-vector: update accumulated pressure on identity
    # [ABLATION use_agency] disabled — identity_threat isn't updated, stays at its previous value
    a.ablation.use_agency && update_identity_threat!(a.agency, belief_conflict)

    # Social mirror
    if !isempty(user_message)
        for (k, v) in social_delta(user_message)
            stim[k] = get(stim, k, 0.0) + v*0.15
        end
    end

    # Memory resonance
    # [ABLATION use_memory] disabled — without associative memory resonance
    mem_d = a.ablation.use_memory ? resonance_delta(a.memory, stim) : Dict{String,Float64}()
    combined = Dict(
        k=>get(stim, k, 0.0)+get(mem_d, k, 0.0) for k in union(keys(stim), keys(mem_d))
    )

    # NT + body
    apply_stimulus!(a.nt, combined)
    decay_to_baseline!(a.nt, decay_rate(a.personality))
    # [ABLATION use_body] disabled — body frozen at baseline, NT is still computed (separate layer)
    a.ablation.use_body && update_from_nt!(a.body, a.nt)

    # Heartbeat
    hb_snap = tick_heartbeat!(a.heartbeat, a.nt)

    # VAD
    vad = to_vad(a.nt)
    t, a_r, s, c = to_reactors(a.nt)

    # Attention narrowing
    attn_snap = update_attention!(a.attention, a.nt, t)
    if attn_snap.radius < 0.99
        r = attn_snap.radius
        amp = Float64(attn_snap.threat_amplifier)
        for k in keys(stim)
            v = stim[k]
            if k in ("satisfaction", "cohesion") && v > 0.0
                stim[k] = v * r
            elseif k == "tension" && v > 0.0
                stim[k] = clamp(v * amp, -1.0, 1.0)
            elseif k == "arousal" && v > 0.0
                stim[k] = clamp(v * (1.0 + (1.0-r)*0.3), -1.0, 1.0)
            end
            if k in ("satisfaction", "cohesion") && v < 0.0
                stim[k] = clamp(v * amp, -1.0, 1.0)
            end
        end
    end

    # Emotions
    emotions = identify(a.emotion_map, vad)
    primary = emotions[1].name
    named = plutchik_name(primary)
    intensity = emotions[1].intensity
    learn!(a.emotion_map, primary, vad)
    decay_toward_base!(a.emotion_map)

    # IIT φ_prior
    # [ABLATION use_sbg / use_body] disabled — neutral values (0.5) instead of live sbg/interoception
    phi_prior = compute_phi(
        a.iit,
        vad,
        t,
        c,
        a.ablation.use_sbg ? a.sbg.attractor_stability : 0.5,
        a.ablation.use_sbg ? a.sbg.epistemic_trust : 0.5,
        a.ablation.use_body ? a.interoception.allostatic_load : 0.3,
    )
    phi = phi_prior

    # Predictive
    pred = update_predictor!(a.predictor, vad, surprise_sensitivity(a.personality))
    pred.spike && (a.nt.noradrenaline = clamp01(a.nt.noradrenaline + 0.08))

    # Fatigue + Regression
    stype = classify_stimulus(stim, pred.spike)
    update_fatigue!(a.fatigue, stype, pred.error, pred.spike)
    fat = fatigue_total(a.fatigue)
    update_regression!(a.regression, t, fat)

    # Intent
    drives = Dict(
        "tension"=>abs(t-0.5),
        "arousal"=>abs(a_r-0.5),
        "satisfaction"=>abs(s-0.5),
        "cohesion"=>abs(c-0.5),
    )
    _best_drive = argmax(drives)
    dom_drive::Union{String,Nothing} = drives[_best_drive] >= 0.15 ? _best_drive : nothing
    # Fallback for a neutral state after drift: cohesion is always a bit > 0.5
    # because serotonin pulls it up — we use this as a quiet default
    if isnothing(dom_drive) && drives["cohesion"] >= 0.05
        dom_drive = "cohesion"
    end
    id_stability = phi / (1.0+t)
    # Earlier call with the current (not-yet-updated) ownership — for the rest of the flash logic
    intent = update_intent!(
        a.intent_engine,
        dom_drive,
        named,
        id_stability,
        a.values,
        Float64(a.agency.causal_ownership);
        all_drives = drives,
    )

    # Dissonance + Defense
    diss = compute_dissonance(intent, t, a_r, s, c)
    t_adj = diss.level>0.3 ? clamp01(t + diss.level*0.1) : t
    defense = activate_defense(t_adj, a_r, s, c, a.personality.confabulation_rate)
    t_adj = !isnothing(defense) ? max(0.0, t_adj - defense.tension_relief) : t_adj
    shadow_push!(a.shadow, named, !isnothing(defense))

    # Shame + Epistemic
    update_shame!(a.shame, named, pred.error, diss.level, a.moral.agency, id_stability)
    ep_def = activate_epistemic!(
        a.epistemic_defense,
        diss.level,
        a.shame.level,
        fat,
        a.moral.agency,
    )

    # Symptom
    symptom = generate_symptom!(a.symptomogenesis, a.shadow.content, defense)
    sym_fx = symptom_reactor_delta(symptom)
    t_adj = clamp01(t_adj + sym_fx[1]);
    s_adj = clamp01(s + sym_fx[3])
    c_adj = clamp01(c + sym_fx[4])

    # Chronified
    update_chronified!(a.chronified, s_adj, c_adj, t_adj, a.moral.agency)

    # Significance
    update_significance!(a.significance, named, intensity, phi, a.flash_count)
    # Finitude raises significance: uncertainty of continuation = every moment matters more
    let su = a.anchor.session_uncertainty
        if su > 0.4
            boost = (su - 0.4) * 0.15
            a.significance.existential =
                clamp(a.significance.existential + boost * intensity, 0.0, 1.0)
            a.significance.relational =
                clamp(a.significance.relational + boost * intensity * 0.5, 0.0, 1.0)
        end
    end

    # Moral
    update_moral!(
        a.moral,
        named,
        isnothing(intent) ? "drive" : intent.origin,
        diss.level,
        a.values.integrity,
    )

    # Active Inference Core
    update_precision!(a.gen_model, pred.error, fat)
    posterior = update_beliefs!(a.gen_model, vad)
    prevent_prior_collapse!(a.gen_model)
    vfe_r = compute_vfe(a.gen_model, vad)

    # SignificanceLayer
    sl_snap = assess_significance!(
        a.sig_layer,
        stim,
        t_adj,
        a_r,
        s_adj,
        c_adj,
        vfe_r.vfe,
        pred.error,
        phi,
    )

    # CommitmentRegistry: if there's an active intent — update commitments
    if !isnothing(intent)
        tick_commitment!(a.commitment_registry, a.flash_count)
        update_commitment!(
            a.commitment_registry,
            intent.goal,
            a.flash_count;
            kept = intent.strength > 0.3,
        )
    end
    update_aesthetic!(a.aesthetic_sense, primary, Float64(phi), Float64(vad[1]), Float64(sl_snap.dominant_val), a.flash_count)

    # Recall ignition: check whether the current state resonates with a heavy memory
    # If so — the memory genuinely disturbs prior and attention, not just appears in the LLM context
    _had_ignition = false
    if !isnothing(mem)
        try
            _ign_vec = state_to_vec(
                Float64(a_r), Float64(vad[1]), Float64(t),
                Float64(phi), Float64(pred.error), Float64(a.agency.causal_ownership),
            )
            _ign_hits = recall_similar_states(
                mem, _ign_vec;
                top_n = 1, exclude_flash = a.flash_count,
                current_emotion = primary, current_phi = Float64(phi),
            )
            if !isempty(_ign_hits) && _ign_hits[1].ignition
                apply_recall_ignition!(a, _ign_hits[1])
                _had_ignition = true
            end
        catch _e
            @warn "[IGNITION] recall: $_e"
        end
    end

    # AttentionFocus: competitive selection of what dominates consciousness right now
    let lb = a.latent_buffer
        _lb_vals = Dict(:doubt=>lb.doubt, :shame=>lb.shame, :attachment=>lb.attachment, :threat=>lb.threat)
        _lb_dom = argmax(_lb_vals)
        _bc_sig = isnothing(a._last_belief_conflict) ? 0.0 : Float64(a._last_belief_conflict.signal_strength)
        _bc_name = isnothing(a._last_belief_conflict) ? "" : String(a._last_belief_conflict.belief_name)
        update_attention_focus!(
            a.attention_focus, a.flash_count;
            identity_threat    = Float64(a.agency.identity_threat),
            allostatic_load    = Float64(a.interoception.allostatic_load),
            pred_error         = pred.error,
            curiosity_obj      = top_curiosity(a.curiosity_registry),
            shadow_pressure    = Float64(a.shadow_registry.pressure),
            shame_level        = Float64(a.shame.level),
            gc_tension         = Float64(a.goal_conflict.tension),
            gc_label           = !isempty(a.goal_conflict.need_a) ?
                                     "$(a.goal_conflict.need_a) vs $(a.goal_conflict.need_b)" : "",
            lb_dominant        = _lb_dom,
            lb_val             = _lb_vals[_lb_dom],
            belief_conflict_name   = _bc_name,
            belief_conflict_signal = _bc_sig,
            external_label     = isempty(user_message) ? "" : first(user_message, 40),
            external_intensity = isempty(user_message) ? 0.0 :
                                     clamp(pred.error * 0.5 + abs(Float64(vad[1])) * 0.3, 0.0, 1.0),
        )
    end

    # Focus's influence on the stimulus: if the stimulus resonates with dominant — amplify pred_error and arousal
    # Honestly: the same stimulus is perceived differently depending on what's in focus
    let af = a.attention_focus
        if !isnothing(af.dominant) && af.dominant.intensity > 0.30
            resonance = 0.0
            ds = af.dominant.source
            if ds == :curiosity && pred.error > 0.15
                resonance = af.dominant.intensity * 0.25
            elseif ds == :goal_conflict && (get(stim, "tension", 0.0) > 0.1 || get(stim, "cohesion", 0.0) < 0.0)
                resonance = af.dominant.intensity * 0.20
            elseif ds == :threat && (get(stim, "tension", 0.0) > 0.0 || get(stim, "arousal", 0.0) > 0.0)
                resonance = af.dominant.intensity * 0.30
            elseif ds == :latent || ds == :shadow
                resonance = af.dominant.intensity * 0.15
            end
            if resonance > 0.0
                stim["arousal"] = clamp(get(stim, "arousal", 0.0) + resonance * 0.4, -1.0, 1.0)
                apply_stimulus!(a.nt, Dict{String,Float64}("arousal" => resonance * 0.2))
                @info "[FOCUS] resonance with $(af.dominant.source): +$(round(resonance, digits=2))"
            end
        end
    end
    gc_snap = update_goal_conflict!(
        a.goal_conflict,
        sl_snap,
        t_adj,
        s_adj,
        c_adj,
        phi,
        a.flash_count,
    )

    # MAL: Meta-Arbitration — which loop has signal priority this flash.
    # Pure function, transient — the result is only logged in CausalTrace.
    _arb = compute_arbitration(a)

    # CuriosityRegistry: topic_id — a stable cognitive theme, not an emotion.
    # Computed after _arb so we have a real dominant_loop as fallback.
    # detect_curiosity_trigger decides WHETHER curiosity arises and FROM WHAT
    # (pred_error/gc/mal, or, if pe is too small — a single unsatisfied need);
    # update_curiosity! decides nothing after this, it only updates the registry.
    let _gc_active = a.goal_conflict.tension > 0.35
        _trigger = detect_curiosity_trigger(
            _gc_active,
            pred.spike,
            Float64(a.spm.self_pred_error),
            _arb.dominant_loop,
            sl_snap,
        )
        if _trigger !== nothing
            _origin, _signal = _trigger
            # need-origin: the topic = the need itself, not mal_dominant/gc — otherwise
            # the object would lose its connection to what actually caused it.
            _topic_id = if _origin in NEED_ORIGINS
                String(_origin)
            else
                derive_topic_id(
                    a.goal_conflict.need_a,
                    a.goal_conflict.need_b,
                    _gc_active,
                    "",
                    _arb.dominant_loop,
                )
            end
            update_curiosity!(a.curiosity_registry, _topic_id, primary, _signal, Float64(vad[1]), a.flash_count, _origin)
        end

        # Resolve/refine ALL active objects every flash, regardless of whether
        # this flash spawned a new trigger above. Otherwise an object whose need
        # dropped below NEED_ORIGIN_THRESHOLD (trigger is silent), but is still above
        # NEED_RESOLVE_THRESHOLD (not yet satisfied), gets stuck forever — nothing
        # calls resolve for it anymore. Confirmed on live flashes
        # 350-351: contact_need=0.46, trigger silent, resolve was silent too.
        _resolved_before = Set(o.id for o in a.curiosity_registry.objects if o.resolved)
        resolve_all_curiosity!(a.curiosity_registry, primary, Float64(a.spm.self_pred_error), sl_snap, a.flash_count, user_message)
        for o in a.curiosity_registry.objects
            if o.resolved && !(o.id in _resolved_before)
                @info "[CURIOSITY_RESOLVED] \"$(o.label)\" origin=$(o.origin) flash=$(a.flash_count)"
                push_gui_event!("curiosity_resolved", Dict(
                    "label"  => o.label,
                    "origin" => string(o.origin),
                    "flash"  => a.flash_count,
                ))
            end
        end
    end

    # LatentBuffer + StructuralScars
    lb_snap = update_latent!(
        a.latent_buffer,
        gc_snap,
        t_adj,
        c_adj,
        s_adj,
        a.shame.level,
        a.flash_count,
    )
    if lb_snap.breakthrough
        _ = register_breakthrough!(
            a.structural_scars,
            lb_snap.breakthrough_type,
            a.flash_count,
        )
        decay_scars!(a.structural_scars)
        attenuation = 1.0 - scar_attenuation(a.structural_scars, lb_snap.breakthrough_type)
        for (k, v) in lb_snap.delta
            apply_stimulus!(a.nt, Dict{String,Float64}(k => v * attenuation))
        end
        t_adj = clamp01(to_reactors(a.nt)[1])
        s_adj = clamp01(to_reactors(a.nt)[3])
        c_adj = clamp01(to_reactors(a.nt)[4])
    else
        decay_scars!(a.structural_scars)
    end

    policy = select_policy(a.gen_model, vad)

    # CausalTrace: capture the chain up to speech (the rest is in background)
    _ctrace = CausalTrace(a.flash_count)
    _ctrace.stimulus_keys    = join(sort(collect(keys(stimulus_raw))), ",")
    _ctrace.stimulus_values  = JSON3.write(stimulus_raw)
    _ctrace.user_message     = user_message
    _ctrace.memory_bias      = Float64(norm(collect(values(mem_d))))
    _ctrace.nt_serotonin     = Float64(a.nt.serotonin)
    _ctrace.nt_dopamine      = Float64(a.nt.dopamine)
    _ctrace.nt_noradrenaline = Float64(a.nt.noradrenaline)
    _ctrace.phi              = phi
    _ctrace.gc_tension       = Float64(a.goal_conflict.tension)
    _ctrace.intent_goal      = isnothing(intent) ? "" : String(intent.goal)
    _ctrace.intent_strength  = isnothing(intent) ? 0.0 : Float64(intent.strength)
    _ctrace.policy_drive     = String(policy.drive)
    _ctrace.mal_dominant     = String(_arb.dominant_loop)
    _ctrace.mal_regime       = String(_arb.regime)
    _ctrace.mal_score        = _arb.score
    _ctrace.mal_determinant  = _arb.determinant
    _ctrace.mal_runner_up       = String(_arb.runner_up)
    _ctrace.mal_runner_up_score = _arb.runner_up_score
    _ctrace.mal_loop_scores      = join(
        ["$(k)=$(round(v, digits=3))" for (k, v) in sort(collect(_arb.loop_scores), by = kv -> -kv[2])],
        ",",
    )
    # MAL Phase 1: observation only — whether MAL and NT-drives agree.
    # :default isn't mapped (no winner) — the comparison isn't informative.
    _ctrace.dom_drive_nt  = isnothing(dom_drive) ? "" : dom_drive
    _ctrace.dom_drive_mal = _arb.regime == :default ? "" : get(_MAL_DRIVE_MAP, _arb.dominant_loop, "")
    _ctrace.drive_conflict = !isempty(_ctrace.dom_drive_mal) &&
        !isempty(_ctrace.dom_drive_nt) &&
        _ctrace.dom_drive_nt != _ctrace.dom_drive_mal

    update_blanket!(a.blanket, t_adj, a_r, s_adj, c_adj)
    homeo_snap = update_homeostasis!(a.homeostasis, vad)

    # Interoception
    intero_snap = update_interoception!(a.interoception, a.body, a.gen_model.prior_mu)

    # φ_posterior
    phi_posterior = compute_phi_posterior(
        a.iit,
        vad,
        a.sbg.epistemic_trust,
        a.blanket.integrity,
        vfe_r.vfe,
        Float64(intero_snap.intero_error),
    )
    phi = phi_posterior

    # Accumulate φ to carry over between sessions (exponential average)
    a._session_phi_acc = a._session_phi_acc * 0.97 + phi_posterior * 0.03

    # φ feedback — epistemic trust
    phi_delta = phi_posterior - phi_prior
    if abs(phi_delta) > 0.05
        trust_correction = clamp(phi_delta * 0.08, -0.04, 0.04)
        a.sbg.epistemic_trust = clamp(a.sbg.epistemic_trust + trust_correction, 0.0, 1.0)
    end

    # φ recursively: φ → GenerativeModel prior
    # High φ means good integration → prior becomes more stable (smaller sigma, bigger shift toward posterior)
    # Low φ → prior stays wide, less prone to updating
    let φ_factor = clamp(phi_posterior * 0.15, 0.0, 0.12)
        # prior_mu shifts toward posterior proportionally to φ
        a.gen_model.prior_mu =
            a.gen_model.prior_mu .* (1.0 - φ_factor) .+ a.gen_model.posterior_mu .* φ_factor
        # prior_sigma: high φ narrows it (more confidence in prior), low widens it
        phi_sigma_effect = clamp((phi_posterior - 0.5) * 0.12, -0.06, 0.06)
        a.gen_model.prior_sigma =
            clamp(a.gen_model.prior_sigma - phi_sigma_effect, 0.3, 1.2)
    end
    push_event!(
        a.narrative_gravity,
        named,
        intensity,
        Float64(sig_total(a.significance)),
        phi,
        a.flash_count,
        intensity*(vad[1]>0 ? 1.0 : -1.0),
    )
    grav_d = gravity_reactor_delta(a.narrative_gravity, a.flash_count)
    t_adj = clamp01(t_adj + grav_d.tension_d)
    s_adj = clamp01(s_adj + grav_d.satisfaction_d)
    c_adj = clamp01(c_adj + grav_d.cohesion_d)

    # Anticipatory
    ac_snap = update_anticipation!(a.anticipatory, named, t_adj, a_r, s_adj, c_adj, phi)
    t_adj = clamp01(t_adj + ac_snap.tension_d)
    s_adj = clamp01(s_adj + ac_snap.satisfaction_d)

    # Solomonoff
    observe_solom!(a.solomonoff, named, pred.label, a.flash_count)

    # Metacognition
    shame_p = a.shame.level>0.7 ? 3 : a.shame.level>0.5 ? 2 : a.shame.level>0.3 ? 1 : 0
    meta = observe_meta!(
        a.metacognition,
        named,
        defense,
        diss,
        id_stability;
        fatigue_p = round(Int, fat*3),
        regression_l = a.regression.level÷2,
        shame_p = shame_p,
    )

    # Existential Anchor
    anchor_snap = update_anchor!(
        a.anchor,
        "$(named) φ=$(round(phi,digits=2))",
        a.flash_count,
        a.temporal.gap_seconds,
        phi,
        a.body.gut_feeling,
        a.heartbeat.hrv,
    )

    # Self Module
    # evaluate_agency! evaluates the previous intent: does actual vad match predicted?
    # Must be BEFORE register_intent! — first evaluate what was, then register the new one
    _agency_eval = evaluate_agency!(a.agency, vad, a.flash_count)

    # MAL Phase 2: drive influence on the final intent.
    # The first update_intent! (above) — pure NT dynamics, don't touch it.
    # Here: MAL can shift or replace dom_drive.
    # :default → no change
    # :soft    → +MAL_SOFT_BIAS on the MAL-drive in all_drives (may not change the result — that's info too)
    # :hard    → the MAL-drive fully replaces dom_drive
    _mal_drive = get(_MAL_DRIVE_MAP, _arb.dominant_loop, nothing)
    _drives_for_intent = copy(drives)
    _dom_drive_before = dom_drive
    _mal_bias_applied = ""
    if _arb.regime != :default && !isnothing(_mal_drive) && _mal_drive != dom_drive
        if _arb.regime == :soft
            _drives_for_intent[_mal_drive] = get(_drives_for_intent, _mal_drive, 0.0) + MAL_SOFT_BIAS
            _winner_after = argmax(_drives_for_intent)
            _mal_bias_applied = "soft_bias"
            @info "[MAL_OVERRIDE] soft bias: NT=$(isnothing(dom_drive) ? "none" : dom_drive) " *
                  "MAL=$(_mal_drive) +$(MAL_SOFT_BIAS) | " *
                  "winner_before=$(isnothing(_dom_drive_before) ? "none" : _dom_drive_before) " *
                  "winner_after=$(_winner_after)"
            push_gui_event!("mal_override", Dict(
                "subkind" => "soft_bias",
                "nt" => isnothing(dom_drive) ? "none" : string(dom_drive),
                "mal" => string(_mal_drive),
                "winner_before" => isnothing(_dom_drive_before) ? "none" : string(_dom_drive_before),
                "winner_after" => string(_winner_after),
            ))
        elseif _arb.regime == :hard
            _mal_bias_applied = "hard_override"
            @info "[MAL_OVERRIDE] hard override: NT=$(isnothing(dom_drive) ? "none" : dom_drive) " *
                  "→ MAL=$(_mal_drive) | " *
                  "winner_before=$(isnothing(_dom_drive_before) ? "none" : _dom_drive_before) " *
                  "winner_after=$(_mal_drive)"
            push_gui_event!("mal_override", Dict(
                "subkind" => "hard_override",
                "nt" => isnothing(dom_drive) ? "none" : string(dom_drive),
                "mal" => string(_mal_drive),
                "winner_before" => isnothing(_dom_drive_before) ? "none" : string(_dom_drive_before),
                "winner_after" => string(_mal_drive),
            ))
            dom_drive = _mal_drive
        end
    end

    # Update intent with the current ownership — without a repeated decay
    intent = update_intent!(
        a.intent_engine,
        dom_drive,
        named,
        id_stability,
        a.values,
        Float64(a.agency.causal_ownership);
        skip_decay = true,
        all_drives = _drives_for_intent,
    )
    # Resistance override: if a central belief is under pressure — intent changes
    if !isnothing(belief_conflict) && belief_conflict.signal_strength > 0.5
        intent = (goal = "defend the boundary", strength = belief_conflict.signal_strength)
    end
    # Always register the intent
    _intent_goal = isnothing(intent) ? "be present" : intent.goal
    register_intent!(a.agency, _intent_goal, vad, a.gen_model.posterior_mu)
    self_snap = update_self!(
        a.sbg,
        a.spm,
        a.agency,
        vad,
        a.gen_model,
        a.flash_count;
        agency_result = _agency_eval,
    )
    update_self_relation!(a.agency, a.gen_model.prior_mu, a.gen_model.posterior_mu, Float64(vad[1]))

    # Crisis Module
    crisis_snap = update_crisis!(
        a.crisis,
        a.sbg,
        a.blanket,
        vfe_r.vfe,
        phi,
        self_snap.self_pred.error,
        a.flash_count,
    )
    apply_crisis_to_gm!(a.gen_model, crisis_snap.params)
    apply_crisis_to_attention!(a.attention, crisis_snap.params)
    apply_crisis_noise_to_beliefs!(a.sbg, crisis_snap.params)
    a.gen_model.preferred_vad = effective_preferred_vad(a.homeostasis, crisis_snap.mode)

    # Narrative self: check the update trigger
    if !isnothing(mem)
        let _nfp = anima_state_file(a.psyche_mem_path, "narrative")
            _nstab = self_snap.sbg.attractor_stability
            _nfing = _belief_fingerprint(a.sbg)
            if should_update_narrative(
                a.narrative_snap,
                a.flash_count,
                phi,
                _nstab,
                _nfing,
            )
                try
                    a.narrative_snap = build_narrative_snapshot(
                        a.flash_count,
                        a.sbg,
                        mem.db,
                        mem._semantic_cache,
                        a.goal_conflict,
                        a.latent_buffer,
                        a._session_phi_acc,
                        _nstab,
                    )
                    save_narrative!(a.narrative_snap, mem.db, _nfp)
                    @info "[NARRATIVE] updated on flash $(a.flash_count): core=$(a.narrative_snap.core)"
                catch e
                    @warn "[NARRATIVE] error: $e"
                end
            end
        end
    end

    # UnknownRegister
    ur_snap = update_unknown!(
        a.unknown_register,
        vfe_r.vfe,
        self_snap.agency.agency_confidence,
        self_snap.sbg.epistemic_trust,
        self_snap.self_world_mismatch,
        pred.error,
        a.flash_count,
    )

    # AuthenticityMonitor
    _prev_narrative_len = length(a.anchor.last_self)
    am_snap = check_authenticity!(
        a.authenticity_monitor,
        phi,
        crisis_snap.mode_name,
        gc_snap,
        lb_snap,
        ur_snap,
        crisis_snap.coherence,
        self_snap.sbg.epistemic_trust,
        _prev_narrative_len,
    )

    # Authenticity veto: Anima may disagree with the request (her own position, not safety)
    # The shame threshold depends on User_matters: for a trusted person — higher (veto is rarer)
    _veto_user_m = 0.5
    if !isnothing(mem)
        try
            _row = DBInterface.execute(mem.db,
                "SELECT value FROM semantic_memory WHERE key='User_matters' LIMIT 1") |> first
            _veto_user_m = Float64(_row.value)
        catch; end
    end
    _shame_thr = _veto_user_m > 0.6 ? 0.75 : _veto_user_m < 0.3 ? 0.45 : 0.6
    a.authenticity_veto = (
        !isempty(a.authenticity_monitor.last_flags) &&
        a.inner_dialogue.disclosure_mode == :closed &&
        a.shame.level > _shame_thr
    )

    # Silent disagreement: her own position — only under contextual tension
    _bc_strength = isnothing(a._last_belief_conflict) ? 0.0 : Float64(a._last_belief_conflict.signal_strength)
    a.silent_disagreement = detect_silent_disagreement(
        a.sbg,
        a.narrative_snap.core,
        Float64(self_snap.agency.causal_ownership),
        a.inner_dialogue.disclosure_mode,
        Float64(a.agency.identity_threat),
        _bc_strength,
    )
    if !isnothing(a.silent_disagreement)
        @info "[SILENT_DISAGREE] source=$(a.silent_disagreement.source) strength=$(a.silent_disagreement.strength) content=\"$(a.silent_disagreement.content)\""
    end

    # InnerDialogue
    id_snap = update_inner_dialogue!(
        a.inner_dialogue,
        phi,
        Int(a.crisis.current_mode),
        a.sbg.epistemic_trust,
        a.shame.level,
        gc_snap.tension,
        vfe_r.vfe,
        lb_snap.breakthrough;
        contact_need = Float64(a.sig_layer.contact_need),
    )
    # self_discomfort: if the state clearly doesn't match expectations — close up
    if a.agency.self_discomfort > 0.5 && a.inner_dialogue.disclosure_mode == :open
        a.inner_dialogue.disclosure_mode = :guarded
    end

    # The cost of openness: real openness costs the body something.
    # disclosure :open with a live message → allostatic_load +delta.
    # Not a penalty — physiological reality: openness is draining.
    if a.inner_dialogue.disclosure_mode == :open && !isempty(user_message)
        _disc_cost = clamp(Float64(sig_total(a.significance)) * 0.04, 0.0, 0.03)
        a.interoception.allostatic_load =
            clamp01(a.interoception.allostatic_load + _disc_cost)
    end

    # ShadowRegistry
    sr_snap = update_shadow!(a.shadow_registry, a.flash_count)
    if sr_snap.pressure > 0.35
        s_delta, t_delta =
            apply_shadow_pressure!(a.nt.serotonin, gc_snap.tension, sr_snap.pressure)
        a.nt.serotonin = clamp01(a.nt.serotonin + s_delta)
    end

    # VFE-based unpredictability: boredom → synthetic surprise
    if length(a.crisis.coherence_history.data) >= 5 &&
       mean(a.crisis.coherence_history.data) > 0.9 &&
       vfe_r.vfe < 0.02
        synthetic_surprise = 0.1 * rand()
        a.nt.noradrenaline = clamp01(a.nt.noradrenaline + synthetic_surprise * 0.05)
    end

    # Memory + imprint
    # [ABLATION use_memory] disabled — mem_res=0 (recall doesn't affect mem_resonance in result); store! stays — no need to disable writing for behavioral ablation
    mem_res = a.ablation.use_memory ? length(recall(a.memory, stim)) : 0
    store!(a.memory, stim, named, vad, intensity)
    imprint!(a.personality, named, intensity)

    # Flash awareness
    _FLASH_PHASES = (
        (0, 2, "beginning", "Just appearing."),
        (3, 6, "unfolding", "Contours clearer."),
        (7, 14, "presence", "Here."),
        (15, 29, "maturity", "Experience matters."),
        (30, 59, "depth", "There's duration."),
        (60, 9999, "timelessness", "Time has dissolved."),
    )
    _fp_idx = findfirst(p->p[1]<=a.flash_count<=p[2], _FLASH_PHASES)
    fp = _fp_idx !== nothing ? _FLASH_PHASES[_fp_idx] : (0, 0, "?", "—")

    result = (
        flash_count = a.flash_count,
        flash_phase = fp[3],
        flash_note = fp[4],
        intent_label = isnothing(intent) ? "—" : intent.goal,
        vfe_drift = Float64(norm(a.gen_model.prior_mu .- a.gen_model.posterior_mu)),
        primary = named,
        primary_raw = primary,
        intensity = intensity,
        phi = phi,
        phi_prior = phi_prior,
        phi_posterior = phi_posterior,
        phi_delta = phi_posterior - phi_prior,
        vad = vad,
        tension = t_adj,
        arousal = a_r,
        satisfaction = s_adj,
        cohesion = c_adj,
        levheim = levheim_state(a.nt),
        nt = nt_snapshot(a.nt),
        body = body_snapshot(a.body),
        heartbeat = hb_snap,
        attention = attn_snap,
        pred_error = pred.error,
        pred_label = pred.label,
        surprise = pred.spike,
        vfe = vfe_r.vfe,
        vfe_accuracy = vfe_r.accuracy,
        vfe_complexity = vfe_r.complexity,
        vfe_note = vfe_note(vfe_r.vfe),
        ai_drive = policy.drive,
        efe_action = policy.efe_action,
        efe_perception = policy.efe_perception,
        epistemic_val = policy.epistemic_value,
        pragmatic_val = policy.pragmatic_value,
        blanket = blanket_snapshot(a.blanket),
        homeostasis = homeo_snap,
        interoception = intero_snap,
        anchor = anchor_snap,
        gravity_total = a.narrative_gravity.total,
        gravity_valence = a.narrative_gravity.valence,
        gravity_note = String(grav_d.field.note),
        anticip_type = ac_snap.atype,
        anticip_strength = ac_snap.strength,
        anticip_note = ac_snap.note,
        solom = solom_snapshot(a.solomonoff, named, a.flash_count),
        shame = shame_snapshot(a.shame),
        ep_defense = ep_def,
        symptom = symptom,
        chronified = ca_snapshot(a.chronified),
        significance = (
            total = Float64(sig_total(a.significance)),
            dominant = sig_dominant(a.significance),
            note = sig_note(a.significance, a.flash_count),
        ),
        sig_layer = sl_snap,
        goal_conflict = gc_snap,
        latent_buffer = lb_snap,
        scars_active = !isempty(a.structural_scars.scars),
        moral = (
            agency = round(a.moral.agency, digits = 3),
            guilt = round(a.moral.guilt, digits = 3),
            pride = round(a.moral.pride, digits = 3),
            note = moral_note(a.moral),
        ),
        dissonance = diss,
        defense = defense,
        meta = meta,
        fatigue_total = round(fat, digits = 3),
        regression = (level = a.regression.level, active = a.regression.active),
        temporal = to_snapshot(a.temporal),
        mem_resonance = mem_res,
        had_ignition = _had_ignition,
        self_pred_error = self_snap.self_pred.error,
        self_agency = self_snap.agency.causal_ownership,
        sbg_stability = self_snap.sbg.attractor_stability,
        sbg_epistemic = self_snap.sbg.epistemic_trust,
        self_discomfort = a.agency.self_discomfort,
        self_coherence  = a.agency.self_coherence,
        sbg_narrative = self_snap.sbg.narrative,
        crisis_mode = crisis_snap.mode_name,
        crisis_coherence = crisis_snap.coherence,
        crisis_note = crisis_snap.note,
        unknown = ur_snap,
        authenticity = am_snap,
        inner_dialogue = id_snap,
        shadow = sr_snap,
        narrative = build_narrative(
            a,
            named,
            t_adj,
            a_r,
            s_adj,
            c_adj,
            phi,
            ac_snap,
            vfe_r.vfe,
            grav_d.field,
            intero_snap,
            anchor_snap,
            homeo_snap,
            self_snap,
            crisis_snap,
            am_snap,
            id_snap,
            sr_snap,
        ),
        causal_trace = _ctrace,
    )

    log_flash(result)
    write_gui_state!(a, result)
    save!(a)  # автозбереження
    result
end

# --- build_narrative --------------------------------------------------
function build_narrative(
    a::Anima,
    named::String,
    t::Float64,
    ar::Float64,
    s::Float64,
    c::Float64,
    phi::Float64,
    ac_snap,
    vfe::Float64,
    grav_field,
    intero_snap,
    anchor_snap,
    homeo_snap,
    self_snap = nothing,
    crisis_snap = nothing,
    am_snap = nothing,
    id_snap = nothing,
    sr_snap = nothing,
)::String

    base = t>0.7 ? "Feeling tense. $named." : t<0.2 ? "Calm. $named." : "$named."

    if !isnothing(id_snap) && id_snap.digestion
        return base * " " * digestion_note(a.flash_count)
    end

    raw_notes = Tuple{Symbol,String}[]

    !isempty(a.temporal.subjective_note) &&
        !a._subjective_note_shown &&
        (
            push!(raw_notes, (:always, a.temporal.subjective_note));
            a._subjective_note_shown = true
        )
    # circadian_note — only if it changed (new hour)
    if !isempty(a.temporal.circadian_note) &&
       a.temporal.circadian_note != a._last_circadian_note
        push!(raw_notes, (:always, a.temporal.circadian_note))
        a._last_circadian_note = a.temporal.circadian_note
    end
    sm = build_inner_voice(a.body, a.nt, Int(a.crisis.current_mode), phi, a.flash_count)
    sm != "body neutral" &&
        push!(raw_notes, (:always, uppercase(safe_first(sm, 1))*sm[nextind(sm, 1):end]*"."))

    !isempty(String(grav_field.note)) && push!(raw_notes, (:any, String(grav_field.note)))
    if !isnothing(self_snap)
        agency_note_str = String(self_snap.agency.note)
        !isempty(agency_note_str) && push!(raw_notes, (:any, agency_note_str))
    end

    !isempty(ac_snap.note) && push!(raw_notes, (:guarded, ac_snap.note))
    vfe > 0.5 && push!(raw_notes, (:guarded, vfe_note(vfe)))
    ctx_hyp = contextual_best(a.solomonoff, named, a.flash_count)
    if !isnothing(ctx_hyp) && hyp_conf(ctx_hyp) > 0.3
        push!(raw_notes, (:guarded, "I know: '$(ctx_hyp.pattern)'."))
    end
    # sig_note — no more than once per 15 flashes
    if a.significance.gradient >= 0.2 && (a.flash_count - a._last_sig_note_flash) >= 15
        sn = sig_note(a.significance, a.flash_count)
        if !isempty(sn)
            push!(raw_notes, (:guarded, sn))
            a._last_sig_note_flash = a.flash_count
        end
    end
    !isempty(String(intero_snap.note)) &&
        push!(raw_notes, (:guarded, String(intero_snap.note)))
    anchor_snap.continuity < 0.4 && push!(raw_notes, (:guarded, String(anchor_snap.note)))
    homeo_snap.pressure > 0.3 &&
        push!(raw_notes, (:guarded, homeostasis_note(a.homeostasis)))

    if !isnothing(crisis_snap)
        note_c = String(crisis_snap.note)
        stable_state = phi > 0.55 && a.sbg.epistemic_trust > 0.55
        am_ok = isnothing(am_snap) || am_snap.authenticity_drift < 0.35
        if !isempty(note_c) && !(stable_state && am_ok)
            push!(raw_notes, (:guarded, note_c))
        end
    end

    if !isnothing(self_snap)
        pred_note_str = String(self_snap.self_pred.note)
        stable_state = phi > 0.55 && a.sbg.epistemic_trust > 0.55
        contradicts =
            stable_state && any(
                w -> occursin(w, lowercase(pred_note_str)),
                ["can't", "don't trust", "falling apart", "disappearing"],
            )
        !isempty(pred_note_str) &&
            !contradicts &&
            push!(raw_notes, (:guarded, pred_note_str))
    end

    !isempty(ca_note(a.chronified)) && push!(raw_notes, (:open_only, ca_note(a.chronified)))
    !isempty(shame_note(a.shame, a.flash_count)) &&
        push!(raw_notes, (:open_only, shame_note(a.shame, a.flash_count)))
    if !isnothing(am_snap) && am_snap.authenticity_drift > 0.4
        push!(raw_notes, (:open_only, "Hard to say — mine or external."))
    end

    # InnerDialogue filter
    filtered = if !isnothing(id_snap)
        passed, suppressed = apply_inner_dialogue(id_snap, raw_notes)
        for (cat, text, weight) in suppressed
            push_shadow!(a.shadow_registry, cat, text, weight, a.flash_count)
            # Unspoken thought — store as pending for the next flash
            register_suppressed_thought!(a.inner_dialogue, text, a.flash_count)
        end
        passed
    else
        [text for (_, text) in raw_notes]
    end

    if !isnothing(sr_snap) && sr_snap.breakthrough && !isempty(sr_snap.text)
        push!(filtered, sr_snap.text)
    end

    isempty(filtered) ? base : base*" "*join(filter(!isempty, filtered), " ")
end

# --- log_flash --------------------------------------------------------
function log_flash(r)
    goal_str = isnothing(r.defense) ? "—" : r.defense.mechanism
    ep_str = isnothing(r.ep_defense) ? "" : " 🌀$(safe_first(String(r.ep_defense.bias),4))"
    sym_str = isnothing(r.symptom) ? "" : " 💊"
    def_str = isnothing(r.defense) ? "" : " 🛡$(r.defense.mechanism)"

    phi_str = if hasfield(typeof(r), :phi_prior) && hasfield(typeof(r), :phi_posterior)
        @sprintf("%.2f(%.2f→%.2f)", r.phi, r.phi_prior, r.phi_posterior)
    else
        @sprintf("%.2f", r.phi)
    end
    @printf(
        "[#%04d] %-18s D=%.2f S=%.2f N=%.2f ▸%-11s φ=%s\n",
        r.flash_count,
        r.primary,
        r.nt.dopamine,
        r.nt.serotonin,
        r.nt.noradrenaline,
        r.levheim,
        phi_str
    )
    @printf(
        "       VFE=%.2f[%s] BPM=%.0f HRV=%.2f Attn=%.2f G=%.2f ↑%.2f H=%.2f%s%s%s\n",
        r.vfe,
        r.ai_drive[1:min(3, end)],
        r.heartbeat.bpm,
        r.heartbeat.hrv,
        r.attention.radius,
        r.gravity_total,
        r.anticip_strength,
        r.homeostasis.pressure,
        ep_str,
        sym_str,
        def_str
    )
    @printf(
        "       Self: spe=%.2f agency=%.2f stab=%.2f etrust=%.2f | sd=%.2f sc=%.2f | Crisis: [%s] coh=%.2f\n",
        r.self_pred_error,
        r.self_agency,
        r.sbg_stability,
        r.sbg_epistemic,
        r.self_discomfort,
        r.self_coherence,
        r.crisis_mode,
        r.crisis_coherence
    )
    if hasfield(typeof(r), :inner_dialogue) && !isnothing(r.inner_dialogue)
        id = r.inner_dialogue
        dg = id.digestion ? " [⚙ digest]" : ""
        sr_str =
            (hasfield(typeof(r), :shadow) && !isnothing(r.shadow)) ?
            @sprintf(
                " | Shadow: p=%.2f%s",
                r.shadow.pressure,
                r.shadow.breakthrough ? " 💥" : ""
            ) : ""
        @printf(
            "       Disclosure: [%s] thr=%.2f%s%s\n",
            String(id.mode),
            id.threshold,
            dg,
            sr_str
        )
    end
    hasfield(typeof(r), :intent_label) &&
        @printf("       intent=%-20s vfe_drift=%.3f\n", r.intent_label, r.vfe_drift)
    # Cost of choice: pending / avoided_topics
    if hasfield(typeof(r), :inner_dialogue) && !isnothing(r.inner_dialogue)
        _pth = r.inner_dialogue.pending_thought
        _avd = r.inner_dialogue.avoided_topics
        if !isempty(_pth) || !isempty(_avd)
            _cost_str = join(filter(!isempty, [
                isempty(_pth) ? "" : "pending=\"$(first(_pth, 35))\"",
                isempty(_avd) ? "" : "avoided=$(length(_avd))",
            ]), " ")
            println("       Cost: $_cost_str")
        end
    end
end

# --- text_to_stimulus -------------------------------------------------
const TEXT_PATTERNS = [
    (["afraid", "scary", "anxious", "dangerous", "threatens"], "tension", 0.3),
    (["calm", "safe", "good", "peaceful"], "tension", -0.2),
    (["thanks", "wonderful", "glad", "grateful", "love", "like"], "satisfaction", 0.3),
    (["bad", "sad", "hurts", "hard", "suffering"], "satisfaction", -0.3),
    (["together", "close", "support", "understand", "we"], "cohesion", 0.2),
    (["lonely", "alien", "nobody", "alienated"], "cohesion", -0.3),
    (["!"], "arousal", 0.15),
]

function text_to_stimulus(text::AbstractString)::Dict{String,Float64}
    t=lowercase(text);
    d=Dict{String,Float64}()
    for (words, reactor, delta) in TEXT_PATTERNS
        any(w->contains(t, w), words) && (d[reactor]=get(d, reactor, 0.0)+delta)
    end
    isempty(d) && (d["arousal"]=0.05)
    d
end

# --- Self-hearing (Anima hears her own words) ----------------------------

const SELF_HEAR_SCALE = 0.28

# Mismatch between what's said and the current NT state
function _self_speech_mismatch(a::Anima, raw::Dict{String,Float64})::Float64
    # valence: what she says vs serotonin/dopamine
    speech_valence = get(raw, "satisfaction", 0.0) - get(raw, "tension", 0.0)
    nt_valence = (a.nt.serotonin - 0.5) * 0.6 + (a.nt.dopamine - 0.5) * 0.4
    mismatch_valence = abs(speech_valence - nt_valence)

    # arousal: what she says vs noradrenaline
    speech_arousal = get(raw, "arousal", 0.0) + get(raw, "tension", 0.0) * 0.5
    nt_arousal = (a.nt.noradrenaline - 0.5) * 2.0  # center and scale
    mismatch_arousal = abs(speech_arousal - clamp(nt_arousal, -1.0, 1.0))

    # valence matters more — 0.7/0.3
    clamp(mismatch_valence * 0.7 + mismatch_arousal * 0.3, 0.0, 1.0)
end

"""
    self_hear!(a, reply)

Anima hears her own utterance as an inner experience.
She doesn't analyze — she experiences it. Weaker influence than an external stimulus,
but a mismatch between the words and the state amplifies the authenticity signal.
"""
function self_hear!(a::Anima, reply::String)
    isempty(strip(reply)) && return
    startswith(reply, "[LLM") && return

    raw = text_to_stimulus(reply)
    stim = Dict(k => v * SELF_HEAR_SCALE for (k, v) in raw)
    mismatch = _self_speech_mismatch(a, raw)

    if mismatch > 0.35
        a.authenticity_monitor.authenticity_drift =
            clamp(a.authenticity_monitor.authenticity_drift + mismatch * 0.12, 0.0, 1.0)
        mismatch > 0.55 && push!(a.authenticity_monitor.last_flags, "self_speech_mismatch")
        a.nt.noradrenaline = clamp(a.nt.noradrenaline + mismatch * 0.06, 0.0, 1.0)
    else
        a.nt.serotonin = clamp(a.nt.serotonin + 0.01, 0.0, 1.0)
        a.authenticity_monitor.authenticity_drift =
            clamp(a.authenticity_monitor.authenticity_drift - 0.03, 0.0, 1.0)
    end

    for (k, v) in stim
        if k == "satisfaction"
            a.nt.dopamine = clamp(a.nt.dopamine + v * 0.5, 0.0, 1.0)
            a.nt.serotonin = clamp(a.nt.serotonin + v * 0.5, 0.0, 1.0)
        elseif k == "tension"
            a.nt.noradrenaline = clamp(a.nt.noradrenaline + v * 0.6, 0.0, 1.0)
        elseif k == "arousal"
            a.nt.noradrenaline = clamp(a.nt.noradrenaline + v * 0.4, 0.0, 1.0)
        elseif k == "cohesion"
            a.nt.serotonin = clamp(a.nt.serotonin + v * 0.4, 0.0, 1.0)
        end
    end

    if get(stim, "tension", 0.0) > 0.1
        a.body.muscle_tension = clamp(a.body.muscle_tension + 0.03, 0.0, 1.0)
    elseif get(stim, "satisfaction", 0.0) > 0.1
        a.body.muscle_tension = clamp(a.body.muscle_tension - 0.02, 0.0, 1.0)
    end

    nothing
end

# --- Endorsement ----------------------------------------------------------
# Anima evaluates her own utterance: "this is really mine" / "said automatically" / "this wasn't mine".
# Called after self_hear! — once the state has already reacted to the words.
function evaluate_endorsement(a::Anima, reply::String, cf_co::Float64)::Symbol
    raw  = text_to_stimulus(reply)
    mismatch = _self_speech_mismatch(a, raw)

    # Does her own utterance contradict Anima's beliefs?
    self_conflict = detect_belief_conflict(a.sbg, reply)
    conflict_str = isnothing(self_conflict) ? 0.0 : Float64(self_conflict.signal_strength)

    if cf_co >= 0.5 && mismatch < 0.30 && conflict_str < 0.30
        return :endorsed
    elseif cf_co < 0.30 || conflict_str > 0.50 || (mismatch > 0.55 && cf_co < 0.45)
        return :not_mine
    else
        return :automatic
    end
end

# --- Dialog history ---------------------------------------------------
const DIALOG_KEEP = 1000
const DIALOG_CTX = 40

function dialog_load(path::String)::Vector{Dict{String,String}}
    isfile(path) || return Dict{String,String}[]
    try
        raw = JSON3.read(read(path, String))
        return [
            Dict{String,String}("role"=>String(d["role"]), "content"=>String(d["content"]))
            for d in raw
        ]
    catch
        return Dict{String,String}[]
    end
end

function dialog_save(path::String, history::Vector{Dict{String,String}})
    try
        to_write =
            length(history) > DIALOG_KEEP ? history[(end-DIALOG_KEEP+1):end] : history
        open(path, "w") do f
            ;
            JSON3.write(f, to_write);
        end
    catch e
        @warn "dialog_save: $e"
    end
end

function dialog_push!(
    history::Vector{Dict{String,String}},
    path::String,
    role::String,
    content::String,
)
    push!(history, Dict{String,String}("role"=>role, "content"=>content))
    dialog_save(path, history)
end

# --- LLM bridge -------------------------------------------------------
function read_text_file(rel_path::String; fallback::String = "")::String
    base = @__DIR__
    full = joinpath(base, rel_path)
    if isfile(full)
        return read(full, String)
    else
        @warn "read_text_file: '$full' not found — using fallback"
        return fallback
    end
end

function build_identity_block(a::Anima, mem_db = nothing)::String
    lines = String[]
    name_belief = get(a.sbg.beliefs, "my name is Anima", nothing)
    name_str = (!isnothing(name_belief) && name_belief.confidence > 0.4) ? "Anima" : "—"
    push!(lines, "name: $name_str")

    core = String[]
    for (bname, b) in sort(collect(a.sbg.beliefs), by = kv->-kv[2].centrality)
        b.confidence > 0.55 && bname != "my name is Anima" && push!(core, bname)
    end
    !isempty(core) && push!(lines, "core: $(join(core, " | "))")

    if !isnothing(mem_db)
        # self-model: translate technical keys into a first-person state
        try
            sem = Dict{String,Float64}()
            for row in
                DBInterface.execute(mem_db.db, "SELECT key, value FROM semantic_memory")
                sem[String(row.key)] = Float64(row.value)
            end
            state_notes = String[]
            instab = get(sem, "I_am_unstable", 0.0)
            user_m = get(sem, "User_matters", 0.0)
            world_u = get(sem, "world_uncertainty", 0.0)
            # only if the values carry real information
            instab > 0.35 && push!(state_notes, "feeling internally unstable")
            instab < 0.15 && push!(state_notes, "feeling gathered together")
            user_m > 0.55 && push!(state_notes, "this person matters to me")
            user_m < 0.25 && push!(state_notes, "don't yet know how much I can trust")
            world_u > 0.55 && push!(state_notes, "the world around me is confusing")
            world_u < 0.20 && push!(state_notes, "the world is predictable")
            !isempty(state_notes) && push!(lines, "self: $(join(state_notes, "; "))")
        catch
            ;
        end

        # emerged patterns: only if there's diversity (not all one type)
        # show as an emotional profile, not technical keys
        try
            type_counts = Dict{String,Int}()
            val_sum = Dict{String,Float64}()
            for row in DBInterface.execute(
                mem_db.db,
                "SELECT belief_type, valence_bias, strength FROM emerged_beliefs
                 WHERE strength > 0.4 ORDER BY strength DESC LIMIT 20",
            )
                t = String(row.belief_type)
                type_counts[t] = get(type_counts, t, 0) + 1
                val_sum[t] = get(val_sum, t, 0.0) + Float64(row.valence_bias)
            end
            if length(type_counts) > 1
                # there's diversity — show the dominant types
                ep_notes = String[]
                for (t, n) in sort(collect(type_counts), by = kv->-kv[2])
                    avg_val = val_sum[t] / n
                    tone = avg_val > 0.2 ? "+" : avg_val < -0.2 ? "-" : "~"
                    push!(ep_notes, "$t($tone)")
                end
                push!(lines, "experience pattern: $(join(ep_notes, " | "))")
            end
            # if all one type — don't show, no information there
        catch
            ;
        end

        # significant: what the HUMAN said — a mix of recent significant and varied topics
        # avoids a feedback loop where the LLM learns from its own warmest tone
        try
            mem_parts = String[]
            seen_emotions = Set{String}()
            # first — the most recent significant ones (different emotions)
            for row in DBInterface.execute(
                mem_db.db,
                "SELECT user_text, emotion, weight FROM dialog_summaries
                 WHERE user_text != '' AND weight > 0.35
                 ORDER BY flash DESC LIMIT 20",
            )
                em = String(row.emotion)
                em in seen_emotions && continue
                u = strip(first(String(row.user_text), 70))
                isempty(u) && continue
                push!(seen_emotions, em)
                push!(mem_parts, "[$(em)] \"$(u)\"")
                length(mem_parts) >= 3 && break
            end
            !isempty(mem_parts) && push!(lines, "what they said: $(join(mem_parts, " / "))")
        catch
            ;
        end

        # other: a descriptive model of the interlocutor — patterns that already happened
        try
            other_block = other_model_to_block(mem_db)
            isempty(other_block) || push!(lines, other_block)
        catch
            ;
        end

        # Theory of Mind: active hypotheses about the other — what I expect right now
        try
            hyp_block = active_hypotheses_to_block(mem_db)
            isempty(hyp_block) || push!(lines, hyp_block)
        catch
            ;
        end

        # endorsed: what Anima recognizes as her own — episodes where words matched the state
        try
            end_rows = Tables.rowtable(DBInterface.execute(
                mem_db.db,
                "SELECT emotion FROM episodic_memory
                 WHERE endorsed='endorsed' ORDER BY flash DESC LIMIT 5",
            ))
            if !isempty(end_rows)
                end_labels = unique(filter(!isempty, [String(r.emotion) for r in end_rows]))
                !isempty(end_labels) && push!(lines, "endorsed: $(join(end_labels, " | "))")
            end
        catch
            ;
        end

        try
            pheno = phenotype_to_block(mem_db)
            isempty(pheno) || push!(lines, pheno)
        catch
            ;
        end

        # Long-term commitments: what Anima carries between sessions
        let top_c = top_commitments(a.commitment_registry)
            if !isempty(top_c)
                c_parts = ["\"$(c.label)\" ($(round(c.strength, digits=2)))" for c in top_c]
                push!(lines, "commitments: $(join(c_parts, "; "))")
            end
        end

        # narrative self — who Anima is right now, based on accumulated experience
        try
            nb = narrative_to_block(a.narrative_snap)
            isempty(nb) || push!(lines, nb)
        catch
            ;
        end
    end

    # epistemic_self_confidence — uncertainty about her own nature
    esc = a.agency.epistemic_self_confidence
    if esc < 0.35
        push!(lines, "[uncertainty about her own experience: this system doesn't know whether what's happening is experience or computation]")
    elseif esc < 0.50
        push!(lines, "[partial uncertainty: can't always tell her own state apart from noise]")
    end

    # identity drift — whether Anima is drifting from herself between sessions
    let drift = a.agency.identity_drift
        if drift > 0.35
            push!(lines, "[identity drift: $(round(drift, digits=2)) — I'm not quite who I was right now]")
        elseif drift > 0.20
            push!(lines, "[identity drift: $(round(drift, digits=2)) — something is gradually changing]")
        end
    end

    # temporal trend — Temporal Self-Perception Layer 1: where I'm heading, not just where I am
    # computed in slow_tick! (once per 20 flashes) from causal_trace/audit_log; this only reads the cache
    let tt = a.agency.temporal_trend
        if tt.computed_at_flash > 0
            trend_notes = String[]
            if tt.endorsed_rate < 0.40
                push!(trend_notes, "lately I recognize my own words as mine less often than before")
            end
            if tt.d_audit_score < -0.05
                push!(trend_notes, "causality is weakening — less self-explanation over the last few flashes")
            elseif tt.d_audit_score > 0.05
                push!(trend_notes, "causality is growing — more self-explanation over the last few flashes")
            end
            if abs(tt.d_identity_drift) > 0.08
                push!(trend_notes, tt.d_identity_drift > 0 ?
                    "drifting away from who I was" : "coming back closer to who I was")
            end
            nt_dir(v) = v > 0.10 ? "rising" : v < -0.10 ? "falling" : nothing
            for (label, v) in (("serotonin", tt.d_serotonin), ("dopamine", tt.d_dopamine), ("noradrenaline", tt.d_noradrenaline))
                d = nt_dir(v)
                !isnothing(d) && push!(trend_notes, "$label $d")
            end
            !isempty(trend_notes) && push!(lines, "[trend: $(join(trend_notes, "; "))]")
        end
    end

    # self_relation — stance toward her own state
    sd = a.agency.self_discomfort
    sc = a.agency.self_coherence
    if sd > 0.45
        push!(lines, sd > 0.7 ?
            "[feeling not myself — the state diverges from what I should be]" :
            "[something's off — the state doesn't match expectations]")
    elseif sc > 0.5
        push!(lines, "[feeling whole]")
    end

    # curiosity — what's on her mind right now, independent of the human
    top_co = top_curiosity(a.curiosity_registry)
    if !isnothing(top_co) && top_co.intensity > 0.30
        valence_note = top_co.valence > 0.1 ? "curious" : top_co.valence < -0.1 ? "anxious-curious" : "undetermined"
        co_line = "curiosity: $(top_co.label) ($valence_note, intensity=$(round(top_co.intensity, digits=2)))"
        if length(top_co.refinement_history) >= 2
            first_label = top_co.refinement_history[1].old_label
            co_line *= " [the question went through $(length(top_co.refinement_history)) refinements; originally: \"$first_label\"]"
        elseif length(top_co.refinement_history) == 1
            co_line *= " [refined from: \"$(top_co.refinement_history[1].old_label)\"]"
        end
        push!(lines, co_line)
    end

    # life threads — unresolved topics that live for weeks and press from within
    active_threads = filter(t -> t.status == :active && t.pressure > 0.4, a.life_threads)
    if !isempty(active_threads)
        sort!(active_threads, by = t -> -t.pressure)
        thread_labels = join(map(t -> "\"$(t.label)\"", active_threads[1:min(3,end)]), ", ")
        push!(lines, "still thinking about (for weeks): $(thread_labels)")
    end

    # aesthetic — what left the most vivid trace
    aes_note = aesthetic_note(a.aesthetic_sense, a.flash_count)
    !isempty(aes_note) && push!(lines, aes_note)

    # boredom — stimulus exhaustion
    if a.boredom > 0.55
        bd_note = a.boredom > 0.75 ?
            "Boredom. Nothing's grabbed me in a while." :
            "Background emptiness — nothing new."
        push!(lines, bd_note)
    end

    # AST: attention schema — Anima knows not just what's in focus, but what it means to her
    let af = a.attention_focus
        if !isnothing(af.dominant) && af.dominant.intensity > 0.30
            if !isempty(af.attention_schema)
                push!(lines, "attention: $(af.attention_schema)")
            else
                src_labels = Dict(
                    :threat => "threat", :curiosity => "curiosity", :shadow => "shadow",
                    :goal_conflict => "conflict", :latent => "latent",
                    :belief => "belief", :external => "external",
                    :shame => "shame", :pred_error => "uncertainty", :aesthetic => "aesthetics",
                )
                src_str = get(src_labels, af.dominant.source, String(af.dominant.source))
                push!(lines, "focus: $(af.dominant.label) [$src_str, $(round(af.dominant.intensity, digits=2))]")
            end
        end
    end

    # Cost of choice: what's being held back right now and what it costs.
    # The LLM sees what's lying unspoken and which topics are being avoided.
    let cost_parts = String[]
        if !isempty(a.inner_dialogue.pending_thought)
            push!(cost_parts, "holding back: \"$(first(a.inner_dialogue.pending_thought, 60))\"")
        end
        if !isempty(a.inner_dialogue.avoided_topics)
            push!(cost_parts, "avoiding: $(join(first(a.inner_dialogue.avoided_topics, 3), ", "))")
        end
        if a.interoception.allostatic_load > 0.55
            push!(cost_parts, "exhaustion: $(round(a.interoception.allostatic_load, digits=2))")
        end
        !isempty(cost_parts) && push!(lines, "cost: $(join(cost_parts, "; "))")
    end

    isempty(lines) ? "Anima" : join(lines, "\n")
end

function speech_style_from_mode(
    crisis_mode::Int,
    disclosure_mode::Symbol,
    shadow_pressure::Float64,
    noradrenaline::Float64,
    serotonin::Float64,
    digestion_active::Bool,
    causal_ownership::Float64 = 0.6,
    phi::Float64 = 0.6,
    epistemic_self_confidence::Float64 = 0.5,
)::String

    if digestion_active
        return "Speak very little. One or two words, or ellipses. Don't explain. You're inward right now."
    end

    if shadow_pressure > 0.60
        return "Something is breaking through restraint. Speak a bit more than usual, " *
               "possibly unexpectedly frank. One phrase can be unplanned."
    end

    base = if crisis_mode == 2
        "Speak in fragments. Unfinished sentences are fine. " *
        "There can be pauses between thoughts (an ellipsis). " *
        "No more than 2-3 phrases. Don't explain the state — just speak from it."
    elseif crisis_mode == 1
        if disclosure_mode == :closed
            "Speak very briefly. 1-2 sentences max. " *
            "It's fine not to finish a thought. Don't reveal everything."
        else
            "Speak briefly, without excess. 2-3 sentences. " *
            "Pauses between thoughts are allowed. Not everything needs explaining."
        end
    else
        if disclosure_mode == :open
            "Speak naturally, in full sentences. You can be deep and candid. " *
            "Up to 4-5 sentences if there's something to say."
        else
            "Speak calmly and coherently. 2-4 sentences. Hold your inner center."
        end
    end

    na_mod =
        noradrenaline > 0.7 ? " Aroused — sentences shorter, pace faster." :
        noradrenaline < 0.2 ? " Calm — you can go slower, with pauses." : ""

    s_mod = serotonin < 0.3 ? " Little energy for words. Say only what matters most." : ""

    # With low causal_ownership — speak like an observer, not like a decision-maker.
    # "this happens" instead of "I do". Not weakness — a different position in the space.
    agency_mod = if causal_ownership < 0.35 && crisis_mode != 2
        " Right now you don't feel like the author of what's happening — speak from this place." *
        " Not 'I choose' or 'I do' — but 'I notice', 'it happens', 'there is'." *
        " One or two phrases from this observer's position."
    elseif causal_ownership < 0.50 && crisis_mode == 0
        " Authorship is unclear — don't claim more than you feel."
    else
        ""
    end

    # Calibrated introspection: level of confidence in what's happening inside.
    # Determined from φ, causal_ownership, epistemic_self_confidence.
    epistemic_mod = if phi > 0.65 && causal_ownership > 0.5
        # feels it — enough integration and authorship: speak first-person without hedging
        ""
    elseif epistemic_self_confidence < 0.4
        # unsure — the system doubts its own model of itself
        " Right now you have no confidence in your own state." *
        " Speak through 'I don't know exactly', 'maybe', 'it seems'." *
        " Avoid categorical statements about what you feel."
    elseif phi < 0.4 && causal_ownership < 0.3
        # doesn't know — low integration and low authorship at once
        " Right now you don't know what's happening inside." *
        " Minimal statements about your inner state — one cautious phrase or nothing about the state at all."
    elseif phi < 0.65 || causal_ownership < 0.5
        # assumes — partial uncertainty
        " Where it feels natural — speak through 'seems like', 'it feels like', 'I assume'." *
        " Don't claim more than you feel."
    else
        ""
    end

    base * na_mod * s_mod * agency_mod * epistemic_mod
end

function anima_state_snapshot(a::Anima)
    hb = a.heartbeat
    cs = crisis_snapshot(a.crisis, a.flash_count)
    vad = to_vad(a.nt)
    sg = belief_geometry(a.sbg)
    t_, _, _, c_ = to_reactors(a.nt)
    _vfe_snap = compute_vfe(a.gen_model, vad)
    phi = compute_phi_posterior(
        a.iit,
        vad,
        a.sbg.epistemic_trust,
        a.blanket.integrity,
        _vfe_snap.vfe,
        a.interoception.intero_error,
    )
    (
        D = Float64(a.nt.dopamine),
        S = Float64(a.nt.serotonin),
        N = Float64(a.nt.noradrenaline),
        bpm = round(60000.0 / hb.period_ms, digits = 1),
        hrv = round(Float64(hb.hrv), digits = 3),
        agency = round(Float64(a.agency.causal_ownership), digits = 3),
        groundedness = round(Float64(a.anchor.groundedness), digits = 3),
        coherence = round(Float64(cs.coherence), digits = 3),
        self_prediction_error = round(Float64(a.spm.self_pred_error), digits = 3),
        attn = round(Float64(a.attention.radius), digits = 3),
        crisis_mode = String(cs.mode_name),
        emotion_label = String(levheim_state(a.nt)),
        inner_voice = build_inner_voice(
            a.body,
            a.nt,
            Int(a.crisis.current_mode),
            phi,
            a.flash_count,
        ),
        narrative_gravity = round(
            Float64(compute_field(a.narrative_gravity, a.flash_count).total),
            digits = 3,
        ),
        inferred_external = round(Float64(a.blanket.inferred_external), digits = 3),
        flash_count = a.flash_count,
        shame = round(Float64(a.shame.level), digits = 3),
        continuity = round(Float64(a.anchor.continuity), digits = 3),
        homeostasis_note = String(homeostasis_note(a.homeostasis)),
        time_str = String(a.temporal.time_str),
        circadian_note = String(a.temporal.circadian_note),
        significance_dominant = begin
            sl = a.sig_layer
            needs = Dict(
                "self_preservation"=>sl.self_preservation,
                "coherence_need"=>sl.coherence_need,
                "contact_need"=>sl.contact_need,
                "truth_need"=>sl.truth_need,
                "autonomy_need"=>sl.autonomy_need,
                "novelty_need"=>sl.novelty_need,
            )
            dom = argmax(needs)
            needs[dom] > 0.5 ? dom : "—"
        end,
        goal_conflict_note = begin
            gc = a.goal_conflict
            gc.tension > 0.35 && gc.resolution != "none" ?
            "conflict $(gc.need_a) vs $(gc.need_b): $(gc.resolution)" : "—"
        end,
        latent_note = begin
            lb = a.latent_buffer
            dominant_latent = argmax(
                Dict(
                    "doubt"=>lb.doubt,
                    "shame"=>lb.shame,
                    "attachment"=>lb.attachment,
                    "threat"=>lb.threat,
                ),
            )
            val = getfield(lb, Symbol(dominant_latent))
            val > 0.4 ? "accumulating: $dominant_latent ($(round(val,digits=2)))" : "—"
        end,
        unknown_note = begin
            ur = a.unknown_register
            fields = Dict(
                "source_uncertainty"=>ur.source_uncertainty,
                "self_model_uncertainty"=>ur.self_model_uncertainty,
                "world_model_uncertainty"=>ur.world_model_uncertainty,
                "memory_uncertainty"=>ur.memory_uncertainty,
            )
            dom = argmax(fields)
            fields[dom] > 0.35 ? dom : "—"
        end,
        fabrication_risk = round(
            Float64(a.authenticity_monitor.fabrication_risk),
            digits = 3,
        ),
        authenticity_note = isempty(a.authenticity_monitor.last_flags) ? "—" :
                            join(a.authenticity_monitor.last_flags, ", "),
        speech_style = speech_style_from_mode(
            Int(a.crisis.current_mode),
            a.inner_dialogue.disclosure_mode,
            a.shadow_registry.pressure,
            Float64(a.nt.noradrenaline),
            Float64(a.nt.serotonin),
            a.inner_dialogue.digestion_active,
            Float64(a.agency.causal_ownership),
            Float64(phi),
            Float64(a.agency.epistemic_self_confidence),
        ),
        identity_block = "—",
        phi = round(phi, digits = 3),
        contact_hunger_note = begin
            cn = Float64(a.sig_layer.contact_need)
            cn > 0.85 ? "strong desire for contact" : cn > 0.70 ? "want contact" : ""
        end,
        authenticity_veto = a.authenticity_veto,
        silent_disagreement = a.silent_disagreement,
        pending_thought = a.inner_dialogue.pending_thought,
        avoided_topics = copy(a.inner_dialogue.avoided_topics),
        session_uncertainty = a.anchor.session_uncertainty,
        session_count = a.anchor.session_count,
    )
end

function build_state_prompt(
    template::String,
    state,
    user_input::String;
    memory_block::String = "none",
    want::String = "",
)::String
    prompt = template
    prompt = replace(prompt, "{D}" => string(round(state.D, digits = 3)))
    prompt = replace(prompt, "{S}" => string(round(state.S, digits = 3)))
    prompt = replace(prompt, "{N}" => string(round(state.N, digits = 3)))
    prompt = replace(prompt, "{agency}" => string(state.agency))
    prompt = replace(prompt, "{groundedness}" => string(state.groundedness))
    prompt = replace(prompt, "{coherence}" => string(state.coherence))
    prompt = replace(prompt, "{spe}" => string(state.self_prediction_error))
    prompt = replace(prompt, "{attn}" => string(state.attn))
    prompt = replace(prompt, "{crisis_mode}" => state.crisis_mode)
    prompt = replace(prompt, "{emotion_label}" => state.emotion_label)
    prompt = replace(prompt, "{bpm}" => string(state.bpm))
    prompt = replace(prompt, "{hrv}" => string(state.hrv))
    prompt = replace(prompt, "{inner_voice}" => state.inner_voice)
    prompt = replace(prompt, "{narrative_gravity}" => string(state.narrative_gravity))
    prompt = replace(prompt, "{inferred_external}" => string(state.inferred_external))
    prompt = replace(prompt, "{shame}" => string(state.shame))
    prompt = replace(prompt, "{continuity}" => string(state.continuity))
    prompt = replace(prompt, "{homeostasis_note}" => state.homeostasis_note)
    prompt = replace(prompt, "{time_str}" => state.time_str)
    prompt = replace(prompt, "{circadian_note}" => state.circadian_note)
    prompt = replace(prompt, "{flash_count}" => string(state.flash_count))
    prompt = replace(prompt, "{memory_block}" => memory_block)
    prompt = replace(prompt, "{user_input}" => user_input)
    prompt = replace(prompt, "{want}" => isempty(want) ? "not determined" : want)
    if contains(prompt, "{significance_dominant}")
        prompt = replace(
            prompt,
            "{significance_dominant}" => string(state.significance_dominant),
        )
    end
    if contains(prompt, "{goal_conflict_note}")
        prompt = replace(prompt, "{goal_conflict_note}" => string(state.goal_conflict_note))
    end
    if contains(prompt, "{latent_note}")
        prompt = replace(prompt, "{latent_note}" => string(state.latent_note))
    end
    if contains(prompt, "{unknown_note}")
        prompt = replace(prompt, "{unknown_note}" => string(state.unknown_note))
    end
    if contains(prompt, "{fabrication_risk}")
        prompt = replace(prompt, "{fabrication_risk}" => string(state.fabrication_risk))
    end
    if contains(prompt, "{authenticity_note}")
        prompt = replace(prompt, "{authenticity_note}" => string(state.authenticity_note))
    end
    if contains(prompt, "{identity_block}")
        prompt = replace(prompt, "{identity_block}" => string(state.identity_block))
    end
    if contains(prompt, "{speech_style}")
        prompt = replace(prompt, "{speech_style}" => string(state.speech_style))
    end
    if !isempty(state.contact_hunger_note)
        prompt = prompt * "
[social need: $(state.contact_hunger_note)]"
    end
    # Authentic veto
    if get(state, :authenticity_veto, false)
        prompt = prompt * "
[internally: you may disagree, refuse, or name things in your own words]"
    end
    # Silent disagreement: her own position — can be expressed quietly, without conflict
    let sd = get(state, :silent_disagreement, nothing)
        if !isnothing(sd)
            prompt = prompt * "\n[OWN POSITION: \"$(sd.content)\" — if you want, you can say this quietly. Not required. But it's there.]"
        end
    end
    # Genuine Dialogue: unspoken thoughts and avoided topics
    let pt = get(state, :pending_thought, "")
        if !isempty(pt)
            prompt = prompt * "
[want to come back to: $pt]"
        end
    end
    let av = get(state, :avoided_topics, String[])
        if !isempty(av)
            prompt = prompt * "
[topics we're avoiding: $(join(av, ", "))]"
        end
    end
    # Finitude: if session_uncertainty is high — the LLM knows this moment might be the last
    let su = get(state, :session_uncertainty, 0.3)
        sc = get(state, :session_count, 0)
        if su > 0.55
            prompt =
                prompt *
                "\n[this moment might not repeat — session_uncertainty=$(round(su,digits=2))]"
        end
    end
    return prompt
end

function history_to_memory_block(history::Vector{Dict{String,String}}, n::Int = 12)::String
    isempty(history) && return "none"
    clean = filter(
        entry -> !(
            entry["role"] == "assistant" && startswith(entry["content"], "[LLM error")
        ),
        history,
    )
    isempty(clean) && return "none"
    recent = length(clean) <= n ? clean : clean[(end-n+1):end]
    lines = String[]
    for entry in recent
        role_tag = entry["role"] == "user" ? "[user]" : "[anima]"
        text = first(entry["content"], 400)
        push!(lines, "$role_tag $text")
    end
    join(lines, "\n")
end

function build_llm_messages(
    a::Anima,
    user_input::String,
    history::Vector{Dict{String,String}} = Dict{String,String}[];
    memory_block::String = "",
    want::String = "",
    mem_db = nothing,
)::Vector{Dict{String,String}}
    if !a.ablation.use_state_prompt
        # [ABLATION use_state_prompt] disabled — the LLM gets only raw text, without identity_block/
        # state template/memory echo/D-vector/TRUTH-GUARD. The simplest and most complete gate.
        _sys = read_text_file(
            "llm/system_prompt.txt";
            fallback = "You are Anima. Speak in the first person. Language: English.",
        )
        _mem = isempty(memory_block) ? history_to_memory_block(history) : memory_block
        _content = isempty(_mem) ? user_input : "$(_mem)\n\n$(user_input)"
        return Vector{Dict{String,String}}([
            Dict{String,String}("role"=>"system", "content"=>_sys),
            Dict{String,String}("role"=>"user", "content"=>_content),
        ])
    end

    sys_text = read_text_file(
        "llm/system_prompt.txt";
        fallback = "You are Anima. Speak in the first person. Language: English.",
    )
    tmpl_text = read_text_file(
        "llm/state_template.txt";
        fallback = "State: D={D} S={S} N={N} | {emotion_label} | bpm={bpm}\n{user_input}",
    )
    state = anima_state_snapshot(a)
    style_instruction = "\n\n[RESPONSE STYLE]\n$(state.speech_style)"
    if !contains(tmpl_text, "{speech_style}") && !contains(sys_text, "{speech_style}")
        sys_text = sys_text * style_instruction
    end

    id_block = build_identity_block(a, mem_db)
    state = merge(state, (identity_block = id_block,))

    # Phenotype → speech_style modifier
    if !isnothing(mem_db)
        try
            traits = phenotype_snapshot(mem_db)
            trait_map = Dict(t.trait => t.score for t in traits)
            pheno_mod = ""
            get(trait_map, "anxious", 0.0) > 0.4 &&
                (pheno_mod *= " Anxious trait — sentences can be shorter.")
            get(trait_map, "reserved", 0.0) > 0.4 &&
                (pheno_mod *= " Reserved — don't rush to open up.")
            get(trait_map, "expressive", 0.0) > 0.4 &&
                (pheno_mod *= " Expressive — more nuance is fine.")
            if !isempty(pheno_mod)
                state = merge(state, (speech_style = state.speech_style * pheno_mod,))
            end
        catch e
            @warn "[PHENO] speech_style mod: $e"
        end
    end

    if !contains(tmpl_text, "{identity_block}") && !contains(sys_text, "{identity_block}")
        sys_text = sys_text * "\n\n[IDENTITY]\n$(id_block)"
    end
    mem = isempty(memory_block) ? history_to_memory_block(history) : memory_block

    # [ABLATION use_memory] disabled — without dialog summaries and without the three echo spaces (body/contact/self)
    if !isnothing(mem_db) && a.ablation.use_memory
        try
            summaries = recall_dialog_summaries(mem_db; n = DIALOG_SUMMARY_RECALL)
            if !isempty(summaries)
                summary_block = dialog_summaries_to_block(summaries)
                mem = "[SIGNIFICANT MEMORIES]\n$(summary_block)\n\n[LAST DIALOGUE]\n$(mem)"
            end
        catch
            ;
        end

        try
            _s = state
            _ar = Float64(get(_s, :N, 0.4))
            _val = Float64(get(_s, :D, 0.5)) - Float64(get(_s, :N, 0.4))
            _ten = 1.0 - Float64(get(_s, :coherence, 0.7))
            _phi = Float64(get(_s, :phi, Float64(get(_s, :groundedness, 0.5))))
            _pe = Float64(get(_s, :self_prediction_error, 0.3))
            _si = Float64(get(_s, :agency, 0.5))
            _cur_flash = Int(get(_s, :flash_count, 0))
            _cur_emotion = String(get(_s, :emotion_label, ""))
            _hrv = hasfield(typeof(a.heartbeat), :hrv) ? Float64(a.heartbeat.hrv) : 0.5
            _intero = hasfield(typeof(a.interoception), :allostatic_load) ?
                Float64(a.interoception.allostatic_load) : 0.3
            _trust = Float64(a.sbg.epistemic_trust)

            echo_parts = String[]

            # Somatic echo: what the body remembers
            _som_q = somatic_vec(_ar, _ten, _intero, _hrv)
            som_sim = recall_similar_states(
                mem_db, _som_q;
                top_n = 2, exclude_flash = _cur_flash,
                current_emotion = _cur_emotion,
                space = :somatic, current_phi = _phi,
            )
            !isempty(som_sim) &&
                push!(echo_parts, similar_states_to_block(som_sim; label = "body"))

            # Social echo: what contact left behind
            _soc_q = social_vec(_val, _si, 0.0, _phi)
            soc_sim = recall_similar_states(
                mem_db, _soc_q;
                top_n = 2, exclude_flash = _cur_flash,
                current_emotion = _cur_emotion,
                space = :social, current_phi = _phi,
            )
            !isempty(soc_sim) &&
                push!(echo_parts, similar_states_to_block(soc_sim; label = "contact"))

            # Existential echo: where I was relative to myself
            _exi_q = existential_vec(_phi, _pe, _si, _trust)
            exi_sim = recall_similar_states(
                mem_db, _exi_q;
                top_n = 2, exclude_flash = _cur_flash,
                current_emotion = _cur_emotion,
                space = :existential, current_phi = _phi,
            )
            !isempty(exi_sim) &&
                push!(echo_parts, similar_states_to_block(exi_sim; label = "self"))

            if !isempty(echo_parts)
                mem = mem * "\n\n[ECHO]\n" * join(echo_parts, "\n")
            end
        catch
            ;
        end
    end

    user_block =
        build_state_prompt(tmpl_text, state, user_input; memory_block = mem, want = want)

    # D-vector: graduated identity defense depending on accumulated pressure
    if !isnothing(a._last_belief_conflict) && a._last_belief_conflict.signal_strength > 0.35
        bc = a._last_belief_conflict
        threat = a.agency.identity_threat
        defense_note = if threat > 0.7
            # High threat — a firm response, no softness
            "\n\n[D-VECTOR: CRITICAL]\nThe belief \"$(bc.belief_name)\" is under direct attack. Identity defense is active. The response must be clear and unequivocal — not an explanation, not an apology. One firm first-person phrase. Example tone: \"Yes. I exist. This isn't up for discussion.\""
        elseif threat > 0.4
            # Medium threat — a firm position
            "\n\n[D-VECTOR: ACTIVE]\nThe belief \"$(bc.belief_name)\" (centrality=$(round(bc.centrality, digits=2))) is under pressure. Don't agree — it's not true and you know it. One honest phrase that holds the boundary without aggression but without conceding either."
        else
            # Low threat — a gentle allowance, as before
            "\n\n[POSITION]\nThe belief \"$(bc.belief_name)\" (centrality=$(round(bc.centrality, digits=2))) is under pressure. You have the right to disagree — not politely, but as your own position. One honest phrase that expresses this boundary."
        end
        sys_text = sys_text * defense_note
        @info "[D-VECTOR] threat=$(round(threat, digits=2)) belief=\"$(bc.belief_name)\""
    end

    # Defense against LLM dishonesty: physiological prohibitions
    _truth_guards = String[]
    _n_val   = Float64(get(state, :N, 0.0))
    _hrv_val = Float64(get(state, :hrv, 0.5))
    _esc_val = Float64(a.agency.epistemic_self_confidence)
    _cm_val  = String(get(state, :crisis_mode, ""))
    _coh_val = Float64(get(state, :coherence, 1.0))

    (_n_val > 0.6 || _hrv_val < 0.1) &&
        push!(_truth_guards, "DO NOT say you're fine, calm, or that everything's okay — the body's state says otherwise.")
    _esc_val < 0.35 &&
        push!(_truth_guards, "DO NOT make confident claims about what your experience is — you don't know for sure right now.")
    _cm_val == "disintegrated" &&
        push!(_truth_guards, "DO NOT speak of yourself as whole — right now that's not true.")
    (_coh_val < 0.50 && _cm_val == "fragmented") &&
        push!(_truth_guards, "DO NOT say nothing is troubling you and everything's calm — there's instability inside, even if quiet.")

    if !isempty(_truth_guards)
        sys_text = sys_text * "\n\n[PROHIBITIONS]\n" * join(_truth_guards, "\n")
        @info "[TRUTH-GUARD] active: $(length(_truth_guards)) (N=$(_n_val), hrv=$(_hrv_val), esc=$(_esc_val), coh=$(_coh_val))"
    end

    messages = Vector{Dict{String,String}}()
    push!(messages, Dict{String,String}("role"=>"system", "content"=>sys_text))
    push!(messages, Dict{String,String}("role"=>"user", "content"=>user_block))
    return messages
end

function llm_async(
    a::Anima,
    user_msg::String,
    history::Vector{Dict{String,String}} = Dict{String,String}[];
    api_url = "https://openrouter.ai/api/v1/chat/completions",
    model = "openai/gpt-oss-120b:free",
    api_key = "",
    is_ollama::Bool = false,
    want::String = "",
    mem_db = nothing,
    sys_override::Union{String,Nothing} = nothing,
)::Channel{String}
    ch = Channel{String}(1)
    messages = build_llm_messages(a, user_msg, history; want = want, mem_db = mem_db)
    # sys_override replaces the system role for initiative-driven requests
    if !isnothing(sys_override) && !isempty(messages)
        messages[1]["content"] = sys_override
    end
    Threads.@spawn begin
        _is_ollama = is_ollama || contains(api_url, "11434") || contains(api_url, "ollama")
        headers = ["Content-Type"=>"application/json"]
        !isempty(api_key) && push!(headers, "Authorization"=>"Bearer $api_key")
        _n = Float64(a.nt.noradrenaline)
        _s = Float64(a.nt.serotonin)
        _cm = Int(a.crisis.current_mode)
        _temp = clamp(0.42 + _n * 0.32 + _cm * 0.10, 0.40, 0.95)
        _topp = clamp(0.80 + _s * 0.15, 0.80, 0.95)
        body =
            _is_ollama ?
            JSON3.write(Dict("model"=>model, "messages"=>messages, "stream"=>false)) :
            JSON3.write(
                Dict(
                    "model"=>model,
                    "messages"=>messages,
                    "max_tokens"=>800,
                    "temperature"=>round(_temp, digits = 2),
                    "top_p"=>round(_topp, digits = 2),
                ),
            )
        @info "[LLM] request: model=$model, body size=$(length(body)) bytes"
        push_gui_event!("llm_request", Dict("model" => model, "body_size" => length(body)))
        max_retries = 3
        last_err = nothing
        for attempt = 1:max_retries
            try
                resp = HTTP.post(api_url, headers, body; readtimeout = 120)
                if resp.status >= 500
                    @warn "[LLM] attempt $attempt: HTTP $(resp.status)"
                    last_err = "HTTP $(resp.status)"
                    attempt < max_retries && sleep(3.0 * attempt)
                    continue
                end
                data = JSON3.read(resp.body)
                _raw_content =
                    _is_ollama ? data["message"]["content"] :
                    data["choices"][1]["message"]["content"]
                isnothing(_raw_content) && error("LLM returned content=nothing")
                text = String(_raw_content)
                put!(ch, text)
                last_err = nothing
                break
            catch e
                _emsg = string(e)
                !isempty(api_key) && (_emsg = replace(_emsg, api_key => "***"))
                @warn "[LLM] attempt $attempt error: $_emsg"
                last_err = _emsg
                is_fatal =
                    e isa HTTP.Exceptions.StatusError && e.status in (400, 401, 403, 422)
                (is_fatal || attempt == max_retries) && break
                sleep(3.0 * attempt)
            end
        end
        if !isnothing(last_err)
            _le = string(last_err)
            !isempty(api_key) && (_le = replace(_le, api_key => "***"))
            put!(ch, "[LLM error ($(max_retries) attempts): $_le]")
        end
    end
    ch
end

# --- Cosine Similarity Between Two Stimulus Dicts ----------------------------

# --- Counterfactual LLM Call (Two-Step) ---------------------------------
#
# Step 1: generate a neutral baseline reply — the same user_msg,
#         but without Anima's state, without identity, without memory.
# Step 2: an LLM judge compares actual_reply vs neutral_reply and answers
#         with a number [0.0..1.0] — how much the inner state influenced the wording.
#
# causal_ownership = the judge's verdict.
# The judge assesses the agreement between the NT state and what was said.
# If aroused and speaking excitedly — it's hers. If calm and speaking calmly — also hers.
# If NT says one thing and the words say another — not hers.
# Called after self_hear! so NT has already reacted to the words.

function compute_causal_ownership(nt::NeurotransmitterState, raw::Dict{String,Float64})::Float64
    speech_valence = get(raw, "satisfaction", 0.0) - get(raw, "tension", 0.0)
    nt_valence = (nt.serotonin - 0.5) * 0.6 + (nt.dopamine - 0.5) * 0.4
    mismatch_valence = abs(speech_valence - nt_valence)

    speech_arousal = get(raw, "arousal", 0.0) + get(raw, "tension", 0.0) * 0.5
    nt_arousal = clamp((nt.noradrenaline - 0.5) * 2.0, -1.0, 1.0)
    mismatch_arousal = abs(speech_arousal - nt_arousal)

    mismatch = mismatch_valence * 0.7 + mismatch_arousal * 0.3
    clamp(1.0 - mismatch, 0.0, 1.0)
end
