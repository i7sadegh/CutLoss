#!/usr/bin/env bash
###############################################################################
# CutLoss phase 25 -- the two follow-ups from the user's new sample-editor
# screenshots (two 542x2412 left-crops + a 194x327 handle close-up, all
# read at 420dpi / 2.625x, the same phone that runs the app):
#
#   1. Trim-handle grip lines: ONE per handle, not two. The user's
#      close-up crop is pixel-identical to the sample editor's selected
#      strip (matched at offset 1760,331): a 50px white handle block
#      carrying a SINGLE centered 3px gray line (#4D000000 over white =
#      the measured 179 gray) spanning the middle 30% of the strip
#      (35%..65%). The app currently draws twin lines at midX +/- 4
#      which read as two vertical bars side by side. -> one centered
#      drawLine per handle at 0.35f..0.65f; stroke width, color and the
#      white handle blocks stay as they are (they already match).
#   2. The + glyph: slimmer arms. The cleaner re-measure of the sample
#      tile (26dp tile, 9dp glyph) reads ~3.5px arms = ~1.3dp; the
#      phase-24 4-unit arms render ~1.7dp and read bold next to the
#      sample. -> ic_add_thin_24 arms slim 4 -> 3 viewport units
#      (~1.25dp rendered). The 26dp tile + 8dp padding from phase 24
#      (which this build also carries) already match the sample tile.
#
# Files: TrackTrimView.kt, ic_add_thin_24.xml.
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

TTV="app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
LAY="app/src/main/res/layout/activity_video_editing.xml"
ICADD="app/src/main/res/drawable/ic_add_thin_24.xml"

for f in "$TTV" "$LAY" "$ICADD"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 25: single grip line + slimmer plus arms =="

python3 - <<'PYEOF'
import os
import sys
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter

TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
LAY = "app/src/main/res/layout/activity_video_editing.xml"
ICADD = "app/src/main/res/drawable/ic_add_thin_24.xml"

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


# ---------------------------------------------------------------------------
# Edit 1: TrackTrimView grip lines - twin lines at midX +/- 4 become ONE
# centered line per handle, spanning the middle 30% of the track height
# (0.35f..0.65f), matching the sample editor's single 3px gray line.
# The anchor reproduces the current bytes exactly, including the
# trailing-whitespace-only line between the two handle blocks.
# ---------------------------------------------------------------------------
OLD_GRIP = (
    '            // Draw vertical grip lines on the handles\n'
    '            val gripPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {\n'
    '                color = Color.parseColor("#4D000000") // Subtle dark overlay for grips\n'
    '                style = Paint.Style.STROKE\n'
    '                strokeWidth = 3f\n'
    '            }\n'
    '            // Left handle grip lines\n'
    '            val leftMidX = startX + currentHandleWidth / 2f\n'
    '            canvas.drawLine(leftMidX - 4f, height * 0.3f, leftMidX - 4f, height * 0.7f, gripPaint)\n'
    '            canvas.drawLine(leftMidX + 4f, height * 0.3f, leftMidX + 4f, height * 0.7f, gripPaint)\n'
    '            \n'
    '            // Right handle grip lines\n'
    '            val rightMidX = endX - currentHandleWidth / 2f\n'
    '            canvas.drawLine(rightMidX - 4f, height * 0.3f, rightMidX - 4f, height * 0.7f, gripPaint)\n'
    '            canvas.drawLine(rightMidX + 4f, height * 0.3f, rightMidX + 4f, height * 0.7f, gripPaint)\n'
)
NEW_GRIP = (
    '            // Draw the vertical grip line on each handle\n'
    '            val gripPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {\n'
    '                color = Color.parseColor("#4D000000") // Subtle dark overlay for grips\n'
    '                style = Paint.Style.STROKE\n'
    '                strokeWidth = 3f\n'
    '            }\n'
    '            // phase 25: reference retune - ONE centered grip line per\n'
    '            // handle: the sample editor draws a single 3px gray line at\n'
    '            // the handle\'s center spanning the middle 30% of the track\n'
    '            // height (35%..65%), and the twin lines at midX +/- 4 read\n'
    '            // as two vertical bars side by side on the white handle\n'
    '            // Left handle grip line\n'
    '            val leftMidX = startX + currentHandleWidth / 2f\n'
    '            canvas.drawLine(leftMidX, height * 0.35f, leftMidX, height * 0.65f, gripPaint)\n'
    '            \n'
    '            // Right handle grip line\n'
    '            val rightMidX = endX - currentHandleWidth / 2f\n'
    '            canvas.drawLine(rightMidX, height * 0.35f, rightMidX, height * 0.65f, gripPaint)\n'
)
apply_edit(TTV, OLD_GRIP, NEW_GRIP, "TTV: one centered grip line per handle (0.35..0.65)")

# ---------------------------------------------------------------------------
# Edit 2: ic_add_thin_24 - the plus arms slim from 4 to 3 of the 20
# viewport units (arm centers stay at 12; span stays 2..22). Full-content
# rewrite so the explanatory comment follows the geometry.
# ---------------------------------------------------------------------------
NEW_ICADD = '''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 25: the arms slim to 3 of the 20 viewport units - the
     cleaner re-measure of the sample editor's plus reads a 9dp glyph
     with ~1.3dp arms (about 3.5px at 420dpi); the phase-24 4-unit arms
     rendered ~1.7dp and read bold next to the sample. The glyph span
     stays 20 of the 24 viewport units; the 26dp tile + 8dp padding
     from phase 24 already match the sample tile. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M10.5,2L13.5,2L13.5,10.5L22,10.5L22,13.5L13.5,13.5L13.5,22L10.5,22L10.5,13.5L2,13.5L2,10.5L10.5,10.5Z" />
</vector>
'''
OLD_PATH = 'M10,2L14,2L14,10L22,10L22,14L14,14L14,22L10,22L10,14L2,14L2,10L10,10Z'
cur_ic = rd(ICADD)
if cur_ic == NEW_ICADD:
    edits_skipped += 1
    print("  [skip]    ic_add_thin_24: 3-unit arms")
