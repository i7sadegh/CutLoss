#!/usr/bin/env bash
###############################################################################
# CutLoss phase 9 -- Smart Export + Freeze fixes
#
# 1. FREEZE BUG FIX: when the playhead sits at the head of the FIRST clip and
#    the user taps Freeze, the generated freeze video was silently DISCARDED
#    (updateSequenceOrder(newItems.drop(1))) and the original main video was
#    trimmed to 3s instead - so the "frozen" segment played as normal video.
#    Fix: promote the freeze video to the MAIN video slot (same pattern as
#    deleteSelectedVideo) and demote the original main clip into the merge
#    list, so the sequence becomes [freeze][original][rest].
#
# 2. FREEZE CODEC MATCHING: the freeze segment is no longer encoded with
#    h264_mediacodec + arbitrary parameters. The source clip is probed with
#    FFprobeKit and the freeze video is encoded with the SAME codec
#    parameters (codec, profile, level, resolution, fps, pix fmt, rotation,
#    silent audio track matching the source audio) so the export pipeline can
#    STREAM-COPY it with -c copy.
#
# 3. OP-INDEX REALIGNMENT: inserting a freeze segment shifts the sequence, so
#    Transition (gap) indices and MuteClip indices are shifted accordingly
#    (previously they silently attached to the wrong clip boundaries).
#
# 4. SMART EXPORT: new SmartExportPlanner + ExportService smart mode. When the
#    project only contains copy-compatible operations (Trim / Merge /
#    Transition / MuteClip / MuteAudio, no text or image overlays, no speed,
#    no background audio, no custom resolution/fps/codec) and all clips share
#    the same codec parameters, the export becomes:
#      - unchanged clip parts        -> stream copy (-c copy)
#      - freeze segments             -> already-encoded matching videos, copied
#      - transition overlaps         -> rendered once (xfade offset=0 + acrossfade)
#                                       with matching parameters, then copied
#      - trim cuts                   -> only the trimmed span re-encoded
#      - final assembly              -> concat demuxer + -c copy -bsf:v dump_extra
#    Anything not copy-compatible falls back to the legacy consolidated
#    filter-graph render, which is left fully intact.
#
# Invariants: pure ASCII, idempotent (2nd run = all [skip], zero diff),
# hard verification gate exits 1 BEFORE anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase9] $*"; }
fail() { echo "[phase9][ERROR] $*" >&2; exit 1; }

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
EXT="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"
EXPS="app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

###############################################################################
# Step 0 -- preconditions + idempotency marker
###############################################################################
log "step0: checking preconditions"
[ -f "$VEA" ]  || fail "VideoEditingActivity.kt not found"
[ -f "$EXT" ]  || fail "VideoEditingViewModelExt.kt not found"
[ -f "$EXPS" ] || fail "ExportService.kt not found"
grep -q "private fun freezeFrameAtCurrentPosition()" "$VEA" \
  || fail "freezeFrameAtCurrentPosition not found (unexpected tree state)"
grep -q "buildConsolidatedFFmpegCommand(" "$VEA" \
  || fail "saveAction consolidated command call not found"
grep -q "ExportService.EXTRA_COMMAND" "$VEA" \
  || fail "saveAction ExportService wiring not found"
grep -q "EXTRA_CONCAT_FILE_PATH" "$EXPS" \
  || fail "ExportService extras not found (unexpected tree state)"
grep -q "fun VideoEditingViewModel.updateSequenceOrder" "$EXT" \
  || fail "Ext updateSequenceOrder not found (unexpected tree state)"
grep -q "ffmpeg-kit-full-gpl" app/build.gradle \
  || fail "ffmpeg-kit-full-gpl dependency not found (FFprobeKit required)"

if [ -f "$PLANNER" ]; then
  APPLIED=1
  log "step0: planner already present -> SKIP mode (idempotent re-run)"
else
  APPLIED=0
  log "step0: [ok] base tree confirmed"
fi

###############################################################################
# Step 1 -- add services/SmartExportPlanner.kt
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step1: [skip] SmartExportPlanner.kt already exists"
else
python3 <<'CUTPY'
import sys

def die(m):
    print("[phase9][ERROR] " + m)
    sys.exit(1)

PLANNER_PATH = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

