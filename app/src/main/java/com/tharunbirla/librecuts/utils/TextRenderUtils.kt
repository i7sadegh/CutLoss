package com.tharunbirla.librecuts.utils

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import com.tharunbirla.librecuts.models.EditOperation
import java.io.File
import java.io.FileOutputStream

/**
 * Shared Canvas-based rendering for AddText operations.
 *
 * The SAME code path renders:
 *  - the on-screen preview (TextOverlayView)
 *  - the exported video (rasterized to a transparent PNG and composited
 *    with the FFmpeg overlay filter)
 *
 * This guarantees a pixel-perfect WYSIWYG match between what the user sees
 * and what FFmpeg writes, and unlocks features drawtext cannot do:
 * underline, strikethrough, letter spacing and rounded-corner backgrounds.
 */
object TextRenderUtils {

    /** Resolve the effective typeface (font file + synthesized bold/italic). */
    fun resolveTypeface(op: EditOperation.AddText): Typeface {
        val base = try {
            if (op.fontPath.isNullOrBlank()) null else Typeface.createFromFile(op.fontPath)
        } catch (e: Exception) {
            null
        }
        val family = base ?: Typeface.DEFAULT
        val style = when {
            op.bold && op.italic -> Typeface.BOLD_ITALIC
            op.bold -> Typeface.BOLD
            op.italic -> Typeface.ITALIC
            else -> Typeface.NORMAL
        }
        return if (style == Typeface.NORMAL) family else Typeface.create(family, style)
    }

    /** Configure a paint for this op (typeface, flags, spacing, color+alpha). */
    fun configPaint(paint: Paint, op: EditOperation.AddText, alphaInt: Int = 255) {
        paint.typeface = resolveTypeface(op)
        paint.isUnderlineText = op.underline
        paint.isStrikeThruText = op.strikethrough
        paint.letterSpacing = op.letterSpacing
        paint.style = Paint.Style.FILL
        val baseColor = try { Color.parseColor(op.color) } catch (e: Exception) { Color.WHITE }
        paint.color = Color.argb(
            alphaInt.coerceIn(0, 255),
            Color.red(baseColor), Color.green(baseColor), Color.blue(baseColor))
    }

    /**
     * Draw the text block (optional rounded background, optional outline,
     * per-line alignment) starting at (startX, startY) where startY is the
     * BASELINE of the first line. Matches the preview rendering exactly.
     *
     * @param scale video-pixel to canvas-pixel scale (1.0 for PNG rendering)
     */
    fun drawBlock(
        canvas: Canvas,
        paint: Paint,
        op: EditOperation.AddText,
        lines: List<String>,
        maxTextWidth: Float,
        startX: Float,
        startY: Float,
        textHeight: Float,
        scale: Float
    ) {
        // 1. Rounded background box behind the whole block
        if (op.bgColor != null) {
            val marginPx = op.bgMargin * scale
            val radiusPx = op.bgCornerRadius * scale
            val bgBase = try { Color.parseColor(op.bgColor) } catch (e: Exception) { Color.BLACK }
            val fill = paint.color
            val bgAlpha = (op.bgOpacity.coerceIn(0f, 1f) * Color.alpha(fill)).toInt().coerceIn(0, 255)
            val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.argb(bgAlpha, Color.red(bgBase), Color.green(bgBase), Color.blue(bgBase))
            }
            val top = startY + paint.ascent() - marginPx
            val bottom = startY + (lines.size - 1) * textHeight + paint.descent() + marginPx
            canvas.drawRoundRect(
                startX - marginPx, top, startX + maxTextWidth + marginPx, bottom,
                radiusPx, radiusPx, bgPaint)
        }

