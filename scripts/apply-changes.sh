#!/usr/bin/env bash
###############################################################################
# CutLoss phase 11 -- the "simple command" contract
#
# User contract being implemented:
#   * Every export-screen toggle maps to exactly ONE ffmpeg option:
#       resolution change  ->  -vf scale=W:H     (nothing when same as input)
#       fps change         ->  -r F              (nothing when same as input)
#       bitrate            ->  -b:v NNNNk
#       audio bitrate      ->  -b:a NNNk
#   * All options "same as input"  ->  audio + video -c copy (lossless).
#   * Multi-segment timelines: cut each part with the simple command
#     (-ss / -t), then assemble with the concat demuxer + -c copy.
#   * The filter_complex render stays ONLY for real edits (text, overlays,
#     rotation, speed, ...), never for a mere resolution/fps change.
#
# What changes:
#   SmartExportPlanner.kt:
#     - settingsBlockSmart no longer blocks on "resolution change" /
#       "fps change" / "custom resolution" - those now switch the smart plan
#       to the simple re-encode template instead of the legacy filter graph.
#     - planInternal: new "reencodeAll" mode. Every segment runs the classic
#       simple command: [-ss S] [-t D] -i SRC -map ... -vf scale=W:H -r F
#       -c:v libx264 -b:v X -c:a aac -b:a Y seg_N.mp4 ; final assembly is
#       still the lossless concat. Re-encode templates drop -noautorotate
#       (validated in the ffmpeg lab: autorotate + scale lands rotated phone
#       clips on their DISPLAY dimensions, e.g. 1080x1920 -> 720x1280).
#     - Transition segments follow the plan mode (same scale filter, target
#       fps) so all segments stay concat-compatible.
#     - SmartAnalysis gains displayWidth + vCodec so the dialog can preview
#       the exact scale dims and encoder name.
#   ExportSettingsDialog.kt:
#     - New smartReencodeMode() + buildSmartReencodeSummary(): the preview
#       shows the actual per-segment simple command + the concat command.
#     - smartEstimateBytes(): in re-encode mode every second counts as
#       encoded at the chosen bitrate.
#
# Precondition: phase 10 + 10.1 + 10.2 must be in the tree (bc5a411).
# Invariants: pure ASCII, idempotent (2nd run = [skip], zero diff),
# touches exactly two source files, hard verification gate exits 1
# BEFORE anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase11] $*"; }
fail() { echo "[phase11][ERROR] $*" >&2; exit 1; }

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"

###############################################################################
# Step 0 -- preconditions (phase 10.2 base must already be in the tree)
###############################################################################
log "step0: checking preconditions"
[ -f "$PLANNER" ] || fail "SmartExportPlanner.kt not found"
[ -f "$ESD" ] || fail "ExportSettingsDialog.kt not found"
[ -f "$VM" ] || fail "VideoEditingViewModel.kt not found"
grep -Fq "fun settingsBlockSmart(" "$PLANNER" \
  || fail "phase-10 base required (settingsBlockSmart missing)"
grep -Fq "private var selKeyframeCut = true" "$ESD" \
  || fail "phase-10.2 base required (selKeyframeCut default missing)"
grep -Fq "private val _exportResolution = MutableStateFlow(0)" "$VM" \
  || fail "phase-10.2 base required (same-as-input resolution default missing)"

###############################################################################
# Step 1 -- SmartExportPlanner.kt patches
###############################################################################
if grep -Fq "val reencodeAll" "$PLANNER"; then
  log "step1: [skip] planner already patched (phase 11 present)"
else
python3 <<'PLANNERPY'
import sys

def die(m):
    print("[phase11][ERROR] " + m)
    sys.exit(1)

P = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
with open(P, "r", encoding="utf-8") as f:
    s = f.read()

def must_replace(old, new, what):
    global s
    n = s.count(old)
    if n != 1:
        die("planner patch (%s): snippet count = %d (expected 1)" % (what, n))
    s = s.replace(old, new, 1)

# ---- 1a. header doc: resolution/fps no longer fall back to legacy ----------
must_replace(
""" * If anything is not copy-compatible (mixed codecs, image clips, text or
 * image overlays, speed changes, background audio, custom resolution or
 * fps, ...) the planner returns null and the caller falls back to the
 * legacy consolidated filter-graph render.
""",
""" * If anything is not copy-compatible (mixed codecs, image clips, text or
 * image overlays, speed changes, background audio, ...) the planner
 * returns null and the caller falls back to the legacy consolidated
 * filter-graph render. Resolution / fps / custom-size changes do NOT
 * fall back (phase 11): they switch the plan to the simple re-encode
 * template - one flag per changed option (-vf scale=W:H, -r F) - and the
 * final assembly is still the lossless concat.
""",
"1a header doc")

