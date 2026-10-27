#!/usr/bin/env bash
###############################################################################
# CutLoss phase 21 -- reference-UI alignment pass (5 user items)
#
# User requests (after phase 20):
#   1. The plus glyph inside the rounded add-media tile must shrink
#      (padding 8dp -> 10dp lands the glyph at ~37% of the tile).
#   2. The between-clips transition chip must match the reference in
#      BOTH states: a white rounded-square tile with a black vertical
#      cut bar when empty and a black bowtie when a transition is set.
#   3. The frame around every track must match the reference: a white
#      ROUNDED rectangle whose left/right edges are the thick white
#      trim-handle zones (rounded outer corners, centered grip marks).
#   4. The top bar must mirror the reference: dark Cancel pill on the
#      left, gray resolution label in the center, vivid amber Save pill
#      on the right; undo/redo move from the top bar to the right of
#      the play button; the magnet moves to the left, beside the
#      timeline-expand arrow.
#   5. Where the reference shows "1080p", show the inert text "RES"
#      for now (a real resolution selector arrives in a later phase).
#
# Files: 5 new drawables + edits in activity_video_editing.xml,
#        item_transition_button.xml, strings.xml,
#        VideoEditingActivity.kt and TrackTrimView.kt.
#
# Idempotent: re-running skips anything already applied.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

LAY="app/src/main/res/layout/activity_video_editing.xml"
TBTN="app/src/main/res/layout/item_transition_button.xml"
STR="app/src/main/res/values/strings.xml"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
TTV="app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"

for f in "$LAY" "$TBTN" "$STR" "$VEA" "$TTV"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 21: applying the reference-UI alignment pass =="

python3 - <<'PYEOF'
import os
import sys

LAY = "app/src/main/res/layout/activity_video_editing.xml"
TBTN = "app/src/main/res/layout/item_transition_button.xml"
STR = "app/src/main/res/values/strings.xml"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
D = "app/src/main/res/drawable/"

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


def ensure_file(path, content, name):
    global edits_applied, edits_skipped
    if os.path.exists(path):
        with open(path) as f:
            if f.read() == content:
                edits_skipped += 1
                print("  [skip] " + name + ": already present")
                return
        print("  [FAIL] " + name + ": exists with unexpected content")
        sys.exit(1)
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w") as f:
        f.write(content)
    edits_applied += 1
    print("  [ OK ] " + name + " (created)")


# ---------------------------------------------------------------------------
# activity_video_editing.xml - the top bar rebuild + player row moves
# ---------------------------------------------------------------------------

# E1: btnClose icon capsule -> the reference dark Cancel pill.
#     The id stays btnClose so the existing click wiring (unsaved
#     changes flow) keeps working; the Kotlin cast is widened in K1.
OLD_E1 = '''            <ImageButton
                android:id="@+id/btnClose"
                android:layout_width="48dp"
                android:layout_height="36dp"
                android:background="@drawable/bg_back_capsule"
                android:src="@drawable/ic_back_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                android:contentDescription="Back"
                app:tint="@color/textColor" />'''

NEW_E1 = '''            <!-- phase 21: reference top bar - the icon-only back
                 capsule becomes a dark Cancel pill (same id btnClose
                 and same click wiring; the Kotlin cast was widened to
                 View so the LinearLayout binds cleanly) -->
            <LinearLayout
                android:id="@+id/btnClose"
                android:layout_width="wrap_content"
                android:layout_height="40dp"
                android:orientation="horizontal"
                android:gravity="center"
                android:paddingHorizontal="22dp"
                android:background="@drawable/bg_cancel_pill"
                android:elevation="2dp"
                android:contentDescription="Cancel">

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="@string/cancel"
                    android:textColor="@color/textColor"
                    android:textSize="15sp"
                    android:fontFamily="sans-serif-medium" />
            </LinearLayout>'''

apply_edit(LAY, OLD_E1, NEW_E1, "E1 btnClose -> Cancel pill")

# E2: undo/redo leave the top bar (they re-appear in the player row).
OLD_E2 = '''            <ImageButton
                android:id="@+id/btnUndo"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:src="@drawable/ic_undo_24"
                android:background="?attr/selectableItemBackgroundBorderless"
                android:padding="8dp"
                android:scaleType="fitCenter"
                android:contentDescription="Undo"
                android:layout_marginEnd="6dp"
                android:alpha="0.5"
                android:enabled="false"
                app:tint="@color/textColor" />

            <ImageButton
                android:id="@+id/btnRedo"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:src="@drawable/ic_redo_24"
                android:background="?attr/selectableItemBackgroundBorderless"
                android:padding="8dp"
                android:scaleType="fitCenter"
                android:contentDescription="Redo"
                android:layout_marginEnd="12dp"
                android:alpha="0.5"
                android:enabled="false"
                app:tint="@color/textColor" />'''

