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
 * and the caller surfaces the real reason instead of re-encoding.
 *
 * Command templates validated against the bundled ffmpeg (Lavf 62 / ffmpeg
 * 6.1, ffmpeg-kit-full-gpl 2.1.0):
 *   full clip copy   : -y -noautorotate -i SRC -map 0:v:0 -map 0:a:0 -c copy SEG
 *   trim re-encode   : -y -noautorotate -ss S -t D -i SRC ... libx264 -profile -level
 *   freeze (2 steps) : PNG -> sensor-space encode, then -display_rotation remux
 *   concat           : -f concat -safe 0 -i list.txt -i seg0 [-map_metadata 1]
 *                      -c copy -bsf:v dump_extra [-movflags +faststart]
 *
 * Phase 10 additions:
 *   keyframe cut     : trimmed spans use INPUT seeking (-ss before -i), which
 *                      snaps to the preceding keyframe, so they are stream-
 *                      copied - 100% lossless, LosslessCut keyframe-cut
 *                      semantics (up to one GOP of extra head material)
 *   separate files   : one output file per timeline clip; the concat step
 *                      is skipped entirely
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
        val displayWidth: Int,
        val shortSide: Int,
        val fpsRounded: Int,
        val vCodec: String,
        val aCodec: String,
        val pixFmt: String,
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
     * reason when the current export settings cannot run in the simple
     * pipeline (there is no fallback render anymore), or null when they
     * can. Resolution / fps / custom-size changes are handled by the
     * simple re-encode plan (phase 11), so they never gate here.
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
        return null
    }

    private fun analyzeInternal(context: Context, project: VideoProject, sourceFilePath: String): SmartAnalysis {
        fun fail(reason: String): SmartAnalysis =
            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", "", "", reason)

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
        // Phase 12: stream copy does not care about the pixel format, so a
        // non-yuv420p source no longer blocks the smart path. Keyframe cuts
        // copy ANY format byte-exactly; trimmed-span re-encodes match the
        // source format (encodablePixFmt); only truly exotic formats (10-bit
        // and friends) switch the whole plan to the uniform re-encode.
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
                if (p.pixFmt != refParams.pixFmt) return fail("clips use different pixel formats")
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
            displayWidth = displayWidth,
            shortSide = Math.min(displayWidth, displayHeight),
            fpsRounded = Math.round(refParams.fpsValue).toInt(),
            vCodec = refParams.vCodec,
            aCodec = audioRef?.aCodec ?: "",
            pixFmt = refParams.pixFmt,
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
        sb.append(",format=").append(encodablePixFmt(params)).append("\"")
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
        if (videoFormat == "avi") return null
        if (videoFormat == "webm" &&
            advancedVideoCodec != "libvpx-vp9" && advancedVideoCodec != "libaom-av1") return null
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
                if (p.pixFmt != refParams.pixFmt) return null
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
        val segExt = if (videoFormat == "webm") ".mp4" else outExt

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
        // Phase 13 container gates (mirror settingsBlockSmart).
        if (videoFormat == "webm" && audioRef != null && advancedAudioCodec != "libopus") return null
        if ((advancedAudioCodec == "pcm_s16le" || advancedAudioCodec == "flac") &&
            (videoFormat == "mp4" || videoFormat == "mov")) return null
        val planHasAudio = audioRef != null
        val aRate = audioRef?.aSampleRate ?: 44100
        val aChanLabel = if ((audioRef?.aChannels ?: 2) == 1) "mono" else "stereo"

        // ---- phase 12: transitions export as straight cuts ----
        // The lossless pipeline never blends frames, so no transition
        // segments are rendered and no span is shortened: every clip is
        // simply its trim, and clips join end to start in the concat.
        val merged = !exportSeparateFiles   // single file vs one per clip
        for (i in clips.indices) {
            if (clips[i].trimEndMs <= clips[i].trimStartMs) return null
        }
        var totalSpanSec = 0.0
        for (c in clips) {
            totalSpanSec += Math.max(0.0, (c.trimEndMs - c.trimStartMs) / 1000.0)
        }

        // ---- build per-segment commands ----
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
        }

        for (i in clips.indices) {
            val clip = clips[i]
            val spanStart = clip.trimStartMs
            val spanEnd = clip.trimEndMs
            val spanMs = spanEnd - spanStart
            val fullRange = spanStart <= 60L && spanEnd >= clip.durationMs - 60L
            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
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
            } else if (fullRange) {
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

        }

        // ---- final assembly: concat with stream copy (merged mode only) ----
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
        }

        // ---- plan json (phase 10: object form; plain array = phase 9 plan) ----
        val arr = JSONArray()
        for (pair in commands) {
            val o = JSONObject()
            o.put("cmd", pair.first)
            o.put("weight", pair.second)
            arr.put(o)
        }
        val outputs = when {
            exportSeparateFiles && twoStep -> encodedOutFiles.map { it.absolutePath }
            exportSeparateFiles -> segmentFiles.map { it.absolutePath }
            else -> listOf(outputFilePath)
        }
        val planObj = JSONObject()
        planObj.put("separate", exportSeparateFiles)
        planObj.put("outputs", JSONArray(outputs))
        planObj.put("commands", arr)
        val planFile = File(workDir, "plan.json")
        planFile.writeText(planObj.toString())

        Log.d(
            TAG,
            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                (if (merged) "" else ", separate mode") +
                (if (twoStep) ", two-step (lossless cut + one finalize encode)" else "") +
                (if (perSegmentEncode) ", direct per-segment encode" else "")
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
            sb.append(" -pix_fmt ").append(encodablePixFmt(p))
            if (bitrate.isNotEmpty()) sb.append(" -b:v ").append(bitrate) else sb.append(" -crf 18")
            if (preset.isNotEmpty()) sb.append(" -preset ").append(preset)
            return sb.toString()
        }
        if (p.vCodec == "hevc") {
            val profile = if (p.vProfile.lowercase() == "main 10") "main10" else "main"
            val sb = StringBuilder("-c:v libx265 -profile:v ").append(profile)
            sb.append(" -tag:v hvc1 -pix_fmt ").append(encodablePixFmt(p))
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

    /**
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
     * Pixel format for the hybrid span re-encode (phase 12): keep the common
     * 8-bit 4:2:0 formats as-is so re-encoded segments stay concat-uniform
     * with stream-copied ones (yuvj420p keeps its full-range flag; nv12 and
     * nv21 are the same 4:2:0 bitstream once encoded). Anything more exotic
     * falls back to plain yuv420p and the encoder converts. Validated in the
     * ffmpeg lab: libx264/libx265 accept all four formats, and re-encoded
     * yuvj420p output keeps its pc range flag.
     */
    private fun encodablePixFmt(p: MediaParams): String =
        if (p.pixFmt == "yuvj420p" || p.pixFmt == "nv12" || p.pixFmt == "nv21") p.pixFmt else "yuv420p"

}
