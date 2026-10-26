#!/usr/bin/env bash
###############################################################################
# CutLoss phase 12 -- "no filter_complex, ever"
#
# User directive (exact words): "why are you even using filter_complex?
# Don't use it. Delete it." The screenshot that triggered it: a trim-only,
# all-same-as-input project whose export still fell back to the legacy
# consolidated re-encode with the note "source pixel format is not yuv420p".
#
# What changes (5 files):
#   SmartExportPlanner.kt:
#     - The pixFmt == "yuv420p" gates are GONE. Stream copy does not care
#       about the pixel format: keyframe cuts copy ANY format byte-exactly
#       (-ss before -i + -c copy), and trimmed-span re-encodes match the
#       source format via the new encodablePixFmt() helper (yuvj420p keeps
#       its full-range flag; nv12/nv21 are the same 4:2:0 bitstream).
#       Multi-clip plans only require that all clips SHARE one format.
#     - Only genuinely non-encodable formats (10-bit etc.) force the uniform
#       reencodeAll plan when a trim needs encoding and keyframe cut is off.
#     - SmartAnalysis gains pixFmt so the dialog mirrors the rule exactly.
#     - Transitions export as STRAIGHT CUTS: the xfade/acrossfade
#       filter_complex segment builder is deleted, spans are no longer
#       shortened, sanitizeTransitionType + validXfadeTransitions removed.
#     - Freeze clips encode with the source pixel format (format=yuvj420p +
#       -pix_fmt yuvj420p) so they concat-copy next to non-yuv420p sources.
#   VideoEditingViewModel.kt:
#     - buildConsolidatedFFmpegCommand (the filter_complex monster) and its
#       helper stack are DELETED (~900 lines): buildVideoFilterStages,
#       prepareTextPngInputs, textPngRenderer, overlayPosExpr,
#       appendOutputContainerArgs, buildOutputScaleFilter, buildOutputVfArgs,
#       buildVideoCodecArgs, buildAudioCodecArgs, copyContentUriToTempFile,
#       buildMergeCommand (dead since phase 9).
#     - buildPreviewCommand rewritten: text preview is now ONE simple -vf
#       holding the drawtext filters chained by commas - no labels, no
#       PNG inputs, no filter_complex (lab-validated).
#   VideoEditingActivity.kt:
#     - saveAction no longer falls back to the consolidated render: when the
#       planner refuses, the REAL reason is surfaced (analyzeSmartExport +
#       settingsBlockSmart) as an export error + toast. Export refuses to
#       start instead of silently re-encoding everything.
#     - Smart freeze gate accepts yuvj420p/nv12/nv21 sources.
#     - textPngRenderer wiring + processConcatList (legacy-only) removed.
#   ExportSettingsDialog.kt:
#     - The command preview NEVER shows a legacy command anymore: it shows
#       the smart plan, or the honest "(export blocked - <reason>)" box.
#       Size estimate likewise shows "(export blocked)" instead of guessing
#       for a render that will never run.
#     - Transition note: "N transition(s) exported as straight cuts".
#   FFmpegRenderEngine.kt:
#     - addBackgroundAudio (the amix filter_complex, zero callers) deleted.
#
# Result: grep -r "filter_complex" app/src/main/java -> EMPTY.
#
# Precondition: phase 11 must be in the tree (aa1a39d or later).
# Invariants: pure ASCII, idempotent (2nd run = [skip], zero diff),
# touches exactly five source files, hard verification gate exits 1
# BEFORE anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase12] $*"; }
fail() { echo "[phase12][ERROR] $*" >&2; exit 1; }

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
ENGINE="app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"

###############################################################################
# Step 0 -- preconditions (phase 11 base must already be in the tree)
###############################################################################
log "step0: checking preconditions"
[ -f "$PLANNER" ] || fail "SmartExportPlanner.kt not found"
[ -f "$ESD" ] || fail "ExportSettingsDialog.kt not found"
[ -f "$VM" ] || fail "VideoEditingViewModel.kt not found"
[ -f "$VEA" ] || fail "VideoEditingActivity.kt not found"
[ -f "$ENGINE" ] || fail "FFmpegRenderEngine.kt not found"
grep -q "reencodeAll" "$PLANNER" || fail "phase-11 planner base not found (reencodeAll missing)"
grep -q "buildSmartReencodeSummary" "$ESD" || fail "phase-11 dialog base not found (buildSmartReencodeSummary missing)"
log "step0: preconditions ok"

