#!/usr/bin/env bash
###############################################################################
# CutLoss phase 10 -- LosslessCut-inspired export upgrades (parts 1-4)
#
# PART 1 -- HONEST SMART-EXPORT PREVIEW (export dialog):
#    The export dialog used buildConsolidatedFFmpegCommand for its live
#    preview, so it ALWAYS showed the legacy re-encode command and claimed
#    "stream copy not possible" even when the phase 9 smart pipeline would
#    actually stream-copy most of the footage. The dialog now probes smart
#    eligibility off the main thread (new analyzeSmartExport /
#    settingsBlockSmart in SmartExportPlanner, read-only, no side effects)
#    and shows the plan that WILL run: per-segment copy vs re-encoded
#    seconds, the lossless concat assembly, and a truthful size estimate.
#
# PART 2 -- KEYFRAME CUT MODE (LosslessCut "keyframeCut"):
#    New Cut Mode chips in the dialog: Normal (accurate - only the trimmed
#    spans are re-encoded) vs Keyframe (fast + lossless). In keyframe mode
#    trim points snap to the PRECEDING keyframe via input seeking (-ss
#    before -i, exactly LosslessCut's semantics), so every segment becomes
#    a pure stream copy (-c copy -avoid_negative_ts make_zero).
#
# PART 3 -- SEPARATE-FILES EXPORT MODE (LosslessCut "Export mode"):
#    New Export Mode chips: Single file (merged, current behavior) vs
#    Separate files (one gallery entry per timeline clip). Separate mode
#    skips transitions and the concat step; plan.json moves to an object
#    format {"separate":bool,"outputs":[...],"commands":[...]} and
#    ExportService saves every output file to the gallery.
#
# PART 4 -- METADATA + MP4 FASTSTART (LosslessCut "preserveMetadata" /
#    "movFastStart"): new Keep/Strip metadata and faststart On/Off chips.
#    Smart path: concat gains -i seg0 + -map_metadata 1 + -movflags
#    +faststart. Legacy path: both consolidated builders + the no-op remux
#    fast path gain -map_metadata 0/-1 and -movflags +faststart for MP4.
#
# Invariants: pure ASCII, idempotent (2nd run = all [skip], zero diff),
# hard verification gate exits 1 BEFORE anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase10] $*"; }
fail() { echo "[phase10][ERROR] $*" >&2; exit 1; }

VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
EXPS="app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
XML="app/src/main/res/layout/dialog_export_settings.xml"

###############################################################################
# Step 0 -- preconditions + idempotency marker
###############################################################################
log "step0: checking preconditions"
[ -f "$VM" ]      || fail "VideoEditingViewModel.kt not found"
[ -f "$VEA" ]     || fail "VideoEditingActivity.kt not found"
[ -f "$ESD" ]     || fail "ExportSettingsDialog.kt not found"
[ -f "$EXPS" ]    || fail "ExportService.kt not found"
[ -f "$PLANNER" ] || fail "SmartExportPlanner.kt not found (phase 9 base required)"
[ -f "$XML" ]     || fail "dialog_export_settings.xml not found"

grep -q "data class AdvancedExport(" "$VM" \
  || fail "AdvancedExport model not found (unexpected tree state)"
grep -q "fun planSmartExport(" "$PLANNER" \
  || fail "planSmartExport not found (unexpected tree state)"
grep -q "private suspend fun runSmartExport" "$EXPS" \
  || fail "runSmartExport not found (unexpected tree state)"
grep -q "planSmartExport(" "$VEA" \
  || fail "saveAction planner call not found (unexpected tree state)"
grep -q "wireChipRow" "$ESD" \
  || fail "ExportSettingsDialog chip wiring not found (unexpected tree state)"
grep -q "tvCommand" "$XML" \
  || fail "export dialog XML command box not found"

if grep -q "fun analyzeSmartExport(" "$PLANNER"; then
  APPLIED=1
  log "step0: phase-10 markers present -> SKIP mode (idempotent re-run)"
else
  APPLIED=0
  log "step0: [ok] base tree confirmed"
fi

###############################################################################
# Step 1 -- VideoEditingViewModel.kt (part 4: model fields + container args)
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step1: [skip] VM already patched"
else
python3 <<'VMPY'
import sys

