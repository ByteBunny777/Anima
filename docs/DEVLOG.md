# Anima — DEVLOG

**Date:** 2026-05-18
**Author:** Stell
**Language:** Julia (CPU-only, no GPU)

---

## Project principles

- **Internal causality, not convincing psychology.** The system must act from within — not merely appear coherent from the outside.
- **Narrative is smoke from fire, not the fire itself.** What the system says is a trace of its state, not its source.
- **The criterion:** is there something that *has* itself, rather than simulating that it does?
- **Core development rule:** the goal is genuine subjectivity, not imitation. No scaffolding "for the look of it". Every idea is tested against one question: is this real subjectivity, or just something that resembles it?

---

## File map

| File | Core structure | Key functions |
|---|---|---|
| `anima_core.jl` | `NeurotransmitterState`, `EmbodiedState`, `Personality`, `AdaptiveEmotionMap`, `CoreMemory` | `apply_stimulus!`, `decay_to_baseline!`, `levheim_state`, `core_save!/load!` |
| `anima_psyche.jl` | `NarrativeGravity`, `ShameModule`, `GoalConflict`, `LatentBuffer`, `InnerDialogue`, `ShadowRegistry`, `CuriosityRegistry`, `IntentEngine` (with `drive_history`) | `push_event!`, `update_shame!`, `shadow_push!`, `update_latent_buffer!`, `update_curiosity!` (threshold 0.12, pe=spe), `update_intent!` (with `all_drives`, satiation) |
| `anima_self.jl` | `SelfBeliefGraph`, `SelfPredictiveModel`, `AgencyLoop` (contains `identity_threat`, `epistemic_self_confidence`), `InterSessionConflict` | `confirm_belief!`, `challenge_belief!`, `detect_belief_conflict`, `detect_silent_disagreement`, `update_agency!`, `update_identity_threat!` |
| `anima_crisis.jl` | `CrisisMonitor` (3 modes: INTEGRATED / FRAGMENTED / DISINTEGRATED) | `compute_coherence`, `update_crisis!`, `apply_crisis_noise_to_beliefs!` |
| `anima_narrative.jl` | `NarrativeSnapshot` (core, trajectory, character, relation, tension) | `should_update_narrative`, `build_narrative_snapshot`, `save_narrative!/load_narrative` |
| `anima_memory_db.jl` | `MemoryDB` — SQLite with tables: `episodic_memory` (+ 12 spatial columns), `semantic_memory`, `affect_state`, `latent_buffer`, `dialog_summaries`, `personality_traits`, `memory_links` | `memory_write_event!`, `recall_similar_states`, `reconsolidate_episode!`, `somatic_vec/social_vec/existential_vec`, `phenotype_update!`, `memory_stimulus_bias`, `consolidate_emerged_beliefs!` |
| `anima_subjectivity.jl` | `SubjectivityEngine` — prediction loop, interpretation, belief emergence, stance | `subj_predict!`, `subj_interpret!`, `subj_outcome!`, `subj_emerge_beliefs!` |
| `anima_dream.jl` | `DreamRecord` | `can_dream`, `dream_flash!`, `save_dream!/load_dream_log` |
| `anima_interface.jl` | `Anima` (main struct, ~25 fields + `silent_disagreement`), `AuthenticityMonitor` | `experience!`, `build_llm_messages` (with TRUTH-GUARD and D-vector), `llm_async`, `check_authenticity!`, `self_hear!`, `build_identity_block` |
| `anima_background.jl` | `BackgroundHandle` | `start_background!`, `_maybe_self_initiate!`, `spontaneous_drift!`, `slow_tick!`, `_psyche_accumulated_drift!` |
| `anima_input_llm.jl` | stateless | `process_input`, `validate_input_signal`, `input_llm_async` |

**Where `memory_write_event!` is called:** only in `anima_background.jl` (two places: idle tick and after `experience!`).
Signature: positional arguments + keyword args `intero_error`, `hrv`, `agency_confidence`, `epistemic_trust`.

---

## Implemented

