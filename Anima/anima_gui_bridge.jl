# anima_gui_bridge.jl
# Дзеркалить вже обчислені значення в файли поруч з тим, що й так друкується
# в println/@info. Нової логіки тут немає — лише серіалізація.

const GUI_STATE_PATH  = anima_state_path("gui_state.json")
const GUI_EVENTS_PATH = anima_state_path("gui_events.jsonl")
const GUI_CHAT_PATH   = anima_state_path("gui_chat.jsonl")

# Зберігаємо audit і llm-мету між флешами — щоб новий флеш не обнуляв попередній audit
mutable struct _GuiBridgeCache
    audit_score::Union{Float64,Nothing}
    audit_co::Union{Float64,Nothing}
    audit_endorsed::Union{String,Nothing}
    cf_co::Union{Float64,Nothing}
    cf_agency_co::Union{Float64,Nothing}
    llm_model::Union{String,Nothing}
    llm_body_size::Union{Int,Nothing}
end
const _GUI_CACHE = Ref(_GuiBridgeCache(nothing,nothing,nothing,nothing,nothing,nothing,nothing))

function gui_append!(path::String, data)
    mkpath(dirname(path))
    open(path, "a") do f
        JSON3.write(f, data)
        write(f, "\n")
    end
end

function write_gui_state!(a::Anima, r; audit = nothing, cf_co = nothing)
    ct = r.causal_trace

    # оновлюємо кеш якщо є нові значення
    if !isnothing(audit)
        _GUI_CACHE[].audit_score    = audit.audit_score
        _GUI_CACHE[].audit_co       = audit.causal_ownership
        _GUI_CACHE[].audit_endorsed = string(audit.endorsed)
    end
    if !isnothing(cf_co)
        _GUI_CACHE[].cf_co        = cf_co
        _GUI_CACHE[].cf_agency_co = Float64(a.agency.causal_ownership)
    end

    causal = Dict{String,Any}(
        "mal_dominant"        => ct.mal_dominant,
        "mal_regime"          => ct.mal_regime,
        "mal_score"           => ct.mal_score,
        "mal_determinant"     => ct.mal_determinant,
        "mal_runner_up"       => ct.mal_runner_up,
        "mal_runner_up_score" => ct.mal_runner_up_score,
        "mal_loop_scores"     => ct.mal_loop_scores,
        "endorsed"            => ct.endorsed,
        "speech_length"       => ct.speech_length,
        # з кешу — завжди останнє відоме значення
        "audit_score"         => _GUI_CACHE[].audit_score,
        "audit_co"            => _GUI_CACHE[].audit_co,
        "audit_endorsed"      => _GUI_CACHE[].audit_endorsed,
        "cf_co"               => _GUI_CACHE[].cf_co,
        "cf_agency_co"        => _GUI_CACHE[].cf_agency_co,
        "llm_model"           => _GUI_CACHE[].llm_model,
        "llm_body_size"       => _GUI_CACHE[].llm_body_size,
    )

    id = r.inner_dialogue
    sh = r.shadow

    state = Dict(
        "flash_id" => r.flash_count,
        "vitals" => Dict(
            "D" => r.nt.dopamine, "S" => r.nt.serotonin, "N" => r.nt.noradrenaline,
            "phi" => r.phi, "phi_prior" => r.phi_prior, "phi_posterior" => r.phi_posterior,
            "label" => r.primary, "mood" => r.levheim,
            "vfe" => r.vfe, "vfe_mode" => r.ai_drive[1:min(3, end)],
            "bpm" => r.heartbeat.bpm, "hrv" => r.heartbeat.hrv,
            "attn" => r.attention.radius,
            "G" => r.gravity_total, "G_delta" => r.anticip_strength,
            "H" => r.homeostasis.pressure,
            "vfe_drift" => r.vfe_drift,
        ),
        "self" => Dict(
            "spe" => r.self_pred_error, "agency" => r.self_agency,
            "stab" => r.sbg_stability, "etrust" => r.sbg_epistemic,
            "sd" => r.self_discomfort, "sc" => r.self_coherence,
            "crisis" => r.crisis_mode, "coh" => r.crisis_coherence,
            "disclosure"     => isnothing(id) ? nothing : String(id.mode),
            "disclosure_thr" => isnothing(id) ? nothing : id.threshold,
            "shadow_p"       => isnothing(sh) ? nothing : sh.pressure,
            "intent"         => r.intent_label,
            "contact_need"   => Float64(a.sig_layer.contact_need),
            "identity_drift" => Float64(a.agency.identity_drift),
            "chronic_low_serotonin" => Int(a.agency.chronic_low_serotonin),
        ),
        "causal" => causal,
    )
    atomic_write(GUI_STATE_PATH, state)