###############################################################################
# Step 1 -- VideoEditingViewModel.kt: delete the legacy filter-graph builders
###############################################################################
step1() {
  if grep -q "fun buildConsolidatedFFmpegCommand(" "$VM"; then
    python3 - <<'PYEOF'
import sys

VM = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(path, old, new, label):
    c = rd(path)
    if new in c and old not in c:
        print("[skip] " + label)
        return
    n = c.count(old)
    if n != 1:
        print("[ERROR] %s: expected 1 occurrence, found %d" % (label, n))
        sys.exit(1)
    wr(path, c.replace(old, new))
    print("[ok] " + label)

def find_line(lines, substr, label):
    i = next((k for k, l in enumerate(lines) if substr in l), None)
    if i is None:
        print("[ERROR] %s: marker not found: %r" % (label, substr))
        sys.exit(1)
    return i

def docblock_open(lines, content_idx, label):
    i = content_idx
    steps = 0
    while i > 0 and steps < 15:
        if lines[i].strip() == "/**":
            return i
        i -= 1
        steps += 1
    print("[ERROR] %s: no docblock opener above line %d" % (label, content_idx + 1))
    sys.exit(1)

def delete_range(path, s, e, label):
    c = rd(path)
    lines = c.split("\n")
    del lines[s:e]
    wr(path, "\n".join(lines))
    print("[ok] %s (deleted %d lines)" % (label, e - s))

lines = rd(VM).split("\n")

# 1a. textPngRenderer + textPngInputs + prepareTextPngInputs + overlayPosExpr
s = find_line(lines, "/** Renders AddText ops to transparent PNGs (WYSIWYG canvas rendering).", "vm-1a")
e = find_line(lines, "/** Build a drawtext filter expression for a text operation. */", "vm-1a")
delete_range(VM, s, e, "vm: delete text-PNG overlay helpers + overlayPosExpr")

# 1b. the five legacy render arg helpers (only callers were consolidated)
lines = rd(VM).split("\n")
ci = find_line(lines, "Output container flags shared by the legacy render paths", "vm-1b")
s = docblock_open(lines, ci, "vm-1b")
e = find_line(lines, "    val operations: StateFlow<List<EditOperation>>", "vm-1b")
delete_range(VM, s, e, "vm: delete legacy arg helpers (appendOutputContainerArgs..buildAudioCodecArgs)")

# 1c. buildVideoFilterStages + buildConsolidatedFFmpegCommand (the monster)
lines = rd(VM).split("\n")
ci = find_line(lines, "Build the video portion of a filter_complex graph from non-merge, non-audio operations.", "vm-1c")
s = docblock_open(lines, ci, "vm-1c")
ci2 = find_line(lines, "Build an FFmpeg command for a fast 3-second preview around the playhead.", "vm-1c")
e = docblock_open(lines, ci2, "vm-1c")
delete_range(VM, s, e, "vm: delete buildVideoFilterStages + buildConsolidatedFFmpegCommand")

# 1d. buildPreviewCommand: simple -vf drawtext chain instead of filter_complex
must_replace(
    VM,
    '''        // Build filter_complex for video operations
        val (videoStages, finalLabel) = buildVideoFilterStages(
            operations = videoOps,
            fontFilePath = fontFilePath,
            density = density,
            sourceVideoHeight = 1080
        )
        if (videoStages.isNotEmpty()) {
            cmd.append(" -filter_complex \\"${videoStages.joinToString(";")}\\"")
            cmd.append(" -map \\"$finalLabel\\" -map 0:a?")
        }
''',
    '''        // Phase 12: preview is a SIMPLE filter chain - one -vf holding
        // the drawtext filters joined by commas. No filter graph, no
        // labeled streams, no PNG inputs: each AddText op becomes one
        // drawtext stage applied to the single input stream (validated in
        // the ffmpeg lab: chained drawtext with escaped enable windows
        // runs fine as a plain -vf).
        val drawtextChain = videoOps.filterIsInstance<EditOperation.AddText>()
            .joinToString(",") { buildDrawtextExpr(it, fontFilePath) }
        if (drawtextChain.isNotEmpty()) {
            cmd.append(" -vf \\"").append(drawtextChain).append("\\"")
            cmd.append(" -map 0:v:0 -map 0:a?")
        }
''',
    "vm: buildPreviewCommand -> simple -vf drawtext chain",
)

# 1e. copyContentUriToTempFile + buildMergeCommand (dead since phase 9)
lines = rd(VM).split("\n")
s = find_line(lines, "    private fun copyContentUriToTempFile(context: Context, uri: Uri): String? {", "vm-1e")
e = find_line(lines, "    fun startExport() {", "vm-1e")
delete_range(VM, s, e, "vm: delete copyContentUriToTempFile + buildMergeCommand")

print("step1 vm migration complete")
PYEOF
  else
    log "step1: [skip] VM already migrated (no buildConsolidatedFFmpegCommand)"
  fi
}