NEW_E2 = '''            <!-- phase 21: undo/redo relocated to the player control row
                 (right of the play button) so the top bar can mirror the
                 reference Cancel / RES / Save layout -->'''

apply_edit(LAY, OLD_E2, NEW_E2, "E2 remove undo/redo from top bar")

# E3: the inert RES label lands in the top bar center, with the second
#     weight spacer that keeps it dead-center between Cancel and Save.
OLD_E3 = '''            <ImageButton
                android:id="@+id/btnPreview"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:src="@drawable/ic_preview_24"
                android:background="?attr/selectableItemBackgroundBorderless"
                android:padding="8dp"
                android:scaleType="fitCenter"
                android:contentDescription="Preview Render"
                android:layout_marginEnd="12dp"
                android:visibility="gone"
                app:tint="@color/textColor" />'''

NEW_E3 = '''            <ImageButton
                android:id="@+id/btnPreview"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:src="@drawable/ic_preview_24"
                android:background="?attr/selectableItemBackgroundBorderless"
                android:padding="8dp"
                android:scaleType="fitCenter"
                android:contentDescription="Preview Render"
                android:layout_marginEnd="12dp"
                android:visibility="gone"
                app:tint="@color/textColor" />

            <!-- phase 21: placeholder resolution label for the top bar
                 center (a real resolution selector arrives in a later
                 phase; "RES" is inert text for now) -->
            <TextView
                android:id="@+id/tvResolutionBadge"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="RES"
                android:textColor="#B3FFFFFF"
                android:textSize="15sp"
                android:fontFamily="sans-serif-medium" />

            <View
                android:layout_width="0dp"
                android:layout_height="0dp"
                android:layout_weight="1" />'''

apply_edit(LAY, OLD_E3, NEW_E3, "E3 top bar center RES label + spacer")

# E4: the wide muted Export lozenge -> the reference amber Save pill
#     with bold black text. IDs stay so the export wiring is untouched.
OLD_E4 = '''            <LinearLayout
                android:id="@+id/layoutSaveSplit"
                android:layout_width="124dp"
                android:layout_height="36dp"
                android:orientation="horizontal"
                android:background="@drawable/bg_split_save_button"
                android:clipToOutline="true"
                android:elevation="2dp">

                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent"
                    android:gravity="center"
                    android:text="@string/export"
                    android:textColor="@color/onAmber"
                    android:fontFamily="sans-serif-medium"
                    android:textSize="13sp"
                    android:clickable="true"
                    android:focusable="true"
                    android:background="?attr/selectableItemBackground" />

            </LinearLayout>'''

NEW_E4 = '''            <!-- phase 21: reference Save pill - vivid amber capsule with
                 bold black text (was the wide muted Export lozenge) -->
            <LinearLayout
                android:id="@+id/layoutSaveSplit"
                android:layout_width="96dp"
                android:layout_height="40dp"
                android:orientation="horizontal"
                android:background="@drawable/bg_save_pill"
                android:clipToOutline="true"
                android:elevation="2dp">

                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent"
                    android:gravity="center"
                    android:text="@string/save"
                    android:textColor="@color/onAmber"
                    android:fontFamily="sans-serif"
                    android:textStyle="bold"
                    android:textSize="15sp"
                    android:clickable="true"
                    android:focusable="true"
                    android:background="?attr/selectableItemBackground" />

            </LinearLayout>'''

apply_edit(LAY, OLD_E4, NEW_E4, "E4 Export lozenge -> Save pill")

# E5: the magnet joins the left player-row cluster, beside the
#     timeline-expand arrow (the "up arrow" per the user's wording).
OLD_E5 = '''                    <ImageButton
                        android:id="@+id/btnExpandTimeline"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:background="?attr/selectableItemBackgroundBorderless"
                        android:src="@drawable/ic_expand_24"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        android:contentDescription="Expand Timeline"
                        app:tint="@color/colorOnSecondary" />'''

NEW_E5 = '''                    <ImageButton
                        android:id="@+id/btnExpandTimeline"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:background="?attr/selectableItemBackgroundBorderless"
                        android:src="@drawable/ic_expand_24"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        android:contentDescription="Expand Timeline"
                        app:tint="@color/colorOnSecondary" />

                    <!-- phase 21: the magnet moved from the right cluster
                         to the left, beside the timeline-expand arrow,
                         per the reference player control row -->
                    <ImageButton
                        android:id="@+id/btnMagnet"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:background="@android:color/transparent"
                        android:src="@drawable/ic_magnet_24"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        android:layout_marginStart="4dp"
                        app:tint="@color/colorOnSecondary" />'''

