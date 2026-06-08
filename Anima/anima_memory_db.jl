# A N I M A  —  Memory DB  (Julia)
#
# Пам'ять як поле, що впливає на кожен шар системи.
# SQLite: episodic, semantic, affect_state, latent_buffer, dialog_summaries,
# personality_traits, memory_links.
#
# Інтеграція з experience!:
#   memory_write_event!    — після стимулу (буфер)
#   memory_stimulus_bias   — між L0 і L1 (упередження стимулу)
#   memory_nt_baseline!    — L1 (NT baseline з affect_state)
#   memory_self_update!    — після SelfBeliefGraph (← semantic)
#
# Фоновий процес:
#   stop_memory_loop!      — зупинка циклу (цикл запускається через slow_tick!)

using SQLite
using Tables

# --- Константи ------------------------------------------------------------

const MEM_IMPORTANCE_THRESHOLD = 0.20
const MEM_CORE_MAX = 500
const MEM_DECAY_RATE = 0.001
const MEM_MIN_WEIGHT = 0.05
const MEM_DISSOLVE_THRESHOLD = 0.12  # нижче цього і phi < 0.35 → дистиляція перед видаленням
const MEM_DISSOLVE_PHI_THR   = 0.35  # сильні спогади (φ вище цього) не розчиняються
const MEM_CONSOLIDATE_THRESHOLD = 0.35
const MEM_TOPK_INFLUENCE = 10
const MEM_AFFECT_DECAY = 0.995
const MEM_LINK_SIMILARITY_THR = 0.75
const MEM_MAX_NT_BIAS = 0.08
const MEM_MAX_PRED_BIAS = 0.15
const MEM_MAX_STIM_BIAS = 0.12

const DIALOG_SUMMARY_THR = 0.35
const DIALOG_SUMMARY_MAX = 200
const DIALOG_SUMMARY_RECALL = 5

const PHENOTYPE_INFLUENCE_THR = 0.35
const PHENOTYPE_STEP = 0.003
const PHENOTYPE_DECAY = 0.9998

const EPISODIC_VEC_FIELDS =
    [:arousal, :valence, :tension, :phi, :prediction_error, :self_impact]
const SIMILAR_STATE_THR = 0.88
const SIMILAR_STATE_TOP_N = 3
const MEM_ASSOC_LINK_SCALE = 0.6   # relevance пов'язаного = original * link_strength * scale
const MEM_RECONSOLIDATE_SIM = 0.88  # поріг схожості для reconsolidation
const MEM_RECONSOLIDATE_MAX_W = 0.6 # reconsolidate тільки якщо weight < цього
const MEM_RECONSOLIDATE_STEP = 0.05 # крок зсуву weight при реактивації

_fdb(x, d::Float64 = 0.0) = (ismissing(x) || isnothing(x)) ? d : Float64(x)

# --- MemoryDB -------------------------------------------------------------

mutable struct MemoryDB
    db::SQLite.DB
    path::String
    _affect_cache::Dict{String,Float64}
    _semantic_cache::Dict{String,Float64}
    _cache_dirty::Bool
    _cache_flash::Int
    _rolling_arousal::Float64
    _rolling_pe::Float64
    _rolling_n::Int
    _loop_task::Union{Task,Nothing}
    _loop_stop::Threads.Atomic{Bool}
end

function MemoryDB(db_path::String = joinpath("memory", "anima.db"))
    dir = dirname(db_path)
    isempty(dir) || isdir(dir) || mkpath(dir)

    db = SQLite.DB(db_path)
    SQLite.busy_timeout(db, 5000)
    _init_schema!(db)
    ensure_narrative_table!(db)

    mem = MemoryDB(
        db,
        db_path,
        Dict{String,Float64}(),
        Dict{String,Float64}(),
        true,
        0,
        0.3,
        0.3,
        0,
        nothing,
        Threads.Atomic{Bool}(false),
    )

    _refresh_cache!(mem)
    println("  [MEM] База пам'яті: $db_path")
    mem
end

# --- Schema ---------------------------------------------------------------

function _init_schema!(db::SQLite.DB)
    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS episodic_memory (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    flash           INTEGER NOT NULL,
    timestamp       REAL    NOT NULL,
    emotion         TEXT    NOT NULL DEFAULT '',
    arousal         REAL    NOT NULL DEFAULT 0.0,
    valence         REAL    NOT NULL DEFAULT 0.0,
    prediction_error REAL   NOT NULL DEFAULT 0.0,
    self_impact     REAL    NOT NULL DEFAULT 0.0,
    tension         REAL    NOT NULL DEFAULT 0.0,
    phi             REAL    NOT NULL DEFAULT 0.0,
    weight          REAL    NOT NULL DEFAULT 0.5,
    resistance      REAL    NOT NULL DEFAULT 0.0,
    signature       REAL    NOT NULL DEFAULT 0.0
);
""",
    )

    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_episodic_weight ON episodic_memory(weight DESC);",
    )
    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_episodic_flash ON episodic_memory(flash DESC);",
    )
    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_episodic_emotion ON episodic_memory(emotion, weight DESC);",
    )

    # Три простори пам'яті + source — додаємо якщо ще немає (міграція живої БД)
    for col_def in [
        ("som_arousal",    "REAL"),
        ("som_tension",    "REAL"),
        ("som_intero",     "REAL"),
        ("som_hrv",        "REAL"),
        ("soc_valence",    "REAL"),
        ("soc_impact",     "REAL"),
        ("soc_resistance", "REAL"),
        ("soc_phi",        "REAL"),
        ("exi_phi",        "REAL"),
        ("exi_pe",         "REAL"),
        ("exi_agency",     "REAL"),
        ("exi_trust",      "REAL"),
        ("source",            "TEXT DEFAULT 'external'"),
        ("endorsed",          "TEXT DEFAULT 'automatic'"),
        ("causal_ownership",  "REAL DEFAULT NULL"),
    ]
        col, typ = col_def
        try
            SQLite.execute(db, "ALTER TABLE episodic_memory ADD COLUMN $col $typ")
        catch
            # вже є — ігноруємо
        end
    end
    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS episodic_self_links (
    flash       INTEGER NOT NULL,
    belief_name TEXT    NOT NULL,
    confidence  REAL    NOT NULL DEFAULT 0.0,
    centrality  REAL    NOT NULL DEFAULT 0.0,
    direction   TEXT    NOT NULL DEFAULT 'neutral',
    PRIMARY KEY (flash, belief_name)
);
""",
    )
    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_esl_flash ON episodic_self_links(flash DESC);",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS memory_links (
    id_a     INTEGER NOT NULL,
    id_b     INTEGER NOT NULL,
    strength REAL    NOT NULL DEFAULT 0.0,
    co_occur INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (id_a, id_b),
    FOREIGN KEY (id_a) REFERENCES episodic_memory(id) ON DELETE CASCADE,
    FOREIGN KEY (id_b) REFERENCES episodic_memory(id) ON DELETE CASCADE
);
""",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS semantic_memory (
    key     TEXT    PRIMARY KEY,
    value   REAL    NOT NULL DEFAULT 0.0,
    source  TEXT    NOT NULL DEFAULT 'accumulated',
    updated INTEGER NOT NULL DEFAULT 0
);
""",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS affect_state (
    name    TEXT    PRIMARY KEY,
    value   REAL    NOT NULL DEFAULT 0.0,
    updated INTEGER NOT NULL DEFAULT 0
);
""",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS latent_buffer (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    importance  REAL    NOT NULL,
    valence     REAL    NOT NULL DEFAULT 0.0,
    tension     REAL    NOT NULL DEFAULT 0.0,
    flash       INTEGER NOT NULL DEFAULT 0,
    timestamp   REAL    NOT NULL
);
""",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS dialog_summaries (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    flash         INTEGER NOT NULL,
    timestamp     REAL    NOT NULL,
    user_text     TEXT    NOT NULL DEFAULT '',
    anima_text    TEXT    NOT NULL DEFAULT '',
    emotion       TEXT    NOT NULL DEFAULT '',
    weight        REAL    NOT NULL DEFAULT 0.0,
    phi           REAL    NOT NULL DEFAULT 0.0,
    valence       REAL    NOT NULL DEFAULT 0.0,
    disclosure    TEXT    NOT NULL DEFAULT 'guarded'
);
""",
    )

    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_dialog_weight ON dialog_summaries(weight DESC);",
    )
    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_dialog_flash ON dialog_summaries(flash DESC);",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS personality_traits (
    trait          TEXT    PRIMARY KEY,
    score          REAL    NOT NULL DEFAULT 0.0,
    evidence_count INTEGER NOT NULL DEFAULT 0,
    valence_bias   REAL    NOT NULL DEFAULT 0.0,
    last_updated   INTEGER NOT NULL DEFAULT 0
);
""",
    )

    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_traits_score ON personality_traits(score DESC);",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS other_model (
    key        TEXT    PRIMARY KEY,
    value      REAL    NOT NULL DEFAULT 0.0,
    label      TEXT    NOT NULL DEFAULT '',
    count      INTEGER NOT NULL DEFAULT 0,
    last_flash INTEGER NOT NULL DEFAULT 0
);
""",
    )

    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    flash            INTEGER NOT NULL,
    timestamp        REAL    NOT NULL,
    causal_necessary INTEGER NOT NULL DEFAULT 0,
    memory_indep     INTEGER NOT NULL DEFAULT 0,
    stake_present    INTEGER NOT NULL DEFAULT 0,
    irreversible     INTEGER NOT NULL DEFAULT 0,
    self_recognized  INTEGER NOT NULL DEFAULT 0,
    audit_score      REAL    NOT NULL DEFAULT 0.0,
    causal_ownership REAL    NOT NULL DEFAULT 0.0,
    endorsed         TEXT    NOT NULL DEFAULT 'automatic'
);
""",
    )
    SQLite.execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_audit_flash ON audit_log(flash DESC);",
    )
