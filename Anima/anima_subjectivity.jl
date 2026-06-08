# A N I M A  —  Subjectivity Engine
#
# Суб'єктність — власна інтерпретація досвіду, що змінює сприйняття нових подій.
#
# Чотири рівні:
#   Prediction Loop   — передбачення і surprise
#   Interpretation    — забарвлення стимулу досвідом
#   Belief Emergence  — народження нових переконань із патернів
#   Position Memory   — позиція щодо типів ситуацій
#
# Інтеграція з experience!:
#   subj_predict!       — до стимулу
#   subj_interpret!     — між L0 і L1
#   subj_outcome!       — після досвіду
#   subj_emerge_beliefs!— у консолідації пам'яті

if !isdefined(Main, :bg_log)
    bg_log(msg::String) = println(msg)
end
_bg_log_dispatch(msg::String) = isdefined(Main, :bg_log) ? Main.bg_log(msg) : println(msg)

# --- Константи ------------------------------------------------------------

const SUBJ_PRED_LEARNING_RATE = 0.12
const SUBJ_PRED_SURPRISE_THR = 0.25
const SUBJ_PRED_TRAUMA_THR = 0.60

const SUBJ_PATTERN_MIN_OCCUR = 4
const SUBJ_PATTERN_WINDOW = 200
const SUBJ_PATTERN_CLUSTER_THR = 0.18
const SUBJ_PATTERN_PROMOTE_N = 8
const SUBJ_PATTERN_STALE_TICKS = 50

const SUBJ_INTERP_WEIGHT = 0.18
const SUBJ_STANCE_DECAY = 0.998
const SUBJ_STANCE_LEARN_RATE = 0.08

_sfdb(x, d::Float64 = 0.0) = (ismissing(x) || isnothing(x)) ? d : Float64(x)
_sidb(x, d::Int = 0) = (ismissing(x) || isnothing(x)) ? d : Int(x)

# --- Schema ---------------------------------------------------------------

