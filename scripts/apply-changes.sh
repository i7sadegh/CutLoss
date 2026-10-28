#!/usr/bin/env bash
###############################################################################
# CutLoss phase 24 -- reference-image retune of the three UI groups the
# user measured on the sample editor (two 1080x2412 screenshots, read at
# 420dpi / 2.625x, strip = 144px = 55dp):
#
#   1. The + add-media tile: the sample tile is 68px = 26dp (incl. its
#      1.5dp border) with a 9dp plus glyph whose arms are ~1.7dp; the
#      current 36dp tile with a 12dp glyph reads big. -> tile 26dp,
#      padding 8dp (glyph ink ~8.3dp), and the ic_add_thin_24 arms widen
#      2 -> 4 viewport units (arm/ink 20% = the sample's 19%) so the
#      stroke no longer renders hairline at the smaller size. The tile
#      radius stays 4dp and the border 1.5dp - both already match.
#   2. Track radius, both states: the sample's UNSELECTED strip corner
#      is ~4px = 2.8% of the strip height (barely rounded), and its
#      SELECTED trim-handle outer corners are ~10.5px = 7.3% (small
#      radius, not the phase-23 fully-sharp frame). -> every 22%-of-
#      height radius retunes: unselected silhouettes 3%, selected
#      frames + ALL trim-handle outer corners 7% (main and secondary
#      tracks now share one handle path), and the VEA segment outline
#      follows (selected 7% so thumbnails never poke out behind the
#      rounded handles, unselected 3%).
#   3. Cancel / Save pills: the sample pills are 201x84px = 76x32dp
#      with fully-rounded 16dp ends and ~17sp labels. -> height
#      40dp -> 32dp, Save width 96dp -> 76dp, Cancel padding
#      22dp -> 15dp (pill ~77dp), pill radius 20dp -> 16dp. The 17sp
#      labels already match the sample - unchanged.
#
# Files: activity_video_editing.xml, ic_add_thin_24.xml,
#        bg_cancel_pill.xml, bg_save_pill.xml, TrackTrimView.kt,
#        VideoEditingActivity.kt.
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

LAY="app/src/main/res/layout/activity_video_editing.xml"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
TTV="app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
PLAN="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

for f in "$LAY" "$VEA" "$TTV" "$PLAN" \
         "app/src/main/res/drawable/ic_add_thin_24.xml" \
         "app/src/main/res/drawable/bg_cancel_pill.xml" \
         "app/src/main/res/drawable/bg_save_pill.xml" \
         "app/src/main/res/drawable/bg_add_media_tile.xml" \
         "app/src/main/res/drawable/ic_transition_cut_24.xml" \
         "app/src/main/res/drawable/ic_transition_bowtie_24.xml" \
         "app/src/main/res/values/themes.xml"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 24: applying the reference-image retune =="

python3 - <<'PYEOF'
import os
import sys
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter

LAY = "app/src/main/res/layout/activity_video_editing.xml"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
PLAN = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
D = "app/src/main/res/drawable/"
THEMES = "app/src/main/res/values/themes.xml"

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


def ensure_drawable(name, old_marks, content, label):
    """Rewrite a small drawable when it still carries its pre-phase-24
    marks; skip when the phase-24 bytes are already in place."""
    global edits_applied, edits_skipped
    p = D + name
    cur = rd(p)
    if cur == content:
        edits_skipped += 1
        print("  [skip]    " + label)
        return
    if all(m in cur for m in old_marks):
        wr(p, content)
        edits_applied += 1
        print("  [applied] " + label)
        return
    FAILED.append(label + " (unexpected current content)")
    print("  [FAIL]    " + label + " (unexpected current content)")


# =========================================================================
# EDITS
# =========================================================================

# -- item 1: the + tile ----------------------------------------------------

apply_edit(
    LAY,
    '<!-- phase 23: plus glyph shrunk again - padding 10dp ->\n'
    '                     12dp so the glyph ink lands at ~28% of the 36dp tile\n'
    '                     (the 10dp form still read big per the user) -->\n'
    '                <ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="36dp"\n'
    '                    android:layout_height="36dp"\n'
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_thin_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="12dp"\n'
    '                    app:tint="@color/textColor" />',
    '<!-- phase 24: reference retune - the tile shrinks to the sample\n'
    '                     editor\'s 26dp (68px at 420dpi, ~47% of the track\n'
    '                     height) and the padding drops to 8dp so the glyph\n'
    '                     ink lands at ~8dp of the tile (sample: a 9dp glyph\n'
    '                     inside a 26dp tile) -->\n'
    '                <ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="26dp"\n'
    '                    android:layout_height="26dp"\n'
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_thin_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="8dp"\n'
    '                    app:tint="@color/textColor" />',
    "LAY: add tile 36dp -> 26dp, padding 12dp -> 8dp")

