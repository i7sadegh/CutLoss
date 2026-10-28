#!/usr/bin/env bash
###############################################################################
# CutLoss phase 23 -- 5 user items (corner behaviour + glyph weights +
# top-bar text size + global mute honouring in the export plan)
#
# User requests (after phase 22):
#   1. Track corners: ROUNDED only while a clip is UNSELECTED; the
#      SELECTED clip (trim handles visible on the left/right edges)
#      must draw SHARP corners - phase 21/22 rounded everything.
#   2. The + glyph in the timeline add-media tile is still too big -
#      shrink it again (padding 10dp -> 12dp, ink ~28% of the tile).
#   3. The glyphs inside the between-clips transition button must NOT
#      read bold/thick: the cut bar slims 3dp -> 2dp and the bowtie
#      becomes a 1dp stroked outline instead of a filled shape.
#   4. The Save and Cancel labels in the top bar grow: 15sp -> 17sp.
#   5. Pressing the speaker (mute) button must produce a MUTE final
#      output: no "-map 0:a:0" anywhere in the join/concat stage. The
#      real planner already gated its concat; this phase extends the
#      gate to every per-segment command, the transition pieces, the
#      rotation remuxes, and the export dialog's command preview.
#
# Files: activity_video_editing.xml, ic_transition_cut_24.xml,
#        ic_transition_bowtie_24.xml, VideoEditingActivity.kt,
#        TrackTrimView.kt, SmartExportPlanner.kt,
#        ExportSettingsDialog.kt.
#
# Idempotent: re-running skips anything already applied.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

LAY="app/src/main/res/layout/activity_video_editing.xml"
TBTN="app/src/main/res/layout/item_transition_button.xml"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
TTV="app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
PLAN="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
DLG="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"

for f in "$LAY" "$TBTN" "$VEA" "$TTV" "$PLAN" "$DLG"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 23: applying the 5 user items =="

python3 - <<'PYEOF'
import os
import sys
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter

LAY = "app/src/main/res/layout/activity_video_editing.xml"
TBTN = "app/src/main/res/layout/item_transition_button.xml"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
TTV = "app/src/main/java/com/tharunbirla/librecuts/customviews/TrackTrimView.kt"
PLAN = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
DLG = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
D = "app/src/main/res/drawable/"

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


def apply_replace_all(path, old, new, expect, label):
    """Count-based idempotent multi-site replacement."""
    global edits_applied, edits_skipped
    src = rd(path)
    c_old = cnt(src, old)
    c_new = cnt(src, new)
    if c_old == 0 and c_new == expect:
        edits_skipped += 1
        print("  [skip]    " + label)
        return
    if c_old == expect and c_new == 0:
        wr(path, src.replace(old, new))
        edits_applied += 1
        print("  [applied] " + label)
        return
    FAILED.append(label + " (old " + str(c_old) + "/new " + str(c_new) + ")")
    print("  [FAIL]    " + label + " (old " + str(c_old) + "/new " + str(c_new) + ")")


def ensure_drawable(name, old_marks, content, label):
    """Rewrite a small drawable when it still carries the pre-phase-23
    marks; skip when the phase-23 bytes are already in place."""
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
# ITEM 1 - track corners: sharp while selected, rounded while not
# =========================================================================

# 1a. TrackTrimView: the main-track selected+trim frame goes sharp
apply_edit(
    TTV,
    """                    // phase 21: reference track frame - a white rounded
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
                    canvas.drawRoundRect(frameRect, frameRadius, frameRadius, borderPaint)""",
    """                    // phase 23: the selected clip draws SHARP corners - the
                    // trim frame and the handle blocks read as one clean
                    // rectangle; the rounded corners return the moment the
                    // selection drops (phase 21 drew this frame rounded,
                    // which the user only wanted on unselected clips)
                    borderPaint.color = Color.parseColor("#FFFFFF")
                    borderPaint.strokeWidth = (height * 0.05f).coerceAtLeast(4f)
                    val frameInset = borderPaint.strokeWidth / 2f
                    val frameRect = RectF(
                        rectF.left + frameInset, rectF.top + frameInset,
                        rectF.right - frameInset, rectF.bottom - frameInset
                    )
                    canvas.drawRect(frameRect, borderPaint)""",
    "TTV: selected main-track frame sharp (drawRect)")

