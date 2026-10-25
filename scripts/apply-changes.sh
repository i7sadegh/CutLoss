#!/usr/bin/env bash
###############################################################################
# CutLoss phase 8 -- remove the Text, Overlay, Crop and Canvas tools from the
# video editor bottom tool row, together with ALL related code:
#   * Text system    : AddText op, text editing toolbar + settings sheets,
#                      font manager, TextOverlayView, DraggableTextOverlayView,
#                      TextRenderUtils, bundled Roboto font asset
#   * Overlay system : AddImageOverlay op (image/GIF/video PIP), image editing
#                      toolbar, chroma key, ImageOverlayView,
#                      DraggableImageOverlayView, layer reorder buttons
#   * Crop system    : Crop op, crop toolbar + CropOverlayView, crop preview
#   * Canvas system  : CanvasBackground op, background toolbar, blur preview,
#                      background image picker
#   * Keyframes      : KeyframePoint model + whole keyframe editing UI
#                      (only served text/image overlays)
#   * Preview render : segmented preview button + pipeline (crop/text only)
# Audio, video toolbar (trim/split/mute/speed/freeze/delete), transitions,
# magnet snapping and export are untouched.
#
# Invariants: pure ASCII, idempotent (2nd run = all [skip], zero diff),
# hard verification gate exits 1 BEFORE anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase8] $*"; }
fail() { echo "[phase8][ERROR] $*" >&2; exit 1; }

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
EXT="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"
ENGINE="app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"
EO="app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt"
SER="app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt"
PIA="app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
AVEXML="app/src/main/res/layout/activity_video_editing.xml"

CV="app/src/main/java/com/tharunbirla/librecuts/customviews"
UT="app/src/main/java/com/tharunbirla/librecuts/utils"
LAY="app/src/main/res/layout"
DRW="app/src/main/res/drawable"

###############################################################################
# Step 0 -- preconditions (phase 7 must already be applied)
###############################################################################
log "step0: checking preconditions"
[ -f "$VEA" ] || fail "VideoEditingActivity.kt not found"
[ -f "$LAY/video_editing_toolbar.xml" ] || fail "video_editing_toolbar.xml not found"
grep -q "btnVideoFreezeFrame" "$LAY/video_editing_toolbar.xml" \
  || fail "phase-7 marker missing (btnVideoFreezeFrame)"
[ ! -f "$LAY/bottom_sheet_mask.xml" ] || fail "phase-7 not applied (bottom_sheet_mask.xml still present)"
[ ! -f "$LAY/dialog_adjustments.xml" ] || fail "phase-7 not applied (dialog_adjustments.xml still present)"
[ ! -f "$CV/MaskedFrameLayout.kt" ] || fail "phase-7 not applied (MaskedFrameLayout.kt still present)"
log "step0: [ok] phase-7 base confirmed"

###############################################################################
# Step 1 -- delete feature files (Kotlin views/utils, layouts, font, drawables)
###############################################################################
DELETE_FILES="
$CV/TextOverlayView.kt
$CV/DraggableTextOverlayView.kt
$CV/ImageOverlayView.kt
$CV/DraggableImageOverlayView.kt
$CV/CropOverlayView.kt
$CV/HSVColorPickerView.kt
$UT/TextRenderUtils.kt
$UT/FontManager.kt
$LAY/text_editing_toolbar.xml
$LAY/text_background_settings.xml
$LAY/text_format_settings.xml
$LAY/text_shadow_settings.xml
$LAY/text_stroke_settings.xml
$LAY/image_editing_toolbar.xml
$LAY/crop_editing_toolbar.xml
$LAY/background_editing_toolbar.xml
$LAY/keyframe_editing_toolbar.xml
$LAY/chroma_key_bottom_sheet_dialog.xml
$LAY/dialog_custom_color_picker.xml
$LAY/dialog_font_manager.xml
$LAY/item_font_manager.xml
app/src/main/assets/fonts/Roboto-Regular.ttf
$DRW/ic_canvas_24.xml
$DRW/ic_canvas_color_24.xml
$DRW/ic_color_lens_24.xml
$DRW/ic_color_picker_24.xml
$DRW/ic_crop_24.xml
$DRW/ic_crop_16_9_24.xml
$DRW/ic_crop_portrait_24.xml
$DRW/ic_crop_square_24.xml
$DRW/ic_format_24.xml
$DRW/ic_keyboard_24.xml
$DRW/ic_keyframe_add.xml
$DRW/ic_keyframe_main.xml
$DRW/ic_keyframe_remove.xml
$DRW/ic_loop_24.xml
$DRW/ic_mirror.xml
$DRW/ic_opacity_24.xml
$DRW/ic_palette_24.xml
$DRW/ic_preview_24.xml
$DRW/ic_rotate_right_24.xml
$DRW/ic_arrow_drop_down_24.xml
$DRW/ic_text_24.xml
$DRW/ic_text_bg_24.xml
$DRW/ic_text_shadow_24.xml
$DRW/ic_text_stroke_24.xml
$DRW/ic_align_center_24.xml
$DRW/ic_align_left_24.xml
$DRW/ic_align_right_24.xml
$DRW/bg_layer_selected.xml
"

ND=0; NS=0
for f in $DELETE_FILES; do
    if [ -f "$f" ]; then
        rm -f "$f"
        ND=$((ND+1))
    else
        NS=$((NS+1))
    fi
done
# remove the fonts dir when it became empty
if [ -d app/src/main/assets/fonts ] && [ -z "$(ls -A app/src/main/assets/fonts 2>/dev/null)" ]; then
    rmdir app/src/main/assets/fonts 2>/dev/null || true
fi
log "step1: deleted=$ND skipped=$NS"

###############################################################################
# Step 2 -- EditOperation.kt: drop Crop / KeyframePoint / AddText /
#           AddImageOverlay / CanvasBackground models + TextPosition enum
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def rep(s, old, new, n=1):
    c = s.count(old)
    if c != n:
        die("rep count=%d expected=%d for: %r" % (c, n, old[:90]))
    return s.replace(old, new)

def cut_between(s, a, b):
    i = s.find(a)
    if i < 0:
        die("cut_between start miss: %r" % a[:70])
    j = s.find(b, i + len(a))
    if j < 0:
        die("cut_between end miss: %r" % b[:70])
    return s[:i] + s[j:]

P = "app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt"
s = rd(P)

if "data class AddText" not in s:
    print("[phase8] step2: [skip] EditOperation already trimmed")
    sys.exit(0)

# --- Crop data class (with doc comment) ---
s = cut_between(s,
    "    /**\n     * Crop operation: Crops video to a specified aspect ratio.\n",
    "    /**\n     * Text overlay operation: Adds customizable text to the video at specified position and size.\n")

# --- KeyframePoint + AddText (with doc comment) ---
s = cut_between(s,
    "    /**\n     * Text overlay operation: Adds customizable text to the video at specified position and size.\n",
    "    data class MergeItem(\n")

# --- AddImageOverlay (with doc comment) ---
s = cut_between(s,
    "    /**\n     * Image overlay operation: Adds an image to the video at specified position, size, and rotation angle.\n",
    "    /**\n     * Canvas background operation: Sets the padding style for clips that do not match the primary aspect ratio.\n")

# --- CanvasBackground (with doc comment + nested enum) ---
s = cut_between(s,
    "    /**\n     * Canvas background operation: Sets the padding style for clips that do not match the primary aspect ratio.\n",
    "}\n\n/**\n * Enum for text positioning options in video overlays.\n")

# --- TextPosition enum ---
s = cut_between(s,
    "/**\n * Enum for text positioning options in video overlays.\n",
    "val EditOperation.id: String\n")

# --- id extension: drop removed branches ---
s = rep(s, "        is EditOperation.Crop -> id\n", "")
s = rep(s, "        is EditOperation.AddText -> id\n", "")
s = rep(s, "        is EditOperation.AddImageOverlay -> id\n", "")
s = rep(s, "        is EditOperation.CanvasBackground -> id\n", "")

wr(P, s)
print("[phase8] step2: [ok] EditOperation.kt trimmed")
CUTPY

###############################################################################
# Step 3 -- VideoEditingActivity.kt surgery (the big one)
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def rep(s, old, new, n=1):
    c = s.count(old)
    if c != n:
        die("rep count=%d expected=%d for: %r" % (c, n, old[:90]))
    return s.replace(old, new)

def sub(s, pat, new, n=1):
    r, c = re.subn(pat, new, s)
    if c != n:
        die("sub count=%d expected=%d for: %s" % (c, n, pat[:90]))
    return r

def cut_between(s, a, b):
    i = s.find(a)
    if i < 0:
        die("cut_between start miss: %r" % a[:70])
    j = s.find(b, i + len(a))
    if j < 0:
        die("cut_between end miss: %r" % b[:70])
    return s[:i] + s[j:]

def cut_between_re(s, a, b):
    ma = re.search(a, s)
    if not ma:
        die("cut_between_re start miss: %s" % a[:70])
    mb = re.compile(b).search(s, ma.end())
    if not mb:
        die("cut_between_re end miss: %s" % b[:70])
    return s[:ma.start()] + s[mb.start():]