ensure_drawable(
    "ic_add_thin_24.xml",
    ["phase 22: the non-bold plus",
     "M11,2L13,2L13,11L22,11L22,13L13,13L13,22L11,22L11,13L2,13L2,11L11,11Z"],
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<!-- phase 24: reference retune - the arms widen to 4 of the 20\n'
    '     viewport units (arm/ink 20%, the sample editor\'s plus reads\n'
    '     ~1.7dp arms on a 9dp glyph); the phase-22 2-unit arms rendered\n'
    '     hairline-thin at the smaller 26dp tile, and the glyph span\n'
    '     stays 20 of the 24 viewport units -->\n'
    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
    '    android:width="24dp"\n'
    '    android:height="24dp"\n'
    '    android:viewportWidth="24"\n'
    '    android:viewportHeight="24">\n'
    '    <path\n'
    '        android:fillColor="#FFFFFF"\n'
    '        android:pathData="M10,2L14,2L14,10L22,10L22,14L14,14L14,22L10,22L10,14L2,14L2,10L10,10Z" />\n'
    '</vector>\n',
    "drawable: ic_add_thin_24 arms 2 -> 4 units")

# -- item 2: track radius retune -------------------------------------------

apply_edit(
    TTV,
    '                    // phase 23: the selected clip draws SHARP corners - the\n'
    '                    // trim frame and the handle blocks read as one clean\n'
    '                    // rectangle; the rounded corners return the moment the\n'
    '                    // selection drops (phase 21 drew this frame rounded,\n'
    '                    // which the user only wanted on unselected clips)\n'
    '                    borderPaint.color = Color.parseColor("#FFFFFF")\n'
    '                    borderPaint.strokeWidth = (height * 0.05f).coerceAtLeast(4f)\n'
    '                    val frameInset = borderPaint.strokeWidth / 2f\n'
    '                    val frameRect = RectF(\n'
    '                        rectF.left + frameInset, rectF.top + frameInset,\n'
    '                        rectF.right - frameInset, rectF.bottom - frameInset\n'
    '                    )\n'
    '                    canvas.drawRect(frameRect, borderPaint)',
    '                    // phase 24: reference retune - the selected clip\'s trim\n'
    '                    // frame is a rectangle with a SMALL radius (7% of the\n'
    '                    // track height - the handle-corner radius measured on\n'
    '                    // the sample editor\'s selected clip); phase 23\'s fully\n'
    '                    // sharp frame read too hard next to the sample\'s\n'
    '                    // barely-rounded 3% unselected silhouette\n'
    '                    borderPaint.color = Color.parseColor("#FFFFFF")\n'
    '                    borderPaint.strokeWidth = (height * 0.05f).coerceAtLeast(4f)\n'
    '                    val frameInset = borderPaint.strokeWidth / 2f\n'
    '                    val frameRect = RectF(\n'
    '                        rectF.left + frameInset, rectF.top + frameInset,\n'
    '                        rectF.right - frameInset, rectF.bottom - frameInset\n'
    '                    )\n'
    '                    canvas.drawRoundRect(frameRect, height * 0.07f, height * 0.07f, borderPaint)',
    "TTV: selected main trim frame sharp -> 7% radius")

apply_edit(
    TTV,
    'val selRadius = height * 0.22f',
    'val selRadius = height * 0.07f',
    "TTV: selected main no-trim radius 22% -> 7%")

apply_edit(
    TTV,
    'canvas.drawRoundRect(rectF, height * 0.22f, height * 0.22f, trackPaint)',
    'canvas.drawRoundRect(rectF, height * 0.03f, height * 0.03f, trackPaint)',
    "TTV: secondary track fill radius 22% -> 3%")

apply_edit(
    TTV,
    '                // phase 21: white rounded frame on every selected track\n'
    '                // (selection still reads via the amber tint below)\n'
    '                val trackRadius = height * 0.22f',
    '                // phase 21: white rounded frame on every selected track\n'
    '                // (selection still reads via the amber tint below);\n'
    '                // phase 24: radius retuned 22% -> 7% of the track height\n'
    '                val trackRadius = height * 0.07f',
    "TTV: secondary selected frame radius 22% -> 7%")

