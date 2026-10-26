#!/usr/bin/env bash
###############################################################################
# CutLoss phase 13 -- "the flag contract"
#
# User directive (the export settings contract, spelled out by the user):
#   - The export page has: resolution, video format, video bitrate, video
#     codec, video fps, audio format, audio codec, audio bitrate, preset.
#   - When EVERY setting is "same as input" the export is a pure -c copy.
#   - When ONE setting changes, its ONE ffmpeg flag appears:
#       resolution -> -vf scale=W:H (audio stays -c:a copy, NO -b flags)
#       fps        -> -r F
#       bitrate    -> -b:v / -b:a
#       codec      -> -c:v / -c:a
#   - A setting left on "same as input" writes NO flag at all.
#   - A long video cut with split/trim + a bitrate change runs TWO steps:
#     the lossless cut first (-c copy, seconds), then ONE re-encode of the
#     assembled cut with -b:v. Never a filter graph, never a per-segment
#     re-encode for the default (keyframe) cut mode.
#
# What changes (6 files):
#   SmartExportPlanner.kt:
#     - New simpleVideoEncoderArgs / simpleAudioEncoderArgs helpers: one
#       flag per CHANGED option only. Codec -> -c:v (source encoder family
#       when unchanged); bitrate -> -b:v only when the user set one (CRF
#       quality otherwise; VP9/AV1 get -crf X -b:v 0 because their default
#       2-pass bitrate is unusable); preset -> x264/x265 only (hardware /
#       VP9 / AV1 encoders do not take -preset); -pix_fmt only when the
#       source format must be converted for the 8-bit encoders.
#     - planInternal modes: twoStep (keyframe cut + changed settings =
#       lossless per-segment -c copy + concat + ONE finalize command on the
#       assembled cut) / perSegmentEncode (normal cut + changed settings =
#       direct frame-accurate encode per segment) / pure copy (unchanged).
#       The old reencodeAll template is gone.
#     - Container support: MP4/MKV/MOV remux losslessly (segments and the
#       concat get the target extension, faststart only for MP4/MOV), WebM
#       requires VP9/AV1 video + Opus audio (settingsBlockSmart says why),
#       AVI is refused. PCM/FLAC audio is MKK-only.
#     - SmartAnalysis gains aCodec so the dialog can mirror the audio flag
#       rules (bitrate-only change re-encodes with the SOURCE codec).
#     - Generated silence (muted clips) encodes as Opus when the target is
#       WebM.
#   ExportSettingsDialog.kt:
#     - "Same as input" bitrate now forwards "" (no -b:v) instead of the
#       measured source bitrate.
#     - smartReencodeMode -> smartEncodeMode: any changed setting (res /
#       fps / custom size / codec / bitrate / audio codec / audio bitrate)
#       switches the plan; the preview shows the exact two-step or
#       per-segment commands with the real flag list.
#   VideoEditingViewModel.kt:
#     - exportBitrate default "8M" -> "" (same as input, no flag).
#   VideoEditingActivity.kt:
#     - Stale "consolidated render" comments/log wording fixed.
#   ExportService.kt:
#     - Gallery save derives the extension + mime type from the ACTUAL
#       output file (MP4/MKV/MOV/WebM/AVI + audio formats) instead of
#       hardcoding video/mp4.
#   FFmpegRenderEngine.kt:
#     - hevc_mediacodec failure falls back to libx265 -tag:v hvc1 (same
#       safety net the h264 encoder already had).
#
# Every new command template was validated in the local ffmpeg 7.1 lab
# (scripts/lab-phase13): two-step cut+finalize, scale+audio-copy, bitrate
# only, audio-only re-encode (-c:v copy), x265/vp9/av1 codec changes,
# mkv/mov/webm containers, webm concat, libopus auto-resample, rotation
# baking, -r with -c copy being a silent no-op (fps always forces encode).
#
# Precondition: phase 12 must be in the tree (22c628f or later).
# Invariants: pure ASCII, idempotent (2nd run = [skip], zero diff),
# touches exactly six source files, hard verification gate exits 1
# BEFORE anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase13] $*"; }
fail() { echo "[phase13][ERROR] $*" >&2; exit 1; }

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
SVC="app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
ENGINE="app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"

###############################################################################
# Step 0 -- preconditions
###############################################################################
log "step0: checking preconditions"
[ -f "$PLANNER" ] || fail "SmartExportPlanner.kt not found"
[ -f "$ESD" ] || fail "ExportSettingsDialog.kt not found"
[ -f "$VM" ] || fail "VideoEditingViewModel.kt not found"
[ -f "$VEA" ] || fail "VideoEditingActivity.kt not found"
[ -f "$SVC" ] || fail "ExportService.kt not found"
[ -f "$ENGINE" ] || fail "FFmpegRenderEngine.kt not found"
grep -q "filter_complex" -r app/src/main/java && fail "filter_complex found in sources (phase 12 regression)"
# Phase 12 must be in the tree (its header note survives phase 13); a tree
# that ALREADY has phase 13 is fine too - every edit below is [skip]-safe.
grep -q "there is NO legacy filter-graph fallback" "$PLANNER" || fail "phase 12 not found in planner header (wrong base commit)"
log "step0: preconditions ok"