apply_edit(LAY, OLD_E5, NEW_E5, "E5 magnet into left player cluster")

# E6: undo/redo take the magnet's old place right of the play button.
OLD_E6 = '''                    <ImageButton
                        android:id="@+id/btnMagnet"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:background="@android:color/transparent"
                        android:src="@drawable/ic_magnet_24"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        app:tint="@color/colorOnSecondary" />

                    <ImageButton
                        android:id="@+id/btnMute"'''

NEW_E6 = '''                    <!-- phase 21: undo/redo relocated from the top bar to
                         sit right of the play button, per the reference
                         player control row -->
                    <ImageButton
                        android:id="@+id/btnUndo"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:src="@drawable/ic_undo_24"
                        android:background="?attr/selectableItemBackgroundBorderless"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        android:contentDescription="Undo"
                        android:alpha="0.5"
                        android:enabled="false"
                        android:layout_marginEnd="4dp"
                        app:tint="@color/textColor" />

                    <ImageButton
                        android:id="@+id/btnRedo"
                        android:layout_width="40dp"
                        android:layout_height="40dp"
                        android:src="@drawable/ic_redo_24"
                        android:background="?attr/selectableItemBackgroundBorderless"
                        android:padding="8dp"
                        android:scaleType="fitCenter"
                        android:contentDescription="Redo"
                        android:alpha="0.5"
                        android:enabled="false"
                        android:layout_marginEnd="12dp"
                        app:tint="@color/textColor" />

                    <ImageButton
                        android:id="@+id/btnMute"'''

apply_edit(LAY, OLD_E6, NEW_E6, "E6 undo/redo right of play button")

# E7: shrink the plus glyph inside the add-media tile.
OLD_E7 = '''                <!-- phase 20: the add-media tile mirrors the reference
                     design - a dark rounded square with a thin white
                     border and a white plus glyph (was an amber
                     circle with a black plus) -->
                <ImageButton
                    android:id="@+id/btnTimelineAdd"
                    android:layout_width="36dp"
                    android:layout_height="36dp"
                    android:background="@drawable/bg_add_media_tile"
                    android:src="@drawable/ic_add_24"
                    android:contentDescription="Add Media"
                    android:elevation="8dp"
                    android:padding="8dp"
                    app:tint="@color/textColor" />'''

NEW_E7 = '''                <!-- phase 20: the add-media tile mirrors the reference
                     design - a dark rounded square with a thin white
                     border and a white plus glyph (was an amber
                     circle with a black plus) -->
                <!-- phase 21: plus glyph shrunk - padding 8dp -> 10dp so
                     the glyph lands at ~37% of the tile (the reference
                     ratio) instead of dominating the rounded square -->
                <ImageButton
                    android:id="@+id/btnTimelineAdd"
                    android:layout_width="36dp"
                    android:layout_height="36dp"
                    android:background="@drawable/bg_add_media_tile"
                    android:src="@drawable/ic_add_24"
                    android:contentDescription="Add Media"
                    android:elevation="8dp"
                    android:padding="10dp"
                    app:tint="@color/textColor" />'''

apply_edit(LAY, OLD_E7, NEW_E7, "E7 smaller plus glyph in add tile")

# ---------------------------------------------------------------------------
# item_transition_button.xml - the reference transition chip
# ---------------------------------------------------------------------------

OLD_TB = '''<?xml version="1.0" encoding="utf-8"?>
<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="24dp"
    android:layout_height="match_parent"
    android:clipChildren="false">

    <ImageView
        android:id="@+id/btnTransition"
        android:layout_width="20dp"
        android:layout_height="20dp"
        android:layout_gravity="center"
        android:background="@drawable/bg_transition_icon"
        android:src="@drawable/ic_add_24"
        android:scaleType="centerInside"
        app:tint="@color/textColor"
        android:padding="4dp" />
</FrameLayout>'''

NEW_TB = '''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 21: the reference transition chip - a white rounded-square
     tile hosting a black glyph: a plain cut bar when no transition is
     set, a bowtie once one is applied (was a 20dp amber-ringed oval
     with a plus / white check mark) -->
<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="24dp"
    android:layout_height="match_parent"
    android:clipChildren="false">

    <ImageView
        android:id="@+id/btnTransition"
        android:layout_width="24dp"
        android:layout_height="24dp"
        android:layout_gravity="center"
        android:background="@drawable/bg_transition_tile"
        android:src="@drawable/ic_transition_cut_24"
        android:scaleType="centerInside"
        android:elevation="4dp"
        android:contentDescription="Transition" />
</FrameLayout>'''