# ---- 1b. SmartAnalysis gains displayWidth + vCodec --------------------------
must_replace(
"""    data class SmartAnalysis(
        val clips: List<SmartClipInfo>,
        val transitions: Map<Int, Long>,
        val hasAudio: Boolean,
        val displayHeight: Int,
        val shortSide: Int,
        val fpsRounded: Int,
        val reason: String?
    )
""",
"""    data class SmartAnalysis(
        val clips: List<SmartClipInfo>,
        val transitions: Map<Int, Long>,
        val hasAudio: Boolean,
        val displayHeight: Int,
        val displayWidth: Int,
        val shortSide: Int,
        val fpsRounded: Int,
        val vCodec: String,
        val reason: String?
    )
""",
"1b SmartAnalysis fields")

# ---- 1c. fail() ctor arity ---------------------------------------------------
must_replace(
"""        fun fail(reason: String): SmartAnalysis =
            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, reason)
""",
"""        fun fail(reason: String): SmartAnalysis =
            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", reason)
""",
"1c fail ctor")

# ---- 1d. settingsBlockSmart: res/fps/custom gates removed -------------------
must_replace(
"""    /**
     * Settings-level gates (cheap, no probing): returns a human readable
     * reason when the current export settings force the legacy render, or
     * null when the smart path can run with these settings.
     */
""",
"""    /**
     * Settings-level gates (cheap, no probing): returns a human readable
     * reason when the current export settings force the legacy render, or
     * null when the smart path can run with these settings. Resolution /
     * fps / custom-size changes are handled by the simple re-encode plan
     * (phase 11), so they never gate here.
     */
""",
"1d settingsBlockSmart doc")

must_replace(
"""        if (audioOnly) return "audio-only export"
        if (videoFormat != "mp4") return "non-MP4 container"
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return "custom codec requested"
        if (customWidth >= 16 || customHeight >= 16) return "custom resolution"
        if (exportResolution != 0 && exportResolution != analysis.displayHeight && exportResolution != analysis.shortSide) {
            return "resolution change"
        }
        if (exportFps != 0 && exportFps != analysis.fpsRounded) return "fps change"
        return null
""",
"""        if (audioOnly) return "audio-only export"
        if (videoFormat != "mp4") return "non-MP4 container"
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return "custom codec requested"
        // Phase 11: resolution / fps / custom-size changes no longer disable
        // the smart path -- they switch it to the simple re-encode template
        // (a scale / -r flag per changed option), like the classic ffmpeg
        // one-command workflow.
        return null
""",
"1d settingsBlockSmart gates")

# ---- 1e. success ctor: new named args ---------------------------------------
must_replace(
"""            displayHeight = displayHeight,
            shortSide = Math.min(displayWidth, displayHeight),
            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            reason = null
        )
""",
"""            displayHeight = displayHeight,
            displayWidth = displayWidth,
            shortSide = Math.min(displayWidth, displayHeight),
            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            vCodec = refParams.vCodec,
            reason = null
        )
""",
"1e success ctor")

# ---- 1f. planInternal: drop the custom-size bail-out ------------------------
must_replace(
"""        if (audioOnly) return null
        if (videoFormat != "mp4") return null
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return null
        if (customWidth >= 16 || customHeight >= 16) return null
        if (isImagePath(sourceFilePath)) return null
""",
"""        if (audioOnly) return null
        if (videoFormat != "mp4") return null
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return null
        if (isImagePath(sourceFilePath)) return null
""",
"1f custom gate")

