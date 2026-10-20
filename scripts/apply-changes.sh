#!/usr/bin/env bash
# ============================================================================
#  CutStudio change pipeline — scripts/apply-changes.sh
#  Idempotent: safe to re-run on any repo state (fresh LibreCuts or any
#  previously applied CutStudio state). Each stage skips what is done.
#
#  Stages:
#    0. home card          FFmpeg Mix bento card on the home screen
#    1. rebrand            LibreCuts -> CutStudio (user-visible text)
#    2. export-button-v1   single pill Export button + first settings dialog
#    3. export-settings-v2 FULL export settings panel (this release)
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

ACT="$REPO_ROOT/app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
VM="$REPO_ROOT/app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
LAY="$REPO_ROOT/app/src/main/res/layout/activity_video_editing.xml"
DLG="$REPO_ROOT/app/src/main/res/layout/dialog_export_settings.xml"
DLGK="$REPO_ROOT/app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
PKG="$REPO_ROOT/app/src/main/java/com/tharunbirla/librecuts"

# ---------------------------------------------------------------------------
#  STAGE 0 — Home screen: FFmpeg Mix bento card (between the two main cards)
# ---------------------------------------------------------------------------
stage0_home_card() {
  echo "── stage 0: FFmpeg Mix home card"
  python3 - "$REPO_ROOT/app/src/main/res/layout/activity_main.xml" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'btnFfmpegMix' in s:
    print('  [skip] layout already has btnFfmpegMix')
else:
    anchor = '            <!-- Secondary Bento Card: Open Project -->'
    block = '''            <!-- Bento Card: FFmpeg Mix -->
            <LinearLayout
                android:id="@+id/btnFfmpegMix"
                android:layout_width="match_parent"
                android:layout_height="wrap_content"
                android:minHeight="150dp"
                android:layout_marginTop="16dp"
                android:background="@drawable/bg_hero_bento_secondary"
                android:clickable="true"
                android:focusable="true"
                android:foreground="?attr/selectableItemBackground"
                android:gravity="center_vertical"
                android:orientation="vertical"
                android:padding="24dp"
                android:elevation="4dp">

                <RelativeLayout
                    android:layout_width="match_parent"
                    android:layout_height="wrap_content"
                    android:layout_marginBottom="12dp">

                    <View
                        android:layout_width="48dp"
                        android:layout_height="48dp"
                        android:background="@drawable/circle_primary_container" />

                    <ImageView
                        android:layout_width="24dp"
                        android:layout_height="24dp"
                        android:layout_centerVertical="true"
                        android:layout_marginStart="12dp"
                        android:src="@drawable/ic_layers_24"
                        app:tint="@color/onPrimaryContainer" />

                    <ImageView
                        android:layout_width="20dp"
                        android:layout_height="20dp"
                        android:layout_alignParentEnd="true"
                        android:layout_centerVertical="true"
                        android:src="@drawable/ic_arrow_up_right_24"
                        app:tint="@color/iconSecondary"
                        android:alpha="0.5" />
                </RelativeLayout>

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="FFmpeg Mix"
                    android:textColor="@color/textColor"
                    android:textSize="18sp"
                    android:fontFamily="sans-serif-medium" />

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:layout_marginTop="4dp"
                    android:text="Multi track encoding"
                    android:textColor="@color/iconSecondary"
                    android:textSize="13sp"
                    android:fontFamily="sans-serif" />

            </LinearLayout>

'''
    if anchor not in s:
        print('  [FAIL] anchor (Secondary Bento Card comment) not found'); sys.exit(1)
    s = s.replace(anchor, block + anchor, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('  [ok]   layout: FFmpeg Mix card inserted')
PYEOF
  [ $? -ne 0 ] && return 1
  python3 - "$REPO_ROOT/app/src/main/java/com/tharunbirla/librecuts/MainActivity.kt" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'btnFfmpegMix' in s:
    print('  [skip] activity already wired')
else:
    anchor = '        // Initialize bottom navigation tab backgrounds'
    block = '''        binding.btnFfmpegMix.setBounceClickListener {
            Log.d("ButtonClick", "FFmpeg Mix card clicked.")
            showToast("FFmpeg Mix — coming soon")
        }

'''
    if anchor not in s:
        print('  [FAIL] anchor (bottom nav init comment) not found'); sys.exit(1)
    s = s.replace(anchor, block + anchor, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('  [ok]   activity: FFmpeg Mix click wired')
PYEOF
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STAGE 1 — Rebrand LibreCuts -> CutStudio  (idempotent, skips if done)
# ---------------------------------------------------------------------------
stage1_rebrand() {
  echo "── stage 1: rebrand LibreCuts -> CutStudio"
  if [ -f "$PKG/CutStudioApplication.kt" ]; then
    echo "  [skip] already rebranded"
    return 0
  fi
  if [ ! -f "$PKG/LibreCutsApplication.kt" ]; then
    echo "  [FAIL] neither CutStudioApplication.kt nor LibreCutsApplication.kt found"
    return 1
  fi
  sed -i 's/LibreCuts/CutStudio/g' app/src/main/res/values/strings.xml
  for f in app/src/main/res/values-*/strings.xml; do sed -i 's/LibreCuts/CutStudio/g' "$f"; done
  sed -i 's/LibreCuts/CutStudio/g' \
    app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt \
    app/src/main/java/com/tharunbirla/librecuts/services/ProxyGenerationService.kt
  sed -i 's/LibreCuts/CutStudio/g' "$ACT"
  sed -i 's/LibreCuts/CutStudio/g' "$VM"
  sed -i 's/LibreCuts/CutStudio/g; s/LIBRECUTS/CUTSTUDIO/g' \
    app/src/main/java/com/tharunbirla/librecuts/ErrorDisplayActivity.kt
  sed -i 's/LibreCuts/CutStudio/g' app/src/main/res/layout/dialog_welcome_onboarding.xml
  sed -i 's/LibreCuts/CutStudio/g' "$PKG/LibreCutsApplication.kt"
  mv "$PKG/LibreCutsApplication.kt" "$PKG/CutStudioApplication.kt"
  sed -i 's/LibreCutsApplication/CutStudioApplication/g' app/src/main/AndroidManifest.xml
  echo "  [ok] rebrand applied"
}

# ---------------------------------------------------------------------------
#  STAGE 2 — Export button v1: merge split button into one pill
#  (btnSaveText + btnSaveDropdown -> single btnSaveText opening a dialog;
#   ViewModel gains _exportBitrate; bitrate becomes user-controllable)
# ---------------------------------------------------------------------------
stage2_export_button_v1() {
  echo "── stage 2: export button v1 (pill button + bitrate state)"

  # 2a. layout: drop divider + dropdown, make text part full-width
  python3 - "$LAY" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
fails = []
def ap(name, old, new, skip2=None):
    global s
    if new in s or (skip2 and skip2 in s):
        print(f'  [skip] {name}'); return
    if old in s:
        s = s.replace(old, new, 1); print(f'  [ok]   {name}'); return
    fails.append(name)

if 'btnSaveDropdown' not in s:
    print('  [skip] whole stage-2 layout (no btnSaveDropdown)')
else:
    ap('layout: single pill btnSaveText', '''                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="0dp"
                    android:layout_height="match_parent"
                    android:layout_weight="0.75"
                    android:gravity="center"
                    android:text="@string/export"
                    android:textColor="@color/onPrimaryContainer"
                    android:fontFamily="sans-serif-medium"
                    android:textSize="13sp"
                    android:clickable="true"
                    android:focusable="true"
                    android:background="?attr/selectableItemBackground" />

                <View
                    android:layout_width="1dp"
                    android:layout_height="match_parent"
                    android:background="#22FFFFFF" />

                <ImageView
                    android:id="@+id/btnSaveDropdown"
                    android:layout_width="0dp"
                    android:layout_height="match_parent"
                    android:layout_weight="0.25"
                    android:scaleType="centerInside"
                    android:src="@drawable/ic_arrow_drop_down_24"
                    android:padding="8dp"
                    app:tint="@color/onPrimaryContainer"
                    android:clickable="true"
                    android:focusable="true"
                    android:background="?attr/selectableItemBackground" />''', '''                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent"
                    android:gravity="center"
                    android:text="@string/export"
                    android:textColor="@color/onPrimaryContainer"
                    android:fontFamily="sans-serif-medium"
                    android:textSize="13sp"
                    android:clickable="true"
                    android:focusable="true"
                    android:background="?attr/selectableItemBackground" />''')

if fails:
    print('FAILED: ' + ', '.join(fails)); sys.exit(1)
if s != open(p, encoding='utf-8').read():
    open(p, 'w', encoding='utf-8').write(s)
PYEOF
  [ $? -ne 0 ] && return 1

  # 2b. Activity: remove dropdown field/wiring, open dialog from btnSaveText
  python3 - "$ACT" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s
fails = []
def ap(name, old, new, skip2=None, dele=False):
    global s
    if dele:
        # deletion patch: NEW is a subset of OLD, so "already applied" == OLD absent
        if old not in s:
            print(f'  [skip] {name}'); return
        s = s.replace(old, new, 1); print(f'  [ok]   {name}'); return
    if new in s or (skip2 and skip2 in s):
        print(f'  [skip] {name}'); return
    if old in s:
        s = s.replace(old, new, 1); print(f'  [ok]   {name}'); return
    fails.append(name)

if 'btnSaveDropdown' not in s and 'showExportSettingsDialog' in s:
    print('  [skip] whole stage-2 activity (already applied)')
else:
    ap('activity: drop btnSaveDropdown field', '''    private lateinit var btnSaveText: View
    private lateinit var btnSaveDropdown: View
''', '''    private lateinit var btnSaveText: View
''', dele=True)
    ap('activity: drop dropdown findViewById', '''        btnSaveText = findViewById(R.id.btnSaveText)
        btnSaveDropdown = findViewById(R.id.btnSaveDropdown)
''', '''        btnSaveText = findViewById(R.id.btnSaveText)
''', dele=True)
    ap('activity: btnSaveText opens dialog', '''        btnSaveText.setBounceClickListener {
            saveAction()
        }

        btnSaveDropdown.setBounceClickListener {
            showQualitySettingsDialog()
        }
''', '''        btnSaveText.setBounceClickListener {
            showExportSettingsDialog()
        }
''')
    ap('activity: isEnabled without dropdown', '''        if (::layoutSaveSplit.isInitialized && ::btnSaveText.isInitialized && ::btnSaveDropdown.isInitialized) {
            layoutSaveSplit.alpha = if (isBusy || !hasOps) 0.4f else 1.0f
            btnSaveText.isEnabled = !isBusy && hasOps
            btnSaveDropdown.isEnabled = !isBusy && hasOps
        }''', '''        if (::layoutSaveSplit.isInitialized && ::btnSaveText.isInitialized) {
            layoutSaveSplit.alpha = if (isBusy || !hasOps) 0.4f else 1.0f
            btnSaveText.isEnabled = !isBusy && hasOps
        }''')
    # insert stub for the dialog function (replaced by stage 3 in the same run)
    if 'private fun showExportSettingsDialog' not in s:
        marker = '    private fun showQualitySettingsDialog() {'
        if marker in s:
            idx = s.index(marker)
            s = s[:idx] + '''    private fun showExportSettingsDialog() {
        // v1 stub - immediately replaced by the v2 dialog in stage 3
    }

''' + s[idx:]
            print('  [ok]   activity: dialog stub inserted')
        else:
            fails.append('activity: anchor showQualitySettingsDialog not found')

if fails:
    print('FAILED: ' + ', '.join(fails)); sys.exit(1)
if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
PYEOF
  [ $? -ne 0 ] && return 1

  # 2c. ViewModel: _exportBitrate state + 4th setExportSettings param
  python3 - "$VM" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
orig = s
fails = []
def ap(name, old, new, skip2=None):
    global s
    if new in s or (skip2 and skip2 in s):
        print(f'  [skip] {name}'); return
    if old in s:
        s = s.replace(old, new, 1); print(f'  [ok]   {name}'); return
    fails.append(name)

if '_exportBitrate' in s and 'when (_exportResolution.value)' not in s:
    print('  [skip] whole stage-2 viewmodel (already applied)')
else:
    ap('vm: _exportBitrate flow', '''    private val _exportAudioOnly = MutableStateFlow(false)
    private val _selectedOperationId = MutableStateFlow<String?>(null)
''', '''    private val _exportAudioOnly = MutableStateFlow(false)
    private val _exportBitrate = MutableStateFlow("8M")
    private val _selectedOperationId = MutableStateFlow<String?>(null)
''')
    ap('vm: exportBitrate public flow', '''    val exportAudioOnly: StateFlow<Boolean> = _exportAudioOnly.asStateFlow()
    val hasUnsavedEdits: StateFlow<Boolean> = _hasUnsavedEdits.asStateFlow()
''', '''    val exportAudioOnly: StateFlow<Boolean> = _exportAudioOnly.asStateFlow()
    val exportBitrate: StateFlow<String> = _exportBitrate.asStateFlow()
    val hasUnsavedEdits: StateFlow<Boolean> = _hasUnsavedEdits.asStateFlow()
''')
    ap('vm: setExportSettings bitrate param', '''    fun setExportSettings(resolution: Int, fps: Int, audioOnly: Boolean) {
        _exportResolution.value = resolution
        _exportFps.value = fps
        _exportAudioOnly.value = audioOnly
    }
''', '''    fun setExportSettings(resolution: Int, fps: Int, audioOnly: Boolean, bitrate: String? = null) {
        _exportResolution.value = resolution
        _exportFps.value = fps
        _exportAudioOnly.value = audioOnly
        if (bitrate != null) _exportBitrate.value = bitrate
    }
''')
    # merge-path: resolution-based when-map -> _exportBitrate (stage 3 rewrites further)
    ap('vm: merge-path bitrate from state', '''                val bitrate = when (_exportResolution.value) {
                    2160 -> "30M"
                    1440 -> "16M"
                    1080 -> "8M"
                    720 -> "5M"
                    480 -> "2M"
                    else -> "1M"
                }
                val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                    ?.getString("default_encoder", "hardware") ?: "hardware"
                val videoCodec = if (defaultEncoder == "software") "-c:v libx264 -pix_fmt yuv420p" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"
                cmd.append(" $videoCodec")''', '''                val bitrate = _exportBitrate.value
                val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                    ?.getString("default_encoder", "hardware") ?: "hardware"
                val videoCodec = if (defaultEncoder == "software") "-c:v libx264 -pix_fmt yuv420p -b:v $bitrate" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"
                cmd.append(" $videoCodec")''',
       skip2='cmd.append(" ${buildVideoCodecArgs(defaultEncoder)}")')
    # non-merge path: same transformation
    ap('vm: non-merge bitrate from state', '''            val bitrate = when (_exportResolution.value) {
                2160 -> "30M"
                1440 -> "16M"
                1080 -> "8M"
                720 -> "5M"
                480 -> "2M"
                else -> "1M"
            }
            val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                ?.getString("default_encoder", "hardware") ?: "hardware"
            val videoCodec = if (defaultEncoder == "software") "-c:v libx264 -pix_fmt yuv420p" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"''', '''            val bitrate = _exportBitrate.value
            val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                ?.getString("default_encoder", "hardware") ?: "hardware"
            val videoCodec = if (defaultEncoder == "software") "-c:v libx264 -pix_fmt yuv420p -b:v $bitrate" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"''',
       skip2='val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)\n                ?.getString("default_encoder", "hardware") ?: "hardware"\n            // If there are no video filters')

if fails:
    print('FAILED: ' + ', '.join(fails)); sys.exit(1)
if s != orig:
    open(p, 'w', encoding='utf-8').write(s)
PYEOF
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STAGE 3 - Export settings v2 (FULL panel)
#  Rewrites dialog_export_settings.xml, adds ExportSettingsDialog.kt,
#  new drawables, and rewires the FFmpeg command builder in the ViewModel.
# ---------------------------------------------------------------------------
stage3_export_settings_v2() {
  echo "-- stage 3: export settings v2 (full panel)"

  # 3a. new/rewritten resource + source files (byte-exact heredocs)
  cat > "app/src/main/res/drawable/bg_capsule_pill.xml" <<'CUTSTUDIO_EOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="@color/surfaceContainerHigh" />
    <stroke android:width="1dp" android:color="@color/outlineVariant" />
    <corners android:radius="16dp" />
</shape>
CUTSTUDIO_EOF
  cat > "app/src/main/res/drawable/bg_command_box.xml" <<'CUTSTUDIO_EOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="@color/surfaceContainerHigh" />
    <stroke android:width="1dp" android:color="@color/outlineVariant" />
    <corners android:radius="10dp" />
</shape>
CUTSTUDIO_EOF
  cat > "app/src/main/res/layout/dialog_export_settings.xml" <<'CUTSTUDIO_EOF'
<?xml version="1.0" encoding="utf-8"?>
<androidx.core.widget.NestedScrollView xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:background="@drawable/floating_panel_background"
    android:scrollbars="none">

    <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"
        android:orientation="vertical" android:padding="20dp">

        <!-- Header: title + estimated-size capsule (top-right) -->
        <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"
            android:orientation="horizontal" android:gravity="center_vertical">
            <TextView android:layout_width="0dp" android:layout_height="wrap_content"
                android:layout_weight="1" android:text="Export Settings"
                android:textColor="@color/textColor" android:textSize="18sp"
                android:fontFamily="sans-serif-medium" />
            <TextView android:id="@+id/tvEstimatedSize" android:layout_width="wrap_content"
                android:layout_height="wrap_content" android:text="..." android:textColor="@color/colorPrimary"
                android:textSize="12sp" android:fontFamily="sans-serif-medium"
                android:background="@drawable/bg_capsule_pill"
                android:paddingStart="14dp" android:paddingEnd="14dp"
                android:paddingTop="6dp" android:paddingBottom="6dp" />
        </LinearLayout>

        <!-- ======================= Resolution ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="18dp" android:text="Resolution"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />

        <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="8dp" android:orientation="horizontal" android:gravity="center_vertical">
            <EditText android:id="@+id/etWidth" android:layout_width="0dp" android:layout_weight="1"
                android:layout_height="46dp" android:inputType="number" android:maxLength="5"
                android:hint="1920" android:textColorHint="@color/iconSecondary"
                android:textColor="@color/textColor" android:textSize="14sp" android:gravity="center"
                android:background="@drawable/bg_command_box" android:padding="10dp"
                android:singleLine="true" android:imeOptions="actionNext" />
            <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
                android:layout_marginStart="8dp" android:layout_marginEnd="8dp"
                android:text="x" android:textColor="@color/iconSecondary" android:textSize="14sp" />
            <EditText android:id="@+id/etHeight" android:layout_width="0dp" android:layout_weight="1"
                android:layout_height="46dp" android:inputType="number" android:maxLength="5"
                android:hint="1080" android:textColorHint="@color/iconSecondary"
                android:textColor="@color/textColor" android:textSize="14sp" android:gravity="center"
                android:background="@drawable/bg_command_box" android:padding="10dp"
                android:singleLine="true" android:imeOptions="actionDone" />
        </LinearLayout>

        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="8dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgResolution"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="false">
                <com.google.android.material.chip.Chip android:id="@+id/chipResSame" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Same as input" />
                <com.google.android.material.chip.Chip android:id="@+id/chipRes360" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="360p" />
                <com.google.android.material.chip.Chip android:id="@+id/chipRes480" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="480p" />
                <com.google.android.material.chip.Chip android:id="@+id/chipRes720" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="720p" />
                <com.google.android.material.chip.Chip android:id="@+id/chipRes1080" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="1080p" />
                <com.google.android.material.chip.Chip android:id="@+id/chipRes1440" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="1440p" />
                <com.google.android.material.chip.Chip android:id="@+id/chipRes2160" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="2160p" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Video Format ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Video Format"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgVideoFormat"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipFmtSame" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Same as input" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFmtMp4" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="MP4" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFmtMkv" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="MKV" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFmtMov" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="MOV" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFmtWebm" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="WebM" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFmtAvi" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="AVI" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Video Bitrate ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Video Bitrate"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="8dp" android:orientation="horizontal" android:gravity="center_vertical">
            <EditText android:id="@+id/etBitrate" android:layout_width="0dp" android:layout_weight="1"
                android:layout_height="46dp" android:inputType="number" android:maxLength="6"
                android:hint="8000" android:textColorHint="@color/iconSecondary"
                android:textColor="@color/textColor" android:textSize="14sp" android:gravity="center"
                android:background="@drawable/bg_command_box" android:padding="10dp"
                android:singleLine="true" android:imeOptions="actionDone" />
            <com.google.android.material.chip.Chip android:id="@+id/chipBitrateSame"
                style="@style/Widget.MaterialComponents.Chip.Filter"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                android:layout_marginStart="10dp" android:text="Same as input" android:checked="true" />
        </LinearLayout>

        <!-- ======================= Video Codec ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Video Codec"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgVideoCodec"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipCodecSame" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Same as input" />
                <com.google.android.material.chip.Chip android:id="@+id/chipCodecX264" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="H.264 (libx264)" />
                <com.google.android.material.chip.Chip android:id="@+id/chipCodecH265" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="H.265" />
                <com.google.android.material.chip.Chip android:id="@+id/chipCodecX265" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="HEVC (libx265)" />
                <com.google.android.material.chip.Chip android:id="@+id/chipCodecVp9" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="VP9 (libvpx-vp9)" />
                <com.google.android.material.chip.Chip android:id="@+id/chipCodecAv1" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="AV1 (libaom-av1)" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Video FPS ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Video FPS"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgFps"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipFpsSame" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Same as input" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFps24" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="24 fps (Cinema)" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFps25" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="25 fps (PAL)" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFps30" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="30 fps (Standard)" />
                <com.google.android.material.chip.Chip android:id="@+id/chipFps60" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="60 fps (Smooth)" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Audio Format ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Audio Format"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgAudioFormat"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipAFSame" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Same as input" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAFAac" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="AAC (.m4a)" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAFMp3" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="MP3" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAFOpus" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Opus" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAFFlac" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="FLAC" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAFWav" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="WAV" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Audio Codec ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Audio Codec"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgAudioCodec"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipACAac" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="AAC-LC" />
                <com.google.android.material.chip.Chip android:id="@+id/chipACMp3" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="LAME MP3" />
                <com.google.android.material.chip.Chip android:id="@+id/chipACOpus" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="libopus" />
                <com.google.android.material.chip.Chip android:id="@+id/chipACPcm" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="PCM 16-bit" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Audio Bitrate ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Audio Bitrate"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgAudioBitrate"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipABSame" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Same as input" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAB128" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="128 kbps" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAB192" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="192 kbps" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAB256" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="256 kbps" />
                <com.google.android.material.chip.Chip android:id="@+id/chipAB320" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="320 kbps" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= Preset (encoding speed) ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="Preset (x264 / x265 encoding speed)"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <HorizontalScrollView android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="6dp" android:scrollbars="none"
            android:requiresFadingEdge="horizontal" android:fadingEdgeLength="16dp">
            <com.google.android.material.chip.ChipGroup android:id="@+id/cgPreset"
                android:layout_width="wrap_content" android:layout_height="wrap_content"
                app:singleSelection="true" app:selectionRequired="true">
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetUltrafast" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="ultrafast" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetSuperfast" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="superfast" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetVeryfast" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="veryfast" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetFaster" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="faster" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetFast" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="fast" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetMedium" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="medium" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetSlow" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="slow" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetSlower" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="slower" />
                <com.google.android.material.chip.Chip android:id="@+id/chipPresetVeryslow" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="veryslow" />
            </com.google.android.material.chip.ChipGroup>
        </HorizontalScrollView>

        <!-- ======================= FFmpeg command preview ======================= -->
        <TextView android:layout_width="wrap_content" android:layout_height="wrap_content"
            android:layout_marginTop="16dp" android:text="FFmpeg command (what will run)"
            android:textColor="@color/iconSecondary" android:textSize="12sp"
            android:letterSpacing="0.05" android:fontFamily="sans-serif-medium" />
        <TextView android:id="@+id/tvCommand" android:layout_width="match_parent"
            android:layout_height="wrap_content" android:layout_marginTop="8dp"
            android:minHeight="72dp" android:fontFamily="monospace" android:textSize="10sp"
            android:textColor="@color/iconSecondary" android:background="@drawable/bg_command_box"
            android:padding="12dp" android:textIsSelectable="true"
            android:text="(will update live as you change settings)" />

        <!-- ======================= Buttons: Cancel (left) / Save (right) ======================= -->
        <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"
            android:layout_marginTop="20dp" android:orientation="horizontal"
            android:gravity="center_vertical">
            <com.google.android.material.button.MaterialButton
                android:id="@+id/btnCancelExport" android:layout_width="wrap_content"
                android:layout_height="44dp" android:text="@string/cancel"
                android:textColor="@color/textColor" android:textSize="14sp"
                android:fontFamily="sans-serif-medium" android:insetTop="0dp" android:insetBottom="0dp"
                android:paddingStart="24dp" android:paddingEnd="24dp"
                app:backgroundTint="@color/surfaceContainerHigh"
                app:strokeColor="@color/outlineVariant" app:strokeWidth="1dp"
                app:cornerRadius="22dp" />
            <Space android:layout_width="0dp" android:layout_height="1dp" android:layout_weight="1" />
            <com.google.android.material.button.MaterialButton
                android:id="@+id/btnSaveExport" android:layout_width="wrap_content"
                android:layout_height="44dp" android:text="@string/str_save"
                android:textColor="@color/onPrimaryContainer" android:textSize="14sp"
                android:fontFamily="sans-serif-medium" android:insetTop="0dp" android:insetBottom="0dp"
                android:paddingStart="28dp" android:paddingEnd="28dp"
                app:backgroundTint="@color/primaryContainer" app:cornerRadius="22dp" />
        </LinearLayout>
    </LinearLayout>
</androidx.core.widget.NestedScrollView>
CUTSTUDIO_EOF
  cat > "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt" <<'CUTSTUDIO_EOF'
package com.tharunbirla.librecuts

import android.media.MediaMetadataRetriever
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.EditText
import android.widget.TextView
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.tharunbirla.librecuts.viewmodels.VideoEditingViewModel
import java.io.File
import java.util.Locale

/**
 * CutStudio - Export settings dialog (v2).
 *
 * Every control change is pushed live into the ViewModel, then the REAL export
 * command is rebuilt through VideoEditingViewModel.buildConsolidatedFFmpegCommand()
 * (the exact same code path the final export uses) and displayed in the preview
 * box, together with an estimated output file size.
 *
 * Save   -> keeps the current state and triggers the export flow.
 * Cancel -> restores the snapshot taken when the dialog was opened.
 */
class ExportSettingsDialog(
    private val activity: VideoEditingActivity,
    private val viewModel: VideoEditingViewModel,
    private val sourceFile: File?,
    private val durationMs: Long,
    private val fontPath: String?,
    private val onApplyAndExport: () -> Unit
) {
    // ---- snapshot of pre-dialog state (restored on Cancel) ----
    private var snapRes = 1080
    private var snapFps = 30
    private var snapBitrate = "8M"
    private var snapAudioOnly = false
    private var snapAdvanced = VideoEditingViewModel.AdvancedExport()

    // ---- current dialog state ----
    private var selRes = 1080            // 0 = same as input
    private var selFps = 30              // 0 = same as input
    private var bitrateSameAsInput = true
    private var manualBitrateKbps = 8000
    private var selFormat = "same"       // same|mp4|mkv|mov|webm|avi
    private var selCodec = ""            // "" = same as input (app default chain)
    private var selPreset = "medium"     // ultrafast..veryslow
    private var selAudioFormat = "same"  // same|aac|mp3|opus|flac|wav
    private var selAudioCodec = "aac"    // aac|libmp3lame|libopus|pcm_s16le|flac
    private var selAudioBitrate = ""     // "" = same as input
    private var customW = 0
    private var customH = 0
    private var suppressBoxClear = false

    // ---- probed source info ----
    private var srcW = 0
    private var srcH = 0
    private var srcKbps = 0

    // ---- views ----
    private lateinit var tvEstimatedSize: TextView
    private lateinit var tvCommand: TextView
    private lateinit var etWidth: EditText
    private lateinit var etHeight: EditText
    private lateinit var etBitrate: EditText
    private lateinit var chipBitrateSame: Chip
    private lateinit var cgResolution: ChipGroup
    private lateinit var cgAudioCodec: ChipGroup

    fun show() {
        probeSource()

        snapRes = viewModel.exportResolution.value
        snapFps = viewModel.exportFps.value
        snapBitrate = viewModel.exportBitrate.value
        snapAudioOnly = viewModel.exportAudioOnly.value
        snapAdvanced = viewModel.advancedExport.value.copy()

        selRes = snapRes
        selFps = snapFps
        selCodec = snapAdvanced.videoCodec
        selPreset = snapAdvanced.preset.ifEmpty { "medium" }
        selAudioCodec = snapAdvanced.audioCodec.ifEmpty { "aac" }
        selAudioBitrate = snapAdvanced.audioBitrate
        selFormat = when (snapAdvanced.videoFormat) {
            "mkv" -> "mkv"; "mov" -> "mov"; "webm" -> "webm"; "avi" -> "avi"; else -> "same"
        }
        selAudioFormat = when (snapAdvanced.audioOnlyFormat) {
            "mp3" -> "mp3"; "opus" -> "opus"; "flac" -> "flac"; "wav" -> "wav"; else -> "same"
        }
        customW = snapAdvanced.customWidth
        customH = snapAdvanced.customHeight
        parseBitrate(snapBitrate)

        val dialogView = activity.layoutInflater.inflate(R.layout.dialog_export_settings, null)
        val dialog = MaterialAlertDialogBuilder(activity).setView(dialogView).create()

        bindViews(dialogView)

        dialog.setOnCancelListener { restoreSnapshot() }
        dialogView.findViewById<View>(R.id.btnCancelExport).setOnClickListener { dialog.cancel() }
        dialogView.findViewById<View>(R.id.btnSaveExport).setOnClickListener {
            dialog.dismiss()
            onApplyAndExport()
        }

        refresh()
        dialog.show()
    }

    // ---------------------------------------------------------------- helpers

    private fun parseBitrate(cur: String) {
        val kbps: Int? = when {
            cur.endsWith("M", true) -> cur.dropLast(1).toDoubleOrNull()?.let { (it * 1000).toInt() }
            cur.endsWith("k", true) -> cur.dropLast(1).toIntOrNull()
            cur.toIntOrNull() != null -> cur.toIntOrNull()
            else -> null
        }
        if (kbps != null && kbps in 100..500000) {
            bitrateSameAsInput = false
            manualBitrateKbps = kbps
        } else {
            bitrateSameAsInput = true
        }
    }

    private fun restoreSnapshot() {
        viewModel.setExportSettings(snapRes, snapFps, snapAudioOnly, snapBitrate)
        viewModel.setAdvancedExport(snapAdvanced)
    }

    private fun probeSource() {
        val f = sourceFile ?: return
        if (!f.exists()) return
        try {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(f.absolutePath)
                var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
                srcW = w
                srcH = h
            } finally { r.release() }
        } catch (_: Exception) { }
        val durSec = durationMs / 1000.0
        if (durSec > 0 && f.length() > 0) {
            srcKbps = (f.length() * 8.0 / 1000.0 / durSec).toInt()
        }
    }

    private fun sourceVideoKbps(): Int {
        val total = if (srcKbps > 0) srcKbps else 8000
        return (total - 128).coerceAtLeast(300)
    }

    private fun effectiveVideoKbps(): Int {
        if (!bitrateSameAsInput) {
            val typed = etBitrate.text.toString().toIntOrNull()
            if (typed != null && typed in 100..500000) return typed
        }
        return sourceVideoKbps()
    }

    private fun currentBitrateString(): String = "${effectiveVideoKbps()}k"

    private fun effectiveVideoFormat(): String {
        if (selFormat != "same") return selFormat
        val ext = sourceFile?.extension?.lowercase(Locale.US) ?: ""
        return if (ext in listOf("mp4", "mkv", "mov", "webm", "avi")) ext else "mp4"
    }

    private fun effectiveAudioOnlyFormat(): String {
        if (selAudioFormat != "same") {
            return when (selAudioFormat) {
                "aac" -> "m4a"; "mp3" -> "mp3"; "opus" -> "opus"
                "flac" -> "flac"; "wav" -> "wav"; else -> "m4a"
            }
        }
        val ext = sourceFile?.extension?.lowercase(Locale.US) ?: ""
        return if (ext in listOf("m4a", "mp3", "opus", "flac", "wav")) ext else "m4a"
    }

    private fun estimateSizeText(): String {
        val durSec = durationMs / 1000.0
        if (durSec <= 0.0) return "..."
        val videoKbps = effectiveVideoKbps()
        val audioKbps = when {
            selAudioCodec == "pcm_s16le" -> 1411
            selAudioCodec == "flac" -> 900
            selAudioBitrate.isNotEmpty() -> selAudioBitrate.dropLast(1).toIntOrNull() ?: 128
            else -> 128
        }
        val bytes = (videoKbps + audioKbps) * 1000.0 / 8.0 * durSec
        val body = when {
            bytes < 1024.0 * 1024 -> String.format(Locale.US, "%.0f KB", bytes / 1024.0)
            bytes < 1024.0 * 1024 * 1024 -> String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024))
            else -> String.format(Locale.US, "%.2f GB", bytes / (1024.0 * 1024 * 1024))
        }
        return "~$body"
    }

    // ------------------------------------------------------------ live refresh

    private fun refresh() {
        if (!::tvCommand.isInitialized) return
        viewModel.setExportSettings(selRes, selFps, snapAudioOnly, currentBitrateString())
        viewModel.setAdvancedExport(
            VideoEditingViewModel.AdvancedExport(
                videoFormat = effectiveVideoFormat(),
                videoCodec = selCodec,
                preset = selPreset,
                audioCodec = selAudioCodec,
                audioBitrate = selAudioBitrate,
                audioOnlyFormat = effectiveAudioOnlyFormat(),
                customWidth = customW,
                customHeight = customH
            )
        )
        val ext = viewModel.getOutputExtension(false)
        val previewPath = File(activity.cacheDir, "temp_video_preview$ext").absolutePath
        val srcPath = sourceFile?.absolutePath
        val cmd = if (srcPath != null)
            viewModel.buildConsolidatedFFmpegCommand(srcPath, previewPath, fontPath, activity)
        else null
        tvCommand.text = when {
            cmd == null -> "(preview unavailable)"
            cmd.contains("(CONCAT_LIST:") ->
                cmd.substring(0, cmd.indexOf("(CONCAT_LIST:")).trim() +
                    "  ...(+concat list appended at export time)"
            else -> cmd
        }
        tvEstimatedSize.text = estimateSizeText()
    }

    // -------------------------------------------------------------- view setup

    private fun <T> wireChipRow(
        group: ChipGroup,
        valueById: Map<Int, T>,
        initial: T?,
        selectionRequired: Boolean,
        onPick: (T?) -> Unit
    ) {
        group.setSelectionRequired(selectionRequired)
        val startChip = valueById.entries.firstOrNull { it.value == initial }?.key
            ?: valueById.entries.firstOrNull()?.key
        if (startChip != null) group.check(startChip)
        group.setOnCheckedStateChangeListener { _, ids ->
            val id = ids.firstOrNull()
            onPick(if (id == null) null else valueById[id])
            refresh()
        }
    }

    private fun bindViews(v: View) {
        tvEstimatedSize = v.findViewById(R.id.tvEstimatedSize)
        tvCommand = v.findViewById(R.id.tvCommand)
        etWidth = v.findViewById(R.id.etWidth)
        etHeight = v.findViewById(R.id.etHeight)
        etBitrate = v.findViewById(R.id.etBitrate)
        chipBitrateSame = v.findViewById(R.id.chipBitrateSame)
        cgResolution = v.findViewById(R.id.cgResolution)
        cgAudioCodec = v.findViewById(R.id.cgAudioCodec)

        etWidth.hint = if (srcW > 0) srcW.toString() else "1920"
        etHeight.hint = if (srcH > 0) srcH.toString() else "1080"

        // ---- Resolution chips (custom W x H boxes override the row) ----
        wireChipRow(cgResolution, mapOf(
            R.id.chipResSame to 0, R.id.chipRes360 to 360, R.id.chipRes480 to 480,
            R.id.chipRes720 to 720, R.id.chipRes1080 to 1080,
            R.id.chipRes1440 to 1440, R.id.chipRes2160 to 2160), selRes, false
        ) { picked ->
            if (picked != null) {
                selRes = picked
                if (!suppressBoxClear) clearWxH()
            }
        }

        // ---- custom W x H boxes ----
        val wxhWatcher = object : TextWatcher {
            override fun beforeTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun onTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun afterTextChanged(e: Editable?) { onWxHChanged() }
        }
        etWidth.addTextChangedListener(wxhWatcher)
        etHeight.addTextChangedListener(wxhWatcher)
        if (customW > 0 && customH > 0) {
            etWidth.setText(customW.toString())
            etHeight.setText(customH.toString())
        }

        // ---- Video format ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgVideoFormat), mapOf(
            R.id.chipFmtSame to "same", R.id.chipFmtMp4 to "mp4", R.id.chipFmtMkv to "mkv",
            R.id.chipFmtMov to "mov", R.id.chipFmtWebm to "webm", R.id.chipFmtAvi to "avi"),
            selFormat, true
        ) { picked -> selFormat = picked ?: "same" }

        // ---- Video codec ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgVideoCodec), mapOf(
            R.id.chipCodecSame to "", R.id.chipCodecX264 to "libx264",
            R.id.chipCodecH265 to "hevc_mediacodec", R.id.chipCodecX265 to "libx265",
            R.id.chipCodecVp9 to "libvpx-vp9", R.id.chipCodecAv1 to "libaom-av1"),
            selCodec, true
        ) { picked -> selCodec = picked ?: "" }

        // ---- Video FPS ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgFps), mapOf(
            R.id.chipFpsSame to 0, R.id.chipFps24 to 24, R.id.chipFps25 to 25,
            R.id.chipFps30 to 30, R.id.chipFps60 to 60), selFps, true
        ) { picked -> selFps = picked ?: 0 }

        // ---- Audio format (also drives -c:a; last-touched wins vs codec row) ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgAudioFormat), mapOf(
            R.id.chipAFSame to "same", R.id.chipAFAac to "aac", R.id.chipAFMp3 to "mp3",
            R.id.chipAFOpus to "opus", R.id.chipAFFlac to "flac", R.id.chipAFWav to "wav"),
            selAudioFormat, true
        ) { picked ->
            selAudioFormat = picked ?: "same"
            val codec = when (selAudioFormat) {
                "aac" -> "aac"; "mp3" -> "libmp3lame"; "opus" -> "libopus"
                "flac" -> "flac"; "wav" -> "pcm_s16le"; else -> null
            }
            if (codec != null) {
                selAudioCodec = codec
                val chip = when (codec) {
                    "aac" -> R.id.chipACAac; "libmp3lame" -> R.id.chipACMp3
                    "libopus" -> R.id.chipACOpus; else -> 0
                }
                if (chip != 0) cgAudioCodec.check(chip) else cgAudioCodec.clearCheck()
            }
        }

        // ---- Audio codec ----
        wireChipRow(cgAudioCodec, mapOf(
            R.id.chipACAac to "aac", R.id.chipACMp3 to "libmp3lame",
            R.id.chipACOpus to "libopus", R.id.chipACPcm to "pcm_s16le"),
            selAudioCodec, true
        ) { picked -> if (picked != null) selAudioCodec = picked }

        // ---- Audio bitrate ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgAudioBitrate), mapOf(
            R.id.chipABSame to "", R.id.chipAB128 to "128k", R.id.chipAB192 to "192k",
            R.id.chipAB256 to "256k", R.id.chipAB320 to "320k"),
            selAudioBitrate, true
        ) { picked -> selAudioBitrate = picked ?: "" }

        // ---- Preset ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgPreset), mapOf(
            R.id.chipPresetUltrafast to "ultrafast", R.id.chipPresetSuperfast to "superfast",
            R.id.chipPresetVeryfast to "veryfast", R.id.chipPresetFaster to "faster",
            R.id.chipPresetFast to "fast", R.id.chipPresetMedium to "medium",
            R.id.chipPresetSlow to "slow", R.id.chipPresetSlower to "slower",
            R.id.chipPresetVeryslow to "veryslow"),
            selPreset, true
        ) { picked -> selPreset = picked ?: "medium" }

        // ---- Video bitrate: textbox + "Same as input" chip ----
        chipBitrateSame.isChecked = bitrateSameAsInput
        chipBitrateSame.setOnCheckedChangeListener { _, checked ->
            bitrateSameAsInput = checked
            applyBitrateBoxState()
            refresh()
        }
        etBitrate.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun onTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun afterTextChanged(e: Editable?) { refresh() }
        })
        applyBitrateBoxState()
        if (!bitrateSameAsInput) etBitrate.setText(manualBitrateKbps.toString())
    }

    private fun applyBitrateBoxState() {
        if (bitrateSameAsInput) {
            etBitrate.isEnabled = false
            etBitrate.alpha = 0.45f
            etBitrate.setText(sourceVideoKbps().toString())
        } else {
            etBitrate.isEnabled = true
            etBitrate.alpha = 1f
        }
    }

    private fun clearWxH() {
        customW = 0
        customH = 0
        etWidth.setText("")
        etHeight.setText("")
    }

    private fun onWxHChanged() {
        val w = etWidth.text.toString().toIntOrNull()
        val h = etHeight.text.toString().toIntOrNull()
        if (w != null && h != null && w >= 16 && h >= 16 && w <= 8192 && h <= 8192) {
            customW = w
            customH = h
            if (cgResolution.checkedChipId != View.NO_ID) cgResolution.clearCheck()
        } else {
            customW = 0
            customH = 0
            if (cgResolution.checkedChipId == View.NO_ID) {
                suppressBoxClear = true
                cgResolution.check(R.id.chipResSame)
                suppressBoxClear = false
            }
        }
        refresh()
    }
}
CUTSTUDIO_EOF
  echo "  [ok]   files written (2 drawables + dialog xml + ExportSettingsDialog.kt)"

  # 3b. ViewModel + Activity patches (guarded, idempotent)
  python3 - <<'CUTSTUDIO_PY'