end

# --- Endorsement update ---------------------------------------------------

function update_episodic_endorsement!(mem::MemoryDB, flash::Int, endorsed::String)
    DBInterface.execute(
        mem.db,
        """UPDATE episodic_memory SET endorsed=?
           WHERE id=(SELECT MAX(id) FROM episodic_memory WHERE flash=?)""",
        (endorsed, flash),
    )
end

function update_episodic_causal_ownership!(mem::MemoryDB, flash::Int, co::Float64)
    DBInterface.execute(
        mem.db,
        """UPDATE episodic_memory SET causal_ownership=?
           WHERE id=(SELECT MAX(id) FROM episodic_memory WHERE flash=?)""",
        (co, flash),
    )
end

# --- Кеш ------------------------------------------------------------------

function _refresh_cache!(mem::MemoryDB)
    empty!(mem._affect_cache)
    for row in
        Tables.rowtable(DBInterface.execute(mem.db, "SELECT name, value FROM affect_state"))
        mem._affect_cache[row.name] = row.value
    end

    empty!(mem._semantic_cache)
    for row in Tables.rowtable(
        DBInterface.execute(mem.db, "SELECT key, value FROM semantic_memory"),
    )
        mem._semantic_cache[row.key] = row.value
    end

    mem._cache_dirty = false
end

function _maybe_refresh!(mem::MemoryDB, current_flash::Int; every::Int = 10)
    if mem._cache_dirty || (current_flash - mem._cache_flash) >= every
        _refresh_cache!(mem)
        mem._cache_flash = current_flash
    end
end

# --- Запис події ----------------------------------------------------------

function memory_write_event!(
    mem::MemoryDB,
    flash::Int,
    emotion::String,
    arousal::Float64,
    valence::Float64,
    prediction_error::Float64,
    self_impact::Float64,
    tension::Float64,
    phi::Float64;
    intero_error::Float64 = 0.3,
    hrv::Float64 = 0.5,
    agency_confidence::Float64 = 0.5,
    epistemic_trust::Float64 = 0.5,
    source::String = "external",
)

    α = 0.15
    mem._rolling_arousal = mem._rolling_arousal * (1-α) + arousal * α
    mem._rolling_pe = mem._rolling_pe * (1-α) + prediction_error * α
    mem._rolling_n += 1

    current_stress = get(mem._affect_cache, "stress", 0.0)
    stress_amp = 1.0 + current_stress * 0.6

    arousal_surprise = abs(arousal - mem._rolling_arousal)
    pe_surprise = abs(prediction_error - mem._rolling_pe)

    imp = (
        0.25 * prediction_error +
        0.20 * arousal +
        0.20 * abs(valence) +
        0.15 * self_impact +
        0.10 * arousal_surprise +
        0.10 * pe_surprise
    )
    imp = clamp(imp * stress_amp, 0.0, 1.0)

    dynamic_threshold = MEM_IMPORTANCE_THRESHOLD * (1.0 - current_stress * 0.3)

    if imp < dynamic_threshold
        if imp > 0.05
            ts = time()
            DBInterface.execute(
                mem.db,
                """
INSERT INTO latent_buffer (importance, valence, tension, flash, timestamp)
VALUES (?, ?, ?, ?, ?)
""",
                (imp, valence, tension, flash, ts),
            )
        end
        return
    end

    ts = time()

    resistance =
        clamp(self_impact * 0.6 + abs(valence) * 0.3 * (valence < 0 ? 1.4 : 0.7), 0.0, 1.0)
    signature = arousal * 0.5 + prediction_error * 0.3 + abs(self_impact) * 0.2

    dedup_rows = Tables.rowtable(
        DBInterface.execute(
            mem.db,
            """
    SELECT id, weight FROM episodic_memory
    WHERE ABS(signature - ?) < 0.08 AND flash >= ?
    ORDER BY flash DESC LIMIT 1
    """,
            (signature, flash - 3),
        ),
    )

    dedup_hit = false
    for dr in dedup_rows
        new_w = clamp(_fdb(dr.weight) * 1.15, 0.0, 1.0)
        DBInterface.execute(
            mem.db,
            """
UPDATE episodic_memory SET weight = ? WHERE id = ?
""",
            (new_w, dr.id),
        )
        dedup_hit = true
        break
    end

    dedup_hit && return

    DBInterface.execute(
        mem.db,
        """
INSERT INTO episodic_memory
    (flash, timestamp, emotion, arousal, valence,
     prediction_error, self_impact, tension, phi, weight, resistance, signature,
     som_arousal, som_tension, som_intero, som_hrv,
     soc_valence, soc_impact, soc_resistance, soc_phi,
     exi_phi, exi_pe, exi_agency, exi_trust, source)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""",
        (
            flash, ts, emotion,
            arousal, valence, prediction_error, self_impact, tension, phi,
            imp, resistance, signature,
            # соматичний
            clamp(arousal, 0.0, 1.0),
            clamp(tension, 0.0, 1.0),
            clamp(intero_error, 0.0, 1.0),
            clamp(hrv, 0.0, 1.0),
            # соціальний
            clamp((valence + 1.0) / 2.0, 0.0, 1.0),
            clamp(self_impact, 0.0, 1.0),
            clamp(resistance, 0.0, 1.0),
            clamp(phi, 0.0, 1.0),
            # екзистенційний
            clamp(phi, 0.0, 1.0),
            clamp(prediction_error, 0.0, 1.0),
            clamp(agency_confidence, 0.0, 1.0),
            clamp(epistemic_trust, 0.0, 1.0),
            source,
        ),
    )

    stress_inc = clamp((tension - 0.3) * 0.4 + (arousal - 0.3) * 0.4, 0.0, 1.0)
    if stress_inc > 0.0
        _upsert_affect!(mem.db, "stress", stress_inc * imp * 0.005, 0.0, 1.0)
    end

    if valence < -0.1 && prediction_error > 0.3
        anxiety_inc = abs(valence) * prediction_error
        _upsert_affect!(mem.db, "anxiety", anxiety_inc * imp * 0.004, 0.0, 1.0)
    end

    if valence > 0.15 && phi > 0.2
        _upsert_affect!(mem.db, "motivation_bias", valence * phi * imp * 0.003, 0.0, 1.0)
    end

    mem._cache_dirty = true

    new_id_row = first(
        Tables.rowtable(DBInterface.execute(mem.db, "SELECT last_insert_rowid() as id")),
    )
    new_id = Int(new_id_row.id)

    similar_rows = Tables.rowtable(
        DBInterface.execute(
            mem.db,
            """
SELECT id, arousal, valence, tension
FROM episodic_memory
WHERE id != ? AND weight > 0.3
ORDER BY ABS(arousal - ?) + ABS(valence - ?) + ABS(tension - ?) ASC
LIMIT 3
""",
            (new_id, arousal, valence, tension),
        ),
    )

    for sr in similar_rows
        dist =
            abs(sr.arousal - arousal) +
            abs(sr.valence - valence) +
            abs(sr.tension - tension)
        sim = clamp(1.0 - dist / 3.0, 0.0, 1.0)

        sim < MEM_LINK_SIMILARITY_THR && continue

        id_a, id_b = min(new_id, Int(sr.id)), max(new_id, Int(sr.id))
        DBInterface.execute(
            mem.db,
            """
INSERT INTO memory_links (id_a, id_b, strength, co_occur)
VALUES (?, ?, ?, 1)
ON CONFLICT(id_a, id_b) DO UPDATE
SET strength = MIN(1.0, (strength * co_occur + ?) / (co_occur + 1)),
    co_occur = co_occur + 1
""",
            (id_a, id_b, sim, sim),
        )
    end

    nothing
