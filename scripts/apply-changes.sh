#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 6 -- three UI changes
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  1. Export dialog: symmetric spacing for the pinned header row.
#     The row that shows the "Export Settings" title plus the estimated
#     output size capsule had 20dp of air above it but only an 18dp gap
#     below it. Now the row carries its own 20dp top AND 20dp bottom
#     padding and the first section ("Resolution") starts at 0dp margin,
#     so the header sits with equal space above and below -- both at
#     rest and while the settings scroll under it.
#
#  2. Frame-capture (screenshot) button removed entirely:
#       - activity_video_editing.xml : btnCaptureFrame ImageButton
#       - VideoEditingActivity.kt    : wiring, captureCurrentFrame(),
#                                      saveBitmapToGallery()
#       - MainActivity.kt            : "Snapshot Export Folder" setting
#                                      (launcher + click wiring + loader)
#       - activity_main.xml          : the Snapshot Export Folder block
#       - strings (14 locales)       : str_snapshot_export_folder,
#                                      str_default_pictures_librecuts
#       - drawable                   : ic_camera_capture.xml deleted
#     NOTE: findTextureView() is KEPT -- the mirror toggle and the
#     transition-preview feature still call it.
#
#  3. Timeline (tracks) section height: 150dp -> 200dp.
#     Both the XML height AND the Kotlin restore site that resets the
#     height after collapsing the expanded timeline are updated, so the
#     new 200dp survives the expand/collapse cycle.
#
#  Verification gate (fails BEFORE the workflow commits anything):
#    - zero leftover references to the removed feature
#    - kept-feature survival asserts (incl. pickBackgroundImage,
#      findTextureView, magnet/mute buttons, audio folder setting)
#    - function-inventory guard vs git HEAD (catches any accidental
#      loss of a LIVE function -- the phase-3 bug class)
#    - brace balance + XML parse of every touched file
#    - scope gate: only expected files in the working diff
#    - hard policy: nothing under .github/ may be modified
#
#  Idempotent: every step checks its own post-state marker first.
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
MA="app/src/main/java/com/tharunbirla/librecuts/MainActivity.kt"
LAY="app/src/main/res/layout/activity_video_editing.xml"
MAINXML="app/src/main/res/layout/activity_main.xml"
DLG="app/src/main/res/layout/dialog_export_settings.xml"
DRAW="app/src/main/res/drawable/ic_camera_capture.xml"
SELF="scripts/apply-changes.sh"
FAILED=0

