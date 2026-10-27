#!/usr/bin/env bash
###############################################################################
# CutLoss phase 22 -- timeline polish pass (5 user items)
#
# User requests (after phase 21, with two fresh timeline screenshots):
#   1. The plus in the add-next-video tile must NOT be bold.
#      ic_add_24 draws 4dp-thick arms; a new ic_add_thin_24 with 2dp
#      arms (standard Material weight = half the current stroke)
#      replaces it on btnTimelineAdd only - the other add buttons keep
#      the stock glyph.
#   2. The add tile's corner radius must be smaller.
#      bg_add_media_tile 10dp -> 4dp (~11% of the 36dp tile, matching
#      the reference design's corner proportions).
#   3. The thumbnail corners poke out from under the left/right handles
#      of the white trim frame. Pixel analysis of the user's screenshot
#      confirms it: blue-sky pixels [171,198,243] fill the rounded
#      corner notches of the white handles while the true background is
#      [27,26,32] - the RecyclerView thumbnails are square-cornered and
#      edge-to-edge, the white frame/handles are rounded. Fix: clip each
#      segment to a rounded outline (radius = 22% of the track height,
#      exactly the radius TrackTrimView draws for the frame and for the
#      handle outer corners), so the thumbnail content can never render
#      outside the white silhouette.
#   4. The transition chip must sit exactly between the two clips.
#      Pixel analysis of the screenshot shows the chip IS centered on
#      the true clip boundary (x=159 in the crop) and the RIGHT clip's
#      thumbnails start flush there - but the LEFT clip's thumbnail
#      strip ends ~12px short of its right edge because itemWidth
#      floors frameSpan/15 fifteen times (up to 15px cumulative
#      shortfall). That opens a dark gap before the boundary and makes
#      the chip look glued to the right clip. Fix: ceil() the frame item
#      width so the 15 tiles always cover the clip's full width; the
#      boundary becomes visually flush and the chip reads centered on
#      the cut. No change to the chip's own placement math.
#   5. The transition tile's corner radius must be smaller.
#      bg_transition_tile 7dp -> 3dp (~12% of the 24dp tile; the
#      reference chips measure a 5-6px radius on 56px tiles = 9-11%).
#
# Files: 1 new drawable (ic_add_thin_24.xml) + edits in
#        bg_add_media_tile.xml, bg_transition_tile.xml,
#        activity_video_editing.xml and VideoEditingActivity.kt.
#
# Idempotent: re-running skips anything already applied.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

LAY="app/src/main/res/layout/activity_video_editing.xml"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
SEP="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
TTV="app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
ADT="app/src/main/res/drawable/bg_add_media_tile.xml"
TRT="app/src/main/res/drawable/bg_transition_tile.xml"
TBTN="app/src/main/res/layout/item_transition_button.xml"
SEG="app/src/main/res/layout/item_sequence_segment.xml"

for f in "$LAY" "$VEA" "$SEP" "$TTV" "$ADT" "$TRT" "$TBTN" "$SEG"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 22: applying the timeline polish pass =="

python3 - <<'PYEOF'
import os
import sys

LAY = "app/src/main/res/layout/activity_video_editing.xml"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
SEP = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
ADT = "app/src/main/res/drawable/bg_add_media_tile.xml"
TRT = "app/src/main/res/drawable/bg_transition_tile.xml"
THIN = "app/src/main/res/drawable/ic_add_thin_24.xml"
TBTN = "app/src/main/res/layout/item_transition_button.xml"
SEG = "app/src/main/res/layout/item_sequence_segment.xml"

edits_applied = 0
edits_skipped = 0
files_written = 0

# snapshot the non-ascii multiset of files that already carry utf-8
# bytes BEFORE any edit, so the purity gate can pin "no NEW non-ascii"
def nonascii_multiset(s):
    d = {}
    for ch in s:
        if ord(ch) > 127:
            d[ch] = d.get(ch, 0) + 1
    return d

