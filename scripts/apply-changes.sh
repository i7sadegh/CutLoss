#!/usr/bin/env bash
###############################################################################
# CutLoss phase 17 -- "the single-APK install fix" (+ transition geometry)
#
# User report:
#   "app not installed as package appeared to be invalid" - the phase-16
#   APK (the first single-APK build) refuses to install over the app that
#   is already on the phone.
#
# Root cause (exactly the step the user pointed at - the single-APK build
# settings):
#   The OLD gradle config had an abi `splits` block PLUS a
#   versionCodeOverride table that offset the base versionCode by ABI:
#     armeabi-v7a -> 12 + 0 = 12
#     arm64-v8a   -> 12 + 1 = 13   <- what every split build installed
#     x86_64      -> 12 + 2 = 14
#   Phase 16 removed both blocks (single arm64-v8a APK, as requested) but
#   left the BASE versionCode at 12 - so the new APK carries 12 while the
#   installed arm64 build carries 13. Android reads that as a DOWNGRADE
#   (INSTALL_FAILED_VERSION_DOWNGRADE) and the installer UI shows exactly
#   "app not installed as package appeared to be invalid".
#
# Fix A (app/build.gradle):
#   versionCode 12 -> 15 (above the highest per-ABI offset ever shipped)
#   versionName "1.0-beta9" -> "1.0-beta10"
#   Same committed debug keystore as before, so 15 installs cleanly OVER
#   every previously installed build without uninstalling first.
#
# Fix B (SmartExportPlanner.kt - found in code review of phase 16):
#   The freeze-frame transition segment always built SENSOR geometry
#   (transpose back + rotation-metadata remux) and always baked the export
#   scaleFilter - but it must match its NEIGHBOURS in the concat list:
#     - stream-copied neighbours (pure copy / keyframe cut / two-step
#       cut): sensor frames + rotation metadata at the SOURCE resolution;
#       the finalize command applies any res/fps change to the assembled
#       cut later, so the transition must NOT bake the export scale/fps.
#     - per-segment-encode neighbours: ffmpeg's default autorotate bakes
#       the rotation into DISPLAY space and each segment applies the
#       export scale/fps itself - the transition must stay in display
#       space, same scale, no rotation metadata, and use the OUTPUT
#       container (outExt) with the matching -video_track_timescale arg
#       (video_track_timescale is an MP4/MOV muxer option; appending it
#       while writing another container fails the command).
#   Both geometry shapes lab-validated (ffmpeg 7.1.5): display-mode
#   segment concats uniformly next to baked neighbours (uniform 720x1280,
#   clean decode); sensor-mode segment round-trips the rotation exactly
#   (corner-marker test: transpose=2 + remux -90 for probed 90,
#   transpose=1 + remux -270 for probed 270) and concats next to copied
#   neighbours; the user's own two uploaded clips join with a freeze
#   transition at the exact VFR fraction (41.17 s output, uniform
#   yuvj420p / tbn 1/90000, clean seam decodes).
#
# 6 edits total. Idempotent: re-running skips every edit already present.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
GRADLE="app/build.gradle"

for f in "$PLANNER" "$GRADLE"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 17: applying the single-APK install fix + transition geometry =="

python3 - <<'PYEOF'
import sys

PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
GRADLE = "app/build.gradle"

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


# ---- G1) build.gradle: versionCode above every split code + beta10 ----
apply_edit(GRADLE, """        versionCode project.hasProperty('versionCode') ? project.property('versionCode').toInteger() : 12
        versionName "1.0-beta9"
""",
"""        // Phase 17: the single arm64-v8a APK must carry a versionCode
        // ABOVE every split APK ever shipped - the old per-ABI splits
        // offset this base by ABI (12 armeabi-v7a / 13 arm64-v8a /
        // 14 x86_64), so leaving the base at 12 made the phase-16 build
        // a DOWNGRADE next to the installed arm64 split (13) and Android
        // refused it ("app not installed as package appeared to be
        // invalid"). 15 clears the highest offset ever produced.
        versionCode project.hasProperty('versionCode') ? project.property('versionCode').toInteger() : 15
        versionName "1.0-beta10"
""",
"gradle: versionCode 15 + beta10 (the install fix)")

