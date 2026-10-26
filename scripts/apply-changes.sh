#!/usr/bin/env bash
###############################################################################
# CutLoss phase 15 -- "the VFR frame-rate gate fix"
#
# User report (with two real phone clips as the evidence):
#   "export blocked - smart export unavailable: clips have different frame
#    rates" - even though both clips are 1080p30 footage from the same
#    camera, recorded 34 seconds apart.
#
# Root cause (lab-verified with the exact uploaded clips):
#   probeMedia() reads avg_frame_rate as the RAW ffprobe fraction string
#   ("55170000/1840177" vs "27135000/904609" = 29.9813 vs 29.9960 fps)
#   and analyzeInternal() / planInternal() compared those strings for
#   equality. Camera footage is variable-frame-rate, so every recording
#   of the SAME camera reports a slightly different exact fraction - the
#   string compare then falsely rejects clips of the SAME rate class.
#   The lab proof: concat demuxer + -c copy joins the two uploaded clips
#   into one 40.640 s file (= 20.501 + 20.139 s, 1216 frames, no decode
#   errors, uniform h264 High / yuvj420p / tbn 1/90000 + AAC LC 48 kHz
#   stereo). The files were never the problem; the gate was.
#
# Fix (1 file):
#   SmartExportPlanner.kt:
#     - New fpsCloseEnough(a, b): numeric comparison with a tolerance of
#       max(0.5 fps, 2% of the reference rate). VFR jitter between
#       recordings of one camera is far below it (0.015 fps in the
#       uploaded pair); the real fps classes (24 vs 25 vs 30 vs 60) stay
#       far above it. 29.97 vs 30 and 59.94 vs 60 still pass; 25 vs
#       29.97 still blocks.
#     - analyzeInternal() and planInternal() now gate on
#       fpsCloseEnough(p.fpsValue, refParams.fpsValue) instead of the
#       exact fraction string compare. The user-facing fail() message is
#       unchanged.
#     - Everything else untouched: the fps= filter in the freeze /
#       transition templates still uses each clip's own / the reference's
#       fraction, exactly as before.
#
# The 3 edit anchors exist identically with AND without phase 14 applied,
# so this script runs on either repo state.
#
# Idempotent: re-running skips every edit that is already present.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

if [ ! -f "$PLANNER" ]; then
  echo "FATAL: $PLANNER not found - run from the repository root at the expected commit"
  exit 1
fi

echo "== phase 15: applying the VFR frame-rate gate fix =="

python3 - <<'PYEOF'
import sys

PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

edits_applied = 0
edits_skipped = 0