apply_edit(TBTN, OLD_TB, NEW_TB, "TB transition chip tile rewrite")

# ---------------------------------------------------------------------------
# strings.xml - the Save label
# ---------------------------------------------------------------------------

apply_edit(
    STR,
    '    <string name="export">Export</string>',
    '    <string name="export">Export</string>\n'
    '    <string name="save">Save</string>',
    "ST add the Save string")

# ---------------------------------------------------------------------------
# VideoEditingActivity.kt
# ---------------------------------------------------------------------------

# K1: btnClose is now a LinearLayout - widen the generic cast so the
#     findViewById does not throw ClassCastException at runtime.
apply_edit(
    VEA,
    "        findViewById<ImageView>(R.id.btnClose)?.setBounceClickListener {",
    "        findViewById<View>(R.id.btnClose)?.setBounceClickListener {",
    "K1 widen btnClose cast to View")

# K2: transition chip glyph states - cut bar when empty, bowtie when set.
OLD_K2 = '''                if (transitionOp != null && transitionOp.type != "none") {
                    btnTransition.setImageResource(R.drawable.ic_check_24) // Or some infinite icon
                    btnTransition.setColorFilter(android.graphics.Color.WHITE)
                    transitionView.background = null
                } else {
                    btnTransition.setImageResource(R.drawable.ic_add_24)
                }'''

NEW_K2 = '''                // phase 21: reference transition chip states - a black
                // cut bar on the white tile when empty, a black bowtie
                // when a transition is applied; the white tile stays in
                // both states so the chip reads as one control
                if (transitionOp != null && transitionOp.type != "none") {
                    btnTransition.setImageResource(R.drawable.ic_transition_bowtie_24)
                    btnTransition.setColorFilter(null)
                } else {
                    btnTransition.setImageResource(R.drawable.ic_transition_cut_24)
                    btnTransition.setColorFilter(null)
                }'''

apply_edit(VEA, OLD_K2, NEW_K2, "K2 transition glyph states")

# ---------------------------------------------------------------------------
# TrackTrimView.kt - the reference rounded frame + edge handles
# ---------------------------------------------------------------------------

# T1: handle width scales with track height (the reference edge zones
#     are ~30% of the height, not a fixed 24px sliver).
apply_edit(
    TTV,
    "    private val handleWidth = 24f",
    "    // phase 21: handle grab width now scales with the track height\n"
    "    // (~30%, the reference frame's thick white edge zones) instead of\n"
    "    // a fixed 24px sliver; coerced to the old floor pre-layout\n"
    "    private val handleWidth: Float\n"
    "        get() = (height * 0.30f).coerceAtLeast(24f)",
    "T1 handleWidth scales with height")

# T2: main track selected + trim enabled - sharp 8f rect -> rounded frame.
OLD_T2 = '''                    // Draw a thick border enclosing the active range when selected
                    // (phase 20: white frame around the track per the reference
                    // design; the amber overlay below stays as the selection
                    // tint)
                    borderPaint.color = Color.parseColor("#FFFFFF")
                    borderPaint.strokeWidth = 8f
                    canvas.drawRect(rectF, borderPaint)'''

NEW_T2 = '''                    // phase 21: reference track frame - a white rounded
                    // rectangle stroke around the active range (phase
                    // 20's sharp corners never matched the sample);
                    // stroke and radius scale with the track height so
                    // the silhouette holds at every density
                    borderPaint.color = Color.parseColor("#FFFFFF")
                    borderPaint.strokeWidth = (height * 0.05f).coerceAtLeast(4f)
                    val frameInset = borderPaint.strokeWidth / 2f
                    val frameRadius = height * 0.22f
                    val frameRect = RectF(
                        rectF.left + frameInset, rectF.top + frameInset,
                        rectF.right - frameInset, rectF.bottom - frameInset
                    )
                    canvas.drawRoundRect(frameRect, frameRadius, frameRadius, borderPaint)'''

apply_edit(TTV, OLD_T2, NEW_T2, "T2 main track rounded frame (trim on)")

# T3a: main track selected + trim disabled - rounded frame.
OLD_T3A = '''                    // Main track selection highlight without trimmer handles/ghosts
                    // (phase 20: white frame per the reference design)
                    borderPaint.color = Color.parseColor("#FFFFFF") // White selection
                    borderPaint.strokeWidth = 10f
                    // Inset the rect so the stroke doesn't get clipped by the parent FrameLayout
                    val inset = borderPaint.strokeWidth / 2f
                    val selRect = RectF(rectF.left + inset, rectF.top + inset, rectF.right - inset, rectF.bottom - inset)
                    canvas.drawRect(selRect, borderPaint)'''