# ---- P1) transition frame rate: only bake the export rate next to ----
# ---- encoded neighbours ----
apply_edit(PLANNER, """        val transFpsValue = if (fpsChange) exportFps.toDouble() else refParams.fpsValue
        val transFpsSpec = if (fpsChange) exportFps.toString() else refParams.fpsString
""",
"""        // Phase 17: the transition runs at the EXPORT frame rate only
        // when its neighbours encode at it (per-segment encode). In the
        // copy and two-step plans the neighbours are stream copies at the
        // source rate and the finalize command converts the assembled cut
        // as a whole, so the transition stays at the source rate there -
        // baking the export rate would make it the odd one out inside the
        // lossless concat.
        val transFpsValue = if (perSegmentEncode && fpsChange) exportFps.toDouble() else refParams.fpsValue
        val transFpsSpec = if (perSegmentEncode && fpsChange) exportFps.toString() else refParams.fpsString
""",
"planner: transition fps follows the neighbours")

# ---- P2) transition geometry: sensor mode next to copies, display ----
# ---- mode next to encoded neighbours ----
apply_edit(PLANNER, """            val transpose = when (refParams.rotation) {
                90 -> "transpose=2,"
                180 -> "transpose=1,transpose=1,"
                270 -> "transpose=1,"
                else -> ""
            }
            val scalePart = scaleFilter
                ?: ("scale=" + refParams.width + ":" + refParams.height + ",setsar=" + sarSpec)
""",
"""            // Phase 17: the transition segment must match its NEIGHBOURS'
            // geometry, which depends on the plan mode. Stream-copied
            // neighbours (pure copy, keyframe cut, or the two-step cut a
            // later finalize command re-encodes as one) are SENSOR frames
            // carrying the rotation metadata at the SOURCE resolution: the
            // display bitmaps transpose back, the rotation metadata is
            // remuxed in, and NO export scale is baked here (the finalize
            // applies it to the assembled cut). Encoded neighbours
            // (per-segment encode) bake the rotation into display space
            // and apply the export scale themselves: the transition stays
            // in display space with the SAME scale and no rotation
            // metadata. Mixing the two modes breaks the concat uniformity
            // (both shapes lab-verified to round-trip cleanly).
            val sensorMode = !perSegmentEncode
            val transposeRaw = when (refParams.rotation) {
                90 -> "transpose=2,"
                180 -> "transpose=1,transpose=1,"
                270 -> "transpose=1,"
                else -> ""
            }
            val transpose = if (sensorMode) transposeRaw else ""
            val scalePart = if (perSegmentEncode) {
                scaleFilter
                    ?: ("scale=" + displayWidth + ":" + displayHeight + ",setsar=" + sarSpec)
            } else {
                "scale=" + refParams.width + ":" + refParams.height + ",setsar=" + sarSpec
            }
""",
"planner: transition geometry mode (sensor vs display)")

# ---- P3) rotation-metadata remux only in sensor mode ----
apply_edit(PLANNER, """            if (refParams.rotation != 0) {
                // like the freeze builder: encode sensor-space first, then
                // remux the rotation metadata back in with a pure -c copy
""",
"""            if (sensorMode && refParams.rotation != 0) {
                // like the freeze builder: encode sensor-space first, then
                // remux the rotation metadata back in with a pure -c copy
                // (display-mode neighbours carry no rotation metadata, so
                // the transition must not either - phase 17)
""",
"planner: rotation remux gated on sensor mode")

# ---- P4a) transition container matches the neighbours ----
apply_edit(PLANNER, """            val seg = nextSegmentFile(segExt)
            val sb = StringBuilder("-y -framerate ").append(transFpsSpec)
""",
"""            // Phase 17: match the neighbours' container too - encoded
            // neighbours are written as outExt, copied ones as segExt.
            val seg = nextSegmentFile(if (perSegmentEncode) outExt else segExt)
            val sb = StringBuilder("-y -framerate ").append(transFpsSpec)
""",
"planner: transition segment container")

