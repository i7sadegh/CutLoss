#!/usr/bin/env bash
###############################################################################
# CutLoss phase 16 -- "freeze-frame transitions" + arm64-only APK
#
# User directive (spelled out by the user):
#   The transition re-encode is too slow (5 transitions take forever) and
#   only a few types work. Instead, LIKE THE FREEZE FEATURE: take a frame
#   from the end of the first video and the start of the next video, build
#   a small video with matching settings, apply the transition effect on
#   it, its duration = the transition duration setting, then join the
#   three videos. Also: build the APK for arm64-v8a ONLY.
#
# What changes (4 files):
#   TransitionFrameRenderer.kt (NEW):
#     - Rasterizes the transition between the two frozen boundary frames
#       as a JPEG frame sequence (frame_0000.jpg ... frame_N-1.jpg). The
#       per-type math is a faithful port of the editor's live preview
#       (TransitionPreviewOverlayView): the right clip's still is the base
#       layer, the left clip's still carries the effect - so EVERY
#       transition type renders now (types the preview maps to a plain
#       fade map to the same fade here), and the export matches the
#       preview frame for frame.
#   SmartExportPlanner.kt:
#     - Transitions become freeze-frame segments (the user's model): the
#       LAST frame of the left clip and the FIRST frame of the right clip
#       are extracted (MediaMetadataRetriever OPTION_CLOSEST), rendered by
#       TransitionFrameRenderer, and ONE simple ffmpeg command encodes the
#       image sequence with parameters IDENTICAL to the reference clip -
#       codec, profile, level, resolution, pixel format, SAR (DAR follows
#       from W/H + SAR), fps, TBN via -video_track_timescale, audio
#       sample rate and channel layout (silence on the audio track). The
#       segment joins the concat list between the two clips.
#     - The clips themselves go back to being exactly what the cut mode
#       produces: pure stream copies (keyframe cut / full range) or the
#       plain matched re-encode of a trim. The whole phase-14 fade-window
#       machinery is REMOVED (tail/head fade pieces, afade windows,
#       keyframe-boundary packet probing, renderableTransitionType gate).
#     - Speed: only D seconds of STILL frames encode per transition
#       (lab: 0.5 s @ 1080p30 = 15 frames = 1.6 s on a slow CI box,
#       sub-second on a phone) - the clips never re-encode for a
#       transition anymore.
#     - Output duration grows by D per transition; the transition window
#       carries silence on audio (the freeze model).
#   ExportSettingsDialog.kt:
#     - Notes/estimates updated: "freeze-frame segments (only the stills
#       re-encode)"; copy/re-encode seconds account for the D windows.
#   app/build.gradle:
#     - The per-ABI split APKs are gone; ndk.abiFilters 'arm64-v8a' ships
#       exactly ONE APK (user request) - ffmpeg-kit's native libs for the
#       other ABIs are dropped, which also shrinks the APK a lot.
#
# Lab-validated with the user's real clips (lab-phase16): the transition
# segment template (image sequence -> matched encode -> concat between two
# stream-copied clips) produced exactly 15 frames / 0.500322 s, uniform
# h264 High 1920x1080 yuvj420p SAR 1:1 tbn 1/90000 + AAC LC 48 kHz stereo,
# exact total duration 41.140313 s (20.501333 + 0.500322 + 20.138658),
# clean seam decodes, and the crossfade survived the encode (mean luma
# 155.09 -> 154.27).
#
# Requires the repo state after phases 14+15 (already committed).
# Idempotent: re-running skips every edit that is already present.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the arm64 APK.
###############################################################################
set -euo pipefail

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
RENDERER="app/src/main/java/com/tharunbirla/librecuts/services/TransitionFrameRenderer.kt"
GRADLE="app/build.gradle"

for f in "$PLANNER" "$ESD" "$GRADLE"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 16: applying freeze-frame transitions + arm64-only APK =="

# ---- 1) the frame renderer (new file) ----
if [ -f "$RENDERER" ]; then
  echo "  [skip] TransitionFrameRenderer.kt already exists"
else
  mkdir -p "$(dirname "$RENDERER")"
  cat > "$RENDERER" <<'KTEOF'
package com.tharunbirla.librecuts.services

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import java.io.File
import java.io.FileOutputStream

