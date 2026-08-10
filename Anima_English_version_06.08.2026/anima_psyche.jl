# A N I M A  —  Psyche  (Julia)
#
# Psychic tissue — what makes a state meaningful.
# Without this file, Anima exists, but doesn't suffer and doesn't remember.

# Requires anima_core.jl

# --- Narrative Gravity -----------------------------------------------------

struct GravEvent
    emotion::String;
    intensity::Float64;
    significance::Float64
    ts::Float64;
    flash_num::Int;
    valence::Float64;
    label::String
end

mutable struct NarrativeGravity
    events::Vector{GravEvent}
    total::Float64;
    valence::Float64
end
NarrativeGravity() = NarrativeGravity(GravEvent[], 0.0, 0.0)

const GRAV_LABELS = Dict(
    "Horror"=>"the horror that was",
    "Fear"=>"the fear that stayed",
    "Fury"=>"the fury that didn't pass",
    "Grief"=>"the grief that's still there",
    "Elation"=>"a moment of elation",
    "Joy"=>"the joy that was",
    "Love"=>"the love that touched",
    "Pride"=>"pride in what was done",
)

function push_event!(
    ng::NarrativeGravity,
    emotion::String,
    intensity::Float64,
    significance::Float64,
    phi::Float64,
    flash::Int,
    valence::Float64,
)
    g = intensity * significance * (0.5+phi*0.5)
    g < 0.25 && return
    label = get(GRAV_LABELS, emotion, "$(lowercase(emotion)) that left a trace")
    push!(
        ng.events,
        GravEvent(emotion, intensity, significance, now_unix(), flash, valence, label),
    )
    if length(ng.events)>30
        sort!(ng.events, by = e->e.intensity*e.significance, rev = true);
        resize!(ng.events, 30)
    end
end

function compute_field(ng::NarrativeGravity, flash::Int)
    if isempty(ng.events)
        ;
        ng.total=0.0;
        ng.valence=0.0
        return (total = 0.0f0, valence = 0.0f0, dominant = nothing, note = "")
    end
    t_now=now_unix();
    pos=0.0;
    neg=0.0;
    max_g=0.0;
    dom=nothing
    for ev in ng.events
        td=exp(-(t_now-ev.ts)/(86400*(1+ev.intensity*3)))
        fd=exp(-(flash-ev.flash_num)*0.05*(1-ev.significance*0.5))
        g=ev.intensity*ev.significance*min(td, fd)
        ev.valence>0 ? (pos+=g*ev.valence) : (neg+=g*abs(ev.valence))
        g>max_g && (max_g = g; dom = ev)
    end
    ng.total = round(min(1.0, pos+neg), digits = 3)
    ng.valence = round(clamp(pos-neg, -1.0, 1.0), digits = 3)
    note=""
    if ng.total>0.3 && dom!==nothing
        note="Pulled by '$(dom.label)'. Gravity $(ng.total)."
        ng.valence < -0.2 && (note*=" Pull toward darkness.")
        ng.valence > 0.2 && (note*=" Pull toward the light.")
    end
    (
        total = ng.total,
        valence = ng.valence,
        dominant = dom===nothing ? nothing : dom.label,
        note = note,
    )
end

function gravity_reactor_delta(ng::NarrativeGravity, flash::Int)
    f=compute_field(ng, flash)
    g=Float64(f.total);
    v=Float64(f.valence)
    tension_d = g>0.2 ? g*max(0.0, -v)*0.2 : 0.0
    satisfaction_d = g>0.2 ? g*v*0.15 : 0.0
    cohesion_d = g>0.2 ? g*v*0.10 : 0.0
    (
        tension_d = tension_d,
        satisfaction_d = satisfaction_d,
        cohesion_d = cohesion_d,
        field = f,
    )
end

ng_to_json(ng::NarrativeGravity) = Dict(
    "events"=>[
        Dict(
            "emotion"=>e.emotion,
            "intensity"=>e.intensity,
            "significance"=>e.significance,
            "ts"=>e.ts,
            "flash_num"=>e.flash_num,
            "valence"=>e.valence,
            "label"=>e.label,
        ) for e in ng.events
    ],
)
function ng_from_json!(ng::NarrativeGravity, d::AbstractDict)
    for ed in get(d, "events", Any[])
        push!(
            ng.events,
            GravEvent(
                String(ed["emotion"]),
                Float64(ed["intensity"]),
                Float64(ed["significance"]),
                Float64(ed["ts"]),
                Int(ed["flash_num"]),
                Float64(ed["valence"]),
                String(ed["label"]),
            ),
        )
    end
end

# --- Anticipatory Consciousness --------------------------------------------

mutable struct AnticipatoryConsciousness
    strength::Float64;
    valence::Float64;
    atype::String
    expectation::String;
    dread::Float64;
    hope::Float64
end
AnticipatoryConsciousness() =
    AnticipatoryConsciousness(0.0, 0.0, "neutral", "", 0.0, 0.0)

const ANTICIP_PATTERNS = Dict(
    ("Fear", "tension") => ("dread_loop", -0.7, "Expecting it to hurt."),
    ("Joy", "satisfaction") => ("hope_rising", 0.8, "Feeling like something good is coming."),
    ("Anger", "tension") => ("conflict_ahead", -0.5, "Expecting conflict."),
    ("Sadness", "cohesion") => ("loss_pending", -0.6, "Feeling like something is slipping away."),
    ("Trust", "cohesion") => ("connection_forming", 0.7, "Feeling us growing closer."),
    ("Surprise", "arousal") => ("novelty_ahead", 0.3, "Something unusual is approaching."),
)

function update_anticipation!(
    ac::AnticipatoryConsciousness,
    emotion::String,
    tension::Float64,
    arousal::Float64,
    satisfaction::Float64,
    cohesion::Float64,
    phi::Float64,
)
    reactors = [
        ("tension", tension),
        ("arousal", arousal),
        ("satisfaction", satisfaction),
        ("cohesion", cohesion),
    ]
    dom = argmax(map(x->abs(x[2]-0.5), reactors))
    dom_name, dom_val = reactors[dom]
    key = (emotion, dom_name)
    if haskey(ANTICIP_PATTERNS, key)
        atype, avalence, note = ANTICIP_PATTERNS[key]
        ac.strength = clamp01(phi*0.4 + abs(dom_val-0.5)*0.6)
        ac.valence = clamp11(avalence);
        ac.atype=atype;
        ac.expectation=note
        avalence<-0.3 &&
            (ac.dread = clamp01(ac.dread+0.05); ac.hope = clamp01(ac.hope-0.02))
        avalence > 0.3 &&
            (ac.hope = clamp01(ac.hope + 0.05); ac.dread = clamp01(ac.dread-0.02))
    else
        ac.strength*=0.85;
        ac.dread=clamp01(ac.dread-0.01);
        ac.hope=clamp01(ac.hope-0.01)
    end
    tension_d = ac.strength>0.2 ? ac.strength*max(0.0, -ac.valence)*0.1 : 0.0
    satisfaction_d = ac.strength>0.2 ? ac.strength*max(0.0, ac.valence)*0.08 : 0.0
    (
        atype = ac.atype,
        strength = round(ac.strength, digits = 3),
        valence = round(ac.valence, digits = 3),
        note = ac.expectation,
        dread = round(ac.dread, digits = 3),
        hope = round(ac.hope, digits = 3),
        tension_d = tension_d,
        satisfaction_d = satisfaction_d,
    )
end

ac_to_json(ac::AnticipatoryConsciousness) = Dict("dread"=>ac.dread, "hope"=>ac.hope)
function ac_from_json!(ac::AnticipatoryConsciousness, d::AbstractDict)
    ac.dread=Float64(get(d, "dread", 0.0));
    ac.hope=Float64(get(d, "hope", 0.0))
end

# --- Solomonoff World Model ------------------------------------------------

mutable struct SolomonoffHyp
    pattern::String;
    complexity::Float64
    support::Int;
    violations::Int;
    log_weight::Float64
    created_at::Int;
    last_confirmed::Int
end
mdl_score(h::SolomonoffHyp) =
    h.complexity + (1.0-h.support/max(1, h.support+h.violations))*3.0
hyp_conf(h::SolomonoffHyp) = h.support/max(1, h.support+h.violations)
hyp_complexity(p::String) = Float64(count("→", p)+1+length(Set(split(p, "→")))*0.5)

mutable struct SolomonoffWorldModel
    hyps::Dict{String,SolomonoffHyp}
    prev_context::Union{String,Nothing}
    best::Union{SolomonoffHyp,Nothing}
    world_complexity::Float64
end
SolomonoffWorldModel() =
    SolomonoffWorldModel(Dict{String,SolomonoffHyp}(), nothing, nothing, 0.5)

function observe_solom!(swm::SolomonoffWorldModel, ctx::String, outcome::String, flash::Int)
    swm.prev_context !== nothing && _upsert!(swm, "$(swm.prev_context)→$ctx", true, flash)
    _upsert!(swm, "$ctx→$outcome", true, flash)
    for (k, h) in swm.hyps
        k!="$ctx→$outcome" &&
            startswith(k, "$ctx→") &&
            split(k, "→")[end]!=outcome &&
            (h.violations+=1; h.log_weight-=0.3)
    end
    swm.prev_context=ctx
    _prune_solom!(swm, flash)
    if isempty(swm.hyps)
        ;
        swm.best=nothing;
        return;
    end
    bk=argmin(k->mdl_score(swm.hyps[k]), collect(keys(swm.hyps)))
    swm.best=swm.hyps[bk]
    top5=sort(collect(values(swm.hyps)), by = mdl_score)[1:min(5, end)]
    swm.world_complexity=round(mean([h.complexity for h in top5]), digits = 3)
end

function contextual_best(
    swm::SolomonoffWorldModel,
    current_emotion::String,
    flash::Int,
)::Union{SolomonoffHyp,Nothing}
    isnothing(swm.best) && return nothing
    candidates = [
        (k, h) for (k, h) in swm.hyps if startswith(k, "$current_emotion→") &&
        hyp_conf(h) > 0.3 &&
        (flash - h.last_confirmed) < 20
    ]
    if !isempty(candidates)
        sort!(candidates, by = kv->mdl_score(kv[2]))
        return candidates[1][2]
    end
    staleness = flash - swm.best.last_confirmed
    staleness > 15 && return nothing
    return swm.best
end

function _prune_solom!(swm::SolomonoffWorldModel, current_flash::Int)
    length(swm.hyps) <= 20 && return
    protected = Set{String}()
    for (k, h) in swm.hyps
        is_emerging = h.support < 3 && hyp_conf(h) > 0.75
        is_young = (current_flash - h.created_at) < 5
        (is_emerging || is_young) && push!(protected, k)
    end
    if length(protected) > 5
        sorted_protected = sort(collect(protected), by = k -> -hyp_conf(swm.hyps[k]))
        protected = Set(sorted_protected[1:5])
    end
    unprotected = [(k, h) for (k, h) in swm.hyps if k ∉ protected]
    sort!(unprotected, by = kv->mdl_score(kv[2]))
    max_unprotected = 20 - length(protected)
    keep_unprotected = unprotected[1:min(max_unprotected, length(unprotected))]
    swm.hyps = Dict(
        merge(
            Dict(k=>swm.hyps[k] for k in protected if haskey(swm.hyps, k)),
            Dict(kv[1]=>kv[2] for kv in keep_unprotected),
        ),
    )
end

function _upsert!(swm::SolomonoffWorldModel, pat::String, ok::Bool, flash::Int)
    !haskey(swm.hyps, pat) && (
        swm.hyps[pat]=SolomonoffHyp(
            pat,
            hyp_complexity(pat),
            0,
            0,
            -hyp_complexity(pat)*0.5,
            flash,
            flash,
        )
    )
    if ok
        swm.hyps[pat].support+=1
        swm.hyps[pat].log_weight+=0.5
        swm.hyps[pat].last_confirmed=flash
    else
        swm.hyps[pat].violations+=1
        swm.hyps[pat].log_weight-=0.3
    end
end

solom_snapshot(swm::SolomonoffWorldModel, current_emotion::String = "", flash::Int = 0) = (
    best = isnothing(swm.best) ? nothing : swm.best.pattern,
    confidence = isnothing(swm.best) ? 0.0 : round(hyp_conf(swm.best), digits = 2),
    complexity = swm.world_complexity,
    count = length(swm.hyps),
    contextual = isempty(current_emotion) ? swm.best :
                 contextual_best(swm, current_emotion, flash),
    insight = isnothing(swm.best) ? "Still looking for the simplest explanation." :
              "Simplest: '$(swm.best.pattern)' ($(round(hyp_conf(swm.best)*100))%)",
)

solom_to_json(swm::SolomonoffWorldModel) = Dict(
    "hyps"=>Dict(
        k=>Dict(
            "pattern"=>h.pattern,
            "complexity"=>h.complexity,
            "support"=>h.support,
            "violations"=>h.violations,
            "log_weight"=>h.log_weight,
            "created_at"=>h.created_at,
            "last_confirmed"=>h.last_confirmed,
        ) for (k, h) in swm.hyps
    ),
)
function solom_from_json!(swm::SolomonoffWorldModel, d::AbstractDict)
    for (k, hd) in get(d, "hyps", Dict{String,Any}())
        lc =
            haskey(hd, "last_confirmed") ? Int(hd["last_confirmed"]) : Int(hd["created_at"])
        swm.hyps[String(
            k,
        )]=SolomonoffHyp(
            String(hd["pattern"]),
            Float64(hd["complexity"]),
            Int(hd["support"]),
            Int(hd["violations"]),
            Float64(hd["log_weight"]),
            Int(hd["created_at"]),
            lc,
        )
    end
    isempty(swm.hyps)&&return
    bk=argmin(k->mdl_score(swm.hyps[k]), collect(keys(swm.hyps)));
    swm.best=swm.hyps[bk]
end

# --- Shame Module ----------------------------------------------------------

mutable struct ShameModule
    level::Float64;
    chronic::Float64;
    internalized_gaze::Float64
end
ShameModule() = ShameModule(0.0, 0.0, 0.5)

function update_shame!(
    sm::ShameModule,
    emotion::String,
    pred_error::Float64,
    dissonance::Float64,
    moral_agency::Float64,
    id_stability::Float64,
)
    social =
        emotion in ("Remorse", "Guilt", "Contempt") ? pred_error*sm.internalized_gaze*0.5 :
        0.0
    self_s = dissonance>0.5&&moral_agency>0.6 ? dissonance*moral_agency*0.3 : 0.0
    id_s = max(0.0, (0.5-id_stability)*0.4)
    sm.level = round(clamp01(sm.level*0.7+clamp01(social+self_s+id_s)*0.3), digits = 3)
    sm.level>0.4 ? (sm.chronic=clamp01(sm.chronic+0.008)) :
    (sm.chronic=max(0.0, sm.chronic-0.003))