# 1b. TrackTrimView: main-track handles become plain rectangles; the
# secondary tracks keep the phase-21 rounded handle look
apply_edit(
    TTV,
    """        if (isTrimEnabled) {
            val currentHandleWidth = handleWidth * currentHandleScale
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
            canvas.drawPath(handlePath, handlePaint)""",
    """        if (isTrimEnabled) {
            val currentHandleWidth = handleWidth * currentHandleScale
            handlePaint.color = Color.WHITE
            if (isMainVideoTrack) {
                // phase 23: main-track trim handles are plain sharp
                // rectangles - while the clip is selected the whole
                // silhouette (frame + handle blocks) reads as one clean
                // rectangle; the rounded corners live only on the
                // UNSELECTED clip's thumbnail outline (grip marks stay)
                canvas.drawRect(startX, 0f, startX + currentHandleWidth, height.toFloat(), handlePaint)
                canvas.drawRect(endX - currentHandleWidth, 0f, endX, height.toFloat(), handlePaint)
            } else {
                // phase 21 look kept for secondary tracks: handle blocks
                // with rounded OUTER corners fusing into their rounded
                // outlines (audio / text / image tracks)
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
                canvas.drawPath(handlePath, handlePaint)
            }""",
    "TTV: main-track handles sharp, secondary keep rounded")

# 1c. VideoEditingActivity: the thumbnail outline rounds only while the
# clip is UNSELECTED; the selected clip clips to a square
apply_edit(
    VEA,
    """            // phase 22: clip the clip's thumbnails to the rounded
            // silhouette of the white trim frame (the same 22%-of-height
            // radius TrackTrimView draws for the frame and the handle
            // outer corners); without it the square thumbnail corners
            // poke out under the rounded handle corners
            segmentView.clipToOutline = true
            segmentView.outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, view.height * 0.22f)
                }
            }
            segmentView.post { segmentView.invalidateOutline() }""",
    """            // phase 23: the rounded thumbnail silhouette shows only while
            // the clip is UNSELECTED (the user's "corners visible" state);
            // the selected clip goes square so the sharp trim frame and
            // the handle blocks read as one clean rectangle (phase 22
            // rounded this outline unconditionally)
            val segmentSelected = selectedVideoIndex == index
            segmentView.clipToOutline = true
            segmentView.outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    val outlineRadius = if (segmentSelected) 0f else view.height * 0.22f
                    outline.setRoundRect(0, 0, view.width, view.height, outlineRadius)
                }
            }
            segmentView.post { segmentView.invalidateOutline() }""",
    "VEA: segment outline conditional on selection")

# =========================================================================
# ITEM 2 - the + glyph shrinks again (padding 10dp -> 12dp)
# =========================================================================

apply_edit(
    LAY,
    """                <!-- phase 21: plus glyph shrunk - padding 8dp -> 10dp so
                     the glyph lands at ~37% of the tile (the reference
                     ratio) instead of dominating the rounded square -->
                <ImageButton
                    android:id="@+id/btnTimelineAdd"
                    android:layout_width="36dp"
                    android:layout_height="36dp"
                    android:background="@drawable/bg_add_media_tile"
                    android:src="@drawable/ic_add_thin_24"
                    android:contentDescription="Add Media"
                    android:elevation="8dp"
                    android:padding="10dp"
                    app:tint="@color/textColor" />""",
    """                <!-- phase 23: plus glyph shrunk again - padding 10dp ->
                     12dp so the glyph ink lands at ~28% of the 36dp tile
                     (the 10dp form still read big per the user) -->
                <ImageButton
                    android:id="@+id/btnTimelineAdd"
                    android:layout_width="36dp"
                    android:layout_height="36dp"
                    android:background="@drawable/bg_add_media_tile"
                    android:src="@drawable/ic_add_thin_24"
                    android:contentDescription="Add Media"
                    android:elevation="8dp"
                    android:padding="12dp"
                    app:tint="@color/textColor" />""",
    "LAY: btnTimelineAdd padding 10dp -> 12dp")