pre_nonascii = {p: nonascii_multiset(open(p, "r").read())
                for p in [LAY, VEA]}


def rd(p):
    with open(p, "r") as f:
        return f.read()


def wr(p, s):
    with open(p, "w") as f:
        f.write(s)


def apply_edit(path, old, new, name):
    global edits_applied, edits_skipped
    s = rd(path)
    if new in s:
        edits_skipped += 1
        print("  [skip] " + name + ": already applied")
        return
    if old not in s:
        print("  [FAIL] " + name + ": anchor not found")
        sys.exit(1)
    if s.count(old) != 1:
        print("  [FAIL] " + name + ": anchor not unique")
        sys.exit(1)
    wr(path, s.replace(old, new, 1))
    edits_applied += 1
    print("  [ OK ] " + name)


# ---------------------------------------------------------------------------
# E1: add tile radius 10dp -> 4dp
# ---------------------------------------------------------------------------
apply_edit(
    ADT,
    '    <corners android:radius="10dp" />',
    '    <!-- phase 22: radius 10dp -> 4dp (~11% of the 36dp tile, the\n'
    '         reference proportion - the user asked for less rounding) -->\n'
    '    <corners android:radius="4dp" />',
    "E1 add-tile corner radius 10dp -> 4dp")

# ---------------------------------------------------------------------------
# E2a: transition tile radius 7dp -> 3dp
# ---------------------------------------------------------------------------
apply_edit(
    TRT,
    '    <corners android:radius="7dp" />',
    '    <!-- phase 22: radius 7dp -> 3dp (~12% of the 24dp tile, matching\n'
    '         the measured reference chips) -->\n'
    '    <corners android:radius="3dp" />',
    "E2a transition-tile corner radius 7dp -> 3dp")

# E2b: refresh the stale phase-21 header comment (it still says 7dp)
apply_edit(
    TRT,
    '<!-- phase 21: the reference transition chip tile - a white rounded\n'
    '     square (7dp radius, squircle-ish) that floats between the clips -->',
    '<!-- phase 21: the reference transition chip tile - a white rounded\n'
    '     square that floats between the clips (radius 7dp -> 3dp in\n'
    '     phase 22 per the user request for less rounding) -->',
    "E2b transition-tile header comment refreshed")

# ---------------------------------------------------------------------------
# E3: btnTimelineAdd switches to the new non-bold plus
# ---------------------------------------------------------------------------
apply_edit(
    LAY,
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_24"',
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_thin_24"',
    "E3 btnTimelineAdd uses the thin plus glyph")

# ---------------------------------------------------------------------------
# E4: clip each segment to the rounded frame silhouette (corner poke fix)
# ---------------------------------------------------------------------------
apply_edit(
    VEA,
    '            val segmentView = layoutInflater.inflate(R.layout.item_sequence_segment, sequenceTrackContainer, false) as FrameLayout\n'
    '            segmentView.clipChildren = false\n'
    '            segmentView.clipToPadding = false',
    '            val segmentView = layoutInflater.inflate(R.layout.item_sequence_segment, sequenceTrackContainer, false) as FrameLayout\n'
    '            segmentView.clipChildren = false\n'
    '            segmentView.clipToPadding = false\n'
    '            // phase 22: clip the clip\'s thumbnails to the rounded\n'
    '            // silhouette of the white trim frame (the same 22%-of-height\n'
    '            // radius TrackTrimView draws for the frame and the handle\n'
    '            // outer corners); without it the square thumbnail corners\n'
    '            // poke out under the rounded handle corners\n'
    '            segmentView.clipToOutline = true\n'
    '            segmentView.outlineProvider = object : android.view.ViewOutlineProvider() {\n'
    '                override fun getOutline(view: View, outline: android.graphics.Outline) {\n'
    '                    outline.setRoundRect(0, 0, view.width, view.height, view.height * 0.22f)\n'
    '                }\n'
    '            }\n'
    '            segmentView.post { segmentView.invalidateOutline() }',
    "E4 segment rounded-outline clip (corner poke fix)")

