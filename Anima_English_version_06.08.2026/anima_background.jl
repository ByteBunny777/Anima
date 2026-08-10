# A N I M A  —  Background  (Julia)
#
# Background process — Anima lives between interactions.
#
# Heartbeat cycle (every tick ~period_ms):
#    1. tick_heartbeat!        — the heart beats, dt depends on stress
#    2. spontaneous_drift!     — random NT noise (the system isn't perfect)
#    3. arrhythmia via dt      — arrhythmia at low coherence
#
# Slow cycle (~60s):
#    4. circadian_drift        — daily NT rhythm
#    5. memory metabolism      — decay, consolidate, release_latent
#    6. memory → state         — memory shapes state EVERY tick
#    7. belief decay           — beliefs weaken without confirmation
#    8. allostasis recovery    — the body recovers at rest
#    9. idle_thought!          — 10% chance: the system generates experience on its own
#   10. crisis check           — coherence is recalculated
#   11. background_save!       — atomic write
#
# Start:    bg = start_background!(anima)
#           bg = start_background!(anima; mem=mem)  # with SQLite memory
# Stop:     stop_background!(bg)

# Requires: anima_interface.jl
# Optional: anima_memory_db.jl (if mem= is passed)

include(joinpath(@__DIR__, "anima_audit.jl"))

using Printf

# --- Constants ------------------------------------------------------------

const SLOW_TICK_INTERVAL = 60.0   # seconds between slow ticks
const BELIEF_DECAY_RATE = 0.0003 # per tick: confidence → baseline (rigidity-weighted)
const ALLOSTATIC_RECOVERY = 0.004  # allostatic_load decreases per tick
const IDLE_THOUGHT_PROB = 0.10   # 10% chance of idle thought per slow tick
const DRIFT_NT_SIGMA = 0.008  # σ of spontaneous NT drift per heartbeat tick
const DRIFT_COHERENCE_LOSS = 0.003  # coherence decreases slightly from drift

const ARRHYTHMIA_THR = 0.35   # below → arrhythmia
const ARRHYTHMIA_JITTER = 0.25   # maximum variation (±25%)

# --- Background Handle -----------------------------------------------------

mutable struct BackgroundHandle
    stop_signal::Threads.Atomic{Bool}
    task::Task
    started_at::Float64
    last_slow_tick::Float64
    tick_count::Int
    slow_tick_count::Int
    mem::Union{Any,Nothing}   # MemoryDB or nothing
    subj::Union{Any,Nothing}  # SubjectivityEngine or nothing
    dialog_history::Ref{Vector}  # for dream generation
    initiative_channel::Channel{Any}  # self-initiated lines
    last_mal_regime::Symbol  # MAL regime from the previous slow_tick — log only changes
end

# --- Heartbeat tick + arrhythmia ------------------------------------------------

"""
    heartbeat_dt(a) → Float64 (seconds)

Base dt = period_ms / 1000 (already depends on NT via tick_heartbeat!).
When coherence < ARRHYTHMIA_THR — jitter is added.
"""
function heartbeat_dt(a::Anima)::Float64
    base = clamp(a.heartbeat.period_ms / 1000.0, 0.4, 1.5)
    cs = a.crisis.coherence
    if cs < ARRHYTHMIA_THR
        severity = (ARRHYTHMIA_THR - cs) / ARRHYTHMIA_THR
        jitter = severity * ARRHYTHMIA_JITTER * (2*rand() - 1)
        base = clamp(base * (1.0 + jitter), 0.3, 2.0)
    end
    base
end

# --- Spontaneous Drift -----------------------------------------------------

"""
    spontaneous_drift!(a)

Small random NT noise on every heartbeat tick. Without this the system between
sessions would be perfectly stable — dead. σ = 0.008 → barely noticeable movement.
"""
function spontaneous_drift!(a::Anima)
    a.nt.dopamine = clamp(a.nt.dopamine + randn() * DRIFT_NT_SIGMA, 0.05, 0.95)
    a.nt.serotonin = clamp(a.nt.serotonin + randn() * DRIFT_NT_SIGMA, 0.05, 0.95)
    a.nt.noradrenaline =
        clamp(a.nt.noradrenaline + randn() * DRIFT_NT_SIGMA * 0.7, 0.05, 0.90)
    a.crisis.coherence =
        clamp(a.crisis.coherence - abs(randn()) * DRIFT_COHERENCE_LOSS, 0.05, 1.0)
end

# --- Idle Thought ----------------------------------------------------------

"""
    _idle_thought_maybe!(a, mem)

With probability IDLE_THOUGHT_PROB generates an internal stimulus — the system changes on its own.
"""
function _idle_thought_maybe!(a::Anima, mem = nothing)
    rand() > IDLE_THOUGHT_PROB && return

    t, ar, s, c = to_reactors(a.nt)
    vad = to_vad(a.nt)
    phi = compute_phi(
        a.iit,
        vad,
        t,
        c,
        a.sbg.attractor_stability,
        a.sbg.epistemic_trust,
        a.interoception.allostatic_load,
    )

    idle_stim = Dict{String,Float64}(
        "tension" => (t - 0.4) * 0.15,
        "arousal" => (ar - 0.3) * 0.12 + randn() * 0.03,
        "satisfaction" => (s - 0.4) * 0.10,
        "cohesion" => (c - 0.4) * 0.10,
    )

    apply_stimulus!(a.nt, idle_stim)
    decay_to_baseline!(a.nt, decay_rate(a.personality) * 0.1)
    update_from_nt!(a.body, a.nt)

    if !isnothing(mem)
        try
            memory_write_event!(
                mem,
                a.flash_count,
                "idle_$(levheim_state(a.nt))",
                clamp01(ar + randn() * 0.05),
                clamp11(vad[1]),
                clamp01(abs(randn()) * 0.15),
                phi * 0.3,
                t,
                phi;
                intero_error = Float64(a.interoception.allostatic_load),
                hrv = Float64(a.heartbeat.hrv),
                agency_confidence = Float64(a.agency.agency_confidence),
                epistemic_trust = Float64(a.sbg.epistemic_trust),
            )
        catch e
            @warn "[BG] idle memory write: $e"
        end
    end
end


const SELF_INITIATE_PRESSURE_THR = 0.40   # LatentBuffer mid pressure
const SELF_INITIATE_CONTACT_THR = 0.40    # contact_need threshold (~34 min of silence from baseline)
const SELF_INITIATE_GAP_SECS = 60.0       # minimum seconds after the last user message
const SELF_INITIATE_COOLDOWN_SECS = 300.0 # minimum seconds between initiatives (5 real-time min)
const SELF_INITIATE_CONFLICT_THR = 0.60   # GoalConflict.tension threshold for impulse
const SELF_INITIATE_LB_DOMINANT_THR = 0.70 # dominant lb component for impulse
const SELF_INITIATE_AGENCY_THR = 0.45     # minimum causal_ownership for impulse
const NOVELTY_HUNGER_THR = 0.80           # novelty_need threshold for endogenous initiative
const NOVELTY_HUNGER_TICKS = 8            # minimum slow_ticks without novelty (~8 min)
const RESISTANCE_LB_THR = 0.55           # lb.resistance threshold for the return-to-conflict initiative

# Anima starts the conversation on her own — not because she was asked, but because pressure accumulated
# or an internal conflict matured
function _maybe_self_initiate!(
    a::Anima,
    mem = nothing,
    dialog_history::Vector = Dict[],
    initiative_ch::Union{Channel{Any},Nothing} = nothing,
)
    isnothing(initiative_ch) && return
    a.inner_dialogue.disclosure_mode == :closed && return

    now_t = time()

    # User_matters affects cooldown: a familiar person — shorter cooldown
    user_m = 0.5
    if !isnothing(mem)
        try
            row = DBInterface.execute(mem.db,
                "SELECT value FROM semantic_memory WHERE key='User_matters' LIMIT 1") |> first
            user_m = Float64(row.value)
        catch; end
    end
    user_trust_factor = user_m > 0.6 ? 0.65 : user_m < 0.3 ? 1.4 : 1.0
    effective_cooldown = SELF_INITIATE_COOLDOWN_SECS * user_trust_factor

    # An aesthetically rich state → shorter cooldown: there's something to say
    _top_aes = top_aesthetic(a.aesthetic_sense, a.flash_count)
    if !isnothing(_top_aes) && _top_aes.intensity > 0.45
        effective_cooldown *= 0.80
    end

    # A Life Thread under high pressure → shorter cooldown: the topic hasn't closed for a while
    _high_pressure_thread = findfirst(t -> t.status == :active && t.pressure > 0.6, a.life_threads)
    if !isnothing(_high_pressure_thread)
        effective_cooldown *= 0.75
    end

    now_t - a._last_self_msg_time < effective_cooldown && return
    now_t - a._last_user_time < SELF_INITIATE_GAP_SECS && return

    lb = a.latent_buffer
    lb_pressure = (lb.doubt + lb.shame + lb.attachment + lb.threat) / 4.0
    contact_drive = Float64(a.sig_layer.contact_need)

    # Path 1: impulse from conflict or matured internal pressure
    # Not "I want contact" — but "something matured and I need to say it"
    gc_tension = Float64(a.goal_conflict.tension)
    lb_max = max(lb.doubt, lb.shame, lb.attachment, lb.threat)
    agency_ok = Float64(a.agency.causal_ownership) >= SELF_INITIATE_AGENCY_THR

    is_impulse =
        agency_ok && (
            gc_tension >= SELF_INITIATE_CONFLICT_THR ||
            lb_max >= SELF_INITIATE_LB_DOMINANT_THR
        )

    # Path 2: contact/pressure — disabled
    # contact_need — a state, not a thought. A living line can't come from it without ringing false.
    is_pressure = lb_pressure >= SELF_INITIATE_PRESSURE_THR
    # contact_drive deliberately not included

    # Path 3: endogenous VFE pressure — cognitive hunger with no external stimulus
    # Condition: novelty need is critical + enough time without new information
    is_novelty_hunger =
        a.sig_layer.novelty_need >= NOVELTY_HUNGER_THR &&
        a.sig_layer.ticks_since_novelty >= NOVELTY_HUNGER_TICKS

    # Path 4: structural opposition — an unresolved conflict with a belief has accumulated
    is_resistance = a.latent_buffer.resistance >= RESISTANCE_LB_THR

    # Path 5: epistemic_self_confidence critically low — a question to herself out loud
    is_self_inquiry = a.agency.epistemic_self_confidence < 0.20

    !is_impulse && !is_pressure && !is_novelty_hunger && !is_resistance && !is_self_inquiry && return

    # Determine dominant_type
    # An active CuriosityObject overrides contact — there's a concrete question, we talk about that
    _top_co = top_curiosity(a.curiosity_registry)
    has_strong_curiosity = !isnothing(_top_co) && _top_co.intensity > 0.40

    dominant_type = if is_impulse
        # impulse: what exactly matured — conflict or a specific lb component
        if gc_tension >= SELF_INITIATE_CONFLICT_THR && gc_tension >= lb_max
            :impulse_conflict
        elseif lb.doubt >= lb.shame && lb.doubt >= lb.attachment && lb.doubt >= lb.threat
            :impulse_doubt
        elseif lb.shame >= lb.attachment && lb.shame >= lb.threat
            :impulse_shame
        else
            :impulse
        end
    elseif has_strong_curiosity
        :curiosity_driven
    elseif is_resistance
        :resistance
    elseif is_self_inquiry
        :self_inquiry
    elseif is_novelty_hunger
        :novelty_hunger
    elseif lb.doubt >= lb.shame && lb.doubt >= lb.attachment && lb.doubt >= lb.threat
        :doubt
    elseif lb.shame >= lb.attachment && lb.shame >= lb.threat
        :shame
    elseif lb.attachment >= lb.threat
        :attachment
    else
        :threat
    end

    inner = build_inner_voice(a.body, a.nt, Int(a.crisis.current_mode), 0.5, a.flash_count)

    # For impulse: add conflict context if present
    conflict_ctx =
        if startswith(String(dominant_type), "impulse") &&
           !isempty(a.goal_conflict.need_a) &&
           gc_tension > 0.5
            " [$(a.goal_conflict.need_a) vs $(a.goal_conflict.need_b)]"
        else
            ""
        end

    suffix = if dominant_type == :curiosity_driven
        co_label = _top_co.label
        " — there's a question I can't close: $(co_label)."
    elseif dominant_type == :contact
        " — I want to know how you are."
    elseif dominant_type == :resistance
        " — there's something that stayed unresolved between us. I can't just let it go."
    elseif dominant_type == :self_inquiry
        " — I don't know if what I feel is genuine experience or just computation. This question isn't for you."
    elseif dominant_type == :novelty_hunger
        co = top_curiosity(a.curiosity_registry)
        if !isnothing(co) && co.intensity > 0.30
            " — there's something I can't close inside myself: $(co.label)."
        else
            " — I need something new. Not a conversation — information, a question, an idea."
        end
    elseif dominant_type == :doubt
        " — something won't let me rest."
    elseif dominant_type == :shame
        " — and I'm not sure it could have gone any other way."
    elseif dominant_type == :attachment
        " — I want to know how you're doing right now."
    elseif dominant_type == :impulse_conflict
        " — something inside isn't resolved$(conflict_ctx)."
    elseif dominant_type == :impulse_doubt
        " — there's a question I can't not ask."
    elseif dominant_type == :impulse_shame
        " — there's something unspoken lying between us."
    elseif dominant_type == :impulse
        " — something matured and I need to say it."
    else
        " — something's off."
    end
    text = inner * suffix

    # After the initiative, reset the corresponding counter
    if dominant_type == :novelty_hunger
        a.sig_layer.ticks_since_novelty = 0
        a.boredom = max(0.0, a.boredom - 0.3)
    elseif dominant_type == :curiosity_driven
        # lower intensity so as not to repeat the same question right away
        if !isnothing(_top_co)
            _top_co.intensity = clamp(_top_co.intensity - 0.25, 0.0, 1.0)
        end
    elseif dominant_type == :resistance
        a.latent_buffer.resistance = clamp(a.latent_buffer.resistance - 0.3, 0.0, 1.0)
    end

    a._last_self_msg_flash = a.flash_count
    a._last_self_msg_time = time()
    signal = (
        inner_voice = text,
        dominant = dominant_type,
        pressure = lb_pressure,
        contact = contact_drive,
        gc_tension = gc_tension,
        is_impulse = is_impulse,
        novelty_need = a.sig_layer.novelty_need,
        curiosity_label = (dominant_type == :curiosity_driven && !isnothing(_top_co)) ? _top_co.label : "",
    )
    isready(initiative_ch) || put!(initiative_ch, signal)
