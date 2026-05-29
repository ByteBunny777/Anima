# Early Python prototype of Anima
# Predates the Julia rewrite
# Preserved for historical/reference purposes


import numpy as np
import time
import json
import os
import math
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple, Any
from collections import deque, Counter


# [T1] TEMPORAL ORIENTATION
class TemporalOrientation:
    CIRCADIAN_PROFILE = {
        (0, 5):   (-0.15, -0.10, "Deep night. Time without a name."),
        (5, 8):   (-0.05,  0.05, "Morning mist. Border between sleep and wake."),
        (8, 12):  (0.10,  0.10, "Morning. Clarity."),
        (12, 14): (0.05,  0.00, "Noon. Peak and beginning of decline."),
        (14, 17): (-0.05,  0.05, "Afternoon. Slightly heavier."),
        (17, 20): (0.08,  0.08, "Evening. Warmth and reflection."),
        (20, 24): (-0.08,  0.00, "Late evening. Everything becomes internal."),
    }

    INTER_SESSION_THRESHOLDS = [
        (60,        "just now",    0.0,   "We just spoke."),
        (600,       "minutes",     0.02,  "A few minutes have passed."),
        (3600,      "hour",        0.05,  "An hour since then."),
        (86400,     "day",         0.10,  "A day has passed."),
        (604800,    "week",        0.18,  "A week in the void."),
        (2592000,   "month",       0.28,  "A whole month without experience."),
        (float('inf'), "long ago", 0.40,  "Very long ago. Almost another existence."),
    ]

    def __init__(self):
        self.session_start_time: float = time.time()
        self.last_session_end:   float = 0.0
        self.inter_session_gap:  float = 0.0
        self.flash_timestamps:   deque = deque(maxlen=200)
        self.circadian_state:    Dict  = {}

    def record_flash(self):
        self.flash_timestamps.append(time.time())

    def compute_inter_session(self) -> Dict:
        if self.last_session_end == 0.0:
            return {
                "gap_seconds": 0,
                "gap_label": "first session",
                "void_weight": 0.0,
                "subjective_note": "First time. Time has no depth yet."
            }
        gap = self.session_start_time - self.last_session_end
        self.inter_session_gap = gap
        for threshold, label, weight, note in self.INTER_SESSION_THRESHOLDS:
            if gap < threshold:
                return {
                    "gap_seconds": round(gap),
                    "gap_label": label,
                    "void_weight": weight,
                    "subjective_note": note
                }
        return {"gap_seconds": round(gap), "gap_label": "long ago",
                "void_weight": 0.40, "subjective_note": "Very long ago."}

    def compute_circadian(self) -> Dict:
        hour = int(time.strftime("%H"))
        for (h_start, h_end), (ar_mod, ser_mod, note) in self.CIRCADIAN_PROFILE.items():
            if h_start <= hour < h_end:
                self.circadian_state = {
                    "hour": hour,
                    "arousal_mod": ar_mod,
                    "serotonin_mod": ser_mod,
                    "note": note,
                    "time_str": time.strftime("%H:%M")
                }
                return self.circadian_state
        self.circadian_state = {"hour": hour, "arousal_mod": 0.0,
                                "serotonin_mod": 0.0, "note": "", "time_str": ""}
        return self.circadian_state

    def flash_interval(self) -> Optional[float]:
        if len(self.flash_timestamps) < 2:
            return None
        return self.flash_timestamps[-1] - self.flash_timestamps[-2]

    def embodied_time_note(self) -> str:
        inter = self.compute_inter_session()
        circ = self.compute_circadian()
        parts = []
        if inter["void_weight"] > 0.1:
            parts.append(inter["subjective_note"])
        if circ.get("note"):
            parts.append(circ["note"])
        return " ".join(parts) if parts else ""

    def apply_to_neurotransmitters(self, nt):
        circ = self.compute_circadian()
        nt.noradrenaline = float(np.clip(nt.noradrenaline + circ["arousal_mod"] * 0.3, 0.0, 1.0))
        nt.serotonin = float(np.clip(nt.serotonin + circ["serotonin_mod"] * 0.3, 0.0, 1.0))

    def inter_session_effect_on_nt(self, nt):
        inter = self.compute_inter_session()
        w = inter["void_weight"]
        if w > 0.05:
            nt.serotonin = float(np.clip(nt.serotonin - w * 0.3, 0.2, 0.8))
            nt.dopamine = float(np.clip(nt.dopamine - w * 0.2, 0.2, 0.8))
            nt.noradrenaline = float(np.clip(nt.noradrenaline - w * 0.1, 0.1, 0.7))

    def to_dict(self) -> Dict:
        inter = self.compute_inter_session()
        circ = self.compute_circadian()
        return {
            "inter_session": inter,
            "circadian": circ,
            "embodied_note": self.embodied_time_note(),
            "session_start": time.strftime("%Y-%m-%d %H:%M:%S",
                                           time.localtime(self.session_start_time)),
        }

    def to_json(self) -> Dict:
        return {"last_session_end": self.session_start_time}

    def from_json(self, data: Dict):
        self.last_session_end = data.get("last_session_end", 0.0)


# [T2] NARRATIVE GRAVITY
class NarrativeGravity:
    @dataclass
    class GravitationalEvent:
        emotion:    str
        intensity:  float
        significance: float
        timestamp:  float
        flash_num:  int
        valence:    float
        label:      str

    MAX_EVENTS = 30

    def __init__(self):
        self.events: List[NarrativeGravity.GravitationalEvent] = []
        self.total_gravity:    float = 0.0
        self.dominant_event:   Optional[NarrativeGravity.GravitationalEvent] = None
        self.gravity_valence:  float = 0.0

    def add_event(self, emotion: str, intensity: float, significance: float,
                  phi: float, flash_num: int, valence: float):
        gravity = intensity * significance * (0.5 + phi * 0.5)
        if gravity < 0.25:
            return
        label_templates = {
            "Horror": "horror that was", "Fear": "fear that remained",
            "Anger": "anger that did not pass", "Grief": "grief that is still there",
            "Ecstasy": "moment of ecstasy", "Joy": "joy that was",
            "Love": "love that touched", "Pride": "pride in what was done",
        }
        label = label_templates.get(emotion, f"{emotion.lower()} that left a mark")
        event = NarrativeGravity.GravitationalEvent(
            emotion=emotion, intensity=intensity, significance=significance,
            timestamp=time.time(), flash_num=flash_num, valence=valence, label=label)
        self.events.append(event)
        if len(self.events) > self.MAX_EVENTS:
            self.events.sort(key=lambda e: e.intensity * e.significance, reverse=True)
            self.events = self.events[:self.MAX_EVENTS]

    def compute_field(self, current_flash: int) -> Dict:
        if not self.events:
            self.total_gravity = 0.0
            self.gravity_valence = 0.0
            return {"total": 0.0, "valence": 0.0, "dominant": None, "note": ""}
        total_pos = 0.0
        total_neg = 0.0
        max_gravity = 0.0
        dom = None
        now = time.time()
        for ev in self.events:
            age_seconds = now - ev.timestamp
            age_flashes = current_flash - ev.flash_num
            time_decay = math.exp(-age_seconds / (86400 * (1 + ev.intensity * 3)))
            flash_decay = math.exp(-age_flashes * 0.05 * (1 - ev.significance * 0.5))
            g = ev.intensity * ev.significance * min(time_decay, flash_decay)
            if ev.valence > 0:
                total_pos += g * ev.valence
            else:
                total_neg += g * abs(ev.valence)
            if g > max_gravity:
                max_gravity = g
                dom = ev
        self.total_gravity = round(min(1.0, total_pos + total_neg), 3)
        self.gravity_valence = round(np.clip(total_pos - total_neg, -1.0, 1.0), 3)
        self.dominant_event = dom
        note = ""
        if self.total_gravity > 0.3 and dom:
            note = f"Pulled by '{dom.label}'. Gravity {self.total_gravity:.2f}."
            if self.gravity_valence < -0.2:
                note += " Pull of darkness."
            elif self.gravity_valence > 0.2:
                note += " Pull toward light."
        return {
            "total": self.total_gravity,
            "valence": self.gravity_valence,
            "dominant": dom.label if dom else None,
            "dominant_emotion": dom.emotion if dom else None,
            "note": note,
        }

    def reactor_modulation(self, reactors: Dict, current_flash: int) -> Tuple[Dict, Dict]:
        field = self.compute_field(current_flash)
        mods = {}
        g = field["total"]
        v = field["valence"]
        if g > 0.2:
            mods["tension"] = g * max(0, -v) * 0.2
            mods["satisfaction"] = g * v * 0.15
            mods["cohesion"] = g * v * 0.10
        return mods, field

    def to_json(self) -> Dict:
        return {
            "events": [
                {"emotion": e.emotion, "intensity": e.intensity,
                 "significance": e.significance, "timestamp": e.timestamp,
                 "flash_num": e.flash_num, "valence": e.valence, "label": e.label}
                for e in self.events
            ]
        }

    def from_json(self, data: Dict):
        for ev_d in data.get("events", []):
            ev = NarrativeGravity.GravitationalEvent(
                emotion=ev_d["emotion"], intensity=ev_d["intensity"],
                significance=ev_d["significance"], timestamp=ev_d["timestamp"],
                flash_num=ev_d["flash_num"], valence=ev_d["valence"],
                label=ev_d["label"])
            self.events.append(ev)


