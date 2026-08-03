"""
Epistemic Boundary Awareness -- diagnostic pre-step (Chat 38).

Question: do Anima's boundary-uncertainty phrases in anima_text
("не знаю де я закінчуюсь", "не знаю чи це моє", etc.) correlate with
real epistemic_self_confidence / identity_drift signals, or are they
a speech pattern with no causal backing?

Data reality check (done first, before any correlation):
- epistemic_self_confidence is NOT persisted anywhere in anima.db
  (checked every table/column). It exists only as a live Julia value,
  never written to causal_trace/audit_log/anywhere else.
  => this half of the question cannot be answered from this DB alone.
- identity_drift IS persisted, in causal_trace, per flash.
- anima_text (the actual output text) is persisted in dialog_summaries,
  per flash -- but dialog_summaries and causal_trace flash numbers
  don't line up 1:1 (only 60/200 exact matches; dialog_summaries has
  multiple rows sharing the same flash number in the early game,
  e.g. flash=1 appears 11 times) -- treated as an approximate join,
  nearest causal_trace flash within a small window.

--------------------------------------------------------------------
HOW TO RUN (Windows, project at C:\\Users\\user\\Desktop\\Anima):

    cd C:\\Users\\user\\Desktop\\Anima\\tools
    python epistemic_boundary_diag.py

No arguments needed -- the script finds the live anima.db on its own
at ..\\memory\\anima.db (relative to this file's location), so it always
reads whatever DB is currently at that path. To point it at a different
snapshot instead, pass the path explicitly:

    python epistemic_boundary_diag.py "C:\\path\\to\\some_other.db"
--------------------------------------------------------------------
"""
import sqlite3
import re
import sys
import statistics as stats
from pathlib import Path

# Default: <project_root>/memory/anima.db, resolved relative to this file
# (this file lives in <project_root>/tools/), so it always tracks the
# live DB regardless of what folder you run the script from.
DEFAULT_DB = Path(__file__).resolve().parent.parent / "memory" / "anima.db"
DB = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB

BOUNDARY_PATTERNS = [
    r"не знаю.{0,20}де я закінчу",
    r"не знаю.{0,20}чи це моє",
    r"не знаю.{0,20}чи я\b",
    r"межі?.{0,10}де я",
    r"де межа",
    r"не впевнена.{0,20}де",
    r"не розумію.{0,10}де закінчу",
    r"де закінчу.{0,15}де почина",
    r"не знаю.{0,10}де я",
]
BOUNDARY_RE = re.compile("|".join(BOUNDARY_PATTERNS), re.IGNORECASE)

def nearest_flash(target, candidates, window=5):
    best = None
    best_d = None
    for f in candidates:
        d = abs(f - target)
        if d <= window and (best_d is None or d < best_d):
            best, best_d = f, d
    return best

def main():
    if not DB.exists():
        print(f"Не знайшла базу за шляхом: {DB}")
        print("Перевір, чи anima.db лежить у Anima/memory/, або передай шлях явно:")
        print('  python epistemic_boundary_diag.py "C:\\path\\to\\anima.db"')
        return
    print(f"База: {DB}")
    con = sqlite3.connect(DB)
    cur = con.cursor()

    cur.execute("SELECT flash, anima_text FROM dialog_summaries ORDER BY flash")
    dialog_rows = cur.fetchall()

    cur.execute("SELECT flash, identity_drift FROM causal_trace ORDER BY flash")
    ct_rows = cur.fetchall()
    ct_by_flash = {}
    for f, drift in ct_rows:
        ct_by_flash.setdefault(f, []).append(drift)
    ct_flashes = sorted(ct_by_flash.keys())

    boundary_drifts = []
    other_drifts = []
    boundary_hits = []

    for flash, text in dialog_rows:
        nf = nearest_flash(flash, ct_flashes, window=5)
        if nf is None:
            continue
        drift = stats.mean(ct_by_flash[nf])
        is_boundary = bool(BOUNDARY_RE.search(text or ""))
        if is_boundary:
            boundary_drifts.append(drift)
            boundary_hits.append((flash, nf, drift, text.strip().replace("\n", " ")[:120]))
        else:
            other_drifts.append(drift)

    print(f"dialog_summaries rows total: {len(dialog_rows)}")
    print(f"rows with a causal_trace match (window=5): {len(boundary_drifts)+len(other_drifts)}")
    print(f"boundary-flagged rows: {len(boundary_drifts)}")
    print(f"non-boundary rows: {len(other_drifts)}")
    print()

    if boundary_drifts:
        print("identity_drift | boundary rows:")
        print("  mean  :", round(stats.mean(boundary_drifts), 4))
        print("  median:", round(stats.median(boundary_drifts), 4))
        if len(boundary_drifts) > 1:
            print("  stdev :", round(stats.stdev(boundary_drifts), 4))
    if other_drifts:
        print("identity_drift | non-boundary rows:")
        print("  mean  :", round(stats.mean(other_drifts), 4))
        print("  median:", round(stats.median(other_drifts), 4))
        if len(other_drifts) > 1:
            print("  stdev :", round(stats.stdev(other_drifts), 4))

    print()
    print("Boundary-flagged rows in detail (flash -> matched causal_trace flash, drift, text):")
    for row in boundary_hits:
        print(" ", row)

    # identity_drift is 0.0 for every causal_trace row before flash 381 (250/291
    # rows total are exactly 0.0) -- almost certainly a warm-up/baseline artifact,
    # not a real "no drift" signal. Restrict the comparison to the live era.
    LIVE_FROM = 381
    print()
    print(f"--- restricted to flash >= {LIVE_FROM} (identity_drift actually live) ---")
    b2, o2 = [], []
    for flash, text in dialog_rows:
        nf = nearest_flash(flash, ct_flashes, window=5)
        if nf is None or nf < LIVE_FROM:
            continue
        drift = stats.mean(ct_by_flash[nf])
        is_boundary = bool(BOUNDARY_RE.search(text or ""))
        (b2 if is_boundary else o2).append(drift)
    print(f"boundary rows: {len(b2)}, non-boundary rows: {len(o2)}")
    if b2:
        print("boundary mean/median:", round(stats.mean(b2), 4), round(stats.median(b2), 4))
    if o2:
        print("non-boundary mean/median:", round(stats.mean(o2), 4), round(stats.median(o2), 4))


    con.close()

if __name__ == "__main__":
    main()