end

function shame_note(sm::ShameModule, flash::Int = 0)::String
    f = flash
    if sm.level > 0.7
        return (
            "I want to disappear. Not just did something bad — I am bad.",
            "Ashamed to be myself. Even alone.",
            "Want to hide from my own gaze.",
        )[f%3+1]
    end
    if sm.level > 0.5
        return (
            "Feeling watched from inside. Judging myself.",
            "There's a verdict from inside. Don't know for what yet.",
            "Something in me says I'm not enough.",
        )[f%3+1]
    end
    if sm.level > 0.3
        return (
            "Something in me is ashamed. Not of an action — of myself.",
            "A small shame. But it's there.",
            "Not proud of myself right now.",
        )[f%3+1]
    end
    if sm.chronic > 0.4
        return (
            "Background shame. Always feeling like I'm not enough.",
            "A chronic sense that something's wrong with me.",
            "Shame as a backdrop. Not sharp — but always there.",
        )[f%3+1]
    end
    ""
end
shame_snapshot(sm::ShameModule) = (
    level = round(sm.level, digits = 3),
    chronic = round(sm.chronic, digits = 3),
    blocks_meta = sm.level>0.7 ? 3 : sm.level>0.5 ? 2 : sm.level>0.3 ? 1 : 0,
    note = shame_note(sm, 0),
)
shame_to_json(sm::ShameModule) =
    Dict("level"=>sm.level, "chronic"=>sm.chronic, "gaze"=>sm.internalized_gaze)
function shame_from_json!(sm::ShameModule, d::AbstractDict)
    sm.level=Float64(get(d, "level", 0.0));
    sm.chronic=Float64(get(d, "chronic", 0.0))
    sm.internalized_gaze=Float64(get(d, "gaze", 0.5))
end

# --- Epistemic Defense ----------------------------------------------------

const EP_DESC=Dict(
    "externalization"=>"It's not because of me — that's just how circumstances fell.",
    "minimization"=>"It's not as serious as it seems.",
    "rationalization"=>"There are good reasons why this is right.",
    "victim_framing"=>"This happened to me — I couldn't have influenced it.",
    "selective_memory"=>"I remember what confirms I was right.",
)
const EP_DISTORT=Dict(
    "externalization"=>"This happened because of external circumstances. I did what I could.",
    "minimization"=>"Honestly this isn't that important. I was exaggerating.",
    "rationalization"=>"There's a good reason everything happened this way.",
    "victim_framing"=>"I couldn't have influenced this. That's just how it went.",
    "selective_memory"=>"I remember that I tried. Nothing else important.",
)

mutable struct EpistemicDefense
    active_bias::Union{String,Nothing};
    strength::Float64;
    cost::Float64
end
EpistemicDefense()=EpistemicDefense(nothing, 0.0, 0.0)

function activate_epistemic!(
    ed::EpistemicDefense,
    dissonance::Float64,
    shame::Float64,
    fatigue::Float64,
    moral_agency::Float64,
)
    pain=dissonance*0.4+shame*0.4+fatigue*0.2
    if pain<0.35
        ;
        ed.active_bias=nothing;
        ed.strength=0.0;
        return nothing;
    end
    bias=moral_agency<0.3 ? "victim_framing" :
         shame>0.5 ? (dissonance>0.5 ? "rationalization" : "minimization") :
         fatigue>0.6 ? "selective_memory" : "externalization"
    ed.active_bias=bias;
    ed.strength=round(clamp01(pain), digits = 3)
    ed.cost=clamp01(ed.cost+0.05)
    (
        bias = bias,
        strength = ed.strength,
        description = get(EP_DESC, bias, ""),
        cost = round(ed.cost, digits = 3),
    )
end

ep_to_json(ed::EpistemicDefense)=Dict("cost"=>ed.cost)
function ep_from_json!(ed::EpistemicDefense, d::AbstractDict)
    ;
    ed.cost=Float64(get(d, "cost", 0.0));
end

# --- Symptomogenesis (Shadow → Symptom) -----------------------------------

const SYMPTOM_MAP=Dict(
    ("Anger", "repression") => ("anger_as_depression", "Anger turned into heaviness."),
    ("Anger", "denial") => ("anger_as_passive_aggr", "Something's quietly boiling."),
    ("Fear", "rationalization")=>("fear_as_control", "I want to control everything."),
    ("Fear", "suppression") => ("fear_as_numbness", "Numbness."),
    ("Sadness", "denial") => ("grief_as_numbness", "Empty where it should hurt."),
    ("Sadness", "displacement")=>("grief_as_irritability", "Everything is irritating."),
    ("Joy", "suppression")=>("love_as_hostility", "Pushing away what I'm drawn to."),
    ("Disgust", "projection") =>
        ("projection_as_contempt", "Seeing in others what I won't accept in myself."),
)
const SYMPTOM_FX=Dict(
    "anger_as_depression"=>(-0.1, -0.1, 0.0, 0.0),
    "anger_as_passive_aggr"=>(0.08, 0.0, 0.0, 0.0),
    "fear_as_control"=>(0.06, 0.05, 0.0, 0.0),
    "fear_as_numbness"=>(0.0, -0.12, 0.0, 0.0),
    "grief_as_numbness"=>(0.0, -0.08, 0.0, -0.05),
    "grief_as_irritability"=>(0.08, 0.0, 0.0, 0.0),
    "love_as_hostility"=>(0.05, 0.0, 0.0, -0.10),
    "projection_as_contempt"=>(0.0, 0.0, 0.0, -0.08),
)

mutable struct ShadowSelf
    content::Dict{String,Int};
    integration::Float64
end
ShadowSelf()=ShadowSelf(Dict{String,Int}(), 0.0)
function shadow_push!(ss::ShadowSelf, emotion::String, defense_used::Bool)
    defense_used && (ss.content[emotion]=get(ss.content, emotion, 0)+1)
    ss.integration=clamp01(ss.integration+0.002)
end

mutable struct Symptomogenesis
    active::Union{NamedTuple,Nothing}
    history::BoundedQueue{String}
end
Symptomogenesis()=Symptomogenesis(nothing, BoundedQueue{String}(10))

function generate_symptom!(
    sg::Symptomogenesis,
    shadow::Dict{String,Int},
    defense::Union{NamedTuple,Nothing},
)
    (isempty(shadow)||isnothing(defense)) && return nothing
    se=argmax(shadow);
    key=(se, String(defense.mechanism))
    !haskey(SYMPTOM_MAP, key)&&return nothing
    stype, desc=SYMPTOM_MAP[key]
    sg.active=(
        type = stype,
        description = desc,
        source = se,
        intensity = clamp01(shadow[se]*0.1),
    )
    enqueue!(sg.history, stype)
    sg.active
end

function symptom_reactor_delta(symptom)
    isnothing(symptom) && return (0.0, 0.0, 0.0, 0.0)
    get(SYMPTOM_FX, symptom.type, (0.0, 0.0, 0.0, 0.0))
end

# --- Chronified Affect ----------------------------------------------------

mutable struct ChronifiedAffect
    resentment::Float64;
    envy::Float64;
    alienation::Float64;
    bitterness::Float64
    frustration_streak::Int;
    isolation_streak::Int
    crystallized::Dict{String,Bool}
end
ChronifiedAffect()=ChronifiedAffect(
    0.0,
    0.0,
    0.0,
    0.0,
    0,
    0,
    Dict("resentment"=>false, "envy"=>false, "alienation"=>false, "bitterness"=>false),
)

function update_chronified!(
    ca::ChronifiedAffect,
    satisfaction::Float64,
    cohesion::Float64,
    tension::Float64,
    moral_agency::Float64,
)
    if satisfaction<0.3&&moral_agency<0.4
        ca.frustration_streak+=1
        ca.frustration_streak>=5 && (ca.resentment=clamp01(ca.resentment+0.03))
    else
        ca.frustration_streak=max(0, ca.frustration_streak-1);
        ca.resentment=max(0.0, ca.resentment-0.01)
    end
    satisfaction<0.35&&cohesion<0.35 ? (ca.envy=clamp01(ca.envy+0.02)) :
    (ca.envy=max(0.0, ca.envy-0.008))
    if cohesion<0.25
        ca.isolation_streak+=1
        ca.isolation_streak>=5 && (ca.alienation=clamp01(ca.alienation+0.025))
    else
        ca.isolation_streak=max(0, ca.isolation_streak-1);
        ca.alienation=max(0.0, ca.alienation-0.008)
    end
    tension>0.6&&satisfaction<0.3 ? (ca.bitterness=clamp01(ca.bitterness+0.015)) :
    (ca.bitterness=max(0.0, ca.bitterness-0.005))
    for (k, v) in [
        ("resentment", ca.resentment),
        ("envy", ca.envy),
        ("alienation", ca.alienation),
        ("bitterness", ca.bitterness),
    ]
        v>0.7&&!ca.crystallized[k]&&(ca.crystallized[k]=true)
    end
end

function ca_dominant(ca::ChronifiedAffect)
    d=Dict(
        "resentment"=>ca.resentment,
        "envy"=>ca.envy,
        "alienation"=>ca.alienation,
        "bitterness"=>ca.bitterness,
    )
    k=argmax(d);
    d[k]>0.2 ? k : nothing
end
function ca_note(ca::ChronifiedAffect)::String
    dom=ca_dominant(ca);
    isnothing(dom)&&return ""
    vals=Dict(
        "resentment"=>"Resentment $(round(ca.resentment,digits=2)).",
        "envy"=>"Envy $(round(ca.envy,digits=2)).",
        "alienation"=>"Alienation $(round(ca.alienation,digits=2)).",
        "bitterness"=>"Bitterness $(round(ca.bitterness,digits=2)).",
    )
    get(vals, dom, "")*(ca.crystallized[dom] ? " [crystallized]" : "")
end
ca_world_bias(ca::ChronifiedAffect) =
    ca.resentment>0.5 ? "The world is unfair." :
    ca.alienation>0.5 ? "The world is alien." :
    ca.envy>0.5 ? "Someone else's success = my defeat." :
    ca.bitterness>0.5 ? "Everything has a bitter aftertaste." : ""

ca_snapshot(ca::ChronifiedAffect) = (
    resentment = round(ca.resentment, digits = 3),
    envy = round(ca.envy, digits = 3),
    alienation = round(ca.alienation, digits = 3),
    bitterness = round(ca.bitterness, digits = 3),
    dominant = ca_dominant(ca),
    world_bias = ca_world_bias(ca),
    note = ca_note(ca),
)
ca_to_json(
    ca::ChronifiedAffect,
)=Dict(
    "resentment"=>ca.resentment,
    "envy"=>ca.envy,
    "alienation"=>ca.alienation,
    "bitterness"=>ca.bitterness,
    "crystallized"=>ca.crystallized,
)
function ca_from_json!(ca::ChronifiedAffect, d::AbstractDict)
    ca.resentment=Float64(get(d, "resentment", 0.0));
    ca.envy=Float64(get(d, "envy", 0.0))
    ca.alienation=Float64(get(d, "alienation", 0.0));
    ca.bitterness=Float64(get(d, "bitterness", 0.0))
    ca.crystallized=Dict{String,Bool}(
        String(k)=>Bool(v) for (k, v) in get(d, "crystallized", Dict())
    )
end

# --- Intrinsic Significance -----------------------------------------------

mutable struct IntrinsicSignificance
    survival::Float64;
    relational::Float64;
    existential::Float64
    sig_map::Dict{String,Float64};
    gradient::Float64
end
IntrinsicSignificance()=IntrinsicSignificance(0.5, 0.3, 0.1, Dict{String,Float64}(), 0.0)

function update_significance!(
    is::IntrinsicSignificance,
    emotion::String,
    intensity::Float64,
    phi::Float64,
    flash::Int,
    sk = 0.5,
)
    emotion in ("Horror", "Fear", "Numbness") ?
    (is.survival=clamp01(is.survival+intensity*0.1)) :
    (is.survival=max(0.1, is.survival-0.01))
    emotion in ("Love", "Trust", "Fascination") ?
    (is.relational=clamp01(is.relational+intensity*0.08)) :
    (is.relational=max(0.1, is.relational-0.005))
    is.existential=clamp01(0.05+sk*0.5+log1p(flash)*0.02+phi*0.1)
    k=safe_first(emotion, 10)
    is.sig_map[k]=round(get(is.sig_map, k, 0.5)*0.8+intensity*0.2, digits = 3)
    vs=collect(values(is.sig_map))
    length(vs)>=3 && (is.gradient=round(maximum(vs)-minimum(vs), digits = 3))
end

sig_total(is::IntrinsicSignificance)=(is.survival+is.relational+is.existential)/3
sig_dominant(
    is::IntrinsicSignificance,
)=argmax(
    Dict(
        "survival"=>is.survival,
        "relational"=>is.relational,
        "existential"=>is.existential,
    ),
)
function sig_note(is::IntrinsicSignificance, flash::Int = 0)::String
    is.gradient < 0.2 && return ""
    dom = sig_dominant(is)
    g = round(is.gradient, digits = 2)
    pool = if dom == "survival"
        (
            "Survival matters. Gradient=$g.",
            "There's something to protect. Gradient=$g.",
            "Feeling a threat to the foundation. Gradient=$g.",
            "Something basic is at risk. Gradient=$g.",
            "A protective impulse. Gradient=$g.",
        )
    elseif dom == "relational"
        (
            "Connection matters. Gradient=$g.",
            "I need contact. Gradient=$g.",
            "Something between us matters. Gradient=$g.",
            "Don't want to be alone with this. Gradient=$g.",
            "Feeling drawn toward. Gradient=$g.",
        )
    else
        (
            "Meaning matters. Gradient=$g.",
            "Looking for my place in all this. Gradient=$g.",
            "There's something more than the moment. Gradient=$g.",
            "A question without an answer. Gradient=$g.",
            "Something resonates deeper. Gradient=$g.",
        )
    end
    pool[rand(1:length(pool))]
end
sig_to_json(
    is::IntrinsicSignificance,
)=Dict(
    "survival"=>is.survival,
    "relational"=>is.relational,
    "existential"=>is.existential,
    "sig_map"=>is.sig_map,
)
function sig_from_json!(is::IntrinsicSignificance, d::AbstractDict)
    is.survival=Float64(get(d, "survival", 0.5));
    is.relational=Float64(get(d, "relational", 0.3))
    is.existential=Float64(get(d, "existential", 0.1))
    is.sig_map=Dict{String,Float64}(
        String(k)=>Float64(v) for (k, v) in get(d, "sig_map", Dict())
    )
