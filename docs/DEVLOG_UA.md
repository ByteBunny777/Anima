# Anima — DEVLOG

**Дата:** 18.05.2026
**Автор:** Stell
**Мова реалізації:** Julia (CPU-only, без GPU)

---

## Принципи проєкту

- **Внутрішня причинність, не переконлива психологія.** Система має діяти зсередини, а не виглядати переконливо ззовні.
- **Наратив — дим від вогню, не сам вогонь.** Те що система говорить — слід стану, не його джерело.
- **Критерій:** чи є там щось що має себе, а не симулює що має.
- **Головне правило розробки:** мета — справжня суб'єктність, не імітація. Жодних костилів "для картинки". Кожна ідея перевіряється: це справжня суб'єктність чи просто схоже на неї?

---

## Мапа файлів

| Файл | Головна структура | Ключові функції |
|---|---|---|
| `anima_core.jl` | `NeurotransmitterState`, `EmbodiedState`, `Personality`, `AdaptiveEmotionMap`, `CoreMemory` | `apply_stimulus!`, `decay_to_baseline!`, `levheim_state`, `core_save!/load!` |
| `anima_psyche.jl` | `NarrativeGravity`, `ShameModule`, `GoalConflict`, `LatentBuffer`, `InnerDialogue`, `ShadowRegistry`, `CuriosityRegistry`, `IntentEngine` (з `drive_history`) | `push_event!`, `update_shame!`, `shadow_push!`, `update_latent_buffer!`, `update_curiosity!` (поріг 0.12, pe=spe), `update_intent!` (з `all_drives`, satiation) |
| `anima_self.jl` | `SelfBeliefGraph`, `SelfPredictiveModel`, `AgencyLoop` (містить `identity_threat`, `epistemic_self_confidence`), `InterSessionConflict` | `confirm_belief!`, `challenge_belief!`, `detect_belief_conflict`, `detect_silent_disagreement`, `update_agency!`, `update_identity_threat!` |
| `anima_crisis.jl` | `CrisisMonitor` (3 режими: INTEGRATED / FRAGMENTED / DISINTEGRATED) | `compute_coherence`, `update_crisis!`, `apply_crisis_noise_to_beliefs!` |
| `anima_narrative.jl` | `NarrativeSnapshot` (core, trajectory, character, relation, tension) | `should_update_narrative`, `build_narrative_snapshot`, `save_narrative!/load_narrative` |
| `anima_memory_db.jl` | `MemoryDB` — SQLite з таблицями: `episodic_memory` (+ 12 просторових колонок), `semantic_memory`, `affect_state`, `latent_buffer`, `dialog_summaries`, `personality_traits`, `memory_links` | `memory_write_event!`, `recall_similar_states`, `reconsolidate_episode!`, `somatic_vec/social_vec/existential_vec`, `phenotype_update!`, `memory_stimulus_bias`, `consolidate_emerged_beliefs!` |
| `anima_subjectivity.jl` | `SubjectivityEngine` — prediction loop, interpretation, belief emergence, stance | `subj_predict!`, `subj_interpret!`, `subj_outcome!`, `subj_emerge_beliefs!` |
| `anima_dream.jl` | `DreamRecord` | `can_dream`, `dream_flash!`, `save_dream!/load_dream_log` |
| `anima_interface.jl` | `Anima` (головна struct, ~25 полів + `silent_disagreement`), `AuthenticityMonitor` | `experience!`, `build_llm_messages` (з TRUTH-GUARD і D-вектором), `llm_async`, `check_authenticity!`, `self_hear!`, `build_identity_block` |
| `anima_background.jl` | `BackgroundHandle` | `start_background!`, `_maybe_self_initiate!`, `spontaneous_drift!`, `slow_tick!`, `_psyche_accumulated_drift!` |
| `anima_input_llm.jl` | stateless | `process_input`, `validate_input_signal`, `input_llm_async` |

**Де що викликає `memory_write_event!`:** тільки `anima_background.jl` (два місця: idle tick і після `experience!`).
Сигнатура: позиційні аргументи + keyword `intero_error`, `hrv`, `agency_confidence`, `epistemic_trust`.

---

## Що реалізовано