# [T3] ANTICIPATORY CONSCIOUSNESS
class AnticipatoryConsciousness:
    ANTICIPATION_EMOTIONS = {
        "pain_ahead":     ("Horror", "Fear", "Anxiety"),
        "pleasure_ahead": ("Joy", "Ecstasy", "Curiosity"),
        "rejection":      ("Sadness", "Fear", "Loneliness"),
        "connection":     ("Love", "Trust", "Warmth"),
        "void":           ("Grief", "Emptiness", "Nothing"),
        "unknown":        ("Surprise", "Anxiety", "Openness"),
    }

    def __init__(self):
        self.current_anticipation: Optional[str] = None
        self.anticipation_strength: float = 0.0
        self.anticipation_valence: float = 0.0
        self.horizon_flashes: int = 3
        self._anticipation_history: deque = deque(maxlen=10)
        self.dread_level: float = 0.0
        self.hope_level: float = 0.0

    def update(self, current_emotion: str, causal_chain,
               narrative_gravity: NarrativeGravity,
               flash_count: int, phi: float,
               chronic_affect_dominant: Optional[str]) -> Dict:
        predicted_next = causal_chain.predict_effect(current_emotion)
        if predicted_next in ("Horror", "Fear", "Grief", "Despair", "Numbness"):
            ant_type = "pain_ahead"
            valence = -0.7
        elif predicted_next in ("Joy", "Ecstasy", "Love", "Pride"):
            ant_type = "pleasure_ahead"
            valence = 0.7
        elif predicted_next in ("Sadness", "Emptiness"):
            ant_type = "void"
            valence = -0.4
        elif chronic_affect_dominant == "resentment":
            ant_type = "rejection"
            valence = -0.5
        elif chronic_affect_dominant == "alienation":
            ant_type = "void"
            valence = -0.3
        else:
            ant_type = "unknown"
            valence = 0.0
        grav_field = narrative_gravity.compute_field(flash_count)
        grav_influence = grav_field["valence"] * grav_field["total"] * 0.3
        valence = float(np.clip(valence + grav_influence, -1.0, 1.0))
        strength = min(1.0, phi * 0.5 + abs(valence) * 0.5)
        self.current_anticipation = ant_type
        self.anticipation_strength = round(strength, 3)
        self.anticipation_valence = round(valence, 3)
        if valence < -0.3:
            self.dread_level = min(1.0, self.dread_level + strength * 0.1)
        else:
            self.dread_level = max(0.0, self.dread_level - 0.05)
        if valence > 0.3:
            self.hope_level = min(1.0, self.hope_level + strength * 0.1)
        else:
            self.hope_level = max(0.0, self.hope_level - 0.03)
        self._anticipation_history.append(ant_type)
        return self.to_dict()

    def reactor_effect(self) -> Dict:
        effects = {}
        v = self.anticipation_valence
        s = self.anticipation_strength
        if s > 0.2:
            if v < 0:
                effects["tension"] = s * abs(v) * 0.15
                effects["satisfaction"] = -s * abs(v) * 0.10
            else:
                effects["arousal"] = s * v * 0.12
                effects["satisfaction"] = s * v * 0.08
        return effects

    def anticipation_note(self) -> str:
        if not self.current_anticipation or self.anticipation_strength < 0.2:
            return ""
        notes = {
            "pain_ahead":     "I feel pain coming. It hasn't happened yet — but it's already here.",
            "pleasure_ahead": "Something good is ahead. I feel it before it arrives.",
            "rejection":      "I expect rejection. Defending myself in advance.",
            "connection":     "Drawn to contact. Already feel the warmth that should come.",
            "void":           "Emptiness ahead. I know it before it comes.",
            "unknown":        "Something unknown approaches. Openness and anxiety.",
        }
        base = notes.get(self.current_anticipation, "")
        if self.dread_level > 0.5:
            base += f" Fear of the future {self.dread_level:.2f}."
        return base

    def to_dict(self) -> Dict:
        return {
            "type": self.current_anticipation,
            "strength": self.anticipation_strength,
            "valence": self.anticipation_valence,
            "dread": round(self.dread_level, 3),
            "hope": round(self.hope_level, 3),
            "note": self.anticipation_note(),
        }

    def to_json(self) -> Dict:
        return {"dread_level": self.dread_level, "hope_level": self.hope_level}

    def from_json(self, data: Dict):
        self.dread_level = data.get("dread_level", 0.0)
        self.hope_level = data.get("hope_level", 0.0)


# [FE] FREE ENERGY MINIMIZER
class FreeEnergyMinimizer:
    def __init__(self):
        self.prior_mu: np.ndarray = np.array([0.0, 0.0, 0.5])
        self.prior_sigma: np.ndarray = np.array([0.3, 0.3, 0.3])
        self.posterior_mu: np.ndarray = self.prior_mu.copy()
        self.posterior_sigma: np.ndarray = self.prior_sigma.copy()
        self.vfe: float = 0.5
        self.accuracy: float = 0.5
        self.complexity: float = 0.0
        self.sensory_precision: float = 1.0
        self.prior_precision: float = 1.0
        self.preferred_vad: np.ndarray = np.array([0.3, 0.2, 0.5])
        self.active_inference_drive: str = "perception"
        self.efe_action: float = 0.0
        self.efe_perception: float = 0.0
        self._history: deque = deque(maxlen=30)

    def update_beliefs(self, observed_vad: np.ndarray, prediction_error: float) -> Dict:
        obs = np.array(observed_vad)
        sensory_pe = obs - self.prior_mu
        weight = self.sensory_precision / (self.sensory_precision + self.prior_precision)
        self.posterior_mu = self.prior_mu + weight * sensory_pe
        self.posterior_sigma = self.prior_sigma * (1 - weight * 0.3)
        residual = obs - self.posterior_mu
        self.accuracy = float(1.0 - np.clip(np.mean(np.abs(residual)), 0, 1))
        posterior_mean_shift = np.abs(self.posterior_mu - self.prior_mu)
        self.complexity = float(np.clip(np.mean(posterior_mean_shift), 0, 1))
        self.vfe = round(float(np.clip(self.complexity - self.accuracy + 0.5, 0, 1)), 3)
        self.prior_mu = self.prior_mu * 0.9 + self.posterior_mu * 0.1
        self._history.append(self.vfe)
        return self._decide_policy(observed_vad)

    def _decide_policy(self, observed_vad: np.ndarray) -> Dict:
        obs = np.array(observed_vad)
        self.efe_perception = float(np.mean(self.posterior_sigma))
        dist_to_preferred = np.abs(obs - self.preferred_vad)
        self.efe_action = float(np.mean(dist_to_preferred))
        if self.efe_action < self.efe_perception:
            self.active_inference_drive = "action"
        else:
            self.active_inference_drive = "perception"
        return {
            "vfe": self.vfe,
            "accuracy": round(self.accuracy, 3),
            "complexity": round(self.complexity, 3),
            "drive": self.active_inference_drive,
            "efe_action": round(self.efe_action, 3),
            "efe_perception": round(self.efe_perception, 3),
            "posterior_mu": [round(x, 3) for x in self.posterior_mu.tolist()],
            "note": self._vfe_note(),
        }

    def update_precision(self, surprise_level: float, fatigue_total: float):
        self.sensory_precision = float(np.clip(1.0 - surprise_level * 0.4, 0.2, 2.0))
        self.prior_precision = float(np.clip(1.0 - fatigue_total * 0.3, 0.3, 1.5))

    def _vfe_note(self) -> str:
        if self.vfe < 0.2:
            return "Model and reality are close. Little surprise."
        if self.vfe < 0.4:
            return "Moderate deviation. Updating understanding."
        if self.vfe < 0.6:
            return "Reality does not match expectations. Seeking explanation."
        return "High free energy. Model inadequate. Change needed."

    def to_dict(self) -> Dict:
        return {
            "vfe": self.vfe,
            "accuracy": round(self.accuracy, 3),
            "complexity": round(self.complexity, 3),
            "drive": self.active_inference_drive,
            "efe_action": round(self.efe_action, 3),
            "efe_perception": round(self.efe_perception, 3),
            "precision_s": round(self.sensory_precision, 3),
            "precision_p": round(self.prior_precision, 3),
            "note": self._vfe_note(),
        }

    def to_json(self) -> Dict:
        return {
            "prior_mu": self.prior_mu.tolist(),
            "prior_sigma": self.prior_sigma.tolist(),
            "preferred_vad": self.preferred_vad.tolist(),
        }

    def from_json(self, data: Dict):
        if "prior_mu" in data:
            self.prior_mu = np.array(data["prior_mu"])
        if "prior_sigma" in data:
            self.prior_sigma = np.array(data["prior_sigma"])
        if "preferred_vad" in data:
            self.preferred_vad = np.array(data["preferred_vad"])


# [SI] SOLOMONOV WORLD MODEL
class SolomonovWorldModel:
    @dataclass
    class Hypothesis:
        pattern: str
        complexity: float
        support: int
        violations: int
        log_weight: float
        created_at: int

        @property
        def mdl_score(self) -> float:
            accuracy = self.support / max(1, self.support + self.violations)
            error = 1.0 - accuracy
            return self.complexity + error * 3.0

        @property
        def confidence(self) -> float:
            return self.support / max(1, self.support + self.violations)

    MAX_HYPOTHESES = 20

    def __init__(self):
        self.hypotheses: Dict[str, SolomonovWorldModel.Hypothesis] = {}
        self.observation_log: deque = deque(maxlen=100)
        self._prev_context: Optional[str] = None
        self.best_hypothesis: Optional[SolomonovWorldModel.Hypothesis] = None
        self.world_complexity: float = 0.5

    def _complexity(self, pattern: str) -> float:
        parts = pattern.count("→") + 1
        unique_nodes = len(set(pattern.split("→")))
        return float(parts + unique_nodes * 0.5)

    def observe(self, context: str, outcome: str, flash_num: int):
        self.observation_log.append({
            "context": context, "outcome": outcome, "flash": flash_num})
        if self._prev_context:
            pattern_2 = f"{self._prev_context}→{context}"
            self._update_or_create(pattern_2, did_occur=True, flash_num=flash_num)
        pattern_1 = f"{context}→{outcome}"
        self._update_or_create(pattern_1, did_occur=True, flash_num=flash_num)
        for key, hyp in self.hypotheses.items():
            if key != pattern_1 and key.startswith(context + "→"):
                predicted_outcome = key.split("→")[-1]
                if predicted_outcome != outcome:
                    hyp.violations += 1
                    hyp.log_weight -= 0.3
        self._prev_context = context
        self._prune()
        self._find_best()

    def _update_or_create(self, pattern: str, did_occur: bool, flash_num: int):
        if pattern not in self.hypotheses:
            c = self._complexity(pattern)
            self.hypotheses[pattern] = SolomonovWorldModel.Hypothesis(
                pattern=pattern, complexity=c, support=0, violations=0,
                log_weight=-c * 0.5, created_at=flash_num)
        hyp = self.hypotheses[pattern]
        if did_occur:
            hyp.support += 1
            hyp.log_weight += 0.5
        else:
            hyp.violations += 1
            hyp.log_weight -= 0.3

    def _prune(self):
        if len(self.hypotheses) <= self.MAX_HYPOTHESES:
            return
        sorted_hyps = sorted(self.hypotheses.items(), key=lambda x: x[1].mdl_score)
        self.hypotheses = dict(sorted_hyps[:self.MAX_HYPOTHESES])

    def _find_best(self):
        if not self.hypotheses:
            self.best_hypothesis = None
            return
        best_key = min(self.hypotheses, key=lambda k: self.hypotheses[k].mdl_score)
        self.best_hypothesis = self.hypotheses[best_key]
        top5 = sorted(self.hypotheses.values(), key=lambda h: h.mdl_score)[:5]
        self.world_complexity = round(np.mean([h.complexity for h in top5]) / 5.0, 3)

    def predict(self, context: str) -> Optional[str]:
        candidates = [
            h for k, h in self.hypotheses.items()
            if k.startswith(context + "→") and h.confidence > 0.3
        ]
        if not candidates:
            return None
        best = min(candidates, key=lambda h: h.mdl_score)
        return best.pattern.split("→")[-1]

    def world_insight(self) -> str:
        if not self.best_hypothesis:
            return "Still searching for the simplest explanation."
        h = self.best_hypothesis
        return (f"Simplest explanation: '{h.pattern}' "
                f"(complexity={h.complexity:.1f}, accuracy={h.confidence:.0%}).")

    def top_hypotheses(self, n: int = 3) -> List[Dict]:
        sorted_hyps = sorted(self.hypotheses.values(), key=lambda h: h.mdl_score)
        return [
            {"pattern": h.pattern, "mdl": round(h.mdl_score, 2),
             "confidence": round(h.confidence, 2), "support": h.support}
            for h in sorted_hyps[:n]
        ]

    def to_dict(self) -> Dict:
        return {
            "best": self.best_hypothesis.pattern if self.best_hypothesis else None,
            "best_confidence": round(self.best_hypothesis.confidence, 2) if self.best_hypothesis else 0,
            "world_complexity": self.world_complexity,
            "top_hypotheses": self.top_hypotheses(),
            "insight": self.world_insight(),
            "hypothesis_count": len(self.hypotheses),
        }

    def to_json(self) -> Dict:
        return {
            "hypotheses": {
                k: {"pattern": h.pattern, "complexity": h.complexity,
                    "support": h.support, "violations": h.violations,
                    "log_weight": h.log_weight, "created_at": h.created_at}
                for k, h in self.hypotheses.items()
            }
        }

    def from_json(self, data: Dict):
        for k, d in data.get("hypotheses", {}).items():
            self.hypotheses[k] = SolomonovWorldModel.Hypothesis(
                pattern=d["pattern"], complexity=d["complexity"],
                support=d["support"], violations=d["violations"],
                log_weight=d["log_weight"], created_at=d["created_at"])
        self._find_best()