###############################################################################
# Step 2 -- SmartExportPlanner.kt: pix_fmt gates out, hard-cut transitions,
#           encodablePixFmt(), freeze format matching
###############################################################################
step2() {
  if grep -q 'fail("source pixel format is not yuv420p")' "$PLANNER"; then
    python3 - <<'PYEOF'
import sys

PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(path, old, new, label):
    c = rd(path)
    if new in c and old not in c:
        print("[skip] " + label)
        return
    n = c.count(old)
    if n != 1:
        print("[ERROR] %s: expected 1 occurrence, found %d" % (label, n))
        sys.exit(1)
    wr(path, c.replace(old, new))
    print("[ok] " + label)

def find_line(lines, substr, label):
    i = next((k for k, l in enumerate(lines) if substr in l), None)
    if i is None:
        print("[ERROR] %s: marker not found: %r" % (label, substr))
        sys.exit(1)
    return i

def delete_range(path, s, e, label):
    c = rd(path)
    lines = c.split("\n")
    del lines[s:e]
    wr(path, "\n".join(lines))
    print("[ok] %s (deleted %d lines)" % (label, e - s))

# 2a. analyzer: the main-source pix_fmt gate is gone (copy does not care)
must_replace(
    PLANNER,
    '''        if (refParams.vCodec != "h264" && refParams.vCodec != "hevc") return fail("source codec is not H.264/HEVC")
        if (refParams.pixFmt != "yuv420p") return fail("source pixel format is not yuv420p")
''',
    '''        if (refParams.vCodec != "h264" && refParams.vCodec != "hevc") return fail("source codec is not H.264/HEVC")
        // Phase 12: stream copy does not care about the pixel format, so a
        // non-yuv420p source no longer blocks the smart path. Keyframe cuts
        // copy ANY format byte-exactly; trimmed-span re-encodes match the
        // source format (encodablePixFmt); only truly exotic formats (10-bit
        // and friends) switch the whole plan to the uniform re-encode.
''',
    "planner: drop analyzer pix_fmt gate",
)

# 2b. analyzer: per-clip check becomes a uniformity check (concat safety)
must_replace(
    PLANNER,
    '''                if (p.pixFmt != "yuv420p") return fail("a clip is not yuv420p")''',
    '''                if (p.pixFmt != refParams.pixFmt) return fail("clips use different pixel formats")''',
    "planner: per-clip pix_fmt uniformity",
)

# 2c. SmartAnalysis gains pixFmt (dialog mirrors the planner rule)
must_replace(
    PLANNER,
    '''        val fpsRounded: Int,
        val vCodec: String,
        val reason: String?
    )''',
    '''        val fpsRounded: Int,
        val vCodec: String,
        val pixFmt: String,
        val reason: String?
    )''',
    "planner: SmartAnalysis +pixFmt",
)

# 2d. fail() constructs SmartAnalysis positionally -> add the new slot
must_replace(
    PLANNER,
    '''            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", reason)''',
    '''            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", "", reason)''',
    "planner: fail() positional args +pixFmt",
)

# 2e. analyzeInternal success return gains pixFmt
must_replace(
    PLANNER,
    '''            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            vCodec = refParams.vCodec,
            reason = null
        )''',
    '''            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            vCodec = refParams.vCodec,
            pixFmt = refParams.pixFmt,
            reason = null
        )''',
    "planner: analyzeInternal returns pixFmt",
)

# 2f. planInternal: drop the main-source pix_fmt gate
must_replace(
    PLANNER,
    '''        val refParams = probeMedia(context, Uri.fromFile(File(sourceFilePath)), sourceFilePath) ?: return null
        if (refParams.vCodec != "h264" && refParams.vCodec != "hevc") return null
        if (refParams.pixFmt != "yuv420p") return null
''',
    '''        val refParams = probeMedia(context, Uri.fromFile(File(sourceFilePath)), sourceFilePath) ?: return null
        if (refParams.vCodec != "h264" && refParams.vCodec != "hevc") return null
''',
    "planner: drop planInternal pix_fmt gate",
)

# 2g. planInternal: per-clip check becomes uniformity
must_replace(
    PLANNER,
    '''                if (p.pixFmt != "yuv420p") return null''',
    '''                if (p.pixFmt != refParams.pixFmt) return null''',
    "planner: planInternal per-clip pix_fmt uniformity",
)

# 2h. move reencodeAll below the clips loop + pixel-format rule
must_replace(
    PLANNER,
    '''        val fpsChange = exportFps != 0 && exportFps != Math.round(refParams.fpsValue).toInt()
        val reencodeAll = customScale || resChange || fpsChange
''',
    '''        val fpsChange = exportFps != 0 && exportFps != Math.round(refParams.fpsValue).toInt()
''',
    "planner: reencodeAll moves below the clips loop",
)

must_replace(
    PLANNER,
    '''        }

        // ---- audio reference ----''',
    '''        }

        // ---- phase 12: pixel-format uniformity ----
        // Keyframe cuts copy ANY pixel format untouched (pure -c copy).
        // Encodable 8-bit 4:2:0 formats (yuv420p/yuvj420p/nv12/nv21) also
        // keep the hybrid plan: trimmed spans re-encode with the source
        // format, so the concat never mixes formats. Only a genuinely
        // non-encodable source (10-bit etc.) with a non-keyframe trim
        // forces the uniform re-encode of every segment.
        val anyTrimmedSpan = clips.any {
            !(it.trimStartMs <= 60L && it.trimEndMs >= it.durationMs - 60L)
        }
        val encodableSource = refParams.pixFmt == "yuv420p" || refParams.pixFmt == "yuvj420p" ||
            refParams.pixFmt == "nv12" || refParams.pixFmt == "nv21"
        val reencodeAll = customScale || resChange || fpsChange ||
            (!encodableSource && !keyframeCut && anyTrimmedSpan)

        // ---- audio reference ----''',
    "planner: reencodeAll + pixel-format uniformity rule",
)

# 2i. transitions with clamped durations + span shrinking -> straight cuts
must_replace(
    PLANNER,
    '''        // ---- transitions with clamped durations ----
        val transitions = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            transitions[t.index] = Pair(t.type, t.durationMs)
        }
        val clampedTransitions = mutableMapOf<Int, Pair<String, Long>>()
        for ((gap, td) in transitions) {
            val leftDur = clips[gap].trimEndMs - clips[gap].trimStartMs
            val rightDur = clips[gap + 1].trimEndMs - clips[gap + 1].trimStartMs
            val d = td.second.coerceAtMost(leftDur).coerceAtMost(rightDur)
            if (d >= 50L) {
                clampedTransitions[gap] = Pair(td.first, d)
            }
        }

        // ---- effective spans + degenerate check ----
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
''',
    '''        // ---- phase 12: transitions export as straight cuts ----
        // The lossless pipeline never blends frames, so no transition
        // segments are rendered and no span is shortened: every clip is
        // simply its trim, and clips join end to start in the concat.
        val merged = !exportSeparateFiles
        for (i in clips.indices) {
            if (clips[i].trimEndMs <= clips[i].trimStartMs) return null
        }
''',
    "planner: transitions -> straight cuts, spans unshrunk",
)

# 2j. segment loop head: spans are plain trims now
must_replace(
    PLANNER,
    '''        for (i in clips.indices) {
            val clip = clips[i]
            val dLeft = if (merged && i > 0) clampedTransitions[i - 1]?.second ?: 0L else 0L
            val dRight = if (merged && i < clips.size - 1) clampedTransitions[i]?.second ?: 0L else 0L
            val spanStart = clip.trimStartMs + dLeft
            val spanEnd = clip.trimEndMs - dRight
''',
    '''        for (i in clips.indices) {
            val clip = clips[i]
            val spanStart = clip.trimStartMs
            val spanEnd = clip.trimEndMs
''',
    "planner: segment loop spans = plain trims",
)

# 2k. encSimple: keep the source pixel format when encodable
must_replace(
    PLANNER,
    '''        val encSimple: String = if (refParams.vCodec == "hevc") {
            val sb = StringBuilder("-c:v libx265 -tag:v hvc1 -pix_fmt yuv420p")''',
    '''        val encPixFmt = encodablePixFmt(refParams)
        val encSimple: String = if (refParams.vCodec == "hevc") {
            val sb = StringBuilder("-c:v libx265 -tag:v hvc1 -pix_fmt ").append(encPixFmt)''',
    "planner: encSimple hevc branch uses encodablePixFmt",
)

must_replace(
    PLANNER,
    '''            val sb = StringBuilder("-c:v libx264 -pix_fmt yuv420p")''',
    '''            val sb = StringBuilder("-c:v libx264 -pix_fmt ").append(encPixFmt)''',
    "planner: encSimple h264 branch uses encodablePixFmt",
)

# 2l. delete the transition-chain args (dead with hard-cut transitions)
must_replace(
    PLANNER,
    '''        // Transition chains follow the plan mode: the same scale filter and
        // the target frame rate when the whole plan is re-encoded.
        val transScalePrefix = if (reencodeAll && scaleFilter != null) scaleFilter + "," else ""
        val transFpsFilter = if (reencodeAll && fpsChange) "fps=" + exportFps else fpsFilter
        val transEnc = if (reencodeAll) encSimple else enc

        var segCounter = 0''',
    '''        var segCounter = 0''',
    "planner: delete transition chain args",
)

# 2m. delete the xfade/acrossfade transition segment builder entirely.
# The block lives INSIDE the per-clip for loop, so the loop's closing brace
# (the "}" right before the blank line above the final-assembly comment)
# must survive: delete [block start, loop close).
lines = rd(PLANNER).split("\n")
s = find_line(lines, "// Transition segment that starts right after this clip (merged only)", "planner-2m")
c_idx = find_line(lines, "// ---- final assembly: concat with stream copy (merged mode only) ----", "planner-2m")
if lines[c_idx - 1].strip() != "":
    print("[ERROR] planner-2m: expected a blank line above the final-assembly comment")
    sys.exit(1)
if lines[c_idx - 2].strip() != "}":
    print("[ERROR] planner-2m: expected the for-loop closing brace above the blank")
    sys.exit(1)
e = c_idx - 2
delete_range(PLANNER, s, e, "planner: delete xfade transition segment builder")

# 2n. freeze: encode with the source pixel format
must_replace(
    PLANNER,
    '''        sb.append(",format=yuv420p\\"")''',
    '''        sb.append(",format=").append(encodablePixFmt(params)).append("\\"")''',
    "planner: freeze format= matches source pix_fmt",
)

# 2o. videoEncoderArgs: pix_fmt follows the source when encodable
must_replace(
    PLANNER,
    '''            sb.append(" -pix_fmt yuv420p")''',
    '''            sb.append(" -pix_fmt ").append(encodablePixFmt(p))''',
    "planner: videoEncoderArgs h264 pix_fmt",
)

must_replace(
    PLANNER,
    '''            sb.append(" -tag:v hvc1 -pix_fmt yuv420p")''',
    '''            sb.append(" -tag:v hvc1 -pix_fmt ").append(encodablePixFmt(p))''',
    "planner: videoEncoderArgs hevc pix_fmt",
)

# 2p. add encodablePixFmt + drop validXfadeTransitions/sanitizeTransitionType
must_replace(
    PLANNER,
    '''        return sb.toString()
    }

    private val validXfadeTransitions = setOf(''',
    '''        return sb.toString()
    }

    /**
     * Pixel format for re-encode templates (phase 12): keep the common
     * 8-bit 4:2:0 formats as-is so re-encoded segments stay concat-uniform
     * with stream-copied ones (yuvj420p keeps its full-range flag; nv12 and
     * nv21 are the same 4:2:0 bitstream once encoded). Anything more exotic
     * falls back to plain yuv420p and the encoder converts. Validated in the
     * ffmpeg lab: libx264/libx265 accept all four formats, and re-encoded
     * yuvj420p output keeps its pc range flag.
     */
    private fun encodablePixFmt(p: MediaParams): String =
        if (p.pixFmt == "yuvj420p" || p.pixFmt == "nv12" || p.pixFmt == "nv21") p.pixFmt else "yuv420p"

    private val validXfadeTransitions = setOf(''',
    "planner: add encodablePixFmt helper",
)

lines = rd(PLANNER).split("\n")
s = find_line(lines, "    private val validXfadeTransitions = setOf(", "planner-2q")
# delete through the end of the file except the final closing brace
last = len(lines) - 1
while last > 0 and lines[last].strip() == "":
    last -= 1
delete_range(PLANNER, s, last, "planner: delete validXfadeTransitions + sanitizeTransitionType")

# 2r. header docblock: no more legacy fallback / xfade template
must_replace(
    PLANNER,
    ''' * Goal: when the timeline only contains operations that do not change the
 * stream parameters (trim, merge, freeze, transitions, mute), the unchanged
 * parts of the source clips are STREAM-COPIED (-c copy) into the output and
 * only the changed parts (freeze segments, transition overlaps, trim cuts)
 * are re-encoded with parameters that match the source clips. The final
 * assembly uses the concat demuxer with -c copy, so most of the output is
 * bit-exact with the original footage.
 *
 * If anything is not copy-compatible (mixed codecs, image clips, text or
 * image overlays, speed changes, background audio, ...) the planner
 * returns null and the caller falls back to the legacy consolidated
 * filter-graph render. Resolution / fps / custom-size changes do NOT
 * fall back (phase 11): they switch the plan to the simple re-encode
 * template - one flag per changed option (-vf scale=W:H, -r F) - and the
 * final assembly is still the lossless concat.''',
    ''' * Goal: when the timeline only contains operations that do not change the
 * stream parameters (trim, merge, freeze, mute), the unchanged parts of the
 * source clips are STREAM-COPIED (-c copy) into the output and only the
 * changed parts (freeze segments, trim cuts) are re-encoded with parameters
 * that match the source clips. The final assembly uses the concat demuxer
 * with -c copy, so most of the output is bit-exact with the original
 * footage.
 *
 * Phase 12: there is NO legacy filter-graph fallback anymore - this
 * planner is the ONLY export pipeline, and it never emits complex filter
 * graphs. Transitions export as straight cuts (frames are never blended). Any
 * pixel format is fine: keyframe cuts copy bytes untouched, encodable
 * 8-bit 4:2:0 sources keep the hybrid copy+match plan, and only exotic
 * formats with a non-keyframe trim re-encode everything uniformly.
 * Resolution / fps / custom-size changes (phase 11) also stay here: the
 * simple re-encode template - one flag per changed option (-vf scale=W:H,
 * -r F) - followed by the lossless concat.
 * When the project or settings are not compatible the planner returns null
 * and the caller surfaces the real reason instead of re-encoding.''',
    "planner: header docblock phase-12 semantics",
)

must_replace(
    PLANNER,
    ''' *   transition       : -ss tail / -ss head + xfade offset=0 (fps= filter needed
 *                      for CFR) + acrossfade
''',
    '',
    "planner: header xfade template line removed",
)

must_replace(
    PLANNER,
    ''' *   separate files   : one output file per timeline clip; transitions and
 *                      the concat step are skipped entirely''',
    ''' *   separate files   : one output file per timeline clip; the concat step
 *                      is skipped entirely''',
    "planner: header separate-files line reworded",
)

# 2s. settingsBlockSmart docblock: no legacy render to force anymore
must_replace(
    PLANNER,
    '''     * Settings-level gates (cheap, no probing): returns a human readable
     * reason when the current export settings force the legacy render, or
     * null when the smart path can run with these settings. Resolution /
     * fps / custom-size changes are handled by the simple re-encode plan
     * (phase 11), so they never gate here.''',
    '''     * Settings-level gates (cheap, no probing): returns a human readable
     * reason when the current export settings cannot run in the simple
     * pipeline (there is no fallback render anymore), or null when they
     * can. Resolution / fps / custom-size changes are handled by the
     * simple re-encode plan (phase 11), so they never gate here.''',
    "planner: settingsBlockSmart docblock",
)

# 2t. plan-summary log line: drop the clause that counted transition
# segments (the variable is gone with the straight-cut export)
must_replace(
    PLANNER,
    '''            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                ", transitions=" + (if (merged) clampedTransitions.size else 0) +
                (if (merged) "" else ", separate mode") +''',
    '''            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                (if (merged) "" else ", separate mode") +''',
    "planner: log line drops clampedTransitions clause",
)

print("step2 planner migration complete")
PYEOF
  else
    log "step2: [skip] planner already migrated (no yuv420p gate)"
  fi
}

