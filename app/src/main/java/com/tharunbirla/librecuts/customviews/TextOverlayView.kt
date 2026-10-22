package com.tharunbirla.librecuts.customviews

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.ScaleGestureDetector
import android.view.View
import com.tharunbirla.librecuts.models.EditOperation
import com.tharunbirla.librecuts.models.TextPosition
import java.io.File

/**
 * TextOverlayView renders text overlays on top of the video player.
 * This allows users to see text operations in real-time without FFmpeg processing.
 */
class TextOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val paint = Paint().apply {
        color = Color.WHITE
        textSize = 48f
        isAntiAlias = true
        setShadowLayer(4f, 2f, 2f, Color.BLACK)
    }

    private var overlayOperations: List<EditOperation> = emptyList()
    private val bitmapCache = mutableMapOf<String, Bitmap>()

    private fun loadBitmapFromUri(uri: android.net.Uri): Bitmap? {
        val cacheKey = uri.toString()
        if (bitmapCache.containsKey(cacheKey)) {
            return bitmapCache[cacheKey]
        }
        try {
            val bitmap = if (uri.scheme == "content") {
                context.contentResolver.openInputStream(uri)?.use { inputStream ->
                    BitmapFactory.decodeStream(inputStream)
                }
            } else {
                val path = uri.path
                if (path != null && File(path).exists()) {
                    BitmapFactory.decodeFile(path)
                } else {
                    null
                }
            }
            if (bitmap != null) {
                bitmapCache[cacheKey] = bitmap
                return bitmap
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }

    private var videoWidth = 0
    private var videoHeight = 0
    var currentPositionMs: Long = 0L
        set(value) {
            field = value
            invalidate()
        }
    var hiddenOperationId: String? = null
        set(value) {
            field = value
            invalidate()
        }

    fun setTextOperations(operations: List<EditOperation.AddText>) {
        this.overlayOperations = operations
        invalidate()
    }

    fun setOverlayOperations(operations: List<EditOperation>) {
        this.overlayOperations = operations
        invalidate()
    }

    fun setVideoSize(width: Int, height: Int) {
        this.videoWidth = width
        this.videoHeight = height
        invalidate()
    }

    private fun getVideoRect(): android.graphics.RectF {
        val rect = android.graphics.RectF()
        if (width <= 0 || height <= 0 || videoWidth <= 0 || videoHeight <= 0) {
            rect.set(0f, 0f, width.toFloat(), height.toFloat())
            return rect
        }

        val containerRatio = width.toFloat() / height
        val videoRatio = videoWidth.toFloat() / videoHeight

        if (videoRatio > containerRatio) {
            val h = width / videoRatio
            val top = (height - h) / 2f
            rect.set(0f, top, width.toFloat(), top + h)
        } else {
            val w = height * videoRatio
            val left = (width - w) / 2f
            rect.set(left, 0f, left + w, height.toFloat())
        }
        return rect
    }

    private fun interpolateKeyframes(
        keyframes: List<EditOperation.KeyframePoint>,
        timeMs: Long,
        defaultValue: Float
    ): Float {
        if (keyframes.isEmpty()) return defaultValue
        val sorted = keyframes.sortedBy { it.timeMs }
        if (timeMs <= sorted.first().timeMs) {
            return sorted.first().valueX
        }
        if (timeMs >= sorted.last().timeMs) {
            return sorted.last().valueX
        }
        for (i in 0 until sorted.size - 1) {
            val k1 = sorted[i]
            val k2 = sorted[i + 1]
            if (timeMs >= k1.timeMs && timeMs <= k2.timeMs) {
                val progress = (timeMs - k1.timeMs).toFloat() / (k2.timeMs - k1.timeMs)
                return k1.valueX + progress * (k2.valueX - k1.valueX)
            }
        }
        return defaultValue
    }

    private fun interpolateKeyframePosition(
        keyframes: List<EditOperation.KeyframePoint>,
        timeMs: Long,
        defaultX: Float,
        defaultY: Float
    ): Pair<Float, Float> {
        if (keyframes.isEmpty()) return Pair(defaultX, defaultY)
        val sorted = keyframes.sortedBy { it.timeMs }
        if (timeMs <= sorted.first().timeMs) {
            return Pair(sorted.first().valueX, sorted.first().valueY)
        }
        if (timeMs >= sorted.last().timeMs) {
            return Pair(sorted.last().valueX, sorted.last().valueY)
        }
        for (i in 0 until sorted.size - 1) {
            val k1 = sorted[i]
            val k2 = sorted[i + 1]
            if (timeMs >= k1.timeMs && timeMs <= k2.timeMs) {
                val progress = (timeMs - k1.timeMs).toFloat() / (k2.timeMs - k1.timeMs)
                val x = k1.valueX + progress * (k2.valueX - k1.valueX)
                val y = k1.valueY + progress * (k2.valueY - k1.valueY)
                return Pair(x, y)
            }
        }
        return Pair(defaultX, defaultY)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val videoRect = getVideoRect()
        val scale = if (videoHeight > 0) videoRect.height() / videoHeight.toFloat() else 1f

        for (op in overlayOperations) {
            if (op is EditOperation.AddText) {
                if (op.id == hiddenOperationId) continue
                val start = op.startTimeMs ?: 0L
                val end = op.endTimeMs ?: Long.MAX_VALUE
                if (currentPositionMs < start || currentPositionMs > end) continue

                paint.textSize = op.fontSize * scale

                val relativeTimeMs = currentPositionMs - start
                val interpolatedPos = if (op.positionKeyframes.isNotEmpty()) {
                    interpolateKeyframePosition(op.positionKeyframes, relativeTimeMs, op.relativeX ?: 0.5f, op.relativeY ?: 0.5f)
                } else {
                    Pair(op.relativeX, op.relativeY)
                }
                val interpolatedOpacity = if (op.opacityKeyframes.isNotEmpty()) {
                    interpolateKeyframes(op.opacityKeyframes, relativeTimeMs, op.opacity)
                } else {
                    op.opacity
                }

                val alphaInt = (interpolatedOpacity * 255).toInt().coerceIn(0, 255)
                com.tharunbirla.librecuts.utils.TextRenderUtils.configPaint(paint, op, alphaInt)

                val lines = op.text.split("\n")
                val textHeight = (paint.descent() - paint.ascent()) + op.lineSpacing * scale
                val totalHeight = lines.size * textHeight
                
                // Find max width among lines
                var maxTextWidth = 0f
                for (line in lines) {
                    val w = paint.measureText(line)
                    if (w > maxTextWidth) maxTextWidth = w
                }

                val startX: Float
                val startY: Float

                val rx = interpolatedPos.first
                val ry = interpolatedPos.second
                val hasCustomPos = rx != null && ry != null || op.positionKeyframes.isNotEmpty()

                if (hasCustomPos) {
                    // WYSIWYG drag-and-drop coordinates (fractional 0.0–1.0) relative to text center
                    val cx = rx ?: 0.5f
                    val cy = ry ?: 0.5f
                    val centerX = videoRect.left + (cx * videoRect.width())
                    val centerY = videoRect.top + (cy * videoRect.height())
                    startX = centerX - (maxTextWidth / 2f)
                    startY = centerY - (totalHeight / 2f) + (textHeight / 2f) - ((paint.ascent() + paint.descent()) / 2f)
                } else {
                    val rectW = videoRect.width()
                    val rectH = videoRect.height()
                    val rectL = videoRect.left
                    val rectT = videoRect.top

                    when (op.position) {
                        TextPosition.TOP_LEFT -> {
                            startX = rectL + 16f
                            startY = rectT + 32f - paint.ascent()
                        }
                        TextPosition.TOP_CENTER -> {
                            startX = rectL + (rectW - maxTextWidth) / 2
                            startY = rectT + 32f - paint.ascent()
                        }
                        TextPosition.TOP_RIGHT -> {
                            startX = rectL + rectW - maxTextWidth - 16f
                            startY = rectT + 32f - paint.ascent()
                        }
                        TextPosition.CENTER_LEFT -> {
                            startX = rectL + 16f
                            startY = rectT + rectH / 2 - totalHeight / 2 - paint.ascent()
                        }
                        TextPosition.CENTER -> {
                            startX = rectL + (rectW - maxTextWidth) / 2
                            startY = rectT + rectH / 2 - totalHeight / 2 - paint.ascent()
                        }
                        TextPosition.CENTER_RIGHT -> {
                            startX = rectL + rectW - maxTextWidth - 16f
                            startY = rectT + rectH / 2 - totalHeight / 2 - paint.ascent()
                        }
                        TextPosition.BOTTOM_LEFT -> {
                            startX = rectL + 16f
                            startY = rectT + rectH - 16f - totalHeight + textHeight - paint.descent()
                        }
                        TextPosition.BOTTOM_CENTER -> {
                            startX = rectL + (rectW - maxTextWidth) / 2
                            startY = rectT + rectH - 16f - totalHeight + textHeight - paint.descent()
                        }
                        TextPosition.BOTTOM_RIGHT -> {
                            startX = rectL + rectW - maxTextWidth - 16f
                            startY = rectT + rectH - 16f - totalHeight + textHeight - paint.descent()
                        }
                        TextPosition.CENTER_BOTTOM -> {
                            startX = rectL + (rectW - maxTextWidth) / 2
                            startY = rectT + rectH - 16f - totalHeight + textHeight - paint.descent()
                        }
                        TextPosition.CENTER_TOP -> {
                            startX = rectL + (rectW - maxTextWidth) / 2
                            startY = rectT + 32f - paint.ascent()
                        }
                    }
                }

                com.tharunbirla.librecuts.utils.TextRenderUtils.drawBlock(
                    canvas, paint, op, lines, maxTextWidth, startX, startY, textHeight, scale)
            }
        }

    }
}
