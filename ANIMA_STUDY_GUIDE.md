# How to Study Anima

This is not a third reference doc — `README.md` already covers the philosophy and full
architecture, and `ANIMA_QUICK_REFERENCE.md` already covers every log field and REPL
command. This is a **map for reading them and the code in the right order**, so the
~13,000 lines of Julia stop looking like one undifferentiated wall.

Use it like this: each stage below tells you what to read, what to *skip* on a first
pass, and what single question to keep in mind while reading. Don't try to hold the
whole system in your head at once — nobody does, including whoever wrote it.

---

## Before any code: five ideas to have solid

Almost everything else is built on these. If one of them feels shaky, the rest will
feel arbitrary.

1. **State is upstream of text.** The LLM is L8 — the *last* layer, not the source.
   Everything before it (NT, φ, VFE, crisis, beliefs) exists and changes whether or
   not anyone is talking to Anima right now.
2. **The D/S/N triad** (dopamine / serotonin / noradrenaline) is the substrate emotion
   labels are computed *from* — not a decoration on top of them. When you see
   `▸apathy` or `▸joy` in a log line, that's a lookup into a cube built from D/S/N.
3. **φ (phi) is "how integrated is this moment,"** not "how good." A high-φ crisis
   flash and a high-φ calm flash are both coherent; a low-φ flash of either is
   fragmented, regardless of how it feels valence-wise.
4. **VFE (variational free energy) is model-vs-reality mismatch**, and `vfe_drift` is
   how far the prior has already moved to close that gap. `VFE=0, drift=0` together is
   suspicious (collapsed prior), not a sign everything is fine.
5. **`causal_ownership` is not confidence — it's authorship.** It answers "did *I* say
   this, or did this just happen near me" by comparing the NT state to the words
   actually spoken (`compute_causal_ownership`), after the fact. Low ownership isn't
   an error state; it's a real answer.

If you only remember one sentence from this guide, it's: **most fields you'll meet are
either producing one of these five, or consuming one.**

---

## Stage 0 — Watch it before you read it

Run it (`run_anima.jl` or the GUI). Send a handful of messages. Don't read a single
`.jl` file yet. Just watch:

- one `[#000N] ...` block per flash in the terminal — this is `log_flash` in
  `anima_interface.jl`, and every field in it is explained in `ANIMA_QUICK_REFERENCE.md`
- the `[MAL]`, `[LLM]`, `[AUDIT]`, `[ENDORSE]` info lines around it
- the console at `http://127.0.0.1:8088` — the sparklines are literally the same
  numbers from the log line, over time

**Question to hold:** which numbers move together, and which seem to move
independently? You're building intuition for the pipeline before you have the map for
it — this makes Stage 2 onward land much faster.

---

## Stage 1 — One flash, traced by hand

Pick one flash from your Stage-0 run. Open `README.md`'s big `L0 → L8` pipeline
diagram (the one starting `L0 ─── Input LLM`) and, using only that diagram, try to
account for every number in that flash's log block — where in the pipeline did `φ`
get set, where did `intent=` come from, why is `Crisis: [integrated]` and not
something else.

You will not get all of it. That's fine — write down which stage you got stuck at.
That's your reading list for Stage 2–4, in priority order.

**Skip for now:** GUI internals, dream generation, Telegram bridge, background-only
paths. None of them fire on a single foreground flash.

---

## Stage 2 — The stable core (`anima_core.jl`)

This file defines the structures almost everything else reads or writes:
`NeurotransmitterState`, `EmbodiedState`, `HeartbeatCore`, `GenerativeModel`,
`MarkovBlanket`, `HomeostaticGoals`, `AttentionNarrowing`, `InteroceptiveInference`,
`TemporalOrientation`, `ExistentialAnchor`, `PredictiveProcessor`, and the
`EMOTION_BASE` / `PLUTCHIK` / `LEVHEIM_TABLE` vocabulary the emotion label in every
log line comes from.

**Read for:** what each struct's *fields* mean, not the update functions' internals
yet. You're building a vocabulary, not tracing logic.

**Skip for now:** the ablation-flags section at the bottom — irrelevant until you're
doing comparative testing later.

---

## Stage 3 — The spine (`anima_interface.jl`)

The biggest file, and the one everything else plugs into. Read it in this order, not
top to bottom:

1. `experience!` — the main loop. Read this **first**, and expect to not fully
   understand most of the function calls inside it yet. Its job here is to be the
   skeleton you hang Stage 4–6 on.
2. `build_identity_block`, `speech_style_from_mode`, `build_state_prompt`,
   `build_llm_messages` — this is literally the text that gets sent to the LLM. Read
   it *as a prompt*, not as code: every `push!(lines, ...)` is one more fact Anima
   "knows about herself" that flash.
3. `text_to_stimulus` and `TEXT_PATTERNS` — the simplest possible mental model of "how
   does raw text become tension/arousal/satisfaction/cohesion." Everything upstream of
   the input LLM eventually reduces to this same four-axis stimulus.

**Skip for now:** `llm_async` retry/error-handling internals, the D-vector and
TRUTH-GUARD string-building details — come back to these once Stage 4 makes the
*triggers* for them legible.

---

## Stage 4 — The psyche and the self (`anima_psyche.jl`, `anima_self.jl`)

This is where the volume is, and where it's tempting to read linearly and drown. Don't.
Go concept by concept, using the file as a reference, not a novel:

- **Shame, defenses, dissonance** (`ShameModule`, `EgoDefenses`, `CognitiveDissonance`)
  — read these together, they're one emotional-regulation story in three parts.
