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

Recent updates, in brief:

- **Self-authorship — intent can become a carried commitment.** A repeated intent is not treated as "mine" the moment it appears. `SelfAuthorship` promotes it only after three consistent, significant, sufficiently agentic flashes with low authenticity drift. An active authored commitment keeps its own history of follow-through, deviations, stake, and release; it may gently return as the next intent when agency is adequate and tension is not acute. It is serialized in `anima_self.json`, displayed in the GUI as `authored_goal` / `authored_stake`, and injected into the output LLM context as a direction rather than a completed action. The background cycle decays stale commitments and performs a bounded reflection on autonomy and integrity — no one flash can rewrite core values.

- **Calibrated self-description.** The LLM prompt now receives `self_coherence`, `self_discomfort`, and `authenticity_drift` in addition to crisis coherence. When the system is not internally aligned, `TRUTH-GUARD` forbids claims such as being fully whole, certain, or treating an emotional interpretation as an indisputable fact. This is deliberately a language constraint, not a claim that the architecture can verify phenomenal experience.

- **Contact satiation and social habituation.** Positive cohesion now partially satisfies `contact_need` instead of reinforcing it. Self-hearing still lets an endorsed warm reply affect the state, but the D/S reward is scaled down as dopamine and serotonin approach saturation. This prevents a simple positive-contact loop from escalating into persistent euphoria while keeping contact meaningful.

- **Durable background state.** Background saves now retain `CommitmentRegistry`, life threads, the intent engine, and self-authorship alongside the existing psyche and self state; an interrupted session no longer loses these long-lived structures.

- **Temporal Self-Perception, Layer 1 — trajectory, not just current state.** `identity_drift` and `audit_score` were already being persisted to `causal_trace`/`audit_log` for the GUI (see "Time trends made honest" below), but only as an external view — Anima herself had no access to her own trend, only to the current moment. `TemporalTrend` (new field on `AgencyLoop`) now aggregates that same data from the inside: every 20 flashes, `_update_temporal_trend!` reads the last 40 rows of `causal_trace`/`audit_log`, splits them into two equal windows, and stores the delta (recent avg − older avg) for serotonin, dopamine, noradrenaline, `identity_drift`, and `audit_score`, plus `endorsed_rate` over the recent window. `build_identity_block` surfaces this as a single `[тренд: ...]` line, only when a signal crosses threshold (e.g. `endorsed_rate < 0.40`, `|d_audit_score| > 0.05`, `|d_identity_drift| > 0.08`) — not on every flash. First live computation confirmed on flash 420: `dS=-0.075 dD=-0.055 dN=0.051 d_drift=0.026 d_audit=0.13 endorsed_rate=0.8`, consistent with the anger/fear states dominant over the preceding flashes. Deliberately read-only for now: no effect yet on `epistemic_self_confidence` or `identity_threat` — that coupling, and the actual self-modifying rule (Meta-Learning of Thresholds, STDP-candidate) the master plan pairs it with, stay paused until enough flashes accumulate for the trend itself to be trustworthy.

- **Ablation testing.** `AblationFlags` — six independent switches (`use_memory`, `use_sbg`, `use_agency`, `use_latent`, `use_body`, `use_state_prompt`), default all-on, set via `ANIMA_ABLATE_*` environment variables at startup (no runtime toggle yet — that would need to handle disabling a layer mid-session without corrupting already-accumulated state, deliberately deferred). Each flag gates its layer at the point it would otherwise feed `experience!` or `build_llm_messages`: e.g. `use_sbg=false` forces `belief_conflict` to `nothing` and feeds `compute_phi` neutral 0.5 instead of live `attractor_stability`/`epistemic_trust`; `use_state_prompt=false` bypasses the entire state block and sends the LLM raw user text with no identity_block, memory echo, or D-vector. `:ablation` REPL command reports current flag state. This is infrastructure for testing whether a layer is load-bearing or decorative — the actual off/on behavioral comparison tooling (replaying the same input through both configurations) is a separate next step.

  The first blocker on that path has been closed: `causal_trace.stimulus_keys` used to store only key names, not values, and the raw `user_message` text was never persisted anywhere queryable by flash (the JSON dialog log is a rolling, un-indexed window for LLM prompt context, not an archive) — so even an "on" replay couldn't reconstruct the text-dependent paths (`social_delta`, curiosity trigger, `inner_dialogue`), let alone an "off" one. `causal_trace` now also carries `stimulus_values` (JSON of the raw stimulus dict) and `user_message`, both added via the same idempotent migration pattern as the MAL/identity_drift columns, confirmed live on a running database. This only covers flashes recorded from that point forward — no retroactive fix for older history. The replay executor itself, and the criteria for a per-flag coupling score (deliberately not a single collapsed index — categorical mismatch rate plus continuous deltas per flag, so the tool shows which layer moves what, rather than one number that "looks like" an impact metric), are still open.

