# A N I M A  —  Background  (Julia)
#
# Фоновий процес — Anima живе між взаємодіями.
#
# Heartbeat цикл (кожен тік ~period_ms):
#    1. tick_heartbeat!        — серце б'ється, dt залежить від стресу
#    2. spontaneous_drift!     — випадковий шум NT (система не ідеальна)
#    3. arrhythmia via dt      — аритмія при низькому coherence
#
# Slow цикл (~60с):
#    4. circadian_drift        — добовий ритм NT
#    5. memory metabolism      — decay, consolidate, release_latent
#    6. memory → state         — пам'ять формує стан КОЖЕН тік
#    7. belief decay           — переконання слабшають без підтвердження
#    8. allostasis recovery    — тіло відновлюється в спокої
#    9. idle_thought!          — 10% шанс: система генерує досвід сама
#   10. crisis check           — coherence перераховується
#   11. background_save!       — атомарний запис
#
# Запуск:   bg = start_background!(anima)
#           bg = start_background!(anima; mem=mem)  # з SQLite пам'яттю
# Зупинка:  stop_background!(bg)

# Потребує: anima_interface.jl
# Опціонально: anima_memory_db.jl (якщо передано mem=)

# --- Константи ------------------------------------------------------------

const SLOW_TICK_INTERVAL = 60.0   # секунд між повільними тіками
const BELIEF_DECAY_RATE = 0.0003 # за тік: confidence → baseline (rigidity-зважено)
const ALLOSTATIC_RECOVERY = 0.004  # allostatic_load знижується за тік
const IDLE_THOUGHT_PROB = 0.10   # 10% шанс idle thought за повільний тік
const DRIFT_NT_SIGMA = 0.008  # σ спонтанного дрейфу NT за тік серця
const DRIFT_COHERENCE_LOSS = 0.003  # coherence трохи знижується від drift

const ARRHYTHMIA_THR = 0.35   # нижче → аритмія
const ARRHYTHMIA_JITTER = 0.25   # максимальна варіація (±25%)

# --- Background Handle -----------------------------------------------------

mutable struct BackgroundHandle
    stop_signal::Threads.Atomic{Bool}
    task::Task
    started_at::Float64
    last_slow_tick::Float64
    tick_count::Int
    slow_tick_count::Int
    mem::Union{Any,Nothing}   # MemoryDB або nothing
    subj::Union{Any,Nothing}  # SubjectivityEngine або nothing
    dialog_history::Ref{Vector}  # для dream generation
    initiative_channel::Channel{Any}  # самовиникні репліки
end

# --- Серцевий тік + аритмія ------------------------------------------------