NEW_T3A = '''                    // Main track selection highlight without trimmer handles/ghosts
                    // (phase 21: rounded white frame + rounded amber tint)
                    borderPaint.color = Color.parseColor("#FFFFFF")
                    borderPaint.strokeWidth = (height * 0.05f).coerceAtLeast(4f)
                    // Inset the rect so the stroke doesn't get clipped by the parent FrameLayout
                    val inset = borderPaint.strokeWidth / 2f
                    val selRadius = height * 0.22f
                    val selRect = RectF(rectF.left + inset, rectF.top + inset, rectF.right - inset, rectF.bottom - inset)
                    canvas.drawRoundRect(selRect, selRadius, selRadius, borderPaint)'''

apply_edit(TTV, OLD_T3A, NEW_T3A, "T3a main track rounded frame (trim off)")

# T3b: the amber tint follows the rounded corners too.
apply_edit(
    TTV,
    "                    canvas.drawRect(selRect, overlay)",
    "                    canvas.drawRoundRect(selRect, selRadius, selRadius, overlay)",
    "T3b rounded amber selection tint")

# T4: the non-main track fill corners match the frame radius.
apply_edit(
    TTV,
    "            canvas.drawRoundRect(rectF, 12f, 12f, trackPaint)",
    "            canvas.drawRoundRect(rectF, height * 0.22f, height * 0.22f, trackPaint)",
    "T4 non-main fill corner radius")

# T5a: selected non-main tracks get the white rounded frame.
OLD_T5A = '''            if (isSelectedTrack) {
                borderPaint.color = Color.parseColor("#FFB200") // Vibrant pink selection accent
                borderPaint.strokeWidth = 6f
                canvas.drawRoundRect(rectF, 12f, 12f, borderPaint)'''

NEW_T5A = '''            if (isSelectedTrack) {
                // phase 21: white rounded frame on every selected track
                // (selection still reads via the amber tint below)
                val trackRadius = height * 0.22f
                borderPaint.color = Color.parseColor("#FFFFFF")
                borderPaint.strokeWidth = (height * 0.05f).coerceAtLeast(4f)
                val borderInset = borderPaint.strokeWidth / 2f
                val borderRect = RectF(
                    rectF.left + borderInset, rectF.top + borderInset,
                    rectF.right - borderInset, rectF.bottom - borderInset
                )
                canvas.drawRoundRect(borderRect, trackRadius, trackRadius, borderPaint)'''

apply_edit(TTV, OLD_T5A, NEW_T5A, "T5a selected secondary white rounded frame")

# T5b: the selection tint overlay follows the same rounded rect.
OLD_T5B = '''                // Draw a subtle 10% opacity pink overlay inside the track
                val selectionOverlayPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.parseColor("#1AFFB200")
                    style = Paint.Style.FILL
                }
                canvas.drawRoundRect(rectF, 12f, 12f, selectionOverlayPaint)'''

NEW_T5B = '''                // Draw a subtle 10% opacity amber overlay inside the track
                val selectionOverlayPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.parseColor("#1AFFB200")
                    style = Paint.Style.FILL
                }
                canvas.drawRoundRect(borderRect, trackRadius, trackRadius, selectionOverlayPaint)'''

apply_edit(TTV, OLD_T5B, NEW_T5B, "T5b rounded selection tint")

# T5c: unselected non-main tracks keep a soft white rounded outline.
OLD_T5C = '''            } else {
                borderPaint.color = Color.parseColor("#33FFFFFF") // Subtle 20% opacity white outline
                borderPaint.strokeWidth = 2f
                canvas.drawRoundRect(rectF, 12f, 12f, borderPaint)
            }
        }'''

NEW_T5C = '''            } else {
                // phase 21: unselected tracks keep a soft white rounded
                // outline, slightly more present than the old 20% hairline
                val trackRadius = height * 0.22f
                borderPaint.color = Color.parseColor("#59FFFFFF")
                borderPaint.strokeWidth = (height * 0.03f).coerceAtLeast(2f)
                val borderInset = borderPaint.strokeWidth / 2f
                val borderRect = RectF(
                    rectF.left + borderInset, rectF.top + borderInset,
                    rectF.right - borderInset, rectF.bottom - borderInset
                )
                canvas.drawRoundRect(borderRect, trackRadius, trackRadius, borderPaint)
            }
        }'''

apply_edit(TTV, OLD_T5C, NEW_T5C, "T5c unselected secondary rounded outline")

