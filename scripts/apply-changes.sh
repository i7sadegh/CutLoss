#!/usr/bin/env bash
###############################################################################
# CutLoss phase 26 -- the two follow-ups from the user's Oct-28 08:05 app
# screenshots (1080x2412, 420dpi / 2.625x, the phone that runs the app):
#
#   1. The + glyph finally shrinks for real. Pixel measurement of the
#      running phase-24/25 build shows the tile IS 26dp (66px, matches the
#      sample) but the plus ink renders ~19dp - 77% of the tile, filling
#      the interior border to border - while the sample editor draws a
#      ~9dp glyph (35%). Root cause: the 8dp XML padding on the
#      ImageButton does not constrain the vector on-device (the drawable
#      scales to the interior instead of the padded box), so every
#      padding-based tuning silently failed. Fix: bake the size into the
#      drawable itself - ic_add_thin_24 intrinsic drops 24dp -> 11dp
#      (viewport stays 24 with the phase-25 3-unit arms, so ink span =
#      20/24 x 11dp = 9.2dp, arms = 3/24 x 11dp = 1.4dp) and the button
#      gains scaleType=center + 0dp padding so the intrinsic size is
#      authoritative no matter how padding behaves. The two Kotlin
#      pre-layout fallbacks 36.dpToPx() -> 26.dpToPx() to match the tile.
#
#   2. Preview + bottom row stop shifting between the unselected and the
#      video-selected states. Measured on the user's screenshots: the
#      preview container's bottom edge sits 20px (~8dp) higher when a
#      clip is selected, dragging the preview, the 00:05/00:20 badge and
#      the fullscreen button up with it. Cause: (a) the six editing
#      toolbar includes carry marginTop 8dp while the resting dock
#      (editingControlsScroll) carries 6dp, and (b) the dock's INNER
#      LinearLayout (editingControlsWrapper) is toggled GONE while the
#      HorizontalScrollView itself stays VISIBLE, so its 6dp margin keeps
#      reserving height next to the visible toolbar. Fix: all six include
#      margins drop to 6dp, and all 11 Kotlin toggle sites now toggle the
#      editingControlsScroll view itself (GONE drops the margin too), so
#      both states occupy exactly 6dp + one row of content.
#
# Files: VideoEditingActivity.kt, activity_video_editing.xml,
#        ic_add_thin_24.xml.
#
# Idempotent: re-running skips anything already applied.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

# ASCII purity of this script itself (spaces only, no tabs, no unicode)
if LC_ALL=C grep -qn '[^ -~]' "$0"; then
  echo "FATAL: non-ascii byte in this script"
  exit 1
fi

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
LAY="app/src/main/res/layout/activity_video_editing.xml"
ICADD="app/src/main/res/drawable/ic_add_thin_24.xml"
TTV="app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"

for f in "$VEA" "$LAY" "$ICADD" "$TTV"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 26: small plus glyph + state-toggle alignment =="

python3 - <<'PYEOF'
import os
import sys
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter

VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
LAY = "app/src/main/res/layout/activity_video_editing.xml"
ICADD = "app/src/main/res/drawable/ic_add_thin_24.xml"
TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"