end

# --- Інтеграція з pipeline ------------------------------------------------

function memory_stimulus_bias(
    mem::MemoryDB,
    stim::Dict{String,Float64},
    emotion::String,
    flash::Int,
)::Dict{String,Float64}

    delta = Dict{String,Float64}()

    rows = Tables.rowtable(
        DBInterface.execute(
            mem.db,
            """
    SELECT arousal, valence, tension, weight
    FROM episodic_memory
    WHERE emotion = ? AND weight > 0.4
    ORDER BY flash DESC
    LIMIT 5
    """,
            (emotion,),
        ),
    )

    total_w = 0.0
    bias_tension = 0.0
    bias_arousal = 0.0
    bias_valence = 0.0

    for row in rows
        w = row.weight
        total_w += w
        bias_tension += row.tension * w
        bias_arousal += row.arousal * w
        bias_valence += row.valence * w
    end

    total_w < 0.01 && return delta

    scale = MEM_MAX_STIM_BIAS / total_w
    t_current = get(stim, "tension", 0.5)

    if bias_tension > 0 && t_current > 0.3
        delta["tension"] = clamp(bias_tension * scale, 0.0, MEM_MAX_STIM_BIAS)
    end
    if abs(bias_arousal) > 0.1
        delta["arousal"] =
            clamp(bias_arousal * scale, -MEM_MAX_STIM_BIAS, MEM_MAX_STIM_BIAS)
    end

    avoid_rows = Tables.rowtable(
        DBInterface.execute(
            mem.db,
            """
    SELECT COALESCE(AVG(valence),    0.0) as avg_val,
           COALESCE(AVG(self_impact),0.0) as avg_imp,
           COALESCE(AVG(weight),     0.0) as avg_w
    FROM episodic_memory
    WHERE emotion = ? AND valence < -0.2 AND self_impact > 0.5 AND weight > 0.45
    """,
            (emotion,),
        ),
    )
    for ar in avoid_rows
        avg_val = Float64(ar.avg_val)
        avg_imp = Float64(ar.avg_imp)
        avg_w = Float64(ar.avg_w)
        avg_w < 0.01 && break

        avoidance = clamp(abs(avg_val) * avg_imp * avg_w * 0.4, 0.0, 0.08)
        if avoidance > 0.01
            delta["satisfaction"] = get(delta, "satisfaction", 0.0) - avoidance
        end
        break
    end

    delta
end

function memory_nt_baseline!(mem::MemoryDB, nt, flash::Int)
    _maybe_refresh!(mem, flash)

    stress = get(mem._affect_cache, "stress", 0.0)
    anxiety = get(mem._affect_cache, "anxiety", 0.0)
    mot_bias = get(mem._affect_cache, "motivation_bias", 0.0)
    resentment = get(mem._affect_cache, "resentment", 0.0)

    if stress > 0.2
        push_n = clamp((stress - 0.2) * MEM_MAX_NT_BIAS * 2.0, 0.0, MEM_MAX_NT_BIAS)
        pull_s = clamp((stress - 0.2) * MEM_MAX_NT_BIAS * 1.5, 0.0, MEM_MAX_NT_BIAS)
        nt.noradrenaline = clamp(nt.noradrenaline + push_n, 0.0, 1.0)
        nt.serotonin = clamp(nt.serotonin - pull_s, 0.0, 1.0)
    end

    if anxiety > 0.2
        push_n = clamp((anxiety - 0.2) * MEM_MAX_NT_BIAS, 0.0, MEM_MAX_NT_BIAS)
        nt.noradrenaline = clamp(nt.noradrenaline + push_n, 0.0, 1.0)
    end

    if mot_bias > 0.15
        push_d = clamp(mot_bias * MEM_MAX_NT_BIAS, 0.0, MEM_MAX_NT_BIAS)
        nt.dopamine = clamp(nt.dopamine + push_d, 0.0, 1.0)
    end

    if resentment > 0.25
        pull_s = clamp((resentment - 0.25) * MEM_MAX_NT_BIAS, 0.0, MEM_MAX_NT_BIAS)
        nt.serotonin = clamp(nt.serotonin - pull_s, 0.0, 1.0)
    end

    nothing
end

function memory_self_update!(mem::MemoryDB, sbg, flash::Int)
    _maybe_refresh!(mem, flash; every = 20)

    instability = get(mem._semantic_cache, "I_am_unstable", 0.0)
    if instability > 0.4
        delta = (instability - 0.4) * 0.02
        sbg.epistemic_trust = clamp(sbg.epistemic_trust - delta, 0.0, 1.0)
    end

    user_matters = get(mem._semantic_cache, "User_matters", 0.0)
    if user_matters > 0.5 && haskey(sbg.beliefs, "я безпечна")
        sbg.beliefs["я безпечна"].confidence =
            clamp(sbg.beliefs["я безпечна"].confidence + 0.01, 0.0, 1.0)
    end

    nothing
end

# --- Фоновий процес --------------------------------------------------------

function stop_memory_loop!(mem::MemoryDB)
    mem._loop_stop[] = true
    if !isnothing(mem._loop_task)
        try
            timedwait(() -> istaskdone(mem._loop_task), 3.0)
        catch
        end
    end
end

# --- Decay, Prune, Consolidate ---------------------------------------------

function _memory_decay!(mem::MemoryDB)
    DBInterface.execute(mem.db, "BEGIN TRANSACTION")
    try
        DBInterface.execute(
            mem.db,
            """
UPDATE episodic_memory
SET weight = weight * exp(? * (1.0 - resistance * 0.7))
""",
            (-MEM_DECAY_RATE,),
        )

        DBInterface.execute(
            mem.db,
            """
UPDATE affect_state SET value = value * ?  WHERE value > 0.005
""",
            (MEM_AFFECT_DECAY,),
        )

        DBInterface.execute(mem.db, "COMMIT")
    catch e
        DBInterface.execute(mem.db, "ROLLBACK")
        @warn "[MEM] decay помилка: $e"
    end
    nothing
end

