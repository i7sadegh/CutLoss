#!/usr/bin/env bash
###############################################################################
# CutLoss phase 19 -- amber theme + English-only + fullscreen default off
# + LIVE preparation progress on the export dialog (the dead 0% fix)
#
# User report (4 requests + 1 observation):
#   1. "For starting the file conversion it pauses for a few moments -
#      the loading stays at 0 and doesn't move at all" (watched in the
#      uploaded screen recording: 0% for ~25 seconds, then a jump to
#      47%, 51-55%, 97%).
#   2. Remove every language except English.
#   3. Remove the language picker from Settings entirely.
#   4. The fullscreen editor mode (status + navigation bars hidden) must
#      be OFF by default; the setting stays available in Settings.
#   5. Change the app theme from red/pink to the attached image's color
#      (an amber #FFB200 capsule with BLACK "Save" text - sampled
#      directly from the screenshot).
#
# Root cause 1 (the dead 0%): everything between tapping Export and the
# first ffmpeg statistics callback happens BEFORE the ExportService even
# starts - the smart-plan phase probes every clip (FFprobeKit +
# MediaMetadataRetriever), copies SAF clips to cache, probes the
# keyframe hand-off window, and rasterizes the transition pieces one
# MediaMetadataRetriever extraction per output frame. The phase-18 model
# opens a NEW retriever per frame (setDataSource + OPTION_CLOSEST decode
# + release, ~300-800ms each on a phone), which dominates the latency -
# ~30 frames = the 25 dead seconds the user recorded - while the export
# dialog sits on 0% because no progress source exists yet.
#
# Fix 1 (two parts):
#   a) The planning phase now reports progress: planSmartExport takes an
#      onPrepareProgress callback that ticks the export dialog's 1-14%
#      band (1 = plan started, 2-4 = clip probes, 5-14 = transition
#      frames, monotonic across transitions) and swaps the dialog
#      subtitle to "Preparing export..." / "Rendering transition...".
#      The ffmpeg session progress from the ExportService then maps
#      onto 15-100 (mapFfmpegProgress), so the ring never jumps
#      backwards when the service takes over.
#   b) ONE MediaMetadataRetriever per clip path serves the whole
#      extraction batch (the left still and all the right clip's playing
#      frames share the demuxer when they come from the same file - the
#      common single-video trim case), removing ~30 setDataSource calls
#      per transition. Bonus: tapping Cancel during planning now truly
#      aborts it (saveAction's coroutine is exportJob; the catch
#      rethrows CancellationException instead of showing an error).
#
# Fix 2/3 (English only): the 16 translated values-* folders are
# deleted, the App Language row disappears from the Settings card, the
# language bottom sheet + item layouts and all the picker code in
# MainActivity (getAvailableLanguages / showLanguageDialog /
# updateLanguageUI / LanguageItem + 3 imports) are removed. Android
# resource fallback serves English for every system locale;
# generateLocaleConfig now emits an English-only locales config.
#
# Fix 4: getBoolean("fullscreen_editor", ...) defaults flip true ->
# false in the 3 readers (MainActivity toggle + label, VideoEditing
# onCreate); the Settings toggle itself stays.
#
# Fix 5 (the amber rebrand): colorPrimary / colorSecondary / their
# variants / primaryContainer / activeTool / toolTextActive ->
# #FFB200 (sampled from the user's image), colorPrimaryVariant ->
# #C78D00, activeToolBackground -> #2A1D00. Theme-level onPrimary /
# onSecondary go to a NEW black resource (onAmber) - Material buttons
# get the reference look (black text/icons on amber fills) - while the
# white colorOnPrimary/colorOnSecondary RESOURCES stay for the toolbar
# icons that tint on dark surfaces; every explicit onPrimary-family
# reference that sits ON an amber background (save button, play
# capsules, add-timeline circle, GitHub button, dialog buttons, status
# badges - 20 layout sites + 3 Kotlin sites) switches to onAmber. The
# remaining hardcoded pinks go too: the nav pill, import hero gradients,
# save/banner icons, trim-view selection paints (#FF4081 family), the
# seek bar, the overlay handles, the indeterminate spinner tint. The
# three functional track-category colors (text pink / image orange /
# audio green chips) deliberately stay - they are content markers, not
# the theme, and must stay mutually distinct.
#
# Edits: 5 Kotlin files + 1 model + 15 layouts + 5 drawables +
# 4 values files + gradle + 16 folder deletions + 2 layout deletions.
# Idempotent: re-running skips every edit already present. Apply +
# build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and builds the APK (versionCode
# 17 / 1.0-beta12 - a strict upgrade over the installed 16).
###############################################################################
set -euo pipefail

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
MAIN="app/src/main/java/com/tharunbirla/librecuts/MainActivity.kt"
PIA="app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
UISTATE="app/src/main/java/com/tharunbirla/librecuts/models/VideoProject.kt"
PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
DIV="app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt"
CVS="app/src/main/java/com/tharunbirla/librecuts/customviews/CustomVideoSeeker.kt"
TTV="app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
GRADLE="app/build.gradle"
COLORS="app/src/main/res/values/colors.xml"
THEMES="app/src/main/res/values/themes.xml"
STRINGS="app/src/main/res/values/strings.xml"
MAINXML="app/src/main/res/layout/activity_main.xml"
VEAXML="app/src/main/res/layout/activity_video_editing.xml"
WELCOME="app/src/main/res/layout/dialog_welcome_onboarding.xml"

for f in "$VEA" "$MAIN" "$PIA" "$VM" "$UISTATE" "$PLANNER" "$DIV" "$CVS" \
         "$TTV" "$GRADLE" "$COLORS" "$THEMES" "$STRINGS" "$MAINXML" \
         "$VEAXML" "$WELCOME"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 19: amber theme + English-only + fullscreen-off + live prep progress =="

python3 - <<'PYEOF'
import sys
import os
import glob
import shutil
import subprocess

VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
MAIN = "app/src/main/java/com/tharunbirla/librecuts/MainActivity.kt"
PIA = "app/src/main/java/com/tharunbirla/librecuts/ProjectImportActivity.kt"
VM = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
UISTATE = "app/src/main/java/com/tharunbirla/librecuts/models/VideoProject.kt"
PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
DIV = "app/src/main/java/com/tharunbirla/librecuts/customviews/DraggableImageOverlayView.kt"
CVS = "app/src/main/java/com/tharunbirla/librecuts/customviews/CustomVideoSeeker.kt"
TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
GRADLE = "app/build.gradle"
COLORS = "app/src/main/res/values/colors.xml"
THEMES = "app/src/main/res/values/themes.xml"
STRINGS = "app/src/main/res/values/strings.xml"
MAINXML = "app/src/main/res/layout/activity_main.xml"
VEAXML = "app/src/main/res/layout/activity_video_editing.xml"
WELCOME = "app/src/main/res/layout/dialog_welcome_onboarding.xml"