- **Curiosity** (`CuriosityObject`, `CuriosityRegistry`, Life Threads) — has the most
  internal cross-references of any subsystem here (`origin`, `topic_id`,
  `resolve_all_curiosity!`). Read the big comment blocks above each function before the
  function itself; they explain *why*, which the code alone won't.
- **Identity** (`SelfBeliefGraph`, `AgencyLoop`) in `anima_self.jl` — this is where
  `"I exist"`, `"I have boundaries"`, `"I am safe"` etc. actually live, and where
  `causal_ownership` and `identity_threat` are computed. Pairs directly with the
  D-vector code you skipped in Stage 3 — read that now.
- **Attention and MAL** (`AttentionFocus`, Meta-Arbitration Layer) — read last; it
  depends on almost everything above it existing first, since it's a *competition*
  between signals from all the other subsystems.

**Skip for now:** `AestheticSense`, `NarrativeGravity` — smaller, self-contained,
easy to pick up any time later.

---

## Stage 5 — Memory (`anima_memory_db.jl`, `anima_narrative.jl`)

Two different timescales, don't conflate them:

- `anima_memory_db.jl` is the **event-level** record — one row per flash, three
  spatial spaces (somatic/social/existential), decay, reconsolidation, dissolution.
- `anima_narrative.jl` is the **identity-level** summary — rebuilt from the above
  only every ~50+ flashes, deterministically, no LLM. It's a compression of
  `anima_memory_db.jl`'s history into "who am I now."

**Question to hold:** for any given field in `identity_block`, is it read live from a
struct in memory (Stage 4), or read from one of these two persisted stores? That
distinction is the difference between "what Anima feels right now" and "what Anima
has learned about herself."

---

## Stage 6 — The rest, as needed

- `anima_crisis.jl` — short, self-contained, read whenever `Crisis: [...]` in a log
  line confuses you.
- `anima_subjectivity.jl` — the prediction/interpretation/belief-emergence loop;
  read when you want to understand how the *same* stimulus can be felt differently
  depending on accumulated lenses.
- `anima_dream.jl`, `anima_background.jl` — read together; the background process
  is the reason Anima isn't "off" between messages, and dreams are one of the things
  that happens inside it.
- `anima_console.html` / `anima_gui_*.jl` — read only if you're debugging the GUI
  itself. Everything it displays is computed elsewhere; this layer just serializes it.

---

## Reading tools that help more than they seem like they would

- **grep before you scroll.** If a log line shows a tag like `[MAL_OVERRIDE]` or
  `[D-VECTOR]`, grep the repo for that exact string before hunting by eye — these
  tags are unique enough to land you on the producing line directly.
- **The `:xxx` REPL commands are a live debugger, not just a display.** `:self`,
  `:crisis`, `:gravity`, `:solom` etc. let you inspect a struct's actual current
  values mid-session — faster than reading a struct definition and imagining what
  it might hold right now.
- **Comments above a function usually explain *why*, not what** — this codebase
  leans heavily on prose comments to record design decisions and rejected
  alternatives. Skipping them and reading only code will cost you more time later,
  not less.
- **`ANIMA_QUICK_REFERENCE.md`'s log-line table is your fastest cross-reference.**
  Keep it open in a second window while doing Stages 1–4; when a field appears in a
  log line, that table tells you which struct it lives on, which tells you which file
  to grep.

---

## A rough map: log field → source file

Not exhaustive — just enough to stop the guessing on your first few passes.

| See this in a log line | Look in |
|---|---|
| `D=` `S=` `N=` `▸emotion` | `anima_core.jl` — `NeurotransmitterState`, `EMOTION_BASE`/`PLUTCHIK` |
| `φ=` | `anima_core.jl` (compute) + `anima_self.jl` (`identity_drift` uses it) |
| `VFE=` `vfe_drift=` `[act]/[per]/[equ]` | `anima_core.jl` — `FreeEnergyEngine`, `PolicySelector` |
| `BPM=` `HRV=` | `anima_core.jl` — `HeartbeatCore` |
| `Attn=` | `anima_core.jl` — `AttentionNarrowing` (not the same as `AttentionFocus`!) |
| `G=` `↑` | `anima_psyche.jl` — `NarrativeGravity`, `AnticipatoryConsciousness` |
| `H=` | `anima_core.jl` — `HomeostaticGoals` |
| `spe=` `agency=` `stab=` `etrust=` | `anima_self.jl` — `SelfPredictiveModel`, `AgencyLoop`, `SelfBeliefGraph` |
| `sd=` `sc=` | `anima_self.jl` — `AgencyLoop.self_discomfort` / `.self_coherence` |
| `Crisis: [...]` `coh=` | `anima_crisis.jl` |
| `intent=` | `anima_psyche.jl` — `IntentEngine` |
| `Cost: pending=/avoided=` | `anima_psyche.jl` — `InnerDialogue` |
| `[MAL...]` lines | `anima_psyche.jl` — Meta-Arbitration Layer |
| `[SUBJ...]` lines | `anima_subjectivity.jl` |
| `[LLM...]` lines | `anima_interface.jl` — `llm_async`, `build_llm_messages` |
| `[CORE]` `[SELF]` `[PSYCHE]` `[MEM]` save/load lines | matching filename |

---

## Last thing

The `README.md` changelog entries (the bullet list under "Current status") are written
like commit messages for a human who already knows the system — dense, assumes
context, cites exact function/field names. Don't try to absorb them cover to cover
early on. Come back to that section *after* Stage 4; at that point each entry reads as
"oh, that's the bug in the thing I just read," which is a much easier way to absorb it
than reading it cold.