#!/usr/bin/env python3
"""CutStudio stage-3 patches: ViewModel + VideoEditingActivity (export settings v2).

Runs from the repository root (any base state: fresh, post-stage-2 or
post-stage-3). Every patch is guarded and skips itself if already applied.
Exits non-zero with a clear message if an anchor is missing.
"""
import sys

VM = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt'
ACT = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with open(p, 'w', encoding='utf-8') as f:
        f.write(s)


# ===================================================================== ViewModel
def patch_viewmodel():
    s = read(VM)
    orig = s
    fails = []

    def ap(name, old, new, marker=None):
        nonlocal s
        m = marker if marker is not None else new
        if m in s:
            print(f'  [skip] vm: {name}')
            return
        if old in s:
            s = s.replace(old, new, 1)
            print(f'  [ok]   vm: {name}')
            return
        fails.append(name)

    # P1: AdvancedExport state + command-assembly helpers (after setExportSettings)
    ap('AdvancedExport + helpers', '''    fun setExportSettings(resolution: Int, fps: Int, audioOnly: Boolean, bitrate: String? = null) {
        _exportResolution.value = resolution
        _exportFps.value = fps
        _exportAudioOnly.value = audioOnly
        if (bitrate != null) _exportBitrate.value = bitrate
    }
''', '''    fun setExportSettings(resolution: Int, fps: Int, audioOnly: Boolean, bitrate: String? = null) {
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
        val videoCodec: String = "",          // "" = app default chain | libx264|libx265|hevc_mediacodec|libvpx-vp9|libaom-av1
        val preset: String = "",              // "" = none; ultrafast..veryslow (x264/x265 only)
        val audioCodec: String = "aac",       // aac|libmp3lame|libopus|pcm_s16le|flac
        val audioBitrate: String = "",        // "" = same as input (omit -b:a); 128k|192k|256k|320k
        val audioOnlyFormat: String = "m4a",  // m4a|mp3|opus|flac|wav (audio-only export extension)
        val customWidth: Int = 0,             // 0 = not set
        val customHeight: Int = 0             // 0 = not set
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

    /** -c:v ... -pix_fmt ... -b:v ... (-preset only where the codec supports it). */
    private fun buildVideoCodecArgs(defaultEncoder: String): String {
        val adv = _advancedExport.value
        val codec = if (adv.videoCodec.isNotEmpty()) adv.videoCodec
                     else if (defaultEncoder == "software") "libx264" else "h264_mediacodec"
        val sb = StringBuilder("-c:v $codec -pix_fmt yuv420p")
        if (_exportBitrate.value.isNotEmpty()) sb.append(" -b:v ${_exportBitrate.value}")
        if (adv.preset.isNotEmpty() && (codec == "libx264" || codec == "libx265")) {
            sb.append(" -preset ${adv.preset}")
        }
        return sb.toString()
    }

    /** -c:a ... (-b:a skipped for lossless codecs). */
    private fun buildAudioCodecArgs(): String {
        val adv = _advancedExport.value
        val codec = if (adv.audioCodec.isNotEmpty()) adv.audioCodec else "aac"
        val sb = StringBuilder("-c:a $codec")
        val lossless = codec == "pcm_s16le" || codec == "flac"
        if (adv.audioBitrate.isNotEmpty() && !lossless) sb.append(" -b:a ${adv.audioBitrate}")
        return sb.toString()
    }
''', marker='data class AdvancedExport')

    # P2: merge-path final scale filter
    ap('merge path scale filter', '''            filterParts.add("${tempVideoLabel}scale=-2:${_exportResolution.value},fps=${_exportFps.value},format=yuv420p$finalVideoLabel")''',
       '''            filterParts.add(buildOutputScaleFilter(tempVideoLabel, finalVideoLabel))''',
       marker='buildOutputScaleFilter(tempVideoLabel')

    # P3: merge-path codec args
    ap('merge path codec args', '''                val bitrate = _exportBitrate.value
                val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                    ?.getString("default_encoder", "hardware") ?: "hardware"
                val videoCodec = if (defaultEncoder == "software") "-c:v libx264 -pix_fmt yuv420p -b:v $bitrate" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"
                cmd.append(" $videoCodec")''',
       '''                val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                    ?.getString("default_encoder", "hardware") ?: "hardware"
                cmd.append(" ${buildVideoCodecArgs(defaultEncoder)}")''')

    # P4: merge-path audio codec
    ap('merge path audio codec', '''                if (!audioMuted) {
                    cmd.append(" -c:a aac")
                }''',
       '''                if (!audioMuted) {
                    cmd.append(" ${buildAudioCodecArgs()}")
                }''')

    # P5: merge-path audio-only encoder
    ap('merge path audio-only encoder', '''                    // CutStudio ffmpeg might have libmp3lame, fallback to libmp3lame or default mp3 encoder
                    cmd.append(" -c:a libmp3lame -b:a 192k")''',
       '''                    // CutStudio ffmpeg might have libmp3lame, fallback to libmp3lame or default mp3 encoder
                    cmd.append(" ${buildAudioCodecArgs()}")''')

    # P6: non-merge-path final scale filter
    ap('non-merge path scale filter', '''                filterComplexParts.add("${finalVideoLabel}scale=-2:${_exportResolution.value},fps=${_exportFps.value},format=yuv420p${fmtLabel}")''',
       '''                filterComplexParts.add(buildOutputScaleFilter(finalVideoLabel, fmtLabel))''',
       marker='buildOutputScaleFilter(finalVideoLabel')

    # P7+P8: non-merge-path codec + -vf block (one combined region)
    ap('non-merge path codec + vf', '''            val bitrate = _exportBitrate.value
            val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                ?.getString("default_encoder", "hardware") ?: "hardware"
            val videoCodec = if (defaultEncoder == "software") "-c:v libx264 -pix_fmt yuv420p -b:v $bitrate" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"
            // If there are no video filters, we still need to apply the scale and fps output params
            if (!hasVideoFilters) {
                cmd.append(" $videoCodec -vf scale=-2:${_exportResolution.value} -r ${_exportFps.value}")
            } else {
                cmd.append(" $videoCodec")
            }''',
       '''            val defaultEncoder = context?.getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
                ?.getString("default_encoder", "hardware") ?: "hardware"
            // If there are no video filters, we still need to apply the scale and fps output params
            if (!hasVideoFilters) {
                cmd.append(" ${buildVideoCodecArgs(defaultEncoder)}")
                val vfArgs = buildOutputVfArgs()
                if (vfArgs.isNotEmpty()) cmd.append(" $vfArgs")
            } else {
                cmd.append(" ${buildVideoCodecArgs(defaultEncoder)}")
            }''', marker='val vfArgs = buildOutputVfArgs()')

    # P9: non-merge-path audio codec
    ap('non-merge path audio codec', '''            if (!effectiveAudioMuted) {
                cmd.append(" -c:a aac")
            }''',
       '''            if (!effectiveAudioMuted) {
                cmd.append(" ${buildAudioCodecArgs()}")
            }''')

    # P10: non-merge-path audio-only encoder
    ap('non-merge path audio-only encoder', '''        if (_exportAudioOnly.value) {
            if (!effectiveAudioMuted) {
                cmd.append(" -c:a libmp3lame -b:a 192k")''',
       '''        if (_exportAudioOnly.value) {
            if (!effectiveAudioMuted) {
                cmd.append(" ${buildAudioCodecArgs()}")''')

    if fails:
        print(f'FAILED viewmodel patches: {fails}')
        return False
    if s != orig:
        write(VM, s)
    return True