apply_edit(
    TTV,
    '                // phase 21: unselected tracks keep a soft white rounded\n'
    '                // outline, slightly more present than the old 20% hairline\n'
    '                val trackRadius = height * 0.22f',
    '                // phase 21: unselected tracks keep a soft white rounded\n'
    '                // outline, slightly more present than the old 20% hairline;\n'
    '                // phase 24: radius retuned 22% -> 3% (the sample editor\'s\n'
    '                // barely-rounded unselected strip)\n'
    '                val trackRadius = height * 0.03f',
    "TTV: secondary unselected outline radius 22% -> 3%")

apply_edit(
    TTV,
    '            handlePaint.color = Color.WHITE\n'
    '            if (isMainVideoTrack) {\n'
    '                // phase 23: main-track trim handles are plain sharp\n'
    '                // rectangles - while the clip is selected the whole\n'
    '                // silhouette (frame + handle blocks) reads as one clean\n'
    '                // rectangle; the rounded corners live only on the\n'
    '                // UNSELECTED clip\'s thumbnail outline (grip marks stay)\n'
    '                canvas.drawRect(startX, 0f, startX + currentHandleWidth, height.toFloat(), handlePaint)\n'
    '                canvas.drawRect(endX - currentHandleWidth, 0f, endX, height.toFloat(), handlePaint)\n'
    '            } else {\n'
    '                // phase 21 look kept for secondary tracks: handle blocks\n'
    '                // with rounded OUTER corners fusing into their rounded\n'
    '                // outlines (audio / text / image tracks)\n'
    '                val handleRadius = height * 0.22f\n'
    '                val handlePath = android.graphics.Path()\n'
    '                // Left handle - round only the outer (left) corners\n'
    '                handlePath.addRoundRect(\n'
    '                    RectF(startX, 0f, startX + currentHandleWidth, height.toFloat()),\n'
    '                    floatArrayOf(handleRadius, handleRadius, 0f, 0f, 0f, 0f, handleRadius, handleRadius),\n'
    '                    android.graphics.Path.Direction.CW\n'
    '                )\n'
    '                // Right handle - round only the outer (right) corners\n'
    '                handlePath.addRoundRect(\n'
    '                    RectF(endX - currentHandleWidth, 0f, endX, height.toFloat()),\n'
    '                    floatArrayOf(0f, 0f, handleRadius, handleRadius, handleRadius, handleRadius, 0f, 0f),\n'
    '                    android.graphics.Path.Direction.CW\n'
    '                )\n'
    '                canvas.drawPath(handlePath, handlePaint)\n'
    '            }',
    '            handlePaint.color = Color.WHITE\n'
    '            // phase 24: reference retune - every trim handle (main and\n'
    '            // secondary tracks alike) is a full-height white block whose\n'
    '            // OUTER corners carry the same small radius as the trim frame\n'
    '            // (7% of the track height, measured on the sample editor\'s\n'
    '            // selected clip); the inner edges stay straight against the\n'
    '            // thumbnails (phase 23 drew the main-track handles fully\n'
    '            // sharp, phase 21 rounded them at the oversized 22% radius)\n'
    '            val handleRadius = height * 0.07f\n'
    '            val handlePath = android.graphics.Path()\n'
    '            // Left handle - round only the outer (left) corners\n'
    '            handlePath.addRoundRect(\n'
    '                RectF(startX, 0f, startX + currentHandleWidth, height.toFloat()),\n'
    '                floatArrayOf(handleRadius, handleRadius, 0f, 0f, 0f, 0f, handleRadius, handleRadius),\n'
    '                android.graphics.Path.Direction.CW\n'
    '            )\n'
    '            // Right handle - round only the outer (right) corners\n'
    '            handlePath.addRoundRect(\n'
    '                RectF(endX - currentHandleWidth, 0f, endX, height.toFloat()),\n'
    '                floatArrayOf(0f, 0f, handleRadius, handleRadius, handleRadius, handleRadius, 0f, 0f),\n'
    '                android.graphics.Path.Direction.CW\n'
    '            )\n'
    '            canvas.drawPath(handlePath, handlePaint)',
    "TTV: handles unified - rounded outer corners at 7% (both track kinds)")

