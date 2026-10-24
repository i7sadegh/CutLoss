#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 7 -- remove six video-toolbar features entirely:
#    1. Filter  (color filters / LUTs)
#    2. Adjust  (brightness / contrast / saturation / ...)
#    3. Mask    (video + image mask system, incl. mask keyframes)
#    4. Reverse
#    5. Mirror  (VIDEO mirror only; image-overlay mirror stays)
#    6. Extract (extract audio to a new layer)
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  Scope of the removal (all of the code, per the no-.lcprj-compat policy):
#    - video_editing_toolbar.xml : the six button blocks
#    - image_editing_toolbar.xml : the image Mask button (mask is shared)
#    - VideoEditingActivity.kt   : wirings, dialogs, preview matrix code,
#                                  keyframe-mask branches, mask view setup
#    - VideoEditingViewModelExt  : setColorFilter / setAdjust / mirror /
#                                  reverse / mask mutators; split + delete
#                                  promotion logic simplified
#    - VideoEditingViewModel.kt  : LUT + adjust filter builders, mask geq
#                                  builder, merge-loop and non-merge paths
#    - EditOperation.kt          : ReverseMain, MirrorMain, MaskMain,
#                                  ColorFilter, Adjust, MaskShape, MaskConfig,
#                                  MergeItem{isReversed,isMirrored,maskConfig},
#                                  AddImageOverlay.maskConfig,
#                                  AddBackgroundAudio.extractedFromSegmentIndex
#    - ProjectSerializer.kt      : the five dead type mappings
#    - ProjectImportActivity.kt  : ReverseMain proxy revalidation branch
#    - customviews               : VideoMaskOverlayView + MaskedFrameLayout
#                                  deleted; mask code stripped from
#                                  DraggableImageOverlayView + ImageOverlayView
#    - services/FFmpegRenderEngine.kt : reverseVideo() + extractAudio()
#    - layouts deleted           : bottom_sheet_mask, dialog_color_filters,
#                                  item_color_filter_option,
#                                  dialog_adjustments, item_adjust_option
#    - drawables deleted         : 9 filter_preview jpgs, ic_mask_24,
#                                  ic_audio_extract_24, ic_fast_rewind_24,
#                                  ic_page_info_24, 10 adjust icons
#    - strings (all locales)     : 9 dead keys
#  Kept on purpose (shared / other features):
#    ic_palette_24 (text palette), ic_mirror (image mirror button),
#    btnImageMirror + DraggableImageOverlayView.toggleMirror,
#    speed / freeze / trim / split / mute buttons, keyframes for
#    Position / Opacity / Speed, findTextureView (transition preview).
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
PIA="app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt"
DIOV="app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt"
IOV="app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView.kt"
FRE="app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt"
VTB="app/src/main/res/layout/video_editing_toolbar.xml"
ITB="app/src/main/res/layout/image_editing_toolbar.xml"
AVEM="app/src/main/res/layout/activity_video_editing.xml"
SELF="scripts/apply-changes.sh"
FAILED=0

