# A N I M A  —  Dream Generation
#
# Dreaming between sessions: processing fragments of dialog history
# as reconstructed signals without an external anchor.
# Result — a changed state upon waking.

const DREAM_PROB = 0.05   # 5% chance per slow_tick
const DREAM_GAP_MIN = 1800.0 # minimum 30min without interaction
const DREAM_NT_SCALE = 0.25   # dream's NT impact — 25% of real experience
const DREAM_LOG_MAX = 20

function _default_dream_log_path()
    dir = strip(get(ENV, "ANIMA_STATE_DIR", ""))
    isempty(dir) && return joinpath(@__DIR__, "anima_dream.json")
    dir = isabspath(dir) ? dir : joinpath(@__DIR__, dir)
    isdir(dir) || mkpath(dir)
    joinpath(dir, "anima_dream.json")
end

const DREAM_LOG_PATH = _default_dream_log_path()

# --- Dream Record ----------------------------------------------------------

struct DreamRecord
    flash_count::Int
    hour::Int
    gap_minutes::Float64
    source_fragment::String
    emotion::String
    phi::Float64
    nt_delta::NTuple{3,Float64}
    memory_uncert::Float64
    narrative::String
end

# --- Dream Conditions -------------------------------------------------------------

function can_dream(a::Anima, gap_seconds::Float64)::Bool
    hour = a.temporal.circadian_hour
    is_night = hour >= 0 && hour < 6
    long_gap = gap_seconds >= DREAM_GAP_MIN
    not_disintegrated = Int(a.crisis.current_mode) != 2
    lucky = rand() < DREAM_PROB

    is_night && long_gap && not_disintegrated && lucky
end

# --- Reconstructing a Stimulus from the Fragment ----------------------------------------

function _dream_stimulus_from_fragment(fragment::String)::Dict{String,Float64}
    base_arousal = clamp(0.4 + randn() * 0.15, 0.0, 1.0)
    base_valence = clamp(0.0 + randn() * 0.2, -1.0, 1.0)
    base_tension = clamp(0.4 + randn() * 0.12, 0.0, 1.0)

    lower = lowercase(fragment)
    if any(w -> occursin(w, lower), ["warm", "close", "trust", "love", "❤", "🌸", "😘"])
        base_valence = clamp(base_valence + 0.3, -1.0, 1.0)
        base_arousal = clamp(base_arousal + 0.1, 0.0, 1.0)
    elseif any(
        w -> occursin(w, lower),
        ["fear", "hurts", "hard", "can't", "falling apart"],
    )
        base_valence = clamp(base_valence - 0.3, -1.0, 1.0)
        base_tension = clamp(base_tension + 0.2, 0.0, 1.0)
    end

    Dict{String,Float64}(
        "arousal" => base_arousal,
        "valence" => base_valence,
        "tension" => base_tension,
        "satisfaction" => clamp(0.5 + base_valence * 0.3, 0.0, 1.0),
        "cohesion" => clamp(0.5 - base_tension * 0.2, 0.0, 1.0),
        "prediction_error" => clamp(0.3 + randn() * 0.1, 0.0, 1.0),
        "self_impact" => 0.3,
    )
end

# --- Dream ------------------------------------------------------------

function dream_flash!(
    a::Anima,
    mem,
    dialog_history::Vector,
    gap_seconds::Float64;
    shadow_registry = nothing,
)::Union{DreamRecord,Nothing}

    isempty(dialog_history) && return nothing
    can_dream(a, gap_seconds) || return nothing

    # Picking a fragment (user lines with length >= 8, not system ones)
    MIN_FRAGMENT_LEN = 8
    user_entries = [
        (i, get(d, "content", get(d, "text", ""))) for
        (i, d) in enumerate(dialog_history) if get(d, "role", "") == "user"
    ]
    user_entries = [
        (i, t) for (i, t) in user_entries if length(t) >= MIN_FRAGMENT_LEN &&
        !startswith(t, ":") &&
        !startswith(t, "[BG]") &&
        !startswith(t, "[SUBJ]") &&
        !startswith(t, "[LLM")
    ]

    isempty(user_entries) && return nothing

    pool =
        length(user_entries) > 60 ? user_entries[1:(end-3)] : user_entries[1:max(1, end-1)]

    recent_sources = Set(get(d, "source", "") for d in load_dream_log())
    fresh_pool = [(i, t) for (i, t) in pool if !in(first(t, 120), recent_sources)]
    chosen_pool = isempty(fresh_pool) ? pool : fresh_pool
    _, fragment_text = rand(chosen_pool)
    isempty(fragment_text) && (fragment_text = "...")

    # Shadow injection: if pressure is high enough — the dream can build around the shadow
    shadow_source = false
    if !isnothing(shadow_registry) &&
       shadow_registry.pressure > 0.3 &&
       !isempty(shadow_registry.items)
        inject_prob = clamp((shadow_registry.pressure - 0.3) * 1.4, 0.0, 0.7)
        if rand() < inject_prob
            weighted = [(it.weight, it) for it in shadow_registry.items]
            sort!(weighted, by = x -> -x[1])
            shadow_item = weighted[1][2]
            fragment_text = shadow_item.text
            shadow_source = true
        end
    end

    fragment_short =
        length(fragment_text) > 120 ? first(fragment_text, 120) * "…" : fragment_text

    stim = _dream_stimulus_from_fragment(fragment_text)

    nt_before = (a.nt.dopamine, a.nt.serotonin, a.nt.noradrenaline)
    _dream_update_state!(a, stim, mem; shadow_amplify = shadow_source)
    nt_after = (a.nt.dopamine, a.nt.serotonin, a.nt.noradrenaline)
    nt_delta =
        (nt_after[1]-nt_before[1], nt_after[2]-nt_before[2], nt_after[3]-nt_before[3])

    # a shadow-dream leaves a bigger trace of uncertainty
    uncert_delta = shadow_source ? 0.22 : 0.15
    a.unknown_register.memory_uncertainty =
        clamp01(a.unknown_register.memory_uncertainty + uncert_delta)

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

    emotion_str = levheim_state(a.nt)
    dream_narrative = _build_dream_narrative(
        fragment_short,
        emotion_str,
        stim["valence"],
        phi_now,
        a.temporal.circadian_hour,
    )

    return DreamRecord(
        a.flash_count,
        a.temporal.circadian_hour,
        gap_seconds / 60.0,
        fragment_short,
        emotion_str,
        phi_now,
        nt_delta,
        a.unknown_register.memory_uncertainty,
        dream_narrative,
    )