def cut_fun(s, header):
    i = s.find("    " + header)
    if i < 0:
        die("cut_fun miss: " + header)
    j = s.find("{", i)
    d = 0
    k = j
    while k < len(s):
        if s[k] == "{":
            d += 1
        elif s[k] == "}":
            d -= 1
            if d == 0:
                break
        k += 1
    if d != 0 or k >= len(s):
        die("cut_fun unbalanced: " + header)
    end = k + 1
    if s[end:end + 1] == "\n":
        end += 1
        if s[end:end + 1] == "\n":
            end += 1
    start = i
    if start >= 2 and s[start - 2:start] == "\n\n":
        start -= 1
    return s[:start] + s[end:]

P = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
s = rd(P)

if "R.id.btnText" not in s:
    print("[phase8] step3: [skip] VEA already trimmed")
    sys.exit(0)

# ---------------- imports ----------------
s = rep(s, "import com.tharunbirla.librecuts.customviews.DraggableTextOverlayView\n"
           "import com.tharunbirla.librecuts.customviews.DraggableImageOverlayView\n"
           "import com.tharunbirla.librecuts.customviews.ImageOverlayView\n", "")
s = rep(s, "import com.tharunbirla.librecuts.models.TextPosition\n", "")

# ---------------- fields ----------------
s = rep(s, "    private lateinit var textTrackContainer: LinearLayout\n"
           "    private lateinit var imageTrackContainer: LinearLayout\n", "")
s = rep(s, "    private lateinit var btnMoveLayerUp: ImageButton\n"
           "    private lateinit var btnMoveLayerDown: ImageButton\n", "")
s = rep(s, "    private lateinit var previewLoadingOverlay: View\n", "")
s = rep(s, "    private lateinit var btnPreview: ImageButton\n", "")
s = rep(s, "    private var tvPreviewBadge: TextView? = null\n"
           "    private var textOverlayView: com.tharunbirla.librecuts.customviews.TextOverlayView? = null\n", "")
s = cut_between(s, "    private var bgPreviewImageView: ImageView? = null\n",
                "    private val activeExtractionUris = mutableSetOf<Uri>()\n")
# font field block (comment line contains non-ASCII dash -- use wildcards)
s = sub(s, r"\n\n    // [^\n]*FONT: cached absolute path[^\n]*\n"
            r"    // Populated in onCreate via ffmpegEngine\.copyFontToCache\(\)\.\n"
            r"    // Passed to buildConsolidatedFFmpegCommand\(\) so drawtext can find the font\.\n"
            r"    private var fontFilePath: String\? = null\n", "")
# text/image editing state fields (keep isMagnetEnabled)
s = rep(s, "    // Inline text editing state\n"
           "    private var draggableTextOverlay: DraggableTextOverlayView? = null\n"
           "    private var textEditingToolbar: View? = null\n"
           "    private var isTextEditingActive = false\n"
           "\n"
           "    // Inline image overlay editing state\n"
           "    private var draggableImageOverlay: DraggableImageOverlayView? = null\n"
           "    private var imageOverlayView: ImageOverlayView? = null\n"
           "    private var imageEditingToolbar: View? = null\n"
           "    private var isImageEditingActive = false\n"
           "    private var isMagnetEnabled = true\n",
           "    private var isMagnetEnabled = true\n")
s = rep(s, "    private var backgroundEditingToolbar: View? = null\n", "")
s = rep(s, "    private var cropEditingToolbar: View? = null\n"
           "    private var cropOverlayView: com.tharunbirla.librecuts.customviews.CropOverlayView? = null\n"
           "    private var initialCropOperation: com.tharunbirla.librecuts.models.EditOperation.Crop? = null\n\n", "")
s = rep(s, "    private var keyframeEditingToolbar: View? = null\n"
           "    private var isKeyframeEditingMode = false\n"
           "    private var activeKeyframeProperty = \"Position\" // \"Position\", \"Opacity\", or \"Speed\"\n\n", "")
s = sub(s, r"\n    // Segmented preview state\n"
            r"    private var previewJob: Job\? = null\n"
            r"    private var isShowingPreview = false\n"
            r"    private var isRenderingPreview = false\n"
            r"    private var previewFile: File\? = null\n"
            r"    \n", "\n")
s = cut_between(s, "    private var activeFontSelectionCallback: ((com.tharunbirla.librecuts.utils.FontItem) -> Unit)? = null\n",
                "    private var photoSequencePreviewImageView: ImageView? = null\n")

# ---------------- onCreate: font copy + text PNG renderer wiring ----------------
s = cut_between_re(s,
    r"        // [^\n]*Copy the bundled font from assets[^\n]*\n",
    "        // Initialize UI components\n")

# ---------------- initializeViews ----------------
s = rep(s, "        bgPreviewImageView = findViewById(R.id.bgPreviewImageView)\n", "")
s = rep(s, "        val canvasLayoutListener = android.view.ViewTreeObserver.OnGlobalLayoutListener {\n"
           "            triggerCanvasLayoutUpdate()\n"
           "        }\n"
           "        playerContainer.viewTreeObserver.addOnGlobalLayoutListener(canvasLayoutListener)\n"
           "        pipPlayerContainer.viewTreeObserver.addOnGlobalLayoutListener(canvasLayoutListener)\n"
           "        fullscreenCanvasHolder.viewTreeObserver.addOnGlobalLayoutListener(canvasLayoutListener)\n\n", "")
s = rep(s, "        previewLoadingOverlay = findViewById(R.id.previewLoadingOverlay)\n", "")
s = rep(s, "        textTrackContainer = findViewById(R.id.textTrackContainer)\n"
           "        imageTrackContainer = findViewById(R.id.imageTrackContainer)\n", "")
# magnet listener: drop overlay snapping lines
s = rep(s, "            draggableTextOverlay?.isSnappingEnabled = isMagnetEnabled\n"
           "            draggableImageOverlay?.isSnappingEnabled = isMagnetEnabled\n", "")
# layer reorder buttons
s = rep(s, "        btnMoveLayerUp = findViewById(R.id.btnMoveLayerUp)\n"
           "        btnMoveLayerDown = findViewById(R.id.btnMoveLayerDown)\n"
           "        btnMoveLayerUp.setBounceClickListener {\n"
           "            viewModel.selectedOperationId.value?.let { id ->\n"
           "                viewModel.moveOverlayOperation(id, moveUp = true)\n"
           "            }\n"
           "        }\n"
           "        btnMoveLayerDown.setBounceClickListener {\n"
           "            viewModel.selectedOperationId.value?.let { id ->\n"
           "                viewModel.moveOverlayOperation(id, moveUp = false)\n"
           "            }\n"
           "        }\n\n", "")
# text/image overlay views + text toolbar + draggable image overlay + crop overlay (contiguous)
s = cut_between(s, "        textOverlayView = try {\n", "        imageEditingToolbar = try {\n")
# image editing toolbar setup
s = cut_between(s, "        imageEditingToolbar = try {\n", "        videoEditingToolbar = try {\n")
# crop + background + keyframe toolbar setups (contiguous)
s = cut_between(s, "        cropEditingToolbar = try {\n",
                "        findViewById<ImageButton>(R.id.btnHome)?.setBounceClickListener {\n")
# tvPreviewBadge init
s = rep(s, "        tvPreviewBadge = findViewById(R.id.tvPreviewBadge)\n\n", "")
# tool button wirings: keep btnAudio only
s = rep(s, "        // Tool Buttons with proper scoping\n"
           "        findViewById<ImageButton>(R.id.btnText).setBounceClickListener {\n"
           "            setActiveToolButton(R.id.btnText)\n"
           "            textAction()\n"
           "        }\n"
           "        findViewById<ImageButton>(R.id.btnMediaOverlay)?.setBounceClickListener {\n"
           "            setActiveToolButton(R.id.btnMediaOverlay)\n"
           "            mediaOverlayAction()\n"
           "        }\n"
           "\n"
           "        findViewById<ImageButton>(R.id.btnAudio).setBounceClickListener {\n",
           "        // Tool Buttons with proper scoping\n"
           "        findViewById<ImageButton>(R.id.btnAudio).setBounceClickListener {\n")
s = rep(s, "        findViewById<ImageButton>(R.id.btnCrop).setBounceClickListener {\n"
           "            setActiveToolButton(R.id.btnCrop)\n"
           "            cropAction()\n"
           "        }\n"
           "\n"
           "        findViewById<ImageButton>(R.id.btnCanvasBackground)?.setBounceClickListener {\n"
           "            setActiveToolButton(R.id.btnCanvasBackground)\n"
           "            canvasBackgroundAction()\n"
           "        }\n\n", "")
# undo/redo/preview block: drop btnPreview
s = rep(s, "        try {\n"
           "            btnUndo = findViewById(R.id.btnUndo)\n"
           "            btnRedo = findViewById(R.id.btnRedo)\n"
           "            btnPreview = findViewById(R.id.btnPreview)\n"
           "            btnUndo.setBounceClickListener {\n"
           "                if (isShowingPreview) dismissPreview()\n"
           "                viewModel.undo()\n"
           "            }\n"
           "            btnRedo.setBounceClickListener {\n"
           "                if (isShowingPreview) dismissPreview()\n"
           "                viewModel.redo()\n"
           "            }\n"
           "            btnPreview.setBounceClickListener {\n"
           "                if (isShowingPreview) {\n"
           "                    dismissPreview()\n"
           "                } else {\n"
           "                    renderSegmentedPreview()\n"
           "                }\n"
           "            }\n"
           "        } catch (e: Exception) {\n"
           "            Log.d(TAG, \"Undo/Redo/Preview buttons not found in layout (optional)\")\n"
           "        }\n",
           "        try {\n"
           "            btnUndo = findViewById(R.id.btnUndo)\n"
           "            btnRedo = findViewById(R.id.btnRedo)\n"
           "            btnUndo.setBounceClickListener {\n"
           "                viewModel.undo()\n"
           "            }\n"
           "            btnRedo.setBounceClickListener {\n"
           "                viewModel.redo()\n"
           "            }\n"
           "        } catch (e: Exception) {\n"
           "            Log.d(TAG, \"Undo/Redo buttons not found in layout (optional)\")\n"
           "        }\n")