# ---- 1g. planInternal: res/fps bail-out -> reencodeAll mode -----------------
must_replace(
"""        val shortSide = Math.min(displayWidth, displayHeight)
        // Resolution is a no-op when it equals the display height or the short
        // side (a "1080" preset on a portrait 1080x1920 clip). Anything else
        // means the user asked for a real resize -> legacy render.
        if (exportResolution != 0 && exportResolution != displayHeight && exportResolution != shortSide) return null
        if (exportFps != 0 && exportFps != Math.round(refParams.fpsValue).toInt()) return null
""",
"""        val shortSide = Math.min(displayWidth, displayHeight)
        // ---- simple re-encode mode (phase 11) ----
        // A resolution / fps / custom-size change no longer kicks the project
        // to the legacy filter-graph render. Every segment runs the classic
        // simple command with one flag per changed option:
        //   ffmpeg [-ss S] [-t D] -i SRC -vf scale=W:H -r F -c:v libx264 ...
        // and the final assembly stays the lossless concat (-c copy), safe
        // because all segments then share identical encode parameters. The
        // re-encode templates drop -noautorotate on purpose: ffmpeg's default
        // autorotate bakes the rotation BEFORE scale, so a rotated phone clip
        // scales to its display dimensions (1080x1920 -> 720x1280).
        val customScale = customWidth >= 16 && customHeight >= 16
        val resChange = !customScale && exportResolution != 0 &&
            exportResolution != displayHeight && exportResolution != shortSide
        val fpsChange = exportFps != 0 && exportFps != Math.round(refParams.fpsValue).toInt()
        val reencodeAll = customScale || resChange || fpsChange
        val scaleFilter: String? = when {
            customScale -> "scale=" + (customWidth - customWidth % 2) + ":" +
                (customHeight - customHeight % 2) + ",setsar=1"
            resChange -> if (displayHeight >= displayWidth) {
                "scale=" + exportResolution + ":-2,setsar=1"
            } else {
                "scale=-2:" + exportResolution + ",setsar=1"
            }
            else -> null
        }
        val fpsArg: String? = if (fpsChange) "-r " + exportFps else null
""",
"1g reencodeAll block")

# ---- 1h. encoder/transition helpers after fpsFilter --------------------------
must_replace(
"""        val enc = videoEncoderArgs(refParams, exportBitrate, advancedPreset) ?: return null
        val aEnc = audioEncoderArgs(audioRef, advancedAudioBitrate)
        val fpsFilter = "fps=" + refParams.fpsString
""",
"""        val enc = videoEncoderArgs(refParams, exportBitrate, advancedPreset) ?: return null
        val aEnc = audioEncoderArgs(audioRef, advancedAudioBitrate)
        val fpsFilter = "fps=" + refParams.fpsString
        // Simple-command encoder for the re-encode mode (phase 11): no
        // profile / level matching (the source profile may not fit the
        // target size) - just the classic "-c:v libx264 -b:v X" form.
        val encSimple: String = if (refParams.vCodec == "hevc") {
            val sb = StringBuilder("-c:v libx265 -tag:v hvc1 -pix_fmt yuv420p")
            if (exportBitrate.isNotEmpty()) sb.append(" -b:v ").append(exportBitrate) else sb.append(" -crf 20")
            if (advancedPreset.isNotEmpty()) sb.append(" -preset ").append(advancedPreset)
            sb.toString()
        } else {
            val sb = StringBuilder("-c:v libx264 -pix_fmt yuv420p")
            if (exportBitrate.isNotEmpty()) sb.append(" -b:v ").append(exportBitrate) else sb.append(" -crf 18")
            if (advancedPreset.isNotEmpty()) sb.append(" -preset ").append(advancedPreset)
            sb.toString()
        }
        // Transition chains follow the plan mode: the same scale filter and
        // the target frame rate when the whole plan is re-encoded.
        val transScalePrefix = if (reencodeAll && scaleFilter != null) scaleFilter + "," else ""
        val transFpsFilter = if (reencodeAll && fpsChange) "fps=" + exportFps else fpsFilter
        val transEnc = if (reencodeAll) encSimple else enc
""",
"1h encSimple + transition helpers")

# ---- 1i. per-segment chain: new reencodeAll branch ---------------------------
must_replace(
"""            if (fullRange) {
                // Whole clip unchanged -> pure stream copy remux
""",
r"""            if (reencodeAll) {
                // Simple re-encode (phase 11): one flag per changed export
                // option. -ss before -i decodes forward, so cuts are
                // frame-accurate; autorotate runs before scale, so rotated
                // phone clips land on their display dimensions.
                val sb = StringBuilder("-y")
                if (spanStart > 0L) sb.append(" -ss ").append(ms(spanStart))
                if (!fullRange) sb.append(" -t ").append(ms(spanMs))
                sb.append(" -i \"").append(clip.path).append("\"")
                if (silenceAudio) {
                    sb.append(" -f lavfi -t ").append(ms(spanMs))
                    sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                }
                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0")
                }
                if (scaleFilter != null) sb.append(" -vf \"").append(scaleFilter).append("\"")
                if (fpsArg != null) sb.append(" ").append(fpsArg)
                sb.append(" ").append(encSimple)
                if (silenceAudio || planHasAudio) sb.append(" ").append(aEnc)
                sb.append(" \"").append(seg.absolutePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else if (fullRange) {
                // Whole clip unchanged -> pure stream copy remux
""",
"1i reencodeAll segment branch")