CONTENT = r'''package com.tharunbirla.librecuts.services

import android.content.Context
import android.net.Uri
import android.util.Log
import com.antonkarpenko.ffmpegkit.FFmpegKitConfig
import com.antonkarpenko.ffmpegkit.FFprobeKit
import com.tharunbirla.librecuts.models.EditOperation
import com.tharunbirla.librecuts.models.VideoProject
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

/**
 * SmartExportPlanner builds a "smart render" export plan.
 *
 * Goal: when the timeline only contains operations that do not change the
 * stream parameters (trim, merge, freeze, transitions, mute), the unchanged
 * parts of the source clips are STREAM-COPIED (-c copy) into the output and
 * only the changed parts (freeze segments, transition overlaps, trim cuts)
 * are re-encoded with parameters that match the source clips. The final
 * assembly uses the concat demuxer with -c copy, so most of the output is
 * bit-exact with the original footage.
 *
 * If anything is not copy-compatible (mixed codecs, image clips, text or
 * image overlays, speed changes, background audio, custom resolution or
 * fps, ...) the planner returns null and the caller falls back to the
 * legacy consolidated filter-graph render.
 *
 * Command templates validated against the bundled ffmpeg (Lavf 62 / ffmpeg
 * 6.1, ffmpeg-kit-full-gpl 2.1.0):
 *   full clip copy   : -y -noautorotate -i SRC -map 0:v:0 -map 0:a:0 -c copy SEG
 *   trim re-encode   : -y -noautorotate -ss S -t D -i SRC ... libx264 -profile -level
 *   freeze (2 steps) : PNG -> sensor-space encode, then -display_rotation remux
 *   transition       : -ss tail / -ss head + xfade offset=0 (fps= filter needed
 *                      for CFR) + acrossfade
 *   concat           : -f concat -safe 0 -i list.txt -c copy -bsf:v dump_extra
 */
object SmartExportPlanner {

    private const val TAG = "SmartExportPlanner"

    data class MediaParams(
        val vCodec: String,
        val vProfile: String,
        val vLevel: Int,
        val width: Int,
        val height: Int,
        val fpsString: String,
        val fpsValue: Double,
        val pixFmt: String,
        val hasAudio: Boolean,
        val aCodec: String,
        val aSampleRate: Int,
        val aChannels: Int,
        val rotation: Int,
        val durationMs: Long
    )

    data class SmartPlan(val planFile: File)

    data class FreezeCommands(val commands: List<String>, val tempFiles: List<String>)

    // ------------------------------------------------------------------
    // Probing
    // ------------------------------------------------------------------

    /**
     * Probe a clip with FFprobeKit (codec params) + MediaMetadataRetriever
     * (rotation, duration). Returns null when probing fails - callers must
     * treat that as "not copy-compatible" and fall back gracefully.
     */
    fun probeMedia(context: Context, uri: Uri, path: String?): MediaParams? {
        val ffprobeArg = when {
            path != null -> path
            uri.scheme == "content" -> try {
                FFmpegKitConfig.getSafParameterForRead(context, uri)
            } catch (e: Exception) {
                Log.w(TAG, "getSafParameterForRead failed: " + e.message)
                null
            } ?: return null
            else -> uri.path ?: return null
        }

        val session = try {
            FFprobeKit.getMediaInformation(ffprobeArg)
        } catch (e: Exception) {
            Log.w(TAG, "ffprobe failed: " + e.message)
            null
        } ?: return null

        val info = try {
            session.getMediaInformation()
        } catch (e: Exception) {
            null
        } ?: return null

        val streams = try {
            info.getStreams()
        } catch (e: Exception) {
            null
        } ?: return null

        var video: JSONObject? = null
        var audio: JSONObject? = null
        for (s in streams) {
            val props = try {
                s.getAllProperties()
            } catch (e: Exception) {
                null
            } ?: continue
            val type = props.optString("codec_type", "")
            if (type == "video" && video == null) video = props
            if (type == "audio" && audio == null) audio = props
        }
        val v = video ?: return null

        var rotation = 0
        var durationMs = 0L
        try {
            val retriever = android.media.MediaMetadataRetriever()
            try {
                if (path != null) {
                    retriever.setDataSource(path)
                } else {
                    retriever.setDataSource(context, uri)
                }
                rotation = retriever.extractMetadata(
                    android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                durationMs = retriever.extractMetadata(
                    android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            } finally {
                retriever.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "MMR probe failed: " + e.message)
        }
        if (durationMs <= 0L) return null

        val fpsString = v.optString("avg_frame_rate", "0/0")
        val fpsValue = parseFraction(fpsString) ?: return null
        if (fpsValue <= 0.0) return null

        return MediaParams(
            vCodec = v.optString("codec_name", ""),
            vProfile = v.optString("profile", ""),
            vLevel = v.optInt("level", 0),
            width = v.optInt("width", 0),
            height = v.optInt("height", 0),
            fpsString = fpsString,
            fpsValue = fpsValue,
            pixFmt = v.optString("pix_fmt", ""),
            hasAudio = audio != null,
            aCodec = audio?.optString("codec_name", "") ?: "",
            aSampleRate = audio?.optInt("sample_rate", 0) ?: 0,
            aChannels = audio?.optInt("channels", 0) ?: 0,
            rotation = rotation,
            durationMs = durationMs
        )
    }

    private fun parseFraction(s: String): Double? {
        if (s.isEmpty() || s == "0/0") return null
        return try {
            if (s.contains("/")) {
                val parts = s.split("/")
                val num = parts[0].trim().toDouble()
                val den = parts[1].trim().toDouble()
                if (den == 0.0) null else num / den
            } else {
                s.trim().toDouble()
            }
        } catch (e: Exception) {
            null
        }
    }

    // ------------------------------------------------------------------
    // Freeze frame command builder
    // ------------------------------------------------------------------

    /**
     * Build the ffmpeg command(s) that turn the extracted freeze-frame PNG
     * (which is in DISPLAY orientation, like MediaMetadataRetriever returns
     * it) into a video whose stream parameters match the source clip. When
     * the source is rotated the PNG is transposed back to sensor space and
     * the rotation metadata is re-inserted with a -display_rotation remux.
     */
    fun buildFreezeFrameCommands(
        params: MediaParams,
        pngPath: String,
        finalOutPath: String,
        durationMs: Long
    ): FreezeCommands {
        val dSec = ms(durationMs)
        val audioOk = params.hasAudio && (params.aCodec == "aac" || params.aCodec == "mp3")
            && params.aSampleRate > 0
        val aChanLabel = if (params.aChannels == 1) "mono" else "stereo"
        val transpose = when (params.rotation) {
            90 -> "transpose=2,"
            180 -> "transpose=1,transpose=1,"
            270 -> "transpose=1,"
            else -> ""
        }
        val enc = videoEncoderArgs(params, "", "") ?: return FreezeCommands(emptyList(), emptyList())
        val aEnc = audioEncoderArgs(params, "")

        val sb = StringBuilder("-y -loop 1 -i \"").append(pngPath).append("\"")
        if (audioOk) {
            sb.append(" -f lavfi -t ").append(dSec)
            sb.append(" -i anullsrc=r=").append(params.aSampleRate).append(":cl=").append(aChanLabel)
        }
        sb.append(" -t ").append(dSec)
        sb.append(" -vf \"").append(transpose)
        sb.append("scale=").append(params.width).append(":").append(params.height)
        sb.append(",setsar=1,fps=").append(params.fpsString)
        sb.append(",format=yuv420p\"")
        sb.append(" -map 0:v:0")
        if (audioOk) sb.append(" -map 1:a:0")
        sb.append(" ").append(enc)
        if (audioOk) sb.append(" ").append(aEnc)

        if (params.rotation != 0) {
            val tmp = File(File(finalOutPath).parentFile, "freeze_tmp_" + System.nanoTime() + ".mp4")
            sb.append(" \"").append(tmp.absolutePath).append("\"")
            val rot = StringBuilder("-y -display_rotation:v ").append(-params.rotation)
            rot.append(" -i \"").append(tmp.absolutePath).append("\"")
            rot.append(" -map 0:v:0")
            if (audioOk) rot.append(" -map 0:a:0")
            rot.append(" -c copy \"").append(finalOutPath).append("\"")
            return FreezeCommands(listOf(sb.toString(), rot.toString()), listOf(tmp.absolutePath))
        }
        sb.append(" \"").append(finalOutPath).append("\"")
        return FreezeCommands(listOf(sb.toString()), emptyList())
    }

    // ------------------------------------------------------------------
    // Planning
    // ------------------------------------------------------------------

    fun planSmartExport(
        context: Context,
        project: VideoProject,
        sourceFilePath: String,
        outputFilePath: String,
        exportResolution: Int,
        exportFps: Int,
        exportBitrate: String,
        audioOnly: Boolean,
        advancedVideoCodec: String,
        advancedAudioCodec: String,
        advancedPreset: String,
        advancedAudioBitrate: String,
        customWidth: Int,
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
        } catch (e: Exception) {
            Log.w(TAG, "smart export planning failed: " + e.message, e)
            return null
        }
    }

    private fun planInternal(
        context: Context,
        project: VideoProject,
        sourceFilePath: String,
        outputFilePath: String,
        exportResolution: Int,
        exportFps: Int,
        exportBitrate: String,
        audioOnly: Boolean,
        advancedVideoCodec: String,
        advancedAudioCodec: String,
        advancedPreset: String,
        advancedAudioBitrate: String,
        customWidth: Int,
        customHeight: Int,
        videoFormat: String
    ): SmartPlan? {
        sweepStaleWorkDirs(context)

        if (audioOnly) return null
        if (videoFormat != "mp4") return null
        if (advancedVideoCodec.isNotEmpty() || advancedAudioCodec.isNotEmpty()) return null
        if (customWidth >= 16 || customHeight >= 16) return null
        if (isImagePath(sourceFilePath)) return null

        val ops = project.operations
        val allowed = ops.all {
            it is EditOperation.Trim || it is EditOperation.Merge ||
                it is EditOperation.Transition || it is EditOperation.MuteClip ||
                it is EditOperation.MuteAudio
        }
        if (!allowed) return null

        val mergeOp = ops.filterIsInstance<EditOperation.Merge>().firstOrNull()
        val trimOp = ops.filterIsInstance<EditOperation.Trim>().lastOrNull()
        val audioMuted = ops.any { it is EditOperation.MuteAudio }

        val workDir = File(context.cacheDir, "smart_export_" + System.currentTimeMillis())
        if (!workDir.mkdirs() && !workDir.isDirectory) return null

        // ---- probe the main clip (reference parameters) ----
        val refParams = probeMedia(context, Uri.fromFile(File(sourceFilePath)), sourceFilePath) ?: return null
        if (refParams.vCodec != "h264" && refParams.vCodec != "hevc") return null
        if (refParams.pixFmt != "yuv420p") return null
        if (refParams.width <= 0 || refParams.height <= 0) return null
        if (refParams.width % 2 != 0 || refParams.height % 2 != 0) return null
        if (refParams.durationMs <= 0L) return null

        val displayWidth = if (refParams.rotation == 90 || refParams.rotation == 270) {
            refParams.height
        } else {
            refParams.width
        }
        val displayHeight = if (refParams.rotation == 90 || refParams.rotation == 270) {
            refParams.width
        } else {
            refParams.height
        }
        val shortSide = Math.min(displayWidth, displayHeight)
        // Resolution is a no-op when it equals the display height or the short
        // side (a "1080" preset on a portrait 1080x1920 clip). Anything else
        // means the user asked for a real resize -> legacy render.
        if (exportResolution != 0 && exportResolution != displayHeight && exportResolution != shortSide) return null
        if (exportFps != 0 && exportFps != Math.round(refParams.fpsValue).toInt()) return null

        data class ClipInfo(
            val path: String,
            val params: MediaParams,
            val trimStartMs: Long,
            val trimEndMs: Long,
            val durationMs: Long,
            val muted: Boolean
        )

        // ---- resolve + probe all clips ----
        val clips = mutableListOf<ClipInfo>()
        clips.add(
            ClipInfo(
                path = sourceFilePath,
                params = refParams,
                trimStartMs = trimOp?.startMs ?: 0L,
                trimEndMs = trimOp?.endMs ?: refParams.durationMs,
                durationMs = refParams.durationMs,
                muted = isClipMuted(ops, 0)
            )
        )
        if (mergeOp != null) {
            for (item in mergeOp.items) {
                if (item.isImage) return null
                if (item.speed != 1.0f) return null
                if (item.proxyUri != null) return null
                val localPath: String? = if (item.uri.scheme == "content") {
                    copyToCache(context, item.uri, workDir)
                } else {
                    item.uri.path
                }
                if (localPath == null || isImagePath(localPath)) return null
                val p = probeMedia(context, item.uri, localPath) ?: return null
                if (p.vCodec != refParams.vCodec) return null
                if (!p.vProfile.equals(refParams.vProfile, ignoreCase = true)) return null
                if (p.width != refParams.width || p.height != refParams.height) return null
                if (p.rotation != refParams.rotation) return null
                if (p.fpsString != refParams.fpsString) return null
                if (p.pixFmt != "yuv420p") return null
                if (p.durationMs <= 0L) return null
                clips.add(
                    ClipInfo(
                        path = localPath,
                        params = p,
                        trimStartMs = item.trimStartMs.coerceIn(0L, p.durationMs),
                        trimEndMs = item.trimEndMs.coerceAtMost(p.durationMs),
                        durationMs = p.durationMs,
                        muted = isClipMuted(ops, clips.size)
                    )
                )
            }
        }

        // ---- audio reference ----
        val audioRef: MediaParams? = clips.firstOrNull { it.params.hasAudio }?.params
        if (audioRef != null) {
            if (audioRef.aCodec != "aac" && audioRef.aCodec != "mp3") return null
            if (audioRef.aSampleRate <= 0) return null
            if (audioRef.aChannels != 1 && audioRef.aChannels != 2) return null
        }
        if (audioRef != null) {
            for (c in clips) {
                if (c.params.hasAudio) {
                    if (c.params.aCodec != audioRef.aCodec) return null
                    if (c.params.aSampleRate != audioRef.aSampleRate) return null
                    if (c.params.aChannels != audioRef.aChannels) return null
                }
            }
        }
        val planHasAudio = audioRef != null
        val aRate = audioRef?.aSampleRate ?: 44100
        val aChanLabel = if ((audioRef?.aChannels ?: 2) == 1) "mono" else "stereo"

        // ---- transitions with clamped durations ----
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
        for (i in clips.indices) {
            val dLeft = if (i > 0) clampedTransitions[i - 1]?.second ?: 0L else 0L
            val dRight = if (i < clips.size - 1) clampedTransitions[i]?.second ?: 0L else 0L
            val start = clips[i].trimStartMs + dLeft
            val end = clips[i].trimEndMs - dRight
            if (end <= start) return null
        }

        // ---- build per-segment commands ----
        val commands = mutableListOf<Pair<String, Double>>()
        val segmentFiles = mutableListOf<File>()
        val enc = videoEncoderArgs(refParams, exportBitrate, advancedPreset) ?: return null
        val aEnc = audioEncoderArgs(audioRef, advancedAudioBitrate)
        val fpsFilter = "fps=" + refParams.fpsString

        var segCounter = 0
        fun nextSegmentFile(): File {
            val f = File(workDir, "seg_" + segCounter + ".mp4")
            segCounter++
            segmentFiles.add(f)
            return f
        }

        for (i in clips.indices) {
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
                // Whole clip unchanged -> pure stream copy remux
                val sb = StringBuilder("-y -noautorotate -i \"").append(clip.path).append("\"")
                if (silenceAudio) {
                    sb.append(" -f lavfi -t ").append(ms(spanMs))
                    sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                    sb.append(" -map 0:v:0 -map 1:a:0 -c:v copy ").append(aEnc)
                } else if (planHasAudio) {
                    sb.append(" -map 0:v:0 -map 0:a:0 -c copy")
                } else {
                    sb.append(" -map 0:v:0 -c copy")
                }
                sb.append(" \"").append(seg.absolutePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else {
                // Trimmed span -> re-encode ONLY this span with matching parameters
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
                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0")
                }
                sb.append(" -vf \"").append(fpsFilter).append(",setsar=1\" ")
                sb.append(enc)
                if (silenceAudio || planHasAudio) sb.append(" ").append(aEnc)
                sb.append(" \"").append(seg.absolutePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            }

            // Transition segment that starts right after this clip
            val trans = clampedTransitions[i]
            if (trans != null && i < clips.size - 1) {
                val type = trans.first
                val dMs = trans.second
                val right = clips[i + 1]
                val dSec = ms(dMs)
                val leftTailStart = ms(clip.trimEndMs - dMs)
                val rightHeadStart = ms(right.trimStartMs)
                val leftAudioReal = planHasAudio && clip.params.hasAudio && !clip.muted
                val rightAudioReal = planHasAudio && right.params.hasAudio && !right.muted
                val tSeg = nextSegmentFile()

                val sb = StringBuilder("-y -noautorotate -ss ").append(leftTailStart)
                sb.append(" -t ").append(dSec).append(" -i \"").append(clip.path).append("\"")
                sb.append(" -noautorotate -ss ").append(rightHeadStart)
                sb.append(" -t ").append(dSec).append(" -i \"").append(right.path).append("\"")

                var anullCounter = 2
                val leftALabel: String
                val rightALabel: String
                if (planHasAudio) {
                    if (leftAudioReal) {
                        leftALabel = "[0:a:0]"
                    } else {
                        sb.append(" -f lavfi -t ").append(dSec)
                        sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                        leftALabel = "[" + anullCounter + ":a:0]"
                        anullCounter++
                    }
                    if (rightAudioReal) {
                        rightALabel = "[1:a:0]"
                    } else {
                        sb.append(" -f lavfi -t ").append(dSec)
                        sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                        rightALabel = "[" + anullCounter + ":a:0]"
                        anullCounter++
                    }
                } else {
                    leftALabel = ""
                    rightALabel = ""
                }

                val filterParts = mutableListOf<String>()
                filterParts.add("[0:v:0]setpts=PTS-STARTPTS," + fpsFilter + "[lv]")
                filterParts.add("[1:v:0]setpts=PTS-STARTPTS," + fpsFilter + "[rv]")
                filterParts.add(
                    "[lv][rv]xfade=transition=" + sanitizeTransitionType(type) +
                        ":duration=" + dSec + ":offset=0[tv]"
                )

                if (planHasAudio) {
                    if (leftAudioReal && rightAudioReal) {
                        filterParts.add("[0:a:0]asetpts=PTS-STARTPTS[la]")
                        filterParts.add("[1:a:0]asetpts=PTS-STARTPTS[ra]")
                        filterParts.add("[la][ra]acrossfade=d=" + dSec + ":c1=tri:c2=tri[ta]")
                    } else if (leftAudioReal) {
                        filterParts.add("[0:a:0]asetpts=PTS-STARTPTS[la]")
                        filterParts.add(leftALabel + "asetpts=PTS-STARTPTS[sa]")
                        filterParts.add("[la][sa]acrossfade=d=" + dSec + ":c1=tri:c2=tri[ta]")
                    } else if (rightAudioReal) {
                        filterParts.add(leftALabel + "asetpts=PTS-STARTPTS[sa]")
                        filterParts.add("[1:a:0]asetpts=PTS-STARTPTS[ra]")
                        filterParts.add("[sa][ra]acrossfade=d=" + dSec + ":c1=tri:c2=tri[ta]")
                    }
                }

                sb.append(" -filter_complex \"").append(filterParts.joinToString(";")).append("\"")
                sb.append(" -map \"[tv]\"")
                if (planHasAudio) {
                    if (leftAudioReal || rightAudioReal) {
                        sb.append(" -map \"[ta]\"")
                    } else {
                        // Both sides silent: map the silence input directly
                        sb.append(" -map ").append(leftALabel)
                    }
                }
                sb.append(" ").append(enc)
                if (planHasAudio) sb.append(" ").append(aEnc)
                sb.append(" \"").append(tSeg.absolutePath).append("\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, dMs / 1000.0)))
            }
        }

        // ---- concat all segments with stream copy ----
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

        // ---- plan json ----
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
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private fun ms(v: Long): String = (v / 1000.0).toString()

    private fun isClipMuted(ops: List<EditOperation>, index: Int): Boolean {
        return ops.filterIsInstance<EditOperation.MuteClip>().any { it.index == index && it.isMuted }
    }

    private fun isImagePath(p: String): Boolean {
        val lower = p.lowercase()
        return lower.endsWith(".png") || lower.endsWith(".jpg") ||
            lower.endsWith(".jpeg") || lower.endsWith(".webp")
    }

    private fun copyToCache(context: Context, uri: Uri, workDir: File): String? {
        return try {
            val f = File(workDir, "src_" + System.nanoTime() + ".mp4")
            val input = context.contentResolver.openInputStream(uri) ?: return null
            val output = FileOutputStream(f)
            try {
                input.copyTo(output)
            } finally {
                input.close()
                output.close()
            }
            if (f.length() == 0L) {
                f.delete()
                return null
            }
            f.absolutePath
        } catch (e: Exception) {
            Log.w(TAG, "copyToCache failed: " + e.message)
            null
        }
    }

    private fun sweepStaleWorkDirs(context: Context) {
        try {
            val cache = context.cacheDir ?: return
            val cutoff = System.currentTimeMillis() - 2L * 60L * 60L * 1000L
            val dirs = cache.listFiles { file ->
                file.isDirectory && file.name.startsWith("smart_export_")
            } ?: return
            for (d in dirs) {
                if (d.lastModified() < cutoff) {
                    d.listFiles()?.forEach { it.delete() }
                    d.delete()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "sweep failed: " + e.message)
        }
    }

    private fun videoEncoderArgs(p: MediaParams, bitrate: String, preset: String): String? {
        if (p.vCodec == "h264") {
            val profile = when (p.vProfile.lowercase()) {
                "baseline", "constrained baseline" -> "baseline"
                "main" -> "main"
                "high 10" -> "high10"
                else -> "high"
            }
            val sb = StringBuilder("-c:v libx264 -profile:v ").append(profile)
            if (p.vLevel > 0) sb.append(" -level:v ").append(p.vLevel)
            sb.append(" -pix_fmt yuv420p")
            if (bitrate.isNotEmpty()) sb.append(" -b:v ").append(bitrate) else sb.append(" -crf 18")
            if (preset.isNotEmpty()) sb.append(" -preset ").append(preset)
            return sb.toString()
        }
        if (p.vCodec == "hevc") {
            val profile = if (p.vProfile.lowercase() == "main 10") "main10" else "main"
            val sb = StringBuilder("-c:v libx265 -profile:v ").append(profile)
            sb.append(" -tag:v hvc1 -pix_fmt yuv420p")
            if (bitrate.isNotEmpty()) sb.append(" -b:v ").append(bitrate) else sb.append(" -crf 20")
            if (preset.isNotEmpty()) sb.append(" -preset ").append(preset)
            return sb.toString()
        }
        return null
    }

    private fun audioEncoderArgs(audioRef: MediaParams?, audioBitrate: String): String {
        val codec = if (audioRef?.aCodec == "mp3") "libmp3lame" else "aac"
        val rate = audioRef?.aSampleRate ?: 44100
        val channels = audioRef?.aChannels ?: 2
        val sb = StringBuilder("-c:a ").append(codec)
        sb.append(" -ar ").append(rate)
        sb.append(" -ac ").append(channels)
        if (audioBitrate.isNotEmpty()) {
            sb.append(" -b:a ").append(audioBitrate)
        } else {
            sb.append(" -b:a 192k")
        }
        return sb.toString()
    }

    private val validXfadeTransitions = setOf(
        "fade", "fadeblack", "fadewhite", "rectcrop", "circlecrop", "circleclose", "circleopen",
        "horzclose", "horzopen", "vertclose", "vertopen", "diagbl", "diagbr", "diagtl", "diagtr",
        "hlslice", "hrslice", "vuslice", "vdslice", "dissolve", "pixelize", "slidedown", "slideleft",
        "slideright", "slideup", "wipedown", "wipeleft", "wiperight", "wipeup", "zoomin", "squeezeh",
        "squeezev", "coverleft", "coverright", "coverup", "coverdown", "revealleft", "revealright",
        "revealup", "revealdown"
    )

    fun sanitizeTransitionType(rawType: String): String {
        val raw = rawType.lowercase()
        return when (raw) {
            "smoothleft" -> "coverleft"
            "smoothright" -> "coverright"
            "distance" -> "zoomin"
            else -> if (validXfadeTransitions.contains(raw)) raw else "fade"
        }
    }
}
'''

