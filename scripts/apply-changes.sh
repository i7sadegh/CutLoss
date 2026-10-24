#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 8 -- remove two more main-toolbar features entirely:
#    1. Crop   (aspect-ratio + custom crop box, preview scaling)
#    2. Canvas (canvas background: color / blur / image padding)
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  Scope of the removal (all of the code, per the no-.lcprj-compat policy):
#    - activity_video_editing.xml : cropOverlayView element,
#                                  cropEditingToolbar + backgroundEditingToolbar
#                                  includes, btnCrop + btnCanvasBackground
#                                  tool blocks, bgPreviewImageView (canvas
#                                  container gets the black backdrop instead)
#    - VideoEditingActivity.kt   : fields, try-block wirings, crop/canvas
#                                  actions + editing modes, applyCropPreview,
#                                  resetCropPreview (renamed fitCanvasToVideo),
#                                  getPresetCropBounds, updateCropUi,
#                                  updateCanvasBackgroundPreview,
#                                  pickBackgroundImage + its request code +
#                                  onActivityResult branch, blur-index block,
#                                  preview gating, tool id list
#    - VideoEditingViewModelExt  : addCropOperation /
#                                  updateCanvasBackgroundOperation
#    - VideoEditingViewModel.kt  : buildCropFilterExpr, crop stage in
#                                  buildVideoFilterStages, Crop in videoOps
#                                  filters + preview gating, canvas background
#                                  image input, merge-path BLUR/IMAGE padding
#                                  (kept: black color pad for concat/xfade)
#    - EditOperation.kt          : Crop + CanvasBackground data classes and
#                                  their id mappings
#    - ProjectSerializer.kt      : Crop + CanvasBackground type mappings and
#                                  the CanvasBackground heuristic
#    - services/FFmpegRenderEngine.kt : renderCropPreview + cropVideo +
#                                  buildCropFilter
#    - customviews               : CropOverlayView deleted
#    - layouts deleted           : crop_editing_toolbar,
#                                  background_editing_toolbar
#    - drawables deleted         : ic_crop_24, ic_crop_16_9_24,
#                                  ic_crop_portrait_24, ic_crop_square_24,
#                                  ic_canvas_24, ic_canvas_color_24,
#                                  aspect_ratio_background(.+_selected) (dead)
#    - strings (all locales)     : str_crop, str_crop_aspect_ratio,
#                                  str_16_9, str_9_16, str_1_1, str_custom
#  Kept on purpose (shared / other features):
#    canvasContainer + fitCanvasToVideo (overlay alignment, fullscreen /
#    PiP reparenting), black pad in the merge path (concat/xfade needs
#    uniform frame sizes), bg_aspect_ratio_item/_selected (audio +
#    transition toolbars), ic_opacity_24 / ic_image_24 / ic_close_24 /
#    ic_check_24 (shared icons), showCustomColorPicker (text palette),
#    copyContentUriToTempFile (merge/audio/images), text background
#    settings (btnTextBackgroundTab family), circlecrop/rectcrop xfade
#    transition names + their preview webps.
#
#  Verification gate (fails BEFORE the workflow commits anything):
#    leftover scan, kept-feature survival asserts, function-inventory
#    guard vs git HEAD, brace balance, XML parse, scope gate,
#    .github/ policy, ASCII self-check.
#
#  Idempotent: every step checks its own post-state first.
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
EXT="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
EO="app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt"
PS="app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt"
FRE="app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"
AVEM="app/src/main/res/layout/activity_video_editing.xml"
SELF="scripts/apply-changes.sh"
FAILED=0

