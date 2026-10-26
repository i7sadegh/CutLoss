package com.tharunbirla.librecuts.viewmodels

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tharunbirla.librecuts.models.EditOperation
import com.tharunbirla.librecuts.models.EditRecipe
import com.tharunbirla.librecuts.models.TextPosition
import com.tharunbirla.librecuts.models.VideoEditingUiState
import com.tharunbirla.librecuts.models.VideoProject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

// ExportQuality enum removed in favor of individual parameters

class VideoEditingViewModel : ViewModel() {

    private companion object {
        const val TAG = "VideoEditingViewModel"
        const val MAX_UNDO_STACK_SIZE = 30
    }


    private val _project = MutableStateFlow<VideoProject?>(null)
    private val _uiState = MutableStateFlow(VideoEditingUiState())
    private val _undoStack = MutableStateFlow<List<HistoryState>>(emptyList())
    private val _redoStack = MutableStateFlow<List<HistoryState>>(emptyList())
    private val _exportResolution = MutableStateFlow(1080)
    private val _exportFps = MutableStateFlow(30)
    private val _exportAudioOnly = MutableStateFlow(false)
    private val _exportBitrate = MutableStateFlow("8M")
    private val _selectedOperationId = MutableStateFlow<String?>(null)

    private val _hasUnsavedEdits = MutableStateFlow(false)

    val project: StateFlow<VideoProject?> = _project.asStateFlow()
    val uiState: StateFlow<VideoEditingUiState> = _uiState.asStateFlow()
    val selectedOperationId: StateFlow<String?> = _selectedOperationId.asStateFlow()
    val undoStack: StateFlow<List<HistoryState>> = _undoStack.asStateFlow()
    val redoStack: StateFlow<List<HistoryState>> = _redoStack.asStateFlow()
    val exportResolution: StateFlow<Int> = _exportResolution.asStateFlow()
    val exportFps: StateFlow<Int> = _exportFps.asStateFlow()
    val exportAudioOnly: StateFlow<Boolean> = _exportAudioOnly.asStateFlow()
    val exportBitrate: StateFlow<String> = _exportBitrate.asStateFlow()
    val hasUnsavedEdits: StateFlow<Boolean> = _hasUnsavedEdits.asStateFlow()

    fun markProjectSaved() {
        _hasUnsavedEdits.value = false
    }

    fun markHasUnsavedEdits() {
        _hasUnsavedEdits.value = true
    }