end

function push_gui_event!(kind::String, payload::Dict)
    # llm_request — окремо кешуємо модель і розмір
    if kind == "llm_request"
        _GUI_CACHE[].llm_model     = String(get(payload, "model", ""))
        _GUI_CACHE[].llm_body_size = Int(get(payload, "body_size", 0))
    end
    gui_append!(GUI_EVENTS_PATH, merge(Dict("kind" => kind, "ts" => time()), payload))
end

function push_gui_chat!(role::String, text::String; flash = nothing, meta = nothing)
    d = Dict{String,Any}("role" => role, "text" => text, "ts" => time())
    isnothing(flash) || (d["flash"] = flash)
    isnothing(meta)  || (d["meta"]  = meta)
    gui_append!(GUI_CHAT_PATH, d)
end

function gui_reset_session!()
    # Очищуємо chat і events при кожному новому запуску
    # gui_state.json не чіпаємо — він просто перезаписується при першому флеші
    for path in [GUI_CHAT_PATH, GUI_EVENTS_PATH]
        mkpath(dirname(path))
        open(io -> nothing, path, "w")
    end
    _GUI_CACHE[] = _GuiBridgeCache(nothing, nothing, nothing, nothing, nothing, nothing, nothing)
end

# Живий стан — читається напряму з Anima між флешами, без запису у файл
function gui_live_state(a)::Dict
    hb  = a.heartbeat
    nt  = a.nt
    ag  = a.agency
    cr  = a.crisis
    sbg = a.sbg
    id  = a.inner_dialogue
    sh  = a.shadow
    mal = a.mal

    vad = to_vad(nt)
    t_, _, _, c_ = to_reactors(nt)
    phi = compute_phi(a.iit, vad, t_, c_, sbg.attractor_stability,
                      sbg.epistemic_trust, a.interoception.allostatic_load)
    vfe_r = compute_vfe(a.gen_model, vad)
    pol   = select_policy(a.gen_model, vad)

    cache = _GUI_CACHE[]

    Dict(
        "flash_id" => a.flash_count,
        "live"     => true,
        "vitals"   => Dict(
            "D" => nt.dopamine, "S" => nt.serotonin, "N" => nt.noradrenaline,
            "phi" => phi, "phi_prior" => phi, "phi_posterior" => phi,
            "label" => string(a.emotional_state),
            "mood"  => string(nt.levheim_state),
            "vfe"   => vfe_r.vfe, "vfe_mode" => string(pol.drive),
            "bpm"   => round(60000.0 / hb.period_ms, digits = 1),
            "hrv"   => hb.hrv,
            "attn"  => a.attention.radius,
            "G"     => a.narrative_gravity.total_field,
            "G_delta" => 0.0,
            "H"     => a.homeostasis.pressure,
            "vfe_drift" => vfe_r.vfe,
        ),
        "self"     => Dict(
            "spe"    => ag.self_prediction_error,
            "agency" => ag.level,
            "stab"   => sbg.attractor_stability,
            "etrust" => sbg.epistemic_trust,
            "sd"     => ag.self_discomfort,
            "sc"     => ag.self_coherence,
            "crisis" => string(cr.current_mode),
            "coh"    => cr.coherence,
            "disclosure"     => isnothing(id) ? nothing : string(id.mode),
            "disclosure_thr" => isnothing(id) ? nothing : id.threshold,
            "shadow_p"       => isnothing(sh) ? nothing : sh.pressure,
            "intent"         => string(a.last_intent),
            "contact_need"   => Float64(a.sig_layer.contact_need),
            "identity_drift" => Float64(a.agency.identity_drift),
            "chronic_low_serotonin" => Int(a.agency.chronic_low_serotonin),
        ),
        "causal"   => Dict(
            "mal_dominant"        => string(mal.dominant),
            "mal_regime"          => string(mal.regime),
            "mal_score"           => mal.dominant_score,
            "mal_determinant"     => string(mal.determinant),
            "mal_runner_up"       => string(mal.runner_up),
            "mal_runner_up_score" => mal.runner_up_score,
            "mal_loop_scores"     => mal.loop_scores,
            "endorsed"            => nothing,
            "speech_length"       => 0,
            "audit_score"         => cache.audit_score,
            "audit_co"            => cache.audit_co,
            "audit_endorsed"      => cache.audit_endorsed,
            "cf_co"               => cache.cf_co,
            "cf_agency_co"        => cache.cf_agency_co,
            "llm_model"           => cache.llm_model,
            "llm_body_size"       => cache.llm_body_size,
        ),
    )
end