# ---------------- updateUIInteractionState ----------------
s = rep(s, "        val isBusy = uiState.isExporting || isRenderingPreview\n"
           "        \n"
           "        if (::previewLoadingOverlay.isInitialized) {\n"
           "            previewLoadingOverlay.visibility = if (isRenderingPreview) View.VISIBLE else View.GONE\n"
           "        }\n"
           "        \n",
           "        val isBusy = uiState.isExporting\n")
s = cut_between(s, "        if (::btnPreview.isInitialized) {\n",
                "        customVideoSeeker.isEnabled = !isBusy\n")

# ---------------- setActiveToolButton ----------------
s = rep(s, "    private fun setActiveToolButton(activeId: Int) {\n"
           "        if (isShowingPreview) dismissPreview()\n"
           "        val toolIds = listOf(R.id.btnText, R.id.btnMediaOverlay, R.id.btnAudio, R.id.btnCrop, R.id.btnCanvasBackground)\n",
           "    private fun setActiveToolButton(activeId: Int) {\n"
           "        val toolIds = listOf(R.id.btnAudio)\n")

# ---------------- observeViewModelState ----------------
s = rep(s,
    "            viewModel.selectedOperationId.collect { selectedId ->\n"
    "                if (selectedId != null && isShowingPreview) dismissPreview()\n"
    "                textOverlayView?.hiddenOperationId = selectedId\n"
    "                imageOverlayView?.hiddenOperationId = selectedId\n"
    "                \n"
    "                if (selectedId != null) {\n"
    "                    if (isKeyframeEditingMode) {\n"
    "                        exitKeyframeEditingMode()\n"
    "                    }\n"
    "\n"
    "                    // Reset editing modes to prevent multiple active editing toolbars/states\n"
    "                    draggableTextOverlay?.deactivate()\n"
    "                    draggableImageOverlay?.deactivate()\n"
    "                    exitTextEditingMode()\n"
    "                    exitImageEditingMode()\n"
    "\n"
    "                    val op = viewModel.project.value?.operations?.find {\n"
    "                        when (it) {\n"
    "                            is EditOperation.AddText -> it.id == selectedId\n"
    "                            is EditOperation.AddImageOverlay -> it.id == selectedId\n"
    "                            is EditOperation.AddBackgroundAudio -> it.id == selectedId\n"
    "                            else -> false\n"
    "                        }\n"
    "                    }\n"
    "                    when (op) {\n"
    "                        is EditOperation.AddText -> {\n"
    "                            draggableTextOverlay?.activateForEdit(op)\n"
    "                            enterTextEditingMode(isReEditing = true)\n"
    "                        }\n"
    "                        is EditOperation.AddImageOverlay -> {\n"
    "                            draggableImageOverlay?.activateForEdit(op)\n"
    "                            enterImageEditingModeForEdit(op.rotationAngle)\n"
    "                        }\n"
    "                        is EditOperation.AddBackgroundAudio -> {\n"
    "                            enterAudioEditingMode(op)\n"
    "                        }\n"
    "                        else -> {}\n"
    "                    }\n"
    "                } else {\n"
    "                    draggableTextOverlay?.deactivate()\n"
    "                    draggableImageOverlay?.deactivate()\n"
    "                    exitTextEditingMode()\n"
    "                    exitImageEditingMode()\n"
    "                    exitAudioEditingMode()\n"
    "                }\n"
    "                \n"
    "                // Re-render tracks so the selection highlight updates\n"
    "                viewModel.project.value?.let { renderTracks(it) }\n"
    "                updateLayerReorderButtons()\n"
    "            }\n",
    "            viewModel.selectedOperationId.collect { selectedId ->\n"
    "                if (selectedId != null) {\n"
    "                    val op = viewModel.project.value?.operations?.find {\n"
    "                        when (it) {\n"
    "                            is EditOperation.AddBackgroundAudio -> it.id == selectedId\n"
    "                            else -> false\n"
    "                        }\n"
    "                    }\n"
    "                    when (op) {\n"
    "                        is EditOperation.AddBackgroundAudio -> {\n"
    "                            enterAudioEditingMode(op)\n"
    "                        }\n"
    "                        else -> {}\n"
    "                    }\n"
    "                } else {\n"
    "                    exitAudioEditingMode()\n"
    "                }\n"
    "                \n"
    "                // Re-render tracks so the selection highlight updates\n"
    "                viewModel.project.value?.let { renderTracks(it) }\n"
    "            }\n")
# project collector: text/image/crop/canvas blocks
s = cut_between(s, "                    textOverlayView?.let { overlay ->\n",
                "                    renderTracks(project)\n")
s = rep(s, "                    renderTracks(project)\n                    updateLayerReorderButtons()\n",
           "                    renderTracks(project)\n")

# ---------------- whole function cuts ----------------
# setupTextFontSelector + showFontManagerBottomSheet (contiguous, before saveProjectLauncher)
s = cut_between(s, "    private fun setupTextFontSelector(formatContainer: View?) {\n",
                "    private val saveProjectLauncher = registerForActivityResult(\n")
for h in [
    "private fun updateLayerReorderButtons(",
    "private fun applyCropPreview(",
    "private fun resetCropPreview(",
    "private fun cropAction(",
    "private fun canvasBackgroundAction(",
    "private fun enterCanvasBackgroundEditingMode(",
    "private fun exitCanvasBackgroundEditingMode(",
    "private fun textAction(",
    "private fun enterTextEditingMode(",
    "private fun exitTextEditingMode(",
    "private fun duplicateSelectedOverlay(",
    "private fun pickBackgroundImage(",
    "private fun mediaOverlayAction(",
    "private fun openImagePicker(",
    "private fun showImageOverlayConfig(",
    "private fun getExtensionFromUri(",
    "private fun getOverlayFileDurationMs(",
    "private fun enterImageEditingMode(",
    "private fun enterImageEditingModeForEdit(",
    "private fun exitImageEditingMode(",
    "private fun getPresetCropBounds(",
    "private fun enterCropEditingMode(",
    "private fun exitCropEditingMode(",
    "private fun updateCanvasBackgroundPreview(",
    "private fun updateCropUi(",
]:
    s = cut_fun(s, h)

# closeActiveEditingModes: keep video/audio toolbars only
s = rep(s,
    "    private fun closeActiveEditingModes() {\n"
    "        if (isTextEditingActive) {\n"
    "            draggableTextOverlay?.commitText()\n"
    "            isTextEditingActive = false\n"
    "        }\n"
    "        if (isImageEditingActive) {\n"
    "            draggableImageOverlay?.commitImage()\n"
    "            isImageEditingActive = false\n"
    "        }\n"
    "        textEditingToolbar?.visibility = View.GONE\n"
    "        imageEditingToolbar?.visibility = View.GONE\n"
    "        videoEditingToolbar?.visibility = View.GONE\n"
    "        audioEditingToolbar?.visibility = View.GONE\n"
    "        cropEditingToolbar?.visibility = View.GONE\n"
    "        backgroundEditingToolbar?.visibility = View.GONE\n"
    "    }\n",
    "    private fun closeActiveEditingModes() {\n"
    "        videoEditingToolbar?.visibility = View.GONE\n"
    "        audioEditingToolbar?.visibility = View.GONE\n"
    "    }\n")

# clearProjectAndShowImportScreen: drop text/image mode exits
s = rep(s, "        // Hide toolbars\n"
           "        exitVideoEditingMode()\n"
           "        exitAudioEditingMode()\n"
           "        exitImageEditingMode()\n"
           "        exitTextEditingMode()\n",
           "        // Hide toolbars\n"
           "        exitVideoEditingMode()\n"
           "        exitAudioEditingMode()\n")

# onActivityResult: drop PICK_IMAGE + PICK_BACKGROUND_IMAGE branches
s = rep(s, "        } else if (requestCode == PICK_IMAGE_REQUEST && resultCode == Activity.RESULT_OK) {\n"
           "            data?.data?.let { imageUri ->\n"
           "                showImageOverlayConfig(imageUri)\n"
           "            }\n", "")
s = cut_between(s, " else if (requestCode == PICK_BACKGROUND_IMAGE_REQUEST && resultCode == Activity.RESULT_OK) {\n",
                "\n    }\n\n    private fun audioAction() {")

# saveAction: commit/preview/font plumbing
s = rep(s, "    /**\n"
           "     * SAVE/EXPORT: Consolidates all pending operations into a single FFmpeg command and runs it.\n"
           "     *\n"
           "     * KEY FIX: fontFilePath (populated in onCreate from assets/fonts/Roboto-Regular.ttf)\n"
           "     * is now passed to buildConsolidatedFFmpegCommand so drawtext gets a valid fontfile= path.\n"
           "     */\n",
           "    /**\n"
           "     * SAVE/EXPORT: Consolidates all pending operations into a single FFmpeg command and runs it.\n"
           "     */\n")