- **Time trends made honest.** The existing GUI sparklines (`phi`, `bpm`, `D/S/N`, `agency`, `spe`, `coh`) were purely client-side — a 30-point JS array that resets on every page reload, which is narrative dressing on top of the current moment rather than a real trend. `identity_drift` is now persisted to `causal_trace` (new column + idempotent migration for existing databases), and a new `GET /api/history` endpoint (`anima_gui_server.jl`) serves the last N `causal_trace`/`audit_log` rows. The console fetches this once on load, before live polling starts, and seeds `identity_drift` and `audit_score` sparklines from it — both now survive a page reload and a server restart. Known limitation, left open rather than glossed over: `causal_trace`/`audit_log` are only written on flashes with an LLM reply, so this is a trend of the conversation, not of background drift during silence between sessions — the latter would need a separate write path from `slow_tick!`, not yet built.

- **Need-driven curiosity — questions can arise from an unmet internal need, not only from prediction error.** Previously `update_curiosity!` was hard-gated by `self_pred_error >= 0.08`, so a single saturated need (e.g. `contact_need` at 0.9, no partner need, no prediction error) could never produce a `CuriosityObject` — `GoalConflict`'s paired thresholds only fire when *two* needs cross 0.38 together. Trigger detection and object maintenance were split into separate responsibilities: `detect_curiosity_trigger(gc_active, pred_spike, self_pred_error, mal_dominant, sig_layer)` returns `(origin, signal_strength)` or `nothing` — prediction error still takes priority when both are present (a temporary simplicity choice, not an architectural claim about which matters more); when pred_error is below threshold, `strongest_unmet_need()` checks the five psychological needs against a 0.55 threshold, higher than the paired-conflict threshold since a single need lacks corroboration. `update_curiosity!` no longer knows about `pe` specifically — it takes a generic `signal`; `pe_mean` renamed to `signal_mean` (old persisted key kept as a fallback on load). First live need-origin object confirmed: `origin=:contact_need`, correct label, tracked signal 0.93 → 0.46 across flashes 329–359.

  Making closure origin-aware surfaced a real bug: `resolve_curiosity!` was only ever called from inside the same trigger check that creates objects, so once a need's level dropped *below* the creation threshold (0.55) but stayed *above* the resolve threshold (0.40), it stopped being a "trigger" and consequently never got checked for resolution again — orphaned indefinitely. Not hypothetical: caught live on flashes 350–351 (`contact_need=0.46`, no `CONTACT_SAT`, no resolve, silence). Fixed by decoupling create/update (still trigger-gated, correctly) from resolve (now `resolve_all_curiosity!`, sweeping every unresolved object every flash regardless of what triggered that flash). Confirmed live on flash 366: two previously-orphaned objects — one `origin=:epistemic_uncertainty`, one `origin=:social_signal` — closed via the same sweep, meaning the bug predated need-driven curiosity and had already been silently affecting prediction-error-origin objects. `[CURIOSITY_RESOLVED]` is now logged explicitly; this transition previously had no log line at all.

  Cross-referencing these logs against `anima_console.html` also surfaced an unrelated pre-existing mismatch: the `[CONTACT_SAT]` regex expected `contact_need=X` but the actual log format is `contact_need X → Y` — it never matched, silently dropping these events from the causal panel's log-parsing path. Fixed; a separate structured `ev.kind` WebSocket channel may already have covered the same data independently (unconfirmed without `anima_gui_bridge.jl`).