function _init_subjectivity_schema!(db::SQLite.DB)

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS prediction_log (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    flash               INTEGER NOT NULL,
    emotion_context     TEXT    NOT NULL DEFAULT '',
    pred_arousal        REAL    NOT NULL DEFAULT 0.0,
    pred_valence        REAL    NOT NULL DEFAULT 0.0,
    pred_tension        REAL    NOT NULL DEFAULT 0.0,
    pred_pe             REAL    NOT NULL DEFAULT 0.0,
    pred_confidence     REAL    NOT NULL DEFAULT 0.5,
    actual_arousal      REAL,
    actual_valence      REAL,
    actual_tension      REAL,
    actual_pe           REAL,
    surprise            REAL    DEFAULT NULL,
    was_traumatic       INTEGER NOT NULL DEFAULT 0,
    closed              INTEGER NOT NULL DEFAULT 0,
    timestamp           REAL    NOT NULL
);
""",
    )

    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_pred_flash ON prediction_log(flash DESC);",
    )
    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_pred_open ON prediction_log(closed, flash DESC);",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS interpretation_history (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    flash           INTEGER NOT NULL,
    emotion_context TEXT    NOT NULL DEFAULT '',
    lens_type       TEXT    NOT NULL DEFAULT 'neutral',
    lens_strength   REAL    NOT NULL DEFAULT 0.0,
    delta_arousal   REAL    NOT NULL DEFAULT 0.0,
    delta_valence   REAL    NOT NULL DEFAULT 0.0,
    delta_tension   REAL    NOT NULL DEFAULT 0.0,
    source_belief   TEXT    NOT NULL DEFAULT '',
    timestamp       REAL    NOT NULL
);
""",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS pattern_candidates (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    label           TEXT    NOT NULL DEFAULT '',
    centroid_arousal REAL   NOT NULL DEFAULT 0.0,
    centroid_valence REAL   NOT NULL DEFAULT 0.0,
    centroid_tension REAL   NOT NULL DEFAULT 0.0,
    centroid_pe      REAL   NOT NULL DEFAULT 0.0,
    dominant_emotion TEXT   NOT NULL DEFAULT '',
    confirmations   INTEGER NOT NULL DEFAULT 1,
    last_seen_flash INTEGER NOT NULL DEFAULT 0,
    created_flash   INTEGER NOT NULL DEFAULT 0,
    promoted        INTEGER NOT NULL DEFAULT 0
);
""",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS emerged_beliefs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    key             TEXT    NOT NULL UNIQUE,
    belief_type     TEXT    NOT NULL DEFAULT 'situational',
    centroid_arousal REAL   NOT NULL DEFAULT 0.0,
    centroid_valence REAL   NOT NULL DEFAULT 0.0,
    centroid_tension REAL   NOT NULL DEFAULT 0.0,
    centroid_pe      REAL   NOT NULL DEFAULT 0.0,
    strength        REAL    NOT NULL DEFAULT 0.5,
    valence_bias    REAL    NOT NULL DEFAULT 0.0,
    activation_thr  REAL    NOT NULL DEFAULT 0.15,
    confirmations   INTEGER NOT NULL DEFAULT 0,
    contradictions  INTEGER NOT NULL DEFAULT 0,
    last_activated  INTEGER NOT NULL DEFAULT 0,
    created_flash   INTEGER NOT NULL DEFAULT 0,
    source_pattern  INTEGER,
    FOREIGN KEY (source_pattern) REFERENCES pattern_candidates(id)
);
""",
    )

    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_emerged_strength ON emerged_beliefs(strength DESC);",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS positional_stances (
    stance_key      TEXT    PRIMARY KEY,
    valence_stance  REAL    NOT NULL DEFAULT 0.0,
    certainty       REAL    NOT NULL DEFAULT 0.1,
    avoidance_weight REAL   NOT NULL DEFAULT 0.0,
    approach_weight  REAL   NOT NULL DEFAULT 0.0,
    encounter_count INTEGER NOT NULL DEFAULT 0,
    last_updated    INTEGER NOT NULL DEFAULT 0
);
""",
    )

    nothing
end

# --- SubjectivityEngine -----------------------------------------------------

mutable struct SubjectivityEngine
    mem::Any
    _active_pred_id::Union{Int,Nothing}
    _pred_flash::Int
    _emerged_cache::Vector{NamedTuple}
    _emerged_cache_flash::Int
    _stance_cache::Dict{String,NamedTuple}
    _stance_dirty::Bool
    _surprise_accumulator::Float64
    _surprise_n::Int
    _current_lens::String
    _current_lens_strength::Float64
end

function SubjectivityEngine(mem)
    db = mem.db
    _init_subjectivity_schema!(db)

    subj = SubjectivityEngine(
        mem,
        nothing,
        0,
        NamedTuple[],
        0,
        Dict{String,NamedTuple}(),
        true,
        0.0,
        0,
        "neutral",
        0.0,
    )

    _subj_refresh_emerged!(subj)
    _subj_refresh_stances!(subj)
    println("  [SUBJ] Subjectivity Engine ініціалізовано.")
    subj
end

# --- Prediction Loop -------------------------------------------------------

function subj_predict!(
    subj::SubjectivityEngine,
    flash::Int,
    emotion_context::String,
    stim::Dict{String,Float64};
    chronified_affect = nothing,
)::Int

    mem = subj.mem
    db = mem.db

    base_arousal = try
        Float64(mem._rolling_arousal)
    catch
        _subj_mean_episodic(db, "arousal", 20, 0.35)
    end

    base_pe = try
        Float64(mem._rolling_pe)
    catch
        _subj_mean_episodic(db, "prediction_error", 20, 0.3)
    end

    base_tension = get(stim, "tension", 0.5)
    base_valence = get(stim, "satisfaction", 0.0) - 0.5

    if !isnothing(chronified_affect)
        ca = chronified_affect
        resentment = Float64(ca.resentment)
        alienation = Float64(ca.alienation)
        bitterness = Float64(ca.bitterness)

        chronic_neg = resentment * 0.35 + alienation * 0.25 + bitterness * 0.20
        if chronic_neg > 0.05
            base_valence = clamp(base_valence - chronic_neg * 0.4, -1.0, 1.0)
            base_tension = clamp(base_tension + chronic_neg * 0.2, 0.0, 1.0)
            base_arousal = clamp(base_arousal + resentment * 0.1, 0.0, 1.0)
        end

        mot = Float64(get(mem._affect_cache, "motivation_bias", 0.0))
        if mot > 0.1
            base_valence = clamp(base_valence + mot * 0.15, -1.0, 1.0)
        end
    end

    stance = get(subj._stance_cache, emotion_context, nothing)
    if !isnothing(stance)
        certainty_scale = stance.certainty
        base_valence += stance.valence_stance * certainty_scale * 0.3
        base_arousal +=
            (stance.avoidance_weight - stance.approach_weight) * certainty_scale * 0.2
        base_tension += stance.avoidance_weight * certainty_scale * 0.15
    end

    for eb in subj._emerged_cache
        dist =
            abs(eb.centroid_arousal - base_arousal) +
            abs(eb.centroid_valence - base_valence) +
            abs(eb.centroid_tension - base_tension)
        dist /= 3.0
        dist > eb.activation_thr * 2.0 && continue

        pull = (1.0 - dist / (eb.activation_thr * 2.0)) * eb.strength * 0.25
        base_arousal = base_arousal * (1.0 - pull) + eb.centroid_arousal * pull
        base_valence = base_valence * (1.0 - pull) + eb.centroid_valence * pull
        base_pe = base_pe * (1.0 - pull) + eb.centroid_pe * pull
    end

    n_episodic = _count_episodic(db, emotion_context)
    confidence = clamp(0.3 + n_episodic / 50.0, 0.3, 0.85)

    ts = time()
    DBInterface.execute(
        db,
        """