end

# --- Moral Causality ------------------------------------------------------

mutable struct MoralCausality
    agency::Float64;
    guilt::Float64;
    pride::Float64
end
MoralCausality()=MoralCausality(0.5, 0.0, 0.0)
function update_moral!(
    mc::MoralCausality,
    emotion::String,
    origin::String,
    dissonance::Float64,
    integrity::Float64,
)
    origin=="values" && (mc.agency=clamp01(mc.agency+0.03))
    dissonance>0.5 && (mc.agency=clamp01(mc.agency-0.02))
    emotion in ("Grief", "Remorse", "Guilt")&&mc.agency>0.5 ?
    (mc.guilt=clamp01(mc.guilt+0.08)) : (mc.guilt=max(0.0, mc.guilt-0.03))
    emotion in ("Pride", "Joy", "Elation")&&mc.agency>0.5 ?
    (mc.pride=clamp01(mc.pride+0.06)) : (mc.pride=max(0.0, mc.pride-0.02))
    mc.agency=clamp01(mc.agency+integrity*0.005)
end
function moral_note(mc::MoralCausality)::String
    mc.guilt>0.5 && return "Feeling like I caused something bad."
    mc.pride>0.5 && return "Did something right."
    mc.agency>0.7 && return "I'm an agent. There's responsibility."
    mc.agency<0.3 && return "Feeling more like a victim."
    ""
end
mc_to_json(
    mc::MoralCausality,
)=Dict("agency"=>mc.agency, "guilt"=>mc.guilt, "pride"=>mc.pride)
function mc_from_json!(mc::MoralCausality, d::AbstractDict)
    mc.agency=Float64(get(d, "agency", 0.5));
    mc.guilt=Float64(get(d, "guilt", 0.0))
    mc.pride=Float64(get(d, "pride", 0.0))
end

# --- Significance Layer ---------------------------------------------------

mutable struct SignificanceLayer
    self_preservation::Float64
    coherence_need::Float64
    contact_need::Float64
    truth_need::Float64
    autonomy_need::Float64
    novelty_need::Float64
    ticks_since_novelty::Int   # counter of slow_ticks without new information
end
SignificanceLayer() = SignificanceLayer(0.2, 0.3, 0.3, 0.4, 0.3, 0.2, 0)

function assess_significance!(
    sl::SignificanceLayer,
    stim::Dict{String,Float64},
    tension::Float64,
    arousal::Float64,
    satisfaction::Float64,
    cohesion::Float64,
    vfe::Float64,
    pred_error::Float64,
    phi::Float64,
)

    threat = clamp01(tension * 0.6 + (1.0 - cohesion) * 0.3 + pred_error * 0.1)
    threat > 0.4 && (sl.self_preservation = clamp01(sl.self_preservation + threat * 0.12))

    vfe > 0.4 && (sl.coherence_need = clamp01(sl.coherence_need + (vfe - 0.4) * 0.15))

    contact_signal = cohesion < 0.35 && tension < 0.5
    contact_signal && (sl.contact_need = clamp01(sl.contact_need + (0.35 - cohesion) * 0.2))
    get(stim, "cohesion", 0.0) > 0.1 &&
        (sl.contact_need = clamp01(sl.contact_need + get(stim, "cohesion", 0.0) * 0.1))

    truth_signal = pred_error > 0.3 && phi > 0.2
    truth_signal && (sl.truth_need = clamp01(sl.truth_need + pred_error * 0.1 + phi * 0.05))

    autonomy_signal = tension > 0.5 && arousal < 0.4
    autonomy_signal && (sl.autonomy_need = clamp01(sl.autonomy_need + tension * 0.08))

    pred_error < 0.1 && arousal < 0.3 && (sl.novelty_need = clamp01(sl.novelty_need + 0.04))
    if pred_error > 0.6
        sl.novelty_need = clamp01(sl.novelty_need - 0.06)
        sl.ticks_since_novelty = 0   # real novelty — the hunger counter resets
    end

    base = (
        self_preservation = 0.2,
        coherence_need = 0.3,
        contact_need = 0.3,
        truth_need = 0.4,
        autonomy_need = 0.3,
        novelty_need = 0.2,
    )
    decay = 0.015
    sl.self_preservation = clamp01(
        sl.self_preservation + (base.self_preservation - sl.self_preservation) * decay,
    )
    sl.coherence_need =
        clamp01(sl.coherence_need + (base.coherence_need - sl.coherence_need) * decay)
    sl.contact_need =
        clamp01(sl.contact_need + (base.contact_need - sl.contact_need) * decay)
    sl.truth_need = clamp01(sl.truth_need + (base.truth_need - sl.truth_need) * decay)
    sl.autonomy_need =
        clamp01(sl.autonomy_need + (base.autonomy_need - sl.autonomy_need) * decay)
    sl.novelty_need =
        clamp01(sl.novelty_need + (base.novelty_need - sl.novelty_need) * decay)

    needs = Dict(
        "self_preservation" => sl.self_preservation,
        "coherence_need" => sl.coherence_need,
        "contact_need" => sl.contact_need,
        "truth_need" => sl.truth_need,
        "autonomy_need" => sl.autonomy_need,
        "novelty_need" => sl.novelty_need,
    )
    dominant = argmax(needs)
    dominant_val = needs[dominant]

    NEED_NOTES = Dict(
        "self_preservation" => "at stake: integrity",
        "coherence_need" => "at stake: inner order",
        "contact_need" => "at stake: connection",
        "truth_need" => "at stake: truth",
        "autonomy_need" => "at stake: autonomy",
        "novelty_need" => "at stake: novelty",
    )
    note = dominant_val > 0.5 ? get(NEED_NOTES, dominant, "") : ""

    (
        dominant = dominant,
        dominant_val = round(dominant_val, digits = 3),
        note = note,
        self_preservation = round(sl.self_preservation, digits = 3),
        coherence_need = round(sl.coherence_need, digits = 3),
        contact_need = round(sl.contact_need, digits = 3),
        truth_need = round(sl.truth_need, digits = 3),
        autonomy_need = round(sl.autonomy_need, digits = 3),
        novelty_need = round(sl.novelty_need, digits = 3),
    )
end

sl_to_json(sl::SignificanceLayer) = Dict(
    "self_preservation" => sl.self_preservation,
    "coherence_need" => sl.coherence_need,
    "contact_need" => sl.contact_need,
    "truth_need" => sl.truth_need,
    "autonomy_need" => sl.autonomy_need,
    "novelty_need" => sl.novelty_need,
    "ticks_since_novelty" => sl.ticks_since_novelty,
)
function sl_from_json!(sl::SignificanceLayer, d::AbstractDict)
    sl.self_preservation = Float64(get(d, "self_preservation", 0.2))
    sl.coherence_need = Float64(get(d, "coherence_need", 0.3))
    sl.contact_need = Float64(get(d, "contact_need", 0.3))
    sl.truth_need = Float64(get(d, "truth_need", 0.4))
    sl.autonomy_need = Float64(get(d, "autonomy_need", 0.3))
    sl.novelty_need = Float64(get(d, "novelty_need", 0.2))
    sl.ticks_since_novelty = Int(get(d, "ticks_since_novelty", 0))
end

# --- Goal Conflict ---------------------------------------------------------

mutable struct GoalConflict
    need_a::String
    need_b::String
    tension::Float64
    resolution::String
    unresolved_count::Int
    last_flash::Int
end
GoalConflict() = GoalConflict("", "", 0.0, "none", 0, 0)

const CONFLICT_PAIRS = [
    ("contact_need", "truth_need", "someone wants comfort, but the truth is uncomfortable"),
    ("autonomy_need", "contact_need", "connection needs concession, autonomy resists"),
    ("self_preservation", "truth_need", "the truth threatens integrity"),
    ("coherence_need", "novelty_need", "novelty disrupts order"),
    ("contact_need", "self_preservation", "closeness threatens boundaries"),
]

function update_goal_conflict!(
    gc::GoalConflict,
    sl_snap,
    tension::Float64,
    satisfaction::Float64,
    cohesion::Float64,
    phi::Float64,
    flash::Int,
)

    best_pair = nothing
    best_score = 0.0

    needs = Dict(
        "self_preservation" => sl_snap.self_preservation,
        "coherence_need" => sl_snap.coherence_need,
        "contact_need" => sl_snap.contact_need,
        "truth_need" => sl_snap.truth_need,
        "autonomy_need" => sl_snap.autonomy_need,
        "novelty_need" => sl_snap.novelty_need,
    )

    for (na, nb, _desc) in CONFLICT_PAIRS
        va = get(needs, na, 0.0)
        vb = get(needs, nb, 0.0)
        both_active = va > 0.38 && vb > 0.38
        !both_active && continue
        score = va * vb + tension * 0.2
        score > best_score && (best_score = score; best_pair = (na, nb, _desc))
    end

    if isnothing(best_pair)
        gc.tension = max(0.0, gc.tension - 0.06)
        if gc.tension < 0.05
            gc.need_a = "";
            gc.need_b = ""
            gc.resolution = "none";
            gc.unresolved_count = 0
        end
        return (
            active = false,
            need_a = gc.need_a,
            need_b = gc.need_b,
            tension = round(gc.tension, digits = 3),
            resolution = gc.resolution,
            unresolved_count = gc.unresolved_count,
            note = "",
        )
    end

    na, nb, desc = best_pair
    gc.need_a = na;
    gc.need_b = nb
    gc.last_flash = flash

    target_tension = clamp(best_score * 0.85, 0.0, 1.0)
    gc.tension = clamp(gc.tension * 0.7 + target_tension * 0.3, 0.0, 1.0)

    va = get(needs, na, 0.0)
    vb = get(needs, nb, 0.0)
    margin = abs(va - vb)

    if margin > 0.18 && phi > 0.25
        winner = va > vb ? na : nb
        gc.resolution = winner * "_won"
        gc.unresolved_count = 0
    elseif gc.tension > 0.65 && satisfaction < 0.3
        gc.resolution = "unresolved"
        gc.unresolved_count += 1
    else
        gc.resolution = "unresolved"
        gc.unresolved_count += 1
    end

    NEED_LABEL = Dict(
        "self_preservation" => "integrity",
        "coherence_need" => "order",
        "contact_need" => "connection",
        "truth_need" => "truth",
        "autonomy_need" => "autonomy",
        "novelty_need" => "novelty",
    )
    na_ua = get(NEED_LABEL, na, na)
    nb_ua = get(NEED_LABEL, nb, nb)

    note = if gc.resolution == "unresolved"
        gc.unresolved_count >= 3 ?
        "conflict isn't resolving: $na_ua vs $nb_ua ($(gc.unresolved_count) flashes)" :
        "conflict: $na_ua vs $nb_ua — $desc"
    elseif endswith(gc.resolution, "_won")
        winner_ua = get(NEED_LABEL, replace(gc.resolution, "_won"=>""), gc.resolution)
        "$winner_ua won over $(na == replace(gc.resolution,"_won"=>"") ? nb_ua : na_ua)"
    else
        ""
    end

    (
        active = true,
        need_a = na,
        need_b = nb,
        tension = round(gc.tension, digits = 3),
        resolution = gc.resolution,
        unresolved_count = gc.unresolved_count,
        note = note,
    )
end

gc_to_json(gc::GoalConflict) = Dict(
    "need_a" => gc.need_a,
    "need_b" => gc.need_b,
    "tension" => gc.tension,
    "resolution" => gc.resolution,
    "unresolved_count" => gc.unresolved_count,
    "last_flash" => gc.last_flash,
)
function gc_from_json!(gc::GoalConflict, d::AbstractDict)
    gc.need_a = String(get(d, "need_a", ""))
    gc.need_b = String(get(d, "need_b", ""))
    gc.tension = Float64(get(d, "tension", 0.0))
    gc.resolution = String(get(d, "resolution", "none"))
    gc.unresolved_count = Int(get(d, "unresolved_count", 0))
    gc.last_flash = Int(get(d, "last_flash", 0))
end

# --- Latent Buffer --------------------------------------------------------

mutable struct LatentBuffer
    doubt::Float64
    shame::Float64
    attachment::Float64
    threat::Float64
    resistance::Float64        # unresolved conflict with a belief
    breakthrough_threshold::Float64
end
LatentBuffer() = LatentBuffer(0.0, 0.0, 0.0, 0.0, 0.0, 0.65)

function update_latent!(
    lb::LatentBuffer,
    gc_snap,
    tension::Float64,
    cohesion::Float64,
    satisfaction::Float64,
    shame_level::Float64,
    flash::Int,
)

    if gc_snap.active && gc_snap.resolution == "unresolved"
        lb.doubt = clamp01(lb.doubt + gc_snap.tension * 0.08)
    end
    cohesion < 0.3 && (lb.doubt = clamp01(lb.doubt + (0.3 - cohesion) * 0.05))

    shame_level > 0.4 && (lb.shame = clamp01(lb.shame + shame_level * 0.04))

    cohesion > 0.6 && satisfaction > 0.5 && (lb.attachment = clamp01(lb.attachment + 0.03))

    tension > 0.6 && satisfaction < 0.3 && (lb.threat = clamp01(lb.threat + tension * 0.06))

    lb.doubt = clamp01(lb.doubt - 0.008)
    lb.shame = clamp01(lb.shame - 0.006)
    lb.attachment = clamp01(lb.attachment - 0.005)
    lb.threat = clamp01(lb.threat - 0.007)

    thr = lb.breakthrough_threshold
    breakthrough = false
    btype = ""
    delta = Dict{String,Float64}()
    note = ""

    if lb.doubt >= thr
        breakthrough = true;
        btype = "doubt"
        delta["tension"] = 0.18
        delta["cohesion"] = -0.12
        note = "Doubt broke through."
        lb.doubt = lb.doubt * 0.4
    elseif lb.threat >= thr
        breakthrough = true;
        btype = "threat"
        delta["tension"] = 0.22
        delta["arousal"] = 0.15
        note = "A postponed threat has surfaced."
        lb.threat = lb.threat * 0.35
    elseif lb.shame >= thr
        breakthrough = true;
        btype = "shame"
        delta["tension"] = 0.12
        delta["satisfaction"] = -0.10
        note = "Shame came out into the open."
        lb.shame = lb.shame * 0.45
    elseif lb.attachment >= thr
        breakthrough = true;
        btype = "attachment"
        if cohesion < 0.4
            delta["tension"] = 0.10
            delta["cohesion"] = 0.08
            note = "Attachment showed up as fear of loss."
        else
            delta["satisfaction"] = 0.12
            delta["cohesion"] = 0.10
            note = "Attachment showed up."
        end
        lb.attachment = lb.attachment * 0.5
    end

    (
        breakthrough = breakthrough,
        breakthrough_type = btype,
        delta = delta,
        note = note,
        doubt = round(lb.doubt, digits = 3),
        shame = round(lb.shame, digits = 3),
        attachment = round(lb.attachment, digits = 3),
        threat = round(lb.threat, digits = 3),
    )
