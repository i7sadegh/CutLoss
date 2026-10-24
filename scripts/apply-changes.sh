#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 10 -- overlay toolbar: drop Duplicate / Mirror / Chroma Key,
#             add a Scale slider for the overlay size
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  What this phase does:
#    1. Overlay (image/video overlay) editing toolbar:
#       removes the Duplicate, Mirror and Chroma Key buttons and every
#       line of their feature code (activity wiring, chroma bottom
#       sheet, chroma bitmap processing in both overlay views, the
#       hflip / colorkey FFmpeg stages, and the chromaKeyColor /
#       chromaKeySimilarity / isMirrored model fields).
#       The Text tool keeps its own Duplicate button (it shares the
#       duplicateSelectedOverlay helper, which becomes text-only).
#    2. New Scale control, built exactly like the Opacity control:
#       a "Scale" button in the overlay toolbar opens a slider row
#       (5..500 percent of the video width) that grows / shrinks the
#       overlay item live, same range as the two-finger pinch zoom.
#       A new ic_resize_24 drawable (Material open-in-full arrows)
#       is added for the button.
#    3. Version bump (intentionally NOT idempotent): every run
#       advances the default versionCode by +1 and the versionName
#       beta number by +1 in app/build.gradle, so each CI build
#       installs over the previous one (phase-9 debug key stays).
#    4. Defensive carry-overs from phase 9: stable debug keystore +
#       signingConfigs are verified present; the workflow push
#       trigger is verified ("branches: [main]") and the known typo
#       variant is repaired if it ever reappears.
#
#  Verification gate (fails BEFORE the workflow commits anything):
#    leftover scan (no chroma / mirror / hflip / colorkey / image
#    duplicate references anywhere), survival + new-feature asserts
#    (opacity, rotation, loop, keyframes, delete, done, cancel, text
#    duplicate, custom color picker all intact; scale wiring present),
#    XML parse of the touched layout + new icon, brace + paren
#    balance for all six touched Kotlin files, R.id cross-check
#    against every layout/xml resource, gradle version + signing
#    asserts, scope gate, untracked-file policy, ASCII self-check.
#
#  Idempotent: every step checks its own post-state first -- EXCEPT
#  the version bump, which advances by exactly 1 on every run by
#  design (each pipeline run produces one installable-over APK).
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

IET="app/src/main/res/layout/image_editing_toolbar.xml"
TET="app/src/main/res/layout/text_editing_toolbar.xml"
RESIZE="app/src/main/res/drawable/ic_resize_24.xml"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
DIOV="app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt"
IOV="app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView.kt"
EO="app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VMX="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt"
GRADLE="app/build.gradle"
YML=".github/workflows/apply-and-build.yml"
CHROMA_LAYOUT="app/src/main/res/layout/chroma_key_bottom_sheet_dialog.xml"
ICMIRROR="app/src/main/res/drawable/ic_mirror.xml"
ICLENS="app/src/main/res/drawable/ic_color_lens_24.xml"
SELF="scripts/apply-changes.sh"
FAILED=0
NEW_VC=""
NEW_BETA=""