elif cnt(cur_ic, OLD_PATH) == 1 and cnt(cur_ic, "pathData") == 1:
    wr(ICADD, NEW_ICADD)
    edits_applied += 1
    print("  [applied] ic_add_thin_24: 3-unit arms")
else:
    FAILED.append("ic_add_thin_24 rewrite (unexpected content)")
    print("  [FAIL]    ic_add_thin_24 rewrite (unexpected content)")

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


ttv = rd(TTV)
ic = rd(ICADD)

# byte-exact survival anchor for the phase-24 add tile
ADD_BLOCK = (
    '                <ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="26dp"\n'
    '                    android:layout_height="26dp"\n'
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_thin_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="8dp"\n'
    '                    app:tint="@color/textColor" />\n'
)

# -- gate group 1: the grip lines -------------------------------------------
gate("TTV: exactly one left grip drawLine at 0.35f..0.65f",
     cnt(ttv, "canvas.drawLine(leftMidX, height * 0.35f, leftMidX, height * 0.65f, gripPaint)") == 1)
gate("TTV: exactly one right grip drawLine at 0.35f..0.65f",
     cnt(ttv, "canvas.drawLine(rightMidX, height * 0.35f, rightMidX, height * 0.65f, gripPaint)") == 1)
gate("TTV: no twin-line offsets survive",
     cnt(ttv, "leftMidX - 4f") == 0 and cnt(ttv, "leftMidX + 4f") == 0
     and cnt(ttv, "rightMidX - 4f") == 0 and cnt(ttv, "rightMidX + 4f") == 0)
gate("TTV: no 0.3f/0.7f grip spans survive",
     cnt(ttv, "height * 0.3f") == 0 and cnt(ttv, "height * 0.7f") == 0)
gate("TTV: exactly two grip drawLine calls",
     cnt(ttv, "gripPaint)") == 2)
gate("TTV: grip stroke width + color survive",
     cnt(ttv, "strokeWidth = 3f") == 2 and cnt(ttv, "#4D000000") == 1)
gate("TTV: height*0.35f total is 3 (1 wave + 2 grips), height*0.65f is 2",
     cnt(ttv, "height * 0.35f") == 3 and cnt(ttv, "height * 0.65f") == 2)
gate("TTV: total drawLine count is 5 (3 wave + 2 grip)",
     cnt(ttv, "drawLine(") == 5)
gate("TTV: handle width property untouched (0.30f once)",
     cnt(ttv, "0.30f") == 1 and cnt(ttv, "coerceAtLeast(24f)") == 1)

# -- gate group 2: phase-19..24 survival ------------------------------------
gate("phase 24: handle blocks keep the 7% rounded-outer-corner path",
     cnt(ttv, "floatArrayOf(handleRadius, handleRadius, 0f, 0f, 0f, 0f, handleRadius, handleRadius)") == 1
     and cnt(ttv, "floatArrayOf(0f, 0f, handleRadius, handleRadius, handleRadius, handleRadius, 0f, 0f)") == 1)
gate("phase 24: all 7%-radius sites survive",
     cnt(ttv, "0.07f") == 5)
gate("phase 24: 3% unselected silhouette survives",
     cnt(ttv, "0.03f") == 4)
gate("phase 24: the + tile stays 26dp with 8dp padding",
     ADD_BLOCK in rd(LAY))
gate("phase 20: the add tile drawable still exists",
     os.path.exists("app/src/main/res/drawable/bg_add_media_tile.xml"))

# -- gate group 3: the plus glyph --------------------------------------------
NEW_PATH = "M10.5,2L13.5,2L13.5,10.5L22,10.5L22,13.5L13.5,13.5L13.5,22L10.5,22L10.5,13.5L2,13.5L2,10.5L10.5,10.5Z"
gate("ic_add_thin_24: new 3-unit-arm path present exactly once",
     cnt(ic, NEW_PATH) == 1)
gate("ic_add_thin_24: old 4-unit-arm path gone",
     cnt(ic, OLD_PATH) == 0)
gate("ic_add_thin_24: 24dp frame + 24 viewport + white fill",
     cnt(ic, 'android:width="24dp"') == 1 and cnt(ic, 'android:height="24dp"') == 1
     and cnt(ic, 'android:viewportWidth="24"') == 1 and cnt(ic, 'android:fillColor="#FFFFFF"') == 1)

# path arithmetic sanity: parse the path, verify the plus is centered
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

# -- XML well-formedness ----------------------------------------------------
for p in [ICADD]:
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


errs = scan(rd(TTV))
gate("kotlin-lite brace/paren balance: " + TTV, not errs, "; ".join(errs[:3]))

# -- ASCII purity + no NEW non-ascii vs HEAD --------------------------------
gate("TTV is pure ASCII", not [c for c in rd(TTV) if ord(c) > 126])
gate("ic_add_thin_24 is pure ASCII", not [c for c in ic if ord(c) > 126])


def non_ascii_multiset(s):
    return Counter(c for c in s if ord(c) > 127)


for p in [TTV, ICADD]:
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

echo "== phase 25 done =="