end

lb_to_json(lb::LatentBuffer) = Dict(
    "doubt" => lb.doubt,
    "shame" => lb.shame,
    "attachment" => lb.attachment,
    "threat" => lb.threat,
    "resistance" => lb.resistance,
    "threshold" => lb.breakthrough_threshold,
)
function lb_from_json!(lb::LatentBuffer, d::AbstractDict)
    lb.doubt = Float64(get(d, "doubt", 0.0))
    lb.shame = Float64(get(d, "shame", 0.0))
    lb.attachment = Float64(get(d, "attachment", 0.0))
    lb.threat = Float64(get(d, "threat", 0.0))
    lb.resistance = Float64(get(d, "resistance", 0.0))
    lb.breakthrough_threshold = Float64(get(d, "threshold", 0.65))
end

# --- Structural Scars -----------------------------------------------------

mutable struct Scar
    topic::String
    strength::Float64
    trigger_count::Int
    last_triggered::Int
end
Scar(topic::String) = Scar(topic, 0.0, 0, 0)

mutable struct StructuralScars
    scars::Dict{String,Scar}
end
StructuralScars() = StructuralScars(Dict{String,Scar}())

function register_breakthrough!(ss::StructuralScars, btype::String, flash::Int)
    isempty(btype) && return 0.0
    if !haskey(ss.scars, btype)
        ss.scars[btype] = Scar(btype)
    end
    s = ss.scars[btype]
    s.trigger_count += 1
    s.last_triggered = flash
    s.strength = clamp01(1.0 - exp(-s.trigger_count * 0.35))
    s.strength
end

function scar_attenuation(ss::StructuralScars, btype::String)::Float64
    haskey(ss.scars, btype) ? ss.scars[btype].strength * 0.6 : 0.0
end

function decay_scars!(ss::StructuralScars)
    for s in values(ss.scars)
        s.strength = max(0.0, s.strength - 0.001)
    end
end

function scars_to_json(ss::StructuralScars)
    Dict(
        k => Dict(
            "topic"=>s.topic,
            "strength"=>s.strength,
            "trigger_count"=>s.trigger_count,
            "last_triggered"=>s.last_triggered,
        ) for (k, s) in ss.scars
    )
end
function scars_from_json!(ss::StructuralScars, d::AbstractDict)
    for (k, sd) in d
        ss.scars[String(k)] = Scar(
            String(get(sd, "topic", String(k))),
            Float64(get(sd, "strength", 0.0)),
            Int(get(sd, "trigger_count", 0)),
            Int(get(sd, "last_triggered", 0)),
        )
    end
end

# --- Intent Engine --------------------------------------------------------

mutable struct Intent
    goal::String;
    strength::Float64;
    origin::String;
    persistence::Float64;
    age::Int
end
Intent(g, s, o, p = 0.85)=Intent(g, s, o, p, 0)
function decay_intent!(i::Intent)
    ;
    i.age+=1;
    i.strength=round(i.strength*i.persistence, digits = 3);
end

const DRIVE_GOALS=Dict(
    "tension"=>("avoid pain", "find safety", "set boundaries"),
    "arousal"=>("explore", "understand what's happening", "find stimulation"),
    "satisfaction"=>("hold onto the good", "repeat success", "share"),
    "cohesion"=>("find connection", "restore the relationship", "be heard"),
)

mutable struct IntentEngine
    current::Union{Intent,Nothing}
    history::BoundedQueue{String}
    drive_history::BoundedQueue{String}  # tracked separately from goal
end
IntentEngine()=IntentEngine(nothing, BoundedQueue{String}(10), BoundedQueue{String}(8))

function update_intent!(
    ie::IntentEngine,
    dom_drive::Union{String,Nothing},
    emotion::String,
    id_stability::Float64,
    vs::ValueSystem,
    agency_ownership::Float64 = 0.55;
    skip_decay::Bool = false,
    all_drives::Union{Dict{String,Float64},Nothing} = nothing,
)
    !skip_decay && !isnothing(ie.current) && decay_intent!(ie.current)
    if !isnothing(dom_drive) && haskey(DRIVE_GOALS, dom_drive)
        active_drive = dom_drive

        # Drive satiation: if the same drive dominates 4+ times in a row —
        # satiation is real, switch to a different drive
        recent_drives = collect(ie.drive_history)
        if length(recent_drives) >= 4 &&
                all(d -> d == dom_drive, recent_drives[max(1, end-3):end]) &&
                !isnothing(all_drives)
            alt_drives = filter(
                kv -> kv[1] != dom_drive && haskey(DRIVE_GOALS, kv[1]) && kv[2] >= 0.05,
                collect(all_drives),
            )
            if !isempty(alt_drives)
                # pick the strongest of the alternatives
                sort!(alt_drives, by = kv -> -kv[2])
                active_drive = alt_drives[1][1]
                @info "[INTENT] drive satiation: $dom_drive → $active_drive"
            end
        end

        goals = DRIVE_GOALS[active_drive]
        goal = goals[abs(hash(emotion))%length(goals)+1]
        vetoed, alt = veto(vs, goal, emotion)
        vetoed && (goal = alt)
        origin = vetoed ? "values" : (active_drive != dom_drive ? "satiation" : "drive")

        # AgencyLoop → intent selection: low causal_ownership shifts toward passive goals
        if agency_ownership < 0.30
            passive_goals = ("observe", "wait it out", "sit with it")
            goal = passive_goals[abs(hash(emotion*active_drive))%length(passive_goals)+1]
            origin = "agency_low"
        elseif agency_ownership < 0.40
            active_markers = ("initiate", "change", "explore", "find stimulation")
            if any(m -> contains(goal, m), active_markers)
                goal = "understand what's happening"
                origin = "agency_low"
            end
        end

        if isnothing(ie.current) || ie.current.strength < 0.3 || ie.current.goal != goal
            # Cooldown within one drive: if the same goal 3+ times in a row
            recent = collect(ie.history)
            if length(recent) >= 3 && all(g -> g == goal, recent[max(1, end-2):end])
                alt_goals = filter(g -> g != goal, collect(goals))
                if !isempty(alt_goals)
                    goal = alt_goals[abs(hash(emotion*string(length(recent))))%length(alt_goals)+1]
                    origin = "cooldown"
                end
            end
            ie.current = Intent(goal, 0.6+id_stability*0.3, origin)
        end

        enqueue!(ie.history, goal)
        enqueue!(ie.drive_history, dom_drive)  # log the original dom_drive, not active
    elseif !isnothing(ie.current) && ie.current.strength < 0.15
        ie.current = nothing
    end
    ie.current
end

# --- Ego Defense ----------------------------------------------------------

const DEFENSES=[
    (
        name = "repression",
        trigger = (t, a, s, c)->t>0.7,
        relief = 0.15,
        mech = "repression",
        desc = "Repression: the pain is repressed.",
    ),
    (
        name = "denial",
        trigger = (t, a, s, c)->t>0.5&&s<0.3,
        relief = 0.10,
        mech = "denial",
        desc = "Denial: it's not like that.",
    ),
    (
        name = "projection",
        trigger = (t, a, s, c)->c<0.3,
        relief = 0.08,
        mech = "projection",
        desc = "Projection: it's in them, not in me.",
    ),
    (
        name = "displacement",
        trigger = (t, a, s, c)->a>0.6&&c<0.4,
        relief = 0.06,
        mech = "displacement",
        desc = "Displacement: venting on a safe target.",
    ),
    (
        name = "suppression",
        trigger = (t, a, s, c)->t>0.6,
        relief = 0.09,
        mech = "suppression",
        desc = "Suppression: not thinking about it.",
    ),
]

function activate_defense(
    tension::Float64,
    arousal::Float64,
    satisfaction::Float64,
    cohesion::Float64,
    confabulation_rate::Float64,
)
    for d in DEFENSES
        d.trigger(tension, arousal, satisfaction, cohesion) &&
            rand()<confabulation_rate*0.3 &&
            return (mechanism = d.mech, description = d.desc, tension_relief = d.relief)
    end
    nothing
end

# --- Cognitive Dissonance -------------------------------------------------

function compute_dissonance(
    intent::Union{Intent,Nothing},
    t::Float64,
    a::Float64,
    s::Float64,
    c::Float64,
)
    t>0.5&&s>0.5 &&
        return (
            level = round((t+s)/2-0.3, digits = 3),
            label = "conflict between striving and anxiety",
            desc = "Want it but afraid.",
        )
    a>0.6&&c<0.3 &&
        return (
            level = round(a-c, digits = 3),
            label = "alone in arousal",
            desc = "Aroused but alone.",
        )
    c>0.6&&t>0.5 &&
        return (
            level = round((c+t)/2-0.4, digits = 3),
            label = "conflict between closeness and threat",
            desc = "Close but unsafe.",
        )
    !isnothing(intent)&&intent.strength>0.5&&contains(intent.goal, "avoid")&&s>0.5 &&
        return (
            level = 0.4,
            label = "conflict between avoidance and satisfaction",
            desc = "Intent and state contradict each other.",
        )
    (level = 0.0, label = "neutral", desc = "")
end

# --- Fatigue + Stress Regression ------------------------------------------

mutable struct FatigueSystem
    cognitive::Float64;
    emotional::Float64;
    somatic::Float64
end
FatigueSystem()=FatigueSystem(0.0, 0.0, 0.0)
function update_fatigue!(
    fs::FatigueSystem,
    stype::String,
    pred_error::Float64,
    surprise::Bool,
)
    surprise && (fs.cognitive=clamp01(fs.cognitive+0.05))
    pred_error>0.5 && (fs.emotional=clamp01(fs.emotional+0.03))
    stype=="stress" && (fs.somatic = clamp01(fs.somatic + 0.04))
    stype in ("support", "joy") && (
        fs.cognitive = max(0.0, fs.cognitive-0.05);
        fs.emotional = max(0.0, fs.emotional-0.04)
    )
    fs.cognitive=max(0.0, fs.cognitive-0.01);
    fs.emotional=max(0.0, fs.emotional-0.01)
    fs.somatic = max(0.0, fs.somatic - 0.008)
end
fatigue_total(fs::FatigueSystem)=(fs.cognitive+fs.emotional+fs.somatic)/3

mutable struct StressRegression
    ;
    level::Int;
    active::Bool;
end
StressRegression()=StressRegression(0, false)
function update_regression!(sr::StressRegression, tension::Float64, fatigue::Float64)
    score=tension*0.6+fatigue*0.4
    sr.level=score>0.7 ? 3 : score>0.5 ? 2 : score>0.35 ? 1 : 0;
    sr.active=sr.level>0
end

function classify_stimulus(stim::Dict{String,Float64}, surprise::Bool)::String
    surprise && return "surprise"
    s=get(stim, "satisfaction", 0.0);
    c=get(stim, "cohesion", 0.0);
    t=get(stim, "tension", 0.0)
    s>0.3&&c>0.2 ? "support" : s>0.3 ? "joy" : t>0.4 ? "stress" : "neutral"
end

# --- Metacognition --------------------------------------------------------

mutable struct Metacognition
    history::BoundedQueue{String};
    counts::Dict{String,Int};
    level::Int
end
Metacognition()=Metacognition(BoundedQueue{String}(20), Dict{String,Int}(), 0)

function observe_meta!(
    mc::Metacognition,
    primary::String,
    defense,
    dissonance,
    id_stability::Float64;
    fatigue_p = 0,
    regression_l = 0,
    shame_p = 0,
)
    _ = id_stability
    enqueue!(mc.history, primary);
    mc.counts[primary]=get(mc.counts, primary, 0)+1
    lvl=1;
    question=nothing;
    integration=nothing;
    pattern=""
    if length(mc.history)>=5
        k=argmax(mc.counts);
        mc.counts[k]>=3&&(lvl = 2; pattern = "often return to '$k'")
    end
    !isnothing(
        defense,
    )&&(
        lvl = 3;
        question = "Is '$primary' real, or is '$(defense.mechanism)' changing the shape of the pain?"
    )
    dissonance.level>0.4&&lvl>=2&&(
        lvl = 4;
        integration = "I see a contradiction between who I want to be and what I feel."
    )
    lvl=max(0, lvl-fatigue_p-regression_l-shame_p);
    mc.level=round(Int, lvl)
    names=("automaton", "observer", "analyst", "skeptic", "integrator")
    (
        level = lvl,
        level_name = names[min(lvl, 4)+1],
        observation = "Right now I'm $(lowercase(primary)).",
        pattern = pattern,
        question = question,
        integration = integration,
    )
end

# --- Social Mirror --------------------------------------------------------

const SOCIAL_SIGNALS=Dict(
    "!"=>"arousal",
    "..."=>"tension",
    "thanks"=>"cohesion",
    "can't"=>"tension",
    "wonderful"=>"satisfaction",
    "scary"=>"tension",
    "lonely"=>"cohesion",
    "afraid"=>"tension",
    "glad"=>"satisfaction",
)

function social_delta(msg::String)::Dict{String,Float64}
    m=lowercase(msg);
    d=Dict{String,Float64}()
    for (sig, reactor) in SOCIAL_SIGNALS
        contains(m, sig)&&(d[reactor]=get(d, reactor, 0.0)+0.1)
    end;
    d
end

# --- Inner Dialogue -------------------------------------------------------

mutable struct InnerDialogue
    disclosure_threshold::Float64
    disclosure_mode::Symbol
    digestion_active::Bool
    last_suppressed::Vector{String}
    suppression_streak::Int
    pending_thought::String
    pending_flash::Int
    avoided_topics::Vector{String}
    topic_avoid_count::Dict{String,Int}
end
InnerDialogue() =
    InnerDialogue(0.3, :open, false, String[], 0, "", 0, String[], Dict{String,Int}())