# ---- 1j. transition command: conditional -noautorotate + scaled chains ------
must_replace(
r"""                val sb = StringBuilder("-y -noautorotate -ss ").append(leftTailStart)
                sb.append(" -t ").append(dSec).append(" -i \"").append(clip.path).append("\"")
                sb.append(" -noautorotate -ss ").append(rightHeadStart)
                sb.append(" -t ").append(dSec).append(" -i \"").append(right.path).append("\"")
""",
r"""                val arFlag = if (reencodeAll) "" else " -noautorotate"
                val sb = StringBuilder("-y").append(arFlag).append(" -ss ").append(leftTailStart)
                sb.append(" -t ").append(dSec).append(" -i \"").append(clip.path).append("\"")
                sb.append(arFlag).append(" -ss ").append(rightHeadStart)
                sb.append(" -t ").append(dSec).append(" -i \"").append(right.path).append("\"")
""",
"1j transition arFlag")

must_replace(
"""                val filterParts = mutableListOf<String>()
                filterParts.add("[0:v:0]setpts=PTS-STARTPTS," + fpsFilter + "[lv]")
                filterParts.add("[1:v:0]setpts=PTS-STARTPTS," + fpsFilter + "[rv]")
""",
"""                val filterParts = mutableListOf<String>()
                filterParts.add("[0:v:0]setpts=PTS-STARTPTS," + transScalePrefix + transFpsFilter + "[lv]")
                filterParts.add("[1:v:0]setpts=PTS-STARTPTS," + transScalePrefix + transFpsFilter + "[rv]")
""",
"1j transition filter chains")

must_replace(
r"""                sb.append(" ").append(enc)
                if (planHasAudio) sb.append(" ").append(aEnc)
                sb.append(" \"").append(tSeg.absolutePath).append("\"")
""",
r"""                sb.append(" ").append(transEnc)
                if (planHasAudio) sb.append(" ").append(aEnc)
                sb.append(" \"").append(tSeg.absolutePath).append("\"")
""",
"1j transition encoder")

# ---- 1k. log line: report the plan mode --------------------------------------
must_replace(
"""                (if (merged) "" else ", separate mode")
        )
""",
"""                (if (merged) "" else ", separate mode") +
                (if (reencodeAll) ", simple re-encode mode (scale=" + (scaleFilter ?: "none") +
                    ", " + (fpsArg ?: "fps unchanged") + ")" else "")
        )
""",
"1k log line")

with open(P, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase11] step1: SmartExportPlanner.kt patched (11 edits)")
PLANNERPY
fi

echo "[phase11] step1 done"

###############################################################################
# Step 2 -- ExportSettingsDialog.kt patches
###############################################################################
if grep -Fq "private fun smartReencodeMode" "$ESD"; then
  log "step2: [skip] dialog already patched (phase 11 present)"
else
python3 <<'ESDPY'
import sys

def die(m):
    print("[phase11][ERROR] " + m)
    sys.exit(1)

E = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
with open(E, "r", encoding="utf-8") as f:
    s = f.read()

def must_replace(old, new, what):
    global s
    n = s.count(old)
    if n != 1:
        die("dialog patch (%s): snippet count = %d (expected 1)" % (what, n))
    s = s.replace(old, new, 1)

# ---- 2a. class doc: phase 11 bullet ------------------------------------------
must_replace(
""" *  - MP4 faststart + source metadata preservation toggles.
""",
""" *  - MP4 faststart + source metadata preservation toggles.
 *  - Phase 11: resolution / FPS changes keep the smart path - the plan
 *    switches to the simple re-encode command (a scale / -r flag per
 *    changed option) with a lossless concat assembly.
""",
"2a class doc")