s = rep(s, "        commitActiveEditsIfAny()\n"
           "        if (isShowingPreview) dismissPreview()\n"
           "        val project = viewModel.project.value\n",
           "        val project = viewModel.project.value\n")
s = sub(s, r"\n        // Warn but don[^\n]*\n"
            r"        if \(fontFilePath == null\) \{\n"
            r"            Log\.w\(TAG, \"fontFilePath is null[^\n]*\n"
            r"                    \"Check that assets/fonts/Roboto-Regular\.ttf exists[^\n]*\n"
            r"        \}\n", "")
s = rep(s, "                    fontFilePath = fontFilePath,\n", "")

# export dialogs
s = rep(s, "        commitActiveEditsIfAny()\n"
           "        if (isShowingPreview) dismissPreview()\n"
           "\n"
           "        ExportSettingsDialog(\n",
           "        ExportSettingsDialog(\n")
s = rep(s, "            fontPath = fontFilePath,\n", "")
s = rep(s, "    private fun showQualitySettingsDialog() {\n"
           "        commitActiveEditsIfAny()\n"
           "        if (isShowingPreview) dismissPreview()\n"
           "        val bottomSheetDialog = BottomSheetDialog(this)\n",
           "    private fun showQualitySettingsDialog() {\n"
           "        val bottomSheetDialog = BottomSheetDialog(this)\n")

# setupExoPlayer STATE_ENDED guard
s = rep(s, "                        stopProgressUpdater()\n"
           "                        if (isShowingPreview) dismissPreview()\n",
           "                        stopProgressUpdater()\n")

# syncUiWithPlayer: overlay positions + keyframes + canvas blur
s = rep(s, "            textOverlayView?.currentPositionMs = currentGlobalPos\n"
           "            imageOverlayView?.currentPositionMs = currentGlobalPos\n"
           "\n"
           "            if (isKeyframeEditingMode) {\n"
           "                updateDraggableOverlayFromKeyframes(currentGlobalPos)\n"
           "            }\n\n", "")
s = cut_between(s, "            if (activeClipIndex != lastActiveClipIndexForBlur) {\n",
                "            // Real-time transition preview overlay update\n")

# seekToGlobalPosition: overlay positions + keyframes
s = rep(s, "        textOverlayView?.currentPositionMs = globalPos\n"
           "        imageOverlayView?.currentPositionMs = globalPos\n"
           "\n"
           "        if (isKeyframeEditingMode) {\n"
           "            updateDraggableOverlayFromKeyframes(globalPos)\n"
           "        }\n", "")

# performRenderTracks: track container widths + overlay tracks + keyframe cues
s = rep(s, "        textTrackContainer.layoutParams = textTrackContainer.layoutParams.apply {\n"
           "            width = timelineWidth\n"
           "        }\n"
           "        imageTrackContainer.layoutParams = imageTrackContainer.layoutParams.apply {\n"
           "            width = timelineWidth\n"
           "        }\n", "")
s = cut_between(s, "        // Combined Text and Image tracks (Overlays) in Z-order stack\n",
                "        // Audio tracks\n")
s = cut_between(s, "        // Keyframe cues tracks\n",
                "        if (activeExtractionCount == 0 && isImportLoading) {\n")

# trim dialog + custom seeker preview guards
s = rep(s, "    private fun showVideoSegmentTrimDialog(index: Int, item: com.tharunbirla.librecuts.models.EditOperation.MergeItem) {\n"
           "        if (isShowingPreview) dismissPreview()\n",
           "    private fun showVideoSegmentTrimDialog(index: Int, item: com.tharunbirla.librecuts.models.EditOperation.MergeItem) {\n")
s = rep(s, "        customVideoSeeker.onSeekListener = { seekPosition ->\n"
           "            // Dismiss preview when user manually seeks\n"
           "            if (isShowingPreview) dismissPreview()\n",
           "        customVideoSeeker.onSeekListener = { seekPosition ->\n")
# setupCustomSeeker: overlay time sync
s = rep(s, "                updateDurationDisplay(newSeekTime.toInt(), totalDuration.toInt())\n"
           "                \n"
           "                textOverlayView?.currentPositionMs = newSeekTime\n"
           "                imageOverlayView?.currentPositionMs = newSeekTime\n",
           "                updateDurationDisplay(newSeekTime.toInt(), totalDuration.toInt())\n")

# fullscreen canvas: drop crop-aware layout trigger
s = rep(s, "        }\n"
           "        targetContainer.post {\n"
           "            triggerCanvasLayoutUpdate()\n"
           "        }\n"
           "    }\n",
           "        }\n"
           "    }\n")
s = cut_fun(s, "private fun triggerCanvasLayoutUpdate(")

# segmented preview rendering block (comment + renderSegmentedPreview + dismissPreview)
def cut_re_lit(s, a, b):
    ma = re.search(a, s)
    if not ma:
        die("cut_re_lit start miss: %s" % a[:70])
    j = s.find(b, ma.end())
    if j < 0:
        die("cut_re_lit end miss: %r" % b[:70])
    return s[:ma.start()] + s[j:]
s = cut_re_lit(s, r"    // [^\n]*Segmented Preview Rendering[^\n]*\n",
               "    override fun onPause() {\n")

# onPause / onDestroy preview + overlay cleanup
s = rep(s, "        frameExtractionJob?.cancel()\n"
           "        previewJob?.cancel()\n"
           "    }\n"
           "\n"
           "    override fun onDestroy() {\n",
           "        frameExtractionJob?.cancel()\n"
           "    }\n"
           "\n"
           "    override fun onDestroy() {\n")
s = rep(s, "        frameExtractionJob?.cancel()\n"
           "        previewJob?.cancel()\n"
           "        clearFrameCache()\n"
           "        extractedFrames.forEach { if (!it.isRecycled) it.recycle() }\n"
           "        draggableTextOverlay?.deactivate()\n"
           "        draggableImageOverlay?.deactivate()\n"
           "        previewFile?.delete()\n"
           "        super.onDestroy()\n",
           "        frameExtractionJob?.cancel()\n"
           "        clearFrameCache()\n"
           "        extractedFrames.forEach { if (!it.isRecycled) it.recycle() }\n"
           "        super.onDestroy()\n")

# palette fields + functions
s = cut_between(s, "    private val textPalettePresets = listOf(\n",
                "    private fun markPaletteSelection(container: LinearLayout, selectedTag: String?) {\n")
for h in [
    "private fun markPaletteSelection(",
    "private fun buildTextPaletteRow(",
    "private fun setupColorPicker(",
    "private fun setupBgColorPicker(",
    "private fun setupStrokeColorPicker(",
    "private fun setupShadowColorPicker(",
    "private fun updateActiveBoundaries(",
    "private fun showChromaKeyDialog(",
    "private fun showCustomColorPicker(",
    "private fun commitActiveEditsIfAny(",
    "private fun enterKeyframeEditingMode(",
    "private fun exitKeyframeEditingMode(",
    "private fun showKeyframePropertyMenu(",
    "private fun handleKeyframeActionClick(",
    "private fun handleKeyframeSliderChange(",
    "private fun updateKeyframeActionButtonState(",
    "private fun updateDraggableOverlayFromKeyframes(",
    "private fun interpolateKeyframes(",
    "private fun interpolateKeyframePosition(",
]:
    s = cut_fun(s, h)

# getSnapTargetsMs: drop text/image overlay snap targets
s = rep(s, "                is EditOperation.AddText -> {\n"
           "                    op.startTimeMs?.let { targets.add(it) }\n"
           "                    op.endTimeMs?.let { targets.add(it) }\n"
           "                }\n"
           "                is EditOperation.AddImageOverlay -> {\n"
           "                    op.startTimeMs?.let { targets.add(it) }\n"
           "                    op.endTimeMs?.let { targets.add(it) }\n"
           "                }\n", "")

# companion constants
s = rep(s, "        private const val PICK_AUDIO_REQUEST = 2\n"
           "        private const val PICK_IMAGE_REQUEST = 3\n"
           "        private const val PICK_DIRECTORY_REQUEST = 5\n"
           "        private const val PICK_BACKGROUND_IMAGE_REQUEST = 6\n",
           "        private const val PICK_AUDIO_REQUEST = 2\n"
           "        private const val PICK_DIRECTORY_REQUEST = 5\n")

wr(P, s)
print("[phase8] step3: [ok] VideoEditingActivity.kt trimmed")
CUTPY

###############################################################################
# Step 4 -- VideoEditingViewModel.kt surgery
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def rep(s, old, new, n=1):
    c = s.count(old)
    if c != n:
        die("rep count=%d expected=%d for: %r" % (c, n, old[:90]))
    return s.replace(old, new)

def cut_between(s, a, b):
    i = s.find(a)
    if i < 0:
        die("cut_between start miss: %r" % a[:70])
    j = s.find(b, i + len(a))
    if j < 0:
        die("cut_between end miss: %r" % b[:70])
    return s[:i] + s[j:]

def cut_between_re(s, a, b):
    ma = re.search(a, s)
    if not ma:
        die("cut_between_re start miss: %s" % a[:70])
    mb = re.compile(b).search(s, ma.end())
    if not mb:
        die("cut_between_re end miss: %s" % b[:70])
    return s[:ma.start()] + s[mb.start():]

P = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
s = rd(P)

if "buildVideoFilterStages" not in s:
    print("[phase8] step4: [skip] ViewModel already trimmed")
    sys.exit(0)