/**
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
object TransitionFrameRenderer {

    /**
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

    private fun drawFrame(
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
        when (kind) {
            "fade", "dissolve" -> {
                paint.alpha = ((1f - progress) * 255f).toInt()
                canvas.drawBitmap(bmpA, srcA, dst, paint)
            }
            "fadeblack", "fadewhite" -> {
                // dip through the color: first half fades the LEFT still
                // out to the color, second half fades the RIGHT still in
                val base = if (progress < 0.5f) bmpA else bmpB
                val baseSrc = if (progress < 0.5f) srcA else srcB
                canvas.drawBitmap(base, baseSrc, dst, paint)
                val alpha = if (progress < 0.5f) progress * 2f else (1f - progress) * 2f
                paint.color = if (kind == "fadewhite") Color.WHITE else Color.BLACK
                paint.alpha = (alpha * 255f).toInt()
                canvas.drawRect(dst, paint)
            }
            "wipeleft" -> {
                canvas.save()
                canvas.clipRect(0f, 0f, w * (1f - progress), h)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "wiperight" -> {
                canvas.save()
                canvas.clipRect(w * progress, 0f, w, h)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "wipeup" -> {
                canvas.save()
                canvas.clipRect(0f, 0f, w, h * (1f - progress))
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "wipedown" -> {
                canvas.save()
                canvas.clipRect(0f, h * progress, w, h)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "slideleft", "coverleft" -> {
                canvas.save()
                canvas.translate(-w * progress, 0f)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "slideright", "coverright" -> {
                canvas.save()
                canvas.translate(w * progress, 0f)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "slideup" -> {
                canvas.save()
                canvas.translate(0f, -h * progress)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "slidedown" -> {
                canvas.save()
                canvas.translate(0f, h * progress)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "circlecrop" -> {
                canvas.save()
                val maxRadius = Math.hypot((w / 2).toDouble(), (h / 2).toDouble()).toFloat()
                val radius = maxRadius * (1f - progress)
                path.reset()
                path.addCircle(w / 2f, h / 2f, radius, Path.Direction.CW)
                canvas.clipPath(path)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "rectcrop" -> {
                canvas.save()
                val halfW = (w / 2f) * (1f - progress)
                val halfH = (h / 2f) * (1f - progress)
                canvas.clipRect(w / 2f - halfW, h / 2f - halfH, w / 2f + halfW, h / 2f + halfH)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            "zoomin" -> {
                canvas.save()
                val scale = 1f + progress * 0.4f
                paint.alpha = ((1f - progress) * 255f).toInt()
                canvas.scale(scale, scale, w / 2f, h / 2f)
                canvas.drawBitmap(bmpA, srcA, dst, paint)
                canvas.restore()
            }
            else -> {
                paint.alpha = ((1f - progress) * 255f).toInt()
                canvas.drawBitmap(bmpA, srcA, dst, paint)
            }
        }
    }
}
KTEOF
  echo "  [ok] created TransitionFrameRenderer.kt"
fi

# ---- 2) planner + dialog + gradle edits ----
python3 - <<'PYEOF'
import sys

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


def remove_edit(path, old, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    if old not in s:
        edits_skipped += 1
        return
    s = s.replace(old, "", 1)
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1


def remove_between(path, start, end, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    if start not in s:
        edits_skipped += 1
        return
    i = s.find(start)
    j = s.find(end, i + len(start))
    if j < 0:
        print("  [FAIL] " + name + ": end marker not found")
        sys.exit(1)
    s = s[:i] + s[j:]
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1


# ================= PLANNER =================

# ---- P1: file doc comment ----
apply_edit(PLANNER, """ * Phase 14 (matched fade segments): a transition between two clips is
 * exported as its own small segments - the tail of the left clip fading
 * out and the head of the right clip fading in - encoded with parameters
 * IDENTICAL to the reference clip (codec, profile, level, resolution,
 * pixel format, SAR - DAR follows from W/H + SAR -, fps, TBN via
 * -video_track_timescale, audio sample rate and channel layout). The rest
 * of the timeline stays a stream copy and the final assembly is still the
 * concat demuxer with -c copy, so only the transition window is ever
 * re-encoded. Fade-type transitions (fade / dissolve / fade black / fade
 * white) render as a dip through the fade color; every other transition
 * type blocks the export honestly because blending frames from two clips
 * at once needs a filter graph. Copied spans next to a transition are cut
 * EXACTLY at keyframe packet boundaries (-ss at the keyframe plus
 * -frames:v N counted from the probed packet list), so no frame is
 * duplicated or lost at the seams.""",
""" * Phase 16 (freeze-frame transitions): a transition between two clips is
 * its own small video, exactly like the freeze feature - the LAST frame
 * of the left clip and the FIRST frame of the right clip are extracted,
 * the app renders the chosen effect between those two stills as a JPEG
 * frame sequence (TransitionFrameRenderer - the same per-type math the
 * live preview uses, so every transition type renders), and ONE simple
 * ffmpeg command encodes that sequence with parameters IDENTICAL to the
 * reference clip (codec, profile, level, resolution, pixel format, SAR -
 * DAR follows from W/H + SAR -, fps, TBN via -video_track_timescale,
 * audio sample rate and channel layout). The segment joins the concat
 * list between the two clips, so the clips themselves stay pure stream
 * copies and only D seconds of still frames ever encode (sub-second per
 * transition on a phone). The output duration grows by D per transition
 * and the transition window carries silence on the audio track.""",
"planner: file doc -> phase 16")

# ---- P2: analyzeInternal type gate removal ----
apply_edit(PLANNER, """        val transitions = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            if (!renderableTransitionType(t.type)) {
                return fail("transition '" + t.type +
                    "' needs frame blending - use Fade, Fade Black or Fade White")
            }
            transitions[t.index] = Pair(t.type, t.durationMs)
        }""",
"""        val transitions = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            // Phase 16: every type renders - the app rasterizes the effect
            // between the two frozen boundary frames itself, so nothing
            // needs a filter graph anymore.
            transitions[t.index] = Pair(t.type, t.durationMs)
        }""",
"planner: analyzeInternal gate removal")

# ---- P3: renderableTransitionType helper removal ----
remove_between(PLANNER,
"""    /**
     * Phase 14: transition types the lossless pipeline can render.""",
"""    /**
     * Phase 14: effective transition durations""",
"planner: renderableTransitionType removal")

# ---- P4: probeVideoPackets + planTransitionSpan + TransitionSpan removal ----
remove_between(PLANNER,
"""    /**
     * Phase 14: video packet list""",
"""    /**
     * Phase 15: numeric frame-rate""",
"planner: packet-probe helpers removal")

# ---- P5: planInternal transition comment + raw loop ----
apply_edit(PLANNER, """        // ---- phase 14: transitions as matched fade segments ----
        // A fade transition is per-stream, so it exports as small segments
        // that then join the rest through the concat: the left clip's tail
        // fades out, the right clip's head fades in, and both pieces are
        // re-encoded with parameters IDENTICAL to the reference clip -
        // codec, profile, level, resolution, pixel format, SAR (DAR
        // follows from W/H + SAR), fps, TBN, audio sample rate and channel
        // layout - so the final assembly stays a pure -c copy. Copied
        // spans around a seam are cut exactly at keyframe packet
        // boundaries. Non-fade transitions need a frame blend, so they
        // block the export instead of silently degrading.
        val merged = !exportSeparateFiles   // single file vs one per clip
        val transitionsRaw = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            if (!renderableTransitionType(t.type)) return null
            transitionsRaw[t.index] = Pair(t.type, t.durationMs)
        }""",
"""        // ---- phase 16: transitions as freeze-frame segments ----
        // Every transition renders: the app rasterizes the effect between
        // the frozen boundary frames of the two clips (see
        // addFreezeTransitionSegment below), the small stills video joins
        // the concat list between the clips, and the clips themselves stay
        // exactly what the cut mode produces - pure stream copies with the
        // keyframe cut, plain matched re-encodes of the trim otherwise.
        val merged = !exportSeparateFiles   // single file vs one per clip
        val transitionsRaw = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            transitionsRaw[t.index] = Pair(t.type, t.durationMs)
        }""",
"planner: planInternal transition loop")
PYEOF

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


def remove_edit(path, old, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    if old not in s:
        edits_skipped += 1
        return
    s = s.replace(old, "", 1)
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1


def remove_between(path, start, end, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    if start not in s:
        edits_skipped += 1
        return
    i = s.find(start)
    j = s.find(end, i + len(start))
    if j < 0:
        print("  [FAIL] " + name + ": end marker not found")
        sys.exit(1)
    s = s[:i] + s[j:]
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1


# ---- P6: perSegmentEncode comment ----
apply_edit(PLANNER, """        // A source pixel format the encoders cannot reproduce would make
        // the fade pieces differ from their copied neighbours, so a
        // transition on a non-encodable source takes the uniform encode
        // (the fades then ride the per-segment commands).
        val perSegmentEncode = (!keyframeCut &&""",
"""        // A source pixel format the encoders cannot reproduce would make
        // the freeze-frame transition segments (8-bit 4:2:0 from stills)
        // differ from their stream-copied neighbours, so a transition on a
        // non-encodable source takes the uniform encode - every segment
        // then becomes yuv420p, transitions included.
        val perSegmentEncode = (!keyframeCut &&""",
"planner: perSegmentEncode comment")

# ---- P7: spanPlans block removal ----
remove_between(PLANNER,
"""        // Transition-adjacent copied spans need exact keyframe boundaries
        // (phase 14); encoded plans carry the fades inside their commands.
        val spanPlans = mutableMapOf<Int, TransitionSpan?>()""",
"""        for (i in clips.indices) {
            if (clips[i].trimEndMs <= clips[i].trimStartMs) return null
        }""",
"planner: spanPlans block removal")

# ---- P8: fadeColorFor removal ----
remove_edit(PLANNER, """        fun fadeColorFor(gap: Int): String =
            if (gap >= 0 && transitionsRaw[gap]?.first.equals("fadewhite", ignoreCase = true)) {
                ":color=white"
            } else {
                ""
            }
""", "planner: fadeColorFor removal")

# ---- P9: leftD/rightD/adjacent vals removal ----
remove_edit(PLANNER, """            val leftD = if (i > 0) (transitionDurations[i - 1] ?: 0L) / 2L else 0L
            val rightD = if (i < clips.size - 1) (transitionDurations[i] ?: 0L) / 2L else 0L
            val adjacent = leftD > 0L || rightD > 0L
""", "planner: adjacent vals removal")

# ---- P10: perSegmentEncode branch - fade windows out ----
apply_edit(PLANNER, """                if (scaleFilter != null || adjacent) {
                    val vParts = mutableListOf<String>()
                    if (scaleFilter != null) vParts.add(scaleFilter)
                    if (leftD > 0L) {
                        vParts.add("fade=t=in:st=0:d=" + ms(leftD) + fadeColorFor(i - 1))
                    }
                    if (rightD > 0L) {
                        vParts.add("fade=t=out:st=" + ms(spanMs - rightD) +
                            ":d=" + ms(rightD) + fadeColorFor(i))
                    }
                    sb.append(" -vf \\"").append(vParts.joinToString(",")).append("\\"")
                }
                if (fpsArg != null) sb.append(" ").append(fpsArg)
                sb.append(" ").append(vEncSimple)
                if (silenceAudio) {
                    sb.append(" ").append(aEncSilence)
                } else if (adjacent && planHasAudio) {
                    sb.append(" ").append(aEnc)
                    val aFades = mutableListOf<String>()
                    if (leftD > 0L) aFades.add("afade=t=in:st=0:d=" + ms(leftD))
                    if (rightD > 0L) {
                        aFades.add("afade=t=out:st=" + ms(spanMs - rightD) + ":d=" + ms(rightD))
                    }
                    sb.append(" -af \\"").append(aFades.joinToString(",")).append("\\"")
                } else if (planHasAudio) {
                    sb.append(" ").append(aEncSimple)
                }""",
"""                if (scaleFilter != null) {
                    sb.append(" -vf \\"").append(scaleFilter).append("\\"")
                }
                if (fpsArg != null) sb.append(" ").append(fpsArg)
                sb.append(" ").append(vEncSimple)
                if (silenceAudio) {
                    sb.append(" ").append(aEncSilence)
                } else if (planHasAudio) {
                    sb.append(" ").append(aEncSimple)
                }""",
"planner: perSegmentEncode fades out")

# ---- P11: the two phase-14 adjacent branches removal ----
remove_between(PLANNER,
"""            } else if (adjacent && (!keyframeCut || spanPlans[i] == null)) {""",
"""            } else if (fullRange) {""",
"planner: adjacent branches removal")

# ---- P12: totalSpanSec includes transition durations ----
apply_edit(PLANNER, """        var totalSpanSec = 0.0
        for (c in clips) {
            totalSpanSec += Math.max(0.0, (c.trimEndMs - c.trimStartMs) / 1000.0)
        }""",
"""        var totalSpanSec = 0.0
        for (c in clips) {
            totalSpanSec += Math.max(0.0, (c.trimEndMs - c.trimStartMs) / 1000.0)
        }
        // Phase 16: each freeze-frame transition segment adds its duration.
        for (d in transitionDurations.values) {
            totalSpanSec += d / 1000.0
        }""",
"planner: totalSpanSec += transitions")

print("edits (planner part 2): %d applied, %d skipped (already present)" % (edits_applied, edits_skipped))
PYEOF

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


# ---- P13: the freeze-frame transition segment builder ----
apply_edit(PLANNER, """        var segCounter = 0
        fun nextSegmentFile(ext: String): File {
            val f = File(workDir, "seg_" + segCounter + ext)
            segCounter++
            segmentFiles.add(f)
            return f
        }""",
"""        var segCounter = 0
        fun nextSegmentFile(ext: String): File {
            val f = File(workDir, "seg_" + segCounter + ext)
            segCounter++
            segmentFiles.add(f)
            return f
        }

        // ---- phase 16: freeze-frame transition segments ----
        // Like the freeze feature: the boundary frames of the two clips
        // are extracted, the app renders the effect between the stills
        // (TransitionFrameRenderer - the live preview's math, so every
        // transition type works), and ONE simple command encodes the JPEG
        // sequence with parameters matched to the reference clip. The
        // segment then joins the concat list between the two clips, so
        // the clips themselves never re-encode for a transition and only
        // D seconds of still frames encode (stills are trivial for the
        // encoder - sub-second per transition on a phone).
        fun extractBoundaryFrame(path: String, timeMs: Long): android.graphics.Bitmap? {
            val retriever = android.media.MediaMetadataRetriever()
            return try {
                retriever.setDataSource(path)
                retriever.getFrameAtTime(
                    timeMs * 1000L, android.media.MediaMetadataRetriever.OPTION_CLOSEST
                )
            } catch (e: Exception) {
                Log.w(TAG, "transition frame extraction failed: " + e.message)
                null
            } finally {
                try { retriever.release() } catch (e: Exception) {}
            }
        }
        val transFpsValue = if (fpsChange) exportFps.toDouble() else refParams.fpsValue
        val transFpsSpec = if (fpsChange) exportFps.toString() else refParams.fpsString
        fun addFreezeTransitionSegment(gap: Int, dMs: Long): Boolean {
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
            val transpose = when (refParams.rotation) {
                90 -> "transpose=2,"
                180 -> "transpose=1,transpose=1,"
                270 -> "transpose=1,"
                else -> ""
            }
            val scalePart = scaleFilter
                ?: ("scale=" + refParams.width + ":" + refParams.height + ",setsar=" + sarSpec)
            val vf = transpose + scalePart + ",fps=" + transFpsSpec +
                ",format=" + encodablePixFmt(refParams)
            val seg = nextSegmentFile(segExt)
            val sb = StringBuilder("-y -framerate ").append(transFpsSpec)
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
            sb.append(segTbn)
            if (refParams.rotation != 0) {
                // like the freeze builder: encode sensor-space first, then
                // remux the rotation metadata back in with a pure -c copy
                val tmp = File(workDir, "trans_tmp_" + gap + ".mp4")
                sb.append(" \\"").append(tmp.absolutePath).append("\\"")
                val rot = StringBuilder("-y -display_rotation:v ").append(-refParams.rotation)
                rot.append(" -i \\"").append(tmp.absolutePath).append("\\"")
                rot.append(" -map 0:v:0")
                if (planHasAudio) rot.append(" -map 0:a:0")
                rot.append(" -c copy \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, dSec)))
                commands.add(Pair(rot.toString(), 0.5))
            } else {
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, dSec)))
            }
            return true
        }""",
"planner: freeze transition segment builder")

# ---- P14: call site at the end of each clip iteration ----
apply_edit(PLANNER, """                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            }

        }""",
"""                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            }

            // Phase 16: the freeze-frame transition segment joins the
            // concat list right after this clip, before the next one.
            if (merged && i < clips.size - 1) {
                val dMs = transitionDurations[i] ?: 0L
                if (dMs >= 200L && !addFreezeTransitionSegment(i, dMs)) return null
            }
        }""",
"planner: transition call site")

# ---- P15: log line ----
apply_edit(PLANNER,
"""                (if (hasTransitions) ", " + transitionDurations.size + " fade transition(s)" else "")""",
"""                (if (hasTransitions) ", " + transitionDurations.size + " freeze-frame transition(s)" else "")""",
"planner: log line")

print("edits (planner part 3): %d applied, %d skipped (already present)" % (edits_applied, edits_skipped))
PYEOF

python3 - <<'PYEOF'
import sys

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


# ================= EXPORT SETTINGS DIALOG =================

# ---- E1: smartEncodeMode comment ----
apply_edit(ESD, """            (nonEncodable && !selKeyframeCut && anyTrimmed) ||
            // phase 14 mirror: a fade segment on a non-encodable source
            // cannot match its copied neighbours, so the uniform encode
            // takes over and the fades ride the per-segment commands.
            (nonEncodable && a.transitions.isNotEmpty() && !selSeparateFiles)""",
"""            (nonEncodable && !selKeyframeCut && anyTrimmed) ||
            // phase 16 mirror: a freeze-frame transition segment encodes
            // to 8-bit 4:2:0, so on a non-encodable source it cannot match
            // stream-copied neighbours - the uniform encode takes over and
            // every segment (transitions included) becomes yuv420p.
            (nonEncodable && a.transitions.isNotEmpty() && !selSeparateFiles)""",
"ESD: smartEncodeMode comment")

# ---- E2: buildSmartSummary copy/enc seconds ----
apply_edit(ESD, """        // phase 14: the fade windows around each transition re-encode (the
        // pieces); with a normal cut the whole adjacent clips do, because
        // the fades ride their re-encode.
        if (selKeyframeCut) {
            for (dMs in a.transitions.values) {
                val dSec = dMs / 1000.0
                copySec = Math.max(0.0, copySec - dSec)
                encSec += dSec
            }
        } else {
            val adjacentIdx = mutableSetOf<Int>()
            for (gap in a.transitions.keys) {
                adjacentIdx.add(gap)
                adjacentIdx.add(gap + 1)
            }
            for (idx in adjacentIdx) {
                val c = a.clips.getOrNull(idx) ?: continue
                if (!c.fullRange) continue
                val spanMs = c.trimEndMs - c.trimStartMs
                if (spanMs <= 0L) continue
                copySec = Math.max(0.0, copySec - spanMs / 1000.0)
                encSec += spanMs / 1000.0
            }
        }""",
"""        // phase 16: freeze-frame transitions re-encode only their D window
        // of stills; the clips themselves stay exactly as computed above.
        for (dMs in a.transitions.values) {
            encSec += dMs / 1000.0
        }""",
"ESD: summary seconds")

# ---- E3: summary transition note ----
apply_edit(ESD, """        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) as matched fade segments (only the transition window is re-encoded)")
        }
        sb.append("; final assembly is a lossless concat)")""",
"""        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) as freeze-frame segments (only the stills re-encode; the output grows by each transition duration)")
        }
        sb.append("; final assembly is a lossless concat)")""",
"ESD: summary transition note")

# ---- E4: encode-summary transition piece line ----
apply_edit(ESD, """                if (a.transitions.isNotEmpty()) {
                    sb.append("\\nffmpeg -ss S -t D -i input -vf \\"fps,setsar,fade\\" -af afade <matched enc> seg_T.mp4   (transition piece)")
                }""",
"""                if (a.transitions.isNotEmpty()) {
                    sb.append("\\nffmpeg -framerate FPS -i frame_%04d.jpg -i anullsrc -vf \\"scale,setsar,fps,format\\" <matched enc> seg_T.mp4   (freeze-frame transition)")
                }""",
"ESD: encode summary piece line")

# ---- E5: encode-summary transition note ----
apply_edit(ESD, """            } else {
                sb.append("; ").append(a.transitions.size)
                    .append(" transition(s) as matched fade segments (only the transition window is re-encoded)")
            }
        }""",
"""            } else {
                sb.append("; ").append(a.transitions.size)
                    .append(" transition(s) as freeze-frame segments (only the stills re-encode)")
            }
        }""",
"ESD: encode summary note")

# ---- E6: estimate copy/enc seconds ----
apply_edit(ESD, """        // phase 14 mirror of the summary math: fade windows re-encode with
        // a keyframe cut, whole adjacent clips with a normal cut.
        if (selKeyframeCut) {
            for (dMs in a.transitions.values) {
                val dSec = dMs / 1000.0
                copySec = Math.max(0.0, copySec - dSec)
                encSec += dSec
            }
        } else {
            val adjacentIdx = mutableSetOf<Int>()
            for (gap in a.transitions.keys) {
                adjacentIdx.add(gap)
                adjacentIdx.add(gap + 1)
            }
            for (idx in adjacentIdx) {
                val c = a.clips.getOrNull(idx) ?: continue
                if (!c.fullRange) continue
                val spanMs = c.trimEndMs - c.trimStartMs
                if (spanMs <= 0L) continue
                copySec = Math.max(0.0, copySec - spanMs / 1000.0)
                encSec += spanMs / 1000.0
            }
        }""",
"""        // phase 16 mirror: freeze-frame transitions re-encode their D
        // window of stills; the clips stay as computed above.
        for (dMs in a.transitions.values) {
            encSec += dMs / 1000.0
        }""",
"ESD: estimate seconds")

# ---- E7: estimate encode-mode total seconds ----
apply_edit(ESD, """            var totalSec = 0.0
            for (i in a.clips.indices) {
                val spanMs = a.clips[i].trimEndMs - a.clips[i].trimStartMs
                if (spanMs > 0L) totalSec += spanMs / 1000.0
            }""",
"""            var totalSec = 0.0
            for (i in a.clips.indices) {
                val spanMs = a.clips[i].trimEndMs - a.clips[i].trimStartMs
                if (spanMs > 0L) totalSec += spanMs / 1000.0
            }
            // phase 16: each freeze-frame transition adds its duration.
            for (dMs in a.transitions.values) {
                totalSec += dMs / 1000.0
            }""",
"ESD: estimate total seconds")

# ================= BUILD GRADLE =================

# ---- G1: arm64-v8a only ----
apply_edit(GRADLE, """        vectorDrawables {
            useSupportLibrary true
        }
    }""",
"""        vectorDrawables {
            useSupportLibrary true
        }

        // Phase 16: ship ONE APK for arm64-v8a devices only (user
        // request). The ffmpeg-kit native libraries for the other ABIs
        // are dropped from the package, which also shrinks the APK a lot.
        ndk {
            abiFilters 'arm64-v8a'
        }
    }""",
"gradle: ndk abiFilters arm64-v8a")

# ---- G2: per-ABI splits removal ----
apply_edit(GRADLE, """    splits {
        abi {
            enable true
            reset()
            include 'armeabi-v7a', 'arm64-v8a', 'x86_64'
            universalApk false
        }
    }

    applicationVariants.all { variant ->
        def abiCodes = ['armeabi-v7a': 0, 'arm64-v8a': 1, 'x86_64': 2]

        variant.outputs.each { output ->
            def abi = output.getFilter(com.android.build.OutputFile.ABI)
            if (abi != null && abiCodes.containsKey(abi)) {
                output.versionCodeOverride = variant.versionCode + abiCodes.get(abi)
            }
        }
    }
}""",
"""    // Phase 16: the per-ABI split APKs and their version-code offsets are
    // gone - the single arm64-v8a build (ndk.abiFilters above) replaces
    // all of them.
}""",
"gradle: splits + variant block removal")

print("edits (ESD + gradle): %d applied, %d skipped (already present)" % (edits_applied, edits_skipped))
PYEOF

echo "== phase 16: gates =="

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
E = open("app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt").read()
G = open("app/build.gradle").read()
try:
    R = open("app/src/main/java/com/tharunbirla/librecuts/services/TransitionFrameRenderer.kt").read()
except IOError:
    R = ""

# 2) the phase-14 fade machinery is gone from the planner
for tok in ["probeVideoPackets", "planTransitionSpan", "TransitionSpan",
            "renderableTransitionType", "fadeColorFor", "spanPlans",
            "adjacent", "leftD = if", "rightD = if", "fade=t=", "afade",
            "needs frame blending", "matched fade segments"]:
    check(P.count(tok) == 0, "planner '%s' gone (got %d)" % (tok, P.count(tok)))

# 3) the phase-16 machinery is wired in
for tok, want in [
    ("TransitionFrameRenderer", 3), ("addFreezeTransitionSegment", 3),
    ("extractBoundaryFrame", 3), ("frame_%04d.jpg", 1), ("-framerate ", 1),
    ("OPTION_CLOSEST", 1), ("freeze-frame transition(s)", 1),
    ("-video_track_timescale", 3), ("setsar=", 6), ("anullsrc", 6),
    ("displayWidth, displayHeight", 3), ("trans_", 2),
]:
    check(P.count(tok) == want, "planner '%s' x%d (got %d)" % (tok, want, P.count(tok)))

# 4) the renderer file
check(R != "", "TransitionFrameRenderer.kt exists")
if R:
    check(R.count("fun renderTransitionFrames") == 1, "renderer entry point x1")
    check(R.count("canvas.save()") == 11, "renderer canvas.save x11 (got %d)" % R.count("canvas.save()"))
    check(R.count("canvas.restore()") == 11, "renderer canvas.restore x11 (got %d)" % R.count("canvas.restore()"))
    for tok in ["\"fade\"", "\"dissolve\"", "\"fadeblack\"", "\"fadewhite\"",
                "\"wipeleft\"", "\"wiperight\"", "\"wipeup\"", "\"wipedown\"",
                "\"slideleft\"", "\"slideright\"", "\"slideup\"", "\"slidedown\"",
                "\"coverleft\"", "\"coverright\"", "\"circlecrop\"", "\"rectcrop\"",
                "\"zoomin\"", "%04d", "CompressFormat.JPEG"]:
        check(tok in R, "renderer has %s" % tok)
    check(R.count("{") == R.count("}"), "renderer braces balanced (%d/%d)" % (R.count("{"), R.count("}")))
    check(R.count("(") == R.count(")"), "renderer parens balanced")
    check(sum(1 for ch in R if ord(ch) > 127) == 0, "renderer ASCII")

# 5) planner structural balance + ASCII
check(P.count("{") == P.count("}"), "planner braces balanced (%d/%d)" % (P.count("{"), P.count("}")))
check(P.count("(") == P.count(")"), "planner parens balanced (%d/%d)" % (P.count("("), P.count(")")))
check(sum(1 for ch in P if ord(ch) > 127) == 0, "planner ASCII")

# 6) ESD updates
check(E.count("freeze-frame segments") == 2, "ESD freeze-frame notes x2 (got %d)" % E.count("freeze-frame segments"))
check(E.count("matched fade segments") == 0, "ESD old fade note gone")
check(E.count("adjacentIdx") == 0, "ESD adjacentIdx gone")
check(E.count("frame_%04d.jpg") == 1, "ESD transition piece line updated")
check(E.count("{") == E.count("}"), "ESD braces balanced (%d/%d)" % (E.count("{"), E.count("}")))
check(sum(1 for ch in E if ord(ch) > 127) == 0, "ESD ASCII")

# 7) build.gradle: arm64 only
check(G.count("abiFilters 'arm64-v8a'") == 1, "gradle abiFilters arm64-v8a x1")
for tok in ["splits", "armeabi-v7a", "x86_64", "universalApk", "versionCodeOverride"]:
    check(G.count(tok) == 0, "gradle '%s' gone (got %d)" % (tok, G.count(tok)))
check(G.count("{") == G.count("}"), "gradle braces balanced (%d/%d)" % (G.count("{"), G.count("}")))

# 8) survival tokens (phases 9-15 contracts intact)
for tok in ["buildFreezeFrameCommands", "fpsCloseEnough", "simpleVideoEncoderArgs",
            "simpleAudioEncoderArgs", "encodablePixFmt", "effectiveTransitionDurations",
            "-c copy", "concat demuxer"]:
    check(P.count(tok) > 0, "planner keeps '%s'" % tok)

V = open("app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt").read()
check(V.count("val windowMs = transOp.durationMs.coerceAtLeast(200L)") == 1,
      "VEA preview window follows the op duration (phase 14 survives)")

if fail:
    print("GATES FAILED: %d" % len(fail))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 16: done =="