with open(PLANNER_PATH, "w", encoding="utf-8") as f:
    f.write(CONTENT)
print("[phase9] step1: [ok] wrote SmartExportPlanner.kt (%d bytes)" % len(CONTENT))
CUTPY
fi

###############################################################################
# Step 2 -- VideoEditingViewModelExt.kt: add shiftSequenceOpIndices()
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step2: [skip] Ext already patched"
else
python3 <<'CUTPY'
import sys

def die(m):
    print("[phase9][ERROR] " + m)
    sys.exit(1)

EXT = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"

with open(EXT, encoding="utf-8") as f:
    s = f.read()

ANCHOR = "fun VideoEditingViewModel.removeMergeVideo(index: Int) {"
if s.count(ANCHOR) != 1:
    die("removeMergeVideo anchor count = %d (expected 1)" % s.count(ANCHOR))

NEWFUN = r'''/**
 * Keep Transition (gap) and MuteClip (position) op indices aligned with the
 * sequence after a freeze insertion changes the clip layout.
 *
 * gapFrom/gapBy   : old gap indices >= gapFrom shift by gapBy (a gap between
 *                   clips g and g+1 moves when an insertion lands at or after
 *                   the gap's left clip).
 * posFrom/posBy   : old clip positions >= posFrom shift by posBy.
 * splitMuteAt     : when the muted clip itself was split in two by the freeze
 *                   insertion, the mute is cloned onto both halves.
 */
fun VideoEditingViewModel.shiftSequenceOpIndices(
    gapFrom: Int,
    gapBy: Int,
    posFrom: Int,
    posBy: Int,
    splitMuteAt: Int = -1
) {
    executeCommand(MutateListCommand("Adjust Sequence Indices") { ops ->
        val result = mutableListOf<EditOperation>()
        for (op in ops) {
            when (op) {
                is EditOperation.Transition -> {
                    result.add(
                        if (op.index >= gapFrom) op.copy(index = op.index + gapBy) else op
                    )
                }
                is EditOperation.MuteClip -> {
                    if (op.index == splitMuteAt) {
                        result.add(op)
                        result.add(op.copy(index = op.index + posBy))
                    } else if (op.index >= posFrom) {
                        result.add(op.copy(index = op.index + posBy))
                    } else {
                        result.add(op)
                    }
                }
                else -> result.add(op)
            }
        }
        result
    })
}

'''