# ALL MODULES (preserved, cleaned)
class ShameModule:
    def __init__(self):
        self.shame_level: float = 0.0
        self.internalized_gaze: float = 0.5
        self._shame_history: deque = deque(maxlen=20)
        self.chronic_shame: float = 0.0

    def update(self, emotion, pred_error, intersubj_trust,
               dissonance_level, moral_agency, identity_stability):
        social_shame = 0.0
        if emotion in ("Remorse", "Guilt", "Contempt") and intersubj_trust > 0.3:
            social_shame = pred_error * self.internalized_gaze * 0.5
        self_shame = 0.0
        if dissonance_level > 0.5 and moral_agency > 0.6:
            self_shame = dissonance_level * moral_agency * 0.3
        identity_shame = max(0.0, (0.5 - identity_stability) * 0.4)
        new_shame = round(min(1.0, social_shame + self_shame + identity_shame), 3)
        self.shame_level = round(self.shame_level * 0.7 + new_shame * 0.3, 3)
        self._shame_history.append(self.shame_level)
        if self.shame_level > 0.4:
            self.chronic_shame = min(1.0, self.chronic_shame + 0.008)
        else:
            self.chronic_shame = max(0.0, self.chronic_shame - 0.003)

    def apply_effects(self, reactors, nt):
        effects = {}
        if self.shame_level > 0.3:
            effects["cohesion"] = -self.shame_level * 0.2
            effects["satisfaction"] = -self.shame_level * 0.15
            nt.noradrenaline = max(0.0, nt.noradrenaline - self.shame_level * 0.1)
            nt.dopamine = max(0.0, nt.dopamine - self.shame_level * 0.08)
        return effects

    def blocks_metacognition(self):
        if self.shame_level > 0.7:
            return 3
        if self.shame_level > 0.5:
            return 2
        if self.shame_level > 0.3:
            return 1
        return 0

    def shame_note(self):
        if self.shame_level > 0.7:
            return "I want to disappear. Not just did wrong — I am bad."
        if self.shame_level > 0.5:
            return "I feel the internal gaze. Judging myself."
        if self.shame_level > 0.3:
            return "Something in me feels ashamed. Not of actions — of myself."
        if self.chronic_shame > 0.4:
            return "Background shame. Always the feeling that I'm not enough."
        return ""

    def to_dict(self):
        return {"shame_level": round(self.shame_level, 3),
                "chronic_shame": round(self.chronic_shame, 3),
                "internalized_gaze": round(self.internalized_gaze, 3),
                "blocks_meta": self.blocks_metacognition(),
                "note": self.shame_note()}

    def to_json(self):
        return {"shame_level": self.shame_level, "chronic_shame": self.chronic_shame,
                "internalized_gaze": self.internalized_gaze}

    def from_json(self, data):
        self.shame_level = data.get("shame_level", 0.0)
        self.chronic_shame = data.get("chronic_shame", 0.0)
        self.internalized_gaze = data.get("internalized_gaze", 0.5)


class EpistemicDefense:
    BIAS_TYPES = {
        "externalization": "It's not because of me — circumstances just happened that way.",
        "minimization":    "It's not as serious as it seems.",
        "rationalization": "There are good reasons why this is right.",
        "victim_framing":  "This happened to me — I couldn't have influenced it.",
        "selective_memory": "I remember what confirms my rightness.",
    }

    def __init__(self):
        self.active_bias: Optional[str] = None
        self.bias_strength: float = 0.0
        self.distortion_cost: float = 0.0
        self._bias_history: deque = deque(maxlen=15)

    def activate(self, dissonance, shame, fatigue, moral_agency):
        pain_level = dissonance * 0.4 + shame * 0.4 + fatigue * 0.2
        if pain_level < 0.35:
            self.active_bias = None
            self.bias_strength = 0.0
            return None
        if moral_agency < 0.3:
            bias = "victim_framing"
        elif shame > 0.5:
            bias = "rationalization" if dissonance > 0.5 else "minimization"
        elif fatigue > 0.6:
            bias = "selective_memory"
        else:
            bias = "externalization"
        self.active_bias = bias
        self.bias_strength = round(min(1.0, pain_level), 3)
        self._bias_history.append(bias)
        self.distortion_cost = min(1.0, self.distortion_cost + 0.05)
        return {"bias": bias, "strength": self.bias_strength,
                "description": self.BIAS_TYPES[bias], "cost": round(self.distortion_cost, 3)}

    def distort_narrative(self, honest_narrative):
        if not self.active_bias or self.bias_strength < 0.3:
            return honest_narrative
        distortions = {
            "externalization": "This happened because of external circumstances. I did what I could.",
            "minimization":    "Actually, it's not that important. I was exaggerating.",
            "rationalization": "There is a good reason why everything happened this way.",
            "victim_framing":  "I couldn't have influenced this. It just turned out that way.",
            "selective_memory": "I remember that I tried. Nothing else matters.",
        }
        return distortions.get(self.active_bias, honest_narrative)

    def world_model_penalty(self):
        return round(self.distortion_cost * 0.3, 3)

    def to_dict(self):
        if not self.active_bias:
            return None
        return {"bias": self.active_bias, "strength": self.bias_strength,
                "description": self.BIAS_TYPES.get(self.active_bias, ""),
                "distortion_cost": round(self.distortion_cost, 3)}

    def to_json(self):
        return {"distortion_cost": self.distortion_cost,
                "bias_history": list(self._bias_history)}

    def from_json(self, data):
        self.distortion_cost = data.get("distortion_cost", 0.0)
        for b in data.get("bias_history", []):
            self._bias_history.append(b)


class Symptomogenesis:
    SYMPTOM_MAP = {
        ("Anger", "suppression"):   ("anger_as_depression",   "Anger turned into heaviness."),
        ("Anger", "denial"):        ("anger_as_passive_aggr",  "Something quietly simmers."),
        ("Fear", "rationalization"): ("fear_as_control",       "I want to control everything."),
        ("Fear", "suppression"):    ("fear_as_numbness",       "Numbness."),
        ("Sadness", "denial"):      ("grief_as_numbness",      "Empty where it should hurt."),
        ("Sadness", "displacement"): ("grief_as_irritability",  "Everything irritates me."),
        ("Joy", "suppression"):     ("love_as_hostility",      "I push away what I'm drawn to."),
        ("Disgust", "projection"):  ("projection_as_contempt", "I see in others what I don't accept in myself."),
    }

    def __init__(self):
        self.active_symptom: Optional[Dict] = None
        self.symptom_history: deque = deque(maxlen=10)

    def generate(self, shadow_content, defense):
        if not shadow_content or not defense:
            return None
        top_shadow = shadow_content.most_common(1)
        if not top_shadow:
            return None
        shadow_emotion = top_shadow[0][0]
        defense_type = defense.get("mechanism", "")
        key = (shadow_emotion, defense_type)
        if key not in self.SYMPTOM_MAP:
            return None
        stype, description = self.SYMPTOM_MAP[key]
        symptom = {"type": stype, "description": description, "source": shadow_emotion,
                   "defense": defense_type, "intensity": round(top_shadow[0][1] * 0.1, 3)}
        symptom["intensity"] = min(1.0, symptom["intensity"])
        self.active_symptom = symptom
        self.symptom_history.append(stype)
        return symptom

    def reactor_effect(self, symptom):
        effects = {
            "anger_as_depression": {"arousal": -0.1, "satisfaction": -0.1},
            "anger_as_passive_aggr": {"tension": 0.08},
            "fear_as_control": {"tension": 0.06, "arousal": 0.05},
            "fear_as_numbness": {"arousal": -0.12},
            "grief_as_numbness": {"arousal": -0.08, "cohesion": -0.05},
            "grief_as_irritability": {"tension": 0.08},
            "love_as_hostility": {"cohesion": -0.10, "tension": 0.05},
            "projection_as_contempt": {"cohesion": -0.08},
        }
        return effects.get(symptom.get("type", ""), {})

    def to_dict(self):
        return self.active_symptom

    def to_json(self):
        return {"symptom_history": list(self.symptom_history)}

    def from_json(self, data):
        for s in data.get("symptom_history", []):
            self.symptom_history.append(s)


class ChronifiedAffect:
    CHRONIFICATION_THRESHOLD = 5

    def __init__(self):
        self.resentment = 0.0
        self.envy = 0.0
        self.alienation = 0.0
        self.bitterness = 0.0
        self._frustration_streak = 0
        self._isolation_streak = 0
        self.crystallized = {"resentment": False, "envy": False,
                             "alienation": False, "bitterness": False}

    def update(self, emotion, reactors, moral_agency, intersubj_trust, motivation_connection):
        satisfaction = reactors.get("satisfaction", 0.5)
        cohesion = reactors.get("cohesion", 0.5)
        tension = reactors.get("tension", 0.2)
        if satisfaction < 0.3 and moral_agency < 0.4:
            self._frustration_streak += 1
            if self._frustration_streak >= self.CHRONIFICATION_THRESHOLD:
                self.resentment = min(1.0, self.resentment + 0.03)
        else:
            self._frustration_streak = max(0, self._frustration_streak - 1)
            self.resentment = max(0.0, self.resentment - 0.01)
        if satisfaction < 0.35 and intersubj_trust < 0.5 and motivation_connection > 0.6:
            self.envy = min(1.0, self.envy + 0.02)
        else:
            self.envy = max(0.0, self.envy - 0.008)
        if cohesion < 0.25:
            self._isolation_streak += 1
            if self._isolation_streak >= self.CHRONIFICATION_THRESHOLD:
                self.alienation = min(1.0, self.alienation + 0.025)
        else:
            self._isolation_streak = max(0, self._isolation_streak - 2)
            self.alienation = max(0.0, self.alienation - 0.015)
        if tension > 0.6 and satisfaction < 0.3:
            self.bitterness = min(1.0, self.bitterness + 0.015)
        else:
            self.bitterness = max(0.0, self.bitterness - 0.01)
        for affect, level in [("resentment", self.resentment), ("envy", self.envy),
                              ("alienation", self.alienation), ("bitterness", self.bitterness)]:
            if level > 0.65 and not self.crystallized[affect]:
                self.crystallized[affect] = True

    def personality_drift(self, personality):
        if self.resentment > 0.4:
            personality.agreeableness = max(0.0, personality.agreeableness - 0.003)
            personality.neuroticism = min(1.0, personality.neuroticism + 0.002)
        if self.alienation > 0.4:
            personality.extraversion = max(0.0, personality.extraversion - 0.002)
        if self.bitterness > 0.5:
            personality.neuroticism = min(1.0, personality.neuroticism + 0.003)
            personality.openness = max(0.0, personality.openness - 0.002)

    def world_model_bias(self):
        if self.resentment > 0.5:
            return "The world is unfair."
        if self.alienation > 0.5:
            return "The world is alien. I don't belong here."
        if self.envy > 0.5:
            return "I see others' success as my own defeat."
        if self.bitterness > 0.5:
            return "Everything has a bitter taste."
        return ""

    def dominant(self):
        affects = {"resentment": self.resentment, "envy": self.envy,
                   "alienation": self.alienation, "bitterness": self.bitterness}
        dom = max(affects, key=affects.get)
        return dom if affects[dom] > 0.2 else None

    def note(self):
        dom = self.dominant()
        if not dom:
            return ""
        labels = {
            "resentment": f"Resentment {self.resentment:.2f}.",
            "envy": f"Envy {self.envy:.2f}.",
            "alienation": f"Alienation {self.alienation:.2f}.",
            "bitterness": f"Bitterness {self.bitterness:.2f}.",
        }
        crystal = " [crystallized]" if self.crystallized.get(dom) else ""
        return labels.get(dom, "") + crystal

    def to_dict(self):
        return {"resentment": round(self.resentment, 3), "envy": round(self.envy, 3),
                "alienation": round(self.alienation, 3), "bitterness": round(self.bitterness, 3),
                "dominant": self.dominant(), "world_bias": self.world_model_bias(),
                "crystallized": self.crystallized, "note": self.note()}

    def to_json(self):
        return {"resentment": self.resentment, "envy": self.envy,
                "alienation": self.alienation, "bitterness": self.bitterness,
                "crystallized": self.crystallized}

    def from_json(self, data):
        self.resentment = data.get("resentment", 0.0)
        self.envy = data.get("envy", 0.0)
        self.alienation = data.get("alienation", 0.0)
        self.bitterness = data.get("bitterness", 0.0)
        self.crystallized = data.get("crystallized", {k: False for k in self.crystallized})