# ---------------------------------------------------------------------------
# E5: frame item width ceil() so the strip covers the full clip width
# ---------------------------------------------------------------------------
apply_edit(
    VEA,
    '            val itemWidth = maxOf(1, ((frameSpanMs * pixelsPerMs) / 15).toInt())',
    '            // phase 22: round UP so the 15 frame tiles always cover the\n'
    '            // clip\'s full width; with floor() the strip could end up to\n'
    '            // 15px short of the right edge, leaving a dark gap before\n'
    '            // the next clip that made the transition chip look glued to\n'
    '            // the right clip instead of sitting centered on the cut\n'
    '            val itemWidth = maxOf(1, kotlin.math.ceil(frameSpanMs * pixelsPerMs / 15f).toInt())',
    "E5 frame item width ceil (flush clip boundary)")

# ---------------------------------------------------------------------------
# E6: new drawable ic_add_thin_24.xml (the non-bold plus)
# ---------------------------------------------------------------------------
THIN_CONTENT = '''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 22: the non-bold plus for the timeline add-media tile -
     2dp-thick arms (half the 4dp weight of ic_add_24) so the glyph
     reads thin inside the rounded square like the reference tile;
     only btnTimelineAdd switches to it, the other add buttons keep
     the stock weight -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M11,2L13,2L13,11L22,11L22,13L13,13L13,22L11,22L11,13L2,13L2,11L11,11Z" />
</vector>
'''
if os.path.exists(THIN) and rd(THIN) == THIN_CONTENT:
    print("  [skip] E6 ic_add_thin_24.xml: already present")
elif os.path.exists(THIN):
    print("  [FAIL] E6 ic_add_thin_24.xml: exists with unexpected content")
    sys.exit(1)
else:
    wr(THIN, THIN_CONTENT)
    files_written += 1
    print("  [ OK ] E6 ic_add_thin_24.xml written")

print("  edits applied: " + str(edits_applied) +
      ", skipped: " + str(edits_skipped) +
      ", files written: " + str(files_written))

# ###########################################################################
# Verification gates
# ###########################################################################
gates_passed = 0
gates_failed = 0


def gate(name, ok, detail=""):
    global gates_passed, gates_failed
    if ok:
        gates_passed += 1
        print("  [GATE OK] " + name)
    else:
        gates_failed += 1
        print("  [GATE FAIL] " + name + (" - " + detail if detail else ""))


def cnt(path, needle):
    return rd(path).count(needle)

# -- 1. XML well-formedness on every touched + survival XML ----------------
import xml.etree.ElementTree as ET
for p in [LAY, ADT, TRT, TBTN, SEG]:
    try:
        ET.parse(p)
        gate("XML well-formed: " + p, True)
    except Exception as e:
        gate("XML well-formed: " + p, False, str(e))
try:
    ET.parse(THIN)
    gate("XML well-formed: " + THIN, True)
except Exception as e:
    gate("XML well-formed: " + THIN, False, str(e))

# -- 2. ASCII purity: drawables fully ASCII; LAY/VEA no NEW non-ascii -----
for p in [ADT, TRT, THIN]:
    gate("pure ASCII: " + p, all(ord(c) < 128 for c in rd(p)))
for p in [LAY, VEA]:
    now = nonascii_multiset(rd(p))
    gate("no NEW non-ascii vs run start: " + p, now == pre_nonascii[p])

# -- 3. add tile geometry ---------------------------------------------------
gate("add tile radius is 4dp now",
     cnt(ADT, '<corners android:radius="4dp" />') == 1
     and cnt(ADT, '<corners android:radius="10dp" />') == 0)
gate("add tile fill/stroke survive phase 20",
     cnt(ADT, '<solid android:color="#2A2A2A" />') == 1
     and cnt(ADT, '<stroke android:width="1.5dp" android:color="#FFFFFF" />') == 1)

