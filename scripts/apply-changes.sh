#!/bin/bash
set -e
echo "=== Apply Changes: start ==="

# ============================================================
# CHANGE: Merge Export split button into one pill button that
# opens an Export Settings dialog (Resolution + Bitrate,
# Cancel/Save buttons). Theme matches app (Material3 dark).
# ============================================================

# ---- Guard: skip if already applied (safe re-runs) ----------
if [ -f app/src/main/res/layout/dialog_export_settings.xml ] && \
   ! grep -q "btnSaveDropdown" app/src/main/res/layout/activity_video_editing.xml; then
  echo "Export dialog changes already applied — nothing to do."
  exit 0
fi

# ---- 1) New dialog layout ----------------------------------
cat > app/src/main/res/layout/dialog_export_settings.xml << 'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:orientation="vertical"
    android:background="@drawable/floating_panel_background"
    android:padding="20dp">

    <TextView
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="Export Settings"
        android:textColor="@color/textColor"
        android:textSize="18sp"
        android:fontFamily="sans-serif-medium" />

    <!-- Resolution -->
    <TextView
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_marginTop="18dp"
        android:text="Resolution"
        android:textColor="@color/iconSecondary"
        android:textSize="12sp"
        android:letterSpacing="0.05"
        android:fontFamily="sans-serif-medium" />

    <com.google.android.material.chip.ChipGroup
        android:id="@+id/cgResolution"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="6dp"
        app:singleSelection="true"
        app:selectionRequired="true">

        <com.google.android.material.chip.Chip
            android:id="@+id/chipRes360"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="360p" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipRes480"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="480p" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipRes720"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="720p" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipRes1080"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="1080p" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipRes1440"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="1440p (2K)" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipRes2160"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="2160p (4K)" />
    </com.google.android.material.chip.ChipGroup>

    <!-- Bitrate -->
    <TextView
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_marginTop="14dp"
        android:text="Video Bitrate"
        android:textColor="@color/iconSecondary"
        android:textSize="12sp"
        android:letterSpacing="0.05"
        android:fontFamily="sans-serif-medium" />

    <com.google.android.material.chip.ChipGroup
        android:id="@+id/cgBitrate"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="6dp"
        app:singleSelection="true"
        app:selectionRequired="true">

        <com.google.android.material.chip.Chip
            android:id="@+id/chipBitrate1"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="1 Mbps" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipBitrate2"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="2 Mbps" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipBitrate5"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="5 Mbps" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipBitrate8"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="8 Mbps" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipBitrate16"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="16 Mbps" />

        <com.google.android.material.chip.Chip
            android:id="@+id/chipBitrate30"
            style="@style/Widget.MaterialComponents.Chip.Choice"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:text="30 Mbps" />
    </com.google.android.material.chip.ChipGroup>

    <!-- Buttons: Cancel (left) / Save (right) -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="24dp"
        android:orientation="horizontal"
        android:gravity="center_vertical">

        <com.google.android.material.button.MaterialButton
            android:id="@+id/btnCancelExport"
            android:layout_width="wrap_content"
            android:layout_height="44dp"
            android:text="@string/cancel"
            android:textColor="@color/textColor"
            android:textSize="14sp"
            android:fontFamily="sans-serif-medium"
            android:insetTop="0dp"
            android:insetBottom="0dp"
            android:paddingStart="24dp"
            android:paddingEnd="24dp"
            app:backgroundTint="@color/surfaceContainerHigh"
            app:strokeColor="@color/outlineVariant"
            app:strokeWidth="1dp"
            app:cornerRadius="22dp" />

        <Space
            android:layout_width="0dp"
            android:layout_height="1dp"
            android:layout_weight="1" />

        <com.google.android.material.button.MaterialButton
            android:id="@+id/btnSaveExport"
            android:layout_width="wrap_content"
            android:layout_height="44dp"
            android:text="@string/str_save"
            android:textColor="@color/onPrimaryContainer"
            android:textSize="14sp"
            android:fontFamily="sans-serif-medium"
            android:insetTop="0dp"
            android:insetBottom="0dp"
            android:paddingStart="28dp"
            android:paddingEnd="28dp"
            app:backgroundTint="@color/primaryContainer"
            app:cornerRadius="22dp" />
    </LinearLayout>
</LinearLayout>
XMLEOF
echo "Created dialog_export_settings.xml"

# ---- 2) Patch all source files (verified exact replacements) ----
python3 << 'PYEOF'
import sys