# ---------------------------------------------------------------------------
#  STEP 0 -- preconditions
# ---------------------------------------------------------------------------
step0_preconditions() {
    echo "== step 0: preconditions"
    local ok=1
    for f in "$VEA" "$MA" "$LAY" "$MAINXML" "$DLG"; do
        if [ ! -f "$f" ]; then
            echo " [FAIL] missing file: $f"
            ok=0
        fi
    done
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo " [FAIL] not inside a git repository"
        ok=0
    fi
    if ! grep -q "PINNED-EXPORT-HEADER" "$DLG" 2>/dev/null; then
        echo " [FAIL] $DLG lacks the phase-5 PINNED-EXPORT-HEADER marker --"
        echo "        wrong base state; phase 5 must be applied first."
        ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        echo " [ok] repo state matches the expected phase-5 base"
    fi
    [ "$ok" -eq 1 ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 1 -- export dialog: symmetric header spacing
# ---------------------------------------------------------------------------
step1_header_spacing() {
    echo "== step 1: export dialog -- symmetric header row spacing (20dp/20dp)"
    python3 - "$DLG" <<'CUTPY'
import sys
import xml.dom.minidom as md

p = sys.argv[1]
t = open(p, encoding='utf-8').read()

post1 = 'android:paddingTop="20dp" android:paddingBottom="20dp">'
post2 = 'android:layout_marginTop="0dp" android:text="Resolution"'
if post1 in t and post2 in t:
    print('   [skip] header spacing already symmetric')
    sys.exit(0)

old1 = 'android:paddingEnd="20dp" android:paddingTop="20dp">'
old2 = 'android:layout_marginTop="18dp" android:text="Resolution"'
if t.count(old1) != 1 or t.count(old2) != 1:
    print('   [FAIL] unexpected dialog XML state')
    print('          paddingEnd+paddingTop marker count: %d' % t.count(old1))
    print('          Resolution 18dp margin count:        %d' % t.count(old2))
    sys.exit(1)

t = t.replace(old1, 'android:paddingEnd="20dp" android:paddingTop="20dp" android:paddingBottom="20dp">')
t = t.replace(old2, post2)
md.parseString(t)
open(p, 'w', encoding='utf-8').write(t)
print('   [ok] header row: 20dp padding above AND below; first section margin -> 0dp')
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 2 -- timeline height 150dp -> 200dp (XML + Kotlin restore site)
# ---------------------------------------------------------------------------
step2_timeline_height() {
    echo "== step 2: timeline (tracks) height 150dp -> 200dp"
    python3 - "$LAY" "$VEA" <<'CUTPY'
import sys
import xml.dom.minidom as md

lay, vea = sys.argv[1], sys.argv[2]

old_x = ('android:id="@+id/timelineContainer"\n'
         '                android:layout_width="match_parent"\n'
         '                android:layout_height="150dp"')
new_x = ('android:id="@+id/timelineContainer"\n'
         '                android:layout_width="match_parent"\n'
         '                android:layout_height="200dp"')
t = open(lay, encoding='utf-8').read()
if new_x in t:
    print('   [skip] timeline XML height already 200dp')
elif t.count(old_x) == 1:
    t = t.replace(old_x, new_x)
    md.parseString(t)
    open(lay, 'w', encoding='utf-8').write(t)
    print('   [ok] activity_video_editing.xml: timelineContainer 150dp -> 200dp')
else:
    print('   [FAIL] timelineContainer 150dp block not found exactly once in layout XML')
    sys.exit(1)

old_k = 'lpTimeline.height = 150.dpToPx()'
new_k = 'lpTimeline.height = 200.dpToPx()'
k = open(vea, encoding='utf-8').read()
if new_k in k:
    print('   [skip] Kotlin collapse-restore height already 200dp')
elif k.count(old_k) == 1:
    k = k.replace(old_k, new_k)
    open(vea, 'w', encoding='utf-8').write(k)
    print('   [ok] VideoEditingActivity.kt: timeline restore height 150dp -> 200dp')
else:
    print('   [FAIL] lpTimeline.height = 150.dpToPx() not found exactly once')
    sys.exit(1)
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 3 -- remove the capture-frame button from the editor layout
# ---------------------------------------------------------------------------
step3_remove_capture_button() {
    echo "== step 3: remove btnCaptureFrame from activity_video_editing.xml"
    python3 - "$LAY" <<'CUTPY'
import sys
import xml.dom.minidom as md

p = sys.argv[1]
t = open(p, encoding='utf-8').read()
if 'btnCaptureFrame' not in t:
    print('   [skip] btnCaptureFrame already absent from layout')
    sys.exit(0)

block = (
'                    <ImageButton\n'
'                        android:id="@+id/btnCaptureFrame"\n'
'                        android:layout_width="40dp"\n'
'                        android:layout_height="40dp"\n'
'                        android:background="@android:color/transparent"\n'
'                        android:src="@drawable/ic_camera_capture"\n'
'                        android:padding="8dp"\n'
'                        android:scaleType="fitCenter"\n'
'                        app:tint="@color/colorOnSecondary" />\n'
'\n')
if t.count(block) != 1:
    print('   [FAIL] btnCaptureFrame block not found exactly once (count=%d)' % t.count(block))
    sys.exit(1)

t = t.replace(block, '')
if 'btnCaptureFrame' in t or 'ic_camera_capture' in t:
    print('   [FAIL] leftover capture references in layout')
    sys.exit(1)
md.parseString(t)
open(p, 'w', encoding='utf-8').write(t)
print('   [ok] capture-frame ImageButton removed (magnet + mute buttons kept)')
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 4 -- VideoEditingActivity.kt: remove the capture feature code
# ---------------------------------------------------------------------------
step4_vea_cuts() {
    echo "== step 4: VideoEditingActivity.kt -- remove capture feature code"
    python3 - "$VEA" <<'CUTPY'
import sys

p = sys.argv[1]
t = open(p, encoding='utf-8').read()
if ('captureCurrentFrame' not in t and 'saveBitmapToGallery' not in t
        and 'btnCaptureFrame' not in t):
    print('   [skip] capture-frame code already removed from VideoEditingActivity.kt')
    sys.exit(0)

before = t.count('\n')

wiring = (
'        val btnCaptureFrame = findViewById<ImageButton>(R.id.btnCaptureFrame)\n'
'        btnCaptureFrame.setBounceClickListener {\n'
'            captureCurrentFrame()\n'
'        }\n'
'\n')
if t.count(wiring) != 1:
    print('   [FAIL] btnCaptureFrame wiring not found exactly once')
    sys.exit(1)
t = t.replace(wiring, '')

enable_block = (
'        findViewById<View>(R.id.btnCaptureFrame)?.apply {\n'
'            isEnabled = enabled\n'
'            this.alpha = alpha\n'
'        }\n')
if t.count(enable_block) != 1:
    print('   [FAIL] setEditingButtonsEnabled capture block not found exactly once')
    sys.exit(1)
t = t.replace(enable_block, '')

def cut_fun(text, sig):
    i = text.find(sig)
    if i < 0 or (i > 0 and text[i-1] != '\n'):
        return None
    j = text.find('{', i)
    depth = 1
    k = j + 1
    n = len(text)
    while depth > 0 and k < n:
        c = text[k]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        k += 1
    if depth != 0:
        return None
    end = k
    if end < n and text[end] == '\n':
        end += 1
        if end < n and text[end] == '\n':
            end += 1
    return (i, end)

for sig in ('    private fun captureCurrentFrame() {',
            '    private fun saveBitmapToGallery(bitmap: android.graphics.Bitmap) {'):
    r = cut_fun(t, sig)
    if r is None:
        print('   [FAIL] could not locate/cut function: ' + sig)
        sys.exit(1)
    t = t[:r[0]] + t[r[1]:]

if t.count('{') != t.count('}'):
    print('   [FAIL] brace balance broken after cuts')
    sys.exit(1)
n_ftv = t.count('findTextureView')
if n_ftv != 4:
    print('   [FAIL] findTextureView count is %d, expected 4 (def + recursion + 2 live callers)' % n_ftv)
    sys.exit(1)
for tok in ('captureCurrentFrame', 'saveBitmapToGallery', 'btnCaptureFrame'):
    if tok in t:
        print('   [FAIL] leftover token in VideoEditingActivity.kt: ' + tok)
        sys.exit(1)

open(p, 'w', encoding='utf-8').write(t)
print('   [ok] wiring + captureCurrentFrame() + saveBitmapToGallery() removed (-%d lines)'
      % (before - t.count('\n')))
print('   [ok] findTextureView() kept (mirror + transition preview still use it)')
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 5 -- MainActivity.kt: remove the snapshot folder setting
# ---------------------------------------------------------------------------
step5_mainactivity() {
    echo "== step 5: MainActivity.kt -- remove Snapshot Export Folder setting"
    python3 - "$MA" <<'CUTPY'
import sys

p = sys.argv[1]
t = open(p, encoding='utf-8').read()
if ('selectSnapshotFolderLauncher' not in t
        and 'btnChangeSnapshotExportFolder' not in t
        and 'export_snapshot_directory_uri' not in t):
    print('   [skip] snapshot folder setting already removed from MainActivity.kt')
    sys.exit(0)

before = t.count('\n')

launcher = (
'    private val selectSnapshotFolderLauncher =\n'
'        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->\n'
'            if (uri != null) {\n'
'                try {\n'
'                    val takeFlags: Int = Intent.FLAG_GRANT_READ_URI_PERMISSION or\n'
'                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION\n'
'                    contentResolver.takePersistableUriPermission(uri, takeFlags)\n'
'\n'
'                    val prefs = getSharedPreferences("librecuts_prefs", MODE_PRIVATE)\n'
'                    prefs.edit().putString("export_snapshot_directory_uri", uri.toString()).apply()\n'
'                    updateExportFolderUI(uri, binding.tvCurrentSnapshotExportFolder, R.string.str_default_pictures_librecuts)\n'
'                } catch (e: Exception) {\n'
'                    Log.e("FolderSelectionError", "Error securing permission for URI", e)\n'
'                    showToast(getString(R.string.toast_failed_to_set_export_folder))\n'
'                }\n'
'            }\n'
'        }\n'
'\n')

wiring = (
'        binding.btnChangeSnapshotExportFolder.setBounceClickListener {\n'
'            selectSnapshotFolderLauncher.launch(null)\n'
'        }\n')

loader = (
'        val savedSnapshotUriString = prefs.getString("export_snapshot_directory_uri", null)\n'
'        if (savedSnapshotUriString != null) {\n'
'            updateExportFolderUI(Uri.parse(savedSnapshotUriString), binding.tvCurrentSnapshotExportFolder, R.string.str_default_pictures_librecuts)\n'
'        } else {\n'
'            updateExportFolderUI(null, binding.tvCurrentSnapshotExportFolder, R.string.str_default_pictures_librecuts)\n'
'        }\n'
'\n')

for name, lit in (('launcher', launcher), ('wiring', wiring), ('loader', loader)):
    if t.count(lit) != 1:
        print('   [FAIL] snapshot %s block not found exactly once (count=%d)' % (name, t.count(lit)))
        sys.exit(1)
    t = t.replace(lit, '')

if t.count('{') != t.count('}'):
    print('   [FAIL] brace balance broken after cuts')
    sys.exit(1)
for need in ('selectAudioFolderLauncher', 'updateLanguageUI', 'btnChangeAudioExportFolder'):
    if need not in t:
        print('   [FAIL] kept-feature check failed, missing: ' + need)
        sys.exit(1)

open(p, 'w', encoding='utf-8').write(t)
print('   [ok] launcher + click wiring + loader removed (-%d lines)' % (before - t.count('\n')))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 6 -- activity_main.xml: remove the snapshot settings UI block
# ---------------------------------------------------------------------------
step6_main_xml() {
    echo "== step 6: activity_main.xml -- remove Snapshot Export Folder block"
    python3 - "$MAINXML" <<'CUTPY'
import sys
import xml.dom.minidom as md

p = sys.argv[1]
t = open(p, encoding='utf-8').read()
if 'btnChangeSnapshotExportFolder' not in t:
    print('   [skip] snapshot settings block already absent from activity_main.xml')
    sys.exit(0)

lines = t.split('\n')
idx = [i for i, ln in enumerate(lines) if '<!-- Snapshot Export Folder Setting -->' in ln]
if len(idx) != 1:
    print('   [FAIL] snapshot comment marker found %d times' % len(idx))
    sys.exit(1)
idx = idx[0]

sep = ['                <View',
       '                    android:layout_width="match_parent"',
       '                    android:layout_height="1dp"',
       '                    android:background="@color/outlineVariant"',
       '                    android:layout_marginVertical="4dp" />',
       '']
if idx < 6 or lines[idx-6:idx] != sep:
    print('   [FAIL] separator View block not found right before the snapshot comment')
    sys.exit(1)
start = idx - 6

if lines[idx+1].strip() != '<LinearLayout':
    print('   [FAIL] expected <LinearLayout> right after the snapshot comment')
    sys.exit(1)

depth = 0
end = -1
for i in range(idx+1, len(lines)):
    s = lines[i].strip()
    if s.startswith('<LinearLayout'):
        depth += 1
    elif s.startswith('</LinearLayout>'):
        depth -= 1
        if depth == 0:
            end = i
            break
if end < 0:
    print('   [FAIL] could not find the closing </LinearLayout> of the snapshot block')
    sys.exit(1)

cut_end = end
if cut_end + 1 < len(lines) and lines[cut_end + 1] == '':
    cut_end += 1

new_lines = lines[:start] + lines[cut_end+1:]
new_t = '\n'.join(new_lines)

for tok in ('btnChangeSnapshotExportFolder', 'tvCurrentSnapshotExportFolder',
            'str_snapshot_export_folder', 'str_default_pictures_librecuts'):
    if tok in new_t:
        print('   [FAIL] leftover token in activity_main.xml: ' + tok)
        sys.exit(1)
for need in ('btnToggleHapticFeedback', 'btnChangeAudioExportFolder',
             'tvCurrentAudioExportFolder'):
    if need not in new_t:
        print('   [FAIL] kept-feature check failed, missing: ' + need)
        sys.exit(1)

md.parseString(new_t)
open(p, 'w', encoding='utf-8').write(new_t)
print('   [ok] snapshot settings block + one separator removed (-%d lines)'
      % (len(lines) - len(new_lines)))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 7 -- strings sweep: drop the two dead snapshot keys from all locales
# ---------------------------------------------------------------------------
step7_strings() {
    echo "== step 7: remove dead snapshot string keys from all locales"
    python3 - <<'CUTPY'
import glob, re, sys
import xml.dom.minidom as md

pat = re.compile(
    r'^[ \t]*<string name="(?:str_snapshot_export_folder|str_default_pictures_librecuts)">'
    r'[^\n]*</string>[ \t]*\n', re.M)

total = 0
files = 0
for f in sorted(glob.glob('app/src/main/res/values*/strings.xml')):
    t = open(f, encoding='utf-8').read()
    t2, n = pat.subn('', t)
    if n == 0:
        continue
    md.parseString(t2)
    open(f, 'w', encoding='utf-8').write(t2)
    total += n
    files += 1
    print('   [ok] %s: removed %d dead string line(s)' % (f, n))

if total == 0:
    print('   [skip] no snapshot string keys found (already removed)')
else:
    print('   [ok] removed %d string lines across %d locale files' % (total, files))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 8 -- delete the orphaned drawable
# ---------------------------------------------------------------------------
step8_delete_drawable() {
    echo "== step 8: delete drawable ic_camera_capture.xml"
    if [ -f "$DRAW" ]; then
        rm -f "$DRAW"
        echo " [ok] $DRAW deleted"
    else
        echo " [skip] $DRAW already absent"
    fi
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 9 -- verification gate
# ---------------------------------------------------------------------------
step9_verify() {
    echo "== step 9: verification gate"

    # 9a: leftover reference scan
    local left=0 tok n
    for tok in btnCaptureFrame captureCurrentFrame saveBitmapToGallery \
               ic_camera_capture selectSnapshotFolderLauncher \
               btnChangeSnapshotExportFolder tvCurrentSnapshotExportFolder \
               export_snapshot_directory_uri str_snapshot_export_folder \
               str_default_pictures_librecuts; do
        n=$(grep -rn -- "$tok" app/src/main 2>/dev/null | wc -l)
        if [ "$n" -ne 0 ]; then
            echo " [FAIL] leftover reference: $tok ($n hits)"
            grep -rn -- "$tok" app/src/main 2>/dev/null | head -3
            left=1
        fi
    done
    if [ "$left" -eq 0 ]; then
        echo " [ok] zero leftover references to the removed feature"
    fi

    # 9b: kept-feature survival asserts
    python3 - <<'CUTPY' || return 1
import sys

def rd(p):
    return open(p, encoding='utf-8').read()

vea = rd('app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt')
ma = rd('app/src/main/java/com/tharunbirla/librecuts/MainActivity.kt')
lay = rd('app/src/main/res/layout/activity_video_editing.xml')
mxml = rd('app/src/main/res/layout/activity_main.xml')
dlg = rd('app/src/main/res/layout/dialog_export_settings.xml')

errs = []
def need(text, tok, lo, name):
    c = text.count(tok)
    if c < lo:
        errs.append('%s: expected >=%d of %r, found %d' % (name, lo, tok, c))

need(vea, 'fun pickBackgroundImage', 1, 'VEA')
need(vea, 'findTextureView', 4, 'VEA')
need(vea, 'val btnMagnet = findViewById', 1, 'VEA')
need(vea, 'btnMute.setBounceClickListener', 1, 'VEA')
need(vea, 'lpTimeline.height = 200.dpToPx()', 1, 'VEA')
need(vea, 'fun trimAction', 1, 'VEA')
need(vea, 'fun cropAction', 1, 'VEA')
need(ma, 'selectAudioFolderLauncher', 2, 'MainActivity')
need(ma, 'updateLanguageUI', 1, 'MainActivity')
need(ma, 'btnChangeAudioExportFolder', 1, 'MainActivity')
need(lay, 'android:id="@+id/btnMagnet"', 1, 'layout')
need(lay, 'android:id="@+id/btnMute"', 1, 'layout')
need(lay, 'android:layout_height="200dp"', 1, 'layout')
need(lay, 'timelineHorizontalScroll', 1, 'layout')
need(dlg, 'PINNED-EXPORT-HEADER', 1, 'dialog')
need(dlg, 'android:paddingTop="20dp" android:paddingBottom="20dp">', 1, 'dialog')
need(dlg, 'android:layout_marginTop="0dp" android:text="Resolution"', 1, 'dialog')
need(dlg, 'tvEstimatedSize', 1, 'dialog')
need(mxml, 'btnToggleHapticFeedback', 1, 'activity_main')
need(mxml, 'btnChangeAudioExportFolder', 1, 'activity_main')

if errs:
    for e in errs:
        print(' [FAIL] survival: ' + e)
    sys.exit(1)
print(' [ok] all kept-feature survival checks passed')
CUTPY

    # 9c: function-inventory guard vs git HEAD
    inv_check() {
        local f="$1" exp_rm="$2" exp_add="$3"
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
    return set(re.findall(r'^\s*(?:private\s+|internal\s+|public\s+)?fun\s+([A-Za-z0-9_]+)\s*\(', t, re.M))

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
print(' [ok] function inventory intact for %s (removed: %s)'
      % (work.split('/')[-1], sorted(erm) or 'none'))
CUTPY
        local rc=$?
        rm -f "$tmp"
        [ $rc -ne 0 ] && return 1
        return 0
    }
    inv_check "$VEA" "captureCurrentFrame,saveBitmapToGallery" "" || return 1
    inv_check "$MA" "" "" || return 1

    # 9d: brace balance
    python3 - "$VEA" "$MA" <<'CUTPY' || return 1
import sys
for p in sys.argv[1:]:
    t = open(p, encoding='utf-8').read()
    if t.count('{') != t.count('}'):
        print(' [FAIL] brace imbalance in ' + p)
        sys.exit(1)
print(' [ok] braces balanced in both Kotlin files')
CUTPY

    # 9e: XML parse of every touched XML file
    python3 - <<'CUTPY' || return 1
import glob
import xml.dom.minidom as md
files = ['app/src/main/res/layout/dialog_export_settings.xml',
         'app/src/main/res/layout/activity_video_editing.xml',
         'app/src/main/res/layout/activity_main.xml']
files += sorted(glob.glob('app/src/main/res/values*/strings.xml'))
for f in files:
    md.parse(f)
print(' [ok] %d XML files parse cleanly' % len(files))
CUTPY

    # 9f: scope gate
    local bad
    bad=$(git status --porcelain 2>/dev/null | cut -c4- | grep -Ev \
'^(scripts/apply-changes\.sh|app/src/main/res/layout/(dialog_export_settings|activity_video_editing|activity_main)\.xml|app/src/main/java/com/tharunbirla/librecuts/(VideoEditingActivity|MainActivity)\.kt|app/src/main/res/drawable/ic_camera_capture\.xml|app/src/main/res/values[^/]*/strings\.xml)$' || true)
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

    # 9g: .github/ policy + ASCII self-check
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
echo " Cutloss phase 6 -- export header spacing, remove the"
echo " frame-capture button, timeline height 200dp"
echo "=========================================================="
step0_preconditions || FAILED=1
step1_header_spacing || FAILED=1
step2_timeline_height || FAILED=1
step3_remove_capture_button || FAILED=1
step4_vea_cuts || FAILED=1
step5_mainactivity || FAILED=1
step6_main_xml || FAILED=1
step7_strings || FAILED=1
step8_delete_drawable || FAILED=1
step9_verify || FAILED=1

echo "----------------------------------------------------------"
echo " line counts: VEA $(wc -l < "$VEA") | MainActivity $(wc -l < "$MA")"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 6 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 6 complete. Steps ok or skipped."
echo "  1. Export dialog header row now has equal 20dp spacing"
echo "     above and below the title + size capsule."
echo "  2. The frame-capture button and every line of code that"
echo "     belonged to it is gone (editor + main settings)."
echo "  3. The timeline (tracks) section is now 200dp tall, and"
echo "     stays 200dp after expand/collapse."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