end

# --- Updating State During the Dream --------------------------------------------

function _dream_update_state!(a::Anima, stim::Dict, mem; shadow_amplify::Bool = false)
    valence = Float64(get(stim, "valence", 0.0))
    arousal = Float64(get(stim, "arousal", 0.5))
    tension = Float64(get(stim, "tension", 0.4))

    amp = shadow_amplify ? 1.6 : 1.0
    d_delta = clamp(valence * 0.08 - tension * 0.04, -0.06, 0.06) * DREAM_NT_SCALE * amp
    s_delta = clamp(valence * 0.06 - arousal * 0.03, -0.05, 0.05) * DREAM_NT_SCALE * amp
    n_delta = clamp(tension * 0.07 + arousal * 0.04, -0.06, 0.06) * DREAM_NT_SCALE * amp

    a.nt.dopamine = clamp01(a.nt.dopamine + d_delta)
    a.nt.serotonin = clamp01(a.nt.serotonin + s_delta)
    a.nt.noradrenaline = clamp01(a.nt.noradrenaline + n_delta)

    if !isnothing(mem)
        try
            if valence < -0.1
                _upsert_affect!(
                    mem.db,
                    "anxiety",
                    abs(valence) * 0.003 * DREAM_NT_SCALE,
                    0.0,
                    1.0,
                )
                if tension > 0.5
                    _upsert_affect!(
                        mem.db,
                        "stress",
                        tension * abs(valence) * 0.002 * DREAM_NT_SCALE,
                        0.0,
                        1.0,
                    )
                end
            elseif valence > 0.2
                _upsert_affect!(
                    mem.db,
                    "motivation_bias",
                    valence * 0.002 * DREAM_NT_SCALE,
                    0.0,
                    1.0,
                )
                _upsert_affect!(
                    mem.db,
                    "anxiety",
                    -valence * 0.001 * DREAM_NT_SCALE,
                    0.0,
                    1.0,
                )
            end
        catch
            ;
        end
    end

    nothing
end

# --- Dream Narrative ----------------------------------------------------------

function _build_dream_narrative(
    fragment::String,
    emotion::String,
    valence::Float64,
    phi::Float64,
    hour::Int,
)::String
    time_str = hour < 3 ? "deep night" : hour < 6 ? "predawn" : "night"

    tone = if valence > 0.2
        "warm"
    elseif valence < -0.2
        "anxious"
    else
        "vague"
    end

    frag_hint = length(fragment) > 40 ? "\"$(first(fragment, 40))…\"" : "\"$(fragment)\""

    "[DREAM | $time_str | φ=$(round(phi,digits=2)) | $emotion] " *
    "Reconstruction: $frag_hint — $tone."
end

# --- Dream Log Persistence -------------------------------------------------

function save_dream!(record::DreamRecord, path::String = DREAM_LOG_PATH)
    existing = load_dream_log(path)
    entry = Dict(
        "flash_count" => record.flash_count,
        "hour" => record.hour,
        "gap_minutes" => round(record.gap_minutes, digits = 1),
        "source" => record.source_fragment,
        "emotion" => record.emotion,
        "phi" => record.phi,
        "nt_delta" => [record.nt_delta...],
        "memory_uncert" => record.memory_uncert,
        "narrative" => record.narrative,
    )
    push!(existing, entry)
    if length(existing) > DREAM_LOG_MAX
        existing = existing[(end-DREAM_LOG_MAX+1):end]
    end
    try
        dir = dirname(path)
        isempty(dir) || isdir(dir) || mkpath(dir)
        tmp = path * ".tmp"
        open(tmp, "w") do f
            ;
            JSON3.write(f, existing);
        end
        mv(tmp, path; force = true)
    catch e
        @warn "[DREAM] Failed to save dream log: $e"
    end
end

function load_dream_log(path::String = DREAM_LOG_PATH)::Vector{Dict}
    isfile(path) || return Dict[]
    try
        data = JSON3.read(read(path, String))
        return [Dict(String(k)=>v for (k, v) in d) for d in data]
    catch
        return Dict[]
    end
end

function show_dreams(n::Int = 5, path::String = DREAM_LOG_PATH)
    log = load_dream_log(path)
    if isempty(log)
        println("  [DREAM] No dreams yet.")
        return
    end
    recent = log[max(1, end-n+1):end]
    println("\n  [DREAM] Last $(length(recent)) dreams:")
    for d in recent
        println("  ──────────────────────────────────────────────")
        println("  $(get(d,"narrative","?"))")
        println("  Source: $(get(d,"source","?"))")
        println("  φ=$(get(d,"phi","?"))  mem_uncert=$(get(d,"memory_uncert","?"))")
    end
    println()
end