edits_applied = 0
edits_skipped = 0
FAILED = []


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def wr(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def cnt(s, needle):
    return s.count(needle)


def apply_edit(path, old, new, label):
    """Single-site idempotent edit. Skip when new is already present,
    fail loudly when the anchor is missing or ambiguous."""
    global edits_applied, edits_skipped
    src = rd(path)
    if new in src:
        edits_skipped += 1
        print("  [skip]    " + label)
        return
    n = src.count(old)
    if n != 1:
        FAILED.append(label + " (anchor count " + str(n) + ")")
        print("  [FAIL]    " + label + " (anchor count " + str(n) + ")")
        return
    wr(path, src.replace(old, new))
    edits_applied += 1
    print("  [applied] " + label)


def apply_edit_multi(path, old, new, label, exp_old):
    """Multi-site idempotent edit: replaces every occurrence when the
    anchor count matches exp_old exactly; skips when nothing is left to
    replace. The final gates verify the resulting counts globally, so a
    wrong tree can never pass silently."""
    global edits_applied, edits_skipped
    src = rd(path)
    n = src.count(old)
    if n == 0:
        edits_skipped += 1
        print("  [skip]    " + label)
        return
    if n != exp_old:
        FAILED.append(label + " (anchor count " + str(n) + " != " + str(exp_old) + ")")
        print("  [FAIL]    " + label + " (anchor count " + str(n) + " != " + str(exp_old) + ")")
        return
    wr(path, src.replace(old, new))
    edits_applied += 1
    print("  [applied] " + label)


# ---------------------------------------------------------------------------
# Edit 1: ic_add_thin_24 - the drawable itself shrinks to an 11dp intrinsic
# so the glyph renders ~9dp of ink no matter how the button pads it.
# The path is byte-identical to phase 25 (3-unit arms, span 2..22).
# ---------------------------------------------------------------------------
NEW_ICADD = '''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 26: the drawable itself shrinks to an 11dp intrinsic so the
     glyph renders ~9dp of ink no matter how the button pads it. The
     on-device measurement of the phase-24/25 build showed the 8dp XML
     padding did not constrain the vector: the plus filled ~77% of the
     26dp tile (~19dp ink) while the sample editor draws ~9dp (35%).
     Viewport stays 24 with the phase-25 3-unit arms, so ink span =
     20/24 x 11dp = 9.2dp and arms = 3/24 x 11dp = 1.4dp. The ImageButton
     also gains scaleType=center + 0dp padding (layout edit) so the
     intrinsic size is authoritative. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="11dp"
    android:height="11dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M10.5,2L13.5,2L13.5,10.5L22,10.5L22,13.5L13.5,13.5L13.5,22L10.5,22L10.5,13.5L2,13.5L2,10.5L10.5,10.5Z" />
</vector>
'''
cur_ic = rd(ICADD)
if cur_ic == NEW_ICADD:
    edits_skipped += 1
    print("  [skip]    ic_add_thin_24: 11dp intrinsic")
elif cnt(cur_ic, "M10.5,2L13.5,2") == 1 and cnt(cur_ic, "pathData") == 1 and cnt(cur_ic, 'android:width="24dp"') == 1:
    wr(ICADD, NEW_ICADD)
    edits_applied += 1
    print("  [applied] ic_add_thin_24: 11dp intrinsic")
else:
    FAILED.append("ic_add_thin_24 rewrite (unexpected content)")
    print("  [FAIL]    ic_add_thin_24 rewrite (unexpected content)")

# ---------------------------------------------------------------------------
# Edit 2: the add-tile ImageButton - padding 8dp -> 0dp and a new
# scaleType=center so the 11dp drawable renders at its intrinsic size,
# centered in the 26dp tile, immune to padding semantics.
# ---------------------------------------------------------------------------
OLD_TILE_ATTRS = (
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="8dp"\n'
    '                    app:tint="@color/textColor" />\n'
)
NEW_TILE_ATTRS = (
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="0dp"\n'
    '                    android:scaleType="center"\n'
    '                    app:tint="@color/textColor" />\n'
)
apply_edit(LAY, OLD_TILE_ATTRS, NEW_TILE_ATTRS, "LAY: add tile scaleType=center + 0dp padding")

# ---------------------------------------------------------------------------
# Edit 3: the six editing-toolbar includes drop marginTop 8dp -> 6dp so
# every mode toolbar aligns with the resting dock's 6dp margin.
# ---------------------------------------------------------------------------
apply_edit_multi(LAY,
                 'android:layout_marginTop="8dp"',
                 'android:layout_marginTop="6dp"',
                 "LAY: six toolbar include margins 8dp -> 6dp",
                 6)

# ---------------------------------------------------------------------------
# Edits 4-8: the eleven Kotlin toggle sites switch from the dock's inner
# LinearLayout (editingControlsWrapper) to the dock itself
# (editingControlsScroll), so a visible mode toolbar replaces the dock's
# FULL footprint (6dp margin included) instead of leaving it reserved.
# The wrapper field itself survives - setEditingButtonsEnabled still
# walks its children for the alpha/enable sweep.
# ---------------------------------------------------------------------------
apply_edit_multi(VEA,
                 '\n        findViewById<LinearLayout>(R.id.editingControlsWrapper)?.visibility = View.GONE',
                 '\n        findViewById<View>(R.id.editingControlsScroll)?.visibility = View.GONE',
                 "VEA: 3 findViewById GONE sites -> toggle the dock",
                 3)
apply_edit_multi(VEA,
                 '\n        findViewById<LinearLayout>(R.id.editingControlsWrapper)?.visibility = View.VISIBLE',
                 '\n        findViewById<View>(R.id.editingControlsScroll)?.visibility = View.VISIBLE',
                 "VEA: 2 findViewById VISIBLE sites -> toggle the dock",
                 2)
apply_edit_multi(VEA,
                 '\n        editingControlsWrapper.visibility = View.GONE',
                 '\n        findViewById<View>(R.id.editingControlsScroll)?.visibility = View.GONE',
                 "VEA: 3 field-based GONE sites -> toggle the dock",
                 3)
apply_edit_multi(VEA,
                 '\n        editingControlsWrapper.visibility = View.VISIBLE',
                 '\n        findViewById<View>(R.id.editingControlsScroll)?.visibility = View.VISIBLE',
                 "VEA: 2 field-based VISIBLE sites -> toggle the dock",
                 2)
apply_edit_multi(VEA,
                 '\n            editingControlsWrapper.visibility = View.VISIBLE',
                 '\n            findViewById<View>(R.id.editingControlsScroll)?.visibility = View.VISIBLE',
                 "VEA: nested VISIBLE site (speed toolbar exit) -> toggle the dock",
                 1)

# ---------------------------------------------------------------------------
# Edits 9-10: the pre-layout fallbacks for the add button's size follow
# the phase-24 tile: 36dp -> 26dp.
# ---------------------------------------------------------------------------
apply_edit(VEA,
           "val btnWidth = btnTimelineAdd.width.takeIf { it > 0 } ?: 36.dpToPx()",
           "val btnWidth = btnTimelineAdd.width.takeIf { it > 0 } ?: 26.dpToPx()",
           "VEA: add-button width fallback 36dp -> 26dp")
apply_edit(VEA,
           "val btnHeight = btnTimelineAdd.height.takeIf { it > 0 } ?: 36.dpToPx()",
           "val btnHeight = btnTimelineAdd.height.takeIf { it > 0 } ?: 26.dpToPx()",
           "VEA: add-button height fallback 36dp -> 26dp")

print("  edits applied: " + str(edits_applied) + ", skipped: " + str(edits_skipped))
if FAILED:
    print("EDITS FAILED: " + "; ".join(FAILED))
    sys.exit(1)

# ===========================================================================
# Gates
# ===========================================================================
passed = 0
failed = 0


def gate(label, ok, note=""):
    global passed, failed
    if ok:
        passed += 1
        print("  [gate ok] " + label)
    else:
        failed += 1
        print("  [GATE FAIL] " + label + (" -> " + note if note else ""))


def cntf(p, needle):
    return cnt(rd(p), needle)


ic = rd(ICADD)
lay = rd(LAY)
vea = rd(VEA)

# -- gate group 1: the + glyph -----------------------------------------------
gate("ic_add_thin_24: intrinsic is 11dp, old 24dp gone",
     cnt(ic, 'android:width="11dp"') == 1 and cnt(ic, 'android:height="11dp"') == 1
     and cnt(ic, 'android:width="24dp"') == 0 and cnt(ic, 'android:height="24dp"') == 0)
gate("ic_add_thin_24: viewport 24 + white fill survive",
     cnt(ic, 'android:viewportWidth="24"') == 1 and cnt(ic, 'android:viewportHeight="24"') == 1
     and cnt(ic, 'android:fillColor="#FFFFFF"') == 1)

NEW_PATH = "M10.5,2L13.5,2L13.5,10.5L22,10.5L22,13.5L13.5,13.5L13.5,22L10.5,22L10.5,13.5L2,13.5L2,10.5L10.5,10.5Z"
gate("ic_add_thin_24: phase-25 3-unit-arm path unchanged",
     cnt(ic, NEW_PATH) == 1 and cnt(ic, "pathData") == 1)

nums = []
for tok in NEW_PATH.replace("M", " ").replace("L", " ").replace("Z", " ").replace(",", " ").split():
    nums.append(float(tok))
xs = nums[0::2]
ys = nums[1::2]
gate("ic_add_thin_24: glyph spans 2..22 in both axes (20 of 24 units)",
     min(xs) == 2.0 and max(xs) == 22.0 and min(ys) == 2.0 and max(ys) == 22.0)
gate("ic_add_thin_24: arms are 3 units wide and centered at 12",
     10.5 in xs and 13.5 in xs and 10.5 in ys and 13.5 in ys
     and (13.5 - 10.5) == 3.0)

# -- gate group 2: the add-tile button ---------------------------------------
NEW_TILE_BLOCK = (
    '                <ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="26dp"\n'
    '                    android:layout_height="26dp"\n'
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_thin_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="0dp"\n'
    '                    android:scaleType="center"\n'
    '                    app:tint="@color/textColor" />\n'
)
gate("LAY: add tile keeps 26dp + gains 0dp padding + scaleType=center",
     NEW_TILE_BLOCK in lay)
gate("LAY: exactly one scaleType=center and one padding=0dp in the file",
     cnt(lay, 'android:scaleType="center"') == 1 and cnt(lay, 'android:padding="0dp"') == 1)

# -- gate group 3: state-toggle alignment ------------------------------------
gate("LAY: no 8dp toolbar include margins survive",
     cnt(lay, 'android:layout_marginTop="8dp"') == 0)
gate("LAY: seven 6dp top margins (six includes + the dock)",
     cnt(lay, 'android:layout_marginTop="6dp"') == 7)
gate("LAY: all six editing-toolbar includes survive",
     cnt(lay, 'layout="@layout/text_editing_toolbar"') == 1
     and cnt(lay, 'layout="@layout/image_editing_toolbar"') == 1
     and cnt(lay, 'layout="@layout/video_editing_toolbar"') == 1
     and cnt(lay, 'layout="@layout/audio_editing_toolbar"') == 1
     and cnt(lay, 'layout="@layout/speed_editing_toolbar"') == 1
     and cnt(lay, 'layout="@layout/keyframe_editing_toolbar"') == 1)
gate("LAY: the dock id and its docked background survive",
     cnt(lay, '@+id/editingControlsScroll') == 1
     and cnt(lay, '@drawable/bg_bottom_nav_docked') == 1)

gate("VEA: no editingControlsWrapper.visibility toggles survive",
     cnt(vea, "editingControlsWrapper.visibility") == 0)
gate("VEA: exactly 6 dock-GONE toggle sites",
     cnt(vea, "findViewById<View>(R.id.editingControlsScroll)?.visibility = View.GONE") == 6)
gate("VEA: exactly 5 dock-VISIBLE toggle sites",
     cnt(vea, "findViewById<View>(R.id.editingControlsScroll)?.visibility = View.VISIBLE") == 5)
gate("VEA: 14 total editingControlsScroll references (11 new + 3 pre-existing)",
     cnt(vea, "R.id.editingControlsScroll") == 14)
gate("VEA: the wrapper field survives for the alpha/enable sweep",
     cnt(vea, "private lateinit var editingControlsWrapper: LinearLayout") == 1
     and cnt(vea, "editingControlsWrapper.alpha") == 1
     and cnt(vea, "editingControlsWrapper.childCount") == 1)
gate("VEA: gallery-mode INVISIBLE on the dock untouched",
     cnt(vea, "R.id.editingControlsScroll).visibility = View.INVISIBLE") == 1)
gate("VEA: video toolbar enter/exit toggles untouched",
     cnt(vea, "videoEditingToolbar?.visibility = View.VISIBLE") == 2
     and cnt(vea, "videoEditingToolbar?.visibility = View.GONE") == 2)
gate("VEA: add-button fallbacks are 26dp, no 36dp left",
     cnt(vea, "26.dpToPx()") == 2 and cnt(vea, "36.dpToPx()") == 0)

# -- right-commit sanity: the phase-25 grip lines survive untouched ---------
gate("TTV: phase-25 single centered grip lines survive",
     cntf(TTV, "canvas.drawLine(leftMidX, height * 0.35f, leftMidX, height * 0.65f, gripPaint)") == 1
     and cntf(TTV, "canvas.drawLine(rightMidX, height * 0.35f, rightMidX, height * 0.65f, gripPaint)") == 1)

# -- XML well-formedness ----------------------------------------------------
for p in [ICADD, LAY]:
    try:
        ET.parse(p)
        passed += 1
        print("  [gate ok] XML well-formed: " + p)
    except Exception as e:
        failed += 1
        print("  [GATE FAIL] XML malformed: " + p + " -> " + str(e))

# -- kotlin-lite brace/paren balance ----------------------------------------


def scan(src):
    errs = []
    depth = 0
    paren = 0
    stack = [("code", 0)]
    i = 0
    n = len(src)
    line = 1
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "\n":
            line += 1
        mode = stack[-1][0]
        if mode == "lcom":
            if ch == "\n":
                stack.pop()
            i += 1
            continue
        if mode == "bcom":
            if ch == "*" and nxt == "/":
                stack.pop()
                i += 2
                continue
            i += 1
            continue
        if mode == "str":
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                stack.pop()
            i += 1
            continue
        if mode == "tstr":
            if ch == '"' and nxt == '"' and i + 2 < n and src[i + 2] == '"':
                stack.pop()
                i += 3
                continue
            i += 1
            continue
        if mode == "char":
            if ch == "\\":
                i += 2
                continue
            if ch == "'":
                stack.pop()
            i += 1
            continue
        if mode == "tpl":
            if ch == "}":
                stack.pop()
                depth -= 1
                i += 1
                continue
            if ch == '"':
                stack.append(("str", 0))
                i += 1
                continue
            if ch == "'":
                stack.append(("char", 0))
                i += 1
                continue
            if ch == "{":
                depth += 1
                i += 1
                continue
            i += 1
            continue
        if ch == "/" and nxt == "/":
            stack.append(("lcom", 0))
            i += 2
            continue
        if ch == "/" and nxt == "*":
            stack.append(("bcom", 0))
            i += 2
            continue
        if ch == '"':
            if nxt == '"' and i + 2 < n and src[i + 2] == '"':
                stack.append(("tstr", 0))
                i += 3
                continue
            stack.append(("str", 0))
            i += 1
            continue
        if ch == "'":
            stack.append(("char", 0))
            i += 1
            continue
        if ch == "$" and nxt == "{":
            stack.append(("tpl", 0))
            depth += 1
            i += 2
            continue
        if ch == "{":
            depth += 1
            i += 1
            continue
        if ch == "}":
            depth -= 1
            if depth < 0:
                errs.append("line " + str(line) + ": unbalanced }")
            i += 1
            continue
        if ch == "(":
            paren += 1
            i += 1
            continue
        if ch == ")":
            paren -= 1
            if paren < 0:
                errs.append("line " + str(line) + ": unbalanced )")
            i += 1
            continue
        i += 1
    if depth != 0:
        errs.append("final brace depth " + str(depth))
    if paren != 0:
        errs.append("final paren depth " + str(paren))
    if len(stack) != 1 or stack[-1][0] != "code":
        errs.append("unclosed literal: " + str(stack))
    return errs


errs = scan(rd(VEA))
gate("kotlin-lite brace/paren balance: " + VEA, not errs, "; ".join(errs[:3]))

# -- ASCII purity + no NEW non-ascii vs HEAD --------------------------------
# (VEA already carries 11 non-ascii lines at HEAD, so only the multiset
# comparison applies to it; LAY and the drawable are fully ASCII.)
gate("LAY is pure ASCII", not [c for c in lay if ord(c) > 126])
gate("ic_add_thin_24 is pure ASCII", not [c for c in ic if ord(c) > 126])


def non_ascii_multiset(s):
    return Counter(c for c in s if ord(c) > 127)


for p in [VEA, LAY, ICADD]:
    try:
        head = subprocess.run(["git", "show", "HEAD:" + p],
                              capture_output=True, text=True, encoding="utf-8").stdout
    except Exception as e:
        gate("non-ascii compare " + p, False, str(e))
        continue
    if head == "" and os.path.exists(p):
        passed += 1
        continue
    gate("no new non-ascii vs HEAD: " + p,
         non_ascii_multiset(head) == non_ascii_multiset(rd(p)))

if failed:
    print("GATES FAILED: " + str(failed) + " of " + str(failed + passed))
    sys.exit(1)
print("ALL GATES GREEN (" + str(passed) + " checks)")
PYEOF

echo "== phase 26 done =="