INSERT INTO prediction_log
    (flash, emotion_context, pred_arousal, pred_valence, pred_tension,
     pred_pe, pred_confidence, timestamp)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
""",
        (
            flash,
            emotion_context,
            clamp(base_arousal, 0.0, 1.0),
            clamp(base_valence, -1.0, 1.0),
            clamp(base_tension, 0.0, 1.0),
            clamp(base_pe, 0.0, 1.0),
            confidence,
            ts,
        ),
    )

    id_row =
        first(Tables.rowtable(DBInterface.execute(db, "SELECT last_insert_rowid() as id")))
    pred_id = Int(id_row.id)

    subj._active_pred_id = pred_id
    subj._pred_flash = flash
    pred_id
end

function subj_outcome!(
    subj::SubjectivityEngine,
    flash::Int,
    actual_arousal::Float64,
    actual_valence::Float64,
    actual_tension::Float64,
    actual_pe::Float64,
    emotion_context::String,
)

    db = subj.mem.db
    pred_id = subj._active_pred_id
    isnothing(pred_id) && return

    pred_rows = Tables.rowtable(
        DBInterface.execute(
            db,
            """
    SELECT pred_arousal, pred_valence, pred_tension, pred_pe, pred_confidence
    FROM prediction_log WHERE id = ? AND closed = 0
    """,
            (pred_id,),
        ),
    )

    pred = nothing
    for r in pred_rows
        pred = r;
        break
    end

    isnothing(pred) && (subj._active_pred_id = nothing; return)

    surprise = (
        abs(_sfdb(pred.pred_arousal) - actual_arousal) * 0.25 +
        abs(_sfdb(pred.pred_valence) - actual_valence) * 0.40 +
        abs(_sfdb(pred.pred_tension) - actual_tension) * 0.20 +
        abs(_sfdb(pred.pred_pe) - actual_pe) * 0.15
    )
    surprise = clamp(surprise, 0.0, 1.0)

    effective_surprise = surprise * (0.7 + _sfdb(pred.pred_confidence, 0.5) * 0.3)
    was_traumatic = effective_surprise > SUBJ_PRED_TRAUMA_THR ? 1 : 0

    DBInterface.execute(
        db,
        """
UPDATE prediction_log
SET actual_arousal = ?, actual_valence = ?, actual_tension = ?,
    actual_pe = ?, surprise = ?, was_traumatic = ?, closed = 1