###############################################################################
# Step 3 -- VideoEditingActivity.kt: honest blocker instead of legacy render
###############################################################################
step3() {
  if grep -q "viewModel.buildConsolidatedFFmpegCommand(" "$VEA"; then
    python3 - <<'PYEOF'
import sys

VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(path, old, new, label):
    c = rd(path)
    if new in c and old not in c:
        print("[skip] " + label)
        return
    n = c.count(old)
    if n != 1:
        print("[ERROR] %s: expected 1 occurrence, found %d" % (label, n))
        sys.exit(1)
    wr(path, c.replace(old, new))
    print("[ok] " + label)

def find_line(lines, substr, label):
    i = next((k for k, l in enumerate(lines) if substr in l), None)
    if i is None:
        print("[ERROR] %s: marker not found: %r" % (label, substr))
        sys.exit(1)
    return i

def delete_range(path, s, e, label):
    c = rd(path)
    lines = c.split("\n")
    del lines[s:e]
    wr(path, "\n".join(lines))
    print("[ok] %s (deleted %d lines)" % (label, e - s))

# 3a. saveAction: replace the whole legacy block (separate-files toast,
# consolidated command build, CONCAT_LIST processing, ExportService
# EXTRA_COMMAND intent) with the honest blocked-export error. The region
# ends at the first "catch" after it, which is re-emitted in the new text.
lines = rd(VEA).split("\n")
s = find_line(lines, "// Separate-files mode only works on the smart pipeline; when the", "vea-3a")
e = next((k for k, l in enumerate(lines[s + 1:], s + 1) if "} catch (e: Exception) {" in l), None)
if e is None:
    print("[ERROR] vea-3a: catch marker not found")
    sys.exit(1)
new_block = '''                // Phase 12: the legacy consolidated filter-graph render is
                // gone. Every export runs the smart pipeline (simple
                // per-segment commands + lossless concat). When the planner
                // refuses, surface the REAL reason instead of silently
                // falling back to a full re-encode.
                val analysis = try {
                    withContext(kotlinx.coroutines.Dispatchers.IO) {
                        com.tharunbirla.librecuts.services.SmartExportPlanner.analyzeSmartExport(
                            this@VideoEditingActivity, project, sourceFilePath
                        )
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Smart export analysis failed: " + e.message, e)
                    null
                }
                val settingsReason = analysis?.let {
                    com.tharunbirla.librecuts.services.SmartExportPlanner.settingsBlockSmart(
                        it,
                        viewModel.exportResolution.value,
                        viewModel.exportFps.value,
                        isAudioOnly,
                        viewModel.advancedExport.value.videoCodec,
                        viewModel.advancedExport.value.audioCodec,
                        viewModel.advancedExport.value.customWidth,
                        viewModel.advancedExport.value.customHeight,
                        viewModel.advancedExport.value.videoFormat
                    )
                }
                val reason = analysis?.reason ?: settingsReason
                    ?: "the project is not compatible with the simple export pipeline"
                viewModel.exportError(
                    "Export cancelled - " + reason + ". The export pipeline only runs simple " +
                        "per-segment commands (stream copy whenever possible); remove the " +
                        "unsupported edits or switch the settings back to Same as input."
                )
                Toast.makeText(this@VideoEditingActivity, "Export blocked: " + reason, Toast.LENGTH_LONG).show()'''
c = rd(VEA)
clines = c.split("\n")
clines[s:e] = new_block.split("\n")
wr(VEA, "\n".join(clines))
print("[ok] vea: saveAction legacy block -> honest blocked-export error (%d lines)" % (e - s))

# 3b. concatFile is gone with the legacy path
must_replace(
    VEA,
    '''            var tempOutputFile: File? = null
            var concatFile: File? = null
''',
    '''            var tempOutputFile: File? = null
''',
    "vea: drop concatFile declaration",
)

must_replace(
    VEA,
    '''                tempOutputFile?.let { if (it.exists()) it.delete() }
                concatFile?.let { if (it.exists()) it.delete() }
''',
    '''                tempOutputFile?.let { if (it.exists()) it.delete() }
''',
    "vea: drop concatFile cleanup",
)

# 3c. textPngRenderer wiring was only consumed by the consolidated builder
lines = rd(VEA).split("\n")
s = find_line(lines, "// WYSIWYG text rendering: AddText ops are rasterized with the same", "vea-3c")
e = find_line(lines, "// Initialize UI components", "vea-3c")
delete_range(VEA, s, e, "vea: delete textPngRenderer wiring")

# 3d. smart freeze gate: accept the encodable 8-bit 4:2:0 formats
must_replace(
    VEA,
    '''                if (srcParams != null && (srcParams.vCodec == "h264" || srcParams.vCodec == "hevc")
                    && srcParams.pixFmt == "yuv420p" && srcParams.width > 0 && srcParams.height > 0) {''',
    '''                if (srcParams != null && (srcParams.vCodec == "h264" || srcParams.vCodec == "hevc")
                    && (srcParams.pixFmt == "yuv420p" || srcParams.pixFmt == "yuvj420p"
                        || srcParams.pixFmt == "nv12" || srcParams.pixFmt == "nv21")
                    && srcParams.width > 0 && srcParams.height > 0) {''',
    "vea: smart freeze gate accepts yuvj420p/nv12/nv21",
)

# 3e. processConcatList only served the deleted CONCAT_LIST branch
lines = rd(VEA).split("\n")
s = find_line(lines, "    private fun processConcatList(concatList: String): String {", "vea-3e")
e = find_line(lines, "    private fun getAudioExtension(uri: Uri): String {", "vea-3e")
delete_range(VEA, s, e, "vea: delete processConcatList")

# 3f. stale comments still naming the deleted consolidated builder
must_replace(
    VEA,
    '''    // Passed to buildConsolidatedFFmpegCommand() so drawtext can find the font.''',
    '''    // Passed to buildPreviewCommand() so drawtext can find the font.''',
    "vea: font comment -> buildPreviewCommand",
)

must_replace(
    VEA,
    '''    /**
     * SAVE/EXPORT: Consolidates all pending operations into a single FFmpeg command and runs it.
     *
     * KEY FIX: fontFilePath (populated in onCreate from assets/fonts/Roboto-Regular.ttf)
     * is now passed to buildConsolidatedFFmpegCommand so drawtext gets a valid fontfile= path.
     */''',
    '''    /**
     * SAVE/EXPORT: plans the smart export (per-segment simple commands +
     * lossless concat) and runs it in the background via ExportService.
     *
     * fontFilePath (populated in onCreate from assets/fonts/Roboto-Regular.ttf)
     * is passed to buildPreviewCommand so drawtext gets a valid fontfile= path.
     */''',
    "vea: saveAction docblock phase-12 semantics",
)

print("step3 vea migration complete")
PYEOF
  else
    log "step3: [skip] VEA already migrated (no consolidated call)"
  fi
}