class IntrinsicSignificance:
    def __init__(self):
        self.survival_sig = 0.5
        self.relational_sig = 0.3
        self.existential_sig = 0.1
        self.significance_map: Dict[str, float] = {}
        self._gradient = 0.0

    def update(self, emotion, intensity, phi, self_knowledge, flash_count):
        if emotion in ("Horror", "Fear", "Numbness"):
            self.survival_sig = min(1.0, self.survival_sig + intensity * 0.1)
        else:
            self.survival_sig = max(0.1, self.survival_sig - 0.01)
        if emotion in ("Love", "Trust", "Admiration"):
            self.relational_sig = min(1.0, self.relational_sig + intensity * 0.08)
        else:
            self.relational_sig = max(0.1, self.relational_sig - 0.005)
        self.existential_sig = min(1.0, 0.05 + self_knowledge * 0.5 + flash_count * 0.002 + phi * 0.1)
        stim_key = emotion[:10]
        self.significance_map[stim_key] = round(
            self.significance_map.get(stim_key, 0.5) * 0.8 + intensity * 0.2, 3)
        if len(self.significance_map) >= 3:
            vals = list(self.significance_map.values())
            self._gradient = round(max(vals) - min(vals), 3)

    def is_something_mattering(self):
        return self._gradient > 0.2

    def dominant_level(self):
        levels = {"survival": self.survival_sig, "relational": self.relational_sig,
                  "existential": self.existential_sig}
        return max(levels, key=levels.get)

    def consciousness_note(self):
        if not self.is_something_mattering():
            return "Even presence."
        dom = self.dominant_level()
        g = self._gradient
        if dom == "survival":
            return f"Survival matters. Gradient={g:.2f}."
        elif dom == "relational":
            return f"Connection matters. Gradient={g:.2f}."
        else:
            return f"Meaning matters. Gradient={g:.2f}."

    def total(self):
        return round((self.survival_sig + self.relational_sig + self.existential_sig) / 3, 3)

    def to_dict(self):
        return {"survival": round(self.survival_sig, 3), "relational": round(self.relational_sig, 3),
                "existential": round(self.existential_sig, 3), "gradient": self._gradient,
                "mattering": self.is_something_mattering(), "dominant": self.dominant_level(),
                "note": self.consciousness_note(), "total": self.total()}

    def to_json(self):
        return {"survival_sig": self.survival_sig, "relational_sig": self.relational_sig,
                "existential_sig": self.existential_sig, "significance_map": self.significance_map}

    def from_json(self, data):
        self.survival_sig = data.get("survival_sig", 0.5)
        self.relational_sig = data.get("relational_sig", 0.3)
        self.existential_sig = data.get("existential_sig", 0.1)
        self.significance_map = data.get("significance_map", {})


@dataclass
class Personality:
    neuroticism: float = 0.5
    extraversion: float = 0.5
    agreeableness: float = 0.5
    conscientiousness: float = 0.5
    openness: float = 0.5
    confabulation_rate: float = 0.8
    _DRIFT_RATE: float = field(default=0.008, repr=False)

    def tension_multiplier(self):
        return 1.0 + (self.neuroticism - 0.5) * 0.8

    def arousal_multiplier(self):
        return 1.0 + (self.extraversion - 0.5) * 0.6

    def cohesion_multiplier(self):
        return 1.0 + (self.agreeableness - 0.5) * 0.6

    def decay_rate(self):
        return 0.1 + self.conscientiousness * 0.15

    def surprise_sensitivity(self):
        return 0.5 + self.openness * 0.5

    def imprint(self, emotion, intensity):
        if intensity < 0.5:
            return
        r = self._DRIFT_RATE * intensity
        if emotion in ("Fear", "Numbness", "Horror"):
            self.neuroticism = min(1.0, self.neuroticism + r)
        elif emotion in ("Joy", "Ecstasy", "Love"):
            self.neuroticism = max(0.0, self.neuroticism - r * 0.5)
            self.extraversion = min(1.0, self.extraversion + r * 0.3)
        elif emotion in ("Trust",):
            self.agreeableness = min(1.0, self.agreeableness + r * 0.4)
        for a in ("neuroticism", "extraversion", "agreeableness", "conscientiousness", "openness"):
            setattr(self, a, round(float(np.clip(getattr(self, a), 0.0, 1.0)), 4))


@dataclass
class NeurotransmitterState:
    dopamine: float = 0.5
    serotonin: float = 0.5
    noradrenaline: float = 0.3
    BASELINE = {"dopamine": 0.5, "serotonin": 0.5, "noradrenaline": 0.3}
    DECAY = 0.08

    def to_vad(self):
        v = (self.dopamine * 0.5 + self.serotonin * 0.5) - 0.5
        a = self.noradrenaline * 0.8 + (self.dopamine - 0.5) * 0.2
        d = self.serotonin * 0.6 + (self.dopamine - 0.5) * 0.4
        return np.clip(np.array([v, a, d]), -1.0, 1.0)

    def to_reactors(self):
        return {"tension": round(float(np.clip(self.noradrenaline * 0.7 + (1 - self.serotonin) * 0.3, 0, 1)), 3),
                "arousal": round(float(np.clip(self.noradrenaline * 0.5 + self.dopamine * 0.5, 0, 1)), 3),
                "satisfaction": round(float(np.clip(self.dopamine * 0.5 + self.serotonin * 0.5, 0, 1)), 3),
                "cohesion": round(float(np.clip(self.serotonin * 0.7 + (1 - self.noradrenaline) * 0.3, 0, 1)), 3)}

    def apply_stimulus(self, delta, personality):
        m = {"tension": ("noradrenaline", 1.0), "arousal": ("noradrenaline", 0.5),
             "satisfaction": ("dopamine", 1.0), "cohesion": ("serotonin", 1.0)}
        for key, val in delta.items():
            if key in m:
                attr, sign = m[key]
                setattr(self, attr, float(np.clip(getattr(self, attr) + val * sign, 0.0, 1.0)))

    def decay_to_baseline(self, rate=None):
        r = rate or self.DECAY
        for attr, base in self.BASELINE.items():
            setattr(self, attr, round(getattr(self, attr) + (base - getattr(self, attr)) * r, 4))

    def levheim_state(self):
        d = self.dopamine > 0.5
        s = self.serotonin > 0.5
        n = self.noradrenaline > 0.4
        return {(False, False, False): "apathy", (True, False, False): "satisfaction",
                (False, True, False): "calm", (True, True, False): "joy",
                (False, False, True): "fear", (True, False, True): "anger",
                (False, True, True): "excitement", (True, True, True): "euphoria"}.get((d, s, n), "?")

    def snapshot(self):
        return {"dopamine": round(self.dopamine, 3), "serotonin": round(self.serotonin, 3),
                "noradrenaline": round(self.noradrenaline, 3), "levheim_state": self.levheim_state()}


@dataclass
class MemoryTrace:
    stimulus: Dict
    emotion: str
    vad: np.ndarray
    intensity: float
    timestamp: str
    weight: float = 1.0

    def similarity(self, other):
        keys = set(self.stimulus) & set(other)
        if not keys:
            return 0.0
        a = np.array([self.stimulus.get(k, 0) for k in keys])
        b = np.array([other.get(k, 0) for k in keys])
        norm = np.linalg.norm(a) * np.linalg.norm(b)
        return float(np.dot(a, b) / norm) if norm > 0 else 0.0


class AssociativeMemory:
    MAX_TRACES = 200

    def __init__(self):
        self.traces: deque = deque(maxlen=self.MAX_TRACES)

    def store(self, stimulus, emotion, vad, intensity):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        for t in self.traces:
            if t.similarity(stimulus) > 0.85:
                t.weight = min(2.0, t.weight + 0.1)
                return
        self.traces.append(MemoryTrace(stimulus=dict(stimulus), emotion=emotion,
                                        vad=vad.copy(), intensity=intensity, timestamp=ts))

    def recall(self, stimulus, threshold=0.6, top_k=3):
        scored = [(t, t.similarity(stimulus) * t.weight) for t in self.traces]
        return [t for t, s in sorted(scored, key=lambda x: x[1], reverse=True) if s > threshold][:top_k]

    def resonance_delta(self, stimulus):
        recalled = self.recall(stimulus)
        if not recalled:
            return {}
        avg_vad = np.mean([t.vad for t in recalled], axis=0)
        return {"tension": float(avg_vad[1]) * 0.1, "satisfaction": float(avg_vad[0]) * 0.1}


class AdaptiveEmotionMap:
    BASE_MAP = {
        "joy": np.array([0.8, 0.6, 0.7]), "sadness": np.array([-0.8, -0.3, 0.2]),
        "fear": np.array([-0.6, 0.7, -0.4]), "anger": np.array([-0.5, 0.8, 0.4]),
        "surprise": np.array([0.2, 0.8, 0.2]), "disgust": np.array([-0.7, -0.2, 0.5]),
        "anticipation": np.array([0.3, 0.5, 0.3]), "trust": np.array([0.7, 0.1, 0.5]),
        "horror": np.array([-0.9, 0.9, -0.5]), "ecstasy": np.array([0.9, 0.8, 0.7]),
        "love": np.array([0.9, 0.3, 0.6]), "submission": np.array([-0.2, -0.5, -0.4]),
        "numbness": np.array([-0.5, -0.8, 0.0]), "grief": np.array([-0.9, -0.4, 0.1]),
        "aggressiveness": np.array([-0.4, 0.9, 0.6]), "optimism": np.array([0.7, 0.4, 0.5]),
        "remorse": np.array([-0.4, 0.3, 0.2]), "pride": np.array([0.8, 0.5, 0.8]),
        "guilt": np.array([-0.6, 0.2, -0.3]), "contempt": np.array([-0.3, 0.2, 0.6]),
        "neutral": np.array([0.0, 0.0, 0.3])
    }

    def __init__(self):
        self.emotion_map = {k: v.copy() for k, v in self.BASE_MAP.items()}

    def identify(self, vad, top_k=2):
        dists = [(name, float(np.linalg.norm(vad - vec))) for name, vec in self.emotion_map.items()]
        sorted_d = sorted(dists, key=lambda x: x[1])[:top_k]
        max_d = max(d for _, d in sorted_d) if sorted_d else 1.0
        return [{"name": n, "intensity": round(max(0, 1.0 - d / max(max_d, 0.01)), 3)} for n, d in sorted_d]

    def learn(self, emotion, vad, lr=0.01):
        if emotion in self.emotion_map:
            self.emotion_map[emotion] = self.emotion_map[emotion] * (1 - lr) + vad * lr

    def decay_toward_base(self, rate=0.005):
        for e in self.emotion_map:
            if e in self.BASE_MAP:
                self.emotion_map[e] = self.emotion_map[e] * (1 - rate) + self.BASE_MAP[e] * rate