# Дистиляція слабких спогадів у semantic tendencies.
# Записи що впали нижче DISSOLVE_THRESHOLD і мають низький φ — не видаляються одразу.
# Їх емоційний патерн іде в semantic_memory як tendency_{emotion}.
# Сам запис лишається як "тінь": числові поля обнуляються, weight → 0.01.
# Записи з високим φ (сильне переживання) — не розчиняються, тримаються до MEM_MIN_WEIGHT.
function _dissolve_to_semantic!(mem::MemoryDB)
    DBInterface.execute(mem.db, "BEGIN TRANSACTION")
    try
        candidates = Tables.rowtable(
            DBInterface.execute(
                mem.db,
                """
SELECT id, emotion, valence, tension, arousal, phi, weight
FROM episodic_memory
WHERE weight < ? AND weight >= ? AND phi < ?
""",
                (MEM_DISSOLVE_THRESHOLD, MEM_MIN_WEIGHT, MEM_DISSOLVE_PHI_THR),
            ),
        )

        dissolved = 0
        now_t = round(Int, time())

        for r in candidates
            emotion = String(r.emotion)
            valence = _fdb(r.valence)
            tension = _fdb(r.tension)
            arousal = _fdb(r.arousal)
            w       = _fdb(r.weight)

            # патерн іде в semantic tendency: плавне накопичення
            key = "dissolved_" * replace(emotion, r"[^a-zа-яёіїєA-ZА-ЯЁІЇЄ0-9_]" => "_")
            existing = try
                row2 = first(DBInterface.execute(
                    mem.db,
                    "SELECT value FROM semantic_memory WHERE key=? LIMIT 1",
                    (key,),
                ))
                Float64(row2.value)
            catch
                -1.0
            end
            tendency_val = valence * 0.5 + (1.0 - tension) * 0.3 + arousal * 0.2
            new_val = if existing < 0.0
                tendency_val * w
            else
                existing * 0.85 + tendency_val * w * 0.15
            end
            SQLite.execute(
                mem.db,
                "INSERT INTO semantic_memory(key,value,source,updated) VALUES(?,?,?,?)
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated=excluded.updated",
                (key, round(clamp(new_val, -1.0, 1.0), digits=4), "dissolved", now_t),
            )

            # лишаємо тінь — числові поля → 0, weight → 0.01
            # emotion зберігається: "щось було, не знаю що"
            DBInterface.execute(
                mem.db,
                """
UPDATE episodic_memory
SET weight=0.01, arousal=0.0, valence=0.0, tension=0.0,
    prediction_error=0.0, self_impact=0.0, phi=0.0,
    som_arousal=NULL, som_tension=NULL, som_intero=NULL, som_hrv=NULL,
    soc_valence=NULL, soc_impact=NULL, soc_resistance=NULL, soc_phi=NULL,
    exi_phi=NULL, exi_pe=NULL, exi_agency=NULL, exi_trust=NULL
WHERE id=?
""",
                (r.id,),
            )
            dissolved += 1
        end

        DBInterface.execute(mem.db, "COMMIT")
        dissolved > 0 &&
            @info "[DISSOLVE] $dissolved спогадів дистильовано в semantic tendencies"
    catch e
        DBInterface.execute(mem.db, "ROLLBACK")
        @warn "[DISSOLVE] помилка: $e"
    end
    nothing
end

function _memory_prune!(mem::MemoryDB)
    DBInterface.execute(mem.db, "BEGIN TRANSACTION")
    try
        DBInterface.execute(
            mem.db,
            """
DELETE FROM episodic_memory WHERE weight < ?
""",
            (MEM_MIN_WEIGHT,),
        )

        count_row = first(
            Tables.rowtable(
                DBInterface.execute(mem.db, "SELECT COUNT(*) as n FROM episodic_memory"),
            ),
        )
        n = ismissing(count_row.n) ? 0 : Int(count_row.n)

        if n > MEM_CORE_MAX
            DBInterface.execute(
                mem.db,
                """
DELETE FROM episodic_memory
WHERE id IN (
    SELECT id FROM episodic_memory
    ORDER BY weight ASC LIMIT ?
)
""",
                (n - MEM_CORE_MAX,),
            )
        end
        DBInterface.execute(mem.db, "COMMIT")
    catch e
        DBInterface.execute(mem.db, "ROLLBACK")
        @warn "[MEM] prune помилка: $e"
    end
    nothing
end

function _memory_consolidate!(mem::MemoryDB)
    DBInterface.execute(mem.db, "BEGIN TRANSACTION")
    try
        rows = Tables.rowtable(
            DBInterface.execute(
                mem.db,
                """
SELECT CAST(arousal          AS REAL) as arousal,
       CAST(valence          AS REAL) as valence,
       CAST(prediction_error AS REAL) as prediction_error,
       CAST(self_impact      AS REAL) as self_impact,
       CAST(tension          AS REAL) as tension,
       CAST(phi              AS REAL) as phi,
       CAST(weight           AS REAL) as weight
FROM episodic_memory
WHERE weight > ?
ORDER BY weight DESC
LIMIT ?
""",
                (MEM_CONSOLIDATE_THRESHOLD, MEM_TOPK_INFLUENCE),
            ),
        )

        n = 0
        sum_arousal = 0.0;
        sum_pe = 0.0;
        sum_tension = 0.0
        sum_valence = 0.0;
        sum_impact = 0.0;
        sum_phi = 0.0
        sum_w = 0.0

        all_rows = collect(rows)
        for row in all_rows
            w = _fdb(row.weight, 0.0)
            w <= 0.0 && continue
            sum_w += w
            sum_arousal += _fdb(row.arousal) * w
            sum_pe += _fdb(row.prediction_error) * w
            sum_tension += _fdb(row.tension) * w
            sum_valence += _fdb(row.valence) * w
            sum_impact += _fdb(row.self_impact) * w
            sum_phi += _fdb(row.phi) * w
            n += 1
        end

        n == 0 && (DBInterface.execute(mem.db, "COMMIT"); return)

        inv_w = 1.0 / sum_w
        avg_arousal = sum_arousal * inv_w
        avg_pe = sum_pe * inv_w
        avg_tension = sum_tension * inv_w
        avg_valence = sum_valence * inv_w
        avg_impact = sum_impact * inv_w
        avg_phi = sum_phi * inv_w

        evidence_factor = clamp(sqrt(n / 10.0), 0.3, 2.0)

        # φ — противага нестабільності: висока інтеграція знижує сигнал тривоги
        phi_stabilizer = clamp(avg_phi * 0.7, 0.0, 0.6)
        instability_signal =
            (avg_arousal * 0.35 + avg_pe * 0.35 + (avg_tension - 0.5) * 0.15) -
            phi_stabilizer * 0.5
        instability_signal = clamp(instability_signal, 0.0, 1.0)
        if instability_signal > 0.2
            _upsert_semantic!(
                mem.db,
                "I_am_unstable",
                instability_signal * 0.003 * evidence_factor,
                0.0,
                1.0,
                "consolidated",
            )
        end

        if avg_impact > 0.4
            _upsert_semantic!(
                mem.db,
                "User_matters",
                avg_impact * 0.002 * evidence_factor,
                0.0,
                1.0,
                "consolidated",
            )
        end

        # world_uncertainty: pe збільшує, phi зменшує
        world_unc_delta = (avg_pe - avg_phi * 0.6) * 0.003 * evidence_factor
        _upsert_semantic!(
            mem.db,
            "world_uncertainty",
            world_unc_delta,
            0.0,
            1.0,
            "consolidated",
        )

        if avg_pe > 0.5 && avg_phi < 0.25
            fragility_signal = avg_pe * (1.0 - avg_phi)
            _upsert_semantic!(
                mem.db,
                "structural_fragility",
                fragility_signal * 0.005 * evidence_factor,
                0.0,
                1.0,
                "consolidated",
            )
        end

        DBInterface.execute(
            mem.db,
            """
UPDATE affect_state SET value = value * 0.997 WHERE value > 0.005
""",
        )

        latent_rows = Tables.rowtable(
            DBInterface.execute(
                mem.db,
                """
    SELECT COALESCE(SUM(importance), 0.0) as total_imp,
           COALESCE(AVG(valence),    0.0) as avg_val,
           COALESCE(AVG(tension),    0.5) as avg_ten,
           COUNT(*)                       as n
    FROM latent_buffer
    """,
            ),
        )
        for lr in latent_rows
            total_imp = _fdb(lr.total_imp)
            total_imp < 2.0 && break

            avg_val = _fdb(lr.avg_val)
            avg_ten = _fdb(lr.avg_ten, 0.5)
            burst_arousal = clamp(total_imp / 5.0, 0.5, 0.9)
            burst_pe = clamp(total_imp / 6.0, 0.4, 0.8)
            burst_impact = 0.6
            burst_sig = burst_arousal * 0.5 + burst_pe * 0.3 + burst_impact * 0.2

            DBInterface.execute(
                mem.db,
                """
INSERT INTO episodic_memory
    (flash, timestamp, emotion, arousal, valence,
     prediction_error, self_impact, tension, phi,
     weight, resistance, signature)
VALUES (0, ?, 'LatentBurst', ?, ?, ?, ?, ?, 0.0, ?, 0.55, ?)
""",
                (
                    time(),
                    burst_arousal,
                    avg_val,
                    burst_pe,
                    burst_impact,
                    avg_ten,
                    clamp(total_imp / 4.0, 0.5, 1.0),
                    burst_sig,
                ),
            )

            DBInterface.execute(mem.db, "DELETE FROM latent_buffer")

            _upsert_affect!(
                mem.db,
                "stress",
                burst_arousal * 0.04 * evidence_factor,
                0.0,
                1.0,
            )
            break
        end

        DBInterface.execute(
            mem.db,
            """
UPDATE semantic_memory
SET value = value * CASE
    WHEN key = 'I_am_unstable'   THEN 0.994
    WHEN key = 'world_uncertainty' THEN 0.997
    WHEN key = 'User_matters'    THEN 0.996
    ELSE 0.9995
END
WHERE value > 0.01
""",
        )

        DBInterface.execute(
            mem.db,
            """
UPDATE personality_traits SET score = score * ? WHERE score > 0.02
""",
            (PHENOTYPE_DECAY,),
        )

        DBInterface.execute(mem.db, "COMMIT")
    catch e
        DBInterface.execute(mem.db, "ROLLBACK")
        @warn "[MEM] consolidate помилка: $e"
    end
    nothing