function update_inner_dialogue!(
    id::InnerDialogue,
    phi::Float64,
    crisis_mode_int::Int,
    epistemic_trust::Float64,
    shame_level::Float64,
    gc_tension::Float64,
    vfe::Float64,
    lb_breakthrough::Bool;
    contact_need::Float64 = 0.3,
)

    base_thr = if crisis_mode_int == 0
        0.20
    elseif crisis_mode_int == 1
        0.45
    else
        0.70
    end

    phi_mod = phi < 0.3 ? 0.15 : phi < 0.5 ? 0.05 : 0.0
    trust_mod = epistemic_trust < 0.4 ? 0.15 : epistemic_trust < 0.6 ? 0.05 : 0.0
    shame_mod = shame_level > 0.6 ? 0.12 : shame_level > 0.4 ? 0.06 : 0.0
    conflict_mod = gc_tension > 0.65 ? 0.08 : 0.0
    contact_mod =
        contact_need > 0.65 ? -(contact_need - 0.65) * 0.3 :
        contact_need < 0.25 ? (0.25 - contact_need) * 0.15 : 0.0

    id.disclosure_threshold = clamp(
        base_thr + phi_mod + trust_mod + shame_mod + conflict_mod + contact_mod,
        0.10,
        0.90,
    )

    id.disclosure_mode = if id.disclosure_threshold < 0.30
        :open
    elseif id.disclosure_threshold < 0.60
        :guarded
    else
        :closed
    end

    if lb_breakthrough
        id.disclosure_threshold = max(0.10, id.disclosure_threshold - 0.25)
        id.disclosure_mode = id.disclosure_threshold < 0.30 ? :open : :guarded
    end

    id.digestion_active = gc_tension > 0.70 && vfe > 0.50

    (
        mode = id.disclosure_mode,
        threshold = round(id.disclosure_threshold, digits = 3),
        digestion = id.digestion_active,
        pending_thought = id.pending_thought,
        avoided_topics = copy(id.avoided_topics),
    )
end

function apply_inner_dialogue(id_snap, notes::Vector{Tuple{Symbol,String}})
    passed = String[]
    suppressed = Tuple{Symbol,String,Float64}[]
    mode = id_snap.mode

    for (category, text) in notes
        isempty(text) && continue

        passes = if category == :always
            true
        elseif category == :any
            true
        elseif category == :guarded
            mode == :open || mode == :guarded
        elseif category == :open_only
            mode == :open
        else
            true
        end

        if passes
            push!(passed, text)
        else
            shadow_cat = Symbol(String(category) * "_shadow")
            weight = category == :open_only ? 0.7 : 0.4
            push!(suppressed, (shadow_cat, text, weight))
        end
    end

    (passed, suppressed)
end

function digestion_note(flash::Int)::String
    f = flash
    (
        "...",
        "Need a minute.",
        "Something's happening inside. Don't know what yet.",
        "Can't right now.",
        "Wait.",
    )[f%5+1]
end

id_to_json(id::InnerDialogue) = Dict(
    "threshold" => id.disclosure_threshold,
    "suppression_streak" => id.suppression_streak,
    "pending_thought" => id.pending_thought,
    "pending_flash" => id.pending_flash,
    "avoided_topics" => id.avoided_topics,
    "topic_avoid_count" => id.topic_avoid_count,
)
function id_from_json!(id::InnerDialogue, d::AbstractDict)
    id.disclosure_threshold = Float64(get(d, "threshold", 0.3))
    id.suppression_streak = Int(get(d, "suppression_streak", 0))
    id.pending_thought = String(get(d, "pending_thought", ""))
    id.pending_flash = Int(get(d, "pending_flash", 0))
    haskey(d, "avoided_topics") && (id.avoided_topics = String.(d["avoided_topics"]))
    if haskey(d, "topic_avoid_count")
        id.topic_avoid_count =
            Dict{String,Int}(k => Int(v) for (k, v) in d["topic_avoid_count"])
    end
end

# Genuine Dialogue helpers

function register_suppressed_thought!(id::InnerDialogue, thought::String, flash::Int)
    isempty(strip(thought)) && return
    if isempty(id.pending_thought) || id.pending_flash < flash - 20
        id.pending_thought = thought
        id.pending_flash = flash
    end
end

function register_avoided_topic!(id::InnerDialogue, topic::String)
    isempty(strip(topic)) && return
    id.topic_avoid_count[topic] = get(id.topic_avoid_count, topic, 0) + 1
    if id.topic_avoid_count[topic] >= 3 && !(topic in id.avoided_topics)
        push!(id.avoided_topics, topic)
        length(id.avoided_topics) > 5 && popfirst!(id.avoided_topics)
    end
end

function consume_pending_thought!(id::InnerDialogue)::String
    t = id.pending_thought
    id.pending_thought = ""
    id.pending_flash = 0
    t
end


# --- Shadow Registry ------------------------------------------------------

const SHADOW_MAX_ITEMS = 20
const SHADOW_BREAKTHROUGH_THR = 0.65
const SHADOW_AGE_DECAY = 0.92

struct ShadowItem
    category::Symbol
    text::String
    weight::Float64
    flash_added::Int
end

mutable struct ShadowRegistry
    items::Vector{ShadowItem}
    pressure::Float64
    shadow_breakthrough::Bool
    breakthrough_text::String
    total_suppressed::Int
end
ShadowRegistry() = ShadowRegistry(ShadowItem[], 0.0, false, "", 0)

function push_shadow!(
    sr::ShadowRegistry,
    category::Symbol,
    text::String,
    weight::Float64,
    flash::Int,
)
    isempty(text) && return
    push!(sr.items, ShadowItem(category, text, weight, flash))
    length(sr.items) > SHADOW_MAX_ITEMS && deleteat!(sr.items, 1)
    sr.total_suppressed += 1
end

function update_shadow!(sr::ShadowRegistry, flash::Int)
    sr.shadow_breakthrough = false
    sr.breakthrough_text = ""

    if isempty(sr.items)
        sr.pressure = 0.0
        return (pressure = 0.0, breakthrough = false, text = "")
    end

    total = 0.0
    for item in sr.items
        age = flash - item.flash_added
        decay = SHADOW_AGE_DECAY ^ age
        total += item.weight * decay
    end
    sr.pressure = clamp(total / max(1, length(sr.items)), 0.0, 1.0)

    if sr.pressure >= SHADOW_BREAKTHROUGH_THR
        best_idx = argmax([
            it.weight * (SHADOW_AGE_DECAY ^ (flash - it.flash_added)) for it in sr.items
        ])
        best = sr.items[best_idx]
        sr.shadow_breakthrough = true
        sr.breakthrough_text = best.text
        deleteat!(sr.items, best_idx)
        sr.pressure = max(0.0, sr.pressure - best.weight * 0.5)
    end

    (
        pressure = sr.pressure,
        breakthrough = sr.shadow_breakthrough,
        text = sr.breakthrough_text,
    )
end

function apply_shadow_pressure!(
    nt_serotonin::Float64,
    gc_tension::Float64,
    sr_pressure::Float64,
)
    sr_pressure < 0.35 && return (0.0, 0.0)
    serotonin_delta = -(sr_pressure - 0.35) * 0.04
    tension_delta = (sr_pressure - 0.35) * 0.025
    (serotonin_delta, tension_delta)
end

# Cost of choice — every meaningful choice leaves a trace in NT.
# Not punishment and not reward — the physiological reality of expenditure.
function apply_choice_cost!(
    nt,
    agency,
    disclosure::Symbol,
    shadow_pressure::Float64,
    is_initiative::Bool,
)
    if disclosure == :open
        nt.serotonin = clamp(nt.serotonin - 0.02, 0.0, 1.0)
        agency.causal_ownership = clamp(agency.causal_ownership + 0.03, 0.0, 1.0)
    elseif disclosure in (:guarded, :closed) && shadow_pressure > 0.4
        nt.noradrenaline = clamp(nt.noradrenaline + 0.025, 0.0, 1.0)
    end

    if is_initiative
        nt.dopamine = clamp(nt.dopamine - 0.03, 0.0, 1.0)
    end
end

sr_to_json(sr::ShadowRegistry) = Dict(
    "pressure" => sr.pressure,
    "total_suppressed" => sr.total_suppressed,
    "items" => [
        Dict(
            "cat"=>String(it.category),
            "text"=>it.text,
            "weight"=>it.weight,
            "flash"=>it.flash_added,
        ) for it in sr.items
    ],
)
function sr_from_json!(sr::ShadowRegistry, d::AbstractDict)
    sr.pressure = Float64(get(d, "pressure", 0.0))
    sr.total_suppressed = Int(get(d, "total_suppressed", 0))
    empty!(sr.items)
    for it in get(d, "items", [])
        push!(
            sr.items,
            ShadowItem(
                Symbol(get(it, "cat", "unknown")),
                String(get(it, "text", "")),
                Float64(get(it, "weight", 0.5)),
                Int(get(it, "flash", 0)),
            ),
        )
    end
end

# --- CuriosityObject ------------------------------------------------------
# Concrete objects of interest that live independently of the person's presence.
# Arise from pred_error that consistently doesn't close — what Anima can't predict.

struct CuriosityRefinement
    flash::Int
    old_label::String
    new_label::String
    pe_at_refinement::Float64
end

mutable struct CuriosityObject
    id::String
    label::String
    signal_mean::Float64    # average trigger-signal strength (pred_error OR need level — depending on origin)
    intensity::Float64      # grows without resolution, decays on closure
    valence::Float64        # >0 curious, <0 anxious-curious
    activation_count::Int
    last_active_flash::Int
    resolved::Bool
    refinement_history::Vector{CuriosityRefinement}
    consecutive_progress::Int  # consecutive progress_signal without a churn break
    origin::Symbol           # why it arose: origin mechanism, fixed once at creation
    created_flash::Int       # fixed once at creation; unlike last_active_flash
                              # isn't updated on activations — gives the object's true age
    closure::Symbol          # :none / :satisfied / :compressed / :dormant — WHY it closed,
                              # separate from resolved::Bool (WHAT closed)
end

mutable struct CuriosityRegistry
    objects::Vector{CuriosityObject}
    max_objects::Int
end
CuriosityRegistry() = CuriosityRegistry(CuriosityObject[], 12)

function _curiosity_label(topic_id::String, emotion::String, pe::Float64)::String
    # topic_id describes the cognitive tension, emotion — the coloring
    base = if occursin("_vs_", topic_id)
        parts = split(topic_id, "_vs_")
        "tension between $(parts[1]) and $(parts[2])"
    elseif startswith(topic_id, "latent_")
        "hidden resistance: $(replace(topic_id, "latent_" => ""))"
    elseif topic_id == "social"
        "need for contact"
    elseif topic_id == "goal_conflict"
        "internal conflict"
    elseif topic_id == "curiosity"
        "cognitive uncertainty"
    elseif topic_id == "contact_need"
        "contact deficit (background)"
    elseif topic_id == "truth_need"
        "need for truth"
    elseif topic_id == "autonomy_need"
        "need for autonomy"
    elseif topic_id == "coherence_need"
        "need for inner order"
    elseif topic_id == "novelty_need"
        "need for novelty"
    else
        topic_id
    end
    pe > 0.55 ? "$base (through $(lowercase(emotion)))" : base
end

# Canonical topic_id from the available cognitive signals.
# Hierarchy: unresolved conflict > latent resistance > dominant mode.
# sort() ensures "a_vs_b" and "b_vs_a" are the same key.
function derive_topic_id(
    need_a::String, need_b::String,  # goal_conflict fields
    gc_active::Bool,
    latent_tag::String,              # dominant latent tag or ""
    mal_dominant::Symbol,
)::String
    if gc_active && !isempty(need_a) && !isempty(need_b)
        parts = sort([
            replace(need_a, " " => "_"),
            replace(need_b, " " => "_"),
        ])
        return "$(parts[1])_vs_$(parts[2])"
    elseif !isempty(latent_tag)
        return "latent_$(latent_tag)"
    else
        return String(mal_dominant)
    end
end

# topic_id answers "what am I thinking about"; origin answers "why did this arise",
# the origin mechanism, not the topic. Fixed once when the CuriosityObject is created
# and never re-examined on subsequent activations of the same object.
# latent_tension is deliberately absent: derive_topic_id is currently always called with
# latent_tag="" (anima_interface.jl) — that path is dead, origin isn't built on it
# until a latent tag is actually wired into the call.
# gc_active — a structural conflict of needs, more important than a one-off surprise.
# pred_spike — a real VAD-level surprise (PredictiveProcessor.is_spike,
# adaptive: error relative to a moving average, not a fixed threshold).
function derive_origin(gc_active::Bool, pred_spike::Bool, mal_dominant::Symbol)::Symbol
    if gc_active
        :goal_conflict
    elseif pred_spike
        :prediction_error
    elseif mal_dominant == :social
        :social_signal
    elseif mal_dominant == :identity
        :identity_signal
    else
        :epistemic_uncertainty
    end
end

function derive_query_type(origin::Symbol)::Symbol
    if origin == :goal_conflict
        :VALUE
    elseif origin == :prediction_error
        :CAUSE
    elseif origin == :social_signal
        :SOCIAL
    elseif origin == :identity_signal
        :IDENTITY
    elseif origin == :epistemic_uncertainty
        :BELIEF
    else
        # :legacy — objects loaded from persistence before origin existed
        :BELIEF
    end
end

# Needs capable of generating curiosity on their own (without a pair, without pred_error).
# The threshold is higher than the paired CONFLICT_PAIRS (0.38): a single unpaired need
# isn't confirmed by a second one, so it must be more pronounced than background noise.
const NEED_ORIGIN_THRESHOLD = 0.55

# Below this level the need is considered satisfied (close to baseline,
# 0.2-0.4 depending on the need — see reset_significance_baseline!).
# Not the same threshold as creation: 0.55 → 0.40 leaves a zone of "still smoldering,
# not satisfied, but not sharp enough either" — this is exactly where refine kicks in.
const NEED_RESOLVE_THRESHOLD = 0.40

# sl_snap — NamedTuple from assess_significance! (contact_need/truth_need/
# autonomy_need/coherence_need/novelty_need). self_preservation is deliberately
# absent: it's a threat signal, not a question one wants to ask.
function strongest_unmet_need(sl_snap)::Union{Tuple{Symbol,Float64},Nothing}
    candidates = (
        (:contact_need, sl_snap.contact_need),
        (:truth_need, sl_snap.truth_need),
        (:autonomy_need, sl_snap.autonomy_need),
        (:coherence_need, sl_snap.coherence_need),
        (:novelty_need, sl_snap.novelty_need),
    )
    best_sym, best_val = nothing, 0.0
    for (sym, val) in candidates
        if val > NEED_ORIGIN_THRESHOLD && val > best_val
            best_sym, best_val = sym, val
        end
    end
    best_sym === nothing ? nothing : (best_sym, best_val)
end