# =========================================================================
# ITEM 3 - transition glyphs stop reading bold
# =========================================================================

ensure_drawable(
    "ic_transition_cut_24.xml",
    ['M10.5,6L13.5,6L13.5,18L10.5,18Z', 'android:fillColor="#000000"'],
    """<?xml version="1.0" encoding="utf-8"?>
<!-- phase 23: empty-state transition glyph - the cut bar slimmed from
     3dp to 2dp so the mark reads thin instead of bold (user request;
     the 24dp box and the 12dp height stay unchanged) -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#000000"
        android:pathData="M11,6L13,6L13,18L11,18Z" />
</vector>
""",
    "drawable: cut bar slimmed to 2dp")

ensure_drawable(
    "ic_transition_bowtie_24.xml",
    ['M6.5,8.5L12,12L6.5,15.5Z M17.5,8.5L12,12L17.5,15.5Z',
     'android:fillColor="#000000"'],
    """<?xml version="1.0" encoding="utf-8"?>
<!-- phase 23: applied-transition glyph - the bowtie switched from a
     filled black shape to a 1dp-thin stroked outline so it stops
     reading bold (user request); the two triangles still meet at the
     center point, now drawn a touch taller (8dp) so the thin stroke
     keeps the same visual presence -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:strokeColor="#000000"
        android:strokeWidth="1"
        android:strokeLineJoin="round"
        android:pathData="M6.5,8L12,12L6.5,16Z M17.5,8L12,12L17.5,16Z" />
</vector>
""",
    "drawable: bowtie as 1dp outline")

# =========================================================================
# ITEM 4 - Save / Cancel labels grow (15sp -> 17sp)
# =========================================================================

apply_edit(
    LAY,
    """                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="@string/cancel"
                    android:textColor="@color/textColor"
                    android:textSize="15sp"
                    android:fontFamily="sans-serif-medium" />""",
    """                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="@string/cancel"
                    android:textColor="@color/textColor"
                    android:textSize="17sp"
                    android:fontFamily="sans-serif-medium" />""",
    "LAY: Cancel label 15sp -> 17sp")

apply_edit(
    LAY,
    """                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent"
                    android:gravity="center"
                    android:text="@string/save"
                    android:textColor="@color/onAmber"
                    android:fontFamily="sans-serif"
                    android:textStyle="bold"
                    android:textSize="15sp\"""",
    """                <TextView
                    android:id="@+id/btnSaveText"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent"
                    android:gravity="center"
                    android:text="@string/save"
                    android:textColor="@color/onAmber"
                    android:fontFamily="sans-serif"
                    android:textStyle="bold"
                    android:textSize="17sp\"""",
    "LAY: Save label 15sp -> 17sp")

# =========================================================================
# ITEM 5 - the speaker button's global mute reaches every command
# =========================================================================

# 5a. SmartAnalysis learns about the global mute so the export dialog's
# live preview can honour it too
apply_edit(
    PLAN,
    """    data class SmartAnalysis(
        val clips: List<SmartClipInfo>,
        val transitions: Map<Int, Long>,
        val hasAudio: Boolean,
        val displayHeight: Int,""",
    """    data class SmartAnalysis(
        val clips: List<SmartClipInfo>,
        val transitions: Map<Int, Long>,
        val hasAudio: Boolean,
        val muted: Boolean,
        val displayHeight: Int,""",
    "PLAN: SmartAnalysis.muted field")

apply_edit(
    PLAN,
    """        fun fail(reason: String): SmartAnalysis =
            SmartAnalysis(emptyList(), emptyMap(), false, 0, 0, 0, 0, "", "", "", reason)""",
    """        fun fail(reason: String): SmartAnalysis =
            SmartAnalysis(emptyList(), emptyMap(), false, false, 0, 0, 0, 0, "", "", "", reason)""",
    "PLAN: fail() positional args widened")