def apply_edit(path, old, new, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    if new in s:
        edits_skipped += 1
        return
    if old not in s:
        print("  [FAIL] " + name + ": anchor not found")
        sys.exit(1)
    if s.count(old) != 1:
        print("  [FAIL] " + name + ": anchor not unique")
        sys.exit(1)
    s = s.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1


# ---- 1) analyzeInternal: numeric fps gate ----
apply_edit(PLANNER, """                if (p.fpsString != refParams.fpsString) return fail("clips have different frame rates")""",
"""                // Phase 15: compare the NUMERIC rates, not the exact fraction
                // strings - camera VFR footage reports a slightly different
                // avg_frame_rate fraction for every recording of the same
                // camera (29.9813 vs 29.9960 fps in the reported pair), so
                // the old string compare falsely blocked clips that concat
                // losslessly.
                if (!fpsCloseEnough(p.fpsValue, refParams.fpsValue)) return fail("clips have different frame rates")""",
"planner: analyzeInternal numeric fps gate")

# ---- 2) planInternal: numeric fps gate ----
apply_edit(PLANNER, """                if (p.fpsString != refParams.fpsString) return null""",
"""                // Phase 15: numeric fps comparison (see fpsCloseEnough) -
                // exact fraction strings differ between VFR recordings of
                // the same camera.
                if (!fpsCloseEnough(p.fpsValue, refParams.fpsValue)) return null""",
"planner: planInternal numeric fps gate")

# ---- 3) fpsCloseEnough helper (before the freeze builder section) ----
apply_edit(PLANNER, """    // ------------------------------------------------------------------
    // Freeze frame command builder
    // ------------------------------------------------------------------""",
"""    /**
     * Phase 15: numeric frame-rate comparison with VFR tolerance. Camera
     * footage is variable-frame-rate, so two recordings from the SAME
     * camera report slightly different avg_frame_rate fractions
     * (29.9813 vs 29.9960 fps, say) even though they are the same rate
     * class - an exact string compare of those fractions falsely blocked
     * clips that concat losslessly (lab-verified with the reported pair:
     * concat demuxer + -c copy joins them with exact durations and a
     * clean decode). The tolerance is the larger of 0.5 fps and 2% of the
     * reference rate: jitter between recordings of one camera is far
     * below it, while the real fps classes (24 vs 25 vs 30 vs 60) stay
     * far above it.
     */
    private fun fpsCloseEnough(a: Double, b: Double): Boolean {
        val tol = Math.max(0.5, Math.abs(b) * 0.02)
        return Math.abs(a - b) <= tol
    }

    // ------------------------------------------------------------------
    // Freeze frame command builder
    // ------------------------------------------------------------------""",
"planner: fpsCloseEnough helper")

print("edits: %d applied, %d skipped (already present)" % (edits_applied, edits_skipped))
PYEOF

echo "== phase 15: gates =="

python3 - <<'PYEOF'
import sys

fail = []


def check(cond, msg):
    print(("  [ok] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fail.append(msg)


# 1) the standing invariant: no complex filter graphs anywhere
import subprocess
n = subprocess.run(["grep", "-r", "-o", "filter_complex", "app/src/main/java"],
                   capture_output=True, text=True).stdout.count("filter_complex")
check(n == 0, "filter_complex count in app/src/main/java == 0 (got %d)" % n)

P = open("app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt").read()

# 2) the new numeric gate is wired in exactly twice
check(P.count("!fpsCloseEnough(p.fpsValue, refParams.fpsValue)") == 2,
      "planner numeric fps gates x2")
check(P.count("fpsCloseEnough") == 4,
      "planner fpsCloseEnough x4 (definition + 2 call sites + comment)")

# 3) the old exact-string compare is gone
check(P.count("p.fpsString != refParams.fpsString") == 0,
      "planner exact-string fps compare gone")

# 4) the tolerance formula is present exactly once
check(P.count("val tol = Math.max(0.5, Math.abs(b) * 0.02)") == 1,
      "planner tolerance formula x1")

# 5) the user-facing message and the probing are unchanged
check(P.count('"clips have different frame rates"') == 1,
      "planner fail message unchanged")
check(P.count('v.optString("avg_frame_rate", "0/0")') == 1,
      "planner avg_frame_rate probe unchanged")

# 6) structural balance (state-independent: braces stay balanced whether
#    or not phase 14 is applied; the helper itself must be balanced too)
check(P.count("{") == P.count("}"),
      "planner braces balanced (%d/%d)" % (P.count("{"), P.count("}")))
i = P.find("private fun fpsCloseEnough")
helper = P[i:P.find("\n    }", i) + len("\n    }")]
check(helper.count("(") == helper.count(")"), "fpsCloseEnough parens balanced")
check(P.count("private fun fpsCloseEnough(a: Double, b: Double): Boolean {") == 1,
      "fpsCloseEnough signature intact")

# 7) ASCII purity
check(sum(1 for ch in P if ord(ch) > 127) == 0, "planner ASCII")

# 8) survival tokens (present both with and without phase 14)
for tok in ["parseFraction", "Freeze frame command builder", "avg_frame_rate",
            "simpleVideoEncoderArgs", "encodablePixFmt", "setsar="]:
    check(P.count(tok) > 0, "planner keeps '%s'" % tok)

if fail:
    print("GATES FAILED: %d" % len(fail))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 15: done =="
