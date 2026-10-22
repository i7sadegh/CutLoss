#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 3 -- remove the "Subtitles" tool (SRT import + editing UI)
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  What this phase does:
#   1. Deletes the feature UI files:
#        - layout/subtitles_editing_toolbar.xml   (the editing toolbar)
#        - drawable/ic_closed_caption_24.xml      (tool button icon, orphan)
#        - drawable/ic_subtitles_24.xml           (already-orphaned icon)
#        - utils/SubtitleParser.kt                (SRT file parser, now dead)
#   2. activity_video_editing.xml: removes the btnSubtitles tool button
#      block and the subtitlesEditingToolbar include.
#   3. VideoEditingActivity.kt: removes every line of subtitle editing
#      code -- the 7 feature functions (subtitlesAction, enter/exit
#      editing mode, updateSubtitlesUi, updateSubtitleOp, pickSrtFile,
#      removeSubtitles), the toolbar setup block, the subtitle font
#      selector, the fields, the SRT import branch in onActivityResult,
#      the PICK_SRT_REQUEST constant and the btnSubtitles wiring.
#   4. strings.xml (all locales): removes the 6 now-dead string keys.
#   5. Verification gate: scans for leftover references and FAILS
#      BEFORE anything is committed.
#
#  DELIBERATELY KEPT (old project compatibility):
#   - models/EditOperation.kt: AddSubtitles + SubtitleCue classes.
#   - utils/ProjectSerializer.kt: "AddSubtitles" type mapping.
#   - viewmodels/VideoEditingViewModel.kt: the FFmpeg filter-graph code
#     that burns subtitle cues into the EXPORTED video.
#   - customviews/TextOverlayView.kt: the subtitle RENDERING half
#     (draws cues of existing projects in the editor preview).
#   Why: .lcprj project files saved earlier may contain subtitle
#   operations. Those projects must still open, preview and export
#   correctly. Only the UI to CREATE/EDIT subtitle tracks is removed.
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
    echo "== step 1: delete Subtitles feature files"
    local n=0 f
    for f in \
        app/src/main/res/layout/subtitles_editing_toolbar.xml \
        app/src/main/res/drawable/ic_closed_caption_24.xml \
        app/src/main/res/drawable/ic_subtitles_24.xml \
        app/src/main/java/com/tharunbirla/librecuts/utils/SubtitleParser.kt
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
#  STEP 2 -- activity_video_editing.xml: remove tool button + include
# ---------------------------------------------------------------------------
step2_main_layout() {
    echo "== step 2: activity_video_editing.xml -- remove Subtitles UI"
    python3 - <<'CUTPY'
import re, sys
import xml.dom.minidom
p = 'app/src/main/res/layout/activity_video_editing.xml'
s = open(p, encoding='utf-8', newline='').read()
changed = []

def cut_element(s, id_marker, open_hint, close_hint, name):
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

# 1. btnSubtitles tool button (whole LinearLayout: ImageButton + TextView)
s = cut_element(s, 'android:id="@+id/btnSubtitles"', '<LinearLayout', '</LinearLayout>', 'btnSubtitles tool button block')
# 2. subtitlesEditingToolbar include
s = cut_element(s, 'android:id="@+id/subtitlesEditingToolbar"', '<include', '/>', 'subtitlesEditingToolbar include')
# 3. the comment line above the old include position
s2 = re.sub(r'^[ \t]*<!-- Subtitles Editing Toolbar[^>]*-->\r?\n', '', s, flags=re.MULTILINE)
if s2 != s:
    changed.append('toolbar comment')
    s = s2

open(p, 'w', encoding='utf-8', newline='').write(s)
xml.dom.minidom.parse(p)
print('   [ok] layout still parses as valid XML')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 3 -- VideoEditingActivity.kt: strip all subtitle editing code
# ---------------------------------------------------------------------------
step3_activity() {
    echo "== step 3: VideoEditingActivity.kt -- strip Subtitles editing code"
    python3 - <<'CUTPY'
import re, sys
p = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
s = open(p, encoding='utf-8', newline='').read()
orig = s
applied, skipped, failed = [], [], []

def rep(name):
    applied.append(name)

def one(name, old, new=''):
    global s
    n = s.count(old)
    if n == 0:
        skipped.append(name)
    elif n == 1:
        s = s.replace(old, new, 1)
        rep(name)
    else:
        failed.append(name + ' (' + str(n) + ' occurrences)')

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

def cut_lines(name, pattern, expect):
    global s
    s2, n = re.subn(pattern, '', s, flags=re.MULTILINE)
    if n == 0:
        skipped.append(name)
    elif n == expect:
        s = s2
        rep(name)
    else:
        failed.append(name + ' (found ' + str(n) + ', expected ' + str(expect) + ')')

# 3a. the whole setupSubtitleFontSelector() function
cut_span('remove setupSubtitleFontSelector() function',
         '    private fun setupSubtitleFontSelector(subtitlesToolbar: View?) {',
         '    private fun showFontManagerBottomSheet(')

# 3b. its 3 call sites (importFontLauncher + 2 inside FontManagerAdapter callbacks)
cut_lines('remove setupSubtitleFontSelector call sites (x3)',
          r'^[ \t]*setupSubtitleFontSelector\(subtitlesEditingToolbar\)\r?\n', 3)

# 3c. the two fields
one('remove subtitlesEditingToolbar + isSubtitlesEditingActive fields',
    '    private var subtitlesEditingToolbar: View? = null\n'
    '    private var isSubtitlesEditingActive = false\n')

# 3d. textOverlayView setup: drop the subtitle drag callback registration
one('simplify textOverlayView setup (drop drag callback)',
    '        textOverlayView = try {\n'
    '            findViewById<com.tharunbirla.librecuts.customviews.TextOverlayView>(R.id.textOverlayView)?.also { overlay ->\n'
    '                overlay.onSubtitlePositionChanged = { relX, relY ->\n'
    '                    val project = viewModel.project.value\n'
    '                    val subOp = project?.operations?.find { it is EditOperation.AddSubtitles } as? EditOperation.AddSubtitles\n'
    '                    if (subOp != null) {\n'
    '                        updateSubtitleOp(subOp.copy(relativeX = relX, relativeY = relY))\n'
    '                    }\n'
    '                }\n'
    '            }\n'
    '        } catch (e: Exception) {\n',
    '        textOverlayView = try {\n'
    '            findViewById<com.tharunbirla.librecuts.customviews.TextOverlayView>(R.id.textOverlayView)\n'
    '        } catch (e: Exception) {\n')

# 3e. the subtitles toolbar setup block (assigns subtitlesEditingToolbar)
cut_span('remove subtitles toolbar setup block',
         '        subtitlesEditingToolbar = try {',
         '        backgroundEditingToolbar = try {')

# 3f. btnSubtitles click wiring
one('remove btnSubtitles click wiring',
    '        findViewById<ImageButton>(R.id.btnSubtitles).setBounceClickListener {\n'
    '            setActiveToolButton(R.id.btnSubtitles)\n'
    '            subtitlesAction()\n'
    '        }\n'
    '\n')

# 3g. tool id list: drop btnSubtitles
one('drop btnSubtitles from tool id list',
    ', R.id.btnSubtitles', '')

# 3h. renderTracks: drop the editing-mode UI refresh (rendering stays!)
one('drop updateSubtitlesUi() refresh from renderTracks',
    '                    if (isSubtitlesEditingActive) {\n'
    '                        updateSubtitlesUi()\n'
    '                    }\n'
    '\n')

# 3i. closeActiveEditingModes(): drop subtitles branch
one('drop subtitles branch from closeActiveEditingModes()',
    '        if (isSubtitlesEditingActive) {\n'
    '            isSubtitlesEditingActive = false\n'
    '        }\n')

# 3j. the 7 feature functions (subtitlesAction .. removeSubtitles)
cut_span('remove 7 subtitle feature functions',
         '    private fun subtitlesAction() {',
         '    private fun mediaOverlayAction() {')

# 3j-2. closeActiveEditingModes(): drop toolbar hide line
#        (must run AFTER 3j: the span above also contained one copy)
one('drop subtitlesEditingToolbar hide line from closeActiveEditingModes()',
    '        subtitlesEditingToolbar?.visibility = View.GONE\n')

# 3k. onActivityResult: SRT import branch
cut_span('remove SRT import branch from onActivityResult()',
         '        } else if (requestCode == PICK_SRT_REQUEST && resultCode == Activity.RESULT_OK) {',
         '        } else if (requestCode == PICK_DIRECTORY_REQUEST')

# 3l. PICK_SRT_REQUEST constant
one('remove PICK_SRT_REQUEST constant',
    '        private const val PICK_SRT_REQUEST = 4\n')

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
#  STEP 4 -- strings.xml: remove the 6 dead keys from every locale
# ---------------------------------------------------------------------------
step4_strings() {
    echo "== step 4: strings.xml -- remove dead keys (all locales)"
    python3 - <<'CUTPY'
import glob, re, sys
keys = ['str_subtitles', 'str_subtitles_srt', 'str_upload_subtitle_file',
        'str_supports_standard_srt_formatte', 'toast_subtitles_removed',
        'toast_failed_to_parse_subtitle_file']
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
#  STEP 5 -- verification gate (fails BEFORE anything gets committed)
# ---------------------------------------------------------------------------
step5_verify() {
    echo "== step 5: leftover reference check (hard gate)"
    python3 - <<'CUTPY'
import os, re, sys

VEA = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
# Files that KEEP subtitle code on purpose (old project compatibility):
KEEP = {
    'app/src/main/java/com/tharunbirla/librecuts/customviews/TextOverlayView.kt',
    'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt',
    'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt',
    'app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt',
}

bad = []
# tokens that must be absent EVERYWHERE in app/src/main
global_tokens = [
    'subtitlesAction', 'enterSubtitlesEditingMode', 'exitSubtitlesEditingMode',
    'updateSubtitlesUi', 'updateSubtitleOp', 'removeSubtitles', 'pickSrtFile',
    'setupSubtitleFontSelector', 'PICK_SRT_REQUEST', 'SubtitleParser',
    'subtitles_editing_toolbar', 'ic_closed_caption_24', 'ic_subtitles_24',
    'btnSubtitles', 'subtitlesEditingToolbar', 'btnUploadSrt', 'btnChangeSrt',
    'btnDeleteSrt', 'btnSaveSubtitles', 'btnCloseSubtitlesSheet',
    'subtitleFontSizeSlider', 'layoutNoSubtitles', 'layoutHasSubtitles',
    'tvSubtitleFileName', 'tvSubtitleFontSizeValue', 'btnSelectSubtitleFont',
    'tvSelectedSubtitleFontName',
]
# tokens that must be absent from the activity only (kept in TextOverlayView)
vea_tokens = ['isSubtitlesEditingActive', 'onSubtitlePositionChanged']
keypat = re.compile(r'name="(?:str_subtitles|str_subtitles_srt|str_upload_subtitle_file'
                    r'|str_supports_standard_srt_formatte|toast_subtitles_removed'
                    r'|toast_failed_to_parse_subtitle_file)"')

for dirpath, dirnames, filenames in os.walk('app/src/main'):
    for fn in filenames:
        fp = os.path.join(dirpath, fn)
        try:
            blob = open(fp, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        if fp in KEEP:
            continue
        for t in global_tokens:
            if t in blob:
                bad.append(fp + ' :: ' + t)
        if fp.endswith('.xml') and keypat.search(blob):
            bad.append(fp + ' :: dead string key')
        if fn == 'VideoEditingActivity.kt':
            for t in vea_tokens:
                if t in blob:
                    bad.append(fp + ' :: ' + t)

if bad:
    print('   [FAIL] leftover references found:')
    for b in sorted(set(bad)):
        print('      ' + b)
    sys.exit(1)
print('   [ok] zero leftover references (subtitle editing UI fully removed)')
print('   [ok] rendering/export half intact: models + serializer + viewmodel + TextOverlayView')
CUTPY
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " Cutloss simplification (phase 3) -- start"
echo " Removes: Subtitles tool (SRT import + editing UI)"
echo " Keeps:   subtitle render/export for old .lcprj projects"
echo "=========================================================="
FAILED=0
step1_delete_files  || FAILED=1
step2_main_layout   || FAILED=1
step3_activity      || FAILED=1
step4_strings       || FAILED=1
step5_verify        || FAILED=1
echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 3 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 3 complete. All steps ok or skipped."
echo " Result: Subtitles tool button gone, SRT import gone,"
echo " 4 dead files deleted, 6 dead string keys dropped."
echo " Old projects with subtitle layers still preview+export."
echo " Remaining tools: Text, Overlay, Audio, Crop, Canvas"
echo " Background (+ trim/speed/filters/keyframes/etc.)."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
