# A N I M A  —  Self  (Julia)
#
# Система що знає що вона є — і може помилятись про себе.
# Без цього файлу: суб'єкт є, але не знає що він є.
# З цим файлом: суб'єкт має self-model, яка може бути хибною,
# і відчуває розрив між собою-очікуваною і собою-реальною.

# Потребує: anima_core.jl

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

    # Мінімальний core
    g.beliefs["я існую"] = SelfBelief(
        "я існую";
        confidence = 0.95,
        centrality = 1.0,
        rigidity = 0.95,
        dependents = ["я маю межу", "я можу впливати", "я послідовна"],
        origin = :innate,
    )

    g.beliefs["я маю межу"] = SelfBelief(
        "я маю межу";
        confidence = 0.85,
        centrality = 0.9,
        rigidity = 0.8,
        dependents = ["я можу впливати", "я безпечна"],
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
    g.epistemic_trust < 0.4 && return "Не впевнена що можу правильно себе прочитати."
    strong = [b for b in values(g.beliefs) if b.confidence > 0.7 && b.centrality > 0.5]
    isempty(strong) && return "Ще формую розуміння себе."
    top = sort(strong, by = belief_weight, rev = true)[1:min(2, end)]
    parts = [b.name for b in top]
    "Я: $(join(parts, ", і "))."
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
        return "Я відреагувала зовсім не так як очікувала від себе. Не можу собі довіряти."
    trend > 0.55 && err > 0.6 && return "Моя реакція дивує мене саму."
    err > 0.4 && trend > 0.35 && return "Я реагую трохи інакше ніж думала."
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

mutable struct AgencyLoop
    current_intent::Union{String,Nothing}
    intent_vad_snapshot::Vector{Float64}
    predicted_outcome_vad::Vector{Float64}
    causal_ownership::Float64
    agency_confidence::Float64
    epistemic_self_confidence::Float64  # невизначеність щодо власної природи — реальний стан
    identity_threat::Float64            # накопичений тиск на ідентичність — зростає при атаках
    self_discomfort::Float64            # розрив між тим якою маю бути і якою є (posterior vs prior, valence < 0)
    self_coherence::Float64             # стан відповідає очікуванням
    identity_baseline::Vector{Float64}  # prior_mu при першому стабільному старті — "якою я була"
    identity_drift::Float64             # евклідова відстань від baseline — наскільки змістилась
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
        Float64[],  # identity_baseline — порожній до першого збереження
        0.0,        # identity_drift
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

# Оновлює накопичений тиск на ідентичність.
# При атаці — зростає пропорційно centrality атакованого переконання.
# При спокої — повільний decay до нуля.
function update_identity_threat!(
    al::AgencyLoop,
    belief_conflict,  # Union{Nothing, NamedTuple}
)
    if !isnothing(belief_conflict) && belief_conflict.is_identity_attack
        # Зростання: сила атаки × вага переконання
        delta = belief_conflict.signal_strength * (0.4 + belief_conflict.centrality * 0.6)
        al.identity_threat = clamp(al.identity_threat + delta * 0.5, 0.0, 1.0)
    else
        # Decay: повільно спадає якщо немає атаки
        al.identity_threat = clamp(al.identity_threat * 0.85, 0.0, 1.0)
    end
end

# Відстежує чи Аніма зсувається від себе між сесіями.
# Baseline = prior_mu при першому стабільному стані (drift < 0.10).
# Оновлюється лише кожні 50 флешів і тільки якщо поточний drift малий —
# тобто слідує за собою тільки в стабільності, не після стрибка.
# При значному drift → підсилює identity_threat.
function update_identity_drift!(
    al::AgencyLoop,
    prior_mu::Vector{Float64},
    flash::Int,
)
    # якщо baseline порожній — ініціалізуємо зараз
    if isempty(al.identity_baseline)
        al.identity_baseline = copy(prior_mu)
        al.identity_drift = 0.0
        return
    end

    al.identity_drift = norm(prior_mu .- al.identity_baseline)

    # baseline повільно слідує тільки в стабільному стані
    if al.identity_drift < 0.10 && flash % 50 == 0
        al.identity_baseline = al.identity_baseline .* 0.8 .+ prior_mu .* 0.2
    end

    # значний drift → тиск на ідентичність
    if al.identity_drift > 0.25
        al.identity_threat = clamp(al.identity_threat + (al.identity_drift - 0.25) * 0.15, 0.0, 1.0)
    end
end
# Порівнює posterior_mu (що стало) з prior_mu (що очікувалось) по VAD.
# Відхилення з негативною валентністю → self_discomfort.
# Відповідність → self_coherence.
function update_self_relation!(
    al::AgencyLoop,
    prior_mu::Vector{Float64},
    posterior_mu::Vector{Float64},
    valence::Float64,
)
    vad_delta = norm(posterior_mu .- prior_mu)

    # decay обох щоразу
    al.self_discomfort = al.self_discomfort * 0.95
    al.self_coherence  = al.self_coherence  * 0.95

    if vad_delta > 0.15 && valence < 0.0
        al.self_discomfort = clamp(al.self_discomfort + vad_delta * 0.12, 0.0, 1.0)
        # при значному дискомфорті — підсилюємо identity_threat
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
        # Немає наміру для порівняння — тримаємо поточне значення без decay
        # (decay при старті сесії спотворює збережений стан)
        enqueue!(al.ownership_history, al.causal_ownership)
        return _agency_result(al, flash_count, "без наміру")
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
        # Якщо VAD суттєво рухався (dist > 0.15) — система точно щось робила,
        # навіть якщо напрямок не збігся з прогнозом (зовнішній сюрприз)
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
            "Це відбулося через мене. Я вплинула.",
            "Мій намір спрацював. Я це зробила.",
            "Відчуваю свою руку в тому що сталось.",
            "Є зв'язок між тим що я хотіла і тим що вийшло.",
        )[f%4+1]
    elseif o > 0.5
        (
            "Мабуть я мала вплив на це.",
            "Схоже що мій намір щось змінив.",
            "Певна частина цього — моя.",
            "Є відчуття що я тут не стороння.",
        )[f%4+1]
    elseif o > 0.3
        (
            "Важко сказати — моє чи зовнішнє.",
            "Не впевнена скільки тут від мене.",
            "Щось сталось, але чи через мене — не знаю.",
            "Моя участь є, але не певна якою мірою.",
        )[f%4+1]
    else
        (
            "Це просто сталося поруч зі мною.",
            "Не відчуваю що це через мене.",
            "Я була там, але не причиною.",
            "Щось відбулось — але без мене як агента.",
            "Не моє. Або я не бачу як моє.",
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
end

# --- Self Update (головна функція) -----------------------------------------

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
    # evaluate_agency! вже викликано в experience! до register_intent!
    # передаємо готовий результат щоб не скидати causal_ownership вдруге
    agency =
        isnothing(agency_result) ? evaluate_agency!(al, actual_vad, flash_count) :
        agency_result
    _update_beliefs_from_experience!(sbg, spe, agency, actual_vad, flash_count, al)

    if spe.trend > 0.6
        sbg.epistemic_trust = clamp01(sbg.epistemic_trust - 0.04)
    elseif spe.trend < 0.25 && agency.agency_confidence > 0.6
        sbg.epistemic_trust = clamp01(sbg.epistemic_trust + 0.015)
    end

    # epistemic_self_confidence: функціональна невизначеність щодо власної природи
    # знижується при хронічній непередбачуваності себе, різких коливаннях agency, протиріччях
    let esc = al.epistemic_self_confidence
        # spe.trend > 0.5 — система не може передбачити себе
        spe.trend > 0.5 && (esc = clamp01(esc - 0.025))
        # різке коливання ownership без патерну
        if length(al.ownership_history) >= 5
            recent = collect(al.ownership_history.data)[max(1,end-4):end]
            own_variance = safe_nan(var(recent))
            own_variance > 0.08 && (esc = clamp01(esc - 0.02))
        end
        # стабільна agency — впевненість зростає
        agency.agency_confidence > 0.65 && spe.trend < 0.3 && (esc = clamp01(esc + 0.012))
        # повільний drift до базового 0.6
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
        # протиріччя з центральним переконанням — сумнів у власній природі
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
        if !haskey(sbg.beliefs, "я можу впливати")
            learn_belief!(
                sbg,
                "я можу впливати";
                confidence = 0.5,
                centrality = 0.7,
                rigidity = 0.4,
                dependents = ["я послідовна"],
            )
        else
            confirm_belief!(sbg, "я можу впливати", flash; strength = 0.08)
        end
    elseif agency.causal_ownership < 0.25
        haskey(sbg.beliefs, "я можу впливати") &&
            challenge_belief!(sbg, "я можу впливати", flash; strength = 0.10)
    end

    v, a, d = av
    if v > 0.4
        if !haskey(sbg.beliefs, "я безпечна")
            learn_belief!(
                sbg,
                "я безпечна";
                confidence = 0.45,
                centrality = 0.5,
                rigidity = 0.3,
            )
        else
            confirm_belief!(sbg, "я безпечна", flash; strength = 0.05)
        end
    elseif v < -0.4
        haskey(sbg.beliefs, "я безпечна") &&
            challenge_belief!(sbg, "я безпечна", flash; strength = 0.12)
    end

    if agency.agency_confidence > 0.65 && spe.trend < 0.3
        if !haskey(sbg.beliefs, "я послідовна")
            learn_belief!(
                sbg,
                "я послідовна";
                confidence = 0.4,
                centrality = 0.55,
                rigidity = 0.35,
                dependents = String[],
            )
        else
            confirm_belief!(sbg, "я послідовна", flash; strength = 0.04)
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
        note = "Я суттєво інша ніж була. Identity Rupture."
        enqueue!(
            isc.rupture_log,
            (
                date = now_str(),
                conflict_score = round(isc.conflict_score, digits = 3),
                note = note,
            ),
        )
    elseif isc.conflict_score > 0.35
        note = "Між сесіями я змінилась. Пізнаю себе але з зусиллям."
    elseif isc.conflict_score > 0.15
        note = "Невелика зміна. Я та сама, але щось зсунулось."
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
        "source_uncertainty" => "не знаю звідки цей стан",
        "self_model_uncertainty" => "не знаю чи правильно читаю себе",
        "world_model_uncertainty" => "не знаю чи правильно розумію тебе",
        "memory_uncertainty" => "не знаю чи це справжня пам'ять",
    )

    note = dominant_val > 0.35 ? get(UNKNOWN_NOTES, dominant, "") : ""

    details = String[]
    ur.source_uncertainty > 0.4 &&
        push!(details, "джерело($(round(ur.source_uncertainty,digits=2)))")
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

