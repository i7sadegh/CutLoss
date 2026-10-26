package com.tharunbirla.librecuts.services

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
 *   concat           : -f concat -safe 0 -i list.txt -i seg0 [-map_metadata 1]
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
        videoFormat: String,
        keyframeCut: Boolean,
        exportSeparateFiles: Boolean,
        movFastStart: Boolean,
        preserveMetadata: Boolean
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
            val dLeft = if (merged && i > 0) clampedTransitions[i - 1]?.second ?: 0L else 0L
            val dRight = if (merged && i < clips.size - 1) clampedTransitions[i]?.second ?: 0L else 0L
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
            } else if (keyframeCut) {
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

            // Transition segment that starts right after this clip (merged only)
            val trans = if (merged) clampedTransitions[i] else null
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

        // ---- final assembly: concat with stream copy (merged mode only) ----
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

        // ---- plan json (phase 10: object form; plain array = phase 9 plan) ----
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