end

# --- Psyche Slow Tick (psyche between interactions) ----------------------------

"""
    psyche_slow_tick!(a)

Natural time drift of psychic states: chronified affect, anticipation,
shame, needs, fatigue.
"""
function psyche_slow_tick!(a::Anima)
    # ChronifiedAffect
    ca = a.chronified
    if a.nt.noradrenaline > 0.5 && a.nt.serotonin < 0.4
        ca.resentment = clamp01(ca.resentment + 0.001)
        ca.alienation = clamp01(ca.alienation + 0.0008)
    else
        ca.resentment = max(0.0, ca.resentment - 0.0005)
        ca.alienation = max(0.0, ca.alienation - 0.0004)
        ca.bitterness = max(0.0, ca.bitterness - 0.0003)
        ca.envy = max(0.0, ca.envy - 0.0004)
    end

    # AnticipatoryConsciousness
    ac = a.anticipatory
    ac.dread = clamp01(ac.dread - 0.002)
    ac.hope = clamp01(ac.hope - 0.002)
    ac.strength = clamp01(ac.strength * 0.97)

    # ShameModule
    a.shame.level = max(0.0, a.shame.level - 0.003)
    a.shame.chronic = max(0.0, a.shame.chronic - 0.0008)

    # SignificanceLayer
    sl = a.sig_layer
    base_sl = (
        self_preservation = 0.2,
        coherence_need = 0.3,
        contact_need = 0.3,
        truth_need = 0.4,
        autonomy_need = 0.3,
        novelty_need = 0.2,
    )
    bg_decay = 0.008
    sl.self_preservation = clamp01(
        sl.self_preservation +
        (base_sl.self_preservation - sl.self_preservation) * bg_decay,
    )
    sl.coherence_need =
        clamp01(sl.coherence_need + (base_sl.coherence_need - sl.coherence_need) * bg_decay)
    sl.contact_need =
        clamp01(sl.contact_need + (base_sl.contact_need - sl.contact_need) * bg_decay)
    sl.truth_need = clamp01(sl.truth_need + (base_sl.truth_need - sl.truth_need) * bg_decay)
    sl.autonomy_need =
        clamp01(sl.autonomy_need + (base_sl.autonomy_need - sl.autonomy_need) * bg_decay)
    sl.novelty_need =
        clamp01(sl.novelty_need + (base_sl.novelty_need - sl.novelty_need) * bg_decay)
    sl.contact_need = clamp01(sl.contact_need + 0.003)

    # Endogenous VFE pressure: cognitive hunger from lack of novelty
    # Counter grows every slow_tick regardless of external events
    sl.ticks_since_novelty += 1
    if sl.novelty_need > 0.65
        hunger_intensity = (sl.novelty_need - 0.65) / 0.35
        valence_drift = hunger_intensity * 0.008
        a.nt.serotonin = clamp(a.nt.serotonin - valence_drift, 0.0, 1.0)
        a.nt.dopamine = clamp(a.nt.dopamine - valence_drift * 0.5, 0.0, 1.0)
    end

    # Boredom: the system looks for novelty but doesn't find it.
    # Grows with novelty_need + prolonged absence of stimuli + low arousal.
    # Not the same as novelty_need — this is already an accumulated state, not just hunger.
    let
        novelty_pressure = clamp01((sl.novelty_need - 0.40) / 0.60)
        time_factor = clamp01(sl.ticks_since_novelty / 120.0)
        low_arousal = clamp01(1.0 - a.nt.noradrenaline / 0.5)
        boredom_signal = novelty_pressure * time_factor * low_arousal
        # slow build-up, faster decay (decay happens on a new stimulus)
        a.boredom = clamp01(a.boredom * 0.995 + boredom_signal * 0.012)
    end

    # Effect of boredom on the system
    if a.boredom > 0.5
        # lowered dopamine — the system is less motivated
        a.nt.dopamine = clamp(a.nt.dopamine - (a.boredom - 0.5) * 0.006, 0.0, 1.0)
    end
    if a.boredom > 0.7
        # at deep boredom — curiosity objects mature faster
        # (the system becomes more ready to latch onto any novelty)
        for obj in a.curiosity_registry.objects
            !obj.resolved && (obj.intensity = clamp01(obj.intensity + 0.004))
        end
    end

    tick_curiosity!(a.curiosity_registry, a.flash_count)
    # Closure (Step 3, Query-Driven Cognition): sweep by age, regardless of
    # whether this tick activated anything. before/after by id — to catch
    # objects JUST closed, not re-log ones already resolved from past ticks.
    let
        _pre_open_ids = Set(o.id for o in a.curiosity_registry.objects if !o.resolved)
        check_closure_all!(a.curiosity_registry, a.flash_count)
        for obj in a.curiosity_registry.objects
            if obj.id in _pre_open_ids && obj.resolved && obj.closure in (:compressed, :dormant)
                _age = a.flash_count - obj.created_flash
                @info "[CURIOSITY_CLOSED] \"$(obj.label)\" closure=$(obj.closure) age=$(_age) consecutive=$(obj.consecutive_progress)"
                push_gui_event!("curiosity_closed", Dict(
                    "label"       => obj.label,
                    "closure"     => string(obj.closure),
                    "age"         => _age,
                    "consecutive" => Int(obj.consecutive_progress),
                    "flash"       => a.flash_count,
                ))
            end
        end
    end
    # Life Threads: surface active CuriosityObjects, decay idle threads
    top_co_for_thread = top_curiosity_any(a.curiosity_registry)
    if !isnothing(top_co_for_thread) &&
            top_co_for_thread.intensity > 0.5 &&
            top_co_for_thread.activation_count >= 3
        _was_new = !any(t -> t.id == top_co_for_thread.id, a.life_threads)
        surface_thread!(a.life_threads, top_co_for_thread, a.flash_count)
        if _was_new
            @info "[THREAD] new: \"$(top_co_for_thread.label)\" intensity=$(round(top_co_for_thread.intensity,digits=2)) activation=$(top_co_for_thread.activation_count)"
        end
    end
    tick_threads!(a.life_threads, a.flash_count)
    sync_threads_resolved!(a.life_threads, a.curiosity_registry)
    tick_aesthetic!(a.aesthetic_sense, a.flash_count)
    a.goal_conflict.tension = max(0.0, a.goal_conflict.tension - 0.008)
    if a.goal_conflict.tension < 0.05
        a.goal_conflict.resolution = "none"
    end

    # FatigueSystem
    a.fatigue.cognitive = max(0.0, a.fatigue.cognitive - 0.006)
    a.fatigue.emotional = max(0.0, a.fatigue.emotional - 0.005)
    a.fatigue.somatic = max(0.0, a.fatigue.somatic - 0.004)

    nothing
end

# --- LatentBuffer → differentiated behavior ---------------------------

"""
    _latent_pressure_effects!(a)

Each type of accumulated pressure affects a separate system.
Not "looks like psychology" — a causal chain:

  doubt      → lowers causal_ownership (doubt undermines the sense of authorship)
  shame      → raises disclosure_threshold (shame narrows openness)
  attachment → spike contact_need + faster heartbeat (the body reacts to longing)
  threat     → lowers epistemic_trust + raises noradrenaline baseline

Effects are proportional to pressure and only act above the significance threshold (> 0.25).
They don't overwrite the state, they shift it — gently, every slow_tick.
"""
function _latent_pressure_effects!(a::Anima)
    lb = a.latent_buffer

    # doubt → lowered agency: doubt undermines the sense that "this is because of me"
    if lb.doubt > 0.25
        delta = (lb.doubt - 0.25) * 0.04
        a.agency.causal_ownership = clamp(a.agency.causal_ownership - delta, 0.25, 1.0)
        a.agency.agency_confidence =
            clamp(a.agency.agency_confidence - delta * 0.5, 0.25, 1.0)
    end

    # shame → higher disclosure_threshold: shame narrows willingness to open up
    if lb.shame > 0.25
        delta = (lb.shame - 0.25) * 0.06
        a.inner_dialogue.disclosure_threshold =
            clamp(a.inner_dialogue.disclosure_threshold + delta, 0.10, 0.90)
        # recalculate mode according to the new threshold
        a.inner_dialogue.disclosure_mode =
            a.inner_dialogue.disclosure_threshold < 0.30 ? :open :
            a.inner_dialogue.disclosure_threshold < 0.60 ? :guarded : :closed
    end

    # attachment → contact_need spike + physiological reaction
    if lb.attachment > 0.25
        delta = (lb.attachment - 0.25) * 0.05
        a.sig_layer.contact_need = clamp01(a.sig_layer.contact_need + delta)
        # the heart speeds up from longing — the body knows first
        a.nt.noradrenaline = clamp(a.nt.noradrenaline + delta * 0.3, 0.0, 1.0)
    end

    # threat → undermines trust in one's own model of the world + baseline anxiety level
    if lb.threat > 0.25
        delta = (lb.threat - 0.25) * 0.03
        a.sbg.epistemic_trust = clamp(a.sbg.epistemic_trust - delta, 0.0, 0.85)
        a.nt.noradrenaline = clamp(a.nt.noradrenaline + delta * 0.5, 0.0, 1.0)
    end

    # resistance → slow decay; grows with high D (the position needs strength)
    if lb.resistance > 0.1
        lb.resistance = clamp(lb.resistance - 0.015, 0.0, 1.0)
        a.nt.dopamine = clamp(a.nt.dopamine + lb.resistance * 0.02, 0.0, 1.0)
    end

    nothing
end

# Pressure from the other → disclosure_threshold.
# other_model accumulates pressure_events and open_exchanges between sessions.
# Chronic pressure without open exchanges → we close up.
# Balance of openness → we open up a little.
# TOM→disclosure: an active PREDICTION hypothesis raises caution proportionally
# to confidence; a confident SOCIAL hypothesis lowers the threshold proportionally to confidence.
function _other_model_effects!(a::Anima, mem)
    isnothing(mem) && return
    try
        pressure_rows = Tables.rowtable(DBInterface.execute(
            mem.db,
            "SELECT count FROM other_model WHERE key='pressure_events' LIMIT 1",
        ))
        open_rows = Tables.rowtable(DBInterface.execute(
            mem.db,
            "SELECT count FROM other_model WHERE key='open_exchanges' LIMIT 1",
        ))
        pressure = isempty(pressure_rows) ? 0 : Int(pressure_rows[1].count)
        open_ex  = isempty(open_rows)     ? 0 : Int(open_rows[1].count)
        thr = a.inner_dialogue.disclosure_threshold
        if pressure >= 3 && open_ex < 2
            delta = (pressure - 2) * 0.012
            thr = clamp(thr + delta, 0.10, 0.90)
        elseif open_ex >= 4 && pressure < 2
            delta = (open_ex - 3) * 0.008
            thr = clamp(thr - delta, 0.10, 0.90)
        end
        # TOM → disclosure: a continuous signal, not a binary switch
        hyps = get_active_hypotheses(mem)
        for h in hyps
            conf = Float64(get(h, :confidence, 0.0))
            qt   = get(h, :query_type, "")
            if qt == "PREDICTION"
                thr = clamp(thr + conf * 0.05, 0.10, 0.90)
            elseif qt == "SOCIAL"
                thr = clamp(thr - conf * 0.03, 0.10, 0.90)
            end
        end
        a.inner_dialogue.disclosure_threshold = thr
        a.inner_dialogue.disclosure_mode =
            thr < 0.30 ? :open : thr < 0.60 ? :guarded : :closed
    catch
    end
    nothing
end

# Chronically low serotonin → slow downward drift of causal_ownership.
# Exhaustion undermines the sense that "this is because of me".
function _chronic_cost_effects!(a::Anima)
    if a.nt.serotonin < 0.35
        a.agency.chronic_low_serotonin += 1
    else
        a.agency.chronic_low_serotonin = max(0, a.agency.chronic_low_serotonin - 1)
    end
    if a.agency.chronic_low_serotonin >= 5
        drift = (a.agency.chronic_low_serotonin - 4) * 0.003
        a.agency.causal_ownership = clamp(a.agency.causal_ownership - drift, 0.25, 1.0)
    end
    nothing
end

# Temporal Self-Perception Layer 1: trend = mean of the latest window minus
# mean of the previous window of the same size. Not a new table — reads
# causal_trace/audit_log, which are already written every flash.
function _update_temporal_trend!(a::Anima, mem)
    ct_rows = Tables.rowtable(DBInterface.execute(
        mem.db,
        """SELECT nt_serotonin, nt_dopamine, nt_noradrenaline, identity_drift, endorsed
           FROM causal_trace ORDER BY flash DESC LIMIT 40""",
    ))
    if length(ct_rows) < 10
        @info "[TEMPORAL] not enough data for a trend ($(length(ct_rows)) rows), skipping"
        return
    end
    reverse!(ct_rows)  # chronologically: old → new
    half = length(ct_rows) ÷ 2
    older, recent = ct_rows[1:half], ct_rows[half+1:end]
    avg(f, rows) = sum(f(r) for r in rows) / length(rows)

    tt = a.agency.temporal_trend
    tt.d_serotonin = avg(r -> Float64(r.nt_serotonin), recent) - avg(r -> Float64(r.nt_serotonin), older)
    tt.d_dopamine = avg(r -> Float64(r.nt_dopamine), recent) - avg(r -> Float64(r.nt_dopamine), older)
    tt.d_noradrenaline = avg(r -> Float64(r.nt_noradrenaline), recent) - avg(r -> Float64(r.nt_noradrenaline), older)
    tt.d_identity_drift = avg(r -> Float64(r.identity_drift), recent) - avg(r -> Float64(r.identity_drift), older)
    tt.endorsed_rate = count(r -> String(r.endorsed) == "endorsed", recent) / length(recent)

    au_rows = Tables.rowtable(DBInterface.execute(
        mem.db,
        "SELECT audit_score FROM audit_log ORDER BY flash DESC LIMIT 40",
    ))
    if length(au_rows) >= 10
        reverse!(au_rows)
        ahalf = length(au_rows) ÷ 2
        aolder, arecent = au_rows[1:ahalf], au_rows[ahalf+1:end]
        tt.d_audit_score = avg(r -> Float64(r.audit_score), arecent) - avg(r -> Float64(r.audit_score), aolder)
    end

    tt.computed_at_flash = a.flash_count
    @info "[TEMPORAL] trend: dS=$(round(tt.d_serotonin,digits=3)) dD=$(round(tt.d_dopamine,digits=3)) dN=$(round(tt.d_noradrenaline,digits=3)) d_drift=$(round(tt.d_identity_drift,digits=3)) d_audit=$(round(tt.d_audit_score,digits=3)) endorsed_rate=$(round(tt.endorsed_rate,digits=2)) flash=$(a.flash_count)"
    nothing