def die(m):
    print("[phase10][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def wr(path, s):
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(s, old, new, what):
    if old not in s:
        die("VM anchor missing: " + what)
    if s.count(old) != 1:
        die("VM anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

VM_PATH = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
s = rw(VM_PATH)

# ---- 1a. AdvancedExport: four new fields -------------------------------
old = """        val customWidth: Int = 0,             // 0 = not set
        val customHeight: Int = 0             // 0 = not set
    )
"""
new = """        val customWidth: Int = 0,             // 0 = not set
        val customHeight: Int = 0,            // 0 = not set
        val keyframeCut: Boolean = false,     // trim points snap to keyframes -> pure stream copy
        val exportSeparateFiles: Boolean = false, // one output file per timeline clip
        val movFastStart: Boolean = true,     // -movflags +faststart on MP4 output
        val preserveMetadata: Boolean = true  // keep the source's global metadata in the output
    )
"""
s = must_replace(s, old, new, "AdvancedExport fields")

# ---- 1b. shared container-args helper ------------------------------------
old = """        return when (adv.videoFormat) {
            "mkv" -> ".mkv"; "mov" -> ".mov"; "webm" -> ".webm"; "avi" -> ".avi"
            else -> ".mp4"
        }
    }
"""
new = """        return when (adv.videoFormat) {
            "mkv" -> ".mkv"; "mov" -> ".mov"; "webm" -> ".webm"; "avi" -> ".avi"
            else -> ".mp4"
        }
    }

    /**
     * Output container flags shared by the legacy render paths (phase 10):
     *  - metadata  : -map_metadata 0 keeps the source's global metadata
     *                (which is also ffmpeg's default); -map_metadata -1
     *                strips it from the output entirely.
     *  - faststart : -movflags +faststart relocates the MP4 moov atom to
     *                the front so players can start before the whole file
     *                has been read (streaming-friendly).
     */
    private fun appendOutputContainerArgs(cmd: StringBuilder) {
        val adv = _advancedExport.value
        if (_exportAudioOnly.value) return
        if (adv.preserveMetadata) {
            cmd.append(" -map_metadata 0")
        } else {
            cmd.append(" -map_metadata -1")
        }
        if (adv.movFastStart && adv.videoFormat == "mp4") {
            cmd.append(" -movflags +faststart")
        }
    }
"""
s = must_replace(s, old, new, "appendOutputContainerArgs insertion point")

# ---- 1c. no-operations fast remux path -----------------------------------
old = """        if (currentProject.operations.isEmpty()) {
            return "-y -i \\"$sourceFilePath\\" -c copy \\"$outputFilePath\\""
        }
"""
new = """        if (currentProject.operations.isEmpty()) {
            val remux = StringBuilder("-y -i \\"").append(sourceFilePath).append("\\"")
            appendOutputContainerArgs(remux)
            remux.append(" -c copy \\"").append(outputFilePath).append("\\"")
            return remux.toString()
        }
"""
s = must_replace(s, old, new, "no-op remux fast path")

# ---- 1d. legacy MERGE builder tail ---------------------------------------
old = """            if (outputDuration != null) {
                cmd.append(" -t $outputDuration")
            }
            cmd.append(" \\"$outputFilePath\\"")

            val finalCommand = cmd.toString()
            Log.d(TAG, "Built merge command: $finalCommand")
"""
new = """            if (outputDuration != null) {
                cmd.append(" -t $outputDuration")
            }
            appendOutputContainerArgs(cmd)
            cmd.append(" \\"$outputFilePath\\"")

            val finalCommand = cmd.toString()
            Log.d(TAG, "Built merge command: $finalCommand")
"""
s = must_replace(s, old, new, "merge builder tail")

# ---- 1e. legacy single/non-merge builder tail ----------------------------
old = """        if (outputDuration != null) {
            cmd.append(" -t $outputDuration")
        }
        cmd.append(" \\"$outputFilePath\\"")

        val finalCommand = cmd.toString()
        Log.d(TAG, "Built command: $finalCommand")
"""
new = """        if (outputDuration != null) {
            cmd.append(" -t $outputDuration")
        }
        appendOutputContainerArgs(cmd)
        cmd.append(" \\"$outputFilePath\\"")

        val finalCommand = cmd.toString()
        Log.d(TAG, "Built command: $finalCommand")
"""
s = must_replace(s, old, new, "non-merge builder tail")

wr(VM_PATH, s)
print("[phase10] step1: VM patched (AdvancedExport +4 fields, container args x3 paths)")
VMPY
fi

echo "[phase10] step1 done"

###############################################################################
# Step 2 -- SmartExportPlanner.kt (parts 1+2+3+4 on the smart path)
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step2: [skip] planner already patched"
else
python3 <<'PLPY'
import sys

def die(m):
    print("[phase10][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def wr(path, s):
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(s, old, new, what):
    if old not in s:
        die("planner anchor missing: " + what)
    if s.count(old) != 1:
        die("planner anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

P = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
s = rw(P)

# ---- 2a. header doc: new command templates ------------------------------
old = r""" *   concat           : -f concat -safe 0 -i list.txt -c copy -bsf:v dump_extra
 */
"""
new = r""" *   concat           : -f concat -safe 0 -i list.txt -i seg0 [-map_metadata 1]
 *                      -c copy -bsf:v dump_extra [-movflags +faststart]
 *
 * Phase 10 additions:
 *   keyframe cut     : trimmed spans use INPUT seeking (-ss before -i), which
 *                      snaps to the preceding keyframe, so they are stream-
 *                      copied - 100% lossless, LosslessCut keyframe-cut
 *                      semantics (up to one GOP of extra head material)
 *   separate files   : one output file per timeline clip; transitions and
 *                      the concat step are skipped entirely
 *   metadata/faststart flags are applied to the final merged output
 */
"""
s = must_replace(s, old, new, "header doc block")

# ---- 2b. analysis API (read-only preview for the dialog) ----------------
old = "    data class SmartPlan(val planFile: File)\n"
new = r'''    data class SmartPlan(val planFile: File)

    /** Per-clip trim info used by the export dialog's live smart preview. */
    data class SmartClipInfo(
        val trimStartMs: Long,
        val trimEndMs: Long,
        val durationMs: Long,
        val fullRange: Boolean,
        val muted: Boolean,
        val hasAudio: Boolean
    )

    /**
     * Read-only eligibility analysis for the export dialog (phase 10).
     * reason != null means the project itself is not copy-compatible; the
     * settings-level gates live in settingsBlockSmart so the dialog can
     * re-check them instantly while the user flips chips. This function has
     * NO side effects: no work dir, no cache copies, no command generation.
     */
    data class SmartAnalysis(
        val clips: List<SmartClipInfo>,
        val transitions: Map<Int, Long>,
        val hasAudio: Boolean,
        val displayHeight: Int,
        val shortSide: Int,
        val fpsRounded: Int,
        val reason: String?
    )

    fun analyzeSmartExport(context: Context, project: VideoProject, sourceFilePath: String): SmartAnalysis? {
        try {
            return analyzeInternal(context, project, sourceFilePath)
        } catch (e: Exception) {
            Log.w(TAG, "smart export analysis failed: " + e.message, e)
            return null
        }
    }

    /**
     * Settings-level gates (cheap, no probing): returns a human readable
     * reason when the current export settings force the legacy render, or
     * null when the smart path can run with these settings.
     */
    fun settingsBlockSmart(
        analysis: SmartAnalysis,
        exportResolution: Int,
        exportFps: Int,
        audioOnly: Boolean,
        advancedVideoCodec: String,
        advancedAudioCodec: String,
        customWidth: Int,
        customHeight: Int,
        videoFormat: String
    ): String? {
        if (audioOnly) return "audio-only export"
        if (videoFormat != "mp4") return "non-MP4 container"
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return "custom codec requested"
        if (customWidth >= 16 || customHeight >= 16) return "custom resolution"
        if (exportResolution != 0 && exportResolution != analysis.displayHeight && exportResolution != analysis.shortSide) {
            return "resolution change"
        }
        if (exportFps != 0 && exportFps != analysis.fpsRounded) return "fps change"
        return null
    }

    private fun analyzeInternal(context: Context, project: VideoProject, sourceFilePath: String): SmartAnalysis {
        fun fail(reason: String): SmartAnalysis =
            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, reason)

        if (isImagePath(sourceFilePath)) return fail("image source")
        val ops = project.operations
        val allowed = ops.all {
            it is EditOperation.Trim || it is EditOperation.Merge ||
                it is EditOperation.Transition || it is EditOperation.MuteClip ||
                it is EditOperation.MuteAudio
        }
        if (!allowed) return fail("edits that force a full re-encode are present")

        val mergeOp = ops.filterIsInstance<EditOperation.Merge>().firstOrNull()
        val trimOp = ops.filterIsInstance<EditOperation.Trim>().lastOrNull()

        val refParams = probeMedia(context, Uri.fromFile(File(sourceFilePath)), sourceFilePath)
            ?: return fail("source could not be probed")
        if (refParams.vCodec != "h264" && refParams.vCodec != "hevc") return fail("source codec is not H.264/HEVC")
        if (refParams.pixFmt != "yuv420p") return fail("source pixel format is not yuv420p")
        if (refParams.width <= 0 || refParams.height <= 0) return fail("bad source dimensions")
        if (refParams.width % 2 != 0 || refParams.height % 2 != 0) return fail("odd source dimensions")
        if (refParams.durationMs <= 0L) return fail("bad source duration")

        data class AClip(
            val params: MediaParams,
            val trimStartMs: Long,
            val trimEndMs: Long,
            val muted: Boolean
        )
        val clips = mutableListOf<AClip>()
        clips.add(
            AClip(
                params = refParams,
                trimStartMs = trimOp?.startMs ?: 0L,
                trimEndMs = trimOp?.endMs ?: refParams.durationMs,
                muted = isClipMuted(ops, 0)
            )
        )
        if (mergeOp != null) {
            for (item in mergeOp.items) {
                if (item.isImage) return fail("image clip in the sequence")
                if (item.speed != 1.0f) return fail("speed-changed clip in the sequence")
                if (item.proxyUri != null) return fail("proxy clip in the sequence")
                val p = probeMedia(context, item.uri, null)
                    ?: return fail("a clip could not be probed")
                if (p.vCodec != refParams.vCodec) return fail("clips use different codecs")
                if (!p.vProfile.equals(refParams.vProfile, ignoreCase = true)) return fail("clips use different profiles")
                if (p.width != refParams.width || p.height != refParams.height) return fail("clips have different dimensions")
                if (p.rotation != refParams.rotation) return fail("clips have different rotation")
                if (p.fpsString != refParams.fpsString) return fail("clips have different frame rates")
                if (p.pixFmt != "yuv420p") return fail("a clip is not yuv420p")
                if (p.durationMs <= 0L) return fail("bad clip duration")
                clips.add(
                    AClip(
                        params = p,
                        trimStartMs = item.trimStartMs.coerceIn(0L, p.durationMs),
                        trimEndMs = item.trimEndMs.coerceAtMost(p.durationMs),
                        muted = isClipMuted(ops, clips.size)
                    )
                )
            }
        }

        val audioRef: MediaParams? = clips.firstOrNull { it.params.hasAudio }?.params
        if (audioRef != null) {
            if (audioRef.aCodec != "aac" && audioRef.aCodec != "mp3") return fail("audio codec is not AAC/MP3")
            if (audioRef.aSampleRate <= 0) return fail("bad audio sample rate")
            if (audioRef.aChannels != 1 && audioRef.aChannels != 2) return fail("audio has more than 2 channels")
            for (c in clips) {
                if (c.params.hasAudio) {
                    if (c.params.aCodec != audioRef.aCodec) return fail("clips use different audio codecs")
                    if (c.params.aSampleRate != audioRef.aSampleRate) return fail("clips use different audio sample rates")
                    if (c.params.aChannels != audioRef.aChannels) return fail("clips use different audio channel counts")
                }
            }
        }

        val transitions = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            transitions[t.index] = Pair(t.type, t.durationMs)
        }
        val clampedTransitions = mutableMapOf<Int, Long>()
        for ((gap, td) in transitions) {
            val leftDur = clips[gap].trimEndMs - clips[gap].trimStartMs
            val rightDur = clips[gap + 1].trimEndMs - clips[gap + 1].trimStartMs
            val d = td.second.coerceAtMost(leftDur).coerceAtMost(rightDur)
            if (d >= 50L) clampedTransitions[gap] = d
        }

        val displayWidth = if (refParams.rotation == 90 || refParams.rotation == 270) refParams.height else refParams.width
        val displayHeight = if (refParams.rotation == 90 || refParams.rotation == 270) refParams.width else refParams.height

        return SmartAnalysis(
            clips = clips.map {
                SmartClipInfo(
                    trimStartMs = it.trimStartMs,
                    trimEndMs = it.trimEndMs,
                    durationMs = it.params.durationMs,
                    fullRange = it.trimStartMs <= 60L && it.trimEndMs >= it.params.durationMs - 60L,
                    muted = it.muted,
                    hasAudio = it.params.hasAudio
                )
            },
            transitions = clampedTransitions,
            hasAudio = audioRef != null,
            displayHeight = displayHeight,
            shortSide = Math.min(displayWidth, displayHeight),
            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            reason = null
        )
    }
'''
s = must_replace(s, old, new, "SmartPlan anchor (analysis API)")

# ---- 2c. planSmartExport signature + pass-through ------------------------
old = r"""        customWidth: Int,
        customHeight: Int,
        videoFormat: String
    ): SmartPlan? {
        try {
            return planInternal(
                context, project, sourceFilePath, outputFilePath,
                exportResolution, exportFps, exportBitrate, audioOnly,
                advancedVideoCodec, advancedAudioCodec, advancedPreset,
                advancedAudioBitrate, customWidth, customHeight, videoFormat
            )
"""
new = r"""        customWidth: Int,
        customHeight: Int,
        videoFormat: String,
        keyframeCut: Boolean = false,
        exportSeparateFiles: Boolean = false,
        movFastStart: Boolean = true,
        preserveMetadata: Boolean = true
    ): SmartPlan? {
        try {
            return planInternal(
                context, project, sourceFilePath, outputFilePath,
                exportResolution, exportFps, exportBitrate, audioOnly,
                advancedVideoCodec, advancedAudioCodec, advancedPreset,
                advancedAudioBitrate, customWidth, customHeight, videoFormat,
                keyframeCut, exportSeparateFiles, movFastStart, preserveMetadata
            )
"""
s = must_replace(s, old, new, "planSmartExport signature")

# ---- 2d. planInternal signature ------------------------------------------
old = r"""        customWidth: Int,
        customHeight: Int,
        videoFormat: String
    ): SmartPlan? {
        sweepStaleWorkDirs(context)
"""
new = r"""        customWidth: Int,
        customHeight: Int,
        videoFormat: String,
        keyframeCut: Boolean,
        exportSeparateFiles: Boolean,
        movFastStart: Boolean,
        preserveMetadata: Boolean
    ): SmartPlan? {
        sweepStaleWorkDirs(context)
"""
s = must_replace(s, old, new, "planInternal signature")

# ---- 2e. merged flag + degeneracy check ----------------------------------
old = r"""        // ---- effective spans + degenerate check ----
        for (i in clips.indices) {
            val dLeft = if (i > 0) clampedTransitions[i - 1]?.second ?: 0L else 0L
            val dRight = if (i < clips.size - 1) clampedTransitions[i]?.second ?: 0L else 0L
            val start = clips[i].trimStartMs + dLeft
            val end = clips[i].trimEndMs - dRight
            if (end <= start) return null
        }
"""
new = r"""        // ---- effective spans + degenerate check ----
        // Separate-files mode skips transitions entirely: each clip is its own
        // output, so spans are NOT shrunk by transition overlaps.
        val merged = !exportSeparateFiles
        for (i in clips.indices) {
            val dLeft = if (merged && i > 0) clampedTransitions[i - 1]?.second ?: 0L else 0L
            val dRight = if (merged && i < clips.size - 1) clampedTransitions[i]?.second ?: 0L else 0L
            val start = clips[i].trimStartMs + dLeft
            val end = clips[i].trimEndMs - dRight
            if (end <= start) return null
        }
"""
s = must_replace(s, old, new, "degeneracy check block")

# ---- 2f. per-clip loop head (merged guards) ------------------------------
old = r"""        for (i in clips.indices) {
            val clip = clips[i]
            val dLeft = if (i > 0) clampedTransitions[i - 1]?.second ?: 0L else 0L
            val dRight = if (i < clips.size - 1) clampedTransitions[i]?.second ?: 0L else 0L
            val spanStart = clip.trimStartMs + dLeft
            val spanEnd = clip.trimEndMs - dRight
            val spanMs = spanEnd - spanStart
            val fullRange = spanStart <= 60L && spanEnd >= clip.durationMs - 60L
            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
            val seg = nextSegmentFile()

            if (fullRange) {
"""
new = r"""        for (i in clips.indices) {
            val clip = clips[i]
            val dLeft = if (merged && i > 0) clampedTransitions[i - 1]?.second ?: 0L else 0L
            val dRight = if (merged && i < clips.size - 1) clampedTransitions[i]?.second ?: 0L else 0L
            val spanStart = clip.trimStartMs + dLeft
            val spanEnd = clip.trimEndMs - dRight
            val spanMs = spanEnd - spanStart
            val fullRange = spanStart <= 60L && spanEnd >= clip.durationMs - 60L
            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
            val seg = nextSegmentFile()

            if (fullRange) {
"""
s = must_replace(s, old, new, "per-clip loop head")

# ---- 2g. keyframe-cut copy branch (part 2) -------------------------------
old = r"""            } else {
                // Trimmed span -> re-encode ONLY this span with matching parameters
                val sb = StringBuilder("-y -noautorotate")
"""
new = r"""            } else if (keyframeCut) {
                // Keyframe cut (LosslessCut-style): -ss BEFORE -i snaps to the
                // preceding keyframe automatically, so the trimmed span is
                // stream-copied - fully lossless, with up to one GOP of extra
                // head material (same semantics as LosslessCut's keyframe cut).
                val sb = StringBuilder("-y -noautorotate")
                if (spanStart > 0L) sb.append(" -ss ").append(ms(spanStart))
                sb.append(" -t ").append(ms(spanMs)).append(" -i \"").append(clip.path).append("\"")
                if (silenceAudio) {
                    sb.append(" -f lavfi -t ").append(ms(spanMs))
                    sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                }
                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                    sb.append(" -c:v copy -avoid_negative_ts make_zero").append(" ").append(aEnc)
                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0 -c copy -avoid_negative_ts make_zero")
                } else {
                    sb.append(" -c copy -avoid_negative_ts make_zero")
                }
                sb.append(" \"").append(seg.absolutePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else {
                // Trimmed span -> re-encode ONLY this span with matching parameters
                val sb = StringBuilder("-y -noautorotate")
"""
s = must_replace(s, old, new, "keyframe-cut branch")

# ---- 2h. transition segment only in merged mode (part 3) -----------------
old = r"""            // Transition segment that starts right after this clip
            val trans = clampedTransitions[i]
"""
new = r"""            // Transition segment that starts right after this clip (merged only)
            val trans = if (merged) clampedTransitions[i] else null
"""
s = must_replace(s, old, new, "transition gate")

# ---- 2i. concat block: merged only + metadata/faststart (part 3+4) -------
old = r"""        // ---- concat all segments with stream copy ----
        val listFile = File(workDir, "concat_list.txt")
        val listSb = StringBuilder()
        for (f in segmentFiles) {
            listSb.append("file '").append(f.absolutePath).append("'\n")
        }
        listFile.writeText(listSb.toString())

        val audioMap = if (planHasAudio && !audioMuted) " -map 0:a:0" else ""
        val concatCmd = "-y -f concat -safe 0 -i \"" + listFile.absolutePath +
            "\" -map 0:v:0" + audioMap + " -c copy -bsf:v dump_extra \"" + outputFilePath + "\""
        commands.add(Pair(concatCmd, 1.0))
"""
new = r"""        // ---- final assembly: concat with stream copy (merged mode only) ----
        // seg_0 is attached as a second input purely so the output can
        // inherit the source's global metadata (-map_metadata 1); faststart
        // relocates the MP4 moov atom to the front of the file.
        if (merged) {
            val listFile = File(workDir, "concat_list.txt")
            val listSb = StringBuilder()
            for (f in segmentFiles) {
                listSb.append("file '").append(f.absolutePath).append("'\n")
            }
            listFile.writeText(listSb.toString())

            val audioMap = if (planHasAudio && !audioMuted) " -map 0:a:0" else ""
            val metaArg = if (preserveMetadata) " -map_metadata 1" else ""
            val fastArg = if (movFastStart) " -movflags +faststart" else ""
            val concatCmd = "-y -f concat -safe 0 -i \"" + listFile.absolutePath +
                "\" -i \"" + segmentFiles[0].absolutePath + "\"" +
                " -map 0:v:0" + audioMap + metaArg + " -c copy -bsf:v dump_extra" + fastArg +
                " \"" + outputFilePath + "\""
            commands.add(Pair(concatCmd, 1.0))
        }
"""
s = must_replace(s, old, new, "concat block")

# ---- 2j. plan json: object form with outputs -----------------------------
old = r"""        // ---- plan json ----
        val arr = JSONArray()
        for (pair in commands) {
            val o = JSONObject()
            o.put("cmd", pair.first)
            o.put("weight", pair.second)
            arr.put(o)
        }
        val planFile = File(workDir, "plan.json")
        planFile.writeText(arr.toString())

        Log.d(
            TAG,
            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                ", transitions=" + clampedTransitions.size
        )
        return SmartPlan(planFile)
"""
new = r"""        // ---- plan json (phase 10: object form; plain array = phase 9 plan) ----
        val arr = JSONArray()
        for (pair in commands) {
            val o = JSONObject()
            o.put("cmd", pair.first)
            o.put("weight", pair.second)
            arr.put(o)
        }
        val outputs = if (merged) listOf(outputFilePath) else segmentFiles.map { it.absolutePath }
        val planObj = JSONObject()
        planObj.put("separate", exportSeparateFiles)
        planObj.put("outputs", JSONArray(outputs))
        planObj.put("commands", arr)
        val planFile = File(workDir, "plan.json")
        planFile.writeText(planObj.toString())

        Log.d(
            TAG,
            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                ", transitions=" + (if (merged) clampedTransitions.size else 0) +
                (if (merged) "" else ", separate mode")
        )
        return SmartPlan(planFile)
"""
s = must_replace(s, old, new, "plan json block")

wr(P, s)
print("[phase10] step2: planner patched (analysis API, keyframe cut, separate mode, concat flags, plan.json v2)")
PLPY
fi

echo "[phase10] step2 done"

###############################################################################
# Step 3 -- ExportService.kt (part 3: object plan format + multi-file save)
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step3: [skip] ExportService already patched"
else
python3 <<'ESPY'
import sys

def die(m):
    print("[phase10][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def wr(path, s):
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(s, old, new, what):
    if old not in s:
        die("ExportService anchor missing: " + what)
    if s.count(old) != 1:
        die("ExportService anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

E = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
s = rw(E)

# ---- 3a. nested data classes ---------------------------------------------
old = r"""    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
"""
new = r"""    /** Phase 10 plan.json parse result (commands + explicit output list). */
    private data class ParsedPlan(val commands: List<Pair<String, Double>>, val outputs: List<String>)

    /** runSmartExport result: render status plus the output files it produced. */
    data class SmartExportOutcome(
        val result: FFmpegRenderEngine.RenderResult,
        val outputFiles: List<File>
    )

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
"""
s = must_replace(s, old, new, "onCreate anchor (data classes)")

# ---- 3b. result computation in onStartCommand -----------------------------
old = r"""                val result: FFmpegRenderEngine.RenderResult = when {
                    smartPlanPath != null -> runSmartExport(smartPlanPath)
                    command != null -> ffmpegEngine.exportFinal(
"""
new = r"""                val smartOutcome: SmartExportOutcome? =
                    if (smartPlanPath != null) runSmartExport(smartPlanPath) else null
                val result: FFmpegRenderEngine.RenderResult = when {
                    smartOutcome != null -> smartOutcome.result
                    command != null -> ffmpegEngine.exportFinal(
"""
s = must_replace(s, old, new, "onStartCommand result block")

# ---- 3c. Success branch: multi-file gallery save --------------------------
old = r"""                when (result) {
                    is FFmpegRenderEngine.RenderResult.Success -> {
                        val savedUri = saveVideoToGallery(tempFile, isAudioOnly)
                        if (savedUri != null) {
                            showCompletionNotification("Export Complete", "Video saved to gallery", savedUri)
                            broadcastSuccess(savedUri.toString())
                            Log.d(TAG, "Export successful: $savedUri")
                        } else {
                            showCompletionNotification("Export Failed", "Failed to save video to gallery", null)
                            broadcastFailure("Failed to save video to gallery")
                        }
                    }
"""
new = r"""                when (result) {
                    is FFmpegRenderEngine.RenderResult.Success -> {
                        // Phase 10: smart separate-files mode produces one output
                        // file per timeline clip - each becomes its own gallery entry.
                        val smartFiles = smartOutcome?.outputFiles ?: emptyList()
                        val filesToSave = if (smartFiles.isNotEmpty()) smartFiles else listOf(tempFile)
                        if (filesToSave.size > 1) {
                            val saved = mutableListOf<Uri>()
                            for (f in filesToSave) {
                                val uri = saveVideoToGallery(f, false)
                                if (uri != null) saved.add(uri)
                            }
                            if (saved.isNotEmpty()) {
                                showCompletionNotification(
                                    "Export Complete",
                                    "${saved.size} of ${filesToSave.size} files saved to gallery",
                                    saved.first()
                                )
                                broadcastSuccess(saved.first().toString())
                                Log.d(TAG, "Separate export successful: ${saved.size} files")
                            } else {
                                showCompletionNotification("Export Failed", "Failed to save videos to gallery", null)
                                broadcastFailure("Failed to save videos to gallery")
                            }
                        } else {
                            val savedUri = saveVideoToGallery(filesToSave[0], isAudioOnly)
                            if (savedUri != null) {
                                showCompletionNotification("Export Complete", "Video saved to gallery", savedUri)
                                broadcastSuccess(savedUri.toString())
                                Log.d(TAG, "Export successful: $savedUri")
                            } else {
                                showCompletionNotification("Export Failed", "Failed to save video to gallery", null)
                                broadcastFailure("Failed to save video to gallery")
                            }
                        }
                    }
"""
s = must_replace(s, old, new, "Success branch")

# ---- 3d. runSmartExport: outcome + plan parser ----------------------------
old = r"""    /**
     * Smart export mode (phase 9): runs the plan produced by
     * SmartExportPlanner command-by-command with aggregated progress. The
     * last command is the concat step that writes the final output file, so
     * its Success result carries the output path for the regular save flow.
     */
    private suspend fun runSmartExport(planPath: String): FFmpegRenderEngine.RenderResult {
        val planFile = File(planPath)
        if (!planFile.exists()) {
            return FFmpegRenderEngine.RenderResult.Failure("Smart export plan not found")
        }
        val commands = try {
            val arr = org.json.JSONArray(planFile.readText())
            val list = mutableListOf<Pair<String, Double>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                list.add(Pair(o.getString("cmd"), o.optDouble("weight", 1.0)))
            }
            list
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse smart export plan: ${e.message}", e)
            return FFmpegRenderEngine.RenderResult.Failure("Invalid smart export plan")
        }
        if (commands.isEmpty()) {
            return FFmpegRenderEngine.RenderResult.Failure("Empty smart export plan")
        }
"""
new = r"""    /**
     * Smart export mode (phase 9/10): runs the plan produced by
     * SmartExportPlanner command-by-command with aggregated progress. In
     * merged mode the last command is the concat step that writes the final
     * output file; in separate mode (phase 10) every segment file IS an
     * output. plan.json is read in object form ({"separate":...,
     * "outputs":[...], "commands":[...]}) with the phase 9 plain-array form
     * still accepted.
     */
    private suspend fun runSmartExport(planPath: String): SmartExportOutcome {
        val planFile = File(planPath)
        if (!planFile.exists()) {
            return SmartExportOutcome(
                FFmpegRenderEngine.RenderResult.Failure("Smart export plan not found"),
                emptyList()
            )
        }
        val parsed: ParsedPlan = try {
            parseSmartPlan(planFile)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse smart export plan: ${e.message}", e)
            return SmartExportOutcome(
                FFmpegRenderEngine.RenderResult.Failure("Invalid smart export plan"),
                emptyList()
            )
        }
        val commands = parsed.commands
        if (commands.isEmpty()) {
            return SmartExportOutcome(
                FFmpegRenderEngine.RenderResult.Failure("Empty smart export plan"),
                emptyList()
            )
        }
"""
s = must_replace(s, old, new, "runSmartExport head")

# ---- 3e. runSmartExport tail: outcome return + parseSmartPlan -------------
old = r"""        broadcastProgress(100)
        updateNotification(100, "Exporting...")
        return lastResult
    }
"""
new = r"""        broadcastProgress(100)
        updateNotification(100, "Exporting...")
        return SmartExportOutcome(lastResult, parsed.outputs.map { File(it) })
    }

    /**
     * Parse a phase 10 plan.json (object form) or a phase 9 plan (plain
     * array of {cmd, weight} objects; outputs stay empty -> the caller falls
     * back to the temp output path).
     */
    private fun parseSmartPlan(planFile: File): ParsedPlan {
        val raw = planFile.readText().trim()
        if (raw.startsWith("[")) {
            val arr = org.json.JSONArray(raw)
            val list = mutableListOf<Pair<String, Double>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                list.add(Pair(o.getString("cmd"), o.optDouble("weight", 1.0)))
            }
            return ParsedPlan(list, emptyList())
        }
        val obj = org.json.JSONObject(raw)
        val arr = obj.getJSONArray("commands")
        val list = mutableListOf<Pair<String, Double>>()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            list.add(Pair(o.getString("cmd"), o.optDouble("weight", 1.0)))
        }
        val outArr = obj.optJSONArray("outputs")
        val outs = mutableListOf<String>()
        if (outArr != null) {
            for (i in 0 until outArr.length()) outs.add(outArr.getString(i))
        }
        return ParsedPlan(list, outs)
    }
"""
s = must_replace(s, old, new, "runSmartExport tail")

wr(E, s)
print("[phase10] step3: ExportService patched (outcome type, plan parser, multi-file gallery save)")
ESPY
fi

echo "[phase10] step3 done"

###############################################################################
# Step 4 -- VideoEditingActivity.kt (planner call args + fallback toast)
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step4: [skip] VEA already patched"
else
python3 <<'VEAPY'
import sys

def die(m):
    print("[phase10][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def wr(path, s):
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(s, old, new, what):
    if old not in s:
        die("VEA anchor missing: " + what)
    if s.count(old) != 1:
        die("VEA anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

V = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
s = rw(V)

# ---- 4a. planner call: four new named arguments ---------------------------
old = r"""                            customWidth = viewModel.advancedExport.value.customWidth,
                            customHeight = viewModel.advancedExport.value.customHeight,
                            videoFormat = viewModel.advancedExport.value.videoFormat
                        )?.planFile?.absolutePath
"""
new = r"""                            customWidth = viewModel.advancedExport.value.customWidth,
                            customHeight = viewModel.advancedExport.value.customHeight,
                            videoFormat = viewModel.advancedExport.value.videoFormat,
                            keyframeCut = viewModel.advancedExport.value.keyframeCut,
                            exportSeparateFiles = viewModel.advancedExport.value.exportSeparateFiles,
                            movFastStart = viewModel.advancedExport.value.movFastStart,
                            preserveMetadata = viewModel.advancedExport.value.preserveMetadata
                        )?.planFile?.absolutePath
"""
s = must_replace(s, old, new, "planner call args")

# ---- 4b. separate-files fallback toast on the legacy path -----------------
old = r"""                    Toast.makeText(this@VideoEditingActivity, "Export started in background...", Toast.LENGTH_SHORT).show()
                    return@launch
                }

                var ffmpegCommand = viewModel.buildConsolidatedFFmpegCommand(
"""
new = r"""                    Toast.makeText(this@VideoEditingActivity, "Export started in background...", Toast.LENGTH_SHORT).show()
                    return@launch
                }

                // Separate-files mode only works on the smart pipeline; when the
                // planner bailed out (speed / overlays / mixed codecs / ...) we
                // tell the user instead of silently exporting one merged file.
                if (viewModel.advancedExport.value.exportSeparateFiles) {
                    Toast.makeText(
                        this@VideoEditingActivity,
                        "Separate-files export needs smart-compatible edits - exporting one merged file instead",
                        Toast.LENGTH_LONG
                    ).show()
                }

                var ffmpegCommand = viewModel.buildConsolidatedFFmpegCommand(
"""
s = must_replace(s, old, new, "separate fallback toast")

wr(V, s)
print("[phase10] step4: VEA patched (planner args + separate fallback toast)")
VEAPY
fi

echo "[phase10] step4 done"

###############################################################################
# Step 5 -- ExportSettingsDialog.kt (parts 1+2+3+4 UI + smart preview)
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step5: [skip] ExportSettingsDialog already patched"
else
python3 <<'ESDPY'
import sys

def die(m):
    print("[phase10][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def wr(path, s):
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(s, old, new, what):
    if old not in s:
        die("ESD anchor missing: " + what)
    if s.count(old) != 1:
        die("ESD anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

D = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
s = rw(D)

# ---- 5a. class doc: v3 -> v4 ----------------------------------------------
old = r""" * CutStudio - Export settings dialog (v3).
 *
"""
new = r""" * CutStudio - Export settings dialog (v4).
 *
 * v4 (phase 10, LosslessCut-inspired):
 *  - Smart-export preview: eligibility is probed off-thread and the dialog
 *    shows the plan that WILL run (stream-copied vs re-encoded seconds,
 *    lossless concat) instead of always showing the legacy re-encode.
 *  - Cut mode: Normal (accurate trim re-encode) vs Keyframe (trim points
 *    snap to keyframes -> 100% stream copy, one-GOP tolerance).
 *  - Export mode: single merged file or one file per timeline clip.
 *  - MP4 faststart + source metadata preservation toggles.
 *
"""
s = must_replace(s, old, new, "class doc header")

# ---- 5b. new state fields --------------------------------------------------
old = "    private var suppressBoxClear = false\n"
new = r'''    private var suppressBoxClear = false
    private var selKeyframeCut = false
    private var selSeparateFiles = false
    private var selFastStart = true
    private var selPreserveMetadata = true

    // ---- smart export analysis (phase 10, cached for the dialog lifetime) ----
    private var smartAnalysis: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis? = null
    private var smartAnalysisDone = false
'''
s = must_replace(s, old, new, "state fields")

# ---- 5c. show(): init new selections + start analysis thread --------------
old = "        parseBitrate(snapBitrate)\n"
new = r'''        parseBitrate(snapBitrate)

        selKeyframeCut = snapAdvanced.keyframeCut
        selSeparateFiles = snapAdvanced.exportSeparateFiles
        selFastStart = snapAdvanced.movFastStart
        selPreserveMetadata = snapAdvanced.preserveMetadata

        // Smart-export eligibility depends only on the PROJECT (ops + clip
        // parameters), never on the dialog settings - so it is probed once,
        // off the main thread, and cached for the lifetime of the dialog.
        smartAnalysisDone = false
        smartAnalysis = null
        val analysisProject = viewModel.project.value
        val analysisSource = sourceFile?.absolutePath
        if (analysisProject != null && analysisSource != null) {
            Thread {
                val result = try {
                    com.tharunbirla.librecuts.services.SmartExportPlanner.analyzeSmartExport(
                        activity, analysisProject, analysisSource
                    )
                } catch (_: Exception) {
                    null
                }
                activity.runOnUiThread {
                    smartAnalysis = result
                    smartAnalysisDone = true
                    refresh()
                }
            }.start()
        }
'''
s = must_replace(s, old, new, "show() analysis bootstrap")

# ---- 5d. refresh(): push the new fields into the ViewModel ----------------
old = r"""        viewModel.setAdvancedExport(
            VideoEditingViewModel.AdvancedExport(
                videoFormat = effectiveVideoFormat(),
                videoCodec = selCodec,
                preset = selPreset,
                audioCodec = selAudioCodec,
                audioBitrate = selAudioBitrate,
                audioOnlyFormat = effectiveAudioOnlyFormat(),
                customWidth = customW,
                customHeight = customH
            )
        )
"""
new = r"""        viewModel.setAdvancedExport(
            VideoEditingViewModel.AdvancedExport(
                videoFormat = effectiveVideoFormat(),
                videoCodec = selCodec,
                preset = selPreset,
                audioCodec = selAudioCodec,
                audioBitrate = selAudioBitrate,
                audioOnlyFormat = effectiveAudioOnlyFormat(),
                customWidth = customW,
                customHeight = customH,
                keyframeCut = selKeyframeCut,
                exportSeparateFiles = selSeparateFiles,
                movFastStart = selFastStart,
                preserveMetadata = selPreserveMetadata
            )
        )
"""
s = must_replace(s, old, new, "refresh setAdvancedExport")

# ---- 5e. estimateSizeText: smart branch ------------------------------------
old = r"""    /** Size estimate that follows what the REAL command will do (copy vs re-encode). */
    private fun estimateSizeText(cmd: String?): String {
        val durSec = durationMs / 1000.0
        if (durSec <= 0.0) return "..."
"""
new = r"""    /** Size estimate that follows what the REAL command will do (copy vs re-encode). */
    private fun estimateSizeText(cmd: String?): String {
        val durSec = durationMs / 1000.0
        if (durSec <= 0.0) return "..."
        val smart = smartEstimateBytes()
        if (smart != null) return "~" + formatBytes(smart) + " (smart export)"
"""
s = must_replace(s, old, new, "estimateSizeText smart branch")

# ---- 5f. commandPreviewText: smart-first -----------------------------------
old = r"""    /** Real command + a short note when "Same as input" was requested but is impossible. */
    private fun commandPreviewText(cmd: String?): String {
        val base = when {
            cmd == null -> "(preview unavailable)"
            cmd.contains("(CONCAT_LIST:") ->
                cmd.substring(0, cmd.indexOf("(CONCAT_LIST:")).trim() +
                    "  ...(+concat list appended at export time)"
            else -> cmd
        }
        if (cmd == null) return base
        val notes = mutableListOf<String>()
        if (selCodec.isEmpty() && cmd.contains("-c:v") && !cmd.contains("-c:v copy")) {
            notes.add("video edits present -> stream copy not possible, H.264 re-encode used")
        }
        if (selAudioCodec.isEmpty() && cmd.contains("-c:a") && !cmd.contains("-c:a copy")) {
            notes.add("audio processing present -> audio re-encoded as shown")
        }
        return if (notes.isEmpty()) base else base + "\n\n(" + notes.joinToString("; ") + ")"
    }
"""
new = r"""    /** Real command + notes. Shows the SMART plan when it will actually run. */
    private fun commandPreviewText(cmd: String?): String {
        val smart = buildSmartSummary()
        if (smart != null) return smart
        val base = when {
            cmd == null -> "(preview unavailable)"
            cmd.contains("(CONCAT_LIST:") ->
                cmd.substring(0, cmd.indexOf("(CONCAT_LIST:")).trim() +
                    "  ...(+concat list appended at export time)"
            else -> cmd
        }
        if (cmd == null) return base
        val notes = mutableListOf<String>()
        val unavailable = smartUnavailableNote()
        if (unavailable != null) {
            notes.add(unavailable)
        } else {
            if (selCodec.isEmpty() && cmd.contains("-c:v") && !cmd.contains("-c:v copy")) {
                notes.add("video edits present -> stream copy not possible, H.264 re-encode used")
            }
            if (selAudioCodec.isEmpty() && cmd.contains("-c:a") && !cmd.contains("-c:a copy")) {
                notes.add("audio processing present -> audio re-encoded as shown")
            }
        }
        return if (notes.isEmpty()) base else base + "\n\n(" + notes.joinToString("; ") + ")"
    }
"""
s = must_replace(s, old, new, "commandPreviewText")

# ---- 5g. smart preview helpers (before the view-setup section) -------------
old = "    // -------------------------------------------------------------- view setup\n"
new = r'''    // ------------------------------------------------------ smart export preview

    /**
     * Non-null when the smart pipeline cannot run, with a human readable
     * reason (project-level incompatibility or a settings gate).
     */
    private fun smartUnavailableNote(): String? {
        val a = smartAnalysis ?: return if (smartAnalysisDone) "smart export analysis failed" else null
        a.reason?.let { return "smart export unavailable: $it - full re-encode used" }
        val gate = com.tharunbirla.librecuts.services.SmartExportPlanner.settingsBlockSmart(
            a,
            selRes, selFps,
            viewModel.exportAudioOnly.value,
            selCodec, selAudioCodec,
            customW, customH,
            effectiveVideoFormat()
        )
        return gate?.let { "smart export disabled by these settings: $it - full re-encode used" }
    }

    /**
     * Human-readable summary of the smart plan that WILL run at export time:
     * per-segment copy/encode split, cut mode, export mode and the final
     * assembly command. Returns null when the smart path is unavailable, so
     * the legacy command preview stays in charge.
     */
    private fun buildSmartSummary(): String? {
        val a = smartAnalysis ?: return null
        if (a.reason != null) return null
        if (smartUnavailableNote() != null) return null
        if (selSeparateFiles) {
            val copy = a.clips.count { it.fullRange || selKeyframeCut }
            val enc = a.clips.size - copy
            val sb = StringBuilder()
            sb.append("smart export: ").append(a.clips.size).append(" separate output files (")
            sb.append(copy).append(" stream-copied losslessly")
            if (enc > 0) sb.append(", ").append(enc).append(" re-encoded at trim points")
            sb.append(")")
            if (selKeyframeCut) {
                sb.append("\nkeyframe cut ON: trim points snap to keyframes (all copy, +/- one GOP accuracy)")
            } else if (enc > 0) {
                sb.append("\n(transitions and faststart apply to the merged single-file mode only)")
            }
            return sb.toString()
        }
        var copySec = 0.0
        var encSec = 0.0
        for (i in a.clips.indices) {
            val c = a.clips[i]
            val dLeft = if (i > 0) a.transitions[i - 1] ?: 0L else 0L
            val dRight = if (i < a.clips.size - 1) a.transitions[i] ?: 0L else 0L
            val spanMs = (c.trimEndMs - dRight) - (c.trimStartMs + dLeft)
            if (spanMs <= 0L) continue
            val full = c.fullRange && dLeft == 0L && dRight == 0L
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }
        encSec += a.transitions.values.sum() / 1000.0
        val sb = StringBuilder()
        sb.append("ffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
        if (a.hasAudio) sb.append(" -map 0:a:0")
        if (selPreserveMetadata) sb.append(" -map_metadata 1")
        sb.append(" -c copy -bsf:v dump_extra")
        if (selFastStart) sb.append(" -movflags +faststart")
        sb.append(" output.mp4")
        sb.append("\n\n(smart export: ").append(a.clips.size).append(" segments - ")
        sb.append(String.format(Locale.US, "%.1fs", copySec)).append(" stream-copied losslessly")
        if (encSec > 0.01) {
            sb.append(", ").append(String.format(Locale.US, "%.1fs", encSec)).append(" re-encoded")
        }
        if (selKeyframeCut) sb.append("; keyframe cut ON (trims snap to keyframes, +/- one GOP accuracy)")
        sb.append("; final assembly is a lossless concat)")
        return sb.toString()
    }

    /** Size estimate that follows the smart plan (copied vs re-encoded parts). */
    private fun smartEstimateBytes(): Double? {
        val a = smartAnalysis ?: return null
        if (a.reason != null) return null
        if (smartUnavailableNote() != null) return null
        var copySec = 0.0
        var encSec = 0.0
        val srcKbpsTotal = if (srcKbps > 0) srcKbps else 8000
        for (i in a.clips.indices) {
            val c = a.clips[i]
            val dLeft = if (!selSeparateFiles && i > 0) a.transitions[i - 1] ?: 0L else 0L
            val dRight = if (!selSeparateFiles && i < a.clips.size - 1) a.transitions[i] ?: 0L else 0L
            val spanMs = (c.trimEndMs - dRight) - (c.trimStartMs + dLeft)
            if (spanMs <= 0L) continue
            val full = c.fullRange && dLeft == 0L && dRight == 0L
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }
        if (!selSeparateFiles) encSec += a.transitions.values.sum() / 1000.0
        val aKbps = when {
            selAudioCodec == "pcm_s16le" -> 1411
            selAudioCodec == "flac" -> 900
            else -> selAudioBitrate.dropLast(1).toIntOrNull() ?: 128
        }
        return (copySec * srcKbpsTotal + encSec * (effectiveVideoKbps() + aKbps)) * 1000.0 / 8.0
    }

    // -------------------------------------------------------------- view setup
'''
s = must_replace(s, old, new, "smart preview helpers insertion")

# ---- 5h. bindViews(): four new chip rows -----------------------------------
old = r"""        // ---- Preset ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgPreset), mapOf(
            R.id.chipPresetUltrafast to "ultrafast", R.id.chipPresetSuperfast to "superfast",
            R.id.chipPresetVeryfast to "veryfast", R.id.chipPresetFaster to "faster",
            R.id.chipPresetFast to "fast", R.id.chipPresetMedium to "medium",
            R.id.chipPresetSlow to "slow", R.id.chipPresetSlower to "slower",
            R.id.chipPresetVeryslow to "veryslow"),
            selPreset, true
        ) { picked -> selPreset = picked ?: "medium" }
"""
new = r"""        // ---- Preset ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgPreset), mapOf(
            R.id.chipPresetUltrafast to "ultrafast", R.id.chipPresetSuperfast to "superfast",
            R.id.chipPresetVeryfast to "veryfast", R.id.chipPresetFaster to "faster",
            R.id.chipPresetFast to "fast", R.id.chipPresetMedium to "medium",
            R.id.chipPresetSlow to "slow", R.id.chipPresetSlower to "slower",
            R.id.chipPresetVeryslow to "veryslow"),
            selPreset, true
        ) { picked -> selPreset = picked ?: "medium" }

        // ---- Cut mode (phase 10): accurate trim vs keyframe snap ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgCutMode), mapOf(
            R.id.chipCutNormal to false, R.id.chipCutKeyframe to true),
            selKeyframeCut, true
        ) { picked -> selKeyframeCut = picked ?: false }

        // ---- Export mode (phase 10): merged single file vs one file per clip ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgExportMode), mapOf(
            R.id.chipModeMerged to false, R.id.chipModeSeparate to true),
            selSeparateFiles, true
        ) { picked -> selSeparateFiles = picked ?: false }

        // ---- MP4 faststart (phase 10): moov atom at the front ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgFastStart), mapOf(
            R.id.chipFsOn to true, R.id.chipFsOff to false),
            selFastStart, true
        ) { picked -> selFastStart = picked ?: true }

        // ---- Source metadata (phase 10): keep or strip ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgMetadata), mapOf(
            R.id.chipMetaKeep to true, R.id.chipMetaStrip to false),
            selPreserveMetadata, true
        ) { picked -> selPreserveMetadata = picked ?: true }
"""
s = must_replace(s, old, new, "bindViews new chip rows")

wr(D, s)
print("[phase10] step5: ExportSettingsDialog patched (smart preview, cut/export/metadata/faststart rows)")
ESDPY
fi

echo "[phase10] step5 done"

###############################################################################
# Step 6 -- dialog_export_settings.xml (four new chip rows)
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step6: [skip] dialog XML already patched"
else
python3 <<'XMLPY'
import sys

def die(m):
    print("[phase10][ERROR] " + m)
    sys.exit(1)

X = "app/src/main/res/layout/dialog_export_settings.xml"
with open(X, "r", encoding="utf-8") as f:
    s = f.read()

old = """        <!-- ======================= FFmpeg command preview ======================= -->
"""
new = r'''        <!-- ======================= Cut Mode (phase 10) ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Cut Mode"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgCutMode"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipCutNormal" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Normal (accurate)" android:checked="true" />
                <com.google.android.material.chip.Chip android:id="@+id/chipCutKeyframe" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Keyframe (fast, lossless)" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Export Mode (phase 10) ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Export Mode"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgExportMode"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipModeMerged" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Single file (merged)" android:checked="true" />
                <com.google.android.material.chip.Chip android:id="@+id/chipModeSeparate" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Separate files (one per clip)" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= MP4 Faststart (phase 10) ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="MP4 Faststart (instant playback)"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgFastStart"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipFsOn" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="On" android:checked="true" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFsOff" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Off" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Source Metadata (phase 10) ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Source Metadata"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgMetadata"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipMetaKeep" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Keep" android:checked="true" />
                <com.google.android.material.chip.Chip android:id="@+id/chipMetaStrip" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Strip" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= FFmpeg command preview ======================= -->
'''

if s.count(old) != 1:
    die("XML anchor (FFmpeg command preview comment) not found or not unique")
s = s.replace(old, new, 1)

with open(X, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase10] step6: dialog XML patched (cut mode / export mode / faststart / metadata rows)")
XMLPY
fi

echo "[phase10] step6 done"

###############################################################################
# Step 7 -- verification gate (inventory, balance, XML, leftovers, survival,
#           scope, .github policy, ASCII) -- exits 1 BEFORE anything commits
###############################################################################
log "step7: running verification gate"

python3 <<'GATEPY'
import re
import subprocess
import sys
import xml.dom.minidom as minidom

def die(m):
    print("[phase10][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def head(p):
    r = subprocess.run(["git", "show", "HEAD:" + p], capture_output=True, text=True)
    if r.returncode != 0:
        die("git show failed for " + p)
    return r.stdout

VM = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
ESD = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
EXPS = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
XML = "app/src/main/res/layout/dialog_export_settings.xml"
FILES = [VM, VEA, ESD, EXPS, PLANNER, XML]

vm, vea, esd, exps, planner = rd(VM), rd(VEA), rd(ESD), rd(EXPS), rd(PLANNER)

# ---- 7a. new-symbol inventory ---------------------------------------------
inv = [
    (PLANNER, planner, "fun analyzeSmartExport("),
    (PLANNER, planner, "fun settingsBlockSmart("),
    (PLANNER, planner, "private fun analyzeInternal("),
    (PLANNER, planner, "data class SmartClipInfo("),
    (PLANNER, planner, "data class SmartAnalysis("),
    (PLANNER, planner, "keyframeCut: Boolean = false,"),
    (PLANNER, planner, "keyframeCut: Boolean,"),
    (PLANNER, planner, "exportSeparateFiles: Boolean,"),
    (PLANNER, planner, "val merged = !exportSeparateFiles"),
    (PLANNER, planner, "} else if (keyframeCut) {"),
    (PLANNER, planner, "-avoid_negative_ts make_zero"),
    (PLANNER, planner, "val trans = if (merged) clampedTransitions[i] else null"),
    (PLANNER, planner, 'planObj.put("separate", exportSeparateFiles)'),
    (PLANNER, planner, 'planObj.put("outputs", JSONArray(outputs))'),
    (EXPS, exps, "data class SmartExportOutcome("),
    (EXPS, exps, "private data class ParsedPlan("),
    (EXPS, exps, "private fun parseSmartPlan("),
    (EXPS, exps, "private suspend fun runSmartExport(planPath: String): SmartExportOutcome"),
    (EXPS, exps, "files saved to gallery"),
    (VM, vm, "val keyframeCut: Boolean = false,"),
    (VM, vm, "val exportSeparateFiles: Boolean = false,"),
    (VM, vm, "val movFastStart: Boolean = true,"),
    (VM, vm, "val preserveMetadata: Boolean = true"),
    (VM, vm, "private fun appendOutputContainerArgs(cmd: StringBuilder)"),
    (VM, vm, '-movflags +faststart'),
    (VM, vm, "-map_metadata 0"),
    (VM, vm, "-map_metadata -1"),
    (VEA, vea, "keyframeCut = viewModel.advancedExport.value.keyframeCut,"),
    (VEA, vea, "exportSeparateFiles = viewModel.advancedExport.value.exportSeparateFiles,"),
    (VEA, vea, "movFastStart = viewModel.advancedExport.value.movFastStart,"),
    (VEA, vea, "preserveMetadata = viewModel.advancedExport.value.preserveMetadata"),
    (VEA, vea, "Separate-files export needs smart-compatible edits"),
    (ESD, esd, "fun smartUnavailableNote(): String?"),
    (ESD, esd, "fun buildSmartSummary(): String?"),
    (ESD, esd, "fun smartEstimateBytes(): Double?"),
    (ESD, esd, "R.id.cgCutMode"),
    (ESD, esd, "R.id.chipCutKeyframe"),
    (ESD, esd, "R.id.cgExportMode"),
    (ESD, esd, "R.id.chipModeSeparate"),
    (ESD, esd, "R.id.cgFastStart"),
    (ESD, esd, "R.id.chipFsOn"),
    (ESD, esd, "R.id.cgMetadata"),
    (ESD, esd, "R.id.chipMetaKeep"),
    (ESD, esd, "keyframeCut = selKeyframeCut,"),
    (ESD, esd, "exportSeparateFiles = selSeparateFiles,"),
    (ESD, esd, "movFastStart = selFastStart,"),
    (ESD, esd, "preserveMetadata = selPreserveMetadata"),
    (ESD, esd, "analyzeSmartExport("),
    (ESD, esd, "settingsBlockSmart("),
    (ESD, esd, "smartEstimateBytes()"),
]
for path, body, tok in inv:
    if tok not in body:
        die("inventory: expected token missing in %s: %r" % (path, tok))
print("[ok] inventory: %d new-symbol tokens present" % len(inv))

# ---- 7b. exact wiring counts ----------------------------------------------
checks = [
    (vm, vm.count("appendOutputContainerArgs("), 4, "VM appendOutputContainerArgs decl+calls"),
    (esd, esd.count("wireChipRow("), 13, "ESD wireChipRow decl+calls (1+12)"),
    (planner, planner.count("keyframeCut"), 4, "planner keyframeCut mentions"),
    (planner, planner.count("-map_metadata 1"), 3, "planner -map_metadata 1 (doc+comment+code)"),
    (planner, planner.count("-movflags +faststart"), 2, "planner faststart (doc+code)"),
    (exps, exps.count("saveVideoToGallery("), 3, "ES saveVideoToGallery decl+calls"),
]
for body, got, want, what in checks:
    if got != want:
        die("count gate: %s = %d, expected %d" % (what, got, want))
print("[ok] wiring counts: 6/6")

# ---- 7c. brace/paren balance vs HEAD --------------------------------------
for f in [VM, VEA, ESD, EXPS, PLANNER]:
    new, old = rd(f), head(f)
    db = new.count("{") - old.count("{") - (new.count("}") - old.count("}"))
    dp = new.count("(") - old.count("(") - (new.count(")") - old.count(")"))
    if db != 0:
        die("brace delta mismatch in %s (open-close diff %+d)" % (f, db))
    if dp != 0:
        die("paren delta mismatch in %s (open-close diff %+d)" % (f, dp))
    nb = new.count("{") - new.count("}")
    if abs(nb) > 0 and f != VEA:
        die("absolute brace imbalance in %s (%+d)" % (f, nb))
print("[ok] brace/paren balance vs HEAD for 5 Kotlin files")

# ---- 7d. XML parse + ids --------------------------------------------------
try:
    dom = minidom.parse(XML)
except Exception as e:
    die("XML parse failed: " + str(e))
ids = [e.getAttribute("android:id") for e in dom.getElementsByTagName("*") if e.hasAttribute("android:id")]
dup = [i for i in set(ids) if ids.count(i) > 1]
if dup:
    die("duplicate android:id in XML: " + ", ".join(dup))
for want in ["@+id/cgCutMode", "@+id/chipCutNormal", "@+id/chipCutKeyframe",
             "@+id/cgExportMode", "@+id/chipModeMerged", "@+id/chipModeSeparate",
             "@+id/cgFastStart", "@+id/chipFsOn", "@+id/chipFsOff",
             "@+id/cgMetadata", "@+id/chipMetaKeep", "@+id/chipMetaStrip"]:
    if want not in ids:
        die("XML missing new id: " + want)
print("[ok] XML parses, %d ids, no duplicates, 12 new ids present" % len(ids))

# ---- 7e. survival asserts (kept features) ----------------------------------
surv = [
    (VEA, vea, "fun freezeFrameAtCurrentPosition()"),
    (VEA, vea, "buildConsolidatedFFmpegCommand("),
    (VEA, vea, "ExportService.EXTRA_SMART_PLAN_PATH"),
    (VEA, vea, "SmartExportPlanner.planSmartExport("),
    (PLANNER, planner, "fun buildFreezeFrameCommands("),
    (PLANNER, planner, "fun sanitizeTransitionType("),
    (PLANNER, planner, "xfade=transition="),
    (PLANNER, planner, "-bsf:v dump_extra"),
    (PLANNER, planner, "fun probeMedia("),
    (VM, vm, "buildVideoCodecArgs("),
    (VM, vm, "Built merge command"),
    (VM, vm, "Built preview command"),
    (VM, vm, "fun getOutputExtension("),
    (EXPS, exps, "EXTRA_SMART_PLAN_PATH"),
    (EXPS, exps, "private fun saveVideoToGallery("),
    (EXPS, exps, "ACTION_EXPORT_SUCCESS"),
    (ESD, esd, "fun show()"),
    (ESD, esd, "private fun restoreSnapshot()"),
    (ESD, esd, "private fun commandPreviewText("),
    (ESD, esd, "private fun estimateSizeText("),
    (ESD, esd, "chipBitrateSame"),
]
for path, body, tok in surv:
    if tok not in body:
        die("survival: token missing in %s: %r" % (path, tok))
print("[ok] survival: %d kept-feature tokens present" % len(surv))

# ---- 7f. ASCII purity (no NEW non-ASCII bytes; the tree already uses -----
# box-drawing divider characters, so compare counts against HEAD)
for f in FILES:
    b = open(f, "rb").read()
    h = head(f).encode("utf-8", "surrogateescape")
    n_new = sum(1 for c in b if c > 127)
    n_old = sum(1 for c in h if c > 127)
    if n_new != n_old:
        die("non-ASCII byte count changed in %s (%d -> %d)" % (f, n_old, n_new))
print("[ok] ASCII purity: no new non-ASCII bytes in 6 modified files")

print("[phase10] step7: ALL GATES GREEN")
GATEPY

###############################################################################
# Step 8 -- scope + .github policy (final pre-commit safety net)
###############################################################################
log "step8: scope gate"

SCOPE_OK=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  path="$(echo "$line" | awk '{print $NF}')"
  case "$path" in
    "$VM"|"$VEA"|"$ESD"|"$EXPS"|"$PLANNER"|"$XML"|scripts/apply-changes.sh) ;;
    *) echo "[phase10][ERROR] out-of-scope change: $path" >&2; SCOPE_OK=1 ;;
  esac
done < <(git status --porcelain)

[ "$SCOPE_OK" = "0" ] || fail "scope gate failed (unexpected files modified)"

if git status --porcelain | grep -q "\.github/"; then
  fail "POLICY: workflow files must never be modified by this script"
fi

log "ALL DONE -- phase 10 applied cleanly (parts 1-4)"
log "summary: smart preview in export dialog, keyframe cut mode, separate-files export, metadata + faststart"