# ---- 2b. smartReencodeMode helper (after smartUnavailableNote) ----------------
must_replace(
"""        return gate?.let { "smart export disabled by these settings: $it - full re-encode used" }
    }
""",
"""        return gate?.let { "smart export disabled by these settings: $it - full re-encode used" }
    }

    /**
     * True when a resolution / fps / custom-size change switches the smart
     * plan to the simple re-encode template (phase 11): one command per
     * timeline segment with a scale / -r flag per changed option, followed
     * by the lossless concat assembly. Mirrors the planner's own logic.
     */
    private fun smartReencodeMode(a: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis): Boolean {
        val customScale = customW >= 16 && customH >= 16
        val resChange = !customScale && selRes != 0 && selRes != a.displayHeight && selRes != a.shortSide
        val fpsChange = selFps != 0 && selFps != a.fpsRounded
        return customScale || resChange || fpsChange
    }
""",
"2b smartReencodeMode")

# ---- 2c. buildSmartSummary: route re-encode mode -------------------------------
must_replace(
"""        val a = smartAnalysis ?: return null
        if (a.reason != null) return null
        if (smartUnavailableNote() != null) return null
        if (selSeparateFiles) {
""",
"""        val a = smartAnalysis ?: return null
        if (a.reason != null) return null
        if (smartUnavailableNote() != null) return null
        if (smartReencodeMode(a)) return buildSmartReencodeSummary(a)
        if (selSeparateFiles) {
""",
"2c buildSmartSummary route")

# ---- 2d. buildSmartReencodeSummary (before smartEstimateBytes) -----------------
must_replace(
"""    /** Size estimate that follows the smart plan (copied vs re-encoded parts). */
""",
"""    /**
     * Preview of the simple re-encode plan (phase 11): the per-segment
     * command shape - the classic ffmpeg template with one flag per changed
     * export option - plus the final concat command when a single merged
     * file is exported.
     */
    private fun buildSmartReencodeSummary(
        a: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis
    ): String {
        val customScale = customW >= 16 && customH >= 16
        val resChange = !customScale && selRes != 0 && selRes != a.displayHeight && selRes != a.shortSide
        val fpsChange = selFps != 0 && selFps != a.fpsRounded
        val scaleSpec: String = when {
            customScale -> "scale=" + (customW - customW % 2) + ":" + (customH - customH % 2)
            resChange -> if (a.displayHeight >= a.displayWidth) "scale=" + selRes + ":-2" else "scale=-2:" + selRes
            else -> ""
        }
        val vCodecLabel = if (a.vCodec == "hevc") "libx265" else "libx264"
        val aBitrate = if (selAudioBitrate.isNotEmpty()) selAudioBitrate else "192k"
        val sb = StringBuilder()
        sb.append("ffmpeg [-ss S] [-t D] -i input -map 0:v:0")
        if (a.hasAudio) sb.append(" -map 0:a:0")
        if (scaleSpec.isNotEmpty()) sb.append(" -vf ").append(scaleSpec)
        if (fpsChange) sb.append(" -r ").append(selFps)
        sb.append(" -c:v ").append(vCodecLabel).append(" -b:v ").append(currentBitrateString())
        if (a.hasAudio) sb.append(" -c:a aac -b:a ").append(aBitrate)
        sb.append(" seg_N.mp4   (one command per timeline segment)")
        if (!selSeparateFiles) {
            sb.append("\\nffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
            if (a.hasAudio) sb.append(" -map 0:a:0")
            if (selPreserveMetadata) sb.append(" -map_metadata 1")
            sb.append(" -c copy -bsf:v dump_extra")
            if (selFastStart) sb.append(" -movflags +faststart")
            sb.append(" output.mp4")
        }
        sb.append("\\n\\n(smart export: ").append(a.clips.size)
        sb.append(if (selSeparateFiles) " separate output files, all re-encoded" else " segments, all re-encoded")
        if (scaleSpec.isNotEmpty()) {
            if (customScale) {
                sb.append(" to ").append(customW - customW % 2).append("x").append(customH - customH % 2)
            } else {
                sb.append(" to ").append(selRes).append("p short side")
            }
        }
        if (fpsChange) sb.append(" @ ").append(selFps).append("fps")
        sb.append("; cuts are frame-accurate; ")
        sb.append(if (selSeparateFiles) "no assembly step" else "assembly is a stream-copy concat")
        sb.append(")")
        return sb.toString()
    }

    /** Size estimate that follows the smart plan (copied vs re-encoded parts). */
""",
"2d buildSmartReencodeSummary")