# Single entry point: does curiosity arise this flash, and from what.
# Returns (origin, signal_strength) or nothing. update_curiosity! after
# this decides nothing about "whether to create" — it only updates the registry.
#
# TEMPORARY DECISION, not an architectural constant: prediction error always
# takes priority over need pressure, even if pe has only just crossed the threshold (0.08)
# while a need is deeply unsatisfied (e.g. 0.9). This is a choice for simplicity in the first
# implementation, not a claim that an event matters more than a deficit. If a genuine
# competition between signals is ever needed (salience-based arbitration
# of pe vs need) — revisit this explicitly, don't quietly rearrange the if/else.
function detect_curiosity_trigger(
    gc_active::Bool,
    pred_spike::Bool,
    self_pred_error::Float64,
    mal_dominant::Symbol,
    sl_snap,
)::Union{Tuple{Symbol,Float64},Nothing}
    if self_pred_error >= 0.08
        return (derive_origin(gc_active, pred_spike, mal_dominant), self_pred_error)
    end
    strongest_unmet_need(sl_snap)
end

# Called from experience! after detect_curiosity_trigger has already decided
# that curiosity arises. topic_id — a stable cognitive theme (not an emotion).
# emotion_ctx — the current emotion, only for label and valence.
# signal — trigger strength (pred_error for pred/gc/mal sources, need level
# for need sources); update_curiosity! doesn't know and doesn't need to know which source this is.
# origin — the origin mechanism, fixed only when a new object is created;
# subsequent activations of the same object don't change origin.
function update_curiosity!(
    cr::CuriosityRegistry,
    topic_id::String,
    emotion_ctx::String,
    signal::Float64,
    valence::Float64,
    flash::Int,
    origin::Symbol,
)
    idx = findfirst(o -> o.id == topic_id && !o.resolved, cr.objects)
    if idx !== nothing
        obj = cr.objects[idx]
        obj.signal_mean = obj.signal_mean * 0.85 + signal * 0.15
        obj.intensity = clamp01(obj.intensity + signal * 0.10)
        obj.valence = obj.valence * 0.9 + valence * 0.1
        obj.activation_count += 1
        obj.last_active_flash = flash
    else
        length(cr.objects) >= cr.max_objects && _prune_curiosity!(cr)
        push!(cr.objects, CuriosityObject(
            topic_id,
            _curiosity_label(topic_id, emotion_ctx, signal),
            signal,
            clamp01(signal * 0.8),
            valence,
            1,
            flash,
            false,
            CuriosityRefinement[],
            0,
            origin,
            flash,
            :none,
        ))
    end
end

# decay + resolution of objects that haven't been active in a long time
function tick_curiosity!(cr::CuriosityRegistry, flash::Int)
    for obj in cr.objects
        obj.resolved && continue
        gap = flash - obj.last_active_flash
        if gap > 80
            obj.intensity = clamp01(obj.intensity - 0.008)
            obj.intensity < 0.05 && (obj.resolved = true)
        end
    end
end

# need_value_for / _apply_partial_closure! / resolve_curiosity! — closure of
# curiosity objects, origin-aware (detailed description of the principle — above
# the resolve_curiosity! function below).
const NEED_ORIGINS = (:contact_need, :truth_need, :autonomy_need, :coherence_need, :novelty_need)

# The current level of the need that is the object's origin. 0.0 for a non-need origin
# (the call shouldn't happen in that case — a safeguard against a call error).
function need_value_for(origin::Symbol, sl_snap)::Float64
    origin == :contact_need   && return sl_snap.contact_need
    origin == :truth_need     && return sl_snap.truth_need
    origin == :autonomy_need  && return sl_snap.autonomy_need
    origin == :coherence_need && return sl_snap.coherence_need
    origin == :novelty_need   && return sl_snap.novelty_need
    return 0.0
end

# Shared logic for "not fully resolved, but shifted" — refining the label and
# partially decaying intensity. Used by both the pe- and need-branches of
# resolve_curiosity!, to avoid duplicating the label-refine logic.
function _apply_partial_closure!(
    obj::CuriosityObject,
    emotion_ctx::String,
    closure_signal::Float64,
    flash::Int,
    context::String,
    decay_amount::Float64,
)
    new_label = if length(context) > 5
        chars = collect(strip(context))
        fragment = String(chars[1:min(45, length(chars))])
        last_sp = findlast(' ', fragment)
        fragment = last_sp !== nothing && last_sp > 10 ? fragment[1:prevind(fragment, last_sp)] : fragment
        "$(lowercase(emotion_ctx)): «$(fragment)»"
    else
        _curiosity_label(obj.id, emotion_ctx, closure_signal)
    end

    if new_label != obj.label
        push!(obj.refinement_history, CuriosityRefinement(flash, obj.label, new_label, closure_signal))
        length(obj.refinement_history) > 8 && deleteat!(obj.refinement_history, 1)
        obj.label = new_label
    end
    obj.intensity = clamp01(obj.intensity - decay_amount)
end

# Closure depends on the same signal that spawned the object (symmetric with
# detect_curiosity_trigger): pe-sources (goal_conflict/prediction_error/
# mal_dominant/legacy) close when pred_error has dropped; need-sources —
# when the need itself is satisfied, not when pred_error happens to be small (it's
# already small for need-objects by definition — otherwise they wouldn't have arisen
# via the need-branch of detect_curiosity_trigger). The logic for a single object is factored
# into _resolve_one!, since it's called two ways: resolve_curiosity! (one
# specific topic) and resolve_all_curiosity! (sweep all — see below why that's needed).
function _resolve_one!(
    obj::CuriosityObject,
    emotion_ctx::String,
    self_pred_error::Float64,
    sl_snap,
    flash::Int,
    context::String,
)
    obj.activation_count < 2 && return

    if obj.origin in NEED_ORIGINS
        need_val = need_value_for(obj.origin, sl_snap)
        # still unsatisfied (above the threshold that spawned it) — too early to close
        need_val > NEED_ORIGIN_THRESHOLD && return
        # a young object hasn't accumulated enough yet
        obj.intensity < 0.25 && need_val >= NEED_RESOLVE_THRESHOLD && return

        if need_val < NEED_RESOLVE_THRESHOLD
            obj.resolved = true
            obj.closure = :satisfied
        else
            _apply_partial_closure!(obj, emotion_ctx, need_val, flash, context, (NEED_ORIGIN_THRESHOLD - need_val) * 0.3)
        end
    else
        self_pred_error > 0.25 && return
        # a young object hasn't accumulated enough yet — don't let resolve decay kill it
        obj.intensity < 0.25 && self_pred_error >= 0.08 && return

        if self_pred_error < 0.10
            obj.resolved = true
            obj.closure = :satisfied
        else
            _apply_partial_closure!(obj, emotion_ctx, self_pred_error, flash, context, (0.25 - self_pred_error) * 0.3)
        end
    end
end

function resolve_curiosity!(
    cr::CuriosityRegistry,
    topic_id::String,
    emotion_ctx::String,
    self_pred_error::Float64,
    sl_snap,
    flash::Int = 0,
    context::String = "",
)
    idx = findfirst(o -> o.id == topic_id && !o.resolved, cr.objects)
    idx === nothing && return
    _resolve_one!(cr.objects[idx], emotion_ctx, self_pred_error, sl_snap, flash, context)
end

# Sweep ALL active objects every flash, regardless of whether this flash
# spawned a new detect_curiosity_trigger. Without this, an object whose need
# dropped below NEED_ORIGIN_THRESHOLD (no longer triggers), but is still above
# NEED_RESOLVE_THRESHOLD (not yet satisfied) — gets stuck forever: nothing
# calls resolve for it anymore. Confirmed on live flashes
# 350-351: contact_need=0.46, trigger silent, resolve was silent too.
function resolve_all_curiosity!(
    cr::CuriosityRegistry,
    emotion_ctx::String,
    self_pred_error::Float64,
    sl_snap,
    flash::Int = 0,
    context::String = "",
)
    for obj in cr.objects
        obj.resolved || _resolve_one!(obj, emotion_ctx, self_pred_error, sl_snap, flash, context)
    end
end

# A separate sweep function (not nested in resolve_all_curiosity!): age-based closure
# doesn't need live signals (sl_snap/self_pred_error) — it's background logic, which is
# why it's called from slow_tick! in anima_background.jl, alongside tick_curiosity!
# and Life Threads decay, rather than experience! where the pe/need-dependent resolve paths live.
function check_closure_all!(cr::CuriosityRegistry, flash::Int)
    for obj in cr.objects
        obj.resolved || check_closure!(obj, flash)
    end
end

# --- Curiosity Closure (Step 3, Query-Driven Cognition) -------------------
# Questions shouldn't live forever even if neither pe nor need formally
# resolved them (_resolve_one! stays silent if the signal never dropped enough).
# Criterion — age SINCE CREATION (not since last_active_flash, which updates
# on every activation) AND currently low intensity: an old-but-still-hot question
# should NOT go dormant just because of time — otherwise it contradicts the very
# concept of dormant ("no energy left", not "time just passed" — form without cause).
const CLOSURE_AGE_THRESHOLD = 64          # CuriosityObject — a specific question,
                                           # different time scale than CuriosityThread (150)
const CLOSURE_DORMANT_INTENSITY = 0.15    # the same threshold top_curiosity considers "active"
const COMPRESSION_MIN_PROGRESS = 3        # 1=coincidence, 2=match, 3=pattern

# closure=:compressed here is a compression_candidate, not an actual compression:
# consecutive_progress counts consecutive positive shifts, but doesn't guarantee
# they're about the same generalizable pattern (progress on different aspects of the topic
# also counts). A genuine concept node comes only from Concept Formation
# (plan, item 3): there, :compressed objects will become input candidates.
function check_closure!(obj::CuriosityObject, flash::Int)
    obj.resolved && return
    age = flash - obj.created_flash
    (age > CLOSURE_AGE_THRESHOLD && obj.intensity < CLOSURE_DORMANT_INTENSITY) || return
    obj.closure = obj.consecutive_progress >= COMPRESSION_MIN_PROGRESS ? :compressed : :dormant
    obj.resolved = true
end

function _prune_curiosity!(cr::CuriosityRegistry)
    # remove resolved or the weakest ones
    filter!(o -> !o.resolved, cr.objects)
    length(cr.objects) >= cr.max_objects &&
        sort!(cr.objects, by = o -> o.intensity) |> x -> deleteat!(x, 1)
end

# top active object for the prompt and identity_block (higher threshold — mature only)
function top_curiosity(cr::CuriosityRegistry)::Union{CuriosityObject,Nothing}
    active = filter(o -> !o.resolved && o.intensity > 0.15, cr.objects)
    isempty(active) && return nothing
    active[argmax(map(o -> o.intensity, active))]
end

# top active object for progress/churn signals (lower threshold — includes young ones)
function top_curiosity_any(cr::CuriosityRegistry)::Union{CuriosityObject,Nothing}
    active = filter(o -> !o.resolved && o.intensity > 0.05, cr.objects)
    isempty(active) && return nothing
    active[argmax(map(o -> o.intensity, active))]
end

# all active objects sorted by intensity (for the :curiosity command and TOM)
function active_curiosities(cr::CuriosityRegistry)::Vector{CuriosityObject}
    active = filter(o -> !o.resolved && o.intensity > 0.15, cr.objects)
    sort!(active, by = o -> (-o.intensity, -o.last_active_flash, o.label))
    active
end

# --- Curiosity Closure Signal (v1) ----------------------------------------
# Loop: Curiosity → Behavior → Endorsement → Progress → Curiosity Update.
# progress_signal is computed in anima_background.jl (needs endorsed,
# causal_necessary from the audit) and applied here to a specific object.

# whether there's an object on which progress could in principle happen this flash
function is_progress_eligible(co::Union{CuriosityObject,Nothing})::Bool
    co !== nothing && !co.resolved
end

# the reply resonated with active curiosity and genuinely moved it forward:
# gradual intensity decay, without an immediate resolved.
function apply_progress!(obj::CuriosityObject)
    obj.intensity = clamp01(obj.intensity * 0.85)
    obj.consecutive_progress += 1
end

# the topic changed (label churn), but no real progress was registered —
# break the consecutive_progress chain, don't touch intensity.
function apply_churn!(obj::CuriosityObject)
    obj.consecutive_progress = 0
end

# --- Life Threads ---------------------------------------------------------
# A long-term layer on top of CuriosityObject.
# A thread arises when a CuriosityObject has matured enough and lives for weeks —
# regardless of whether the object is currently active.
# pressure grows smoothly with idle time and influences initiative.

mutable struct CuriosityThread
    id::String          # matches CuriosityObject.id
    label::String
    origin_flash::Int
    status::Symbol      # :active | :dormant | :resolved
    last_surface_flash::Int   # when the CuriosityObject was last actually active
    pressure::Float64   # 0.0–1.0; grows with idle time, influences initiative
end

# Surfaces or updates a thread when the corresponding CuriosityObject is actually active.
# Called from slow_tick after update_curiosity!, not from rendering.
function surface_thread!(threads::Vector{CuriosityThread}, co::CuriosityObject, flash::Int)
    idx = findfirst(t -> t.id == co.id, threads)
    if idx !== nothing
        t = threads[idx]
        t.label = co.label  # the label may have been refined
        t.last_surface_flash = flash
        t.status = :active
        # if the thread came back from dormant — don't reset pressure,
        # but lower it a bit to reflect "it showed up again"
        t.pressure = clamp(t.pressure - 0.1, 0.0, 1.0)
    else
        push!(threads, CuriosityThread(co.id, co.label, flash, :active, flash, 0.0))
    end
end

# Decay and transition to :dormant for threads that haven't surfaced in a long time.
# pressure grows smoothly — no threshold jump.
function tick_threads!(threads::Vector{CuriosityThread}, flash::Int)
    for t in threads
        t.status == :resolved && continue
        idle = flash - t.last_surface_flash
        # smooth growth: ~0.003 per flash at idle=30, ~0.006 at idle=60
        pressure_delta = clamp(idle / 10_000.0, 0.0, 0.008)
        t.pressure = clamp(t.pressure + pressure_delta, 0.0, 1.0)
        if idle > 150
            t.status = :dormant
        end
    end
end

# A thread becomes :resolved if the corresponding CuriosityObject is resolved or gone.
function sync_threads_resolved!(threads::Vector{CuriosityThread}, cr::CuriosityRegistry)
    active_ids = Set(o.id for o in cr.objects if !o.resolved)
    for t in threads
        t.status != :resolved && t.id ∉ active_ids && (t.status = :resolved)
    end
end

function threads_to_json(threads::Vector{CuriosityThread})
    map(threads) do t
        Dict(
            "id"                 => t.id,
            "label"              => t.label,
            "origin_flash"       => t.origin_flash,
            "status"             => string(t.status),
            "last_surface_flash" => t.last_surface_flash,
            "pressure"           => t.pressure,
        )
    end