###############################################################################
# Step 1 -- SmartExportPlanner.kt
###############################################################################
step1() {
    log "step1: SmartExportPlanner.kt -- the flag contract"
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
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# ---------------------------------------------------------------- 1a header
must_replace(PLANNER,
r''' * Resolution / fps / custom-size changes (phase 11) also stay here: the
 * simple re-encode template - one flag per changed option (-vf scale=W:H,
 * -r F) - followed by the lossless concat.
 * When the project or settings are not compatible the planner returns null
 * and the caller surfaces the real reason instead of re-encoding.''',
r''' * Resolution / fps / custom-size changes (phase 11) also stay here: the
 * simple re-encode template - one flag per changed option (-vf scale=W:H,
 * -r F) - followed by the lossless concat.
 * Phase 13 (the flag contract): every export setting maps to exactly one
 * ffmpeg flag, and a setting left on "same as input" writes NO flag at
 * all - all-same-as-input exports are a pure -c copy. Keyframe-cut exports
 * with changed settings run TWO steps: the lossless cut first (per-segment
 * -c copy + concat), then ONE finalize command on the assembled file with
 * a flag per changed option (-vf scale, -r, -c:v, -b:v, -c:a, -b:a,
 * -preset). Normal-cut exports with changed settings encode each segment
 * directly (frame-accurate). Containers: MP4/MKV/MOV remux losslessly,
 * WebM needs VP9/AV1 video + Opus audio, AVI is refused.
 * When the project or settings are not compatible the planner returns null
 * and the caller surfaces the real reason instead of re-encoding.''',
"1a header doc")

# ------------------------------------------------- 1b SmartAnalysis + aCodec
must_replace(PLANNER,
r'''        val fpsRounded: Int,
        val vCodec: String,
        val pixFmt: String,
        val reason: String?
    )''',
r'''        val fpsRounded: Int,
        val vCodec: String,
        val aCodec: String,
        val pixFmt: String,
        val reason: String?
    )''',
"1b SmartAnalysis field")

must_replace(PLANNER,
r'''            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", "", reason)''',
r'''            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", "", "", reason)''',
"1b fail() constructor")

must_replace(PLANNER,
r'''            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            vCodec = refParams.vCodec,
            pixFmt = refParams.pixFmt,
            reason = null
        )''',
r'''            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            vCodec = refParams.vCodec,
            aCodec = audioRef?.aCodec ?: "",
            pixFmt = refParams.pixFmt,
            reason = null
        )''',
"1b analysis return")

# ------------------------------------------------------ 1c settingsBlockSmart
must_replace(PLANNER,
r'''        if (audioOnly) return "audio-only export"
        if (videoFormat != "mp4") return "non-MP4 container"
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return "custom codec requested"
        // Phase 11: resolution / fps / custom-size changes no longer disable
        // the smart path -- they switch it to the simple re-encode template
        // (a scale / -r flag per changed option), like the classic ffmpeg
        // one-command workflow.
        return null''',
r'''        if (audioOnly) return "audio-only export"
        // Phase 13 container rules: MP4/MKV/MOV remux losslessly, WebM
        // needs VP9/AV1 video and Opus audio, AVI cannot hold the streams.
        if (videoFormat == "avi") {
            return "AVI cannot hold the streams - use MP4, MKV, MOV or Same as input"
        }
        if (videoFormat == "webm") {
            if (advancedVideoCodec != "libvpx-vp9" && advancedVideoCodec != "libaom-av1") {
                return "WebM needs VP9 or AV1 video - set the Video codec chip or use MKV"
            }
            if (analysis.hasAudio && advancedAudioCodec != "libopus") {
                return "WebM audio must be Opus - set the Audio codec to Opus or use MKV"
            }
        }
        if ((advancedAudioCodec == "pcm_s16le" || advancedAudioCodec == "flac") &&
            (videoFormat == "mp4" || videoFormat == "mov")
        ) {
            return "PCM/FLAC audio does not fit MP4/MOV - pick MKV or Same as input"
        }
        // Phase 11/13: resolution / fps / custom-size / codec / bitrate
        // changes never disable the smart path -- they switch it to the
        // simple commands with ONE flag per changed option.
        return null''',
"1c settingsBlockSmart gates")

# --------------------------------------------------- 1d planInternal early gates
must_replace(PLANNER,
r'''        if (audioOnly) return null
        if (videoFormat != "mp4") return null
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return null
        if (isImagePath(sourceFilePath)) return null''',
r'''        if (audioOnly) return null
        if (videoFormat == "avi") return null
        if (videoFormat == "webm" &&
            advancedVideoCodec != "libvpx-vp9" && advancedVideoCodec != "libaom-av1") return null
        if (isImagePath(sourceFilePath)) return null''',
"1d planInternal container gates")

# --------------------------------------------------- 1e flag contract + modes
must_replace(PLANNER,
r'''        // ---- phase 12: pixel-format uniformity ----
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
            (!encodableSource && !keyframeCut && anyTrimmedSpan)''',
r'''        // ---- phase 12: pixel-format uniformity ----
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
        // ---- phase 13: the flag contract ----
        // A setting left on "same as input" never writes a flag. All
        // same-as-input = pure -c copy. Keyframe cut + changed settings =
        // TWO steps: the lossless cut first, then ONE finalize command with
        // a flag per changed option. Normal cut + changed settings = direct
        // per-segment encode (frame-accurate). A non-encodable pixel format
        // with a normal-cut trim still forces the uniform encode.
        val vBitrateSet = exportBitrate.isNotEmpty()
        val vCodecSet = advancedVideoCodec.isNotEmpty()
        val aBitrateSet = advancedAudioBitrate.isNotEmpty()
        val aCodecSet = advancedAudioCodec.isNotEmpty()
        val needsVideoEncode = customScale || resChange || fpsChange || vBitrateSet || vCodecSet
        val needsAudioEncode = aBitrateSet || aCodecSet
        val anyEncode = needsVideoEncode || needsAudioEncode
        val twoStep = anyEncode && keyframeCut
        val perSegmentEncode = !keyframeCut &&
            (anyEncode || (!encodableSource && anyTrimmedSpan))
        val outExt = when (videoFormat) {
            "mkv" -> ".mkv"
            "mov" -> ".mov"
            "webm" -> ".webm"
            else -> ".mp4"
        }
        // Stage-one segments hold the COPIED source streams, so they cannot
        // be WebM (H.264/HEVC do not fit that container); encoded
        // per-segment outputs can.
        val segExt = if (videoFormat == "webm") ".mp4" else outExt''',
"1e flag contract + plan modes")

# ------------------------------------------------------- 1f webm/pcm audio gate
must_replace(PLANNER,
r'''        if (audioRef != null) {
            for (c in clips) {
                if (c.params.hasAudio) {
                    if (c.params.aCodec != audioRef.aCodec) return null
                    if (c.params.aSampleRate != audioRef.aSampleRate) return null
                    if (c.params.aChannels != audioRef.aChannels) return null
                }
            }
        }
        val planHasAudio = audioRef != null''',
r'''        if (audioRef != null) {
            for (c in clips) {
                if (c.params.hasAudio) {
                    if (c.params.aCodec != audioRef.aCodec) return null
                    if (c.params.aSampleRate != audioRef.aSampleRate) return null
                    if (c.params.aChannels != audioRef.aChannels) return null
                }
            }
        }
        // Phase 13 container gates (mirror settingsBlockSmart).
        if (videoFormat == "webm" && audioRef != null && advancedAudioCodec != "libopus") return null
        if ((advancedAudioCodec == "pcm_s16le" || advancedAudioCodec == "flac") &&
            (videoFormat == "mp4" || videoFormat == "mov")) return null
        val planHasAudio = audioRef != null''',
"1f webm/pcm audio gates")

# ------------------------------------------------------------- 1g total span
must_replace(PLANNER,
r'''        val merged = !exportSeparateFiles
        for (i in clips.indices) {
            if (clips[i].trimEndMs <= clips[i].trimStartMs) return null
        }''',
r'''        val merged = !exportSeparateFiles   // single file vs one per clip
        for (i in clips.indices) {
            if (clips[i].trimEndMs <= clips[i].trimStartMs) return null
        }
        var totalSpanSec = 0.0
        for (c in clips) {
            totalSpanSec += Math.max(0.0, (c.trimEndMs - c.trimStartMs) / 1000.0)
        }''',
"1g total span seconds")
PYEOF
}

step1
log "step1: done"

