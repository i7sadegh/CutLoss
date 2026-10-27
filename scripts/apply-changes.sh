#!/usr/bin/env bash
###############################################################################
# CutLoss phase 20 -- "match the reference images": 4 UI polish fixes
# reported by the user after the phase-19 amber rebrand
#
# User report (4 items):
#   1. The back-press dialog's "Keep Editing" button text is DARK on the
#      dark surfaceContainerHigh background and unreadable. Root cause:
#      the button sets no textColor, so it inherits the theme default
#      colorOnPrimary, which phase 19 turned BLACK (onAmber) for the
#      amber buttons -> black-on-near-black. Fix: explicit light
#      textColor (#F2F2F2) on that one button.
#   2. The "+" add-media button in the timeline (btnTimelineAdd) must
#      become the reference image's tile: a dark rounded square
#      (sampled #2A2A2A) with a thin white border (1.5dp) and a white
#      plus glyph. It is currently an amber circle with a black plus.
#      New drawable bg_add_media_tile.xml; the button keeps its 36dp
#      size, padding and floating elevation.
#   3. The frame around the (main video) track must be WHITE. The
#      TrackTrimView draws that frame in amber (#FFB200) at two sites
#      (trim-enabled 8f border + selection 10f border); both become
#      #FFFFFF. The 20% amber selection overlay, the amber trim handles
#      and the secondary-track borders stay as they are.
#   4. Every value slider must look like the reference image: a fat
#      amber capsule track (measured 60px = 20dp at 3x, rounded ends)
#      with a white circular thumb (34px = ~12dp diameter) riding
#      INSIDE the track, a dark inactive track and no tick dots.
#      Implemented once in the theme: sliderStyle -> Widget.CutLoss.Slider
#      (parent Widget.Material3.Slider, verified against the Material
#      1.9.0 AAR: trackHeight/thumbRadius/thumbColor/trackColorActive/
#      trackColorInactive/haloColor/tickVisible all exist, the track is
#      a Cap.ROUND stroke so the capsule + 4dp amber nose past the thumb
#      match the reference pixels exactly, and the widget stays 48dp
#      tall for touch). The four sliders that carried explicit
#      thumbColor/trackColorActive overrides (audio fade x2, custom
#      speed, audio volume - one even had a stale blue halo) drop them
#      so the theme style rules all 21 sliders uniformly.
#
# Idempotent: re-running skips every edit that is already present.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

BASE="app/src/main"
DIALOG_UNSAVED="$BASE/res/layout/dialog_unsaved_changes.xml"
LAY_EDITING="$BASE/res/layout/activity_video_editing.xml"
TRACK_VIEW="$BASE/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
THEMES="$BASE/res/values/themes.xml"
DIALOG_FADE="$BASE/res/layout/dialog_audio_fade.xml"
TOOLBAR_SPEED="$BASE/res/layout/speed_editing_toolbar.xml"
TOOLBAR_AUDIO="$BASE/res/layout/audio_editing_toolbar.xml"
TILE_DRAWABLE="$BASE/res/drawable/bg_add_media_tile.xml"

for f in "$DIALOG_UNSAVED" "$LAY_EDITING" "$TRACK_VIEW" "$THEMES" "$DIALOG_FADE" "$TOOLBAR_SPEED" "$TOOLBAR_AUDIO"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 20: applying the reference-image UI polish =="

python3 - <<'PYEOF'
import sys

edits_applied = 0
edits_skipped = 0