    fun setExportSettings(resolution: Int, fps: Int, audioOnly: Boolean, bitrate: String? = null) {
        _exportResolution.value = resolution
        _exportFps.value = fps
        _exportAudioOnly.value = audioOnly
        if (bitrate != null) _exportBitrate.value = bitrate
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CutStudio: advanced export settings (export dialog v2)
    // ─────────────────────────────────────────────────────────────────────────

    data class AdvancedExport(
        val videoFormat: String = "mp4",      // mp4|mkv|mov|webm|avi
        val videoCodec: String = "",          // "" = same as input -> -c:v copy (libx264 fallback when re-encode is forced) | libx264|libx265|hevc_mediacodec|libvpx-vp9|libaom-av1
        val preset: String = "",              // "" = none; ultrafast..veryslow (x264/x265 only)
        val audioCodec: String = "",          // "" = same as input -> -c:a copy when possible | aac|libmp3lame|libopus|pcm_s16le|flac
        val audioBitrate: String = "",        // "" = same as input (omit -b:a); 128k|192k|256k|320k
        val audioOnlyFormat: String = "m4a",  // m4a|mp3|opus|flac|wav (audio-only export extension)
        val customWidth: Int = 0,             // 0 = not set
        val customHeight: Int = 0,            // 0 = not set
        val keyframeCut: Boolean = false,     // trim points snap to keyframes -> pure stream copy
        val exportSeparateFiles: Boolean = false, // one output file per timeline clip
        val movFastStart: Boolean = true,     // -movflags +faststart on MP4 output
        val preserveMetadata: Boolean = true  // keep the source's global metadata in the output
    )

    private val _advancedExport = MutableStateFlow(AdvancedExport())
    val advancedExport: StateFlow<AdvancedExport> = _advancedExport.asStateFlow()

    fun setAdvancedExport(value: AdvancedExport) {
        _advancedExport.value = value
    }

    fun getOutputExtension(isAudioOnly: Boolean): String {
        val adv = _advancedExport.value
        if (isAudioOnly) {
            return when (adv.audioOnlyFormat) {
                "mp3" -> ".mp3"; "opus" -> ".opus"; "flac" -> ".flac"; "wav" -> ".wav"
                else -> ".m4a"
            }
        }
        return when (adv.videoFormat) {
            "mkv" -> ".mkv"; "mov" -> ".mov"; "webm" -> ".webm"; "avi" -> ".avi"
            else -> ".mp4"
        }
    }

    /**
     * Output container flags shared by the legacy render paths (phase 10):
     *  - metadata  : -map_metadata 0 keeps the source's global metadata
     *                (which is also ffmpeg's default); -map_metadata -1
     *                strips it from the output entirely.
     *  - faststart : -movflags +faststart relocates the MP4 moov atom to
     *                the front so players can start before the whole file
     *                has been read (streaming-friendly).
     */
    private fun appendOutputContainerArgs(cmd: StringBuilder) {
        val adv = _advancedExport.value
        if (_exportAudioOnly.value) return
        if (adv.preserveMetadata) {
            cmd.append(" -map_metadata 0")
        } else {
            cmd.append(" -map_metadata -1")
        }
        if (adv.movFastStart && adv.videoFormat == "mp4") {
            cmd.append(" -movflags +faststart")
        }
    }

    /**
     * Final scale/fps segment of the filter graph. Omits scale when resolution
     * is "Same as input" (0), omits fps likewise; custom W x H (forced to even
     * numbers) wins over the preset heights.
     */
    private fun buildOutputScaleFilter(inLabel: String, outLabel: String): String {
        val adv = _advancedExport.value
        val parts = mutableListOf<String>()
        if (adv.customWidth >= 16 && adv.customHeight >= 16) {
            val w = adv.customWidth - (adv.customWidth % 2)
            val h = adv.customHeight - (adv.customHeight % 2)
            parts.add("scale=$w:$h")
        } else if (_exportResolution.value > 0) {
            parts.add("scale=-2:${_exportResolution.value}")
        }
        if (_exportFps.value > 0) parts.add("fps=${_exportFps.value}")
        parts.add("format=yuv420p")
        return "$inLabel${parts.joinToString(",")}$outLabel"
    }

    /** "-vf scale=... [-r N]" for the no-filter path; empty when all is same-as-input. */
    private fun buildOutputVfArgs(): String {
        val adv = _advancedExport.value
        val parts = mutableListOf<String>()
        if (adv.customWidth >= 16 && adv.customHeight >= 16) {
            val w = adv.customWidth - (adv.customWidth % 2)
            val h = adv.customHeight - (adv.customHeight % 2)
            parts.add("-vf scale=$w:$h")
        } else if (_exportResolution.value > 0) {
            parts.add("-vf scale=-2:${_exportResolution.value}")
        }
        if (_exportFps.value > 0) parts.add("-r ${_exportFps.value}")
        return parts.joinToString(" ")
    }

    /**
     * -c:v ... -pix_fmt ... -b:v ... (-preset only where the codec supports it).
     * "Same as input" + nothing forcing a re-encode -> "-c:v copy" (lossless remux).
     * When re-encoding is unavoidable the fallback encoder is libx264 so the
     * selected preset is actually honored (h264_mediacodec ignores -preset).
     */
    private fun buildVideoCodecArgs(defaultEncoder: String, allowStreamCopy: Boolean = false): String {
        val adv = _advancedExport.value
        if (allowStreamCopy && adv.videoCodec.isEmpty()) return "-c:v copy"
        val codec = if (adv.videoCodec.isNotEmpty()) adv.videoCodec else "libx264"
        val sb = StringBuilder("-c:v $codec -pix_fmt yuv420p")
        if (_exportBitrate.value.isNotEmpty()) sb.append(" -b:v ${_exportBitrate.value}")
        if (adv.preset.isNotEmpty() && (codec == "libx264" || codec == "libx265")) {
            sb.append(" -preset ${adv.preset}")
        }
        return sb.toString()
    }

    /**
     * -c:a ... (-b:a skipped for lossless codecs).
     * "Same as input" + no audio filtering -> "-c:a copy" (bit-exact passthrough).
     */
    private fun buildAudioCodecArgs(allowStreamCopy: Boolean = false): String {
        val adv = _advancedExport.value
        if (allowStreamCopy && adv.audioCodec.isEmpty()) return "-c:a copy"
        val codec = if (adv.audioCodec.isNotEmpty()) adv.audioCodec else "aac"
        val sb = StringBuilder("-c:a $codec")
        val lossless = codec == "pcm_s16le" || codec == "flac"
        if (adv.audioBitrate.isNotEmpty() && !lossless) sb.append(" -b:a ${adv.audioBitrate}")
        return sb.toString()
    }

    val operations: StateFlow<List<EditOperation>>
        get() = MutableStateFlow(project.value?.operations ?: emptyList()).asStateFlow()

    fun initializeProject(sourceUri: Uri, sourceName: String) {
        _project.value = VideoProject(sourceUri = sourceUri, sourceName = sourceName)
        _undoStack.value = emptyList()
        _redoStack.value = emptyList()
        _hasUnsavedEdits.value = false
        updateUiState { it.copy(canUndo = false) }
    }

    fun loadProject(project: VideoProject) {
        _project.value = project
        _undoStack.value = emptyList()
        _redoStack.value = emptyList()
        _hasUnsavedEdits.value = false
        updateUiState { it.copy(canUndo = false, pendingOperationCount = project.getOperationCount()) }
    }


    data class HistoryState(
        val project: VideoProject,
        val commandDescription: String
    )

    fun executeCommand(command: com.tharunbirla.librecuts.commands.EditCommand) {
        val current = _project.value ?: return
        
        val historyState = HistoryState(current, command.description)
        val stack = _undoStack.value + historyState
        _undoStack.value = if (stack.size > MAX_UNDO_STACK_SIZE) stack.takeLast(MAX_UNDO_STACK_SIZE) else stack
        
        _redoStack.value = emptyList()
        
        val newProject = command.execute(current)
        _project.value = newProject
        
        updateUiState { state ->
            state.copy(
                pendingOperationCount = newProject.getOperationCount(),
                canUndo = true,
                canRedo = false
            )
        }
        markHasUnsavedEdits()
    }

    fun undo() {
        val current = _project.value ?: return
        val stack = _undoStack.value
        if (stack.isEmpty()) return
        
        val previousState = stack.last()
        _undoStack.value = stack.dropLast(1)
        
        // Push current to redo stack.
        val redoState = HistoryState(current, previousState.commandDescription)
        val rStack = _redoStack.value + redoState
        _redoStack.value = if (rStack.size > MAX_UNDO_STACK_SIZE) rStack.takeLast(MAX_UNDO_STACK_SIZE) else rStack
        
        _project.value = previousState.project
        
        updateUiState { state ->
            state.copy(
                pendingOperationCount = previousState.project.getOperationCount(),
                canUndo = _undoStack.value.isNotEmpty(),
                canRedo = true
            )
        }
        markHasUnsavedEdits()
    }

    fun selectOperation(id: String?) {
        _selectedOperationId.value = id
    }

    fun redo() {
        val current = _project.value ?: return
        val stack = _redoStack.value
        if (stack.isEmpty()) return
        
        val nextState = stack.last()
        _redoStack.value = stack.dropLast(1)
        
        // Push current to undo stack.
        val undoState = HistoryState(current, nextState.commandDescription)
        val uStack = _undoStack.value + undoState
        _undoStack.value = if (uStack.size > MAX_UNDO_STACK_SIZE) uStack.takeLast(MAX_UNDO_STACK_SIZE) else uStack
        
        _project.value = nextState.project
        
        updateUiState { state ->
            state.copy(
                pendingOperationCount = nextState.project.getOperationCount(),
                canUndo = true,
                canRedo = _redoStack.value.isNotEmpty()
            )
        }
        markHasUnsavedEdits()
    }
    fun setPreviewOperationIndex(operationIndex: Int) {
        updateUiState { it.copy(currentPreviewOperationIndex = operationIndex) }
    }

    // ── Private filter-building helpers ─────────────────────────────────────


    /** Renders AddText ops to transparent PNGs (WYSIWYG canvas rendering).
     *  Set by the Activity; when set, text overlays are composited with the
     *  overlay filter instead of drawtext, so bold / italic / underline /
     *  strikethrough / letter spacing / rounded backgrounds all render
     *  exactly like the preview. */
    var textPngRenderer: ((EditOperation.AddText) -> String?)? = null
    private val textPngInputs = mutableListOf<Pair<EditOperation.AddText, String>>()

    private fun prepareTextPngInputs(operations: List<EditOperation>) {
        textPngInputs.clear()
        val renderer = textPngRenderer ?: return
        for (textOp in operations.filterIsInstance<EditOperation.AddText>()) {
            try {
                val path = renderer(textOp)
                if (path != null) {
                    textPngInputs.add(Pair(textOp, path))
                }
            } catch (e: Exception) {
                Log.w(TAG, "Text PNG render failed for op " + textOp.id + ": " + e.message)
            }
        }
    }

    /** overlay-filter position expressions (W/H = main video, w/h = text image). */
    private fun overlayPosExpr(pos: TextPosition): Pair<String, String> = when (pos) {
        TextPosition.BOTTOM_RIGHT -> Pair("'W-w'", "'H-h'")
        TextPosition.TOP_RIGHT -> Pair("'W-w'", "0")
        TextPosition.TOP_LEFT -> Pair("0", "0")
        TextPosition.BOTTOM_LEFT -> Pair("0", "'H-h'")
        TextPosition.CENTER_BOTTOM -> Pair("'(W-w)/2'", "'H-h'")
        TextPosition.CENTER_TOP -> Pair("'(W-w)/2'", "0")
        TextPosition.CENTER -> Pair("'(W-w)/2'", "'(H-h)/2'")
        TextPosition.TOP_CENTER -> Pair("'(W-w)/2'", "0")
        TextPosition.CENTER_LEFT -> Pair("0", "'(H-h)/2'")
        TextPosition.CENTER_RIGHT -> Pair("'W-w'", "'(H-h)/2'")
        TextPosition.BOTTOM_CENTER -> Pair("'(W-w)/2'", "'H-h'")
    }

    /** Build a drawtext filter expression for a text operation. */
    private fun buildDrawtextExpr(op: EditOperation.AddText, fontFilePath: String?): String {
        val escapedText = op.text
            .replace("\\", "\\\\")
            .replace("'", "\\\\'")
            .replace(":", "\\:")

        val fontToUse = op.fontPath ?: fontFilePath
        val fontPart = if (!fontToUse.isNullOrBlank()) {
            val escapedFont = fontToUse
                .replace("\\", "\\\\")
                .replace("'", "\\'")
                .replace(":", "\\:")
            "fontfile='$escapedFont':"
        } else {
            Log.w(TAG, "No fontFilePath — text overlay may not render on Android.")
            ""
        }

        // Use WYSIWYG fractional coordinates if available, else fall back to enum position
        val positionPart = if (op.positionKeyframes.isNotEmpty()) {
            val xExpr = buildFFmpegInterpolationExpr(op.positionKeyframes, useValueY = false, defaultValue = op.relativeX ?: 0.5f, startTimeMs = op.startTimeMs ?: 0L)
            val yExpr = buildFFmpegInterpolationExpr(op.positionKeyframes, useValueY = true, defaultValue = op.relativeY ?: 0.5f, startTimeMs = op.startTimeMs ?: 0L)
            "x='(w*($xExpr))-(tw/2)':y='(h*($yExpr))-(th/2)'"
        } else if (op.hasCustomPosition()) {
            "x='(w*${op.relativeX})-(tw/2)':y='(h*${op.relativeY})-(th/2)'"
        } else {
            op.position.ffmpegParam
        }

        val enablePart = buildEnableExpr(op.startTimeMs, op.endTimeMs)
        
        val alphaPart = if (op.opacityKeyframes.isNotEmpty()) {
            val alphaExpr = buildFFmpegInterpolationExpr(op.opacityKeyframes, useValueY = false, defaultValue = op.opacity, startTimeMs = op.startTimeMs ?: 0L)
            ":alpha='$alphaExpr'"
        } else if (op.opacity < 1.0f) {
            ":alpha='${op.opacity}'"
        } else {
            ""
        }
        val borderPart = if (op.borderThickness > 0) ":borderw=${op.borderThickness}:bordercolor='${formatColorForFFmpeg(op.borderColor)}'" else ""
        val alignPart = if (op.textAlign.isNotEmpty()) ":text_align=${op.textAlign}" else ""
        val lineSpacingPart = if (op.lineSpacing != 0f) ":line_spacing=${op.lineSpacing.toInt()}" else ""
        
        return "drawtext=${fontPart}text='$escapedText':fontcolor='${formatColorForFFmpeg(op.color)}':fontsize=${op.fontSize}:$positionPart$enablePart$alphaPart$borderPart$alignPart$lineSpacingPart"
    }


    private fun buildFFmpegInterpolationExpr(
        keyframes: List<EditOperation.KeyframePoint>,
        useValueY: Boolean,
        defaultValue: Float,
        startTimeMs: Long,
        timeVar: String = "t"
    ): String {
        if (keyframes.isEmpty()) return defaultValue.toString()
        val sorted = keyframes.sortedBy { it.timeMs }
        val startSec = startTimeMs / 1000.0
        val tRel = "($timeVar-$startSec)"
        
        if (sorted.size == 1) {
            val v = if (useValueY) sorted[0].valueY else sorted[0].valueX
            return v.toString()
        }
        
        var expr = ""
        val lastVal = if (useValueY) sorted.last().valueY else sorted.last().valueX
        expr = lastVal.toString()
        
        for (i in sorted.size - 2 downTo 0) {
            val k1 = sorted[i]
            val k2 = sorted[i + 1]
            val t1 = k1.timeMs / 1000.0
            val t2 = k2.timeMs / 1000.0
            val v1 = if (useValueY) k1.valueY else k1.valueX
            val v2 = if (useValueY) k2.valueY else k2.valueX
            
            val diffVal = v2 - v1
            val diffTime = t2 - t1
            val segmentExpr = if (diffTime > 0) {
                "$v1 + ($diffVal) * ($tRel - $t1) / ($diffTime)"
            } else {
                v1.toString()
            }
            
            expr = "if(lt($tRel\\, $t2)\\, $segmentExpr\\, $expr)"
        }
        
        val firstVal = if (useValueY) sorted.first().valueY else sorted.first().valueX
        val firstTime = sorted.first().timeMs / 1000.0
        expr = "if(lt($tRel\\, $firstTime)\\, $firstVal\\, $expr)"
        
        return expr
    }

    private fun formatColorForFFmpeg(colorHex: String): String {
        if (!colorHex.startsWith("#")) return colorHex
        return when (colorHex.length) {
            9 -> { // #AARRGGBB -> 0xRRGGBBAA
                val aa = colorHex.substring(1, 3)
                val rrggbb = colorHex.substring(3)
                "0x$rrggbb$aa"
            }
            7 -> { // #RRGGBB -> 0xRRGGBB
                "0x${colorHex.substring(1)}"
            }
            else -> colorHex
        }
    }

    private fun buildEnableExpr(startTimeMs: Long?, endTimeMs: Long?): String {
        if (startTimeMs == null && endTimeMs == null) return ""
        val startSec = maxOf(0L, startTimeMs ?: 0L) / 1000.0
        return if (endTimeMs != null) {
            val endSec = maxOf(0L, endTimeMs) / 1000.0
            ":enable='between(t\\,$startSec\\,$endSec)'"
        } else {
            ":enable='gte(t\\,$startSec)'"
        }
    }



    /**
     * Build the video portion of a filter_complex graph from non-merge, non-audio operations.
     *
     * @return Pair of (list of filter stages, final stream label) — e.g. (["[0:v]crop=...[v0]", "[v0]drawtext=...[v1]"], "[v1]")
     *         If no video filters needed, returns (emptyList, "[0:v]")
     */
    private fun buildVideoFilterStages(
        operations: List<EditOperation>,
        fontFilePath: String?,
        inputLabel: String = "[0:v]",
        imageInputIndices: List<Pair<Int, EditOperation.AddImageOverlay>> = emptyList(),
        textInputIndices: List<Pair<Int, EditOperation.AddText>> = emptyList(),
        density: Float = 1.0f,
        sourceVideoHeight: Int = 1080
    ): Pair<List<String>, String> {
        val stages = mutableListOf<String>()
        var currentLabel = inputLabel
        var stageIndex = 0

        for (op in operations) {
            when (op) {
                is EditOperation.AddText -> {
                    val textPngIndex = textInputIndices.find { it.second.id == op.id }?.first
                    if (textPngIndex != null) {
                        // WYSIWYG path: canvas-rendered PNG composited with overlay
                        val hasOpacityKfs = op.opacityKeyframes.isNotEmpty()
                        val rgbaLabel = "[txt_rgba_$stageIndex]"
                        if (hasOpacityKfs) {
                            stages.add("[$textPngIndex:v]format=rgba,loop=loop=-1:size=1:start=0,fps=25$rgbaLabel")
                        } else {
                            stages.add("[$textPngIndex:v]format=rgba$rgbaLabel")
                        }
                        var textLabel = rgbaLabel
                        if (hasOpacityKfs) {
                            val alphaLabel = "[txt_alpha_$stageIndex]"
                            val alphaExpr = buildFFmpegInterpolationExpr(
                                op.opacityKeyframes, useValueY = false, defaultValue = op.opacity,
                                startTimeMs = op.startTimeMs ?: 0L, timeVar = "T")
                            stages.add("${textLabel}geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*($alphaExpr)'$alphaLabel")
                            textLabel = alphaLabel
                        } else if (op.opacity < 1.0f) {
                            val alphaLabel = "[txt_alpha_$stageIndex]"
                            stages.add("${textLabel}colorchannelmixer=aa=${op.opacity}$alphaLabel")
                            textLabel = alphaLabel
                        }
                        val overlayX = if (op.positionKeyframes.isNotEmpty()) {
                            val xExpr = buildFFmpegInterpolationExpr(
                                op.positionKeyframes, useValueY = false,
                                defaultValue = op.relativeX ?: 0.5f, startTimeMs = op.startTimeMs ?: 0L)
                            "x='(W*($xExpr))-(w/2)'"
                        } else if (op.hasCustomPosition()) {
                            "x='(W*${op.relativeX})-(w/2)'"
                        } else {
                            "x=" + overlayPosExpr(op.position).first
                        }
                        val overlayY = if (op.positionKeyframes.isNotEmpty()) {
                            val yExpr = buildFFmpegInterpolationExpr(
                                op.positionKeyframes, useValueY = true,
                                defaultValue = op.relativeY ?: 0.5f, startTimeMs = op.startTimeMs ?: 0L)
                            "y='(H*($yExpr))-(h/2)'"
                        } else if (op.hasCustomPosition()) {
                            "y='(H*${op.relativeY})-(h/2)'"
                        } else {
                            "y=" + overlayPosExpr(op.position).second
                        }
                        val enablePart = buildEnableExpr(op.startTimeMs, op.endTimeMs)
                        val shortestPart = if (hasOpacityKfs) ":shortest=1" else ""
                        val nextLabel = "[v$stageIndex]"
                        stages.add("$currentLabel${textLabel}overlay=$overlayX:$overlayY$shortestPart$enablePart$nextLabel")
                        currentLabel = nextLabel
                        stageIndex++
                    } else {
                        // Fallback: classic drawtext filter
                        val filterExpr = buildDrawtextExpr(op, fontFilePath)
                        val nextLabel = "[v$stageIndex]"
                        stages.add("$currentLabel$filterExpr$nextLabel")
                        currentLabel = nextLabel
                        stageIndex++
                    }
                }
                is EditOperation.AddImageOverlay -> {
                    val imageInputIndex = imageInputIndices.find { it.second.id == op.id }?.first
                    if (imageInputIndex != null) {
                        val radians = op.rotationAngle * Math.PI / 180.0
                        val scaledImgLabel = "[scaled_img_$stageIndex]"
                        val refVidLabel = "[ref_vid_$stageIndex]"
                        val rotatedImgLabel = "[rotated_img_$stageIndex]"
                        val nextLabel = "[v$stageIndex]"

                        val path = op.imageUri.path
                        val isGif = path != null && path.endsWith(".gif", ignoreCase = true)
                        val isVideo = path != null && (path.endsWith(".mp4", ignoreCase = true) ||
                                                       path.endsWith(".mkv", ignoreCase = true) ||
                                                       path.endsWith(".mov", ignoreCase = true) ||
                                                       path.endsWith(".3gp", ignoreCase = true))

                        if (isVideo) {
                            val startSec = (op.startTimeMs ?: 0L) / 1000.0
                            val ptsLabel = "[pts_$stageIndex]"
                            val speedExpr = if (op.speedKeyframes.isNotEmpty()) {
                                buildFFmpegInterpolationExpr(op.speedKeyframes, useValueY = false, defaultValue = 1.0f, startTimeMs = 0L, timeVar = "T")
                            } else {
                                "1.0"
                            }
                            val safeSpeedExpr = "if(gt($speedExpr,0.1),$speedExpr,0.1)"
                            stages.add("[$imageInputIndex:v]setpts='(PTS-STARTPTS)/($safeSpeedExpr)+${startSec}/TB',format=rgba$ptsLabel")
                            stages.add("${ptsLabel}${currentLabel}scale2ref=w=iw*${op.relativeWidth}:h=ih*${op.relativeHeight}${scaledImgLabel}${refVidLabel}")
                        } else {
                            val rgbaImgLabel = "[rgba_img_$stageIndex]"
                            if (op.opacityKeyframes.isNotEmpty()) {
                                // Static image: convert to video stream so geq's T variable advances
                                stages.add("[$imageInputIndex:v]format=rgba,loop=loop=-1:size=1:start=0,fps=25$rgbaImgLabel")
                            } else {
                                stages.add("[$imageInputIndex:v]format=rgba$rgbaImgLabel")
                            }
                            stages.add("${rgbaImgLabel}${currentLabel}scale2ref=w=iw*${op.relativeWidth}:h=ih*${op.relativeHeight}${scaledImgLabel}${refVidLabel}")
                        }

                        var currentOverlayLabel = scaledImgLabel

                        val overlayStartMs = op.startTimeMs ?: 0L
                        if (op.opacityKeyframes.isNotEmpty()) {
                            val opacityLabel = "[opacity_$stageIndex]"
                            val alphaExpr = buildFFmpegInterpolationExpr(op.opacityKeyframes, useValueY = false, defaultValue = op.opacity, startTimeMs = overlayStartMs, timeVar = "T")
                            stages.add("${currentOverlayLabel}format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*($alphaExpr)'${opacityLabel}")
                            currentOverlayLabel = opacityLabel
                        } else if (op.opacity < 1.0f) {
                            val opacityLabel = "[opacity_$stageIndex]"
                            stages.add("${currentOverlayLabel}format=rgba,colorchannelmixer=aa=${op.opacity}${opacityLabel}")
                            currentOverlayLabel = opacityLabel
                        }



                        // Rotate image/video overlay (c=none preserves transparent background, ow/oh prevent cropping)
                        stages.add("${currentOverlayLabel}rotate=$radians:c=none:ow='rotw($radians)':oh='roth($radians)'${rotatedImgLabel}")
                        // Overlay image/video on the reference video
                        val enablePart = buildEnableExpr(op.startTimeMs, op.endTimeMs)
                        val shortestPart = if (((isGif || isVideo) && op.isLooping) || (!isGif && !isVideo && op.opacityKeyframes.isNotEmpty())) ":shortest=1" else ""
                        
                        val overlayX = if (op.positionKeyframes.isNotEmpty()) {
                            val xExpr = buildFFmpegInterpolationExpr(op.positionKeyframes, useValueY = false, defaultValue = op.relativeX, startTimeMs = op.startTimeMs ?: 0L)
                            "x='(W*($xExpr))-(w/2)'"
                        } else {
                            "x='(W*${op.relativeX})-(w/2)'"
                        }
                        val overlayY = if (op.positionKeyframes.isNotEmpty()) {
                            val yExpr = buildFFmpegInterpolationExpr(op.positionKeyframes, useValueY = true, defaultValue = op.relativeY, startTimeMs = op.startTimeMs ?: 0L)
                            "y='(H*($yExpr))-(h/2)'"
                        } else {
                            "y='(H*${op.relativeY})-(h/2)'"
                        }
                        
                        stages.add("${refVidLabel}${rotatedImgLabel}overlay=$overlayX:$overlayY${shortestPart}${enablePart}${nextLabel}")

                        currentLabel = nextLabel
                        stageIndex++
                    }
                }
                else -> {}
            }
        }

        return Pair(stages, currentLabel)
    }

    /**
     * Build the consolidated FFmpeg command for final export.
     *
     * Uses -filter_complex with explicit stream labels so each filter stage
     * receives the correct input dimensions (e.g., drawtext after crop uses
     * post-crop resolution).
     *
     * @param sourceFilePath  Absolute path to the source video.
     * @param outputFilePath  Absolute path for the exported video.
     * @param fontFilePath    Absolute path to a TTF font file (from assets via copyFontToCache).
     *                        Required for text overlays to render on Android.
     */
    fun buildConsolidatedFFmpegCommand(
        sourceFilePath: String,
        outputFilePath: String,
        fontFilePath: String? = null,
        context: Context? = null
    ): String? {
        val currentProject = _project.value ?: return null
        val density = context?.resources?.displayMetrics?.density ?: 1.0f

        var sourceVideoWidth = 1280
        var sourceVideoHeight = 720
        try {
            val retriever = android.media.MediaMetadataRetriever()
            try {
                retriever.setDataSource(sourceFilePath)
                val wStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                val hStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                val rStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                val w = wStr?.toIntOrNull() ?: 1280
                val h = hStr?.toIntOrNull() ?: 720
                val r = rStr?.toIntOrNull() ?: 0
                if (r == 90 || r == 270) {
                    sourceVideoWidth = h
                    sourceVideoHeight = w
                } else {
                    sourceVideoWidth = w
                    sourceVideoHeight = h
                }
            } finally {
                retriever.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error extracting source video dimensions: ${e.message}")
        }

        if (currentProject.operations.isEmpty()) {
            val remux = StringBuilder("-y -i \"").append(sourceFilePath).append("\"")
            appendOutputContainerArgs(remux)
            remux.append(" -c copy \"").append(outputFilePath).append("\"")
            return remux.toString()
        }

        val operations = currentProject.operations

        val isMainImage = sourceFilePath.endsWith(".png", ignoreCase = true) ||
                          sourceFilePath.endsWith(".jpg", ignoreCase = true) ||
                          sourceFilePath.endsWith(".jpeg", ignoreCase = true) ||
                          sourceFilePath.endsWith(".webp", ignoreCase = true)

        // Detect if source video has an audio stream
        val hasAudio = if (isMainImage) {
            false
        } else {
            try {
                val retriever = android.media.MediaMetadataRetriever()
                try {
                    retriever.setDataSource(sourceFilePath)
                    val hasAudioStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
                    hasAudioStr == "yes"
                } finally {
                    retriever.release()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error checking audio in source file: ${e.message}")
                true // fallback to assuming it has audio
            }
        }

        // ── Collect operation types ───────────────────────────────────────────
        val mergeOp = operations.filterIsInstance<EditOperation.Merge>().firstOrNull()
        val nonMergeOps = operations.filterNot { it is EditOperation.Merge }
        val trimOp = operations.filterIsInstance<EditOperation.Trim>().lastOrNull()
        val audioOps = operations.filterIsInstance<EditOperation.AddBackgroundAudio>()
        val audioMuted = operations.any { it is EditOperation.MuteAudio }
        val videoOps = nonMergeOps.filter { it is EditOperation.AddText || it is EditOperation.AddImageOverlay }
        val imageOps = operations.filterIsInstance<EditOperation.AddImageOverlay>()
        // Render text overlay PNGs before inputs are indexed
        prepareTextPngInputs(operations)

        // ── Unified Input Indexing ────────────────────────────────────────────
        val cmd = StringBuilder("-y") // Always overwrite output — prevents silent failure on retry
        var inputIndex = 0

        /** Resolve a URI to a real filesystem path FFmpeg can read.
         *  content:// URIs are copied to cacheDir; file:// or plain paths are used directly. */
        fun resolveUriToPath(uri: android.net.Uri): String? {
            if (uri.scheme == "content" && context != null) {
                return copyContentUriToTempFile(context, uri)
            }
            return uri.path ?: uri.toString()
        }

        // 1. Source Video Input (Index 0)
        var outputDuration: Double? = null
        val speedOp = operations.filterIsInstance<EditOperation.SpeedMain>().lastOrNull()
        val finalProxyUri = speedOp?.proxyUri
        
        if (finalProxyUri != null) {
            val proxyPath = resolveUriToPath(finalProxyUri) ?: finalProxyUri.toString()
            val baseDuration = if (trimOp != null) (trimOp.endMs - trimOp.startMs) else 0L
            if (baseDuration > 0) {
                val speed = speedOp?.speed ?: 1.0f
                outputDuration = baseDuration / speed / 1000.0
                cmd.append(" -t $outputDuration -i \"$proxyPath\"")
            } else {
                cmd.append(" -i \"$proxyPath\"")
            }
        } else {
            val isMainImage = sourceFilePath.endsWith(".png", ignoreCase = true) ||
                              sourceFilePath.endsWith(".jpg", ignoreCase = true) ||
                              sourceFilePath.endsWith(".jpeg", ignoreCase = true) ||
                              sourceFilePath.endsWith(".webp", ignoreCase = true)
            if (isMainImage) {
                val duration = if (trimOp != null) (trimOp.endMs - trimOp.startMs) / 1000.0 else 5.0
                if (mergeOp == null) {
                    outputDuration = duration
                }
                cmd.append(" -loop 1 -t $duration -i \"$sourceFilePath\"")
            } else if (trimOp != null) {
                val startSecs = trimOp.startMs / 1000.0
                val duration = (trimOp.endMs - trimOp.startMs) / 1000.0
                if (mergeOp == null) {
                    outputDuration = duration
                }
                cmd.append(" -ss $startSecs -t $duration -i \"$sourceFilePath\"")
            } else {
                cmd.append(" -i \"$sourceFilePath\"")
            }
        }
        inputIndex++

        // 2. Merge Video Inputs
        val mergeVideoIndices = mutableListOf<Int>()
        if (mergeOp != null) {
            for (item in mergeOp.items) {
                if (item.proxyUri != null) {
                    val proxyPath = item.proxyUri.path ?: item.proxyUri.toString()
                    val duration = item.trimmedDurationMs / 1000.0
                    cmd.append(" -t $duration -i \"$proxyPath\"")
                } else {
                    val videoPath = resolveUriToPath(item.uri) ?: item.uri.toString()
                    val startSecs = item.trimStartMs / 1000.0
                    val duration = (item.trimEndMs - item.trimStartMs) / 1000.0
                    
                    val isImage = item.isImage || 
                                  videoPath.endsWith(".png", ignoreCase = true) || 
                                  videoPath.endsWith(".jpg", ignoreCase = true) || 
                                  videoPath.endsWith(".jpeg", ignoreCase = true) ||
                                  videoPath.endsWith(".webp", ignoreCase = true)
                    
                    if (isImage) {
                        cmd.append(" -loop 1 -t $duration -i \"$videoPath\"")
                    } else {
                        cmd.append(" -ss $startSecs -t $duration -i \"$videoPath\"")
                    }
                }
                mergeVideoIndices.add(inputIndex)
                inputIndex++
            }
        }

        // 3. Audio Inputs  (content:// URIs must be cached to a real path)
        val audioInputIndices = mutableListOf<Pair<Int, EditOperation.AddBackgroundAudio>>()
        for (audioOp in audioOps) {
            val audioPath = resolveUriToPath(audioOp.audioUri)
            if (audioPath == null) {
                Log.e(TAG, "Failed to resolve audio URI to path: ${audioOp.audioUri} — skipping track")
                continue
            }
            cmd.append(" -i \"$audioPath\"")
            audioInputIndices.add(Pair(inputIndex, audioOp))
            inputIndex++
        }

        // 4. Image Overlay Inputs  (content:// URIs must be cached to a real path)
        val imageInputIndices = mutableListOf<Pair<Int, EditOperation.AddImageOverlay>>()
        for (imageOp in imageOps) {
            val imagePath = resolveUriToPath(imageOp.imageUri)
            if (imagePath == null) {
                Log.e(TAG, "Failed to resolve image URI to path: ${imageOp.imageUri} — skipping overlay")
                continue
            }
            val isGif = imagePath.endsWith(".gif", ignoreCase = true)
            val isVideo = imagePath.endsWith(".mp4", ignoreCase = true) ||
                          imagePath.endsWith(".mkv", ignoreCase = true) ||
                          imagePath.endsWith(".mov", ignoreCase = true) ||
                          imagePath.endsWith(".3gp", ignoreCase = true)
            if ((isGif || isVideo) && imageOp.isLooping) {
                cmd.append(" -stream_loop -1 -i \"$imagePath\"")
            } else {
                cmd.append(" -i \"$imagePath\"")
            }
            imageInputIndices.add(Pair(inputIndex, imageOp))
            inputIndex++
        }

        // 4b. Text Overlay PNG Inputs (WYSIWYG canvas-rendered text)
        val textInputIndices = mutableListOf<Pair<Int, EditOperation.AddText>>()
        for ((textOp, pngPath) in textPngInputs) {
            cmd.append(" -i \"$pngPath\"")
            textInputIndices.add(Pair(inputIndex, textOp))
            inputIndex++
        }

        // ── MERGE PATH ────────────────────────────────────────────────────────
        if (mergeOp != null) {
            val inputCount = 1 + mergeOp.videoUris.size
            val filterParts = mutableListOf<String>()

            var mainWidth = 1280
            var mainHeight = 720
            var sourceDurationMs = 0L

            if (isMainImage) {
                try {
                    val opts = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeFile(sourceFilePath, opts)
                    if (opts.outWidth > 0 && opts.outHeight > 0) {
                        mainWidth = opts.outWidth
                        mainHeight = opts.outHeight
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error extracting image dimensions: ${e.message}")
                }
                sourceDurationMs = 5000L
            } else {
                try {
                    val retriever = android.media.MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(sourceFilePath)
                        val wStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                        val hStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                        val rStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                        val dStr = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                        val w = wStr?.toIntOrNull() ?: 1280
                        val h = hStr?.toIntOrNull() ?: 720
                        val r = rStr?.toIntOrNull() ?: 0
                        sourceDurationMs = dStr?.toLongOrNull() ?: 0L
                        if (r == 90 || r == 270) {
                            mainWidth = h
                            mainHeight = w
                        } else {
                            mainWidth = w
                            mainHeight = h
                        }
                    } finally {
                        retriever.release()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error extracting dimensions: ${e.message}")
                }
            }

            // FFmpeg requires even dimensions
            if (mainWidth % 2 != 0) mainWidth -= 1
            if (mainHeight % 2 != 0) mainHeight -= 1

            val hasAudioArray = BooleanArray(inputCount)
            val durationsArray = DoubleArray(inputCount)
            
            hasAudioArray[0] = if (isMainImage) false else hasAudio
            durationsArray[0] = if (isMainImage) {
                if (trimOp != null) (trimOp.endMs - trimOp.startMs) / 1000.0 else 5.0
            } else if (speedOp?.proxyUri != null) {
                val base = if (trimOp != null) (trimOp.endMs - trimOp.startMs) else sourceDurationMs
                (base / speedOp.speed) / 1000.0
            } else if (trimOp != null) {
                (trimOp.endMs - trimOp.startMs) / 1000.0
            } else {
                sourceDurationMs / 1000.0
            }

            for ((idx, item) in mergeOp.items.withIndex()) {
                val path = item.uri.path ?: item.uri.toString()
                hasAudioArray[idx + 1] = try {
                    val isImage = path.endsWith(".png", ignoreCase = true) || 
                                  path.endsWith(".jpg", ignoreCase = true) || 
                                  path.endsWith(".jpeg", ignoreCase = true) ||
                                  path.endsWith(".webp", ignoreCase = true)
                    if (isImage) {
                        false
                    } else {
                        val r = android.media.MediaMetadataRetriever()
                        try {
                            r.setDataSource(path)
                            val h = r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
                            h == "yes"
                        } finally {
                            r.release()
                        }
                    }
                } catch (e: Exception) { false }
                durationsArray[idx + 1] = item.trimmedDurationMs / 1000.0
            }


            for (i in 0 until inputCount) {

                
                
                // 1. Prepare raw video with basic visual filters
                var preFilters = "setpts=PTS-STARTPTS"
                

                
                filterParts.add("[$i:v]$preFilters[pre$i]")

                // 2. Pad every clip onto a black canvas of the main dimensions
                //    (uniform frame sizes are required for concat/xfade)
                filterParts.add("color=c=black:s=${mainWidth}x${mainHeight}:r=30[bg$i]")
                filterParts.add("[pre$i]scale=$mainWidth:$mainHeight:force_original_aspect_ratio=decrease[fg$i]")
                filterParts.add("[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2:shortest=1,setsar=1,fps=30,format=yuv420p[norm$i]")

                val isClipMuted = operations.filterIsInstance<EditOperation.MuteClip>().find { it.index == i }?.isMuted ?: false
                if (hasAudioArray[i] && !isClipMuted) {
                    filterParts.add("[$i:a]asetpts=PTS-STARTPTS,aformat=sample_rates=44100:channel_layouts=stereo[anorm$i]")
                } else {
                    val d = durationsArray[i]
                    filterParts.add("anullsrc=r=44100:cl=stereo,atrim=duration=$d,asetpts=PTS-STARTPTS[anorm$i]")
                }
            }

            // Build a list of per-gap transition info (gap i = between clip i and clip i+1)
            // transitionOps[i] is the Transition op for gap i, or null if none.
            val transitionOps = List(inputCount - 1) { gapIdx ->
                operations.filterIsInstance<EditOperation.Transition>().find { it.index == gapIdx }
            }

            // Chain xfade/acrossfade for transitions and concat for plain gaps.
            // Represents a finalized stream ready to be used as xfade input
            data class StreamInfo(val vLabel: String, val aLabel: String, val durationSec: Double)

            val pendingClipIndices = mutableListOf(0) // start with clip 0

            var currentStream: StreamInfo? = null
            var transitionLabelCounter = 0
            var concatLabelCounter = 0

            fun flushPendingGroup(clipIndices: List<Int>): StreamInfo {
                return if (clipIndices.size == 1) {
                    val i = clipIndices[0]
                    StreamInfo("[norm$i]", "[anorm$i]", durationsArray[i])
                } else {
                    val vOut = "[ccat${concatLabelCounter}v]"
                    val aOut = "[ccat${concatLabelCounter}a]"
                    val inputs = clipIndices.joinToString("") { "[norm$it][anorm$it]" }
                    // concat then normalize timestamps for proper xfade offsets
                    filterParts.add("${inputs}concat=n=${clipIndices.size}:v=1:a=1${vOut}${aOut}")
                    filterParts.add("${vOut}settb=1/30,setpts=N[norm${concatLabelCounter}v]")
                    filterParts.add("${aOut}asetpts=PTS-STARTPTS[anorm${concatLabelCounter}a]")
                    val totalDur = clipIndices.sumOf { durationsArray[it] }
                    concatLabelCounter++
                    // use the normalized labels for subsequent processing
                    StreamInfo("[norm${concatLabelCounter - 1}v]", "[anorm${concatLabelCounter - 1}a]", totalDur)
                }
            }

            for (gapIdx in 0 until inputCount - 1) {
                val transOp = transitionOps[gapIdx]
                if (transOp == null || transOp.type == "none") {
                    // No transition at this gap — just accumulate the next clip
                    pendingClipIndices.add(gapIdx + 1)
                } else {
                    // Flush the pending group into a stream, if any pending clips exist.
                    // If none exist, it means the currentStream (previous transition output) is the base.
                    val baseStream = if (pendingClipIndices.isEmpty()) {
                        currentStream ?: throw IllegalStateException("Both pending clips and currentStream are empty")
                    } else {
                        val leftStream = flushPendingGroup(pendingClipIndices)
                        pendingClipIndices.clear()
                        if (currentStream == null) {
                            leftStream
                        } else {
                            // Concat previous xfade output with the newly flushed left group
                            val vOut = "[ccat${concatLabelCounter}v]"
                            val aOut = "[ccat${concatLabelCounter}a]"
                            filterParts.add("${currentStream.vLabel}${currentStream.aLabel}${leftStream.vLabel}${leftStream.aLabel}concat=n=2:v=1:a=1${vOut}${aOut}")
                            filterParts.add("${vOut}settb=1/30,setpts=N[norm${concatLabelCounter}v]")
                            filterParts.add("${aOut}asetpts=PTS-STARTPTS[anorm${concatLabelCounter}a]")
                            concatLabelCounter++
                            StreamInfo("[norm${concatLabelCounter - 1}v]", "[anorm${concatLabelCounter - 1}a]", currentStream.durationSec + leftStream.durationSec)
                        }
                    }

                    val rawTransDuration = transOp.durationMs / 1000.0
                    val transDuration = rawTransDuration.coerceAtMost(baseStream.durationSec).coerceAtMost(durationsArray[gapIdx + 1])
                    val offset = (baseStream.durationSec - transDuration).coerceAtLeast(0.0)

                    val xfvOut = "[xfv${transitionLabelCounter}]"
                    val xfaOut = "[xfa${transitionLabelCounter}]"
                    val nextVLabel = "[norm${gapIdx + 1}]"
                    val nextALabel = "[anorm${gapIdx + 1}]"

                    val validXfadeTransitions = setOf(
                        "fade", "fadeblack", "fadewhite", "rectcrop", "circlecrop", "circleclose", "circleopen",
                        "horzclose", "horzopen", "vertclose", "vertopen", "diagbl", "diagbr", "diagtl", "diagtr",
                        "hlslice", "hrslice", "vuslice", "vdslice", "dissolve", "pixelize", "slidedown", "slideleft",
                        "slideright", "slideup", "wipedown", "wipeleft", "wiperight", "wipeup", "zoomin", "squeezeh",
                        "squeezev", "coverleft", "coverright", "coverup", "coverdown", "revealleft", "revealright",
                        "revealup", "revealdown"
                    )
                    val rawType = transOp.type.lowercase()
                    val sanitizedTransType = when (rawType) {
                        "smoothleft" -> "coverleft"
                        "smoothright" -> "coverright"
                        "distance" -> "zoomin"
                        else -> if (validXfadeTransitions.contains(rawType)) rawType else "fade"
                    }

                    filterParts.add("${baseStream.vLabel}${nextVLabel}xfade=transition=${sanitizedTransType}:duration=${transDuration}:offset=${offset}${xfvOut}")
                    filterParts.add("${baseStream.aLabel}${nextALabel}acrossfade=d=${transDuration}:c1=tri:c2=tri${xfaOut}")

                    val newDuration = offset + durationsArray[gapIdx + 1]
                    currentStream = StreamInfo(xfvOut, xfaOut, newDuration)
                    transitionLabelCounter++
                    // Next clip (gapIdx+1) has already been consumed by xfade — don't add it to pending
                }
            }

            // Flush any remaining pending clips
            val remainingStream = if (pendingClipIndices.isNotEmpty()) flushPendingGroup(pendingClipIndices) else null

            val finalStream: StreamInfo = when {
                currentStream == null && remainingStream != null -> remainingStream
                currentStream != null && remainingStream == null -> currentStream!!
                currentStream != null && remainingStream != null -> {
                    // Concat the last xfade output with remaining plain clips
                    // FFmpeg concat requires interleaved [v0][a0][v1][a1] order
                    val vOut = "[ccat${concatLabelCounter}v]"
                    val aOut = "[ccat${concatLabelCounter}a]"
                    // concat then normalize timestamps
                    filterParts.add("${currentStream.vLabel}${currentStream.aLabel}${remainingStream.vLabel}${remainingStream.aLabel}concat=n=2:v=1:a=1${vOut}${aOut}")
                    filterParts.add("${vOut}settb=1/30,setpts=N[norm${concatLabelCounter}v]")
                    filterParts.add("${aOut}asetpts=PTS-STARTPTS[anorm${concatLabelCounter}a]")
                    concatLabelCounter++
                    StreamInfo("[norm${concatLabelCounter - 1}v]", "[anorm${concatLabelCounter - 1}a]", currentStream.durationSec + remainingStream.durationSec)
                }
                else -> StreamInfo("[norm0]", "[anorm0]", durationsArray[0]) // fallback single clip
            }

            var currentVLabel = finalStream.vLabel
            var currentALabel = finalStream.aLabel
            val accumulatedDuration = finalStream.durationSec

            var currentVideoLabel = currentVLabel
            var currentAudioLabel = currentALabel

            outputDuration = accumulatedDuration


            val (sourceVideoStages, tempVideoLabel) = buildVideoFilterStages(
                operations = videoOps,
                fontFilePath = fontFilePath,
                inputLabel = currentVideoLabel,
                imageInputIndices = imageInputIndices,
                textInputIndices = textInputIndices,
                density = density,
                sourceVideoHeight = sourceVideoHeight
            )
            filterParts.addAll(sourceVideoStages)
            val finalVideoLabel = "[fmtv]"
            filterParts.add(buildOutputScaleFilter(tempVideoLabel, finalVideoLabel))

            if (audioMuted) {
                filterParts.add("${currentAudioLabel}anullsink")
            } else if (audioInputIndices.isNotEmpty()) {
                val mixInputLabels = mutableListOf<String>()
                mixInputLabels.add(currentAudioLabel)

                for ((idx, pair) in audioInputIndices.withIndex()) {
                    val (inputIdx, audioOp) = pair
                    val trackLabel = "[a_bg_$idx]"
                    val filters = mutableListOf<String>()

                    val internalStartSec = audioOp.internalStartMs / 1000.0
                    var internalEndSec = if (audioOp.internalEndMs > 0L) audioOp.internalEndMs / 1000.0 else Double.MAX_VALUE

                    if (audioOp.startTimeMs != null && audioOp.endTimeMs != null) {
                        val timelineDurationSec = (audioOp.endTimeMs - audioOp.startTimeMs) / 1000.0
                        val maxEndSec = internalStartSec + timelineDurationSec
                        if (maxEndSec < internalEndSec) internalEndSec = maxEndSec
                    }

                    if (internalStartSec > 0.0 || internalEndSec != Double.MAX_VALUE) {
                        if (internalEndSec != Double.MAX_VALUE) {
                            filters.add("atrim=start=$internalStartSec:end=$internalEndSec,asetpts=PTS-STARTPTS")
                        } else {
                            filters.add("atrim=start=$internalStartSec,asetpts=PTS-STARTPTS")
                        }
                    }
                    if (audioOp.fadeInDurationMs > 0L) {
                        val fadeSec = audioOp.fadeInDurationMs / 1000.0
                        filters.add("afade=t=in:st=0:d=$fadeSec")
                    }
                    if (audioOp.fadeOutDurationMs > 0L) {
                        val fadeSec = audioOp.fadeOutDurationMs / 1000.0
                        val clipDur = if (audioOp.endTimeMs != null && audioOp.startTimeMs != null) {
                            (audioOp.endTimeMs - audioOp.startTimeMs) / 1000.0
                        } else if (audioOp.internalEndMs > 0L) {
                            (audioOp.internalEndMs - audioOp.internalStartMs) / 1000.0
                        } else {
                            (audioOp.originalDurationMs - audioOp.internalStartMs) / 1000.0
                        }
                        val fadeOutStart = maxOf(0.0, clipDur - fadeSec)
                        filters.add("afade=t=out:st=$fadeOutStart:d=$fadeSec")
                    }
                    var delayMs = audioOp.startTimeMs ?: 0L
                    if (delayMs < 0) delayMs = 0L
                    if (delayMs > 0) {
                        filters.add("adelay=$delayMs|$delayMs")
                    }
                    if (audioOp.volume != 1.0f) {
                        filters.add("volume=${audioOp.volume}")
                    }

                    if (filters.isNotEmpty()) {
                        filterParts.add("[$inputIdx:a]${filters.joinToString(",")}$trackLabel")
                        mixInputLabels.add(trackLabel)
                    } else {
                        mixInputLabels.add("[$inputIdx:a]")
                    }
                }

                if (!audioInputIndices.any { it.second.removeOriginalAudio }) {
                    var mainAudioRef = currentAudioLabel
                    val duckingCount = audioInputIndices.count { it.second.ducking }
                    
                    if (duckingCount > 0) {
                        val splits = (0..duckingCount).map { "[main_split_$it]" }
                        filterParts.add("${mainAudioRef}asplit=${duckingCount + 1}${splits.joinToString("")}")
                        mainAudioRef = splits[0]
                        
                        var splitIdx = 1
                        for (i in mixInputLabels.indices.drop(1)) { // skip index 0 which is currentAudioLabel
                            val opIndex = i - 1
                            val op = audioInputIndices[opIndex].second
                            if (op.ducking) {
                                val bgLabel = mixInputLabels[i]
                                val sidechainLabel = splits[splitIdx++]
                                val duckedLabel = "[ducked_$opIndex]"
                                filterParts.add("${bgLabel}aformat=sample_rates=44100:channel_layouts=stereo[bg_fmt_$opIndex]")
                                filterParts.add("${sidechainLabel}aformat=sample_rates=44100:channel_layouts=stereo[sc_fmt_$opIndex]")
                                filterParts.add("[bg_fmt_$opIndex][sc_fmt_$opIndex]sidechaincompress=threshold=0.03:ratio=4:attack=5:release=500${duckedLabel}")
                                mixInputLabels[i] = duckedLabel
                            }
                        }
                    }
                    
                    mixInputLabels[0] = mainAudioRef
                    val allInputs = mixInputLabels.joinToString("")
                    filterParts.add("${allInputs}amix=inputs=${mixInputLabels.size}:duration=longest[outa]")
                    currentAudioLabel = "[outa]"
                } else {
                    filterParts.add("${mixInputLabels[0]}anullsink")
                    mixInputLabels.removeAt(0)
                    if (mixInputLabels.size == 1) {
                        val singleLabel = mixInputLabels[0]
                        filterParts.add("${singleLabel}aformat=sample_rates=44100:channel_layouts=stereo[outa]")
                        currentAudioLabel = "[outa]"
                    } else {
                        val allBg = mixInputLabels.joinToString("")
                        filterParts.add("${allBg}amix=inputs=${mixInputLabels.size}:duration=longest[outa]")
                        currentAudioLabel = "[outa]"
                    }
                }
            }

            if (_exportAudioOnly.value) {
                filterParts.add("${finalVideoLabel}nullsink")
            }
            cmd.append(" -filter_complex \"${filterParts.joinToString(";")}\"")
            
            if (_exportAudioOnly.value) {
                if (!audioMuted) {
                    cmd.append(" -map \"$currentAudioLabel\"")
                    // CutStudio ffmpeg might have libmp3lame, fallback to libmp3lame or default mp3 encoder
                    cmd.append(" ${buildAudioCodecArgs()}")
                } else {
                    cmd.append(" -an")
                }
            } else {
                cmd.append(" -map \"$finalVideoLabel\"")
                if (!audioMuted) {
                    cmd.append(" -map \"$currentAudioLabel\"")
                } else {
                    cmd.append(" -an")
                }
                
                val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                    ?.getString("default_encoder", "hardware") ?: "hardware"
                cmd.append(" ${buildVideoCodecArgs(defaultEncoder)}")
                
                if (!audioMuted) {
                    cmd.append(" ${buildAudioCodecArgs()}")
                }
            }

            if (outputDuration != null) {
                cmd.append(" -t $outputDuration")
            }
            appendOutputContainerArgs(cmd)
            cmd.append(" \"$outputFilePath\"")

            val finalCommand = cmd.toString()
            Log.d(TAG, "Built merge command: $finalCommand")
            return finalCommand
        }

        // ── NON-MERGE PATH ────────────────────────────────────────────────────
        val filterComplexParts = mutableListOf<String>()
        var currentInputVideoLabel = "[0:v]"


        




        // ── Video filter stages (crop, text, image overlays) ──
        val (videoStages, finalVideoLabel) = buildVideoFilterStages(
            operations = videoOps,
            fontFilePath = fontFilePath,
            inputLabel = currentInputVideoLabel,
            imageInputIndices = imageInputIndices,
            textInputIndices = textInputIndices,
            density = density,
            sourceVideoHeight = sourceVideoHeight
        )
        filterComplexParts.addAll(videoStages)

        // ── Audio filter stages (multi-track adelay + volume mixing) ──
        var finalAudioLabel: String? = null
        val mainVideoMuted = operations.filterIsInstance<EditOperation.MuteClip>().find { it.index == 0 }?.isMuted ?: false
        val effectiveAudioMuted = audioMuted || (mainVideoMuted && audioInputIndices.isEmpty())

        if (effectiveAudioMuted) {
            // No audio output — will use -an flag
        } else if (audioInputIndices.isNotEmpty()) {
            val mixInputLabels = mutableListOf<String>()

            for ((idx, pair) in audioInputIndices.withIndex()) {
                val (inputIdx, audioOp) = pair
                val trackLabel = "[a$idx]"
                val filters = mutableListOf<String>()

                val internalStartSec = audioOp.internalStartMs / 1000.0
                var internalEndSec = if (audioOp.internalEndMs > 0L) audioOp.internalEndMs / 1000.0 else Double.MAX_VALUE

                if (audioOp.startTimeMs != null && audioOp.endTimeMs != null) {
                    val timelineDurationSec = (audioOp.endTimeMs - audioOp.startTimeMs) / 1000.0
                    val maxEndSec = internalStartSec + timelineDurationSec
                    if (maxEndSec < internalEndSec) {
                        internalEndSec = maxEndSec
                    }
                }

                if (internalStartSec > 0.0 || internalEndSec != Double.MAX_VALUE) {
                    if (internalEndSec != Double.MAX_VALUE) {
                        filters.add("atrim=start=$internalStartSec:end=$internalEndSec,asetpts=PTS-STARTPTS")
                    } else {
                        filters.add("atrim=start=$internalStartSec,asetpts=PTS-STARTPTS")
                    }
                }
                if (audioOp.fadeInDurationMs > 0L) {
                    val fadeSec = audioOp.fadeInDurationMs / 1000.0
                    filters.add("afade=t=in:st=0:d=$fadeSec")
                }
                if (audioOp.fadeOutDurationMs > 0L) {
                    val fadeSec = audioOp.fadeOutDurationMs / 1000.0
                    val clipDur = if (audioOp.endTimeMs != null && audioOp.startTimeMs != null) {
                        (audioOp.endTimeMs - audioOp.startTimeMs) / 1000.0
                    } else if (audioOp.internalEndMs > 0L) {
                        (audioOp.internalEndMs - audioOp.internalStartMs) / 1000.0
                    } else {
                        (audioOp.originalDurationMs - audioOp.internalStartMs) / 1000.0
                    }
                    val fadeOutStart = maxOf(0.0, clipDur - fadeSec)
                    filters.add("afade=t=out:st=$fadeOutStart:d=$fadeSec")
                }
                var delayMs = audioOp.startTimeMs ?: 0L
                if (delayMs < 0) delayMs = 0L
                if (delayMs > 0) {
                    filters.add("adelay=$delayMs|$delayMs")
                }
                
                if (audioOp.volume != 1.0f) {
                    filters.add("volume=${audioOp.volume}")
                }

                if (filters.isNotEmpty()) {
                    filterComplexParts.add("[$inputIdx:a]${filters.joinToString(",")}$trackLabel")
                    mixInputLabels.add(trackLabel)
                } else {
                    mixInputLabels.add("[$inputIdx:a]")
                }
            }

            // Mix original audio with all background tracks
            if (hasAudio && !mainVideoMuted && !audioInputIndices.any { it.second.removeOriginalAudio }) {
                var mainAudioRef = "[0:a]"
                val duckingCount = audioInputIndices.count { it.second.ducking }
                
                if (duckingCount > 0) {
                    val splits = (0..duckingCount).map { "[main_split_$it]" }
                    filterComplexParts.add("${mainAudioRef}asplit=${duckingCount + 1}${splits.joinToString("")}")
                    mainAudioRef = splits[0]
                    
                    var splitIdx = 1
                    for (i in mixInputLabels.indices) {
                        val op = audioInputIndices[i].second
                        if (op.ducking) {
                            val bgLabel = mixInputLabels[i]
                            val sidechainLabel = splits[splitIdx++]
                            val duckedLabel = "[ducked_$i]"
                            filterComplexParts.add("${bgLabel}aformat=sample_rates=44100:channel_layouts=stereo[bg_fmt_$i]")
                            filterComplexParts.add("${sidechainLabel}aformat=sample_rates=44100:channel_layouts=stereo[sc_fmt_$i]")
                            filterComplexParts.add("[bg_fmt_$i][sc_fmt_$i]sidechaincompress=threshold=0.03:ratio=4:attack=5:release=500${duckedLabel}")
                            mixInputLabels[i] = duckedLabel
                        }
                    }
                }

                val allInputs = mainAudioRef + mixInputLabels.joinToString("")
                val totalInputs = 1 + mixInputLabels.size
                filterComplexParts.add("${allInputs}amix=inputs=$totalInputs:duration=longest[outa]")
                finalAudioLabel = "[outa]"
            } else {
                if (mixInputLabels.size == 1) {
                    val singleLabel = mixInputLabels[0]
                    filterComplexParts.add("${singleLabel}aformat=sample_rates=44100:channel_layouts=stereo[outa]")
                    finalAudioLabel = "[outa]"
                } else {
                    val allBg = mixInputLabels.joinToString("")
                    filterComplexParts.add("${allBg}amix=inputs=${mixInputLabels.size}:duration=longest[outa]")
                    finalAudioLabel = "[outa]"
                }
            }
        }

        // ── Assemble the command ──
        val hasVideoFilters = videoStages.isNotEmpty()
        val hasAudioFilters = finalAudioLabel != null

        if (hasVideoFilters || hasAudioFilters) {
            var mappedVideoLabel = finalVideoLabel
            if (hasVideoFilters) {
                val fmtLabel = "[fmtv]"
                filterComplexParts.add(buildOutputScaleFilter(finalVideoLabel, fmtLabel))
                mappedVideoLabel = fmtLabel
            }
            
            if (_exportAudioOnly.value && hasVideoFilters) {
                filterComplexParts.add("${mappedVideoLabel}nullsink")
            }
            
            cmd.append(" -filter_complex \"${filterComplexParts.joinToString(";")}\"")

            if (!_exportAudioOnly.value) {
                if (hasVideoFilters) {
                    cmd.append(" -map \"$mappedVideoLabel\"")
                } else {
                    cmd.append(" -map 0:v")
                }
            }

            if (effectiveAudioMuted) {
                cmd.append(" -an")
            } else if (hasAudioFilters) {
                cmd.append(" -map \"$finalAudioLabel\"")
            } else {
                cmd.append(" -map 0:a?")
            }
        } else {
            if (_exportAudioOnly.value) {
                cmd.append(" -vn")
                if (!effectiveAudioMuted) {
                    cmd.append(" -map 0:a?")
                }
            }
            if (effectiveAudioMuted) {
                cmd.append(" -an")
            }
        }

        // Codecs
        if (_exportAudioOnly.value) {
            if (!effectiveAudioMuted) {
                cmd.append(" ${buildAudioCodecArgs(finalAudioLabel == null)}")
            }
        } else {
            val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                ?.getString("default_encoder", "hardware") ?: "hardware"
            // If there are no video filters, we still need to apply the scale and fps output params.
            // Stream copy is only possible when nothing forces a re-encode (no filters, no scale/fps change).
            if (!hasVideoFilters) {
                val vfArgs = buildOutputVfArgs()
                cmd.append(" ${buildVideoCodecArgs(defaultEncoder, vfArgs.isEmpty())}")
                if (vfArgs.isNotEmpty()) cmd.append(" $vfArgs")
            } else {
                cmd.append(" ${buildVideoCodecArgs(defaultEncoder)}")
            }
            
            if (!effectiveAudioMuted) {
                cmd.append(" ${buildAudioCodecArgs(finalAudioLabel == null)}")
            }
        }

        if (outputDuration != null) {
            cmd.append(" -t $outputDuration")
        }
        appendOutputContainerArgs(cmd)
        cmd.append(" \"$outputFilePath\"")

        val finalCommand = cmd.toString()
        Log.d(TAG, "Built command: $finalCommand")
        return finalCommand
    }

    /**
     * Build an FFmpeg command for a fast 3-second preview around the playhead.
     * Uses ultrafast preset and high CRF for speed over quality.
     * Skips merge operations (preview is source-only).
     *
     * @param seekPositionMs  Current playhead position in ms.
     */
    fun buildPreviewCommand(
        sourceFilePath: String,
        previewOutputPath: String,
        seekPositionMs: Long,
        fontFilePath: String? = null,
        density: Float = 1.0f
    ): String? {
        val currentProject = _project.value ?: return null
        val operations = currentProject.operations
            .filterNot { it is EditOperation.Merge } // Skip merge for preview

        if (operations.none { it is EditOperation.AddText }) {
            return null // No visual operations to preview
        }

        val videoOps = operations.filter { it is EditOperation.AddText }
        val trimOp = operations.filterIsInstance<EditOperation.Trim>().lastOrNull()

        val cmd = StringBuilder()
        var outputDuration: Double? = null
        if (trimOp != null) {
            val durationSecs = (trimOp.endMs - trimOp.startMs) / 1000.0
            outputDuration = durationSecs
            cmd.append("-ss ${trimOp.startMs / 1000.0} -t $durationSecs -i \"$sourceFilePath\"")
        } else {
            cmd.append("-i \"$sourceFilePath\"")
        }

        // Build filter_complex for video operations
        val (videoStages, finalLabel) = buildVideoFilterStages(
            operations = videoOps,
            fontFilePath = fontFilePath,
            density = density,
            sourceVideoHeight = 1080
        )
        if (videoStages.isNotEmpty()) {
            cmd.append(" -filter_complex \"${videoStages.joinToString(";")}\"")
            cmd.append(" -map \"$finalLabel\" -map 0:a?")
        }

        // Fast preview settings
        cmd.append(" -c:v h264_mediacodec -pix_fmt yuv420p -b:v 1500k -c:a aac")
        if (outputDuration != null) {
            cmd.append(" -t $outputDuration")
        }
        cmd.append(" -y \"$previewOutputPath\"")

        val finalCommand = cmd.toString()
        Log.d(TAG, "Built preview command: $finalCommand")
        return finalCommand
    }

    private fun copyContentUriToTempFile(context: Context, uri: Uri): String? {
        return try {
            val tempFile = File.createTempFile("temp_video", ".mp4", context.cacheDir)
            context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(tempFile).use { input.copyTo(it) }
            }
            tempFile.absolutePath
        } catch (e: Exception) {
            Log.e("VideoEditingViewModel", "Failed to copy content URI: ${e.message}")
            null
        }
    }

    /**
     * Build the FFmpeg concat command for merging videos.
     * FIX: All paths are now quoted to prevent truncation on long package-name paths.
     */
    fun buildMergeCommand(
        context: Context,
        currentVideoPath: String,
        videoUrisToMerge: List<Uri>,
        listFilePath: String,
        outputFilePath: String
    ): String {
        val listContent = StringBuilder()
        listContent.append("file '$currentVideoPath'\n")

        for (uri in videoUrisToMerge) {
            val tempFilePath = copyContentUriToTempFile(context, uri)
            if (tempFilePath != null) {
                listContent.append("file '$tempFilePath'\n")
            } else {
                Log.e("VideoEditingViewModel", "Skipping URI due to copy failure: $uri")
            }
        }

        File(listFilePath).writeText(listContent.toString())

        // Both listFilePath and outputFilePath are quoted
        return "-f concat -safe 0 -i \"$listFilePath\" -c:v copy -c:a copy \"$outputFilePath\""
    }

    fun startExport() {
        updateUiState { it.copy(isExporting = true, exportProgress = 0, errorMessage = null) }
    }

    fun updateExportProgress(progress: Int) {
        updateUiState { it.copy(exportProgress = progress.coerceIn(0, 100)) }
    }

    fun finishExport() {
        updateUiState { it.copy(isExporting = false, exportProgress = 100) }
    }

    fun exportError(error: String) {
        updateUiState { it.copy(isExporting = false, errorMessage = error) }
    }

    fun clearError() {
        updateUiState { it.copy(errorMessage = null) }
    }

    fun saveRecipe(projectName: String): EditRecipe? =
        _project.value?.let { EditRecipe.fromVideoProject(projectName, it) }

    fun loadRecipe(recipe: EditRecipe) {
        _project.value = recipe.toVideoProject()
        _undoStack.value = emptyList()
        _redoStack.value = emptyList()
        updateUiState { it.copy(pendingOperationCount = recipe.operations.size, canUndo = false) }
    }

    private fun updateUiState(updater: (VideoEditingUiState) -> VideoEditingUiState) {
        _uiState.update(updater)
        if (_undoStack.value.isNotEmpty()) {
            _hasUnsavedEdits.value = true
        }
    }
}