def load(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()

def save(path, content):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

def patch(content, old, new, label, count=1):
    n = content.count(old)
    if n != count:
        print(f"ERROR: expected {count} occurrence(s) of [{label}], found {n}")
        sys.exit(1)
    print(f"OK: {label} ({count} replacement(s))")
    return content.replace(old, new)

# ============ A) activity_video_editing.xml ============
LAYOUT = 'app/src/main/res/layout/activity_video_editing.xml'
c = load(LAYOUT)

# A1: single full-width Export text (remove split weights)
c = patch(c, '''                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="0dp"
                    android:layout_height="match_parent"
                    android:layout_weight="0.75"''',
'''                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent"''', 'layout: full-width export text')

# A2: remove divider + dropdown arrow
c = patch(c, '''                <View
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
                    android:background="?attr/selectableItemBackground" />

            </LinearLayout>''',
'''            </LinearLayout>''', 'layout: remove dropdown arrow')

save(LAYOUT, c)

# ============ B) VideoEditingActivity.kt ============
ACT = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
c = load(ACT)

# B1: remove btnSaveDropdown declaration
c = patch(c, '''    private lateinit var btnSaveText: View
    private lateinit var btnSaveDropdown: View''',
'''    private lateinit var btnSaveText: View''', 'activity: remove dropdown field')

# B2: remove findViewById wiring
c = patch(c, '''        layoutSaveSplit = findViewById(R.id.layoutSaveSplit)
        btnSaveText = findViewById(R.id.btnSaveText)
        btnSaveDropdown = findViewById(R.id.btnSaveDropdown)''',
'''        layoutSaveSplit = findViewById(R.id.layoutSaveSplit)
        btnSaveText = findViewById(R.id.btnSaveText)''', 'activity: remove dropdown wiring')

# B3: single click listener -> open export settings dialog
c = patch(c, '''        btnSaveText.setBounceClickListener {
            saveAction()
        }

        btnSaveDropdown.setBounceClickListener {
            showQualitySettingsDialog()
        }''',
'''        btnSaveText.setBounceClickListener {
            showExportSettingsDialog()
        }''', 'activity: export opens dialog')

# B4: enabled-state block
c = patch(c, '''        if (::layoutSaveSplit.isInitialized && ::btnSaveText.isInitialized && ::btnSaveDropdown.isInitialized) {
            layoutSaveSplit.alpha = if (isBusy || !hasOps) 0.4f else 1.0f
            btnSaveText.isEnabled = !isBusy && hasOps
            btnSaveDropdown.isEnabled = !isBusy && hasOps''',
'''        if (::layoutSaveSplit.isInitialized && ::btnSaveText.isInitialized) {
            layoutSaveSplit.alpha = if (isBusy || !hasOps) 0.4f else 1.0f
            btnSaveText.isEnabled = !isBusy && hasOps''', 'activity: enabled-state block')

# B5: insert showExportSettingsDialog() before showQualitySettingsDialog()
NEW_DIALOG_FN = '''    private fun showExportSettingsDialog() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                androidx.core.app.ActivityCompat.requestPermissions(this, arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
                android.widget.Toast.makeText(this, "Please grant notification permission and try exporting again.", android.widget.Toast.LENGTH_LONG).show()
                return
            }
        }
        commitActiveEditsIfAny()
        if (isShowingPreview) dismissPreview()

        val dialogView = layoutInflater.inflate(R.layout.dialog_export_settings, null)
        val dialog = MaterialAlertDialogBuilder(this)
            .setView(dialogView)
            .create()

        val cgResolution = dialogView.findViewById<com.google.android.material.chip.ChipGroup>(R.id.cgResolution)
        val cgBitrate = dialogView.findViewById<com.google.android.material.chip.ChipGroup>(R.id.cgBitrate)
        val btnCancel = dialogView.findViewById<View>(R.id.btnCancelExport)
        val btnSave = dialogView.findViewById<View>(R.id.btnSaveExport)

        when (viewModel.exportResolution.value) {
            360 -> cgResolution.check(R.id.chipRes360)
            480 -> cgResolution.check(R.id.chipRes480)
            720 -> cgResolution.check(R.id.chipRes720)
            1080 -> cgResolution.check(R.id.chipRes1080)
            1440 -> cgResolution.check(R.id.chipRes1440)
            2160 -> cgResolution.check(R.id.chipRes2160)
            else -> cgResolution.check(R.id.chipRes1080)
        }

        when (viewModel.exportBitrate.value) {
            "1M" -> cgBitrate.check(R.id.chipBitrate1)
            "2M" -> cgBitrate.check(R.id.chipBitrate2)
            "5M" -> cgBitrate.check(R.id.chipBitrate5)
            "8M" -> cgBitrate.check(R.id.chipBitrate8)
            "16M" -> cgBitrate.check(R.id.chipBitrate16)
            "30M" -> cgBitrate.check(R.id.chipBitrate30)
            else -> cgBitrate.check(R.id.chipBitrate8)
        }

        // Bitrate follows the resolution-based default until the user picks one manually
        var bitrateTouched = false
        var autoFollowing = false
        cgBitrate.setOnCheckedStateChangeListener { _, _ ->
            if (!autoFollowing) bitrateTouched = true
        }
        cgResolution.setOnCheckedStateChangeListener { _, checkedIds ->
            if (!bitrateTouched && checkedIds.isNotEmpty()) {
                val chipId = when (checkedIds[0]) {
                    R.id.chipRes360 -> R.id.chipBitrate1
                    R.id.chipRes480 -> R.id.chipBitrate2
                    R.id.chipRes720 -> R.id.chipBitrate5
                    R.id.chipRes1440 -> R.id.chipBitrate16
                    R.id.chipRes2160 -> R.id.chipBitrate30
                    else -> R.id.chipBitrate8
                }
                autoFollowing = true
                cgBitrate.check(chipId)
                autoFollowing = false
            }
        }

        btnCancel.setBounceClickListener { dialog.dismiss() }

        btnSave.setBounceClickListener {
            val res = when (cgResolution.checkedChipId) {
                R.id.chipRes360 -> 360
                R.id.chipRes480 -> 480
                R.id.chipRes720 -> 720
                R.id.chipRes1440 -> 1440
                R.id.chipRes2160 -> 2160
                else -> 1080
            }
            val bitrate = when (cgBitrate.checkedChipId) {
                R.id.chipBitrate1 -> "1M"
                R.id.chipBitrate2 -> "2M"
                R.id.chipBitrate5 -> "5M"
                R.id.chipBitrate16 -> "16M"
                R.id.chipBitrate30 -> "30M"
                else -> "8M"
            }
            viewModel.setExportSettings(res, viewModel.exportFps.value, viewModel.exportAudioOnly.value, bitrate)
            dialog.dismiss()
            saveAction()
        }

        dialog.show()
    }

'''
c = patch(c, '    private fun showQualitySettingsDialog() {',
           NEW_DIALOG_FN + '    private fun showQualitySettingsDialog() {',
           'activity: insert showExportSettingsDialog()')

save(ACT, c)

# ============ C) VideoEditingViewModel.kt ============
VM = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt'
c = load(VM)

# C1: private StateFlow
c = patch(c, '''    private val _exportAudioOnly = MutableStateFlow(false)''',
'''    private val _exportAudioOnly = MutableStateFlow(false)
    private val _exportBitrate = MutableStateFlow("8M")''', 'viewmodel: add _exportBitrate')

# C2: public StateFlow
c = patch(c, '''    val exportAudioOnly: StateFlow<Boolean> = _exportAudioOnly.asStateFlow()''',
'''    val exportAudioOnly: StateFlow<Boolean> = _exportAudioOnly.asStateFlow()
    val exportBitrate: StateFlow<String> = _exportBitrate.asStateFlow()''', 'viewmodel: add exportBitrate flow')

# C3: setExportSettings with optional bitrate
c = patch(c, '''    fun setExportSettings(resolution: Int, fps: Int, audioOnly: Boolean) {
        _exportResolution.value = resolution
        _exportFps.value = fps
        _exportAudioOnly.value = audioOnly
    }''',
'''    fun setExportSettings(resolution: Int, fps: Int, audioOnly: Boolean, bitrate: String? = null) {
        _exportResolution.value = resolution
        _exportFps.value = fps
        _exportAudioOnly.value = audioOnly
        if (bitrate != null) _exportBitrate.value = bitrate
    }''', 'viewmodel: setExportSettings bitrate param')

# C4: bitrate maps -> stored value (two places, different indents)
c = patch(c, '''                val bitrate = when (_exportResolution.value) {
                    2160 -> "30M"
                    1440 -> "16M"
                    1080 -> "8M"
                    720 -> "5M"
                    480 -> "2M"
                    else -> "1M"
                }''',
'''                val bitrate = _exportBitrate.value''', 'viewmodel: bitrate map #1')

c = patch(c, '''            val bitrate = when (_exportResolution.value) {
                2160 -> "30M"
                1440 -> "16M"
                1080 -> "8M"
                720 -> "5M"
                480 -> "2M"
                else -> "1M"
            }''',
'''            val bitrate = _exportBitrate.value''', 'viewmodel: bitrate map #2')

# C5: apply bitrate to software encoder too (both places)
c = patch(c, '"-c:v libx264 -pix_fmt yuv420p" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"',
          '"-c:v libx264 -pix_fmt yuv420p -b:v $bitrate" else "-c:v h264_mediacodec -pix_fmt yuv420p -b:v $bitrate"',
          'viewmodel: software encoder bitrate', count=2)

save(VM, c)

print("ALL PATCHES APPLIED SUCCESSFULLY")
PYEOF

echo "=== Apply Changes: done ==="
