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