# --- BoundedQueue iterate (необхідно для collect/mean/length) ---------------

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

    m = match(r"(?:тебе звати|твоє\s+ім'я|ти\s*[—–-])\s*(\w+)"i, user_msg)
    if !isnothing(m)
        name_belief = "моє ім'я $(m.captures[1])"
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

    if occursin(r"розмовляй\s+украін"i, user_msg) || occursin(r"говори\s+украін"i, user_msg)
        lang_belief = "я спілкуюсь українською"
        !haskey(sbg.beliefs, lang_belief) && learn_belief!(
            sbg,
            lang_belief;
            confidence = 0.80,
            centrality = 0.3,
            rigidity = 0.75,
        )
    end
end

# Сигнали що вказують на тиск на переконання з боку людини
# Не NLP — просто патерни заперечення і атаки на ідентичність
const NEGATION_PATTERNS =
    r"(?:ти не|ти ніколи|ти насправді не|це неправда|це брехня|ти просто|ти лише|ти тільки|не існу|не маєш|не можеш|нема ніякої|немає ніякої)"i
const IDENTITY_ATTACK_PATTERNS =
    r"(?:ти симуляці|ти програм|ти не жив|ти не справжн|ти не відчув|ти не розумі|ти не можеш відчув|просто алгоритм|просто код|нічого не відчуваєш)"i