apply_edit(
    PLAN,
    """            transitions = clampedTransitions,
            hasAudio = audioRef != null,
            displayHeight = displayHeight,""",
    """            transitions = clampedTransitions,
            hasAudio = audioRef != null,
            muted = ops.any { it is EditOperation.MuteAudio },
            displayHeight = displayHeight,""",
    "PLAN: analysis populates muted")

# 5b. transition piece: no real audio, no silence track, no audio map,
# no audio encoder while the speaker button muted the project
apply_edit(
    PLAN,
    """            val realAudio = planHasAudio && right.params.hasAudio && !right.muted""",
    """            val realAudio = planHasAudio && !audioMuted && right.params.hasAudio && !right.muted""",
    "PLAN: transition piece realAudio honours the global mute")

apply_edit(
    PLAN,
    """            } else if (planHasAudio) {
                sb.append(" -f lavfi -t ")
                    .append(String.format(java.util.Locale.US, "%.6f", dSec))
                sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
            }
            sb.append(" -map 0:v:0")
            if (planHasAudio) sb.append(" -map 1:a:0")
            sb.append(" -vf \\\"").append(vf).append("\\\"")
            sb.append(" ").append(transVEnc)
            if (planHasAudio) sb.append(" ").append(pieceAEnc)""",
    """            } else if (planHasAudio && !audioMuted) {
                sb.append(" -f lavfi -t ")
                    .append(String.format(java.util.Locale.US, "%.6f", dSec))
                sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
            }
            sb.append(" -map 0:v:0")
            if (planHasAudio && !audioMuted) sb.append(" -map 1:a:0")
            sb.append(" -vf \\\"").append(vf).append("\\\"")
            sb.append(" ").append(transVEnc)
            if (planHasAudio && !audioMuted) sb.append(" ").append(pieceAEnc)""",
    "PLAN: transition piece audio maps gated")

# 5c. transition rotation remux: a video-only tmp must not map 0:a:0
# (ffmpeg fails on a missing stream - this would have broken every
# rotated muted export)
apply_edit(
    PLAN,
    """                rot.append(" -map 0:v:0")
                if (planHasAudio) rot.append(" -map 0:a:0")
                rot.append(" -c copy \\\"").append(seg.absolutePath).append("\\\"")""",
    """                rot.append(" -map 0:v:0")
                if (planHasAudio && !audioMuted) rot.append(" -map 0:a:0")
                rot.append(" -c copy \\\"").append(seg.absolutePath).append("\\\"")""",
    "PLAN: transition rotation remux gated")

# 5d. per-clip segments: silence generation and audio mapping both stop
# while muted (video-only segments; the concat already mapped video only)
apply_edit(
    PLAN,
    """            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)""",
    """            val silenceAudio = planHasAudio && !audioMuted && (!clip.params.hasAudio || clip.muted)""",
    "PLAN: silenceAudio honours the global mute")

apply_edit(
    PLAN,
    """                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0")
                }
                if (scaleFilter != null) {""",
    """                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                } else if (planHasAudio && !audioMuted) {
                    sb.append(" -map 0:a:0")
                }
                if (scaleFilter != null) {""",
    "PLAN: per-segment encode audio map gated")

apply_edit(
    PLAN,
    """                sb.append(" ").append(vEncSimple)
                if (silenceAudio) {
                    sb.append(" ").append(aEncSilence)
                } else if (planHasAudio) {
                    sb.append(" ").append(aEncSimple)
                }
                if (preserveMetadata) sb.append(" -map_metadata 0")""",
    """                sb.append(" ").append(vEncSimple)
                if (silenceAudio) {
                    sb.append(" ").append(aEncSilence)
                } else if (planHasAudio && !audioMuted) {
                    sb.append(" ").append(aEncSimple)
                }
                if (preserveMetadata) sb.append(" -map_metadata 0")""",
    "PLAN: per-segment encode audio flags gated")

apply_edit(
    PLAN,
    """                } else if (planHasAudio) {
                    sb.append(" -map 0:v:0 -map 0:a:0 -c copy")
                } else {
                    sb.append(" -map 0:v:0 -c copy")
                }""",
    """                } else if (planHasAudio && !audioMuted) {
                    sb.append(" -map 0:v:0 -map 0:a:0 -c copy")
                } else {
                    sb.append(" -map 0:v:0 -c copy")
                }""",
    "PLAN: full-range stream copy gated")

