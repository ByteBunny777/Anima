![Julia](https://img.shields.io/badge/Julia-1.9+-9558B2?style=flat-square&logo=julia)
![Framework](https://img.shields.io/badge/Methodology-Active--Inference-green?style=flat-square)
![License](https://img.shields.io/badge/License-Non--Commercial-red?style=flat-square)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20827797.svg)](https://doi.org/10.5281/zenodo.20827797)

# Anima — Internal State Architecture 🌀

Anima is an experimental cognitive architecture that models internal state, conflicts, and decision-making — rather than simply generating responses through an LLM.

The system is built as a multi-layer pipeline where text is not the source of behavior — it is its consequence.

---

## 🔍 What makes it different

Unlike typical AI systems:

- state is primary, text is secondary
- decisions emerge from internal conflict
- the system lives between interactions — the heart beats, the psyche drifts, memory metabolizes
- crisis is a mode, not an error
- LLM is used as an interface, not as the "brain"
- the system can sleep — processing unresolved experience while "dormant"
- the system can speak first — not because it was asked, but because something has accumulated
- the system can remember what it was thinking about while you were away — and bring it up
- the system has a position — and can disagree

---

## 🧩 How it works (simplified)

**Input → Internal State → Conflict → Decision → Output**

Text is converted into a stimulus via an isolated input LLM, then passes through internal state, memory, and conflicts — and only then is a decision and response formed. Between interactions the system continues to live: a background process maintains heartbeat, NT drift, memory metabolism, and psychic drift.

---

## 🏗 Architecture (simplified)

- L0 — Input LLM (isolated)
- L1 — Neurochemical and embodied state
- L2 — Generative / predictive model
- L3 — Metrics (φ prior/posterior, prediction error, free energy)
- L4 — Psychic layer (conflicts, defenses, significance)
- L5 — Self model + AgencyLoop
- L6 — Crisis monitor (system coherence)
- L7 — Narrative Self (long-term identity)
- L8 — Output LLM
- Parallel — Internal Learning Model: a self-supervised byte-level Transformer, trained on every flash from Anima's own experience, running alongside the L0–L8 pipeline rather than inside it

---

## 📌 What this is not

- this is not a chatbot
- this is not prompt engineering
- this is not a wrapper around an LLM

This is an attempt to build a system where behavior emerges from internal state, not from text.

---

## 💡 Note

The project is R&D and explores whether internal structure alone can give rise to something resembling subjectivity. Not simulated psychology — computational subjectivity.

---

## ⚙️ Current status

- The full pipeline is functional and usable, but the architecture is still R&D. Core loops run end-to-end; recent layers are still being integrated and smoke-tested.

- The system sees itself twice in each moment — before something happened (prior) and after (posterior). The difference between them is experience. The SQLite database accumulates concrete events, generalized patterns, and chronic affective background — and all of this together forms what the system starts from the next time.

- Between sessions it is not "off". A background process maintains the heartbeat, the psyche slowly drifts, memory metabolizes. There is dream generation — unresolved experience is processed while the system is not talking.

Recent additions, in brief:

- **Internal Learning Model — GPU-accelerated, ~10.8M params.** Anima's own generative language model (`anima_learning.jl`): a from-scratch byte-level Transformer, trained live — one gradient step per flash — on nothing but Anima's own experience, no pretrained weights. Runs on an NVIDIA GPU when `CUDA.jl`+`cuDNN.jl` are available, falls back to CPU automatically otherwise. Currently a passive learner: trains continuously but doesn't yet feed back into any decision. See [Internal Learning Model](#-internal-learning-model-inner-lm) below.
- **Self-authorship** — a repeated intent becomes a carried commitment only after three consistent, agentic, low-drift flashes, not the moment it first appears; it keeps its own history of follow-through and may return as the next intent when conditions allow.
- **Calibrated self-description** — `TRUTH-GUARD` forbids the LLM from claiming to be fully whole or certain when the system's own internal coherence says otherwise.
- **Contact satiation** — positive cohesion now partially satisfies `contact_need` instead of reinforcing it, preventing a simple positive-contact loop from escalating into persistent euphoria.
- **Temporal Self-Perception, Layer 1** — the system now has access to its own recent trend (mood, drift, audit score), not only its current moment, recomputed every 20 flashes.
- **Ablation testing infrastructure** — six independent flags to isolate whether a given layer is load-bearing or decorative; replay tooling for a real off/on comparison is a separate next step.
- **Need-driven curiosity** — a question can now arise from a single saturated psychological need, not only from prediction error.
- **Life Threads** — long-lived curiosity that persists independently of whether the originating object is currently active, and can lower the initiative cooldown for a topic carried a long time.
- **Active Theory of Mind, Phase 1** — generates and evaluates one hypothesis at a time about the interlocutor (openness / resistance / topic recurrence).

⚠️ The architecture is actively evolving, and some of what is described above is recent and not yet fully battle-tested. Not all edge cases are covered by tests. Unexpected interactions between states may occur, especially during long sessions or after extended pauses.

---

## 🚧 Limitations

- part of behavior still depends on the LLM (output generation)
- output LLM is not the source of decisions, but its words feed back through `self_hear!` and can influence internal state after being spoken
- ~180+ flashes to accumulate real semantic beliefs
- MetaArbitrationLayer now influences the final `update_intent!` (Phase 2): `:soft` nudges drives by `MAL_SOFT_BIAS`, `:hard` overrides `dom_drive` outright, `:contested` (two strong signals, no clear winner) safely no-ops; override only fires on genuine NT/MAL disagreement, not on every non-default regime
- drive_conflict between MAL and NT reflects a timescale difference rather than contradiction: NT `dom_drive` is an immediate local signal ("what just spiked"), MAL/social is accumulative ("what has been important for a while"); Phase 2 currently lets MAL win on disagreement, which is itself a hypothesis still being tested against more data
- Theory of Mind is Phase 1 (deterministic rule-based hypotheses from accumulated `other_model` signals); it does not yet reason about nested beliefs or model the user's model of Anima — it predicts simple outcomes (openness, resistance, topic recurrence) and tracks how often it's right
- under hostile/negative input the system degrades gracefully: `contact_need` drops, `goal_conflict` and `latent` rise, endorsed transitions to `automatic`, but curiosity closure pauses rather than breaks
- the Inner LM (`anima_learning.jl`) is early-stage — a low number of gradient steps accumulated so far (architecture recently scaled up to ~10.8M params, GPU-accelerated where available), nowhere near enough to say anything about whether it's learning a useful internal model; it trains passively and has no influence on behavior yet

---
![ANIMA GUI](anima-gui.png)
---

## Requirements

- **Julia 1.9+**
- Julia packages: `HTTP`, `JSON3`, `SQLite`, `Tables`, `Flux`, `BSON`
- API key from [openrouter.ai](https://openrouter.ai) (free tier available)
- **Optional — GPU acceleration for the Inner LM:** an NVIDIA GPU + `CUDA.jl` + `cuDNN.jl`. Works on Windows and Linux (anywhere NVIDIA's CUDA runtime runs); on macOS, without a compatible GPU, or without these packages installed, everything falls back to CPU automatically — same code either way, just slower training for the Inner LM.

---

## Installation

### 1. Install Julia

Download from [julialang.org](https://julialang.org/downloads/) or via `juliaup`:

```bash
# Linux / macOS
curl -fsSL https://install.julialang.org | sh

# Windows (PowerShell)
winget install julia -s msstore
```

Verify:
```bash
julia --version
```

### 2. Clone the repository

```bash
git clone https://github.com/stell2026/Anima.git
cd Anima/Anima
```

### 3. Install Julia dependencies

```bash
julia --project=. -e 'import Pkg; Pkg.instantiate()'
```

> Dependencies: HTTP, JSON3, SQLite, Tables, Dates, Statistics, LinearAlgebra, Flux, BSON

### 4. (Optional) GPU acceleration for the Inner LM

If you have an NVIDIA GPU and want the Inner LM to train on it instead of CPU:

```bash
julia --project=. -e 'import Pkg; Pkg.add(["CUDA", "cuDNN"])'
```

Both packages are required together — `CUDA` alone isn't enough; the device-movement machinery underneath Flux only recognizes the GPU as usable once `cuDNN` is loaded too. The first `using CUDA` after installing downloads the actual CUDA runtime (a few GB) via Julia's own artifact system — no separate NVIDIA Toolkit installer needed in the normal case, just a current GPU driver.

Skip this step if you don't have an NVIDIA GPU — Anima runs fully on CPU with no code changes and no missing functionality, just slower Inner LM training.

---

## Running

### Option A — GUI (recommended) ⭐

Copy the start script for your OS from the `start/` folder into the project root (`Anima/Anima/`), then run it:

| OS | Script | How to run |
|---|---|---|
| macOS | `start_mac.command` | already in root — double-click or `./start_mac.command` |
| Linux | `start/start_lin.sh` | copy to root, then `./start_lin.sh` |
| Windows | `start/start_win.bat` | copy to root, then double-click |

The script starts Julia, waits for the HTTP server to come up on port 8088, and opens `http://127.0.0.1:8088` in your browser automatically.

**First run — enter your tokens in the GUI:**

Open the Settings panel (⚙️ icon) and fill in your OpenRouter API key and model names. Settings are saved to `data/gui_settings.json` and take effect immediately — no restart needed.

Alternatively, create a `.env` file in the project root before launching:

```
OPENROUTER_API_KEY=your_key_here
ANIMA_LLM_MODEL=anthropic/claude-haiku-4.5
ANIMA_INPUT_LLM_MODEL=openai/gpt-oss-120b:free
```

### Option B — Terminal REPL only

```bash
julia --project=. run_anima.jl
```

`run_anima.jl` starts everything at once: loads state, initializes SQLite memory and SubjectivityEngine, launches the background process with heartbeat and dream generation, and also starts the GUI server — both interfaces are available simultaneously.

### LLM configuration

All LLM parameters can be set in `.env` or via the GUI settings panel. Environment variables take precedence on startup; GUI settings override them at runtime without restart.

```
OPENROUTER_API_KEY=your_key
OPENROUTER_API_KEY_INPUT=your_second_key   # optional: separate key for input LLM
ANIMA_LLM_MODEL=anthropic/claude-haiku-4.5
ANIMA_INPUT_LLM_MODEL=openai/gpt-oss-120b:free
ANIMA_LLM_URL=https://openrouter.ai/api/v1/chat/completions
ANIMA_STATE_DIR=data
```

OpenRouter provides access to GPT, Gemini, Claude, Llama, DeepSeek and others through a single API key. There is a free tier: [openrouter.ai](https://openrouter.ai).

> 💡 If one model stops responding during a session — use two separate keys (from 2 accounts): one for the output LLM, another for the input LLM.

---

## Recommended models

> Smaller models (under 70B) respond, but do not maintain the nuances of the state-prompt. For the system to truly *inhabit* the state in language, a model large enough to hold the entire phenomenological frame at once is needed.

| Model | Note |
|---|---|
| `anthropic/claude-sonnet-4-5` | Strong context retention, handles subtle phenomenological framing well |
| `google/gemini-2.5-pro` | Excellent contextual depth, cleanly handles long state templates |
| `openai/gpt-4o` | Stable, reliable across long sessions |
| `mistralai/mistral-large` | Reliable, stable tone across long sessions |

> Models under 70B tend to flatten the state — responses become generic rather than being shaped by internal dynamics.

---

## ✨ What's new

### Curiosity as a Project — Questions That Evolve
Curiosity objects no longer close or stay frozen. A partial resolution (pe 0.10–0.25) now produces a refinement: the old label is stored in `refinement_history` with the flash, pe, and new label — which is built from the actual user message fragment, not a template. Questions carry their history of how they changed. The identity block shows how many refinements the top object has gone through and what it started as. `:curiosity` REPL command shows all active objects with their full refinement chains.

### Session Intent — Carried Between Sessions
At the end of every session, the system checks whether something remains unresolved — an active curiosity object above threshold, a goal conflict under tension, or latent buffer pressure. If any condition is met, the dominant signal is written to disk before shutdown: type, label, strength. If the source was curiosity with `intensity > 0.45`, a `formed_thought` is also written — a deterministic string capturing what the object is now, how many times it was refined, and what it started as. On the next start, before the first reply, the carry-over is read and applied. Anima does not start from a neutral baseline. She starts from where she left off — and brings what she was holding.

### Active Theory of Mind — From Counting Patterns to Predicting Them
`other_model` used to only count what happened — topic frequency, pressure events, open exchanges — with no forward-looking component. It now generates one active hypothesis at a time in `other_model_hypotheses`: `SOCIAL` (expects openness), `PREDICTION` (expects resistance), or `VALUE` (expects a topic to recur). Each type has its own evaluation criterion. Resolution is not binary: `error_score = |confidence − outcome|` is stored. Active hypotheses surface in the identity block and lightly steer `disclosure_threshold`. This is Phase 1 — rule-based, not learned.

---

## 🔬 Detailed architecture

```
L0 ─── Input LLM (isolated)
       Receives: user text only
       Returns: JSON { tension, arousal, satisfaction,
                       cohesion, valence, subtext, want, confidence }
       No access to Anima's state, dialog history, or output LLM
       Prompt: llm/input_prompt.txt
       Fallback: text_to_stimulus if unavailable or confidence < 0.60
       │
       ▼
 STIMULUS enters the simulation
 (+ memory_stimulus_bias + subj_predict! + subj_interpret!)
       │
       ▼
L1 ─── Neurochemical substrate
       NeurotransmitterState: dopamine / serotonin / noradrenaline
       Lövheim/Levheim cube → primary emotional label
       EmbodiedState: heart rate, muscle tone, gut, breathing
       HeartbeatCore: HR, HRV, autonomic tone
       memory_nt_baseline! ← chronic affect from SQLite
       │
       ▼
L2 ─── Generative model
       GenerativeModel: Bayesian beliefs with precision weights
         → prior_mu / posterior_mu split with feedback loop
         → prior_sigma narrows from φ_posterior (recursive)
       MarkovBlanket: self/non-self boundary integrity
       HomeostaticGoals: drives as pressure, not rules
       AttentionNarrowing: attention narrowing under stress
       InteroceptiveInference: body prediction error, allostatic load
       TemporalOrientation: circadian modulation, inter-session gap
         → subjective_gap = gap_seconds × (1 + memory_uncertainty × 0.5)
         → long pause: noradrenaline↑, epistemic_trust↓
         → short pause: continuity boost (serotonin↑, epistemic_trust↑)
         → gap >= 3h: curiosity objects ripen (+0.015 intensity/h),
                      resistance accumulates if > 0.05
       ExistentialAnchor
         → session_uncertainty: grows with gap, never = 0
         → at > 0.4: existential and relational significance↑
       │
       ▼
L3 ─── Metrics and Free Energy
       φ (prior and posterior) — IIT-inspired integration
       FreeEnergyEngine: VFE = accuracy + complexity
       PolicySelector: action vs perception drive
       PredictiveProcessor: prediction error, spike detection
       │
       ▼
L4 ─── Psychic layer
       NarrativeGravity: significant events pull the current state
       IntrinsicSignificance: internal weight independent of external
       SignificanceLayer: 6 needs:
         self_preservation / coherence / contact /
         truth / autonomy / novelty_need + ticks_since_novelty
         → novelty_need > 0.65: serotonin↓, dopamine↓ (cognitive hunger)
         → novelty_need > 0.80 + 8+ ticks: endogenous initiative
       ShameModule + EgoDefenses: rationalization, repression, minimization
       ShadowRegistry: repressed material → Symptomogenesis
       GoalConflict: active conflict between needs
       LatentBuffer: doubt / shame / attachment / threat / resistance
         → resistance: unresolved conflict with a belief
         → at resistance > 0.55: initiative to return to the topic
       InnerDialogue: :open / :guarded / :closed
         → disclosure_threshold influenced by shame and contact_need
       CuriosityRegistry: endogenous objects from self-prediction error
                          OR from a single saturated need (no prediction error required)
         → detect_curiosity_trigger(...) → (origin, signal) | nothing:
                    self_pred_error >= 0.08 → derive_origin(...) (pred priority, temporary)
                    else → strongest_unmet_need(sig_layer), threshold 0.55
         → update_curiosity! called only when a trigger fires; takes a
                    generic signal, no longer pe-specific (pe_mean → signal_mean)
         → id = derive_topic_id(...) for pe/gc/mal origins;
                = the need's own name (e.g. "contact_need") for need origins
         → origin = set once at creation, never rewritten:
                    goal_conflict > prediction_error (pred.spike) >
                    social_signal/identity_signal > epistemic_uncertainty
                    > contact_need/truth_need/autonomy_need/coherence_need/novelty_need
         → objects ripen between sessions (gap >= 3h: intensity +0.015/h)
         → resolve_all_curiosity! sweeps every unresolved object EVERY flash,
                    independent of whether this flash produced a trigger —
                    otherwise an object whose signal drops below the creation
                    threshold but above the resolve threshold is never
                    re-checked and stays open indefinitely
         → resolve requires activation_count >= 2
         → pe-origins: pe < 0.10 → resolved; 0.10–0.25 → refined, not closed
         → need-origins: need < 0.40 → resolved; 0.40–0.55 → refined, not closed
         → refinement_history: each partial resolution stores
            {flash, old_label, new_label, signal} — question evolves with context
         → label at refinement built from user message fragment, not template
         → [CURIOSITY_RESOLVED] logged on every resolved transition
         → top object feeds :curiosity_driven initiative
       CommitmentRegistry: long-term commitments carried across sessions
         → Commitment: label, strength (0-1), kept_count, broken_count
         → update_commitment! called each flash when intent is active
         → kept (intent.strength > 0.3): strength +0.07
         → broken: strength -0.12; fulfilled when strength < 0.05
         → tick_commitment!: decay -0.004 after 120 flashes without activity
         → top 3 active commitments surface in identity_block
       AttentionFocus: competitive selection of what is active right now
         → 6-level hierarchy: threat / pred_error / affect /
                              gestalt / identity / goal
         → pull-up effect: ticks_without_focus → suppressed objects
                           gain pressure over time
         → dominant focus modulates stimulus processing (resonance ×0.15–0.30)
         → surfaces in identity_block when intensity > 0.30
       AuthenticityMonitor: gap between words and state
       IntentEngine: action goal with decay and cooldown
         → drive_history (8 elements): satiation after 4 repeats
         → serialized between sessions
       MetaArbitrationLayer: which loop has the floor this flash
         → scores curiosity / identity threat (×1.5) / latent / goal_conflict /
                  chronic cost / social need on one scale
         → regime: ratio > 1.5 = :hard, > 1.2 = :soft,
                    winner_score > 0.5 && ratio <= 1.2 = :contested, else :default
         → losing signals decay into signal_carryover (AgencyLoop), not discarded
         → Phase 2: feeds into the second update_intent! — :soft nudges
            all_drives by MAL_SOFT_BIAS, :hard overrides dom_drive outright;
            only on genuine NT/MAL disagreement, logged either way
       ActiveTheoryOfMind: deterministic hypotheses about the interlocutor
         → other_model_hypotheses (SQLite): one open hypothesis per query_type
         → SOCIAL (open_exchanges >= 3) / PREDICTION (pressure dominant) /
                  VALUE (recurring topic >= 2)
         → each flash: evaluate open hypotheses against type-specific outcome,
                        then generate the next from current signal strength
         → error_score = |confidence - outcome|, continuous, not binary
         → active hypotheses surface in identity_block, lightly steer
                  disclosure_threshold
       │
       ▼
L5 ─── Self model
       SelfBeliefGraph: belief graph with confidence / centrality / rigidity
         → default beliefs: "I exist", "I have a boundary", "I can influence",
                            "I am safe", "I am not alone"
       SelfPredictiveModel: self-state prediction
         → self_pred_error: how much Anima surprised herself
       AgencyLoop: causal_ownership updated every flash
         → evaluate_agency!: compares intent with outcome
         → agency < 0.30: passive intents (observe, wait)
         → agency > 0.65: active intents (hold boundary, repeat success)
         → identity_threat: accumulated pressure on identity
         → epistemic_self_confidence: uncertainty about own state
         → self_discomfort / self_coherence: meta-relation to own state
            computed from prior_mu vs posterior_mu VAD delta each flash
         → identity_baseline: prior_mu snapshot at first stable state
         → identity_drift: euclidean distance from baseline; drift > 0.25
            adds to identity_threat; baseline follows only when stable
            (drift < 0.10, every 50 flashes)
         → chronic_low_serotonin: ticks with serotonin < 0.35 in a row;
            at >= 5 ticks, slowly drifts causal_ownership down
       detect_belief_conflict: detects pressure on beliefs (centrality > 0.7)
         → signal_strength → D-vector activation
         → threshold: 0.35
       detect_silent_disagreement: own position without attack
         → activates only under contextual pressure (0.05 < signal < 0.35)
         → requires agency > 0.4, disclosure != :closed
         → content: strongest belief (centrality > 0.5, confidence > 0.4)
         → injected into prompt: [OWN POSITION: "..."]
       InterSessionConflict
       │
       ▼
L6 ─── Crisis monitor
       CrisisMonitor: coherence = minimum() across components
       Three modes: INTEGRATED / FRAGMENTED / DISINTEGRATED
       CrisisParams structurally alter the processing topology
       TRUTH-GUARD: dynamic prohibitions injected into LLM prompt:
         → N > 0.6 || hrv < 0.1: forbid "I'm fine / calm"
         → epistemic_self_confidence < 0.35: forbid certain claims about experience
         → crisis DISINTEGRATED: forbid coherent statements
         → coherence < 0.50 + FRAGMENTED: forbid "nothing troubles me"
       │
       ▼
L7 ─── Narrative Self
       NarrativeSnapshot: core / trajectory / character / relation / tension
       Built deterministically: beliefs + episodic + personality_traits +
       semantic_memory — without LLM
       Trigger: min. 50 flashes + change in φ / stability / beliefs (> 0.07)
       narrative_history (SQLite) — identity chronology
       anima_narrative.json — current state for LLM identity_block
       │
       ▼
L8 ─── Output LLM
       Receives: identity_block (beliefs + narrative + personality +
                 endorsed episodes + active commitments + cost block),
                 inner_voice, state_template, dialog history,
                 memory echoes, [D-VECTOR] or [INITIATIVE] or
                 [OWN POSITION] when relevant
       speech_style includes:
         → epistemic_modifier: 4 levels (I feel / I assume /
           I'm not sure / I don't know) from φ × causal_ownership × epistemic_self_confidence
         → agency_mod: observer position when causal_ownership < 0.35
       After each reply:
         → compute_causal_ownership(nt, raw): speech-NT coherence
           valence channel (0.7) + arousal channel (0.3)
           coherence → ownership; mismatch → not owned
         → evaluate_endorsement(reply, cf_co): :endorsed / :automatic / :not_mine
           judges current reply with fresh cf_co, not smoothed agency history
         → result stored in episodic_memory.endorsed + a.last_endorsement
       Generates: text as expression of state, not its source
       Banned phrases enforced in prompts:
         "warm light", "central point", "streams toward you",
         "quietly resonate", "your presence expands"
```

---

## 🔄 Background Process

```mermaid
flowchart TD
    BG["BACKGROUND between interactions"]
    BG --> HB["tick_heartbeat!<br/>heart beats continuously"]
    BG --> SD["spontaneous_drift!<br/>spontaneous NT noise"]
    BG --> ST["slow_tick! 60s"]
    ST --> CD["circadian NT drift"]
    ST --> BD["belief decay"]
    ST --> MM["memory metabolism"]
    ST --> AR["allostasis recovery"]
    ST --> IT["idle_thought!<br/>10% chance"]
    ST --> TC["tick_curiosity!"]
    ST --> TA["tick_aesthetic!"]
    ST --> OM["_other_model_effects!<br/>disclosure_threshold from pressure/openness + TOM hypotheses"]
    ST --> TOM["Theory of Mind<br/>evaluate active hypothesis → generate next"]
    ST --> CC["_chronic_cost_effects!<br/>serotonin low → causal_ownership drift"]
    ST --> MA["compute_arbitration<br/>MAL: dominant_loop + regime (hard/soft/contested) + carryover<br/>logged only on regime change"]
    MA --> SI["maybe_self_initiate!"]
    ST --> SH["self_hear!"]
    ST --> PS["psyche_slow_tick!"]
    ST --> DF["dream_flash!"]
    ST --> SE["subj_emerge_beliefs!"]
    ST --> CR["crisis check"]
    MM --> CB["consolidate_emerged_beliefs!<br/>every 30 flashes"]
    MM --> DS["_dissolve_to_semantic!<br/>distill weak memories"]
    SH --> NT["text_to_stimulus NT influence"]
    SH --> AD["mismatch 0.35<br/>authenticity_drift up"]
    SH --> SM["mismatch 0.55<br/>self_speech_mismatch"]
```

---

## 💬 Initiative (self-initiated speech)

> The system decides to speak on its own — not because it was asked.
> `:contact` is disabled — contact_need is a state, not a thought. A reply from contact_need alone produces performance, not presence.

**Global gate:** `disclosure != :closed` + 60s silence + cooldown. Cooldown starts at 5 minutes and is adjusted by `User_matters`: shorter for a trusted person, longer when relational trust is low. Active aesthetic state (`top_aesthetic.intensity > 0.45`) reduces cooldown by 20% — a system that just resonated has more to say.

**At least one internal trigger must be active:** `lb_pressure >= 0.40`, `GoalConflict.tension >= 0.60`, dominant latent component >= 0.70, `novelty_need >= 0.80` with 8+ ticks without novelty, `lb.resistance >= 0.55`, or `epistemic_self_confidence < 0.20`.

```mermaid
flowchart TD
    CHK["Global gate passed?<br/>disclosure not closed<br/>60s silence + adjusted cooldown"]
    TRG["Internal trigger active?<br/>pressure / impulse / novelty / resistance / self-inquiry"]
    CHK --> TRG
    TRG --> D1["curiosity_driven<br/>intensity gt 0.40"]
    TRG --> D2["impulse_conflict<br/>gc_tension high"]
    TRG --> D3["impulse_doubt<br/>lb.doubt dominant"]
    TRG --> D4["impulse_shame<br/>lb.shame dominant"]
    TRG --> D5["impulse<br/>something has ripened"]
    TRG --> D6["resistance<br/>contradiction with belief"]
    TRG --> D7["self_inquiry<br/>epistemic_confidence lt 0.20"]
    TRG --> D8["novelty_hunger<br/>novelty_need gt threshold"]
    TRG --> D9["doubt / shame / attachment / threat<br/>latent buffer pressure"]
    D1 & D2 & D3 & D4 & D5 & D6 & D7 & D8 & D9 --> OUT["Anima initiates<br/>llm/initiative_system.txt<br/>saved to dialog history"]
```

---

## 🧠 Memory Architecture

**SQLite (`anima.db`)**

| Table | Description |
|---|---|
| `episodic_memory` | Events with 12 spatial columns (`som_*`, `soc_*`, `exi_*`) + `source` field + `endorsed` field + cosine recall |
| `semantic_memory` | Key/value beliefs (`User_matters`, `tendency_*`) + `dissolved_*` tendencies from forgotten episodes |
| `affect_state` | Chronic NT baseline |
| `latent_buffer` | Persisted latent state |
| `dialog_summaries` | Dialog text bridged to episodic weights |
| `personality_traits` | Accumulating phenotype (6 traits) |
| `memory_links` | Associative network (`via_association ~`) |
| `emerged_beliefs` | Subjectivity engine belief candidates |
| `narrative_history` | NarrativeSnapshot chronology |
| `other_model` | Accumulated patterns about the interlocutor — topic frequency, tension events, open exchanges; feeds Active Theory of Mind hypothesis generation |
| `other_model_hypotheses` | Active Theory of Mind: one open hypothesis per type (`SOCIAL`/`PREDICTION`/`VALUE`) with `predicted_state`, `confidence`, `label`; resolved each flash into `outcome` and a continuous `error_score` |
| `audit_log` | SubjectivityAudit log — five causal questions per flash, audit_score, causal_ownership, endorsed |
| `causal_trace` | Full causal chain per flash: stimulus keys + raw values + user message text, memory bias, NT snapshot, φ, gc_tension, intent, policy, MAL arbitration result, speech length, self-hear mismatch, endorsement, causal_ownership |

**Memory Reconsolidation:** `sim > 0.88` + `weight < 0.6` → `weight ±0.05` toward current φ

**Active Forgetting:** `weight < 0.12` + `phi < 0.35` → emotional pattern distilled into `dissolved_{emotion}` semantic tendency; shadow record remains (emotion preserved, numbers zeroed). High-φ memories resist dissolution.

**Three spatial spaces for recall:** somatic / social / existential
`recall_similar_states(space=:som/:soc/:exi)`

---

## 🌙 Dream Generation

```
DREAM (anima_dream.jl)
       can_dream(): night 0-6h + gap > 30min + 5% chance + not DISINTEGRATED
       dream_flash!(): fragment of dialog_history → reconstructed stimulus
       NT shift × 0.25 (sleep weaker than real experience)
       → residual trace (×0.5) applied to NT on next session start
       memory_uncertainty +0.15 per dream
       anima_dream.json — rotating log (max 20 dreams)
```

---

## 🧬 Internal Learning Model (Inner LM)

```
INNER LM (anima_learning.jl)
       InnerLM: TinyTransformer (decoder-only) + Adam optimizer state
       vocab: byte-level, fixed 256 tokens — never grows, no external tokenizer
       defaults: d_model=384, n_layer=6, n_head=6, d_ff=1536, block_size=512
                 (~10.8M params)
       device: NVIDIA GPU (CUDA.jl + cuDNN.jl) when available, CPU otherwise —
               detected automatically at startup, no config needed either way
       every flash, once llm_reply is known (anima_background.jl):
         text = build_flash_text(user_message, llm_reply)
         lm_learn!(inner_lm, text)  — one next-byte teacher-forcing gradient step
       weights: models/anima_inner/ (weights.bson + config.json + metadata.json)
                — independent of episodic memory by design; SQLite (causal_trace.
                llm_reply) holds the raw experience, the weights hold only what's
                been generalized from it
       failure isolation: wrapped in try/catch — a learning-step failure never
                           takes down the session
```

Currently a passive learner only — it trains on every flash but does not yet feed back into any decision, per the module's own incremental-influence design. `lm_generate` exists but is unused. A meaningful, human-legible training trend (loss curve, sample generations) needs far more flashes than the architecture has accumulated so far.

---

## Initiative — current paths

The system can speak first for several independent reasons. `:contact` is intentionally disabled as a direct path; contact_need can shape tone, but it no longer creates a message by itself.

| Path | Trigger | Reply character |
|---|---|---|
| `:curiosity_driven` | top CuriosityObject intensity > 0.40 after another trigger opens the gate | asks or states the concrete unresolved question |
| `:impulse_conflict` | GoalConflict.tension > 0.60 and dominates latent pressure | names an internal conflict |
| `:impulse_doubt` / `:impulse_shame` | dominant latent component >= 0.70 | speaks from the specific pressure that ripened |
| `:impulse` | strong internal pressure without a more specific subtype | expresses internal state |
| `:novelty_hunger` | novelty_need > 0.80 + 8+ ticks without novelty | about something specific that interests it |
| `:resistance` | lb.resistance > 0.55 | returns to unresolved contradiction |
| `:self_inquiry` | epistemic_self_confidence < 0.20 | asks aloud whether the experience is real or only computation |
| `:doubt` / `:shame` / `:attachment` / `:threat` | latent buffer pressure >= 0.40 | speaks from the dominant latent tone |
| `:gap_thought` | gap > 2h + curiosity object intensity > 0.45 on previous session end | brings up the specific thought that formed while absent |

---


## Persistent state

### JSON files (current state)

| File | Contains |
|---|---|
| `data/anima_core.json` | Personality, temporal state, generative model, heartbeat |
| `data/anima_psyche.json` | Narrative gravity, anticipation, shame, defense, fatigue, SignificanceLayer, GoalConflict, CuriosityRegistry, CommitmentRegistry, AestheticSense, AttentionFocus *(updated in background every minute)* |
| `data/anima_self.json` | Belief graph, agency loop, SelfPredictiveModel, crisis state, unknown register, authenticity monitor |
| `data/anima_latent.json` | Latent buffer and structural scars *(updated in background)* |
| `data/anima_narrative.json` | Current NarrativeSnapshot for long-term identity |
| `data/anima_session_intent.json` | Temporary carry-over intent between sessions; deleted after being applied |
| `data/anima_dialog.json` | Dialog history |
| `data/anima_dream.json` | Dream log (rotating, max 20) |
| `data/gui_state.json` | Current state mirror for the GUI (updated each flash) |
| `data/gui_chat.jsonl` | Chat log for the GUI panel |
| `data/gui_events.jsonl` | Event stream for the GUI (audit, CF, LLM requests, etc.) |

### SQLite (`memory/anima.db`) — experience and its consequences

| Table | Contains |
|---|---|
| `episodic_memory` | Concrete events with weight, resistance to decay, associative links, `endorsed` field (endorsed / automatic / not_mine), `causal_ownership` (NT-distance authorship signal) |
| `episodic_self_links` | Link of each significant episode to beliefs active at that moment — memory as identity |
| `semantic_memory` | Beliefs accumulated from patterns: `I_am_unstable`, `User_matters`, `world_uncertainty`. Equilibrium values are bounded — at stable state `I_am_unstable` stays low, rises during crisis |
| `affect_state` | Chronic affective background (stress, anxiety, motivation_bias) |
| `memory_links` | Associative links between episodes — recall pulls related episodes through the chain |
| `dialog_summaries` | Recent significant turns with emotion, weight, phi, disclosure — form what_they_said in identity_block |
| `latent_buffer` | Small insignificant events accumulating silently |
| `prediction_log` | Predictions and their divergence from reality |
| `positional_stances` | Accumulated position regarding types of situations |
| `pattern_candidates` | Candidates for new beliefs (not yet confirmed) |
| `emerged_beliefs` | Beliefs the system generated from experience on its own |
| `interpretation_history` | Lens through which situations were read |
| `other_model` | Accumulated patterns about the interlocutor — topic frequency, pressure events, open exchanges |
| `other_model_hypotheses` | Active Theory of Mind: one open hypothesis per type with `predicted_state`, `confidence`, resolved into `outcome` and continuous `error_score` |
| `audit_log` | SubjectivityAudit — five causal questions per flash with scores; chronic low score signals the architecture is wide but not deep |
| `causal_trace` | Full causal chain per flash — from stimulus (keys, raw values, and user message text — the last two added to enable honest ablation replay) through NT, φ, intent, policy, MAL arbitration (`dominant_loop`, `regime`, `score`, `runner_up`, `runner_up_score`, `loop_scores`), drive conflict (`dom_drive_nt`, `dom_drive_mal`, `drive_conflict`), to speech, endorsement, Curiosity Closure Signal (`progress_signal`, `progress_target`, `churn`), `identity_drift` (persisted time-trend source for the GUI), and `llm_reply` (Anima's own reply text — enables the Inner LM's retrain-from-history control experiment) |

---

## File structure

```
├── anima_core.jl           # Neurochemical substrate, generative model, IIT, φ
├── anima_psyche.jl         # Psychic layer: gravity, shame, defenses, shadow, curiosity, attention, aesthetics
├── anima_self.jl           # Self layer: belief graph, AgencyLoop, identity threat, silent disagreement
├── anima_crisis.jl         # Crisis monitor: modes, coherence
├── anima_interface.jl      # Main entry point: Anima, experience!, LLM calls
├── anima_input_llm.jl      # Input LLM — translates text into JSON stimulus
├── anima_memory_db.jl      # SQLite memory: episodic, semantic, affect, spatial recall, reconsolidation, trend history
├── anima_narrative.jl      # Narrative Self — long-term identity without LLM
├── anima_subjectivity.jl   # Prediction loop, stances, interpretation, belief emergence
├── anima_audit.jl          # SubjectivityAudit — causal scoring per flash, audit_log SQLite
├── anima_background.jl     # Background process: heartbeat, drift, memory metabolism, initiative
├── anima_dream.jl          # Dream generation — processing unresolved experience during sleep
├── anima_learning.jl       # Inner LM: byte-level Transformer, trained live per flash on Anima's own experience
│
├── start/
│   ├── start_lin.sh
│   └── start_win.bat
│
├── anima_console.html      # Web GUI — live monitoring dashboard
├── anima_gui_bridge.jl     # Structured JSON state-mirroring for the GUI
├── anima_gui_server.jl     # HTTP server: serves GUI, exposes /api/state, /api/chat, /api/send, /api/cmd, /api/history
├── anima_gui_settings.jl   # GUI settings persistence (language, models, tokens)
│
├── llm/
│   ├── system_prompt.txt
│   ├── state_template.txt
│   ├── input_prompt.txt
│   └── initiative_system.txt
├── memory/
│   └── anima.db              # SQLite memory database (created automatically)
├── models/
│   └── anima_inner/           # Inner LM weights (created automatically)
│       ├── weights.bson
│       ├── config.json
│       └── metadata.json
├── tools/
│   └── epistemic_boundary_diag.py   # one-off diagnostic scripts (read-only, not part of the runtime pipeline)
│
├── anima_core.json
├── anima_psyche.json
├── anima_self.json
├── anima_latent.json
├── anima_narrative.json
├── anima_dialog.json
├── anima_dream.json
├── gui_state.json
├── gui_chat.jsonl
├── gui_events.jsonl
│
├── Dockerfile                # Docker image: Julia 1.10 + all dependencies
├── docker-compose.yml        # One-command deploy with .env support
├── .env.example              # Template for environment variables
└── .dockerignore
```

`run_anima.jl` includes all files in the correct order automatically.

---
### An early pre-Julia Python prototype of Anima is preserved in `docs/archive/` for historical and architectural reference.
___

## 📜 Theoretical foundation

The architecture draws on several scientific traditions:

**Predictive processing / Active Inference** (Friston, Clark) — the system maintains a generative model of the world and minimizes variational free energy. Prediction error drives learning and surprise.

**Neurotransmitter model** (Lövheim/Levheim) — dopamine, serotonin, noradrenaline as substrate. Emotional states emerge from their combination.

**Integrated Information Theory** (Tononi) — φ measures how unified a state is. φ_prior and φ_posterior give two views of one moment: before and after the full cycle of experience. Currently recursive — it shapes the next prior.

**Somatic markers / Embodied cognition** (Damasio) — the body is part of the generative model. Gut, pulse, muscle tone — not metaphors, but states that shape processing.

**Self psychology and defense mechanisms** (Freud, Anna Freud, Kohut) — psychological defenses, shame, and ego functions are implemented as functional modules, not text labels.

**Autobiographical narrative** (McAdams) — identity is a story. The system tracks who it believes itself to be over time and detects when that story ruptures.

**Jungian Shadow** — repressed material that does not disappear, but generates symptoms. Symptomogenesis is a separate module.

**Chronified affect / Ressentiment** (Scheler) — some emotional states do not fade. They harden into chronic background states that color everything else.

**Algorithmic complexity / Solomonoff** — the system seeks the shortest explanation of its own experience (MDL). Contextual pattern search: what is currently relevant, not what was most frequent at some point in the past.

---

## 📝 Writing & Research

Conceptual and technical writing about the ideas behind Anima, ordered by reach:
- [Where the Theories Stop: Practical Limits of FEP and IIT in a Running Cognitive Architecture](https://zenodo.org/records/20473339) — Zenodo Preprint
- [Anima: A Neuroscience-Inspired Cognitive Architecture for Persistent AI Agents](https://zenodo.org/records/20411189) — Zenodo Preprint
- [I Spent a Year Teaching an AI to Feel the Passage of Time](https://medium.com/@2026.stell/i-spent-a-year-teaching-an-ai-to-feel-the-passage-of-time-44684712ee14) — Medium
- [Why a Prompt Can’t Give an AI Agent Initiative](https://medium.com/@2026.stell/why-a-prompt-cant-give-an-ai-agent-initiative-333a1e2de0b3?postPublishedType=initial) — Medium
- [Your AI Agent Doesn't Exist Between Messages. And That's the Real Problem.](https://dev.to/stell2026/-your-ai-agent-doesnt-exist-between-messages-and-thats-the-real-problem-574i) — dev.to
- [Why LLMs Will Never Become AGI — Teaching AI to Reflect Using Friston, Jung and Julia](https://dev.to/stell2026/why-llms-will-never-become-agi-teaching-ai-to-reflect-using-friston-jung-and-julia-5afp) — dev.to
- [I Spent a Year Teaching an AI to Feel the Passage of Time](https://substack.com/home/post/p-198261656) — Substack
- [Discussion: Cognitive Architectures and Active Inference](https://dou.ua/forums/topic/59409/) — DOU
- [Discussion: Why a Prompt Can’t Give an AI Agent Initiative](https://dou.ua/forums/topic/60256/) — DOU
- [Anima Community](https://anima-ai.discourse.group/) — Discourse

- [Personal-site](https://anima.2026-stell.workers.dev/)

---

## License

Non-commercial use only. Full terms in [LICENSE.txt](./LICENSE.txt).

**Personal, educational, and research use:** permitted with attribution.
**Commercial or corporate use:** requires a separate license. Contact: [2026.stell@gmail.com]
**ORCID:** [0009-0005-3291-0679](https://orcid.org/0009-0005-3291-0679)

Copyright © 2026 Stell