- **`CuriosityObject` origin — why a question arose, separate from what it's about.** The first attempt at typing curiosity objects derived a `query_type` from `topic_id` (the theme) — tested on live data and dropped: theme and question-type turned out to be different axes, and the classification was systematically blind on the generic curiosity fallback (where the interesting CAUSE/PREDICTION cases actually live). Replaced with `origin::Symbol`, set once when an object is created and never rewritten on later activations: `derive_origin(gc_active, pred_spike, mal_dominant)` — hierarchy `goal_conflict > prediction_error > social_signal/identity_signal > epistemic_uncertainty`. `pred_spike` (`PredictiveProcessor.is_spike`) was verified before use: it compares current error against the rolling mean of `error_history`, not a fixed cutoff — an adaptive signal already used elsewhere (noradrenaline, fatigue, stimulus classification), not a new threshold invented for this. `latent_tension` is deliberately excluded — `derive_topic_id` is currently always called with `latent_tag=""`, so that branch is dead code. Old persisted objects load with `origin=:legacy` rather than being reconstructed from `topic_id` — reconstruction would repeat the same mistake the topic_id approach made. First live non-legacy object confirmed: `origin=:social_signal`. `:curiosity` REPL command now prints `origin` per object.

- **Life Threads** — a long-term layer above `CuriosityObject`. A `CuriosityThread` is born when a curiosity object has matured (intensity > 0.5, activation_count ≥ 3) and lives independently of whether that object is currently active. `pressure` grows smoothly with idle time (no threshold jump), and drives initiative: a thread with `pressure > 0.6` lowers the initiative cooldown by 25%, making the system more likely to raise a topic it has been carrying for a long time. Threads surface in `build_identity_block` as "thinking about for weeks" context. Persistence via `psyche_save!/load!`.

- **CuriosityObject identity rebuilt around cognitive topics, not emotions.** The previous `id = emotion_ctx` (emotion name as key) meant that the same topic across different emotional states spawned separate, unrelated objects that could never accumulate history. Now `id = derive_topic_id(...)` with a three-level hierarchy: active `goal_conflict` ("self_preservation_vs_truth_need") → latent resistance tag → MAL `dominant_loop` as fallback. Sort is canonical — "a_vs_b" and "b_vs_a" are the same key. `topic_id` is computed after `compute_arbitration` so the real MAL regime is available as fallback. Label generation uses the topic for semantic content and the emotion only as coloring.

- **Curiosity closure loop tuned.** Two thresholds separated: `top_curiosity` (prompt and identity_block, threshold 0.15) vs `top_curiosity_any` (progress/churn signals and Life Thread surfacing, threshold 0.05). Young objects now accumulate without being blocked by older visible ones. Starting intensity raised to `pe * 0.8`, growth rate to `pe * 0.10`. Young objects (intensity < 0.25) are protected from `resolve_curiosity!` decay — they can't be killed before they've had a chance to build.

- **GUI gaps closed.** `contact_need`, `identity_drift`, `chronic_low_serotonin` now flow through `write_gui_state!` and `gui_live_state` into the Self panel. Three new live events: `curiosity_progress`, `curiosity_churn`, `contact_sat` — with `push_gui_event!` calls in `anima_background.jl` and corresponding routing in `anima_console.html`. Soft bias regex fixed in log pattern matching.

- MAL now actually changes what gets said, not just what gets logged. Phase 2 wires `compute_arbitration`'s result into the second `update_intent!`: at `:soft`, the MAL-favored drive gets a `MAL_SOFT_BIAS` (+0.1) nudge; at `:hard`, MAL's drive fully replaces NT's `dom_drive`; `:contested` (two strong signals, no clear winner) safely no-ops.

- Active Theory of Mind, Phase 1. Generates one active hypothesis at a time (`SOCIAL` / `PREDICTION` / `VALUE`), evaluates it on the next flash against type-specific outcomes, stores continuous `error_score`. Active hypotheses surface in `identity_block` and steer `disclosure_threshold`.