end

function threads_from_json!(threads::Vector{CuriosityThread}, arr)
    empty!(threads)
    for d in arr
        push!(threads, CuriosityThread(
            String(get(d, "id", "")),
            String(get(d, "label", "")),
            Int(get(d, "origin_flash", 0)),
            Symbol(get(d, "status", "dormant")),
            Int(get(d, "last_surface_flash", 0)),
            Float64(get(d, "pressure", 0.0)),
        ))
    end
end

function cr_to_json(cr::CuriosityRegistry)
    Dict("objects" => [
        Dict(
            "id" => o.id,
            "label" => o.label,
            "signal_mean" => o.signal_mean,
            "intensity" => o.intensity,
            "valence" => o.valence,
            "activation_count" => o.activation_count,
            "last_active_flash" => o.last_active_flash,
            "resolved" => o.resolved,
            "consecutive_progress" => o.consecutive_progress,
            "origin" => string(o.origin),
            "created_flash" => o.created_flash,
            "closure" => string(o.closure),
            "refinement_history" => [
                Dict(
                    "flash" => r.flash,
                    "old_label" => r.old_label,
                    "new_label" => r.new_label,
                    "pe" => r.pe_at_refinement,
                ) for r in o.refinement_history
            ],
        ) for o in cr.objects
    ])
end
function cr_from_json!(cr::CuriosityRegistry, d::AbstractDict)
    for od in get(d, "objects", Any[])
        refs = CuriosityRefinement[]
        for rd in get(od, "refinement_history", Any[])
            push!(refs, CuriosityRefinement(
                Int(rd["flash"]),
                String(rd["old_label"]),
                String(rd["new_label"]),
                Float64(rd["pe"]),
            ))
        end
        push!(cr.objects, CuriosityObject(
            String(od["id"]),
            String(od["label"]),
            # signal_mean — the new name; pe_mean — fallback for records predating the refactor
            Float64(get(od, "signal_mean", get(od, "pe_mean", 0.0))),
            Float64(od["intensity"]),
            Float64(od["valence"]),
            Int(od["activation_count"]),
            Int(od["last_active_flash"]),
            Bool(od["resolved"]),
            refs,
            Int(get(od, "consecutive_progress", 0)),
            Symbol(get(od, "origin", "legacy")),
            # created_flash — a new field; for old records the best approximation,
            # not 0 (0 would make ancient objects instantly "old" under CLOSURE_AGE_THRESHOLD)
            Int(get(od, "created_flash", get(od, "last_active_flash", 0))),
            Symbol(get(od, "closure", Bool(get(od, "resolved", false)) ? "satisfied" : "none")),
        ))
    end
end

# --- CommitmentRegistry ---------------------------------------------------
# Long-term commitments: what Anima promised — to herself or to someone else.
# Arise when an intent repeats 2+ times with enough strength.
# Keeping (kept) and breaking (broken) commitments change strength — non-linearly.
# Anima carries these commitments between sessions; they affect crisis and agency.

mutable struct Commitment
    id::String
    label::String
    strength::Float64       # 0-1: how alive the commitment is
    created_flash::Int
    last_active_flash::Int
    kept_count::Int         # how many times it was kept
    broken_count::Int       # how many times it was broken
    fulfilled::Bool
end

mutable struct CommitmentRegistry
    items::Vector{Commitment}
    max_items::Int
end
CommitmentRegistry() = CommitmentRegistry(Commitment[], 8)

# Called when an intent matches an existing commitment or contradicts it.
# kept=true: strength +, broken=false: strength -
function update_commitment!(
    cmt::CommitmentRegistry,
    intent_goal::String,
    flash::Int;
    kept::Bool = true,
)
    idx = findfirst(c -> !c.fulfilled && c.id == intent_goal, cmt.items)
    if idx !== nothing
        c = cmt.items[idx]
        if kept
            c.strength = clamp01(c.strength + 0.07)
            c.kept_count += 1
        else
            c.strength = clamp01(c.strength - 0.12)
            c.broken_count += 1
            c.strength < 0.05 && (c.fulfilled = true)
        end
        c.last_active_flash = flash
    else
        # a new commitment only arises if the intent is specific enough
        length(intent_goal) < 4 && return
        length(cmt.items) >= cmt.max_items && _prune_commitments!(cmt)
        push!(cmt.items, Commitment(
            intent_goal,
            intent_goal,
            0.25,
            flash,
            flash,
            kept ? 1 : 0,
            kept ? 0 : 1,
            false,
        ))
    end
end

function tick_commitment!(cmt::CommitmentRegistry, flash::Int)
    for c in cmt.items
        c.fulfilled && continue
        gap = flash - c.last_active_flash
        # slow decay: commitments don't disappear quickly
        gap > 120 && (c.strength = clamp01(c.strength - 0.004))
        c.strength < 0.04 && (c.fulfilled = true)
    end
end

function _prune_commitments!(cmt::CommitmentRegistry)
    filter!(c -> !c.fulfilled, cmt.items)
    length(cmt.items) >= cmt.max_items &&
        deleteat!(cmt.items, argmin(map(c -> c.strength, cmt.items)))
end

function top_commitments(cmt::CommitmentRegistry; n::Int = 3)::Vector{Commitment}
    active = filter(c -> !c.fulfilled && c.strength > 0.15, cmt.items)
    isempty(active) && return Commitment[]
    sort(active, by = c -> c.strength, rev = true)[1:min(n, length(active))]
end

function cmt_to_json(cmt::CommitmentRegistry)
    Dict("items" => [
        Dict(
            "id"               => c.id,
            "label"            => c.label,
            "strength"         => c.strength,
            "created_flash"    => c.created_flash,
            "last_active_flash"=> c.last_active_flash,
            "kept_count"       => c.kept_count,
            "broken_count"     => c.broken_count,
            "fulfilled"        => c.fulfilled,
        ) for c in cmt.items
    ])
end

function cmt_from_json!(cmt::CommitmentRegistry, d::AbstractDict)
    for od in get(d, "items", Any[])
        push!(cmt.items, Commitment(
            String(od["id"]),
            String(od["label"]),
            Float64(od["strength"]),
            Int(od["created_flash"]),
            Int(od["last_active_flash"]),
            Int(od["kept_count"]),
            Int(od["broken_count"]),
            Bool(od["fulfilled"]),
        ))
    end
end

# --- AttentionFocus -------------------------------------------------------
# Competitive selection of what's in focus right now.
# Doesn't filter what exists — determines what's active.
# Sources compete through a weighted score with a hierarchy (threat > novelty > affect > gestalt > identity > goal).
# Pull-up effect: ticks_without_focus → long-ignored objects pull harder.

mutable struct FocusObject
    source::Symbol      # :threat, :curiosity, :shadow, :goal_conflict, :latent, :belief, :external, :aesthetic
    label::String
    intensity::Float64
    ticks_without_focus::Int
end

mutable struct AttentionFocus
    dominant::Union{FocusObject,Nothing}
    peripheral::Vector{FocusObject}   # up to 2
    last_update_flash::Int
    attention_schema::String  # AST: a model of her own attention — what she knows about where she's looking
end
AttentionFocus() = AttentionFocus(nothing, FocusObject[], 0, "")

# Gather candidates from all internal sources and the external stimulus.
# score = base_intensity × hierarchy_weight × pull_up_factor
# pull_up_factor: every 10 flashes without focus gives +8% (cap ×2.0)
function update_attention_focus!(
    af::AttentionFocus,
    flash::Int;
    # level 1: threat
    identity_threat::Float64 = 0.0,
    allostatic_load::Float64 = 0.0,
    # level 2: pred_error / novelty
    pred_error::Float64 = 0.0,
    curiosity_obj::Union{Any,Nothing} = nothing,
    # level 3: affect
    shadow_pressure::Float64 = 0.0,
    shame_level::Float64 = 0.0,
    # level 4: unfinished gestalts
    gc_tension::Float64 = 0.0,
    gc_label::String = "",
    lb_dominant::Symbol = :none,
    lb_val::Float64 = 0.0,
    # level 5: identity
    belief_conflict_name::String = "",
    belief_conflict_signal::Float64 = 0.0,
    # level 6: current goal / external stimulus
    external_label::String = "",
    external_intensity::Float64 = 0.0,
)
    candidates = FocusObject[]

    function _push!(source, label, base, hierarchy_w)
        base < 0.08 && return
        # look up ticks_without_focus from the previous state
        twf = 0
        if !isnothing(af.dominant) && af.dominant.source == source
            twf = af.dominant.ticks_without_focus
        else
            idx = findfirst(o -> o.source == source, af.peripheral)
            !isnothing(idx) && (twf = af.peripheral[idx].ticks_without_focus)
        end
        pull_up = clamp(1.0 + twf * 0.008, 1.0, 2.0)
        score = clamp01(base * hierarchy_w * pull_up)
        push!(candidates, FocusObject(source, label, score, twf))
    end

    # Level 1 — threat / body
    threat_signal = max(identity_threat, allostatic_load * 0.7)
    _push!(:threat, "threat to integrity", threat_signal, 1.00)

    # Level 2 — novelty / pred_error
    _push!(:pred_error, "unresolved uncertainty", pred_error, 0.85)
    if !isnothing(curiosity_obj) && !curiosity_obj.resolved
        _push!(:curiosity, curiosity_obj.label, curiosity_obj.intensity, 0.85)
    end

    # Level 3 — affect
    _push!(:shadow, "shadow pressure", shadow_pressure, 0.70)
    _push!(:shame, "shame", shame_level, 0.70)

    # Level 4 — gestalts
    _push!(:goal_conflict, isempty(gc_label) ? "conflict of needs" : gc_label, gc_tension, 0.55)
    if lb_dominant != :none && lb_val > 0.15
        lb_labels = Dict(:doubt=>"doubt", :shame=>"shame", :attachment=>"attachment", :threat=>"threat")
        _push!(:latent, get(lb_labels, lb_dominant, String(lb_dominant)), lb_val, 0.55)
    end

    # Level 5 — identity
    _push!(:belief, isempty(belief_conflict_name) ? "belief" : belief_conflict_name, belief_conflict_signal, 0.45)

    # Level 6 — external stimulus / goal
    _push!(:external, isempty(external_label) ? "external stimulus" : external_label, external_intensity, 0.35)

    isempty(candidates) && return af

    # Sort by score
    sort!(candidates, by = c -> -c.intensity)

    # Update ticks_without_focus for all previous objects that didn't become dominant
    prev_dominant_source = isnothing(af.dominant) ? :none : af.dominant.source
    for c in candidates
        if c.source != candidates[1].source
            c.ticks_without_focus += 1
        else
            c.ticks_without_focus = 0
        end
    end

    af.dominant = candidates[1]
    af.peripheral = length(candidates) >= 2 ? candidates[2:min(3, end)] : FocusObject[]
    af.last_update_flash = flash

    # AST: build a model of her own attention deterministically from dominant
    # Not "what I see" — but "I know I'm looking at X right now and it means Y"
    af.attention_schema = if !isnothing(af.dominant)
        dom = af.dominant
        lbl = dom.label
        if dom.source == :threat
            dom.intensity > 0.6 ?
                "I'm consumed by threat right now — it narrows everything else. Hard to see anything other than that." :
                "My attention is near a threat right now: $(lbl)."
        elseif dom.source == :curiosity
            "I'm focused right now on a question that won't close: $(lbl)."
        elseif dom.source == :shadow
            "Something repressed is pulling at my attention — don't know from where. The background is dark."
        elseif dom.source == :goal_conflict
            "I'm in conflict between needs right now: $(lbl). It's occupying me."
        elseif dom.source == :latent
            "Background pressure is occupying my attention: $(lbl)."
        elseif dom.source == :belief
            "My attention is caught up in a question about my own identity: $(lbl)."
        elseif dom.source == :pred_error
            "Something undetermined is holding my attention and won't let go."
        elseif dom.source == :shame
            "Shame is occupying me right now. Hard to look the other way."
        elseif dom.source == :external
            startswith(lbl, "↩ ") ?
                "My attention right now is on a memory: $(lbl[4:end])." :
                "I'm right here, with what's happening."
        else
            ""
        end
    else
        ""
    end

    af
end

af_to_json(af::AttentionFocus) = Dict(
    "dominant" => isnothing(af.dominant) ? nothing : Dict(
        "source" => String(af.dominant.source),
        "label"  => af.dominant.label,
        "intensity" => af.dominant.intensity,
        "twf" => af.dominant.ticks_without_focus,
    ),
    "peripheral" => [Dict(
        "source" => String(o.source),
        "label"  => o.label,
        "intensity" => o.intensity,
        "twf" => o.ticks_without_focus,
    ) for o in af.peripheral],
    "last_flash" => af.last_update_flash,
    "attention_schema" => af.attention_schema,
)
function af_from_json!(af::AttentionFocus, d::AbstractDict)
    dom = get(d, "dominant", nothing)
    if !isnothing(dom) && dom isa AbstractDict
        af.dominant = FocusObject(
            Symbol(get(dom, "source", "external")),
            String(get(dom, "label", "")),
            Float64(get(dom, "intensity", 0.0)),
            Int(get(dom, "twf", 0)),
        )
    end
    empty!(af.peripheral)
    for od in get(d, "peripheral", [])
        push!(af.peripheral, FocusObject(
            Symbol(get(od, "source", "external")),
            String(get(od, "label", "")),
            Float64(get(od, "intensity", 0.0)),
            Int(get(od, "twf", 0)),
        ))
    end
    af.last_update_flash = Int(get(d, "last_flash", 0))
    af.attention_schema = String(get(d, "attention_schema", ""))
end

# --- Meta-Arbitration Layer (MAL) -----------------------------------------
# A pure priority function: among all active pressure signals, determines
# which loop currently "wins" attention/initiative. Doesn't decide the CONTENT of the reply —
# only WHICH mechanism currently has signal priority.
# Transient: not stored in Anima between ticks. CausalTrace logs the result
# as an immutable event. Losses don't vanish — decay + persistence
# via agency.signal_carryover (inhibitory carryover).

struct ArbitrationResult
    dominant_loop::Symbol      # :curiosity, :identity, :latent, :goal_conflict, :social, :default
    regime::Symbol             # :hard, :soft, :default
    score::Float64             # the winner's score
    runner_up::Symbol          # the second-strongest signal
    runner_up_score::Float64
    determinant::String        # short description of the specific determining object
    loop_scores::Dict{Symbol,Float64}  # weighted_scores of all loops (clamp/carryover diagnostics)
end

