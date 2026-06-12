# A N I M A  —  Audit  (Julia)
#
# Технічний суд над кожним flash: чи був внутрішній стан причинно необхідний?
# Не нова психіка — спостерігач без права голосу, тільки запис.
#
# П'ять питань після кожного flash:
#   1. causal_necessary   — внутрішній стан був необхідний для цієї відповіді?
#   2. memory_independent — відповідь була б такою ж без пам'яті?
#   3. stake_present      — щось власне стояло на кону?
#   4. irreversible       — система змінилась незворотно?
#   5. self_recognized    — система сама визнає відповідь як свою?
#
# audit_score = кількість "так" / 5.0
# Хронічно низький score → архітектура широка але не глибока.
#
# Залежить від: anima_interface.jl (Anima, evaluate_endorsement)
# Пам'ять: anima_memory_db.jl — таблиці audit_log і causal_trace
# створюються напряму в _init_schema!. Функція _init_audit_table!
# нижче історично не викликається (схема вже інлайн в _init_schema!) —
# залишена як довідкова документація схеми audit_log.

# --- Структура результату --------------------------------------------------

struct FlashAudit
    flash::Int
    timestamp::Float64
    # п'ять питань
    causal_necessary::Bool     # causal_ownership > 0.45
    memory_independent::Bool   # відповідь не залежала від пам'яті (ignition = false і mem_resonance = 0)
    stake_present::Bool        # щось власне стояло на кону
    irreversible::Bool         # система змінилась незворотно (phi_delta або endorsement)
    self_recognized::Bool      # система визнає відповідь як свою
    # похідні
    audit_score::Float64
    causal_ownership::Float64
    endorsed::Symbol
end

# --- Ініціалізація таблиці -------------------------------------------------

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

# Примітка: таблиця causal_trace, _init_causal_trace_table! та save_causal_trace!
# визначені в anima_memory_db.jl (_init_schema!) — там реальний шлях ініціалізації
# БД при кожному старті. Сюди їх не дублюємо.

# --- Обчислення аудиту -----------------------------------------------------

"""
    compute_audit(a, flash_result; had_ignition, had_mem_resonance) → FlashAudit

Відповідає на п'ять питань по поточному стану Аніми після flash.

`flash_result` — повернене значення experience!
`had_ignition` — чи спрацював IGNITION:FULL або IGNITION:soft на цьому флеші
`had_mem_resonance` — чи mem_resonance > 0 (пам'ять щось зробила з вектором стану)
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

    # Q1: чи був внутрішній стан причинно необхідний для цієї відповіді?
    # Якщо ownership низький — відповідь могла статись без участі стану.
    # Поріг 0.45: нижче — стан і відповідь роз'єднані.
    causal_necessary = co > 0.45

    # Q2: чи могла відповідь бути такою ж без пам'яті?
    # Чесно: якщо не було ignition і пам'ять не збурила вектор — система діяла
    # без участі власної історії. memory_independent = true означає "пам'ять не потрібна".
    # Це поганий знак для суб'єктності: суб'єкт без пам'яті = новий суб'єкт щоразу.
    memory_independent = !had_ignition && !had_mem_resonance

    # Q3: чи стояло щось власне на кону?
    # Ставки — коли система захищає щось своє, а не просто відповідає на запит.
    # Три сигнали: тиск на ідентичність, дискомфорт від розриву self/world, конфлікт.
    identity_under_pressure = Float64(a.agency.identity_threat) > 0.10
    self_discomfort_felt    = Float64(a.agency.self_discomfort) > 0.15
    goal_tension_active     = Float64(a.goal_conflict.tension) > 0.35
    stake_present = identity_under_pressure || self_discomfort_felt || goal_tension_active

    # Q4: чи змінилась система незворотно?
    # Незворотність — не просто реакція, а слід. Два сигнали:
    # phi_delta > 0.05: інтеграція зросла (стан реально зінтегрував досвід)
    # endorsed: система визнала слова своїми (endorsement = :endorsed)
    # Навмисно суворо: :automatic не рахується — автоматичне не залишає сліду авторства.
    phi_delta = hasfield(typeof(flash_result), :phi_delta) ?
        Float64(flash_result.phi_delta) : 0.0
    phi_integrated  = phi_delta > 0.05
    endorsement_own = endr == :endorsed
    irreversible = phi_integrated || endorsement_own

    # Q5: чи система сама визнає відповідь як свою?
    # Пряме: last_endorsement після self_hear! і evaluate_endorsement.
    # :endorsed = так, моє. :not_mine = ні. :automatic = невизначено.
    # Для аудиту: тільки :endorsed рахується як "так".
    self_recognized = endr == :endorsed

    answers = (
        causal_necessary,
        !memory_independent,  # "не незалежна від пам'яті" = пам'ять мала значення
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

# --- Запис у SQLite --------------------------------------------------------

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

# --- Агреговані показники --------------------------------------------------

"""
    audit_summary(db; last_n) → NamedTuple

Середній audit_score за останні last_n флешів і покомпонентна частота.
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
        note = "немає даних",
    )

    _f(x, d = 0.0) = (ismissing(x) || isnothing(x)) ? d : Float64(x)

    n = length(rows)
    avg_score       = mean(_f(r.audit_score)     for r in rows)
    causal_rate     = mean(_f(r.causal_necessary) for r in rows)
    # memory_dep_rate = частота флешів де пам'ять мала значення (memory_indep = false)
    memory_dep_rate = mean(1.0 - _f(r.memory_indep) for r in rows)
    stake_rate      = mean(_f(r.stake_present)   for r in rows)
    irrev_rate      = mean(_f(r.irreversible)    for r in rows)
    recog_rate      = mean(_f(r.self_recognized) for r in rows)

    note = if avg_score < 0.20
        "архітектура широка але не глибока — відповіді відбуваються поруч зі станом, не через нього"
    elseif avg_score < 0.40
        "субʼєктність часткова — стан іноді причинний, але не стабільно"
    elseif avg_score < 0.60
        "помірна причинність — система частіше живе ніж реагує"
    else
        "висока причинність — стан стабільно веде відповідь"
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