- Contact satiation signal. After an `:endorsed` flash with `contact_need > 0.5`, `contact_need` drops by 0.08 — symmetric to Curiosity Closure. Positive cohesion also gives a smaller immediate relief, while high D/S values reduce the gain from repeated warm self-hearing. A genuine exchange is felt as satisfying; an automatic one isn't.

- Curiosity closure loop (original). `progress_signal = endorsed && is_progress_eligible && causal_necessary`. On progress, intensity decays by 0.85 per step. Separate `churn` signal on topic drift without advancement.

⚠️ The architecture is actively evolving, and some of what is described above is recent and not yet fully battle-tested. Some modules interact in complex ways, and not all edge cases are covered by tests. Unexpected interactions between states may occur, especially during long sessions or after extended pauses.

---

## 🚧 Limitations

- part of behavior still depends on the LLM (output generation)
- output LLM is not the source of decisions, but its words feed back through `self_hear!` and can influence internal state after being spoken
- ~180+ flashes to accumulate real semantic beliefs
- MetaArbitrationLayer now influences the final `update_intent!` (Phase 2): `:soft` nudges drives by `MAL_SOFT_BIAS`, `:hard` overrides `dom_drive` outright, `:contested` (two strong signals, no clear winner) safely no-ops; override only fires on genuine NT/MAL disagreement, not on every non-default regime
- drive_conflict between MAL and NT reflects a timescale difference rather than contradiction: NT `dom_drive` is an immediate local signal ("what just spiked"), MAL/social is accumulative ("what has been important for a while"); Phase 2 currently lets MAL win on disagreement, which is itself a hypothesis still being tested against more data
- Theory of Mind is Phase 1 (deterministic rule-based hypotheses from accumulated `other_model` signals); it does not yet reason about nested beliefs or model the user's model of Anima — it predicts simple outcomes (openness, resistance, topic recurrence) and tracks how often it's right
- under hostile/negative input the system degrades gracefully: `contact_need` drops, `goal_conflict` and `latent` rise, endorsed transitions to `automatic`, but curiosity closure pauses rather than breaks

---
![ANIMA GUI](anima-gui.png)
---

## Requirements

- **Julia 1.9+**
- Julia packages: `HTTP`, `JSON3`, `SQLite`, `Tables`
- API key from [openrouter.ai](https://openrouter.ai) (free tier available)

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

> Dependencies: HTTP, JSON3, SQLite, Tables, Dates, Statistics, LinearAlgebra

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

### Option C — Telegram Bot (optional, for persistent use)

Run Anima as a Telegram bot — it polls for messages, responds through the full experience pipeline, and can speak first when internal pressure builds up.

**Setup:**

1. Create a bot via [@BotFather](https://t.me/BotFather) and get the token
2. Get your Telegram user ID (e.g. via [@userinfobot](https://t.me/userinfobot))
3. Start a DM with your bot and press `/start`
4. Copy `.env.example` to `.env` and fill in your values:
   ```
   ANIMA_TELEGRAM_TOKEN=your_bot_token
   ANIMA_TELEGRAM_CHAT_ID=your_user_id
   OPENROUTER_API_KEY=your_key
   ```

**Run with Docker (no Julia installation needed):**

```bash
docker compose up --build
```

**Run without Docker:**

```bash
cd Anima
julia --project=. run_anima_telegram.jl
```

**Telegram commands:**

| Command | Action |
|---|---|
| `/state` | Show current NT state, BPM, coherence |
| `/stop` | Save and shut down gracefully |
| *(any text)* | Process through the full experience pipeline |

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
| `causal_trace` | Full causal chain per flash — from stimulus (keys, raw values, and user message text — the last two added to enable honest ablation replay) through NT, φ, intent, policy, MAL arbitration (`dominant_loop`, `regime`, `score`, `runner_up`, `runner_up_score`, `loop_scores`), drive conflict (`dom_drive_nt`, `dom_drive_mal`, `drive_conflict`), to speech, endorsement, Curiosity Closure Signal (`progress_signal`, `progress_target`, `churn`), and `identity_drift` (persisted time-trend source for the GUI) |

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
├── anima_telegram.jl       # Telegram bridge — bot loop replacing the terminal REPL
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