i = s.find(ANCHOR)
s = s[:i] + NEWFUN + s[i:]

with open(EXT, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase9] step2: [ok] shiftSequenceOpIndices added to Ext")
CUTPY
fi

###############################################################################
# Step 3 -- VideoEditingActivity.kt: rewrite freezeFrameAtCurrentPosition()
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step3: [skip] freeze function already rewritten"
else
python3 <<'CUTPY'
import sys

def die(m):
    print("[phase9][ERROR] " + m)
    sys.exit(1)

VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"

with open(VEA, encoding="utf-8") as f:
    s = f.read()

def replace_fun(s, header, newfun):
    i = s.find(header)
    if i < 0:
        die("replace_fun miss: " + header)
    if s.find(header, i + 1) >= 0:
        die("replace_fun duplicate header: " + header)
    j = s.find("{", i)
    if j < 0:
        die("replace_fun no opening brace: " + header)
    depth = 0
    k = j
    while k < len(s):
        c = s[k]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    if k >= len(s) or depth != 0:
        die("replace_fun unbalanced braces: " + header)
    end = k + 1
    if s[end:end + 1] == "\n":
        end += 1
    return s[:i] + newfun + s[end:]

NEWFREEZE = r'''    private fun freezeFrameAtCurrentPosition() {
        val index = selectedVideoIndex ?: return
        val sequenceItems = getSequenceItems()
        if (index < 0 || index >= sequenceItems.size) return
        val item = sequenceItems[index]

        showLoading("Creating freeze frame...")
        isImportLoading = true

        val globalPos = getGlobalPosition()

        lifecycleScope.launch {
            val resultUri = withContext(Dispatchers.IO) {
                var bitmap: android.graphics.Bitmap? = null
                val retriever = android.media.MediaMetadataRetriever()
                try {
                    retriever.setDataSource(this@VideoEditingActivity, item.uri)

                    var globalStartMs = 0L
                    for (i in 0 until index) {
                        globalStartMs += sequenceItems[i].trimmedDurationMs
                    }
                    val relativePosMs = globalPos - globalStartMs
                    val sourceTimeMs = item.trimStartMs + (relativePosMs * item.speed).toLong()
                    val coercedSourceTimeMs = sourceTimeMs.coerceIn(item.trimStartMs, item.trimEndMs)

                    bitmap = retriever.getFrameAtTime(coercedSourceTimeMs * 1000L, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to retrieve frame: ${e.message}", e)
                } finally {
                    try {
                        retriever.release()
                    } catch (e: Exception) {}
                }

                if (bitmap == null) return@withContext null

                val pngFile = File(cacheDir, "freeze_${System.nanoTime()}.png")
                try {
                    java.io.FileOutputStream(pngFile).use { out ->
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to save temp PNG: ${e.message}", e)
                    return@withContext null
                }

                val mp4File = File(cacheDir, "freeze_vid_${System.nanoTime()}.mp4")

                // SMART FREEZE (phase 9): encode the still frame with the SAME codec
                // parameters as the source clip (codec, profile, level, resolution,
                // fps, rotation, silent audio matching the source audio) so the smart
                // export pipeline can stream-copy this segment with -c copy.
                val srcParams = com.tharunbirla.librecuts.services.SmartExportPlanner.probeMedia(
                    this@VideoEditingActivity, item.uri, item.uri.path
                )
                var outUri: Uri? = null
                if (srcParams != null && (srcParams.vCodec == "h264" || srcParams.vCodec == "hevc")
                    && srcParams.pixFmt == "yuv420p" && srcParams.width > 0 && srcParams.height > 0) {
                    val freezeCmds = com.tharunbirla.librecuts.services.SmartExportPlanner.buildFreezeFrameCommands(
                        srcParams, pngFile.absolutePath, mp4File.absolutePath, 3000L
                    )
                    var ok = freezeCmds.commands.isNotEmpty()
                    for (cmd in freezeCmds.commands) {
                        val r = ffmpegEngine.executeCommand(cmd)
                        if (r !is com.tharunbirla.librecuts.services.FFmpegRenderEngine.RenderResult.Success) {
                            Log.e(TAG, "FFmpeg failed to create freeze frame video")
                            ok = false
                            break
                        }
                    }
                    for (tmpPath in freezeCmds.tempFiles) {
                        try { File(tmpPath).delete() } catch (e: Exception) {}
                    }
                    if (ok) outUri = Uri.fromFile(mp4File)
                }
                if (outUri == null) {
                    // Fallback: legacy hardware-encoder path (works, but not copy-compatible)
                    val cmd = "-y -loop 1 -i \"${pngFile.absolutePath}\" -c:v h264_mediacodec -t 3 -pix_fmt yuv420p -vf \"scale=trunc(iw/2)*2:trunc(ih/2)*2\" \"${mp4File.absolutePath}\""
                    val renderResult = ffmpegEngine.executeCommand(cmd)
                    if (renderResult is com.tharunbirla.librecuts.services.FFmpegRenderEngine.RenderResult.Success) {
                        outUri = Uri.fromFile(mp4File)
                    }
                }

                try { pngFile.delete() } catch (e: Exception) {}
                outUri
            }

            isImportLoading = false
            loadingScreen.visibility = View.GONE

            if (resultUri != null) {
                val freezeFrameItem = com.tharunbirla.librecuts.models.EditOperation.MergeItem(resultUri, 3000L)

                var globalStartMs = 0L
                for (i in 0 until index) {
                    globalStartMs += sequenceItems[i].trimmedDurationMs
                }
                val relativePosMs = globalPos - globalStartMs
                val splitSourceMs = item.trimStartMs + (relativePosMs * item.speed).toLong()

                val atHeadOfFirstClip = (index == 0 && splitSourceMs <= item.trimStartMs)

                if (atHeadOfFirstClip) {
                    // Phase-9 fix: the freeze frame lands at position 0 of the timeline.
                    // Promote the freeze video to the MAIN video slot and demote the current
                    // main clip into the merge list. Previously the freeze file was discarded
                    // (updateSequenceOrder(newItems.drop(1))) and the original main video was
                    // trimmed to 3s instead, so the "frozen" segment played as normal video.
                    tempInputFile = File(resultUri.path ?: resultUri.toString())
                    originalMainVideoDurationMs = 3000L
                    videoFileName = tempInputFile.name
                    videoUri = resultUri
                    viewModel.updateMainVideoTrim(0L, 3000L)
                    viewModel.updateMainVideoSpeed(1.0f, null)
                    // Whole old sequence shifts one slot to the right (freeze is the new main)
                    viewModel.shiftSequenceOpIndices(-1, 1, 0, 1)
                    viewModel.updateSequenceOrder(sequenceItems)
                    selectedVideoIndex = null
                    exitVideoEditingMode()
                } else {
                    val newItems = mutableListOf<com.tharunbirla.librecuts.models.EditOperation.MergeItem>()

                    for (i in 0 until sequenceItems.size) {
                        if (i == index) {
                            if (splitSourceMs > item.trimStartMs && splitSourceMs < item.trimEndMs) {
                                val itemA = item.copy(trimEndMs = splitSourceMs)
                                val itemB = item.copy(trimStartMs = splitSourceMs)
                                newItems.add(itemA)
                                newItems.add(freezeFrameItem)
                                newItems.add(itemB)
                            } else if (splitSourceMs <= item.trimStartMs) {
                                newItems.add(freezeFrameItem)
                                newItems.add(item)
                            } else {
                                newItems.add(item)
                                newItems.add(freezeFrameItem)
                            }
                        } else {
                            newItems.add(sequenceItems[i])
                        }
                    }

                    // Keep Transition / MuteClip op indices aligned with the new layout:
                    //  - main mid-split  : freeze lands at seq 1, second half at seq 2
                    //  - merge mid-split : freeze lands at seq index+1, second half at index+2
                    //  - insert before   : freeze takes the item's old position
                    //  - insert after    : freeze lands at seq index+1
                    if (index == 0) {
                        viewModel.shiftSequenceOpIndices(0, 2, 1, 2, 0)
                    } else if (splitSourceMs > item.trimStartMs && splitSourceMs < item.trimEndMs) {
                        viewModel.shiftSequenceOpIndices(index, 2, index + 1, 2, index)
                    } else if (splitSourceMs <= item.trimStartMs) {
                        viewModel.shiftSequenceOpIndices(index - 1, 1, index, 1)
                    } else {
                        viewModel.shiftSequenceOpIndices(index, 1, index + 1, 1)
                    }

                    selectedVideoIndex = null
                    exitVideoEditingMode()
                    if (newItems.isNotEmpty()) {
                        val primaryItem = newItems[0]
                        viewModel.updateMainVideoTrim(primaryItem.trimStartMs, primaryItem.trimEndMs)
                        viewModel.updateSequenceOrder(newItems.drop(1))
                    }
                }
                Toast.makeText(this@VideoEditingActivity, R.string.toast_freeze_frame_added_to_sequence, Toast.LENGTH_SHORT).show()
            } else {
                Toast.makeText(this@VideoEditingActivity, R.string.toast_failed_to_create_freeze_frame, Toast.LENGTH_SHORT).show()
            }
        }
    }
'''