WHERE id = ?
""",
        (
            actual_arousal,
            actual_valence,
            actual_tension,
            actual_pe,
            effective_surprise,
            was_traumatic,
            pred_id,
        ),
    )

    subj._surprise_accumulator =
        subj._surprise_accumulator * 0.85 + effective_surprise * 0.15
    subj._surprise_n += 1

    _update_stance!(
        subj,
        emotion_context,
        actual_valence,
        actual_arousal,
        actual_tension,
        effective_surprise,
        flash,
    )

    _check_belief_resonance!(
        subj,
        actual_arousal,
        actual_valence,
        actual_tension,
        actual_pe,
        flash,
        effective_surprise > SUBJ_PRED_SURPRISE_THR,
    )

    subj._active_pred_id = nothing
    nothing
end

# --- Interpretation Layer ---------------------------------------------------

function subj_interpret!(
    subj::SubjectivityEngine,
    stim::Dict{String,Float64},
    emotion_context::String,
    flash::Int,
)::Dict{String,Float64}

    delta = Dict{String,Float64}()
    db = subj.mem.db

    stance = get(subj._stance_cache, emotion_context, nothing)
    lens_type = "neutral"
    lens_strength = 0.0

    if !isnothing(stance)
        certainty = stance.certainty
        if certainty > 0.3
            if stance.valence_stance < -0.3 && stance.avoidance_weight > 0.4
                lens_type = "threat_amplify"
                lens_strength = certainty * abs(stance.valence_stance)
            elseif stance.valence_stance > 0.3 && stance.approach_weight > 0.3
                lens_type = "familiar_comfort"
                lens_strength = certainty * stance.valence_stance
            elseif stance.valence_stance < -0.15
                lens_type = "avoidance"
                lens_strength = certainty * 0.5
            elseif stance.valence_stance > 0.15
                lens_type = "approach"
                lens_strength = certainty * 0.5
            end
        end
    end

    current_arousal = get(stim, "arousal", 0.5)
    current_tension = get(stim, "tension", 0.5)
    current_valence = get(stim, "satisfaction", 0.5) - 0.5

    dominant_eb_strength = 0.0
    dominant_eb_valence = 0.0

    for eb in subj._emerged_cache
        dist =
            (
                abs(eb.centroid_arousal - current_arousal) +
                abs(eb.centroid_valence - current_valence) +
                abs(eb.centroid_tension - current_tension)
            ) / 3.0
        dist > eb.activation_thr && continue

        resonance = (1.0 - dist / eb.activation_thr) * eb.strength
        if resonance > dominant_eb_strength
            dominant_eb_strength = resonance
            dominant_eb_valence = eb.valence_bias
        end
    end

    scale = SUBJ_INTERP_WEIGHT

    if lens_type == "threat_amplify"
        δa = clamp(lens_strength * scale * 1.2, 0.0, 0.15)
        δt = clamp(lens_strength * scale, 0.0, 0.12)
        δs = clamp(-lens_strength * scale * 0.8, -0.10, 0.0)
        delta["arousal"] = δa
        delta["tension"] = δt
        delta["satisfaction"] = δs
    elseif lens_type == "familiar_comfort"
        δa = clamp(-lens_strength * scale * 0.5, -0.08, 0.0)
        δs = clamp(lens_strength * scale * 0.9, 0.0, 0.10)
        delta["arousal"] = δa
        delta["satisfaction"] = δs
    elseif lens_type == "avoidance"
        δt = clamp(lens_strength * scale, 0.0, 0.10)
        δs = clamp(-lens_strength * scale * 0.6, -0.08, 0.0)
        delta["tension"] = δt
        delta["satisfaction"] = δs
    elseif lens_type == "approach"
        δa = clamp(lens_strength * scale * 0.4, 0.0, 0.06)
        δs = clamp(lens_strength * scale * 0.7, 0.0, 0.09)
        delta["arousal"] = δa
        delta["satisfaction"] = δs
    end

    if dominant_eb_strength > 0.4
        eb_scale = dominant_eb_strength * scale * 0.8
        if dominant_eb_valence < -0.2
            delta["tension"] = get(delta, "tension", 0.0) + clamp(eb_scale, 0.0, 0.12)
            delta["satisfaction"] =
                get(delta, "satisfaction", 0.0) - clamp(eb_scale * 0.7, 0.0, 0.09)
        elseif dominant_eb_valence > 0.2
            delta["satisfaction"] =
                get(delta, "satisfaction", 0.0) + clamp(eb_scale * 0.8, 0.0, 0.10)
        end
    end

    if lens_type != "neutral" || dominant_eb_strength > 0.2
        subj._current_lens = lens_type
        subj._current_lens_strength = max(lens_strength, dominant_eb_strength)

        DBInterface.execute(
            db,
            """
INSERT INTO interpretation_history
    (flash, emotion_context, lens_type, lens_strength,
     delta_arousal, delta_valence, delta_tension,
     source_belief, timestamp)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