# ---------------------------------------------------------------------------
#  STEP 0 -- preconditions
# ---------------------------------------------------------------------------
step0_preconditions() {
    echo "== step 0: preconditions"
    local ok=1 f
    for f in "$VEA" "$EXT" "$VM" "$EO" "$PS" "$PIA" "$DIOV" "$IOV" "$FRE" \
             "$VTB" "$ITB" "$AVEM"; do
        if [ ! -f "$f" ]; then
            echo " [FAIL] missing file: $f"
            ok=0
        fi
    done
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo " [FAIL] not inside a git repository"
        ok=0
    fi
    # phase-6 markers must be present (correct base state)
    if grep -q 'btnVideoReverse' "$VTB" 2>/dev/null; then
        echo " [ok] video toolbar still contains the six target buttons"
    else
        echo " [skip-check] video toolbar already clean of target buttons"
    fi
    if grep -q 'android:layout_height="200dp"' "$AVEM" 2>/dev/null; then
        echo " [ok] phase-6 base state detected (timeline 200dp)"
    else
        echo " [FAIL] phase-6 marker (timeline 200dp) missing -- wrong base"
        ok=0
    fi
    [ "$ok" -eq 1 ] && echo " [ok] repo state matches the expected phase-6 base"
    [ "$ok" -eq 1 ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 1 -- toolbar layouts: remove the six video buttons + image mask button
# ---------------------------------------------------------------------------
step1_toolbars() {
    echo "== step 1: remove the six buttons from the toolbars"
    python3 - <<'CUTPY'
import sys
import xml.dom.minidom as md

def lit(t, old, new, cnt=1, name=''):
    c = t.count(old)
    if c == cnt:
        return t.replace(old, new), True
    if c == 0 and (new in t or new == ''):
        return t, False          # already applied
    print('   [FAIL] %s: expected %d, found %d' % (name or old[:50], cnt, c))
    sys.exit(1)

# ---- video_editing_toolbar.xml: six blocks -------------------------------
p = 'app/src/main/res/layout/video_editing_toolbar.xml'
t = open(p, encoding='utf-8').read()
changed = False

blocks = [
"""        <!-- Color Filters / LUTs -->
        <LinearLayout
            android:id="@+id/btnVideoFilterContainer"
            android:layout_width="60dp"
            android:layout_height="wrap_content"
            android:orientation="vertical"
            android:gravity="center">
            <ImageButton
                android:id="@+id/btnVideoFilter"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="@drawable/tool_button_inactive"
                android:src="@drawable/ic_palette_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                app:tint="@color/toolTextInactive" />
            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="4dp"
                android:text="@string/str_filters"
                android:textSize="11sp"
                android:fontFamily="sans-serif-medium"
                android:textColor="@color/toolTextInactive"/>
        </LinearLayout>

""",
"""        <!-- Mask -->
        <LinearLayout
            android:id="@+id/btnVideoMaskContainer"
            android:layout_width="60dp"
            android:layout_height="wrap_content"
            android:orientation="vertical"
            android:gravity="center">
            <ImageButton
                android:id="@+id/btnVideoMask"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="@drawable/tool_button_inactive"
                android:src="@drawable/ic_mask_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                app:tint="@color/toolTextInactive" />
            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="4dp"
                android:text="Mask"
                android:textSize="11sp"
                android:fontFamily="sans-serif-medium"
                android:textColor="@color/toolTextInactive"/>
        </LinearLayout>

""",
"""        <!-- Adjust -->
        <LinearLayout
            android:id="@+id/btnVideoAdjustContainer"
            android:layout_width="60dp"
            android:layout_height="wrap_content"
            android:orientation="vertical"
            android:gravity="center">
            <ImageButton
                android:id="@+id/btnVideoAdjust"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="@drawable/tool_button_inactive"
                android:src="@drawable/ic_page_info_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                app:tint="@color/toolTextInactive" />
            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="4dp"
                android:text="@string/str_adjust"
                android:textSize="11sp"
                android:fontFamily="sans-serif-medium"
                android:textColor="@color/toolTextInactive"/>
        </LinearLayout>

""",
"""        <!-- Extract Audio -->
        <LinearLayout
            android:id="@+id/btnVideoExtractAudioContainer"
            android:layout_width="60dp"
            android:layout_height="wrap_content"
            android:orientation="vertical"
            android:gravity="center">
            <ImageButton
                android:id="@+id/btnVideoExtractAudio"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="@drawable/tool_button_inactive"
                android:src="@drawable/ic_audio_extract_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                app:tint="@color/toolTextInactive" />
            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="4dp"
                android:text="@string/str_extract"
                android:textSize="11sp"
                android:fontFamily="sans-serif-medium"
                android:textColor="@color/toolTextInactive"/>
        </LinearLayout>

""",
"""        <!-- Reverse -->
        <LinearLayout
            android:id="@+id/btnVideoReverseContainer"
            android:layout_width="60dp"
            android:layout_height="wrap_content"
            android:orientation="vertical"
            android:gravity="center">
            <ImageButton
                android:id="@+id/btnVideoReverse"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="@drawable/tool_button_inactive"
                android:src="@drawable/ic_fast_rewind_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                app:tint="@color/toolTextInactive" />
            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="4dp"
                android:text="@string/str_reverse"
                android:textSize="11sp"
                android:fontFamily="sans-serif-medium"
                android:textColor="@color/toolTextInactive"/>
        </LinearLayout>

""",
"""        <!-- Mirror -->
        <LinearLayout
            android:id="@+id/btnVideoMirrorContainer"
            android:layout_width="60dp"
            android:layout_height="wrap_content"
            android:orientation="vertical"
            android:gravity="center">
            <ImageButton
                android:id="@+id/btnVideoMirror"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="@drawable/tool_button_inactive"
                android:src="@drawable/ic_mirror"
                android:padding="8dp"
                android:scaleType="fitCenter"
                app:tint="@color/toolTextInactive" />
            <TextView
                android:id="@+id/tvVideoMirror"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="4dp"
                android:text="Mirror"
                android:textSize="11sp"
                android:fontFamily="sans-serif-medium"
                android:textColor="@color/toolTextInactive"/>
        </LinearLayout>

"""]

removed = 0
for b in blocks:
    t2, ch = lit(t, b, '', 1, 'toolbar block')
    if ch:
        removed += 1
    t = t2

md.parseString(t)
open(p, 'w', encoding='utf-8').write(t)
print('   [ok] video_editing_toolbar.xml: %d button block(s) removed' % removed)

# ---- image_editing_toolbar.xml: the image Mask block ----------------------
p = 'app/src/main/res/layout/image_editing_toolbar.xml'
t = open(p, encoding='utf-8').read()
blk = """        <!-- Mask -->
        <LinearLayout
            android:id="@+id/btnImageMaskContainer"
            android:layout_width="60dp"
            android:layout_height="wrap_content"
            android:orientation="vertical"
            android:gravity="center">
            <ImageButton
                android:id="@+id/btnImageMask"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="@drawable/tool_button_inactive"
                android:src="@drawable/ic_mask_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                app:tint="@color/toolTextInactive" />
            <TextView
                android:id="@+id/tvImageMask"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="4dp"
                android:text="Mask"
                android:textSize="11sp"
                android:fontFamily="sans-serif-medium"
                android:textColor="@color/toolTextInactive"/>
        </LinearLayout>

"""
t, ch = lit(t, blk, '', 1, 'image mask block')
md.parseString(t)
open(p, 'w', encoding='utf-8').write(t)
print('   [ok] image_editing_toolbar.xml: mask block %s' % ('removed' if ch else 'already absent'))

# ---- activity_video_editing.xml: unmask the player container --------------
p = 'app/src/main/res/layout/activity_video_editing.xml'
t = open(p, encoding='utf-8').read()

t, c1 = lit(t,
"""                <com.tharunbirla.librecuts.customviews.MaskedFrameLayout
                    android:id="@+id/mainVideoMaskContainer"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent">""",
"""                <FrameLayout
                    android:layout_width="match_parent"
                    android:layout_height="match_parent">""", 1, 'MaskedFrameLayout open')

t, c2 = lit(t,
'                </com.tharunbirla.librecuts.customviews.MaskedFrameLayout>',
'                </FrameLayout>', 1, 'MaskedFrameLayout close')

t, c3 = lit(t,
"""            <com.tharunbirla.librecuts.customviews.VideoMaskOverlayView
                android:id="@+id/videoMaskOverlayView"
                android:layout_width="match_parent"
                android:layout_height="match_parent"
                android:visibility="gone" />

""", '', 1, 'VideoMaskOverlayView element')

md.parseString(t)
open(p, 'w', encoding='utf-8').write(t)
print('   [ok] activity_video_editing.xml: player container unmasked (%d/%d/%d edits)'
      % (c1, c2, c3))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 2 -- VideoEditingActivity.kt
# ---------------------------------------------------------------------------
step2_vea() {
    echo "== step 2: VideoEditingActivity.kt -- remove the six features"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
t = open(P, encoding='utf-8').read()
orig_lines = t.count('\n')

def fail(msg):
    print('   [FAIL] ' + msg)
    sys.exit(1)

def repl(old, new, cnt=1, name=''):
    global t
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('%s: expected %d, found %d' % (name or old[:60].replace('\n', '|'), cnt, c))

def cut_span(start, end, repl_text=''):
    global t
    i = t.find(start)
    if i == -1:
        return False
    j = t.find(end, i + len(start))
    if j == -1:
        fail('cut_span: end marker not found for ' + start[:60])
    t = t[:i] + repl_text + t[j + len(end):]
    return True

def walk_close(s, i):
    """index just past the brace closing the first '{' at/after i"""
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
    global t
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
    return True

def func_span(sig):
    i = t.find('\n' + sig)
    if i == -1:
        return None
    i += 1
    k = walk_close(t, i)
    return (i, k) if k != -1 else None

def repl_in(sig, old, new, cnt=1):
    global t
    r = func_span(sig)
    if r is None:
        return False
    i, end = r
    body = t[i:end]
    c = body.count(old)
    if c == cnt:
        t = t[:i] + body.replace(old, new) + t[end:]
        return True
    if c == 0 and (new in body or new == ''):
        return False
    fail('in %s: expected %d, found %d of %r' % (sig.split('(')[0], cnt, c, old[:60]))

def cut_video_else(sig, first_line):
    """Remove the trailing `} else { ... }` branch whose first body line is
    given; the if-close brace before ` else ` is kept."""
    global t
    r = func_span(sig)
    if r is None:
        return False
    i, end = r
    body = t[i:end]
    sm = '        } else {\n' + first_line
    si = body.find(sm)
    if si == -1:
        return False
    k = walk_close(body, si + 9)
    if k == -1:
        fail('cut_video_else: unbalanced in ' + sig)
    body = body[:si + 9] + body[k:]
    t = t[:i] + body + t[end:]
    return True

# --- 2a. whole-function cuts ---------------------------------------------
funs = [
 ('    private fun reverseVideoSegment(index: Int, item: com.tharunbirla.librecuts.models.EditOperation.MergeItem) {', 'reverseVideoSegment'),
 ('    private fun regenerateSpeedProxyForUnreverse(index: Int, item: com.tharunbirla.librecuts.models.EditOperation.MergeItem) {', 'regenerateSpeedProxyForUnreverse'),
 ('    private fun extractAudioFromSegment(index: Int, item: com.tharunbirla.librecuts.models.EditOperation.MergeItem) {', 'extractAudioFromSegment'),
 ('    private fun showColorFilterSelectionDialog(clipIndex: Int) {', 'showColorFilterSelectionDialog'),
 ('    private fun showAdjustSelectionDialog(clipIndex: Int) {', 'showAdjustSelectionDialog'),
 ('    private fun showMaskBottomSheet() {', 'showMaskBottomSheet'),
 ('    private fun applyColorFilterToPlayer(filterName: String) {', 'applyColorFilterToPlayer'),
 ('    private fun applyColorFilterAndAdjustToPlayer(', 'applyColorFilterAndAdjustToPlayer'),
]
nfun = sum(1 for sig, _ in funs if cut_fun(sig))
print('   [ok] %d whole function(s) cut' % nfun)

# --- 2b. toolbar wirings ---------------------------------------------------
repl("""                toolbar.findViewById<ImageButton>(R.id.btnVideoExtractAudio)?.setBounceClickListener {
                    selectedVideoIndex?.let { index ->
                        val items = getSequenceItems()
                        if (index >= 0 && index < items.size) {
                            extractAudioFromSegment(index, items[index])
                        }
                    }
                }
""", '', 1, 'extract wiring')
repl("""                toolbar.findViewById<ImageButton>(R.id.btnVideoReverse)?.setBounceClickListener {
                    selectedVideoIndex?.let { index ->
                        val items = getSequenceItems()
                        if (index >= 0 && index < items.size) {
                            reverseVideoSegment(index, items[index])
                        }
                    }
                }
""", '', 1, 'reverse wiring')
repl("""                toolbar.findViewById<ImageButton>(R.id.btnVideoMirror)?.setBounceClickListener {
                    selectedVideoIndex?.let { index ->
                        if (index == 0) {
                            val isCurrentlyMirrored = viewModel.project.value?.operations?.any { it is EditOperation.MirrorMain && it.isMirrored } ?: false
                            viewModel.updateMainVideoMirror(!isCurrentlyMirrored)
                        } else {
                            viewModel.toggleMergeItemMirror(index - 1)
                        }
                        viewModel.project.value?.let { renderTracks(it) }
                        syncUiWithPlayer()
                    }
                }
""", '', 1, 'mirror wiring')
repl("""                toolbar.findViewById<ImageButton>(R.id.btnVideoFilter)?.setBounceClickListener {
                    selectedVideoIndex?.let { index ->
                        showColorFilterSelectionDialog(index)
                    }
                }
""", '', 1, 'filter wiring')
repl("""                toolbar.findViewById<ImageButton>(R.id.btnVideoMask)?.setBounceClickListener {
                    showMaskBottomSheet()
                }
""", '', 1, 'mask wiring')
repl("""                toolbar.findViewById<ImageButton>(R.id.btnVideoAdjust)?.setBounceClickListener {
                    selectedVideoIndex?.let { index ->
                        showAdjustSelectionDialog(index)
                    }
                }
""", '', 1, 'adjust wiring')
repl("""                toolbar.findViewById<View>(R.id.btnImageMask)?.setBounceClickListener {
                    showMaskBottomSheet()
                }
""", '', 1, 'image mask wiring')
print('   [ok] toolbar wirings removed')

# --- 2c. fields ------------------------------------------------------------
repl("""    private var videoMaskOverlayView: com.tharunbirla.librecuts.customviews.VideoMaskOverlayView? = null
    private var mainVideoMaskContainer: com.tharunbirla.librecuts.customviews.MaskedFrameLayout? = null
""", '', 1, 'mask view fields')
repl("""    private var lastAppliedFilterName: String? = null
    private var lastAppliedAdjust: com.tharunbirla.librecuts.models.EditOperation.Adjust? = null
""", '', 1, 'preview filter fields')

# --- 2d. image-commit callback: drop maskConfig parameter ------------------
repl('overlay.onImageCommitted = { uri, relX, relY, relW, relH, rotationAngle, opacity, isMirrored, maskConfig ->',
     'overlay.onImageCommitted = { uri, relX, relY, relW, relH, rotationAngle, opacity, isMirrored ->',
     1, 'onImageCommitted lambda')
repl('imageUri = uri, relativeX = relX, relativeY = relY, relativeWidth = relW, relativeHeight = relH, rotationAngle = rotationAngle, opacity = opacity, isMirrored = isMirrored, maskConfig = maskConfig',
     'imageUri = uri, relativeX = relX, relativeY = relY, relativeWidth = relW, relativeHeight = relH, rotationAngle = rotationAngle, opacity = opacity, isMirrored = isMirrored',
     1, 'updateOperation args')
repl("""                                opacity = opacity,
                                isMirrored = isMirrored,
                                maskConfig = maskConfig
                            )""",
"""                                opacity = opacity,
                                isMirrored = isMirrored
                            )""", 1, 'addImageOverlayOperation args')

# --- 2e. draggableImageOverlay onMaskChanged + videoMaskOverlayView init ---
cut_span(
'                overlay.onMaskChanged = { newMaskConfig ->',
"""                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "DraggableImageOverlayView not found:""",
"""            }
        } catch (e: Exception) {
            Log.w(TAG, "DraggableImageOverlayView not found:""")

cut_span(
'        mainVideoMaskContainer = findViewById(R.id.mainVideoMaskContainer)',
"""        } catch (e: Exception) {
            Log.w(TAG, "VideoMaskOverlayView not found: ${e.message}")
            null
        }
""")
print('   [ok] mask view initialization removed')

# --- 2f. clipChildren -------------------------------------------------------
repl("""            // Enable clipping on canvasContainer and mainVideoMaskContainer
            canvasContainer.clipChildren = true
            canvasContainer.clipToPadding = true
            mainVideoMaskContainer?.clipChildren = true
            mainVideoMaskContainer?.clipToPadding = true""",
"""            // Enable clipping on canvasContainer
            canvasContainer.clipChildren = true
            canvasContainer.clipToPadding = true""", 1, 'clipChildren')
repl('val overlays = listOf(textOverlayView, draggableTextOverlay, imageOverlayView, draggableImageOverlay, cropOverlayView, videoMaskOverlayView)',
     'val overlays = listOf(textOverlayView, draggableTextOverlay, imageOverlayView, draggableImageOverlay, cropOverlayView)',
     2, 'overlays lists')
print('   [ok] overlays + clipping cleaned')

# --- 2g. applySpeedToSegment: drop reverse preservation (BOTH branches) ----
repl("""            if (result is com.tharunbirla.librecuts.services.FFmpegRenderEngine.RenderResult.Success) {
                if (item.isReversed) {
                    showLoading("Reversing speed-adjusted video...")
                    val reverseFileName = "proxy_reverse_${System.currentTimeMillis()}.mp4"
                    val reverseFilePath = java.io.File(cacheDir, reverseFileName).absolutePath
                    val speedProxyPath = result.outputPath

                    val durationMs = ((item.trimEndMs - item.trimStartMs) / speed).toLong()
                    val reverseResult = ffmpegEngine.reverseVideo(
                        sourceFilePath = speedProxyPath,
                        startMs = 0L,
                        endMs = durationMs,
                        outputFilePath = reverseFilePath
                    )

                    hideLoading()

                    if (reverseResult is com.tharunbirla.librecuts.services.FFmpegRenderEngine.RenderResult.Success) {
                        val finalProxyUri = android.net.Uri.fromFile(java.io.File(reverseResult.outputPath))
                        if (index == 0) {
                            viewModel.updateMainVideoSpeed(speed, null)
                            viewModel.updateMainVideoReverse(isReversed = true, proxyUri = finalProxyUri)
                        } else {
                            updateVideoSegment(index, item.copy(speed = speed, proxyUri = finalProxyUri, isReversed = true))
                        }
                        hideSpeedEditingToolbar()
                    } else {
                        android.widget.Toast.makeText(this@VideoEditingActivity, R.string.toast_failed_to_reverse_speed_proxy, android.widget.Toast.LENGTH_SHORT).show()
                    }
                } else {
                    hideLoading()
                    val proxyUri = android.net.Uri.fromFile(java.io.File(result.outputPath))
                    if (index == 0) {
                        viewModel.updateMainVideoSpeed(speed, proxyUri)
                    } else {
                        updateVideoSegment(index, item.copy(speed = speed, proxyUri = proxyUri))
                    }
                    hideSpeedEditingToolbar()
                }
            } else {""",
"""            if (result is com.tharunbirla.librecuts.services.FFmpegRenderEngine.RenderResult.Success) {
                hideLoading()
                val proxyUri = android.net.Uri.fromFile(java.io.File(result.outputPath))
                if (index == 0) {
                    viewModel.updateMainVideoSpeed(speed, proxyUri)
                } else {
                    updateVideoSegment(index, item.copy(speed = speed, proxyUri = proxyUri))
                }
                hideSpeedEditingToolbar()
            } else {""", 1, 'speed apply reverse branch')
print('   [ok] speed apply no longer chains a reverse pass')

repl("""            // Reset to normal speed, but preserve reverse if it is reversed!
            if (item.isReversed) {
                lifecycleScope.launch {
                    showLoading("Resetting speed...")
                    val outputFileName = "proxy_reverse_${System.currentTimeMillis()}.mp4"
                    val outputFilePath = java.io.File(cacheDir, outputFileName).absolutePath
                    val result = ffmpegEngine.reverseVideo(
                        sourceFilePath = getFilePathFromUri(item.uri) ?: "",
                        startMs = item.trimStartMs,
                        endMs = item.trimEndMs,
                        outputFilePath = outputFilePath
                    )
                    hideLoading()
                    if (result is com.tharunbirla.librecuts.services.FFmpegRenderEngine.RenderResult.Success) {
                        val proxyUri = android.net.Uri.fromFile(java.io.File(result.outputPath))
                        if (index == 0) {
                            viewModel.updateMainVideoSpeed(1.0f, null)
                            viewModel.updateMainVideoReverse(isReversed = true, proxyUri = proxyUri)
                        } else {
                            updateVideoSegment(index, item.copy(speed = 1.0f, proxyUri = proxyUri, isReversed = true))
                        }
                        hideSpeedEditingToolbar()
                    } else {
                        android.widget.Toast.makeText(this@VideoEditingActivity, R.string.toast_failed_to_apply_speed_reset, android.widget.Toast.LENGTH_SHORT).show()
                    }
                }
            } else {
                if (index == 0) {
                    viewModel.updateMainVideoSpeed(1.0f, null)
                } else {
                    updateVideoSegment(index, item.copy(speed = 1.0f, proxyUri = null))
                }
                hideSpeedEditingToolbar()
            }""",
"""            if (index == 0) {
                viewModel.updateMainVideoSpeed(1.0f, null)
            } else {
                updateVideoSegment(index, item.copy(speed = 1.0f, proxyUri = null))
            }
            hideSpeedEditingToolbar()""", 1, 'speed reset branch')
print('   [ok] speed reset no longer preserves reverse')

# --- 2h. getSequenceItems ---------------------------------------------------
repl("""        val reverseOp = viewModel.project.value?.operations?.filterIsInstance<com.tharunbirla.librecuts.models.EditOperation.ReverseMain>()?.lastOrNull()
        val isReversed = reverseOp?.isReversed ?: false
        val proxyUri = reverseOp?.proxyUri ?: speedOp?.proxyUri
        val mirrorOp = viewModel.project.value?.operations?.filterIsInstance<com.tharunbirla.librecuts.models.EditOperation.MirrorMain>()?.lastOrNull()
        val isMirrored = mirrorOp?.isMirrored ?: false
        val maskMainOp = viewModel.project.value?.operations?.filterIsInstance<com.tharunbirla.librecuts.models.EditOperation.MaskMain>()?.lastOrNull()
        val maskConfig = maskMainOp?.maskConfig ?: com.tharunbirla.librecuts.models.EditOperation.MaskConfig()
""", '        val proxyUri = speedOp?.proxyUri\n', 1, 'getSequenceItems ops')
repl("""            speed = speed,
            isReversed = isReversed,
            isMirrored = isMirrored,
            proxyUri = proxyUri,
            scrubProxyUri = viewModel.project.value?.scrubProxyUri,
            maskConfig = maskConfig,
            isImage = isMainImg""",
"""            speed = speed,
            proxyUri = proxyUri,
            scrubProxyUri = viewModel.project.value?.scrubProxyUri,
            isImage = isMainImg""", 1, 'MergeItem ctor args')
print('   [ok] getSequenceItems simplified')

# --- 2i. syncUiWithPlayer ----------------------------------------------------
repl('            // Apply color filter corresponding to the active clip\n', '', 1, 'syncUi filter comment')
repl("""            val activeFilterName = viewModel.project.value?.operations?.filterIsInstance<com.tharunbirla.librecuts.models.EditOperation.ColorFilter>()
                ?.find { it.index == activeClipIndex }?.filterName ?: "none"
            val activeAdjust = viewModel.project.value?.operations?.filterIsInstance<com.tharunbirla.librecuts.models.EditOperation.Adjust>()
                ?.find { it.index == activeClipIndex }
            applyColorFilterAndAdjustToPlayer(activeFilterName, activeAdjust)
""", '', 1, 'syncUi filter block')

repl("""                val relTimeMs = currentGlobalPos - accumulatedStartMs
                val evaluatedMask = sequenceItems[activeClipIndex].maskConfig.evaluatedAt(relTimeMs)
                mainVideoMaskContainer?.maskConfig = evaluatedMask
""", '', 1, 'syncUi mask block')

repl("""            val isMirrored = if (activeClipIndex == 0) {
                viewModel.project.value?.operations?.any { it is com.tharunbirla.librecuts.models.EditOperation.MirrorMain && it.isMirrored } == true
            } else {
                viewModel.project.value?.operations?.filterIsInstance<com.tharunbirla.librecuts.models.EditOperation.Merge>()
                    ?.firstOrNull()?.items?.getOrNull(activeClipIndex - 1)?.isMirrored == true
            }
""", '', 1, 'syncUi mirror decl')

repl("""            val videoSurface = playerView.videoSurfaceView
            if (videoSurface != null) {
                videoSurface.scaleX = if (isMirrored) -1f else 1f
            } else {
                findTextureView(playerView)?.scaleX = if (isMirrored) -1f else 1f
            }
""", '', 1, 'syncUi mirror surface')
print('   [ok] syncUiWithPlayer: filter/adjust/mask/mirror preview removed')

# --- 2j. keyframe functions: strip mask branches ----------------------------

repl_in('    private fun showKeyframePropertyMenu(view: View) {',
"""            if (op.maskConfig.shape != EditOperation.MaskShape.NONE) {
                popup.menu.add("Mask Position")
                popup.menu.add("Mask Size")
                popup.menu.add("Mask Rotation")
                popup.menu.add("Mask Feather")
            }
""", '')
repl_in('    private fun showKeyframePropertyMenu(view: View) {',
'if (activeKeyframeProperty == "Position" || activeKeyframeProperty == "Mask Position") {',
'if (activeKeyframeProperty == "Position") {')
repl_in('    private fun showKeyframePropertyMenu(view: View) {',
"""                    "Mask Size" -> {
                        slider?.valueFrom = 1.0f
                        slider?.valueTo = 200.0f
                        slider?.stepSize = 1.0f
                    }
                    "Mask Rotation" -> {
                        slider?.valueFrom = -180.0f
                        slider?.valueTo = 180.0f
                        slider?.stepSize = 1.0f
                    }
                    "Mask Feather" -> {
                        slider?.valueFrom = 0.0f
                        slider?.valueTo = 100.0f
                        slider?.stepSize = 1.0f
                    }
""", '')

repl_in('    private fun handleKeyframeActionClick() {',
"""                        "Mask Position" -> {
                            val mc = op.maskConfig
                            val currentList = mc.positionKeyframes.toMutableList()
                            val existingIndex = currentList.indexOfFirst { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                            if (existingIndex != -1) currentList.removeAt(existingIndex) else {
                                val pos = mc.getInterpolatedPos(relativeTimeMs)
                                currentList.add(EditOperation.KeyframePoint(relativeTimeMs, pos.first, pos.second))
                            }
                            viewModel.updateOperation(op.copy(maskConfig = mc.copy(positionKeyframes = currentList)))
                        }
                        "Mask Size" -> {
                            val mc = op.maskConfig
                            val currentList = mc.sizeKeyframes.toMutableList()
                            val existingIndex = currentList.indexOfFirst { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                            if (existingIndex != -1) currentList.removeAt(existingIndex) else {
                                val sizeVal = mc.getInterpolatedSize(relativeTimeMs)
                                currentList.add(EditOperation.KeyframePoint(relativeTimeMs, sizeVal))
                            }
                            viewModel.updateOperation(op.copy(maskConfig = mc.copy(sizeKeyframes = currentList)))
                        }
                        "Mask Rotation" -> {
                            val mc = op.maskConfig
                            val currentList = mc.rotationKeyframes.toMutableList()
                            val existingIndex = currentList.indexOfFirst { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                            if (existingIndex != -1) currentList.removeAt(existingIndex) else {
                                val rotVal = mc.getInterpolatedRotation(relativeTimeMs)
                                currentList.add(EditOperation.KeyframePoint(relativeTimeMs, rotVal))
                            }
                            viewModel.updateOperation(op.copy(maskConfig = mc.copy(rotationKeyframes = currentList)))
                        }
                        "Mask Feather" -> {
                            val mc = op.maskConfig
                            val currentList = mc.featherKeyframes.toMutableList()
                            val existingIndex = currentList.indexOfFirst { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                            if (existingIndex != -1) currentList.removeAt(existingIndex) else {
                                val featherVal = mc.getInterpolatedFeather(relativeTimeMs)
                                currentList.add(EditOperation.KeyframePoint(relativeTimeMs, featherVal))
                            }
                            viewModel.updateOperation(op.copy(maskConfig = mc.copy(featherKeyframes = currentList)))
                        }
""", '')
cut_video_else('    private fun handleKeyframeActionClick() {',
               '            val index = selectedVideoIndex\n')

repl_in('    private fun handleKeyframeSliderChange(value: Float) {',
'                        val mc = op.maskConfig\n', '')
repl_in('    private fun handleKeyframeSliderChange(value: Float) {',
"""                            "Mask Size" -> {
                                val currentList = mc.sizeKeyframes.toMutableList()
                                val existingIndex = currentList.indexOfFirst { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                                val newPoint = EditOperation.KeyframePoint(relativeTimeMs, value)
                                if (existingIndex != -1) currentList[existingIndex] = newPoint else currentList.add(newPoint)
                                val relScale = value / 200f
                                val newMc = mc.copy(relativeWidth = relScale, relativeHeight = relScale, sizeKeyframes = currentList)
                                viewModel.updateOperation(op.copy(maskConfig = newMc))
                            }
                            "Mask Rotation" -> {
                                val currentList = mc.rotationKeyframes.toMutableList()
                                val existingIndex = currentList.indexOfFirst { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                                val newPoint = EditOperation.KeyframePoint(relativeTimeMs, value)
                                if (existingIndex != -1) currentList[existingIndex] = newPoint else currentList.add(newPoint)
                                val newMc = mc.copy(rotationAngle = value, rotationKeyframes = currentList)
                                viewModel.updateOperation(op.copy(maskConfig = newMc))
                            }
                            "Mask Feather" -> {
                                val currentList = mc.featherKeyframes.toMutableList()
                                val existingIndex = currentList.indexOfFirst { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                                val newPoint = EditOperation.KeyframePoint(relativeTimeMs, value)
                                if (existingIndex != -1) currentList[existingIndex] = newPoint else currentList.add(newPoint)
                                val newMc = mc.copy(feather = value, featherKeyframes = currentList)
                                viewModel.updateOperation(op.copy(maskConfig = newMc))
                            }
""", '')
cut_video_else('    private fun handleKeyframeSliderChange(value: Float) {',
               '            val videoIdx = selectedVideoIndex\n')

repl_in('    private fun updateKeyframeActionButtonState(globalTimeMs: Long) {',
"""                            "Mask Position" -> op.maskConfig.positionKeyframes.any { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                            "Mask Size" -> op.maskConfig.sizeKeyframes.any { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                            "Mask Rotation" -> op.maskConfig.rotationKeyframes.any { Math.abs(it.timeMs - relativeTimeMs) < 150L }
                            "Mask Feather" -> op.maskConfig.featherKeyframes.any { Math.abs(it.timeMs - relativeTimeMs) < 150L }
""", '')
cut_video_else('    private fun updateKeyframeActionButtonState(globalTimeMs: Long) {',
               '            val videoIdx = selectedVideoIndex\n')

repl_in('    private fun updateDraggableOverlayFromKeyframes(globalTimeMs: Long) {',
'                    val evaluatedMask = op.maskConfig.evaluatedAt(relativeTimeMs)\n', '')
repl_in('    private fun updateDraggableOverlayFromKeyframes(globalTimeMs: Long) {',
"""                    draggableImageOverlay?.maskConfig = evaluatedMask
                    draggableImageOverlay?.isMaskEditingMode = evaluatedMask.shape != EditOperation.MaskShape.NONE
""", '')
repl_in('    private fun updateDraggableOverlayFromKeyframes(globalTimeMs: Long) {',
"""                    } else if (activeKeyframeProperty == "Mask Size") {
                        val sizeVal = evaluatedMask.getInterpolatedSize(relativeTimeMs)
                        val roundedSize = Math.round(sizeVal).toFloat().coerceIn(minVal, maxVal)
                        slider?.value = roundedSize
                        tvSliderValue?.text = "${roundedSize.toInt()}%"
                    } else if (activeKeyframeProperty == "Mask Rotation") {
                        val rotVal = evaluatedMask.getInterpolatedRotation(relativeTimeMs)
                        val roundedRot = Math.round(rotVal).toFloat().coerceIn(minVal, maxVal)
                        slider?.value = roundedRot
                        tvSliderValue?.text = "${roundedRot.toInt()}\u00b0"
                    } else if (activeKeyframeProperty == "Mask Feather") {
                        val featherVal = evaluatedMask.getInterpolatedFeather(relativeTimeMs)
                        val roundedFeather = Math.round(featherVal).toFloat().coerceIn(minVal, maxVal)
                        slider?.value = roundedFeather
                        tvSliderValue?.text = "${roundedFeather.toInt()}%"
                    }""", '                    }')
cut_video_else('    private fun updateDraggableOverlayFromKeyframes(globalTimeMs: Long) {',
               '            val videoIdx = selectedVideoIndex\n')
print('   [ok] keyframe mask branches removed (Position/Opacity/Speed kept)')

# --- 2j-b. renderTracks: mask keyframe markers --------------------------------
repl("""                keyframes.addAll(op.maskConfig.positionKeyframes.map { it.timeMs })
                keyframes.addAll(op.maskConfig.sizeKeyframes.map { it.timeMs })
                keyframes.addAll(op.maskConfig.rotationKeyframes.map { it.timeMs })
                keyframes.addAll(op.maskConfig.featherKeyframes.map { it.timeMs })
""", '', 1, 'renderTracks mask keyframes')
print('   [ok] renderTracks: mask keyframe markers removed')

# --- 2k. final checks --------------------------------------------------------
if t.count('{') != t.count('}'):
    fail('brace balance broken in VideoEditingActivity.kt')
for tok in ('btnVideoFilter', 'btnVideoMask', 'btnVideoAdjust', 'btnVideoExtractAudio',
            'btnVideoReverse', 'btnVideoMirror', 'btnImageMask', 'showMaskBottomSheet',
            'showColorFilterSelectionDialog', 'showAdjustSelectionDialog',
            'reverseVideoSegment', 'extractAudioFromSegment', 'applyColorFilterToPlayer',
            'videoMaskOverlayView', 'mainVideoMaskContainer', 'isReversed',
            'updateMainVideoMirror', 'toggleMergeItemMirror', 'viewModel.setColorFilter',
            'viewModel.setAdjust', 'updateMergeItemMask', 'MaskMain', 'ReverseMain', 'MirrorMain',
            'MaskConfig', 'MaskShape', 'EditOperation.ColorFilter', 'EditOperation.Adjust',
            'lastAppliedFilterName', 'maskConfig'):
    if tok in t:
        fail('leftover token in VEA: ' + tok)
n_ftv = t.count('findTextureView')
if n_ftv != 3:
    fail('findTextureView count is %d, expected 3 (def+recursion+transition)' % n_ftv)

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] VideoEditingActivity.kt: %d -> %d lines' % (orig_lines, t.count('\n')))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 3 -- VideoEditingViewModelExt.kt
# ---------------------------------------------------------------------------
step3_ext() {
    echo "== step 3: VideoEditingViewModelExt.kt -- remove feature mutators"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt'
t = open(P, encoding='utf-8').read()
orig = t.count('\n')

def fail(m):
    print('   [FAIL] ' + m)
    sys.exit(1)

def repl(old, new, cnt=1):
    global t
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('expected %d, found %d of %r' % (cnt, c, old[:60]))

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
    global t
    i = t.find('\n' + sig)
    if i == -1:
        return False
    i += 1
    k = walk_close(t, i)
    if k == -1:
        fail('unbalanced cut: ' + sig)
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:i] + t[k:]
    return True

for sig in (
 'fun VideoEditingViewModel.updateMainVideoReverse(isReversed: Boolean, proxyUri: Uri?) {',
 'fun VideoEditingViewModel.updateMainVideoMirror(isMirrored: Boolean) {',
 'fun VideoEditingViewModel.toggleMergeItemMirror(index: Int) {',
 'fun VideoEditingViewModel.setColorFilter(index: Int, filterName: String) {',
 'fun VideoEditingViewModel.updateMergeItemMask(index: Int, maskConfig: EditOperation.MaskConfig) {',
 'fun VideoEditingViewModel.setAdjust('):
    cut_fun(sig)
print('   [ok] six mutator functions removed')

# addBackgroundAudioOperation: drop extractedFromSegmentIndex
repl('    endTimeMs: Long? = null, originalDurationMs: Long = 0L, extractedFromSegmentIndex: Int? = null,',
     '    endTimeMs: Long? = null, originalDurationMs: Long = 0L,')
repl('        endTimeMs, originalDurationMs, extractedFromSegmentIndex, beats, ducking, fadeInDurationMs, fadeOutDurationMs',
     '        endTimeMs, originalDurationMs, beats, ducking, fadeInDurationMs, fadeOutDurationMs')

# addImageOverlayOperation: drop maskConfig
repl('    opacity: Float = 1.0f, isMirrored: Boolean = false, maskConfig: EditOperation.MaskConfig = EditOperation.MaskConfig()',
     '    opacity: Float = 1.0f, isMirrored: Boolean = false')
repl('        chromaKeySimilarity, opacity, isMirrored, maskConfig = maskConfig',
     '        chromaKeySimilarity, opacity, isMirrored')

# splitVideoSegment: drop reverse/mirror/mask carry-over
repl("""            val reverseOp = newOps.filterIsInstance<EditOperation.ReverseMain>().lastOrNull()
            val mirrorOp = newOps.filterIsInstance<EditOperation.MirrorMain>().lastOrNull()
            val maskOp = newOps.filterIsInstance<EditOperation.MaskMain>().lastOrNull()
""", '')
repl("""            val isReversed = reverseOp?.isReversed ?: false
            val isMirrored = mirrorOp?.isMirrored ?: false
            val maskConfig = maskOp?.maskConfig ?: EditOperation.MaskConfig()
""", '')
repl('            val proxyUri = reverseOp?.proxyUri ?: speedOp?.proxyUri',
     '            val proxyUri = speedOp?.proxyUri')
repl('            val newItem = EditOperation.MergeItem(sourceUri, sourceDuration, trimStartMs = localSplitTimeMs, trimEndMs = oldEndMs, speed = speed, isReversed = isReversed, isMirrored = isMirrored, maskConfig = maskConfig, proxyUri = proxyUri)',
     '            val newItem = EditOperation.MergeItem(sourceUri, sourceDuration, trimStartMs = localSplitTimeMs, trimEndMs = oldEndMs, speed = speed, proxyUri = proxyUri)')

# deleteSequenceSegment: simplify removeAll + drop promotion blocks
repl('ops.removeAll { it is EditOperation.Trim || it is EditOperation.SpeedMain || it is EditOperation.ReverseMain || it is EditOperation.MirrorMain || it is EditOperation.MaskMain }',
     'ops.removeAll { it is EditOperation.Trim || it is EditOperation.SpeedMain }')
repl("""                    if (promotedItem.isReversed) {
                        ops.add(EditOperation.ReverseMain(true, promotedItem.proxyUri))
                    }
""", '')
repl("""                    if (promotedItem.isMirrored) {
                        ops.add(EditOperation.MirrorMain(true))
                    }
""", '')
repl("""                    if (promotedItem.maskConfig.shape != EditOperation.MaskShape.NONE) {
                        ops.add(EditOperation.MaskMain(promotedItem.maskConfig))
                    }
""", '')

if t.count('{') != t.count('}'):
    fail('brace balance broken in Ext')
for tok in ('ReverseMain', 'MirrorMain', 'MaskMain', 'ColorFilter', 'EditOperation.Adjust',
            'MaskConfig', 'isReversed', 'extractedFromSegmentIndex'):
    if tok in t:
        fail('leftover token in Ext: ' + tok)
for need in ('updateMainVideoTrim', 'updateMainVideoSpeed', 'addCropOperation',
             'addTextOperation', 'updateMergeItemTrim', 'addMergeOperation',
             'addTransitionOperation', 'toggleMuteClip', 'addBackgroundAudioOperation',
             'addImageOverlayOperation', 'splitVideoSegment', 'deleteSequenceSegment',
             'moveOverlayOperation', 'setScrubProxyUri'):
    if need not in t:
        fail('kept function missing in Ext: ' + need)

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] Ext: %d -> %d lines' % (orig, t.count('\n')))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 4 -- VideoEditingViewModel.kt
# ---------------------------------------------------------------------------
step4_vm() {
    echo "== step 4: VideoEditingViewModel.kt -- remove render paths"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt'
t = open(P, encoding='utf-8').read()
orig = t.count('\n')

def fail(m):
    print('   [FAIL] ' + m)
    sys.exit(1)

def repl(old, new, cnt=1):
    global t
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('expected %d, found %d of %r' % (cnt, c, old[:60]))

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
    global t
    i = t.find('\n' + sig)
    if i == -1:
        return False
    i += 1
    k = walk_close(t, i)
    if k == -1:
        fail('unbalanced cut: ' + sig)
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:i] + t[k:]
    return True

cut_fun('    private fun buildFFmpegMaskAlphaExpr(')
cut_fun('    private fun getFFmpegFilterForAdjust(op: EditOperation.Adjust): String? {')
cut_fun('    private fun getFFmpegFilterForName(name: String): String? {')
print('   [ok] three filter-builder functions removed')

# buildVideoFilterStages: image-overlay mask handling
repl('                            val hasMaskKeyframes = op.maskConfig.positionKeyframes.isNotEmpty() || op.maskConfig.sizeKeyframes.isNotEmpty() || op.maskConfig.rotationKeyframes.isNotEmpty() || op.maskConfig.featherKeyframes.isNotEmpty()\n                            if (op.opacityKeyframes.isNotEmpty() || hasMaskKeyframes) {',
     '                            if (op.opacityKeyframes.isNotEmpty()) {')

i = t.find('                        if (op.maskConfig.shape != EditOperation.MaskShape.NONE) {')
if i != -1:
    k = walk_close(t, i)
    if k == -1:
        fail('mask stage block unbalanced')
    t = t[:i] + t[k:]

repl('                        val hasMaskKfs = op.maskConfig.positionKeyframes.isNotEmpty() || op.maskConfig.sizeKeyframes.isNotEmpty() || op.maskConfig.rotationKeyframes.isNotEmpty() || op.maskConfig.featherKeyframes.isNotEmpty()\n                        val shortestPart = if (((isGif || isVideo) && op.isLooping) || (!isGif && !isVideo && (op.opacityKeyframes.isNotEmpty() || hasMaskKfs))) ":shortest=1" else ""',
     '                        val shortestPart = if (((isGif || isVideo) && op.isLooping) || (!isGif && !isVideo && op.opacityKeyframes.isNotEmpty())) ":shortest=1" else ""')

# input selection: reverse proxy no longer exists
repl("""        val reverseOp = operations.filterIsInstance<EditOperation.ReverseMain>().lastOrNull()
        val speedOp = operations.filterIsInstance<EditOperation.SpeedMain>().lastOrNull()
        val finalProxyUri = reverseOp?.proxyUri ?: speedOp?.proxyUri""",
"""        val speedOp = operations.filterIsInstance<EditOperation.SpeedMain>().lastOrNull()
        val finalProxyUri = speedOp?.proxyUri""")

# merge path per-input loop: strip filter/adjust/mirror/mask pre-filters
repl("""                val colorFilterOp = operations.filterIsInstance<EditOperation.ColorFilter>().find { it.index == i }
                val lutFilterExpr = colorFilterOp?.let { getFFmpegFilterForName(it.filterName) }
                val adjustOp = operations.filterIsInstance<EditOperation.Adjust>().find { it.index == i }
                val adjustFilterExpr = adjustOp?.let { getFFmpegFilterForAdjust(it) }
""", '')
repl("""                val isMirrored = if (i == 0) {
                    operations.any { it is EditOperation.MirrorMain && it.isMirrored }
                } else {
                    mergeOp?.items?.getOrNull(i - 1)?.isMirrored == true
                }
""", '')
repl("""                val maskConfig = if (i == 0) {
                    val mainMask = operations.filterIsInstance<EditOperation.MaskMain>().lastOrNull()?.maskConfig
                    if (mainMask != null && mainMask.shape != EditOperation.MaskShape.NONE) {
                        mainMask
                    } else {
                        mergeOp?.items?.getOrNull(0)?.maskConfig ?: EditOperation.MaskConfig()
                    }
                } else {
                    mergeOp?.items?.getOrNull(i - 1)?.maskConfig ?: EditOperation.MaskConfig()
                }
""", '')
repl("""                if (lutFilterExpr != null) preFilters += ",$lutFilterExpr"
                if (adjustFilterExpr != null) preFilters += ",$adjustFilterExpr"
                if (isMirrored) preFilters += ",hflip"
""", '')
i = t.find('                if (maskConfig.shape != EditOperation.MaskShape.NONE) {')
if i != -1:
    k = walk_close(t, i)
    if k == -1:
        fail('merge-loop mask block unbalanced')
    t = t[:i] + t[k:]
print('   [ok] merge-path pre-filters simplified to setpts only')

# non-merge path: strip lut/adjust/mirror/mask prep entirely
repl("""        val colorFilterOp = operations.filterIsInstance<EditOperation.ColorFilter>().find { it.index == 0 }
        val adjustOp = operations.filterIsInstance<EditOperation.Adjust>().find { it.index == 0 }
""", '')
repl("""        if (colorFilterOp != null) {
            val lutFilterExpr = getFFmpegFilterForName(colorFilterOp.filterName)
            if (lutFilterExpr != null) {
                prepFilters.add(lutFilterExpr)
            }
        }
""", '')
repl("""        if (adjustOp != null) {
            val adjustFilterExpr = getFFmpegFilterForAdjust(adjustOp)
            if (adjustFilterExpr != null) {
                prepFilters.add(adjustFilterExpr)
            }
        }
""", '')
repl("""        val mirrorMainOp = operations.filterIsInstance<EditOperation.MirrorMain>().find { it.isMirrored }
        if (mirrorMainOp != null) {
            prepFilters.add("hflip")
        }
""", '')
i = t.find('        val maskMainOp = operations.filterIsInstance<EditOperation.MaskMain>().lastOrNull()')
if i != -1:
    j = t.find('        if (maskMainOp != null && maskMainOp.maskConfig.shape != EditOperation.MaskShape.NONE) {', i)
    if j == -1:
        fail('non-merge mask if not found')
    k = walk_close(t, j)
    if k == -1:
        fail('non-merge mask block unbalanced')
    t = t[:i] + t[k:]
repl('        val prepFilters = mutableListOf<String>()\n', '')
repl('        val hasVideoFilters = videoStages.isNotEmpty() || prepFilters.isNotEmpty()',
     '        val hasVideoFilters = videoStages.isNotEmpty()')
i = t.find('        if (prepFilters.isNotEmpty()) {')
if i != -1:
    k = walk_close(t, i)
    if k == -1:
        fail('prepFilters if-block unbalanced')
    t = t[:i] + t[k:]
print('   [ok] non-merge path: lut/adjust/mirror/mask prep removed')

if t.count('{') != t.count('}'):
    fail('brace balance broken in ViewModel')
for tok in ('ReverseMain', 'MirrorMain', 'MaskMain', 'ColorFilter', 'EditOperation.Adjust',
            'MaskConfig', 'MaskShape', 'isReversed', 'getFFmpegFilterForName',
            'getFFmpegFilterForAdjust', 'buildFFmpegMaskAlphaExpr', 'prepFilters'):
    if tok in t:
        fail('leftover token in ViewModel: ' + tok)
for need in ('buildVideoFilterStages', 'buildConsolidatedFFmpegCommand', 'SpeedMain',
             'buildDrawtextExpr', 'buildFFmpegInterpolationExpr'):
    if need not in t:
        fail('kept symbol missing in ViewModel: ' + need)

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] ViewModel: %d -> %d lines' % (orig, t.count('\n')))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 5 -- EditOperation.kt (models)
# ---------------------------------------------------------------------------
step5_models() {
    echo "== step 5: EditOperation.kt -- remove dead operation models"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt'
t = open(P, encoding='utf-8').read()
orig = t.count('\n')

def fail(m):
    print('   [FAIL] ' + m)
    sys.exit(1)

def cut_span(start, end, repl_text):
    global t
    i = t.find(start)
    if i == -1:
        return False
    j = t.find(end, i + len(start))
    if j == -1:
        fail('end marker missing for ' + start[:50])
    t = t[:i] + repl_text + t[j + len(end):]
    return True

def repl(old, new, cnt=1):
    global t
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('expected %d, found %d of %r' % (cnt, c, old[:60]))

cut_span("""    /**
     * Reverse operation for the main video.
     */""", "    /**\n     * Mirror operation for the main video.", "    /**\n     * Mirror operation for the main video.")
cut_span("""    /**
     * Mirror operation for the main video.
     */""", "    /**\n     * Crop operation:", "    /**\n     * Crop operation:")
cut_span("    enum class MaskShape", "    data class MergeItem(", "    data class MergeItem(")
cut_span("    /** Mask configuration for the main track video base (index 0) */",
         "    /**\n     * Mute audio operation:", "    /**\n     * Mute audio operation:")
cut_span("""    /**
     * Color filter (LUT) operation: Applies a preset color grade filter to a specific clip index.
     */""", "    /**\n     * Add background audio operation:", "    /**\n     * Add background audio operation:")
cut_span("""    /**
     * Adjust operation: Adjusts video properties for a specific clip index.
     * All properties range from -100 to 100, default is 0.
     */""", "    /**\n     * Canvas background operation:", "    /**\n     * Canvas background operation:")

# MergeItem: drop isReversed / isMirrored / maskConfig
repl("""        val isReversed: Boolean = false,
        val isMirrored: Boolean = false,
        val maskConfig: MaskConfig = MaskConfig(),
        val isImage: Boolean = false""",
'        val isImage: Boolean = false')

# AddBackgroundAudio: drop extractedFromSegmentIndex
repl('        val extractedFromSegmentIndex: Int? = null,\n', '')

# AddImageOverlay: drop maskConfig
repl("""        val speedKeyframes: List<KeyframePoint> = emptyList(),
        val maskConfig: MaskConfig = MaskConfig()
    ) : EditOperation()""",
"""        val speedKeyframes: List<KeyframePoint> = emptyList()
    ) : EditOperation()""")

# id extension: drop the five dead branches
for line in ('        is EditOperation.ReverseMain -> id\n',
             '        is EditOperation.MirrorMain -> id\n',
             '        is EditOperation.MaskMain -> id\n',
             '        is EditOperation.ColorFilter -> id\n',
             '        is EditOperation.Adjust -> id\n'):
    repl(line, '')

if t.count('{') != t.count('}'):
    fail('brace balance broken in EditOperation')
for tok in ('ReverseMain', 'MirrorMain', 'MaskMain', 'ColorFilter', 'MaskConfig',
            'MaskShape', 'Adjust', 'isReversed', 'extractedFromSegmentIndex'):
    if tok in t:
        fail('leftover token in EditOperation: ' + tok)
for need in ('data class Trim(', 'data class SpeedMain(', 'data class Crop(',
             'data class AddText(', 'data class MergeItem(', 'data class Merge(',
             'data class MuteAudio(', 'data class Transition(', 'data class MuteClip(',
             'data class AddBackgroundAudio(', 'data class AddImageOverlay(',
             'data class CanvasBackground(', 'val isMirrored: Boolean = false',
             'val speedKeyframes:'):
    if need not in t:
        fail('kept model missing: ' + need)

open(P, 'w', encoding='utf-8').write(t)
print('   [ok] EditOperation: %d -> %d lines' % (orig, t.count('\n')))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 6 -- ProjectSerializer.kt + ProjectImportActivity.kt
# ---------------------------------------------------------------------------
step6_serializer() {
    echo "== step 6: serializer + import activity dead mappings"
    python3 - <<'CUTPY'
import sys

def fail(m):
    print('   [FAIL] ' + m)
    sys.exit(1)

P = 'app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt'
t = open(P, encoding='utf-8').read()

old_set = 'val validClasses = setOf("Trim", "SpeedMain", "ReverseMain", "MirrorMain", "Crop", "AddText", "Merge", "MaskMain", "MuteAudio", "Transition", "MuteClip", "ColorFilter", "AddBackgroundAudio", "AddImageOverlay", "Adjust", "CanvasBackground")'
new_set = 'val validClasses = setOf("Trim", "SpeedMain", "Crop", "AddText", "Merge", "MuteAudio", "Transition", "MuteClip", "AddBackgroundAudio", "AddImageOverlay", "CanvasBackground")'
c = t.count(old_set)
if c == 1:
    t = t.replace(old_set, new_set)
elif c == 0 and new_set in t:
    print('   [skip] validClasses already cleaned')
else:
    fail('validClasses marker count %d' % c)

for line in ('                "ReverseMain" -> EditOperation.ReverseMain::class.java\n',
             '                "MirrorMain" -> EditOperation.MirrorMain::class.java\n',
             '                "MaskMain" -> EditOperation.MaskMain::class.java\n',
             '                "ColorFilter" -> EditOperation.ColorFilter::class.java\n',
             '                "Adjust" -> EditOperation.Adjust::class.java\n'):
    c = t.count(line)
    if c == 1:
        t = t.replace(line, '')
    elif c == 0:
        pass
    else:
        fail('serializer mapping count %d for %r' % (c, line[:40]))

if t.count('{') != t.count('}'):
    fail('brace balance broken in serializer')
for tok in ('ReverseMain', 'MirrorMain', 'MaskMain', 'ColorFilter', 'EditOperation.Adjust'):
    if tok in t:
        fail('leftover token in serializer: ' + tok)
open(P, 'w', encoding='utf-8').write(t)
print('   [ok] serializer type mappings cleaned')

Q = 'app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt'
t = open(Q, encoding='utf-8').read()
old = """                    is EditOperation.ReverseMain -> {
                        if (op.proxyUri != null && !checkUriExists(op.proxyUri)) op.copy(proxyUri = null) else op
                    }
"""
if t.count(old) == 1:
    t = t.replace(old, '')
    open(Q, 'w', encoding='utf-8').write(t)
    print('   [ok] ProjectImportActivity: ReverseMain branch removed')
elif t.count(old) == 0:
    print('   [skip] ProjectImportActivity already clean')
else:
    fail('PIA branch count %d' % t.count(old))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 7 -- custom views (DraggableImageOverlayView + ImageOverlayView)
# ---------------------------------------------------------------------------
step7_views() {
    echo "== step 7: custom views -- strip mask rendering"
    python3 - <<'CUTPY'
import sys

def fail(m):
    print('   [FAIL] ' + m)
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

# ---------- DraggableImageOverlayView.kt ----------------------------------
P = 'app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt'
t = open(P, encoding='utf-8').read()
orig = t.count('\n')

def repl(old, new, cnt=1):
    global t
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('DIOV: expected %d, found %d of %r' % (cnt, c, old[:60]))

def cut_span(start, end, repl_text=''):
    global t
    i = t.find(start)
    if i == -1:
        return False
    j = t.find(end, i + len(start))
    if j == -1:
        fail('DIOV span end missing for ' + start[:50])
    t = t[:i] + repl_text + t[j + len(end):]
    return True

def cut_fun(sig):
    global t
    i = t.find('\n' + sig)
    if i == -1:
        return False
    i += 1
    k = walk_close(t, i)
    if k == -1:
        fail('DIOV unbalanced: ' + sig)
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:i] + t[k:]
    return True

repl('    var onImageCommitted: ((uri: Uri, relativeX: Float, relativeY: Float, relativeWidth: Float, relativeHeight: Float, rotationAngle: Float, opacity: Float, isMirrored: Boolean, maskConfig: com.tharunbirla.librecuts.models.EditOperation.MaskConfig) -> Unit)? = null',
     '    var onImageCommitted: ((uri: Uri, relativeX: Float, relativeY: Float, relativeWidth: Float, relativeHeight: Float, rotationAngle: Float, opacity: Float, isMirrored: Boolean) -> Unit)? = null')
repl('    var onMaskChanged: ((com.tharunbirla.librecuts.models.EditOperation.MaskConfig) -> Unit)? = null\n', '')
repl('    var isMaskEditingMode = false\n    var maskConfig = com.tharunbirla.librecuts.models.EditOperation.MaskConfig()\n', '')

repl('        visibility = VISIBLE\n        isMaskEditingMode = false\n        maskConfig = com.tharunbirla.librecuts.models.EditOperation.MaskConfig()\n',
     '        visibility = VISIBLE\n')

repl('        isMirrored = op.isMirrored\n        isMaskEditingMode = false\n        maskConfig = op.maskConfig.copy()\n',
     '        isMirrored = op.isMirrored\n')

repl('        isEditingActive = false\n        isMaskEditingMode = false\n        visibility = GONE',
     '        isEditingActive = false\n        visibility = GONE')

repl('            onImageCommitted?.invoke(uri, relativeX, relativeY, relativeWidth, relativeHeight, rotationAngle, opacity, isMirrored, maskConfig)',
     '            onImageCommitted?.invoke(uri, relativeX, relativeY, relativeWidth, relativeHeight, rotationAngle, opacity, isMirrored)')

repl("""            if (isMaskEditingMode) {
                maskConfig = maskConfig.copy(
                    relativeWidth = (maskConfig.relativeWidth * scaleFactor).coerceIn(0.01f, 5.0f),
                    relativeHeight = (maskConfig.relativeHeight * scaleFactor).coerceIn(0.01f, 5.0f)
                )
                onMaskChanged?.invoke(maskConfig)
                invalidate()
                return true
            }
""", '')

repl("""                if (!isMaskEditingMode) {
                    // round 9: the press must land on the image itself
                    // (plus room for the selection handles) -- presses on
                    // empty canvas no longer yank the overlay around.
                    val slop = 32f
                    val inX = event.x >= imageView.x - slop && event.x <= imageView.x + imageView.width + slop
                    val inY = event.y >= imageView.y - slop && event.y <= imageView.y + imageView.height + slop
                    if (!inX || !inY) return false
                }""",
"""                // round 9: the press must land on the image itself
                // (plus room for the selection handles) -- presses on
                // empty canvas no longer yank the overlay around.
                val slop = 32f
                val inX = event.x >= imageView.x - slop && event.x <= imageView.x + imageView.width + slop
                val inY = event.y >= imageView.y - slop && event.y <= imageView.y + imageView.height + slop
                if (!inX || !inY) return false""")

repl("""                isDragging = true
                if (isMaskEditingMode) {
                    dragOffsetX = event.x
                    dragOffsetY = event.y
                } else {
                    dragOffsetX = event.x - imageView.x
                    dragOffsetY = event.y - imageView.y
                }""",
"""                isDragging = true
                dragOffsetX = event.x - imageView.x
                dragOffsetY = event.y - imageView.y""")

repl("""                    if (isMaskEditingMode) {
                        val dx = event.x - dragOffsetX
                        val dy = event.y - dragOffsetY
                        dragOffsetX = event.x
                        dragOffsetY = event.y
                        if (imageView.width > 0 && imageView.height > 0) {
                            maskConfig = maskConfig.copy(
                                relativeX = maskConfig.relativeX + dx / imageView.width,
                                relativeY = maskConfig.relativeY + dy / imageView.height
                            )
                            onMaskChanged?.invoke(maskConfig)
                        }
                        invalidate()
                        return true
                    }
""", '')

cut_span('        val hasMask = maskConfig.shape != com.tharunbirla.librecuts.models.EditOperation.MaskShape.NONE',
         '        } else {\n            super.dispatchDraw(canvas)\n        }',
         '        super.dispatchDraw(canvas)')

cut_span('            if (isMaskEditingMode && hasMask) {',
         '                canvas.restore()\n            }', '')

cut_fun('    private fun createHeartPath(')
cut_fun('    private fun createStarPath(')

if t.count('{') != t.count('}'):
    fail('DIOV brace balance broken')
for tok in ('maskConfig', 'MaskConfig', 'MaskShape', 'isMaskEditingMode', 'onMaskChanged'):
    if tok in t:
        fail('DIOV leftover token: ' + tok)
for need in ('toggleMirror', 'commitImage', 'activateForEdit', 'setProperties',
             'isMirrored = op.isMirrored'):
    if need not in t:
        fail('DIOV kept symbol missing: ' + need)
open(P, 'w', encoding='utf-8').write(t)
print('   [ok] DraggableImageOverlayView: %d -> %d lines' % (orig, t.count('\n')))

# ---------- ImageOverlayView.kt --------------------------------------------
P = 'app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView.kt'
t = open(P, encoding='utf-8').read()
orig = t.count('\n')

def repl2(old, new, cnt=1):
    global t
    c = t.count(old)
    if c == cnt:
        t = t.replace(old, new)
        return True
    if c == 0 and (new in t or new == ''):
        return False
    fail('IOV: expected %d, found %d of %r' % (cnt, c, old[:60]))

def cut_span2(start, end, repl_text=''):
    global t
    i = t.find(start)
    if i == -1:
        return False
    j = t.find(end, i + len(start))
    if j == -1:
        fail('IOV span end missing for ' + start[:50])
    t = t[:i] + repl_text + t[j + len(end):]
    return True

def cut_fun2(sig):
    global t
    i = t.find('\n' + sig)
    if i == -1:
        return False
    i += 1
    k = walk_close(t, i)
    if k == -1:
        fail('IOV unbalanced: ' + sig)
    if k < len(t) and t[k] == '\n':
        k += 1
    t = t[:i] + t[k:]
    return True

cut_span2('        val relativeClipTimeMs = currentPositionMs - (op.startTimeMs ?: 0L)',
          '        if (op.isMirrored) {', '        if (op.isMirrored) {')
cut_fun2('    private fun createHeartPath(')
cut_fun2('    private fun createStarPath(')

if t.count('{') != t.count('}'):
    fail('IOV brace balance broken')
for tok in ('maskConfig', 'MaskConfig', 'MaskShape', 'relativeClipTimeMs'):
    if tok in t:
        fail('IOV leftover token: ' + tok)
for need in ('op.isMirrored', 'drawBitmap'):
    if need not in t:
        fail('IOV kept symbol missing: ' + need)
open(P, 'w', encoding='utf-8').write(t)
print('   [ok] ImageOverlayView: %d -> %d lines' % (orig, t.count('\n')))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 8 -- FFmpegRenderEngine.kt: drop reverseVideo + extractAudio
# ---------------------------------------------------------------------------
step8_engine() {
    echo "== step 8: FFmpegRenderEngine.kt -- drop reverse/extract helpers"
    python3 - <<'CUTPY'
import sys

P = 'app/src/main/java/com/tharunbirla/librecuts/services/FFmpegRenderEngine.kt'
t = open(P, encoding='utf-8').read()
orig = t.count('\n')

def fail(m):
    print('   [FAIL] ' + m)
    sys.exit(1)

def cut_lit(old):
    global t
    c = t.count(old)
    if c == 1:
        t = t.replace(old, '')
        return True
    if c == 0:
        return False
    fail('engine: count %d for %r' % (c, old[:50]))

cut_lit("""    /** Extract audio from a video file using FFmpeg. */
    suspend fun extractAudio(
        sourceFilePath: String,
        outputFilePath: String
    ): RenderResult {
        // -vn disables video stream, -acodec copy copies the audio stream.
        val command = "-y -i \\"$sourceFilePath\\" -vn -acodec copy \\"$outputFilePath\\""
        return executeCommand(command)
    }

""")

cut_lit("""    suspend fun reverseVideo(
        sourceFilePath: String,
        startMs: Long,
        endMs: Long,
        outputFilePath: String
    ): RenderResult {
        val startSecs = startMs / 1000.0
        val durationSecs = (endMs - startMs) / 1000.0
        val command = "-y -ss $startSecs -i \\"$sourceFilePath\\" -to $durationSecs -filter:v \\"reverse,format=yuv420p\\" -filter:a \\"areverse\\" -c:v libx264 -c:a aac \\"$outputFilePath\\""
        return executeCommand(command)
    }

""")

if t.count('{') != t.count('}'):
    fail('engine brace balance broken')
for tok in ('reverseVideo', 'extractAudio'):
    if tok in t:
        fail('engine leftover token: ' + tok)
for need in ('mergeVideos', 'trimVideo', 'generateSpeedProxy', 'generateScrubProxy', 'cropVideo'):
    if need not in t:
        fail('engine kept function missing: ' + need)
open(P, 'w', encoding='utf-8').write(t)
print('   [ok] engine: %d -> %d lines' % (orig, t.count('\n')))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 9 -- delete dead files + strings sweep + icon cleanup
# ---------------------------------------------------------------------------
step9_resources() {
    echo "== step 9: delete dead layouts, strings, icons"

    # 9a: dead files
    local dead=(
        app/src/main/java/com/tharunbirla/librecuts/customviews/VideoMaskOverlayView.kt
        app/src/main/java/com/tharunbirla/librecuts/customviews/MaskedFrameLayout.kt
        app/src/main/res/layout/bottom_sheet_mask.xml
        app/src/main/res/layout/dialog_color_filters.xml
        app/src/main/res/layout/item_color_filter_option.xml
        app/src/main/res/layout/dialog_adjustments.xml
        app/src/main/res/layout/item_adjust_option.xml
    )
    local f ndel=0
    for f in "${dead[@]}"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            ndel=$((ndel+1))
        fi
    done
    echo " [ok] deleted $ndel/7 dead files (views + layouts)"

    # 9b: strings sweep (9 dead keys, all locales)
    python3 - <<'CUTPY'
import glob, re, sys
import xml.dom.minidom as md

pat = re.compile(
    r'^[ \t]*<string name="(?:str_filters|str_adjust|str_extract|str_reverse|'
    r'toast_failed_to_reverse_video|toast_failed_to_restore_video_speed|'
    r'toast_audio_extracted_to_new_layer|toast_failed_to_extract_audio|'
    r'toast_failed_to_apply_speed_reset|toast_failed_to_reverse_speed_proxy)">[^\n]*</string>[ \t]*\n', re.M)

total = files = 0
for f in sorted(glob.glob('app/src/main/res/values*/strings.xml')):
    t = open(f, encoding='utf-8').read()
    t2, n = pat.subn('', t)
    if n == 0:
        continue
    md.parseString(t2)
    open(f, 'w', encoding='utf-8').write(t2)
    total += n
    files += 1
if total == 0:
    print('   [skip] no dead string keys found (already removed)')
else:
    print('   [ok] removed %d string lines across %d locale files' % (total, files))
CUTPY
    [ $? -ne 0 ] && return 1

    # 9c: dead drawables
    local icons=(
        app/src/main/res/drawable/filter_preview_contrast.jpg
        app/src/main/res/drawable/filter_preview_cool.jpg
        app/src/main/res/drawable/filter_preview_crossprocess.jpg
        app/src/main/res/drawable/filter_preview_monochrome.jpg
        app/src/main/res/drawable/filter_preview_negative.jpg
        app/src/main/res/drawable/filter_preview_none.jpg
        app/src/main/res/drawable/filter_preview_vignette.jpg
        app/src/main/res/drawable/filter_preview_vintage.jpg
        app/src/main/res/drawable/filter_preview_warm.jpg
        app/src/main/res/drawable/ic_mask_24.xml
        app/src/main/res/drawable/ic_audio_extract_24.xml
        app/src/main/res/drawable/ic_fast_rewind_24.xml
        app/src/main/res/drawable/ic_page_info_24.xml
        app/src/main/res/drawable/ic_brightness_24.xml
        app/src/main/res/drawable/ic_contrast_24.xml
        app/src/main/res/drawable/ic_warmth_24.xml
        app/src/main/res/drawable/ic_shadow_24.xml
        app/src/main/res/drawable/ic_shadows_24.xml
        app/src/main/res/drawable/ic_highlights_24.xml
        app/src/main/res/drawable/ic_saturation_24.xml
        app/src/main/res/drawable/ic_exposure_24.xml
        app/src/main/res/drawable/ic_sharpen_24.xml
        app/src/main/res/drawable/ic_vignette_24.xml
    )
    local nidel=0
    for f in "${icons[@]}"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            nidel=$((nidel+1))
        fi
    done
    echo " [ok] deleted $nidel/23 dead drawables (ic_palette_24 + ic_mirror kept)"
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 10 -- verification gate
# ---------------------------------------------------------------------------
step10_verify() {
    echo "== step 10: verification gate"

    # 10a: leftover reference scan
    local left=0 tok n
    for tok in btnVideoFilter btnVideoMask btnVideoAdjust btnVideoExtractAudio \
               btnVideoReverse btnVideoMirror btnImageMask tvVideoMirror \
               showColorFilterSelectionDialog showAdjustSelectionDialog \
               showMaskBottomSheet reverseVideoSegment regenerateSpeedProxyForUnreverse \
               extractAudioFromSegment applyColorFilterToPlayer applyColorFilterAndAdjustToPlayer \
               updateMainVideoReverse updateMainVideoMirror toggleMergeItemMirror \
               "viewModel.setColorFilter" "viewModel.setAdjust" updateMergeItemMask \
               ReverseMain MirrorMain MaskMain MaskConfig MaskShape \
               "EditOperation.ColorFilter" "EditOperation.Adjust" \
               videoMaskOverlayView mainVideoMaskContainer MaskedFrameLayout \
               VideoMaskOverlayView isReversed extractedFromSegmentIndex \
               maskConfig onMaskChanged isMaskEditingMode \
               bottom_sheet_mask dialog_color_filters dialog_adjustments \
               item_color_filter_option item_adjust_option filter_preview_ \
               ic_mask_24 ic_audio_extract_24 ic_fast_rewind_24 ic_page_info_24 \
               getFFmpegFilterForName getFFmpegFilterForAdjust buildFFmpegMaskAlphaExpr \
               reverseVideo extractAudio lastAppliedFilterName lastAppliedAdjust \
               str_filters str_adjust str_extract str_reverse \
               toast_failed_to_reverse_video toast_failed_to_restore_video_speed \
               toast_audio_extracted_to_new_layer toast_failed_to_extract_audio \
               toast_failed_to_apply_speed_reset toast_failed_to_reverse_speed_proxy; do
        n=$(grep -rn -- "$tok" app/src/main 2>/dev/null | wc -l)
        if [ "$n" -ne 0 ]; then
            echo " [FAIL] leftover reference: $tok ($n hits)"
            grep -rn -- "$tok" app/src/main 2>/dev/null | head -3
            left=1
        fi
    done
    if [ "$left" -eq 0 ]; then
        echo " [ok] zero leftover references to the six removed features"
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
di = rd('app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt')
vtb = rd('app/src/main/res/layout/video_editing_toolbar.xml')
itb = rd('app/src/main/res/layout/image_editing_toolbar.xml')
avem = rd('app/src/main/res/layout/activity_video_editing.xml')

errs = []
def need(text, tok, lo, name):
    c = text.count(tok)
    if c < lo:
        errs.append('%s: expected >=%d of %r, found %d' % (name, lo, tok, c))

need(vea, 'fun pickBackgroundImage', 1, 'VEA')
need(vea, 'findTextureView', 3, 'VEA')
need(vea, 'btnVideoFreezeFrame', 1, 'VEA')
need(vea, 'btnVideoSpeed', 1, 'VEA')
need(vea, 'btnVideoTrim', 1, 'VEA')
need(vea, 'btnVideoSplit', 1, 'VEA')
need(vea, 'btnVideoMute', 1, 'VEA')
need(vea, 'btnVideoCancel', 1, 'VEA')
need(vea, 'btnVideoDelete', 1, 'VEA')
need(vea, 'applySpeedToSegment', 1, 'VEA')
need(vea, 'freezeFrameAtCurrentPosition', 1, 'VEA')
need(vea, 'updateVideoMuteButtonState', 1, 'VEA')
need(vea, 'btnImageMirror', 1, 'VEA')
need(vea, 'showChromaKeyDialog', 1, 'VEA')
need(vea, 'popup.menu.add("Position")', 1, 'VEA')
need(vea, 'popup.menu.add("Opacity")', 1, 'VEA')
need(vea, 'popup.menu.add("Speed")', 1, 'VEA')
need(vea, 'fun interpolateKeyframes', 1, 'VEA')
need(vea, 'onImageCommitted = { uri, relX, relY, relW, relH, rotationAngle, opacity, isMirrored ->', 1, 'VEA')
need(ext, 'updateMainVideoTrim', 1, 'Ext')
need(ext, 'updateMainVideoSpeed', 1, 'Ext')
need(ext, 'splitVideoSegment', 1, 'Ext')
need(ext, 'deleteSequenceSegment', 1, 'Ext')
need(ext, 'addBackgroundAudioOperation', 1, 'Ext')
need(ext, 'addImageOverlayOperation', 1, 'Ext')
need(vm, 'buildVideoFilterStages', 1, 'VM')
need(vm, 'buildConsolidatedFFmpegCommand', 1, 'VM')
need(vm, 'EditOperation.SpeedMain', 1, 'VM')
need(eo, 'data class Trim(', 1, 'EO')
need(eo, 'data class SpeedMain(', 1, 'EO')
need(eo, 'data class Crop(', 1, 'EO')
need(eo, 'data class AddText(', 1, 'EO')
need(eo, 'data class MergeItem(', 1, 'EO')
need(eo, 'data class Merge(', 1, 'EO')
need(eo, 'data class MuteAudio(', 1, 'EO')
need(eo, 'data class Transition(', 1, 'EO')
need(eo, 'data class MuteClip(', 1, 'EO')
need(eo, 'data class AddBackgroundAudio(', 1, 'EO')
need(eo, 'data class AddImageOverlay(', 1, 'EO')
need(eo, 'data class CanvasBackground(', 1, 'EO')
need(eo, 'val isMirrored: Boolean = false', 1, 'EO')
need(di, 'fun toggleMirror()', 1, 'DIOV')
need(vtb, 'btnVideoFreezeFrame', 1, 'toolbar')
need(vtb, 'btnVideoSpeed', 1, 'toolbar')
need(vtb, 'btnVideoMute', 1, 'toolbar')
need(vtb, 'btnVideoTrim', 1, 'toolbar')
need(vtb, 'btnVideoSplit', 1, 'toolbar')
need(vtb, 'btnVideoCancel', 1, 'toolbar')
need(vtb, 'btnVideoDelete', 1, 'toolbar')
need(itb, 'btnImageMirror', 1, 'image-toolbar')
need(itb, 'btnImageChromaKey', 1, 'image-toolbar')
need(itb, 'ic_mirror', 1, 'image-toolbar')
need(avem, '<FrameLayout', 1, 'main-layout')
need(rd('app/src/main/res/layout/text_editing_toolbar.xml'), 'ic_palette_24', 1, 'text-toolbar')

if errs:
    for e in errs:
        print(' [FAIL] survival: ' + e)
    sys.exit(1)
print(' [ok] all kept-feature survival checks passed')
CUTPY

    # 10c: function-inventory guard vs git HEAD
    inv_check() {
        local f="$1" exp_rm="$2"
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
        python3 - "$tmp" "$f" "$exp_rm" <<'CUTPY'
import re, sys
head, work, exp_rm = sys.argv[1], sys.argv[2], sys.argv[3]

def inv(p):
    t = open(p, encoding='utf-8').read()
    names = set()
    for m in re.finditer(r'^\s*(?:(?:private|internal|public|suspend|override)\s+)*fun\s+([A-Za-z0-9_.]+?)\s*\(', t, re.M):
        names.add(m.group(1).split('.')[-1])
    return names

h, w = inv(head), inv(work)
rm, add = h - w, w - h
erm = set(x for x in exp_rm.split(',') if x)
bad = []
if rm != erm:
    bad.append('removed=%s expected=%s' % (sorted(rm), sorted(erm)))
if add:
    bad.append('added=%s' % sorted(add))
if bad:
    print(' [FAIL] function inventory drift in %s: %s' % (work, '; '.join(bad)))
    sys.exit(1)
print(' [ok] inventory intact: %s (removed %d)' % (work.split('/')[-1], len(erm)))
CUTPY
        local rc=$?
        rm -f "$tmp"
        [ $rc -ne 0 ] && return 1
        return 0
    }
    inv_check "$VEA" "reverseVideoSegment,regenerateSpeedProxyForUnreverse,extractAudioFromSegment,showColorFilterSelectionDialog,showAdjustSelectionDialog,showMaskBottomSheet,applyColorFilterToPlayer,applyColorFilterAndAdjustToPlayer,getValForOption,updateSliderForSelection,highlightShape,applyMaskToView,updateMaskShape" || return 1
    inv_check "$EXT" "updateMainVideoReverse,updateMainVideoMirror,toggleMergeItemMirror,setColorFilter,updateMergeItemMask,setAdjust" || return 1
    inv_check "$VM" "buildFFmpegMaskAlphaExpr,getFFmpegFilterForAdjust,getFFmpegFilterForName" || return 1
    inv_check "$EO" "getInterpolatedPos,getInterpolatedSize,getInterpolatedRotation,getInterpolatedFeather,evaluatedAt,isDefault" || return 1
    inv_check "$DIOV" "createHeartPath,createStarPath" || return 1
    inv_check "app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView.kt" "createHeartPath,createStarPath" || return 1
    inv_check "$FRE" "extractAudio,reverseVideo" || return 1
    inv_check "$PIA" "" || return 1

    # 10d: brace-balance DELTA vs git HEAD (pre-existing deltas tolerated)
    python3 - <<'CUTPY' || return 1
import subprocess, sys
files = [
 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt',
 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt',
 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt',
 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt',
 'app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt',
 'app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt',
 'app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt',
 'app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView.kt',
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
files = ['app/src/main/res/layout/video_editing_toolbar.xml',
         'app/src/main/res/layout/image_editing_toolbar.xml',
         'app/src/main/res/layout/activity_video_editing.xml']
files += sorted(glob.glob('app/src/main/res/values*/strings.xml'))
for f in files:
    md.parse(f)
print(' [ok] %d XML files parse cleanly' % len(files))
CUTPY

    # 10f: scope gate
    local bad
    bad=$(git status --porcelain 2>/dev/null | cut -c4- | grep -Ev \
'^(scripts/apply-changes\.sh|app/src/main/res/layout/(video_editing_toolbar|image_editing_toolbar|activity_video_editing)\.xml|app/src/main/java/com/tharunbirla/librecuts/(VideoEditingActivity|ProjectImportActivity)\.kt|app/src/main/java/com/tharunbirla/librecuts/(viewmodels/VideoEditingViewModelExt|viewmodels/VideoEditingViewModel|models/EditOperation|utils/ProjectSerializer|services/FFmpegRenderEngine)\.kt|app/src/main/java/com/tharunbirla/librecuts/customviews/(DraggableImageOverlayView|ImageOverlayView|VideoMaskOverlayView|MaskedFrameLayout)\.kt|app/src/main/res/layout/(bottom_sheet_mask|dialog_color_filters|item_color_filter_option|dialog_adjustments|item_adjust_option)\.xml|app/src/main/res/drawable/(filter_preview_[a-z]+\.jpg|ic_(mask|audio_extract|fast_rewind|page_info|brightness|contrast|warmth|shadows?|highlights|saturation|exposure|sharpen|vignette)_24\.xml)|app/src/main/res/values[^/]*/strings\.xml)$' || true)
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
echo " Cutloss phase 7 -- remove Filter, Adjust, Mask, Reverse,"
echo " Mirror and Extract from the video toolbar (all code)"
echo "=========================================================="
step0_preconditions || FAILED=1
step1_toolbars     || FAILED=1
step2_vea          || FAILED=1
step3_ext          || FAILED=1
step4_vm           || FAILED=1
step5_models       || FAILED=1
step6_serializer   || FAILED=1
step7_views        || FAILED=1
step8_engine       || FAILED=1
step9_resources    || FAILED=1
step10_verify      || FAILED=1

echo "----------------------------------------------------------"
echo " line counts: VEA $(wc -l < "$VEA" 2>/dev/null) | Ext $(wc -l < "$EXT" 2>/dev/null) | VM $(wc -l < "$VM" 2>/dev/null) | EO $(wc -l < "$EO" 2>/dev/null)"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 7 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 7 complete. Steps ok or skipped."
echo "  The video toolbar now shows only: Cancel, Trim, Split,"
echo "  Mute, Speed, Freeze, Delete. All six removed features"
echo "  are gone down to their models, serializers, render"
echo "  paths, icons and translated strings."
echo "  Image-overlay mirror + chroma key + text palette stay."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