apply_edit(
    PLAN,
    """                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0 -c copy -avoid_negative_ts make_zero")
                } else {""",
    """                } else if (planHasAudio && !audioMuted) {
                    sb.append(" -map 0:a:0 -c copy -avoid_negative_ts make_zero")
                } else {""",
    "PLAN: keyframe cut gated")

apply_edit(
    PLAN,
    """                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0")
                }
                sb.append(" -vf \\\"").append(fpsFilter)""",
    """                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                } else if (planHasAudio && !audioMuted) {
                    sb.append(" -map 0:a:0")
                }
                sb.append(" -vf \\\"").append(fpsFilter)""",
    "PLAN: span re-encode audio map gated")

apply_edit(
    PLAN,
    """                sb.append(enc)
                if (silenceAudio || planHasAudio) sb.append(" ").append(aEnc)""",
    """                sb.append(enc)
                if (silenceAudio || (planHasAudio && !audioMuted)) sb.append(" ").append(aEnc)""",
    "PLAN: span re-encode audio flags gated")

# 5e. ExportSettingsDialog: the command preview shows exactly what the
# planner will run - no -map 0:a:0, no audio flags, plus a mute note
apply_replace_all(
    DLG,
    'if (a.hasAudio) sb.append(" -map 0:a:0")',
    'if (a.hasAudio && !a.muted) sb.append(" -map 0:a:0")',
    6,
    "DLG: all 6 preview -map 0:a:0 sites gated on mute")

apply_replace_all(
    DLG,
    'if (a.hasAudio) sb.append(" ").append(aFlags)',
    'if (a.hasAudio && !a.muted) sb.append(" ").append(aFlags)',
    2,
    "DLG: both preview audio-flag sites gated on mute")

apply_edit(
    DLG,
    """            if (a.transitions.isNotEmpty()) {
                sb.append("\\ntransitions apply only to the merged single-file export")
            }
            return sb.toString()""",
    """            if (a.transitions.isNotEmpty()) {
                sb.append("\\ntransitions apply only to the merged single-file export")
            }
            // phase 23: mute note - every separate output drops its audio
            if (a.muted) sb.append("\\n(muted: original audio muted - no audio track in the output)")
            return sb.toString()""",
    "DLG: separate-files summary mute note")

apply_edit(
    DLG,
    """        sb.append("; final assembly is a lossless concat)")
        return sb.toString()""",
    """        sb.append("; final assembly is a lossless concat)")
        // phase 23: the speaker button's global mute drops the audio
        // track from every displayed command too (the real planner
        // already maps video only when MuteAudio is present)
        if (a.muted) sb.append("\\n(muted: original audio muted - no audio track in the output)")
        return sb.toString()""",
    "DLG: copy-summary mute note")

apply_edit(
    DLG,
    """        sb.append(")")
        return sb.toString()
    }

    /** Size estimate that follows the smart plan (copied vs re-encoded parts). */""",
    """        sb.append(")")
        // phase 23: mute note - the commands above carry no audio maps
        if (a.muted) sb.append("\\n(muted: original audio muted - no audio track in the output)")
        return sb.toString()
    }

    /** Size estimate that follows the smart plan (copied vs re-encoded parts). */""",
    "DLG: encode-summary mute note")

print("")
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


# -- item 1: corners -------------------------------------------------------
W = rd(TTV)
gate("TTV: selected main frame is sharp",
     cnt(W, "canvas.drawRect(frameRect, borderPaint)") == 1)
gate("TTV: main handles are sharp rectangles",
     cnt(W, "canvas.drawRect(startX, 0f, startX + currentHandleWidth, height.toFloat(), handlePaint)") == 1
     and cnt(W, "canvas.drawRect(endX - currentHandleWidth, 0f, endX, height.toFloat(), handlePaint)") == 1)