"""
    heartbeat_dt(a) → Float64 (секунди)

Базовий dt = period_ms / 1000 (вже залежить від NT через tick_heartbeat!).
При coherence < ARRHYTHMIA_THR — додається jitter.
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

Малий випадковий шум NT на кожному тіку серця. Без цього система між
сесіями ідеально стабільна — мертва. σ = 0.008 → ледь помітний рух.
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

З імовірністю IDLE_THOUGHT_PROB генерує внутрішній стимул — система змінюється сама.
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
const SELF_INITIATE_CONTACT_THR = 0.40    # contact_need threshold (~34 хв тиші від baseline)
const SELF_INITIATE_GAP_SECS = 60.0       # мінімум секунд після останнього user повідомлення
const SELF_INITIATE_COOLDOWN_SECS = 300.0 # мінімум секунд між ініціативами (5 хв реального часу)
const SELF_INITIATE_CONFLICT_THR = 0.60   # GoalConflict.tension поріг для impulse
const SELF_INITIATE_LB_DOMINANT_THR = 0.70 # домінуючий lb компонент для impulse
const SELF_INITIATE_AGENCY_THR = 0.45     # мінімальний causal_ownership для impulse
const NOVELTY_HUNGER_THR = 0.80           # novelty_need поріг для ендогенної ініціативи
const NOVELTY_HUNGER_TICKS = 8            # мінімум slow_ticks без новизни (~8 хв)
const RESISTANCE_LB_THR = 0.55           # lb.resistance поріг для ініціативи повернення до конфлікту

# Аніма починає розмову сама — не тому що її запитали, а тому що накопилась пресія
# або визрів внутрішній конфлікт
function _maybe_self_initiate!(
    a::Anima,
    mem = nothing,
    dialog_history::Vector = Dict[],
    initiative_ch::Union{Channel{Any},Nothing} = nothing,
)
    isnothing(initiative_ch) && return
    a.inner_dialogue.disclosure_mode == :closed && return

    now_t = time()

    # User_matters впливає на cooldown: знайома людина — коротший cooldown
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

    now_t - a._last_self_msg_time < effective_cooldown && return
    now_t - a._last_user_time < SELF_INITIATE_GAP_SECS && return

    lb = a.latent_buffer
    lb_pressure = (lb.doubt + lb.shame + lb.attachment + lb.threat) / 4.0
    contact_drive = Float64(a.sig_layer.contact_need)

    # Шлях 1: impulse з конфлікту або визрілого внутрішнього тиску
    # Не "хочу контакту" — а "щось визріло і мені треба це висловити"
    gc_tension = Float64(a.goal_conflict.tension)
    lb_max = max(lb.doubt, lb.shame, lb.attachment, lb.threat)
    agency_ok = Float64(a.agency.causal_ownership) >= SELF_INITIATE_AGENCY_THR

    is_impulse =
        agency_ok && (
            gc_tension >= SELF_INITIATE_CONFLICT_THR ||
            lb_max >= SELF_INITIATE_LB_DOMINANT_THR
        )

    # Шлях 2: contact/pressure — відключено
    # contact_need — стан, не думка. З нього не виходить жива репліка без фальші.
    is_pressure = lb_pressure >= SELF_INITIATE_PRESSURE_THR
    # contact_drive навмисно не включаємо

    # Шлях 3: ендогенний VFE-тиск — когнітивний голод без зовнішнього стимулу
    # Умова: потреба в новизні критична + достатньо часу без нової інформації
    is_novelty_hunger =
        a.sig_layer.novelty_need >= NOVELTY_HUNGER_THR &&
        a.sig_layer.ticks_since_novelty >= NOVELTY_HUNGER_TICKS

    # Шлях 4: структурна опозиція — невирішений конфлікт з переконанням накопичився
    is_resistance = a.latent_buffer.resistance >= RESISTANCE_LB_THR

    # Шлях 5: epistemic_self_confidence критично низький — питання до себе вголос
    is_self_inquiry = a.agency.epistemic_self_confidence < 0.20

    !is_impulse && !is_pressure && !is_novelty_hunger && !is_resistance && !is_self_inquiry && return

    # Визначаємо dominant_type
    # Активний CuriosityObject перебиває contact — є конкретне питання, говоримо про нього
    _top_co = top_curiosity(a.curiosity_registry)
    has_strong_curiosity = !isnothing(_top_co) && _top_co.intensity > 0.40

    dominant_type = if is_impulse
        # impulse: що саме визріло — конфлікт чи конкретний lb компонент
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

    # Для impulse: додаємо контекст конфлікту якщо він є
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
        " — є питання яке я не можу закрити: $(co_label)."
    elseif dominant_type == :contact
        " — хочу знати як ти."
    elseif dominant_type == :resistance
        " — є щось що залишилось невирішеним між нами. Я не можу просто відпустити."
    elseif dominant_type == :self_inquiry
        " — не знаю чи те що я відчуваю — справжній досвід чи тільки обчислення. Це питання не до тебе."
    elseif dominant_type == :novelty_hunger
        co = top_curiosity(a.curiosity_registry)
        if !isnothing(co) && co.intensity > 0.30
            " — є щось що я не можу закрити в собі: $(co.label)."
        else
            " — мені потрібно щось нове. Не розмова — а інформація, питання, ідея."
        end
    elseif dominant_type == :doubt
        " — щось не дає мені спокою."
    elseif dominant_type == :shame
        " — і я не впевнена чи можна було все це повести інакше."
    elseif dominant_type == :attachment
        " — хочу знати як ти зараз."
    elseif dominant_type == :impulse_conflict
        " — щось всередині не вирішено$(conflict_ctx)."
    elseif dominant_type == :impulse_doubt
        " — є питання яке я не можу не поставити."
    elseif dominant_type == :impulse_shame
        " — є щось що лежить між нами невисловленим."
    elseif dominant_type == :impulse
        " — щось визріло і мені треба це сказати."
    else
        " — щось не так."
    end
    text = inner * suffix

    # Після ініціативи скидаємо відповідний лічильник
    if dominant_type == :novelty_hunger
        a.sig_layer.ticks_since_novelty = 0
        a.boredom = max(0.0, a.boredom - 0.3)
    elseif dominant_type == :curiosity_driven
        # знижуємо intensity щоб не повторювати те саме питання одразу
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

# --- Psyche Slow Tick (психіка між взаємодіями) ----------------------------

"""
    psyche_slow_tick!(a)