# ---- 2e. smartEstimateBytes: all-encoded estimate -------------------------------
must_replace(
"""        if (smartUnavailableNote() != null) return null
        var copySec = 0.0
""",
"""        if (smartUnavailableNote() != null) return null
        if (smartReencodeMode(a)) {
            // Simple re-encode plan (phase 11): every second is re-encoded
            // at the chosen bitrate (no stream-copied parts).
            var totalSec = 0.0
            for (i in a.clips.indices) {
                val dLeft = if (!selSeparateFiles && i > 0) a.transitions[i - 1] ?: 0L else 0L
                val dRight = if (!selSeparateFiles && i < a.clips.size - 1) a.transitions[i] ?: 0L else 0L
                val spanMs = (a.clips[i].trimEndMs - dRight) - (a.clips[i].trimStartMs + dLeft)
                if (spanMs > 0L) totalSec += spanMs / 1000.0
            }
            if (!selSeparateFiles) totalSec += a.transitions.values.sum() / 1000.0
            val aKbps = when {
                selAudioCodec == "pcm_s16le" -> 1411
                selAudioCodec == "flac" -> 900
                else -> selAudioBitrate.dropLast(1).toIntOrNull() ?: 128
            }
            return (totalSec * (effectiveVideoKbps() + aKbps)) * 1000.0 / 8.0
        }
        var copySec = 0.0
""",
"2e smartEstimateBytes reencode branch")

with open(E, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase11] step2: ExportSettingsDialog.kt patched (5 edits)")
ESDPY
fi

echo "[phase11] step2 done"

###############################################################################
# Step 3 -- verification gate (exits 1 BEFORE anything commits)
###############################################################################
log "step3: running verification gate"

python3 <<'GATEPY'
import re
import subprocess
import sys