""",
            (
                flash,
                emotion_context,
                lens_type,
                max(lens_strength, dominant_eb_strength),
                get(delta, "arousal", 0.0),
                get(delta, "satisfaction", 0.0),
                get(delta, "tension", 0.0),
                dominant_eb_strength > 0.4 ? "emerged_belief" : emotion_context,
                time(),
            ),
        )
    end

    delta
end

# --- Belief Emergence ------------------------------------------------------

function subj_emerge_beliefs!(subj::SubjectivityEngine, flash::Int)
    db = subj.mem.db
    subj._emerged_cache_flash = flash

    rows = Tables.rowtable(
        DBInterface.execute(
            db,
            """
SELECT arousal, valence, prediction_error, tension, emotion, weight
FROM episodic_memory
WHERE weight > 0.3
ORDER BY flash DESC
LIMIT ?
""",
            (SUBJ_PATTERN_WINDOW,),
        ),
    )

    length(rows) < SUBJ_PATTERN_MIN_OCCUR && return

    clusters = Vector{Dict{Symbol,Any}}()

    for row in rows
        a = _sfdb(row.arousal)
        v = _sfdb(row.valence)
        t = _sfdb(row.tension)
        p = _sfdb(row.prediction_error)
        e = String(row.emotion)
        w = _sfdb(row.weight, 0.3)

        matched = false
        for cl in clusters
            dist = (abs(cl[:ca] - a) + abs(cl[:cv] - v) + abs(cl[:ct] - t)) / 3.0
            if dist < SUBJ_PATTERN_CLUSTER_THR
                α = 0.2
                cl[:ca] = cl[:ca] * (1-α) + a * α
                cl[:cv] = cl[:cv] * (1-α) + v * α
                cl[:ct] = cl[:ct] * (1-α) + t * α
                cl[:cp] = cl[:cp] * (1-α) + p * α
                cl[:n] = cl[:n] + 1
                cl[:sum_w] = cl[:sum_w] + w
                cl[:emotions][e] = get(cl[:emotions], e, 0) + 1
                matched = true
                break
            end
        end

        if !matched
            push!(
                clusters,
                Dict(
                    :ca => a,
                    :cv => v,
                    :ct => t,
                    :cp => p,
                    :n => 1,
                    :sum_w => w,
                    :emotions => Dict(e => 1),
                ),
            )
        end
    end

    for cl in clusters
        cl[:n] < SUBJ_PATTERN_MIN_OCCUR && continue

        dom_emotion = argmax(cl[:emotions])
        val_sign = cl[:cv] > 0.1 ? "+" : (cl[:cv] < -0.1 ? "-" : "~")
        label = "$(dom_emotion)$(val_sign)_a$(round(cl[:ca], digits=1))"

        existing_rows = Tables.rowtable(
            DBInterface.execute(
                db,
                """
SELECT id, confirmations, promoted
FROM pattern_candidates
WHERE ABS(centroid_arousal - ?) < ? AND
      ABS(centroid_valence - ?) < ? AND
      ABS(centroid_tension - ?) < ? AND
      promoted = 0
LIMIT 1
""",
                (
                    cl[:ca],
                    SUBJ_PATTERN_CLUSTER_THR,
                    cl[:cv],
                    SUBJ_PATTERN_CLUSTER_THR,
                    cl[:ct],
                    SUBJ_PATTERN_CLUSTER_THR,
                ),
            ),
        )

        found_id = nothing
        found_conf = 0

        for er in existing_rows
            found_id = _sidb(er.id)
            found_conf = _sidb(er.confirmations)
            break
        end

        if isnothing(found_id)
            DBInterface.execute(
                db,
                """
INSERT INTO pattern_candidates
    (label, centroid_arousal, centroid_valence, centroid_tension,
     centroid_pe, dominant_emotion, confirmations, last_seen_flash, created_flash)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
""",
                (
                    label,
                    cl[:ca],
                    cl[:cv],
                    cl[:ct],
                    cl[:cp],
                    dom_emotion,
                    cl[:n],
                    flash,
                    flash,
                ),
            )
        else
            new_conf = found_conf + cl[:n]
            DBInterface.execute(
                db,
                """
UPDATE pattern_candidates
SET confirmations   = ?,
    last_seen_flash = ?,
    centroid_arousal = (centroid_arousal + ?) / 2.0,
    centroid_valence = (centroid_valence + ?) / 2.0,
    centroid_tension = (centroid_tension + ?) / 2.0,
    centroid_pe      = (centroid_pe      + ?) / 2.0