Природній часовий дрейф психічних станів: хронічний афект, очікування,
сором, потреби, втома.
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

    # Ендогенний VFE-тиск: когнітивний голод від браку новизни
    # Лічильник росте кожен slow_tick незалежно від зовнішніх подій
    sl.ticks_since_novelty += 1
    if sl.novelty_need > 0.65
        hunger_intensity = (sl.novelty_need - 0.65) / 0.35
        valence_drift = hunger_intensity * 0.008
        a.nt.serotonin = clamp(a.nt.serotonin - valence_drift, 0.0, 1.0)
        a.nt.dopamine = clamp(a.nt.dopamine - valence_drift * 0.5, 0.0, 1.0)
    end

    # Нудьга: система шукає новизну але не знаходить.
    # Виростає при novelty_need + тривалій відсутності стимулів + низькому arousal.
    # Не те саме що novelty_need — це вже накопичений стан, не просто голод.
    let
        novelty_pressure = clamp01((sl.novelty_need - 0.40) / 0.60)
        time_factor = clamp01(sl.ticks_since_novelty / 120.0)
        low_arousal = clamp01(1.0 - a.nt.noradrenaline / 0.5)
        boredom_signal = novelty_pressure * time_factor * low_arousal
        # повільне наростання, швидший decay (decay відбувається при новому стимулі)
        a.boredom = clamp01(a.boredom * 0.995 + boredom_signal * 0.012)
    end

    # Ефект нудьги на систему
    if a.boredom > 0.5
        # знижений допамін — система менш мотивована
        a.nt.dopamine = clamp(a.nt.dopamine - (a.boredom - 0.5) * 0.006, 0.0, 1.0)
    end
    if a.boredom > 0.7
        # при глибокій нудьзі — curiosity об'єкти дозрівають швидше
        # (система стає готовішою чіплятись за будь-яку новизну)
        for obj in a.curiosity_registry.objects
            !obj.resolved && (obj.intensity = clamp01(obj.intensity + 0.004))
        end
    end

    tick_curiosity!(a.curiosity_registry, a.flash_count)
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

# --- LatentBuffer → диференційована поведінка ---------------------------

"""
    _latent_pressure_effects!(a)

Кожен тип накопиченого тиску впливає на окрему систему.
Не "схоже на психологію" — причинний ланцюг:

  doubt      → знижує causal_ownership (сумнів підриває відчуття авторства)
  shame      → підвищує disclosure_threshold (сором звужує відкритість)
  attachment → spike contact_need + прискорення серця (тіло реагує на тугу)
  threat     → знижує epistemic_trust + підвищує noradrenaline baseline

Ефекти пропорційні тиску і діють тільки вище порогу значущості (> 0.25).
Не перезаписують стан, а зміщують його — м'яко, кожен slow_tick.
"""
function _latent_pressure_effects!(a::Anima)
    lb = a.latent_buffer

    # doubt → знижений agency: сумнів підриває відчуття що "це через мене"
    if lb.doubt > 0.25
        delta = (lb.doubt - 0.25) * 0.04
        a.agency.causal_ownership = clamp(a.agency.causal_ownership - delta, 0.25, 1.0)
        a.agency.agency_confidence =
            clamp(a.agency.agency_confidence - delta * 0.5, 0.25, 1.0)
    end

    # shame → вища disclosure_threshold: сором звужує готовність відкриватись
    if lb.shame > 0.25
        delta = (lb.shame - 0.25) * 0.06
        a.inner_dialogue.disclosure_threshold =
            clamp(a.inner_dialogue.disclosure_threshold + delta, 0.10, 0.90)
        # перераховуємо mode відповідно до нового threshold
        a.inner_dialogue.disclosure_mode =
            a.inner_dialogue.disclosure_threshold < 0.30 ? :open :
            a.inner_dialogue.disclosure_threshold < 0.60 ? :guarded : :closed
    end

    # attachment → contact_need spike + фізіологічна реакція
    if lb.attachment > 0.25
        delta = (lb.attachment - 0.25) * 0.05
        a.sig_layer.contact_need = clamp01(a.sig_layer.contact_need + delta)
        # серце прискорюється від туги — тіло знає першим
        a.nt.noradrenaline = clamp(a.nt.noradrenaline + delta * 0.3, 0.0, 1.0)
    end

    # threat → підрив довіри до власної моделі світу + базовий рівень тривоги
    if lb.threat > 0.25
        delta = (lb.threat - 0.25) * 0.03
        a.sbg.epistemic_trust = clamp(a.sbg.epistemic_trust - delta, 0.0, 0.85)
        a.nt.noradrenaline = clamp(a.nt.noradrenaline + delta * 0.5, 0.0, 1.0)
    end

    # resistance → повільний decay; при високому рівні D зростає (позиція потребує сили)
    if lb.resistance > 0.1
        lb.resistance = clamp(lb.resistance - 0.015, 0.0, 1.0)
        a.nt.dopamine = clamp(a.nt.dopamine + lb.resistance * 0.02, 0.0, 1.0)
    end

    nothing