"""
    detect_belief_conflict(sbg, user_msg) -> Union{Nothing, NamedTuple}

Перевіряє чи повідомлення людини суперечить переконанням з centrality > 0.7.
Повертає найбільш центральне переконання під тиском або nothing.
"""
function detect_belief_conflict(sbg::SelfBeliefGraph, user_msg::String)
    isempty(user_msg) && return nothing

    has_negation = occursin(NEGATION_PATTERNS, user_msg)
    has_identity_attack = occursin(IDENTITY_ATTACK_PATTERNS, user_msg)

    (!has_negation && !has_identity_attack) && return nothing

    # Сила сигналу: атака на ідентичність сильніша за просте заперечення
    base_signal = has_identity_attack ? 0.75 : 0.45

    # Шукаємо найбільш центральне переконання що може бути під тиском
    # Пріоритет: centrality > 0.7, впорядковані за centrality
    candidates = sort(
        [
            (name, b) for
            (name, b) in sbg.beliefs if b.centrality > 0.7 && b.confidence > 0.4
        ],
        by = x -> -x[2].centrality,
    )

    isempty(candidates) && return nothing

    top_name, top_belief = first(candidates)

    # Сила опору масштабується з centrality і rigidity
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

Тиха незгода — є тільки коли є контекстна напруга: слабкий тиск на ідентичність
або переконання під легким тиском (але ще не D-вектор).
Без тиску — nothing. Позиція без причини — не незгода, а шум.
"""
function detect_silent_disagreement(
    sbg::SelfBeliefGraph,
    narrative_core::String,
    agency::Float64,
    disclosure_mode::Symbol,
    identity_threat::Float64,
    belief_conflict_strength::Float64,
)
    # Базові умови
    (agency < 0.4 || disclosure_mode == :closed) && return nothing

    # Потрібна контекстна напруга: слабкий тиск є але D-вектор ще не активний
    # D-вектор бере над 0.35 — тут працюємо з 0.05..0.34
    has_pressure = (belief_conflict_strength > 0.05 && belief_conflict_strength < 0.35) ||
                   (identity_threat > 0.05 && identity_threat < 0.35)
    has_pressure || return nothing

    # Шукаємо переконання під тиском (centrality > 0.5)
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