WHERE id = ?
""",
                (new_conf, flash, cl[:ca], cl[:cv], cl[:ct], cl[:cp], found_id),
            )

            if new_conf >= SUBJ_PATTERN_PROMOTE_N
                _promote_to_belief!(subj, found_id, label, cl, dom_emotion, flash)
            end
        end
    end

    DBInterface.execute(
        db,
        """
DELETE FROM pattern_candidates
WHERE promoted = 0
  AND (? - last_seen_flash) > ?
  AND confirmations < ?
""",
        (flash, SUBJ_PATTERN_STALE_TICKS, SUBJ_PATTERN_PROMOTE_N),
    )

    DBInterface.execute(
        db,
        """
UPDATE emerged_beliefs
SET strength = strength * 0.9998
WHERE (? - last_activated) > 30 AND strength > 0.05
""",
        (flash,),
    )

    DBInterface.execute(
        db,
        """
UPDATE emerged_beliefs
SET strength = strength * 0.98
WHERE contradictions > confirmations AND strength > 0.05
""",
    )

    _subj_refresh_emerged!(subj)
    nothing
end

function _promote_to_belief!(
    subj::SubjectivityEngine,
    pattern_id::Int,
    label::String,
    cl::Dict,
    dom_emotion::String,
    flash::Int,
)
    db = subj.mem.db

    belief_type = if cl[:cp] > 0.55 && cl[:ca] > 0.5
        "world"
    elseif cl[:cv] < -0.3 && cl[:ct] > 0.5
        "situational"
    elseif cl[:cv] > 0.25 && cl[:ca] > 0.4
        "relational"
    else
        "situational"
    end

    key = "EB:$(label):$(flash)"
    valence_bias = cl[:cv]
    avg_w = cl[:sum_w] / max(cl[:n], 1)
    activation_thr = SUBJ_PATTERN_CLUSTER_THR * (1.0 + (1.0 - avg_w) * 0.5)

    existing =
        DBInterface.execute(db, "SELECT 1 FROM emerged_beliefs WHERE key = ?", (key,))
    is_new = isempty(Tables.rowtable(existing))

    DBInterface.execute(
        db,
        """
INSERT OR IGNORE INTO emerged_beliefs
    (key, belief_type, centroid_arousal, centroid_valence, centroid_tension,
     centroid_pe, strength, valence_bias, activation_thr, confirmations,
     last_activated, created_flash, source_pattern)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""",
        (
            key,
            belief_type,
            cl[:ca],
            cl[:cv],
            cl[:ct],
            cl[:cp],
            0.5,
            valence_bias,
            activation_thr,
            cl[:n],
            flash,
            flash,
            pattern_id,
        ),
    )

    DBInterface.execute(
        db,
        """
UPDATE pattern_candidates SET promoted = 1 WHERE id = ?
""",
        (pattern_id,),
    )

    is_new && _bg_log_dispatch(
        "  [SUBJ] Нове переконання: \"$(key)\" ($(belief_type), val=$(round(valence_bias, digits=2)))",
    )

    if valence_bias < -0.4 && cl[:cp] > 0.5
        _upsert_semantic_subj!(
            db,
            "EB_structural_fragility",
            abs(valence_bias) * cl[:cp] * 0.012,
            0.0,
            1.0,
            "emerged_belief",
        )
    end

    _subj_refresh_emerged!(subj)
    nothing
end

# --- Positional Stances ---------------------------------------------------

function _update_stance!(
    subj::SubjectivityEngine,
    stance_key::String,
    actual_valence::Float64,
    actual_arousal::Float64,
    actual_tension::Float64,
    surprise::Float64,
    flash::Int,
)
    db = subj.mem.db

    approach = actual_valence > 0.1 ? actual_valence * SUBJ_STANCE_LEARN_RATE : 0.0
    avoidance =
        (actual_valence < -0.1 && actual_tension > 0.4) ?
        abs(actual_valence) * actual_tension * SUBJ_STANCE_LEARN_RATE : 0.0

    surprise_amp = 1.0 + surprise * 0.5
    valence_delta = actual_valence * SUBJ_STANCE_LEARN_RATE * surprise_amp

    try
        SQLite.transaction(db) do
            DBInterface.execute(
                db,
                """
INSERT INTO positional_stances
    (stance_key, valence_stance, certainty, avoidance_weight,
     approach_weight, encounter_count, last_updated)