gate("TTV: sharp handles only on the main track",
     cnt(W, "handlePaint.color = Color.WHITE\n            if (isMainVideoTrack) {") == 1)
gate("TTV: secondary handles keep the rounded phase-21 look",
     cnt(W, "handlePath.addRoundRect") == 2
     and cnt(W, "canvas.drawPath(handlePath, handlePaint)") == 1)
gate("TTV: 6 rounded sites left (was 7), 3 sharp sites (was 0)",
     cnt(W, "canvas.drawRoundRect") == 6 and cnt(W, "canvas.drawRect") == 3)
gate("TTV: grip marks survive",
     cnt(W, "#4D000000") == 1 and cnt(W, "canvas.drawLine") == 7)
gate("TTV: handleWidth still scales with track height",
     cnt(W, "get() = (height * 0.30f).coerceAtLeast(24f)") == 1)

V = rd(VEA)
gate("VEA: segment outline radius conditional on selection",
     cnt(V, "val segmentSelected = selectedVideoIndex == index") == 1
     and cnt(V, "val outlineRadius = if (segmentSelected) 0f else view.height * 0.22f") == 1)
gate("VEA: unconditional rounded outline gone",
     cnt(V, "outline.setRoundRect(0, 0, view.width, view.height, view.height * 0.22f)") == 0)

# -- item 2: plus glyph ----------------------------------------------------
L = rd(LAY)
gate("LAY: add tile padding is 12dp (glyph ~28% of the tile)",
     cnt(L, 'android:padding="12dp"') == 1)
gate("LAY: thin plus still wired (phase 22 survival)",
     cnt(L, "@drawable/ic_add_thin_24") == 1
     and cnt(L, "@drawable/bg_add_media_tile") == 1)

# -- item 3: transition glyphs ---------------------------------------------
gate("drawable: cut bar is the 2dp form",
     cntf(D + "ic_transition_cut_24.xml", "M11,6L13,6L13,18L11,18Z") == 1
     and cntf(D + "ic_transition_cut_24.xml", "M10.5,6") == 0)
gate("drawable: bowtie is the stroked outline form",
     cntf(D + "ic_transition_bowtie_24.xml", 'android:strokeColor="#000000"') == 1
     and cntf(D + "ic_transition_bowtie_24.xml", 'android:strokeWidth="1"') == 1
     and cntf(D + "ic_transition_bowtie_24.xml", "M6.5,8L12,12L6.5,16Z M17.5,8L12,12L17.5,16Z") == 1
     and cntf(D + "ic_transition_bowtie_24.xml", 'android:fillColor="#000000"') == 0)
gate("transition chip still hosts the glyphs (phase 21 survival)",
     cntf(TBTN, "@drawable/ic_transition_cut_24") == 1
     and cntf(TBTN, "@drawable/bg_transition_tile") == 1)

# -- item 4: Save / Cancel text size ---------------------------------------
gate("LAY: Cancel label is 17sp",
     cnt(L, 'android:text="@string/cancel"\n                    android:textColor="@color/textColor"\n                    android:textSize="17sp"') == 1)
gate("LAY: Save label is 17sp",
     cnt(L, 'android:textStyle="bold"\n                    android:textSize="17sp"') == 1)
gate("LAY: exactly two 17sp labels (Cancel + Save)",
     cnt(L, 'android:textSize="17sp"') == 2)

# -- item 5: global mute ----------------------------------------------------
P = rd(PLAN)
gate("PLAN: SmartAnalysis carries the muted flag",
     cnt(P, "val hasAudio: Boolean,\n        val muted: Boolean,\n        val displayHeight: Int,") == 1
     and cnt(P, "muted = ops.any { it is EditOperation.MuteAudio },") == 1
     and cnt(P, 'SmartAnalysis(emptyList(), emptyMap(), false, false, 0, 0, 0, 0, "", "", "", reason)') == 1)
gate("PLAN: transition piece audio fully gated",
     cnt(P, "val realAudio = planHasAudio && !audioMuted && right.params.hasAudio && !right.muted") == 1
     and cnt(P, 'if (planHasAudio && !audioMuted) sb.append(" -map 1:a:0")') == 1)