###############################################################################
# Step 4 -- ExportSettingsDialog.kt: honest preview, no legacy command
###############################################################################
step4() {
  if grep -q "viewModel.buildConsolidatedFFmpegCommand(" "$ESD"; then
    python3 - <<'PYEOF'
import sys

ESD = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(path, old, new, label):
    c = rd(path)
    if new in c and old not in c:
        print("[skip] " + label)
        return
    n = c.count(old)
    if n != 1:
        print("[ERROR] %s: expected 1 occurrence, found %d" % (label, n))
        sys.exit(1)
    wr(path, c.replace(old, new))
    print("[ok] " + label)

def find_line(lines, substr, label):
    i = next((k for k, l in enumerate(lines) if substr in l), None)
    if i is None:
        print("[ERROR] %s: marker not found: %r" % (label, substr))
        sys.exit(1)
    return i

# 4a. class docblock: no more consolidated-command rebuild
must_replace(
    ESD,
    ''' * Every control change is pushed live into the ViewModel, then the REAL export
 * command is rebuilt through VideoEditingViewModel.buildConsolidatedFFmpegCommand()
 * (the exact same code path the final export uses) and displayed in the preview
 * box, together with an estimated output file size.
 *
 * "Same as input" semantics (v3):
 *  - Video Codec "Same as input"  -> "-c:v copy" (lossless remux) whenever the
 *    edit graph allows it; if video processing is present the command falls
 *    back to libx264 (so the selected preset is honored) and the preview says so.
 *  - Audio Codec "Same as input"  -> "-c:a copy" whenever no audio filtering
 *    is needed; otherwise the chosen encoder is used.''',
    ''' * Every control change is pushed live into the ViewModel; the preview box
 * shows the exact simple commands the smart pipeline will run (per-segment
 * cuts + lossless concat) or, when the project/settings are not compatible,
 * the honest reason the export is blocked - there is no fallback re-encode
 * anymore (phase 12), together with an estimated output file size.
 *
 * "Same as input" semantics (v3): the smart plan stream-copies every segment
 * (-c copy) and assembles them with the concat demuxer; anything that needs
 * re-encoding runs the classic one-flag-per-option command.''',
    "esd: class docblock phase-12 semantics",
)

# 4b. estimateSizeText(): no cmd parameter, blocked case instead of guessing.
# Line-based splice: the old body contains a non-ascii comment line, so an
# exact-text match is not reliable here.
lines = rd(ESD).split("\n")
s = find_line(lines, "    private fun estimateSizeText(cmd: String?): String {", "esd-4b")
if s > 0 and "Size estimate that follows what the REAL command will do" in lines[s - 1]:
    s -= 1
e = next((k for k in range(s + 1, len(lines)) if lines[k] == "    }"), None)
if e is None:
    print("[ERROR] esd-4b: function close not found")
    sys.exit(1)
new_fn = '''    /** Size estimate that follows the smart plan (copied vs re-encoded parts). */
    private fun estimateSizeText(): String {
        val durSec = durationMs / 1000.0
        if (durSec <= 0.0) return "..."
        val smart = smartEstimateBytes()
        if (smart != null) return "~" + formatBytes(smart) + " (smart export)"
        // No fallback render exists anymore (phase 12): when the smart plan
        // cannot run the export refuses to start, so there is nothing to
        // estimate.
        return "(export blocked - see the command box)"
    }'''
lines[s:e + 1] = new_fn.split("\n")
wr(ESD, "\n".join(lines))
print("[ok] esd: estimateSizeText blocked-case rewrite")

# 4c. refresh(): no legacy command build
must_replace(
    ESD,
    '''        val ext = viewModel.getOutputExtension(false)
        val previewPath = File(activity.cacheDir, "temp_video_preview$ext").absolutePath
        val srcPath = sourceFile?.absolutePath
        val cmd = if (srcPath != null)
            viewModel.buildConsolidatedFFmpegCommand(srcPath, previewPath, fontPath, activity)
        else null
        tvCommand.text = commandPreviewText(cmd)
        tvEstimatedSize.text = estimateSizeText(cmd)''',
    '''        tvCommand.text = commandPreviewText()
        tvEstimatedSize.text = estimateSizeText()''',
    "esd: refresh() drops legacy command build",
)

# 4d. commandPreviewText(): smart plan or honest blocker, never a monster
must_replace(
    ESD,
    '''    /** Real command + notes. Shows the SMART plan when it will actually run. */
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
        return if (notes.isEmpty()) base else base + "\\n\\n(" + notes.joinToString("; ") + ")"
    }''',
    '''    /** The exact commands the smart pipeline will run, or the honest blocker. */
    private fun commandPreviewText(): String {
        val smart = buildSmartSummary()
        if (smart != null) return smart
        val why = smartUnavailableNote() ?: "smart export analysis failed"
        return "(export blocked - " + why + ")\\n\\n" +
            "The export pipeline only runs simple per-segment ffmpeg commands\\n" +
            "(stream copy whenever possible, concat demuxer assembly) - there is\\n" +
            "no filter-graph fallback. Remove the unsupported edits above or switch\\n" +
            "the settings back to Same as input, then export again."
    }''',
    "esd: commandPreviewText blocked-case rewrite",
)

# 4e. smartUnavailableNote(): no "full re-encode used" anymore
must_replace(
    ESD,
    '''        a.reason?.let { return "smart export unavailable: $it - full re-encode used" }''',
    '''        a.reason?.let { return "smart export unavailable: $it" }''',
    "esd: reason note wording",
)

must_replace(
    ESD,
    '''        return gate?.let { "smart export disabled by these settings: $it - full re-encode used" }''',
    '''        return gate?.let { "export blocked by these settings: $it" }''',
    "esd: settings gate note wording",
)

# 4f. smartReencodeMode(): mirror the planner's pixel-format rule
must_replace(
    ESD,
    '''    private fun smartReencodeMode(a: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis): Boolean {
        val customScale = customW >= 16 && customH >= 16
        val resChange = !customScale && selRes != 0 && selRes != a.displayHeight && selRes != a.shortSide
        val fpsChange = selFps != 0 && selFps != a.fpsRounded
        return customScale || resChange || fpsChange
    }''',
    '''    private fun smartReencodeMode(a: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis): Boolean {
        val customScale = customW >= 16 && customH >= 16
        val resChange = !customScale && selRes != 0 && selRes != a.displayHeight && selRes != a.shortSide
        val fpsChange = selFps != 0 && selFps != a.fpsRounded
        // Phase 12 mirror of the planner rule: a source pixel format the
        // re-encode templates cannot reproduce (10-bit and friends) forces
        // the uniform re-encode plan whenever a trim needs encoding.
        val anyTrimmed = a.clips.any {
            !(it.trimStartMs <= 60L && it.trimEndMs >= it.durationMs - 60L)
        }
        return customScale || resChange || fpsChange ||
            (a.pixFmt != "yuv420p" && a.pixFmt != "yuvj420p" &&
                a.pixFmt != "nv12" && a.pixFmt != "nv21" && !selKeyframeCut && anyTrimmed)
    }''',
    "esd: smartReencodeMode mirrors planner pix_fmt rule",
)

# 4g. separate-files note: transitions no longer apply at all
must_replace(
    ESD,
    '''                sb.append("\\n(transitions and faststart apply to the merged single-file mode only)")''',
    '''                sb.append("\\n(faststart applies to the merged single-file mode only)")''',
    "esd: separate-files note reworded",
)

# 4h. buildSmartSummary(): spans are plain trims, transitions not re-encoded
must_replace(
    ESD,
    '''        var copySec = 0.0
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
        encSec += a.transitions.values.sum() / 1000.0''',
    '''        var copySec = 0.0
        var encSec = 0.0
        for (i in a.clips.indices) {
            val c = a.clips[i]
            val spanMs = c.trimEndMs - c.trimStartMs
            if (spanMs <= 0L) continue
            val full = c.fullRange
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }''',
    "esd: buildSmartSummary plain spans",
)

# 4i. transition note after the keyframe-cut note
must_replace(
    ESD,
    '''        if (selKeyframeCut) sb.append("; keyframe cut ON (trims snap to keyframes, +/- one GOP accuracy)")
        sb.append("; final assembly is a lossless concat)")''',
    '''        if (selKeyframeCut) sb.append("; keyframe cut ON (trims snap to keyframes, +/- one GOP accuracy)")
        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) exported as straight cuts (no frame blending)")
        }
        sb.append("; final assembly is a lossless concat)")''',
    "esd: straight-cuts transition note",
)

# 4j. smartEstimateBytes(): plain spans in both branches
must_replace(
    ESD,
    '''            var totalSec = 0.0
            for (i in a.clips.indices) {
                val dLeft = if (!selSeparateFiles && i > 0) a.transitions[i - 1] ?: 0L else 0L
                val dRight = if (!selSeparateFiles && i < a.clips.size - 1) a.transitions[i] ?: 0L else 0L
                val spanMs = (a.clips[i].trimEndMs - dRight) - (a.clips[i].trimStartMs + dLeft)
                if (spanMs > 0L) totalSec += spanMs / 1000.0
            }
            if (!selSeparateFiles) totalSec += a.transitions.values.sum() / 1000.0''',
    '''            var totalSec = 0.0
            for (i in a.clips.indices) {
                val spanMs = a.clips[i].trimEndMs - a.clips[i].trimStartMs
                if (spanMs > 0L) totalSec += spanMs / 1000.0
            }''',
    "esd: smartEstimateBytes reencode branch plain spans",
)

must_replace(
    ESD,
    '''        for (i in a.clips.indices) {
            val c = a.clips[i]
            val dLeft = if (!selSeparateFiles && i > 0) a.transitions[i - 1] ?: 0L else 0L
            val dRight = if (!selSeparateFiles && i < a.clips.size - 1) a.transitions[i] ?: 0L else 0L
            val spanMs = (c.trimEndMs - dRight) - (c.trimStartMs + dLeft)
            if (spanMs <= 0L) continue
            val full = c.fullRange && dLeft == 0L && dRight == 0L
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }
        if (!selSeparateFiles) encSec += a.transitions.values.sum() / 1000.0''',
    '''        for (i in a.clips.indices) {
            val c = a.clips[i]
            val spanMs = c.trimEndMs - c.trimStartMs
            if (spanMs <= 0L) continue
            val full = c.fullRange
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }''',
    "esd: smartEstimateBytes hybrid branch plain spans",
)

print("step4 esd migration complete")
PYEOF
  else
    log "step4: [skip] ESD already migrated (no consolidated call)"
  fi
}