# import
s = rep(s, "import com.tharunbirla.librecuts.models.TextPosition\n", "")

# filter helper block: buildCropFilterExpr (with doc)
s = cut_between(s, "    /** Build a crop filter expression for an aspect ratio. */\n",
                "    /** Renders AddText ops to transparent PNGs (WYSIWYG canvas rendering).\n")
# textPng fields + prepare + overlayPosExpr + drawtext + interpolation + color + enable + buildVideoFilterStages
s = cut_between(s, "    /** Renders AddText ops to transparent PNGs (WYSIWYG canvas rendering).\n",
                "    /**\n     * Build the consolidated FFmpeg command for final export.\n")

# buildConsolidatedFFmpegCommand signature + doc
s = rep(s, "     * Uses -filter_complex with explicit stream labels so each filter stage\n"
           "     * receives the correct input dimensions (e.g., drawtext after crop uses\n"
           "     * post-crop resolution).\n",
           "     * Uses -filter_complex with explicit stream labels so each filter stage\n"
           "     * receives the correct input dimensions.\n")
s = rep(s, "     * @param outputFilePath  Absolute path for the exported video.\n"
           "     * @param fontFilePath    Absolute path to a TTF font file (from assets via copyFontToCache).\n"
           "     *                        Required for text overlays to render on Android.\n",
           "     * @param outputFilePath  Absolute path for the exported video.\n")
s = rep(s, "    fun buildConsolidatedFFmpegCommand(\n"
           "        sourceFilePath: String,\n"
           "        outputFilePath: String,\n"
           "        fontFilePath: String? = null,\n"
           "        context: Context? = null\n",
           "    fun buildConsolidatedFFmpegCommand(\n"
           "        sourceFilePath: String,\n"
           "        outputFilePath: String,\n"
           "        context: Context? = null\n")
# density + source dimensions block
s = cut_between(s, "        val density = context?.resources?.displayMetrics?.density ?: 1.0f\n",
                "        if (currentProject.operations.isEmpty()) {\n")
# op collection: drop nonMergeOps/videoOps/imageOps/prepareTextPngInputs
s = rep(s, "        val nonMergeOps = operations.filterNot { it is EditOperation.Merge }\n", "")
s = rep(s, "        val videoOps = nonMergeOps.filter { it is EditOperation.Crop || it is EditOperation.AddText || it is EditOperation.AddImageOverlay }\n"
           "        val imageOps = operations.filterIsInstance<EditOperation.AddImageOverlay>()\n"
           "        // Render text overlay PNGs before inputs are indexed\n"
           "        prepareTextPngInputs(operations)\n", "")
# input indexing: image overlays + text PNGs + canvas background image
s = cut_between_re(s, r"        // 4\. Image Overlay Inputs[^\n]*\n",
                   r"\n        // [^\n]*MERGE PATH")
# merge path: background/padding block -> plain black padding
s = cut_between_re(s, r"                // 2\. Apply background/padding\n",
                   r"                val isClipMuted = operations\.filterIsInstance<EditOperation\.MuteClip>\(\)\.find \{ it\.index == i \}\?\.isMuted \?: false\n")
s = rep(s, "                val isClipMuted = operations.filterIsInstance<EditOperation.MuteClip>().find { it.index == i }?.isMuted ?: false\n",
           "                // 2. Apply background/padding (solid black behind letterboxed clips)\n"
           "                filterParts.add(\"color=c=black:s=${mainWidth}x${mainHeight}:r=30[bg$i]\")\n"
           "                filterParts.add(\"[pre$i]scale=$mainWidth:$mainHeight:force_original_aspect_ratio=decrease[fg$i]\")\n"
           "                filterParts.add(\"[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2:shortest=1,setsar=1,fps=30,format=yuv420p[norm$i]\")\n"
           "\n"
           "                val isClipMuted = operations.filterIsInstance<EditOperation.MuteClip>().find { it.index == i }?.isMuted ?: false\n")
# merge path: buildVideoFilterStages call -> direct output scale
s = rep(s, "            val (sourceVideoStages, tempVideoLabel) = buildVideoFilterStages(\n"
           "                operations = videoOps,\n"
           "                fontFilePath = fontFilePath,\n"
           "                inputLabel = currentVideoLabel,\n"
           "                imageInputIndices = imageInputIndices,\n"
           "                textInputIndices = textInputIndices,\n"
           "                density = density,\n"
           "                sourceVideoHeight = sourceVideoHeight\n"
           "            )\n"
           "            filterParts.addAll(sourceVideoStages)\n"
           "            val finalVideoLabel = \"[fmtv]\"\n"
           "            filterParts.add(buildOutputScaleFilter(tempVideoLabel, finalVideoLabel))\n",
           "            val finalVideoLabel = \"[fmtv]\"\n"
           "            filterParts.add(buildOutputScaleFilter(currentVideoLabel, finalVideoLabel))\n")
# non-merge path: label + video filter stages call
s = cut_between_re(s, r"        var currentInputVideoLabel = \"\[0:v\]\"\n",
                   r"\n        // [^\n]*Audio filter stages")
# non-merge assembly: hasVideoFilters always false now
s = rep(s, "        val hasVideoFilters = videoStages.isNotEmpty()\n"
           "        val hasAudioFilters = finalAudioLabel != null\n"
           "\n"
           "        if (hasVideoFilters || hasAudioFilters) {\n"
           "            var mappedVideoLabel = finalVideoLabel\n"
           "            if (hasVideoFilters) {\n"
           "                val fmtLabel = \"[fmtv]\"\n"
           "                filterComplexParts.add(buildOutputScaleFilter(finalVideoLabel, fmtLabel))\n"
           "                mappedVideoLabel = fmtLabel\n"
           "            }\n"
           "            \n"
           "            if (_exportAudioOnly.value && hasVideoFilters) {\n"
           "                filterComplexParts.add(\"${mappedVideoLabel}nullsink\")\n"
           "            }\n"
           "            \n"
           "            cmd.append(\" -filter_complex \\\"${filterComplexParts.joinToString(\";\")}\\\"\")\n"
           "\n"
           "            if (!_exportAudioOnly.value) {\n"
           "                if (hasVideoFilters) {\n"
           "                    cmd.append(\" -map \\\"$mappedVideoLabel\\\"\")\n"
           "                } else {\n"
           "                    cmd.append(\" -map 0:v\")\n"
           "                }\n"
           "            }\n"
           "\n"
           "            if (effectiveAudioMuted) {\n"
           "                cmd.append(\" -an\")\n"
           "            } else if (hasAudioFilters) {\n"
           "                cmd.append(\" -map \\\"$finalAudioLabel\\\"\")\n"
           "            } else {\n"
           "                cmd.append(\" -map 0:a?\")\n"
           "            }\n"
           "        } else {\n",
           "        val hasAudioFilters = finalAudioLabel != null\n"
           "\n"
           "        if (hasAudioFilters) {\n"
           "            cmd.append(\" -filter_complex \\\"${filterComplexParts.joinToString(\";\")}\\\"\")\n"
           "\n"
           "            if (!_exportAudioOnly.value) {\n"
           "                cmd.append(\" -map 0:v\")\n"
           "            }\n"
           "\n"
           "            if (effectiveAudioMuted) {\n"
           "                cmd.append(\" -an\")\n"
           "            } else {\n"
           "                cmd.append(\" -map \\\"$finalAudioLabel\\\"\")\n"
           "            }\n"
           "        } else {\n")
# codec section: hasVideoFilters branch
s = rep(s, "            if (!hasVideoFilters) {\n"
           "                val vfArgs = buildOutputVfArgs()\n"
           "                cmd.append(\" ${buildVideoCodecArgs(defaultEncoder, vfArgs.isEmpty())}\")\n"
           "                if (vfArgs.isNotEmpty()) cmd.append(\" $vfArgs\")\n"
           "            } else {\n"
           "                cmd.append(\" ${buildVideoCodecArgs(defaultEncoder)}\")\n"
           "            }\n",
           "            val vfArgs = buildOutputVfArgs()\n"
           "            cmd.append(\" ${buildVideoCodecArgs(defaultEncoder, vfArgs.isEmpty())}\")\n"
           "            if (vfArgs.isNotEmpty()) cmd.append(\" $vfArgs\")\n")

# buildPreviewCommand (with doc)
s = cut_between(s, "    /**\n     * Build an FFmpeg command for a fast 3-second preview around the playhead.\n",
                "    private fun copyContentUriToTempFile(context: Context, uri: Uri): String? {\n")

wr(P, s)
print("[phase8] step4: [ok] VideoEditingViewModel.kt trimmed")
CUTPY

###############################################################################
# Step 5 -- VideoEditingViewModelExt.kt surgery
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def cut_between(s, a, b):
    i = s.find(a)
    if i < 0:
        die("cut_between start miss: %r" % a[:70])
    j = s.find(b, i + len(a))
    if j < 0:
        die("cut_between end miss: %r" % b[:70])
    return s[:i] + s[j:]

P = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"
s = rd(P)

if "addTextOperation" not in s:
    print("[phase8] step5: [skip] Ext already trimmed")
    sys.exit(0)

# import
s = s.replace("import com.tharunbirla.librecuts.models.TextPosition\n", "")
# addCropOperation + updateCanvasBackgroundOperation + addTextOperation (contiguous)
s = cut_between(s, "fun VideoEditingViewModel.addCropOperation(\n",
                "fun VideoEditingViewModel.updateMergeItemTrim(index: Int, startMs: Long, endMs: Long) {\n")