VALUES (?, ?, 0.1, ?, ?, 1, ?)
ON CONFLICT(stance_key) DO UPDATE SET
    valence_stance   = MIN(1.0, MAX(-1.0,
                           valence_stance * 0.92 + ? )),
    certainty        = MIN(0.95, certainty + 0.03),
    avoidance_weight = MIN(1.0, avoidance_weight * 0.95 + ?),
    approach_weight  = MIN(1.0, approach_weight  * 0.95 + ?),
    encounter_count  = encounter_count + 1,
    last_updated     = ?
""",
                (
                    stance_key,
                    clamp(valence_delta, -1.0, 1.0),
                    clamp(avoidance * surprise_amp, 0.0, 0.3),
                    clamp(approach * surprise_amp, 0.0, 0.3),
                    flash,
                    valence_delta,
                    clamp(avoidance * surprise_amp, 0.0, 0.1),
                    clamp(approach * surprise_amp, 0.0, 0.1),
                    flash,
                ),
            )
        end
    catch e
        @warn "[SUBJ] stance update помилка: $e"
    end

    subj._stance_dirty = true
    _subj_refresh_stances!(subj)
    nothing
end

# --- Belief Resonance ------------------------------------------------------

function _check_belief_resonance!(
    subj::SubjectivityEngine,
    actual_arousal::Float64,
    actual_valence::Float64,
    actual_tension::Float64,
    actual_pe::Float64,
    flash::Int,
    is_surprise::Bool,
)
    db = subj.mem.db

    try
        SQLite.transaction(db) do
            for eb in subj._emerged_cache
                dist =
                    (
                        abs(eb.centroid_arousal - actual_arousal) +
                        abs(eb.centroid_valence - actual_valence) +
                        abs(eb.centroid_tension - actual_tension)
                    ) / 3.0
                dist > eb.activation_thr && continue

                strength_delta = 0.008 * (1.0 - dist / eb.activation_thr)

                if eb.valence_bias * actual_valence < -0.1
                    DBInterface.execute(
                        db,
                        """
UPDATE emerged_beliefs
SET contradictions = contradictions + 1,
    strength = MAX(0.05, strength - 0.015),
    last_activated = ?
WHERE key = ?
""",
                        (flash, eb.key),
                    )
                else
                    DBInterface.execute(
                        db,
                        """
UPDATE emerged_beliefs
SET confirmations = confirmations + 1,
    strength = MIN(0.95, strength + ?),
    last_activated = ?
WHERE key = ?
""",
                        (strength_delta, flash, eb.key),
                    )
                end
            end
        end
    catch e
        @warn "[SUBJ] belief resonance помилка: $e"
    end

    _subj_refresh_emerged!(subj)
    nothing
end

# --- Cache Refresh ---------------------------------------------------------

function _subj_refresh_emerged!(subj::SubjectivityEngine)
    db = subj.mem.db
    subj._emerged_cache = NamedTuple[]

    for row in Tables.rowtable(
        DBInterface.execute(
            db,
            """
    SELECT key, belief_type, centroid_arousal, centroid_valence,
           centroid_tension, centroid_pe, strength, valence_bias,
           activation_thr, confirmations, contradictions
    FROM emerged_beliefs
    WHERE strength > 0.1
    ORDER BY strength DESC
    LIMIT 20
    """,
        ),
    )
        push!(
            subj._emerged_cache,
            (
                key = String(row.key),
                belief_type = String(row.belief_type),
                centroid_arousal = _sfdb(row.centroid_arousal),
                centroid_valence = _sfdb(row.centroid_valence),
                centroid_tension = _sfdb(row.centroid_tension),
                centroid_pe = _sfdb(row.centroid_pe),
                strength = _sfdb(row.strength, 0.5),
                valence_bias = _sfdb(row.valence_bias),
                activation_thr = _sfdb(row.activation_thr, 0.15),
                confirmations = _sidb(row.confirmations),
                contradictions = _sidb(row.contradictions),
            ),
        )
    end
end

function _subj_refresh_stances!(subj::SubjectivityEngine)
    db = subj.mem.db
    empty!(subj._stance_cache)

    for row in Tables.rowtable(
        DBInterface.execute(
            db,
            """
    SELECT stance_key, valence_stance, certainty,
           avoidance_weight, approach_weight, encounter_count
    FROM positional_stances
    WHERE certainty > 0.1
    """,
        ),
    )
        subj._stance_cache[String(row.stance_key)] = (
            valence_stance = _sfdb(row.valence_stance),
            certainty = _sfdb(row.certainty, 0.1),
            avoidance_weight = _sfdb(row.avoidance_weight),
            approach_weight = _sfdb(row.approach_weight),
            encounter_count = _sidb(row.encounter_count),
        )
    end
    subj._stance_dirty = false
end

# --- Helpers ---------------------------------------------------------------

function _subj_mean_episodic(
    db::SQLite.DB,
    col::String,
    limit::Int,
    default::Float64,
)::Float64
    allowed =
        Set(["arousal", "valence", "prediction_error", "tension", "phi", "self_impact"])
    col in allowed || return default

    sql =
        "SELECT COALESCE(AVG($col), ?) as val FROM (SELECT $col FROM episodic_memory " *
        "WHERE weight > 0.3 ORDER BY flash DESC LIMIT ?)"
    rows = Tables.rowtable(DBInterface.execute(db, sql, (default, limit)))
    for r in rows
        return _sfdb(r.val, default)
    end
    default
end

function _count_episodic(db::SQLite.DB, emotion::String)::Int
    rows = Tables.rowtable(
        DBInterface.execute(
            db,
            """
    SELECT COUNT(*) as n FROM episodic_memory
    WHERE emotion = ? AND weight > 0.3
    """,
            (emotion,),
        ),
    )
    for r in rows
        return _sidb(r.n)
    end
    return 0
end

function _upsert_semantic_subj!(
    db::SQLite.DB,
    key::String,
    delta::Float64,
    lo::Float64,
    hi::Float64,
    source::String,
)
    DBInterface.execute(
        db,
        """