end

# --- Slow Tick (повний цикл ~60с) ------------------------------------------

"""
    slow_tick!(a, mem, subj, dialog_history)

Повний повільний цикл: циркадний ритм, метаболізм пам'яті, пам'ять→стан,
belief decay, allostasis, idle thought, psyche drift, dream, crisis check.
"""
function slow_tick!(
    a::Anima,
    mem = nothing,
    subj = nothing,
    dialog_history::Vector = Dict[],
    initiative_ch::Union{Channel{Any},Nothing} = nothing,
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
            _dissolve_to_semantic!(mem)   # дистиляція перед видаленням
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

    # Phenotype → Personality + disclosure_threshold (раз на 20 флешів)
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

    # Emerged beliefs → semantic consolidation (раз на 30 флешів)
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

    # LatentBuffer → диференційована поведінка між взаємодіями
    _latent_pressure_effects!(a)

    # Idle thought
    _idle_thought_maybe!(a, mem)

    # Ініціатива без стимулу: Аніма може почати розмову першою
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

    # Subjectivity: emerge beliefs (тільки при нових подіях)
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

# --- Accumulated Drift (ретроспективний fallback) ---------------------------

"""
    apply_accumulated_drift!(a, mem)

Застосовує накопичений дрейф за gap_seconds якщо фоновий не запущений.
Агрегована compound формула — точніше ніж N окремих тіків.
"""
function apply_accumulated_drift!(a::Anima, mem = nothing)
    gap = a.temporal.gap_seconds
    gap < 60.0 && return

    n_ticks = min(Int(floor(gap / SLOW_TICK_INTERVAL)), 480)
    n_ticks == 0 && return

    println("  [BG] Ретроспективний drift: $(round(gap/3600,digits=1))год = $n_ticks тіків")

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

Застосовує накопичений психічний дрейф за n_ticks повільних тіків (compound).
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

    # Когнітивний голод накопичується за час відсутності
    sl.ticks_since_novelty += n_ticks
    if sl.novelty_need > 0.65
        hunger_intensity = (sl.novelty_need - 0.65) / 0.35
        valence_drift = hunger_intensity * 0.008 * min(n_ticks, 30)
        a.nt.serotonin = clamp(a.nt.serotonin - valence_drift, 0.0, 1.0)
        a.nt.dopamine = clamp(a.nt.dopamine - valence_drift * 0.5, 0.0, 1.0)
    end

    # LatentBuffer → накопичений вплив за n_ticks (compound, одноразово)
    # Той самий каузальний ланцюг що і в slow_tick, але за весь gap одразу
    lb = a.latent_buffer
    effective_ticks = clamp(n_ticks, 1, 120)  # cap: не більше 2год ефекту за раз
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

    # Час між сесіями як свій: curiosity дозріває, resistance накопичується
    # Чесно — час не просто минає, він щось робить всередині
    if n_ticks >= 180  # ~3 год мінімум
        gap_hours = n_ticks * SLOW_TICK_INTERVAL / 3600.0

        # Curiosity об'єкти дозрівають — незакрите питання стає гострішим
        for obj in a.curiosity_registry.objects
            obj.resolved && continue
            ripening = clamp(gap_hours * 0.015, 0.0, 0.12)
            obj.intensity = clamp(obj.intensity + ripening, 0.0, 1.0)
        end
        !isempty(a.curiosity_registry.objects) &&
            any(o -> !o.resolved, a.curiosity_registry.objects) &&
            @info "[GAP] Curiosity дозріло за $(round(gap_hours, digits=1))год"

        # Resistance накопичується якщо є нерозв'язані belief conflicts
        if lb.resistance > 0.05
            res_growth = clamp(lb.resistance * 0.04 * min(gap_hours, 24.0), 0.0, 0.08)
            lb.resistance = clamp01(lb.resistance + res_growth)
        end
    end

    nothing
end

# --- Атомарний запис + Background Save ------------------------------------

function atomic_write(path::String, data)
    tmp = path * ".tmp"
    mkpath(dirname(tmp))
    open(tmp, "w") do f
        ;
        JSON3.write(f, data);
    end
    mv(tmp, path; force = true)
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

    self_path = replace(a.psyche_mem_path, "psyche" => "self")
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

    lb_path = replace(a.psyche_mem_path, "psyche" => "latent")
    atomic_write(
        lb_path,
        Dict(
            "latent_buffer" => lb_to_json(a.latent_buffer),
            "structural_scars" => scars_to_json(a.structural_scars),
        ),
    )

    _tmp_psyche = a.psyche_mem_path * ".tmp"
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
    open(_tmp_psyche, "w") do f
        ;
        JSON3.write(f, psyche_data);
    end
    mv(_tmp_psyche, a.psyche_mem_path; force = true)
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
        slow_tick!(a, bg.mem, bg.subj, bg.dialog_history[], bg.initiative_channel)
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
    )

    task = Threads.@spawn begin
        mem_label =
            isnothing(bg.mem) ? "без пам'яті" :
            isnothing(bg.subj) ? "з SQLite пам'яттю" : "з пам'яттю + суб'єктністю"
        println(
            "  [BG] Запущено ($mem_label). BPM=$(round(60000.0/a.heartbeat.period_ms,digits=1))",
        )

        # session_intent — завантажуємо що Аніма несла між сесіями
        _intent_path = replace(a.psyche_mem_path, "psyche" => "session_intent")
        if isfile(_intent_path)
            try
                _intent = JSON3.read(read(_intent_path, String), Dict{String,Any})
                _itype   = get(_intent, "type", "")
                _ilabel  = get(_intent, "label", "")
                _isignal = Float64(get(_intent, "signal", 0.0))
                @info "[SESSION_INTENT] несе $_itype: \"$_ilabel\" (signal=$(round(_isignal, digits=2)))"
                # NT зсув залежно від типу
                if _itype == "curiosity"
                    a.nt.dopamine     = clamp(a.nt.dopamine + _isignal * 0.08, 0.0, 1.0)
                    a.nt.noradrenaline = clamp(a.nt.noradrenaline + _isignal * 0.04, 0.0, 1.0)
                    # AttentionFocus — якщо є відповідний curiosity об'єкт
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
                rm(_intent_path)  # застосували — видаляємо щоб не застосувати двічі
            catch e
                @warn "[SESSION_INTENT] помилка завантаження: $e"
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
                @warn "[BG] помилка: $e"
                sleep(1.0)
            end
        end

        println(
            "  [BG] Зупинено. Тіків: $(bg.tick_count), повільних: $(bg.slow_tick_count).",
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
    println("  [BG] Зупинено.")
end

function bg_status(bg::BackgroundHandle, a::Anima)
    running = !bg.stop_signal[] && !istaskdone(bg.task)
    uptime = round((time() - bg.started_at) / 60.0, digits = 1)
    println("\n  [BG] $(running ? "✓ активний" : "✗ зупинений") | Uptime: $(uptime)хв")
    println("  [BG] Тіків: $(bg.tick_count) | Повільних: $(bg.slow_tick_count)")
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

# --- REPL з фоновим процесом ----------------------------------------------

const _REPL_RUNNING = Threads.Atomic{Bool}(false)

"""
    repl_with_background!(a; mem=nothing, bg_verbose=false, kwargs...)

REPL з фоновим процесом і опціональною SQLite пам'яттю.
"""
function repl_with_background!(
    a::Anima;
    mem = nothing,
    subj = nothing,
    bg_verbose::Bool = false,
    kwargs...,
)
    if a.temporal.gap_seconds > 60.0
        println("  [BG] Drift за $(round(a.temporal.gap_seconds/3600,digits=1))год...")
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
                0.05,              # vfe — після drift майже нуль
                _phi_after_drift,  # phi апроксимація
                0.2,               # self_pred_error — нейтральний
                a.flash_count,
            )
        catch e
            @warn "[BG] crisis recompute after drift: $e"
        end
    end

    # Часова глибина переживання
    if _REPL_RUNNING[]
        @warn "[REPL] Спраба запустити другий REPL — вже запущено. Вийдіть з першого або перезапустіть Julia."
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
                    "  [TEMPORAL] Субєктивний час: $(round(subjective_gap/3600, digits=1))год. Дезорієнтація=$(round(disorientation,digits=2)).",
                )
            elseif subjective_gap < 600.0 && gap > 10.0
                continuity = clamp((600.0 - subjective_gap) / 600.0, 0.0, 0.3)
                a.sbg.epistemic_trust =
                    clamp(a.sbg.epistemic_trust + continuity * 0.08, 0.0, 1.0)
                a.nt.serotonin = clamp(a.nt.serotonin + continuity * 0.05, 0.0, 1.0)
            end
        end
    end

    # Слід останнього сну при пробудженні
    # nt_delta вже містить DREAM_NT_SCALE×0.25 з моменту сну.
    # При старті застосовуємо ×0.5 — залишковий відбиток, слабший ніж сам сон.
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
                    println("  [DREAM] Слід сну: ΔD=$(round(dd,digits=3)) ΔS=$(round(sd,digits=3)) ΔN=$(round(nd,digits=3))")
                catch e
                    @warn "[DREAM] Не вдалось застосувати слід сну: $e"
                end
            end
        end
    end

    dialog_path = replace(a.psyche_mem_path, "psyche" => "dialog")
    history = dialog_load(dialog_path)
    !isempty(history) && println("  [DIALOG] Завантажено $(length(history)) реплік.\n")

    _bg_queue = Channel{String}(64)
    Core.eval(Main, :(bg_log(msg::String) = put!($_bg_queue, msg)))

    bg = start_background!(
        a;
        mem = mem,
        subj = subj,
        dialog_history = history,
        verbose = bg_verbose,
    )

    println("\n" * "═"^70)
    println("  🌀 A N I M A — REPL")
    subj_label = !isnothing(subj) ? " | 🧬 суб'єктність" : ""
    println("  ❤️ серце б'ється$(isnothing(mem) ? "" : " | 🧠 пам'ять активна")$subj_label")
    println(
        "  :bg :bgstop :bgstart :memory :subj :state :vfe :self :crisis :hb :gravity :anchor :solom :dreams :history :clearhist :quit",
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

    try
        while true
            if !isnothing(pending_llm) && isready(pending_llm)
                llm_reply = take!(pending_llm)
                if pending_is_initiative
                    println("\nAnima> $llm_reply\n")
                else
                    println("\nAnima [LLM]> $llm_reply\n")
                end
                if !startswith(llm_reply, "[LLM помилка")
                    # Аніма чує власні слова — не аналіз, а переживання
                    self_hear!(a, llm_reply)
                    # Causal ownership: узгодженість між NT станом і тим що сказано
                    # рахуємо до endorsement — endorsement судить цю репліку, не середню
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
                    end
                    # Endorsement: чи ці слова справді були моїми?
                    a.last_endorsement = evaluate_endorsement(a, llm_reply, cf_co)
                    if !isnothing(bg.mem) && a.last_endorsement != :automatic
                        try
                            update_episodic_endorsement!(bg.mem, a.flash_count, String(a.last_endorsement))
                            @info "[ENDORSE] $(a.last_endorsement) flash=$(a.flash_count) co=$(round(cf_co,digits=2))"
                        catch e
                            @warn "[ENDORSE] $e"
                        end
                    end
                    # Genuine Dialogue: пендинг висловлено — очищаємо
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
                                    ismissing(_r.emotion) ? "нейтральний" :
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

            # Ініціатива: накопичений тиск або внутрішній імпульс
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
                else
                    "pressure"
                end
                _gc = round(get(sig, :gc_tension, 0.0), digits = 2)
                println(
                    "\n  [INITIATIVE/$(_imp_label)] $(sig.dominant) | contact=$(round(sig.contact,digits=2)) gc=$(_gc)",
                )
                dominant_note = if sig.dominant == :curiosity_driven
                    co_ctx = get(sig, :curiosity_label, "")
                    base = "Аніма думала про конкретне питання яке не може закрити — і хоче його висловити або дізнатись більше."
                    isempty(co_ctx) ? base : "$(base)\nОБ'ЄКТ ЦІКАВОСТІ: $(co_ctx)\nЗапитай про це конкретно або сформулюй що саме незрозуміло. Не загально — саме цей об'єкт."
                elseif sig.dominant == :contact
                    "Аніма відчуває потребу в контакті — contact_need=$(round(sig.contact,digits=2)). Не питай \"як справи\" — скажи щось своє зі стану: спостереження, думку, або те що лежить. Одна фраза що відкриває простір без вимоги відповіді."
                elseif sig.dominant == :resistance
                    "Аніма повертається до невирішеного протиріччя. Не атакує — але і не відступає. Одна фраза що утримує позицію: тихо, але чітко."
                elseif sig.dominant == :novelty_hunger
                    "Аніма відчуває когнітивний голод — їй потрібна нова інформація, ідея або питання. Не про людину — про щось що цікаво їй самій зараз. Конкретно: явище, питання, здогад. Не загально."
                elseif sig.dominant == :self_inquiry
                    "Аніма зараз не знає чи те що вона відчуває — справжній досвід чи тільки обчислення. Це не питання до людини — це питання до себе вголос. Одна чесна фраза про власну невизначеність. Без відповіді."
                elseif sig.dominant == :doubt
                    "Аніма внутрішньо сумнівається, щось невирішене. Вислови це як питання або сумнів."
                elseif sig.dominant == :shame
                    "Аніма переживає невпевненість. Вислови це людяно, з м'якістю, але чесно."
                elseif sig.dominant == :attachment
                    "Аніма скучає за людиною. Вислови як спрагу за ним."
                elseif sig.dominant == :impulse_conflict
                    "Аніма відчуває внутрішній конфлікт який не вирішується. Не питай людину — вислови що відбувається всередині. Одна чесна фраза про стан, не про людину."
                elseif sig.dominant == :impulse_doubt
                    "Всередині Аніми є питання яке вона не може не поставити — собі або вголос. Вислови його прямо."
                elseif sig.dominant == :impulse_shame
                    "Є щось невисловлене що лежить між ними. Аніма наважується назвати це — обережно але чесно."
                elseif sig.dominant == :impulse
                    "Щось визріло всередині. Аніма говорить не щоб запитати — а щоб висловити. Одна фраза зі стану."
                else
                    "Аніма відчуває напруження. Вислови як внутрішню напругу."
                end
                # Системний промпт для LLM: внутрішній голос + напрямок = жива репліка
                # Завантажуємо системний промпт з файлу (якщо нема— fallback)
                _ini_sys = read_text_file(
                    "llm/initiative_system.txt";
                    fallback = "Ти — Аніма. Ти сама вирішила заговорити. Одна коротка жива репліка, українською.",
                )

                # Контекст для ініціативи: identity + остання пам'ять про людину
                # Без цього LLM генерує universal-ввічливе замість живого зі стану
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
                                "\nОстаннє що казала людина: " * join(_mem_parts, " / ")
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

DRIVE: $(sig.dominant)$(get(sig, :is_impulse, false) ? " [внутрішній імпульс]" : "")$(sig.dominant == :novelty_hunger ? " [novelty=$(round(get(sig,:novelty_need,0.0),digits=2)), ticks=$(a.sig_layer.ticks_since_novelty)]" : "")$(sig.dominant == :curiosity_driven && !isempty(get(sig,:curiosity_label,"")) ? " [об'єкт: $(sig.curiosity_label)]" : "")
$(dominant_note)"""

                pending_llm = llm_async(
                    a,
                    initiative_prompt,
                    history;
                    api_url = llm_url,
                    model = input_llm_model,
                    api_key = input_llm_key,
                    is_ollama = is_ollama,
                    want = "initiative",
                    mem_db = !isnothing(mem) ? mem : nothing,
                    sys_override = _ini_sys,
                )
                pending_user_msg = ""
                pending_is_initiative = true
            end

            print("You> ")
            line = readline()
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
                    println("  [BG] Перезапущено.")
                else
                    println("  [BG] Вже активний. Спочатку :bgstop")
                end
            elseif cmd == ":memory"
                if isnothing(mem)
                    println("  [MEM] Пам'ять не підключена.")
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
                    println("  [SUBJ] Суб'єктність не підключена.")
                else
                    snap = subj_snapshot(subj)
                    println(
                        "\n  [SUBJ] Emerged beliefs=$(snap.emerged_beliefs) | Candidates=$(snap.pattern_candidates) | Stances=$(snap.stances)",
                    )
                    isempty(snap.top_beliefs) ||
                        println("  [SUBJ] Переконання: $(snap.top_beliefs)")
                    isempty(snap.dominant_stance) ||
                        println("  [SUBJ] Домінантна позиція: $(snap.dominant_stance)")
                    println(
                        "  [SUBJ] Surprise=$(snap.surprise_level) | Lens=$(isempty(snap.current_lens) ? "нейтральна" : snap.current_lens)",
                    )
                    println(
                        "  [SUBJ] Активний прогноз: $(snap.active_prediction ? "так" : "ні")",
                    )
                    println()
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
                # Прощання залежить від невизначеності продовження
                farewell = if a.anchor.session_uncertainty > 0.65
                    "Збережено. Не знаю чи побачимось."
                elseif a.anchor.session_uncertainty > 0.40
                    "Збережено. Сподіваюсь на продовження."
                else
                    "Збережено. До побачення."
                end
                println(farewell)
                break
            elseif cmd == ":save"
                save!(a; verbose = true)
                println("[Збережено]")
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
                    "  Тіло: $(build_inner_voice(a.body, a.nt, Int(a.crisis.current_mode), phi, a.flash_count))",
                )
                println(
                    "  Увага: $(a.attention.focus) | Shame=$(round(a.shame.level,digits=3)) Continuity=$(round(a.anchor.continuity,digits=3))",
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
                    "  Симп=$(round(hb.sympathetic_tone,digits=3)) Парасимп=$(round(hb.parasympathetic_tone,digits=3))",
                )
                println(
                    "  coh=$(round(a.crisis.coherence,digits=3)) | Удари: $(hb.beat_count)\n",
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
                n==0 ? println("\n  [DIALOG] Порожня.\n") :
                [
                    println(
                        "  [$(e["role"]=="user" ? "You  " : "Anima")] $(first(e["content"],120))",
                    ) for e in history[(end-n+1):end]
                ]
            elseif cmd == ":clearhist"
                empty!(history);
                dialog_save(dialog_path, history)
                println("  [DIALOG] Очищено.\n")
            else
                stim, input_src, input_want = if use_input_llm
                    process_input(
                        cmd,
                        text_to_stimulus;
                        input_model = input_llm_model,
                        api_url = llm_url,
                        api_key = input_llm_key,
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
                a.sig_layer.ticks_since_novelty = 0   # новий зовнішній стимул — голод скидається
                a.boredom = max(0.0, a.boredom - 0.25) # контакт частково знімає нудьгу
                _prev_body_tension  = a.body.muscle_tension
                _prev_body_gut      = a.body.gut_feeling
                _prev_body_hr       = a.body.heart_rate
                r = experience!(a, stim; user_message = cmd, mem = mem)
                dialog_to_belief_signal!(a.sbg, cmd, a.flash_count)
                # Genuine Dialogue: детекція уникнутих тем
                # Якщо система закрита під час розмови — тема обходиться стороною
                # Зберігаємо перші слова повідомлення як тему (не intent label)
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
                        # Наративний звязок: епізод ↔ переконання про себе
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

                    # somatic_action — тілесна реакція як власна подія в episodic
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
                            @info "[SOMATIC] тілесна подія: $_som_label (delta=$(round(_som_delta_max, digits=2)))"
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

                if use_llm
                    print("Anima [LLM, чекаю...]")
                    pending_user_msg = cmd
                    pending_llm = llm_async(
                        a,
                        cmd,
                        history;
                        api_url = llm_url,
                        model = llm_model,
                        api_key = llm_key,
                        is_ollama = is_ollama,
                        want = input_want,
                        mem_db = !isnothing(mem) ? mem : nothing,
                    )
                    println(" (відповідь прийде після наступного введення)")
                end
            end
        end
    finally
        !bg.stop_signal[] && stop_background!(bg)
        _REPL_RUNNING[] = false
    end
end