s = replace_fun(s, "    private fun freezeFrameAtCurrentPosition() {", NEWFREEZE)

# sanity: old buggy pattern must be gone, new markers present
if "newItems.drop(1))" in s and "atHeadOfFirstClip" not in s:
    die("old freeze insertion logic still present")
if "atHeadOfFirstClip" not in s:
    die("new freeze promote branch missing")
if "buildFreezeFrameCommands" not in s:
    die("smart freeze encode missing")
if "shiftSequenceOpIndices" not in s:
    die("op index realignment missing")

with open(VEA, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase9] step3: [ok] freezeFrameAtCurrentPosition rewritten")
CUTPY
fi

###############################################################################
# Step 4 -- VideoEditingActivity.kt: smart-export hook in saveAction()
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step4: [skip] saveAction already hooked"
else
python3 <<'CUTPY'
import sys

def die(m):
    print("[phase9][ERROR] " + m)
    sys.exit(1)

VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"

with open(VEA, encoding="utf-8") as f:
    s = f.read()

ANCHOR = '''                val tempOutputPath = tempOutputFile.absolutePath

                var ffmpegCommand = viewModel.buildConsolidatedFFmpegCommand('''
if s.count(ANCHOR) != 1:
    die("saveAction anchor count = %d (expected 1)" % s.count(ANCHOR))

