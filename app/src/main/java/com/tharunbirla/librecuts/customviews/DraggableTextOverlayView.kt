package com.tharunbirla.librecuts.customviews

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Editable
import android.text.TextWatcher
import android.util.AttributeSet
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout

/**
 * DraggableTextOverlayView provides an inline, draggable text editing experience
 * directly on top of the video viewport.
 *
 * When activated, it spawns a transparent EditText at the center of the viewport.
 * The user can:
 *   - Type text and see it live on the video canvas
 *   - Drag the text to any position on the viewport
 *   - Adjust font size via external controls (the text editing toolbar)
 *
 * On commit, it reports the text, font size, and fractional position (0.0–1.0)
 * relative to the viewport dimensions — these map directly to FFmpeg drawtext
 * coordinates: x='w*relX':y='h*relY'
 */
class DraggableTextOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

    // ── Public callbacks ──────────────────────────────────────────────────────
    /** Called when the user commits the text (taps Done). */
    var onTextCommitted: ((text: String, fontSize: Int, relativeX: Float, relativeY: Float, color: String, fontPath: String?, opacity: Float, borderThickness: Int, borderColor: String, textAlign: String, letterSpacing: Float, lineSpacing: Float, bold: Boolean, italic: Boolean, underline: Boolean, strikethrough: Boolean, bgColor: String?, bgOpacity: Float, bgCornerRadius: Int, bgMargin: Int, strokeOpacity: Float, shadowColor: String?, shadowOpacity: Float, shadowBlur: Int, shadowAngle: Int, shadowWidth: Int) -> Unit)? = null

    /** Called when the text content changes (for live preview feedback). */
    var onTextChanged: ((text: String) -> Unit)? = null

    /** Called when the user taps the text to edit (keyboard opens). */
    var onEditingFocused: (() -> Unit)? = null
    var onPositionChanged: ((relativeX: Float, relativeY: Float) -> Unit)? = null

    // ── State ─────────────────────────────────────────────────────────────────
    private var isEditingActive = false
    private var currentFontSize = 36
    private var relativeX = 0.5f  // center default
    private var relativeY = 0.5f
    private var videoWidth = 0
    private var videoHeight = 0
    private var currentColorString = "#FFFFFF"

    private var currentOpacity = 1.0f
    private var currentBorderThickness = 0
    private var currentBorderColor = "#000000"
    private var currentTextAlign = "center"
    private var currentLetterSpacing = 0f
    private var currentLineSpacing = 0f
    var currentFontPath: String? = null
    private var currentBold = false
    private var currentItalic = false
    private var currentUnderline = false
    private var currentStrikethrough = false
    private var currentBgColor: String? = null
    private var currentBgOpacity = 1.0f
    private var currentBgCornerRadius = 0
    private var currentBgMargin = 0
    private var currentStrokeOpacity = 1.0f
    private var currentShadowColor: String? = null
    private var currentShadowOpacity = 1.0f
    private var currentShadowBlur = 0
    private var currentShadowAngle = 0
    private var currentShadowWidth = 0

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val scaleFactor = detector.scaleFactor
            val newSize = (currentFontSize * scaleFactor).toInt().coerceIn(12, 2000)
            if (newSize != currentFontSize) {
                setFontSize(newSize)
            }
            return true
        }
    })

    fun setTextColor(colorString: String) {
        currentColorString = colorString
        try {
            editText.setTextColor(Color.parseColor(colorString))
        } catch (e: Exception) {
            editText.setTextColor(Color.WHITE)
        }
        invalidate()
    }

    fun getTextColor(): String = currentColorString

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
        pathEffect = DashPathEffect(floatArrayOf(15f, 10f), 0f)
    }

    // ── UI components ─────────────────────────────────────────────────────────
    private val editText: EditText = EditText(context).apply {
        setBackgroundColor(Color.TRANSPARENT)
        setTextColor(Color.WHITE)
        // Text size set in pixels later
        setPadding(16, 8, 16, 8)
        hint = "Type here"
        setHintTextColor(Color.argb(100, 255, 255, 255))
        gravity = Gravity.CENTER
        isSingleLine = false
        maxLines = 5
        isCursorVisible = true

        // Shadow for readability on any video background
        setShadowLayer(4f, 2f, 2f, Color.BLACK)
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

    fun setVideoSize(width: Int, height: Int) {
        this.videoWidth = width
        this.videoHeight = height
        post {
            updateFontSizeOnScreen()
            positionEditTextFromRelative()
            invalidate()
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

    private fun updateFontSizeOnScreen() {
        val videoRect = getVideoRect()
        val scale = if (videoHeight > 0) videoRect.height() / videoHeight.toFloat() else 1f
        val fontSizeOnScreen = currentFontSize * scale
        editText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, fontSizeOnScreen)
    }

    init {
        // Initially hidden until activated
        visibility = GONE

        // Add the EditText as a child
        val editTextParams = LayoutParams(
            LayoutParams.WRAP_CONTENT,
            LayoutParams.WRAP_CONTENT
        ).apply {
            gravity = Gravity.CENTER
        }
        addView(editText, editTextParams)

        // Track text changes
        editText.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                onTextChanged?.invoke(s?.toString() ?: "")
            }
            override fun afterTextChanged(s: Editable?) {}
        })

        editText.setOnFocusChangeListener { _, hasFocus ->
            if (hasFocus) {
                onEditingFocused?.invoke()
            }
        }
        
        editText.setOnClickListener {
            onEditingFocused?.invoke()
        }

        // Allow this view to draw over its children (for the selection border)
        setWillNotDraw(false)
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /** Activate the text editing mode with an optional pre-filled text. */
    fun activate(initialText: String = "", fontSize: Int = 36) {
        isEditingActive = true
        currentFontSize = fontSize
        relativeX = 0.5f
        relativeY = 0.5f
        currentColorString = "#FFFFFF"
        currentFontPath = null
        currentBold = false
        currentItalic = false
        currentUnderline = false
        currentStrikethrough = false
        currentBgColor = null
        currentBgOpacity = 1.0f
        currentBgCornerRadius = 0
        currentBgMargin = 0
        currentStrokeOpacity = 1.0f
        currentShadowColor = null
        currentShadowOpacity = 1.0f
        currentShadowBlur = 0
        currentShadowAngle = 0
        currentShadowWidth = 0
        applyTypefaceAndFlags()
        refreshEditTextBackground()
        refreshTextEffects()

        editText.setText(initialText)
        editText.setTextColor(Color.WHITE)
        updateFontSizeOnScreen()
        visibility = VISIBLE

        // Position at center
        post {
            positionEditTextFromRelative()
            editText.requestFocus()
            showKeyboard()
        }
    }

    /** Activate for re-editing an existing text operation. */
    fun activateForEdit(op: com.tharunbirla.librecuts.models.EditOperation.AddText) {
        isEditingActive = true
        currentFontSize = op.fontSize
        relativeX = op.relativeX ?: 0.5f
        relativeY = op.relativeY ?: 0.5f
        currentColorString = op.color
        currentOpacity = op.opacity
        currentBorderThickness = op.borderThickness
        currentBorderColor = op.borderColor
        currentTextAlign = op.textAlign
        currentLetterSpacing = op.letterSpacing
        currentLineSpacing = op.lineSpacing
        currentFontPath = op.fontPath
        currentBold = op.bold
        currentItalic = op.italic
        currentUnderline = op.underline
        currentStrikethrough = op.strikethrough
        currentBgColor = op.bgColor
        currentBgOpacity = op.bgOpacity
        currentBgCornerRadius = op.bgCornerRadius
        currentBgMargin = op.bgMargin
        currentStrokeOpacity = op.strokeOpacity ?: 1.0f
        currentShadowColor = op.shadowColor
        currentShadowOpacity = op.shadowOpacity
        currentShadowBlur = op.shadowBlur
        currentShadowAngle = op.shadowAngle
        currentShadowWidth = op.shadowWidth

        setFontPath(op.fontPath)
        editText.setText(op.text)
        try {
            editText.setTextColor(Color.parseColor(op.color))
        } catch (e: Exception) {
            editText.setTextColor(Color.WHITE)
        }
        updateFontSizeOnScreen()
        visibility = VISIBLE
        refreshEditTextBackground()
        refreshTextEffects()

        post {
            positionEditTextFromRelative()
            editText.requestFocus()
        }
    }

    /** Deactivate and hide the text editor. */
    fun deactivate() {
        isEditingActive = false
        visibility = GONE
        hideKeyboard()
        editText.setText("")
    }

    /** Expose a way to focus the input field and pop the keyboard. */
    fun requestEditingFocus() {
        editText.requestFocus()
        showKeyboard()
    }

    /** Commit the current text and position, invoke the callback. */
    fun commitText() {
        val text = editText.text.toString().trim()
        if (text.isNotEmpty()) {
            // Compute final relative position from EditText's current layout position
            updateRelativePosition()
            onTextCommitted?.invoke(
                text, currentFontSize, relativeX, relativeY, currentColorString,
                currentFontPath, currentOpacity, currentBorderThickness, currentBorderColor, currentTextAlign, currentLetterSpacing, currentLineSpacing,
                currentBold, currentItalic, currentUnderline, currentStrikethrough, currentBgColor, currentBgOpacity, currentBgCornerRadius, currentBgMargin,
                currentStrokeOpacity, currentShadowColor, currentShadowOpacity, currentShadowBlur, currentShadowAngle, currentShadowWidth
            )
        }
        deactivate()
    }

    /** Get the current text. */
    fun getText(): String = editText.text.toString()

    /** Update the font size from external toolbar. */
    fun setFontSize(size: Int) {
        currentFontSize = size.coerceIn(8, 500)
        updateFontSizeOnScreen()
        invalidate()
    }

    fun setFontPath(fontPath: String?) {
        currentFontPath = fontPath
        applyTypefaceAndFlags()
    }

    // New format setters
    fun setOpacity(opacity: Float) {
        currentOpacity = opacity.coerceIn(0f, 1f)
        try {
            val colorInt = Color.parseColor(currentColorString)
            editText.setTextColor(Color.argb((currentOpacity * 255).toInt(), Color.red(colorInt), Color.green(colorInt), Color.blue(colorInt)))
        } catch (e: Exception) {}
        invalidate()
    }

    // -- Stroke + shadow setters (CutStudio round 6) --
    fun setStrokeColor(hex: String) { currentBorderColor = hex; refreshTextEffects() }
    fun setStrokeOpacity(value: Float) { currentStrokeOpacity = value.coerceIn(0f, 1f); refreshTextEffects() }
    fun setStrokeWidth(width: Int) { currentBorderThickness = width.coerceAtLeast(0); refreshTextEffects() }
    fun setShadowColor(hex: String?) { currentShadowColor = hex; refreshTextEffects() }
    fun setShadowOpacity(value: Float) { currentShadowOpacity = value.coerceIn(0f, 1f); refreshTextEffects() }
    fun setShadowBlur(value: Int) { currentShadowBlur = value.coerceAtLeast(0); refreshTextEffects() }
    fun setShadowAngle(value: Int) { currentShadowAngle = value.coerceIn(0, 360); refreshTextEffects() }
    fun setShadowWidth(value: Int) { currentShadowWidth = value.coerceAtLeast(0); refreshTextEffects() }

    fun getStrokeColor(): String = currentBorderColor
    fun getStrokeOpacity(): Float = currentStrokeOpacity
    fun getStrokeWidth(): Int = currentBorderThickness
    fun getShadowColor(): String? = currentShadowColor
    fun getShadowOpacity(): Float = currentShadowOpacity
    fun getShadowBlur(): Int = currentShadowBlur
    fun getShadowAngle(): Int = currentShadowAngle
    fun getShadowWidth(): Int = currentShadowWidth

    /**
     * Live preview on the EditText (only one shadow layer is possible).
     * Stroke wins over shadow while both are active; the committed render
     * in TextRenderUtils draws both of them exactly.
     */
    private fun refreshTextEffects() {
        val shadowHex = currentShadowColor
        if (currentBorderThickness > 0) {
            val c = try { Color.parseColor(currentBorderColor) } catch (e: Exception) { Color.BLACK }
            val a = (currentStrokeOpacity.coerceIn(0f, 1f) * 255).toInt().coerceIn(0, 255)
            editText.setShadowLayer((currentBorderThickness * 1.2f).coerceAtLeast(1f), 0f, 0f,
                Color.argb(a, Color.red(c), Color.green(c), Color.blue(c)))
        } else if (shadowHex != null && (currentShadowWidth > 0 || currentShadowBlur > 0)) {
            val c = try { Color.parseColor(shadowHex) } catch (e: Exception) { Color.BLACK }
            val a = (currentShadowOpacity.coerceIn(0f, 1f) * 255).toInt().coerceIn(0, 255)
            val rad = Math.toRadians(currentShadowAngle.toDouble())
            val dx = (currentShadowWidth * Math.cos(rad)).toFloat()
            val dy = (currentShadowWidth * Math.sin(rad)).toFloat()
            editText.setShadowLayer(currentShadowBlur.toFloat(), dx, dy,
                Color.argb(a, Color.red(c), Color.green(c), Color.blue(c)))
        } else {
            editText.setShadowLayer(4f, 2f, 2f, Color.BLACK)
        }
    }

    fun setLetterSpacing(spacing: Float) {
        currentLetterSpacing = spacing
        editText.letterSpacing = spacing
    }

    fun setLineSpacing(spacing: Float) {
        currentLineSpacing = spacing
        editText.setLineSpacing(spacing, 1f)
    }

    fun setTextAlign(align: String) {
        currentTextAlign = align
        when (align) {
            "left", "L" -> editText.gravity = Gravity.START or Gravity.CENTER_VERTICAL
            "right", "R" -> editText.gravity = Gravity.END or Gravity.CENTER_VERTICAL
            else -> editText.gravity = Gravity.CENTER
        }
    }

    // -- Style + background setters (CutStudio round 5) --
    fun setBold(on: Boolean) { currentBold = on; applyTypefaceAndFlags() }
    fun setItalic(on: Boolean) { currentItalic = on; applyTypefaceAndFlags() }
    fun setUnderline(on: Boolean) { currentUnderline = on; applyTypefaceAndFlags() }
    fun setStrikethrough(on: Boolean) { currentStrikethrough = on; applyTypefaceAndFlags() }
    fun setBgColor(hex: String?) { currentBgColor = hex; refreshEditTextBackground() }
    fun setBgOpacity(value: Float) { currentBgOpacity = value.coerceIn(0f, 1f); refreshEditTextBackground() }
    fun setBgCornerRadius(value: Int) { currentBgCornerRadius = value.coerceAtLeast(0); refreshEditTextBackground() }
    fun setBgMargin(value: Int) { currentBgMargin = value.coerceAtLeast(0); refreshEditTextBackground() }

    fun getBold(): Boolean = currentBold
    fun getItalic(): Boolean = currentItalic
    fun getUnderline(): Boolean = currentUnderline
    fun getStrikethrough(): Boolean = currentStrikethrough
    fun getBgColor(): String? = currentBgColor
    fun getBgOpacity(): Float = currentBgOpacity
    fun getBgCornerRadius(): Int = currentBgCornerRadius
    fun getBgMargin(): Int = currentBgMargin

    private fun applyTypefaceAndFlags() {
        val base = try {
            if (currentFontPath.isNullOrBlank()) null else Typeface.createFromFile(currentFontPath)
        } catch (e: Exception) {
            null
        }
        val family = base ?: Typeface.DEFAULT
        val style = when {
            currentBold && currentItalic -> Typeface.BOLD_ITALIC
            currentBold -> Typeface.BOLD
            currentItalic -> Typeface.ITALIC
            else -> Typeface.NORMAL
        }
        editText.typeface = if (style == Typeface.NORMAL) family else Typeface.create(family, style)
        var flags = editText.paintFlags and (Paint.UNDERLINE_TEXT_FLAG or Paint.STRIKE_THRU_TEXT_FLAG).inv()
        if (currentUnderline) flags = flags or Paint.UNDERLINE_TEXT_FLAG
        if (currentStrikethrough) flags = flags or Paint.STRIKE_THRU_TEXT_FLAG
        editText.paintFlags = flags
    }

    private fun refreshEditTextBackground() {
        val hex = currentBgColor
        if (hex == null) {
            editText.background = null
            editText.setPadding(16, 8, 16, 8)
            return
        }
        val scale = if (videoHeight > 0) {
            val rect = getVideoRect()
            if (rect.height() > 0f) rect.height() / videoHeight.toFloat() else 1f
        } else 1f
        val marginPx = (currentBgMargin * scale).toInt().coerceAtLeast(0)
        val radiusPx = (currentBgCornerRadius * scale).coerceAtLeast(0f)
        val baseColor = try { Color.parseColor(hex) } catch (e: Exception) { Color.BLACK }
        val alpha = (currentBgOpacity.coerceIn(0f, 1f) * 255).toInt()
        val drawable = android.graphics.drawable.GradientDrawable().apply {
            cornerRadius = radiusPx
            setColor(Color.argb(alpha, Color.red(baseColor), Color.green(baseColor), Color.blue(baseColor)))
        }
        editText.background = drawable
        editText.setPadding(16 + marginPx, 8 + marginPx / 2, 16 + marginPx, 8 + marginPx / 2)
    }

    /** Increase font size by a step. */
    fun increaseFontSize(step: Int = 2): Int {
        setFontSize(currentFontSize + step)
        return currentFontSize
    }

    /** Decrease font size by a step. */
    fun decreaseFontSize(step: Int = 2): Int {
        setFontSize(currentFontSize - step)
        return currentFontSize
    }

    fun getCurrentFontSize(): Int = currentFontSize

    // ── Touch handling for drag ───────────────────────────────────────────────

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
                val editLeft = editText.left.toFloat()
                val editTop = editText.top.toFloat()
                val editRight = editText.right.toFloat()
                val editBottom = editText.bottom.toFloat()

                if (touchX in editLeft..editRight && touchY in editTop..editBottom) {
                    return false
                }

                isDragging = true
                dragOffsetX = touchX - editText.x
                dragOffsetY = touchY - editText.y
                return true
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
                isDragging = true
                dragOffsetX = event.x - editText.x
                dragOffsetY = event.y - editText.y
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (isDragging) {
                    val videoRect = getVideoRect()
                    val centerX = event.x - dragOffsetX + editText.width / 2f
                    val centerY = event.y - dragOffsetY + editText.height / 2f

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

                    editText.x = snappedX - editText.width / 2f
                    editText.y = snappedY - editText.height / 2f
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

        if (isEditingActive && editText.text.isNotEmpty()) {
            val videoRect = getVideoRect()
            if (showVerticalGuideline) {
                canvas.drawLine(videoRect.centerX(), videoRect.top, videoRect.centerX(), videoRect.bottom, guidelinePaint)
            }
            if (showHorizontalGuideline) {
                canvas.drawLine(videoRect.left, videoRect.centerY(), videoRect.right, videoRect.centerY(), guidelinePaint)
            }

            // Draw selection border around the EditText
            selectionRect.set(
                editText.x - 4f,
                editText.y - 4f,
                editText.x + editText.width + 4f,
                editText.y + editText.height + 4f
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
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private fun positionEditTextFromRelative() {
        if (width <= 0 || height <= 0) return
        val videoRect = getVideoRect()

        val targetCenterX = videoRect.left + (relativeX * videoRect.width())
        val targetCenterY = videoRect.top + (relativeY * videoRect.height())

        editText.x = targetCenterX - editText.width / 2f
        editText.y = targetCenterY - editText.height / 2f
    }

    private fun updateRelativePosition() {
        if (width <= 0 || height <= 0) return
        val videoRect = getVideoRect()

        val centerX = editText.x + editText.width / 2f
        val centerY = editText.y + editText.height / 2f

        relativeX = if (videoRect.width() > 0) ((centerX - videoRect.left) / videoRect.width()).coerceIn(0f, 1f) else 0.5f
        relativeY = if (videoRect.height() > 0) ((centerY - videoRect.top) / videoRect.height()).coerceIn(0f, 1f) else 0.5f
        onPositionChanged?.invoke(relativeX, relativeY)
    }

    private fun showKeyboard() {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
    }

    fun hideKeyboard() {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(editText.windowToken, 0)
    }

    fun getRelativeX(): Float = relativeX
    fun getRelativeY(): Float = relativeY
    fun getOpacity(): Float = currentOpacity

    fun setProperties(rx: Float, ry: Float, op: Float) {
        relativeX = rx
        relativeY = ry
        setOpacity(op)
        post {
            positionEditTextFromRelative()
            invalidate()
        }
    }
}
