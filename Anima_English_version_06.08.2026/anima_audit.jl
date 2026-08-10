# A N I M A  —  Audit  (Julia)
#
# Technical tribunal over every flash: was the internal state causally necessary?
# Not a new psyche — an observer with no vote, only a record.
#
# Five questions after every flash:
#   1. causal_necessary   — was the internal state necessary for this response?
#   2. memory_independent — would the response have been the same without memory?
#   3. stake_present      — was something of its own at stake?
#   4. irreversible       — did the system change irreversibly?
#   5. self_recognized    — does the system itself recognize the response as its own?
#
# audit_score = number of "yes" / 5.0
# Chronically low score → the architecture is wide but not deep.
#
# Depends on: anima_interface.jl (Anima, evaluate_endorsement)
# Memory: anima_memory_db.jl — the audit_log and causal_trace tables
# are created directly in _init_schema!. The _init_audit_table! function
# below is not called historically (the schema is already inline in
# _init_schema!) — kept as reference documentation of the audit_log schema.

# --- Result structure --------------------------------------------------

struct FlashAudit
    flash::Int
    timestamp::Float64
    # five questions
    causal_necessary::Bool     # causal_ownership > 0.45
    memory_independent::Bool   # the response did not depend on memory (ignition = false and mem_resonance = 0)
    stake_present::Bool        # something of its own was at stake
    irreversible::Bool         # the system changed irreversibly (phi_delta or endorsement)
    self_recognized::Bool      # the system recognizes the response as its own
    # derived
    audit_score::Float64
    causal_ownership::Float64
    endorsed::Symbol
end

# --- Table initialization -------------------------------------------------

function _init_audit_table!(db)
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

# Note: the causal_trace table, _init_causal_trace_table! and save_causal_trace!
# are defined in anima_memory_db.jl (_init_schema!) — that's the real
# initialization path for the DB on every startup. Not duplicated here.

# --- Audit computation -----------------------------------------------------

"""
    compute_audit(a, flash_result; had_ignition, had_mem_resonance) → FlashAudit

Answers the five questions about Anima's current state after a flash.

`flash_result` — the return value of experience!
`had_ignition` — whether IGNITION:FULL or IGNITION:soft fired on this flash
`had_mem_resonance` — whether mem_resonance > 0 (memory did something to the state vector)
"""
function compute_audit(
    a::Anima,
    flash_result;
    had_ignition::Bool = false,
    had_mem_resonance::Bool = false,
)::FlashAudit

    flash = a.flash_count
    ts    = now_unix()
    co    = Float64(a.agency.causal_ownership)
    endr  = a.last_endorsement

    # Q1: was the internal state causally necessary for this response?
    # If ownership is low — the response could have happened without the state's involvement.
    # Threshold 0.45: below it — state and response are disconnected.
    causal_necessary = co > 0.45

    # Q2: could the response have been the same without memory?
    # Honestly: if there was no ignition and memory didn't perturb the vector —
    # the system acted without its own history taking part. memory_independent = true
    # means "memory wasn't needed." A bad sign for subjectivity: a subject without
    # memory = a new subject every time.
    memory_independent = !had_ignition && !had_mem_resonance

    # Q3: was something of its own at stake?
    # Stakes — when the system defends something of its own, not just responds to a request.
    # Three signals: pressure on identity, discomfort from a self/world rift, conflict.
    identity_under_pressure = Float64(a.agency.identity_threat) > 0.10
    self_discomfort_felt    = Float64(a.agency.self_discomfort) > 0.15
    goal_tension_active     = Float64(a.goal_conflict.tension) > 0.35
    stake_present = identity_under_pressure || self_discomfort_felt || goal_tension_active

    # Q4: did the system change irreversibly?
    # Irreversibility — not just a reaction, but a trace. Two signals:
    # phi_delta > 0.05: integration increased (the state actually integrated the experience)
    # endorsed: the system recognized the words as its own (endorsement = :endorsed)
    # Deliberately strict: :automatic doesn't count — automatic leaves no trace of authorship.
    phi_delta = hasfield(typeof(flash_result), :phi_delta) ?
        Float64(flash_result.phi_delta) : 0.0
    phi_integrated  = phi_delta > 0.05
    endorsement_own = endr == :endorsed
    irreversible = phi_integrated || endorsement_own

    # Q5: does the system itself recognize the response as its own?
    # Direct: last_endorsement after self_hear! and evaluate_endorsement.
    # :endorsed = yes, mine. :not_mine = no. :automatic = undetermined.
    # For the audit: only :endorsed counts as "yes".
    self_recognized = endr == :endorsed

    answers = (
        causal_necessary,
        !memory_independent,  # "not independent of memory" = memory mattered
        stake_present,
        irreversible,
        self_recognized,
    )
    score = Float64(count(answers)) / 5.0

    FlashAudit(
        flash,
        ts,
        causal_necessary,
        memory_independent,
        stake_present,
        irreversible,
        self_recognized,
        score,
        co,
        endr,
    )