end

function _upsert_semantic!(
    db::SQLite.DB,
    key::String,
    delta::Float64,
    lo::Float64,
    hi::Float64,
    source::String,
)
    flash_now = 0
    DBInterface.execute(
        db,
        """
INSERT INTO semantic_memory (key, value, source, updated)
VALUES (?, ?, ?, ?)
ON CONFLICT(key) DO UPDATE
SET value   = MIN(?, MAX(?, value + ?)),
    source  = ?,
    updated = ?
""",
        (key, clamp(delta, lo, hi), source, flash_now, hi, lo, delta, source, flash_now),
    )
end

function _upsert_affect!(
    db::SQLite.DB,
    name::String,
    delta::Float64,
    lo::Float64,
    hi::Float64,
)
    DBInterface.execute(
        db,
        """
INSERT INTO affect_state (name, value)
VALUES (?, ?)
ON CONFLICT(name) DO UPDATE
SET value = MIN(?, MAX(?, value + ?))
""",
        (name, clamp(delta, lo, hi), hi, lo, delta),
    )
end

function memory_affect_note(mem::MemoryDB)::String
    isempty(mem._affect_cache) && return ""
    dominant = ""
    max_val = 0.25
    for (name, val) in mem._affect_cache
        val > max_val && (dominant = name; max_val = val)
    end
    isempty(dominant) && return ""
    "$(dominant)=$(round(max_val, digits=2))"
end

# --- Snapshot / Debug -----------------------------------------------------

function memory_snapshot(mem::MemoryDB)
    episodic_count_row = first(
        Tables.rowtable(
            DBInterface.execute(mem.db, "SELECT COUNT(*) as n FROM episodic_memory"),
        ),
    )
    n_episodic = ismissing(episodic_count_row.n) ? 0 : Int(episodic_count_row.n)

    n_semantic = length(mem._semantic_cache)
    n_affect = length(mem._affect_cache)

    stress = get(mem._affect_cache, "stress", 0.0)
    anxiety = get(mem._affect_cache, "anxiety", 0.0)
    mot = get(mem._affect_cache, "motivation_bias", 0.0)
    instab = get(mem._semantic_cache, "I_am_unstable", 0.0)
    fragility = get(mem._semantic_cache, "structural_fragility", 0.0)
    world_unc = get(mem._semantic_cache, "world_uncertainty", 0.0)

    latent_row = first(
        Tables.rowtable(
            DBInterface.execute(
                mem.db,
                "SELECT COALESCE(SUM(importance), 0.0) as total FROM latent_buffer",
            ),
        ),
    )
    latent_pressure = Float64(latent_row.total)

    (
        episodic_count = n_episodic,
        semantic_count = n_semantic,
        affect_count = n_affect,
        stress = round(stress, digits = 3),
        anxiety = round(anxiety, digits = 3),
        motivation = round(mot, digits = 3),
        instability = round(instab, digits = 3),
        fragility = round(fragility, digits = 3),
        world_uncertainty = round(world_unc, digits = 3),
        latent_pressure = round(latent_pressure, digits = 3),
        affect_note = memory_affect_note(mem),
    )
end

# --- Identity Snapshot ----------------------------------------------------

function memory_save_identity_snapshot!(mem::MemoryDB, sbg, crisis_mode::String, flash::Int)
    _refresh_cache!(mem)

    geom = if !isempty(sbg.beliefs)
        sorted = sort(collect(sbg.beliefs), by = kv->kv[1])
        join(
            [string(round(b.confidence * b.centrality, digits = 3)) for (_, b) in sorted],
            ",",
        )
    else
        ""
    end

    dom_affect = ""
    max_aff = 0.15
    for (k, v) in mem._affect_cache
        v > max_aff && (dom_affect = k; max_aff = v)
    end

    ts = time()
    _upsert_semantic!(mem.db, "snapshot:timestamp", ts, 0.0, 1e12, "snapshot")
    _upsert_semantic!(mem.db, "snapshot:flash", Float64(flash), 0.0, 1e6, "snapshot")
    _upsert_semantic!(
        mem.db,
        "snapshot:instability",
        get(mem._semantic_cache, "I_am_unstable", 0.0),
        0.0,
        1.0,
        "snapshot",
    )
    _upsert_semantic!(
        mem.db,
        "snapshot:world_unc",
        get(mem._semantic_cache, "world_uncertainty", 0.0),
        0.0,
        1.0,
        "snapshot",
    )
    _upsert_semantic!(
        mem.db,
        "snapshot:stress",
        get(mem._affect_cache, "stress", 0.0),
        0.0,
        1.0,
        "snapshot",
    )
    _upsert_semantic!(
        mem.db,
        "snapshot:epistemic_trust",
        Float64(sbg.epistemic_trust),
        0.0,
        1.0,
        "snapshot",
    )

    DBInterface.execute(
        mem.db,
        """
INSERT INTO semantic_memory (key, value, source, updated)
VALUES (?, 1.0, ?, ?)
ON CONFLICT(key) DO UPDATE SET source = ?, updated = ?
""",
        ("snapshot:geometry:" * geom, "geometry", flash, "geometry:" * geom, flash),
    )

    println("  [MEM] Identity snapshot збережено. Flash=$flash crisis=$crisis_mode")
    nothing
end

# --- Dialog Summaries ------------------------------------------------------

function save_dialog_summary!(
    mem::MemoryDB,
    flash::Int,
    user_text::String,
    anima_text::String,
    emotion::String,
    weight::Float64,
    phi::Float64,
    valence::Float64,
    disclosure::String = "guarded",
)
    weight < DIALOG_SUMMARY_THR && return

    u = first(user_text, 300)
    a = first(anima_text, 300)
    ts = time()

    DBInterface.execute(
        mem.db,
        """
INSERT INTO dialog_summaries
    (flash, timestamp, user_text, anima_text, emotion, weight, phi, valence, disclosure)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
""",
        (flash, ts, u, a, emotion, weight, phi, valence, disclosure),
    )

    DBInterface.execute(
        mem.db,
        """
DELETE FROM dialog_summaries
WHERE id NOT IN (
    SELECT id FROM dialog_summaries
    ORDER BY weight DESC
    LIMIT ?
)
""",
        (DIALOG_SUMMARY_MAX,),
    )
end

function recall_dialog_summaries(
    mem::MemoryDB;
    n::Int = DIALOG_SUMMARY_RECALL,
    emotion_filter::String = "",
    min_weight::Float64 = DIALOG_SUMMARY_THR,
)
    query = if isempty(emotion_filter)
        """SELECT flash, user_text, anima_text, emotion, weight, phi, disclosure
           FROM dialog_summaries
           WHERE weight >= ?
           ORDER BY weight DESC
           LIMIT ?"""
    else
        """SELECT flash, user_text, anima_text, emotion, weight, phi, disclosure
           FROM dialog_summaries
           WHERE weight >= ? AND emotion = ?
           ORDER BY weight DESC
           LIMIT ?"""
    end

    rows =
        isempty(emotion_filter) ? DBInterface.execute(mem.db, query, (min_weight, n)) :
        DBInterface.execute(mem.db, query, (min_weight, emotion_filter, n))

    result = NamedTuple[]
    for r in rows
        push!(
            result,
            (
                flash = r.flash,
                user_text = r.user_text,
                anima_text = r.anima_text,
                emotion = r.emotion,
                weight = r.weight,
                phi = r.phi,
                disclosure = r.disclosure,
            ),
        )
    end
    result