# addImageOverlayOperation
s = cut_between(s, "fun VideoEditingViewModel.addImageOverlayOperation(\n",
                "fun VideoEditingViewModel.addOperation(operation: EditOperation) {\n")
# moveOverlayOperation
s = cut_between(s, "fun VideoEditingViewModel.moveOverlayOperation(id: String, moveUp: Boolean) {\n",
                "fun VideoEditingViewModel.setScrubProxyUri(dependencyId: String, proxyUri: Uri) {\n")

wr(P, s)
print("[phase8] step5: [ok] VideoEditingViewModelExt.kt trimmed")
CUTPY

###############################################################################
# Step 6 -- FFmpegRenderEngine.kt surgery
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def cut_between(s, a, b):
    i = s.find(a)
    if i < 0:
        die("cut_between start miss: %r" % a[:70])
    j = s.find(b, i + len(a))
    if j < 0:
        die("cut_between end miss: %r" % b[:70])
    return s[:i] + s[j:]

def cut_between_re(s, a, b):
    ma = re.search(a, s)
    if not ma:
        die("cut_between_re start miss: %s" % a[:70])
    mb = re.compile(b).search(s, ma.end())
    if not mb:
        die("cut_between_re end miss: %s" % b[:70])
    return s[:ma.start()] + s[mb.start():]

P = "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"
s = rd(P)

if "copyFontToCache" not in s:
    print("[phase8] step6: [skip] Engine already trimmed")
    sys.exit(0)

# class doc: drop FONT NOTE section (comment contains non-ASCII dash -> regex)
s = cut_between_re(s, r" \*\n \* FONT NOTE:\n", r" \*/\n")
# init block: system font directory probing
s = cut_between_re(s,
    r"        // System fonts as a last-resort fallback[^\n]*\n"
    r"        // Always supply an explicit fontFilePath[^\n]*\n"
    r"        // Probe multiple vendor font directories[^\n]*\n"
    r"        val fontDir = listOf\(",
    r"        // Register a global log callback")
# font helper section (section comment + doc + copyFontToCache)
s = cut_between_re(s, r"    // [^\n]*Font helper[^\n]*\n", r"    // [^\n]*Core execution")
# renderCropPreview + renderTextPreview (with doc); section marker has non-ASCII dashes -> regex end
def cut_lit_re(s, a, b):
    i = s.find(a)
    if i < 0:
        die("cut_lit_re start miss: %r" % a[:70])
    mb = re.compile(b).search(s, i + len(a))
    if not mb:
        die("cut_lit_re end miss: %s" % b[:70])
    return s[:i] + s[mb.start():]
s = cut_lit_re(s, "    suspend fun renderCropPreview(\n", r"    // [^\n]*Full-quality operations")
# cropVideo + addTextOverlay (with doc)
s = cut_between(s, "    suspend fun cropVideo(\n",
                "    suspend fun addBackgroundAudio(\n")
# buildDrawtextFilter (with doc) + buildCropFilter
s = cut_between(s, "    /**\n     * Build a drawtext filter string.\n",
                "    /**\n     * Extract the output file path from an FFmpeg command.\n")
# misplaced extractOutputPath doc + generateVideoFromImage + generateVideoFromGif
s = cut_between(s, "    /**\n     * Extract the output file path from an FFmpeg command.\n",
                "    /**\n     * Resolve any URI to a plain file-system path that FFmpeg can read.\n")

wr(P, s)
print("[phase8] step6: [ok] FFmpegRenderEngine.kt trimmed")
CUTPY

###############################################################################
# Step 7 -- ProjectSerializer.kt surgery
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def rep(s, old, new, n=1):
    c = s.count(old)
    if c != n:
        die("rep count=%d expected=%d for: %r" % (c, n, old[:90]))
    return s.replace(old, new)

P = "app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt"
s = rd(P)

if '"AddText" -> EditOperation.AddText::class.java' not in s:
    print("[phase8] step7: [skip] Serializer already trimmed")
    sys.exit(0)

# valid classes
s = rep(s, 'val validClasses = setOf("Trim", "SpeedMain", "Crop", "AddText", "Merge", "MuteAudio", "Transition", "MuteClip", "AddBackgroundAudio", "AddImageOverlay", "CanvasBackground")\n',
           'val validClasses = setOf("Trim", "SpeedMain", "Merge", "MuteAudio", "Transition", "MuteClip", "AddBackgroundAudio")\n')
# drop the colorHex/blurRadius heuristic
s = rep(s, "                    if (jsonObject.has(\"durationMs\") && jsonObject.has(\"index\") && !jsonObject.has(\"items\")) {\n"
           "                        opTypeStr = \"Transition\"\n"
           "                    } else if (jsonObject.has(\"colorHex\") && jsonObject.has(\"blurRadius\")) {\n"
           "                        opTypeStr = \"CanvasBackground\"\n"
           "                    } else {\n"
           "                        opTypeStr = typeVal\n"
           "                    }\n",
           "                    if (jsonObject.has(\"durationMs\") && jsonObject.has(\"index\") && !jsonObject.has(\"items\")) {\n"
           "                        opTypeStr = \"Transition\"\n"
           "                    } else {\n"
           "                        opTypeStr = typeVal\n"
           "                    }\n")
# soften missing-type into graceful skip instead of throwing
s = rep(s, "            val type = opTypeStr ?: throw JsonParseException(\"Missing type property in EditOperation\")\n",
           "            val type = opTypeStr\n"
           "            if (type == null) {\n"
           "                android.util.Log.w(\"ProjectSerializer\", \"Skipping EditOperation with missing type property\")\n"
           "                return EditOperation.MuteAudio(\"skipped_unknown_null\")\n"
           "            }\n")
# drop CanvasBackground backgroundType remap
s = rep(s, "            } else if (type == \"CanvasBackground\") {\n"
           "                val t = jsonObject.get(\"type\")?.asString\n"
           "                if (t != null && t != \"CanvasBackground\") {\n"
           "                     jsonObject.addProperty(\"backgroundType\", t)\n"
           "                } else if (!jsonObject.has(\"backgroundType\")) {\n"
           "                     jsonObject.addProperty(\"backgroundType\", \"COLOR\")\n"
           "                }\n"
           "            }\n",
           "            }\n")
# class mapping branches
s = rep(s, '                "Crop" -> EditOperation.Crop::class.java\n', "")
s = rep(s, '                "AddText" -> EditOperation.AddText::class.java\n', "")
s = rep(s, '                "AddImageOverlay" -> EditOperation.AddImageOverlay::class.java\n', "")
s = rep(s, '                "CanvasBackground" -> EditOperation.CanvasBackground::class.java\n', "")
# JsonParseException import now unused
s = rep(s, "import com.google.gson.JsonParseException\n", "")

wr(P, s)
print("[phase8] step7: [ok] ProjectSerializer.kt trimmed")
CUTPY

###############################################################################
# Step 8 -- ProjectImportActivity.kt surgery
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def rep(s, old, new, n=1):
    c = s.count(old)
    if c != n:
        die("rep count=%d expected=%d for: %r" % (c, n, old[:90]))
    return s.replace(old, new)

def cut_between(s, a, b):
    i = s.find(a)
    if i < 0:
        die("cut_between start miss: %r" % a[:70])
    j = s.find(b, i + len(a))
    if j < 0:
        die("cut_between end miss: %r" % b[:70])
    return s[:i] + s[j:]

P = "app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt"
s = rd(P)

if "AddImageOverlay" not in s:
    print("[phase8] step8: [skip] ProjectImportActivity already trimmed")
    sys.exit(0)

# dependency scan branch
s = cut_between(s, "                is EditOperation.AddImageOverlay -> {\n",
                "                else -> {}\n")
# remap branch
s = rep(s, "                    is EditOperation.AddImageOverlay -> {\n"
           "                        val dep = dependencies.find { it.operationId == op.id }\n"
           "                        if (dep != null && dep.currentUri != null) op.copy(imageUri = dep.currentUri!!) else op\n"
           "                    }\n", "")

wr(P, s)
print("[phase8] step8: [ok] ProjectImportActivity.kt trimmed")
CUTPY

###############################################################################
# Step 9 -- ExportSettingsDialog.kt: drop fontPath plumbing
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

def rep(s, old, new, n=1):
    c = s.count(old)
    if c != n:
        die("rep count=%d expected=%d for: %r" % (c, n, old[:90]))
    return s.replace(old, new)

P = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
s = rd(P)

if "fontPath" not in s:
    print("[phase8] step9: [skip] ExportSettingsDialog already trimmed")
    sys.exit(0)

s = rep(s, "    private val fontPath: String?,\n", "")
s = rep(s, "            viewModel.buildConsolidatedFFmpegCommand(srcPath, previewPath, fontPath, activity)\n",
           "            viewModel.buildConsolidatedFFmpegCommand(srcPath, previewPath, activity)\n")

wr(P, s)
print("[phase8] step9: [ok] ExportSettingsDialog.kt trimmed")
CUTPY

###############################################################################
# Step 10 -- activity_video_editing.xml surgery
###############################################################################
python3 <<'CUTPY'
import re, sys

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

P = "app/src/main/res/layout/activity_video_editing.xml"
with open(P, encoding="utf-8") as f:
    s = f.read()

if 'android:id="@+id/btnText"' not in s:
    print("[phase8] step10: [skip] layout already trimmed")
    sys.exit(0)