# ---------------------------------------------------------------------------
#  STEP 0 -- preconditions
# ---------------------------------------------------------------------------
step0_preconditions() {
    echo "== step 0: preconditions"
    local ok=1 f
    for f in "$VEA" "$EXT" "$VM" "$EO" "$PS" "$FRE" "$AVEM"; do
        if [ ! -f "$f" ]; then
            echo " [FAIL] missing file: $f"
            ok=0
        fi
    done
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo " [FAIL] not inside a git repository"
        ok=0
    fi
    # phase-7 must already be applied (the six toolbar features gone)
    if grep -q 'btnVideoReverse' app/src/main/res/layout/video_editing_toolbar.xml 2>/dev/null; then
        echo " [FAIL] phase-7 markers still present (btnVideoReverse) -- wrong base"
        ok=0
    else
        echo " [ok] phase-7 base detected (six toolbar features already gone)"
    fi
    # phase-6 marker must still be present
    if grep -q 'android:layout_height="200dp"' "$AVEM" 2>/dev/null; then
        echo " [ok] phase-6 marker detected (timeline 200dp)"
    else
        echo " [FAIL] phase-6 marker (timeline 200dp) missing -- wrong base"
        ok=0
    fi
    # phase-8 targets: present (fresh base) or already clean (re-run)
    if grep -q 'btnCrop' "$AVEM" 2>/dev/null; then
        echo " [ok] crop + canvas targets still present (fresh phase-8 base)"
    else
        echo " [skip-check] crop + canvas targets already clean (phase-8 re-run)"
    fi
    [ "$ok" -eq 1 ] && echo " [ok] repo state matches the expected phase-7 base"
    [ "$ok" -eq 1 ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 1 -- activity_video_editing.xml: remove crop/canvas views + buttons
# ---------------------------------------------------------------------------
step1_layout() {
    echo "== step 1: strip crop/canvas views from the main layout"
    python3 - <<'CUTPY'
import sys
import xml.dom.minidom as md

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

def repl(t, old, new, cnt=1, name=''):
    c = t.count(old)
    if c == cnt:
        return t.replace(old, new), True
    if c == 0 and (new in t or new == ''):
        return t, False
    fail('%s: expected %d, found %d' % (name or old[:60].replace('\n', '|'), cnt, c))

p = 'app/src/main/res/layout/activity_video_editing.xml'
t = open(p, encoding='utf-8').read()
n = 0

# 1a. canvasContainer gets the black backdrop; bgPreviewImageView goes away
t, ch = repl(t, """            <FrameLayout
                android:id="@+id/canvasContainer"
                android:layout_width="match_parent"
                android:layout_height="match_parent"
                android:layout_gravity="center">

                <ImageView
                    android:id="@+id/bgPreviewImageView"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent"
                    android:scaleType="centerCrop"
                    android:background="@color/cinemaBlack" />

""", """            <FrameLayout
                android:id="@+id/canvasContainer"
                android:layout_width="match_parent"
                android:layout_height="match_parent"
                android:layout_gravity="center"
                android:background="@color/cinemaBlack">

""", 1, 'canvasContainer + bgPreviewImageView')
n += ch

# 1b. CropOverlayView element
t, ch = repl(t, """            <com.tharunbirla.librecuts.customviews.CropOverlayView
                android:id="@+id/cropOverlayView"
                android:layout_width="match_parent"
                android:layout_height="match_parent"
                android:visibility="gone" />

""", '', 1, 'cropOverlayView element')
n += ch

# 1c. cropEditingToolbar include
t, ch = repl(t, """        <!-- Crop Editing Toolbar (inline mode, hidden by default) -->
        <include
            android:id="@+id/cropEditingToolbar"
            layout="@layout/crop_editing_toolbar"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="8dp"
            android:visibility="gone" />

""", '', 1, 'cropEditingToolbar include')
n += ch

# 1d. backgroundEditingToolbar include
t, ch = repl(t, """        <!-- Background Editing Toolbar (inline mode, hidden by default) -->
        <include
            android:id="@+id/backgroundEditingToolbar"
            layout="@layout/background_editing_toolbar"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="8dp"
            android:visibility="gone" />

""", '', 1, 'backgroundEditingToolbar include')
n += ch

# 1e. btnCrop + btnCanvasBackground tool blocks
t, ch = repl(t, """
                <LinearLayout
                    android:layout_width="60dp"
                    android:layout_height="wrap_content"
                    android:orientation="vertical"
                    android:gravity="center">
                    <ImageButton
                        android:id="@+id/btnCrop"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:background="@drawable/tool_button_inactive"
                        android:src="@drawable/ic_crop_24"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        app:tint="@color/toolTextInactive" />
                    <TextView
                        android:layout_width="wrap_content"
                        android:layout_height="wrap_content"
                        android:layout_marginTop="4dp"
                        android:text="@string/str_crop"
                        android:textSize="11sp"
                        android:fontFamily="sans-serif-medium"
                        android:textColor="@color/toolTextInactive"/>
                </LinearLayout>

                <LinearLayout
                    android:layout_width="60dp"
                    android:layout_height="wrap_content"
                    android:orientation="vertical"
                    android:gravity="center">
                    <ImageButton
                        android:id="@+id/btnCanvasBackground"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:background="@drawable/tool_button_inactive"
                        android:src="@drawable/ic_canvas_24"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        app:tint="@color/toolTextInactive" />
                    <TextView
                        android:layout_width="wrap_content"
                        android:layout_height="wrap_content"
                        android:layout_marginTop="4dp"
                        android:text="Canvas"
                        android:textSize="11sp"
                        android:fontFamily="sans-serif-medium"
                        android:textColor="@color/toolTextInactive"/>
                </LinearLayout>
""", "\n", 1, 'btnCrop + btnCanvasBackground blocks')
n += ch

md.parseString(t)
open(p, 'w', encoding='utf-8').write(t)
print('   [ok] activity_video_editing.xml: %d block(s) removed/reworked' % n)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 2 -- delete dead files (view, toolbars, icons)
# ---------------------------------------------------------------------------
step2_delete_files() {
    echo "== step 2: delete crop/canvas files"
    local n=0 f
    for f in \
        app/src/main/java/com/tharunbirla/librecuts/customviews/CropOverlayView.kt \
        app/src/main/res/layout/crop_editing_toolbar.xml \
        app/src/main/res/layout/background_editing_toolbar.xml \
        app/src/main/res/drawable/ic_crop_24.xml \
        app/src/main/res/drawable/ic_crop_16_9_24.xml \
        app/src/main/res/drawable/ic_crop_portrait_24.xml \
        app/src/main/res/drawable/ic_crop_square_24.xml \
        app/src/main/res/drawable/ic_canvas_24.xml \
        app/src/main/res/drawable/ic_canvas_color_24.xml \
        app/src/main/res/drawable/aspect_ratio_background.xml \
        app/src/main/res/drawable/aspect_ratio_background_selected.xml \
    ; do
        if [ -f "$f" ]; then
            git rm -q -- "$f" 2>/dev/null || rm -f -- "$f"
            echo " [ok] deleted $f"
            n=$((n + 1))
        fi
    done
    if [ "$n" -eq 0 ]; then
        echo " [skip] all crop/canvas files already absent"
    fi
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 3 -- EditOperation.kt: drop the Crop + CanvasBackground models
# ---------------------------------------------------------------------------
step3_models() {
    echo "== step 3: EditOperation.kt -- remove Crop + CanvasBackground"
    python3 - <<'CUTPY'
import re, sys

P = 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt'
t = open(P, encoding='utf-8').read()
n = 0

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

def cut_class(doc_first_line, cls_sig):
    """Remove a doc comment + data class block, brace-walked from cls_sig."""
    global t, n
    if cls_sig not in t:
        return False
    i = t.find(cls_sig)
    # strip the preceding /** ... */ comment block if directly attached
    head = t[:i]
    if head.endswith('    /**\n' + doc_first_line + '\n'):
        j = head.rfind('    /**\n' + doc_first_line)
    else:
        j = i
    # brace-walk the class body
    k = t.find('{', i)
    depth, k = 1, k + 1
    while depth > 0 and k < len(t):
        if t[k] == '{':
            depth += 1
        elif t[k] == '}':
            depth -= 1
        k += 1
    if depth != 0:
        fail('unbalanced class body for ' + cls_sig)
    # eat one trailing newline
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:j] + t[k:]
    n += 1
    return True

# 3a. Crop data class (doc comment + class + init block)
cut_class('     * Crop operation: Crops video to a specified aspect ratio.',
          '    data class Crop(\n')

# 3b. CanvasBackground data class (doc comment + class + nested enum)
cut_class('     * Canvas background operation: Sets the padding style for clips that do not match the primary aspect ratio.',
          '    data class CanvasBackground(\n')

# 3c. id mappings
def repl(old, new, cnt=1, name=''):
    global t, n
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        n += 1
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('%s: expected %d, found %d' % (name or old[:60], cnt, c))

repl('        is EditOperation.Crop -> id\n', '', 1, 'Crop id mapping')
repl('        is EditOperation.CanvasBackground -> id\n', '', 1, 'CanvasBackground id mapping')

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] EditOperation.kt: %d removal(s)' % n)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 4 -- ProjectSerializer.kt: drop the dead type mappings
# ---------------------------------------------------------------------------
step4_serializer() {
    echo "== step 4: ProjectSerializer.kt -- remove Crop/CanvasBackground mappings"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt'
t = open(P, encoding='utf-8').read()
n = 0

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

def repl(old, new, cnt=1, name=''):
    global t, n
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        n += 1
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('%s: expected %d, found %d' % (name or old[:60], cnt, c))

# 4a. validClasses set entries
repl('"Crop", "AddText"', '"AddText"', 1, 'validClasses Crop entry')
repl('"AddImageOverlay", "CanvasBackground")', '"AddImageOverlay")', 1, 'validClasses CanvasBackground entry')

# 4b. CanvasBackground deserialization heuristic
repl("""                    } else if (jsonObject.has("colorHex") && jsonObject.has("blurRadius")) {
                        opTypeStr = "CanvasBackground"
                    } else {
""", """                    } else {
""", 1, 'CanvasBackground heuristic')

# 4c. CanvasBackground type-normalization block
repl("""            } else if (type == "CanvasBackground") {
                val t = jsonObject.get("type")?.asString
                if (t != null && t != "CanvasBackground") {
                     jsonObject.addProperty("backgroundType", t)
                } else if (!jsonObject.has("backgroundType")) {
                     jsonObject.addProperty("backgroundType", "COLOR")
                }
            }
""", """            }
""", 1, 'CanvasBackground normalize block')

# 4d. class mappings
repl('                "Crop" -> EditOperation.Crop::class.java\n', '', 1, 'Crop class mapping')
repl('                "CanvasBackground" -> EditOperation.CanvasBackground::class.java\n', '', 1, 'CanvasBackground class mapping')

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] ProjectSerializer.kt: %d removal(s)' % n)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 5 -- VideoEditingViewModelExt.kt: drop the two mutators
# ---------------------------------------------------------------------------
step5_ext() {
    echo "== step 5: VideoEditingViewModelExt.kt -- remove crop/canvas mutators"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt'
t = open(P, encoding='utf-8').read()

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

old = """fun VideoEditingViewModel.addCropOperation(
    aspectRatio: String, xFraction: Float = 0f, yFraction: Float = 0f,
    wFraction: Float = 1f, hFraction: Float = 1f
) {
    executeCommand(ReplaceUniqueOperationCommand(
        EditOperation.Crop(aspectRatio, xFraction, yFraction, wFraction, hFraction),
        "Crop Video"
    ))
}

fun VideoEditingViewModel.updateCanvasBackgroundOperation(
    type: EditOperation.CanvasBackground.BackgroundType, colorHex: String = "#000000",
    imageUri: Uri? = null, blurRadius: Int = 20
) {
    executeCommand(ReplaceUniqueOperationCommand(
        EditOperation.CanvasBackground(type, colorHex, imageUri, blurRadius),
        "Set Canvas Background"
    ))
}

"""
c = t.count(old)
if c == 1:
    t = t.replace(old, '')
    print('   [ok] both mutators removed')
elif c == 0 and 'addCropOperation' not in t and 'updateCanvasBackgroundOperation' not in t:
    print('   [skip] mutators already absent')
else:
    fail('unexpected state: addCropOperation/updateCanvasBackgroundOperation block mismatch (count=%d)' % c)

open(P, 'w', encoding='utf-8').write(t)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 6 -- VideoEditingViewModel.kt: render paths + preview gating
# ---------------------------------------------------------------------------
step6_vm() {
    echo "== step 6: VideoEditingViewModel.kt -- remove crop/canvas render paths"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt'
t = open(P, encoding='utf-8').read()
n = 0

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

def repl(old, new, cnt=1, name=''):
    global t, n
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        n += 1
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('%s: expected %d, found %d' % (name or old[:60].replace('\n', '|'), cnt, c))

def walk_close(s, i):
    j = s.find('{', i)
    if j == -1:
        return -1
    depth, k = 1, j + 1
    while depth > 0 and k < len(s):
        if s[k] == '{':
            depth += 1
        elif s[k] == '}':
            depth -= 1
        k += 1
    return k if depth == 0 else -1

def cut_fun(sig):
    global t, n
    i = t.find('\n' + sig)
    if i == -1:
        return False
    i += 1
    k = walk_close(t, i)
    if k == -1:
        fail('cut_fun: unbalanced for ' + sig)
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:i] + t[k:]
    n += 1
    return True

# 6a. buildCropFilterExpr + its doc comment
cut_fun('    private fun buildCropFilterExpr(op: EditOperation.Crop): String? {')
repl('    /** Build a crop filter expression for an aspect ratio. */\n', '', 1, 'buildCropFilterExpr doc')

# 6b. buildVideoFilterStages: iterate operations directly, no crop stage
repl("""        // Process overlays first so their relative coordinates align with the uncropped original video, matching the UI.
        val overlayOps = operations.filterNot { it is EditOperation.Crop }
        val cropOps = operations.filterIsInstance<EditOperation.Crop>()

        for (op in overlayOps) {
""", """        for (op in operations) {
""", 1, 'overlayOps/cropOps split')

repl("""
        // Process crop at the end so it crops the video and all overlays together, matching the preview.
        for (op in cropOps) {
            val filterExpr = buildCropFilterExpr(op)
            if (filterExpr != null) {
                val nextLabel = "[v$stageIndex]"
                stages.add("$currentLabel$filterExpr$nextLabel")
                currentLabel = nextLabel
                stageIndex++
            }
        }

        return Pair(stages, currentLabel)
""", """
        return Pair(stages, currentLabel)
""", 1, 'crop-at-end stage')

# 6c. videoOps filter in buildConsolidatedFFmpegCommand
repl('        val videoOps = nonMergeOps.filter { it is EditOperation.Crop || it is EditOperation.AddText || it is EditOperation.AddImageOverlay }\n',
     '        val videoOps = nonMergeOps.filter { it is EditOperation.AddText || it is EditOperation.AddImageOverlay }\n',
     1, 'videoOps filter')

# 6d. canvas background image input section
repl(r"""        // 5. Canvas Background Image Input
        val bgOp = operations.filterIsInstance<EditOperation.CanvasBackground>().lastOrNull()
        var bgImageIndex = -1
        if (bgOp != null && bgOp.type == EditOperation.CanvasBackground.BackgroundType.IMAGE && bgOp.imageUri != null) {
            val bgPath = resolveUriToPath(bgOp.imageUri)
            if (bgPath != null) {
                cmd.append(" -loop 1 -i \"$bgPath\"")
                bgImageIndex = inputIndex
                inputIndex++
            }
        }

""", '', 1, 'canvas background image input')

# 6e. merge path padding: keep only the black color pad
repl("""                // 2. Apply background/padding
                if (bgOp?.type == EditOperation.CanvasBackground.BackgroundType.BLUR) {
                    val blur = bgOp.blurRadius
                    val bgScale = "format=yuv420p,scale=$mainWidth:$mainHeight:force_original_aspect_ratio=increase,crop=$mainWidth:$mainHeight,boxblur=$blur"
                    val fgScale = "scale=$mainWidth:$mainHeight:force_original_aspect_ratio=decrease"
                    filterParts.add("[pre$i]split=2[bg_orig$i][fg_orig$i]")
                    filterParts.add("[bg_orig$i]$bgScale[bg$i]")
                    filterParts.add("[fg_orig$i]$fgScale[fg$i]")
                    filterParts.add("[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2,setsar=1,fps=30,format=yuv420p[norm$i]")
                } else if (bgOp?.type == EditOperation.CanvasBackground.BackgroundType.IMAGE && bgImageIndex != -1) {
                    val bgScale = "scale=$mainWidth:$mainHeight:force_original_aspect_ratio=increase,crop=$mainWidth:$mainHeight"
                    val fgScale = "scale=$mainWidth:$mainHeight:force_original_aspect_ratio=decrease"
                    filterParts.add("[$bgImageIndex:v]$bgScale[bg$i]")
                    filterParts.add("[pre$i]$fgScale[fg$i]")
                    // Use shortest=1 in case the loop goes on forever, but we specified -loop 1 which creates an infinite stream for image
                    filterParts.add("[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2:shortest=1,setsar=1,fps=30,format=yuv420p[norm$i]")
                } else {
                    // Default COLOR
                    val color = bgOp?.colorHex ?: "black"
                    val padColor = if (color.startsWith("#")) color else "black"
                    // Create a solid color background of mainWidth x mainHeight
                    filterParts.add("color=c=$padColor:s=${mainWidth}x${mainHeight}:r=30[bg$i]")
                    filterParts.add("[pre$i]scale=$mainWidth:$mainHeight:force_original_aspect_ratio=decrease[fg$i]")
                    filterParts.add("[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2:shortest=1,setsar=1,fps=30,format=yuv420p[norm$i]")
                }
""", """                // 2. Pad every clip onto a black canvas of the main dimensions
                //    (uniform frame sizes are required for concat/xfade)
                filterParts.add("color=c=black:s=${mainWidth}x${mainHeight}:r=30[bg$i]")
                filterParts.add("[pre$i]scale=$mainWidth:$mainHeight:force_original_aspect_ratio=decrease[fg$i]")
                filterParts.add("[bg$i][fg$i]overlay=(W-w)/2:(H-h)/2:shortest=1,setsar=1,fps=30,format=yuv420p[norm$i]")
""", 1, 'merge path padding')

# 6f. buildPreviewCommand gating + videoOps
repl('        if (operations.none { it is EditOperation.Crop || it is EditOperation.AddText }) {\n',
     '        if (operations.none { it is EditOperation.AddText }) {\n',
     1, 'preview none gate')
repl('        val videoOps = operations.filter { it is EditOperation.Crop || it is EditOperation.AddText }\n',
     '        val videoOps = operations.filter { it is EditOperation.AddText }\n',
     1, 'preview videoOps filter')

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] VideoEditingViewModel.kt: %d edit(s)' % n)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 7 -- FFmpegRenderEngine.kt: drop the dead crop renderers
# ---------------------------------------------------------------------------
step7_engine() {
    echo "== step 7: FFmpegRenderEngine.kt -- remove crop renderers"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt'
t = open(P, encoding='utf-8').read()
n = 0

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

def walk_close(s, i):
    j = s.find('{', i)
    if j == -1:
        return -1
    depth, k = 1, j + 1
    while depth > 0 and k < len(s):
        if s[k] == '{':
            depth += 1
        elif s[k] == '}':
            depth -= 1
        k += 1
    return k if depth == 0 else -1

def cut_fun(sig):
    global t, n
    i = t.find('\n' + sig)
    if i == -1:
        return False
    i += 1
    k = walk_close(t, i)
    if k == -1:
        fail('cut_fun: unbalanced for ' + sig)
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:i] + t[k:]
    n += 1
    return True

def cut_span(start, end):
    global t, n
    i = t.find(start)
    if i == -1:
        return False
    j = t.find(end, i + len(start))
    if j == -1:
        fail('cut_span: end marker not found for ' + start[:60])
    t = t[:i] + t[j + len(end):]
    n += 1
    return True

# 7a. renderCropPreview (brace-walked)
cut_fun('    suspend fun renderCropPreview(')

# 7b. cropVideo (brace-walked)
cut_fun('    suspend fun cropVideo(')

# 7c. buildCropFilter (expression-bodied: cut signature line through closer)
cut_span('    private fun buildCropFilter(aspectRatio: String): String? = when (aspectRatio) {\n',
         '        else   -> null\n    }\n\n')

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] FFmpegRenderEngine.kt: %d removal(s)' % n)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 8 -- VideoEditingActivity.kt: strip all crop/canvas UI code
# ---------------------------------------------------------------------------
step8_vea() {
    echo "== step 8: VideoEditingActivity.kt -- remove crop/canvas UI code"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
t = open(P, encoding='utf-8').read()
n = 0

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

def repl(old, new, cnt=1, name=''):
    global t, n
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        n += 1
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('%s: expected %d, found %d' % (name or old[:60].replace('\n', '|'), cnt, c))

def cut_span(start, end, repl_text=''):
    global t, n
    i = t.find(start)
    if i == -1:
        return False
    j = t.find(end, i + len(start))
    if j == -1:
        fail('cut_span: end marker not found for ' + start[:60].replace('\n', '|'))
    t = t[:i] + repl_text + t[j + len(end):]
    n += 1
    return True

def walk_close(s, i):
    j = s.find('{', i)
    if j == -1:
        return -1
    depth, k = 1, j + 1
    while depth > 0 and k < len(s):
        if s[k] == '{':
            depth += 1
        elif s[k] == '}':
            depth -= 1
        k += 1
    return k if depth == 0 else -1

def cut_fun(sig):
    global t, n
    i = t.find('\n' + sig)
    if i == -1:
        return False
    i += 1
    k = walk_close(t, i)
    if k == -1:
        fail('cut_fun: unbalanced for ' + sig)
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:i] + t[k:]
    n += 1
    return True

def func_span(sig):
    i = t.find('\n' + sig)
    if i == -1:
        return None
    i += 1
    k = walk_close(t, i)
    return (i, k) if k != -1 else None

def repl_in(sig, old, new, cnt=1):
    global t, n
    r = func_span(sig)
    if r is None:
        return False
    i, end = r
    body = t[i:end]
    c = body.count(old)
    if c == cnt:
        t = t[:i] + body.replace(old, new) + t[end:]
        n += 1
        return True
    if c == 0 and (new in body or new == ''):
        return False
    fail('in %s: expected %d, found %d of %r' % (sig.split('(')[0], cnt, c, old[:60]))

# --- 8a. field declarations ----------------------------------------------
repl("""    private var bgPreviewImageView: ImageView? = null
    private var lastActiveClipIndexForBlur: Int = 0
    private var currentBlurJob: Job? = null
""", '', 1, 'bg preview fields')
repl("    private var backgroundEditingToolbar: View? = null\n", '', 1, 'backgroundEditingToolbar field')
repl("""    private var cropEditingToolbar: View? = null
    private var cropOverlayView: com.tharunbirla.librecuts.customviews.CropOverlayView? = null
    private var initialCropOperation: com.tharunbirla.librecuts.models.EditOperation.Crop? = null
""", '', 1, 'crop fields')

# --- 8b. initializeViews --------------------------------------------------
repl("        bgPreviewImageView = findViewById(R.id.bgPreviewImageView)\n", '', 1, 'bgPreviewImageView init')

# --- 8c. cropOverlayView try-block ---------------------------------------
cut_span("        cropOverlayView = try {\n",
         '            Log.w(TAG, "CropOverlayView not found: ${e.message}")\n            null\n        }\n\n')

# --- 8d. cropEditingToolbar try-block -------------------------------------
cut_span("        cropEditingToolbar = try {\n",
         '            Log.w(TAG, "Crop editing toolbar not found: ${e.message}")\n            null\n        }\n\n')

# --- 8e. backgroundEditingToolbar try-block -------------------------------
cut_span("        backgroundEditingToolbar = try {\n",
         '            Log.w(TAG, "Background editing toolbar not found: ${e.message}")\n            null\n        }\n\n')

# --- 8f. tool button click listeners --------------------------------------
repl("""        findViewById<ImageButton>(R.id.btnCrop).setBounceClickListener {
            setActiveToolButton(R.id.btnCrop)
            cropAction()
        }

        findViewById<ImageButton>(R.id.btnCanvasBackground)?.setBounceClickListener {
            setActiveToolButton(R.id.btnCanvasBackground)
            canvasBackgroundAction()
        }

""", '', 1, 'btnCrop/btnCanvasBackground listeners')

# --- 8g. preview button gating --------------------------------------------
repl('                it is EditOperation.Crop || it is EditOperation.AddText\n',
     '                it is EditOperation.AddText\n', 1, 'preview gating')

# --- 8h. tool id list ------------------------------------------------------
repl('        val toolIds = listOf(R.id.btnText, R.id.btnMediaOverlay, R.id.btnAudio, R.id.btnCrop, R.id.btnCanvasBackground)\n',
     '        val toolIds = listOf(R.id.btnText, R.id.btnMediaOverlay, R.id.btnAudio)\n',
     1, 'toolIds list')

# --- 8i. project observer: always fit, no crop/canvas preview -------------
cut_span("                    val cropOps = project.operations.filterIsInstance<EditOperation.Crop>()\n",
         "                    updateCanvasBackgroundPreview()\n",
         "                    fitCanvasToVideo()\n")

# --- 8j. applyCropPreview (whole function) --------------------------------
cut_fun('    private fun applyCropPreview(aspectRatio: String) {')

# --- 8k. resetCropPreview -> fitCanvasToVideo (rename + strip crop refs) --
repl('    private fun resetCropPreview() {\n', '    private fun fitCanvasToVideo() {\n', 1, 'rename resetCropPreview')
repl('            val overlays = listOf(textOverlayView, draggableTextOverlay, imageOverlayView, draggableImageOverlay, cropOverlayView)\n',
     '            val overlays = listOf(textOverlayView, draggableTextOverlay, imageOverlayView, draggableImageOverlay)\n',
     1, 'overlays list in fitCanvasToVideo')
repl('            cropOverlayView?.setVideoSize(finalWidth, finalHeight)\n', '', 1, 'cropOverlayView sizing')

# --- 8l. crop/canvas actions + editing modes -------------------------------
repl("""    @SuppressLint("InflateParams")
    private fun cropAction() {
        enterCropEditingMode()
    }

    private fun canvasBackgroundAction() {
        enterCanvasBackgroundEditingMode()
    }

    private fun enterCanvasBackgroundEditingMode() {
        closeActiveEditingModes()
        editingControlsWrapper.visibility = View.GONE
        backgroundEditingToolbar?.visibility = View.VISIBLE
    }

    private fun exitCanvasBackgroundEditingMode() {
        backgroundEditingToolbar?.visibility = View.GONE
        editingControlsWrapper.visibility = View.VISIBLE
        setActiveToolButton(-1)
    }

""", '', 1, 'crop/canvas actions + editing modes')

# --- 8m. closeActiveEditingModes ------------------------------------------
repl("""        cropEditingToolbar?.visibility = View.GONE
        backgroundEditingToolbar?.visibility = View.GONE
""", '', 1, 'closeActiveEditingModes lines')

# --- 8n. pickBackgroundImage (whole function) ------------------------------
cut_fun('    private fun pickBackgroundImage() {')

# --- 8o. getPresetCropBounds / enter/exit crop mode (whole functions) -----
cut_fun('    private fun getPresetCropBounds(aspectRatio: String): android.graphics.RectF {')
cut_fun('    private fun enterCropEditingMode() {')
cut_fun('    private fun exitCropEditingMode() {')

# --- 8p. updateCanvasBackgroundPreview / updateCropUi (whole functions) ---
cut_fun('    private fun updateCanvasBackgroundPreview(activeClipIndex: Int = lastActiveClipIndexForBlur) {')
cut_fun('    private fun updateCropUi(ratio: String) {')

# --- 8q. onActivityResult: background-image branch -------------------------
repl("""        } else if (requestCode == PICK_BACKGROUND_IMAGE_REQUEST && resultCode == Activity.RESULT_OK) {
            data?.data?.let { imageUri ->
                lifecycleScope.launch {
                    val tempFile = withContext(Dispatchers.IO) { copyContentUriToTempFile(imageUri, "bg_image", ".png") }
                    if (tempFile != null) {
                        val tempUri = Uri.fromFile(tempFile)
                        viewModel.updateCanvasBackgroundOperation(
                            type = EditOperation.CanvasBackground.BackgroundType.IMAGE,
                            imageUri = tempUri
                        )
                        updateCanvasBackgroundPreview()
                    } else {
                        Toast.makeText(this@VideoEditingActivity, "Failed to load image", Toast.LENGTH_SHORT).show()
                    }
                }
            }
        }
""", """        }
""", 1, 'background-image result branch')

# --- 8r. position listener: blur-index block -------------------------------
cut_span("            if (activeClipIndex != lastActiveClipIndexForBlur) {\n",
         "                updateCanvasBackgroundPreview(activeClipIndex)\n            }\n\n")

# --- 8s. triggerCanvasLayoutUpdate: always fit ------------------------------
repl("""    private fun triggerCanvasLayoutUpdate() {
        val cropOps = viewModel.project.value?.operations?.filterIsInstance<com.tharunbirla.librecuts.models.EditOperation.Crop>()
        if (cropOps != null && cropOps.isNotEmpty() && cropEditingToolbar?.visibility != View.VISIBLE) {
            applyCropPreview(cropOps.last().aspectRatio)
        } else {
            resetCropPreview()
        }
    }
""", """    private fun triggerCanvasLayoutUpdate() {
        fitCanvasToVideo()
    }
""", 1, 'triggerCanvasLayoutUpdate')

# --- 8t. request-code constant ----------------------------------------------
repl('        private const val PICK_BACKGROUND_IMAGE_REQUEST = 6\n', '', 1, 'PICK_BACKGROUND_IMAGE_REQUEST const')

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] VideoEditingActivity.kt: %d edit(s)' % n)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 9 -- strings sweep: remove the six dead keys from every locale
# ---------------------------------------------------------------------------
step9_strings() {
    echo "== step 9: strings sweep (all locales)"
    python3 - <<'CUTPY'
import glob, re, sys

KEYS = ['str_crop', 'str_crop_aspect_ratio', 'str_16_9', 'str_9_16', 'str_1_1', 'str_custom']
files = sorted(glob.glob('app/src/main/res/values*/strings.xml'))
removed_total = 0
for f in files:
    t = open(f, encoding='utf-8').read()
    before = t
    for k in KEYS:
        # exact name match -- never touches str_custom_directory / str_custom_speed
        t = re.sub(r'[ \t]*<string name="' + k + r'">[^<]*</string>\n', '', t)
    if t != before:
        open(f, 'w', encoding='utf-8').write(t)
        removed_total += 1
print('   [ok] %d locale file(s) cleaned' % removed_total)
if not files:
    print('   [FAIL] no strings.xml files found')
    sys.exit(1)
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 10 -- verification gate
# ---------------------------------------------------------------------------
step10_verify() {
    echo "== step 10: verification gate"

    # 10a: leftover scan -- zero references to the removed features
    local left=0 tok n
    for tok in btnCrop btnCanvasBackground btnCropDone btnBackFromBackground \
               btnBackgroundDone btnBackgroundColor btnBackgroundBlur btnBackgroundImage \
               tvTitleBackground tvTitleCrop frameAspectRatio1 frameAspectRatio2 \
               frameAspectRatio3 frameAspectRatioCustom \
               bg16_9 ic16_9 txt16_9 bg9_16 ic9_16 txt9_16 \
               bg1_1 ic1_1 txt1_1 bgCustom icCustom txtCustom \
               cropOverlayView cropEditingToolbar backgroundEditingToolbar \
               initialCropOperation bgPreviewImageView lastActiveClipIndexForBlur \
               currentBlurJob pickBackgroundImage PICK_BACKGROUND_IMAGE_REQUEST \
               applyCropPreview resetCropPreview getPresetCropBounds \
               enterCropEditingMode exitCropEditingMode updateCropUi \
               updateCanvasBackgroundPreview canvasBackgroundAction \
               enterCanvasBackgroundEditingMode exitCanvasBackgroundEditingMode \
               cropAction CropOverlayView \
               addCropOperation updateCanvasBackgroundOperation \
               buildCropFilterExpr buildCropFilter renderCropPreview cropVideo \
               "EditOperation.Crop" "EditOperation.CanvasBackground" \
               "viewModel.addCropOperation" "updateCanvasBackground" \
               crop_editing_toolbar background_editing_toolbar \
               ic_crop_24 ic_crop_16_9_24 ic_crop_portrait_24 ic_crop_square_24 \
               ic_canvas_24 ic_canvas_color_24 aspect_ratio_background \
               str_crop str_crop_aspect_ratio str_16_9 str_9_16 str_1_1 ; do
        n=$(grep -rn -- "$tok" app/src/main 2>/dev/null | wc -l)
        if [ "$n" -ne 0 ]; then
            echo " [FAIL] leftover reference: $tok ($n hits)"
            grep -rn -- "$tok" app/src/main 2>/dev/null | head -3
            left=1
        fi
    done
    # str_custom needs a word-boundary scan (avoids str_custom_directory etc.)
    n=$(grep -rnE -- 'name="str_custom"|@string/str_custom"|R\.string\.str_custom\b' app/src/main 2>/dev/null | wc -l)
    if [ "$n" -ne 0 ]; then
        echo " [FAIL] leftover reference: str_custom ($n hits)"
        grep -rnE -- 'name="str_custom"|@string/str_custom"|R\.string\.str_custom\b' app/src/main 2>/dev/null | head -3
        left=1
    fi
    if [ "$left" -eq 0 ]; then
        echo " [ok] zero leftover references to crop + canvas"
    else
        return 1
    fi

    # 10b: kept-feature survival asserts
    python3 - <<'CUTPY' || return 1
import sys

def rd(p):
    return open(p, encoding='utf-8').read()

vea = rd('app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt')
ext = rd('app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt')
vm = rd('app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt')
eo = rd('app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt')
ps = rd('app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt')
fre = rd('app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt')
avem = rd('app/src/main/res/layout/activity_video_editing.xml')

errs = []
def need(text, tok, lo, name):
    c = text.count(tok)
    if c < lo:
        errs.append('%s: expected >=%d of %r, found %d' % (name, lo, tok, c))

# the renamed fit function + its two call sites
need(vea, 'fun fitCanvasToVideo', 1, 'VEA')
need(vea, 'fitCanvasToVideo()', 2, 'VEA')
need(vea, 'reparentCanvasContainer', 3, 'VEA')
need(vea, 'triggerCanvasLayoutUpdate', 2, 'VEA')
# remaining main tools
need(vea, 'R.id.btnText)', 1, 'VEA')
need(vea, 'R.id.btnMediaOverlay', 1, 'VEA')
need(vea, 'R.id.btnAudio', 1, 'VEA')
need(vea, 'val toolIds = listOf(R.id.btnText, R.id.btnMediaOverlay, R.id.btnAudio)', 1, 'VEA')
# video toolbar survivors (phase 7 kept these)
need(vea, 'btnVideoTrim', 1, 'VEA')
need(vea, 'btnVideoSplit', 1, 'VEA')
need(vea, 'btnVideoSpeed', 1, 'VEA')
need(vea, 'btnVideoFreezeFrame', 1, 'VEA')
need(vea, 'btnVideoMute', 1, 'VEA')
# shared helpers that must survive
need(vea, 'fun showCustomColorPicker', 1, 'VEA')
need(vea, 'fun copyContentUriToTempFile', 2, 'VEA')
need(vea, 'findTextureView', 3, 'VEA')
need(vea, 'PICK_VIDEO_REQUEST', 2, 'VEA')
need(vea, 'PICK_AUDIO_REQUEST', 2, 'VEA')
need(vea, 'PICK_IMAGE_REQUEST', 2, 'VEA')
need(vea, 'PICK_DIRECTORY_REQUEST', 2, 'VEA')
need(vea, 'is EditOperation.AddText', 2, 'VEA')
# viewmodel survivors
need(ext, 'fun VideoEditingViewModel.updateMainVideoTrim', 1, 'Ext')
need(ext, 'fun VideoEditingViewModel.updateMainVideoSpeed', 1, 'Ext')
need(ext, 'fun VideoEditingViewModel.addTextOperation', 1, 'Ext')
need(ext, 'fun VideoEditingViewModel.addMergeOperation', 1, 'Ext')
need(ext, 'fun VideoEditingViewModel.addBackgroundAudioOperation', 1, 'Ext')
need(ext, 'fun VideoEditingViewModel.addImageOverlayOperation', 1, 'Ext')
need(vm, 'fun buildVideoFilterStages', 1, 'VM')
need(vm, 'fun buildConsolidatedFFmpegCommand', 1, 'VM')
need(vm, 'fun buildPreviewCommand', 1, 'VM')
need(vm, 'fun buildMergeCommand', 1, 'VM')
need(vm, 'for (op in operations) {', 1, 'VM')
need(vm, 'color=c=black:s=', 1, 'VM')
need(vm, 'xfade=transition=', 1, 'VM')
need(vm, 'EditOperation.SpeedMain', 1, 'VM')
# model survivors
need(eo, 'data class Trim(', 1, 'EO')
need(eo, 'data class SpeedMain(', 1, 'EO')
need(eo, 'data class AddText(', 1, 'EO')
need(eo, 'data class MergeItem(', 1, 'EO')
need(eo, 'data class Merge(', 1, 'EO')
need(eo, 'data class MuteAudio(', 1, 'EO')
need(eo, 'data class Transition(', 1, 'EO')
need(eo, 'data class MuteClip(', 1, 'EO')
need(eo, 'data class AddBackgroundAudio(', 1, 'EO')
need(eo, 'data class AddImageOverlay(', 1, 'EO')
# serializer survivors
need(ps, '"Trim" -> EditOperation.Trim::class.java', 1, 'PS')
need(ps, '"AddText" -> EditOperation.AddText::class.java', 1, 'PS')
need(ps, '"AddImageOverlay" -> EditOperation.AddImageOverlay::class.java', 1, 'PS')
need(ps, '"Transition" -> EditOperation.Transition::class.java', 1, 'PS')
# engine survivors
need(fre, 'fun executeCommand', 1, 'FRE')
need(fre, 'suspend fun generateScrubProxy', 1, 'FRE')
need(fre, 'suspend fun addTextOverlay', 1, 'FRE')
need(fre, 'fun buildDrawtextFilter', 1, 'FRE')
# layout survivors
need(avem, 'canvasContainer', 1, 'main-layout')
need(avem, '@color/cinemaBlack', 1, 'main-layout')
need(avem, 'btnText', 1, 'main-layout')
need(avem, 'btnMediaOverlay', 1, 'main-layout')
need(avem, 'btnAudio', 1, 'main-layout')
need(avem, 'android:layout_height="200dp"', 1, 'main-layout')
need(rd('app/src/main/res/layout/video_editing_toolbar.xml'), 'btnVideoSpeed', 1, 'video-toolbar')
need(rd('app/src/main/res/layout/video_editing_toolbar.xml'), 'btnVideoCancel', 1, 'video-toolbar')
need(rd('app/src/main/res/values/strings.xml'), 'name="str_text"', 1, 'strings')
need(rd('app/src/main/res/values/strings.xml'), 'name="str_overlay"', 1, 'strings')
need(rd('app/src/main/res/values/strings.xml'), 'name="str_audio"', 1, 'strings')

if errs:
    for e in errs:
        print(' [FAIL] survival: ' + e)
    sys.exit(1)
print(' [ok] all kept-feature survival checks passed')
CUTPY

    # 10c: function-inventory guard vs git HEAD
    inv_check() {
        local f="$1" exp_rm="$2" exp_add="$3"
        if [ ! -f "$f" ]; then
            echo " [FAIL] expected file missing: $f"
            return 1
        fi
        if git diff --quiet HEAD -- "$f" 2>/dev/null; then
            echo " [skip] $f matches HEAD (already committed)"
            return 0
        fi
        local tmp
        tmp=$(mktemp)
        if ! git show "HEAD:$f" > "$tmp" 2>/dev/null; then
            echo " [FAIL] cannot read HEAD version of $f"
            rm -f "$tmp"
            return 1
        fi
        python3 - "$tmp" "$f" "$exp_rm" "$exp_add" <<'CUTPY'
import re, sys
head, work, exp_rm, exp_add = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def inv(p):
    t = open(p, encoding='utf-8').read()
    names = set()
    for m in re.finditer(r'^\s*(?:(?:private|internal|public|suspend|override)\s+)*fun\s+([A-Za-z0-9_.]+?)\s*\(', t, re.M):
        names.add(m.group(1).split('.')[-1])
    return names

h, w = inv(head), inv(work)
rm, add = h - w, w - h
erm = set(x for x in exp_rm.split(',') if x)
ead = set(x for x in exp_add.split(',') if x)
bad = []
if rm != erm:
    bad.append('removed=%s expected=%s' % (sorted(rm), sorted(erm)))
if add != ead:
    bad.append('added=%s expected=%s' % (sorted(add), sorted(ead)))
if bad:
    print(' [FAIL] function inventory drift in %s: %s' % (work, '; '.join(bad)))
    sys.exit(1)
print(' [ok] inventory intact: %s (removed %d, added %d)' % (work.split('/')[-1], len(erm), len(ead)))
CUTPY
        local rc=$?
        rm -f "$tmp"
        [ $rc -ne 0 ] && return 1
        return 0
    }
    inv_check "$VEA" "applyCropPreview,resetCropPreview,cropAction,canvasBackgroundAction,enterCanvasBackgroundEditingMode,exitCanvasBackgroundEditingMode,pickBackgroundImage,getPresetCropBounds,enterCropEditingMode,exitCropEditingMode,updateCanvasBackgroundPreview,updateCropUi" "fitCanvasToVideo" || return 1
    inv_check "$EXT" "addCropOperation,updateCanvasBackgroundOperation" "" || return 1
    inv_check "$VM" "buildCropFilterExpr" "" || return 1
    inv_check "$EO" "" "" || return 1
    inv_check "$PS" "" "" || return 1
    inv_check "$FRE" "renderCropPreview,cropVideo,buildCropFilter" "" || return 1

    # 10d: brace-balance DELTA vs git HEAD (pre-existing deltas tolerated)
    python3 - <<'CUTPY' || return 1
import subprocess, sys
files = [
 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt',
 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt',
 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt',
 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt',
 'app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt',
 'app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt',
]
for f in files:
    w = open(f, encoding='utf-8').read()
    h = subprocess.run(['git', 'show', 'HEAD:' + f],
                       capture_output=True, text=True).stdout
    wd = w.count('{') - w.count('}')
    hd = h.count('{') - h.count('}')
    if wd != hd:
        print(' [FAIL] brace-delta drift in %s (was %d, now %d)' % (f, hd, wd))
        sys.exit(1)
print(' [ok] brace balance preserved in %d Kotlin files' % len(files))
CUTPY

    # 10e: XML parse of touched files
    python3 - <<'CUTPY' || return 1
import glob
import xml.dom.minidom as md
files = ['app/src/main/res/layout/activity_video_editing.xml']
files += sorted(glob.glob('app/src/main/res/values*/strings.xml'))
for f in files:
    md.parse(f)
print(' [ok] %d XML files parse cleanly' % len(files))
CUTPY

    # 10f: scope gate
    local bad
    bad=$(git status --porcelain 2>/dev/null | cut -c4- | grep -Ev \
'^(scripts/apply-changes\.sh|app/src/main/res/layout/activity_video_editing\.xml|app/src/main/java/com/tharunbirla/librecuts/(VideoEditingActivity|models/EditOperation|utils/ProjectSerializer|services/FFmpegRenderEngine)\.kt|app/src/main/java/com/tharunbirla/librecuts/viewmodels/(VideoEditingViewModelExt|VideoEditingViewModel)\.kt|app/src/main/java/com/tharunbirla/librecuts/customviews/CropOverlayView\.kt|app/src/main/res/layout/(crop_editing_toolbar|background_editing_toolbar)\.xml|app/src/main/res/drawable/(ic_crop_24|ic_crop_16_9_24|ic_crop_portrait_24|ic_crop_square_24|ic_canvas_24|ic_canvas_color_24|aspect_ratio_background|aspect_ratio_background_selected)\.xml|app/src/main/res/values[^/]*/strings\.xml)$' || true)
    if [ -n "$bad" ]; then
        echo " [FAIL] unexpected files in the working diff:"
        echo "$bad"
        return 1
    fi
    if git status --porcelain 2>/dev/null | grep -q '^??'; then
        echo " [FAIL] untracked files present (pipeline must not create any)"
        git status --porcelain | grep '^??'
        return 1
    fi
    echo " [ok] change scope is exactly the expected file set"

    # 10g: .github/ policy + ASCII self-check
    local gh
    gh=$(git status --porcelain 2>/dev/null | grep -c '\.github/' || true)
    if [ "${gh:-0}" -ne 0 ]; then
        echo " [FAIL] .github/ files modified -- refusing to continue"
        return 1
    fi
    echo " [ok] no .github/ files touched"

    local ascii
    ascii=$(LC_ALL=C grep -cP '[^\x00-\x7F]' "$SELF" 2>/dev/null || true)
    if [ "${ascii:-0}" -ne 0 ]; then
        echo " [FAIL] $SELF contains non-ASCII characters"
        return 1
    fi
    echo " [ok] script is 100% pure ASCII"
    return 0
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " Cutloss phase 8 -- remove Crop and Canvas Background"
echo " from the main toolbar (all the way down to models,"
echo " serializers, render paths, icons and translated strings)"
echo "=========================================================="
step0_preconditions || FAILED=1
step1_layout       || FAILED=1
step2_delete_files || FAILED=1
step3_models       || FAILED=1
step4_serializer   || FAILED=1
step5_ext          || FAILED=1
step6_vm           || FAILED=1
step7_engine       || FAILED=1
step8_vea          || FAILED=1
step9_strings      || FAILED=1
step10_verify      || FAILED=1

echo "----------------------------------------------------------"
echo " line counts: VEA $(wc -l < "$VEA" 2>/dev/null) | Ext $(wc -l < "$EXT" 2>/dev/null) | VM $(wc -l < "$VM" 2>/dev/null) | EO $(wc -l < "$EO" 2>/dev/null) | PS $(wc -l < "$PS" 2>/dev/null) | FRE $(wc -l < "$FRE" 2>/dev/null)"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 8 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 8 complete. Steps ok or skipped."
echo "  The main toolbar now shows only: Text, Overlay, Audio."
echo "  Crop and Canvas Background are gone down to their models,"
echo "  serializers, render paths, icons and translated strings."
echo "  The canvas container keeps a black backdrop and still"
echo "  fits the video aspect ratio (fitCanvasToVideo) so overlay"
echo "  alignment, fullscreen and PiP reparenting keep working."
echo "  Merge exports keep the black pad (concat/xfade requires"
echo "  uniform frame sizes)."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