HOOK = r'''                val tempOutputPath = tempOutputFile.absolutePath

                // SMART EXPORT (phase 9): when the project is copy-compatible (only
                // trims / merges / freezes / transitions / mutes, all clips sharing the
                // same codec parameters), build a segment plan that stream-copies the
                // unchanged parts and only re-encodes the changed parts. Falls back to
                // the consolidated render below whenever the planner says null.
                val smartPlanPath = try {
                    withContext(kotlinx.coroutines.Dispatchers.IO) {
                        com.tharunbirla.librecuts.services.SmartExportPlanner.planSmartExport(
                            context = this@VideoEditingActivity,
                            project = project,
                            sourceFilePath = sourceFilePath,
                            outputFilePath = tempOutputPath,
                            exportResolution = viewModel.exportResolution.value,
                            exportFps = viewModel.exportFps.value,
                            exportBitrate = viewModel.exportBitrate.value,
                            audioOnly = isAudioOnly,
                            advancedVideoCodec = viewModel.advancedExport.value.videoCodec,
                            advancedAudioCodec = viewModel.advancedExport.value.audioCodec,
                            advancedPreset = viewModel.advancedExport.value.preset,
                            advancedAudioBitrate = viewModel.advancedExport.value.audioBitrate,
                            customWidth = viewModel.advancedExport.value.customWidth,
                            customHeight = viewModel.advancedExport.value.customHeight,
                            videoFormat = viewModel.advancedExport.value.videoFormat
                        )?.planFile?.absolutePath
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Smart export planning failed, using consolidated render: ${e.message}", e)
                    null
                }

                if (smartPlanPath != null) {
                    val intent = Intent(this@VideoEditingActivity, com.tharunbirla.librecuts.services.ExportService::class.java).apply {
                        putExtra(com.tharunbirla.librecuts.services.ExportService.EXTRA_SMART_PLAN_PATH, smartPlanPath)
                        putExtra(com.tharunbirla.librecuts.services.ExportService.EXTRA_TEMP_OUTPUT_PATH, tempOutputPath)
                        putExtra(com.tharunbirla.librecuts.services.ExportService.EXTRA_TOTAL_DURATION_SECS, getTotalSequenceDuration() / 1000.0)
                        putExtra(com.tharunbirla.librecuts.services.ExportService.EXTRA_IS_AUDIO_ONLY, false)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    Toast.makeText(this@VideoEditingActivity, "Export started in background...", Toast.LENGTH_SHORT).show()
                    return@launch
                }

                var ffmpegCommand = viewModel.buildConsolidatedFFmpegCommand('''