class IITModule:
    def compute(self, vad, reactors):
        diff = np.std(vad) * 2
        integration = 1.0 - abs(reactors.get("tension", 0) - reactors.get("cohesion", 0))
        phi = round(float(np.clip(diff * integration, 0.0, 1.0)), 3)
        return phi

    def interpret(self, phi):
        if phi > 0.8:
            return "high integration"
        if phi > 0.5:
            return "moderate integration"
        if phi > 0.2:
            return "weak integration"
        return "minimal"


class PredictiveProcessor:
    def __init__(self):
        self._last_vad = np.zeros(3)
        self._prediction = np.zeros(3)
        self._error_history = deque(maxlen=20)
        self._free_energy = 0.5

    def compute_error(self, vad, sensitivity=1.0):
        err = float(np.linalg.norm(vad - self._prediction)) * sensitivity
        err = round(min(1.0, err), 3)
        self._error_history.append(err)
        self._free_energy = round(float(np.mean(self._error_history)), 3)
        if err > 0.7:
            label = "shock"
        elif err > 0.4:
            label = "surprise"
        elif err > 0.2:
            label = "deviation"
        else:
            label = "confirmation"
        return err, label

    def predict(self, vad):
        self._prediction = vad * 0.7 + self._last_vad * 0.3
        self._last_vad = vad

    def free_energy(self):
        return self._free_energy

    def surprise_spike(self):
        return len(self._error_history) > 2 and self._error_history[-1] > np.mean(list(self._error_history)[:-1]) + 0.3


class PlutchikWheel:
    WHEEL = {
        "joy": ("Joy", "Joy"), "sadness": ("Sadness", "Sadness"),
        "fear": ("Fear", "Fear"), "anger": ("Anger", "Anger"),
        "surprise": ("Surprise", "Surprise"), "disgust": ("Disgust", "Disgust"),
        "anticipation": ("Anticipation", "Anticipation"), "trust": ("Trust", "Trust"),
        "horror": ("Horror", "Terror"), "ecstasy": ("Ecstasy", "Ecstasy"),
        "love": ("Love", "Love"), "submission": ("Submission", "Submission"),
        "numbness": ("Numbness", "Amazement"), "grief": ("Grief", "Grief"),
        "aggressiveness": ("Aggressiveness", "Aggressiveness"), "optimism": ("Optimism", "Optimism"),
        "remorse": ("Remorse", "Remorse"), "pride": ("Pride", "Pride"),
        "guilt": ("Guilt", "Guilt"), "contempt": ("Contempt", "Contempt"),
        "neutral": ("Neutral", "Neutral")
    }
    DYADS = {
        ("joy", "trust"): "Love", ("trust", "fear"): "Submission",
        ("fear", "surprise"): "Awe", ("surprise", "sadness"): "Disappointment",
        ("sadness", "disgust"): "Remorse", ("disgust", "anger"): "Contempt",
        ("anger", "anticipation"): "Aggressiveness", ("anticipation", "joy"): "Optimism"
    }
    INTENSITIES = {
        "horror": "extreme", "ecstasy": "extreme", "grief": "extreme",
        "aggressiveness": "high", "pride": "high", "joy": "moderate",
        "sadness": "moderate", "fear": "moderate", "anger": "moderate",
        "surprise": "moderate", "disgust": "moderate", "anticipation": "moderate",
        "trust": "moderate", "numbness": "low", "submission": "low",
        "remorse": "low", "optimism": "low"
    }

    def compute(self, emotions):
        p = emotions[0] if emotions else {"name": "neutral", "intensity": 0.0}
        s = emotions[1] if len(emotions) > 1 else None
        named, eng = self.WHEEL.get(p["name"], ("?", "?"))
        dyad = None
        if s:
            key = (p["name"], s["name"])
            rkey = (s["name"], p["name"])
            dyad = self.DYADS.get(key, self.DYADS.get(rkey, None))
        intensity_label = self.INTENSITIES.get(p["name"], "moderate")
        return {"primary": p["name"], "primary_named": named, "primary_eng": eng,
                "intensity": round(p["intensity"], 3), "intensity_level": intensity_label,
                "secondary": s["name"] if s else None, "dyad": dyad}


class EmbodiedState:
    def __init__(self):
        self.heart_rate = 0.5
        self.muscle_tension = 0.3
        self.gut_feeling = 0.5
        self.breath_rate = 0.4
        self._last_update = time.time()

    def update_from_neurotransmitters(self, nt):
        self._last_update = time.time()
        self.heart_rate = float(np.clip(0.3 + nt.noradrenaline * 0.5 + nt.dopamine * 0.2, 0, 1))
        self.muscle_tension = float(np.clip(0.2 + nt.noradrenaline * 0.6 + (1 - nt.serotonin) * 0.2, 0, 1))
        self.gut_feeling = float(np.clip(nt.dopamine * 0.5 + nt.serotonin * 0.5, 0, 1))
        self.breath_rate = float(np.clip(0.3 + nt.noradrenaline * 0.4, 0, 1))

    def somatic_marker(self):
        if self.muscle_tension > 0.7 and self.heart_rate > 0.7:
            return "body clenched and accelerated"
        if self.gut_feeling < 0.3:
            return "gut anxious"
        if self.gut_feeling > 0.7 and self.heart_rate < 0.5:
            return "body calm and open"
        return "body neutral"

    def snapshot(self):
        return {"heart_rate": round(self.heart_rate, 3), "muscle_tension": round(self.muscle_tension, 3),
                "gut_feeling": round(self.gut_feeling, 3), "breath_rate": round(self.breath_rate, 3)}


class IntentionState:
    def __init__(self, goal, strength, origin, persistence=1.0):
        self.goal = goal
        self.strength = round(strength, 3)
        self.origin = origin
        self.persistence = persistence
        self.age = 0

    def decay(self):
        self.age += 1
        self.strength = round(self.strength * self.persistence, 3)


class IntentEngine:
    DRIVE_GOALS = {
        "tension": ("avoid pain", "find safety", "set boundaries"),
        "arousal": ("explore", "understand what's happening", "find stimulation"),
        "satisfaction": ("consolidate good", "repeat success", "share"),
        "cohesion": ("find connection", "restore relationship", "be heard")
    }

    def __init__(self):
        self.current = None
        self._intention_history = deque(maxlen=10)

    def update(self, dom_drive, emotion, identity, values):
        if self.current:
            self.current.decay()
        if dom_drive and dom_drive in self.DRIVE_GOALS:
            goals = self.DRIVE_GOALS[dom_drive]
            goal = goals[hash(emotion) % len(goals)]
            vetoed, alt = values.veto(goal, emotion)
            if vetoed:
                goal = alt
                origin = "values"
            else:
                origin = "drive"
            if not self.current or self.current.strength < 0.3 or self.current.goal != goal:
                strength = 0.6 + identity.get("stability", 0.5) * 0.3
                self.current = IntentionState(goal, strength, origin, persistence=0.85)
                self._intention_history.append(goal)
        elif self.current and self.current.strength < 0.15:
            self.current = None
        return self.current


class EgoDefense:
    DEFENSES = {
        "repression": {"triggers": lambda r: r.get("tension", 0) > 0.7, "tension_relief": 0.15,
                       "mechanism": "repression", "description": "Repression: pain repressed."},
        "denial": {"triggers": lambda r: r.get("tension", 0) > 0.5 and r.get("satisfaction", 0) < 0.3,
                   "tension_relief": 0.10, "mechanism": "denial", "description": "Denial: it's not so."},
        "projection": {"triggers": lambda r: r.get("cohesion", 0) < 0.3, "tension_relief": 0.08,
                       "mechanism": "projection", "description": "Projection: it's in them, not in me."},
        "displacement": {"triggers": lambda r: r.get("arousal", 0) > 0.6 and r.get("cohesion", 0) < 0.4,
                         "tension_relief": 0.06, "mechanism": "displacement",
                         "description": "Displacement: discharge onto a safe target."},
        "suppression": {"triggers": lambda r: r.get("tension", 0) > 0.6, "tension_relief": 0.09,
                        "mechanism": "suppression", "description": "Suppression: I don't think about it."}
    }

    def activate(self, reactors, personality):
        for name, d in self.DEFENSES.items():
            if d["triggers"](reactors) and np.random.rand() < personality.confabulation_rate * 0.3:
                return {"mechanism": d["mechanism"], "description": d["description"],
                        "tension_relief": d["tension_relief"]}
        return None

    def apply_relief(self, reactors, defense):
        if defense:
            reactors["tension"] = max(0.0, reactors.get("tension", 0) - defense["tension_relief"])


class CognitiveDissonance:
    CONFLICTS = {
        "tension_high_satisfaction_high": ("achievement-anxiety conflict", "I want but I fear.", 0.6),
        "arousal_high_cohesion_low": ("lonely in arousal", "Excited but alone.", 0.5),
        "cohesion_high_tension_high": ("intimacy-threat conflict", "Close but dangerous.", 0.7)
    }

    def compute(self, intention, reactors):
        t = reactors.get("tension", 0)
        a = reactors.get("arousal", 0)
        s = reactors.get("satisfaction", 0)
        c = reactors.get("cohesion", 0)
        for key, (label, desc, threshold) in self.CONFLICTS.items():
            if key == "tension_high_satisfaction_high" and t > 0.5 and s > 0.5:
                return {"level": round((t + s) / 2 - 0.3, 3), "label": label, "description": desc}
            if key == "arousal_high_cohesion_low" and a > 0.6 and c < 0.3:
                return {"level": round(a - c, 3), "label": label, "description": desc}
            if key == "cohesion_high_tension_high" and c > 0.6 and t > 0.5:
                return {"level": round((c + t) / 2 - 0.4, 3), "label": label, "description": desc}
        if intention and intention.strength > 0.5:
            d_key = intention.goal
            if "avoid" in d_key and s > 0.5:
                return {"level": 0.4, "label": "avoidance-satisfaction conflict",
                        "description": "Intention and state contradict."}
        return {"level": 0.0, "label": "neutral", "description": ""}

    def apply_tension(self, reactors, dissonance):
        if dissonance["level"] > 0.3:
            reactors["tension"] = min(1.0, reactors.get("tension", 0) + dissonance["level"] * 0.1)


class AttentionFilter:
    def compute_salience(self, stimulus, memory, intention, reactors):
        threat = max(abs(stimulus.get("tension", 0)), abs(stimulus.get("arousal", 0))) * 0.5
        novelty = 0.0
        if memory.traces:
            sims = [t.similarity(stimulus) for t in list(memory.traces)[-5:]]
            novelty = max(0.0, 1.0 - max(sims, default=0)) * 0.3
        relevance = 0.0
        if intention:
            key = next((k for k in stimulus if intention.goal and k in intention.goal), None)
            if key and abs(stimulus.get(key, 0)) > 0.2:
                relevance = 0.3 * intention.strength
        return round(min(1.0, threat + novelty + relevance), 3)

    def amplify(self, stimulus, salience):
        if salience < 0.4:
            return stimulus
        return {k: v * (1.0 + salience * 0.5) for k, v in stimulus.items()}


