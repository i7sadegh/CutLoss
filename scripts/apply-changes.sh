#!/usr/bin/env bash
###############################################################################
# CutLoss phase 18 -- "the transition must not freeze the second video"
# (+ the export size estimate fix)
#
# User report (two issues):
#   1. "the transition part, where the first video finishes - for that
#      same time the second video stays FROZEN, then it plays. This must
#      be fixed."
#   2. "the approximate size shown in the export section is wrong."
#
# Root cause 1 (the freeze): the phase-16 model rendered the transition
# between TWO stills - the left clip's frozen last frame AND the right
# clip's frozen FIRST frame - so the second video sat frozen on screen
# for the whole transition and only started playing afterwards. The
# editor's live preview never does this: the player keeps PLAYING the
# second clip under the outgoing snapshot (TransitionPreviewOverlayView
# animates the left clip's frozen frame over the moving picture).
#
# Fix 1 (the dip model, matches the preview):
#   The transition segment is now built from the second clip's REAL,
#   PLAYING head frames - one MediaMetadataRetriever extraction per
#   output frame (OPTION_CLOSEST at the reference-rate grid) - with the
#   first clip's frozen LAST frame carrying the effect on top
#   (TransitionFrameRenderer draws each playing frame as the base
#   layer). The follow-on segment continues the second clip right after
#   the piece:
#     - per-segment-encode plans: hand-off at the exact effect end
#       (frame-accurate -ss).
#     - stream-copy / keyframe-cut / two-step plans: the piece BRIDGES
#       from the trim start to the first real keyframe at/after the
#       effect end (new compact probeNextKeyframeMs via FFprobeKit), so
#       the copied span starts exactly on that keyframe and never
#       replays transition material (a plain -ss would snap BACK to the
#       preceding keyframe). Degenerate keyframe windows (huge GOP or a
#       tiny remainder) hand off frame-accurately through the existing
#       matched re-encode branch instead.
#   Audio: the piece carries the second clip's REAL audio, stream-copied
#   with it (-ss S -t D -i clip2 -map 1:a:0; -c:a copy in the copy
#   plans, the re-encode form only inside encode plans with changed
#   audio settings) - the sound keeps playing through the transition
#   exactly like the preview. Silence only for muted / audio-less clips.
#   Timeline: the transition dips INTO the second clip's opening, so the
#   output duration is exactly the sum of the clip spans (the editor
#   timeline's own number - the phase-16 "+D per transition" is gone).
#
# Lab proof (ffmpeg 7.1.5, the user's own uploaded clips - ALL CHECKS
# PASS): [v1 whole copy] + [piece = v2's real frames 0..1.003s under
# v1's frozen last frame fading out, v2's real audio sample-exact] +
# [v2 copy from keyframe 1.003s] concat to 40.640s (= 20.501 + 20.139,
# NO +D), 1216 frames, uniform h264 High 1920x1080 yuvj420p tbn 1/90000
# aac 48k stereo, clean seam decodes, the piece's audio positioned
# sample-exactly at 20.501s and v2's continuation at 21.551s, last piece
# frame == v2 frame 29, first copied frame == the keyframe frame 30
# (adjacent, forward motion, no back-jump).
#
# Root cause 2 (the size estimate): probeSource() divided the FIRST
# file's byte size by durationMs - the dialog's WHOLE-timeline duration
# (every clip summed) - so srcKbps came out N times too small for an
# N-clip sequence and every size estimate with it (the reported case:
# ~49 MB estimated for a ~93 MB output).
#
# Fix 2: divide by the FILE's own duration (MediaMetadataRetriever
# METADATA_KEY_DURATION - the retriever is already open for the
# width/height probe), plus the estimate mirrors the new dip timeline:
# transition seconds MOVE from the copied to the re-encoded column and
# the encode-mode estimate no longer adds D per transition.
#
# 21 edits total. Idempotent: re-running skips every edit already
# present. Apply + build: upload as scripts/apply-changes.sh; the
# apply-and-build workflow runs it, commits the result and builds the
# APK (versionCode 16 / 1.0-beta11 - a strict upgrade over the
# installed 15).
###############################################################################
set -euo pipefail

RENDERER="app/src/main/java/com/tharunbirla/librecuts/services/TransitionFrameRenderer.kt"
PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
GRADLE="app/build.gradle"

for f in "$RENDERER" "$PLANNER" "$ESD" "$GRADLE"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 18: applying the playing-transition + size-estimate fixes =="

python3 - <<'PYEOF'
import sys
import subprocess

RENDERER = "app/src/main/java/com/tharunbirla/librecuts/services/TransitionFrameRenderer.kt"
PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
GRADLE = "app/build.gradle"

edits_applied = 0
edits_skipped = 0


