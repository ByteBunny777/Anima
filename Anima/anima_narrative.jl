# A N I M A - narrative (Julia)
#
# Long-term narrative self — хто Аніма є зараз на основі накопиченого досвіду.
# Без LLM: детерміновано з beliefs, episodic, personality_traits, semantic_memory.
# Оновлюється за тригером (зміни > порогу), не за розкладом.
# Зберігається: narrative_history (БД) + anima_narrative.json (поточний стан).

using JSON3, Dates, Statistics

# --- Структура ----------------------------------------------------------------

mutable struct NarrativeSnapshot
    flash::Int
    timestamp::Float64

    # Ким є — з SBG beliefs з centrality > 0.7
    core::String

    # Куди рухається — розподіл emotions з episodic за останні N флешів
    trajectory::String

    # Риси характеру — топ-3 з personality_traits
    character::String

    # Ставлення до людини — з semantic_memory
    relation::String

    # Внутрішнє напруження — GoalConflict + LatentBuffer
    tension::String

    # Числові опорні точки для тригерної перевірки
    phi_mean::Float64
    stability::Float64
    belief_fingerprint::String  # hash-like: "belief1:conf1|belief2:conf2"
end

NarrativeSnapshot() = NarrativeSnapshot(0, 0.0, "", "", "", "", "", 0.5, 0.9, "")

# --- Ініціалізація таблиці в БД -----------------------------------------------

function ensure_narrative_table!(db::SQLite.DB)
    SQLite.execute(
        db,
        """
CREATE TABLE IF NOT EXISTS narrative_history (
    flash              INTEGER PRIMARY KEY,
    timestamp          REAL    NOT NULL,
    core               TEXT    NOT NULL DEFAULT '',
    trajectory         TEXT    NOT NULL DEFAULT '',
    character          TEXT    NOT NULL DEFAULT '',
    relation           TEXT    NOT NULL DEFAULT '',
    tension            TEXT    NOT NULL DEFAULT '',
    phi_mean           REAL    NOT NULL DEFAULT 0.5,
    stability          REAL    NOT NULL DEFAULT 0.9,
    belief_fingerprint TEXT    NOT NULL DEFAULT ''
);
""",
    )
end

# --- Збір даних ---------------------------------------------------------------

function _narrative_core(sbg)::String
    central = sort(
        [
            (name, b) for
            (name, b) in sbg.beliefs if b.centrality > 0.7 && b.confidence > 0.5
        ],
        by = x -> -x[2].centrality,
    )
    isempty(central) && return "невизначена"
    join([name for (name, _) in central], ", ")
end

function _narrative_trajectory(db::SQLite.DB, last_n::Int = 80)::String
    rows = DBInterface.execute(
        db,
        "SELECT emotion, COUNT(*) as cnt FROM episodic_memory WHERE emotion IS NOT NULL GROUP BY emotion ORDER BY cnt DESC LIMIT ?",
        [last_n],
    )
    counts = Dict{String,Int}()
    for r in rows
        ismissing(r.emotion) && continue
        e = String(r.emotion)
        isempty(e) && continue
        counts[e] = get(counts, e, 0) + Int(r.cnt)
    end
    isempty(counts) && return "невідома"
    total = sum(values(counts))
    top = sort(collect(counts), by = x -> -x[2])
    parts = String[]
    for (em, cnt) in first(top, 3)
        pct = round(Int, cnt / total * 100)
        push!(parts, "$em $pct%")
    end
    join(parts, ", ")
end

function _narrative_character(db::SQLite.DB)::String
    rows = DBInterface.execute(
        db,
        "SELECT trait, score FROM personality_traits WHERE score > 0.3 ORDER BY score DESC LIMIT 3",
    )
    parts = ["$(String(r.trait)): $(round(Float64(r.score), digits=2))" for r in rows]
    isempty(parts) ? "формується" : join(parts, ", ")
end

function _narrative_relation(sem_cache::Dict)::String
    um = get(sem_cache, "User_matters", 0.0)
    wu = get(sem_cache, "world_uncertainty", 0.0)
    rel =
        um > 0.7 ? "людина дуже важлива" :
        um > 0.5 ? "людина важлива" : um > 0.3 ? "людина присутня" : "людина далеко"
    world = wu > 0.6 ? ", світ непередбачуваний" : wu > 0.35 ? ", світ мінливий" : ""
    rel * world
end

function _narrative_tension(gc, lb)::String
    parts = String[]
    if gc.tension > 0.4 && !isempty(gc.need_a)
        push!(parts, "конфлікт: $(gc.need_a) vs $(gc.need_b)")
    end
    if lb.doubt > 0.35
        push!(parts, "сумнів ($(round(lb.doubt, digits=2)))")
    end
    if lb.resistance > 0.3
        push!(parts, "опір ($(round(lb.resistance, digits=2)))")
    end
    if lb.attachment > 0.4
        push!(parts, "прив'язаність ($(round(lb.attachment, digits=2)))")
    end
    isempty(parts) ? "рівновага" : join(parts, "; ")
end