        // 2. Text lines (optional stroke outline first, then fill).
        //    Round 6: the stroke honors its own transparency, and a real
        //    drop shadow (color / transparency / blur / angle / width) is
        //    drawn under the widest pass only -- the stroke pass when a
        //    stroke exists, otherwise the fill pass -- so the shadow
        //    always matches the full glyph silhouette.
        val fillColor = paint.color
        val strokeAlphaFactor = op.strokeOpacity ?: 1.0f
        val shadowOn = op.shadowColor != null && (op.shadowWidth > 0 || op.shadowBlur > 0)
        var shadowDx = 0f
        var shadowDy = 0f
        var shadowArgb = 0
        if (shadowOn) {
            val shHex: String = op.shadowColor ?: "#000000"
            val rad = Math.toRadians(op.shadowAngle.toDouble())
            shadowDx = (op.shadowWidth * Math.cos(rad)).toFloat() * scale
            shadowDy = (op.shadowWidth * Math.sin(rad)).toFloat() * scale
            val shBase = try { Color.parseColor(shHex) } catch (e: Exception) { Color.BLACK }
            val shAlpha = (op.shadowOpacity.coerceIn(0f, 1f) * Color.alpha(fillColor)).toInt().coerceIn(0, 255)
            shadowArgb = Color.argb(shAlpha, Color.red(shBase), Color.green(shBase), Color.blue(shBase))
        }
        for ((index, line) in lines.withIndex()) {
            val lineW = paint.measureText(line)
            val lineX = when (op.textAlign) {
                "left", "L" -> startX
                "right", "R" -> startX + maxTextWidth - lineW
                else -> startX + (maxTextWidth - lineW) / 2f
            }
            val lineY = startY + (index * textHeight)

            if (op.borderThickness > 0) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = op.borderThickness * scale
                paint.strokeJoin = Paint.Join.ROUND
                val borderColorInt = try { Color.parseColor(op.borderColor) } catch (e: Exception) { Color.BLACK }
                val strokeAlpha = (strokeAlphaFactor.coerceIn(0f, 1f) * Color.alpha(fillColor)).toInt().coerceIn(0, 255)
                paint.color = Color.argb(
                    strokeAlpha,
                    Color.red(borderColorInt), Color.green(borderColorInt), Color.blue(borderColorInt))
                if (shadowOn) {
                    paint.setShadowLayer(op.shadowBlur * scale, shadowDx, shadowDy, shadowArgb)
                } else {
                    paint.clearShadowLayer()
                }
                canvas.drawText(line, lineX, lineY, paint)
                paint.style = Paint.Style.FILL
                paint.color = fillColor
                paint.clearShadowLayer()
            } else {
                paint.style = Paint.Style.FILL
                if (shadowOn) {
                    paint.setShadowLayer(op.shadowBlur * scale, shadowDx, shadowDy, shadowArgb)
                } else {
                    paint.clearShadowLayer()
                }
            }

            canvas.drawText(line, lineX, lineY, paint)
        }
        paint.clearShadowLayer()
    }

    /**
     * Rasterize a text operation to a transparent PNG at source-video pixel
     * scale (fontSize px = source video px). Returns the file or null.
     * The file is overwritten per operation id, so repeated builds do not
     * accumulate cache files.
     */
    fun renderAddTextToPng(context: Context, op: EditOperation.AddText): File? {
        return try {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.textSize = op.fontSize.toFloat().coerceIn(4f, 2000f)
            configPaint(paint, op, 255)

            val lines = op.text.split("\n")
            val textHeight = (paint.descent() - paint.ascent()) + op.lineSpacing
            var maxTextWidth = 0f
            for (line in lines) {
                val w = paint.measureText(line)
                if (w > maxTextWidth) maxTextWidth = w
            }
            if (maxTextWidth <= 0f || lines.isEmpty()) return null

            val pad = (op.bgMargin + op.borderThickness + op.shadowWidth + op.shadowBlur + 8).coerceAtLeast(8)
            val width = (maxTextWidth + 2 * pad).toInt().coerceAtLeast(8)
            val height = (lines.size * textHeight + 2 * pad).toInt().coerceAtLeast(8)
            if (width > 8192 || height > 8192) return null

            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val startX = pad.toFloat()
            val startY = pad.toFloat() - paint.ascent()
            drawBlock(canvas, paint, op, lines, maxTextWidth, startX, startY, textHeight, 1.0f)

            val file = File(context.cacheDir, "text_ov_" + op.id + ".png")
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
            bitmap.recycle()
            file
        } catch (e: Exception) {
            null
        }
    }
}