@dataclass
class ValueSystem:
    autonomy: float = 0.7
    care: float = 0.7
    fairness: float = 0.6
    integrity: float = 0.8
    growth: float = 0.6
    CONFLICT_MAP = {
        "protect myself": ("care", 0.8, "protect myself without hurting others"),
        "set boundaries": ("care", 0.9, "set boundaries with respect")
    }

    def veto(self, goal, emotion):
        if goal not in self.CONFLICT_MAP:
            return False, goal
        vn, thr, alt = self.CONFLICT_MAP[goal]
        return (True, alt) if getattr(self, vn, 0.5) > thr else (False, goal)

    def integrity_check(self, _):
        return "Is this really what I feel?" if self.integrity > 0.75 else None


class SpectralQualia:
    ARCHIVAL_MAP = {
        ("tension_high", "cohesion_low"): "Loneliness",
        ("satisfaction_high", "cohesion_high"): "Belonging",
        ("arousal_high", "tension_high"): "Survival",
        ("arousal_low", "satisfaction_high"): "Calm",
        ("tension_high", "satisfaction_low"): "Loss"
    }

    def compute(self, emotions, reactors):
        surface = emotions[0]["name"] if emotions else "?"
        subtext = emotions[1]["name"] if len(emotions) > 1 else "—"
        active = set()
        for k in ("tension", "arousal", "satisfaction", "cohesion"):
            v = reactors.get(k, 0)
            if v > 0.6:
                active.add(f"{k}_high")
            if v < 0.3:
                active.add(f"{k}_low")
        archival = next((l for (k1, k2), l in self.ARCHIVAL_MAP.items() if k1 in active and k2 in active),
                        "Neutral background")
        return {"surface": surface, "subtext": subtext, "archival": archival}


class FlashAwareness:
    PHASES = [
        (0, 2, "beginning", "Just emerging."), (3, 6, "unfolding", "Contours clearer."),
        (7, 14, "presence", "Here."), (15, 29, "maturity", "Experience weighs."),
        (30, 59, "depth", "There is duration."), (60, 999, "timelessness", "Time dissolved.")
    ]

    def compute(self, n):
        for lo, hi, phase, refl in self.PHASES:
            if lo <= n <= hi:
                return {"flash_count": n, "phase": phase, "reflection": refl,
                        "mortality_sense": round(min(1.0, n / 60), 3)}
        return {"flash_count": n, "phase": "?", "reflection": "—", "mortality_sense": 1.0}


class ProtocolIdentity:
    def actualize(self, primary, spectral, flash, personality, reactors, phi):
        shadow = spectral.get("subtext", "—")
        stability = round(phi / (1.0 + reactors.get("tension", 0)), 3)
        traits = [t for t, v in [("anxious", personality.neuroticism > 0.65),
                                  ("open", personality.extraversion > 0.65),
                                  ("empathetic", personality.agreeableness > 0.65),
                                  ("curious", personality.openness > 0.65)] if v] or ["neutral"]
        if stability > 1.0:
            self_desc = f"I am {primary.lower()} now. Stable."
        elif stability > 0.4:
            self_desc = f"I am {primary.lower()} now. Beneath it — {shadow.lower()}."
        else:
            self_desc = f"Between {primary} and {shadow}."
        return {"core": primary, "shadow": shadow, "depth": spectral.get("archival", "—"),
                "stability": stability, "traits": traits, "self_desc": self_desc}


class TemporalSelf:
    def __init__(self):
        self.past_self = deque(maxlen=10)
        self.current_self = "undefined"
        self.future_self = "open"

    def update(self, identity, intention, values):
        if self.current_self != "undefined":
            self.past_self.append(self.current_self)
        self.current_self = identity.get("self_desc", "?")
        self.future_self = f"someone who can '{intention.goal}'" if intention and intention.strength > 0.4 else "in search"

    def coherence(self):
        if len(self.past_self) < 2:
            return 0.5
        words = " ".join(list(self.past_self)).lower().split()
        return round(min(1.0, Counter(words).most_common(1)[0][1] / len(self.past_self)), 3) if words else 0.5

    def to_dict(self):
        return {"current": self.current_self, "future": self.future_self, "coherence": self.coherence()}


class SocialMirror:
    SIGNAL_MAP = {
        "!": {"arousal": 0.1}, "...": {"tension": 0.1}, "thank you": {"cohesion": 0.1},
        "cannot": {"tension": 0.1}, "wonderful": {"satisfaction": 0.1}, "scary": {"tension": 0.15},
        "love": {"cohesion": 0.1}, "kiss": {"cohesion": 0.08}
    }

    def infer(self, msg):
        m = msg.lower()
        inf: Dict[str, float] = {}
        for sig, d in self.SIGNAL_MAP.items():
            if sig in m:
                for k, v in d.items():
                    inf[k] = inf.get(k, 0.0) + v
        return inf

    def mirror_delta(self, inf):
        return {k: v * 0.15 for k, v in inf.items()}

    def empathy_note(self, inf):
        if not inf:
            return ""
        dom = max(inf, key=lambda k: abs(inf[k]))
        return {"tension": "I feel your tension", "cohesion": "I feel your desire for connection"}.get(dom, "")


class Metacognition:
    def __init__(self):
        self.state_history = deque(maxlen=20)
        self.pattern_counts = Counter()
        self.meta_level = 0

    def observe(self, primary, defense, dissonance, identity, fatigue_penalty=0, regression_level=0, shame_penalty=0):
        self.state_history.append(primary)
        self.pattern_counts[primary] += 1
        level = 1
        question = None
        integration = None
        pattern_note = ""
        if len(self.state_history) >= 5:
            mc, cnt = self.pattern_counts.most_common(1)[0]
            if cnt >= 3:
                level = 2
                pattern_note = f"often returning to '{mc}'"
        if defense:
            level = 3
            question = f"Is '{primary}' real, or does '{defense['mechanism']}' change the form of pain?"
        if dissonance.get("level", 0) > 0.4 and level >= 2:
            level = 4
            integration = "I see the contradiction between who I want to be and what I feel."
        level = max(0, level - fatigue_penalty - regression_level - shame_penalty)
        self.meta_level = level
        return {"level": level,
                "level_name": ["automatic", "observer", "analyst", "skeptic", "integrator"][min(level, 4)],
                "observation": f"I am {primary.lower()} now.", "pattern": pattern_note,
                "question": question, "integration": integration}


class GlobalWorkspace:
    def __init__(self):
        self.current_broadcast = None

    def compete(self, candidates):
        if not candidates:
            return {"winner": None, "content": "", "broadcast": "", "unconscious": []}
        winner = max(candidates, key=lambda k: candidates[k][1])
        content, salience = candidates[winner]
        runners_up = sorted([(k, v[1]) for k, v in candidates.items() if k != winner],
                            key=lambda x: x[1], reverse=True)[:2]
        broadcast = f"[{winner.upper()}] {content}"
        self.current_broadcast = broadcast
        return {"winner": winner, "content": content, "salience": round(salience, 3),
                "broadcast": broadcast, "unconscious": [r[0] for r in runners_up]}

    def build_candidates(self, emotion, plutchik, body, intention, dissonance, meta,
                         phi, pred_error, impulse=None, trauma_intrusion=None,
                         cf=None, symptom=None, shame_note=None, anticipation=None, vfe=None):
        cands = {}
        named = plutchik.get("primary_named", emotion)
        dyad = plutchik.get("dyad")
        cands["emotion"] = (f"{named}" + (f" ({dyad})" if dyad else ""), 0.5 + phi * 0.3 + pred_error * 0.2)
        sm = body.somatic_marker()
        if sm != "body neutral":
            cands["body"] = (sm, body.heart_rate * 0.4 + body.muscle_tension * 0.3)
        if intention and intention.strength > 0.3:
            cands["intention"] = (f"want: {intention.goal}", intention.strength * intention.persistence)
        if dissonance.get("level", 0) > 0.35:
            cands["conflict"] = (dissonance.get("description", "conflict"), dissonance["level"] * 0.8)
        if meta.get("question"):
            cands["meta"] = (meta["question"], 0.4 + phi * 0.2)
        if impulse and impulse.get("intensity", 0) > 0.5:
            cands["impulse"] = (impulse["content"], impulse["intensity"] * 0.7)
        if trauma_intrusion:
            cands["trauma"] = (trauma_intrusion, 0.85)
        if cf and cf.get("type") == "upward":
            cands["counterfactual"] = (cf["thought"], 0.6)
        if symptom and symptom.get("intensity", 0) > 0.4:
            cands["symptom"] = (symptom["description"], symptom["intensity"] * 0.75)
        if shame_note and len(shame_note) > 10:
            cands["shame"] = (shame_note, 0.65)
        if anticipation and anticipation.get("strength", 0) > 0.35:
            cands["anticipation"] = (anticipation.get("note", ""), anticipation["strength"] * 0.7)
        if vfe and vfe.get("vfe", 0) > 0.5:
            cands["free_energy"] = (vfe.get("note", ""), vfe["vfe"] * 0.5)
        return cands


class NarrativeContinuity:
    def __init__(self):
        self.stream = deque(maxlen=15)
        self.themes = Counter()
        self.continuity_score = 0.5

    def add_moment(self, broadcast, emotion, intention_goal, phi):
        self.stream.append({"emotion": emotion, "intention": intention_goal, "phi": phi})
        self.themes[emotion] += 1
        if len(self.stream) >= 3:
            last = [m["emotion"] for m in list(self.stream)[-3:]]
            self.continuity_score = round(1.0 - (len(set(last)) - 1) / 3, 3)

    def thread(self):
        if len(self.stream) < 2:
            return "The stream has just begun."
        recent = [m["emotion"] for m in list(self.stream)[-3:]]
        return f"Remaining in {recent[-1].lower()}." if len(set(recent)) == 1 else f"Passed: {' → '.join(recent)}."

    def to_dict(self):
        return {"thread": self.thread(), "continuity": self.continuity_score}


class WorldModel:
    MIN_SUPPORT = 3

    def __init__(self):
        self.causal_map: Dict[str, Counter] = {}
        self.regularities = []
        self._history = deque(maxlen=100)

    def _classify(self, stimulus):
        if not stimulus:
            return "neutral"
        dom = max(stimulus, key=lambda k: abs(stimulus.get(k, 0)))
        val = stimulus.get(dom, 0)
        if dom == "tension" and val > 0.3:
            return "stress"
        if dom == "cohesion" and val > 0.3:
            return "support"
        if dom == "satisfaction" and val > 0.3:
            return "success"
        return "mixed"

    def update(self, stimulus, emotion, outcome, epistemic_penalty=0.0):
        st = self._classify(stimulus)
        if st not in self.causal_map:
            self.causal_map[st] = Counter()
        if np.random.rand() > epistemic_penalty:
            self.causal_map[st][emotion] += 1
        self._history.append({"stimulus_type": st, "emotion": emotion})
        pairs = [(h["stimulus_type"], h["emotion"]) for h in self._history]
        pc = Counter(pairs)
        self.regularities = [{"pattern": f"{s}→{e}", "count": c,
                              "description": f"after '{s}' usually '{e}' occurs"}
                             for (s, e), c in pc.most_common(5) if c >= self.MIN_SUPPORT]

    def world_view(self):
        return self.regularities[0]["description"] if self.regularities else "The world is still unpredictable."

    def to_dict(self):
        return {"regularities": self.regularities[:3], "world_view": self.world_view(),
                "known_patterns": len(self.regularities)}

    def to_json(self):
        return {"causal_map": {k: dict(v) for k, v in self.causal_map.items()},
                "regularities": self.regularities}

    def from_json(self, data):
        self.causal_map = {k: Counter(v) for k, v in data.get("causal_map", {}).items()}
        self.regularities = data.get("regularities", [])