s = s.replace(ANCHOR, HOOK, 1)

if "SmartExportPlanner.planSmartExport" not in s:
    die("smart export hook missing after insert")
if s.count("EXTRA_SMART_PLAN_PATH") < 1:
    die("smart export service extras missing after insert")

with open(VEA, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase9] step4: [ok] saveAction smart-export hook inserted")
CUTPY
fi

###############################################################################
# Step 5 -- ExportService.kt: smart multi-command export mode
###############################################################################
if [ "$APPLIED" = "1" ]; then
  log "step5: [skip] ExportService already patched"
else
python3 <<'CUTPY'
import sys

def die(m):
    print("[phase9][ERROR] " + m)
    sys.exit(1)

EXPS = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"

with open(EXPS, encoding="utf-8") as f:
    s = f.read()

# 5a. new extra constant
A1 = '''        const val EXTRA_IS_AUDIO_ONLY = "extra_is_audio_only"'''
if s.count(A1) != 1:
    die("EXTRA_IS_AUDIO_ONLY anchor count = %d" % s.count(A1))
R1 = A1 + '''
        const val EXTRA_SMART_PLAN_PATH = "extra_smart_plan_path"'''
s = s.replace(A1, R1, 1)

# 5b. null-guard that accepts smart mode (no EXTRA_COMMAND)
A2 = '''        val command = intent.getStringExtra(EXTRA_COMMAND) ?: return START_NOT_STICKY'''
if s.count(A2) != 1:
    die("EXTRA_COMMAND guard anchor count = %d" % s.count(A2))
R2 = '''        val smartPlanPath = intent.getStringExtra(EXTRA_SMART_PLAN_PATH)
        val command = intent.getStringExtra(EXTRA_COMMAND)
        if (command == null && smartPlanPath == null) {
            return START_NOT_STICKY
        }'''
s = s.replace(A2, R2, 1)

# 5c. result computation branch
A3 = '''                val result = ffmpegEngine.exportFinal(
                    ffmpegCommand = command,
                    totalDurationSecs = durationSecs,
                    onProgress = { progress ->
                        updateNotification(progress, "Exporting...")
                        broadcastProgress(progress)
                    }
                )'''
if s.count(A3) != 1:
    die("exportFinal result block anchor count = %d" % s.count(A3))
R3 = '''                val result: FFmpegRenderEngine.RenderResult = when {
                    smartPlanPath != null -> runSmartExport(smartPlanPath)
                    command != null -> ffmpegEngine.exportFinal(
                        ffmpegCommand = command,
                        totalDurationSecs = durationSecs,
                        onProgress = { progress ->
                            updateNotification(progress, "Exporting...")
                            broadcastProgress(progress)
                        }
                    )
                    else -> FFmpegRenderEngine.RenderResult.Failure("No export command provided")
                }'''
s = s.replace(A3, R3, 1)

# 5d. cleanup of the smart work dir
A4 = '''                if (concatFile?.exists() == true) concatFile.delete()'''
if s.count(A4) != 1:
    die("concat cleanup anchor count = %d" % s.count(A4))
R4 = A4 + '''
                smartPlanPath?.let { sp ->
                    val smartWorkDir = File(sp).parentFile
                    if (smartWorkDir != null && smartWorkDir.exists()) {
                        smartWorkDir.listFiles()?.forEach { it.delete() }
                        smartWorkDir.delete()
                    }
                }'''
s = s.replace(A4, R4, 1)

# 5e. runSmartExport implementation
A5 = '''    private fun createNotificationChannel() {'''
if s.count(A5) != 1:
    die("createNotificationChannel anchor count = %d" % s.count(A5))
R5 = r'''    /**
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

        val totalWeight = commands.sumOf { it.second }.coerceAtLeast(0.001)
        var completedWeight = 0.0
        var lastResult: FFmpegRenderEngine.RenderResult =
            FFmpegRenderEngine.RenderResult.Failure("No commands executed")

        for (pair in commands) {
            val cmd = pair.first
            val weight = pair.second
            val base = completedWeight
            val result = ffmpegEngine.exportFinal(
                ffmpegCommand = cmd,
                totalDurationSecs = if (weight > 0.01) weight else null,
                onProgress = { pct ->
                    val overall = (((base + pct / 100.0 * weight) / totalWeight) * 100)
                        .toInt().coerceIn(0, 99)
                    updateNotification(overall, "Exporting...")
                    broadcastProgress(overall)
                }
            )
            if (result !is FFmpegRenderEngine.RenderResult.Success) {
                return result
            }
            completedWeight += weight
            lastResult = result
        }

        broadcastProgress(100)
        updateNotification(100, "Exporting...")
        return lastResult
    }

    private fun createNotificationChannel() {'''
s = s.replace(A5, R5, 1)

for marker in ["runSmartExport", "EXTRA_SMART_PLAN_PATH", "commands.sumOf"]:
    if marker not in s:
        die("ExportService marker missing after patch: " + marker)

with open(EXPS, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase9] step5: [ok] ExportService smart mode added")
CUTPY
fi

###############################################################################
# Step 6 -- hard verification gate (exits 1 BEFORE anything gets committed)
###############################################################################
log "step6: verification gate"

python3 <<'CUTPY'
import re, subprocess, sys