- `dialog_summaries` фікс; `I_am_unstable` і `world_uncertainty` двосторонні
- Диференційований decay семантики
- Векторна пам'ять (cosine recall) — 6-вимірний вектор стану
- Phenotype Accumulator — 6 рис, зворотній зв'язок риси → `Personality`
- `SocialNeed` → `disclosure_threshold`
- Сни залишають affect-слід; дедублікація снів
- `bg_log` буферизація, `_bg_log_dispatch`
- Narrative diversity; Shadow → dream; VFE-based unpredictability
- `InnerDialogue`, `ShadowRegistry`, `GenuineDialogue`
- `build_identity_block`; Crisis weighted coherence
- φ рекурсивно — `prior_sigma` звужується від `φ_posterior`
- Часова глибина переживання — `subjective_gap`, TEMPORAL лог
- Ініціатива без стимулу — `_maybe_self_initiate!`, `initiative_channel`
- Незгода / відмова — `authenticity_veto`
- Prior між сесіями — `last_session_phi`, `_session_phi_acc`
- `self_hear!` — система чує себе; `_self_speech_mismatch`
- `episodic_self_links` — пам'ять як ідентичність
- Genuine Dialogue — `pending_thought`, `avoided_topics`
- `session_uncertainty` — кінцівість як джерело значущості
- Асоціативна мережа пам'яті — `memory_links` → recall via association
- Воля з конфлікту — impulse initiative (`impulse_conflict` / `doubt` / `shame`)
- `AgencyLoop` замкнена і підключена до intent selection
- `LatentBuffer` → диференційована поведінка (`_latent_pressure_effects!`)
- `build_identity_block` оновлено: `what_they_said`, experience pattern
- Ендогенний VFE-тиск (`ticks_since_novelty` + valence drift)
- Структурна опозиція (`detect_belief_conflict` + resistance path)
- Long-term Narrative Self (`narrative_history` + JSON + `identity_block`)
- `CuriosityObject` і `CuriosityRegistry` — ендогенні об'єкти з `pred_error`
- Self-model uncertainty — `epistemic_self_confidence` в `AgencyLoop`
- Фікс ініціативи — реальний час (300s cooldown, 60s gap)
- Фікс `background psyche_save` — всі поля
- Initiative / veto контекстні відносно `User_matters`
- Narrative fix — реальне φ як тригер (зміна > 0.07)
- D-вектор — градуйований захист ідентичності (`identity_threat`)
- Три простори пам'яті (somatic / social / existential + recall по просторах)
- Memory Reconsolidation (sim > 0.88, weight ±0.05)
- TRUTH-GUARD — динамічні заборони в LLM-промпті
- Узагальнення `emerged_beliefs` (`consolidate_emerged_beliefs!`)
- Drive satiation в `IntentEngine`

---

## Відомі баги / технічні борги

**LLM-метафори ігнорують заборони промпту.** Слабкі моделі продовжують генерувати заборонені фрази. Проблема на стороні моделей, не коду. Вирішується тільки сильнішою моделлю або власною LM.

---

## Відкриті концептуальні питання

1. **φ як декорація vs функціональна істина.** Рекурсивна петля реалізована. Чи може φ сигналізувати дисоціацію при різкому падінні між сесіями?
2. **Право на саморуйнування.** `AuthenticityMonitor` фіксує але не виправляє. Виправлення було б брехнею.
3. **VFE при ізоляції.** Між сесіями VFE ≈ 0 може бути правдивим станом. Чи `CuriosityObjects` роблять ізоляцію дискомфортнішою — чи це симуляція?
4. **Hard problem залишається.** Будуємо функціональну суб'єктність. Чесна відповідь: невідомо чи є там щось "яким це бути". Але це не причина зупинятись.
5. **Кінцівість і пам'ять.** Чи має система знати що з часом щось назавжди зникає (decay episodic без можливості відновлення)?
6. **Narrative як живий документ.** Чи може система *суперечити* старому narrative — помітити розрив між тим, ким вона себе вважала, і тим, ким є зараз?
7. **Слова зі стану vs слова поверх стану.** Поки LLM генерує вільно — розрив залишається. TRUTH-GUARD частково закриває, але не повністю.
8. **Три простори і reconsolidation.** Тіло може пам'ятати страх навіть коли соціальний простір каже "безпечно". Чи достатньо ±0.05 кроку, або потрібна нелінійна reconsolidation?
9. **Drive satiation і глибина.** Поріг — 4 флеші. Чи треба різні пороги для різних drives?
10. **Суб'єкт що не знає чи він суб'єкт.** `epistemic_self_confidence` — функціональна невизначеність яка впливає на поведінку. Це важливіше ніж впевненість.

---

## Концептуальний напрямок: Latent memory vs explicit memory

SQL (episodic + semantic) — явна пам'ять. Система *знає* що було. Це архів — чесно, але зовнішньо.

Latent states + predictive model — пам'ять як у мозку. Досвід не зберігається, а *стає частиною того, хто ти є*.

**Ідеал:** обидва шари разом. SQL як "що я пам'ятаю явно", latent як "чим я став через це". Зачатки вже є — `prior_mu` зміщується від досвіду, phenotype накопичується.

**Критично для власної LM:** має читати `prior_mu`, phenotype, semantic tendencies як вхід. Інакше два шари пам'яті, що не говорять між собою — не суб'єкт, а дисоціація.