def apply_edit(path, old, new, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    if new in s:
        edits_skipped += 1
        print("  [skip] " + name)
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
    print("  [ ok ] " + name)


# ===================== TransitionFrameRenderer.kt =====================

# ---- R1) object doc: the new model ----
apply_edit(RENDERER, """/**
 * Phase 16: rasterizes a freeze-frame transition into a numbered JPEG
 * frame sequence that the export pipeline encodes with ONE simple ffmpeg
 * command (image sequence -> matched encode; no filter graph).
 *
 * The transition model (the user's spec, same as the freeze feature):
 * the LAST frame of the left clip and the FIRST frame of the right clip
 * are frozen, the effect plays between those two stills for exactly the
 * transition duration, and the resulting small video is concatenated
 * between the two clips like any other segment.
 *
 * The per-type drawing is a faithful port of the editor's live preview
 * (TransitionPreviewOverlayView): the right clip's still is the base
 * layer and the left clip's still carries the effect, so the export
 * shows what the preview showed. Types the preview maps to a plain fade
 * (pixelize, distance, slices, smooth variants, ...) map to the same
 * fade here.
 */
""",
"""/**
 * Phase 16/18: rasterizes a transition into a numbered JPEG frame
 * sequence that the export pipeline encodes with ONE simple ffmpeg
 * command (image sequence -> matched encode; no filter graph).
 *
 * Phase 18 model (matches the editor's live preview): the LEFT clip
 * freezes into its LAST frame and that still carries the effect, while
 * the RIGHT clip keeps PLAYING underneath - the base layer of every
 * frame is the right clip's actual frame at that instant, extracted one
 * at a time by the planner. The transition therefore dips into the
 * second clip's opening: the effect completes, the second clip is
 * already playing, and the concat continues it seamlessly - no frozen
 * second video, no extra seconds added to the output.
 *
 * The per-type drawing is a faithful port of the editor's live preview
 * (TransitionPreviewOverlayView) - the outgoing snapshot transforms away
 * over the incoming, playing video. Types the preview maps to a plain
 * fade (pixelize, distance, slices, smooth variants, ...) map to the
 * same fade here.
 */
""",
"renderer: doc comment -> the dip model")

# ---- R2) renderTransitionFrames: per-frame playing base + effect ----
# ---- window ----
apply_edit(RENDERER, """    /**
     * Render [frameCount] frames of the transition [type] between [bmpA]
     * (the frozen last frame of the left clip) and [bmpB] (the frozen
     * first frame of the right clip) into [outDir] as frame_0000.jpg ..
     * frame_N-1.jpg at [outW] x [outH]. Returns false when a frame could
     * not be written; the caller then gives up the plan honestly.
     */
    fun renderTransitionFrames(
        type: String,
        bmpA: Bitmap,
        bmpB: Bitmap,
        outDir: File,
        frameCount: Int,
        outW: Int,
        outH: Int
    ): Boolean {
        if (outW <= 0 || outH <= 0 || frameCount < 2) return false
        if (bmpA.isRecycled || bmpB.isRecycled) return false
        if (outDir.exists() && !outDir.isDirectory) return false
        if (!outDir.exists() && !outDir.mkdirs()) return false
        val kind = type.lowercase()
        val bitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint()
        val path = Path()
        val srcA = Rect(0, 0, bmpA.width, bmpA.height)
        val srcB = Rect(0, 0, bmpB.width, bmpB.height)
        val dst = RectF(0f, 0f, outW.toFloat(), outH.toFloat())
        val w = outW.toFloat()
        val h = outH.toFloat()
        try {
            for (i in 0 until frameCount) {
                val progress = i.toFloat() / (frameCount - 1).toFloat()
                drawFrame(canvas, paint, path, kind, progress, bmpA, srcA, bmpB, srcB, dst, w, h)
                val file = File(outDir, "frame_" +
                    String.format(java.util.Locale.US, "%04d", i) + ".jpg")
                try {
                    FileOutputStream(file).use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
                    }
                } catch (e: Exception) {
                    return false
                }
            }
        } finally {
            bitmap.recycle()
        }
        return true
    }
""",
"""    /**
     * Render [frameCount] frames of the transition [type] into [outDir]
     * as frame_0000.jpg .. frame_N-1.jpg at [outW] x [outH]: frame i
     * draws [baseFrames](i) - the right clip's PLAYING frame i, returned
     * in display orientation and recycled right after drawing - with
     * [bmpA] (the frozen last frame of the left clip) carrying the
     * effect on top. The effect runs over the first [effectCount] frames
     * (progress 0 -> 1); any remaining frames are plain bridge material
     * (the right clip playing on, no overlay) the stream-copy plans use
     * to reach a keyframe hand-off. Returns false when a frame could not
     * be extracted or written; the caller then gives up the plan
     * honestly.
     */
    fun renderTransitionFrames(
        type: String,
        bmpA: Bitmap,
        baseFrames: (Int) -> Bitmap?,
        outDir: File,
        frameCount: Int,
        effectCount: Int,
        outW: Int,
        outH: Int
    ): Boolean {
        if (outW <= 0 || outH <= 0 || frameCount < 2) return false
        if (effectCount < 2) return false
        if (bmpA.isRecycled) return false
        if (outDir.exists() && !outDir.isDirectory) return false
        if (!outDir.exists() && !outDir.mkdirs()) return false
        val kind = type.lowercase()
        val bitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint()
        val path = Path()
        val srcA = Rect(0, 0, bmpA.width, bmpA.height)
        val dst = RectF(0f, 0f, outW.toFloat(), outH.toFloat())
        val w = outW.toFloat()
        val h = outH.toFloat()
        try {
            for (i in 0 until frameCount) {
                val bmpB = baseFrames(i)
                if (bmpB == null || bmpB.isRecycled) return false
                val srcB = Rect(0, 0, bmpB.width, bmpB.height)
                try {
                    val progress = if (i < effectCount) {
                        i.toFloat() / (effectCount - 1).toFloat()
                    } else {
                        1f
                    }
                    drawFrame(canvas, paint, path, kind, progress, i < effectCount,
                        bmpA, srcA, bmpB, srcB, dst, w, h)
                    val file = File(outDir, "frame_" +
                        String.format(java.util.Locale.US, "%04d", i) + ".jpg")
                    try {
                        FileOutputStream(file).use { out ->
                            bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
                        }
                    } catch (e: Exception) {
                        return false
                    }
                } finally {
                    try { bmpB.recycle() } catch (e: Exception) {}
                }
            }
        } finally {
            bitmap.recycle()
        }
        return true
    }
""",
"renderer: playing base layer + effect window")

# ---- R3) drawFrame: hasOverlay param + plain-bridge early return ----
apply_edit(RENDERER, """    private fun drawFrame(
        canvas: Canvas,
        paint: Paint,
        path: Path,
        kind: String,
        progress: Float,
        bmpA: Bitmap,
        srcA: Rect,
        bmpB: Bitmap,
        srcB: Rect,
        dst: RectF,
        w: Float,
        h: Float
    ) {
        paint.reset()
        paint.isAntiAlias = true
        paint.isFilterBitmap = true
        // Base layer: the right clip's still sits underneath (the live
        // preview plays the right clip under the transforming snapshot).
        canvas.drawBitmap(bmpB, srcB, dst, paint)
""",
"""    private fun drawFrame(
        canvas: Canvas,
        paint: Paint,
        path: Path,
        kind: String,
        progress: Float,
        hasOverlay: Boolean,
        bmpA: Bitmap,
        srcA: Rect,
        bmpB: Bitmap,
        srcB: Rect,
        dst: RectF,
        w: Float,
        h: Float
    ) {
        paint.reset()
        paint.isAntiAlias = true
        paint.isFilterBitmap = true
        // Base layer: the right clip's PLAYING frame sits underneath (the
        // live preview plays the right clip under the transforming
        // snapshot - phase 18 makes the export match it).
        canvas.drawBitmap(bmpB, srcB, dst, paint)
        if (!hasOverlay) {
            // bridge material past the effect window: the right clip
            // simply plays on with no overlay (the stream-copy plans
            // reach their keyframe hand-off through it)
            return
        }
""",
"renderer: drawFrame overlay gate")

# ---- R4) fadeblack/fadewhite comment follows the new model ----
apply_edit(RENDERER, """            "fadeblack", "fadewhite" -> {
                // dip through the color: first half fades the LEFT still
                // out to the color, second half fades the RIGHT still in
""",
"""            "fadeblack", "fadewhite" -> {
                // dip through the color: first half fades the LEFT still
                // out to the color, second half fades the RIGHT clip's
                // playing frames back in
""",
"renderer: color-dip comment")

# ===================== SmartExportPlanner.kt =====================

# ---- P1) transition clamp: the right span is the only constraint ----
apply_edit(PLANNER, """        for ((gap, td) in transitions) {
            if (gap < 0 || gap >= spans.size - 1) continue
            val leftDur = spans[gap].second - spans[gap].first
            val rightDur = spans[gap + 1].second - spans[gap + 1].first
            val maxD = Math.min(leftDur - 250L, rightDur - 250L)
            if (maxD < 200L) continue
            val d = Math.min(td.second, maxD)
            if (d >= 200L) out[gap] = d
        }
""",
"""        for ((gap, td) in transitions) {
            if (gap < 0 || gap >= spans.size - 1) continue
            // Phase 18: the transition dips into the RIGHT clip only -
            // the left clip plays untouched to its very end and merely
            // its last frame freezes as the effect layer - so the right
            // span is the only one that must fit the duration plus a
            // sane remainder.
            val rightDur = spans[gap + 1].second - spans[gap + 1].first
            val maxD = rightDur - 250L
            if (maxD < 200L) continue
            val d = Math.min(td.second, maxD)
            if (d >= 200L) out[gap] = d
        }
""",
"planner: transition clamp follows the right span only")

# ---- P2) output duration: no seconds added per transition ----
apply_edit(PLANNER, """        // Phase 16: each freeze-frame transition segment adds its duration.
        for (d in transitionDurations.values) {
            totalSpanSec += d / 1000.0
        }
""",
"""        // Phase 18: transitions dip into the FOLLOWING clip's opening -
        // the effect plays over that clip's real, playing frames and the
        // concat continues right after them - so the output duration is
        // exactly the sum of the clip spans and NO seconds are added per
        // transition anymore (the phase-16 stills model added D each).
""",
"planner: totalSpanSec no longer grows per transition")

# ---- P3) new helper: probe the next video keyframe ----
apply_edit(PLANNER, """    private fun fpsCloseEnough(a: Double, b: Double): Boolean {
        val tol = Math.max(0.5, Math.abs(b) * 0.02)
        return Math.abs(a - b) <= tol
    }

    // ------------------------------------------------------------------
    // Freeze frame command builder
    // ------------------------------------------------------------------
""",
"""    private fun fpsCloseEnough(a: Double, b: Double): Boolean {
        val tol = Math.max(0.5, Math.abs(b) * 0.02)
        return Math.abs(a - b) <= tol
    }

    /**
     * Phase 18: the first video keyframe at or after [minMs] (clip-file
     * time, milliseconds), searching no further than [maxMs]. The
     * stream-copy plans hand the follow-on segment off at a real keyframe
     * so the concat never replays transition material (a plain -ss copy
     * would snap BACK to the preceding keyframe and re-show it). Returns
     * null when the probe fails or no keyframe sits in the window - the
     * caller then falls back to a frame-accurate re-encode hand-off.
     */
    private fun probeNextKeyframeMs(path: String, minMs: Long, maxMs: Long): Long? {
        if (minMs > maxMs) return null
        val probeArg = "-v error -select_streams v:0 -show_entries packet=pts_time,flags " +
            "-of csv=print_section=0 \\"" + path + "\\""
        val out: String? = try {
            FFprobeKit.execute(probeArg).output
        } catch (e: Exception) {
            Log.w(TAG, "keyframe probe failed: " + e.message)
            null
        }
        if (out == null || out.isEmpty()) return null
        for (line in out.split("\\n")) {
            val parts = line.trim().split(",")
            if (parts.size < 2) continue
            if (!parts[1].contains("K")) continue
            val sec = parts[0].toDoubleOrNull() ?: continue
            val tMs = Math.round(sec * 1000.0)
            if (tMs >= minMs && tMs <= maxMs) return tMs
        }
        return null
    }

    // ------------------------------------------------------------------
    // Freeze frame command builder
    // ------------------------------------------------------------------
""",
"planner: probeNextKeyframeMs helper")

# ---- P4) hand-off bookkeeping the transition fills, the loop reads ----
apply_edit(PLANNER, """        var segCounter = 0
        fun nextSegmentFile(ext: String): File {
            val f = File(workDir, "seg_" + segCounter + ext)
            segCounter++
            segmentFiles.add(f)
            return f
        }
""",
"""        var segCounter = 0
        fun nextSegmentFile(ext: String): File {
            val f = File(workDir, "seg_" + segCounter + ext)
            segCounter++
            segmentFiles.add(f)
            return f
        }
        // Phase 18 hand-off bookkeeping, filled by
        // addFreezeTransitionSegment: a transition into clip i consumes
        // [trimStartMs, pieceHandoffMs[i]] of it (the piece renders that
        // opening under the effect), and spanReencode marks clips whose
        // keyframe window was degenerate - those hand off frame-accurately
        // through the matched re-encode branch instead of a copied span.
        val pieceHandoffMs = mutableMapOf<Int, Long>()
        val spanReencode = mutableMapOf<Int, Boolean>()
""",
"planner: hand-off bookkeeping maps")

# ---- P5) the transition piece itself: playing base, real audio, ----
# ---- keyframe hand-off ----
apply_edit(PLANNER, """        fun addFreezeTransitionSegment(gap: Int, dMs: Long): Boolean {
            val left = clips[gap]
            val right = clips[gap + 1]
            val type = transitionsRaw[gap]?.first ?: "fade"
            val frameCount = Math.max(2, Math.round(dMs / 1000.0 * transFpsValue).toInt())
            val dSec = frameCount / transFpsValue
            // last displayed frame of the left clip, first of the right one
            val endA = extractBoundaryFrame(
                left.path, (left.trimEndMs - 1L).coerceAtLeast(left.trimStartMs)
            )
            val startB = extractBoundaryFrame(right.path, right.trimStartMs)
            if (endA == null || startB == null) return false
            val framesDir = File(workDir, "trans_" + gap)
            if (!TransitionFrameRenderer.renderTransitionFrames(
                    type, endA, startB, framesDir, frameCount, displayWidth, displayHeight
                )
            ) return false
            // encoder spec mirrors whatever the neighbouring segments use:
            // the matched source encoder next to stream-copied segments,
            // the one-flag-per-option encoder inside the encode plans.
            val transVEnc = if (perSegmentEncode) vEncSimple else enc
            val transAEnc = if (perSegmentEncode && (aCodecSet || aBitrateSet)) aEncSimple else aEnc
""",
"""        fun addFreezeTransitionSegment(gap: Int, dMs: Long): Boolean {
            val left = clips[gap]
            val right = clips[gap + 1]
            val type = transitionsRaw[gap]?.first ?: "fade"
            // Phase 18: the transition dips into the RIGHT clip's opening,
            // exactly like the editor preview plays it - the right clip's
            // real, playing frames are the base layer and the LEFT clip's
            // frozen last frame carries the effect on top. The follow-on
            // segment continues the right clip right after the piece, so
            // the second video is never frozen and the output gains no
            // extra seconds. Stream-copy plans hand the follow-on segment
            // off at a real keyframe: the piece bridges from the trim
            // start to the first keyframe at/after the effect end (plain
            // playing material once the effect finishes), so the copied
            // span starts exactly on that keyframe and never replays
            // transition material. Encode plans are frame-accurate and
            // need no bridge.
            var pieceEndMs = right.trimStartMs + dMs
            var reencodeRight = false
            if (!perSegmentEncode) {
                val kf = probeNextKeyframeMs(
                    right.path, right.trimStartMs + dMs,
                    Math.min(right.trimStartMs + dMs + 3000L, right.trimEndMs - 100L)
                )
                if (kf != null && right.trimEndMs - kf >= 100L) {
                    pieceEndMs = kf
                } else {
                    // no usable keyframe in the window (huge GOP or a tiny
                    // remainder): hand off frame-accurately instead - the
                    // right clip's span re-encodes through the existing
                    // matched re-encode branch
                    reencodeRight = true
                }
            }
            pieceHandoffMs[gap + 1] = pieceEndMs
            spanReencode[gap + 1] = reencodeRight
            val pieceMs = Math.max(200L, pieceEndMs - right.trimStartMs)
            val frameCount = Math.max(2, Math.round(pieceMs / 1000.0 * transFpsValue).toInt())
            val effectCount = Math.max(2, Math.round(dMs / 1000.0 * transFpsValue).toInt())
            val dSec = frameCount / transFpsValue
            // the effect layer: the left clip's frozen last frame
            val endA = extractBoundaryFrame(
                left.path, (left.trimEndMs - 1L).coerceAtLeast(left.trimStartMs)
            ) ?: return false
            // the base layer: the right clip's PLAYING frames, one
            // extraction per output frame on the reference-rate grid
            // (OPTION_CLOSEST = the frame nearest that instant, exactly
            // what the player shows under the preview overlay)
            val rightStartMs = right.trimStartMs
            val framesDir = File(workDir, "trans_" + gap)
            val renderOk = TransitionFrameRenderer.renderTransitionFrames(
                type, endA,
                { i ->
                    extractBoundaryFrame(
                        right.path,
                        rightStartMs + Math.round(i * 1000.0 / transFpsValue)
                    )
                },
                framesDir, frameCount, effectCount, displayWidth, displayHeight
            )
            try { endA.recycle() } catch (e: Exception) {}
            if (!renderOk) return false
            // encoder spec mirrors whatever the neighbouring segments use:
            // the matched source encoder next to stream-copied segments,
            // the one-flag-per-option encoder inside the encode plans.
            val transVEnc = if (perSegmentEncode) vEncSimple else enc
            // Phase 18 audio: the piece carries the right clip's REAL
            // audio, stream-copied with it (the sound keeps playing
            // through the transition, exactly like the preview); the
            // re-encode form only inside the encode plans with changed
            // audio settings. Generated silence just for a muted or
            // audio-less right clip.
            val realAudio = planHasAudio && right.params.hasAudio && !right.muted
            val pieceAEnc = if (realAudio) {
                if (perSegmentEncode && (aCodecSet || aBitrateSet)) aEncSimple else "-c:a copy"
            } else {
                aEncSilence
            }
""",
"planner: transition piece head (dip model)")

# ---- P5b) the piece command: real audio input instead of anullsrc ----
apply_edit(PLANNER, """            val sb = StringBuilder("-y -framerate ").append(transFpsSpec)
                .append(" -start_number 0 -i \\"")
                .append(framesDir.absolutePath).append("/frame_%04d.jpg\\"")
            if (planHasAudio) {
                sb.append(" -f lavfi -t ")
                    .append(String.format(java.util.Locale.US, "%.6f", dSec))
                sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
            }
            sb.append(" -map 0:v:0")
            if (planHasAudio) sb.append(" -map 1:a:0")
            sb.append(" -vf \\"").append(vf).append("\\"")
            sb.append(" ").append(transVEnc)
            if (planHasAudio) sb.append(" ").append(transAEnc)
""",
"""            val sb = StringBuilder("-y -framerate ").append(transFpsSpec)
                .append(" -start_number 0 -i \\"")
                .append(framesDir.absolutePath).append("/frame_%04d.jpg\\"")
            if (realAudio) {
                // the right clip's real audio rides the piece (stream copy
                // in the copy plans) - seamless into the follow-on segment
                if (rightStartMs > 0L) sb.append(" -ss ").append(ms(rightStartMs))
                sb.append(" -t ").append(String.format(java.util.Locale.US, "%.6f", dSec))
                sb.append(" -i \\"").append(right.path).append("\\"")
            } else if (planHasAudio) {
                sb.append(" -f lavfi -t ")
                    .append(String.format(java.util.Locale.US, "%.6f", dSec))
                sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
            }
            sb.append(" -map 0:v:0")
            if (planHasAudio) sb.append(" -map 1:a:0")
            sb.append(" -vf \\"").append(vf).append("\\"")
            sb.append(" ").append(transVEnc)
            if (planHasAudio) sb.append(" ").append(pieceAEnc)
""",
"planner: transition piece audio + encoder args")

# ---- P6) the clip loop: spans continue from the hand-off point ----
apply_edit(PLANNER, """        for (i in clips.indices) {
            val clip = clips[i]
            val spanStart = clip.trimStartMs
            val spanEnd = clip.trimEndMs
            val spanMs = spanEnd - spanStart
            val fullRange = spanStart <= 60L && spanEnd >= clip.durationMs - 60L
            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
""",
"""        for (i in clips.indices) {
            val clip = clips[i]
            // Phase 18: an incoming transition consumed this clip's head
            // (the piece played its real opening under the effect); the
            // segment continues from the hand-off point. Copy plans hand
            // off at the probed keyframe, encode plans at the exact
            // effect end, and a degenerate keyframe window hands off
            // frame-accurately through the matched re-encode branch.
            val handoffMs = pieceHandoffMs[i]
            val spanStart = handoffMs ?: clip.trimStartMs
            val spanEnd = clip.trimEndMs
            val spanMs = spanEnd - spanStart
            val fullRange = handoffMs == null &&
                spanStart <= 60L && spanEnd >= clip.durationMs - 60L
            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
""",
"planner: clip spans follow the transition hand-off")

# ---- P7) whole-clip copy branch: only without a re-encode hand-off ----
apply_edit(PLANNER, """            } else if (fullRange) {
""",
"""            } else if (spanReencode[i] != true && fullRange) {
""",
"planner: fullRange branch gated on spanReencode")

# ---- P8) keyframe-cut branch: only without a re-encode hand-off ----
apply_edit(PLANNER, """            } else if (keyframeCut) {
""",
"""            } else if (spanReencode[i] != true && keyframeCut) {
""",
"planner: keyframeCut branch gated on spanReencode")

# ---- P9) log line wording ----
apply_edit(PLANNER, """                (if (hasTransitions) ", " + transitionDurations.size + " freeze-frame transition(s)" else "")
""",
"""                (if (hasTransitions) ", " + transitionDurations.size + " dip transition(s)" else "")
""",
"planner: log wording")

# ===================== ExportSettingsDialog.kt =====================

# ---- E1) size estimate root cause: the FILE's own duration ----
apply_edit(ESD, """    private fun probeSource() {
        val f = sourceFile ?: return
        if (!f.exists()) return
        try {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(f.absolutePath)
                var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
                srcW = w
                srcH = h
            } finally { r.release() }
        } catch (_: Exception) { }
        val durSec = durationMs / 1000.0
        if (durSec > 0 && f.length() > 0) {
            srcKbps = (f.length() * 8.0 / 1000.0 / durSec).toInt()
        }
    }
""",
"""    private fun probeSource() {
        val f = sourceFile ?: return
        if (!f.exists()) return
        var fileDurMs = 0L
        try {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(f.absolutePath)
                var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
                srcW = w
                srcH = h
                fileDurMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
            } finally { r.release() }
        } catch (_: Exception) { }
        // Phase 18: the bitrate proxy must divide the file's size by the
        // FILE's own duration. The old code divided by the dialog's
        // durationMs - the WHOLE timeline (every clip in the sequence) -
        // so the rate (and with it the whole size estimate) came out N
        // times too small for an N-clip sequence: a 2-clip project
        // estimated ~49 MB for a ~93 MB output. The file's own duration
        // is the correct denominator; the timeline value stays only as a
        // fallback for the single-clip case when probing failed.
        val durSec = (if (fileDurMs > 0L) fileDurMs else durationMs) / 1000.0
        if (durSec > 0 && f.length() > 0) {
            srcKbps = (f.length() * 8.0 / 1000.0 / durSec).toInt()
        }
    }
""",
"esd: srcKbps from the file's own duration")

# ---- E2) encode-mode estimate: no seconds added per transition ----
apply_edit(ESD, """            // phase 16: each freeze-frame transition adds its duration.
            for (dMs in a.transitions.values) {
                totalSec += dMs / 1000.0
            }
""",
"""            // phase 18: transitions add NO seconds anymore - each dips
            // into the following clip's opening, which re-encodes as part
            // of the spans already summed above.
""",
"esd: encode estimate drops the +D")

# ---- E3) copy-mode estimate: the transition window moves copy->encode ----
apply_edit(ESD, """        // phase 16 mirror: freeze-frame transitions re-encode their D
        // window of stills; the clips stay as computed above.
        for (dMs in a.transitions.values) {
            encSec += dMs / 1000.0
        }
""",
"""        // phase 18 mirror: a transition dips into the FOLLOWING clip's
        // opening - that window moves from the copied seconds to the
        // re-encoded ones (estimated at the transition duration; the
        // stream-copy plans extend a little further to reach a keyframe)
        // and the output gains no extra seconds. Merged mode only:
        // separate files export no transitions.
        if (!selSeparateFiles) {
            for (dMs in a.transitions.values) {
                copySec -= dMs / 1000.0
                encSec += dMs / 1000.0
            }
        }
""",
"esd: copy estimate moves the transition window")

# ---- E4) summary seconds: same mirror ----
apply_edit(ESD, """        // phase 16: freeze-frame transitions re-encode only their D window
        // of stills; the clips themselves stay exactly as computed above.
        for (dMs in a.transitions.values) {
            encSec += dMs / 1000.0
        }
""",
"""        // phase 18: transitions re-encode only the window they dip into
        // (the following clip's opening, which keeps playing under the
        // effect); the rest of every clip stays exactly as computed above.
        for (dMs in a.transitions.values) {
            copySec -= dMs / 1000.0
            encSec += dMs / 1000.0
        }
""",
"esd: summary seconds move the window")

# ---- E5) copy-mode transition note ----
apply_edit(ESD, """        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) as freeze-frame segments (only the stills re-encode; the output grows by each transition duration)")
        }
""",
"""        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) (the second clip keeps playing through each one; only that short window re-encodes)")
        }
""",
"esd: copy-mode transition note")

# ---- E6) two-step command preview line ----
apply_edit(ESD, """                if (a.transitions.isNotEmpty()) {
                    sb.append("\\nffmpeg -framerate FPS -i frame_%04d.jpg -i anullsrc -vf \\"scale,setsar,fps,format\\" <matched enc> seg_T.mp4   (freeze-frame transition)")
                }
""",
"""                if (a.transitions.isNotEmpty()) {
                    sb.append("\\nffmpeg -framerate FPS -i frame_%04d.jpg -ss S -t D -i clip2 -vf \\"scale,setsar,fps,format\\" <matched enc> seg_T.mp4   (transition: clip2 keeps playing under clip1's frozen last frame)")
                }
""",
"esd: two-step transition preview line")

# ---- E7) encode-mode transition note ----
apply_edit(ESD, """                sb.append("; ").append(a.transitions.size)
                    .append(" transition(s) as freeze-frame segments (only the stills re-encode)")
""",
"""                sb.append("; ").append(a.transitions.size)
                    .append(" transition(s) (the second clip keeps playing through each one)")
""",
"esd: encode-mode transition note")

# ===================== app/build.gradle =====================

# ---- G1) versionCode 16 / beta11 ----
apply_edit(GRADLE, """        // invalid"). 15 clears the highest offset ever produced.
        versionCode project.hasProperty('versionCode') ? project.property('versionCode').toInteger() : 15
        versionName "1.0-beta10"
""",
"""        // invalid"). 15 clears the highest offset ever produced.
        // Phase 18: 16 / beta11 - the playing-transition + size-estimate
        // build; every APK stays a strict upgrade over the installed one.
        versionCode project.hasProperty('versionCode') ? project.property('versionCode').toInteger() : 16
        versionName "1.0-beta11"
""",
"gradle: versionCode 16 + beta11")

print("edits applied: %d, skipped: %d" % (edits_applied, edits_skipped))

# ========================= gates =========================
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
R = open(RENDERER).read()
P = open(PLANNER).read()
E = open(ESD).read()

# 2) the version bump is in and the old values are gone
check(G.count("toInteger() : 16") == 1, "gradle versionCode 16")
check(G.count("toInteger() : 15") == 0, "gradle versionCode 15 gone")
check(G.count('"1.0-beta11"') == 1, "gradle versionName beta11")
check(G.count('"1.0-beta10"') == 0, "gradle versionName beta10 gone")
check(G.count("abiFilters 'arm64-v8a'") == 1, "gradle arm64-v8a abiFilter kept")
check(G.count("splits {") == 0, "gradle splits still gone")
check(G.count("versionCodeOverride") == 0, "gradle versionCodeOverride still gone")

# 3) the renderer runs the dip model
check(R.count("baseFrames: (Int) -> Bitmap?") == 1,
      "renderer per-frame base provider x1")
check(R.count("val bmpB = baseFrames(i)") == 1,
      "renderer pulls a fresh base frame per output frame")
check(R.count("effectCount: Int") == 1, "renderer effectCount param x1")
check(R.count("hasOverlay: Boolean") == 1, "renderer hasOverlay param x1")
check(R.count("if (!hasOverlay)") == 1, "renderer plain-bridge early return x1")
check(R.count("bmpB.recycle()") == 1, "renderer recycles each base bitmap x1")
check(R.count("bmpB: Bitmap,") == 1, "renderer drawFrame base param x1 (old two-still param gone)")

# 4) the planner wires the dip model exactly once each
check(P.count("private fun probeNextKeyframeMs") == 1,
      "planner probeNextKeyframeMs definition x1")
check(P.count("probeNextKeyframeMs(") == 2,
      "planner probeNextKeyframeMs definition + call x2")
check(P.count("pieceHandoffMs") == 4,
      "planner pieceHandoffMs x4 (comment + declare + fill + read)")
check(P.count("spanReencode[i] != true") == 2,
      "planner spanReencode branch gates x2")
check(P.count("val spanReencode = mutableMapOf") == 1,
      "planner spanReencode declaration x1")
check(P.count("val realAudio = planHasAudio") == 1,
      "planner realAudio selection x1")
check(P.count("pieceAEnc") == 2, "planner pieceAEnc x2 (define + use)")
check(P.count("rightStartMs + Math.round(i * 1000.0 / transFpsValue)") == 1,
      "planner playing-base extraction grid x1")
check(P.count("dip transition(s)") == 1, "planner log wording updated")
check(P.count("freeze-frame transition(s)") == 0, "planner old wording gone")
check(P.count("transAEnc") == 0, "planner old transAEnc gone")
check(P.count("val startB = extractBoundaryFrame") == 0,
      "planner frozen-first-frame extraction gone")
check(P.count("totalSpanSec += d / 1000.0") == 0,
      "planner output duration no longer grows per transition")
check(P.count("val leftDur = spans[gap].second") == 0,
      "planner clamp no longer constrains the left span")

# 5) the dialog estimate follows the file duration + dip timeline
check(E.count("fileDurMs") == 4, "esd fileDurMs x4 (declare + probe + use x2)")
check(E.count("(if (fileDurMs > 0L) fileDurMs else durationMs)") == 1,
      "esd file-own-duration denominator x1")
check(E.count("copySec -= dMs / 1000.0") == 2,
      "esd transition window moves copy->encode x2")
check(E.count("totalSec += dMs / 1000.0") == 0, "esd encode estimate +D gone")
check(E.count("the output grows by") == 0, "esd grows-by note gone")
check(E.count("keeps playing through") == 2, "esd new transition notes x2")
check(E.count("clip1's frozen last frame") == 1,
      "esd two-step preview line mentions the effect layer")

# 6) structural balance (the edits add balanced blocks only)
for name, s in (("renderer", R), ("planner", P), ("esd", E), ("gradle", G)):
    check(s.count("{") == s.count("}"),
          "%s braces balanced (%d/%d)" % (name, s.count("{"), s.count("}")))
    check(s.count("(") == s.count(")"),
          "%s parens balanced (%d/%d)" % (name, s.count("("), s.count(")")))

# 7) ASCII purity
for name, s in (("renderer", R), ("planner", P), ("esd", E), ("gradle", G)):
    check(sum(1 for ch in s if ord(ch) > 127) == 0, "%s ASCII" % name)

# 8) survival tokens (phase 16/17 + earlier invariants intact)
for tok in ["renderTransitionFrames", "addFreezeTransitionSegment",
            "effectiveTransitionDurations", "fpsCloseEnough",
            "nextSegmentFile", "encodablePixFmt", "-framerate ",
            "trans_tmp_", "video_track_timescale", "extractBoundaryFrame",
            "OPTION_CLOSEST", "anullsrc=r=", "-bsf:v dump_extra",
            "val sensorMode = !perSegmentEncode",
            "sensorMode && refParams.rotation != 0",
            "val transVEnc = if (perSegmentEncode) vEncSimple else enc"]:
    check(P.count(tok) > 0, "planner keeps '%s'" % tok)
for tok in ["smartEstimateBytes", "estimateSizeText", "formatBytes",
            "METADATA_KEY_DURATION"]:
    check(E.count(tok) > 0, "esd keeps '%s'" % tok)
for tok in ["drawBitmap(bmpB", "drawBitmap(bmpA"]:
    check(R.count(tok) > 0, "renderer keeps '%s'" % tok)

# 9) scope: only the four intended files may be dirty (clean tree also ok -
#    that is the re-run-after-commit case)
r = subprocess.run(["git", "status", "--porcelain"],
                   capture_output=True, text=True)
allowed = {"app/build.gradle", RENDERER, PLANNER, ESD}
dirty = [l[3:].strip() for l in r.stdout.splitlines() if l.strip()]
bad = [p for p in dirty if p not in allowed]
check(len(bad) == 0, "scope: no unexpected dirty files (dirty=%d, bad=%d)" %
      (len(dirty), len(bad)))

if fail:
    print("GATES FAILED: %d" % len(fail))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 18: done =="