def die(m):
    print("[phase11][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def head(p):
    r = subprocess.run(["git", "show", "HEAD:" + p], capture_output=True, text=True)
    if r.returncode != 0:
        die("git show failed for " + p)
    return r.stdout

P = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
E = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
ps = rd(P)
es = rd(E)

# ---- 3a. planner inventory: new machinery present, stale gates gone ----------
inv = [
    "val reencodeAll = customScale || resChange || fpsChange",
    "val scaleFilter: String? = when {",
    'val fpsArg: String? = if (fpsChange) "-r " + exportFps else null',
    'val encSimple: String = if (refParams.vCodec == "hevc") {',
    "val transScalePrefix = if (reencodeAll && scaleFilter != null) scaleFilter + \",\" else \"\"",
    'val transFpsFilter = if (reencodeAll && fpsChange) "fps=" + exportFps else fpsFilter',
    "val transEnc = if (reencodeAll) encSimple else enc",
    "val displayWidth: Int,",
    "val vCodec: String,",
    "displayWidth = displayWidth,",
    "vCodec = refParams.vCodec,",
    "SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, \"\", reason)",
]
for tok in inv:
    if tok not in ps:
        die("planner inventory: expected token missing: %r" % tok)
for stale in ['"resolution change"', '"fps change"', '"custom resolution"']:
    if stale in ps:
        die("planner inventory: stale gate still present: %r" % stale)
print("[ok] planner inventory: 12 new tokens present, 3 stale gates gone")

# ---- 3b. planner exact counts --------------------------------------------------
counts = [
    ("reencodeAll", 7),
    ("encSimple", 3),
    ("scaleFilter", 6),
    ("fpsArg", 4),
    ("-noautorotate", 7),
    ("settingsBlockSmart(", 1),
]
for tok, want in counts:
    got = ps.count(tok)
    if got != want:
        die("planner count: %r = %d, expected %d" % (tok, got, want))
print("[ok] planner counts: reencodeAll 7 / encSimple 3 / scaleFilter 6 / fpsArg 4 / -noautorotate 7")

# ---- 3c. dialog inventory + counts ---------------------------------------------
dinv = [
    "private fun smartReencodeMode(",
    "private fun buildSmartReencodeSummary(",
    "if (smartReencodeMode(a)) return buildSmartReencodeSummary(a)",
    "if (smartReencodeMode(a)) {",
]
for tok in dinv:
    if tok not in es:
        die("dialog inventory: expected token missing: %r" % tok)
dcnts = [
    ("smartReencodeMode", 3),
    ("buildSmartReencodeSummary", 2),
    ("settingsBlockSmart(", 1),
    ("-b:v ", 1),
    (" -vf ", 1),
]
for tok, want in dcnts:
    got = es.count(tok)
    if got != want:
        die("dialog count: %r = %d, expected %d" % (tok, got, want))
print("[ok] dialog counts: smartReencodeMode 3 / buildSmartReencodeSummary 2 / -b:v 1 / -vf 1")

# ---- 3d. function inventory vs HEAD (no live function lost) ---------------------
def funs(t):
    return set(re.findall(r"(?:private |internal |public )?fun (\w+)\(", t))

for path, cur, expect_added in ((P, ps, set()), (E, es, {"smartReencodeMode", "buildSmartReencodeSummary"})):
    old = funs(head(path))
    new = funs(cur)
    added = new - old
    removed = old - new
    if removed:
        die("function inventory %s: functions LOST: %s" % (path, sorted(removed)))
    if added not in (expect_added, set()):
        die("function inventory %s: unexpected added functions: %s" % (path, sorted(added)))
print("[ok] function inventory: planner unchanged, dialog +2 (smartReencodeMode, buildSmartReencodeSummary)")

# ---- 3e. brace/paren balance vs HEAD ---------------------------------------------
for path, cur in ((P, ps), (E, es)):
    old = head(path)
    db = cur.count("{") - old.count("{") - (cur.count("}") - old.count("}"))
    dp = cur.count("(") - old.count("(") - (cur.count(")") - old.count(")"))
    if db != 0:
        die("brace delta mismatch %s (%+d)" % (path, db))
    if dp != 0:
        die("paren delta mismatch %s (%+d)" % (path, dp))
print("[ok] brace/paren balance vs HEAD (delta 0/0 for both files)")

# ---- 3f. survival asserts (phase 9/10/10.2 machinery untouched) -----------------
psurv = [
    "-f concat -safe 0",
    "-avoid_negative_ts make_zero",
    "xfade=transition=",
    "anullsrc=r=",
    "sweepStaleWorkDirs(",
    'planObj.put("separate"',
    'planObj.put("commands"',
    "nextSegmentFile()",
    "videoEncoderArgs(",
    "audioEncoderArgs(",
    "sanitizeTransitionType(",
    "keyframeCut: Boolean",
]
for tok in psurv:
    if tok not in ps:
        die("planner survival: token missing: %r" % tok)
esurv = [
    "wireChipRow(",
    "smartUnavailableNote()",
    "buildSmartSummary()",
    "smartEstimateBytes()",
    "commandPreviewText(",
    "estimateSizeText(",
    "settingsBlockSmart(",
    "private var selKeyframeCut = true",
]
for tok in esurv:
    if tok not in es:
        die("dialog survival: token missing: %r" % tok)
print("[ok] survival: %d planner + %d dialog kept-feature tokens present" % (len(psurv), len(esurv)))

# ---- 3g. ASCII purity (no NEW non-ASCII bytes) -----------------------------------
for path, cur in ((P, ps), (E, es)):
    old = head(path)
    b = open(path, "rb").read()
    h = old.encode("utf-8", "surrogateescape")
    n_new = sum(1 for c in b if c > 127)
    n_old = sum(1 for c in h if c > 127)
    if n_new != n_old:
        die("non-ASCII byte count changed %s (%d -> %d)" % (path, n_old, n_new))
print("[ok] ASCII purity: no new non-ASCII bytes in either file")

print("[phase11] step3: ALL GATES GREEN")
GATEPY

###############################################################################
# Step 4 -- scope + .github policy (final pre-commit safety net)
###############################################################################
log "step4: scope gate"

SCOPE_OK=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  path="$(echo "$line" | awk '{print $NF}')"
  case "$path" in
    "$PLANNER"|"$ESD"|scripts/apply-changes.sh) ;;
    *) echo "[phase11][ERROR] out-of-scope change: $path" >&2; SCOPE_OK=1 ;;
  esac
done < <(git status --porcelain)

[ "$SCOPE_OK" = "0" ] || fail "scope gate failed (unexpected files modified)"

if git status --porcelain | grep -q "\.github/"; then
  fail "POLICY: workflow files must never be modified by this script"
fi

log "ALL DONE -- phase 11 applied cleanly"
log "summary: export settings now map 1:1 to ffmpeg options; res/fps changes use the simple re-encode template instead of the legacy filter graph"
