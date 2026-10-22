#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 2 -- remove the "Voice Over" and "Draw" (Handwriting) features
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  What this phase does (feature removal):
#   1. Deletes the feature source files:
#        - customviews/HandwritingCanvasView.kt  (Draw canvas)
#        - customviews/BrushSizeDotView.kt       (brush size preview dot)
#        - layout/layout_handwriting_panel.xml   (Draw toolbar panel)
#        - layout/dialog_voice_over.xml          (Voice Over bottom sheet)
#        - drawable/ic_brush_24.xml, ic_mic_24.xml (orphaned icons)
#   2. AndroidManifest.xml: drops the RECORD_AUDIO permission (the only
#      user of the microphone was Voice Over -> better privacy now).
#   3. activity_video_editing.xml: removes the Draw and Voice tool
#      buttons, the handwriting canvas overlay view and the handwriting
#      panel include.
#   4. VideoEditingActivity.kt: removes every line of Voice Over code
#      (fields, permission launcher, tool button wiring, dialog with the
#      MediaRecorder logic) and every line of Draw/Handwriting code
#      (state flag, controls setup, open/close mode, save+commit logic).
#      Shared plumbing (image overlay ops, background audio ops, custom
#      color picker, shared icons) is deliberately KEPT -- other tools
#      still use it.
#   5. strings.xml (all 17 locales): removes the 8 now-dead string keys
#      (str_draw, str_voice, str_voice_over, str_handwriting, ...).
#   6. Verification gate: scans app/src/main for any leftover reference
#      (class names, view ids, string keys, icons, permission). If any
#      leftover is found the script FAILS BEFORE anything is committed,
#      so main can never receive a half-removed feature.
#
#  Idempotent: every step checks its own marker and skips if applied.
#  POLICY: this pipeline must never modify files under .github/workflows/
#  (bot pushes get rejected by GitHub). Workflow changes are always
#  manual web-editor edits by the repo owner.
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"

