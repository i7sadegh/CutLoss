#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 5 -- Export dialog: pin the header row (title + estimated size)
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  USER REQUEST: in the Export Settings dialog, the top row that shows the
#  "Export Settings" title and the estimated output size capsule used to
#  live INSIDE the scrollable content, so it disappeared when scrolling
#  down. This phase pins it above the scrolling area.
#
#  What this phase does:
#   1. app/src/main/res/layout/dialog_export_settings.xml restructure:
#
#        BEFORE:                                  AFTER:
#        <NestedScrollView root>                  <LinearLayout root, vertical>
#          <LinearLayout padding=20dp>              <header row (pinned)>
#            <header row>                            <NestedScrollView>
#            ...22 setting sections...                 <LinearLayout body>
#            <buttons row>                              ...22 sections...
#          </LinearLayout>                               <buttons row>
#        </NestedScrollView>                            </LinearLayout>
#                                                     </NestedScrollView>
#                                                   </LinearLayout>
#
#      Rest-state spacing is preserved exactly (same 20dp paddings, same
#      18dp gap below the header), so the dialog looks identical until
#      you scroll -- then the header (and the live size estimate) stays
#      visible at the top while only the settings scroll under it.
#
#   2. Verification gate (fails BEFORE the workflow commits anything):
#      - XML parses (minidom) and the exact tree shape is asserted with
#        ElementTree: header OUTSIDE the scroll, all controls INSIDE it
#      - the full @+id set is compared against git HEAD (no element lost)
#      - only dialog_export_settings.xml may appear in the working diff
#      - no Kotlin file is touched (zero compile risk)
#      - hard policy: nothing under .github/ may be modified
#
#  Idempotent: step 1 checks its own marker and skips if already applied.
#  POLICY: this pipeline must never modify files under .github/workflows/
#  (bot pushes get rejected by GitHub). Workflow changes are always
#  manual web-editor edits by the repo owner.
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

XML="app/src/main/res/layout/dialog_export_settings.xml"
SELF="scripts/apply-changes.sh"
FAILED=0

# ---------------------------------------------------------------------------
#  STEP 0 -- preconditions
# ---------------------------------------------------------------------------
step0_preconditions() {
    echo "== step 0: preconditions"
    if [ ! -f "$XML" ]; then
        echo " [FAIL] $XML not found -- wrong repo state?"
        return 1
    fi
    if grep -q 'PINNED-EXPORT-HEADER' "$XML"; then
        echo " [info] phase 5 marker already present (already applied)"
        return 0
    fi
    if ! head -3 "$XML" | grep -q '<androidx.core.widget.NestedScrollView'; then
        echo " [FAIL] $XML does not have the expected NestedScrollView root."
        echo "        Apply this on top of the current main branch."
        return 1
    fi
    if ! grep -q 'estimated-size capsule' "$XML"; then
        echo " [FAIL] expected header comment not found in $XML."
        return 1
    fi
    echo " [ok] preconditions met"
}