INSERT INTO semantic_memory (key, value, source, updated)
VALUES (?, ?, ?, 0)
ON CONFLICT(key) DO UPDATE
SET value  = MIN(?, MAX(?, value + ?)),
    source = ?
""",
        (key, clamp(delta, lo, hi), source, hi, lo, delta, source),
    )
end

# --- Snapshot / Debug -----------------------------------------------------

function subj_snapshot(subj::SubjectivityEngine)
    db = subj.mem.db

    n_beliefs_row = first(
        Tables.rowtable(
            DBInterface.execute(
                db,
                "SELECT COUNT(*) as n FROM emerged_beliefs WHERE strength > 0.1",
            ),
        ),
    )
    n_beliefs = _sidb(n_beliefs_row.n)

    n_candidates_row = first(
        Tables.rowtable(
            DBInterface.execute(
                db,
                "SELECT COUNT(*) as n FROM pattern_candidates WHERE promoted = 0",
            ),
        ),
    )
    n_candidates = _sidb(n_candidates_row.n)

    n_stances = length(subj._stance_cache)

    top_beliefs = String[]
    for eb in subj._emerged_cache[1:min(3, length(subj._emerged_cache))]
        push!(top_beliefs, "$(eb.key)($(round(eb.strength, digits=2)))")
    end

    dom_stance = ""
    max_cert = 0.0
    for (k, s) in subj._stance_cache
        if s.certainty > max_cert
            max_cert = s.certainty
            dom_stance = "$k→$(round(s.valence_stance, digits=2))"
        end
    end

    avg_surprise = subj._surprise_n > 0 ? subj._surprise_accumulator : 0.0
    current_lens =
        subj._current_lens != "neutral" ?
        "$(subj._current_lens)($(round(subj._current_lens_strength, digits=2)))" : ""

    (
        emerged_beliefs = n_beliefs,
        pattern_candidates = n_candidates,
        stances = n_stances,
        top_beliefs = join(top_beliefs, ", "),
        dominant_stance = dom_stance,
        surprise_level = round(avg_surprise, digits = 3),
        current_lens = current_lens,
        active_prediction = !isnothing(subj._active_pred_id),
    )
end

# --- Delta Safety ---------------------------------------------------------

function clamp_merged_delta!(delta::Dict{String,Float64})
    haskey(delta, "tension") && (delta["tension"] = clamp(delta["tension"], -0.25, 0.25))
    haskey(delta, "satisfaction") &&
        (delta["satisfaction"] = clamp(delta["satisfaction"], -0.20, 0.20))
    haskey(delta, "arousal") && (delta["arousal"] = clamp(delta["arousal"], -0.20, 0.20))
    haskey(delta, "cohesion") && (delta["cohesion"] = clamp(delta["cohesion"], -0.15, 0.15))
    delta
end
