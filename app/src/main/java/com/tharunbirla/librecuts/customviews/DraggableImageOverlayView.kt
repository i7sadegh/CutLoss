package com.tharunbirla.librecuts.customviews

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.util.AttributeSet
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.appcompat.widget.AppCompatImageView
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.util.Log

class DraggableImageOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    // ── Public callbacks ──────────────────────────────────────────────────────
    var onImageCommitted: ((uri: Uri, relativeX: Float, relativeY: Float, relativeWidth: Float, relativeHeight: Float, rotationAngle: Float, opacity: Float) -> Unit)? = null
    var onPositionChanged: ((relativeX: Float, relativeY: Float) -> Unit)? = null

    // ── State ─────────────────────────────────────────────────────────────────
    private var isEditingActive = false
    private var relativeX = 0.5f  // center default
    private var relativeY = 0.5f
    private var relativeWidth = 0.3f
    private var relativeHeight = 0.3f
    private var rotationAngle = 0f
    private var opacity = 1.0f
    
    
    private var videoWidth = 0
    private var videoHeight = 0
    private var imageAspectRatio = 1.0f
    private var imageUri: Uri? = null

    // ── Snap & Drag tracking ──────────────────────────────────────────────────
    var isSnappingEnabled = true
    private var showVerticalGuideline = false
    private var showHorizontalGuideline = false
    private var isDragging = false
    private var dragOffsetX = 0f
    private var dragOffsetY = 0f

    private val guidelinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#CEC0EC")
        style = Paint.Style.STROKE
        strokeWidth = 3f
        pathEffect = android.graphics.DashPathEffect(floatArrayOf(15f, 10f), 0f)
    }

    // ── UI components ─────────────────────────────────────────────────────────
    private val imageView: ImageView = AppCompatImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
        adjustViewBounds = true
    }

    // ── Selection border paint ────────────────────────────────────────────────
    private val selectionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#99FFFFFF")
        style = Paint.Style.STROKE
        strokeWidth = 2f
        pathEffect = DashPathEffect(floatArrayOf(12f, 8f), 0f)
    }

    private val selectionRect = RectF()

    private val cornerHandlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 5f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        setShadowLayer(5f, 0f, 1f, Color.parseColor("#99000000"))
    }
    
    private val cornerPath = android.graphics.Path()

    private val handleFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#FF2A6D")
        style = Paint.Style.FILL
    }
    
    private val handleStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#FFFFFF")
        style = Paint.Style.STROKE
        strokeWidth = 3f
    }

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val scaleFactor = detector.scaleFactor
            relativeWidth = (relativeWidth * scaleFactor).coerceIn(0.05f, 5.0f)
            val videoRatio = if (videoHeight > 0) videoWidth.toFloat() / videoHeight else 1.0f
            relativeHeight = relativeWidth * videoRatio / imageAspectRatio
            syncRelativePositionFromVisual()
            updateImageViewSizeAndPosition()
            return true
        }
    })

    init {
        visibility = GONE
        val imageViewParams = LayoutParams(
            LayoutParams.WRAP_CONTENT,
            LayoutParams.WRAP_CONTENT
        ).apply {
            gravity = Gravity.CENTER
        }
        addView(imageView, imageViewParams)
        setWillNotDraw(false)
    }

    fun setVideoSize(width: Int, height: Int) {
        this.videoWidth = width
        this.videoHeight = height
        post {
            updateImageViewSizeAndPosition()
        }
    }

    private fun getVideoRect(): RectF {
        val rect = RectF()
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

    private fun updateImageViewSizeAndPosition() {
        if (width <= 0 || height <= 0 || imageUri == null) return
        // round 9: never fight an active drag -- external reposition calls
        // (setVideoSize / setProperties / keyframe ticks) used to snap the
        // image back to its last committed relative position mid-drag.
        if (isDragging) return
        val videoRect = getVideoRect()

        // Calculate size on screen based on relative width/height
        val widthOnScreen = relativeWidth * videoRect.width()
        val heightOnScreen = relativeHeight * videoRect.height()

        imageView.layoutParams = LayoutParams(widthOnScreen.toInt(), heightOnScreen.toInt())

        // Calculate position on screen
        val targetCenterX = videoRect.left + (relativeX * videoRect.width())
        val targetCenterY = videoRect.top + (relativeY * videoRect.height())

        imageView.x = targetCenterX - widthOnScreen / 2f
        imageView.y = targetCenterY - heightOnScreen / 2f
        
        imageView.rotation = rotationAngle
        invalidate()
    }

    // round 9: derive relativeX/relativeY from where the image currently
    // sits on screen (used after drags and before pinch-driven resizing so
    // a scale keeps the visual anchor instead of recentering).
    private fun syncRelativePositionFromVisual() {
        if (width <= 0 || height <= 0 || imageView.width <= 0) return
        val videoRect = getVideoRect()
        val centerX = imageView.x + imageView.width / 2f
        val centerY = imageView.y + imageView.height / 2f
        relativeX = if (videoRect.width() > 0) ((centerX - videoRect.left) / videoRect.width()).coerceIn(0f, 1f) else relativeX
        relativeY = if (videoRect.height() > 0) ((centerY - videoRect.top) / videoRect.height()).coerceIn(0f, 1f) else relativeY
    }

    private fun updateRelativePosition() {
        if (width <= 0 || height <= 0) return
        syncRelativePositionFromVisual()
        onPositionChanged?.invoke(relativeX, relativeY)
    }

    // ── Public API ────────────────────────────────────────────────────────────

    private fun getMediaAspectRatio(uri: Uri): Float {
        val path = uri.path ?: return 1.0f
        val isGif = path.endsWith(".gif", ignoreCase = true)
        val isVideo = path.endsWith(".mp4", ignoreCase = true) ||
                      path.endsWith(".mkv", ignoreCase = true) ||
                      path.endsWith(".mov", ignoreCase = true) ||
                      path.endsWith(".3gp", ignoreCase = true)
        if (isGif) {
            try {
                val movie = android.graphics.Movie.decodeFile(path)
                if (movie != null && movie.width() > 0 && movie.height() > 0) {
                    return movie.width().toFloat() / movie.height().toFloat()
                }
            } catch (e: Exception) {
                Log.e("DraggableImage", "Error getting GIF aspect: ${e.message}")
            }
        } else if (isVideo) {
            try {
                val retriever = android.media.MediaMetadataRetriever()
                retriever.setDataSource(path)
                val wStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                val hStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                val rStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                val w = wStr?.toIntOrNull() ?: 1
                val h = hStr?.toIntOrNull() ?: 1
                val r = rStr?.toIntOrNull() ?: 0
                retriever.release()
                val isSwapped = r == 90 || r == 270
                return if (isSwapped) h.toFloat() / w else w.toFloat() / h
            } catch (e: Exception) {
                Log.e("DraggableImage", "Error getting video aspect: ${e.message}")
            }
        } else {
            try {
                var rotation = 0
                try {
                    val exif = android.media.ExifInterface(path)
                    val orientation = exif.getAttributeInt(
                        android.media.ExifInterface.TAG_ORIENTATION,
                        android.media.ExifInterface.ORIENTATION_NORMAL
                    )
                    when (orientation) {
                        android.media.ExifInterface.ORIENTATION_ROTATE_90 -> rotation = 90
                        android.media.ExifInterface.ORIENTATION_ROTATE_180 -> rotation = 180
                        android.media.ExifInterface.ORIENTATION_ROTATE_270 -> rotation = 270
                    }
                } catch (e: Exception) {
                    // Ignore exif load failure
                }

                val options = BitmapFactory.Options().apply {
                    inJustDecodeBounds = true
                }
                BitmapFactory.decodeFile(path, options)
                if (options.outHeight > 0) {
                    val isSwapped = rotation == 90 || rotation == 270
                    return if (isSwapped) options.outHeight.toFloat() / options.outWidth else options.outWidth.toFloat() / options.outHeight
                }
            } catch (e: Exception) {
                Log.e("DraggableImage", "Error getting image aspect: ${e.message}")
            }
        }
        return 1.0f
    }

    fun activate(uri: Uri, aspect: Float = 1.0f) {
        isEditingActive = true
        imageUri = uri
        
        val trueAspect = getMediaAspectRatio(uri)
        imageAspectRatio = trueAspect
        relativeX = 0.5f
        relativeY = 0.5f
        relativeWidth = 0.3f
        val videoRatio = if (videoHeight > 0) videoWidth.toFloat() / videoHeight else 1.0f
        relativeHeight = relativeWidth * videoRatio / imageAspectRatio
        rotationAngle = 0f
        opacity = 1.0f
        imageView.alpha = opacity

        loadOverlayMedia(uri)

        visibility = VISIBLE
        post {
            updateImageViewSizeAndPosition()
        }
    }

    fun activateForEdit(op: com.tharunbirla.librecuts.models.EditOperation.AddImageOverlay) {
        isEditingActive = true
        imageUri = op.imageUri
        val videoRatio = if (videoHeight > 0) videoWidth.toFloat() / videoHeight else 1.0f
        
        val trueAspect = getMediaAspectRatio(op.imageUri)
        imageAspectRatio = trueAspect
        relativeX = op.relativeX
        relativeY = op.relativeY
        relativeWidth = op.relativeWidth
        relativeHeight = relativeWidth * videoRatio / imageAspectRatio
        rotationAngle = op.rotationAngle
        opacity = op.opacity

        loadOverlayMedia(op.imageUri)

        imageView.rotation = rotationAngle
        imageView.alpha = opacity
        visibility = VISIBLE
        post {
            updateImageViewSizeAndPosition()
        }
    }

    private fun loadOverlayMedia(uri: Uri) {
        val path = uri.path
        if (path != null) {
            val isGif = path.endsWith(".gif", ignoreCase = true)
            val isVideo = path.endsWith(".mp4", ignoreCase = true) ||
                          path.endsWith(".mkv", ignoreCase = true) ||
                          path.endsWith(".mov", ignoreCase = true) ||
                          path.endsWith(".3gp", ignoreCase = true)

            if (isGif && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                try {
                    val source = android.graphics.ImageDecoder.createSource(context.contentResolver, uri)
                    val drawable = android.graphics.ImageDecoder.decodeDrawable(source)
                    imageView.setImageDrawable(drawable)
                    if (drawable is android.graphics.drawable.AnimatedImageDrawable) {
                        drawable.repeatCount = android.graphics.drawable.AnimatedImageDrawable.REPEAT_INFINITE
                        drawable.start()
                    } else if (drawable is android.graphics.drawable.Animatable) {
                        drawable.start()
                    }
                } catch (e: Exception) {
                    imageView.setImageURI(uri)
                }
            } else if (isVideo) {
                try {
                    val retriever = android.media.MediaMetadataRetriever()
                    retriever.setDataSource(path)
                    val bitmap = retriever.getFrameAtTime(0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    imageView.setImageBitmap(bitmap)
                    retriever.release()
                } catch (e: Exception) {
                    imageView.setImageURI(uri)
                }
            } else {
                imageView.setImageURI(uri)
            }
        } else {
            imageView.setImageURI(uri)
        }
    }

    fun deactivate() {
        isEditingActive = false
        visibility = GONE
        imageUri = null
    }

    fun setRotationAngle(angle: Float) {
        rotationAngle = angle
        imageView.rotation = rotationAngle
        invalidate()
    }

    fun setOpacity(value: Float) {
        opacity = value
        imageView.alpha = opacity
        invalidate()
    }
    
    fun setScaleWidth(w: Float) {
        relativeWidth = w.coerceIn(0.05f, 5.0f)
        val videoRatio = if (videoHeight > 0) videoWidth.toFloat() / videoHeight else 1.0f
        relativeHeight = relativeWidth * videoRatio / imageAspectRatio
        syncRelativePositionFromVisual()
        updateImageViewSizeAndPosition()
    }

    fun commitImage() {
        val uri = imageUri
        if (uri != null) {
            updateRelativePosition()
            onImageCommitted?.invoke(uri, relativeX, relativeY, relativeWidth, relativeHeight, rotationAngle, opacity)
        }
        deactivate()
    }

    // ── Touch handling for drag and scale ───────────────────────────────────────

    @SuppressLint("ClickableViewAccessibility")
    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        if (!isEditingActive) return false

        scaleDetector.onTouchEvent(ev)

        if (scaleDetector.isInProgress || ev.pointerCount > 1) {
            return true
        }

        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val touchX = ev.x
                val touchY = ev.y
                val imgLeft = imageView.x
                val imgTop = imageView.y
                val imgRight = imageView.x + imageView.width
                val imgBottom = imageView.y + imageView.height

                // Check if touch is inside the image bounds
                if (touchX in imgLeft..imgRight && touchY in imgTop..imgBottom) {
                    isDragging = true
                    dragOffsetX = touchX - imageView.x
                    dragOffsetY = touchY - imageView.y
                    return true
                }
            }
        }
        return false
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEditingActive) return false

        scaleDetector.onTouchEvent(event)

        if (scaleDetector.isInProgress || event.pointerCount > 1) {
            isDragging = false
            return true
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // round 9: the press must land on the image itself
                // (plus room for the selection handles) -- presses on
                // empty canvas no longer yank the overlay around.
                val slop = 32f
                val inX = event.x >= imageView.x - slop && event.x <= imageView.x + imageView.width + slop
                val inY = event.y >= imageView.y - slop && event.y <= imageView.y + imageView.height + slop
                if (!inX || !inY) return false
                isDragging = true
                dragOffsetX = event.x - imageView.x
                dragOffsetY = event.y - imageView.y
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (isDragging) {
                    val videoRect = getVideoRect()
                    val centerX = event.x - dragOffsetX + imageView.width / 2f
                    val centerY = event.y - dragOffsetY + imageView.height / 2f

                    val constrainedCenterX = centerX.coerceIn(videoRect.left, videoRect.right)
                    val constrainedCenterY = centerY.coerceIn(videoRect.top, videoRect.bottom)

                    val videoCenterX = videoRect.centerX()
                    val videoCenterY = videoRect.centerY()
                    val threshold = 16f

                    var snappedX = constrainedCenterX
                    var snappedY = constrainedCenterY

                    if (isSnappingEnabled) {
                        if (Math.abs(constrainedCenterX - videoCenterX) < threshold) {
                            snappedX = videoCenterX
                            showVerticalGuideline = true
                        } else {
                            showVerticalGuideline = false
                        }
                        if (Math.abs(constrainedCenterY - videoCenterY) < threshold) {
                            snappedY = videoCenterY
                            showHorizontalGuideline = true
                        } else {
                            showHorizontalGuideline = false
                        }
                    } else {
                        showVerticalGuideline = false
                        showHorizontalGuideline = false
                    }

                    imageView.x = snappedX - imageView.width / 2f
                    imageView.y = snappedY - imageView.height / 2f
                    invalidate()
                    return true
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (isDragging) {
                    isDragging = false
                    showVerticalGuideline = false
                    showHorizontalGuideline = false
                    updateRelativePosition()
                    return true
                }
            }
        }
        return super.onTouchEvent(event)
    }

    // ── Drawing ───────────────────────────────────────────────────────────────

    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)

        if (isEditingActive && imageUri != null) {
            val videoRect = getVideoRect()
            if (showVerticalGuideline) {
                canvas.drawLine(videoRect.centerX(), videoRect.top, videoRect.centerX(), videoRect.bottom, guidelinePaint)
            }
            if (showHorizontalGuideline) {
                canvas.drawLine(videoRect.left, videoRect.centerY(), videoRect.right, videoRect.centerY(), guidelinePaint)
            }

            // Draw selection bounds around rotated image
            canvas.save()
            canvas.rotate(rotationAngle, imageView.x + imageView.width / 2f, imageView.y + imageView.height / 2f)
            selectionRect.set(
                imageView.x - 4f,
                imageView.y - 4f,
                imageView.x + imageView.width + 4f,
                imageView.y + imageView.height + 4f
            )
            canvas.drawRect(selectionRect, selectionPaint)

            // Draw 4 modern curved corner bracket handles touching the border
            val bracketLength = 22f
            val cornerRadius = 8f

            // Top-Left Corner
            cornerPath.reset()
            cornerPath.moveTo(selectionRect.left + bracketLength, selectionRect.top)
            cornerPath.lineTo(selectionRect.left + cornerRadius, selectionRect.top)
            cornerPath.quadTo(selectionRect.left, selectionRect.top, selectionRect.left, selectionRect.top + cornerRadius)
            cornerPath.lineTo(selectionRect.left, selectionRect.top + bracketLength)
            canvas.drawPath(cornerPath, cornerHandlePaint)

            // Top-Right Corner
            cornerPath.reset()
            cornerPath.moveTo(selectionRect.right - bracketLength, selectionRect.top)
            cornerPath.lineTo(selectionRect.right - cornerRadius, selectionRect.top)
            cornerPath.quadTo(selectionRect.right, selectionRect.top, selectionRect.right, selectionRect.top + cornerRadius)
            cornerPath.lineTo(selectionRect.right, selectionRect.top + bracketLength)
            canvas.drawPath(cornerPath, cornerHandlePaint)

            // Bottom-Left Corner
            cornerPath.reset()
            cornerPath.moveTo(selectionRect.left + bracketLength, selectionRect.bottom)
            cornerPath.lineTo(selectionRect.left + cornerRadius, selectionRect.bottom)
            cornerPath.quadTo(selectionRect.left, selectionRect.bottom, selectionRect.left, selectionRect.bottom - cornerRadius)
            cornerPath.lineTo(selectionRect.left, selectionRect.bottom - bracketLength)
            canvas.drawPath(cornerPath, cornerHandlePaint)

            // Bottom-Right Corner
            cornerPath.reset()
            cornerPath.moveTo(selectionRect.right - bracketLength, selectionRect.bottom)
            cornerPath.lineTo(selectionRect.right - cornerRadius, selectionRect.bottom)
            cornerPath.quadTo(selectionRect.right, selectionRect.bottom, selectionRect.right, selectionRect.bottom - cornerRadius)
            cornerPath.lineTo(selectionRect.right, selectionRect.bottom - bracketLength)
            canvas.drawPath(cornerPath, cornerHandlePaint)

            canvas.restore()
            

        }
    }

    fun getRelativeX(): Float = relativeX
    fun getRelativeY(): Float = relativeY
    fun getRelativeWidth(): Float = relativeWidth
    fun getRelativeHeight(): Float = relativeHeight
    fun getRotationAngle(): Float = rotationAngle
    fun getOpacity(): Float = opacity

    fun setProperties(rx: Float, ry: Float, rw: Float, rh: Float, rot: Float, op: Float) {
        relativeX = rx
        relativeY = ry
        relativeWidth = rw
        relativeHeight = rh
        rotationAngle = rot
        setOpacity(op)
        updateImageViewSizeAndPosition()
    }


}