# ---------------------------------------------------------------------------
#  STEP 0 -- preconditions
# ---------------------------------------------------------------------------
step0_preconditions() {
    echo "== step 0: preconditions"
    local ok=1 f t
    for f in "$IET" "$TET" "$VEA" "$DIOV" "$IOV" "$EO" "$VM" "$VMX" \
             "$GRADLE" "$YML"; do
        if [ ! -f "$f" ]; then
            echo " [FAIL] missing file: $f"
            ok=0
        fi
    done
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo " [FAIL] not inside a git repository"
        ok=0
    fi
    for t in python3 sed grep git; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo " [FAIL] required tool missing: $t"
            ok=0
        fi
    done
    # phase-9 base markers: committed debug key + signing + new icon
    if [ ! -f app/debug.keystore ]; then
        echo " [FAIL] app/debug.keystore missing -- phase 9 not applied (wrong base)"
        ok=0
    fi
    if ! grep -q 'signingConfigs {' "$GRADLE"; then
        echo " [FAIL] signingConfigs missing from build.gradle -- phase 9 not applied"
        ok=0
    fi
    if ! grep -q 'M 265,215 L 265,297 L 335,256 Z' app/src/main/res/drawable/ic_launcher_foreground.xml 2>/dev/null; then
        echo " [FAIL] phase-9 launcher icon not present -- wrong base"
        ok=0
    fi
    # the overlay toolbar must be fresh phase-9 or already phase-10
    if grep -q 'btnImageScale' "$IET" 2>/dev/null; then
        echo " [ok] phase-10 toolbar detected (re-run)"
    elif grep -q 'btnImageDuplicate' "$IET" 2>/dev/null; then
        echo " [ok] fresh phase-9 toolbar detected"
    else
        echo " [FAIL] $IET is neither fresh phase-9 nor phase-10 state"
        ok=0
    fi
    # the chroma dialog must exist on a fresh base (it gets deleted)
    if grep -q 'btnImageScale' "$IET" 2>/dev/null; then
        : # phase-10 re-run: dialog already gone
    elif [ ! -f "$CHROMA_LAYOUT" ]; then
        echo " [FAIL] $CHROMA_LAYOUT missing on a fresh base -- unexpected"
        ok=0
    fi
    [ "$ok" -eq 1 ] && echo " [ok] repo state matches the expected phase-9 base"
    [ "$ok" -eq 1 ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 1 -- image_editing_toolbar.xml: drop 3 buttons, add Scale controls
# ---------------------------------------------------------------------------
step1_toolbar_layout() {
    echo "== step 1: overlay toolbar -- remove Duplicate/Mirror/Chroma Key, add Scale"
    if grep -q 'btnImageScale' "$IET" 2>/dev/null; then
        echo " [skip] toolbar already carries the Scale controls"
        return 0
    fi
    python3 - <<'P10A' || return 1
import sys
p = 'app/src/main/res/layout/image_editing_toolbar.xml'
t = open(p, encoding='utf-8').read()
if 'btnImageScale' in t:
    print(' [skip] already applied')
    sys.exit(0)
for tok in ('btnImageDuplicate', 'btnImageMirrorContainer', 'btnImageChromaKeyContainer'):
    if tok not in t:
        print(' [FAIL] fresh-base marker missing: ' + tok)
        sys.exit(1)

# 1) cut the Duplicate / Mirror / Chroma Key button blocks
dup = t.find('        <!-- Duplicate -->')
opa = t.find('        <!-- Opacity -->')
if dup < 0 or opa < 0 or opa < dup:
    print(' [FAIL] button-block anchors not found')
    sys.exit(1)
t = t[:dup] + t[opa:]

# 2) insert the Scale slider row right after the opacity slider row
anchor_row = (
    '        <TextView\n'
    '            android:id="@+id/tvImageOpacityValue"\n'
    '            android:layout_width="40dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:gravity="end"\n'
    '            android:text="@string/str_100"\n'
    '            android:textColor="@color/textColor"\n'
    '            android:textSize="14sp"\n'
    '            android:fontFamily="sans-serif-medium" />\n'
    '    </LinearLayout>\n'
)
scale_row = (
    '\n'
    '    <!-- Scale Slider Row -->\n'
    '    <LinearLayout\n'
    '        android:id="@+id/imageScaleSliderRow"\n'
    '        android:layout_width="match_parent"\n'
    '        android:layout_height="56dp"\n'
    '        android:layout_marginHorizontal="16dp"\n'
    '        android:layout_marginTop="8dp"\n'
    '        android:layout_marginBottom="8dp"\n'
    '        android:orientation="horizontal"\n'
    '        android:gravity="center_vertical"\n'
    '        android:background="@drawable/bg_bottom_nav_floating"\n'
    '        android:paddingHorizontal="16dp"\n'
    '        android:elevation="12dp"\n'
    '        android:visibility="gone">\n'
    '\n'
    '        <ImageView\n'
    '            android:layout_width="24dp"\n'
    '            android:layout_height="24dp"\n'
    '            android:src="@drawable/ic_resize_24"\n'
    '            app:tint="@color/iconSecondary" />\n'
    '\n'
    '        <com.google.android.material.slider.Slider\n'
    '            android:id="@+id/imageScaleSlider"\n'
    '            android:layout_width="0dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:layout_weight="1"\n'
    '            android:valueFrom="5.0"\n'
    '            android:valueTo="500.0"\n'
    '            android:value="30.0"\n'
    '            android:stepSize="1.0"\n'
    '            app:thumbColor="@color/colorPrimary"\n'
    '            app:trackColorActive="@color/colorPrimary" />\n'
    '\n'
    '        <TextView\n'
    '            android:id="@+id/tvImageScaleValue"\n'
    '            android:layout_width="48dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:gravity="end"\n'
    '            android:text="30%"\n'
    '            android:textColor="@color/textColor"\n'
    '            android:textSize="14sp"\n'
    '            android:fontFamily="sans-serif-medium" />\n'
    '    </LinearLayout>\n'
)
if t.count(anchor_row) != 1:
    print(' [FAIL] opacity slider row anchor not found exactly once')
    sys.exit(1)
t = t.replace(anchor_row, anchor_row + scale_row, 1)

# 3) insert the Scale button right after the Opacity button
anchor_btn = (
    '            <TextView\n'
    '                android:id="@+id/tvImageOpacity"\n'
    '                android:layout_width="wrap_content"\n'
    '                android:layout_height="wrap_content"\n'
    '                android:layout_marginTop="4dp"\n'
    '                android:text="@string/str_opacity"\n'
    '                android:textSize="11sp"\n'
    '                android:fontFamily="sans-serif-medium"\n'
    '                android:textColor="@color/toolTextInactive"/>\n'
    '        </LinearLayout>\n'
)
scale_btn = (
    '\n'
    '        <!-- Scale -->\n'
    '        <LinearLayout\n'
    '            android:id="@+id/btnImageScaleContainer"\n'
    '            android:layout_width="60dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:orientation="vertical"\n'
    '            android:gravity="center">\n'
    '            <ImageButton\n'
    '                android:id="@+id/btnImageScale"\n'
    '                android:layout_width="40dp"\n'
    '                android:layout_height="40dp"\n'
    '                android:background="@drawable/tool_button_inactive"\n'
    '                android:src="@drawable/ic_resize_24"\n'
    '                android:padding="8dp"\n'
    '                android:scaleType="fitCenter"\n'
    '                app:tint="@color/toolTextInactive" />\n'
    '            <TextView\n'
    '                android:id="@+id/tvImageScale"\n'
    '                android:layout_width="wrap_content"\n'
    '                android:layout_height="wrap_content"\n'
    '                android:layout_marginTop="4dp"\n'
    '                android:text="Scale"\n'
    '                android:textSize="11sp"\n'
    '                android:fontFamily="sans-serif-medium"\n'
    '                android:textColor="@color/toolTextInactive"/>\n'
    '        </LinearLayout>\n'
)
if t.count(anchor_btn) != 1:
    print(' [FAIL] opacity button anchor not found exactly once')
    sys.exit(1)
t = t.replace(anchor_btn, anchor_btn + scale_btn, 1)

open(p, 'w', encoding='utf-8').write(t)
for tok in ('btnImageScale', 'imageScaleSliderRow', 'imageScaleSlider',
            'tvImageScaleValue', 'ic_resize_24', 'valueTo="500.0"'):
    if tok not in t:
        print(' [FAIL] post-state token missing: ' + tok)
        sys.exit(1)
for tok in ('btnImageDuplicate', 'btnImageMirror', 'btnImageChromaKey',
            'tvImageMirror', 'tvImageChromaKey', 'str_duplicate',
            'ic_copy_24', 'ic_mirror', 'ic_color_lens_24'):
    if tok in t:
        print(' [FAIL] leftover token still present: ' + tok)
        sys.exit(1)
print(' [ok] toolbar: 3 buttons removed, Scale slider + button added')
P10A
}

# ---------------------------------------------------------------------------
#  STEP 2 -- new drawable: ic_resize_24 (Material open-in-full arrows)
# ---------------------------------------------------------------------------
step2_resize_icon() {
    echo "== step 2: create drawable/ic_resize_24.xml"
    if [ -f "$RESIZE" ]; then
        echo " [skip] ic_resize_24.xml already exists"
        return 0
    fi
    cat > "$RESIZE" <<'ICONXML'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="@android:color/white"
        android:pathData="M21,11V3h-8l3.29,3.29-10,10L3,13v8h8l-3.29-3.29,10-10z"/>
</vector>
ICONXML
    if grep -q 'M21,11V3h-8l3.29,3.29-10,10L3,13v8h8l-3.29-3.29,10-10z' "$RESIZE"; then
        echo " [ok] ic_resize_24.xml written (two diagonal outward arrows)"
        return 0
    fi
    echo " [FAIL] ic_resize_24.xml write did not land"
    return 1
}

# ---------------------------------------------------------------------------
#  STEP 3 -- VideoEditingActivity.kt: rewire toolbar, drop feature code
# ---------------------------------------------------------------------------
step3_activity() {
    echo "== step 3: VideoEditingActivity.kt -- scale wiring + feature removal"
    python3 - <<'P10B' || return 1
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
t = open(p, encoding='utf-8').read()
if 'R.id.btnImageScale' in t and 'showChromaKeyDialog' not in t:
    print(' [skip] activity already carries phase-10 wiring')
    sys.exit(0)
fresh = ('R.id.btnImageDuplicate' in t and 'showChromaKeyDialog' in t
         and 'toggleMirror' in t and 'chromaKeyColor' in t)
if not fresh:
    print(' [FAIL] activity is neither fresh phase-9 nor phase-10 state')
    sys.exit(1)

def rep(old, new, name, cnt=1):
    global t
    c = t.count(old)
    if c != cnt:
        print(' [FAIL] %s: expected %d match(es), found %d' % (name, cnt, c))
        sys.exit(1)
    t = t.replace(old, new)

# 3.1 replace the Duplicate / Mirror / Chroma Key wirings with the Scale toggle
old = (
    '                toolbar.findViewById<View>(R.id.btnImageDuplicate)?.setBounceClickListener {\n'
    '                    duplicateSelectedOverlay()\n'
    '                }\n'
    '                toolbar.findViewById<View>(R.id.btnImageMirror)?.setBounceClickListener {\n'
    '                    draggableImageOverlay?.toggleMirror()\n'
    '                }\n'
    '                toolbar.findViewById<View>(R.id.btnImageChromaKey)?.setBounceClickListener {\n'
    '                    showChromaKeyDialog()\n'
    '                }\n'
)
new = (
    '                toolbar.findViewById<View>(R.id.btnImageScale)?.setBounceClickListener {\n'
    '                    val scaleRow = toolbar.findViewById<View>(R.id.imageScaleSliderRow)\n'
    '                    val opacityRow = toolbar.findViewById<View>(R.id.imageOpacitySliderRow)\n'
    '                    val rotationRow = toolbar.findViewById<View>(R.id.imageRotationSliderRow)\n'
    '                    if (scaleRow?.visibility == View.VISIBLE) {\n'
    '                        scaleRow.visibility = View.GONE\n'
    '                        rotationRow?.visibility = View.VISIBLE\n'
    '                        toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageScale)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this@VideoEditingActivity, R.color.toolTextInactive))\n'
    '                    } else {\n'
    '                        scaleRow?.visibility = View.VISIBLE\n'
    '                        opacityRow?.visibility = View.GONE\n'
    '                        rotationRow?.visibility = View.GONE\n'
    '                        toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageScale)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this@VideoEditingActivity, R.color.colorPrimary))\n'
    '                    }\n'
    '                }\n'
)
rep(old, new, 'scale toggle wiring replaces the 3 removed wirings')

# 3.2 opacity toggle: also hide the scale row when opening
old = (
    '                toolbar.findViewById<View>(R.id.btnImageOpacity)?.setBounceClickListener {\n'
    '                    val opacityRow = toolbar.findViewById<View>(R.id.imageOpacitySliderRow)\n'
    '                    val rotationRow = toolbar.findViewById<View>(R.id.imageRotationSliderRow)\n'
    '                    if (opacityRow?.visibility == View.VISIBLE) {\n'
    '                        opacityRow.visibility = View.GONE\n'
    '                        rotationRow?.visibility = View.VISIBLE\n'
    '                        toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageOpacity)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this@VideoEditingActivity, R.color.toolTextInactive))\n'
    '                    } else {\n'
    '                        opacityRow?.visibility = View.VISIBLE\n'
    '                        rotationRow?.visibility = View.GONE\n'
    '                        toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageOpacity)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this@VideoEditingActivity, R.color.colorPrimary))\n'
    '                    }\n'
    '                }\n'
)
new = (
    '                toolbar.findViewById<View>(R.id.btnImageOpacity)?.setBounceClickListener {\n'
    '                    val opacityRow = toolbar.findViewById<View>(R.id.imageOpacitySliderRow)\n'
    '                    val rotationRow = toolbar.findViewById<View>(R.id.imageRotationSliderRow)\n'
    '                    val scaleRow = toolbar.findViewById<View>(R.id.imageScaleSliderRow)\n'
    '                    if (opacityRow?.visibility == View.VISIBLE) {\n'
    '                        opacityRow.visibility = View.GONE\n'
    '                        rotationRow?.visibility = View.VISIBLE\n'
    '                        toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageOpacity)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this@VideoEditingActivity, R.color.toolTextInactive))\n'
    '                    } else {\n'
    '                        opacityRow?.visibility = View.VISIBLE\n'
    '                        rotationRow?.visibility = View.GONE\n'
    '                        scaleRow?.visibility = View.GONE\n'
    '                        toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageOpacity)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this@VideoEditingActivity, R.color.colorPrimary))\n'
    '                    }\n'
    '                }\n'
)
rep(old, new, 'opacity toggle also hides the scale row')

# 3.3 scale slider listener, modeled on the opacity slider listener
anchor = (
    '                val opacitySlider = toolbar.findViewById<Slider>(R.id.imageOpacitySlider)\n'
    '                val tvOpacityValue = toolbar.findViewById<TextView>(R.id.tvImageOpacityValue)\n'
    '                opacitySlider?.addOnChangeListener { _, value, _ ->\n'
    '                    tvOpacityValue?.text = "${value.toInt()}%"\n'
    '                    draggableImageOverlay?.setOpacity(value / 100f)\n'
    '                }\n'
)
insert = (
    '\n'
    '                val scaleSlider = toolbar.findViewById<Slider>(R.id.imageScaleSlider)\n'
    '                val tvScaleValue = toolbar.findViewById<TextView>(R.id.tvImageScaleValue)\n'
    '                scaleSlider?.addOnChangeListener { _, value, _ ->\n'
    '                    tvScaleValue?.text = "${value.toInt()}%"\n'
    '                    draggableImageOverlay?.setScaleWidth(value / 100f)\n'
    '                }\n'
)
rep(anchor, anchor + insert, 'scale slider listener inserted')

# 3.4 onImageCommitted: drop the isMirrored lambda parameter
rep('overlay.onImageCommitted = { uri, relX, relY, relW, relH, rotationAngle, opacity, isMirrored ->',
    'overlay.onImageCommitted = { uri, relX, relY, relW, relH, rotationAngle, opacity ->',
    'onImageCommitted lambda signature')

# 3.5 drop isMirrored from the updateOperation copy
rep('rotationAngle = rotationAngle, opacity = opacity, isMirrored = isMirrored\n',
    'rotationAngle = rotationAngle, opacity = opacity\n',
    'updateOperation copy without isMirrored')

# 3.6 drop the chroma capture lines before addImageOverlayOperation
rep('                            val chromaColor = draggableImageOverlay?.currentChromaColor\n'
    '                            val chromaSim = draggableImageOverlay?.currentChromaSimilarity ?: 0.1f\n',
    '',
    'chroma capture lines removed')

# 3.7 drop chroma + mirror args from the addImageOverlayOperation call
rep('                                chromaKeyColor = chromaColor,\n'
    '                                chromaKeySimilarity = chromaSim,\n'
    '                                opacity = opacity,\n'
    '                                isMirrored = isMirrored\n',
    '                                opacity = opacity\n',
    'addImageOverlayOperation call slimmed')

# 3.8 duplicateSelectedOverlay becomes text-only (text toolbar keeps it)
old = (
    '    private fun duplicateSelectedOverlay() {\n'
    '        val selectedId = viewModel.selectedOperationId.value ?: return\n'
    '        val currentProject = viewModel.project.value ?: return\n'
    '        val op = currentProject.operations.find {\n'
    '            when (it) {\n'
    '                is EditOperation.AddText -> it.id == selectedId\n'
    '                is EditOperation.AddImageOverlay -> it.id == selectedId\n'
    '                else -> false\n'
    '            }\n'
    '        } ?: return\n'
    '\n'
    '        val newOp = when (op) {\n'
    '            is EditOperation.AddText -> {\n'
    '                val newX = ((op.relativeX ?: 0.5f) + 0.05f).coerceIn(0f, 1f)\n'
    '                val newY = ((op.relativeY ?: 0.5f) + 0.05f).coerceIn(0f, 1f)\n'
    '                op.copy(\n'
    '                    id = System.nanoTime().toString(),\n'
    '                    relativeX = newX,\n'
    '                    relativeY = newY\n'
    '                )\n'
    '            }\n'
    '            is EditOperation.AddImageOverlay -> {\n'
    '                val newX = (op.relativeX + 0.05f).coerceIn(0f, 1f)\n'
    '                val newY = (op.relativeY + 0.05f).coerceIn(0f, 1f)\n'
    '                op.copy(\n'
    '                    id = System.nanoTime().toString(),\n'
    '                    relativeX = newX,\n'
    '                    relativeY = newY\n'
    '                )\n'
    '            }\n'
    '            else -> null\n'
    '        }\n'
    '\n'
    '        val newOpId = when (newOp) {\n'
    '            is EditOperation.AddText -> newOp.id\n'
    '            is EditOperation.AddImageOverlay -> newOp.id\n'
    '            else -> null\n'
    '        }\n'
    '\n'
    '        if (newOp != null && newOpId != null) {\n'
    '            viewModel.addOperation(newOp)\n'
    '            viewModel.selectOperation(newOpId)\n'
    '        }\n'
    '    }\n'
)
new = (
    '    private fun duplicateSelectedOverlay() {\n'
    '        val selectedId = viewModel.selectedOperationId.value ?: return\n'
    '        val currentProject = viewModel.project.value ?: return\n'
    '        val textOp = currentProject.operations.find {\n'
    '            (it as? EditOperation.AddText)?.id == selectedId\n'
    '        } as? EditOperation.AddText ?: return\n'
    '\n'
    '        val newX = ((textOp.relativeX ?: 0.5f) + 0.05f).coerceIn(0f, 1f)\n'
    '        val newY = ((textOp.relativeY ?: 0.5f) + 0.05f).coerceIn(0f, 1f)\n'
    '        val newOp = textOp.copy(\n'
    '            id = System.nanoTime().toString(),\n'
    '            relativeX = newX,\n'
    '            relativeY = newY\n'
    '        )\n'
    '        viewModel.addOperation(newOp)\n'
    '        viewModel.selectOperation(newOp.id)\n'
    '    }\n'
)
rep(old, new, 'duplicateSelectedOverlay is now text-only')

# 3.9 remove showChromaKeyDialog entirely
a = t.find('    private fun showChromaKeyDialog() {')
b = t.find('    private fun showCustomColorPicker(')
if a < 0 or b < 0 or b < a:
    print(' [FAIL] showChromaKeyDialog cut anchors not found')
    sys.exit(1)
t = t[:a] + t[b:]

# 3.10 keyframe tick: setProperties without the mirror argument
rep('                        interpolatedOpacity,\n'
    '                        op.isMirrored\n'
    '                    )\n',
    '                        interpolatedOpacity\n'
    '                    )\n',
    'keyframe setProperties call without mirror')

# 3.11 enterImageEditingMode: reset the scale slider (fresh overlay)
anchor = (
    '            val opacitySlider = toolbar.findViewById<Slider>(R.id.imageOpacitySlider)\n'
    '            val tvOpacityValue = toolbar.findViewById<TextView>(R.id.tvImageOpacityValue)\n'
    '            opacitySlider?.value = 100f\n'
    '            tvOpacityValue?.text = "100%"\n'
)
insert = (
    '\n'
    '            val scaleSlider = toolbar.findViewById<Slider>(R.id.imageScaleSlider)\n'
    '            val tvScaleValue = toolbar.findViewById<TextView>(R.id.tvImageScaleValue)\n'
    '            scaleSlider?.value = 30f\n'
    '            tvScaleValue?.text = "30%"\n'
)
rep(anchor, anchor + insert, 'enterImageEditingMode scale reset')

# 3.12 enterImageEditingModeForEdit: scale slider from the stored width
anchor = (
    '            val opacitySlider = toolbar.findViewById<Slider>(R.id.imageOpacitySlider)\n'
    '            val tvOpacityValue = toolbar.findViewById<TextView>(R.id.tvImageOpacityValue)\n'
    '            val currentOpacity = ((op?.opacity ?: 1.0f) * 100f).coerceIn(0f, 100f)\n'
    '            opacitySlider?.value = currentOpacity\n'
    '            tvOpacityValue?.text = "${currentOpacity.toInt()}%"\n'
)
insert = (
    '\n'
    '            val scaleSlider = toolbar.findViewById<Slider>(R.id.imageScaleSlider)\n'
    '            val tvScaleValue = toolbar.findViewById<TextView>(R.id.tvImageScaleValue)\n'
    '            val currentScale = Math.round(((op?.relativeWidth ?: 0.3f) * 100f).coerceIn(5f, 500f))\n'
    '            scaleSlider?.value = currentScale.toFloat()\n'
    '            tvScaleValue?.text = "$currentScale%"\n'
)
rep(anchor, anchor + insert, 'enterImageEditingModeForEdit scale init')

# 3.13 both enter modes: hide the scale row + reset its button tint
anchor = (
    '            toolbar.findViewById<View>(R.id.imageOpacitySliderRow)?.visibility = View.GONE\n'
    '            toolbar.findViewById<View>(R.id.imageRotationSliderRow)?.visibility = View.VISIBLE\n'
    '            toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageOpacity)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this, R.color.toolTextInactive))\n'
)
insert = (
    '            toolbar.findViewById<View>(R.id.imageScaleSliderRow)?.visibility = View.GONE\n'
    '            toolbar.findViewById<android.widget.ImageButton>(R.id.btnImageScale)?.setColorFilter(androidx.core.content.ContextCompat.getColor(this, R.color.toolTextInactive))\n'
)
rep(anchor, anchor + insert, 'enter modes reset the scale row', cnt=2)

open(p, 'w', encoding='utf-8').write(t)
for tok in ('R.id.btnImageScale', 'R.id.imageScaleSlider', 'R.id.tvImageScaleValue',
            'setScaleWidth', 'duplicateSelectedOverlay', 'showCustomColorPicker'):
    if tok not in t:
        print(' [FAIL] post-state token missing: ' + tok)
        sys.exit(1)
for tok in ('btnImageDuplicate', 'btnImageMirror', 'btnImageChromaKey',
            'showChromaKeyDialog', 'toggleMirror', 'chromaKeyColor',
            'chromaKeySimilarity', 'isMirrored', 'currentChromaColor'):
    if tok in t:
        print(' [FAIL] leftover token still present: ' + tok)
        sys.exit(1)
print(' [ok] activity: scale wired in, duplicate/mirror/chroma code gone')
P10B
}

# ---------------------------------------------------------------------------
#  STEP 4 -- DraggableImageOverlayView.kt: setScaleWidth + feature removal
# ---------------------------------------------------------------------------
step4_draggable_view() {
    echo "== step 4: DraggableImageOverlayView.kt -- setScaleWidth, no mirror/chroma"
    python3 - <<'P10C' || return 1
import re, sys
p = 'app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt'
t = open(p, encoding='utf-8').read()
if 'fun setScaleWidth' in t:
    print(' [skip] overlay view already carries setScaleWidth')
    sys.exit(0)
if 'fun toggleMirror' not in t or 'applyChromaKey' not in t:
    print(' [FAIL] overlay view is neither fresh phase-9 nor phase-10 state')
    sys.exit(1)

def rep(old, new, name, cnt=1):
    global t
    c = t.count(old)
    if c != cnt:
        print(' [FAIL] %s: expected %d match(es), found %d' % (name, cnt, c))
        sys.exit(1)
    t = t.replace(old, new)

# 4.1 imports: Bitmap + coroutines were chroma-only
rep('import android.graphics.Bitmap\n', '', 'Bitmap import removed')
rep('import kotlinx.coroutines.CoroutineScope\n'
    'import kotlinx.coroutines.Dispatchers\n'
    'import kotlinx.coroutines.Job\n'
    'import kotlinx.coroutines.SupervisorJob\n'
    'import kotlinx.coroutines.launch\n'
    'import kotlinx.coroutines.withContext\n',
    '', 'coroutine imports removed')

# 4.2 onImageCommitted type: drop isMirrored
rep('rotationAngle: Float, opacity: Float, isMirrored: Boolean) -> Unit)? = null',
    'rotationAngle: Float, opacity: Float) -> Unit)? = null',
    'onImageCommitted type without mirror')

# 4.3 state: drop isMirrored
rep('    private var isMirrored = false\n', '', 'isMirrored state removed')

# 4.4 chroma picker state block (comment line uses unicode dashes: regex)
pat = re.compile(
    r'    //[^\n]*Chroma Key Picker State[^\n]*\n'
    r'    var isColorPickingMode = false\n'
    r'    var onColorPicked: \(\(colorHex: String\) -> Unit\)\? = null\n'
    r'[ \t]*\n'
    r'    private val scope = CoroutineScope\(Dispatchers\.Main \+ SupervisorJob\(\)\)\n'
    r'    private var originalBitmapForChroma: Bitmap\? = null\n'
    r'    var currentChromaColor: String\? = null\n'
    r'        private set\n'
    r'    var currentChromaSimilarity: Float = 0\.1f\n'
    r'        private set\n'
    r'    private var chromaJob: Job\? = null\n'
    r'[ \t]*\n'
)
t2, n = pat.subn('', t, count=1)
if n != 1:
    print(' [FAIL] chroma picker state block not matched')
    sys.exit(1)
t = t2

# 4.5 activate(): chroma reset lines
rep('        originalBitmapForChroma?.recycle()\n'
    '        originalBitmapForChroma = null\n'
    '        currentChromaColor = null\n',
    '', 'activate chroma reset removed')

# 4.6 activate(): opacity trio without mirror
rep('        isMirrored = false\n'
    '        imageView.alpha = opacity\n'
    '        imageView.scaleX = if (isMirrored) -1f else 1f\n',
    '        imageView.alpha = opacity\n',
    'activate mirror lines removed')

# 4.7 activateForEdit(): chroma state init
rep('        originalBitmapForChroma?.recycle()\n'
    '        originalBitmapForChroma = null\n'
    '        currentChromaColor = op.chromaKeyColor\n'
    '        currentChromaSimilarity = op.chromaKeySimilarity\n',
    '', 'activateForEdit chroma init removed')

# 4.8 activateForEdit(): mirror assignment + chroma apply in the post block
rep('        isMirrored = op.isMirrored\n', '', 'activateForEdit mirror assignment removed')
rep('        imageView.rotation = rotationAngle\n'
    '        imageView.alpha = opacity\n'
    '        imageView.scaleX = if (isMirrored) -1f else 1f\n'
    '        visibility = VISIBLE\n'
    '        post {\n'
    '            updateImageViewSizeAndPosition()\n'
    '            if (currentChromaColor != null) {\n'
    '                applyChromaKey()\n'
    '            }\n'
    '        }\n',
    '        imageView.rotation = rotationAngle\n'
    '        imageView.alpha = opacity\n'
    '        visibility = VISIBLE\n'
    '        post {\n'
    '            updateImageViewSizeAndPosition()\n'
    '        }\n',
    'activateForEdit mirror/chroma removed')

# 4.9 toggleMirror becomes setScaleWidth (same pinch math as the scale detector)
rep('    fun toggleMirror() {\n'
    '        isMirrored = !isMirrored\n'
    '        imageView.scaleX = if (isMirrored) -1f else 1f\n'
    '        invalidate()\n'
    '    }\n',
    '    fun setScaleWidth(w: Float) {\n'
    '        relativeWidth = w.coerceIn(0.05f, 5.0f)\n'
    '        val videoRatio = if (videoHeight > 0) videoWidth.toFloat() / videoHeight else 1.0f\n'
    '        relativeHeight = relativeWidth * videoRatio / imageAspectRatio\n'
    '        syncRelativePositionFromVisual()\n'
    '        updateImageViewSizeAndPosition()\n'
    '    }\n',
    'setScaleWidth replaces toggleMirror')

# 4.10 commitImage: drop isMirrored arg
rep('rotationAngle, opacity, isMirrored)\n', 'rotationAngle, opacity)\n',
    'commitImage invoke without mirror')

# 4.11 touch handlers: drop the color-picking branches
rep('                    if (isColorPickingMode) {\n'
    '                        return true\n'
    '                    }\n',
    '', 'onInterceptTouchEvent color-pick branch removed')
rep('                if (isColorPickingMode) {\n'
    '                    pickColorAt(event.x, event.y)\n'
    '                    return true\n'
    '                }\n',
    '', 'onTouchEvent color-pick branch removed')

# 4.12 cut pickColorAt / setChromaKey / applyChromaKey (up to the Drawing section)
a = t.find('    private fun pickColorAt(x: Float, y: Float) {')
m = re.search(r'    //[^\n]*Drawing[^\n]*\n', t)
if a < 0 or m is None or m.start() <= a:
    print(' [FAIL] pickColorAt cut anchors not found')
    sys.exit(1)
t = t[:a] + t[m.start():]

# 4.13 getters + setProperties without mirror
rep('    fun getIsMirrored(): Boolean = isMirrored\n', '', 'getIsMirrored removed')
rep('    fun setProperties(rx: Float, ry: Float, rw: Float, rh: Float, rot: Float, op: Float, mir: Boolean) {',
    '    fun setProperties(rx: Float, ry: Float, rw: Float, rh: Float, rot: Float, op: Float) {',
    'setProperties signature without mirror')
rep('        setOpacity(op)\n        isMirrored = mir\n', '        setOpacity(op)\n',
    'setProperties body without mirror')

open(p, 'w', encoding='utf-8').write(t)
for tok in ('fun setScaleWidth', 'fun setOpacity', 'fun setRotationAngle',
            'fun commitImage', 'fun setProperties', 'fun activateForEdit'):
    if tok not in t:
        print(' [FAIL] post-state token missing: ' + tok)
        sys.exit(1)
for tok in ('toggleMirror', 'getIsMirrored', 'isMirrored', 'isColorPickingMode',
            'pickColorAt', 'applyChromaKey', 'setChromaKey', 'currentChromaColor',
            'currentChromaSimilarity', 'originalBitmapForChroma', 'chromaJob',
            'onColorPicked', 'CoroutineScope', 'import android.graphics.Bitmap\n'):
    if tok in t:
        print(' [FAIL] leftover token still present: ' + tok)
        sys.exit(1)
print(' [ok] overlay view: setScaleWidth added, mirror + chroma removed')
P10C
}

# ---------------------------------------------------------------------------
#  STEP 5 -- EditOperation.kt: drop the 3 model fields
# ---------------------------------------------------------------------------
step5_operation_model() {
    echo "== step 5: EditOperation.kt -- drop chroma + mirror fields"
    python3 - <<'P10D' || return 1
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt'
t = open(p, encoding='utf-8').read()
if 'chromaKeyColor' not in t:
    print(' [skip] AddImageOverlay already slim')
    sys.exit(0)
old = (
    '        val isLooping: Boolean = true,\n'
    '        val chromaKeyColor: String? = null,\n'
    '        val chromaKeySimilarity: Float = 0.1f,\n'
    '        val opacity: Float = 1.0f,\n'
    '        val isMirrored: Boolean = false,\n'
)
new = (
    '        val isLooping: Boolean = true,\n'
    '        val opacity: Float = 1.0f,\n'
)
if t.count(old) != 1:
    print(' [FAIL] AddImageOverlay field block not found exactly once')
    sys.exit(1)
t = t.replace(old, new)
open(p, 'w', encoding='utf-8').write(t)
for tok in ('chromaKeyColor', 'chromaKeySimilarity', 'isMirrored'):
    if tok in t:
        print(' [FAIL] leftover token still present: ' + tok)
        sys.exit(1)
if 'data class AddImageOverlay(' not in t or 'val opacity: Float = 1.0f,' not in t:
    print(' [FAIL] AddImageOverlay damaged')
    sys.exit(1)
print(' [ok] AddImageOverlay: chroma + mirror fields removed')
P10D
}

# ---------------------------------------------------------------------------
#  STEP 6 -- VideoEditingViewModelExt.kt: slim addImageOverlayOperation
# ---------------------------------------------------------------------------
step6_viewmodel_ext() {
    echo "== step 6: VideoEditingViewModelExt.kt -- slim overlay factory"
    python3 - <<'P10E' || return 1
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt'
t = open(p, encoding='utf-8').read()
if 'chromaKeyColor' not in t:
    print(' [skip] addImageOverlayOperation already slim')
    sys.exit(0)
old = (
    'fun VideoEditingViewModel.addImageOverlayOperation(\n'
    '    imageUri: Uri, relativeX: Float, relativeY: Float, relativeWidth: Float, relativeHeight: Float,\n'
    '    rotationAngle: Float, startTimeMs: Long? = null, endTimeMs: Long? = null, fileDurationMs: Long? = null,\n'
    '    isLooping: Boolean = true, chromaKeyColor: String? = null, chromaKeySimilarity: Float = 0.1f,\n'
    '    opacity: Float = 1.0f, isMirrored: Boolean = false\n'
    ') {\n'
    '    executeCommand(AddOperationCommand(EditOperation.AddImageOverlay(\n'
    '        imageUri, relativeX, relativeY, relativeWidth, relativeHeight, rotationAngle, startTimeMs,\n'
    '        endTimeMs, id = System.nanoTime().toString(), fileDurationMs, isLooping, chromaKeyColor,\n'
    '        chromaKeySimilarity, opacity, isMirrored\n'
    '    ), "Add Image Overlay"))\n'
    '}\n'
)
new = (
    'fun VideoEditingViewModel.addImageOverlayOperation(\n'
    '    imageUri: Uri, relativeX: Float, relativeY: Float, relativeWidth: Float, relativeHeight: Float,\n'
    '    rotationAngle: Float, startTimeMs: Long? = null, endTimeMs: Long? = null, fileDurationMs: Long? = null,\n'
    '    isLooping: Boolean = true,\n'
    '    opacity: Float = 1.0f\n'
    ') {\n'
    '    executeCommand(AddOperationCommand(EditOperation.AddImageOverlay(\n'
    '        imageUri, relativeX, relativeY, relativeWidth, relativeHeight, rotationAngle, startTimeMs,\n'
    '        endTimeMs, id = System.nanoTime().toString(), fileDurationMs, isLooping,\n'
    '        opacity\n'
    '    ), "Add Image Overlay"))\n'
    '}\n'
)
if t.count(old) != 1:
    print(' [FAIL] addImageOverlayOperation block not found exactly once')
    sys.exit(1)
t = t.replace(old, new)
open(p, 'w', encoding='utf-8').write(t)
for tok in ('chromaKeyColor', 'chromaKeySimilarity', 'isMirrored'):
    if tok in t:
        print(' [FAIL] leftover token still present: ' + tok)
        sys.exit(1)
if 'fun VideoEditingViewModel.addImageOverlayOperation(' not in t:
    print(' [FAIL] addImageOverlayOperation damaged')
    sys.exit(1)
print(' [ok] addImageOverlayOperation: chroma + mirror params removed')
P10E
}

# ---------------------------------------------------------------------------
#  STEP 7 -- VideoEditingViewModel.kt: drop hflip + colorkey FFmpeg stages
# ---------------------------------------------------------------------------
step7_viewmodel_ffmpeg() {
    echo "== step 7: VideoEditingViewModel.kt -- no hflip / colorkey stages"
    python3 - <<'P10F' || return 1
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt'
t = open(p, encoding='utf-8').read()
if 'mirrorStr' not in t and 'chromaKeyColor' not in t:
    print(' [skip] FFmpeg stages already slim')
    sys.exit(0)
if 'mirrorStr' not in t or 'chromaKeyColor' not in t:
    print(' [FAIL] viewmodel is neither fresh phase-9 nor phase-10 state')
    sys.exit(1)

def rep(old, new, name, cnt=1):
    global t
    c = t.count(old)
    if c != cnt:
        print(' [FAIL] %s: expected %d match(es), found %d' % (name, cnt, c))
        sys.exit(1)
    t = t.replace(old, new)

# both mirrorStr declarations are identical -> remove both lines
rep('                            val mirrorStr = if (op.isMirrored) ",hflip" else ""\n',
    '', 'mirrorStr declarations removed', cnt=2)

# the three filter chains that referenced $mirrorStr
rep("format=rgba$mirrorStr$ptsLabel\")", "format=rgba$ptsLabel\")",
    'video overlay chain without hflip')
rep("format=rgba$mirrorStr,loop=loop=-1:size=1:start=0,fps=25$rgbaImgLabel\")",
    "format=rgba,loop=loop=-1:size=1:start=0,fps=25$rgbaImgLabel\")",
    'keyframed static overlay chain without hflip')
rep("format=rgba$mirrorStr$rgbaImgLabel\")", "format=rgba$rgbaImgLabel\")",
    'static overlay chain without hflip')

# the colorkey stage block
old = (
    '                        var currentOverlayLabel = scaledImgLabel\n'
    '                        if (op.chromaKeyColor != null) {\n'
    '                            val colorkeyLabel = "[colorkey_$stageIndex]"\n'
    '                            val color = formatColorForFFmpeg(op.chromaKeyColor)\n'
    '                            // colorkey=color=0xRRGGBB:similarity=0.1:blend=0.1\n'
    '                            stages.add("${currentOverlayLabel}colorkey=${color}:${op.chromaKeySimilarity}:0.1${colorkeyLabel}")\n'
    '                            currentOverlayLabel = colorkeyLabel\n'
    '                        }\n'
)
new = (
    '                        var currentOverlayLabel = scaledImgLabel\n'
)
rep(old, new, 'colorkey stage removed')

open(p, 'w', encoding='utf-8').write(t)
for tok in ('formatColorForFFmpeg', 'scale2ref', 'buildFFmpegInterpolationExpr'):
    if tok not in t:
        print(' [FAIL] survivor token missing: ' + tok)
        sys.exit(1)
for tok in ('mirrorStr', 'hflip', 'colorkey', 'chromaKeyColor', 'chromaKeySimilarity',
            'isMirrored'):
    if tok in t:
        print(' [FAIL] leftover token still present: ' + tok)
        sys.exit(1)
print(' [ok] render engine: hflip + colorkey stages removed')
P10F
}

# ---------------------------------------------------------------------------
#  STEP 8 -- ImageOverlayView.kt: preview without chroma + mirror
# ---------------------------------------------------------------------------
step8_preview_view() {
    echo "== step 8: ImageOverlayView.kt -- preview rendering cleanup"
    python3 - <<'P10G' || return 1
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView.kt'
t = open(p, encoding='utf-8').read()
if 'applyChromaKey' not in t:
    print(' [skip] preview view already slim')
    sys.exit(0)

def rep(old, new, name, cnt=1):
    global t
    c = t.count(old)
    if c != cnt:
        print(' [FAIL] %s: expected %d match(es), found %d' % (name, cnt, c))
        sys.exit(1)
    t = t.replace(old, new)

rep('        // Cache static images with their chroma key properties considered\n',
    '        // Cache static images for preview rendering\n',
    'caching comment updated')
rep('                    val cacheKey = "${op.imageUri}_${op.chromaKeyColor}_${op.chromaKeySimilarity}"\n',
    '                    val cacheKey = op.imageUri.toString()\n',
    'static cache key simplified')
rep('                                if (bitmap != null && op.chromaKeyColor != null) {\n'
    '                                    bitmap = applyChromaKey(bitmap, op.chromaKeyColor!!, op.chromaKeySimilarity, cacheKey)\n'
    '                                }\n',
    '', 'static-image chroma application removed')
rep('                            if (bitmap != null && op.chromaKeyColor != null) {\n'
    '                                bitmap = applyChromaKey(bitmap, op.chromaKeyColor!!, op.chromaKeySimilarity, cacheKey)\n'
    '                            }\n',
    '', 'video-frame chroma application removed')
rep('                val staticCacheKey = "${op.imageUri}_${op.chromaKeyColor}_${op.chromaKeySimilarity}"\n',
    '                val staticCacheKey = op.imageUri.toString()\n',
    'onDraw cache key simplified')
rep('        if (op.isMirrored) {\n'
    '            canvas.scale(-1f, 1f, centerX, centerY)\n'
    '        }\n',
    '', 'mirror preview draw removed')
rep('    private val reusableIntArrays = mutableMapOf<String, IntArray>()\n',
    '', 'reusableIntArrays pool removed')
rep('        reusableIntArrays.clear()\n', '', 'reusableIntArrays clear removed')

# cut the applyChromaKey function itself
a = t.find('    private fun applyChromaKey(bitmap: Bitmap, colorHex: String, similarity: Float, cacheKey: String): Bitmap {')
b = t.find('    private fun interpolateKeyframes(')
if a < 0 or b < 0 or b < a:
    print(' [FAIL] applyChromaKey cut anchors not found')
    sys.exit(1)
t = t[:a] + t[b:]

open(p, 'w', encoding='utf-8').write(t)
for tok in ('fun drawBitmapOp', 'reusableBitmaps', 'interpolateKeyframes'):
    if tok not in t:
        print(' [FAIL] survivor token missing: ' + tok)
        sys.exit(1)
for tok in ('chroma', 'Chroma', 'isMirrored', 'reusableIntArrays'):
    if tok in t:
        print(' [FAIL] leftover token still present: ' + tok)
        sys.exit(1)
print(' [ok] preview view: chroma + mirror rendering removed')
P10G
}

# ---------------------------------------------------------------------------
#  STEP 9 -- delete orphaned chroma/mirror resources
# ---------------------------------------------------------------------------
step9_delete_files() {
    echo "== step 9: delete chroma dialog + mirror/chroma icons"
    local f n=0
    for f in "$CHROMA_LAYOUT" "$ICMIRROR" "$ICLENS"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            n=$((n + 1))
        fi
    done
    if [ "$n" -eq 0 ]; then
        echo " [skip] no chroma/mirror resources left"
    else
        echo " [ok] deleted $n orphaned resource file(s)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 10 -- version bump (advances by exactly 1 on EVERY run, by design)
# ---------------------------------------------------------------------------
step10_version_bump() {
    echo "== step 10: version bump"
    local old_vc old_beta
    old_vc=$(grep -oE "toInteger\(\) : [0-9]+" "$GRADLE" | head -1 | grep -oE "[0-9]+$" || true)
    if ! echo "$old_vc" | grep -qE '^[0-9]+$'; then
        echo " [FAIL] cannot read the default versionCode from build.gradle"
        return 1
    fi
    NEW_VC=$((old_vc + 1))
    if ! sed -i "s/toInteger() : ${old_vc}\$/toInteger() : ${NEW_VC}/" "$GRADLE"; then
        echo " [FAIL] versionCode sed failed"
        return 1
    fi
    old_beta=$(grep -oE 'versionName "1\.0-beta[0-9]+"' "$GRADLE" | head -1 | grep -oE 'beta[0-9]+' | grep -oE '[0-9]+' || true)
    if ! echo "$old_beta" | grep -qE '^[0-9]+$'; then
        echo " [FAIL] cannot read the versionName beta number from build.gradle"
        return 1
    fi
    NEW_BETA=$((old_beta + 1))
    sed -i "s/versionName \"1\.0-beta${old_beta}\"/versionName \"1.0-beta${NEW_BETA}\"/" "$GRADLE"
    if grep -q "toInteger() : ${NEW_VC}\$" "$GRADLE" \
       && grep -qF "versionName \"1.0-beta${NEW_BETA}\"" "$GRADLE"; then
        echo " [ok] version bumped: versionCode ${old_vc} -> ${NEW_VC}, versionName 1.0-beta${old_beta} -> 1.0-beta${NEW_BETA}"
        return 0
    fi
    echo " [FAIL] version bump did not land"
    return 1
}

# ---------------------------------------------------------------------------
#  STEP 11 -- verify the workflow push trigger (defensive carry-over)
# ---------------------------------------------------------------------------
step11_workflow_trigger() {
    echo "== step 11: verify the workflow push trigger"
    if grep -q 'branches: \[main\]' "$YML"; then
        echo " [skip] push trigger intact (branches: [main])"
        return 0
    fi
    if ! grep -q 'branches: ain\]' "$YML"; then
        echo " [FAIL] neither 'branches: [main]' nor the typo 'branches: ain]' found -- unexpected workflow file"
        return 1
    fi
    sed -i 's/branches: ain\]/branches: [main]/' "$YML"
    if grep -q 'branches: \[main\]' "$YML" && ! grep -q 'branches: ain\]' "$YML"; then
        echo " [ok] push trigger repaired"
        return 0
    fi
    echo " [FAIL] workflow trigger repair did not land"
    return 1
}

# ---------------------------------------------------------------------------
#  STEP 12 -- verification gate
# ---------------------------------------------------------------------------
step12_verify() {
    echo "== step 12: verification gate"

    # 12a: leftover scan -- zero chroma / mirror / image-duplicate references
    python3 - <<'P10H' || return 1
import os, sys
bad = []
gone_tokens = (
    'chroma', 'Chroma', 'isMirrored', 'toggleMirror', 'getIsMirrored',
    'hflip', 'colorkey', 'mirrorStr', 'btnImageDuplicate', 'btnImageMirror',
    'btnImageChromaKey', 'tvImageMirror', 'tvImageChromaKey', 'ic_mirror',
    'ic_color_lens_24', 'showChromaKeyDialog', 'isColorPickingMode',
    'pickColorAt', 'chromaKey',
)
for root, dirs, files in os.walk('app/src/main'):
    for fn in files:
        if not (fn.endswith('.kt') or fn.endswith('.xml')):
            continue
        p = os.path.join(root, fn)
        try:
            t = open(p, encoding='utf-8').read()
        except Exception as e:
            bad.append('%s: unreadable (%s)' % (p, e))
            continue
        for tok in gone_tokens:
            if tok in t:
                bad.append('%s: still contains %r' % (p, tok))
if bad:
    for b in bad[:20]:
        print(' [FAIL] leftover: ' + b)
    if len(bad) > 20:
        print(' ... and %d more' % (len(bad) - 20))
    sys.exit(1)
print(' [ok] zero chroma / mirror / image-duplicate references remain')
P10H

    # 12b: survival + new-feature asserts
    python3 - <<'P10I' || return 1
import os, sys
errs = []

def rd(p):
    return open(p, encoding='utf-8').read()

iet = rd('app/src/main/res/layout/image_editing_toolbar.xml')
for tok in ('btnImageCancel', 'btnImageOpacity', 'btnImageOpacityContainer',
            'imageOpacitySlider', 'imageOpacitySliderRow', 'tvImageOpacityValue',
            'imageRotationSlider', 'imageRotationSliderRow', 'tvImageRotationValue',
            'btnImageLoop', 'btnImageLoopContainer', 'btnImageKeyframe',
            'btnImageKeyframeContainer', 'btnImageDelete', 'btnImageDone',
            '@string/str_opacity', '@string/str_loop', '@drawable/ic_opacity_24',
            '@drawable/ic_rotate_right_24', '@drawable/ic_loop_24',
            '@drawable/ic_keyframe_main'):
    if tok not in iet:
        errs.append('toolbar: missing survivor %r' % tok)
for tok in ('btnImageScale', 'btnImageScaleContainer', 'imageScaleSlider',
            'imageScaleSliderRow', 'tvImageScaleValue', 'tvImageScale',
            '@drawable/ic_resize_24', 'android:valueFrom="5.0"',
            'android:valueTo="500.0"', 'android:text="Scale"', 'android:text="30%"'):
    if tok not in iet:
        errs.append('toolbar: missing new Scale token %r' % tok)

vea = rd('app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt')
for tok in ('R.id.btnImageScale', 'R.id.imageScaleSlider', 'R.id.tvImageScaleValue',
            'R.id.imageScaleSliderRow', 'setScaleWidth', 'duplicateSelectedOverlay',
            'showCustomColorPicker', 'R.id.btnTextDuplicate', 'R.id.btnImageOpacity',
            'R.id.btnImageLoop', 'R.id.btnImageKeyframe', 'R.id.btnImageDone',
            'R.id.btnImageDelete', 'R.id.btnImageCancel'):
    if tok not in vea:
        errs.append('activity: missing survivor/new token %r' % tok)

diov = rd('app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt')
for tok in ('fun setScaleWidth', 'fun setOpacity', 'fun setRotationAngle',
            'fun commitImage', 'fun setProperties', 'fun activateForEdit',
            'coerceIn(0.05f, 5.0f)'):
    if tok not in diov:
        errs.append('overlay view: missing token %r' % tok)

vm = rd('app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt')
for tok in ('formatColorForFFmpeg', 'scale2ref', 'buildFFmpegInterpolationExpr'):
    if tok not in vm:
        errs.append('viewmodel: missing survivor %r' % tok)

tet = rd('app/src/main/res/layout/text_editing_toolbar.xml')
if 'btnTextDuplicate' not in tet or '@string/str_duplicate' not in tet:
    errs.append('text toolbar: duplicate button must survive')
if not os.path.isfile('app/src/main/java/com/tharunbirla/librecuts/customviews/HSVColorPickerView.kt'):
    errs.append('HSVColorPickerView.kt must survive (custom color picker)')
if not os.path.isfile('app/src/main/res/layout/dialog_custom_color_picker.xml'):
    errs.append('dialog_custom_color_picker.xml must survive')
if not os.path.isfile('app/src/main/res/drawable/ic_copy_24.xml'):
    errs.append('ic_copy_24.xml must survive (text toolbar duplicate)')
if not os.path.isfile('app/src/main/res/drawable/ic_resize_24.xml'):
    errs.append('ic_resize_24.xml must exist (new scale icon)')
strs = rd('app/src/main/res/values/strings.xml')
for tok in ('str_duplicate', 'str_opacity', 'str_loop', 'str_freeze', 'str_overlay'):
    if tok not in strs:
        errs.append('strings.xml: missing %r' % tok)
if errs:
    for e in errs:
        print(' [FAIL] survival: ' + e)
    sys.exit(1)
print(' [ok] survivors intact + Scale controls present')
P10I

    # 12c: XML parse of the touched layout + new icon
    python3 - <<'P10J' || return 1
import xml.dom.minidom as md
for f in ('app/src/main/res/layout/image_editing_toolbar.xml',
          'app/src/main/res/drawable/ic_resize_24.xml'):
    md.parse(f)
print(' [ok] touched XML files parse cleanly')
P10J

    # 12d: brace + paren delta check for the six touched Kotlin files
    #      (VideoEditingActivity.kt carries a pre-existing +3 paren skew
    #      from string literals, so we compare deltas against HEAD)
    python3 - <<'P10K' || return 1
import subprocess, sys
files = [
    'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt',
    'app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt',
    'app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView.kt',
    'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt',
    'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt',
    'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt.kt',
]
errs = []
for p in files:
    cur = open(p, encoding='utf-8').read()
    try:
        base = subprocess.run(['git', 'show', 'HEAD:' + p],
                              capture_output=True, text=True,
                              check=True).stdout
    except subprocess.CalledProcessError:
        base = cur  # not tracked yet -> compare against itself
    for a, b in (('{', '}'), ('(', ')')):
        d_open = cur.count(a) - base.count(a)
        d_close = cur.count(b) - base.count(b)
        if d_open != d_close:
            errs.append('%s: %s%s delta skew (%+d vs %+d)'
                        % (p.split('/')[-1], a, b, d_open, d_close))
    if cur.count('{') != cur.count('}') and base.count('{') == base.count('}'):
        errs.append('%s: brace balance broken by this phase (%d vs %d)'
                    % (p.split('/')[-1], cur.count('{'), cur.count('}')))
if errs:
    for e in errs:
        print(' [FAIL] balance: ' + e)
    sys.exit(1)
print(' [ok] all six touched Kotlin files keep matched brace/paren deltas')
P10K

    # 12e: R.id cross-check -- every R.id.X in Kotlin exists in some res xml
    python3 - <<'P10L' || return 1
import os, re, sys
defined = set()
for root, dirs, files in os.walk('app/src/main/res'):
    for fn in files:
        if not fn.endswith('.xml'):
            continue
        p = os.path.join(root, fn)
        try:
            t = open(p, encoding='utf-8').read()
        except Exception:
            continue
        for m in re.finditer(r'@\+id/(\w+)', t):
            defined.add(m.group(1))
refs = {}
for root, dirs, files in os.walk('app/src/main/java'):
    for fn in files:
        if not fn.endswith('.kt'):
            continue
        p = os.path.join(root, fn)
        t = open(p, encoding='utf-8').read()
        for m in re.finditer(r'(?<!android\.)R\.id\.(\w+)', t):
            refs.setdefault(m.group(1), set()).add(p.split('/')[-1])
missing = {k: v for k, v in refs.items() if k not in defined}
if missing:
    for k, v in sorted(missing.items()):
        print(' [FAIL] R.id.%s referenced in %s but defined nowhere' % (k, ', '.join(sorted(v))))
    sys.exit(1)
print(' [ok] all %d referenced R.id tokens resolve to resource ids' % len(refs))
P10L

    # 12f: gradle -- exact version values + phase-9 signing intact
    if [ -z "$NEW_VC" ] || [ -z "$NEW_BETA" ]; then
        echo " [FAIL] version bump did not run -- cannot verify build.gradle"
        return 1
    fi
    python3 - "$NEW_VC" "$NEW_BETA" <<'P10M' || return 1
import re, sys
new_vc, new_beta = sys.argv[1], sys.argv[2]
t = open('app/build.gradle', encoding='utf-8').read()
errs = []
if not re.search(r"toInteger\(\) : %s$" % re.escape(new_vc), t, re.M):
    errs.append('versionCode default is not %s' % new_vc)
if 'versionName "1.0-beta%s"' % new_beta not in t:
    errs.append('versionName is not 1.0-beta%s' % new_beta)
for tok in ('signingConfigs {', "storeFile file('debug.keystore')",
            "storePassword 'android'", "keyAlias 'androiddebugkey'",
            "keyPassword 'android'"):
    if tok not in t:
        errs.append('build.gradle missing %r' % tok)
if t.count('{') != t.count('}'):
    errs.append('build.gradle brace balance broken (%d vs %d)'
                % (t.count('{'), t.count('}')))
if errs:
    for e in errs:
        print(' [FAIL] gradle: ' + e)
    sys.exit(1)
print(' [ok] build.gradle: versionCode %s / 1.0-beta%s + stable debug signing intact'
      % (new_vc, new_beta))
P10M
    if ! keytool -list -keystore app/debug.keystore -storepass android >/dev/null 2>&1; then
        echo " [FAIL] app/debug.keystore not resolvable"
        return 1
    fi
    if git check-ignore -q app/debug.keystore; then
        echo " [FAIL] app/debug.keystore is gitignored"
        return 1
    fi
    echo " [ok] app/debug.keystore valid and git-tracked"

    # 12g: scope gate -- only the expected file set may appear in the diff
    local bad
    bad=$(git status --porcelain 2>/dev/null | cut -c4- | grep -Ev \
'^(scripts/apply-changes\.sh|app/src/main/res/layout/image_editing_toolbar\.xml|app/src/main/res/drawable/ic_resize_24\.xml|app/src/main/res/layout/chroma_key_bottom_sheet_dialog\.xml|app/src/main/res/drawable/ic_mirror\.xml|app/src/main/res/drawable/ic_color_lens_24\.xml|app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity\.kt|app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView\.kt|app/src/main/java/com/tharunbirla/librecuts/customviews/ImageOverlayView\.kt|app/src/main/java/com/tharunbirla/librecuts/models/EditOperation\.kt|app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel\.kt|app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModelExt\.kt|app/build\.gradle|\.github/workflows/apply-and-build\.yml|app/debug\.keystore)$' || true)
    if [ -n "$bad" ]; then
        echo " [FAIL] unexpected files in the working diff:"
        echo "$bad"
        return 1
    fi
    local untracked
    untracked=$(git status --porcelain 2>/dev/null | grep '^??' | cut -c4- \
                | grep -Ev '^(app/debug\.keystore|app/src/main/res/drawable/ic_resize_24\.xml)$' || true)
    if [ -n "$untracked" ]; then
        echo " [FAIL] unexpected untracked files (only ic_resize_24.xml / debug.keystore may be new):"
        echo "$untracked"
        return 1
    fi
    echo " [ok] change scope is exactly the expected file set"

    # 12h: ASCII self-check
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
echo " Cutloss phase 10 -- overlay toolbar: remove Duplicate,"
echo " Mirror and Chroma Key; add a Scale slider (5-500%) for"
echo " the overlay size; version bump for in-place installs"
echo "=========================================================="
step0_preconditions || FAILED=1
if [ "$FAILED" -eq 0 ]; then
    step1_toolbar_layout    || FAILED=1
    step2_resize_icon       || FAILED=1
    step3_activity          || FAILED=1
    step4_draggable_view    || FAILED=1
    step5_operation_model   || FAILED=1
    step6_viewmodel_ext     || FAILED=1
    step7_viewmodel_ffmpeg  || FAILED=1
    step8_preview_view      || FAILED=1
    step9_delete_files      || FAILED=1
    step10_version_bump     || FAILED=1
    step11_workflow_trigger || FAILED=1
else
    echo " preconditions failed -- skipping the mutation steps"
fi
step12_verify || FAILED=1

echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 10 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 10 complete. Steps ok or skipped (version bump ran)."
echo "  - Overlay toolbar: Duplicate / Mirror / Chroma Key gone"
echo "    (text tool keeps its own Duplicate)."
echo "  - New Scale button + slider: 5..500 percent of the video"
echo "    width, same live behavior and range as pinch zoom."
echo "  - versionCode ${NEW_VC} / versionName 1.0-beta${NEW_BETA}"
echo "    (same committed debug key -> installs over the old APK)."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