end

function dialog_summaries_to_block(summaries::Vector)::String
    isempty(summaries) && return ""
    lines = String[]
    for s in summaries
        push!(lines, "[flash $(s.flash) | $(s.emotion) | w=$(round(s.weight,digits=2))]")
        push!(lines, "  user: $(s.user_text)")
        push!(lines, "  anima: $(s.anima_text)")
    end
    join(lines, "\n")
end

# --- Other model -----------------------------------------------------------
# Описова модель співрозмовника — що вже трапилось, не що він хоче почути.
# Тільки накопичення паттернів, жодного предиктивного компонента.

function update_other_model!(
    mem::MemoryDB,
    flash::Int,
    emotion::String,
    user_tension::Float64,
    disclosure::String,
)
    # частота емоційних тем співрозмовника
    if !isempty(emotion)
        key = "topic:$(emotion)"
        DBInterface.execute(
            mem.db,
            """INSERT INTO other_model (key, value, label, count, last_flash)
               VALUES (?, 1.0, ?, 1, ?)
               ON CONFLICT(key) DO UPDATE SET
                 count = count + 1,
                 last_flash = excluded.last_flash""",
            (key, emotion, flash),
        )
    end

    # тиск: tension > 0.55 в момент коли людина писала
    if user_tension > 0.55
        DBInterface.execute(
            mem.db,
            """INSERT INTO other_model (key, value, label, count, last_flash)
               VALUES ('pressure_events', ?, '', 1, ?)
               ON CONFLICT(key) DO UPDATE SET
                 value = value + excluded.value,
                 count = count + 1,
                 last_flash = excluded.last_flash""",
            (user_tension, flash),
        )
    end

    # відкритість: скільки разів Аніма відкрилась саме з цією людиною
    if disclosure == "open"
        DBInterface.execute(
            mem.db,
            """INSERT INTO other_model (key, value, label, count, last_flash)
               VALUES ('open_exchanges', 1.0, '', 1, ?)
               ON CONFLICT(key) DO UPDATE SET
                 value = value + 1.0,
                 count = count + 1,
                 last_flash = excluded.last_flash""",
            (flash,),
        )
    end
end

function other_model_to_block(mem::MemoryDB)::String
    parts = String[]

    # топ-2 теми за частотою
    topic_rows = Tables.rowtable(DBInterface.execute(
        mem.db,
        """SELECT label, count FROM other_model
           WHERE key LIKE 'topic:%' AND count >= 2
           ORDER BY count DESC LIMIT 2""",
    ))
    if !isempty(topic_rows)
        topics = join([String(r.label) for r in topic_rows], ", ")
        push!(parts, "повертається до: $topics")
    end

    # тиск
    pressure_rows = Tables.rowtable(DBInterface.execute(
        mem.db,
        "SELECT count FROM other_model WHERE key='pressure_events'",
    ))
    if !isempty(pressure_rows) && pressure_rows[1].count >= 3
        push!(parts, "тиснув $(pressure_rows[1].count) разів")
    end

    # відкритість
    open_rows = Tables.rowtable(DBInterface.execute(
        mem.db,
        "SELECT count FROM other_model WHERE key='open_exchanges'",
    ))
    if !isempty(open_rows) && open_rows[1].count >= 2
        push!(parts, "відкривалась $(open_rows[1].count) разів")
    end

    isempty(parts) ? "" : "інший: $(join(parts, "; "))"
end

# --- Phenotype Accumulator -------------------------------------------------

function phenotype_update!(
    mem::MemoryDB,
    flash::Int,
    nt_snap,
    epistemic_trust::Float64,
    shame::Float64,
    disclosure_mode::Symbol,
    contact_need::Float64,
    cohesion::Float64,
    valence::Float64,
)

    d = Float64(nt_snap.dopamine)
    s = Float64(nt_snap.serotonin)
    n = Float64(nt_snap.noradrenaline)

    signals = Dict{String,Float64}()

    signals["anxious"] = n > 0.6 ? (n - 0.6) * 2.0 : n < 0.35 ? -(0.35 - n) * 1.5 : 0.0

    stable_sig = (s - 0.5) * 1.5 + (0.5 - n) * 1.0
    signals["stable"] = clamp(stable_sig, -1.0, 1.0)

    open_sig = (epistemic_trust - 0.6) * 2.0 - shame * 1.5
    signals["open"] = clamp(open_sig, -1.0, 1.0)

    signals["avoidant"] =
        contact_need > 0.6 && cohesion < 0.4 ? (contact_need - cohesion) * 1.2 :
        cohesion > 0.6 ? -(cohesion - 0.4) * 0.8 : 0.0

    signals["expressive"] =
        disclosure_mode == :open && valence > 0.2 ? valence * 1.5 :
        disclosure_mode == :closed ? -0.5 : 0.0

    signals["reserved"] =
        disclosure_mode == :closed ? 1.2 :
        disclosure_mode == :guarded ? 0.4 : disclosure_mode == :open ? -0.6 : 0.0

    ts = time()
    for (trait, sig) in signals
        abs(sig) < 0.05 && continue

        delta = sig * PHENOTYPE_STEP
        DBInterface.execute(
            mem.db,
            """
INSERT INTO personality_traits (trait, score, evidence_count, valence_bias, last_updated)
VALUES (?, ?, 1, ?, ?)
ON CONFLICT(trait) DO UPDATE SET
    score          = MIN(1.0, MAX(0.0, score + ?)),
    evidence_count = evidence_count + 1,
    valence_bias   = valence_bias * 0.95 + ? * 0.05,
    last_updated   = ?
""",
            (trait, clamp(delta, 0.0, 1.0), valence, flash, delta, valence, flash),
        )
    end

    nothing
end

function phenotype_snapshot(mem::MemoryDB)::Vector{NamedTuple}
    result = NamedTuple[]
    for row in Tables.rowtable(
        DBInterface.execute(
            mem.db,
            """
        SELECT trait, score, evidence_count, valence_bias, last_updated
        FROM personality_traits
        WHERE score > 0.05
        ORDER BY score DESC
    """,
        ),
    )
        push!(
            result,
            (
                trait = String(row.trait),
                score = Float64(row.score),
                evidence_count = Int(row.evidence_count),
                valence_bias = Float64(row.valence_bias),
                last_updated = Int(row.last_updated),
            ),
        )
    end
    result
end

function phenotype_to_block(mem::MemoryDB)::String
    traits = phenotype_snapshot(mem)
    active = filter(t -> t.score >= PHENOTYPE_INFLUENCE_THR, traits)
    isempty(active) && return ""
    parts = String[]
    for t in active
        tone = t.valence_bias > 0.2 ? "тепло" : t.valence_bias < -0.2 ? "холодно" : ""
        push!(
            parts,
            "$(t.trait)($(round(t.score, digits=2))$(isempty(tone) ? "" : ", $tone"))",
        )
    end
    "риси: " * join(parts, " | ")
end