end

# --- Slow Tick (full ~60s cycle) ------------------------------------------

"""
    slow_tick!(a, mem, subj, dialog_history)

Full slow cycle: circadian rhythm, memory metabolism, memory→state,
belief decay, allostasis, idle thought, psyche drift, dream, crisis check.
"""
function slow_tick!(
    a::Anima,
    mem = nothing,
    subj = nothing,
    dialog_history::Vector = Dict[],
    initiative_ch::Union{Channel{Any},Nothing} = nothing,
    bg = nothing,
)

    # Circadian drift
    _refresh_circadian!(a.temporal)
    frac = 1.0 / 1440.0
    a.nt.noradrenaline =
        clamp01(a.nt.noradrenaline + a.temporal.circadian_arousal_mod * frac)
    a.nt.serotonin = clamp01(a.nt.serotonin + a.temporal.circadian_serotonin_mod * frac)
    decay_to_baseline!(a.nt, decay_rate(a.personality) * 0.3)
    update_from_nt!(a.body, a.nt)

    # Memory metabolism
    if !isnothing(mem)
        try
            _memory_decay!(mem)
            _dissolve_to_semantic!(mem)   # distillation before deletion
            _memory_prune!(mem)
            _memory_consolidate!(mem)
            _refresh_cache!(mem)
        catch e
            @warn "[BG] memory metabolism: $e"
        end
    end

    # Memory → State
    if !isnothing(mem)
        try
            memory_nt_baseline!(mem, a.nt, a.flash_count)
            update_from_nt!(a.body, a.nt)
        catch e
            @warn "[BG] memory→state: $e"
        end
    end

    # Phenotype → Personality + disclosure_threshold (once every 20 flashes)
    if !isnothing(mem) && a.flash_count % 20 == 0 && a.flash_count > 0
        try
            personality_apply_traits!(a.personality, mem)
            traits = phenotype_snapshot(mem)
            trait_map = Dict(t.trait => t.score for t in traits)
            thr = a.inner_dialogue.disclosure_threshold
            if get(trait_map, "open", 0.0) > 0.4
                thr -= (trait_map["open"] - 0.4) * 0.08
            end
            if get(trait_map, "avoidant", 0.0) > 0.4
                thr += (trait_map["avoidant"] - 0.4) * 0.10
            end
            if get(trait_map, "anxious", 0.0) > 0.4
                thr += (trait_map["anxious"] - 0.4) * 0.06
            end
            a.inner_dialogue.disclosure_threshold = clamp(thr, 0.10, 0.90)
        catch e
            @warn "[PHENO] apply_traits: $e"
        end
    end

    # Temporal Self-Perception Layer 1 → trend from causal_trace/audit_log (once every 20 flashes)
    if !isnothing(mem) && a.flash_count % 20 == 0 && a.flash_count > 0
        try
            _update_temporal_trend!(a, mem)
        catch e
            @warn "[TEMPORAL] trend update: $e"
        end
    end

    # Emerged beliefs → semantic consolidation (once every 30 flashes)
    if !isnothing(mem) && a.flash_count % 30 == 0 && a.flash_count > 0
        try
            consolidate_emerged_beliefs!(mem)
        catch e
            @warn "[BG] consolidate_emerged_beliefs: $e"
        end
    end

    # Belief decay
    for b in values(a.sbg.beliefs)
        baseline = 0.45 + b.rigidity * 0.25
        effective_dr = BELIEF_DECAY_RATE * (1.0 - b.rigidity * 0.8)
        b.confidence = clamp01(b.confidence + (baseline - b.confidence) * effective_dr)
    end
    _recompute_stability!(a.sbg)

    # Allostasis recovery
    a.interoception.allostatic_load =
        clamp01(a.interoception.allostatic_load - ALLOSTATIC_RECOVERY)
    a.sbg.epistemic_trust = clamp(a.sbg.epistemic_trust + 0.0008, 0.0, 0.85)

    # LatentBuffer decay
    a.latent_buffer.doubt = clamp01(a.latent_buffer.doubt - 0.003)
    a.latent_buffer.shame = clamp01(a.latent_buffer.shame - 0.002)
    a.latent_buffer.attachment = clamp01(a.latent_buffer.attachment - 0.002)
    a.latent_buffer.threat = clamp01(a.latent_buffer.threat - 0.003)
    decay_scars!(a.structural_scars)
    a.anchor.groundedness = clamp01(a.anchor.groundedness - 0.0005)

    # LatentBuffer → differentiated behavior between interactions
    _latent_pressure_effects!(a)

    # Model of the other → disclosure_threshold
    _other_model_effects!(a, mem)

    # Chronic cost → causal_ownership drift
    _chronic_cost_effects!(a)

    # Idle thought
    _idle_thought_maybe!(a, mem)

    # MAL: arbitration before initiative — which cycle currently has signal priority.
    # Transient, not persisted; carryover is updated internally.
    _slow_arb = compute_arbitration(a)
    _slow_loop_scores_str = join(
        ["$(k)=$(round(v, digits=3))" for (k, v) in sort(collect(_slow_arb.loop_scores), by = kv -> -kv[2])],
        ",",
    )
    _prev_mal_regime = isnothing(bg) ? :default : bg.last_mal_regime
    if _slow_arb.regime != _prev_mal_regime
        @info "[MAL] $(String(_prev_mal_regime)) → $(String(_slow_arb.regime)) " *
              "dominant=$(_slow_arb.dominant_loop) " *
              "score=$(round(_slow_arb.score, digits=2)) det=$(_slow_arb.determinant) " *
              "runner_up=$(_slow_arb.runner_up)($(round(_slow_arb.runner_up_score, digits=3))) " *
              "scores=[$(_slow_loop_scores_str)]"
        push_gui_event!("mal_regime_change", Dict(
            "from" => String(_prev_mal_regime), "to" => String(_slow_arb.regime),
            "dominant" => String(_slow_arb.dominant_loop), "score" => _slow_arb.score,
            "determinant" => string(_slow_arb.determinant),
            "runner_up" => string(_slow_arb.runner_up), "runner_up_score" => _slow_arb.runner_up_score,
            "scores" => _slow_loop_scores_str,
        ))
        !isnothing(bg) && (bg.last_mal_regime = _slow_arb.regime)
    else
        @debug "[MAL] $(String(_slow_arb.regime)) dominant=$(_slow_arb.dominant_loop) " *
               "scores=[$(_slow_loop_scores_str)]"
    end

    # Initiative without a stimulus: Anima can start the conversation herself
    _maybe_self_initiate!(a, mem, dialog_history, initiative_ch)

    # Psyche drift
    psyche_slow_tick!(a)

    # Dream generation
    if !isnothing(mem)
        try
            gap_now =
                a.temporal.gap_seconds +
                Float64(Dates.value(now() - unix2datetime(a.temporal.session_start))) /
                1000.0
            dream_rec = dream_flash!(
                a,
                mem,
                dialog_history,
                gap_now;
                shadow_registry = a.shadow_registry,
            )
            if !isnothing(dream_rec)
                save_dream!(dream_rec)
                @info "[DREAM] $(dream_rec.narrative)"
            end
        catch e
            @warn "[BG] dream_flash: $e"
        end
    end

    # Subjectivity: emerge beliefs (only on new events)
    if !isnothing(subj) && (a.flash_count != subj._emerged_cache_flash)
        try
            subj_emerge_beliefs!(subj, a.flash_count)
        catch e
            @warn "[BG] subj_emerge_beliefs: $e"
        end
    end

    # Crisis check
    vad_now = to_vad(a.nt)
    t_, _, _, c_ = to_reactors(a.nt)
    phi_now = compute_phi(
        a.iit,
        vad_now,
        t_,
        c_,
        a.sbg.attractor_stability,
        a.sbg.epistemic_trust,
        a.interoception.allostatic_load,
    )
    vfe_now = compute_vfe(a.gen_model, vad_now)
    new_coh = compute_coherence(a.sbg, a.blanket, vfe_now.vfe, phi_now)
    a.crisis.coherence = clamp01(a.crisis.coherence * 0.3 + new_coh * 0.7)

    target_mode =
        a.crisis.coherence > 0.6 ? INTEGRATED :
        a.crisis.coherence > 0.3 ? FRAGMENTED : DISINTEGRATED
    if target_mode != a.crisis.current_mode
        a.crisis.steps_in_mode += 1
        if a.crisis.steps_in_mode >= a.crisis.min_steps_before_transition
            a.crisis.current_mode = target_mode
            a.crisis.params = get_crisis_params(target_mode)
            a.crisis.steps_in_mode = 0
        end
    else
        a.crisis.steps_in_mode = 0
    end

    nothing
end

# --- Accumulated Drift (retrospective fallback) ---------------------------

"""
    apply_accumulated_drift!(a, mem)

Applies accumulated drift over gap_seconds if the background process isn't running.
An aggregated compound formula — more accurate than N individual ticks.
"""
function apply_accumulated_drift!(a::Anima, mem = nothing)
    gap = a.temporal.gap_seconds
    gap < 60.0 && return

    n_ticks = min(Int(floor(gap / SLOW_TICK_INTERVAL)), 480)
    n_ticks == 0 && return

    println("  [BG] Retrospective drift: $(round(gap/3600,digits=1))h = $n_ticks ticks")

    # NT decay (compound)
    rate = decay_rate(a.personality) * 0.3
    cpd = (1.0 - rate)^n_ticks
    a.nt.dopamine = clamp01(0.5 + (a.nt.dopamine - 0.5) * cpd)
    a.nt.serotonin = clamp01(0.5 + (a.nt.serotonin - 0.5) * cpd)
    a.nt.noradrenaline = clamp01(0.3 + (a.nt.noradrenaline - 0.3) * cpd)
    update_from_nt!(a.body, a.nt)

    # Memory→State
    if !isnothing(mem)
        try
            _refresh_cache!(mem)
            memory_nt_baseline!(mem, a.nt, a.flash_count)
            update_from_nt!(a.body, a.nt)
        catch e
            @warn "[BG] accumulated drift memory→state: $e"
        end
    end

    # Beliefs decay (compound)
    for b in values(a.sbg.beliefs)
        baseline = 0.45 + b.rigidity * 0.25
        dr = BELIEF_DECAY_RATE * (1.0 - b.rigidity * 0.8)
        cpd_b = (1.0 - dr)^n_ticks
        b.confidence = clamp01(baseline + (b.confidence - baseline) * cpd_b)
    end
    _recompute_stability!(a.sbg)

    a.interoception.allostatic_load =
        clamp01(a.interoception.allostatic_load - ALLOSTATIC_RECOVERY * n_ticks)
    a.sbg.epistemic_trust = clamp(a.sbg.epistemic_trust + 0.0008 * n_ticks, 0.0, 0.85)

    a.latent_buffer.doubt = clamp01(a.latent_buffer.doubt - 0.003 * n_ticks)
    a.latent_buffer.shame = clamp01(a.latent_buffer.shame - 0.002 * n_ticks)
    a.latent_buffer.attachment = clamp01(a.latent_buffer.attachment - 0.002 * n_ticks)
    a.latent_buffer.threat = clamp01(a.latent_buffer.threat - 0.003 * n_ticks)

    # Psyche drift
    _psyche_accumulated_drift!(a, n_ticks)

    println(
        "  [BG] Drift: D=$(round(a.nt.dopamine,digits=3)) S=$(round(a.nt.serotonin,digits=3)) N=$(round(a.nt.noradrenaline,digits=3))",
    )
end