# T6: the trim handles become thick white edge zones with rounded
#     outer corners that fuse into the rounded frame; grips stay.
OLD_T6 = '''            val currentHandleWidth = handleWidth * currentHandleScale
            if (isMainVideoTrack) {
                handlePaint.color = Color.parseColor("#FFB200")
            } else {
                handlePaint.color = Color.WHITE
            }
            // Draw left handle
            canvas.drawRect(startX, 0f, startX + currentHandleWidth, height.toFloat(), handlePaint)
            // Draw right handle
            canvas.drawRect(endX - currentHandleWidth, 0f, endX, height.toFloat(), handlePaint)'''

NEW_T6 = '''            val currentHandleWidth = handleWidth * currentHandleScale
            // phase 21: reference trim handles - the frame's left and
            // right edges become thick white grab zones whose OUTER
            // corners carry the frame radius so they fuse seamlessly
            // into the rounded outline; amber is dropped so the whole
            // frame reads white like the sample (grip marks stay)
            handlePaint.color = Color.WHITE
            val handleRadius = height * 0.22f
            val handlePath = android.graphics.Path()
            // Left handle - round only the outer (left) corners
            handlePath.addRoundRect(
                RectF(startX, 0f, startX + currentHandleWidth, height.toFloat()),
                floatArrayOf(handleRadius, handleRadius, 0f, 0f, 0f, 0f, handleRadius, handleRadius),
                android.graphics.Path.Direction.CW
            )
            // Right handle - round only the outer (right) corners
            handlePath.addRoundRect(
                RectF(endX - currentHandleWidth, 0f, endX, height.toFloat()),
                floatArrayOf(0f, 0f, handleRadius, handleRadius, handleRadius, handleRadius, 0f, 0f),
                android.graphics.Path.Direction.CW
            )
            canvas.drawPath(handlePath, handlePaint)'''

apply_edit(TTV, OLD_T6, NEW_T6, "T6 white rounded edge handles")

# ---------------------------------------------------------------------------
# New drawable resources
# ---------------------------------------------------------------------------

D = "app/src/main/res/drawable/"

ensure_file(D + "bg_cancel_pill.xml",
'''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 21: reference top-bar Cancel pill - a charcoal capsule
     (#333333, 20dp radius on the 40dp pill) behind white text -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#333333" />
    <corners android:radius="20dp" />
</shape>
''', "drawable bg_cancel_pill.xml")

ensure_file(D + "bg_save_pill.xml",
'''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 21: reference top-bar Save pill - the vivid amber capsule
     (colorPrimary, 20dp radius on the 40dp pill) behind bold black
     text -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="@color/colorPrimary" />
    <corners android:radius="20dp" />
</shape>
''', "drawable bg_save_pill.xml")

ensure_file(D + "bg_transition_tile.xml",
'''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 21: the reference transition chip tile - a white rounded
     square (7dp radius, squircle-ish) that floats between the clips -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#FFFFFF" />
    <corners android:radius="7dp" />
</shape>
''', "drawable bg_transition_tile.xml")

ensure_file(D + "ic_transition_cut_24.xml",
'''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 21: empty-state transition glyph - a plain vertical cut
     bar (the reference app's "no transition / hard cut" mark),
     black on the white tile: 3dp wide, 12dp tall in the 24dp box -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#000000"
        android:pathData="M10.5,6L13.5,6L13.5,18L10.5,18Z" />
</vector>
''', "drawable ic_transition_cut_24.xml")

ensure_file(D + "ic_transition_bowtie_24.xml",
'''<?xml version="1.0" encoding="utf-8"?>
<!-- phase 21: applied-transition glyph - two triangles meeting at
     the center (the reference app's bowtie mark), black on the
     white tile: 11dp wide, 7dp tall in the 24dp box -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#000000"
        android:pathData="M6.5,8.5L12,12L6.5,15.5Z M17.5,8.5L12,12L17.5,15.5Z" />
</vector>
''', "drawable ic_transition_bowtie_24.xml")

print("edits applied: " + str(edits_applied) + ", skipped: " + str(edits_skipped))
PYEOF

echo "== phase 21: gates =="

python3 - <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

LAY = "app/src/main/res/layout/activity_video_editing.xml"
TBTN = "app/src/main/res/layout/item_transition_button.xml"
STR = "app/src/main/res/values/strings.xml"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
THEMES = "app/src/main/res/values/themes.xml"
PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
DIALOG = "app/src/main/res/layout/dialog_unsaved_changes.xml"
D = "app/src/main/res/drawable/"

NEW_DRAWABLES = [
    "bg_cancel_pill.xml",
    "bg_save_pill.xml",
    "bg_transition_tile.xml",
    "ic_transition_cut_24.xml",
    "ic_transition_bowtie_24.xml",
]