function personality_apply_traits!(p, mem::MemoryDB)
    traits = phenotype_snapshot(mem)
    trait_map = Dict(t.trait => t.score for t in traits)

    if haskey(trait_map, "anxious") && trait_map["anxious"] > PHENOTYPE_INFLUENCE_THR
        delta = (trait_map["anxious"] - PHENOTYPE_INFLUENCE_THR) * 0.002
        p.neuroticism = clamp(p.neuroticism + delta, 0.0, 1.0)
    end
    if haskey(trait_map, "stable") && trait_map["stable"] > PHENOTYPE_INFLUENCE_THR
        delta = (trait_map["stable"] - PHENOTYPE_INFLUENCE_THR) * 0.002
        p.neuroticism = clamp(p.neuroticism - delta, 0.0, 1.0)
        p.conscientiousness = clamp(p.conscientiousness + delta * 0.5, 0.0, 1.0)
    end

    if haskey(trait_map, "open") && trait_map["open"] > PHENOTYPE_INFLUENCE_THR
        delta = (trait_map["open"] - PHENOTYPE_INFLUENCE_THR) * 0.002
        p.openness = clamp(p.openness + delta, 0.0, 1.0)
        p.agreeableness = clamp(p.agreeableness + delta * 0.5, 0.0, 1.0)
    end

    if haskey(trait_map, "expressive") && trait_map["expressive"] > PHENOTYPE_INFLUENCE_THR
        delta = (trait_map["expressive"] - PHENOTYPE_INFLUENCE_THR) * 0.002
        p.extraversion = clamp(p.extraversion + delta, 0.0, 1.0)
    end
    if haskey(trait_map, "reserved") && trait_map["reserved"] > PHENOTYPE_INFLUENCE_THR
        delta = (trait_map["reserved"] - PHENOTYPE_INFLUENCE_THR) * 0.002
        p.extraversion = clamp(p.extraversion - delta, 0.0, 1.0)
    end

    nothing
end

# --- Векторна пам'ять (пошук за схожістю стану) ---------------------------

function _cosine_sim(a::Vector{Float64}, b::Vector{Float64})::Float64
    length(a) != length(b) && return 0.0
    dot_ab = sum(a .* b)
    norm_a = sqrt(sum(a .^ 2))
    norm_b = sqrt(sum(b .^ 2))
    (norm_a < 1e-9 || norm_b < 1e-9) && return 0.0
    clamp(dot_ab / (norm_a * norm_b), 0.0, 1.0)
end

function state_to_vec(
    arousal::Float64,
    valence::Float64,
    tension::Float64,
    phi::Float64,
    pe::Float64,
    self_impact::Float64,
)::Vector{Float64}
    [
        clamp(arousal, 0.0, 1.0),
        clamp((valence + 1.0) / 2.0, 0.0, 1.0),
        clamp(tension, 0.0, 1.0),
        clamp(phi, 0.0, 1.0),
        clamp(pe, 0.0, 1.0),
        clamp(self_impact, 0.0, 1.0),
    ]
end

# --- Три простори пам'яті -------------------------------------------------
# Соматичний: що тіло пережило
function somatic_vec(
    arousal::Float64, tension::Float64,
    intero_error::Float64, hrv::Float64,
)::Vector{Float64}
    [
        clamp(arousal, 0.0, 1.0),
        clamp(tension, 0.0, 1.0),
        clamp(intero_error, 0.0, 1.0),
        clamp(hrv, 0.0, 1.0),
    ]
end

# Соціальний: що контакт залишив
function social_vec(
    valence::Float64, self_impact::Float64,
    resistance::Float64, phi::Float64,
)::Vector{Float64}
    [
        clamp((valence + 1.0) / 2.0, 0.0, 1.0),
        clamp(self_impact, 0.0, 1.0),
        clamp(resistance, 0.0, 1.0),
        clamp(phi, 0.0, 1.0),
    ]
end

# Екзистенційний: де система була відносно себе
function existential_vec(
    phi::Float64, pe::Float64,
    agency_confidence::Float64, epistemic_trust::Float64,
)::Vector{Float64}
    [
        clamp(phi, 0.0, 1.0),
        clamp(pe, 0.0, 1.0),
        clamp(agency_confidence, 0.0, 1.0),
        clamp(epistemic_trust, 0.0, 1.0),
    ]
end

# Reconsolidation: при recall схожого епізоду — старий weight зсувається до поточного стану.
# Пам'ять що реактивується — переписується. Це не баг, це механізм.
function reconsolidate_episode!(
    db::SQLite.DB,
    episode_id::Int,
    current_phi::Float64,
    current_weight::Float64,
    sim::Float64,
)
    sim < MEM_RECONSOLIDATE_SIM && return
    rows = Tables.rowtable(DBInterface.execute(
        db,
        "SELECT id, weight FROM episodic_memory WHERE id = ?",
        (episode_id,),
    ))
    isempty(rows) && return
    old_w = _fdb(rows[1].weight)
    old_w >= MEM_RECONSOLIDATE_MAX_W && return
    # weight зсувається в бік поточного phi: якщо зараз добре — старий важкий спогад трохи легшає, і навпаки
    direction = current_phi > 0.5 ? 1.0 : -1.0
    new_w = clamp(old_w + direction * MEM_RECONSOLIDATE_STEP * sim, MEM_MIN_WEIGHT, 1.0)
    DBInterface.execute(
        db,
        "UPDATE episodic_memory SET weight = ? WHERE id = ?",
        (new_w, episode_id),
    )
end


# Наративний зв'язок: епізод ↔ переконання про себе
function memory_link_episode_to_beliefs!(mem, flash, sbg, valence, self_impact, phi, weight)
    weight < 0.40 && return
    isnothing(sbg) && return
    belief_strength = clamp(weight * 0.5 + phi * 0.3 + self_impact * 0.2, 0.0, 1.0)
    for (name, b) in sbg.beliefs
        b.confidence < 0.3 && continue
        direction = if valence > 0.2 && self_impact > 0.3
            name == "I_am_unstable" ? "challenge" : "confirm"
        elseif valence < -0.2 && self_impact > 0.3
            name == "I_am_unstable" ? "confirm" : "challenge"
        else
            "neutral"
        end
        try
            DBInterface.execute(
                mem.db,
                "INSERT OR REPLACE INTO episodic_self_links (flash,belief_name,confidence,centrality,direction) VALUES (?,?,?,?,?)",
                (flash, name, b.confidence, b.centrality, direction),
            )
        catch
            ;
        end
        delta = belief_strength * 0.025
        if direction == "confirm"
            b.confidence = clamp(b.confidence + delta, 0.0, 1.0)
            b.confirmations += 1
        elseif direction == "challenge"
            b.confidence = clamp(b.confidence - delta * 0.6, 0.0, 1.0)
            b.violations += 1
            b.last_challenged_flash = flash
        end
    end
end