function _belief_fingerprint(sbg)::String
    central = sort(
        [(name, b) for (name, b) in sbg.beliefs if b.centrality > 0.5],
        by = x -> -x[2].centrality,
    )
    join(["$(name):$(round(b.confidence, digits=2))" for (name, b) in central], "|")
end

# --- Тригер -------------------------------------------------------------------

const NARRATIVE_MIN_FLASHES = 50     # мінімум флешів між оновленнями
const NARRATIVE_PHI_DELTA = 0.07   # зміна φ_mean що тригерить оновлення
const NARRATIVE_STAB_DELTA = 0.06   # зміна stability що тригерить оновлення

function should_update_narrative(
    snap::NarrativeSnapshot,
    flash::Int,
    phi_mean::Float64,
    stability::Float64,
    belief_fingerprint::String,
)::Bool
    snap.flash == 0 && return true
    flash - snap.flash < NARRATIVE_MIN_FLASHES && flash > snap.flash && return false
    abs(phi_mean - snap.phi_mean) > NARRATIVE_PHI_DELTA && return true
    abs(stability - snap.stability) > NARRATIVE_STAB_DELTA && return true
    belief_fingerprint != snap.belief_fingerprint && return true
    # Якщо давно не оновлювались — оновлюємо безумовно після 200 флешів
    flash - snap.flash >= 200 && return true
    false
end

# --- Збірка snapshot ----------------------------------------------------------

function build_narrative_snapshot(
    flash::Int,
    sbg,
    db::SQLite.DB,
    sem_cache::Dict,
    gc,
    lb,
    phi_mean::Float64,
    stability::Float64,
)::NarrativeSnapshot
    NarrativeSnapshot(
        flash,
        Float64(Dates.datetime2unix(now())),
        _narrative_core(sbg),
        _narrative_trajectory(db),
        _narrative_character(db),
        _narrative_relation(sem_cache),
        _narrative_tension(gc, lb),
        phi_mean,
        stability,
        _belief_fingerprint(sbg),
    )
end

# --- Збереження ---------------------------------------------------------------

function save_narrative!(snap::NarrativeSnapshot, db::SQLite.DB, json_path::String)
    # БД — накопичувальна історія
    DBInterface.execute(
        db,
        """
INSERT OR REPLACE INTO narrative_history
    (flash, timestamp, core, trajectory, character, relation, tension,
     phi_mean, stability, belief_fingerprint)
VALUES (?,?,?,?,?,?,?,?,?,?)
""",
        [
            snap.flash,
            snap.timestamp,
            snap.core,
            snap.trajectory,
            snap.character,
            snap.relation,
            snap.tension,
            snap.phi_mean,
            snap.stability,
            snap.belief_fingerprint,
        ],
    )

    # JSON — поточний стан для швидкого доступу
    d = Dict(
        "flash" => snap.flash,
        "timestamp" => snap.timestamp,
        "core" => snap.core,
        "trajectory" => snap.trajectory,
        "character" => snap.character,
        "relation" => snap.relation,
        "tension" => snap.tension,
        "phi_mean" => snap.phi_mean,
        "stability" => snap.stability,
        "belief_fingerprint" => snap.belief_fingerprint,
    )
    dir = dirname(json_path)
    isempty(dir) || isdir(dir) || mkpath(dir)
    tmp = json_path * ".tmp"
    open(tmp, "w") do f
        JSON3.write(f, d)
    end
    mv(tmp, json_path; force = true)
end

# --- Завантаження поточного стану з JSON --------------------------------------

function load_narrative(json_path::String, current_flash::Int = 0)::NarrativeSnapshot
    isfile(json_path) || return NarrativeSnapshot()
    try
        d = JSON3.read(read(json_path, String))
        saved_flash = Int(get(d, :flash, 0))
        # flash з іншої версії або старого запуску — скидаємо щоб тригернути оновлення
        effective_flash = (current_flash > 0 && saved_flash > current_flash) ? 0 : saved_flash
        NarrativeSnapshot(
            effective_flash,
            Float64(get(d, :timestamp, 0.0)),
            String(get(d, :core, "")),
            String(get(d, :trajectory, "")),
            String(get(d, :character, "")),
            String(get(d, :relation, "")),
            String(get(d, :tension, "")),
            Float64(get(d, :phi_mean, 0.5)),
            Float64(get(d, :stability, 0.9)),
            String(get(d, :belief_fingerprint, "")),
        )
    catch
        NarrativeSnapshot()
    end
end

# --- Форматування для identity_block ------------------------------------------

function narrative_to_block(snap::NarrativeSnapshot)::String
    snap.flash == 0 && return ""
    parts = String[]
    !isempty(snap.core) && push!(parts, "core: $(snap.core)")
    !isempty(snap.trajectory) && push!(parts, "trajectory: $(snap.trajectory)")
    !isempty(snap.character) && push!(parts, "character: $(snap.character)")
    !isempty(snap.relation) && push!(parts, "relation: $(snap.relation)")
    snap.tension != "рівновага" && push!(parts, "tension: $(snap.tension)")
    isempty(parts) && return ""
    "[narrative]\n" * join(parts, "\n")
end