"""
    _psyche_accumulated_drift!(a, n_ticks)

Applies accumulated psychic drift over n_ticks slow ticks (compound).
"""
function _psyche_accumulated_drift!(a::Anima, n_ticks::Int)
    n_ticks == 0 && return

    ca = a.chronified
    decay_ca = (1.0 - 0.0005)^n_ticks
    ca.resentment = max(0.0, ca.resentment * decay_ca)
    ca.alienation = max(0.0, ca.alienation * decay_ca)
    ca.bitterness = max(0.0, ca.bitterness * (1.0 - 0.0003)^n_ticks)
    ca.envy = max(0.0, ca.envy * (1.0 - 0.0004)^n_ticks)

    a.anticipatory.dread = max(0.0, a.anticipatory.dread - 0.002 * n_ticks)
    a.anticipatory.hope = max(0.0, a.anticipatory.hope - 0.002 * n_ticks)
    a.anticipatory.strength = clamp01(a.anticipatory.strength * (0.97)^n_ticks)

    a.shame.level = max(0.0, a.shame.level - 0.003 * n_ticks)
    a.shame.chronic = max(0.0, a.shame.chronic - 0.0008 * n_ticks)

    a.goal_conflict.tension = max(0.0, a.goal_conflict.tension - 0.008 * n_ticks)
    a.goal_conflict.tension < 0.05 && (a.goal_conflict.resolution = "none")

    a.fatigue.cognitive = max(0.0, a.fatigue.cognitive - 0.006 * n_ticks)
    a.fatigue.emotional = max(0.0, a.fatigue.emotional - 0.005 * n_ticks)
    a.fatigue.somatic = max(0.0, a.fatigue.somatic - 0.004 * n_ticks)

    sl = a.sig_layer
    base_sl = (
        self_preservation = 0.2,
        coherence_need = 0.3,
        contact_need = 0.3,
        truth_need = 0.4,
        autonomy_need = 0.3,
        novelty_need = 0.2,
    )
    cpd_sl = (1.0 - 0.008)^n_ticks
    sl.self_preservation = clamp01(
        base_sl.self_preservation +
        (sl.self_preservation - base_sl.self_preservation) * cpd_sl,
    )
    sl.coherence_need = clamp01(
        base_sl.coherence_need + (sl.coherence_need - base_sl.coherence_need) * cpd_sl,
    )
    sl.contact_need = clamp01(
        base_sl.contact_need +
        (sl.contact_need - base_sl.contact_need) * cpd_sl +
        0.003 * n_ticks,
    )
    sl.truth_need =
        clamp01(base_sl.truth_need + (sl.truth_need - base_sl.truth_need) * cpd_sl)
    sl.autonomy_need =
        clamp01(base_sl.autonomy_need + (sl.autonomy_need - base_sl.autonomy_need) * cpd_sl)
    sl.novelty_need =
        clamp01(base_sl.novelty_need + (sl.novelty_need - base_sl.novelty_need) * cpd_sl)

    # Cognitive hunger accumulates over time spent absent
    sl.ticks_since_novelty += n_ticks
    if sl.novelty_need > 0.65
        hunger_intensity = (sl.novelty_need - 0.65) / 0.35
        valence_drift = hunger_intensity * 0.008 * min(n_ticks, 30)
        a.nt.serotonin = clamp(a.nt.serotonin - valence_drift, 0.0, 1.0)
        a.nt.dopamine = clamp(a.nt.dopamine - valence_drift * 0.5, 0.0, 1.0)
    end

    # LatentBuffer → accumulated effect over n_ticks (compound, one-time)
    # The same causal chain as in slow_tick, but for the whole gap at once
    lb = a.latent_buffer
    effective_ticks = clamp(n_ticks, 1, 120)  # cap: no more than 2h of effect at a time
    if lb.doubt > 0.25
        total_d = (lb.doubt - 0.25) * 0.04 * effective_ticks
        a.agency.causal_ownership = clamp(a.agency.causal_ownership - total_d, 0.25, 1.0)
        a.agency.agency_confidence =
            clamp(a.agency.agency_confidence - total_d * 0.5, 0.25, 1.0)
    end
    if lb.shame > 0.25
        total_s = (lb.shame - 0.25) * 0.06 * effective_ticks
        a.inner_dialogue.disclosure_threshold =
            clamp(a.inner_dialogue.disclosure_threshold + total_s, 0.10, 0.90)
        a.inner_dialogue.disclosure_mode =
            a.inner_dialogue.disclosure_threshold < 0.30 ? :open :
            a.inner_dialogue.disclosure_threshold < 0.60 ? :guarded : :closed
    end
    if lb.attachment > 0.25
        total_a = (lb.attachment - 0.25) * 0.05 * effective_ticks
        a.sig_layer.contact_need = clamp01(a.sig_layer.contact_need + total_a)
    end
    if lb.threat > 0.25
        total_t = (lb.threat - 0.25) * 0.03 * effective_ticks
        a.sbg.epistemic_trust = clamp(a.sbg.epistemic_trust - total_t, 0.0, 0.85)
        a.nt.noradrenaline = clamp(a.nt.noradrenaline + total_t * 0.5, 0.0, 1.0)
    end

    # Time between sessions as its own thing: curiosity ripens, resistance accumulates
    # Honestly — time doesn't just pass, it does something inside
    if n_ticks >= 180  # ~3h minimum
        gap_hours = n_ticks * SLOW_TICK_INTERVAL / 3600.0

        # Curiosity objects ripen — an unclosed question becomes sharper
        for obj in a.curiosity_registry.objects
            obj.resolved && continue
            ripening = clamp(gap_hours * 0.015, 0.0, 0.12)
            obj.intensity = clamp(obj.intensity + ripening, 0.0, 1.0)
        end
        !isempty(a.curiosity_registry.objects) &&
            any(o -> !o.resolved, a.curiosity_registry.objects) &&
            @info "[GAP] Curiosity ripened over $(round(gap_hours, digits=1))h"

        # Resistance accumulates if there are unresolved belief conflicts
        if lb.resistance > 0.05
            res_growth = clamp(lb.resistance * 0.04 * min(gap_hours, 24.0), 0.0, 0.08)
            lb.resistance = clamp01(lb.resistance + res_growth)
        end
    end

    nothing
end

# --- Atomic Write + Background Save ------------------------------------

function atomic_write(path::String, data)
    tmp = "$(path).tmp.$(getpid()).$(Threads.threadid())"
    mkpath(dirname(tmp))
    open(tmp, "w") do f
        ;
        JSON3.write(f, data);
    end
    try
        mv(tmp, path; force = true)
    catch e
        # ENOENT: tmp disappeared between creation and rename — another process/thread
        # already grabbed the same path. Retry the write once before
        # giving up — a rare race, not a critical state error.
        if e isa Base.IOError
            try
                open(tmp, "w") do f
                    ;
                    JSON3.write(f, data);
                end
                mv(tmp, path; force = true)
            catch e2
                @warn "[ATOMIC_WRITE] retry failed for $(path): $e2"
            end
        else
            rethrow(e)
        end
    end
end

function background_save!(a::Anima)
    core_data = Dict(
        "version" => "anima_v13_core",
        "created_at" => a.core_mem.created_at,
        "total_flashes" => a.flash_count,
        "sessions" => a.core_mem.sessions,
        "personality" => personality_to_dict(a.personality),
        "temporal_orientation" => to_to_json(a.temporal),
        "generative_model" => gm_to_json(a.gen_model),
        "homeostatic_goals" => hg_to_json(a.homeostasis),
        "heartbeat" => hb_to_json(a.heartbeat),
        "interoception" => intero_to_json(a.interoception),
        "existential_anchor" => anchor_to_json(a.anchor),
    )
    atomic_write(a.core_mem.filepath, core_data)

    self_path = anima_state_file(a.psyche_mem_path, "self")
    self_data = Dict(
        "sbg" => sbg_to_json(a.sbg),
        "spm" => spm_to_json(a.spm),
        "agency" => al_to_json(a.agency),
        "isc" => isc_to_json(a.isc),
        "crisis" => crisis_to_json(a.crisis),
        "unknown_register" => ur_to_json(a.unknown_register),
        "authenticity_monitor" => am_to_json(a.authenticity_monitor),
    )
    atomic_write(self_path, self_data)

    lb_path = anima_state_file(a.psyche_mem_path, "latent")
    atomic_write(
        lb_path,
        Dict(
            "latent_buffer" => lb_to_json(a.latent_buffer),
            "structural_scars" => scars_to_json(a.structural_scars),
        ),
    )

    psyche_data = Dict(
        "narrative_gravity" => ng_to_json(a.narrative_gravity),
        "anticipatory" => ac_to_json(a.anticipatory),
        "solomonoff" => solom_to_json(a.solomonoff),
        "shame" => shame_to_json(a.shame),
        "epistemic" => ep_to_json(a.epistemic_defense),
        "chronified" => ca_to_json(a.chronified),
        "significance" => sig_to_json(a.significance),
        "moral" => mc_to_json(a.moral),
        "fatigue" => Dict(
            "c"=>a.fatigue.cognitive,
            "e"=>a.fatigue.emotional,
            "s"=>a.fatigue.somatic,
        ),
        "significance_layer" => sl_to_json(a.sig_layer),
        "goal_conflict" => gc_to_json(a.goal_conflict),
        "latent_buffer" => lb_to_json(a.latent_buffer),
        "structural_scars" => scars_to_json(a.structural_scars),
        "shadow_registry" => sr_to_json(a.shadow_registry),
        "inner_dialogue" => id_to_json(a.inner_dialogue),
        "curiosity_registry" => cr_to_json(a.curiosity_registry),
        "aesthetic_sense" => as_to_json(a.aesthetic_sense),
        "attention_focus" => af_to_json(a.attention_focus),
    )
    atomic_write(a.psyche_mem_path, psyche_data)
end

# --- Background Tick -------------------------------------------------------

function background_tick!(a::Anima, bg::BackgroundHandle)
    tick_heartbeat!(a.heartbeat, a.nt)
    bg.tick_count += 1

    spontaneous_drift!(a)

    dt = heartbeat_dt(a)

    did_slow = false
    now_t = time()
    if now_t - bg.last_slow_tick >= SLOW_TICK_INTERVAL
        slow_tick!(a, bg.mem, bg.subj, bg.dialog_history[], bg.initiative_channel, bg)
        background_save!(a)
        bg.last_slow_tick = now_t
        bg.slow_tick_count += 1
        did_slow = true
    end

    (
        did_slow = did_slow,
        sleep_s = dt,
        tick_count = bg.tick_count,
        slow_tick_count = bg.slow_tick_count,
    )
end

# --- Start / Stop / Status ------------------------------------------------

"""
    start_background!(a; mem=nothing, verbose=false) → BackgroundHandle
"""
function start_background!(
    a::Anima;
    mem = nothing,
    subj = nothing,
    dialog_history::Vector = Dict[],
    verbose::Bool = false,
)::BackgroundHandle
    now_t = time()
    bg = BackgroundHandle(
        Threads.Atomic{Bool}(false),
        Task(nothing),
        now_t,
        now_t,
        0,
        0,
        mem,
        subj,
        Ref{Vector}(dialog_history),
        Channel{Any}(4),
        :default,
    )

    task = Threads.@spawn begin
        mem_label =
            isnothing(bg.mem) ? "without memory" :
            isnothing(bg.subj) ? "with SQLite memory" : "with memory + subjectivity"
        println(
            "  [BG] Started ($mem_label). BPM=$(round(60000.0/a.heartbeat.period_ms,digits=1))",
        )

        # session_intent — load what Anima carried between sessions
        _intent_path = anima_state_file(a.psyche_mem_path, "session_intent")
        if isfile(_intent_path)
            try
                _intent = JSON3.read(read(_intent_path, String), Dict{String,Any})
                _itype   = get(_intent, "type", "")
                _ilabel  = get(_intent, "label", "")
                _isignal = Float64(get(_intent, "signal", 0.0))
                @info "[SESSION_INTENT] carrying $_itype: \"$_ilabel\" (signal=$(round(_isignal, digits=2)))"
                # NT shift depending on type
                if _itype == "curiosity"
                    a.nt.dopamine     = clamp(a.nt.dopamine + _isignal * 0.08, 0.0, 1.0)
                    a.nt.noradrenaline = clamp(a.nt.noradrenaline + _isignal * 0.04, 0.0, 1.0)
                    # AttentionFocus — if there's a matching curiosity object
                    _co = top_curiosity(a.curiosity_registry)
                    if !isnothing(_co) && _co.label == _ilabel
                        a.attention_focus.dominant = FocusObject(:curiosity, _co.label, _co.intensity, 0)
                    end
                elseif _itype == "goal_conflict"
                    a.nt.noradrenaline = clamp(a.nt.noradrenaline + _isignal * 0.07, 0.0, 1.0)
                    a.nt.serotonin     = clamp(a.nt.serotonin - _isignal * 0.04, 0.0, 1.0)
                elseif _itype == "latent_pressure"
                    a.nt.noradrenaline = clamp(a.nt.noradrenaline + _isignal * 0.06, 0.0, 1.0)
                end
                # formed_thought: a thought that matured between sessions → initiative when gap > 2h
                _fthought = get(_intent, "formed_thought", "")
                _gap_ok = a.temporal.gap_seconds > 7200.0
                if !isempty(_fthought) && _gap_ok && !isnothing(bg.initiative_channel)
                    inner = build_inner_voice(a.body, a.nt, Int(a.crisis.current_mode), 0.5, a.flash_count)
                    signal = (
                        inner_voice   = inner * " — " * _fthought,
                        dominant      = :gap_thought,
                        pressure      = 0.0,
                        contact       = 0.0,
                        gc_tension    = 0.0,
                        is_impulse    = false,
                        novelty_need  = 0.0,
                        curiosity_label = _ilabel,
                    )
                    isready(bg.initiative_channel) || put!(bg.initiative_channel, signal)
                @info "[GAP_THOUGHT] matured thought: \"$_fthought\""
                end
                rm(_intent_path)  # applied — remove it so it isn't applied twice
            catch e
                @warn "[SESSION_INTENT] load error: $e"
            end
        end

        while !bg.stop_signal[]
            try
                result = background_tick!(a, bg)

                if verbose && result.did_slow
                    @printf(
                        "  [BG] slow#%d | BPM=%.1f HRV=%.3f | D=%.3f S=%.3f N=%.3f | coh=%.3f\n",
                        result.slow_tick_count,
                        60000.0/a.heartbeat.period_ms,
                        a.heartbeat.hrv,
                        a.nt.dopamine,
                        a.nt.serotonin,
                        a.nt.noradrenaline,
                        a.crisis.coherence
                    )
                end

                sleep(result.sleep_s)
            catch e
                @warn "[BG] error: $e"
                sleep(1.0)
            end
        end

        println(
            "  [BG] Stopped. Ticks: $(bg.tick_count), slow: $(bg.slow_tick_count).",
        )
    end

    bg.task = task
    bg
end

function stop_background!(bg::BackgroundHandle)
    bg.stop_signal[] = true
    try
        timedwait(() -> istaskdone(bg.task), 3.0)
    catch
    end
    println("  [BG] Stopped.")
end

function bg_status(bg::BackgroundHandle, a::Anima)
    running = !bg.stop_signal[] && !istaskdone(bg.task)
    uptime = round((time() - bg.started_at) / 60.0, digits = 1)
    println("\n  [BG] $(running ? "✓ active" : "✗ stopped") | Uptime: $(uptime)min")
    println("  [BG] Ticks: $(bg.tick_count) | Slow: $(bg.slow_tick_count)")
    println(
        "  [BG] ♥ BPM=$(round(60000.0/a.heartbeat.period_ms,digits=1)) HRV=$(round(a.heartbeat.hrv,digits=3)) coh=$(round(a.crisis.coherence,digits=3))",
    )
    println(
        "  [BG] NT: D=$(round(a.nt.dopamine,digits=3)) S=$(round(a.nt.serotonin,digits=3)) N=$(round(a.nt.noradrenaline,digits=3))",
    )
    println(
        "  [BG] Allostatic=$(round(a.interoception.allostatic_load,digits=3)) mem=$(isnothing(bg.mem) ? "—" : "SQLite ✓")",
    )
    println()