# ---------------------------------------------------------------------------
#  STEP 1 -- restructure the export dialog (pinned header)
# ---------------------------------------------------------------------------
step1_pin_header() {
    echo "== step 1: pin the export dialog header above the scroll content"
    if grep -q 'PINNED-EXPORT-HEADER' "$XML"; then
        echo " [skip] header already pinned"
        return 0
    fi
    python3 - "$XML" <<'CUTPY' || return 1
import sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()

def lines(ls):
    return '\n'.join(ls) + '\n'

ROOT_OLD = lines([
'<androidx.core.widget.NestedScrollView xmlns:android="http://schemas.android.com/apk/res/android"',
'    xmlns:app="http://schemas.android.com/apk/res-auto"',
'    android:layout_width="match_parent"',
'    android:layout_height="wrap_content"',
'    android:background="@drawable/floating_panel_background"',
'    android:scrollbars="none">',
])

ROOT_NEW = lines([
'<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"',
'    xmlns:app="http://schemas.android.com/apk/res-auto"',
'    android:layout_width="match_parent"',
'    android:layout_height="wrap_content"',
'    android:orientation="vertical"',
'    android:background="@drawable/floating_panel_background">',
])

# The old inner container open tag (uniform 20dp padding, header inside).
INNER_OLD = lines([
'    <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"',
'        android:orientation="vertical" android:padding="20dp">',
])

# Its replacement: pinned header + scroll container + new inner container.
INNER_NEW = lines([
'    <!-- Header: pinned above the scrolling settings (PINNED-EXPORT-HEADER) -->',
'    <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"',
'        android:orientation="horizontal" android:gravity="center_vertical"',
'        android:paddingStart="20dp" android:paddingEnd="20dp" android:paddingTop="20dp">',
'        <TextView android:layout_width="0dp" android:layout_height="wrap_content"',
'            android:layout_weight="1" android:text="Export Settings"',
'            android:textColor="@color/textColor" android:textSize="18sp"',
'            android:fontFamily="sans-serif-medium" />',
'        <TextView android:id="@+id/tvEstimatedSize" android:layout_width="wrap_content"',
'            android:layout_height="wrap_content" android:text="..." android:textColor="@color/colorPrimary"',
'            android:textSize="12sp" android:fontFamily="sans-serif-medium"',
'            android:background="@drawable/bg_capsule_pill"',
'            android:paddingStart="14dp" android:paddingEnd="14dp"',
'            android:paddingTop="6dp" android:paddingBottom="6dp" />',
'    </LinearLayout>',
'',
'    <androidx.core.widget.NestedScrollView',
'        android:layout_width="match_parent"',
'        android:layout_height="wrap_content"',
'        android:scrollbars="none">',
'',
'        <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"',
'            android:orientation="vertical"',
'            android:paddingStart="20dp" android:paddingEnd="20dp" android:paddingBottom="20dp">',
])

# The old header block that gets cut out of the scrolling body.
HEADER_OLD = lines([
'        <!-- Header: title + estimated-size capsule (top-right) -->',
'        <LinearLayout android:layout_width="match_parent" android:layout_height="wrap_content"',
'            android:orientation="horizontal" android:gravity="center_vertical">',
'            <TextView android:layout_width="0dp" android:layout_height="wrap_content"',
'                android:layout_weight="1" android:text="Export Settings"',
'                android:textColor="@color/textColor" android:textSize="18sp"',
'                android:fontFamily="sans-serif-medium" />',
'            <TextView android:id="@+id/tvEstimatedSize" android:layout_width="wrap_content"',
'                android:layout_height="wrap_content" android:text="..." android:textColor="@color/colorPrimary"',
'                android:textSize="12sp" android:fontFamily="sans-serif-medium"',
'                android:background="@drawable/bg_capsule_pill"',
'                android:paddingStart="14dp" android:paddingEnd="14dp"',
'                android:paddingTop="6dp" android:paddingBottom="6dp" />',
'        </LinearLayout>',
])

TAIL_OLD = lines([
'    </LinearLayout>',
'</androidx.core.widget.NestedScrollView>',
])[:-1]  # no trailing newline; matched at end-of-file

TAIL_NEW = lines([
'        </LinearLayout>',
'    </androidx.core.widget.NestedScrollView>',
'</LinearLayout>',
])


def cut_once(s, old, new, what):
    n = s.count(old)
    if n != 1:
        print('   [FAIL] expected exactly 1 occurrence of %s, found %d' % (what, n))
        sys.exit(1)
    return s.replace(old, new, 1)


src = cut_once(src, ROOT_OLD, ROOT_NEW, 'the NestedScrollView root open tag')
src = cut_once(src, INNER_OLD, INNER_NEW, 'the inner container open tag')
# Remove the old header block together with the blank line above it.
src = cut_once(src, '\n' + HEADER_OLD, '', 'the original header block')

stripped = src.rstrip('\n')
if not stripped.endswith(TAIL_OLD):
    print('   [FAIL] unexpected file ending -- aborting before write')
    sys.exit(1)
src = stripped[:-len(TAIL_OLD)] + TAIL_NEW

# Well-formedness check before the file is written for good.
import tempfile, xml.dom.minidom
tmp = tempfile.NamedTemporaryFile('w', suffix='.xml', delete=False)
tmp.write(src)
tmp.close()
xml.dom.minidom.parse(tmp.name)
import os
os.unlink(tmp.name)

open(path, 'w', encoding='utf-8').write(src)
print('   [ok] header pinned above the NestedScrollView; body scrolls under it')
CUTPY
    if [ $? -eq 0 ]; then
        echo " [ok] step 1 applied"
    else
        echo " [FAIL] step 1 transformation failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
#  STEP 2 -- verification gate (before the workflow commits anything)
# ---------------------------------------------------------------------------
step2_verify() {
    echo "== step 2: verification gate"
    python3 - "$XML" <<'CUTPY' || return 1
import re, subprocess, sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
A = '{http://schemas.android.com/apk/res/android}'
bad = []

try:
    tree = ET.parse(path)
except Exception as e:
    print('   [FAIL] XML does not parse: %s' % e)
    sys.exit(1)

root = tree.getroot()

def chk(cond, msg):
    if not cond:
        bad.append(msg)

chk(root.tag == 'LinearLayout', 'root element is not LinearLayout')
chk(root.get(A + 'orientation') == 'vertical', 'root orientation is not vertical')
chk(root.get(A + 'background') == '@drawable/floating_panel_background',
    'root lost the floating_panel_background')
chk(len(root) == 2, 'root must have exactly 2 children (header + scroll), got %d' % len(root))

if len(root) == 2:
    hdr, nsv = list(root)
    chk(hdr.tag == 'LinearLayout', 'first root child is not the header LinearLayout')
    chk(len(hdr) == 2, 'header row must contain 2 TextViews')
    hids = [c.get(A + 'id') for c in list(hdr)]
    chk('@+id/tvEstimatedSize' in hids,
        'tvEstimatedSize is NOT in the pinned header')
    chk(hdr.get(A + 'paddingStart') == '20dp' and hdr.get(A + 'paddingEnd') == '20dp'
        and hdr.get(A + 'paddingTop') == '20dp', 'header paddings are wrong')
    chk(nsv.tag == 'androidx.core.widget.NestedScrollView',
        'second root child is not the NestedScrollView')
    chk(nsv.get(A + 'scrollbars') == 'none', 'scroll view lost scrollbars=none')
    chk(nsv.get(A + 'background') is None,
        'background must live on the root, not on the scroll view')
    chk(len(nsv) == 1, 'scroll view must have exactly 1 child')
    if len(nsv) == 1:
        inner = nsv[0]
        chk(inner.tag == 'LinearLayout', 'scroll child is not a LinearLayout')
        chk(inner.get(A + 'orientation') == 'vertical', 'scroll body orientation wrong')
        chk(len(inner) == 22,
            'scroll body must hold the 22 setting sections, got %d' % len(inner))
        chk(inner.get(A + 'paddingStart') == '20dp'
            and inner.get(A + 'paddingEnd') == '20dp'
            and inner.get(A + 'paddingBottom') == '20dp', 'scroll body paddings wrong')

# full id-set comparison against git HEAD (catches ANY lost element)
head = subprocess.run(['git', 'show', 'HEAD:' + path],
                      capture_output=True, text=True).stdout
ids_head = set(re.findall(r'@\+id/([\w]+)', head))
ids_now = set(re.findall(r'@\+id/([\w]+)', open(path, encoding='utf-8').read()))
if ids_head != ids_now:
    bad.append('id set changed vs HEAD: added=%s removed=%s'
               % (sorted(ids_now - ids_head), sorted(ids_head - ids_now)))

# textual order: the pinned header must precede the scroll container, and
# every interactive control must live inside the scroll body
txt = open(path, encoding='utf-8').read()
scroll_pos = txt.find('<androidx.core.widget.NestedScrollView')
chk(scroll_pos > 0, 'scroll container not found')
if scroll_pos > 0:
    chk(txt.find('tvEstimatedSize') < scroll_pos,
        'tvEstimatedSize must sit BEFORE (outside) the scroll container')
    for want in ('tvCommand', 'btnSaveExport', 'btnCancelExport', 'etWidth',
                 'etHeight', 'etBitrate', 'cgResolution', 'cgPreset'):
        chk(txt.find(want) > scroll_pos, want + ' must sit INSIDE the scroll body')

if bad:
    print('   [FAIL] verification failed:')
    for b in bad:
        print('      ' + b)
    sys.exit(1)

print('   [ok] XML parses; tree shape correct (header pinned, body scrolls)')
print('   [ok] id set identical to git HEAD -- no element lost')
print('   [ok] all controls verified inside the scroll body')
CUTPY
    if [ $? -ne 0 ]; then
        return 1
    fi

    # scope gate: only the dialog layout (and this script itself) may differ
    mods=$(git diff --name-only 2>/dev/null | grep -v "^${XML}$" | grep -v "^${SELF}$" || true)
    if [ -n "$mods" ]; then
        echo " [FAIL] unexpected modified files: ${mods}"
        return 1
    fi
    if git diff --name-only 2>/dev/null | grep -q "^${XML}$"; then
        echo " [ok] change scope is exactly dialog_export_settings.xml"
    else
        echo " [ok] no working-tree changes (already applied / skipped)"
    fi
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " Cutloss phase 5 -- pin the Export Settings header row"
echo " (title + estimated size stay visible while scrolling)"
echo "=========================================================="
step0_preconditions || FAILED=1
step1_pin_header    || FAILED=1
step2_verify        || FAILED=1

# hard policy check: nothing under .github/ may be touched by this pipeline
if git rev-parse --git-dir >/dev/null 2>&1; then
    badgh=$(git status --porcelain 2>/dev/null | grep -c '\.github/' || true)
    if [ "${badgh:-0}" -ne 0 ]; then
        echo " [FAIL] .github/ files modified -- refusing to continue"
        FAILED=1
    fi
fi

echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 5 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 5 complete. Steps ok or skipped."
echo " The Export Settings dialog now keeps its title row and the"
echo " live estimated-size capsule pinned at the top while the"
echo " settings scroll underneath them. No Kotlin was touched,"
echo " so there is zero compile risk in this phase."
echo " Next: the workflow commits this change and builds the APK."
echo "----------------------------------------------------------"
exit 0