# ===================================================================== Activity
def patch_activity():
    s = read(ACT)
    orig = s
    fails = []

    def ap(name, old, new, marker=None):
        nonlocal s
        m = marker if marker is not None else new
        if m in s:
            print(f'  [skip] act: {name}')
            return
        if old in s:
            s = s.replace(old, new, 1)
            print(f'  [ok]   act: {name}')
            return
        fails.append(name)

    # A2: output extension follows the export settings (container / audio format)
    ap('saveAction ext from settings', '''                val ext = if (isAudioOnly) ".mp3" else ".mp4"''',
       '''                val ext = viewModel.getOutputExtension(isAudioOnly)''')

    # A1: replace showExportSettingsDialog (v1 or stub) with the v2 dialog hookup
    marker = 'onApplyAndExport = { saveAction() }'
    if marker in s:
        print('  [skip] act: showExportSettingsDialog v2')
    else:
        start = '    private fun showExportSettingsDialog() {'
        end = '    private fun showQualitySettingsDialog() {'
        newfunc = '''    private fun showExportSettingsDialog() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                androidx.core.app.ActivityCompat.requestPermissions(this, arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
                android.widget.Toast.makeText(this, "Please grant notification permission and try exporting again.", Toast.LENGTH_LONG).show()
                return
            }
        }
        commitActiveEditsIfAny()
        if (isShowingPreview) dismissPreview()

        ExportSettingsDialog(
            activity = this,
            viewModel = viewModel,
            sourceFile = if (::tempInputFile.isInitialized) tempInputFile else null,
            durationMs = getTotalSequenceDuration(),
            fontPath = fontFilePath,
            onApplyAndExport = { saveAction() }
        ).show()
    }

'''
        if start in s and end in s and s.index(start) < s.index(end):
            i, j = s.index(start), s.index(end)
            s = s[:i] + newfunc + s[j:]
            print('  [ok]   act: showExportSettingsDialog v2')
        else:
            fails.append('showExportSettingsDialog anchors')

    if fails:
        print(f'FAILED activity patches: {fails}')
        return False
    if s != orig:
        write(ACT, s)
    return True