# ---------------------------------------------------------------------------
#  STEP 1 -- delete feature files
# ---------------------------------------------------------------------------
step1_delete_files() {
    echo "== step 1: delete Voice/Draw feature files"
    local n=0 f
    for f in \
        app/src/main/java/com/tharunbirla/librecuts/customviews/HandwritingCanvasView.kt \
        app/src/main/java/com/tharunbirla/librecuts/customviews/BrushSizeDotView.kt \
        app/src/main/res/layout/layout_handwriting_panel.xml \
        app/src/main/res/layout/dialog_voice_over.xml \
        app/src/main/res/drawable/ic_brush_24.xml \
        app/src/main/res/drawable/ic_mic_24.xml
    do
        if [ -f "$f" ]; then
            rm -f "$f" && echo "   [del] $f" && n=$((n+1))
        else
            echo "   [skip] $f (already gone)"
        fi
    done
    echo "   -> removed $n file(s)"
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 2 -- manifest: drop RECORD_AUDIO permission
# ---------------------------------------------------------------------------
step2_manifest() {
    echo "== step 2: AndroidManifest.xml -- drop RECORD_AUDIO permission"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/AndroidManifest.xml'
s = open(p, encoding='utf-8', newline='').read()
line = '    <uses-permission android:name="android.permission.RECORD_AUDIO" />\n'
if line in s:
    s = s.replace(line, '', 1)
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok] RECORD_AUDIO permission removed')
elif 'RECORD_AUDIO' in s:
    print('   [FAIL] RECORD_AUDIO present but not in expected form')
    sys.exit(1)
else:
    print('   [skip] permission already absent')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 3 -- activity_video_editing.xml: remove tool buttons + views
# ---------------------------------------------------------------------------
step3_main_layout() {
    echo "== step 3: activity_video_editing.xml -- remove Draw/Voice UI"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/res/layout/activity_video_editing.xml'
s = open(p, encoding='utf-8', newline='').read()

def cut_element(s, id_marker, open_hint, close_hint, name):
    """Cut the whole element that contains id_marker.
    open_hint: tag opening to search backwards for.
    close_hint: closing token to search forwards for ('/>' or '</LinearLayout>').
    Whitespace after the element is swallowed up to the next '<'."""
    i = s.find(id_marker)
    if i < 0:
        print('   [skip] ' + name + ' (already gone)')
        return s
    start = s.rfind(open_hint, 0, i)
    if start < 0:
        print('   [FAIL] ' + name + ': opening tag not found')
        sys.exit(1)
    end = s.find(close_hint, i)
    if end < 0:
        print('   [FAIL] ' + name + ': closing tag not found')
        sys.exit(1)
    end += len(close_hint)
    while end < len(s) and s[end] in ' \t\r\n':
        end += 1
    print('   [ok] ' + name)
    return s[:start] + s[end:]

# 1. Draw tool button (whole LinearLayout: ImageButton + TextView)
s = cut_element(s, 'android:id="@+id/btnDraw"', '<LinearLayout', '</LinearLayout>', 'btnDraw tool button block')
# 2. Voice tool button (whole LinearLayout: ImageButton + TextView)
s = cut_element(s, 'android:id="@+id/btnVoiceOver"', '<LinearLayout', '</LinearLayout>', 'btnVoiceOver tool button block')
# 3. Handwriting canvas overlay view (custom view element)
s = cut_element(s, 'android:id="@+id/handwritingCanvasView"',
                '<com.tharunbirla.librecuts.customviews.HandwritingCanvasView',
                '/>', 'handwritingCanvasView overlay element')
# 4. Handwriting panel include
s = cut_element(s, 'android:id="@+id/handwritingPanel"', '<include', '/>', 'handwritingPanel include')

open(p, 'w', encoding='utf-8', newline='').write(s)
import xml.dom.minidom
xml.dom.minidom.parse(p)
print('   [ok] layout still parses as valid XML')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 4 -- VideoEditingActivity.kt: strip all Voice + Draw code
# ---------------------------------------------------------------------------
step4_activity() {
    echo "== step 4: VideoEditingActivity.kt -- strip Voice/Draw code"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
s = open(p, encoding='utf-8', newline='').read()
orig = s
applied, skipped, failed = [], [], []

def rep(name):
    applied.append(name)

def one(name, old, new=''):
    """Replace exactly one occurrence of old with new."""
    global s
    n = s.count(old)
    if n == 0:
        skipped.append(name)
    elif n == 1:
        s = s.replace(old, new, 1)
        rep(name)
    else:
        failed.append(name + ' (' + str(n) + ' occurrences)')

def many(name, old, new, expect):
    global s
    n = s.count(old)
    if n == 0:
        skipped.append(name)
    elif n == expect:
        s = s.replace(old, new)
        rep(name)
    else:
        failed.append(name + ' (found ' + str(n) + ', expected ' + str(expect) + ')')

def cut_span(name, start_marker, end_marker):
    global s
    i = s.find(start_marker)
    if i < 0:
        skipped.append(name)
        return
    j = s.find(end_marker, i + len(start_marker))
    if j < 0:
        failed.append(name + ': end marker not found')
        return
    s = s[:i] + s[j:]
    rep(name)

# 4a. imports of the two deleted custom views
one('remove HandwritingCanvasView + BrushSizeDotView imports',
    'import com.tharunbirla.librecuts.customviews.HandwritingCanvasView\n'
    'import com.tharunbirla.librecuts.customviews.BrushSizeDotView\n')

# 4b. Voice Over fields + RECORD_AUDIO permission launcher
one('remove voiceOver fields + permission launcher',
    '    private var mediaRecorder: android.media.MediaRecorder? = null\n'
    '    private var isRecordingVoiceOver = false\n'
    '    private var voiceOverFile: File? = null\n'
    '    private var voiceOverStartTimeMs = 0L\n'
    '\n'
    '    private val requestRecordAudioPermissionLauncher = registerForActivityResult(\n'
    '        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()\n'
    '    ) { isGranted ->\n'
    '        if (isGranted) {\n'
    '            showVoiceOverDialog()\n'
    '        } else {\n'
    '            Toast.makeText(this, R.string.toast_microphone_permission_required, Toast.LENGTH_SHORT).show()\n'
    '        }\n'
    '    }\n'
    '\n')

# 4c. back-press handler: drop the handwriting branch
one('simplify back-press handler (drop handwriting branch)',
    '                } else if (isHandwritingActive) {\n'
    '                    val canvasView = findViewById<HandwritingCanvasView>(R.id.handwritingCanvasView)\n'
    '                    if (canvasView != null && !canvasView.isEmpty()) {\n'
    '                        MaterialAlertDialogBuilder(this@VideoEditingActivity)\n'
    '                            .setTitle("Discard Handwriting?")\n'
    '                            .setMessage("Are you sure you want to discard your drawing?")\n'
    '                            .setPositiveButton("Discard") { _, _ -> closeHandwritingMode() }\n'
    '                            .setNegativeButton("Keep Editing", null)\n'
    '                            .show()\n'
    '                    } else {\n'
    '                        closeHandwritingMode()\n'
    '                    }\n'
    '                } else {\n',
    '                } else {\n')

# 4d. setupHandwritingControls() call in onCreate flow
one('remove setupHandwritingControls() call',
    '        setupHandwritingControls()\n')

# 4e. btnVoiceOver click wiring
one('remove btnVoiceOver click wiring',
    '        findViewById<ImageButton>(R.id.btnVoiceOver)?.setBounceClickListener {\n'
    '            setActiveToolButton(R.id.btnVoiceOver)\n'
    '            voiceOverAction()\n'
    '        }\n'
    '\n')

# 4f. tool id list: drop btnDraw + btnVoiceOver
one('drop btnDraw/btnVoiceOver from tool id list',
    '        val toolIds = listOf(R.id.btnText, R.id.btnMediaOverlay, R.id.btnDraw, R.id.btnAudio, R.id.btnCrop, R.id.btnSubtitles, R.id.btnVoiceOver, R.id.btnCanvasBackground)\n',
    '        val toolIds = listOf(R.id.btnText, R.id.btnMediaOverlay, R.id.btnAudio, R.id.btnCrop, R.id.btnSubtitles, R.id.btnCanvasBackground)\n')

# 4g. crop-preview overlay lists: drop hwCanvas (2 identical spots)
many('drop hwCanvas from crop preview overlay lists (x2)',
     '            val hwCanvas = findViewById<com.tharunbirla.librecuts.customviews.HandwritingCanvasView>(R.id.handwritingCanvasView)\n'
     '            val overlays = listOf(textOverlayView, draggableTextOverlay, imageOverlayView, draggableImageOverlay, cropOverlayView, videoMaskOverlayView, hwCanvas)\n',
     '            val overlays = listOf(textOverlayView, draggableTextOverlay, imageOverlayView, draggableImageOverlay, cropOverlayView, videoMaskOverlayView)\n',
     2)

# 4h. handwriting state flag + all five handwriting functions
#     (setupHandwritingControls, getVideoRect, openHandwritingMode,
#      closeHandwritingMode, saveAndCommitHandwriting) -- contiguous span
cut_span('remove handwriting state + 5 functions',
         '    private var isHandwritingActive = false',
         '    @SuppressLint("InflateParams")\n    private fun textAction() {')

# 4i. closeActiveEditingModes(): drop handwriting branch
one('drop handwriting branch from closeActiveEditingModes()',
    '        if (isHandwritingActive) {\n'
    '            closeHandwritingMode()\n'
    '        }\n')

# 4j. voiceOverAction() + showVoiceOverDialog() -- contiguous span
cut_span('remove voiceOverAction + showVoiceOverDialog',
         '    private fun voiceOverAction() {',
         '    private fun subtitlesAction() {')

for n in applied:
    print('   [ok] ' + n)
for n in skipped:
    print('   [skip] ' + n)
for n in failed:
    print('   [FAIL] ' + n)

# sanity: removed blocks must be brace/paren balanced
d_open = orig.count('{') - s.count('{')
d_close = orig.count('}') - s.count('}')
d_popen = orig.count('(') - s.count('(')
d_pclose = orig.count(')') - s.count(')')
if d_open != d_close or d_popen != d_pclose:
    print('   [FAIL] brace/paren balance broken: braces %d/%d parens %d/%d'
          % (d_open, d_close, d_popen, d_pclose))
    sys.exit(1)
print('   [ok] brace/paren balance preserved (%d pairs removed)' % d_open)

if failed:
    sys.exit(1)

if applied:
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok] %d edit(s) applied, %d skipped, %d line(s) removed'
          % (len(applied), len(skipped), orig.count('\n') - s.count('\n')))
else:
    print('   [ok] nothing to do (already applied)')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 5 -- strings.xml: remove the 8 dead keys from every locale
# ---------------------------------------------------------------------------
step5_strings() {
    echo "== step 5: strings.xml -- remove dead keys (all locales)"
    python3 - <<'CUTPY'
import glob, re, sys
keys = ['str_record_live_commentary_while_t', 'str_tap_to_start_recording',
        'toast_microphone_permission_required', 'toast_failed_to_start_recording',
        'str_voice_over', 'str_voice', 'str_handwriting', 'str_draw']
pat = re.compile(r'^[ \t]*<string\s+name="(?:' + '|'.join(keys) + r')"[^>]*>[^<]*</string>[ \t]*\r?\n',
                 re.MULTILINE)
files = sorted(glob.glob('app/src/main/res/values*/strings.xml'))
if not files:
    print('   [FAIL] no values*/strings.xml found')
    sys.exit(1)
total, touched = 0, 0
import xml.dom.minidom
for f in files:
    s = open(f, encoding='utf-8', newline='').read()
    s2, n = pat.subn('', s)
    if n:
        open(f, 'w', encoding='utf-8', newline='').write(s2)
        xml.dom.minidom.parse(f)
        total += n
        touched += 1
print('   [ok] removed %d key line(s) from %d locale file(s)' % (total, touched))
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 6 -- verification gate (fails BEFORE anything gets committed)
# ---------------------------------------------------------------------------
step6_verify() {
    echo "== step 6: leftover reference check (hard gate)"
    python3 - <<'CUTPY'
import os, re, sys

bad = []
tokens = [
    'HandwritingCanvasView', 'BrushSizeDotView', 'handwritingPanel',
    'handwritingCanvasView', 'btnDraw', 'btnVoiceOver', 'isHandwritingActive',
    'voiceOver', 'VoiceOver', 'mediaRecorder', 'showVoiceOverDialog',
    'requestRecordAudioPermissionLauncher', 'setupHandwritingControls',
    'openHandwritingMode', 'closeHandwritingMode', 'saveAndCommitHandwriting',
    'hwCanvas', 'RECORD_AUDIO', 'dialog_voice_over', 'layout_handwriting_panel',
    'ic_brush_24', 'ic_mic_24',
]
keypat = re.compile(r'name="(?:str_draw|str_voice|str_voice_over|str_handwriting'
                    r'|str_record_live_commentary_while_t|str_tap_to_start_recording'
                    r'|toast_microphone_permission_required|toast_failed_to_start_recording)"')
roots = ['app/src/main']
for root in roots:
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            try:
                blob = open(fp, encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            for t in tokens:
                if t in blob:
                    bad.append(fp + ' :: ' + t)
            if fp.endswith('.xml') and keypat.search(blob):
                bad.append(fp + ' :: dead string key')
if bad:
    print('   [FAIL] leftover references found:')
    for b in sorted(set(bad)):
        print('      ' + b)
    sys.exit(1)
print('   [ok] zero leftover references in app/src/main')
CUTPY
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " Cutloss simplification (phase 2) -- start"
echo " Removes: Voice Over tool + Draw (Handwriting) tool"
echo "=========================================================="
FAILED=0
step1_delete_files  || FAILED=1
step2_manifest       || FAILED=1
step3_main_layout    || FAILED=1
step4_activity       || FAILED=1
step5_strings        || FAILED=1
step6_verify         || FAILED=1
echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 2 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 2 complete. All steps ok or skipped."
echo " Result: 2 tools removed, RECORD_AUDIO permission gone,"
echo " 6 dead files deleted, 8 dead string keys dropped."
echo " Remaining tools: Text, Overlay, Audio, Crop, Subtitles,"
echo " Canvas Background (+ trim/speed/filters/etc.)."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