def die(m):
    print("[phase9][GATE-FAIL] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def head(p):
    r = subprocess.run(["git", "show", "HEAD:" + p],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

def fun_names(src):
    names = set()
    for m in re.finditer(r"\bfun\s+([A-Za-z0-9_]+)\s*\(", src):
        names.add(m.group(1))
    for m in re.finditer(r"\bfun\s+[A-Za-z0-9_.]+\.([A-Za-z0-9_]+)\s*\(", src):
        names.add(m.group(1))
    return names

def check_inventory(path, expected_removed, expected_added):
    old_src = head(path)
    if old_src is None:
        return  # new file (planner) or not comparable
    new_src = rd(path)
    old = fun_names(old_src)
    new = fun_names(new_src)
    removed = old - new
    added = new - old
    exp_rm = set(expected_removed)
    exp_ad = set(expected_added)
    if removed == exp_rm and added == exp_ad:
        return
    if not removed and not added:
        return  # already committed at HEAD (RUN 3)
    die("function inventory mismatch for %s:\n  unexpected removals: %s\n  unexpected additions: %s\n  missing removals: %s\n  missing additions: %s"
        % (path, sorted(removed - exp_rm), sorted(added - exp_ad),
           sorted(exp_rm - removed), sorted(exp_ad - added)))

VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
EXT = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"
EXPS = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

# freezeFrameAtCurrentPosition is REPLACED (same name) -> no inventory change;
# saveAction hook adds no function. Ext and ExportService gain exactly one each.
check_inventory(VEA, [], [])
check_inventory(EXT, [], ["shiftSequenceOpIndices"])
check_inventory(EXPS, [], ["runSmartExport"])

# ---- brace balance ----
for p in [VEA, EXT, EXPS]:
    new_src = rd(p)
    old_src = head(p)
    if old_src is not None and old_src.strip():
        do = old_src.count("{") - new_src.count("{")
        dc = old_src.count("}") - new_src.count("}")
        if do != dc:
            die("brace delta mismatch for %s (open removed %d, close removed %d)"
                % (p, do, dc))
    if new_src.count("{") != new_src.count("}"):
        die("unbalanced braces in %s (open %d, close %d)"
            % (p, new_src.count("{"), new_src.count("}")))

psrc = rd(PLANNER)
if psrc.count("{") != psrc.count("}"):
    die("unbalanced braces in %s (open %d, close %d)"
        % (PLANNER, psrc.count("{"), psrc.count("}")))
if psrc.count("(") != psrc.count(")"):
    die("unbalanced parens in %s (open %d, close %d)"
        % (PLANNER, psrc.count("("), psrc.count(")")))

print("[phase9] gate: inventory + brace checks passed")
CUTPY

# ---- positive marker checks (all new wiring must be present) ----
for t in "SmartExportPlanner.planSmartExport" "atHeadOfFirstClip" \
         "buildFreezeFrameCommands" "shiftSequenceOpIndices" \
         "EXTRA_SMART_PLAN_PATH" "runSmartExport"; do
    grep -rq -- "$t" app/src/main/java || fail "new phase-9 marker missing: $t"
done
grep -q "SmartExportPlanner.planSmartExport" "$VEA" || fail "VEA smart hook missing"
grep -q "atHeadOfFirstClip" "$VEA" || fail "VEA freeze promote branch missing"
grep -q "updateSequenceOrder(sequenceItems)" "$VEA" || fail "VEA freeze promote order update missing"
grep -q "fun VideoEditingViewModel.shiftSequenceOpIndices(" "$EXT" || fail "Ext shift function missing"
grep -q "private suspend fun runSmartExport(" "$EXPS" || fail "ExportService runSmartExport missing"
grep -q "const val EXTRA_SMART_PLAN_PATH" "$EXPS" || fail "ExportService smart extra missing"
log "gate: positive marker checks passed"

# ---- planner content checks ----
for t in "fun probeMedia(" "fun planSmartExport(" "fun buildFreezeFrameCommands(" \
         "anullsrc" "xfade=transition=" "acrossfade" "-f concat -safe 0" \
         "-bsf:v dump_extra" "libx264" "getMediaInformation" "getSafParameterForRead" \
         "sanitizeTransitionType"; do
    grep -q -- "$t" "$PLANNER" || fail "planner missing required piece: $t"
done
log "gate: planner content checks passed"

# ---- kept-feature survival asserts (legacy path must stay intact) ----
grep -q "private fun freezeFrameAtCurrentPosition()" "$VEA" || fail "freeze function lost"
[ "$(grep -c 'private fun freezeFrameAtCurrentPosition()' "$VEA")" = "1" ] || fail "freeze function duplicated"
grep -q "btnVideoFreezeFrame" "$VEA" || fail "freeze button wiring lost"
grep -q "freezeFrameAtCurrentPosition()" "$VEA" || fail "freeze button call lost"
grep -q "buildConsolidatedFFmpegCommand(" "$VEA" || fail "legacy consolidated call lost from VEA"
grep -q "fun buildConsolidatedFFmpegCommand(" "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt" || fail "legacy builder lost from VM"
grep -q "ffmpegEngine.exportFinal(" "$EXPS" || fail "legacy exportFinal branch lost"
grep -q "saveVideoToGallery" "$EXPS" || fail "gallery save flow lost"
grep -q "fun showTransitionDialog(" "$VEA" || fail "transition dialog lost"
grep -q "fun VideoEditingViewModel.updateMainVideoTrim(" "$EXT" || fail "updateMainVideoTrim lost"
grep -q "fun VideoEditingViewModel.updateSequenceOrder(" "$EXT" || fail "updateSequenceOrder lost"
grep -q "fun VideoEditingViewModel.updateMainVideoSpeed(" "$EXT" || fail "updateMainVideoSpeed lost"
grep -q "toast_freeze_frame_added_to_sequence" app/src/main/res/values/strings.xml || fail "freeze toast string lost"
grep -q "fun getSequenceItems()" "$VEA" || fail "getSequenceItems lost"
grep -q "fun getGlobalPosition()" "$VEA" || fail "getGlobalPosition lost"
log "gate: survival checks passed"

# ---- scope gate: only allowlisted files changed ----
python3 - <<'CUTPY'
import subprocess, sys

ALLOWED = {
    "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt",
    "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt",
    "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt",
    "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt",
    "scripts/apply-changes.sh",
    "apply-changes.sh",
}

out = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True).stdout
bad = []
gh = []
for line in out.splitlines():
    path = line[3:].strip().strip('"')
    if path.startswith(".github/"):
        gh.append(path)
    if path not in ALLOWED:
        bad.append(path)
if gh:
    print("[phase9][GATE-FAIL] .github policy violation: %s" % gh)
    sys.exit(1)
if bad:
    print("[phase9][GATE-FAIL] out-of-scope changes: %s" % bad)
    sys.exit(1)
print("[phase9] gate: scope ok (4 code files + script only, no .github/)")
CUTPY

# ---- ASCII self-check of this script ----
if LC_ALL=C tr -d '\t' < "$0" | LC_ALL=C grep -nq '[^ -~]'; then
    fail "script contains non-ASCII characters"
fi
log "gate: ASCII self-check passed"

log "ALL DONE -- phase 9 applied and verified"