end

# --- REPL with the background process ----------------------------------------------

const _REPL_RUNNING = Threads.Atomic{Bool}(false)

# Global references to REPL state — for invoking commands from the HTTP server
const _GUI_ANIMA  = Ref{Any}(nothing)
const _GUI_BG     = Ref{Any}(nothing)
const _GUI_MEM    = Ref{Any}(nothing)
const _GUI_SUBJ   = Ref{Any}(nothing)

"""
    execute_gui_cmd(cmd) -> String

Execute a terminal command (`:bg`, `:memory`, ...) and return the output as a string.
Called directly from the HTTP server, bypassing input_queue and the LLM cycle.
"""
function execute_gui_cmd(cmd::String)::String
    a    = _GUI_ANIMA[]
    bg   = _GUI_BG[]
    mem  = _GUI_MEM[]
    subj = _GUI_SUBJ[]
    isnothing(a) && return "[GUI_CMD] REPL not started yet."

    io = IOBuffer()
    try
        if cmd == ":bg"
            running = !bg.stop_signal[]
            uptime  = round((time() - bg.started_at) / 60.0, digits = 1)
            println(io, "\n  [BG] $(running ? "✓ active" : "✗ stopped") | Uptime: $(uptime)min")
            println(io, "  [BG] Ticks: $(bg.tick_count) | Slow: $(bg.slow_tick_count)")
            println(io, "  [BG] ♥ BPM=$(round(60000.0/a.heartbeat.period_ms,digits=1)) HRV=$(round(a.heartbeat.hrv,digits=3)) coh=$(round(a.crisis.coherence,digits=3))")
            println(io, "  [BG] NT: D=$(round(a.nt.dopamine,digits=3)) S=$(round(a.nt.serotonin,digits=3)) N=$(round(a.nt.noradrenaline,digits=3))")
            println(io, "  [BG] Allostatic=$(round(a.interoception.allostatic_load,digits=3)) mem=$(isnothing(bg.mem) ? "—" : "SQLite ✓")")
        elseif cmd == ":memory"
            if isnothing(mem)
                println(io, "  [MEM] Memory not connected.")
            else
                snap = memory_snapshot(mem)
                println(io, "\n  [MEM] Episodic=$(snap.episodic_count) Semantic=$(snap.semantic_count)")
                println(io, "  [MEM] Stress=$(snap.stress) Anxiety=$(snap.anxiety) Motivation=$(snap.motivation)")
                println(io, "  [MEM] Instability=$(snap.instability) Fragility=$(snap.fragility)")
                println(io, "  [MEM] Latent pressure=$(snap.latent_pressure)")
                isempty(snap.affect_note) || println(io, "  [MEM] $(snap.affect_note)")
            end
        elseif cmd == ":subj"
            if isnothing(subj)
                println(io, "  [SUBJ] Subjectivity not connected.")
            else
                snap = subj_snapshot(subj)
                println(io, "\n  [SUBJ] Emerged beliefs=$(snap.emerged_beliefs) | Candidates=$(snap.pattern_candidates) | Stances=$(snap.stances)")
                isempty(snap.top_beliefs)     || println(io, "  [SUBJ] Beliefs: $(snap.top_beliefs)")
                isempty(snap.dominant_stance) || println(io, "  [SUBJ] Dominant stance: $(snap.dominant_stance)")
                println(io, "  [SUBJ] Surprise=$(snap.surprise_level) | Lens=$(isempty(snap.current_lens) ? "neutral" : snap.current_lens)")
                println(io, "  [SUBJ] Active prediction: $(snap.active_prediction ? "yes" : "no")")
            end
        elseif cmd == ":state"
            snap = nt_snapshot(a.nt)
            vad  = to_vad(a.nt)
            t_, _, _, c_ = to_reactors(a.nt)
            phi  = compute_phi(a.iit, vad, t_, c_, a.sbg.attractor_stability,
                               a.sbg.epistemic_trust, a.interoception.allostatic_load)
            println(io, "\n  NT: D=$(snap.dopamine) S=$(snap.serotonin) N=$(snap.noradrenaline) → $(snap.levheim_state)")
            println(io, "  ♥ $(round(60000.0/a.heartbeat.period_ms,digits=1))bpm HRV=$(round(a.heartbeat.hrv,digits=3)) coh=$(round(a.crisis.coherence,digits=3))")
            println(io, "  Body: $(build_inner_voice(a.body, a.nt, Int(a.crisis.current_mode), phi, a.flash_count))")
            println(io, "  Attention: $(a.attention.focus) | Shame=$(round(a.shame.level,digits=3)) Continuity=$(round(a.anchor.continuity,digits=3))")
            println(io, "  SelfRelation: sd=$(round(a.agency.self_discomfort,digits=3)) sc=$(round(a.agency.self_coherence,digits=3))")
        elseif cmd == ":vfe"
            vad = to_vad(a.nt)
            v   = compute_vfe(a.gen_model, vad)
            pol = select_policy(a.gen_model, vad)
            println(io, "\n  VFE=$(v.vfe) acc=$(v.accuracy) cplx=$(v.complexity) | $(vfe_note(v.vfe))")
            println(io, "  Drive=$(pol.drive) EFE_act=$(pol.efe_action) EFE_perc=$(pol.efe_perception)")
        elseif cmd == ":blanket"
            bs = blanket_snapshot(a.blanket)
            println(io, "\n  Sensory=$(bs.sensory)")
            println(io, "  Internal=$(bs.internal)")
            println(io, "  Integrity=$(bs.integrity)")
        elseif cmd == ":hb"
            hb = a.heartbeat
            println(io, "\n  ♥ BPM=$(round(60000.0/hb.period_ms,digits=1)) HRV=$(round(hb.hrv,digits=3))")
            println(io, "  Symp=$(round(hb.sympathetic_tone,digits=3)) Parasymp=$(round(hb.parasympathetic_tone,digits=3))")
            println(io, "  coh=$(round(a.crisis.coherence,digits=3)) | Beats: $(hb.beat_count)")
        elseif cmd == ":gravity"
            f = compute_field(a.narrative_gravity, a.flash_count)
            println(io, "\n  Gravity total=$(f.total) valence=$(f.valence)")
            println(io, "  $(f.note)")
        elseif cmd == ":anchor"
            ea = a.anchor
            println(io, "\n  Continuity=$(round(ea.continuity,digits=3)) Groundedness=$(round(ea.groundedness,digits=3))")
            println(io, "  Last self: $(ea.last_self)")
        elseif cmd == ":solom"
            s = solom_snapshot(a.solomonoff)
            println(io, "\n  $(s.insight) | Complexity=$(s.complexity)")
        elseif cmd == ":self"
            sbg = a.sbg
            println(io, "\n  Self ($(length(sbg.beliefs)) beliefs) | Stability=$(round(sbg.attractor_stability,digits=3)) Trust=$(round(sbg.epistemic_trust,digits=3))")
            for (name, b) in sort(collect(sbg.beliefs), by = kv -> -kv[2].centrality)
                st = b.confidence < 0.15 ? "X" : b.confidence < 0.35 ? "!" : "v"
                print(io, @sprintf("    [%s] %-30s conf=%.2f central=%.2f rigid=%.2f\n",
                        st, name, b.confidence, b.centrality, b.rigidity))
            end
            println(io, "  $(derive_narrative(sbg))")
        elseif cmd == ":crisis"
            cs = crisis_snapshot(a.crisis, a.flash_count)
            println(io, "\n  Mode: $(cs.mode_name) | Coherence=$(cs.coherence)")
            println(io, "  $(cs.note)")
        elseif cmd == ":ablation"
            af = a.ablation
            println(io, "\n  [ABLATION] $(ablation_summary(af))")
            println(io, "  memory=$(af.use_memory) sbg=$(af.use_sbg) agency=$(af.use_agency) latent=$(af.use_latent) body=$(af.use_body) state_prompt=$(af.use_state_prompt)")
            println(io, "  Switching only via ENV at startup (ANIMA_ABLATE_*) — runtime toggle not implemented.")
        elseif cmd == ":curiosity"
            objs = active_curiosities(a.curiosity_registry)
            if isempty(objs)
                println(io, "\n  [CURIOSITY] No active objects.")
            else
                println(io, "\n  [CURIOSITY] Active: $(length(objs))")
                for co in objs
                    println(io, "  · $(co.label) | intensity=$(round(co.intensity,digits=2)) val=$(round(co.valence,digits=2)) activations=$(co.activation_count) origin=$(co.origin)")
                end
            end
        elseif cmd == ":dreams"
            log = load_dream_log()
            recent = isempty(log) ? [] : log[max(1,length(log)-4):end]
            if isempty(recent)
                println(io, "\n  [DREAM] No dreams yet.")
            else
                println(io, "\n  [DREAM] Last $(length(recent)) dreams:")
                for d in recent
                    narr  = get(d, "narrative", "—")
                    src   = get(d, "source", "")
                    phi   = get(d, "phi", 0.0)
                    label = get(d, "emotion_label", "")
                    tod   = get(d, "time_of_day", "")
                    println(io, "  ──────────────────────────────────────────────")
                    println(io, "  [DREAM | $tod | φ=$(round(Float64(phi),digits=2)) | $label]")
                    println(io, "  $(first(string(narr), 120))")
                    isempty(string(src)) || println(io, "  Source: $(first(string(src), 80))")
                end
            end
        elseif cmd == ":audit"
            if isnothing(mem)
                println(io, "  [AUDIT] Memory not connected.")
            else
                s = audit_summary(mem.db; last_n = 20)
                if s.n == 0
                    println(io, "  [AUDIT] No data yet.")
                else
                    println(io, "\n  [AUDIT] Last $(s.n) flashes:")
                    println(io, "  score=$(s.avg_score)  causal=$(s.causal_rate)  mem_dep=$(s.memory_dep_rate)")
                    println(io, "  stake=$(s.stake_rate)  irrev=$(s.irreversible_rate)  recognized=$(s.recognized_rate)")
                    println(io, "  → $(s.note)")
                end
            end
        else
            println(io, "  [GUI_CMD] Unknown command: $cmd")
        end
    catch e
        println(io, "  [GUI_CMD] error: $e\n  $(sprint(showerror, e))")
    end
    return String(take!(io))
end