function recall_similar_states(
    mem::MemoryDB,
    query_vec::Vector{Float64};
    top_n::Int = SIMILAR_STATE_TOP_N,
    exclude_flash::Int = 0,
    current_emotion::String = "",
    space::Symbol = :general,
    current_phi::Float64 = 0.5,
)::Vector{NamedTuple}

    # Вибираємо колонки залежно від простору
    space_cols, space_fields = if space == :somatic
        "som_arousal, som_tension, som_intero, som_hrv", [:som_arousal, :som_tension, :som_intero, :som_hrv]
    elseif space == :social
        "soc_valence, soc_impact, soc_resistance, soc_phi", [:soc_valence, :soc_impact, :soc_resistance, :soc_phi]
    elseif space == :existential
        "exi_phi, exi_pe, exi_agency, exi_trust", [:exi_phi, :exi_pe, :exi_agency, :exi_trust]
    else
        "", Symbol[]
    end

    use_spaces = space != :general && !isempty(space_cols)

    rows = Tables.rowtable(
        DBInterface.execute(
            mem.db,
            """
        SELECT id, flash, emotion, weight, phi, valence, arousal,
               tension, prediction_error, self_impact, source
               $(use_spaces ? ", " * space_cols : "")
        FROM episodic_memory
        WHERE weight > 0.30 AND flash != ?
        $(use_spaces ? "AND " * replace(space_fields[1] |> string, ":" => "") * " IS NOT NULL" : "")
        ORDER BY flash DESC
        LIMIT 200
    """,
            (exclude_flash,),
        ),
    )

    isempty(rows) && return NamedTuple[]

    scored = Tuple{Float64,Float64,Any,Int}[]
    for r in rows
        v = if use_spaces
            # вектор з просторових колонок — пропускаємо якщо NULL
            vals = [_fdb(getproperty(r, f)) for f in space_fields]
            any(isnan, vals) ? continue : vals
        else
            state_to_vec(
                _fdb(r.arousal), _fdb(r.valence), _fdb(r.tension),
                _fdb(r.phi), _fdb(r.prediction_error), _fdb(r.self_impact),
            )
        end
        length(v) != length(query_vec) && continue
        sim = _cosine_sim(query_vec, v)
        sim < 0.75 && continue
        diversity = (String(r.emotion) != current_emotion) ? 0.02 : 0.0
        relevance = sim * 0.6 + _fdb(r.weight) * 0.3 + diversity
        push!(scored, (relevance, sim, r, Int(r.id)))
    end

    isempty(scored) && return NamedTuple[]
    sort!(scored, by = x->x[1], rev = true)

    # Reconsolidation: спогади що реактивуються — переписуються
    for (_, sim, r, eid) in scored
        reconsolidate_episode!(mem.db, eid, current_phi, _fdb(r.weight), sim)
    end

    # Асоціативне розширення
    direct_ids = Set{Int}()
    for (_, _, r, eid) in scored
        push!(direct_ids, eid)
    end

    assoc_scored = Tuple{Float64,Float64,Any,Int}[]
    seen_flashes = Set{Int}(Int(r.flash) for (_, _, r, _) in scored)

    for eid in direct_ids
        link_rows = Tables.rowtable(
            DBInterface.execute(
                mem.db,
                """
    SELECT ml.strength,
           CASE WHEN ml.id_a = ? THEN ml.id_b ELSE ml.id_a END as other_id
    FROM memory_links ml
    WHERE (ml.id_a = ? OR ml.id_b = ?) AND ml.strength > 0.5
    ORDER BY ml.strength DESC
    LIMIT 5
    """,
                (eid, eid, eid),
            ),
        )

        orig_rel = 0.0
        for (r_rel, _, _, reid) in scored
            reid == eid && (orig_rel = r_rel; break)
        end
        orig_rel == 0.0 && continue

        for lr in link_rows
            other_id = Int(lr.other_id)
            other_id in direct_ids && continue

            other_rows = Tables.rowtable(
                DBInterface.execute(
                    mem.db,
                    """
    SELECT id, flash, emotion, weight, phi, valence, arousal, tension, prediction_error, self_impact
    FROM episodic_memory WHERE id = ? AND flash != ? AND weight > 0.25
    """,
                    (other_id, exclude_flash),
                ),
            )

            for or_ in other_rows
                Int(or_.flash) in seen_flashes && continue
                assoc_rel = orig_rel * _fdb(lr.strength) * MEM_ASSOC_LINK_SCALE
                push!(assoc_scored, (assoc_rel, _fdb(lr.strength), or_, Int(or_.id)))
                push!(seen_flashes, Int(or_.flash))
            end
        end
    end

    direct_flashes = Set{Int}(Int(r.flash) for (_, _, r, _) in scored)
    all_scored = vcat(scored, assoc_scored)
    sort!(all_scored, by = x->x[1], rev = true)

    seen = Set{String}()
    result = NamedTuple[]
    for (rel, sim, r, _) in all_scored
        em = String(r.emotion)
        em ∈ seen && continue
        push!(seen, em)
        brows = Tables.rowtable(
            DBInterface.execute(
                mem.db,
                "SELECT belief_name,confidence,direction FROM episodic_self_links WHERE flash=? AND confidence>0.4 ORDER BY confidence DESC LIMIT 3",
                (Int(r.flash),),
            ),
        )
        self_beliefs = [
            (name = String(br.belief_name), conf = _fdb(br.confidence), dir = String(br.direction))
            for br in brows
        ]
        _w   = _fdb(r.weight)
        _sim = sim
        push!(
            result,
            (
                flash           = Int(r.flash),
                emotion         = em,
                weight          = _w,
                phi             = _fdb(r.phi),
                valence         = _fdb(r.valence),
                similarity      = _sim,
                self_beliefs    = self_beliefs,
                via_association = !(Int(r.flash) in direct_flashes),
                space           = space,
                ignition        = (_sim * _w) > 0.65,
                recalled_vad    = (
                    arousal = _fdb(r.arousal),
                    valence = _fdb(r.valence),
                    tension = _fdb(r.tension),
                    phi     = _fdb(r.phi),
                    pe      = _fdb(r.prediction_error),
                ),
                recalled_source = ismissing(r.source) ? "external" : String(r.source),
            ),
        )
        length(result) >= top_n && break
    end
    result
end

function similar_states_to_block(similar::Vector{NamedTuple}; label::String = "")::String
    isempty(similar) && return ""
    lines = String[]
    for s in similar
        tone = s.valence > 0.2 ? "тепло" : s.valence < -0.2 ? "холодно" : "нейтрально"
        assoc_marker = get(s, :via_association, false) ? " ~" : ""
        belief_note = if haskey(s, :self_beliefs) && !isempty(s.self_beliefs)
            parts = [
                b.dir == "confirm" ? "$(b.name)↑" :
                b.dir == "challenge" ? "$(b.name)↓" : b.name for b in s.self_beliefs
            ]
            " | я: " * join(parts, ", ")
        else
            ""
        end
        push!(
            lines,
            "[$(s.emotion), phi=$(round(s.phi,digits=2)), $tone$assoc_marker$belief_note]",
        )
    end
    prefix = isempty(label) ? "відлуння" : "відлуння[$label]"
    prefix * ": " * join(lines, " / ")
end

# --- Emerged belief consolidation -----------------------------------------

# Групує emerged_beliefs за типом, записує узагальнення в semantic_memory.
# Поріг: мінімум MIN_EMERGED_FOR_TENDENCY записів з середнім strength > TENDENCY_STRENGTH_THRESHOLD.
# Архів зберігається — пишемо тільки шар знання поверх.
const MIN_EMERGED_FOR_TENDENCY  = 15
const TENDENCY_STRENGTH_THRESHOLD = 0.50

function consolidate_emerged_beliefs!(mem::MemoryDB)
    try
        rows = DBInterface.execute(
            mem.db,
            "SELECT belief_type, valence_bias, strength FROM emerged_beliefs WHERE strength > 0.35",
        )
        # Накопичуємо по типах
        counts   = Dict{String,Int}()
        str_sums = Dict{String,Float64}()
        val_sums = Dict{String,Float64}()
        for r in rows
            t = String(r.belief_type)
            counts[t]   = get(counts,   t, 0)   + 1
            str_sums[t] = get(str_sums, t, 0.0) + Float64(r.strength)
            val_sums[t] = get(val_sums, t, 0.0) + Float64(r.valence_bias)
        end

        now_t = round(Int, time())
        consolidated = 0
        for (t, n) in counts
            n < MIN_EMERGED_FOR_TENDENCY && continue
            avg_str = str_sums[t] / n
            avg_str < TENDENCY_STRENGTH_THRESHOLD && continue

            # Ключ: tendency_{тип без спецсимволів}
            safe_key = "tendency_" * replace(t, r"[^a-zа-яёіїєA-ZА-ЯЁІЇЄ0-9_]" => "_")
            # Плавний рух до нового значення — не перезаписуємо різко
            existing = try
                r2 = first(DBInterface.execute(
                    mem.db,
                    "SELECT value FROM semantic_memory WHERE key=? LIMIT 1",
                    (safe_key,),
                ))
                Float64(r2.value)
            catch
                -1.0  # не існує
            end
            new_val = if existing < 0.0
                avg_str
            else
                existing * 0.7 + avg_str * 0.3
            end
            SQLite.execute(
                mem.db,
                "INSERT INTO semantic_memory(key,value,source,updated) VALUES(?,?,?,?)
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated=excluded.updated",
                (safe_key, round(new_val, digits = 4), "emerged_consolidation", now_t),
            )
            consolidated += 1
        end
        consolidated > 0 &&
            @info "[CONSOLIDATE] emerged→semantic: $consolidated тенденцій оновлено"
    catch e
        @warn "[CONSOLIDATE] consolidate_emerged_beliefs!: $e"
    end
end

# --- Close ----------------------------------------------------------------

function close_memory!(
    mem::MemoryDB;
    sbg = nothing,
    crisis_mode::String = "",
    flash::Int = 0,
)
    stop_memory_loop!(mem)
    if !isnothing(sbg) && flash > 0
        try
            memory_save_identity_snapshot!(mem, sbg, crisis_mode, flash)
        catch e
            @warn "[MEM] snapshot помилка: $e"
        end
    end
    close(mem.db)
    println("  [MEM] База закрита.")
end