apply_edit(
    VEA,
    '            // phase 23: the rounded thumbnail silhouette shows only while\n'
    '            // the clip is UNSELECTED (the user\'s "corners visible" state);\n'
    '            // the selected clip goes square so the sharp trim frame and\n'
    '            // the handle blocks read as one clean rectangle (phase 22\n'
    '            // rounded this outline unconditionally)\n'
    '            val segmentSelected = selectedVideoIndex == index\n'
    '            segmentView.clipToOutline = true\n'
    '            segmentView.outlineProvider = object : android.view.ViewOutlineProvider() {\n'
    '                override fun getOutline(view: View, outline: android.graphics.Outline) {\n'
    '                    val outlineRadius = if (segmentSelected) 0f else view.height * 0.22f\n'
    '                    outline.setRoundRect(0, 0, view.width, view.height, outlineRadius)\n'
    '                }\n'
    '            }',
    '            // phase 24: reference retune - the UNSELECTED clip keeps a\n'
    '            // barely-rounded silhouette (3% of the height, the sample\n'
    '            // editor\'s ~4px-on-55dp corner) while the SELECTED clip\'s\n'
    '            // silhouette matches the 7% handle-corner radius so the\n'
    '            // thumbnails never poke out behind the rounded handles\n'
    '            val segmentSelected = selectedVideoIndex == index\n'
    '            segmentView.clipToOutline = true\n'
    '            segmentView.outlineProvider = object : android.view.ViewOutlineProvider() {\n'
    '                override fun getOutline(view: View, outline: android.graphics.Outline) {\n'
    '                    val outlineRadius = if (segmentSelected) view.height * 0.07f else view.height * 0.03f\n'
    '                    outline.setRoundRect(0, 0, view.width, view.height, outlineRadius)\n'
    '                }\n'
    '            }',
    "VEA: segment outline radius - selected 7% / unselected 3%")

# -- item 3: Cancel / Save pills -------------------------------------------

apply_edit(
    LAY,
    '            <LinearLayout\n'
    '                android:id="@+id/btnClose"\n'
    '                android:layout_width="wrap_content"\n'
    '                android:layout_height="40dp"\n'
    '                android:orientation="horizontal"\n'
    '                android:gravity="center"\n'
    '                android:paddingHorizontal="22dp"\n'
    '                android:background="@drawable/bg_cancel_pill"',
    '            <LinearLayout\n'
    '                android:id="@+id/btnClose"\n'
    '                android:layout_width="wrap_content"\n'
    '                android:layout_height="32dp"\n'
    '                android:orientation="horizontal"\n'
    '                android:gravity="center"\n'
    '                android:paddingHorizontal="15dp"\n'
    '                android:background="@drawable/bg_cancel_pill"',
    "LAY: Cancel pill height 40dp -> 32dp, padding 22dp -> 15dp")

apply_edit(
    LAY,
    '            <LinearLayout\n'
    '                android:id="@+id/layoutSaveSplit"\n'
    '                android:layout_width="96dp"\n'
    '                android:layout_height="40dp"\n'
    '                android:orientation="horizontal"\n'
    '                android:background="@drawable/bg_save_pill"',
    '            <LinearLayout\n'
    '                android:id="@+id/layoutSaveSplit"\n'
    '                android:layout_width="76dp"\n'
    '                android:layout_height="32dp"\n'
    '                android:orientation="horizontal"\n'
    '                android:background="@drawable/bg_save_pill"',
    "LAY: Save pill 96x40dp -> 76x32dp")

ensure_drawable(
    "bg_cancel_pill.xml",
    ["phase 21: reference top-bar Cancel pill", '<corners android:radius="20dp" />'],
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<!-- phase 24: reference retune - the pill shrinks to the sample\n'
    '     editor\'s 32dp height, so the full-round radius is 16dp now\n'
    '     (phase 21: charcoal #333333 capsule behind white text) -->\n'
    '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
    '    android:shape="rectangle">\n'
    '    <solid android:color="#333333" />\n'
    '    <corners android:radius="16dp" />\n'
    '</shape>\n',
    "drawable: bg_cancel_pill radius 20dp -> 16dp")