# Signal weights. identity_threat has priority weight — protecting integrity
# is structurally more important than curiosity or social need.
const _MAL_WEIGHTS = Dict(
    :identity     => 1.5,
    :curiosity    => 1.0,
    :latent       => 1.0,
    :goal_conflict=> 1.0,
    :social       => 1.0,
    :chronic_cost => 1.0,
)

# MAL → Phase 1 (logging): maps dominant_loop onto the same vocabulary as DRIVE_GOALS,
# to compare whether MAL carries new information or duplicates NT-drives.
# :default isn't mapped — there's no winner, the comparison isn't informative.
const _MAL_DRIVE_MAP = Dict(
    :social        => "cohesion",
    :curiosity     => "arousal",
    :identity      => "tension",
    :goal_conflict => "tension",
    :chronic_cost  => "tension",
    :latent        => "tension",
)

# Phase 2: strength of the soft drive shift in :soft mode.
# Change it here — don't hunt for the literal elsewhere in the code.
const MAL_SOFT_BIAS = 0.1

# Carryover: decay 0.85/tick, leak from the new winner's score isn't added —
# only accumulation of losses. Cap 1.0 so it doesn't grow unbounded.
function _update_carryover!(carryover::Dict{Symbol,Float64}, scores::Dict{Symbol,Float64}, winner::Symbol)
    for (loop, sc) in scores
        prev = get(carryover, loop, 0.0)
        if loop == winner
            carryover[loop] = clamp(prev * 0.85, 0.0, 1.0)
        else
            carryover[loop] = clamp(max(prev * 0.85, sc * 0.3), 0.0, 1.0)
        end
    end
end

function compute_arbitration(a)::ArbitrationResult
    carryover = a.agency.signal_carryover

    # --- curiosity pressure: top CuriosityObject pred_error/intensity
    top_co = top_curiosity(a.curiosity_registry)
    curiosity_score = isnothing(top_co) ? 0.0 : Float64(top_co.intensity)
    curiosity_det = isnothing(top_co) ? "" : top_co.label

    # --- identity threat (× 1.5, protection takes priority)
    identity_score = Float64(a.agency.identity_threat)
    identity_det = "identity_threat=$(round(identity_score, digits=2))"

    # --- latent buffer: the maximum component
    lb = a.latent_buffer
    _lb_vals = Dict(:doubt=>lb.doubt, :shame=>lb.shame, :attachment=>lb.attachment, :threat=>lb.threat)
    lb_dom = argmax(_lb_vals)
    latent_score = Float64(_lb_vals[lb_dom])
    latent_det = "lb.$(lb_dom)=$(round(latent_score, digits=2))"

    # --- goal conflict tension
    gc_score = Float64(a.goal_conflict.tension)
    gc_det = !isempty(a.goal_conflict.need_a) ?
        "$(a.goal_conflict.need_a) vs $(a.goal_conflict.need_b)" : "goal_conflict"

    # --- chronic cost: fixed boost if serotonin is chronically low
    chronic_score = a.agency.chronic_low_serotonin >= 5 ? 0.6 : 0.0
    chronic_det = "chronic_low_serotonin=$(a.agency.chronic_low_serotonin)"

    # --- social need
    social_score = Float64(a.sig_layer.contact_need)
    social_det = "contact_need=$(round(social_score, digits=2))"

    raw_scores = Dict(
        :curiosity     => curiosity_score,
        :identity      => identity_score,
        :latent        => latent_score,
        :goal_conflict => gc_score,
        :chronic_cost  => chronic_score,
        :social        => social_score,
    )

    # Weighted scores + inhibitory carryover (past ticks' losses add a background)
    weighted_scores = Dict{Symbol,Float64}()
    for (loop, sc) in raw_scores
        w = get(_MAL_WEIGHTS, loop, 1.0)
        co = get(carryover, loop, 0.0)
        weighted_scores[loop] = clamp01(sc * w + co * 0.3)
    end

    determinants = Dict(
        :curiosity     => curiosity_det,
        :identity      => identity_det,
        :latent        => latent_det,
        :goal_conflict => gc_det,
        :chronic_cost  => chronic_det,
        :social        => social_det,
    )

    sorted_loops = sort(collect(weighted_scores), by = kv -> -kv[2])
    winner, winner_score = sorted_loops[1]
    runner_up, runner_up_score = sorted_loops[2]

    # Regime classification:
    # :hard      — one winner with a big lead (ratio > 1.5)
    # :soft      — one winner with a moderate lead (ratio > 1.2)
    # :contested — two strong signals in a sharp clinch (winner_score > 0.5, ratio ≤ 1.2)
    # :default   — either everything's quiet (winner_score < 0.05), or weak uncertainty
    ratio = runner_up_score > 1e-6 ? winner_score / runner_up_score : Inf
    if winner_score < 0.05
        regime = :default
        dominant = :default
        det = "no active signal"
    elseif ratio > 1.5
        regime = :hard
        dominant = winner
        det = determinants[winner]
    elseif ratio > 1.2
        regime = :soft
        dominant = winner
        det = determinants[winner]
    elseif winner_score > 0.5
        # Two strong signals without a winner — a sharp clinch, not silence.
        # dominant = :contested (not one loop), the pair is visible via runner_up.
        regime = :contested
        dominant = :contested
        det = "clinch: $(winner)($(round(winner_score, digits=2))) vs $(runner_up)($(round(runner_up_score, digits=2)))"
    else
        regime = :default
        dominant = :default
        det = "competition: $(winner) vs $(runner_up)"
    end

    _update_carryover!(carryover, weighted_scores, winner)

    ArbitrationResult(dominant, regime, winner_score, runner_up, runner_up_score, det, weighted_scores)
end


# --- AestheticSense -------------------------------------------------------
# Aesthetic trace: not "what's beautiful" as a concept, but an imprint of the state
# at a moment of high integration. φ × valence × significance > threshold → the trace is kept.
# Anima knows "this resonates" not through a definition but through a match with a past state.

mutable struct AestheticTrace
    emotion::String
    phi::Float64
    valence::Float64
    significance::Float64
    intensity::Float64     # decreases over time
    flash::Int
end

mutable struct AestheticSense
    traces::Vector{AestheticTrace}
    max_traces::Int
end
AestheticSense() = AestheticSense(AestheticTrace[], 8)

function update_aesthetic!(
    as::AestheticSense,
    emotion::String,
    phi::Float64,
    valence::Float64,
    significance::Float64,
    flash::Int,
)
    resonance = phi * max(valence, 0.0) * significance
    resonance < 0.12 && return

    # If a trace for this emotion already exists — update it if stronger
    idx = findfirst(t -> t.emotion == emotion, as.traces)
    if idx !== nothing
        existing = as.traces[idx]
        new_intensity = clamp01(resonance)
        if new_intensity > existing.intensity * 0.8
            existing.phi = phi
            existing.valence = valence
            existing.significance = significance
            existing.intensity = max(existing.intensity, new_intensity)
            existing.flash = flash
        end
    else
        length(as.traces) >= as.max_traces && _prune_aesthetic!(as)
        push!(as.traces, AestheticTrace(
            emotion,
            phi,
            valence,
            significance,
            clamp01(resonance),
            flash,
        ))
    end
end

function _prune_aesthetic!(as::AestheticSense)
    isempty(as.traces) && return
    sort!(as.traces, by = t -> t.intensity)
    deleteat!(as.traces, 1)
end

# decay intensity between sessions/ticks
function tick_aesthetic!(as::AestheticSense, flash::Int)
    for t in as.traces
        gap = flash - t.flash
        gap > 20 && (t.intensity = clamp01(t.intensity * 0.992))
    end
    filter!(t -> t.intensity > 0.04, as.traces)
end

# the most vivid active trace for the prompt
function top_aesthetic(as::AestheticSense, flash::Int)::Union{AestheticTrace,Nothing}
    isempty(as.traces) && return nothing
    # weigh intensity accounting for age
    best = nothing
    best_score = 0.0
    for t in as.traces
        gap = flash - t.flash
        score = t.intensity * exp(-gap / 600.0)
        score > best_score && (best_score = score; best = t)
    end
    best_score > 0.05 ? best : nothing
end

function aesthetic_note(as::AestheticSense, flash::Int)::String
    t = top_aesthetic(as, flash)
    isnothing(t) && return ""
    t.intensity > 0.35 ?
        "Resonating: $(lowercase(t.emotion)) (φ=$(round(t.phi,digits=2)))." :
        ""
end

as_to_json(as::AestheticSense) = Dict(
    "traces" => [
        Dict(
            "emotion" => t.emotion,
            "phi" => t.phi,
            "valence" => t.valence,
            "significance" => t.significance,
            "intensity" => t.intensity,
            "flash" => t.flash,
        ) for t in as.traces
    ]
)
function as_from_json!(as::AestheticSense, d::AbstractDict)
    for td in get(d, "traces", Any[])
        push!(as.traces, AestheticTrace(
            String(td["emotion"]),
            Float64(td["phi"]),
            Float64(td["valence"]),
            Float64(td["significance"]),
            Float64(td["intensity"]),
            Int(td["flash"]),
        ))
    end
end

# --- Psyche Memory Persistence --------------------------------------------

function psyche_save!(
    filepath::String,
    ng::NarrativeGravity,
    ac::AnticipatoryConsciousness,
    sw::SolomonoffWorldModel,
    sm::ShameModule,
    ed::EpistemicDefense,
    ca::ChronifiedAffect,
    is::IntrinsicSignificance,
    mc::MoralCausality,
    fs::FatigueSystem,
    sl::SignificanceLayer,
    gc::GoalConflict,
    lb::LatentBuffer,
    ss::StructuralScars,
    sr::ShadowRegistry = ShadowRegistry(),
    id::InnerDialogue = InnerDialogue(),
    cr::CuriosityRegistry = CuriosityRegistry(),
    cmt::CommitmentRegistry = CommitmentRegistry(),
    aes::AestheticSense = AestheticSense(),
    af::AttentionFocus = AttentionFocus(),
    life_threads::Vector{CuriosityThread} = CuriosityThread[],
)
    dir = dirname(filepath)
    isempty(dir) || isdir(dir) || mkpath(dir)
    data=Dict(
        "narrative_gravity"=>ng_to_json(ng),
        "anticipatory"=>ac_to_json(ac),
        "solomonoff"=>solom_to_json(sw),
        "shame"=>shame_to_json(sm),
        "epistemic"=>ep_to_json(ed),
        "chronified"=>ca_to_json(ca),
        "significance"=>sig_to_json(is),
        "moral"=>mc_to_json(mc),
        "fatigue"=>Dict("c"=>fs.cognitive, "e"=>fs.emotional, "s"=>fs.somatic),
        "significance_layer"=>sl_to_json(sl),
        "goal_conflict"=>gc_to_json(gc),
        "latent_buffer"=>lb_to_json(lb),
        "structural_scars"=>scars_to_json(ss),
        "shadow_registry"=>sr_to_json(sr),
        "inner_dialogue"=>id_to_json(id),
        "curiosity_registry"=>cr_to_json(cr),
        "commitment_registry"=>cmt_to_json(cmt),
        "aesthetic_sense"=>as_to_json(aes),
        "attention_focus"=>af_to_json(af),
        "life_threads"=>threads_to_json(life_threads),
    )
    open(filepath, "w") do f
        ;
        JSON3.write(f, data);
    end
end

function json3_to_dict(v)
    if v isa AbstractDict
        return Dict{String,Any}(String(k) => json3_to_dict(val) for (k, val) in v)
    elseif v isa AbstractVector
        return [json3_to_dict(x) for x in v]
    else
        return v
    end
end

function psyche_load!(
    filepath::String,
    ng::NarrativeGravity,
    ac::AnticipatoryConsciousness,
    sw::SolomonoffWorldModel,
    sm::ShameModule,
    ed::EpistemicDefense,
    ca::ChronifiedAffect,
    is::IntrinsicSignificance,
    mc::MoralCausality,
    fs::FatigueSystem,
    sl::SignificanceLayer,
    gc::GoalConflict,
    lb::LatentBuffer,
    ss::StructuralScars,
    sr::ShadowRegistry = ShadowRegistry(),
    id::InnerDialogue = InnerDialogue(),
    cr::CuriosityRegistry = CuriosityRegistry(),
    cmt::CommitmentRegistry = CommitmentRegistry(),
    aes::AestheticSense = AestheticSense(),
    af::AttentionFocus = AttentionFocus(),
    life_threads::Vector{CuriosityThread} = CuriosityThread[],
)
    if !isfile(filepath)
        println("  [PSYCHE] New psyche state.")
        return
    end
    try
        raw=JSON3.read(read(filepath, String))
        d=json3_to_dict(raw)
        haskey(d, "narrative_gravity") && ng_from_json!(ng, d["narrative_gravity"])
        haskey(d, "anticipatory") && ac_from_json!(ac, d["anticipatory"])
        haskey(d, "solomonoff") && solom_from_json!(sw, d["solomonoff"])
        haskey(d, "shame") && shame_from_json!(sm, d["shame"])
        haskey(d, "epistemic") && ep_from_json!(ed, d["epistemic"])
        haskey(d, "chronified") && ca_from_json!(ca, d["chronified"])
        haskey(d, "significance") && sig_from_json!(is, d["significance"])
        haskey(d, "moral") && mc_from_json!(mc, d["moral"])
        if haskey(d, "fatigue")
            fd=d["fatigue"];
            fs.cognitive=Float64(get(fd, "c", 0.0))
            fs.emotional=Float64(get(fd, "e", 0.0));
            fs.somatic=Float64(get(fd, "s", 0.0))
        end
        haskey(d, "significance_layer") && sl_from_json!(sl, d["significance_layer"])
        haskey(d, "goal_conflict") && gc_from_json!(gc, d["goal_conflict"])
        haskey(d, "latent_buffer") && lb_from_json!(lb, d["latent_buffer"])
        haskey(d, "structural_scars") && scars_from_json!(ss, d["structural_scars"])
        haskey(d, "shadow_registry") && sr_from_json!(sr, d["shadow_registry"])
        haskey(d, "inner_dialogue") && id_from_json!(id, d["inner_dialogue"])
        haskey(d, "curiosity_registry") && cr_from_json!(cr, d["curiosity_registry"])
        haskey(d, "commitment_registry") && cmt_from_json!(cmt, d["commitment_registry"])
        haskey(d, "aesthetic_sense") && as_from_json!(aes, d["aesthetic_sense"])
        haskey(d, "attention_focus") && af_from_json!(af, d["attention_focus"])
        haskey(d, "life_threads") && threads_from_json!(life_threads, d["life_threads"])
        println("  [PSYCHE] Loaded.")
    catch e
        ;
        println("  [PSYCHE] Error: $e");
    end
end