failed = 0
passed = 0


def gate(name, ok, detail=""):
    global failed, passed
    if ok:
        passed += 1
        print("  [PASS] " + name)
    else:
        failed += 1
        print("  [FAIL] " + name + ((" - " + detail) if detail else ""))


def rd(p):
    with open(p) as f:
        return f.read()


def cnt(s, sub):
    return s.count(sub)


# -- 1. XML well-formedness (edited + new + survival files) --------------
for p in [LAY, TBTN, STR, THEMES, DIALOG] + [D + n for n in NEW_DRAWABLES]:
    try:
        ET.parse(p)
        gate("well-formed XML: " + p, True)
    except Exception as e:
        gate("well-formed XML: " + p, False, str(e))

# -- 2. No NEW non-ascii bytes (some edited files already carry utf-8
#       at HEAD: a degree sign in strings.xml, box-drawing chars in the
#       Kotlin comments - the gate pins the non-ascii multiset to HEAD) --
import subprocess

for p in [LAY, TBTN, STR, VEA, TTV]:
    with open(p, "rb") as f:
        cur = f.read()
    r = subprocess.run(["git", "show", "HEAD:" + p], capture_output=True)
    if r.returncode != 0:
        gate("no NEW non-ascii: " + p, False, "git show failed")
        continue
    head = r.stdout
    gate("no NEW non-ascii: " + p,
         [x for x in cur if x >= 128] == [x for x in head if x >= 128])

for n in NEW_DRAWABLES:
    p = D + n
    with open(p, "rb") as f:
        b = f.read()
    gate("ASCII only (new file): " + p, all(x < 128 for x in b))

# -- 3. Top bar + player row structure ------------------------------------
L = rd(LAY)

for i in ["btnClose", "btnHome", "btnPreview", "tvResolutionBadge",
          "layoutSaveSplit", "btnSaveText", "btnUndo", "btnRedo",
          "btnMagnet", "btnMute", "btnExpandTimeline", "btnMoveLayerUp",
          "btnMoveLayerDown", "btnTimelineAdd", "btnPlayPause"]:
    gate("unique id @+id/" + i,
         cnt(L, 'android:id="@+id/' + i + '"') == 1)

gate("RES label present",
     cnt(L, 'android:text="RES"') == 1)

CANCEL_BLOCK = (
    '            <LinearLayout\n'
    '                android:id="@+id/btnClose"\n'
    '                android:layout_width="wrap_content"\n'
    '                android:layout_height="40dp"')
gate("btnClose is the Cancel pill",
     cnt(L, CANCEL_BLOCK) == 1 and cnt(L, '@string/cancel') == 1
     and cnt(L, '@drawable/bg_cancel_pill') == 1)

SAVE_BLOCK = (
    '                android:id="@+id/layoutSaveSplit"\n'
    '                android:layout_width="96dp"\n'
    '                android:layout_height="40dp"')
gate("Save pill wired",
     cnt(L, SAVE_BLOCK) == 1 and cnt(L, '@string/save') == 1
     and cnt(L, '@drawable/bg_save_pill') == 1
     and cnt(L, 'android:textStyle="bold"') >= 1)

gate("old back capsule gone from editing layout",
     cnt(L, 'bg_back_capsule') == 0 and cnt(L, 'ic_back_24') == 0)

gate("icons moved, not duplicated",
     cnt(L, '@drawable/ic_undo_24') == 1
     and cnt(L, '@drawable/ic_redo_24') == 1
     and cnt(L, '@drawable/ic_magnet_24') == 1)


def idx(s, sub):
    return s.find(sub)


gate("top bar order: Cancel < RES < Save",
     0 <= idx(L, '@+id/btnClose')
     < idx(L, '@+id/tvResolutionBadge')
     < idx(L, '@+id/layoutSaveSplit'))

gate("magnet sits left, beside the expand (up) arrow",
     0 <= idx(L, '@+id/btnExpandTimeline')
     < idx(L, '@+id/btnMagnet')
     < idx(L, '@+id/btnMoveLayerUp'))

gate("undo/redo right of play, before mute",
     0 <= idx(L, '@+id/btnPlayPause')
     < idx(L, '@+id/btnUndo')
     < idx(L, '@+id/btnRedo')
     < idx(L, '@+id/btnMute'))

PLUS_BLOCK = (
    '                    android:background="@drawable/bg_add_media_tile"\n'
    '                    android:src="@drawable/ic_add_24"\n'
    '                    android:contentDescription="Add Media"\n'
    '                    android:elevation="8dp"\n'
    '                    android:padding="10dp"')
gate("smaller plus glyph (10dp padding)", cnt(L, PLUS_BLOCK) == 1)