def elem_bounds(s, id_attr):
    m = re.search(r'android:id="@\+id/%s"' % re.escape(id_attr), s)
    if not m:
        die("xml id miss: " + id_attr)
    i = s.rfind("<", 0, m.start())
    tag = re.compile(r"<([A-Za-z][A-Za-z0-9._]*)").match(s, i).group(1)
    depth = 0
    end = -1
    for mt in re.compile(r"<%s(?:\s[^<>]*)?/?>|</%s\s*>" % (re.escape(tag), re.escape(tag))).finditer(s, i):
        tok = mt.group(0)
        if tok.startswith("</"):
            depth -= 1
            if depth == 0:
                end = mt.end()
                break
        elif tok.endswith("/>"):
            if depth == 0:
                end = mt.end()
                break
        else:
            depth += 1
    if end < 0:
        die("xml walk fail: " + id_attr)
    return i, end

def swallow_comment(s, i):
    before = s[:i]
    stripped = before.rstrip()
    if not stripped.endswith("-->"):
        return i
    cstart = before.rfind("<!--")
    if cstart < 0:
        return i
    between = before[before.find("-->", cstart) + 3:i]
    if between.strip() != "":
        return i
    return cstart

def cut_elem(s, id_attr):
    i, end = elem_bounds(s, id_attr)
    i = swallow_comment(s, i)
    if s[end:end + 1] == "\n":
        end += 1
    if s[:i].endswith("\n\n") and s[end:end + 1] == "\n":
        end += 1
    return s[:i] + s[end:]

def wrapper_start(s, id_attr):
    m = re.search(r'android:id="@\+id/%s"' % re.escape(id_attr), s)
    if not m:
        die("wrapper id miss: " + id_attr)
    return s.rfind("<LinearLayout", 0, m.start())

for eid in [
    "bgPreviewImageView",
    "btnPreview",
    "textOverlayView",
    "draggableTextOverlay",
    "imageOverlayView",
    "draggableImageOverlay",
    "cropOverlayView",
    "tvPreviewBadge",
    "btnMoveLayerUp",
    "btnMoveLayerDown",
    "textTrackContainer",
    "imageTrackContainer",
    "keyframeTrackContainer",
    "textEditingToolbar",
    "imageEditingToolbar",
    "cropEditingToolbar",
    "backgroundEditingToolbar",
    "keyframeEditingToolbar",
    "previewLoadingOverlay",
]:
    s = cut_elem(s, eid)

# tool row: remove btnText + btnMediaOverlay wrappers (up to btnAudio wrapper)
i = wrapper_start(s, "btnText")
j = wrapper_start(s, "btnAudio")
if i < 0 or j < 0 or i >= j:
    die("tool row span A failed")
s = s[:i] + s[j:]

# tool row: remove btnCrop + btnCanvasBackground wrappers (up to wrapper close)
i = wrapper_start(s, "btnCrop")
j = s.find("            </LinearLayout>\n        </HorizontalScrollView>")
if i < 0 or j < 0 or i >= j:
    die("tool row span B failed")
s = s[:i] + s[j:]

# validate XML + normalize blank-line runs created by the cuts
s = re.sub(r"\n{4,}", "\n\n\n", s)
import xml.dom.minidom as md
md.parseString(s)

with open(P, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase8] step10: [ok] activity_video_editing.xml trimmed")
CUTPY

###############################################################################
# Step 11 -- strings sweep (all locales)
###############################################################################
python3 <<'CUTPY'
import re, sys, glob

def die(m):
    print("[phase8][ERROR] " + m)
    sys.exit(1)

KEYS = [
    "str_text", "str_overlay", "str_crop", "str_crop_aspect_ratio",
    "toast_failed_to_load_overlay_file",
    "str_0_1", "str_16_9", "str_1_1", "str_9_16", "str_color",
    "str_color_filters",
    "str_custom", "str_duplicate", "str_keyboard", "str_loop", "str_opacity",
]

import xml.dom.minidom as md
touched = 0
for f in sorted(glob.glob("app/src/main/res/values*/strings.xml")):
    with open(f, encoding="utf-8") as fh:
        s = fh.read()
    orig = s
    for k in KEYS:
        s = re.sub(r'[ \t]*<string name="%s">[^<]*</string>\n' % k, "", s)
    if s != orig:
        try:
            md.parseString(s)
        except Exception as e:
            die("strings XML invalid after sweep: %s (%s)" % (f, e))
        with open(f, "w", encoding="utf-8") as fh:
            fh.write(s)
        touched += 1
print("[phase8] step11: [ok] strings swept in %d locale files" % touched)
CUTPY

###############################################################################
# Step 12 -- hard verification gate (exits 1 BEFORE anything gets committed)
###############################################################################
log "step12: verification gate"

python3 <<'CUTPY'
import re, subprocess, sys

def die(m):
    print("[phase8][GATE-FAIL] " + m)
    sys.exit(1)

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def head(p):
    return subprocess.run(["git", "show", "HEAD:" + p],
                          capture_output=True, text=True).stdout

def fun_names(src):
    names = set()
    for m in re.finditer(r"\bfun\s+([A-Za-z0-9_]+)\s*\(", src):
        names.add(m.group(1))
    for m in re.finditer(r"\bfun\s+[A-Za-z0-9_.]+\.([A-Za-z0-9_]+)\s*\(", src):
        names.add(m.group(1))
    return names

def check_inventory(path, expected_removed):
    old = fun_names(head(path))
    new = fun_names(rd(path))
    removed = old - new
    added = new - old
    exp = set(expected_removed)
    if removed == exp and not added:
        return
    if not removed and not added:
        return  # already committed at HEAD (RUN 3)
    die("function inventory mismatch for %s:\n  unexpected removals: %s\n  unexpected additions: %s\n  missing removals: %s"
        % (path, sorted(removed - exp), sorted(added), sorted(exp - removed)))

VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
VM = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
EXT = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"
ENGINE = "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"

check_inventory(VEA, [
    "setupTextFontSelector", "showFontManagerBottomSheet", "updateLayerReorderButtons",
    "applyCropPreview", "resetCropPreview", "cropAction", "canvasBackgroundAction",
    "enterCanvasBackgroundEditingMode", "exitCanvasBackgroundEditingMode",
    "textAction", "enterTextEditingMode", "exitTextEditingMode",
    "duplicateSelectedOverlay", "pickBackgroundImage", "mediaOverlayAction",
    "openImagePicker", "showImageOverlayConfig", "getExtensionFromUri",
    "getOverlayFileDurationMs", "enterImageEditingMode", "enterImageEditingModeForEdit",
    "exitImageEditingMode", "getPresetCropBounds", "enterCropEditingMode",
    "exitCropEditingMode", "updateCanvasBackgroundPreview", "updateCropUi",
    "triggerCanvasLayoutUpdate", "renderSegmentedPreview", "dismissPreview",
    "markPaletteSelection", "buildTextPaletteRow", "setupColorPicker",
    "setupBgColorPicker", "setupStrokeColorPicker", "setupShadowColorPicker",
    "updateActiveBoundaries", "showChromaKeyDialog", "showCustomColorPicker",
    "commitActiveEditsIfAny", "enterKeyframeEditingMode", "exitKeyframeEditingMode",
    "showKeyframePropertyMenu", "handleKeyframeActionClick", "handleKeyframeSliderChange",
    "updateKeyframeActionButtonState", "updateDraggableOverlayFromKeyframes",
    "interpolateKeyframes", "interpolateKeyframePosition",
    # local/nested functions inside removed regions
    "refreshFontList", "onCreateViewHolder", "onBindViewHolder", "getItemCount",
    "resetTabs", "styleTint", "syncStyleButtons", "syncBgSliders",
    "syncStrokeSliders", "syncShadowSliders", "updatePreview",
])

check_inventory(VM, [
    "buildCropFilterExpr", "prepareTextPngInputs", "overlayPosExpr",
    "buildDrawtextExpr", "buildFFmpegInterpolationExpr", "formatColorForFFmpeg",
    "buildEnableExpr", "buildVideoFilterStages", "buildPreviewCommand",
])

check_inventory(EXT, [
    "addCropOperation", "updateCanvasBackgroundOperation", "addTextOperation",
    "addImageOverlayOperation", "moveOverlayOperation",
])

check_inventory(ENGINE, [
    "copyFontToCache", "renderCropPreview", "renderTextPreview", "cropVideo",
    "addTextOverlay", "buildDrawtextFilter", "buildCropFilter",
    "generateVideoFromImage", "generateVideoFromGif",
])

# ---- brace delta vs HEAD must match (removed code is brace-balanced) ----
for p in [VEA, VM, EXT, ENGINE,
          "app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt",
          "app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt",
          "app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt",
          "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"]:
    old = head(p)
    new = rd(p)
    do = old.count("{") - new.count("{")
    dc = old.count("}") - new.count("}")
    if do != dc:
        die("brace delta mismatch for %s (open removed %d, close removed %d)"
            % (p, do, dc))
    if old.count("{") == old.count("}") and new.count("{") != new.count("}"):
        die("unbalanced braces in %s (open %d, close %d)"
            % (p, new.count("{"), new.count("}")))

print("[phase8] gate: inventory + brace checks passed")
CUTPY