###############################################################################
# Step 1b -- SmartExportPlanner.kt (command building)
###############################################################################
step1b() {
    log "step1b: SmartExportPlanner.kt -- simple encoders + command building"
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
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# ------------------------------------------- 1h simple encoders + segment files
must_replace(PLANNER,
r'''        // ---- build per-segment commands ----
        val commands = mutableListOf<Pair<String, Double>>()
        val segmentFiles = mutableListOf<File>()
        val enc = videoEncoderArgs(refParams, exportBitrate, advancedPreset) ?: return null
        val aEnc = audioEncoderArgs(audioRef, advancedAudioBitrate)
        val fpsFilter = "fps=" + refParams.fpsString
        // Simple-command encoder for the re-encode mode (phase 11): no
        // profile / level matching (the source profile may not fit the
        // target size) - just the classic "-c:v libx264 -b:v X" form.
        val encPixFmt = encodablePixFmt(refParams)
        val encSimple: String = if (refParams.vCodec == "hevc") {
            val sb = StringBuilder("-c:v libx265 -tag:v hvc1 -pix_fmt ").append(encPixFmt)
            if (exportBitrate.isNotEmpty()) sb.append(" -b:v ").append(exportBitrate) else sb.append(" -crf 20")
            if (advancedPreset.isNotEmpty()) sb.append(" -preset ").append(advancedPreset)
            sb.toString()
        } else {
            val sb = StringBuilder("-c:v libx264 -pix_fmt ").append(encPixFmt)
            if (exportBitrate.isNotEmpty()) sb.append(" -b:v ").append(exportBitrate) else sb.append(" -crf 18")
            if (advancedPreset.isNotEmpty()) sb.append(" -preset ").append(advancedPreset)
            sb.toString()
        }
        var segCounter = 0
        fun nextSegmentFile(): File {
            val f = File(workDir, "seg_" + segCounter + ".mp4")
            segCounter++
            segmentFiles.add(f)
            return f
        }''',
r'''        // ---- build per-segment commands ----
        val commands = mutableListOf<Pair<String, Double>>()
        val segmentFiles = mutableListOf<File>()
        val encodedOutFiles = mutableListOf<File>()
        // Matched-parameter encoders for the hybrid span re-encode (phase 9):
        // a trimmed span must be bitstream-compatible with its copied
        // neighbours, so it matches the source profile / level / format.
        val enc = videoEncoderArgs(refParams, exportBitrate, advancedPreset) ?: return null
        val aEnc = audioEncoderArgs(audioRef, advancedAudioBitrate)
        // Generated silence cannot stream-copy, and WebM needs Opus.
        val aEncSilence = when {
            videoFormat != "webm" -> aEnc
            advancedAudioBitrate.isNotEmpty() -> "-c:a libopus -ar 48000 -b:a " + advancedAudioBitrate
            else -> "-c:a libopus -ar 48000 -b:a 128k"
        }
        val fpsFilter = "fps=" + refParams.fpsString
        // ---- phase 13: one-flag-per-changed-option encoders ----
        // Same-as-input options write NO flag: codec -> -c:v (source
        // encoder family when unchanged), bitrate -> -b:v only when the
        // user set one (CRF-quality default otherwise), preset -> x264/x265
        // only, audio -> -c:a copy unless codec or bitrate changed.
        val vEncSimple = simpleVideoEncoderArgs(refParams, advancedVideoCodec, exportBitrate, advancedPreset)
        val aEncSimple = simpleAudioEncoderArgs(audioRef, advancedAudioCodec, advancedAudioBitrate)
        var segCounter = 0
        fun nextSegmentFile(ext: String): File {
            val f = File(workDir, "seg_" + segCounter + ext)
            segCounter++
            segmentFiles.add(f)
            return f
        }''',
"1h encoder section")

# ------------------------------------------------- 1i per-segment loop head
must_replace(PLANNER,
r'''            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
            val seg = nextSegmentFile()

            if (reencodeAll) {
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
            } else if (fullRange) {''',
r'''            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
            val seg = if (perSegmentEncode) nextSegmentFile(outExt) else nextSegmentFile(segExt)

            if (perSegmentEncode) {
                // Frame-accurate direct encode (phase 11/13): one command
                // per segment with ONE flag per changed option. -ss before
                // -i decodes forward, so cuts land on the exact frame;
                // autorotate runs before scale, so rotated phone clips land
                // on their display dimensions. Audio left on same-as-input
                // stream-copies next to the re-encoded video.
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
                sb.append(" ").append(vEncSimple)
                if (silenceAudio) {
                    sb.append(" ").append(aEncSilence)
                } else if (planHasAudio) {
                    sb.append(" ").append(aEncSimple)
                }
                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(" \"").append(seg.absolutePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else if (fullRange) {''',
"1i per-segment encode branch")

# ------------------------------------- 1j concat + two-step finalize + separate
must_replace(PLANNER,
r'''        // ---- final assembly: concat with stream copy (merged mode only) ----
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
        }''',
r'''        // ---- final assembly: concat with stream copy (merged mode only) ----
        // seg_0 is attached as a second input purely so the output can
        // inherit the source's global metadata (-map_metadata 1); faststart
        // relocates the MP4 moov atom to the front of the file. In the
        // two-step plan (phase 13) the concat assembles the intermediate
        // lossless cut and the finalize command below re-encodes it once.
        if (merged) {
            val listFile = File(workDir, "concat_list.txt")
            val listSb = StringBuilder()
            for (f in segmentFiles) {
                listSb.append("file '").append(f.absolutePath).append("'\n")
            }
            listFile.writeText(listSb.toString())

            val audioMap = if (planHasAudio && !audioMuted) " -map 0:a:0" else ""
            val metaArg = if (preserveMetadata) " -map_metadata 1" else ""
            val concatTarget = if (twoStep) File(workDir, "cut" + segExt).absolutePath else outputFilePath
            val fastArg = if (movFastStart && !twoStep && (segExt == ".mp4" || segExt == ".mov"))
                " -movflags +faststart" else ""
            val concatCmd = "-y -f concat -safe 0 -i \"" + listFile.absolutePath +
                "\" -i \"" + segmentFiles[0].absolutePath + "\"" +
                " -map 0:v:0" + audioMap + metaArg + " -c copy -bsf:v dump_extra" + fastArg +
                " \"" + concatTarget + "\""
            commands.add(Pair(concatCmd, 1.0))

            if (twoStep) {
                // ---- phase 13 step two: the ONE finalize command ----
                // The lossless cut is assembled; re-encode it once with a
                // flag per changed option. Audio untouched -> -c:a copy;
                // video untouched (audio-only change) -> -c:v copy.
                val sb = StringBuilder("-y -i \"").append(concatTarget).append("\"")
                sb.append(" -map 0:v:0")
                if (planHasAudio && !audioMuted) sb.append(" -map 0:a:0")
                if (scaleFilter != null) sb.append(" -vf \"").append(scaleFilter).append("\"")
                if (fpsArg != null) sb.append(" ").append(fpsArg)
                sb.append(" ").append(if (needsVideoEncode) vEncSimple else "-c:v copy")
                if (planHasAudio && !audioMuted) sb.append(" ").append(aEncSimple)
                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(" \"").append(outputFilePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(1.0, totalSpanSec)))
            }
        } else if (twoStep) {
            // ---- separate files + changed settings: encode each cut ----
            for (i in segmentFiles.indices) {
                val spanMs = clips[i].trimEndMs - clips[i].trimStartMs
                val out = File(workDir, "out_" + i + outExt)
                val sb = StringBuilder("-y -i \"").append(segmentFiles[i].absolutePath).append("\"")
                sb.append(" -map 0:v:0")
                if (planHasAudio && !audioMuted) sb.append(" -map 0:a:0")
                if (scaleFilter != null) sb.append(" -vf \"").append(scaleFilter).append("\"")
                if (fpsArg != null) sb.append(" ").append(fpsArg)
                sb.append(" ").append(if (needsVideoEncode) vEncSimple else "-c:v copy")
                if (planHasAudio && !audioMuted) sb.append(" ").append(aEncSimple)
                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(" \"").append(out.absolutePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
                encodedOutFiles.add(out)
            }
        }''',
"1j concat + finalize")

# --------------------------------------------------------------- 1k outputs
must_replace(PLANNER,
r'''        val outputs = if (merged) listOf(outputFilePath) else segmentFiles.map { it.absolutePath }''',
r'''        val outputs = when {
            exportSeparateFiles && twoStep -> encodedOutFiles.map { it.absolutePath }
            exportSeparateFiles -> segmentFiles.map { it.absolutePath }
            else -> listOf(outputFilePath)
        }''',
"1k outputs list")

# ------------------------------------------------------------------- 1l log
must_replace(PLANNER,
r'''        Log.d(
            TAG,
            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                (if (merged) "" else ", separate mode") +
                (if (reencodeAll) ", simple re-encode mode (scale=" + (scaleFilter ?: "none") +
                    ", " + (fpsArg ?: "fps unchanged") + ")" else "")
        )''',
r'''        Log.d(
            TAG,
            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                (if (merged) "" else ", separate mode") +
                (if (twoStep) ", two-step (lossless cut + one finalize encode)" else "") +
                (if (perSegmentEncode) ", direct per-segment encode" else "")
        )''',
"1l plan log")
PYEOF
}