###############################################################################
# Step 5 -- FFmpegRenderEngine.kt: delete the amix filter_complex helper
###############################################################################
step5() {
  if grep -q "suspend fun addBackgroundAudio(" "$ENGINE"; then
    python3 - <<'PYEOF'
import sys

ENGINE = "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def find_line(lines, substr, label):
    i = next((k for k, l in enumerate(lines) if substr in l), None)
    if i is None:
        print("[ERROR] %s: marker not found: %r" % (label, substr))
        sys.exit(1)
    return i

def delete_range(path, s, e, label):
    c = rd(path)
    lines = c.split("\n")
    del lines[s:e]
    wr(path, "\n".join(lines))
    print("[ok] %s (deleted %d lines)" % (label, e - s))

lines = rd(ENGINE).split("\n")
s = find_line(lines, "    suspend fun addBackgroundAudio(", "engine-5a")
e = find_line(lines, "    suspend fun muteAudio(", "engine-5a")
delete_range(ENGINE, s, e, "engine: delete addBackgroundAudio (amix filter_complex, zero callers)")
print("step5 engine migration complete")
PYEOF
  else
    log "step5: [skip] engine already migrated (no addBackgroundAudio)"
  fi
}

###############################################################################
# Step 6 -- hard verification gate (exits 1 BEFORE anything can be committed)
###############################################################################
step6() {
  log "step6: verification gate"
  python3 - <<'PYEOF'
import subprocess, sys

FILES = {
    "PLANNER": "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt",
    "ESD": "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt",
    "VM": "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt",
    "VEA": "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt",
    "ENGINE": "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt",
}

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def head(p):
    try:
        out = subprocess.run(["git", "show", "HEAD:" + p],
                             capture_output=True, text=True, check=True)
        return out.stdout
    except subprocess.CalledProcessError:
        return None

def count(hay, needle):
    return hay.count(needle)

errors = []

def check(cond, msg):
    if cond:
        print("  [pass] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)

# ---- THE gate: no filter_complex anywhere in the app sources ----
import glob, os
hits = []
for path in glob.glob("app/src/main/java/**/*.kt", recursive=True) + \
          glob.glob("app/src/main/java/**/*.java", recursive=True):
    try:
        if "filter_complex" in rd(path):
            hits.append(path)
    except Exception:
        pass
check(not hits, "filter_complex absent from every app source file (%s)" %
      ("found in: " + ", ".join(hits) if hits else "zero occurrences"))

# ---- symbol inventory: deleted things must be gone ----
gone = {
    "VM": ["fun buildConsolidatedFFmpegCommand(", "buildVideoFilterStages(",
           "prepareTextPngInputs(", "textPngRenderer", "overlayPosExpr(",
           "appendOutputContainerArgs(", "buildOutputScaleFilter(",
           "buildOutputVfArgs(", "buildVideoCodecArgs(", "buildAudioCodecArgs(",
           "copyContentUriToTempFile(", "fun buildMergeCommand(",
           "-filter_complex"],
    "PLANNER": ['fail("source pixel format is not yuv420p")',
                'fail("a clip is not yuv420p")',
                "xfade", "acrossfade", "sanitizeTransitionType",
                "validXfadeTransitions", "transScalePrefix", "transFpsFilter",
                "transEnc"],
    "VEA": ["buildConsolidatedFFmpegCommand", "textPngRenderer",
            "processConcatList", "(CONCAT_LIST:", "EXTRA_COMMAND",
            "{CONCAT_FILE_PATH}"],
    "ESD": ["buildConsolidatedFFmpegCommand", "(CONCAT_LIST:",
            "full re-encode used", "preview unavailable"],
    "ENGINE": ["addBackgroundAudio", "amix"],
}
for key, toks in gone.items():
    c = rd(FILES[key])
    for t in toks:
        check(count(c, t) == 0, "%s: no %r (count=%d)" % (key, t, count(c, t)))

# ---- symbol inventory: new/kept things must exist ----
present = {
    "VM": [("fun buildPreviewCommand(", 1), ("buildDrawtextExpr(", 2),
           ("drawtextChain", 3), (' -vf \\"', 1)],
    "PLANNER": [("fun analyzeSmartExport(", 1), ("fun settingsBlockSmart(", 1),
                ("fun planSmartExport(", 1), ("encodablePixFmt", 6),
                ("clips use different pixel formats", 1),
                ('val vCodec: String,\n        val pixFmt: String,\n        val reason: String?', 1),
                ("pixFmt = refParams.pixFmt,", 1),
                ('SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", "", reason)', 1),
                ("val reencodeAll = customScale || resChange || fpsChange ||", 1),
                ("val anyTrimmedSpan = clips.any {", 1),
                ("val encodableSource = ", 1),
                ("transitions export as straight cuts", 1),
                ("-bsf:v dump_extra", 2),
                ("-avoid_negative_ts make_zero", 3),
                ("fun buildFreezeFrameCommands(", 1),
                ("clampedTransitions", 3)],
    "VEA": [("analyzeSmartExport(", 1), ("settingsBlockSmart(", 1),
            ("Export blocked: ", 1), ("EXTRA_SMART_PLAN_PATH", 1),
            ("Export started in background...", 1),
            ('srcParams.pixFmt == "yuvj420p"', 1),
            ("buildPreviewCommand(", 2)],
    "ESD": [("fun commandPreviewText(): String {", 1),
            ("fun estimateSizeText(): String {", 1),
            ("(export blocked - see the command box)", 1),
            ("(export blocked - ", 2),
            ("no filter-graph fallback", 1),
            ("exported as straight cuts", 1),
            ("a.pixFmt", 4),
            ("fun buildSmartSummary(): String? {", 1),
            ("fun smartEstimateBytes(): Double? {", 1)],
    "ENGINE": [("suspend fun muteAudio(", 1),
               ("suspend fun addTextOverlay(", 1)],
}
for key, toks in present.items():
    c = rd(FILES[key])
    for t, expected in toks:
        n = count(c, t)
        if expected == 0:
            check(n == 0, "%s: exactly 0 x %r (count=%d)" % (key, t, n))
        else:
            check(n == expected, "%s: %d x %r (count=%d)" % (key, expected, t, n))

# ---- brace / paren deltas vs HEAD (deletions+insertions are balanced) ----
# When the phase-12 tree is already committed (cur == HEAD), delta checks are
# meaningless (everything is 0 by definition) and must be skipped.
import subprocess as _sp
_dirty = set()
try:
    _st = _sp.run(["git", "status", "--porcelain"],
                  capture_output=True, text=True, check=True).stdout
    for _l in _st.split("\n"):
        if _l.strip():
            _dirty.add(_l[3:].strip().strip('"'))
except Exception:
    pass

for key, path in FILES.items():
    if path not in _dirty:
        print("  [info] %s: already committed (== HEAD), delta checks skipped" % key)
        continue
    cur = rd(path)
    base = head(path)
    if base is None:
        print("  [warn] %s: no HEAD version, skipping delta" % key)
        continue
    for ch_open, ch_close, name in [("{", "}", "braces"), ("(", ")", "parens")]:
        d = (count(cur, ch_open) - count(cur, ch_close)) - \
            (count(base, ch_open) - count(base, ch_close))
        if name == "braces":
            check(d == 0, "%s: brace delta vs HEAD == 0 (actual %d)" % (key, d))
        else:
            print("  [info] %s: paren delta vs HEAD = %d" % (key, d))

# pinned paren deltas (string literals inside deleted code carry unbalanced
# parens; calibrated on the pristine phase-11 tree during testing)
PAREN_DELTAS = {"VM": 0, "PLANNER": 0, "VEA": -3, "ESD": -2, "ENGINE": 0}
for key, path in FILES.items():
    if path not in _dirty:
        continue
    cur = rd(path)
    base = head(path)
    if base is None:
        continue
    d = (count(cur, "(") - count(cur, ")")) - (count(base, "(") - count(base, ")"))
    check(d == PAREN_DELTAS[key],
          "%s: paren delta == %d (actual %d)" % (key, PAREN_DELTAS[key], d))

# ---- ASCII purity: no NEW non-ascii characters vs HEAD ----
for key, path in FILES.items():
    if path not in _dirty:
        continue
    cur = rd(path)
    base = head(path)
    if base is None:
        continue
    def nonascii(s):
        return sum(1 for ch in s if ord(ch) > 127)
    check(nonascii(cur) <= nonascii(base),
          "%s: no new non-ascii chars (now %d, before %d)" %
          (key, nonascii(cur), nonascii(base)))

# ---- survival: the smart pipeline core is intact ----
planner = rd(FILES["PLANNER"])
check("keyframeCut" in planner and "-c copy" in planner,
      "planner: keyframe copy branch intact")
esd = rd(FILES["ESD"])
check("keyframe cut ON" in esd, "esd: keyframe-cut note intact")
check("concat_list.txt" in esd, "esd: concat preview intact")

# ---- no empty duplicated catch clause (splice regression guard) ----
for key in ("VEA",):
    src = rd(FILES[key])
    ls = src.split("\n")
    dup = [i + 1 for i, l in enumerate(ls[:-1])
           if "} catch (" in l and "} catch (" in ls[i + 1]]
    check(not dup, "%s: no duplicated empty catch clause (lines %s)" % (key, dup))

if errors:
    print("\n[phase12][GATE] %d check(s) FAILED - aborting" % len(errors))
    for e in errors:
        print("  - " + e)
    sys.exit(1)
print("\n[phase12][GATE] all checks passed")
PYEOF
}

###############################################################################
# Step 7 -- scope gate: only the five files (+ this script) may change
###############################################################################
step7() {
  log "step7: scope gate"
  python3 - <<'PYEOF'
import subprocess, sys

ALLOWED = {
    "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt",
    "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt",
    "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt",
    "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt",
    "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt",
    "scripts/apply-changes.sh",
}
out = subprocess.run(["git", "status", "--porcelain"],
                     capture_output=True, text=True, check=True).stdout
dirty = []
for line in out.split("\n"):
    if not line.strip():
        continue
    path = line[3:].strip().strip('"')
    if path.startswith(".github/"):
        print("[ERROR] scope: .github file modified: " + path)
        sys.exit(1)
    if path not in ALLOWED:
        dirty.append(path)
if dirty:
    print("[ERROR] scope: unexpected modified files: " + ", ".join(dirty))
    sys.exit(1)
print("[phase12] scope ok: only the five source files (+ script) changed")
PYEOF
}

###############################################################################
# Main
###############################################################################
step1
step2
step3
step4
step5
step6
step7
log "phase 12 applied successfully - no filter_complex anywhere in the export pipeline"