L = "app/src/main/res/layout/"

edits_applied = 0
edits_skipped = 0
deletions = 0


def apply_edit(path, old, new, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    # idempotency, two shapes:
    #  - append-style edits (the new text CONTAINS the old anchor, e.g.
    #    a tick line inserted after an existing line): applied == the
    #    full new text is present exactly once
    #  - replacement edits: applied == the old anchor is gone (pure
    #    deletions with new == "" or new already a subset of the file
    #    must be judged by the anchor, not by "new in s")
    if new != "" and old in new:
        if s.count(new) == 1:
            edits_skipped += 1
            print("  [skip] " + name)
            return
        if old not in s:
            print("  [FAIL] " + name + ": anchor not found")
            sys.exit(1)
    else:
        if old not in s:
            if new in s or new == "":
                edits_skipped += 1
                print("  [skip] " + name)
                return
            print("  [FAIL] " + name + ": anchor not found")
            sys.exit(1)
    if s.count(old) != 1:
        print("  [FAIL] " + name + ": anchor not unique (%d)" % s.count(old))
        sys.exit(1)
    s = s.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1
    print("  [ ok ] " + name)


def apply_replace_all(path, old, new, expected, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    n = s.count(old)
    if n == 0 and s.count(new) >= expected:
        edits_skipped += 1
        print("  [skip] " + name)
        return
    if n != expected:
        print("  [FAIL] " + name + ": expected %d occurrences, found %d" % (expected, n))
        sys.exit(1)
    s = s.replace(old, new)
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1
    print("  [ ok ] " + name + " (x%d)" % n)


def apply_span_cut(path, start_marker, end_marker, name):
    """Delete whole lines from the line EQUAL to start_marker (inclusive)
    up to (NOT including) the line EQUAL to end_marker. Idempotent: the
    start marker being gone means the cut already happened."""
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        lines = f.readlines()
    if not any(l.rstrip("\r\n") == start_marker for l in lines):
        edits_skipped += 1
        print("  [skip] " + name)
        return
    si = [i for i, l in enumerate(lines) if l.rstrip("\r\n") == start_marker]
    ei = [i for i, l in enumerate(lines) if l.rstrip("\r\n") == end_marker]
    if len(si) != 1 or len(ei) != 1:
        print("  [FAIL] " + name + ": marker not unique (start=%d end=%d)" % (len(si), len(ei)))
        sys.exit(1)
    if ei[0] <= si[0]:
        print("  [FAIL] " + name + ": end marker before start marker")
        sys.exit(1)
    removed = ei[0] - si[0]
    del lines[si[0]:ei[0]]
    with open(path, "w") as f:
        f.writelines(lines)
    edits_applied += 1
    print("  [ ok ] " + name + " (removed %d lines)" % removed)


def delete_path(path, name):
    global deletions
    if not os.path.exists(path):
        print("  [skip] delete " + name)
        return
    if os.path.isdir(path):
        shutil.rmtree(path)
    else:
        os.remove(path)
    deletions += 1
    print("  [ ok ] delete " + name)


# ===================== G1) versionCode 17 / beta12 =====================

apply_edit(GRADLE, """        // Phase 18: 16 / beta11 - the playing-transition + size-estimate
        // build; every APK stays a strict upgrade over the installed one.
        versionCode project.hasProperty('versionCode') ? project.property('versionCode').toInteger() : 16
        versionName "1.0-beta11"
""",
"""        // Phase 18: 16 / beta11 - the playing-transition + size-estimate
        // build; every APK stays a strict upgrade over the installed one.
        // Phase 19: 17 / beta12 - amber theme, English-only, fullscreen
        // default off, live preparation progress on the export dialog.
        versionCode project.hasProperty('versionCode') ? project.property('versionCode').toInteger() : 17
        versionName "1.0-beta12"
""",
"gradle: versionCode 17 + beta12")

# ===================== T1) colors.xml + themes.xml =====================

apply_edit(COLORS, """    <!-- PRIMARY: Electric Pink -->
    <color name="colorPrimary">#FF2A6D</color>
    <color name="colorPrimaryVariant">#C81D52</color>
    <color name="colorOnPrimary">#FFFFFF</color>

    <!-- SECONDARY: Bright Pink Accent -->
    <color name="colorSecondary">#FF2A6D</color>
    <color name="colorSecondaryVariant">#C81D52</color>
    <color name="colorOnSecondary">#FFFFFF</color>
""",
"""    <!-- PRIMARY: Signature Amber (phase 19 rebrand - sampled from the
         user's reference image: an amber capsule with black text) -->
    <color name="colorPrimary">#FFB200</color>
    <color name="colorPrimaryVariant">#C78D00</color>
    <color name="colorOnPrimary">#FFFFFF</color>
    <!-- content drawn ON TOP of amber fills - black, like the reference
         Save button. Theme-level onPrimary/onSecondary and every explicit
         reference sitting on an amber background use this; the white
         colorOn* resources above stay for icons tinted on dark surfaces -->
    <color name="onAmber">#000000</color>

    <!-- SECONDARY: Amber Accent -->
    <color name="colorSecondary">#FFB200</color>
    <color name="colorSecondaryVariant">#C78D00</color>
    <color name="colorOnSecondary">#FFFFFF</color>
""",
"colors: primary/secondary -> amber + onAmber resource")

apply_edit(COLORS, """    <color name="primaryContainer">#FF2A6D</color>
    <color name="onPrimaryContainer">#FFFFFF</color>
""",
"""    <color name="primaryContainer">#FFB200</color>
    <color name="onPrimaryContainer">#FFFFFF</color>
""",
"colors: primaryContainer -> amber")

apply_edit(COLORS, """    <color name="activeTool">#FF2A6D</color>
    <color name="activeToolBackground">#2A1118</color> <!-- Subtle pink tint for active tool -->
    <color name="inactiveTool">#8A8A93</color>
    <color name="inactiveToolBackground">#111114</color>

    <color name="toolTextActive">#FF2A6D</color>
""",
"""    <color name="activeTool">#FFB200</color>
    <color name="activeToolBackground">#2A1D00</color> <!-- Subtle amber tint for active tool -->
    <color name="inactiveTool">#8A8A93</color>
    <color name="inactiveToolBackground">#111114</color>

    <color name="toolTextActive">#FFB200</color>
""",
"colors: tool colors -> amber")

# theme-level on-colors go black (Material fills are amber now); the
# white resources above stay for the dark-surface icon tints
apply_replace_all(THEMES, "<item name=\"colorOnPrimary\">@color/colorOnPrimary</item>",
                  "<item name=\"colorOnPrimary\">@color/onAmber</item>", 2,
                  "themes: AppTheme+Editor colorOnPrimary -> onAmber")
apply_replace_all(THEMES, "<item name=\"colorOnSecondary\">@color/colorOnSecondary</item>",
                  "<item name=\"colorOnSecondary\">@color/onAmber</item>", 2,
                  "themes: AppTheme+Editor colorOnSecondary -> onAmber")

# ===================== T2) drawable recolors =====================

apply_edit("app/src/main/res/drawable/bg_nav_active_pill.xml", """    <solid android:color="#20FF2A6D" />
    <stroke
        android:width="1dp"
        android:color="#4DFF2A6D" />
""",
"""    <solid android:color="#20FFB200" />
    <stroke
        android:width="1dp"
        android:color="#4DFFB200" />
""",
"drawable: nav active pill -> amber")

apply_edit("app/src/main/res/drawable/bg_import_hero.xml",
          "        android:startColor=\"#2A1118\"",
          "        android:startColor=\"#2A1D00\"",
          "drawable: import hero gradient -> amber tint")

apply_edit("app/src/main/res/drawable/bg_hero_bento_primary.xml",
          "        android:startColor=\"#2A1118\"",
          "        android:startColor=\"#2A1D00\"",
          "drawable: hero bento primary gradient -> amber tint")

apply_edit("app/src/main/res/drawable/ic_save_color_24.xml",
          "android:tint=\"#FF4081\"",
          "android:tint=\"#FFB200\"",
          "drawable: save icon tint -> amber")

apply_edit("app/src/main/res/drawable/ic_banner_foreground.xml",
          "android:fillColor=\"#FF4081\"",
          "android:fillColor=\"#FFB200\"",
          "drawable: banner accent -> amber")

# ===================== T3) hardcoded pinks in layouts =====================

apply_edit(VEAXML, "            android:indeterminateTint=\"#FF4081\" />",
          "            android:indeterminateTint=\"#FFB200\" />",
          "editing layout: indeterminate spinner -> amber")

apply_edit(WELCOME, "                    app:tint=\"#E91E63\" />",
          "                    app:tint=\"#FFB200\" />",
          "welcome dialog: heart icon tint -> amber")

# ===================== T4) onPrimary-family refs on amber fills =====================
# Every reference below sits ON a primary/primaryContainer background and
# switches to the black onAmber resource; the colorOnSecondary toolbar
# icons (dark surfaces) are deliberately NOT touched.

apply_replace_all(MAINXML, "@color/onPrimaryContainer", "@color/onAmber", 5,
                  "main layout: 5 amber-bg refs -> onAmber (3 circle icons + GitHub text/icon)")

apply_replace_all(VEAXML, "@color/onPrimaryContainer", "@color/onAmber", 3,
                  "editing layout: 3 amber-bg refs -> onAmber (save text + 2 play icons)")
apply_replace_all(VEAXML, "app:tint=\"@color/colorOnPrimary\"",
                  "app:tint=\"@color/onAmber\"", 1,
                  "editing layout: add-timeline icon on amber circle -> onAmber")

for f, old, expected, note in [
    ("dialog_export_settings.xml", "android:textColor=\"@color/onPrimaryContainer\"", 1,
     "export settings button text"),
    ("trim_bottom_sheet_dialog.xml", "android:textColor=\"@color/onPrimaryContainer\"", 1,
     "trim sheet button text"),
    ("activity_project_import.xml", "android:textColor=\"@color/onPrimaryContainer\"", 1,
     "project import button text"),
    ("dialog_welcome_onboarding.xml", "android:textColor=\"@color/onPrimaryContainer\"", 1,
     "welcome button text"),
    ("dialog_audio_fade.xml", "android:textColor=\"@color/onPrimaryContainer\"", 1,
     "audio fade button text"),
    ("export_quality_bottom_sheet_dialog.xml", "@color/onPrimaryContainer", 2,
     "export quality button text + icon"),
    ("activity_error_display.xml", "android:textColor=\"@color/colorOnPrimary\"", 1,
     "error display button text"),
    ("dialog_unsaved_changes.xml", "app:tint=\"@color/colorOnPrimary\"", 1,
     "unsaved-changes warning icon on amber circle"),
    ("dialog_transitions.xml", "android:textColor=\"@color/colorOnPrimary\"", 1,
     "transitions dialog button text"),
    ("item_dependency.xml", "app:tint=\"@color/onPrimaryContainer\"", 1,
     "dependency status badge icon"),
]:
    apply_replace_all(L + f, old, old.replace("colorOnPrimary", "onAmber")
                      .replace("onPrimaryContainer", "onAmber"), expected,
                      "layout %s -> onAmber" % note)

# ===================== T5) hardcoded pinks in Kotlin =====================

apply_edit(DIV, "        color = Color.parseColor(\"#FF2A6D\")",
          "        color = Color.parseColor(\"#FFB200\")",
          "DraggableImageOverlayView: handle fill -> amber")

apply_replace_all(CVS, "color = Color.parseColor(\"#FF2A6D\") // Primary theme color",
                  "color = Color.parseColor(\"#FFB200\") // Primary theme color", 2,
                  "CustomVideoSeeker: accent line + handle -> amber")

# the class doc comment still advertises the old pink accent (unicode
# escapes for the bullet and arrow keep this script ASCII)
apply_edit(CVS, " *  \u2022 Playhead line color \u2192 #FF4081 (accent)\n",
          " *  \u2022 Playhead line color \u2192 #FFB200 (accent)\n",
          "CustomVideoSeeker: doc comment color -> amber")

apply_replace_all(TTV, "Color.parseColor(\"#FF4081\")", "Color.parseColor(\"#FFB200\")", 3,
                  "TrackTrimView: selection borders + handle -> amber")

# VEA: the speed chip's selected label sits on the amber selected pill
apply_edit(VEA, "                txt?.setTextColor(androidx.core.content.ContextCompat.getColor(this, R.color.colorOnPrimary))",
          "                txt?.setTextColor(androidx.core.content.ContextCompat.getColor(this, R.color.onAmber))",
          "VEA: speed chip selected text -> onAmber")
apply_edit(TTV, "                    borderPaint.color = Color.parseColor(\"#FF2A6D\") // Electric Pink selection",
          "                    borderPaint.color = Color.parseColor(\"#FFB200\") // Amber selection",
          "TrackTrimView: main-track selection border -> amber")
apply_edit(TTV, "                        color = Color.parseColor(\"#33FF2A6D\")",
          "                        color = Color.parseColor(\"#33FFB200\")",
          "TrackTrimView: selection overlay -> amber")
apply_edit(TTV, "                    color = Color.parseColor(\"#1AFF4081\")",
          "                    color = Color.parseColor(\"#1AFFB200\")",
          "TrackTrimView: track selection overlay -> amber")

# ProjectImportActivity: status badge icons sit on amber circles
apply_edit(PIA, "holder.ivStatusBadge.setColorFilter(ContextCompat.getColor(this@ProjectImportActivity, R.color.onPrimaryContainer))",
          "holder.ivStatusBadge.setColorFilter(ContextCompat.getColor(this@ProjectImportActivity, R.color.onAmber))",
          "ProjectImportActivity: found badge -> onAmber")
apply_edit(PIA, """                holder.ivStatusBadge.setImageResource(R.drawable.ic_close_24)
                holder.ivStatusBadge.setColorFilter(ContextCompat.getColor(this@ProjectImportActivity, R.color.colorOnPrimary))
""",
"""                holder.ivStatusBadge.setImageResource(R.drawable.ic_close_24)
                holder.ivStatusBadge.setColorFilter(ContextCompat.getColor(this@ProjectImportActivity, R.color.onAmber))
""",
"ProjectImportActivity: missing badge -> onAmber")

# ===================== L1) delete the translations + language layouts =====================

for d in ["ar", "cs", "de", "el", "es", "et", "hi", "in", "it", "nl",
          "pt-rBR", "ru", "sk", "ta", "tr", "zh-rCN"]:
    delete_path("app/src/main/res/values-" + d, "values-" + d + "/")

delete_path("app/src/main/res/layout/language_bottom_sheet_dialog.xml",
            "language_bottom_sheet_dialog.xml")
delete_path("app/src/main/res/layout/item_language_selection.xml",
            "item_language_selection.xml")

# ===================== L2) Settings card: drop the App Language row =====================

apply_span_cut(MAINXML,
               "                <!-- App Language Setting -->",
               "                <!-- Video Export Folder Setting -->",
               "main layout: App Language row + separator cut")

# ===================== L3) MainActivity: drop the language picker =====================

apply_edit(MAIN, """import android.widget.TextView
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.tharunbirla.librecuts.databinding.ActivityMainBinding
""",
"""import android.widget.TextView
import com.tharunbirla.librecuts.databinding.ActivityMainBinding
""",
"MainActivity: language imports cut")

apply_span_cut(MAIN,
               "        binding.btnChangeLanguage.setBounceClickListener {",
               "        binding.btnCheckForUpdates.setBounceClickListener {",
               "MainActivity: btnChangeLanguage wiring cut")

apply_span_cut(MAIN,
               "        updateLanguageUI()",
               "        // Initialize Haptic Feedback preference",
               "MainActivity: updateLanguageUI() call cut")

apply_span_cut(MAIN,
               "    private data class LanguageItem(",
               "    private fun updateHapticFeedbackUI() {",
               "MainActivity: LanguageItem + getAvailableLanguages + updateLanguageUI cut")

apply_span_cut(MAIN,
               "    private fun showLanguageDialog() {",
               "    private fun switchTab(tabIndex: Int) {",
               "MainActivity: showLanguageDialog cut")

# ===================== L4) strings.xml =====================

apply_edit(STRINGS, """    <string name="str_app_language">App Language</string>
    <string name="str_system_default">System Default</string>
    <string name="str_opacity">Opacity</string>
""",
"""    <string name="str_opacity">Opacity</string>
""",
"str_app_language + str_system_default removed")

apply_edit(STRINGS,
          "    <string name=\"str_please_don_t_close_the_app\">Please don\\'t close the app</string>",
          "    <string name=\"str_please_don_t_close_the_app\">Please don\\'t close the app</string>\n"
          "    <string name=\"str_preparing_analyzing\">Preparing export...</string>\n"
          "    <string name=\"str_preparing_transition\">Rendering transition...</string>",
          "preparation stage strings added")

# ===================== F1) fullscreen editor OFF by default =====================

apply_edit(MAIN, """        binding.btnToggleFullscreenEditor.setBounceClickListener {
            val current = prefs.getBoolean("fullscreen_editor", true)
""",
"""        binding.btnToggleFullscreenEditor.setBounceClickListener {
            val current = prefs.getBoolean("fullscreen_editor", false)
""",
"MainActivity: fullscreen toggle default false")

apply_edit(MAIN, """    private fun updateFullscreenEditorUI() {
        val prefs = getSharedPreferences("librecuts_prefs", MODE_PRIVATE)
        val isFullscreen = prefs.getBoolean("fullscreen_editor", true)
""",
"""    private fun updateFullscreenEditorUI() {
        val prefs = getSharedPreferences("librecuts_prefs", MODE_PRIVATE)
        val isFullscreen = prefs.getBoolean("fullscreen_editor", false)
""",
"MainActivity: fullscreen label default false")

apply_edit(VEA, """        // Apply system UI visibility based on user setting
        val prefs = getSharedPreferences("librecuts_prefs", MODE_PRIVATE)
        val isFullscreen = prefs.getBoolean("fullscreen_editor", true)
""",
"""        // Apply system UI visibility based on user setting
        // (phase 19: OFF by default - the user flips it on in Settings)
        val prefs = getSharedPreferences("librecuts_prefs", MODE_PRIVATE)
        val isFullscreen = prefs.getBoolean("fullscreen_editor", false)
""",
"VideoEditingActivity: fullscreen default false")

# ===================== P1-P7) planner: live prep progress =====================

# R import for the stage string resources
apply_edit(PLANNER, """import com.tharunbirla.librecuts.models.EditOperation
import com.tharunbirla.librecuts.models.VideoProject
""",
"""import com.tharunbirla.librecuts.R
import com.tharunbirla.librecuts.models.EditOperation
import com.tharunbirla.librecuts.models.VideoProject
""",
"planner: R import for stage strings")

# P1) planSmartExport signature + pass-through
apply_edit(PLANNER, """        keyframeCut: Boolean = false,
        exportSeparateFiles: Boolean = false,
        movFastStart: Boolean = true,
        preserveMetadata: Boolean = true
    ): SmartPlan? {
        try {
            return planInternal(
                context, project, sourceFilePath, outputFilePath,
                exportResolution, exportFps, exportBitrate, audioOnly,
                advancedVideoCodec, advancedAudioCodec, advancedPreset,
                advancedAudioBitrate, customWidth, customHeight, videoFormat,
                keyframeCut, exportSeparateFiles, movFastStart, preserveMetadata
            )
""",
"""        keyframeCut: Boolean = false,
        exportSeparateFiles: Boolean = false,
        movFastStart: Boolean = true,
        preserveMetadata: Boolean = true,
        onPrepareProgress: ((Int, Int) -> Unit)? = null
    ): SmartPlan? {
        try {
            return planInternal(
                context, project, sourceFilePath, outputFilePath,
                exportResolution, exportFps, exportBitrate, audioOnly,
                advancedVideoCodec, advancedAudioCodec, advancedPreset,
                advancedAudioBitrate, customWidth, customHeight, videoFormat,
                keyframeCut, exportSeparateFiles, movFastStart, preserveMetadata,
                onPrepareProgress
            )
""",
"planner: planSmartExport takes onPrepareProgress")

# P2) planInternal signature + the instant entry tick (fires before any
# early-return gate, so the dialog leaves 0% immediately)
apply_edit(PLANNER, """        keyframeCut: Boolean,
        exportSeparateFiles: Boolean,
        movFastStart: Boolean,
        preserveMetadata: Boolean
    ): SmartPlan? {
        sweepStaleWorkDirs(context)
""",
"""        keyframeCut: Boolean,
        exportSeparateFiles: Boolean,
        movFastStart: Boolean,
        preserveMetadata: Boolean,
        onPrepareProgress: ((Int, Int) -> Unit)? = null
    ): SmartPlan? {
        // phase 19: 1% the moment planning starts - the dialog must
        // never sit dead on 0% while probes and frame extraction run
        onPrepareProgress?.invoke(1, R.string.str_preparing_analyzing)
        sweepStaleWorkDirs(context)
""",
"planner: planInternal signature + entry tick")

# P4) tick after the reference clip probe
apply_edit(PLANNER, """        // ---- probe the main clip (reference parameters) ----
        val refParams = probeMedia(context, Uri.fromFile(File(sourceFilePath)), sourceFilePath) ?: return null
""",
"""        // ---- probe the main clip (reference parameters) ----
        val refParams = probeMedia(context, Uri.fromFile(File(sourceFilePath)), sourceFilePath) ?: return null
        onPrepareProgress?.invoke(2, R.string.str_preparing_analyzing)
""",
"planner: tick after reference probe")

# P5) tick after each merged clip's cache copy + probe
apply_edit(PLANNER, """                val p = probeMedia(context, item.uri, localPath) ?: return null
""",
"""                val p = probeMedia(context, item.uri, localPath) ?: return null
                onPrepareProgress?.invoke((2 + clips.size).coerceAtMost(4), R.string.str_preparing_analyzing)
""",
"planner: tick per merged clip probe")

# P6) shared retrievers replace the per-frame open/close
apply_edit(PLANNER, """        fun extractBoundaryFrame(path: String, timeMs: Long): android.graphics.Bitmap? {
            val retriever = android.media.MediaMetadataRetriever()
            return try {
                retriever.setDataSource(path)
                retriever.getFrameAtTime(
                    timeMs * 1000L, android.media.MediaMetadataRetriever.OPTION_CLOSEST
                )
            } catch (e: Exception) {
                Log.w(TAG, "transition frame extraction failed: " + e.message)
                null
            } finally {
                try { retriever.release() } catch (e: Exception) {}
            }
        }
""",
"""        // Phase 19: ONE retriever per clip path serves the whole
        // extraction batch - reopening the demuxer per frame dominated
        // the planning latency (the dead 0% the user watched). The left
        // still and the right clip's playing frames share the retriever
        // when both spans come from the same file (the common
        // single-video trim case).
        fun openRetriever(path: String): android.media.MediaMetadataRetriever? {
            return try {
                android.media.MediaMetadataRetriever().also { it.setDataSource(path) }
            } catch (e: Exception) {
                Log.w(TAG, "transition retriever open failed: " + e.message)
                null
            }
        }
        fun frameAt(retriever: android.media.MediaMetadataRetriever?, timeMs: Long): android.graphics.Bitmap? {
            if (retriever == null) return null
            return try {
                retriever.getFrameAtTime(
                    timeMs * 1000L, android.media.MediaMetadataRetriever.OPTION_CLOSEST
                )
            } catch (e: Exception) {
                Log.w(TAG, "transition frame extraction failed: " + e.message)
                null
            }
        }
        // Phase 19: monotonic preparation tick for the transition frames
        // (5..14 of the export dialog band) - multiple transitions never
        // move the ring backwards.
        var prepFrameTick = 5
""",
"planner: shared retriever helpers + prepFrameTick")

# P7) the transition extraction block itself
apply_edit(PLANNER, """            // the effect layer: the left clip's frozen last frame
            val endA = extractBoundaryFrame(
                left.path, (left.trimEndMs - 1L).coerceAtLeast(left.trimStartMs)
            ) ?: return false
            // the base layer: the right clip's PLAYING frames, one
            // extraction per output frame on the reference-rate grid
            // (OPTION_CLOSEST = the frame nearest that instant, exactly
            // what the player shows under the preview overlay)
            val rightStartMs = right.trimStartMs
            val framesDir = File(workDir, "trans_" + gap)
            val renderOk = TransitionFrameRenderer.renderTransitionFrames(
                type, endA,
                { i ->
                    extractBoundaryFrame(
                        right.path,
                        rightStartMs + Math.round(i * 1000.0 / transFpsValue)
                    )
                },
                framesDir, frameCount, effectCount, displayWidth, displayHeight
            )
            try { endA.recycle() } catch (e: Exception) {}
            if (!renderOk) return false
""",
"""            // the effect layer: the left clip's frozen last frame; the
            // base layer: the right clip's PLAYING frames, one extraction
            // per output frame on the reference-rate grid (OPTION_CLOSEST =
            // the frame nearest that instant, exactly what the player
            // shows under the preview overlay). Phase 19: shared
            // retrievers (one per clip path) and a live preparation tick
            // per extracted frame, so the export dialog visibly advances
            // while the frames rasterize instead of sitting dead on 0%.
            val leftRetriever = openRetriever(left.path)
            val rightRetriever = if (right.path == left.path) leftRetriever else openRetriever(right.path)
            var renderOk = false
            var endA: android.graphics.Bitmap? = null
            try {
                endA = frameAt(
                    leftRetriever, (left.trimEndMs - 1L).coerceAtLeast(left.trimStartMs)
                )
                if (endA == null) return false
                val rightStartMs = right.trimStartMs
                val framesDir = File(workDir, "trans_" + gap)
                renderOk = TransitionFrameRenderer.renderTransitionFrames(
                    type, endA,
                    { i ->
                        val tick = 5 + i * 10 / Math.max(1, frameCount)
                        if (tick > prepFrameTick) prepFrameTick = tick
                        onPrepareProgress?.invoke(
                            prepFrameTick.coerceAtMost(14),
                            R.string.str_preparing_transition
                        )
                        frameAt(
                            rightRetriever,
                            rightStartMs + Math.round(i * 1000.0 / transFpsValue)
                        )
                    },
                    framesDir, frameCount, effectCount, displayWidth, displayHeight
                )
            } finally {
                try { endA?.recycle() } catch (e: Exception) {}
                try { leftRetriever?.release() } catch (e: Exception) {}
                if (rightRetriever !== leftRetriever) {
                    try { rightRetriever?.release() } catch (e: Exception) {}
                }
            }
            if (!renderOk) return false
""",
"planner: transition block -> shared retrievers + live ticks")

# ===================== P8) UiState + ViewModel =====================

apply_edit(UISTATE, """data class VideoEditingUiState(
    val isLoading: Boolean = false,
    val isExporting: Boolean = false,
    val exportProgress: Int = 0, // 0-100
    val errorMessage: String? = null,
""",
"""data class VideoEditingUiState(
    val isLoading: Boolean = false,
    val isExporting: Boolean = false,
    val exportProgress: Int = 0, // 0-100
    val exportStageRes: Int? = null, // phase 19: preparation stage label (string resource)
    val errorMessage: String? = null,
""",
"UiState: exportStageRes field")

apply_edit(VM, """    fun updateExportProgress(progress: Int) {
        updateUiState { it.copy(exportProgress = progress.coerceIn(0, 100)) }
    }
""",
"""    fun updateExportProgress(progress: Int) {
        updateUiState { it.copy(exportProgress = progress.coerceIn(0, 100), exportStageRes = null) }
    }

    /**
     * Phase 19: live progress while the export is still being PLANNED
     * (clip probing + transition frame rasterization) - the 1-14% band
     * of the export dialog, with the stage label replacing the default
     * subtitle. Any real ffmpeg progress clears the stage again
     * (updateExportProgress sets exportStageRes back to null).
     */
    fun updateExportPreparation(stageRes: Int, progress: Int) {
        updateUiState { it.copy(exportProgress = progress.coerceIn(0, 14), exportStageRes = stageRes) }
    }
""",
"ViewModel: updateExportPreparation + stage clearing")

# ===================== P9) VideoEditingActivity wiring =====================

# the receiver maps the service progress onto 15-100
apply_edit(VEA, """                com.tharunbirla.librecuts.services.ExportService.ACTION_EXPORT_PROGRESS -> {
                    val progress = intent.getIntExtra(com.tharunbirla.librecuts.services.ExportService.EXTRA_PROGRESS, 0)
                    viewModel.updateExportProgress(progress)
                }
""",
"""                com.tharunbirla.librecuts.services.ExportService.ACTION_EXPORT_PROGRESS -> {
                    val progress = intent.getIntExtra(com.tharunbirla.librecuts.services.ExportService.EXTRA_PROGRESS, 0)
                    viewModel.updateExportProgress(mapFfmpegProgress(progress))
                }
""",
"VEA: receiver maps service progress onto 15-100")

# the dialog subtitle shows the preparation stage while planning
apply_edit(VEA, """                if (uiState.isExporting) {
                    loadingScreen.visibility = View.GONE
                    val progress = uiState.exportProgress
                    exportScreen.findViewById<TextView>(R.id.tvExportPercentage)?.text = "$progress%"
                    exportScreen.findViewById<android.widget.ProgressBar>(R.id.exportProgressBar)?.progress = progress
                } else {
""",
"""                if (uiState.isExporting) {
                    loadingScreen.visibility = View.GONE
                    val progress = uiState.exportProgress
                    exportScreen.findViewById<TextView>(R.id.tvExportPercentage)?.text = "$progress%"
                    exportScreen.findViewById<android.widget.ProgressBar>(R.id.exportProgressBar)?.progress = progress
                    // phase 19: the preparation stage label replaces the
                    // default subtitle while the plan is being built
                    exportScreen.findViewById<TextView>(R.id.tvExportMessage)?.setText(
                        uiState.exportStageRes ?: R.string.str_please_don_t_close_the_app
                    )
                } else {
""",
"VEA: collector shows the preparation stage label")

# saveAction feeds the planner ticks into the ViewModel
apply_edit(VEA, """                            preserveMetadata = viewModel.advancedExport.value.preserveMetadata
                        )?.planFile?.absolutePath
""",
"""                            preserveMetadata = viewModel.advancedExport.value.preserveMetadata,
                            onPrepareProgress = { pct, stageRes ->
                                viewModel.updateExportPreparation(stageRes, pct)
                            }
                        )?.planFile?.absolutePath
""",
"VEA: saveAction wires onPrepareProgress")

# saveAction's coroutine becomes exportJob so Cancel truly aborts the
# planning phase
apply_edit(VEA, """        lifecycleScope.launch(Dispatchers.Main) {
            var tempOutputFile: File? = null
""",
"""        exportJob = lifecycleScope.launch(Dispatchers.Main) {
            var tempOutputFile: File? = null
""",
"VEA: saveAction coroutine is exportJob (cancellable)")

# a user cancel must not surface as an error dialog
apply_edit(VEA, """            } catch (e: Exception) {
                tempOutputFile?.let { if (it.exists()) it.delete() }
                viewModel.exportError(e.message ?: "Unknown error")
                Log.e(TAG, "Export start exception: ${e.message}", e)
            }
""",
"""            } catch (e: Exception) {
                // phase 19: a user cancel (cancelExport -> exportJob.cancel)
                // must not surface as an error dialog - rethrow so the
                // coroutine simply ends cancelled
                if (e is kotlinx.coroutines.CancellationException) throw e
                tempOutputFile?.let { if (it.exists()) it.delete() }
                viewModel.exportError(e.message ?: "Unknown error")
                Log.e(TAG, "Export start exception: ${e.message}", e)
            }
""",
"VEA: catch rethrows CancellationException")

# the 15-100 mapping helper, next to cancelExport
apply_edit(VEA, """    private fun cancelExport() {
""",
"""    /**
     * Phase 19: the export dialog's 1-14% band belongs to the planning
     * stage (clip probing + transition frame rasterization); the ffmpeg
     * session progress maps onto the remaining 15-100 so the ring never
     * jumps backwards when the background service takes over.
     */
    private fun mapFfmpegProgress(progress: Int): Int {
        val p = progress.coerceIn(0, 100)
        return if (p >= 100) 100 else 15 + p * 85 / 100
    }

    private fun cancelExport() {
""",
"VEA: mapFfmpegProgress helper")

print("edits applied: %d, skipped: %d, deletions: %d" %
      (edits_applied, edits_skipped, deletions))

# ========================= gates =========================
fail = []


def check(cond, msg):
    print(("  [ok] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fail.append(msg)


def read(p):
    with open(p) as f:
        return f.read()


def rg_count(pattern, root="app/src/main"):
    r = subprocess.run(["grep", "-r", "-o", pattern, root],
                       capture_output=True, text=True)
    return r.stdout.count(pattern) if r.returncode in (0, 1) else -1


G = read(GRADLE)
C = read(COLORS)
T = read(THEMES)
S = read(STRINGS)
MA = read(MAIN)
VE = read(VEA)
PI = read(PIA)
VMV = read(VM)
US = read(UISTATE)
PL = read(PLANNER)
MX = read(MAINXML)
VX = read(VEAXML)

# 1) the version bump
check(G.count("toInteger() : 17") == 1, "gradle versionCode 17")
check(G.count("toInteger() : 16") == 0, "gradle versionCode 16 gone")
check(G.count('"1.0-beta12"') == 1, "gradle versionName beta12")
check(G.count('"1.0-beta11"') == 0, "gradle versionName beta11 gone")

# 2) the amber theme
check(C.count("#FFB200") == 5, "colors.xml: 5 amber primaries (got %d)" % C.count("#FFB200"))
check(C.count("#C78D00") == 2, "colors.xml: 2 amber variants")
check(C.count("#2A1D00") == 1, "colors.xml: activeToolBackground amber tint")
check(C.count('name="onAmber"') == 1, "colors.xml: onAmber black resource")
check(T.count("@color/onAmber") == 4, "themes.xml: 2 styles x onPrimary+onSecondary -> onAmber")
check(rg_count("#FF2A6D") == 0, "no #FF2A6D anywhere in app/src/main")
check(rg_count("#C81D52") == 0, "no #C81D52 anywhere")
check(rg_count("#2A1118") == 0, "no #2A1118 anywhere")
check(rg_count("#FF4081") == 0, "no #FF4081 anywhere")
check(rg_count("#33FF2A6D") == 0, "no #33FF2A6D anywhere")
check(rg_count("#1AFF4081") == 0, "no #1AFF4081 anywhere")
check(rg_count("#E91E63") == 1,
      "the single functional text-track pink kept (got %d)" % rg_count("#E91E63"))
check(rg_count("@color/onAmber") == 24,
      "24 @color/onAmber refs (4 theme + 20 layout) (got %d)" % rg_count("@color/onAmber"))
check(rg_count("R.color.onAmber") == 3,
      "3 R.color.onAmber refs in Kotlin (got %d)" % rg_count("R.color.onAmber"))
check(read("app/src/main/res/drawable/ic_save_color_24.xml").count("#FFB200") == 1,
      "save icon amber tint x1")
check(read("app/src/main/res/drawable/ic_banner_foreground.xml").count("#FFB200") == 1,
      "banner amber fill x1")

# 3) English only
leftover = sorted(glob.glob("app/src/main/res/values-*"))
check(len(leftover) == 0, "no values-* locale folders left (%s)" % leftover)
for tok in ["btnChangeLanguage", "tvCurrentLanguage", "showLanguageDialog",
            "getAvailableLanguages", "updateLanguageUI", "LanguageItem",
            "str_app_language", "str_system_default",
            "language_bottom_sheet_dialog", "item_language_selection",
            "LocaleListCompat", "LocaleConfig"]:
    check(rg_count(tok) == 0, "language token gone: %s" % tok)
check(MA.count("AppCompatDelegate") == 0, "MainActivity: AppCompatDelegate gone")
check(MA.count("BottomSheetDialog") == 0, "MainActivity: BottomSheetDialog import gone")
check(MA.count("showEncoderDialog") == 2, "MainActivity: encoder dialog survives (def + call)")
check(MA.count("btnToggleFullscreenEditor") == 1, "MainActivity: fullscreen toggle wiring stays")
check(MA.count("btnTranslate") == 1, "MainActivity: About translate link survives")

# 4) fullscreen OFF by default
check(rg_count('getBoolean("fullscreen_editor", false)') == 3,
      "fullscreen_editor default false x3 (got %d)" % rg_count('getBoolean("fullscreen_editor", false)'))
check(rg_count('getBoolean("fullscreen_editor", true)') == 0,
      "fullscreen_editor default true gone")

# 5) the live preparation progress
check(PL.count("onPrepareProgress") == 7,
      "planner onPrepareProgress x7 (got %d)" % PL.count("onPrepareProgress"))
check(PL.count("fun openRetriever") == 1, "planner openRetriever def x1")
check(PL.count("openRetriever(") == 3, "planner openRetriever def + 2 calls")
check(PL.count("fun frameAt") == 1, "planner frameAt def x1")
check(PL.count("frameAt(") == 3, "planner frameAt def + 2 calls")
check(PL.count("prepFrameTick") == 4, "planner prepFrameTick x4 (declare + compare + assign + coerce)")
check(PL.count("R.string.str_preparing_analyzing") == 3, "planner analyze-stage ticks x3")
check(PL.count("R.string.str_preparing_transition") == 1, "planner transition-stage tick x1")
check(PL.count("extractBoundaryFrame") == 0, "planner per-frame extractBoundaryFrame gone")
check(VE.count("mapFfmpegProgress") == 2, "VEA mapFfmpegProgress def + call x2")
check(VE.count("updateExportPreparation") == 1, "VEA prep callback wiring x1")
check(VMV.count("updateExportPreparation") == 1, "VM updateExportPreparation def x1")
check(VMV.count("exportStageRes") == 3, "VM exportStageRes x3 (2 code + 1 doc)")
check(US.count("exportStageRes") == 1, "UiState exportStageRes x1")
check(VE.count("tvExportMessage") == 1, "VEA stage subtitle wiring x1")
check(VE.count("15 + p * 85 / 100") == 1, "VEA 15-100 mapping formula x1")
check(S.count("str_preparing_analyzing") == 1, "strings: preparing_analyzing x1")
check(S.count("str_preparing_transition") == 1, "strings: preparing_transition x1")
check(VE.count("if (e is kotlinx.coroutines.CancellationException) throw e") == 1,
      "VEA cancel rethrow line x1")
check(VE.count("exportJob = lifecycleScope.launch") == 1, "VEA saveAction is exportJob")

# 6) structural balance for every edited Kotlin file
# ProjectImportActivity is excluded: its 169/168 brace imbalance is
# pre-existing (a brace inside a string literal) and none of the phase-19
# edits touch its braces
for name, s in (("MainActivity", MA), ("VEA", VE),
                ("ViewModel", VMV), ("UiState", US), ("planner", PL),
                ("DraggableImageOverlayView", read(DIV)),
                ("CustomVideoSeeker", read(CVS)), ("TrackTrimView", read(TTV))):
    check(s.count("{") == s.count("}"),
          "%s braces balanced (%d/%d)" % (name, s.count("{"), s.count("}")))
    check(s.count("(") == s.count(")"),
          "%s parens balanced (%d/%d)" % (name, s.count("("), s.count(")")))

# 7) XML parses for every edited layout + values file
import xml.etree.ElementTree as ET
for p in [COLORS, THEMES, STRINGS, MAINXML, VEAXML, WELCOME,
          L + "dialog_export_settings.xml", L + "trim_bottom_sheet_dialog.xml",
          L + "activity_project_import.xml", L + "dialog_audio_fade.xml",
          L + "export_quality_bottom_sheet_dialog.xml",
          L + "activity_error_display.xml", L + "dialog_unsaved_changes.xml",
          L + "dialog_transitions.xml", L + "item_dependency.xml",
          "app/src/main/res/drawable/bg_nav_active_pill.xml",
          "app/src/main/res/drawable/bg_import_hero.xml",
          "app/src/main/res/drawable/bg_hero_bento_primary.xml",
          "app/src/main/res/drawable/ic_save_color_24.xml",
          "app/src/main/res/drawable/ic_banner_foreground.xml"]:
    try:
        ET.parse(p)
        check(True, "xml parses: " + p.split("/")[-1])
    except Exception as e:
        check(False, "xml parses: %s (%s)" % (p.split("/")[-1], e))

# 8) ASCII purity for every edited text file
# strings/MainActivity/VEA/VM already contain non-ASCII (degree signs,
# em-dashes, box characters) in pristine - only gate the files that were
# ASCII-clean before AND that this phase edited
for name, s in (("gradle", G), ("colors", C), ("themes", T),
                ("PIA", PI), ("UiState", US), ("planner", PL),
                ("main layout", MX), ("editing layout", VX)):
    check(sum(1 for ch in s if ord(ch) > 127) == 0, "%s ASCII" % name)

# 9) survival tokens (standing invariants from earlier phases)
for tok in ["probeMedia", "probeNextKeyframeMs", "addFreezeTransitionSegment",
            "renderTransitionFrames", "OPTION_CLOSEST", "anullsrc=r=",
            "-bsf:v dump_extra", "video_track_timescale",
            "val sensorMode = !perSegmentEncode", "pieceHandoffMs",
            "spanReencode", "fpsCloseEnough", "encodablePixFmt"]:
    check(PL.count(tok) > 0, "planner keeps '%s'" % tok)
check(VE.count("exportVideoFile") > 0, "VEA keeps exportVideoFile")
check(VE.count("btnCancelExport") > 0, "VEA keeps the cancel button wiring")
check(G.count("generateLocaleConfig = true") == 1,
      "gradle locale config generation kept (English-only output)")

# 10) scope: only the intended files may be dirty (clean tree also ok -
#     that is the re-run-after-commit case); deleted locale folders are
#     reported as D paths under values-* and must be allowed
r = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True)
allowed = set()
for p in [GRADLE, COLORS, THEMES, STRINGS, MAINXML, VEAXML, WELCOME,
          VEA, MAIN, PIA, VM, UISTATE, PLANNER, DIV, CVS, TTV,
          L + "dialog_export_settings.xml", L + "trim_bottom_sheet_dialog.xml",
          L + "activity_project_import.xml", L + "dialog_audio_fade.xml",
          L + "export_quality_bottom_sheet_dialog.xml",
          L + "activity_error_display.xml", L + "dialog_unsaved_changes.xml",
          L + "dialog_transitions.xml", L + "item_dependency.xml",
          "app/src/main/res/drawable/bg_nav_active_pill.xml",
          "app/src/main/res/drawable/bg_import_hero.xml",
          "app/src/main/res/drawable/bg_hero_bento_primary.xml",
          "app/src/main/res/drawable/ic_save_color_24.xml",
          "app/src/main/res/drawable/ic_banner_foreground.xml",
          "app/src/main/res/layout/language_bottom_sheet_dialog.xml",
          "app/src/main/res/layout/item_language_selection.xml"]:
    allowed.add(p)
bad = []
for line in r.stdout.splitlines():
    if not line.strip():
        continue
    p = line[3:].strip()
    if p in allowed:
        continue
    if p.startswith("app/src/main/res/values-"):
        continue
    bad.append(p)
check(len(bad) == 0, "scope: no unexpected dirty files (bad=%d)" % len(bad))

if fail:
    print("GATES FAILED: %d" % len(fail))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 19: done =="