step1b
log "step1b: done"

###############################################################################
# Step 1c -- SmartExportPlanner.kt (new helpers)
###############################################################################
step1c() {
    log "step1c: SmartExportPlanner.kt -- simple encoder helpers"
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
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# ---------------------------------------- 1m simpleVideoEncoderArgs + audio args
must_replace(PLANNER,
r'''    /**
     * Pixel format for re-encode templates (phase 12): keep the common''',
r'''    /**
     * Phase 13 "one flag per changed option" video encoder string for the
     * simple commands (the two-step finalize command and the per-segment
     * direct encode). A same-as-input option writes NO flag: codec ->
     * -c:v with the source encoder family when unchanged; bitrate ->
     * -b:v only when the user set one (CRF-quality default otherwise, and
     * VP9/AV1 get constant-quality mode because their default 2-pass
     * bitrate is unusable); preset -> x264/x265 only (hardware / VP9 / AV1
     * encoders do not take -preset). -pix_fmt appears only when the source
     * format must be converted for the 8-bit encoders. -tag:v hvc1 keeps
     * HEVC files playable on Apple players (ignored by MKV).
     */
    private fun simpleVideoEncoderArgs(
        p: MediaParams,
        chosenCodec: String,
        bitrate: String,
        preset: String
    ): String {
        val enc = when {
            chosenCodec.isNotEmpty() -> chosenCodec
            p.vCodec == "hevc" -> "libx265"
            else -> "libx264"
        }
        val sb = StringBuilder("-c:v ").append(enc)
        if (enc == "libx265") sb.append(" -tag:v hvc1")
        if ((enc == "libx264" || enc == "libx265") &&
            p.pixFmt != "yuv420p" && p.pixFmt != "yuvj420p" &&
            p.pixFmt != "nv12" && p.pixFmt != "nv21"
        ) {
            sb.append(" -pix_fmt yuv420p")
        }
        when {
            bitrate.isNotEmpty() -> sb.append(" -b:v ").append(bitrate)
            enc == "libx264" -> sb.append(" -crf 18")
            enc == "libx265" -> sb.append(" -crf 20")
            enc == "libvpx-vp9" -> sb.append(" -crf 32 -b:v 0")
            enc == "libaom-av1" -> sb.append(" -crf 30 -b:v 0")
            else -> { /* hevc_mediacodec: encoder default bitrate */ }
        }
        if (preset.isNotEmpty() && (enc == "libx264" || enc == "libx265")) {
            sb.append(" -preset ").append(preset)
        }
        return sb.toString()
    }

    /**
     * Phase 13 audio encoder string: "-c:a copy" when both the codec and
     * the bitrate are same-as-input; otherwise the chosen encoder (the
     * source codec family when only the bitrate changed) with -b:a only
     * when the user set one. libopus re-encodes fine from any input rate
     * (ffmpeg auto-resamples to 48 kHz - lab validated).
     */
    private fun simpleAudioEncoderArgs(
        audioRef: MediaParams?,
        chosenCodec: String,
        audioBitrate: String
    ): String {
        if (chosenCodec.isEmpty() && audioBitrate.isEmpty()) return "-c:a copy"
        val enc = when {
            chosenCodec.isNotEmpty() -> chosenCodec
            audioRef?.aCodec == "mp3" -> "libmp3lame"
            else -> "aac"
        }
        val sb = StringBuilder("-c:a ").append(enc)
        if (audioBitrate.isNotEmpty()) sb.append(" -b:a ").append(audioBitrate)
        return sb.toString()
    }

    /**
     * Pixel format for the hybrid span re-encode (phase 12): keep the common''',
"1m simple encoder helpers")
PYEOF
}

step1c
log "step1c: done"