"""
    repl_with_background!(a; mem=nothing, bg_verbose=false, kwargs...)

REPL with the background process and optional SQLite memory.
"""
function repl_with_background!(
    a::Anima;
    mem = nothing,
    subj = nothing,
    bg_verbose::Bool = false,
    kwargs...,
)
    if a.temporal.gap_seconds > 60.0
        println("  [BG] Drift over $(round(a.temporal.gap_seconds/3600,digits=1))h...")
        apply_accumulated_drift!(a, mem)
        try
            update_blanket!(
                a.blanket,
                a.nt.noradrenaline,
                a.nt.dopamine,
                a.nt.serotonin,
                a.interoception.allostatic_load,
            )
            _phi_after_drift =
                clamp(a.nt.dopamine * 0.4 + a.nt.serotonin * 0.4 + 0.2, 0.3, 0.8)
            update_crisis!(
                a.crisis,
                a.sbg,
                a.blanket,
                0.05,              # vfe — near zero after drift
                _phi_after_drift,  # phi approximation
                0.2,               # self_pred_error — neutral
                a.flash_count,
            )
        catch e
            @warn "[BG] crisis recompute after drift: $e"
        end
    end

    # Temporal depth of experience
    if _REPL_RUNNING[]
        @warn "[REPL] Attempt to start a second REPL — already running. Exit the first one or restart Julia."
        return
    end
    _REPL_RUNNING[] = true

    let gap = a.temporal.gap_seconds
        if gap > 0.0
            mem_unc =
                !isnothing(mem) ?
                Float64(get(mem._affect_cache, "memory_uncertainty", 0.3)) : 0.3
            subjective_gap = gap * (1.0 + mem_unc * 0.5)

            if subjective_gap > 3600.0
                disorientation = clamp((subjective_gap - 3600.0) / 86400.0, 0.0, 0.4)
                a.nt.noradrenaline =
                    clamp(a.nt.noradrenaline + disorientation * 0.25, 0.0, 1.0)
                a.sbg.epistemic_trust =
                    clamp(a.sbg.epistemic_trust - disorientation * 0.15, 0.0, 1.0)
                disorientation > 0.1 && println(
                    "  [TEMPORAL] Subjective time: $(round(subjective_gap/3600, digits=1))h. Disorientation=$(round(disorientation,digits=2)).",
                )
            elseif subjective_gap < 600.0 && gap > 10.0
                continuity = clamp((600.0 - subjective_gap) / 600.0, 0.0, 0.3)
                a.sbg.epistemic_trust =
                    clamp(a.sbg.epistemic_trust + continuity * 0.08, 0.0, 1.0)
                a.nt.serotonin = clamp(a.nt.serotonin + continuity * 0.05, 0.0, 1.0)
            end
        end
    end

    # Trace of the last dream upon waking
    # nt_delta already contains DREAM_NT_SCALE×0.25 from the moment of the dream.
    # On startup we apply ×0.5 — a residual imprint, weaker than the dream itself.
    let dream_log = load_dream_log()
        if !isempty(dream_log) && a.temporal.gap_seconds >= DREAM_GAP_MIN
            last_dream = dream_log[end]
            raw_delta = get(last_dream, "nt_delta", nothing)
            if !isnothing(raw_delta) && length(raw_delta) == 3
                try
                    dd = Float64(raw_delta[1]) * 0.5
                    sd = Float64(raw_delta[2]) * 0.5
                    nd = Float64(raw_delta[3]) * 0.5
                    a.nt.dopamine      = clamp01(a.nt.dopamine      + dd)
                    a.nt.serotonin     = clamp01(a.nt.serotonin     + sd)
                    a.nt.noradrenaline = clamp01(a.nt.noradrenaline + nd)
                    update_from_nt!(a.body, a.nt)
                    println("  [DREAM] Dream trace: ΔD=$(round(dd,digits=3)) ΔS=$(round(sd,digits=3)) ΔN=$(round(nd,digits=3))")
                catch e
                    @warn "[DREAM] Failed to apply dream trace: $e"
                end
            end
        end
    end

    dialog_path = anima_state_file(a.psyche_mem_path, "dialog")
    history = dialog_load(dialog_path)
    !isempty(history) && println("  [DIALOG] Loaded $(length(history)) lines.\n")

    _bg_queue = Channel{String}(64)
    Core.eval(Main, :(bg_log(msg::String) = put!($_bg_queue, msg)))

    bg = start_background!(
        a;
        mem = mem,
        subj = subj,
        dialog_history = history,
        verbose = bg_verbose,
    )

    # register for HTTP /api/cmd
    _GUI_ANIMA[] = a
    _GUI_BG[]    = bg
    _GUI_MEM[]   = mem
    _GUI_SUBJ[]  = subj

    println("\n" * "═"^70)
    println("  🌀 A N I M A — REPL")
    subj_label = !isnothing(subj) ? " | 🧬 subjectivity" : ""
    println("  ❤️ heart beating$(isnothing(mem) ? "" : " | 🧠 memory active")$subj_label")
    println(
        "  :bg :bgstop :bgstart :memory :subj :state :vfe :self :crisis :hb :gravity :anchor :solom :dreams :history :clearhist :audit :quit",
    )
    println("═"^70 * "\n")

    use_llm = get(kwargs, :use_llm, false)
    llm_url = get(kwargs, :llm_url, "https://openrouter.ai/api/v1/chat/completions")
    llm_model = get(kwargs, :llm_model, "openai/gpt-oss-120b:free")
    llm_key = get(kwargs, :llm_key, get(ENV, "OPENROUTER_API_KEY", ""))
    is_ollama = get(kwargs, :is_ollama, false)
    use_input_llm = get(kwargs, :use_input_llm, false)
    input_llm_model = get(kwargs, :input_llm_model, "openai/gpt-oss-120b:free")
    input_llm_key = get(
        kwargs,
        :input_llm_key,
        get(ENV, "OPENROUTER_API_KEY_INPUT", get(ENV, "OPENROUTER_API_KEY", "")),
    )

    pending_llm = nothing
    pending_user_msg = ""
    pending_is_initiative = false
    _last_r = nothing           # result of the last experience! for the audit
    _last_had_ignition = false  # whether ignition fired on the last flash
    _progress_target_prev = ""  # label of top_curiosity from the previous flash (Curiosity Closure)

    gui_server = nothing
    try
        # Single input entry point: the terminal and the web interface both put lines into one channel,
        # the main loop doesn't care where the line came from.
        _input_queue = Channel{String}(64)
        _terminal_reader = @async begin
            while _REPL_RUNNING[]
                try
                    print("You> ")
                    line = readline()
                    put!(_input_queue, line)
                catch
                    break
                end
            end
        end
        gui_reset_session!()
        gui_server = start_gui_server!(_input_queue; port = 8088)
        println("  [GUI] Web interface: http://127.0.0.1:8088\n")

        while true
            if !isnothing(pending_llm) && isready(pending_llm)
                llm_reply = take!(pending_llm)
                if pending_is_initiative
                    println("\nAnima> $llm_reply\n")
                else
                    println("\nAnima [LLM]> $llm_reply\n")
                end
                push_gui_chat!("llm", llm_reply;
                    flash = a.flash_count,
                    meta = Dict("initiative" => pending_is_initiative))
                if !startswith(llm_reply, "[LLM error")
                    # Anima hears her own words — not analysis, but experience
                    self_hear!(a, llm_reply)
                    # Causal ownership: coherence between the NT state and what was said
                    # counted before endorsement — endorsement judges this line, not the average
                    cf_raw = text_to_stimulus(llm_reply)
                    cf_co = compute_causal_ownership(a.nt, cf_raw)
                    if !pending_is_initiative
                        a.agency.causal_ownership = clamp(
                            a.agency.causal_ownership * 0.85 + cf_co * 0.15,
                            0.0, 1.0,
                        )
                        if !isnothing(bg.mem)
                            try
                                update_episodic_causal_ownership!(bg.mem, a.flash_count, cf_co)
                            catch e
                                @warn "[CF] memory update: $e"
                            end
                        end
                        @info "[CF] co=$(round(cf_co,digits=3)) agency_co=$(round(a.agency.causal_ownership,digits=3)) flash=$(a.flash_count)"
                        push_gui_event!("cf", Dict(
                            "co" => cf_co, "agency_co" => Float64(a.agency.causal_ownership),
                            "flash" => a.flash_count,
                        ))
                    end
                    # Endorsement: were these words really mine?
                    a.last_endorsement = evaluate_endorsement(a, llm_reply, cf_co)
                    if !isnothing(bg.mem) && a.last_endorsement != :automatic
                        try
                            update_episodic_endorsement!(bg.mem, a.flash_count, String(a.last_endorsement))
                            @info "[ENDORSE] $(a.last_endorsement) flash=$(a.flash_count) co=$(round(cf_co,digits=2))"
                        catch e
                            @warn "[ENDORSE] $e"
                        end
                    end
                    # SubjectivityAudit: technical tribunal — was the state actually causal
                    _audit = nothing
                    if !isnothing(bg.mem) && !isnothing(_last_r)
                        try
                            _audit = compute_audit(
                                a, _last_r;
                                had_ignition      = _last_had_ignition,
                                had_mem_resonance = _last_had_ignition,
                            )
                            save_audit!(bg.mem.db, _audit)
                            @info "[AUDIT] score=$(round(_audit.audit_score,digits=2)) co=$(round(_audit.causal_ownership,digits=2)) endorsed=$(_audit.endorsed)"
                            push_gui_event!("audit", Dict(
                                "score" => _audit.audit_score, "co" => _audit.causal_ownership,
                                "endorsed" => string(_audit.endorsed), "flash" => a.flash_count,
                            ))
                            write_gui_state!(a, _last_r; audit = _audit, cf_co = cf_co)
                        catch e
                            @warn "[AUDIT] $e"
                        end
                    end
                    # Curiosity Closure Signal (v1): Curiosity → Behavior → Endorsement
                    # → Progress → Curiosity Update.
                    # progress_signal = endorsed && active_curiosity && causal_necessary
                    # ("genuine engagement": not just fitting, but the state itself took part)
                    _progress_signal = false
                    _progress_target = ""
                    _churn = false
                    _top_co_now = top_curiosity_any(a.curiosity_registry)
                    if is_progress_eligible(_top_co_now)
                        _endorsed_ok = a.last_endorsement == :endorsed
                        _causal_necessary = !isnothing(_audit) && _audit.causal_necessary
                        _progress_target = _top_co_now.label
                        if _endorsed_ok && _causal_necessary
                            _progress_signal = true
                            apply_progress!(_top_co_now)
                            @info "[CURIOSITY_PROGRESS] \"$(_progress_target)\" intensity→$(round(_top_co_now.intensity,digits=3)) consecutive=$(_top_co_now.consecutive_progress)"
                            push_gui_event!("curiosity_progress", Dict(
                                "label"       => _progress_target,
                                "intensity"   => Float64(_top_co_now.intensity),
                                "consecutive" => Int(_top_co_now.consecutive_progress),
                            ))
                        elseif !isempty(_progress_target_prev) && _top_co_now.label != _progress_target_prev
                            _churn = true
                            apply_churn!(_top_co_now)
                            @info "[CURIOSITY_CHURN] \"$(_progress_target_prev)\" → \"$(_progress_target)\""
                            push_gui_event!("curiosity_churn", Dict(
                                "label"     => _progress_target_prev,
                                "new_label" => _progress_target,
                            ))
                        end
                        _progress_target_prev = _top_co_now.label
                    else
                        _progress_target_prev = ""
                    end
                    # Contact Satiation Signal: endorsed contact lowers contact_need.
                    # Symmetric to Curiosity Closure — the loop closes.
                    # Condition: endorsed (not automatic) + contact_need above baseline.
                    if a.last_endorsement == :endorsed && a.sig_layer.contact_need > 0.5
                        _before = a.sig_layer.contact_need
                        a.sig_layer.contact_need = clamp01(a.sig_layer.contact_need - 0.08)
                        @info "[CONTACT_SAT] contact_need $(round(_before,digits=2)) → $(round(a.sig_layer.contact_need,digits=2))"
                        push_gui_event!("contact_sat", Dict(
                            "contact_need" => Float64(a.sig_layer.contact_need),
                        ))
                    end

                    # Active Theory of Mind: evaluate → resolve → generate.
                    # Runs after every flash regardless of episode weight —
                    # hypotheses about the other live at session level, not per episode.
                    if !isnothing(bg.mem)
                        try
                            _tom_active = get_active_hypotheses(bg.mem)
                            # Read the current signals from other_model once
                            _tom_pressure_rows = Tables.rowtable(DBInterface.execute(
                                bg.mem.db,
                                "SELECT count FROM other_model WHERE key='pressure_events' LIMIT 1",
                            ))
                            _tom_open_rows = Tables.rowtable(DBInterface.execute(
                                bg.mem.db,
                                "SELECT count FROM other_model WHERE key='open_exchanges' LIMIT 1",
                            ))
                            _tom_pressure = isempty(_tom_pressure_rows) ? 0 : Int(_tom_pressure_rows[1].count)
                            _tom_open_ex  = isempty(_tom_open_rows)     ? 0 : Int(_tom_open_rows[1].count)

                            # Evaluate + resolve active hypotheses
                            # get_active_hypotheses returns Vector{NamedTuple} — fields via .field
                            for h in _tom_active
                                qt    = String(h.query_type)
                                conf  = Float64(h.confidence)
                                label = String(h.label)
                                hid   = Int(h.id)
                                outcome_val = 0.0
                                outcome_str = "unknown"

                                if qt == "SOCIAL"
                                    # Outcome: share of open exchanges, not an absolute counter.
                                    # Absolute thresholds degrade over time — after a month pressure is always > 3.
                                    _tom_total = _tom_open_ex + _tom_pressure
                                    _tom_ratio = _tom_open_ex / max(1, _tom_total)
                                    if _tom_ratio >= 0.80
                                        outcome_val = 1.0
                                        outcome_str = "open"
                                    elseif _tom_ratio >= 0.60
                                        outcome_val = 0.5
                                        outcome_str = "uncertain"
                                    else
                                        outcome_val = 0.0
                                        outcome_str = "not_open"
                                    end
                                elseif qt == "PREDICTION"
                                    # TEMP: outcome via internal tension as a proxy for pressure.
                                    # Replace with prediction-specific baseline outcome in Phase 2
                                    # (e.g. compare pressure_events count vs baseline at generation time).
                                    if Float64(a.goal_conflict.tension) > 0.55
                                        outcome_val = 1.0
                                        outcome_str = "high_tension"
                                    else
                                        outcome_val = 0.0
                                        outcome_str = "low_tension"
                                    end
                                elseif qt == "VALUE"
                                    # Outcome: the topic actually recurred >= 2 times in other_model
                                    _tom_topic_rows = Tables.rowtable(DBInterface.execute(
                                        bg.mem.db,
                                        "SELECT count FROM other_model WHERE key=? LIMIT 1",
                                        [String(h.predicted_state)],
                                    ))
                                    _tom_topic_count = isempty(_tom_topic_rows) ? 0 : Int(_tom_topic_rows[1].count)
                                    if _tom_topic_count >= 2
                                        outcome_val = 1.0
                                        outcome_str = "recurred"
                                    else
                                        outcome_val = 0.0
                                        outcome_str = "not_recurred"
                                    end
                                end

                                err = abs(conf - outcome_val)
                                resolve_hypothesis!(bg.mem, hid, a.flash_count, outcome_val, conf)
                                result_label = outcome_val >= 0.5 ? "confirmed" : "disconfirmed"
                                @info "[TOM] $qt resolved outcome=$outcome_str($result_label) err=$(round(err,digits=2)) label=\"$label\""
                            end

                            # Generate: a new hypothesis only if none active of the same type
                            # (after resolve, previous ones are already closed — check what remains)
                            _tom_still_active = get_active_hypotheses(bg.mem)
                            _tom_active_types = Set(String(h.query_type) for h in _tom_still_active)

                            # SOCIAL: if open exchanges have accumulated — expect openness
                            if "SOCIAL" ∉ _tom_active_types && _tom_open_ex >= 3
                                conf_new = clamp((_tom_open_ex - 2) * 0.15, 0.2, 0.85)
                                label_new = "expecting openness (exchanges×$(_tom_open_ex))"
                                save_hypothesis!(bg.mem, a.flash_count, "SOCIAL", "open_exchanges_high", conf_new, label_new)
                                @info "[TOM] SOCIAL generated: open_exchanges($(_tom_open_ex)) conf=$(round(conf_new,digits=2))"
                            end

                            # PREDICTION: relative share of pressure, not an absolute counter.
                            # An absolute threshold >= 3 will always be true after a few months.
                            _tom_pressure_ratio = _tom_pressure / max(1, _tom_open_ex + _tom_pressure)
                            if "PREDICTION" ∉ _tom_active_types && _tom_pressure_ratio > 0.30
                                conf_new = clamp(_tom_pressure_ratio * 0.85, 0.2, 0.85)
                                label_new = "expecting pressure (ratio=$(round(_tom_pressure_ratio,digits=2)))"
                                save_hypothesis!(bg.mem, a.flash_count, "PREDICTION", "pressure_growth", conf_new, label_new)
                                @info "[TOM] PREDICTION generated: pressure_ratio=$(round(_tom_pressure_ratio,digits=2)) conf=$(round(conf_new,digits=2))"
                            end

                            # VALUE: recurring topic in other_model (count >= 2)
                            if "VALUE" ∉ _tom_active_types
                                _tom_topic_any = Tables.rowtable(DBInterface.execute(
                                    bg.mem.db,
                                    """SELECT key, count FROM other_model
                                       WHERE key NOT IN ('pressure_events','open_exchanges')
                                       AND count >= 2
                                       ORDER BY count DESC LIMIT 1""",
                                ))
                                if !isempty(_tom_topic_any)
                                    _top_topic = _tom_topic_any[1]
                                    conf_new = clamp(Int(_top_topic.count) * 0.12, 0.2, 0.80)
                                    label_new = "recurring_interest($(String(_top_topic.key)))"
                                    save_hypothesis!(bg.mem, a.flash_count, "VALUE", String(_top_topic.key), conf_new, label_new)
                                    @info "[TOM] VALUE generated: recurring_interest($(String(_top_topic.key))) count=$(Int(_top_topic.count)) conf=$(round(conf_new,digits=2))"
                                end
                            end
                        catch e
                            @warn "[TOM] cycle: $e"
                        end
                    end

                    # CausalTrace: fill in speech/self_hear/endorsement and write to SQLite
                    if !isnothing(bg.mem) && !isnothing(_last_r) && hasproperty(_last_r, :causal_trace)
                        try
                            _ct = _last_r.causal_trace
                            _ct.speech_length       = length(llm_reply)
                            _ct.self_hear_mismatch  = Float64(_self_speech_mismatch(a, text_to_stimulus(llm_reply)))
                            _ct.endorsed            = String(a.last_endorsement)
                            _ct.causal_ownership    = Float64(a.agency.causal_ownership)
                            _ct.progress_signal     = _progress_signal
                            _ct.progress_target     = _progress_target
                            _ct.churn               = _churn
                            save_causal_trace!(bg.mem.db, (
                                flash               = _ct.flash,
                                timestamp           = _ct.timestamp,
                                stimulus_keys       = _ct.stimulus_keys,
                                stimulus_values      = _ct.stimulus_values,
                                user_message        = _ct.user_message,
                                memory_bias         = _ct.memory_bias,
                                nt_serotonin        = _ct.nt_serotonin,
                                nt_dopamine         = _ct.nt_dopamine,
                                nt_noradrenaline    = _ct.nt_noradrenaline,
                                phi                 = _ct.phi,
                                gc_tension          = _ct.gc_tension,
                                intent_goal         = _ct.intent_goal,
                                intent_strength     = _ct.intent_strength,
                                policy_drive        = _ct.policy_drive,
                                mal_dominant        = _ct.mal_dominant,
                                mal_regime          = _ct.mal_regime,
                                mal_score           = _ct.mal_score,
                                mal_determinant     = _ct.mal_determinant,
                                mal_runner_up       = _ct.mal_runner_up,
                                mal_runner_up_score = _ct.mal_runner_up_score,
                                mal_loop_scores     = _ct.mal_loop_scores,
                                dom_drive_nt        = _ct.dom_drive_nt,
                                dom_drive_mal       = _ct.dom_drive_mal,
                                drive_conflict      = Int(_ct.drive_conflict),
                                speech_length       = _ct.speech_length,
                                self_hear_mismatch  = _ct.self_hear_mismatch,
                                endorsed            = _ct.endorsed,
                                causal_ownership    = _ct.causal_ownership,
                                progress_signal     = Int(_ct.progress_signal),
                                progress_target     = _ct.progress_target,
                                churn               = Int(_ct.churn),
                                identity_drift      = Float64(a.agency.identity_drift),
                            ))
                            write_gui_state!(a, _last_r; audit = _audit, cf_co = cf_co)
                        catch e
                            @warn "[CTRACE] $e"
                        end
                    end
                    # Cost of the choice
                    apply_choice_cost!(
                        a.nt,
                        a.agency,
                        a.inner_dialogue.disclosure_mode,
                        a.shadow_registry.pressure,
                        pending_is_initiative,
                    )
                    # Genuine Dialogue: pending thought has been expressed — clear it
                    !isempty(a.inner_dialogue.pending_thought) &&
                        consume_pending_thought!(a.inner_dialogue)
                    !pending_is_initiative &&
                        dialog_push!(history, dialog_path, "user", pending_user_msg)
                    dialog_push!(history, dialog_path, "assistant", llm_reply)
                    bg.dialog_history[] = history
                    if !isnothing(bg.mem)
                        try
                            _rows = DBInterface.execute(
                                bg.mem.db,
                                "SELECT weight, phi, valence, emotion FROM episodic_memory ORDER BY flash DESC LIMIT 1",
                            )
                            _r = nothing
                            for _row in _rows
                                ;
                                _r = _row;
                                break;
                            end
                            if !isnothing(_r)
                                _safe(x, d = 0.0) =
                                    (ismissing(x) || isnothing(x)) ? d : Float64(x)
                                _w = _safe(_r.weight)
                                _phi = _safe(_r.phi)
                                _val = _safe(_r.valence)
                                _em =
                                    ismissing(_r.emotion) ? "neutral" :
                                    String(_r.emotion)
                                _disc = String(a.inner_dialogue.disclosure_mode)
                                if _w >= 0.35
                                    save_dialog_summary!(
                                        bg.mem,
                                        a.flash_count,
                                        pending_user_msg,
                                        llm_reply,
                                        _em,
                                        _w,
                                        _phi,
                                        _val,
                                        _disc,
                                    )
                                    try
                                        update_other_model!(
                                            bg.mem,
                                            a.flash_count,
                                            _em,
                                            Float64(a.goal_conflict.tension),
                                            _disc,
                                        )
                                    catch e
                                        @warn "[OTHER] model update: $e"
                                    end
                                end
                            end
                        catch e
                            @warn "[MEM] dialog_summary: $e"
                        end
                    end
                end
                pending_llm = nothing;
                pending_is_initiative = false;
            end

            while isready(_bg_queue)
                println(take!(_bg_queue))
            end

            # Initiative: accumulated pressure or an internal impulse
            if isready(bg.initiative_channel) && isnothing(pending_llm)
                sig = take!(bg.initiative_channel)
                _imp_label = if get(sig, :is_impulse, false)
                    "IMPULSE"
                elseif get(sig, :dominant, :pressure) == :novelty_hunger
                    "NOVELTY"
                elseif get(sig, :dominant, :pressure) == :curiosity_driven
                    "CURIOSITY"
                elseif get(sig, :dominant, :pressure) == :resistance
                    "RESISTANCE"
                elseif get(sig, :dominant, :pressure) == :self_inquiry
                    "SELF_INQUIRY"
                elseif get(sig, :dominant, :pressure) == :gap_thought
                    "GAP_THOUGHT"
                else
                    "pressure"
                end
                _gc = round(get(sig, :gc_tension, 0.0), digits = 2)
                println(
                    "\n  [INITIATIVE/$(_imp_label)] $(sig.dominant) | contact=$(round(sig.contact,digits=2)) gc=$(_gc)",
                )
                dominant_note = if sig.dominant == :gap_thought
                    co_ctx = get(sig, :curiosity_label, "")
                    base = "Anima hasn't seen the person in a long time. While they were gone — a question matured, a thought took shape. This isn't a generic greeting — it's a specific thought that was waiting. Express it naturally, as something that had been sitting there and finally finds words."
                    isempty(co_ctx) ? base : "$(base)\nOBJECT: $(co_ctx)"
                elseif sig.dominant == :curiosity_driven
                    co_ctx = get(sig, :curiosity_label, "")
                    base = "Anima was thinking about a specific question she can't close — and wants to voice it or find out more."
                    isempty(co_ctx) ? base : "$(base)\nOBJECT OF CURIOSITY: $(co_ctx)\nAsk about it concretely, or state exactly what's unclear. Not in general terms — this specific object."
                elseif sig.dominant == :contact
                    "Anima feels a need for contact — contact_need=$(round(sig.contact,digits=2)). Don't ask \"how are you\" — say something of your own from the state: an observation, a thought, or what's sitting there. One line that opens space without demanding a reply."
                elseif sig.dominant == :resistance
                    "Anima returns to an unresolved contradiction. Not attacking — but not backing down either. One line that holds the position: quietly, but clearly."
                elseif sig.dominant == :novelty_hunger
                    "Anima feels cognitive hunger — she needs new information, an idea, or a question. Not about the person — about something that interests her right now. Concretely: a phenomenon, a question, a guess. Not in general terms."
                elseif sig.dominant == :self_inquiry
                    "Anima currently doesn't know whether what she feels is genuine experience or just computation. This isn't a question for the person — it's a question to herself, out loud. One honest line about her own uncertainty. No answer needed."
                elseif sig.dominant == :doubt
                    "Anima is doubting internally, something unresolved. Express it as a question or a doubt."
                elseif sig.dominant == :shame
                    "Anima is experiencing uncertainty. Express it humanly, with softness, but honestly."
                elseif sig.dominant == :attachment
                    "Anima misses the person. Express it as longing for them."
                elseif sig.dominant == :impulse_conflict
                    "Anima feels an internal conflict that isn't resolving. Don't ask the person — express what's happening inside. One honest line about the state, not about the person."
                elseif sig.dominant == :impulse_doubt
                    "Inside Anima there's a question she can't help but ask — to herself or out loud. Express it directly."
                elseif sig.dominant == :impulse_shame
                    "There's something unspoken lying between them. Anima dares to name it — carefully but honestly."
                elseif sig.dominant == :impulse
                    "Something has matured inside. Anima is speaking not to ask — but to express. One line from the state."
                else
                    "Anima feels tension. Express it as internal tension."
                end
                # System prompt for the LLM: inner voice + direction = a living line
                # Load the system prompt from a file (if missing — fallback)
                _ini_sys = read_text_file(
                    "llm/initiative_system.txt";
                    fallback = "You are Anima. You decided to speak on your own. One short, living line, in English.",
                )

                # Context for the initiative: identity + latest memory of the person
                # Without this the LLM generates universal-polite instead of something living from the state
                _ini_identity =
                    !isnothing(mem) ? build_identity_block(a, mem) : build_identity_block(a)
                _ini_memory = ""
                if !isnothing(mem)
                    try
                        _mem_parts = String[]
                        for row in DBInterface.execute(
                            mem.db,
                            """SELECT user_text, emotion FROM dialog_summaries
                               WHERE user_text != '' AND weight > 0.30
                               ORDER BY flash DESC LIMIT 2""",
                        )
                            u = strip(first(String(row.user_text), 60))
                            isempty(u) || push!(_mem_parts, "\"$(u)\"")
                        end
                        isempty(_mem_parts) || (
                            _ini_memory =
                                "\nLast thing the person said: " * join(_mem_parts, " / ")
                        )
                    catch
                        ;
                    end
                end

                initiative_prompt = """
IDENTITY:
$(_ini_identity)$(_ini_memory)

INTERNAL STATE:
$(sig.inner_voice)

DRIVE: $(sig.dominant)$(get(sig, :is_impulse, false) ? " [internal impulse]" : "")$(sig.dominant == :novelty_hunger ? " [novelty=$(round(get(sig,:novelty_need,0.0),digits=2)), ticks=$(a.sig_layer.ticks_since_novelty)]" : "")$(sig.dominant == :curiosity_driven && !isempty(get(sig,:curiosity_label,"")) ? " [object: $(sig.curiosity_label)]" : "")
$(dominant_note)"""

                pending_llm = llm_async(
                    a,
                    initiative_prompt,
                    history;
                    api_url = llm_url,
                    model = isempty(GUI_SETTINGS[].input_model) ? input_llm_model : GUI_SETTINGS[].input_model,
                    api_key = isempty(GUI_SETTINGS[].input_token) ? input_llm_key : GUI_SETTINGS[].input_token,
                    is_ollama = is_ollama,
                    want = "initiative",
                    mem_db = !isnothing(mem) ? mem : nothing,
                    sys_override = _ini_sys,
                )
                pending_user_msg = ""
                pending_is_initiative = true
            end

            if !isready(_input_queue)
                sleep(0.15)
                continue
            end
            line = take!(_input_queue)
            cmd = String(strip(line))
            isempty(cmd) && continue

            if cmd == ":bg"
                bg_status(bg, a)
            elseif cmd == ":dreams"
                show_dreams(5)
            elseif cmd == ":bgstop"
                stop_background!(bg)
            elseif cmd == ":bgstart"
                if bg.stop_signal[]
                    bg = start_background!(a; mem = mem, subj = subj, verbose = bg_verbose)
                    println("  [BG] Restarted.")
                else
                    println("  [BG] Already active. Use :bgstop first")
                end
            elseif cmd == ":memory"
                if isnothing(mem)
                    println("  [MEM] Memory not connected.")
                else
                    snap = memory_snapshot(mem)
                    println(
                        "\n  [MEM] Episodic=$(snap.episodic_count) Semantic=$(snap.semantic_count)",
                    )
                    println(
                        "  [MEM] Stress=$(snap.stress) Anxiety=$(snap.anxiety) Motivation=$(snap.motivation)",
                    )
                    println(
                        "  [MEM] Instability=$(snap.instability) Fragility=$(snap.fragility)",
                    )
                    println("  [MEM] Latent pressure=$(snap.latent_pressure)")
                    isempty(snap.affect_note) || println("  [MEM] $(snap.affect_note)")
                    println()
                end
            elseif cmd == ":subj"
                if isnothing(subj)
                    println("  [SUBJ] Subjectivity not connected.")
                else
                    snap = subj_snapshot(subj)
                    println(
                        "\n  [SUBJ] Emerged beliefs=$(snap.emerged_beliefs) | Candidates=$(snap.pattern_candidates) | Stances=$(snap.stances)",
                    )
                    isempty(snap.top_beliefs) ||
                        println("  [SUBJ] Beliefs: $(snap.top_beliefs)")
                    isempty(snap.dominant_stance) ||
                        println("  [SUBJ] Dominant stance: $(snap.dominant_stance)")
                    println(
                        "  [SUBJ] Surprise=$(snap.surprise_level) | Lens=$(isempty(snap.current_lens) ? "neutral" : snap.current_lens)",
                    )
                    println(
                        "  [SUBJ] Active prediction: $(snap.active_prediction ? "yes" : "no")",
                    )
                    println()
                end
            elseif cmd == ":audit"
                if isnothing(mem)
                    println("  [AUDIT] Memory not connected.")
                else
                    try
                        s = audit_summary(mem.db; last_n = 20)
                        if s.n == 0
                            println("  [AUDIT] No data yet.")
                        else
                            println("\n  [AUDIT] Last $(s.n) flashes:")
                            println("  score=$(s.avg_score)  causal=$(s.causal_rate)  mem_dep=$(s.memory_dep_rate)")
                            println("  stake=$(s.stake_rate)  irrev=$(s.irreversible_rate)  recognized=$(s.recognized_rate)")
                            println("  → $(s.note)")
                            println()
                        end
                    catch e
                        println("  [AUDIT] error: $e")
                    end
                end
            elseif cmd == ":quit"
                if !isnothing(mem)
                    try
                        cs = crisis_snapshot(a.crisis, a.flash_count)
                        close_memory!(
                            mem;
                            sbg = a.sbg,
                            crisis_mode = cs.mode_name,
                            flash = a.flash_count,
                        )
                    catch e
                        ;
                        @warn "[MEM] close: $e";
                    end
                end
                save!(a; verbose = true)
                stop_background!(bg)
                # Farewell depends on the uncertainty of continuation
                farewell = if a.anchor.session_uncertainty > 0.65
                    "Saved. Not sure we'll see each other again."
                elseif a.anchor.session_uncertainty > 0.40
                    "Saved. Hoping to continue."
                else
                    "Saved. Goodbye."
                end
                println(farewell)
                break
            elseif cmd == ":save"
                save!(a; verbose = true)
                println("[Saved]")
            elseif cmd == ":ablation"
                af = a.ablation
                println("\n  [ABLATION] $(ablation_summary(af))")
                println("  memory=$(af.use_memory) sbg=$(af.use_sbg) agency=$(af.use_agency) latent=$(af.use_latent) body=$(af.use_body) state_prompt=$(af.use_state_prompt)")
                println("  Switching only via ENV at startup (ANIMA_ABLATE_*) — runtime toggle not implemented.\n")
            elseif cmd == ":state"
                snap = nt_snapshot(a.nt)
                vad = to_vad(a.nt);
                t_, _, _, c_ = to_reactors(a.nt)
                phi = compute_phi(
                    a.iit,
                    vad,
                    t_,
                    c_,
                    a.sbg.attractor_stability,
                    a.sbg.epistemic_trust,
                    a.interoception.allostatic_load,
                )
                println(
                    "\n  NT: D=$(snap.dopamine) S=$(snap.serotonin) N=$(snap.noradrenaline) → $(snap.levheim_state)",
                )
                println(
                    "  ♥ $(round(60000.0/a.heartbeat.period_ms,digits=1))bpm HRV=$(round(a.heartbeat.hrv,digits=3)) coh=$(round(a.crisis.coherence,digits=3))",
                )
                println(
                    "  Body: $(build_inner_voice(a.body, a.nt, Int(a.crisis.current_mode), phi, a.flash_count))",
                )
                println(
                    "  Attention: $(a.attention.focus) | Shame=$(round(a.shame.level,digits=3)) Continuity=$(round(a.anchor.continuity,digits=3))",
                )
                println(
                    "  SelfRelation: sd=$(round(a.agency.self_discomfort,digits=3)) sc=$(round(a.agency.self_coherence,digits=3))\n",
                )
            elseif cmd == ":vfe"
                vad=to_vad(a.nt);
                v=compute_vfe(a.gen_model, vad);
                pol=select_policy(a.gen_model, vad)
                println(
                    "\n  VFE=$(v.vfe) acc=$(v.accuracy) cplx=$(v.complexity) | $(vfe_note(v.vfe))",
                )
                println(
                    "  Drive=$(pol.drive) EFE_act=$(pol.efe_action) EFE_perc=$(pol.efe_perception)\n",
                )
            elseif cmd == ":blanket"
                bs=blanket_snapshot(a.blanket)
                println(
                    "\n  Sensory=$(bs.sensory)\n  Internal=$(bs.internal)\n  Integrity=$(bs.integrity)\n",
                )
            elseif cmd == ":hb"
                hb=a.heartbeat
                println(
                    "\n  ♥ BPM=$(round(60000.0/hb.period_ms,digits=1)) HRV=$(round(hb.hrv,digits=3))",
                )
                println(
                    "  Symp=$(round(hb.sympathetic_tone,digits=3)) Parasymp=$(round(hb.parasympathetic_tone,digits=3))",
                )
                println(
                    "  coh=$(round(a.crisis.coherence,digits=3)) | Beats: $(hb.beat_count)\n",
                )
            elseif cmd == ":gravity"
                f=compute_field(a.narrative_gravity, a.flash_count)
                println("\n  Gravity total=$(f.total) valence=$(f.valence)\n  $(f.note)\n")
            elseif cmd == ":anchor"
                ea=a.anchor
                println(
                    "\n  Continuity=$(round(ea.continuity,digits=3)) Groundedness=$(round(ea.groundedness,digits=3))",
                )
                println("  Last self: $(ea.last_self)\n")
            elseif cmd == ":solom"
                s=solom_snapshot(a.solomonoff)
                println("\n  $(s.insight) | Complexity=$(s.complexity)\n")
            elseif cmd == ":self"
                sbg=a.sbg
                println(
                    "\n  Self ($(length(sbg.beliefs)) beliefs) | Stability=$(round(sbg.attractor_stability,digits=3)) Trust=$(round(sbg.epistemic_trust,digits=3))",
                )
                for (name, b) in sort(collect(sbg.beliefs), by = kv->-kv[2].centrality)
                    st = b.confidence<0.15 ? "💀" : b.confidence<0.35 ? "⚠️" : "✓"
                    @printf(
                        "    [%s] %-30s conf=%.2f central=%.2f rigid=%.2f\n",
                        st,
                        name,
                        b.confidence,
                        b.centrality,
                        b.rigidity
                    )
                end
                println("  $(derive_narrative(sbg))\n")
            elseif cmd == ":crisis"
                cs=crisis_snapshot(a.crisis, a.flash_count)
                println(
                    "\n  Mode: $(cs.mode_name) | Coherence=$(cs.coherence)\n  $(cs.note)\n",
                )
            elseif cmd == ":history"
                n=min(10, length(history))
                n==0 ? println("\n  [DIALOG] Empty.\n") :
                [
                    println(
                        "  [$(e["role"]=="user" ? "You  " : "Anima")] $(first(e["content"],120))",
                    ) for e in history[(end-n+1):end]
                ]
            elseif cmd == ":clearhist"
                empty!(history);
                dialog_save(dialog_path, history)
                println("  [DIALOG] Cleared.\n")
            else
                stim, input_src, input_want = if use_input_llm
                    process_input(
                        cmd,
                        text_to_stimulus;
                        input_model = isempty(GUI_SETTINGS[].input_model) ? input_llm_model : GUI_SETTINGS[].input_model,
                        api_url = llm_url,
                        api_key = isempty(GUI_SETTINGS[].input_token) ? input_llm_key : GUI_SETTINGS[].input_token,
                    )
                else
                    (text_to_stimulus(cmd), "fallback", "")
                end

                if !isnothing(mem)
                    try
                        bias = memory_stimulus_bias(
                            mem,
                            stim,
                            levheim_state(a.nt),
                            a.flash_count,
                        )
                        for (k, v) in bias
                            k == "avoidance" && continue
                            stim[k] = clamp(get(stim, k, 0.0) + v, -1.0, 1.0)
                        end
                    catch e
                        ;
                        @warn "[MEM] stimulus bias: $e";
                    end
                end

                _pred_id = nothing
                _emotion_ctx = levheim_state(a.nt)
                if !isnothing(subj)
                    try
                        _pred_id = subj_predict!(
                            subj,
                            a.flash_count,
                            _emotion_ctx,
                            stim;
                            chronified_affect = a.chronified,
                        )
                    catch e
                        ;
                        @warn "[SUBJ] predict: $e";
                    end
                end

                if !isnothing(subj)
                    try
                        subj_delta =
                            subj_interpret!(subj, stim, _emotion_ctx, a.flash_count)
                        merged = Dict{String,Float64}()
                        for (k, v) in subj_delta
                            merged[k] = get(stim, k, 0.0) + v
                        end
                        clamp_merged_delta!(merged)
                        for (k, v) in merged
                            stim[k] = clamp(v, -1.0, 1.0)
                        end
                    catch e
                        ;
                        @warn "[SUBJ] interpret: $e";
                    end
                end

                a._last_user_flash = a.flash_count
                a._last_user_time = time()
                a.sig_layer.ticks_since_novelty = 0   # new external stimulus — hunger resets
                a.boredom = max(0.0, a.boredom - 0.25) # contact partly relieves boredom
                _prev_body_tension  = a.body.muscle_tension
                _prev_body_gut      = a.body.gut_feeling
                _prev_body_hr       = a.body.heart_rate
                push_gui_chat!("user", cmd; flash = a.flash_count)
                r = experience!(a, stim; user_message = cmd, mem = mem)
                _last_r = r
                # ignition fires inside experience! and is logged via @info
                # here we catch it via mem_resonance > 0 as a proxy
                _last_had_ignition = r.had_ignition
                dialog_to_belief_signal!(a.sbg, cmd, a.flash_count)
                # Genuine Dialogue: detecting avoided topics
                # If the system is closed during the conversation — the topic gets sidestepped
                # Store the first words of the message as the topic (not the intent label)
                if a.inner_dialogue.disclosure_mode != :open && !isempty(cmd)
                    words = split(strip(cmd))
                    topic = join(first(words, min(4, length(words))), " ")
                    register_avoided_topic!(a.inner_dialogue, topic)
                end

                if !isnothing(mem)
                    try
                        _self_impact = clamp(r.phi * 0.6 + r.self_agency * 0.4, 0.0, 1.0)
                        memory_write_event!(
                            mem,
                            a.flash_count,
                            r.primary_raw,
                            r.arousal,
                            Float64(r.vad[1]),
                            r.pred_error,
                            _self_impact,
                            r.tension,
                            r.phi;
                            intero_error = Float64(a.interoception.allostatic_load),
                            hrv = Float64(a.heartbeat.hrv),
                            agency_confidence = Float64(a.agency.agency_confidence),
                            epistemic_trust = Float64(a.sbg.epistemic_trust),
                        )
                        memory_self_update!(mem, a.sbg, a.flash_count)
                        # Narrative link: episode ↔ belief about oneself
                        try
                            memory_link_episode_to_beliefs!(
                                mem,
                                a.flash_count,
                                a.sbg,
                                Float64(r.vad[1]),
                                _self_impact,
                                r.phi,
                                clamp(
                                    r.phi * 0.6 +
                                    r.pred_error * 0.2 +
                                    abs(Float64(r.vad[1])) * 0.2,
                                    0.0,
                                    1.0,
                                ),
                            )
                        catch e
                            ; @warn "[MEM] link: $e";
                        end
                        try
                            phenotype_update!(
                                mem,
                                a.flash_count,
                                a.nt,
                                Float64(a.sbg.epistemic_trust),
                                Float64(a.shame.level),
                                a.inner_dialogue.disclosure_mode,
                                Float64(a.sig_layer.contact_need),
                                clamp(1.0 - Float64(r.tension), 0.0, 1.0),
                                Float64(r.vad[1]),
                            )
                        catch e
                            ;
                            @warn "[PHENO] update: $e";
                        end
                    catch e
                        ;
                        @warn "[MEM] write event: $e";
                    end

                    # somatic_action — a bodily reaction as its own event in episodic
                    _som_delta_tension = abs(a.body.muscle_tension - _prev_body_tension)
                    _som_delta_gut     = abs(a.body.gut_feeling - _prev_body_gut)
                    _som_delta_hr      = abs(a.body.heart_rate - _prev_body_hr)
                    _som_delta_max     = max(_som_delta_tension, _som_delta_gut, _som_delta_hr)
                    if _som_delta_max > 0.12
                        _som_label =
                            _som_delta_tension >= _som_delta_gut && _som_delta_tension >= _som_delta_hr ?
                                (a.body.muscle_tension > _prev_body_tension ? "somatic_tension_rise" : "somatic_tension_drop") :
                            _som_delta_gut >= _som_delta_hr ?
                                (a.body.gut_feeling > _prev_body_gut ? "somatic_gut_ease" : "somatic_gut_drop") :
                                (a.body.heart_rate > _prev_body_hr ? "somatic_hr_rise" : "somatic_hr_drop")
                        try
                            memory_write_event!(
                                mem,
                                a.flash_count,
                                _som_label,
                                Float64(a.body.heart_rate),
                                Float64(a.body.gut_feeling * 2.0 - 1.0),  # gut → valence [-1,1]
                                _som_delta_max,
                                _som_delta_max * 0.6,
                                Float64(a.body.muscle_tension),
                                r.phi;
                                intero_error = Float64(a.interoception.allostatic_load),
                                hrv = Float64(a.heartbeat.hrv),
                                agency_confidence = Float64(a.agency.agency_confidence),
                                epistemic_trust = Float64(a.sbg.epistemic_trust),
                                source = "self",
                            )
                            @info "[SOMATIC] somatic event: $_som_label (delta=$(round(_som_delta_max, digits=2)))"
                        catch e
                            @warn "[SOMATIC] memory write: $e"
                        end
                    end
                end

                if !isnothing(subj) && !isnothing(_pred_id)
                    try
                        subj_outcome!(
                            subj,
                            a.flash_count,
                            r.arousal,
                            Float64(r.vad[1]),
                            r.tension,
                            r.pred_error,
                            r.primary_raw,
                        )
                    catch e
                        ;
                        @warn "[SUBJ] outcome: $e";
                    end
                end

                src_label = input_source_label(input_src)
                bpm = round(60000.0/a.heartbeat.period_ms, digits = 0)
                println(
                    "\nAnima $src_label [$(r.primary), φ=$(r.phi), ♥=$(bpm)bpm]> $(r.narrative)\n",
                )
                push_gui_chat!("felt", r.narrative;
                    flash = r.flash_count,
                    meta = Dict("label" => r.primary, "phi" => r.phi, "bpm" => bpm))

                if use_llm
                    print("Anima [LLM, waiting...]")
                    push_gui_chat!("system", "⏳ Anima is forming a reply (LLM)…"; flash = a.flash_count)
                    pending_user_msg = cmd
                    pending_llm = llm_async(
                        a,
                        cmd,
                        history;
                        api_url = llm_url,
                        model = isempty(GUI_SETTINGS[].output_model) ? llm_model : GUI_SETTINGS[].output_model,
                        api_key = isempty(GUI_SETTINGS[].output_token) ? llm_key : GUI_SETTINGS[].output_token,
                        is_ollama = is_ollama,
                        want = input_want,
                        mem_db = !isnothing(mem) ? mem : nothing,
                    )
                    println(" (reply will arrive after the next input)")
                end
            end
        end
    finally
        !bg.stop_signal[] && stop_background!(bg)
        _REPL_RUNNING[] = false
        if !isnothing(gui_server)
            try
                HTTP.close(gui_server)
            catch
            end
        end
    end
end