# -- 4. Transition chip ----------------------------------------------------
T = rd(TBTN)
gate("transition chip tile + default glyph",
     cnt(T, '@drawable/bg_transition_tile') == 1
     and cnt(T, '@drawable/ic_transition_cut_24') == 1)
gate("transition chip is a 24dp square tile",
     cnt(T, 'android:layout_width="24dp"') == 2
     and cnt(T, 'android:layout_height="24dp"') == 1)
gate("transition chip de-tinted and de-padded",
     cnt(T, 'app:tint') == 0 and cnt(T, 'bg_transition_icon') == 0
     and cnt(T, 'ic_add_24') == 0 and cnt(T, 'android:padding') == 0)
gate("transition chip floats above the clips",
     cnt(T, 'android:elevation="4dp"') == 1)

# -- 5. strings ------------------------------------------------------------
S = rd(STR)
gate("Save string added", cnt(S, '<string name="save">Save</string>') == 1)

# -- 6. VideoEditingActivity.kt -------------------------------------------
V = rd(VEA)
gate("btnClose cast widened to View",
     cnt(V, 'findViewById<View>(R.id.btnClose)') == 1
     and cnt(V, 'findViewById<ImageView>(R.id.btnClose)') == 0)
gate("transition glyph states wired",
     cnt(V, 'R.drawable.ic_transition_bowtie_24') == 1
     and cnt(V, 'R.drawable.ic_transition_cut_24') == 1)
gate("old transition glyphs gone",
     cnt(V, 'ic_check_24') == 0
     and cnt(V, 'btnTransition.setImageResource(R.drawable.ic_add_24)') == 0
     and cnt(V, 'transitionView.background = null') == 0)
gate("transition filter cleared in both states",
     cnt(V, 'btnTransition.setColorFilter(null)') == 2)

# -- 7. TrackTrimView.kt ---------------------------------------------------
W = rd(TTV)
gate("handleWidth scales with track height",
     cnt(W, 'private val handleWidth: Float') == 1
     and cnt(W, 'get() = (height * 0.30f).coerceAtLeast(24f)') == 1)
gate("every frame draws rounded (7 sites), none sharp",
     cnt(W, 'canvas.drawRoundRect') == 7 and cnt(W, 'canvas.drawRect') == 0)
gate("edge handles fused with the rounded frame",
     cnt(W, 'handlePath.addRoundRect') == 2
     and cnt(W, 'val handlePath = android.graphics.Path()') == 1)
gate("handles are white now (amber dropped)",
     cnt(W, 'handlePaint.color = Color.parseColor("#FFB200")') == 0
     and cnt(W, 'handlePaint.color = Color.WHITE') == 1)
gate("grip marks survive on the wider handles",
     cnt(W, '#4D000000') == 1 and cnt(W, 'canvas.drawLine') == 7)

# -- 8. kotlin-lite brace/paren balance on both Kotlin files --------------
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

# -- 9. New drawable contents ----------------------------------------------
DRAWABLE_MARKS = {
    "bg_cancel_pill.xml": ["#333333", 'android:radius="20dp"'],
    "bg_save_pill.xml": ["@color/colorPrimary", 'android:radius="20dp"'],
    "bg_transition_tile.xml": ["#FFFFFF", 'android:radius="7dp"'],
    "ic_transition_cut_24.xml":
        ["M10.5,6L13.5,6L13.5,18L10.5,18Z", 'android:fillColor="#000000"'],
    "ic_transition_bowtie_24.xml":
        ["M6.5,8.5L12,12L6.5,15.5Z M17.5,8.5L12,12L17.5,15.5Z",
         'android:fillColor="#000000"'],
}
for n, marks in DRAWABLE_MARKS.items():
    s = rd(D + n)
    gate("drawable content: " + n, all(m in s for m in marks))

# -- 10. Survival of earlier phases ---------------------------------------
P = rd(PLANNER)
gate("phase 19a scope fix intact",
     cnt(P, "val rightStartMs = right.trimStartMs") >= 1)
TH = rd(THEMES)
gate("phase 20 slider style intact",
     cnt(TH, "Widget.CutLoss.Slider") >= 2)
DG = rd(DIALOG)
gate("phase 20 Keep Editing light text intact",
     cnt(DG, 'android:textColor="@color/textColor"') >= 1)
gate("phase 20 add-media tile intact",
     cnt(L, "@drawable/bg_add_media_tile") == 1)

if failed:
    print("GATES FAILED: " + str(failed) + " of " + str(failed + passed))
    sys.exit(1)
print("ALL GATES GREEN (" + str(passed) + " checks)")
PYEOF

echo "== phase 21 done =="