###############################################################################
# Step 2 -- ExportSettingsDialog.kt
###############################################################################
step2() {
    log "step2: ExportSettingsDialog.kt -- flag-contract preview + bitrate"
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
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# ------------------------------------------------------------- 2a header doc
must_replace(ESD,
r''' *  - Phase 11: resolution / FPS changes keep the smart path - the plan
 *    switches to the simple re-encode command (a scale / -r flag per
 *    changed option) with a lossless concat assembly.''',
r''' *  - Phase 11: resolution / FPS changes keep the smart path - the plan
 *    switches to the simple re-encode command (a scale / -r flag per
 *    changed option) with a lossless concat assembly; phase 13 extends
 *    it to the full flag contract:
 *  - Phase 13 (flag contract): a setting left on "Same as input" writes
 *    NO ffmpeg flag; keyframe cut + changed settings runs the lossless
 *    cut FIRST, then ONE finalize encode of the assembled cut; codec /
 *    bitrate / audio options map to -c:v / -b:v / -c:a / -b:a exactly;
 *    the video bitrate chip forwards "" (no -b:v) while it stays on
 *    "Same as input".''',
"2a header doc")

# --------------------------------------------------- 2b chosenBitrateString
must_replace(ESD,
r'''    private fun currentBitrateString(): String = "${effectiveVideoKbps()}k"''',
r'''    /** Phase 13: "" while the bitrate chip is on Same as input (no -b:v). */
    private fun chosenBitrateString(): String {
        if (bitrateSameAsInput) return ""
        val typed = etBitrate.text.toString().toIntOrNull()
        return if (typed != null && typed in 100..500000) typed.toString() + "k" else ""
    }''',
"2b chosenBitrateString helper")

must_replace(ESD,
r'''        viewModel.setExportSettings(selRes, selFps, snapAudioOnly, currentBitrateString())''',
r'''        viewModel.setExportSettings(selRes, selFps, snapAudioOnly, chosenBitrateString())''',
"2b refresh forwards empty bitrate")

# --------------------------------------------------------- 2c smartEncodeMode
must_replace(ESD,
r'''    /**
     * True when a resolution / fps / custom-size change switches the smart
     * plan to the simple re-encode template (phase 11): one command per
     * timeline segment with a scale / -r flag per changed option, followed
     * by the lossless concat assembly. Mirrors the planner's own logic.
     */
    private fun smartReencodeMode(a: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis): Boolean {
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
r'''    /**
     * True when ANY export setting differs from the source (phase 13 flag
     * contract): resolution / custom size / fps / video codec / video
     * bitrate / audio codec / audio bitrate. The plan then runs the simple
     * encode commands - one flag per changed option - instead of the pure
     * -c copy. Mirrors the planner's own logic (chosenBitrateString is ""
     * while the bitrate chip is on Same as input).
     */
    private fun smartEncodeMode(a: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis): Boolean {
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
            chosenBitrateString().isNotEmpty() || selCodec.isNotEmpty() ||
            selAudioBitrate.isNotEmpty() || selAudioCodec.isNotEmpty() ||
            (a.pixFmt != "yuv420p" && a.pixFmt != "yuvj420p" &&
                a.pixFmt != "nv12" && a.pixFmt != "nv21" && !selKeyframeCut && anyTrimmed)
    }''',
"2c smartEncodeMode")

# ------------------------------------------------ 2d buildSmartSummary call site
must_replace(ESD,
r'''        if (smartReencodeMode(a)) return buildSmartReencodeSummary(a)''',
r'''        if (smartEncodeMode(a)) return buildSmartEncodeSummary(a)''',
"2d encode summary call site")

# ------------------------------------------- 2e buildSmartSummary output format
must_replace(ESD,
r'''        val sb = StringBuilder()
        sb.append("ffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
        if (a.hasAudio) sb.append(" -map 0:a:0")
        if (selPreserveMetadata) sb.append(" -map_metadata 1")
        sb.append(" -c copy -bsf:v dump_extra")
        if (selFastStart) sb.append(" -movflags +faststart")
        sb.append(" output.mp4")''',
r'''        val outFmt = effectiveVideoFormat()
        val sb = StringBuilder()
        sb.append("ffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
        if (a.hasAudio) sb.append(" -map 0:a:0")
        if (selPreserveMetadata) sb.append(" -map_metadata 1")
        sb.append(" -c copy -bsf:v dump_extra")
        if (selFastStart && (outFmt == "mp4" || outFmt == "mov")) sb.append(" -movflags +faststart")
        sb.append(" output.").append(outFmt)''',
"2e pure-copy preview honors the container")
PYEOF
}

step2
log "step2: done"

###############################################################################
# Step 2b -- ExportSettingsDialog.kt (encode summary builder)
###############################################################################
step2b() {
    log "step2b: ExportSettingsDialog.kt -- the encode summary builder"
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
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# ------------------------------------------- 2f buildSmartEncodeSummary replaces
must_replace(ESD,
r'''    /**
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
            sb.append("\nffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
            if (a.hasAudio) sb.append(" -map 0:a:0")
            if (selPreserveMetadata) sb.append(" -map_metadata 1")
            sb.append(" -c copy -bsf:v dump_extra")
            if (selFastStart) sb.append(" -movflags +faststart")
            sb.append(" output.mp4")
        }
        sb.append("\n\n(smart export: ").append(a.clips.size)
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
    }''',
r'''    /**
     * Phase 13 preview of the commands the smart pipeline will run when a
     * setting changed: the exact flag list with one flag per CHANGED
     * option (same-as-input options write no flag). Keyframe cut (the
     * default) shows the two-step plan - the lossless cut commands plus
     * the ONE finalize encode of the assembled cut; Normal cut shows the
     * frame-accurate per-segment encode. Mirrors simpleVideoEncoderArgs /
     * simpleAudioEncoderArgs in the planner.
     */
    private fun buildSmartEncodeSummary(
        a: com.tharunbirla.librecuts.services.SmartExportPlanner.SmartAnalysis
    ): String {
        val customScale = customW >= 16 && customH >= 16
        val resChange = !customScale && selRes != 0 && selRes != a.displayHeight && selRes != a.shortSide
        val fpsChange = selFps != 0 && selFps != a.fpsRounded
        val vBitrate = chosenBitrateString()
        val scaleSpec: String = when {
            customScale -> "scale=" + (customW - customW % 2) + ":" + (customH - customH % 2) + ",setsar=1"
            resChange -> if (a.displayHeight >= a.displayWidth) "scale=" + selRes + ":-2,setsar=1" else "scale=-2:" + selRes + ",setsar=1"
            else -> ""
        }
        // ---- video flags (mirrors simpleVideoEncoderArgs) ----
        val vEnc = when {
            selCodec.isNotEmpty() -> selCodec
            a.vCodec == "hevc" -> "libx265"
            else -> "libx264"
        }
        val vFlags = StringBuilder("-c:v ").append(vEnc)
        if (vEnc == "libx265") vFlags.append(" -tag:v hvc1")
        when {
            vBitrate.isNotEmpty() -> vFlags.append(" -b:v ").append(vBitrate)
            vEnc == "libx264" -> vFlags.append(" -crf 18")
            vEnc == "libx265" -> vFlags.append(" -crf 20")
            vEnc == "libvpx-vp9" -> vFlags.append(" -crf 32 -b:v 0")
            vEnc == "libaom-av1" -> vFlags.append(" -crf 30 -b:v 0")
            else -> { }
        }
        if (selPreset.isNotEmpty() && (vEnc == "libx264" || vEnc == "libx265")) {
            vFlags.append(" -preset ").append(selPreset)
        }
        // ---- audio flags (mirrors simpleAudioEncoderArgs) ----
        val aFlags = if (selAudioCodec.isEmpty() && selAudioBitrate.isEmpty()) {
            "-c:a copy"
        } else {
            val enc = when {
                selAudioCodec.isNotEmpty() -> selAudioCodec
                a.aCodec == "mp3" -> "libmp3lame"
                else -> "aac"
            }
            if (selAudioBitrate.isNotEmpty()) "-c:a " + enc + " -b:a " + selAudioBitrate else "-c:a " + enc
        }
        val needsVideo = scaleSpec.isNotEmpty() || fpsChange ||
            vBitrate.isNotEmpty() || selCodec.isNotEmpty()
        val outFmt = effectiveVideoFormat()
        val outExt = "." + outFmt
        val fastOk = selFastStart && (outFmt == "mp4" || outFmt == "mov")

        val modeNote = if (selKeyframeCut) {
            if (selSeparateFiles) " separate files, each cut losslessly then encoded"
            else " segments - lossless cut first, then ONE encode of the assembled cut"
        } else {
            if (selSeparateFiles) " separate output files, all re-encoded"
            else " segments, all re-encoded (frame-accurate cuts)"
        }
        val sb = StringBuilder()
        if (selKeyframeCut) {
            // two-step: the lossless cut first, ONE finalize command after
            sb.append("ffmpeg -ss S -t D -i input -map 0:v:0")
            if (a.hasAudio) sb.append(" -map 0:a:0")
            sb.append(" -c copy -avoid_negative_ts make_zero seg_N.mp4   (lossless cut, one per segment)")
            if (!selSeparateFiles) {
                sb.append("\nffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
                if (a.hasAudio) sb.append(" -map 0:a:0")
                if (selPreserveMetadata) sb.append(" -map_metadata 1")
                sb.append(" -c copy -bsf:v dump_extra cut.mp4")
            }
            sb.append("\nffmpeg -i ").append(if (selSeparateFiles) "seg_N" else "cut.mp4")
            sb.append(" -map 0:v:0")
            if (a.hasAudio) sb.append(" -map 0:a:0")
            if (scaleSpec.isNotEmpty()) sb.append(" -vf \"").append(scaleSpec).append("\"")
            if (fpsChange) sb.append(" -r ").append(selFps)
            if (needsVideo) sb.append(" ").append(vFlags) else sb.append(" -c:v copy")
            if (a.hasAudio) sb.append(" ").append(aFlags)
            if (fastOk) sb.append(" -movflags +faststart")
            sb.append(" output").append(if (selSeparateFiles) "_N" else "").append(outExt)
        } else {
            sb.append("ffmpeg [-ss S] [-t D] -i input -map 0:v:0")
            if (a.hasAudio) sb.append(" -map 0:a:0")
            if (scaleSpec.isNotEmpty()) sb.append(" -vf \"").append(scaleSpec).append("\"")
            if (fpsChange) sb.append(" -r ").append(selFps)
            if (needsVideo) sb.append(" ").append(vFlags) else sb.append(" -c:v copy")
            if (a.hasAudio) sb.append(" ").append(aFlags)
            if (fastOk) sb.append(" -movflags +faststart")
            sb.append(" seg_N").append(outExt).append("   (frame-accurate, one per segment)")
            if (!selSeparateFiles) {
                sb.append("\nffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
                if (a.hasAudio) sb.append(" -map 0:a:0")
                if (selPreserveMetadata) sb.append(" -map_metadata 1")
                sb.append(" -c copy -bsf:v dump_extra")
                if (fastOk) sb.append(" -movflags +faststart")
                sb.append(" output").append(outExt)
            }
        }
        sb.append("\n\n(smart export: ").append(a.clips.size).append(modeNote)
        if (scaleSpec.isNotEmpty()) {
            if (customScale) {
                sb.append(" to ").append(customW - customW % 2).append("x").append(customH - customH % 2)
            } else {
                sb.append(" to ").append(selRes).append("p short side")
            }
        }
        if (fpsChange) sb.append(" @ ").append(selFps).append("fps")
        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) exported as straight cuts (no frame blending)")
        }
        sb.append(")")
        return sb.toString()
    }''',
"2f buildSmartEncodeSummary")

# ---------------------------------------------------- 2g smartEstimateBytes
must_replace(ESD,
r'''        if (smartReencodeMode(a)) {
            // Simple re-encode plan (phase 11): every second is re-encoded
            // at the chosen bitrate (no stream-copied parts).''',
r'''        if (smartEncodeMode(a)) {
            // Encode plan (phase 13): every second is re-encoded at the
            // chosen bitrate, or at the source-equivalent rate when the
            // bitrate chip stays on Same as input (CRF quality).''',
"2g smartEstimateBytes mode")
PYEOF
}

step2b
log "step2b: done"

###############################################################################
# Step 3 -- VideoEditingViewModel.kt + VideoEditingActivity.kt
###############################################################################
step3() {
    log "step3: ViewModel default bitrate + Activity comment fixes"
    python3 - <<'PYEOF'
import sys

VM = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(path, old, new, label):
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# --------------------------------------------------- 3a VM default bitrate
must_replace(VM,
r'''    private val _exportAudioOnly = MutableStateFlow(false)
    private val _exportBitrate = MutableStateFlow("8M")''',
r'''    private val _exportAudioOnly = MutableStateFlow(false)
    private val _exportBitrate = MutableStateFlow("")   // "" = same as input (no -b:v flag)''',
"3a VM default bitrate = same as input")

# ------------------------------------------------------ 3b VEA stale comments
must_replace(VEA,
r'''                // SMART EXPORT (phase 9): when the project is copy-compatible (only
                // trims / merges / freezes / transitions / mutes, all clips sharing the
                // same codec parameters), build a segment plan that stream-copies the
                // unchanged parts and only re-encodes the changed parts. Falls back to
                // the consolidated render below whenever the planner says null.''',
r'''                // SMART EXPORT (phase 9+): when the project is copy-compatible (only
                // trims / merges / freezes / transitions / mutes, all clips sharing the
                // same codec parameters), build a segment plan that stream-copies the
                // unchanged parts and only re-encodes the changed parts. When the
                // planner refuses, the real reason is surfaced below (phase 12);
                // changed export settings run the phase 13 flag contract
                // (lossless cut first, then ONE finalize encode).''',
"3b saveAction comment")

must_replace(VEA,
r'''                    Log.w(TAG, "Smart export planning failed, using consolidated render: ${e.message}", e)''',
r'''                    Log.w(TAG, "Smart export planning failed: ${e.message}", e)''',
"3b planning-failed log wording")
PYEOF
}

step3
log "step3: done"

###############################################################################
# Step 4 -- ExportService.kt (gallery save honors the real container)
###############################################################################
step4() {
    log "step4: ExportService.kt -- container-aware gallery save"
    python3 - <<'PYEOF'
import sys

SVC = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(path, old, new, label):
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# ------------------------------------------ 4a drop the isAudioOnly intent read
must_replace(SVC,
r'''        val durationSecs = intent.getDoubleExtra(EXTRA_TOTAL_DURATION_SECS, 0.0)
        val isAudioOnly = intent.getBooleanExtra(EXTRA_IS_AUDIO_ONLY, false)''',
r'''        val durationSecs = intent.getDoubleExtra(EXTRA_TOTAL_DURATION_SECS, 0.0)''',
"4a drop isAudioOnly extra read")

# ------------------------------------------------- 4b call sites (single file)
must_replace(SVC,
r'''                            val savedUri = saveVideoToGallery(filesToSave[0], isAudioOnly)''',
r'''                            val savedUri = saveVideoToGallery(filesToSave[0])''',
"4b single-file call site")

# --------------------------------------------- 4c call sites (separate files)
must_replace(SVC,
r'''                                val uri = saveVideoToGallery(f, false)''',
r'''                                val uri = saveVideoToGallery(f)''',
"4c separate-files call site")

# ------------------------------------------------------- 4d function rewrite
must_replace(SVC,
'''    private fun saveVideoToGallery(videoFile: File, isAudioOnly: Boolean): Uri? {
        val mimeType = if (isAudioOnly) "audio/mpeg" else "video/mp4"
        val ext = if (isAudioOnly) ".mp3" else ".mp4"
        val prefix = if (isAudioOnly) "Cutloss_Audio_" else "Cutloss_"
        
        val sharedPreferences = getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
        val prefKey = if (isAudioOnly) "export_audio_directory_uri" else "export_directory_uri"''',
'''    private fun saveVideoToGallery(videoFile: File): Uri? {
        // Phase 13: the smart plan can export MP4/MKV/MOV/WebM (and the
        // audio-only formats) - derive the gallery mime type, extension and
        // name prefix from the ACTUAL output file instead of assuming MP4.
        val ext = "." + videoFile.extension.lowercase()
        val isAudio: Boolean
        val mimeType: String
        val prefix: String
        when (ext) {
            ".mp3" -> { isAudio = true; mimeType = "audio/mpeg"; prefix = "Cutloss_Audio_" }
            ".m4a" -> { isAudio = true; mimeType = "audio/mp4"; prefix = "Cutloss_Audio_" }
            ".opus" -> { isAudio = true; mimeType = "audio/opus"; prefix = "Cutloss_Audio_" }
            ".flac" -> { isAudio = true; mimeType = "audio/flac"; prefix = "Cutloss_Audio_" }
            ".wav" -> { isAudio = true; mimeType = "audio/x-wav"; prefix = "Cutloss_Audio_" }
            ".mkv" -> { isAudio = false; mimeType = "video/x-matroska"; prefix = "Cutloss_" }
            ".mov" -> { isAudio = false; mimeType = "video/quicktime"; prefix = "Cutloss_" }
            ".webm" -> { isAudio = false; mimeType = "video/webm"; prefix = "Cutloss_" }
            ".avi" -> { isAudio = false; mimeType = "video/x-msvideo"; prefix = "Cutloss_" }
            else -> { isAudio = false; mimeType = "video/mp4"; prefix = "Cutloss_" }
        }

        val sharedPreferences = getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
        val prefKey = if (isAudio) "export_audio_directory_uri" else "export_directory_uri"''',
"4d saveVideoToGallery rewrite")

# ------------------------------------------- 4e isAudioOnly -> isAudio in body
must_replace(SVC,
r'''                if (isAudioOnly) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/Cutloss")
                } else {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Cutloss")
                }''',
r'''                if (isAudio) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/Cutloss")
                } else {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Cutloss")
                }''',
"4e relative path")

must_replace(SVC,
r'''            val collectionUri = if (isAudioOnly) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI''',
r'''            val collectionUri = if (isAudio) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI''',
"4e collection uri")
PYEOF
}

step4
log "step4: done"

###############################################################################
# Step 5 -- FFmpegRenderEngine.kt (hevc hardware fallback)
###############################################################################
step5() {
    log "step5: FFmpegRenderEngine.kt -- hevc_mediacodec fallback"
    python3 - <<'PYEOF'
import sys

ENGINE = "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def must_replace(path, old, new, label):
    s = rd(path)
    n = s.count(old)
    if n == 0:
        print("  [skip] " + label + " (already applied)")
        return
    if n > 1:
        sys.exit("  [ERROR] " + label + ": anchor not unique (" + str(n) + " matches)")
    wr(path, s.replace(old, new))
    print("  [ok] " + label)

# --------------------------------------------- 5a executeCommand fallback chain
must_replace(ENGINE,
r'''                        val fallbackCommand = command.replace("h264_mediacodec", "libx264")
                        return@withContext executeCommand(fallbackCommand, isRetry = true)
                    } else if (!isRetry && command.contains("libx264")) {''',
r'''                        val fallbackCommand = command.replace("h264_mediacodec", "libx264")
                        return@withContext executeCommand(fallbackCommand, isRetry = true)
                    } else if (!isRetry && command.contains("hevc_mediacodec")) {
                        Log.w(TAG, "Hardware encoder hevc_mediacodec failed. Falling back to software encoder libx265. Error:\n$diagnosticLog")
                        val fallbackCommand = command.replace("hevc_mediacodec", "libx265 -tag:v hvc1")
                        return@withContext executeCommand(fallbackCommand, isRetry = true)
                    } else if (!isRetry && command.contains("libx264")) {''',
"5a executeCommand hevc fallback")

# ----------------------------------------------- 5b exportFinal fallback chain
must_replace(ENGINE,
r'''                        val fallbackCommand = ffmpegCommand.replace("h264_mediacodec", "libx264")
                        return@withContext exportFinal(fallbackCommand, totalDurationSecs, onProgress, isRetry = true)
                    } else if (!isRetry && ffmpegCommand.contains("libx264")) {''',
r'''                        val fallbackCommand = ffmpegCommand.replace("h264_mediacodec", "libx264")
                        return@withContext exportFinal(fallbackCommand, totalDurationSecs, onProgress, isRetry = true)
                    } else if (!isRetry && ffmpegCommand.contains("hevc_mediacodec")) {
                        Log.w(TAG, "Hardware encoder hevc_mediacodec failed. Falling back to software encoder libx265. Error:\n$diagnosticLog")
                        val fallbackCommand = ffmpegCommand.replace("hevc_mediacodec", "libx265 -tag:v hvc1")
                        return@withContext exportFinal(fallbackCommand, totalDurationSecs, onProgress, isRetry = true)
                    } else if (!isRetry && ffmpegCommand.contains("libx264")) {''',
"5b exportFinal hevc fallback")
PYEOF
}

step5
log "step5: done"

###############################################################################
# Step 6 -- verification gate (runs BEFORE anything could be committed)
###############################################################################
step6() {
    log "step6: verification gate"
    python3 - <<'PYEOF'
import glob, subprocess, sys

FILES = {
    "PLANNER": "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt",
    "ESD":     "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt",
    "VM":      "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt",
    "VEA":     "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt",
    "SVC":     "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt",
    "ENGINE":  "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt",
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

errors = []

def check(cond, msg):
    if cond:
        print("  [pass] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)

# ---- THE permanent gate: no filter_complex anywhere in the app sources ----
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

# ---- deleted symbols must be gone ----
gone = {
    "PLANNER": ["encSimple", "reencodeAll", 'videoFormat != "mp4"',
                "custom codec requested", "non-MP4 container"],
    "ESD":     ["currentBitrateString", "smartReencodeMode", "buildSmartReencodeSummary"],
    "VM":      ['MutableStateFlow("8M")'],
    "SVC":     ["isAudioOnly", "saveVideoToGallery(videoFile: File, isAudioOnly"],
    "VEA":     ["using consolidated render"],
}
for key, toks in gone.items():
    s = rd(FILES[key])
    bad = [t for t in toks if t in s]
    check(not bad, key + ": stale symbols gone (%s)" % (", ".join(bad) if bad else "clean"))

# ---- new symbols with pinned counts ----
pinned = {
    "PLANNER": [
        ("simpleVideoEncoderArgs", 2),      # def + one call
        ("simpleAudioEncoderArgs", 2),      # def + one call
        ("aEncSilence", 2),                 # def + silence branch use
        ("encodedOutFiles", 3),             # def + add + map
        ("twoStep", 7),                     # mode + concat + finalize + separate + outputs + log
        ("perSegmentEncode", 4),            # mode + seg ext + branch + log
        ("nextSegmentFile(", 3),            # def + two call sites
        ('"-c:a copy"', 2),                 # simpleAudioEncoderArgs code + doc comment
        ("-crf 32 -b:v 0", 1),              # vp9 constant-quality default
        ("-crf 30 -b:v 0", 1),              # av1 constant-quality default
        ("-tag:v hvc1", 3),                 # hybrid + simple encoder + comment
        ("val aCodec: String,", 2),         # SmartAnalysis field + MediaParams field
        ('aCodec = audioRef?.aCodec ?: "",', 1),
        ("cut\" + segExt", 1),              # intermediate cut file
        ("out_\" + i + outExt", 1),         # separate-mode encoded output
    ],
    "ESD": [
        ("chosenBitrateString", 5),         # def + refresh + mode + summary + doc
        ("smartEncodeMode", 3),             # def + two call sites
        ("buildSmartEncodeSummary", 2),     # def + call site
        ('"-c:a copy"', 1),                 # audio flags mirror
        ("same-as-input options write no flag", 1),  # doc (lowercase variant)
        ("Same as input\" writes", 1),      # header doc fragment
    ],
    "VM": [
        ('_exportBitrate = MutableStateFlow("")', 1),
    ],
    "SVC": [
        ("saveVideoToGallery(videoFile: File): Uri?", 1),
        ("video/x-matroska", 1),
        ("video/quicktime", 1),
        ("video/webm", 1),
        ("video/x-msvideo", 1),
        ("audio/opus", 1),
    ],
    "ENGINE": [
        ("hevc_mediacodec failed. Falling back to software encoder libx265", 2),
        ("libx265 -tag:v hvc1", 2),
    ],
}
for key, toks in pinned.items():
    s = rd(FILES[key])
    for tok, want in toks:
        got = s.count(tok)
        check(got == want, key + ": '%s' count %d == %d" % (tok, got, want))

# ---- brace / paren balance deltas vs HEAD (all replacements are
#      complete blocks, so the net delta must be zero per file) ----
for key, p in FILES.items():
    h = head(p)
    if h is None:
        print("  [skip] " + key + ": no HEAD version (new file?)")
        continue
    if h == rd(p):
        print("  [skip] " + key + ": identical to HEAD")
        continue
    db = (rd(p).count("{") - rd(p).count("}")) - (h.count("{") - h.count("}"))
    dp = (rd(p).count("(") - rd(p).count(")")) - (h.count("(") - h.count(")"))
    check(db == 0 and dp == 0,
          key + ": brace/paren net delta vs HEAD is 0/0 (got %d/%d)" % (db, dp))

# ---- ASCII purity: the patch only ever inserts ASCII text, so the
#      non-ASCII char count must never INCREASE vs HEAD (VM/VEA/ENGINE
#      carry pre-existing non-ASCII from earlier phases) ----
for key, p in FILES.items():
    s = rd(p)
    h = head(p)
    now = sum(1 for c in s if ord(c) > 127)
    before = sum(1 for c in h if ord(c) > 127) if h is not None else now
    check(now <= before, key + ": non-ASCII count did not grow (%d -> %d)" % (before, now))

# ---- survival tokens: the phase 9-12 pipeline must still be intact ----
survive = {
    "PLANNER": ["fun planSmartExport(", "fun analyzeSmartExport(",
                "fun settingsBlockSmart(", "fun probeMedia(",
                "videoEncoderArgs(refParams", "audioEncoderArgs(audioRef",
                "encodablePixFmt(", "buildFreezeFrameCommands(",
                "-avoid_negative_ts make_zero", "-bsf:v dump_extra",
                "-map_metadata 1", "-movflags +faststart",
                "anullsrc=r=", "sweepStaleWorkDirs("],
    "ESD":     ["smartUnavailableNote()", "smartEstimateBytes()",
                "buildSmartSummary()", "wireChipRow("],
    "VEA":     ["planSmartExport(", "settingsBlockSmart(",
                "EXTRA_SMART_PLAN_PATH", "EXTRA_TEMP_OUTPUT_PATH",
                "getOutputExtension("],
    "SVC":     ["runSmartExport(", "parseSmartPlan(", "EXTRA_SMART_PLAN_PATH",
                "saveVideoToGallery("],
    "VM":      ["fun getOutputExtension(", "data class AdvancedExport("],
    "ENGINE":  ["suspend fun exportFinal(", "h264_mediacodec failed"],
}
for key, toks in survive.items():
    s = rd(FILES[key])
    bad = [t for t in toks if t not in s]
    check(not bad, key + ": survival tokens intact (%s)" %
          (", ".join(bad) if bad else "all present"))

if errors:
    sys.exit("[phase13][ERROR] gate failed with %d error(s)" % len(errors))
print("  [pass] all gates green")
PYEOF
}

###############################################################################
# Step 7 -- scope policy
###############################################################################
step7() {
    log "step7: scope policy"
    python3 - <<'PYEOF'
import subprocess, sys

ALLOWED = {
    "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt",
    "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt",
    "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt",
    "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt",
    "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt",
    "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt",
}
out = subprocess.run(["git", "status", "--porcelain"],
                     capture_output=True, text=True, check=True).stdout
dirty = []
for line in out.splitlines():
    if not line.strip():
        continue
    path = line[3:].strip().strip('"')
    dirty.append(path)
unexpected = [p for p in dirty if p not in ALLOWED]
if unexpected:
    sys.exit("[phase13][ERROR] unexpected dirty files outside the scope: " +
             ", ".join(unexpected))
print("  [pass] scope clean: %d file(s), all within the phase 13 allowlist" % len(dirty))

# .github policy: never touch CI/FUNDING/issue templates
out2 = subprocess.run(["git", "status", "--porcelain", ".github"],
                      capture_output=True, text=True, check=True).stdout
if out2.strip():
    sys.exit("[phase13][ERROR] .github files must never be modified")
print("  [pass] .github untouched")
PYEOF
}

step6
step7
log "phase 13 applied and verified"