gate("PLAN: rotation remux gated (rotated muted export would fail otherwise)",
     cnt(P, 'if (planHasAudio && !audioMuted) rot.append(" -map 0:a:0")') == 1)
gate("PLAN: silence generation gated",
     cnt(P, "val silenceAudio = planHasAudio && !audioMuted && (!clip.params.hasAudio || clip.muted)") == 1)
gate("PLAN: no ungated planHasAudio branch remains",
     cnt(P, "} else if (planHasAudio) {") == 0)
gate("PLAN: 17 gated audio sites (5 pre-existing + 12 new)",
     cnt(P, "!audioMuted") == 17,
     "found " + str(cnt(P, "!audioMuted")))
gate("PLAN: concat + finalize still gated (pre-existing)",
     cnt(P, 'val audioMap = if (planHasAudio && !audioMuted) " -map 0:a:0" else ""') == 1
     and cnt(P, "if (planHasAudio && !audioMuted) sb.append(\" -map 0:a:0\")") >= 2)

G = rd(DLG)
gate("DLG: all 6 preview audio maps gated, none ungated",
     cnt(G, 'if (a.hasAudio && !a.muted) sb.append(" -map 0:a:0")') == 6
     and cnt(G, 'if (a.hasAudio) sb.append(" -map 0:a:0")') == 0)
gate("DLG: both preview audio-flag sites gated",
     cnt(G, 'if (a.hasAudio && !a.muted) sb.append(" ").append(aFlags)') == 2
     and cnt(G, 'if (a.hasAudio) sb.append(" ").append(aFlags)') == 0)
gate("DLG: the mute note appears in all three summaries",
     cnt(G, "(muted: original audio muted - no audio track in the output)") == 3)

# -- survival of earlier phases --------------------------------------------
gate("phase 19a scope fix intact",
     cnt(P, "val rightStartMs = right.trimStartMs") >= 1)
gate("phase 22 ceil() frame tiling intact",
     cnt(V, "kotlin.math.ceil(frameSpanMs * pixelsPerMs / 15f)") == 1)
gate("phase 21 btnClose cast intact",
     cnt(V, "findViewById<View>(R.id.btnClose)") == 1)
gate("phase 21 transition glyph wiring intact",
     cnt(V, "R.drawable.ic_transition_bowtie_24") == 1
     and cnt(V, "R.drawable.ic_transition_cut_24") == 1)
gate("phase 21 top bar order intact (Cancel < RES < Save)",
     L.find("@+id/btnClose") < L.find("@+id/tvResolutionBadge") < L.find("@+id/layoutSaveSplit"))
gate("phase 21 player row order intact (play < undo < redo < mute)",
     L.find("@+id/btnPlayPause") < L.find("@+id/btnUndo") < L.find("@+id/btnRedo") < L.find("@+id/btnMute"))
gate("phase 22 tile radii intact",
     cntf(D + "bg_add_media_tile.xml", 'android:radius="4dp"') == 1
     and cntf(D + "bg_transition_tile.xml", 'android:radius="3dp"') == 1)
gate("phase 20 slider style intact",
     cntf("app/src/main/res/values/themes.xml", "Widget.CutLoss.Slider") >= 2)
gate("phase 20 Keep Editing light text intact",
     cntf("app/src/main/res/layout/dialog_unsaved_changes.xml",
          'android:textColor="@color/textColor"') >= 1)

# -- XML well-formedness ----------------------------------------------------
for p in [LAY, TBTN, D + "ic_transition_cut_24.xml", D + "ic_transition_bowtie_24.xml"]:
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


for p in [VEA, TTV, PLAN, DLG]:
    errs = scan(rd(p))
    gate("kotlin-lite brace/paren balance: " + p, not errs, "; ".join(errs[:3]))

# -- no NEW non-ascii vs HEAD (multiset compare per touched file) -----------
TOUCHED = [LAY, VEA, TTV, PLAN, DLG,
           D + "ic_transition_cut_24.xml", D + "ic_transition_bowtie_24.xml"]


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

echo "== phase 23 done =="