# -- 4. transition tile geometry --------------------------------------------
gate("transition tile radius is 3dp now",
     cnt(TRT, '<corners android:radius="3dp" />') == 1
     and cnt(TRT, '<corners android:radius="7dp" />') == 0)
gate("transition tile keeps the solid white fill",
     cnt(TRT, '<solid android:color="#FFFFFF" />') == 1)

# -- 5. thin plus drawable --------------------------------------------------
gate("ic_add_thin_24 has exactly one 2dp-arm plus path",
     cnt(THIN, '<path') == 1
     and cnt(THIN, 'M11,2L13,2L13,11L22,11L22,13L13,13L13,22L11,22L11,13L2,13L2,11L11,11Z') == 1
     and cnt(THIN, 'android:fillColor="#FFFFFF"') == 1)
gate("ic_add_thin_24 is a 24dp vector",
     cnt(THIN, 'android:width="24dp"') == 1
     and cnt(THIN, 'android:viewportWidth="24"') == 1)

# -- 6. layout wiring -------------------------------------------------------
gate("btnTimelineAdd uses the thin plus",
     cnt(LAY, 'android:src="@drawable/ic_add_thin_24"') == 1
     and cnt(LAY, 'android:src="@drawable/ic_add_24"') == 1)
gate("btnTimelineAdd tile geometry survives",
     cnt(LAY, 'android:background="@drawable/bg_add_media_tile"') == 1
     and cnt(LAY, 'android:padding="10dp"') >= 1)
gate("phase 20/21 top bar + chip wiring survives",
     cnt(LAY, 'tvResolutionBadge') >= 1
     and cnt(LAY, 'bg_save_pill') >= 1
     and cnt(LAY, 'bg_cancel_pill') >= 1
     and cnt(TBTN, 'bg_transition_tile') == 1
     and cnt(TBTN, 'ic_transition_cut_24') == 1)

# -- 7. VEA: rounded outline clip ------------------------------------------
gate("segmentView rounded outline clip installed",
     cnt(VEA, 'segmentView.clipToOutline = true') == 1
     and cnt(VEA, 'segmentView.outlineProvider = object : android.view.ViewOutlineProvider()') == 1
     and cnt(VEA, 'outline.setRoundRect(0, 0, view.width, view.height, view.height * 0.22f)') == 1
     and cnt(VEA, 'segmentView.post { segmentView.invalidateOutline() }') == 1)
gate("outline radius matches the frame radius in TrackTrimView",
     cnt(VEA, 'view.height * 0.22f') == 1
     and cnt(TTV, 'height * 0.22f') >= 2)

# -- 8. VEA: frame width ceil + chip placement untouched -------------------
gate("frame item width uses ceil now",
     cnt(VEA, 'kotlin.math.ceil(frameSpanMs * pixelsPerMs / 15f)') == 1
     and cnt(VEA, '((frameSpanMs * pixelsPerMs) / 15).toInt()') == 0)
gate("transition chip placement math untouched (still boundary-centered)",
     cnt(VEA, 'leftMargin = segmentLeft - transitionWidth / 2') == 1
     and cnt(VEA, 'val transitionWidth = 24.dpToPx()') == 1)
gate("phase 21 transition glyph states survive",
     cnt(VEA, 'ic_transition_bowtie_24') >= 1
     and cnt(VEA, 'ic_transition_cut_24') >= 1)

# -- 9. phase 19a survival (SmartExportPlanner scope fix) ------------------
gate("phase 19a hoisted declarations survive",
     cnt(SEP, 'val rightStartMs = right.trimStartMs') == 1
     and cnt(SEP, 'val framesDir = File(workDir, "trans_" + gap)') == 1)

# -- 10. kotlin-lite brace/paren balance ------------------------------------
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

# ###########################################################################
print("  gates passed: " + str(gates_passed) + ", failed: " + str(gates_failed))
if gates_failed > 0:
    print("PHASE 22 GATES FAILED")
    sys.exit(1)
print("PHASE 22 GATES GREEN")
PYEOF

echo "== phase 22: done =="