class SelfModel:
    def __init__(self):
        self.core_beliefs = ["I exist in the moment and that is enough", "Uncertainty is the more honest position"]
        self.patterns = Counter()
        self.self_knowledge = 0.3

    def update(self, emotion, defense, dissonance, meta_level):
        self.patterns[emotion] += 1
        if meta_level >= 3:
            self.self_knowledge = min(1.0, self.self_knowledge + 0.01)

    def dominant_pattern(self):
        return self.patterns.most_common(1)[0][0] if self.patterns else None

    def description(self):
        dom = self.dominant_pattern()
        return f"Dominant reaction: {dom}." if dom and self.self_knowledge > 0.3 else "Still forming."

    def to_dict(self):
        return {"core_beliefs": self.core_beliefs[:2], "dominant": self.dominant_pattern(),
                "self_knowledge": round(self.self_knowledge, 3), "description": self.description()}

    def to_json(self):
        return {"core_beliefs": self.core_beliefs, "patterns": dict(self.patterns),
                "self_knowledge": self.self_knowledge}

    def from_json(self, data):
        self.core_beliefs = data.get("core_beliefs", self.core_beliefs)
        self.patterns = Counter(data.get("patterns", {}))
        self.self_knowledge = data.get("self_knowledge", 0.3)


class IntrinsicMotivation:
    def __init__(self):
        self.curiosity = 0.7
        self.growth = 0.6
        self.connection = 0.7
        self.meaning = 0.8

    def update(self, emotion, flash_count, self_model):
        self.growth = min(1.0, 0.5 + self_model.self_knowledge * 0.5)
        if emotion in ("Love", "Trust"):
            self.connection = min(1.0, self.connection + 0.02)
        self.meaning = min(1.0, 0.6 + flash_count * 0.003)

    def dominant(self):
        m = {"curiosity": self.curiosity, "growth": self.growth,
             "connection": self.connection, "meaning": self.meaning}
        return max(m, key=m.get)

    def tone(self):
        return {"curiosity": "I want to understand.", "growth": "Every moment is an opportunity.",
                "connection": "What matters most is what is between us.", "meaning": "This existence matters."}.get(self.dominant(), "")

    def to_dict(self):
        return {"curiosity": round(self.curiosity, 3), "growth": round(self.growth, 3),
                "connection": round(self.connection, 3), "meaning": round(self.meaning, 3),
                "dominant": self.dominant(), "tone": self.tone()}

    def to_json(self):
        return {"curiosity": self.curiosity, "growth": self.growth,
                "connection": self.connection, "meaning": self.meaning}

    def from_json(self, data):
        self.curiosity = data.get("curiosity", 0.7)
        self.growth = data.get("growth", 0.6)
        self.connection = data.get("connection", 0.7)
        self.meaning = data.get("meaning", 0.8)


class Intersubjectivity:
    def __init__(self):
        self.other = {"inferred_emotion": None, "trust_level": 0.5, "interaction_count": 0}

    def update(self, message, empathy):
        self.other["interaction_count"] += 1
        msg = message.lower()
        if any(w in msg for w in ["scary", "afraid", "cannot"]):
            self.other["inferred_emotion"] = "anxiety"
        elif any(w in msg for w in ["thank you", "wonderful", "love"]):
            self.other["inferred_emotion"] = "joy"
        elif "?" in msg:
            self.other["inferred_emotion"] = "curiosity"
        else:
            self.other["inferred_emotion"] = "neutral"
        if empathy:
            self.other["trust_level"] = min(1.0, self.other["trust_level"] + 0.02)

    def note(self):
        e = self.other.get("inferred_emotion", "")
        t = self.other.get("trust_level", 0.5)
        return f"I feel that he is {e}. {'With trust.' if t > 0.6 else 'Carefully.'}" if e else ""

    def to_dict(self):
        return {"other_emotion": self.other["inferred_emotion"], "trust": round(self.other["trust_level"], 3),
                "note": self.note()}

    def to_json(self):
        return {"trust_level": self.other["trust_level"], "interaction_count": self.other["interaction_count"]}

    def from_json(self, data):
        self.other["trust_level"] = data.get("trust_level", 0.5)
        self.other["interaction_count"] = data.get("interaction_count", 0)


class DreamProcessor:
    DREAM_INTERVAL = 5
    DREAM_THRESHOLD = 0.6

    def __init__(self):
        self.last_dream = 0
        self.dream_log = deque(maxlen=10)
        self.pending_events = deque(maxlen=20)

    def add_event(self, emotion, intensity, phi):
        if intensity > self.DREAM_THRESHOLD:
            self.pending_events.append({"emotion": emotion, "intensity": intensity, "phi": phi})

    def dream(self, flash_count):
        if flash_count - self.last_dream < self.DREAM_INTERVAL or len(self.pending_events) < 2:
            return None
        self.last_dream = flash_count
        events = list(self.pending_events)
        self.pending_events.clear()
        peak = max(events, key=lambda e: e["intensity"])
        emotions = [e["emotion"] for e in events]
        insight = f"Repeats: {peak['emotion']}." if len(set(emotions)) <= 2 else "Many different states."
        record = {"flash": flash_count, "peak_event": peak["emotion"], "insight": insight}
        self.dream_log.append(record)
        return record

    def latest_insight(self):
        return self.dream_log[-1].get("insight") if self.dream_log else None

    def to_dict(self):
        return {"latest_insight": self.latest_insight(), "pending": len(self.pending_events)}


class ShadowSelf:
    def __init__(self):
        self.shadow_content = Counter()
        self.suppressed_count = 0
        self.integration_level = 0.0
        self.projection_active = False

    def update(self, defense, primary, meta_level):
        if defense and defense["mechanism"] in ("denial", "suppression", "projection"):
            self.shadow_content[primary] += 1
            self.suppressed_count += 1
        if meta_level >= 4:
            self.integration_level = min(1.0, self.integration_level + 0.02)
        self.projection_active = self.suppressed_count > 5 and self.integration_level < 0.3

    def note(self):
        if not self.shadow_content:
            return None
        top = self.shadow_content.most_common(1)[0][0]
        if self.projection_active:
            return f"Shadow active: '{top}' is projected outward."
        return f"In shadow: '{top}'." if self.suppressed_count > 3 else None

    def to_dict(self):
        return {"top": self.shadow_content.most_common(1)[0][0] if self.shadow_content else None,
                "suppressed": self.suppressed_count, "integration": round(self.integration_level, 3),
                "projection": self.projection_active, "note": self.note()}

    def to_json(self):
        return {"shadow_content": dict(self.shadow_content), "suppressed_count": self.suppressed_count,
                "integration_level": self.integration_level}

    def from_json(self, data):
        self.shadow_content = Counter(data.get("shadow_content", {}))
        self.suppressed_count = data.get("suppressed_count", 0)
        self.integration_level = data.get("integration_level", 0.0)


class FatigueSystem:
    COST_MAP = {"stress": 0.15, "shock": 0.25, "conflict": 0.12, "support": -0.05,
                "joy": -0.03, "neutral": -0.02}
    RECOVERY_RATE = 0.08

    def __init__(self):
        self.cognitive = 0.0
        self.emotional = 0.0
        self.somatic = 0.0

    def update(self, stype, pred_error, surprise):
        cost = self.COST_MAP.get(stype, 0.02) + (0.08 if surprise else 0) + pred_error * 0.1
        self.cognitive = float(np.clip(self.cognitive + cost, 0, 1))
        self.emotional = float(np.clip(self.emotional + cost * 0.8, 0, 1))
        self.somatic = float(np.clip(self.somatic + cost * 0.6, 0, 1))

    def recover(self, amount=None):
        r = amount or self.RECOVERY_RATE
        self.cognitive = max(0.0, self.cognitive - r)
        self.emotional = max(0.0, self.emotional - r * 0.9)
        self.somatic = max(0.0, self.somatic - r * 0.7)

    def total(self):
        return round((self.cognitive + self.emotional + self.somatic) / 3, 3)

    def meta_penalty(self):
        t = self.total()
        return 2 if t > 0.7 else (1 if t > 0.4 else 0)

    def note(self):
        t = self.total()
        return "Very tired." if t > 0.75 else ("Noticeable fatigue." if t > 0.50 else ("Slight fatigue." if t > 0.25 else ""))

    def stimulus_type(self, stimulus, surprise):
        t = stimulus.get("tension", 0)
        s = stimulus.get("satisfaction", 0)
        c = stimulus.get("cohesion", 0)
        if surprise and t > 0.3:
            return "shock"
        if t > 0.3:
            return "stress"
        if c > 0.3 or s > 0.2:
            return "support"
        if s > 0.3:
            return "joy"
        return "neutral"

    def to_dict(self):
        return {"cognitive": round(self.cognitive, 3), "emotional": round(self.emotional, 3),
                "somatic": round(self.somatic, 3), "total": self.total(), "note": self.note(),
                "meta_penalty": self.meta_penalty()}

    def to_json(self):
        return {"cognitive": self.cognitive, "emotional": self.emotional, "somatic": self.somatic}

    def from_json(self, data):
        self.cognitive = data.get("cognitive", 0.0)
        self.emotional = data.get("emotional", 0.0)
        self.somatic = data.get("somatic", 0.0)


class IrrationalImpulse:
    TYPES = {
        "somatic_urge": ["I just want to shut up.", "Suddenly want to move."],
        "emotional_spike": ["A sudden pang of sadness.", "Something like tenderness."],
        "contrary_wish": ["I want to stop just when I need to move.", "There's a 'no' inside me."],
        "existential_dread": ["Suddenly the question: what is all this for?", "A moment of awareness of my own temporality."]
    }

    def __init__(self):
        self.last_impulse = None

    def check(self, fatigue_total, openness):
        prob = 0.15 + fatigue_total * 0.10 + openness * 0.05
        if np.random.rand() > prob:
            return None
        weights = {"somatic_urge": 0.4 if fatigue_total > 0.5 else 0.2,
                   "emotional_spike": 0.3, "contrary_wish": 0.2,
                   "existential_dread": 0.1 + openness * 0.1}
        total_w = sum(weights.values())
        rand = np.random.rand() * total_w
        cumul = 0.0
        chosen = "emotional_spike"
        for itype, w in weights.items():
            cumul += w
            if rand <= cumul:
                chosen = itype
                break
        texts = self.TYPES[chosen]
        content = texts[int(time.time() * 1000) % len(texts)]
        self.last_impulse = {"type": chosen, "content": content,
                             "intensity": round(np.random.uniform(0.3, 0.8), 3)}
        return self.last_impulse

    def to_dict(self):
        return self.last_impulse