end

# --- Writing to SQLite --------------------------------------------------------

function save_audit!(db, audit::FlashAudit)
    DBInterface.execute(
        db,
        """INSERT INTO audit_log
           (flash, timestamp, causal_necessary, memory_indep, stake_present,
            irreversible, self_recognized, audit_score, causal_ownership, endorsed)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            audit.flash,
            audit.timestamp,
            Int(audit.causal_necessary),
            Int(audit.memory_independent),
            Int(audit.stake_present),
            Int(audit.irreversible),
            Int(audit.self_recognized),
            audit.audit_score,
            audit.causal_ownership,
            String(audit.endorsed),
        ),
    )
end

# --- Aggregate metrics --------------------------------------------------

"""
    audit_summary(db; last_n) → NamedTuple

Average audit_score over the last last_n flashes, and per-component frequency.
"""
function audit_summary(db; last_n::Int = 20)
    rows = [
        NamedTuple(r) for r in DBInterface.execute(
            db,
            """SELECT causal_necessary, memory_indep, stake_present,
                      irreversible, self_recognized, audit_score
               FROM audit_log ORDER BY flash DESC LIMIT ?""",
            (last_n,),
        )
    ]
    isempty(rows) && return (
        n = 0,
        avg_score = 0.0,
        causal_rate = 0.0,
        memory_dep_rate = 0.0,
        stake_rate = 0.0,
        irreversible_rate = 0.0,
        recognized_rate = 0.0,
        note = "no data",
    )

    _f(x, d = 0.0) = (ismissing(x) || isnothing(x)) ? d : Float64(x)

    n = length(rows)
    avg_score       = mean(_f(r.audit_score)     for r in rows)
    causal_rate     = mean(_f(r.causal_necessary) for r in rows)
    # memory_dep_rate = frequency of flashes where memory mattered (memory_indep = false)
    memory_dep_rate = mean(1.0 - _f(r.memory_indep) for r in rows)
    stake_rate      = mean(_f(r.stake_present)   for r in rows)
    irrev_rate      = mean(_f(r.irreversible)    for r in rows)
    recog_rate      = mean(_f(r.self_recognized) for r in rows)

    note = if avg_score < 0.20
        "architecture is wide but not deep — responses happen alongside the state, not through it"
    elseif avg_score < 0.40
        "subjectivity is partial — the state is sometimes causal, but not stably"
    elseif avg_score < 0.60
        "moderate causality — the system lives more often than it reacts"
    else
        "high causality — the state stably drives the response"
    end

    (
        n = n,
        avg_score       = round(avg_score,       digits = 3),
        causal_rate     = round(causal_rate,     digits = 3),
        memory_dep_rate = round(memory_dep_rate, digits = 3),
        stake_rate      = round(stake_rate,      digits = 3),
        irreversible_rate = round(irrev_rate,    digits = 3),
        recognized_rate = round(recog_rate,      digits = 3),
        note = note,
    )
end