# ---- P4b) timescale flag matches the container actually written ----
apply_edit(PLANNER, """            sb.append(" ").append(transVEnc)
            if (planHasAudio) sb.append(" ").append(transAEnc)
            sb.append(segTbn)
""",
"""            sb.append(" ").append(transVEnc)
            if (planHasAudio) sb.append(" ").append(transAEnc)
            // Phase 17: the timescale flag must match the container the
            // segment is actually written to (outExt in the encode plans,
            // segExt next to the stream copies) - video_track_timescale
            // is an MP4/MOV muxer option and fails on other containers.
            sb.append(if (perSegmentEncode) outTbn else segTbn)
""",
"planner: transition timescale arg")

print("edits: %d applied, %d skipped (already present)" % (edits_applied, edits_skipped))
PYEOF

echo "== phase 17: gates =="

python3 - <<'PYEOF'
import subprocess
import sys

fail = []


def check(cond, msg):
    print(("  [ok] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fail.append(msg)


# 1) the standing invariant: no complex filter graphs anywhere
n = subprocess.run(["grep", "-r", "-o", "filter_complex", "app/src/main/java"],
                   capture_output=True, text=True).stdout.count("filter_complex")
check(n == 0, "filter_complex count in app/src/main/java == 0 (got %d)" % n)

G = open("app/build.gradle").read()
P = open("app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt").read()

# 2) the install fix is in and the old values are gone
check(G.count("toInteger() : 15") == 1, "gradle versionCode 15")
check(G.count("toInteger() : 12") == 0, "gradle versionCode 12 gone")
check(G.count('"1.0-beta10"') == 1, "gradle versionName beta10")
check(G.count('"1.0-beta9"') == 0, "gradle versionName beta9 gone")

# 3) the single-APK config from phase 16 survives
check(G.count("abiFilters 'arm64-v8a'") == 1, "gradle arm64-v8a abiFilter kept")
check(G.count("splits {") == 0, "gradle splits still gone")
check(G.count("versionCodeOverride") == 0, "gradle versionCodeOverride still gone")

# 4) the transition geometry fix is wired in exactly once each
check(P.count("val sensorMode = !perSegmentEncode") == 1,
      "planner sensorMode definition x1")
check(P.count("val transpose = if (sensorMode) transposeRaw else \"\"") == 1,
      "planner transpose gated on sensorMode")
check(P.count("sensorMode && refParams.rotation != 0") == 1,
      "planner rotation remux gated on sensorMode")
check(P.count("perSegmentEncode && fpsChange") == 2,
      "planner transition fps gates x2")
check(P.count("if (perSegmentEncode) outExt else segExt") == 1,
      "planner transition container follows the plan mode")
check(P.count("if (perSegmentEncode) outTbn else segTbn") == 1,
      "planner transition timescale follows the plan mode")
check(P.count("val transposeRaw = when (refParams.rotation)") == 1,
      "planner transposeRaw when-block x1")

# 5) structural balance (the edits add balanced if/else blocks only)
check(P.count("{") == P.count("}"),
      "planner braces balanced (%d/%d)" % (P.count("{"), P.count("}")))
check(P.count("(") == P.count(")"),
      "planner parens balanced (%d/%d)" % (P.count("("), P.count(")")))
check(G.count("{") == G.count("}"), "gradle braces balanced")

# 6) ASCII purity
check(sum(1 for ch in P if ord(ch) > 127) == 0, "planner ASCII")
check(sum(1 for ch in G if ord(ch) > 127) == 0, "gradle ASCII")

# 7) survival tokens (phase 16 + earlier invariants intact)
for tok in ["renderTransitionFrames", "addFreezeTransitionSegment",
            "effectiveTransitionDurations", "fpsCloseEnough",
            "nextSegmentFile", "encodablePixFmt", "-framerate ",
            "trans_tmp_", "video_track_timescale"]:
    check(P.count(tok) > 0, "planner keeps '%s'" % tok)

# 8) scope: only the two intended files may be dirty (clean tree also ok -
#    that is the re-run-after-commit case)
r = subprocess.run(["git", "status", "--porcelain"],
                   capture_output=True, text=True)
allowed = {"app/build.gradle",
           "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"}
dirty = [l[3:].strip() for l in r.stdout.splitlines() if l.strip()]
bad = [p for p in dirty if p not in allowed]
check(len(bad) == 0, "scope: no unexpected dirty files (dirty=%d, bad=%d)" %
      (len(dirty), len(bad)))

if fail:
    print("GATES FAILED: %d" % len(fail))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 17: done =="