if __name__ == '__main__':
    ok = patch_viewmodel()
    ok = patch_activity() and ok
    if not ok:
        sys.exit(1)
    print('stage3 patches: done')
CUTSTUDIO_PY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  VERIFICATION - XML validity, brace balance, R.id cross-check, key markers
# ---------------------------------------------------------------------------
verify_all() {
  echo "-- verify"
  python3 - <<'CUTSTUDIO_PY'
import xml.etree.ElementTree as ET
import glob, re, sys

bad = 0
xmls = [
    'app/src/main/res/layout/dialog_export_settings.xml',
    'app/src/main/res/layout/activity_video_editing.xml',
    'app/src/main/res/drawable/bg_capsule_pill.xml',
    'app/src/main/res/drawable/bg_command_box.xml',
    'app/src/main/AndroidManifest.xml',
] + glob.glob('app/src/main/res/values*/strings.xml')
for f in xmls:
    try:
        ET.parse(f)
    except Exception as e:
        print(f'  [FAIL] XML {f}: {e}'); bad += 1
print(f'  [ok]   XML valid: {len(xmls)} files')

for f in ['app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt',
          'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt',
          'app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt']:
    s = open(f, encoding='utf-8').read()
    if s.count('{') != s.count('}'):
        print(f'  [FAIL] braces unbalanced in {f}'); bad += 1
print('  [ok]   Kotlin braces balanced')

k = open('app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt', encoding='utf-8').read()
x = open('app/src/main/res/layout/dialog_export_settings.xml', encoding='utf-8').read()
used = set(re.findall(r'R\.id\.(\w+)', k))
defined = set(re.findall(r'\+id/(\w+)', x))
missing = used - defined
if missing:
    print(f'  [FAIL] R.id missing in layout: {sorted(missing)}'); bad += 1
else:
    print(f'  [ok]   R.id cross-check ({len(used)} ids)')

vm = open('app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt', encoding='utf-8').read()
act = open('app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt', encoding='utf-8').read()
checks = [
    ('AdvancedExport present', 'data class AdvancedExport' in vm),
    ('scale helper wired (2 paths)', vm.count('buildOutputScaleFilter(') >= 3),
    ('codec args wired (3 call sites)', vm.count('cmd.append(" ${buildVideoCodecArgs(defaultEncoder)}")') == 3),
    ('audio codec wired (4 call sites)', vm.count('cmd.append(" ${buildAudioCodecArgs()}")') == 4),
    ('vf args wired', 'val vfArgs = buildOutputVfArgs()' in vm),
    ('no stale bitrate maps', 'when (_exportResolution.value)' not in vm),
    ('extension helper used', 'viewModel.getOutputExtension(isAudioOnly)' in act),
    ('dialog v2 hookup', 'onApplyAndExport = { saveAction() }' in act),
    ('no stale dropdown in activity', 'btnSaveDropdown' not in act),
    ('no stale dropdown in layout', 'btnSaveDropdown' not in open('app/src/main/res/layout/activity_video_editing.xml', encoding='utf-8').read()),
]
for name, ok in checks:
    if not ok:
        print(f'  [FAIL] {name}'); bad += 1
print('  [ok]   markers: ' + ', '.join(n for n, _ in checks))

if bad:
    print(f'VERIFY FAILED ({bad} problems)')
    sys.exit(1)
print('VERIFY OK')
CUTSTUDIO_PY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
stage0_home_card           || { echo "ABORT: stage 0"; exit 1; }
stage1_rebrand          || { echo "ABORT: stage 1"; exit 1; }
stage2_export_button_v1 || { echo "ABORT: stage 2"; exit 1; }
stage3_export_settings_v2 || { echo "ABORT: stage 3"; exit 1; }
verify_all              || { echo "ABORT: verify"; exit 1; }
echo ""
echo "ALL STAGES APPLIED SUCCESSFULLY"