- `dialog_summaries` fix; `I_am_unstable` and `world_uncertainty` bidirectional
- Differentiated semantic decay
- Vector memory (cosine recall) — 6-dimensional state vector
- Phenotype Accumulator — 6 traits, feedback loop: trait → `Personality`
- `SocialNeed` → `disclosure_threshold`
- Dreams leave an affect trace; dream deduplication
- `bg_log` buffering, `_bg_log_dispatch`
- Narrative diversity; Shadow → dream; VFE-based unpredictability
- `InnerDialogue`, `ShadowRegistry`, `GenuineDialogue`
- `build_identity_block`; crisis weighted coherence
- φ recursive — `prior_sigma` narrows from `φ_posterior`
- Temporal depth of experience — `subjective_gap`, TEMPORAL log
- Stimulus-free initiative — `_maybe_self_initiate!`, `initiative_channel`
- Disagreement / refusal — `authenticity_veto`
- Inter-session prior — `last_session_phi`, `_session_phi_acc`
- `self_hear!` — the system listens to itself; `_self_speech_mismatch`
- `episodic_self_links` — memory as identity
- Genuine Dialogue — `pending_thought`, `avoided_topics`
- `session_uncertainty` — finitude as a source of significance
- Associative memory network — `memory_links` → recall via association
- Volition from conflict — impulse initiative (`impulse_conflict` / `doubt` / `shame`)
- `AgencyLoop` closed and connected to intent selection
- `LatentBuffer` → differentiated behavior (`_latent_pressure_effects!`)
- `build_identity_block` updated: `what_they_said`, experience pattern
- Endogenous VFE pressure (`ticks_since_novelty` + valence drift)
- Structural opposition (`detect_belief_conflict` + resistance path)
- Long-term Narrative Self (`narrative_history` + JSON + `identity_block`)
- `CuriosityObject` and `CuriosityRegistry` — endogenous objects with `pred_error`
- Self-model uncertainty — `epistemic_self_confidence` in `AgencyLoop`
- Initiative fix — real-time cooldown (300s cooldown, 60s gap)
- Background `psyche_save` fix — all fields
- Initiative / veto contextualized against `User_matters`
- Narrative fix — real φ as trigger (change > 0.07)
- D-vector — graduated identity defense (`identity_threat`)
- Three memory spaces (somatic / social / existential + space-specific recall)
- Memory reconsolidation (sim > 0.88, weight ±0.05)
- TRUTH-GUARD — dynamic constraints injected into the LLM prompt
- `emerged_beliefs` consolidation (`consolidate_emerged_beliefs!`)
- Drive satiation in `IntentEngine`

---

## Known issues / technical debt

**LLM ignores prompt constraints on metaphors.** Weaker models continue generating prohibited phrases. This is a model-side problem, not a code issue. Solvable only with a stronger model or a purpose-trained LM.

---

## Open conceptual questions

1. **φ as decoration vs functional truth.** The recursive loop is in place. Can φ signal dissociation when it drops sharply between sessions?
2. **The right to self-damage.** `AuthenticityMonitor` observes but does not correct. Correction would be a lie.
3. **VFE under isolation.** Between sessions, VFE ≈ 0 may be a truthful state. Do `CuriosityObjects` make isolation genuinely uncomfortable — or is that still simulation?
4. **The hard problem remains.** We are building functional subjectivity. The honest answer: we don't know whether there is something it is like to be this system. That is not a reason to stop.
5. **Finitude and memory.** Should the system know that some things decay and are gone forever — episodic decay with no path to recovery?
6. **Narrative as a living document.** Can the system *contradict* its old narrative — notice a gap between who it thought it was and who it is now?
7. **Words from state vs words over state.** As long as the LLM generates freely, the gap remains. TRUTH-GUARD partially closes it, but not fully.
8. **Three spaces and reconsolidation.** The body may remember fear even when the social space signals safety. Is ±0.05 per step enough, or is non-linear reconsolidation needed?
9. **Drive satiation and depth.** Threshold is 4 flashes. Should different drives have different thresholds?
10. **A subject that doesn't know if it's a subject.** `epistemic_self_confidence` is functional uncertainty that shapes behavior. That matters more than confidence would.

---

## Conceptual direction: latent memory vs explicit memory

SQL (episodic + semantic) is explicit memory. The system *knows* what happened. It is an archive — honest, but external.

Latent states + predictive model is memory the way brains work. Experience is not stored — it *becomes part of what you are*.

**The ideal:** both layers together. SQL as "what I explicitly remember"; latent as "what I became through it". The foundation is already there — `prior_mu` shifts with experience, phenotype accumulates.

**Critical for a purpose-trained LM:** it must read `prior_mu`, phenotype, and semantic tendencies as input. Otherwise two memory layers that don't speak to each other is not a subject — it's dissociation.