def apply_edit(path, old, new, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
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
    s = s.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1
    print("  [ OK ] " + name)


# ---------------------------------------------------------------------------
# 1. Keep Editing: light text on the dark surface button
# ---------------------------------------------------------------------------
apply_edit(
    "app/src/main/res/layout/dialog_unsaved_changes.xml",
    '        android:text="Keep Editing"\n'
    '        android:textAllCaps="false"\n'
    '        android:textSize="16sp"\n'
    '        android:textStyle="bold"\n'
    '        app:cornerRadius="12dp"\n',
    '        android:text="Keep Editing"\n'
    '        android:textAllCaps="false"\n'
    '        android:textSize="16sp"\n'
    '        android:textStyle="bold"\n'
    '        android:textColor="@color/textColor"\n'
    '        app:cornerRadius="12dp"\n',
    "Keep Editing light textColor",
)

# ---------------------------------------------------------------------------
# 2. The add-media tile: dark rounded square, white border, white glyph
# ---------------------------------------------------------------------------
apply_edit(
    "app/src/main/res/layout/activity_video_editing.xml",
    '                <ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="36dp"\n'
    '                    android:layout_height="36dp"\n'
    '                    android:background="@drawable/circle_primary_container"\n'
    '                    android:src="@drawable/ic_add_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="8dp"\n'
    '                    app:tint="@color/onAmber" />\n',
    '                <!-- phase 20: the add-media tile mirrors the reference\n'
    '                     design - a dark rounded square with a thin white\n'
    '                     border and a white plus glyph (was an amber\n'
    '                     circle with a black plus) -->\n'
    '                <ImageButton\n'
    '                    android:id="@+id/btnTimelineAdd"\n'
    '                    android:layout_width="36dp"\n'
    '                    android:layout_height="36dp"\n'
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="8dp"\n'
    '                    app:tint="@color/textColor" />\n',
    "btnTimelineAdd -> reference tile style",
)

# ---------------------------------------------------------------------------
# 3. The frame around the main track: amber -> white (2 sites)
# ---------------------------------------------------------------------------
apply_edit(
    "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt",
    '                    // Draw a thick border enclosing the active range when selected\n'
    '                    borderPaint.color = Color.parseColor("#FFB200")\n'
    '                    borderPaint.strokeWidth = 8f\n',
    '                    // Draw a thick border enclosing the active range when selected\n'
    '                    // (phase 20: white frame around the track per the reference\n'
    '                    // design; the amber overlay below stays as the selection\n'
    '                    // tint)\n'
    '                    borderPaint.color = Color.parseColor("#FFFFFF")\n'
    '                    borderPaint.strokeWidth = 8f\n',
    "trim border -> white",
)

apply_edit(
    "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt",
    '                    // Main track selection highlight without trimmer handles/ghosts\n'
    '                    borderPaint.color = Color.parseColor("#FFB200") // Amber selection\n',
    '                    // Main track selection highlight without trimmer handles/ghosts\n'
    '                    // (phase 20: white frame per the reference design)\n'
    '                    borderPaint.color = Color.parseColor("#FFFFFF") // White selection\n',
    "selection border -> white",
)

# ---------------------------------------------------------------------------
# 4a. The slider theme: one style for all 21 Material Sliders
# ---------------------------------------------------------------------------
apply_edit(
    "app/src/main/res/values/themes.xml",
    '        <item name="android:windowActivityTransitions">true</item>\n'
    '    </style>\n',
    '        <item name="android:windowActivityTransitions">true</item>\n'
    '        <!-- phase 20: every Material Slider gets the reference look - a\n'
    '             fat amber capsule track with a white round thumb riding in\n'
    '             it (Widget.CutLoss.Slider below) -->\n'
    '        <item name="sliderStyle">@style/Widget.CutLoss.Slider</item>\n'
    '    </style>\n',
    "AppTheme sliderStyle",
)

apply_edit(
    "app/src/main/res/values/themes.xml",
    '        <item name="android:statusBarColor">@color/statusBarColor</item>\n'
    '    </style>\n'
    '\n'
    '    <style name="DialogShapeAppearance" parent="">\n',
    '        <item name="android:statusBarColor">@color/statusBarColor</item>\n'
    '        <item name="sliderStyle">@style/Widget.CutLoss.Slider</item>\n'
    '    </style>\n'
    '\n'
    '    <style name="DialogShapeAppearance" parent="">\n',
    "Editor sliderStyle",
)

apply_edit(
    "app/src/main/res/values/themes.xml",
    '    <style name="DialogShapeAppearance" parent="">\n'
    '        <item name="cornerFamily">rounded</item>\n'
    '        <item name="cornerSize">24dp</item>\n'
    '    </style>\n'
    '\n'
    '</resources>\n',
    '    <style name="DialogShapeAppearance" parent="">\n'
    '        <item name="cornerFamily">rounded</item>\n'
    '        <item name="cornerSize">24dp</item>\n'
    '    </style>\n'
    '\n'
    '    <!-- phase 20: the reference-image slider - a fat amber capsule\n'
    '         track (20dp, Cap.ROUND ends so the capsule shape and the\n'
    '         amber nose past the thumb match the reference pixels) with a\n'
    '         white circular thumb (12dp) riding inside it, a dark\n'
    '         inactive track and no tick dots. Applies to every\n'
    '         com.google.android.material.slider.Slider via the\n'
    '         sliderStyle theme attribute (Material 1.9.0 verified). -->\n'
    '    <style name="Widget.CutLoss.Slider" parent="Widget.Material3.Slider">\n'
    '        <item name="trackColorActive">@color/colorPrimary</item>\n'
    '        <item name="trackColorInactive">@color/outlineVariant</item>\n'
    '        <item name="thumbColor">@color/textColor</item>\n'
    '        <item name="haloColor">@color/sliderHalo</item>\n'
    '        <item name="trackHeight">20dp</item>\n'
    '        <item name="thumbRadius">6dp</item>\n'
    '        <item name="tickVisible">false</item>\n'
    '    </style>\n'
    '\n'
    '</resources>\n',
    "Widget.CutLoss.Slider style",
)

# ---------------------------------------------------------------------------
# 4b. Drop the per-slider overrides that fight the theme style
# ---------------------------------------------------------------------------
apply_edit(
    "app/src/main/res/layout/dialog_audio_fade.xml",
    '        <com.google.android.material.slider.Slider\n'
    '            android:id="@+id/fadeInSlider"\n'
    '            android:layout_width="0dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:layout_weight="1"\n'
    '            android:valueFrom="0.0"\n'
    '            android:valueTo="5.0"\n'
    '            android:value="0.0"\n'
    '            app:thumbColor="@color/colorPrimary"\n'
    '            app:trackColorActive="@color/colorPrimary" />\n',
    '        <com.google.android.material.slider.Slider\n'
    '            android:id="@+id/fadeInSlider"\n'
    '            android:layout_width="0dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:layout_weight="1"\n'
    '            android:valueFrom="0.0"\n'
    '            android:valueTo="5.0"\n'
    '            android:value="0.0" />\n',
    "fadeInSlider inherits the theme slider style",
)

apply_edit(
    "app/src/main/res/layout/dialog_audio_fade.xml",
    '        <com.google.android.material.slider.Slider\n'
    '            android:id="@+id/fadeOutSlider"\n'
    '            android:layout_width="0dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:layout_weight="1"\n'
    '            android:valueFrom="0.0"\n'
    '            android:valueTo="5.0"\n'
    '            android:value="0.0"\n'
    '            app:thumbColor="@color/colorPrimary"\n'
    '            app:trackColorActive="@color/colorPrimary" />\n',
    '        <com.google.android.material.slider.Slider\n'
    '            android:id="@+id/fadeOutSlider"\n'
    '            android:layout_width="0dp"\n'
    '            android:layout_height="wrap_content"\n'
    '            android:layout_weight="1"\n'
    '            android:valueFrom="0.0"\n'
    '            android:valueTo="5.0"\n'
    '            android:value="0.0" />\n',
    "fadeOutSlider inherits the theme slider style",
)

apply_edit(
    "app/src/main/res/layout/speed_editing_toolbar.xml",
    '                android:value="1.0"\n'
    '                android:stepSize="0.1"\n'
    '                app:haloColor="#3300C3FF"\n'
    '                app:thumbColor="@color/colorPrimary"\n'
    '                app:trackColorActive="@color/colorPrimary"\n'
    '                app:trackColorInactive="@color/surfaceVariant" />\n',
    '                android:value="1.0"\n'
    '                android:stepSize="0.1" />\n',
    "custom speed slider inherits the theme slider style",
)

apply_edit(
    "app/src/main/res/layout/audio_editing_toolbar.xml",
    '            android:valueFrom="0.0"\n'
    '            android:valueTo="2.0"\n'
    '            android:value="1.0"\n'
    '            app:thumbColor="@color/colorPrimary"\n'
    '            app:trackColorActive="@color/colorPrimary" />\n',
    '            android:valueFrom="0.0"\n'
    '            android:valueTo="2.0"\n'
    '            android:value="1.0" />\n',
    "audio volume slider inherits the theme slider style",
)

print("edits applied: " + str(edits_applied) + ", skipped: " + str(edits_skipped))
PYEOF

# ---------------------------------------------------------------------------
# New drawable: the add-media tile background (only if missing)
# ---------------------------------------------------------------------------
if [ ! -f "$TILE_DRAWABLE" ]; then
  mkdir -p "$(dirname "$TILE_DRAWABLE")"
  cat > "$TILE_DRAWABLE" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- phase 20: the reference-image add tile - a dark rounded square
     (sampled #2A2A2A) with a thin white border, hosting a white plus
     glyph (the glyph tint lives on the ImageButton). -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#2A2A2A" />
    <stroke android:width="1.5dp" android:color="#FFFFFF" />
    <corners android:radius="10dp" />
</shape>
XMLEOF
  echo "  [ OK ] bg_add_media_tile.xml created"
else
  echo "  [skip] bg_add_media_tile.xml: already present"
fi

echo "== phase 20: gates =="

python3 - <<'PYEOF'
import sys
import xml.etree.ElementTree as ET
import glob

failures = []


def gate(name, ok, detail=""):
    print(("  [ OK ] " if ok else "  [FAIL] ") + name + ((" - " + detail) if detail else ""))
    if not ok:
        failures.append(name)


def read(path):
    with open(path, "r") as f:
        return f.read()


# --- 1. Keep Editing -------------------------------------------------------
s = read("app/src/main/res/layout/dialog_unsaved_changes.xml")
i = s.find('android:text="Keep Editing"')
blk = s[i:i + 600]
gate("Keep Editing has light textColor", 'android:textColor="@color/textColor"' in blk)

# --- 2. The add-media tile -------------------------------------------------
lay = read("app/src/main/res/layout/activity_video_editing.xml")
j = lay.find('android:id="@+id/btnTimelineAdd"')
blk2 = lay[j:j + 700]
gate("btnTimelineAdd uses the tile drawable", 'android:background="@drawable/bg_add_media_tile"' in blk2)
gate("btnTimelineAdd glyph is white", 'app:tint="@color/textColor"' in blk2)
gate("btnTimelineAdd dropped the amber circle", 'circle_primary_container' not in blk2)
gate("btnTimelineAdd keeps 36dp size", 'android:layout_width="36dp"' in blk2 and 'android:layout_height="36dp"' in blk2)

tile_path = "app/src/main/res/drawable/bg_add_media_tile.xml"
try:
    tile = read(tile_path)
    ET.fromstring(tile)
    gate("bg_add_media_tile.xml exists + well-formed", True)
    gate("tile fill is the sampled dark", '#2A2A2A' in tile)
    gate("tile stroke is white 1.5dp", 'android:width="1.5dp"' in tile and '#FFFFFF' in tile)
    gate("tile corner radius 10dp", 'android:radius="10dp"' in tile)
except Exception as e:
    gate("bg_add_media_tile.xml exists + well-formed", False, str(e))

# --- 3. The white track frame ----------------------------------------------
tv = read("app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt")
gate("track frame white x2 (trim + selection)", tv.count('Color.parseColor("#FFFFFF")') == 2,
     "count=" + str(tv.count('Color.parseColor("#FFFFFF")')))
gate("amber frame gone from the main track", tv.count('Color.parseColor("#FFB200")') == 2,
     "count=" + str(tv.count('Color.parseColor("#FFB200")')) + " (secondary-track selected + trim handles)")
gate("20% amber selection overlay kept", tv.count('"#33FFB200"') == 1)
gate("trim handles stay amber", 'handlePaint.color = Color.parseColor("#FFB200")' in tv)

# --- 4. The slider theme ----------------------------------------------------
th = read("app/src/main/res/values/themes.xml")
gate("sliderStyle set in both themes", th.count('<item name="sliderStyle">@style/Widget.CutLoss.Slider</item>') == 2)
gate("Widget.CutLoss.Slider style present", 'parent="Widget.Material3.Slider"' in th)
for item in ['trackColorActive">@color/colorPrimary', 'trackColorInactive">@color/outlineVariant',
             'thumbColor">@color/textColor', 'haloColor">@color/sliderHalo',
             'trackHeight">20dp', 'thumbRadius">6dp', 'tickVisible">false']:
    gate("slider style item " + item.split('">')[0], ('<item name="' + item) in th)

# --- 4b. no per-slider overrides left ---------------------------------------
for path, label in [
    ("app/src/main/res/layout/dialog_audio_fade.xml", "audio fade"),
    ("app/src/main/res/layout/speed_editing_toolbar.xml", "speed toolbar"),
    ("app/src/main/res/layout/audio_editing_toolbar.xml", "audio toolbar"),
]:
    t = read(path)
    gate(label + ": overrides removed",
         "app:thumbColor" not in t and "app:trackColorActive" not in t and
         "app:trackColorInactive" not in t and "app:haloColor" not in t)

# --- 5. slider population unchanged -----------------------------------------
total = 0
for f in glob.glob("app/src/main/res/layout/*.xml"):
    total += read(f).count("com.google.android.material.slider.Slider")
gate("all 21 Material Sliders intact", total == 21, "count=" + str(total))

# --- 6. XML well-formedness of every edited XML ------------------------------
for path in ["app/src/main/res/layout/dialog_unsaved_changes.xml",
             "app/src/main/res/layout/activity_video_editing.xml",
             "app/src/main/res/values/themes.xml",
             "app/src/main/res/layout/dialog_audio_fade.xml",
             "app/src/main/res/layout/speed_editing_toolbar.xml",
             "app/src/main/res/layout/audio_editing_toolbar.xml",
             "app/src/main/res/drawable/bg_add_media_tile.xml"]:
    try:
        ET.fromstring(read(path))
        gate("well-formed XML: " + path.split("/")[-1], True)
    except Exception as e:
        gate("well-formed XML: " + path.split("/")[-1], False, str(e))

# --- 7. ASCII purity of the edited files -------------------------------------
for path in ["app/src/main/res/layout/dialog_unsaved_changes.xml",
             "app/src/main/res/layout/activity_video_editing.xml",
             "app/src/main/res/values/themes.xml",
             "app/src/main/res/layout/dialog_audio_fade.xml",
             "app/src/main/res/layout/speed_editing_toolbar.xml",
             "app/src/main/res/layout/audio_editing_toolbar.xml",
             "app/src/main/res/drawable/bg_add_media_tile.xml"]:
    try:
        read(path).encode("ascii")
        gate("pure ASCII: " + path.split("/")[-1], True)
    except UnicodeEncodeError as e:
        gate("pure ASCII: " + path.split("/")[-1], False, str(e))

# --- 8. Kotlin-lite brace/paren balance for TrackTrimView ---------------------
def scan(src):
    stack = [("code", 0)]
    depth = 0
    paren = 0
    errs = []
    line = 1
    i, n = 0, len(src)
    while i < n:
        mode = stack[-1][0]
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "\n":
            line += 1
            if mode == "lcom":
                stack.pop()
            i += 1
            continue
        if mode == "lcom":
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
            if ch == '"' and nxt == '"' and src[i + 2] == '"':
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
            if nxt == '"' and src[i + 2] == '"':
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

errs = scan(tv)
gate("TrackTrimView brace/paren balance", not errs, "; ".join(errs[:3]))

# --- 9. survival gates from the earlier phases --------------------------------
fc = 0
for f in glob.glob("app/src/main/java/**/*.kt", recursive=True) + glob.glob("app/src/main/java/**/*.java", recursive=True):
    fc += read(f).count("filter_complex")
gate("filter_complex stays banned", fc == 0, "count=" + str(fc))

planner = read("app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt")
gate("phase 19a scope fix survives", planner.count("val rightStartMs = right.trimStartMs") == 1 and
     planner.count('val framesDir = File(workDir, "trans_" + gap)') == 1)
gate("phase 19 preparation ticks survive", planner.count("onPrepareProgress?.invoke(1, R.string.str_preparing_analyzing)") == 1)

if failures:
    print("GATE FAILURES: " + ", ".join(failures))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 20: done =="