ensure_drawable(
    "bg_save_pill.xml",
    ["phase 21: reference top-bar Save pill", '<corners android:radius="20dp" />'],
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<!-- phase 24: reference retune - the pill shrinks to the sample\n'
    '     editor\'s 32dp height, so the full-round radius is 16dp now\n'
    '     (phase 21: vivid amber capsule behind bold black text) -->\n'
    '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
    '    android:shape="rectangle">\n'
    '    <solid android:color="@color/colorPrimary" />\n'
    '    <corners android:radius="16dp" />\n'
    '</shape>\n',
    "drawable: bg_save_pill radius 20dp -> 16dp")

print("edits applied: " + str(edits_applied) + ", skipped: " + str(edits_skipped))
if FAILED:
    print("EDIT FAILURES: " + str(len(FAILED)))
    for f in FAILED:
        print("  - " + f)
    sys.exit(1)

# =========================================================================
# GATES
# =========================================================================
passed = 0
failed = 0


def gate(label, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("  [GATE FAIL] " + label + (" " + detail if detail else ""))


def cntf(path, needle):
    return cnt(rd(path), needle)


# -- item 1: the + tile ----------------------------------------------------
L = rd(LAY)
NEW_TILE = (
    '<ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="26dp"\n'
    '                    android:layout_height="26dp"\n'
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_thin_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="8dp"\n'
    '                    app:tint="@color/textColor" />')
gate("LAY: add tile is the 26dp form with 8dp padding",
     cnt(L, NEW_TILE) == 1)
OLD_TILE = (
    '<ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="36dp"\n'
    '                    android:layout_height="36dp"')
gate("LAY: the 36dp tile form is gone",
     cnt(L, OLD_TILE) == 0)
gate("drawable: plus glyph has the 4-unit arms",
     cntf(D + "ic_add_thin_24.xml", "M10,2L14,2L14,10L22,10L22,14L14,14L14,22L10,22L10,14L2,14L2,10L10,10Z") == 1
     and cntf(D + "ic_add_thin_24.xml", "M11,2L13,2L13,11L22,11L22,13L13,13L13,22L11,22L11,13L2,13L2,11L11,11Z") == 0)
gate("drawable: tile border + radius survive (phase 20/22)",
     cntf(D + "bg_add_media_tile.xml", 'android:width="1.5dp"') == 1
     and cntf(D + "bg_add_media_tile.xml", '<corners android:radius="4dp" />') == 1
     and cntf(D + "bg_add_media_tile.xml", '<solid android:color="#2A2A2A" />') == 1)

# -- item 2: track radius retune -------------------------------------------
W = rd(TTV)
gate("TTV: every 22% radius is gone",
     cnt(W, "height * 0.22f") == 0)
gate("TTV: four 3% sites (fill x2, unselected outline, hairline stroke)",
     cnt(W, "height * 0.03f") == 4)
gate("TTV: five 7% occurrences (frame x2, selRadius, secondary selected, handles)",
     cnt(W, "height * 0.07f") == 5)
gate("TTV: selected main trim frame is the rounded 7% form",
     cnt(W, "canvas.drawRoundRect(frameRect, height * 0.07f, height * 0.07f, borderPaint)") == 1)
gate("TTV: 7 rounded-rect draw sites, zero plain drawRect left",
     cnt(W, "canvas.drawRoundRect") == 7 and cnt(W, "canvas.drawRect") == 0)
gate("TTV: one unified handle path (rounded outer corners)",
     cnt(W, "handlePath.addRoundRect") == 2
     and cnt(W, "canvas.drawPath(handlePath, handlePaint)") == 1
     and cnt(W, "val handleRadius = height * 0.07f") == 1)
gate("TTV: main/secondary handle split removed",
     cnt(W, "handlePaint.color = Color.WHITE\n            if (isMainVideoTrack) {") == 0
     and cnt(W, "if (isMainVideoTrack) {") == 1)
gate("TTV: handleWidth still scales with track height",
     cnt(W, "get() = (height * 0.30f).coerceAtLeast(24f)") == 1)
gate("TTV: grip marks survive",
     cnt(W, "#4D000000") == 1)
gate("TTV: frame stroke widths survive",
     cnt(W, "(height * 0.05f).coerceAtLeast(4f)") == 3)

V = rd(VEA)
gate("VEA: segment outline radius 7% selected / 3% unselected",
     cnt(V, "val outlineRadius = if (segmentSelected) view.height * 0.07f else view.height * 0.03f") == 1)
gate("VEA: the 0f/22% conditional is gone",
     cnt(V, "if (segmentSelected) 0f else view.height * 0.22f") == 0)
gate("VEA: selection binding survives",
     cnt(V, "val segmentSelected = selectedVideoIndex == index") == 1)

# -- item 3: pills ---------------------------------------------------------
NEW_CANCEL = (
    '            <LinearLayout\n'
    '                android:id="@+id/btnClose"\n'
    '                android:layout_width="wrap_content"\n'
    '                android:layout_height="32dp"\n'
    '                android:orientation="horizontal"\n'
    '                android:gravity="center"\n'
    '                android:paddingHorizontal="15dp"')
NEW_SAVE = (
    '            <LinearLayout\n'
    '                android:id="@+id/layoutSaveSplit"\n'
    '                android:layout_width="76dp"\n'
    '                android:layout_height="32dp"\n'
    '                android:orientation="horizontal"\n'
    '                android:background="@drawable/bg_save_pill"')
gate("LAY: Cancel pill is the 32dp / 15dp-padding form",
     cnt(L, NEW_CANCEL) == 1)
gate("LAY: Save pill is the 76x32dp form",
     cnt(L, NEW_SAVE) == 1)
gate("LAY: pill 17sp labels unchanged (sample ~17sp)",
     cnt(L, 'android:textSize="17sp"') == 2)
gate("drawable: both pill radii are 16dp",
     cntf(D + "bg_cancel_pill.xml", '<corners android:radius="16dp" />') == 1
     and cntf(D + "bg_save_pill.xml", '<corners android:radius="16dp" />') == 1)
gate("drawable: pill fills unchanged",
     cntf(D + "bg_cancel_pill.xml", '<solid android:color="#333333" />') == 1
     and cntf(D + "bg_save_pill.xml", '<solid android:color="@color/colorPrimary" />') == 1)

# -- prior-phase survival ---------------------------------------------------
gate("phase 15: fps tolerance gate survives",
     cntf(PLAN, "fpsCloseEnough") >= 2)
gate("phase 19a: framesDir hoist survives",
     cntf(PLAN, 'val framesDir = File(workDir, "trans_" + gap)') == 1)
gate("phase 20: slider style survives",
     cntf(THEMES, '<item name="sliderStyle">@style/Widget.CutLoss.Slider</item>') == 2
     and cntf(THEMES, '<style name="Widget.CutLoss.Slider"') == 1)
gate("phase 23: transition cut bar is the 2dp form",
     cntf(D + "ic_transition_cut_24.xml", "M11,6L13,6L13,18L11,18Z") == 1)
gate("phase 23: transition bowtie is the stroked outline form",
     cntf(D + "ic_transition_bowtie_24.xml", 'android:strokeWidth="1"') == 1)
gate("phase 23: global mute field survives",
     cntf(PLAN, "val muted: Boolean,\n        val hasAudio: Boolean") == 1)

# -- XML well-formedness ----------------------------------------------------
for p in [LAY, D + "ic_add_thin_24.xml", D + "bg_cancel_pill.xml", D + "bg_save_pill.xml"]:
    try:
        ET.parse(p)
        passed += 1
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


for p in [VEA, TTV]:
    errs = scan(rd(p))
    gate("kotlin-lite brace/paren balance: " + p, not errs, "; ".join(errs[:3]))

# -- no NEW non-ascii vs HEAD (multiset compare per touched file) -----------
TOUCHED = [LAY, VEA, TTV,
           D + "ic_add_thin_24.xml", D + "bg_cancel_pill.xml", D + "bg_save_pill.xml"]


def non_ascii_multiset(s):
    return Counter(c for c in s if ord(c) > 127)


for p in TOUCHED:
    try:
        head = subprocess.run(["git", "show", "HEAD:" + p],
                              capture_output=True, text=True, encoding="utf-8").stdout
    except Exception as e:
        gate("non-ascii compare " + p, False, str(e))
        continue
    if head == "" and os.path.exists(p):
        # file may be new vs HEAD - only compare when HEAD has it
        passed += 1
        continue
    gate("no new non-ascii vs HEAD: " + p,
         non_ascii_multiset(head) == non_ascii_multiset(rd(p)))

if failed:
    print("GATES FAILED: " + str(failed) + " of " + str(failed + passed))
    sys.exit(1)
print("ALL GATES GREEN (" + str(passed) + " checks)")
PYEOF

echo "== phase 24 done =="