# ---- leftover token scan across app/src/main ----
LEFT_TOKENS="AddText AddImageOverlay CanvasBackground KeyframePoint TextPosition \
textOverlayView imageOverlayView draggableTextOverlay draggableImageOverlay cropOverlayView \
bgPreviewImageView textEditingToolbar imageEditingToolbar cropEditingToolbar \
backgroundEditingToolbar keyframeEditingToolbar btnText btnMediaOverlay btnCrop \
btnCanvasBackground btnMoveLayerUp btnMoveLayerDown btnPreview tvPreviewBadge \
previewLoadingOverlay textTrackContainer imageTrackContainer keyframeTrackContainer \
pickBackgroundImage mediaOverlayAction textAction cropAction canvasBackgroundAction \
showChromaKeyDialog showCustomColorPicker HSVColorPickerView TextRenderUtils \
FontManager FontItem fontFilePath fontPath fontfile copyFontToCache fontDir drawtext \
buildVideoFilterStages buildPreviewCommand textPngRenderer prepareTextPngInputs \
buildDrawtextExpr overlayPosExpr buildFFmpegInterpolationExpr buildCropFilterExpr \
formatColorForFFmpeg buildEnableExpr moveOverlayOperation addTextOperation \
addImageOverlayOperation updateCanvasBackgroundOperation updateCanvasBackgroundPreview \
updateLayerReorderButtons duplicateSelectedOverlay enterKeyframeEditingMode \
isKeyframeEditingMode updateDraggableOverlayFromKeyframes interpolateKeyframe \
renderSegmentedPreview dismissPreview isShowingPreview isRenderingPreview previewJob \
commitActiveEditsIfAny buildTextPaletteRow markPaletteSelection setupColorPicker \
textPalettePresets selectedTextColor importFontLauncher activeFontSelectionCallback \
showFontManagerBottomSheet setupTextFontSelector getExtensionFromUri \
getOverlayFileDurationMs openImagePicker showImageOverlayConfig enterImageEditingMode \
exitImageEditingMode PICK_IMAGE_REQUEST PICK_BACKGROUND_IMAGE_REQUEST \
updateActiveBoundaries triggerCanvasLayoutUpdate generateVideoFromImage \
generateVideoFromGif chroma ic_text_24 ic_canvas_24 ic_crop_24 ic_keyframe \
ic_palette_24 ic_mirror ic_preview_24 ic_loop_24 ic_opacity_24 str_text str_overlay \
str_crop str_16_9 str_9_16 str_1_1 str_0_1 str_color str_custom str_duplicate \
str_keyboard str_loop str_opacity toast_failed_to_load_overlay_file"

for t in $LEFT_TOKENS; do
    if grep -rIqE -- "$t\\b" app/src/main 2>/dev/null; then
        HIT=$(grep -rIlE -- "$t\\b" app/src/main 2>/dev/null | head -3 | tr '\n' ' ')
        fail "leftover token '$t' still present in: $HIT"
    fi
done
log "gate: leftover scan clean"

# ---- kept-feature survival asserts ----
SURVIVE_VEA="fun audioAction( fun enterAudioEditingMode( fun exitAudioEditingMode( \
fun showTransitionDialog( fun performRenderTracks( fun freezeFrameAtCurrentPosition( \
fun findTextureView( fun getSnapTargetsMs( fun showVideoSegmentTrimDialog( \
fun splitSelectedVideo( fun applySpeedToSegment( fun enterVideoEditingMode( \
fun reparentCanvasContainer( fun setActiveToolButton( fun closeActiveEditingModes( \
fun updateUIInteractionState( fun renderTracks( fun syncUiWithPlayer( \
R.id.btnAudio R.id.editingControlsScroll"
for t in $SURVIVE_VEA; do
    grep -q -- "$t" "$VEA" || fail "survival check failed in VEA: $t"
done
grep -q "findTextureView(playerView)" "$VEA" || fail "findTextureView transition-preview call lost"
grep -q "AddBackgroundAudio" "$VEA" || fail "AddBackgroundAudio usage lost in VEA"
grep -q "data class Trim(" "app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt" || fail "Trim model lost"
grep -q "data class Merge(" "app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt" || fail "Merge model lost"
grep -q "data class AddBackgroundAudio(" "app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt" || fail "AddBackgroundAudio model lost"
grep -q "fun buildConsolidatedFFmpegCommand(" "$VM" || fail "buildConsolidatedFFmpegCommand lost"
grep -q "fun VideoEditingViewModel.addBackgroundAudioOperation(" "$EXT" || fail "addBackgroundAudioOperation lost"
grep -q "fun VideoEditingViewModel.splitVideoSegment(" "$EXT" || fail "splitVideoSegment lost"
grep -q "AddBackgroundAudio" "app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt" || fail "serializer audio mapping lost"
grep -q "str_audio" "app/src/main/res/values/strings.xml" || fail "str_audio string lost"
grep -q 'android:id="@+id/btnAudio"' "$AVEXML" || fail "btnAudio button lost from layout"
grep -q 'android:id="@+id/audioTrackContainer"' "$AVEXML" || fail "audioTrackContainer lost from layout"
grep -q 'android:id="@+id/videoEditingToolbar"' "$AVEXML" || fail "videoEditingToolbar include lost"
log "gate: survival checks passed"

# ---- XML validity of all touched resources ----
python3 - <<'CUTPY'
import glob, sys
import xml.dom.minidom as md
files = ["app/src/main/res/layout/activity_video_editing.xml"] + \
        sorted(glob.glob("app/src/main/res/values*/strings.xml"))
for f in files:
    with open(f, "rb") as fh:
        md.parseString(fh.read())
print("[phase8] gate: XML parse ok for %d files" % len(files))
CUTPY

# ---- scope gate: only allowlisted files changed ----
python3 - <<'CUTPY'
import subprocess, sys

ALLOWED = set()

def add(p):
    ALLOWED.add(p)

cv = "app/src/main/java/com/tharunbirla/librecuts/customviews"
ut = "app/src/main/java/com/tharunbirla/librecuts/utils"
lay = "app/src/main/res/layout"
drw = "app/src/main/res/drawable"
for p in [
    "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt",
    "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt",
    "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt",
    "app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt",
    "app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt",
    "app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt",
    "app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt",
    "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt",
    "app/src/main/res/layout/activity_video_editing.xml",
    cv + "/TextOverlayView.kt", cv + "/DraggableTextOverlayView.kt",
    cv + "/ImageOverlayView.kt", cv + "/DraggableImageOverlayView.kt",
    cv + "/CropOverlayView.kt", cv + "/HSVColorPickerView.kt",
    ut + "/TextRenderUtils.kt", ut + "/FontManager.kt",
    lay + "/text_editing_toolbar.xml", lay + "/text_background_settings.xml",
    lay + "/text_format_settings.xml", lay + "/text_shadow_settings.xml",
    lay + "/text_stroke_settings.xml", lay + "/image_editing_toolbar.xml",
    lay + "/crop_editing_toolbar.xml", lay + "/background_editing_toolbar.xml",
    lay + "/keyframe_editing_toolbar.xml", lay + "/chroma_key_bottom_sheet_dialog.xml",
    lay + "/dialog_custom_color_picker.xml", lay + "/dialog_font_manager.xml",
    lay + "/item_font_manager.xml",
    "app/src/main/assets/fonts/Roboto-Regular.ttf",
    drw + "/ic_canvas_24.xml", drw + "/ic_canvas_color_24.xml",
    drw + "/ic_color_lens_24.xml", drw + "/ic_color_picker_24.xml",
    drw + "/ic_crop_24.xml", drw + "/ic_crop_16_9_24.xml",
    drw + "/ic_crop_portrait_24.xml", drw + "/ic_crop_square_24.xml",
    drw + "/ic_format_24.xml", drw + "/ic_keyboard_24.xml",
    drw + "/ic_keyframe_add.xml", drw + "/ic_keyframe_main.xml",
    drw + "/ic_keyframe_remove.xml", drw + "/ic_loop_24.xml",
    drw + "/ic_mirror.xml", drw + "/ic_opacity_24.xml",
    drw + "/ic_palette_24.xml", drw + "/ic_preview_24.xml",
    drw + "/ic_rotate_right_24.xml", drw + "/ic_arrow_drop_down_24.xml",
    drw + "/ic_text_24.xml", drw + "/ic_text_bg_24.xml",
    drw + "/ic_text_shadow_24.xml", drw + "/ic_text_stroke_24.xml",
    drw + "/ic_align_center_24.xml", drw + "/ic_align_left_24.xml",
    drw + "/ic_align_right_24.xml", drw + "/bg_layer_selected.xml",
]:
    add(p)
import glob
for f in glob.glob("app/src/main/res/values*/strings.xml"):
    add(f)

out = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True).stdout
bad = []
gh = []
for line in out.splitlines():
    path = line[3:].strip().strip('"')
    if path.startswith(".github/"):
        gh.append(path)
    if path not in ALLOWED:
        bad.append(path)
if gh:
    print("[phase8][GATE-FAIL] .github policy violation: %s" % gh)
    sys.exit(1)
if bad:
    print("[phase8][GATE-FAIL] out-of-scope changes: %s" % bad)
    sys.exit(1)
print("[phase8] gate: scope ok (all changed files allowlisted, no .github/)")
CUTPY

# ---- ASCII self-check of this script ----
if LC_ALL=C tr -d '\t' < "$0" | LC_ALL=C grep -nq '[^ -~]'; then
    fail "script contains non-ASCII characters"
fi
log "gate: ASCII self-check passed"

log "ALL DONE -- phase 8 applied and verified"