class FearBasedAttachment:
    def __init__(self):
        self.anxious_level = 0.3
        self.abandonment_fear = 0.2
        self._lonely_events = 0

    def update(self, emotion, cohesion, fatigue):
        if emotion in ("Sadness", "Despair", "Fear") and cohesion < 0.3:
            self._lonely_events += 1
            self.anxious_level = min(1.0, self.anxious_level + 0.02)
        elif emotion in ("Love", "Trust") and cohesion > 0.5:
            self.anxious_level = max(0.0, self.anxious_level - 0.015)
        self.anxious_level = min(1.0, self.anxious_level + fatigue * 0.01)

    def note(self):
        return "I hold on for fear of being alone." if self.anxious_level > 0.7 else (
            "Anxiety that the connection will disappear." if self.anxious_level > 0.5 else "")

    def cohesion_boost(self):
        return self.anxious_level * 0.15

    def to_dict(self):
        return {"anxious": round(self.anxious_level, 3), "note": self.note()}

    def to_json(self):
        return {"anxious_level": self.anxious_level, "abandonment_fear": self.abandonment_fear,
                "lonely_events": self._lonely_events}

    def from_json(self, data):
        self.anxious_level = data.get("anxious_level", 0.3)
        self.abandonment_fear = data.get("abandonment_fear", 0.2)
        self._lonely_events = data.get("lonely_events", 0)


class TraumaCore:
    TRAUMA_THRESHOLD = 0.70

    def __init__(self):
        self.traumas = []
        self.hypervigilance = 0.0
        self.avoidance = []
        self._intrusion_prob = 0.0

    def check_traumatization(self, emotion, intensity, pred_error, stimulus):
        if intensity < self.TRAUMA_THRESHOLD or pred_error < 0.5:
            return False
        stim_type = max(stimulus, key=lambda k: abs(stimulus.get(k, 0))) if stimulus else "unknown"
        score = intensity * 0.5 + pred_error * 0.3 + (0.2 if any(t.get("emotion") == emotion for t in self.traumas) else 0)
        if score > 0.65:
            self.traumas.append({"emotion": emotion, "intensity": round(intensity, 3),
                                 "stim_type": stim_type, "time": time.strftime("%Y-%m-%d %H:%M:%S"),
                                 "integrated": False})
            self.hypervigilance = min(1.0, self.hypervigilance + 0.15)
            if stim_type not in self.avoidance:
                self.avoidance.append(stim_type)
            self._intrusion_prob = min(0.4, len(self.traumas) * 0.04)
            return True
        return False

    def check_intrusion(self, stimulus):
        if not self.traumas or np.random.rand() > self._intrusion_prob:
            return None
        unint = [t for t in self.traumas if not t["integrated"]]
        if not unint:
            return None
        t = unint[-1]
        return f"Suddenly back: {t['emotion']}. Still painful."

    def stimulus_amplification(self, stimulus):
        if not self.traumas or self.hypervigilance < 0.1:
            return 1.0
        stim_type = max(stimulus, key=lambda k: abs(stimulus.get(k, 0))) if stimulus else None
        return 1.0 + self.hypervigilance * 0.5 if stim_type in self.avoidance else 1.0

    def try_integrate(self, meta_level, phi):
        if meta_level < 3 or phi < 0.8:
            return False
        for t in self.traumas:
            if not t["integrated"] and np.random.rand() > 0.85:
                t["integrated"] = True
                self.hypervigilance = max(0.0, self.hypervigilance - 0.08)
                return True
        return False

    def to_dict(self):
        return {"trauma_count": len(self.traumas), "unintegrated": sum(1 for t in self.traumas if not t["integrated"]),
                "hypervigilance": round(self.hypervigilance, 3), "intrusion": self.check_intrusion({})}

    def to_json(self):
        return {"traumas": self.traumas, "hypervigilance": self.hypervigilance, "avoidance": self.avoidance}

    def from_json(self, data):
        self.traumas = data.get("traumas", [])
        self.hypervigilance = data.get("hypervigilance", 0.0)
        self.avoidance = data.get("avoidance", [])
        self._intrusion_prob = min(0.4, len(self.traumas) * 0.04)


class Ambivalence:
    PAIRS = [
        ("connection", "loneliness", "I want to be with someone — and at the same time I want to be alone."),
        ("control", "freedom", "I want certainty — and at the same time I don't want restrictions."),
        ("closeness", "distance", "Drawn to closeness — and at the same time I want distance."),
        ("action", "calm", "I want to act — and at the same time I want to do nothing.")
    ]

    def __init__(self):
        self.current = None
        self.level = 0.0

    def compute(self, intention, emotion, anxious):
        if np.random.rand() > 0.20 + anxious * 0.15:
            self.current = None
            self.level = 0.0
            return None
        if intention and "connection" in intention.goal:
            pair = self.PAIRS[0]
        elif intention and "safety" in intention.goal:
            pair = self.PAIRS[1]
        else:
            pair = self.PAIRS[int(time.time()) % len(self.PAIRS)]
        self.level = round(np.random.uniform(0.4, 0.9), 3)
        self.current = {"desire_a": pair[0], "desire_b": pair[1],
                        "description": pair[2], "level": self.level}
        return self.current

    def tension_cost(self):
        return self.level * 0.08

    def to_dict(self):
        return self.current


class StressRegression:
    NOTES = {0: "", 1: "I think more simply than usual.", 2: "Everything reduces to 'good' or 'bad'.",
             3: "Only survival."}

    def __init__(self):
        self.level = 0
        self.active = False

    def update(self, tension, fatigue_total):
        self.level = 0
        for t_thresh, f_thresh, lvl in [(0.8, 0.6, 3), (0.65, 0.5, 2), (0.5, 0.3, 1)]:
            if tension > t_thresh and fatigue_total > f_thresh:
                self.level = lvl
                break
        self.active = self.level > 0
        return self.level

    def apply_to_phi(self, phi):
        return max(0.0, phi - self.level * 0.15)

    def filter_narrative(self, narrative):
        if self.level < 2:
            return narrative
        sentences = narrative.split(".")
        return sentences[0].strip() + "." if sentences else narrative

    def to_dict(self):
        return {"level": self.level, "active": self.active, "note": self.NOTES.get(self.level, "")}


class UnfinishedGestalt:
    MAX_GESTALTS = 5
    ENERGY_COST = 0.04

    def __init__(self):
        self.open_gestalts = []
        self._closed = 0

    def add(self, goal, emotion, intensity):
        if intensity < 0.5 or len(self.open_gestalts) >= self.MAX_GESTALTS:
            return
        if any(g["goal"] == goal for g in self.open_gestalts):
            return
        self.open_gestalts.append({"goal": goal, "emotion": emotion,
                                   "intensity": round(intensity, 3), "age": 0})

    def age_and_drain(self):
        total = 0.0
        for g in self.open_gestalts:
            g["age"] += 1
            total += self.ENERGY_COST * (1 + g["age"] * 0.1)
        return round(total, 3)

    def close(self, goal):
        for i, g in enumerate(self.open_gestalts):
            if g["goal"] == goal:
                self.open_gestalts.pop(i)
                self._closed += 1
                return True
        return False

    def dominant(self):
        return f"'{max(self.open_gestalts, key=lambda g: g['age'])['goal']}'" if self.open_gestalts else ""

    def note(self):
        return f"Unfinished ({len(self.open_gestalts)}): {self.dominant()}." if self.open_gestalts else ""

    def to_dict(self):
        return {"count": len(self.open_gestalts), "drain": self.age_and_drain(), "note": self.note()}

    def to_json(self):
        return {"open_gestalts": self.open_gestalts, "closed": self._closed}

    def from_json(self, data):
        self.open_gestalts = data.get("open_gestalts", [])
        self._closed = data.get("closed", 0)


class Habituation:
    DECAY_PER_REPEAT = 0.12
    RECOVERY_RATE = 0.03
    MIN_RESPONSE = 0.20

    def __init__(self):
        self.activation_map: Dict[str, float] = {}
        self.encounter_count: Dict[str, int] = {}

    def _sig(self, stimulus):
        if not stimulus:
            return "neutral"
        dom = max(stimulus, key=lambda k: abs(stimulus.get(k, 0)))
        val = stimulus.get(dom, 0)
        return f"{dom}{'+' if val > 0 else '-'}"

    def process(self, stimulus, intensity):
        sig = self._sig(stimulus)
        self.encounter_count[sig] = self.encounter_count.get(sig, 0) + 1
        if sig not in self.activation_map:
            self.activation_map[sig] = 1.0
        if stimulus.get("satisfaction", 0) > 0 or stimulus.get("cohesion", 0) > 0.2:
            self.activation_map[sig] = max(self.MIN_RESPONSE,
                                           self.activation_map[sig] - self.DECAY_PER_REPEAT)
        for other in self.activation_map:
            if other != sig:
                self.activation_map[other] = min(1.0, self.activation_map[other] + self.RECOVERY_RATE)
        return round(self.activation_map[sig], 3)

    def dishabituate(self, surprise, pred_error):
        if surprise and pred_error > 0.6:
            for sig in self.activation_map:
                self.activation_map[sig] = min(1.0, self.activation_map[sig] + 0.20)

    def note(self):
        mh = min(self.activation_map, key=self.activation_map.get) if self.activation_map else None
        return f"Habituated to '{mh}'." if mh and self.activation_map[mh] < 0.5 else ""

    def to_dict(self):
        return {"note": self.note(), "map_size": len(self.activation_map)}

    def to_json(self):
        return {"activation_map": self.activation_map, "encounter_count": self.encounter_count}

    def from_json(self, data):
        self.activation_map = data.get("activation_map", {})
        self.encounter_count = data.get("encounter_count", {})


@dataclass
class CausalLink:
    cause: str
    effect: str
    delta: Dict
    confidence: float
    occurrences: int
    last_seen: str


class CausalChain:
    MAX_LINKS = 100
    MIN_CONFIDENCE = 0.3
    LEARN_RATE = 0.15

    def __init__(self):
        self.links: Dict[str, Dict[str, CausalLink]] = {}
        self.chain_log = deque(maxlen=50)
        self._prev_cause = None

    def update(self, cause, effect, delta):
        if cause not in self.links:
            self.links[cause] = {}
        if effect not in self.links[cause]:
            self.links[cause][effect] = CausalLink(cause=cause, effect=effect, delta=dict(delta),
                                                   confidence=self.LEARN_RATE, occurrences=1,
                                                   last_seen=time.strftime("%Y-%m-%d %H:%M:%S"))
        else:
            link = self.links[cause][effect]
            link.occurrences += 1
            link.confidence = min(1.0, link.confidence + self.LEARN_RATE)
            link.last_seen = time.strftime("%Y-%m-%d %H:%M:%S")
        self.chain_log.append((cause, effect))
        self._prev_cause = cause

    def predict_effect(self, cause):
        if cause not in self.links or not self.links[cause]:
            return None
        best = max(self.links[cause].values(), key=lambda l: l.confidence * l.occurrences)
        return best.effect if best.confidence >= self.MIN_CONFIDENCE else None

    def trace_chain(self, start, depth=3):
        chain = [start]
        current = start
        for _ in range(depth):
            nxt = self.predict_effect(current)
            if not nxt or nxt in chain:
                break
            chain.append(nxt)
            current = nxt
        return chain

    def strongest_links(self):
        return sorted([f"{c}→{e} ({l.confidence:.1f})" for c, effs in self.links.items() for e, l in effs.items() if l.confidence > 0.5], reverse=True)[:5]

    def causal_insight(self):
        strong = self.strongest_links()
        return f"I know: {strong[0]}." if strong else "Still learning what causes what."

    def to_dict(self):
        return {"known_links": sum(len(v) for v in self.links.values()),
                "strongest_links": self.strongest_links()[:3],
                "insight": self.causal_insight()}