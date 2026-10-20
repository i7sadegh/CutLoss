#!/usr/bin/env bash
# ==========================================================================
#  CutStudio change pipeline -- scripts/apply-changes.sh
#  ROUND 5 + ROUND 6 + ROUND 7 + ROUND 8 -- text tool WYSIWYG,
#  stroke/shadow tabs, Duplicate restored, capsule back button and
#  the ORIGINAL Electric Pink theme (amber recolor reverted)
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  Round 5 contents:
#   1. AddText data model: bold / italic / underline / strikethrough /
#      background color / background transparency / corner radius / margin.
#   2. NEW utils/TextRenderUtils.kt: ONE shared Canvas rendering path used
#      by the on-screen preview AND by export. AddText ops are rasterized
#      to transparent PNGs and composited with the FFmpeg "overlay" filter
#      (same machinery as image stickers), which unlocks everything
#      drawtext cannot do: underline, strikethrough, letter spacing and
#      rounded-corner backgrounds -- plus pixel-perfect WYSIWYG output and
#      full RTL/Persian shaping. Classic drawtext stays as a fallback.
#   3. Color tab: Draw-page style palette (custom color circle first +
#      preset swatches + HSV custom color picker dialog).
#   4. Format tab: new "Style" row with Bold / Italic / Underline /
#      Strikethrough toggle buttons.
#   5. NEW "Background" tab (after Format): color row (None/custom/presets)
#      + Transparency / Corner Radius / Margin sliders, styled like Format.
#
#
#  Round 6 contents:
#   1. Editor play button: circular background -> capsule pill (72x40dp);
#      the tap bounce effect is kept (it lives in the click listener).
#   2. (superseded by round 7) the round-6 removal of the text Duplicate
#      button is reverted -- Duplicate stays in the text tool.
#   3. Format tab: the old "Shadow" slider is gone.
#   4. NEW "Stroke" tab (right of Format): color row + Transparency +
#      Width sliders; stroke transparency is a new model field.
#   5. NEW "Shadow" tab (left of Background): color row (None = off) +
#      Transparency / Blur / Angle / Width sliders -- a real drop shadow
#      rendered by the same Canvas code in preview AND export.
#      Tab order: Keyboard | Color | Format | Stroke | Shadow | Background.
#
#  Round 7 contents:
#   1. Text tool: Duplicate button restored to its original spot (right
#      before Keyframes) with its original behaviour -- copying the
#      selected text overlay. If an older round-6 script already removed
#      it, this round re-adds it automatically.
#   2. (superseded by round 8) the round-7 amber recolor is reverted:
#      the app keeps its ORIGINAL Electric Pink / red theme.
#   3. Editor top bar: the back arrow gets a dark capsule background
#      (48x36dp, tap ripple kept) -- same 36dp height and mirrored edge
#      position as the Export capsule on the other side.
#   4. (superseded by round 8) play/pause icon tint follows the theme.
#
#  Round 8 contents:
#   1. Theme colors are back to the ORIGINAL Electric Pink / red palette.
#      The round-7 amber #F9B10B recolor is fully reverted (colors.xml,
#      nav pill, save/app/banner icons, spinner, record button, timeline
#      selection + handles, seeker, mask handles, text track color).
#      Forks that never went amber simply skip this step. The capsule
#      back button and the restored text Duplicate button stay as they
#      are -- only the colors are reverted.
#
#  Idempotent: every patch checks its own marker and skips if applied.
#  Requires: the v3 export panel state (works with or without round 4).
#  Round 5 steps run first (skipped when already applied), then round 6,
#  then round 7, then round 8.
# ==========================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PKG="app/src/main/java/com/tharunbirla/librecuts"
EOP="$PKG/models/EditOperation.kt"
TOV="$PKG/customviews/TextOverlayView.kt"
DRG="$PKG/customviews/DraggableTextOverlayView.kt"
VM="$PKG/viewmodels/VideoEditingViewModel.kt"
VME="$PKG/viewmodels/VideoEditingViewModelExt.kt"
ACT="$PKG/VideoEditingActivity.kt"
TOOLBAR="app/src/main/res/layout/text_editing_toolbar.xml"
FMT="app/src/main/res/layout/text_format_settings.xml"

# ---------------------------------------------------------------------------
#  PRE-CHECK
# ---------------------------------------------------------------------------
precheck() {
  echo "== pre-check"
  if [ ! -f "$FMT" ]; then
    echo "ABORT: text_format_settings.xml not found."
    return 1
  fi
  echo "   [ok] text tool layouts present"
}

# ---------------------------------------------------------------------------
#  STEP 1 -- EditOperation.AddText: new style + background fields
# ---------------------------------------------------------------------------
step1_model() {
  echo "== step 1: AddText data model fields"
  python3 - "$EOP" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
MARK = 'val bgCornerRadius: Int = 0,'
if MARK in s:
    print('   [skip] AddText fields already present')
    sys.exit(0)
ANCHOR = '        val letterSpacing: Float = 0f,\n        val lineSpacing: Float = 0f,\n'
if s.count(ANCHOR) != 1:
    print('   [FAIL] AddText anchor mismatch (%d found)' % s.count(ANCHOR))
    sys.exit(1)
NEW = ANCHOR + (
    '        val bold: Boolean = false,\n'
    '        val italic: Boolean = false,\n'
    '        val underline: Boolean = false,\n'
    '        val strikethrough: Boolean = false,\n'
    '        val bgColor: String? = null,\n'
    '        val bgOpacity: Float = 1.0f,\n'
    '        val bgCornerRadius: Int = 0,\n'
    '        val bgMargin: Int = 0,\n')
s = s.replace(ANCHOR, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   AddText: 8 new fields added (backward-compatible defaults)')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STEP 2 -- NEW files: TextRenderUtils.kt, text_background_settings.xml,
#            ic_text_bg_24.xml
# ---------------------------------------------------------------------------
step2_new_files() {
  echo "== step 2: new files (TextRenderUtils + background settings layout + icon)"

  if [ -f "$PKG/utils/TextRenderUtils.kt" ]; then
    echo "   [skip] TextRenderUtils.kt exists"
  else
    mkdir -p "$PKG/utils"
    cat > "$PKG/utils/TextRenderUtils.kt" <<'KTEOF'
package com.tharunbirla.librecuts.utils

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import com.tharunbirla.librecuts.models.EditOperation
import java.io.File
import java.io.FileOutputStream

/**
 * Shared Canvas-based rendering for AddText operations.
 *
 * The SAME code path renders:
 *  - the on-screen preview (TextOverlayView)
 *  - the exported video (rasterized to a transparent PNG and composited
 *    with the FFmpeg overlay filter)
 *
 * This guarantees a pixel-perfect WYSIWYG match between what the user sees
 * and what FFmpeg writes, and unlocks features drawtext cannot do:
 * underline, strikethrough, letter spacing and rounded-corner backgrounds.
 */
object TextRenderUtils {

    /** Resolve the effective typeface (font file + synthesized bold/italic). */
    fun resolveTypeface(op: EditOperation.AddText): Typeface {
        val base = try {
            if (op.fontPath.isNullOrBlank()) null else Typeface.createFromFile(op.fontPath)
        } catch (e: Exception) {
            null
        }
        val family = base ?: Typeface.DEFAULT
        val style = when {
            op.bold && op.italic -> Typeface.BOLD_ITALIC
            op.bold -> Typeface.BOLD
            op.italic -> Typeface.ITALIC
            else -> Typeface.NORMAL
        }
        return if (style == Typeface.NORMAL) family else Typeface.create(family, style)
    }

    /** Configure a paint for this op (typeface, flags, spacing, color+alpha). */
    fun configPaint(paint: Paint, op: EditOperation.AddText, alphaInt: Int = 255) {
        paint.typeface = resolveTypeface(op)
        paint.isUnderlineText = op.underline
        paint.isStrikeThruText = op.strikethrough
        paint.letterSpacing = op.letterSpacing
        paint.style = Paint.Style.FILL
        val baseColor = try { Color.parseColor(op.color) } catch (e: Exception) { Color.WHITE }
        paint.color = Color.argb(
            alphaInt.coerceIn(0, 255),
            Color.red(baseColor), Color.green(baseColor), Color.blue(baseColor))
    }

    /**
     * Draw the text block (optional rounded background, optional outline,
     * per-line alignment) starting at (startX, startY) where startY is the
     * BASELINE of the first line. Matches the preview rendering exactly.
     *
     * @param scale video-pixel to canvas-pixel scale (1.0 for PNG rendering)
     */
    fun drawBlock(
        canvas: Canvas,
        paint: Paint,
        op: EditOperation.AddText,
        lines: List<String>,
        maxTextWidth: Float,
        startX: Float,
        startY: Float,
        textHeight: Float,
        scale: Float
    ) {
        // 1. Rounded background box behind the whole block
        if (op.bgColor != null) {
            val marginPx = op.bgMargin * scale
            val radiusPx = op.bgCornerRadius * scale
            val bgBase = try { Color.parseColor(op.bgColor) } catch (e: Exception) { Color.BLACK }
            val fill = paint.color
            val bgAlpha = (op.bgOpacity.coerceIn(0f, 1f) * Color.alpha(fill)).toInt().coerceIn(0, 255)
            val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.argb(bgAlpha, Color.red(bgBase), Color.green(bgBase), Color.blue(bgBase))
            }
            val top = startY + paint.ascent() - marginPx
            val bottom = startY + (lines.size - 1) * textHeight + paint.descent() + marginPx
            canvas.drawRoundRect(
                startX - marginPx, top, startX + maxTextWidth + marginPx, bottom,
                radiusPx, radiusPx, bgPaint)
        }

        // 2. Text lines (optional stroke outline first, then fill)
        for ((index, line) in lines.withIndex()) {
            val lineW = paint.measureText(line)
            val lineX = when (op.textAlign) {
                "left", "L" -> startX
                "right", "R" -> startX + maxTextWidth - lineW
                else -> startX + (maxTextWidth - lineW) / 2f
            }
            val lineY = startY + (index * textHeight)

            if (op.borderThickness > 0) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = op.borderThickness * scale
                paint.strokeJoin = Paint.Join.ROUND
                val borderColorInt = try { Color.parseColor(op.borderColor) } catch (e: Exception) { Color.BLACK }
                val fill = paint.color
                paint.color = Color.argb(
                    Color.alpha(fill),
                    Color.red(borderColorInt), Color.green(borderColorInt), Color.blue(borderColorInt))
                canvas.drawText(line, lineX, lineY, paint)
                paint.style = Paint.Style.FILL
                paint.color = fill
            } else {
                paint.style = Paint.Style.FILL
            }

            canvas.drawText(line, lineX, lineY, paint)
        }
    }

    /**
     * Rasterize a text operation to a transparent PNG at source-video pixel
     * scale (fontSize px = source video px). Returns the file or null.
     * The file is overwritten per operation id, so repeated builds do not
     * accumulate cache files.
     */
    fun renderAddTextToPng(context: Context, op: EditOperation.AddText): File? {
        return try {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.textSize = op.fontSize.toFloat().coerceIn(4f, 2000f)
            configPaint(paint, op, 255)

            val lines = op.text.split("\n")
            val textHeight = (paint.descent() - paint.ascent()) + op.lineSpacing
            var maxTextWidth = 0f
            for (line in lines) {
                val w = paint.measureText(line)
                if (w > maxTextWidth) maxTextWidth = w
            }
            if (maxTextWidth <= 0f || lines.isEmpty()) return null

            val pad = (op.bgMargin + op.borderThickness + 8).coerceAtLeast(8)
            val width = (maxTextWidth + 2 * pad).toInt().coerceAtLeast(8)
            val height = (lines.size * textHeight + 2 * pad).toInt().coerceAtLeast(8)
            if (width > 8192 || height > 8192) return null

            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val startX = pad.toFloat()
            val startY = pad.toFloat() - paint.ascent()
            drawBlock(canvas, paint, op, lines, maxTextWidth, startX, startY, textHeight, 1.0f)

            val file = File(context.cacheDir, "text_ov_" + op.id + ".png")
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
            bitmap.recycle()
            file
        } catch (e: Exception) {
            null
        }
    }
}
KTEOF
    echo "   [ok]   TextRenderUtils.kt created"
  fi

  if [ -f "app/src/main/res/layout/text_background_settings.xml" ]; then
    echo "   [skip] text_background_settings.xml exists"
  else
    cat > "app/src/main/res/layout/text_background_settings.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:orientation="vertical"
    android:padding="16dp"
    android:background="@drawable/bg_bottom_nav_floating"
    android:elevation="12dp"
    android:layout_marginHorizontal="16dp"
    android:layout_marginBottom="8dp">

    <!-- Background Color -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Color"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <HorizontalScrollView
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:scrollbars="none"
            android:requiresFadingEdge="horizontal"
            android:fadingEdgeLength="16dp">
            <LinearLayout
                android:id="@+id/bgColorPickerList"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:orientation="horizontal"
                android:gravity="center_vertical" />
        </HorizontalScrollView>
    </LinearLayout>

    <!-- Transparency -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Transparency"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekBgOpacity"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="100"
            android:stepSize="1"
            android:value="100" />
    </LinearLayout>

    <!-- Corner Radius -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Corner Radius"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekBgCornerRadius"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="50"
            android:stepSize="1"
            android:value="0" />
    </LinearLayout>

    <!-- Margin -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Margin"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekBgMargin"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="50"
            android:stepSize="1"
            android:value="0" />
    </LinearLayout>

</LinearLayout>
XMLEOF
    echo "   [ok]   text_background_settings.xml created"
  fi

  if [ -f "app/src/main/res/drawable/ic_text_bg_24.xml" ]; then
    echo "   [skip] ic_text_bg_24.xml exists"
  else
    cat > "app/src/main/res/drawable/ic_text_bg_24.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FF000000"
        android:fillType="evenOdd"
        android:pathData="M5,3h14c1.1,0 2,0.9 2,2v14c0,1.1 -0.9,2 -2,2H5c-1.1,0 -2,-0.9 -2,-2V5c0,-1.1 0.9,-2 2,-2zM5,13v6h14v-6H5z" />
</vector>
XMLEOF
    echo "   [ok]   ic_text_bg_24.xml created"
  fi
}

# ---------------------------------------------------------------------------
#  STEP 3 -- Layout patches: toolbar (Background tab + include) and
#            format settings (Style row)
# ---------------------------------------------------------------------------
step3_layouts() {
  echo "== step 3: toolbar + format layout patches"
  python3 - "$TOOLBAR" "$FMT" <<'CUTPY'
import re, sys
toolbar, fmt = sys.argv[1], sys.argv[2]

def rd(p):
    return open(p, encoding='utf-8', newline='').read()

def wr(p, s):
    open(p, 'w', encoding='utf-8', newline='').write(s)

def sub1(s, pat, repl, name, flags=0):
    hits = re.findall(pat, s, flags)
    if len(hits) != 1:
        print('   [FAIL] %s: %d match(es)' % (name, len(hits)))
        sys.exit(1)
    return re.sub(pat, lambda m: repl, s, count=1, flags=flags)

# --- toolbar: include the background settings panel -----------------------
s = rd(toolbar)
if 'bgSettingsContainer' in s:
    print('   [skip] toolbar include already patched')
else:
    ANCHOR = ('    <!-- Format Settings Container -->\n'
              '    <include layout="@layout/text_format_settings"\n'
              '        android:id="@+id/formatSettingsContainer"\n'
              '        android:visibility="gone" />')
    if s.count(ANCHOR) != 1:
        print('   [FAIL] toolbar include anchor mismatch')
        sys.exit(1)
    s = s.replace(ANCHOR, ANCHOR + '\n\n'
        '    <!-- Background Settings Container -->\n'
        '    <include layout="@layout/text_background_settings"\n'
        '        android:id="@+id/bgSettingsContainer"\n'
        '        android:visibility="gone" />', 1)
    wr(toolbar, s)
    print('   [ok]   toolbar: background settings include added')

# --- toolbar: Background tab button (after Format, before Duplicate) ------
s = rd(toolbar)
if 'btnTextBackgroundTab' in s:
    print('   [skip] toolbar tab button already patched')
else:
    BTN = ('            <!-- Background Settings -->\n'
           '            <LinearLayout\n'
           '                android:layout_width="60dp"\n'
           '                android:layout_height="wrap_content"\n'
           '                android:orientation="vertical"\n'
           '                android:gravity="center">\n'
           '                <ImageButton\n'
           '                    android:id="@+id/btnTextBackgroundTab"\n'
           '                    android:layout_width="40dp"\n'
           '                    android:layout_height="40dp"\n'
           '                    android:background="@drawable/tool_button_inactive"\n'
           '                    android:src="@drawable/ic_text_bg_24"\n'
           '                    android:padding="8dp"\n'
           '                    android:scaleType="fitCenter"\n'
           '                    app:tint="@color/toolTextInactive" />\n'
           '                <TextView\n'
           '                    android:layout_width="wrap_content"\n'
           '                    android:layout_height="wrap_content"\n'
           '                    android:layout_marginTop="4dp"\n'
           '                    android:text="Background"\n'
           '                    android:textSize="10sp"\n'
           '                    android:fontFamily="sans-serif-medium"\n'
           '                    android:textColor="@color/toolTextInactive" />\n'
           '            </LinearLayout>\n\n')
    s = sub1(s, re.escape('            <!-- Duplicate -->'),
             BTN + '            <!-- Duplicate -->',
             'toolbar tab anchor')
    wr(toolbar, s)
    print('   [ok]   toolbar: Background tab button added after Format')

# --- format settings: Style row (B / I / U / S) ---------------------------
s = rd(fmt)
if 'btnStyleBold' in s:
    print('   [skip] format Style row already patched')
else:
    END = '    </LinearLayout>\n\n</LinearLayout>'
    if s.count(END) != 1:
        print('   [FAIL] format end anchor mismatch')
        sys.exit(1)
    ROW = (
        '    </LinearLayout>\n\n'
        '    <!-- Style: Bold / Italic / Underline / Strikethrough -->\n'
        '    <LinearLayout\n'
        '        android:layout_width="match_parent"\n'
        '        android:layout_height="wrap_content"\n'
        '        android:orientation="horizontal"\n'
        '        android:gravity="center_vertical"\n'
        '        android:layout_marginTop="8dp">\n'
        '        <TextView\n'
        '            android:layout_width="100dp"\n'
        '            android:layout_height="wrap_content"\n'
        '            android:text="Style"\n'
        '            android:textColor="#FFFFFF"\n'
        '            android:textSize="14sp" />\n'
        '        <com.google.android.material.button.MaterialButton\n'
        '            android:id="@+id/btnStyleBold"\n'
        '            android:layout_width="0dp"\n'
        '            android:layout_height="40dp"\n'
        '            android:layout_weight="1"\n'
        '            android:insetTop="0dp"\n'
        '            android:insetBottom="0dp"\n'
        '            android:text="B"\n'
        '            android:textSize="16sp"\n'
        '            android:textStyle="bold"\n'
        '            android:textColor="#FFFFFF"\n'
        '            android:backgroundTint="@color/inactiveToolBackground" />\n'
        '        <com.google.android.material.button.MaterialButton\n'
        '            android:id="@+id/btnStyleItalic"\n'
        '            android:layout_width="0dp"\n'
        '            android:layout_height="40dp"\n'
        '            android:layout_weight="1"\n'
        '            android:layout_marginHorizontal="4dp"\n'
        '            android:insetTop="0dp"\n'
        '            android:insetBottom="0dp"\n'
        '            android:text="I"\n'
        '            android:textSize="16sp"\n'
        '            android:textStyle="italic"\n'
        '            android:textColor="#FFFFFF"\n'
        '            android:backgroundTint="@color/inactiveToolBackground" />\n'
        '        <com.google.android.material.button.MaterialButton\n'
        '            android:id="@+id/btnStyleUnderline"\n'
        '            android:layout_width="0dp"\n'
        '            android:layout_height="40dp"\n'
        '            android:layout_weight="1"\n'
        '            android:insetTop="0dp"\n'
        '            android:insetBottom="0dp"\n'
        '            android:text="U"\n'
        '            android:textSize="16sp"\n'
        '            android:textColor="#FFFFFF"\n'
        '            android:backgroundTint="@color/inactiveToolBackground" />\n'
        '        <com.google.android.material.button.MaterialButton\n'
        '            android:id="@+id/btnStyleStrike"\n'
        '            android:layout_width="0dp"\n'
        '            android:layout_height="40dp"\n'
        '            android:layout_weight="1"\n'
        '            android:layout_marginStart="4dp"\n'
        '            android:insetTop="0dp"\n'
        '            android:insetBottom="0dp"\n'
        '            android:text="S"\n'
        '            android:textSize="16sp"\n'
        '            android:textColor="#FFFFFF"\n'
        '            android:backgroundTint="@color/inactiveToolBackground" />\n'
        '    </LinearLayout>\n\n'
        '</LinearLayout>')
    s = s.replace(END, ROW, 1)
    wr(fmt, s)
    print('   [ok]   format: Style row (Bold/Italic/Underline/Strikethrough) added')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STEP 4 -- TextOverlayView: delegate AddText rendering to TextRenderUtils
# ---------------------------------------------------------------------------
step4_textoverlayview() {
  echo "== step 4: TextOverlayView shared rendering"
  python3 - "$TOV" <<'CUTPY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()

def sub1(s, pat, repl, name, flags=re.DOTALL):
    hits = re.findall(pat, s, flags)
    if len(hits) != 1:
        print('   [FAIL] %s: %d match(es)' % (name, len(hits)))
        sys.exit(1)
    return re.sub(pat, lambda m: repl, s, count=1, flags=flags)

# T1: typeface if/else block (fontPath) -> removed; configPaint handles it.
# The pattern is anchored on the if(op.fontPath) line right after textSize
# so it can never jump to the subtitle section's similar else-branch, and
# it must run to the END of the else-branch close brace (not the inner
# catch-close), otherwise broken remnants would be left behind.
pat1 = (re.escape('paint.textSize = op.fontSize * scale') +
        r'[ \t]*\n[ \t]*' + re.escape('if (op.fontPath != null) {') +
        r'.*?' + re.escape('} else {') +
        r'[ \t]*\n[ \t]*' + re.escape('paint.typeface = android.graphics.Typeface.DEFAULT') +
        r'[ \t]*\n[ \t]*\}')
# T2: color + letterSpacing block -> configPaint with interpolated alpha
pat2 = (re.escape('val baseColorInt = try { Color.parseColor(op.color) }') +
        r'.*?' + re.escape('paint.letterSpacing = op.letterSpacing'))
# T3: per-line draw loop -> drawBlock (background + border + alignment)
pat3 = (re.escape('// Draw each line') +
        r'.*?' + re.escape('canvas.drawText(line, lineX, lineY, paint)') +
        r'[ \t]*\n[ \t]*\}')

if re.findall(pat1, s, re.DOTALL):
    s = sub1(s, pat1, 'paint.textSize = op.fontSize * scale', 'T1 typeface block')
    print('   [ok]   T1: typeface block delegated')
else:
    print('   [skip] T1: typeface block already delegated')

if re.findall(pat2, s, re.DOTALL):
    s = sub1(s, pat2,
             'val alphaInt = (interpolatedOpacity * 255).toInt().coerceIn(0, 255)\n'
             '                com.tharunbirla.librecuts.utils.TextRenderUtils.configPaint(paint, op, alphaInt)',
             'T2 color block')
    print('   [ok]   T2: paint config delegated (style flags included)')
else:
    print('   [skip] T2: paint config already delegated')

if re.findall(pat3, s, re.DOTALL):
    s = sub1(s, pat3,
             'com.tharunbirla.librecuts.utils.TextRenderUtils.drawBlock(\n'
             '                    canvas, paint, op, lines, maxTextWidth, startX, startY, textHeight, scale)',
             'T3 draw loop')
    print('   [ok]   T3: draw loop delegated (bg + styles render in preview)')
else:
    print('   [skip] T3: draw loop already delegated')

open(p, 'w', encoding='utf-8', newline='').write(s)
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STEP 5 -- DraggableTextOverlayView: style + background state
# ---------------------------------------------------------------------------
step5_draggable() {
  echo "== step 5: DraggableTextOverlayView style/background state"
  python3 - "$DRG" <<'CUTPY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()

# D-a: extend the commit callback signature (full suffix replace; slicing
# the tail would keep the params-closing paren and produce invalid Kotlin)
if 'bold: Boolean, italic: Boolean, underline: Boolean' not in s:
    OLD_SIG = ('textAlign: String, letterSpacing: Float, lineSpacing: Float) -> Unit)? = null')
    NEW_SIG = ('textAlign: String, letterSpacing: Float, lineSpacing: Float, '
               'bold: Boolean, italic: Boolean, underline: Boolean, strikethrough: Boolean, '
               'bgColor: String?, bgOpacity: Float, bgCornerRadius: Int, bgMargin: Int) -> Unit)? = null')
    if s.count(OLD_SIG) != 1:
        print('   [FAIL] D-a anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD_SIG, NEW_SIG, 1)
    print('   [ok]   D-a: commit callback signature extended')
else:
    print('   [skip] D-a: callback already extended')

# D-b: state fields
if 'private var currentBgColor' not in s:
    ANCHOR = '    var currentFontPath: String? = null'
    if s.count(ANCHOR) != 1:
        print('   [FAIL] D-b anchor mismatch')
        sys.exit(1)
    s = s.replace(ANCHOR, ANCHOR + '\n'
        '    private var currentBold = false\n'
        '    private var currentItalic = false\n'
        '    private var currentUnderline = false\n'
        '    private var currentStrikethrough = false\n'
        '    private var currentBgColor: String? = null\n'
        '    private var currentBgOpacity = 1.0f\n'
        '    private var currentBgCornerRadius = 0\n'
        '    private var currentBgMargin = 0', 1)
    print('   [ok]   D-b: state fields added')
else:
    print('   [skip] D-b: state fields already present')

# D-c: setFontPath applies synthesized styles
if 'currentFontPath = fontPath\n        applyTypefaceAndFlags()' not in s:
    OLD = ('    fun setFontPath(fontPath: String?) {\n'
           '        currentFontPath = fontPath\n'
           '        try {\n'
           '            editText.typeface = if (fontPath.isNullOrBlank()) Typeface.DEFAULT else Typeface.createFromFile(fontPath)\n'
           '        } catch (e: Exception) {\n'
           '            editText.typeface = Typeface.DEFAULT\n'
           '        }\n'
           '    }')
    if s.count(OLD) != 1:
        print('   [FAIL] D-c anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, '    fun setFontPath(fontPath: String?) {\n'
        '        currentFontPath = fontPath\n'
        '        applyTypefaceAndFlags()\n'
        '    }', 1)
    print('   [ok]   D-c: setFontPath now applies styles')
else:
    print('   [skip] D-c: setFontPath already patched')

# D-d: setters, getters, helpers (after setTextAlign)
if 'fun setBgMargin(' not in s:
    ANCHOR = ('    fun setTextAlign(align: String) {\n'
              '        currentTextAlign = align\n'
              '        when (align) {\n'
              '            "left", "L" -> editText.gravity = Gravity.START or Gravity.CENTER_VERTICAL\n'
              '            "right", "R" -> editText.gravity = Gravity.END or Gravity.CENTER_VERTICAL\n'
              '            else -> editText.gravity = Gravity.CENTER\n'
              '        }\n'
              '    }')
    if s.count(ANCHOR) != 1:
        print('   [FAIL] D-d anchor mismatch')
        sys.exit(1)
    NEW = ANCHOR + '\n\n' + (
        '    // -- Style + background setters (CutStudio round 5) --\n'
        '    fun setBold(on: Boolean) { currentBold = on; applyTypefaceAndFlags() }\n'
        '    fun setItalic(on: Boolean) { currentItalic = on; applyTypefaceAndFlags() }\n'
        '    fun setUnderline(on: Boolean) { currentUnderline = on; applyTypefaceAndFlags() }\n'
        '    fun setStrikethrough(on: Boolean) { currentStrikethrough = on; applyTypefaceAndFlags() }\n'
        '    fun setBgColor(hex: String?) { currentBgColor = hex; refreshEditTextBackground() }\n'
        '    fun setBgOpacity(value: Float) { currentBgOpacity = value.coerceIn(0f, 1f); refreshEditTextBackground() }\n'
        '    fun setBgCornerRadius(value: Int) { currentBgCornerRadius = value.coerceAtLeast(0); refreshEditTextBackground() }\n'
        '    fun setBgMargin(value: Int) { currentBgMargin = value.coerceAtLeast(0); refreshEditTextBackground() }\n'
        '\n'
        '    fun getBold(): Boolean = currentBold\n'
        '    fun getItalic(): Boolean = currentItalic\n'
        '    fun getUnderline(): Boolean = currentUnderline\n'
        '    fun getStrikethrough(): Boolean = currentStrikethrough\n'
        '    fun getBgColor(): String? = currentBgColor\n'
        '    fun getBgOpacity(): Float = currentBgOpacity\n'
        '    fun getBgCornerRadius(): Int = currentBgCornerRadius\n'
        '    fun getBgMargin(): Int = currentBgMargin\n'
        '\n'
        '    private fun applyTypefaceAndFlags() {\n'
        '        val base = try {\n'
        '            if (currentFontPath.isNullOrBlank()) null else Typeface.createFromFile(currentFontPath)\n'
        '        } catch (e: Exception) {\n'
        '            null\n'
        '        }\n'
        '        val family = base ?: Typeface.DEFAULT\n'
        '        val style = when {\n'
        '            currentBold && currentItalic -> Typeface.BOLD_ITALIC\n'
        '            currentBold -> Typeface.BOLD\n'
        '            currentItalic -> Typeface.ITALIC\n'
        '            else -> Typeface.NORMAL\n'
        '        }\n'
        '        editText.typeface = if (style == Typeface.NORMAL) family else Typeface.create(family, style)\n'
        '        var flags = editText.paintFlags and (Paint.UNDERLINE_TEXT_FLAG or Paint.STRIKE_THRU_TEXT_FLAG).inv()\n'
        '        if (currentUnderline) flags = flags or Paint.UNDERLINE_TEXT_FLAG\n'
        '        if (currentStrikethrough) flags = flags or Paint.STRIKE_THRU_TEXT_FLAG\n'
        '        editText.paintFlags = flags\n'
        '    }\n'
        '\n'
        '    private fun refreshEditTextBackground() {\n'
        '        val hex = currentBgColor\n'
        '        if (hex == null) {\n'
        '            editText.background = null\n'
        '            editText.setPadding(16, 8, 16, 8)\n'
        '            return\n'
        '        }\n'
        '        val scale = if (videoHeight > 0) {\n'
        '            val rect = getVideoRect()\n'
        '            if (rect.height() > 0f) rect.height() / videoHeight.toFloat() else 1f\n'
        '        } else 1f\n'
        '        val marginPx = (currentBgMargin * scale).toInt().coerceAtLeast(0)\n'
        '        val radiusPx = (currentBgCornerRadius * scale).coerceAtLeast(0f)\n'
        '        val baseColor = try { Color.parseColor(hex) } catch (e: Exception) { Color.BLACK }\n'
        '        val alpha = (currentBgOpacity.coerceIn(0f, 1f) * 255).toInt()\n'
        '        val drawable = android.graphics.drawable.GradientDrawable().apply {\n'
        '            cornerRadius = radiusPx\n'
        '            setColor(Color.argb(alpha, Color.red(baseColor), Color.green(baseColor), Color.blue(baseColor)))\n'
        '        }\n'
        '        editText.background = drawable\n'
        '        editText.setPadding(16 + marginPx, 8 + marginPx / 2, 16 + marginPx, 8 + marginPx / 2)\n'
        '    }')
    s = s.replace(ANCHOR, NEW, 1)
    print('   [ok]   D-d: setters/getters/helpers added')
else:
    print('   [skip] D-d: setters already present')

# D-e: activate() resets
if 'currentBgColor = null\n        currentBgOpacity = 1.0f' not in s:
    ANCHOR = '        currentColorString = "#FFFFFF"\n        currentFontPath = null'
    if s.count(ANCHOR) != 1:
        print('   [FAIL] D-e anchor mismatch')
        sys.exit(1)
    s = s.replace(ANCHOR, ANCHOR + '\n'
        '        currentBold = false\n'
        '        currentItalic = false\n'
        '        currentUnderline = false\n'
        '        currentStrikethrough = false\n'
        '        currentBgColor = null\n'
        '        currentBgOpacity = 1.0f\n'
        '        currentBgCornerRadius = 0\n'
        '        currentBgMargin = 0\n'
        '        applyTypefaceAndFlags()\n'
        '        refreshEditTextBackground()', 1)
    print('   [ok]   D-e: activate() resets new state')
else:
    print('   [skip] D-e: activate() already resets')

# D-f: activateForEdit() loads op state
if 'currentBold = op.bold' not in s:
    ANCHOR = '        currentFontPath = op.fontPath\n\n        setFontPath(op.fontPath)'
    if s.count(ANCHOR) != 1:
        print('   [FAIL] D-f anchor mismatch')
        sys.exit(1)
    s = s.replace(ANCHOR, '        currentFontPath = op.fontPath\n'
        '        currentBold = op.bold\n'
        '        currentItalic = op.italic\n'
        '        currentUnderline = op.underline\n'
        '        currentStrikethrough = op.strikethrough\n'
        '        currentBgColor = op.bgColor\n'
        '        currentBgOpacity = op.bgOpacity\n'
        '        currentBgCornerRadius = op.bgCornerRadius\n'
        '        currentBgMargin = op.bgMargin\n\n'
        '        setFontPath(op.fontPath)', 1)
    print('   [ok]   D-f: activateForEdit() loads style + background')
else:
    print('   [skip] D-f: activateForEdit() already loads')

# D-f2: refresh background preview when re-editing
if 'refreshEditTextBackground()\n\n        post {\n            positionEditTextFromRelative()\n            editText.requestFocus()\n        }\n    }' not in s and 'refreshEditTextBackground()\n        refreshTextEffects()\n\n        post {\n            positionEditTextFromRelative()\n            editText.requestFocus()\n        }\n    }' not in s:
    ANCHOR = ('        updateFontSizeOnScreen()\n'
              '        visibility = VISIBLE\n'
              '\n'
              '        post {\n'
              '            positionEditTextFromRelative()\n'
              '            editText.requestFocus()\n'
              '        }\n'
              '    }')
    if s.count(ANCHOR) != 1:
        print('   [FAIL] D-f2 anchor mismatch')
        sys.exit(1)
    s = s.replace(ANCHOR, '        updateFontSizeOnScreen()\n'
        '        visibility = VISIBLE\n'
        '        refreshEditTextBackground()\n'
        '\n'
        '        post {\n'
        '            positionEditTextFromRelative()\n'
        '            editText.requestFocus()\n'
        '        }\n'
        '    }', 1)
    print('   [ok]   D-f2: background preview refreshed on re-edit')
else:
    print('   [skip] D-f2: already refreshed')

# D-g: commitText passes new fields
if 'currentBgMargin\n            )' not in s and 'currentShadowWidth\n            )' not in s:
    OLD = ('            onTextCommitted?.invoke(\n'
           '                text, currentFontSize, relativeX, relativeY, currentColorString,\n'
           '                currentFontPath, currentOpacity, currentBorderThickness, currentBorderColor, currentTextAlign, currentLetterSpacing, currentLineSpacing\n'
           '            )')
    if s.count(OLD) != 1:
        print('   [FAIL] D-g anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, '            onTextCommitted?.invoke(\n'
        '                text, currentFontSize, relativeX, relativeY, currentColorString,\n'
        '                currentFontPath, currentOpacity, currentBorderThickness, currentBorderColor, currentTextAlign, currentLetterSpacing, currentLineSpacing,\n'
        '                currentBold, currentItalic, currentUnderline, currentStrikethrough, currentBgColor, currentBgOpacity, currentBgCornerRadius, currentBgMargin\n'
        '            )', 1)
    print('   [ok]   D-g: commitText passes style + background')
else:
    print('   [skip] D-g: commitText already passes')

open(p, 'w', encoding='utf-8', newline='').write(s)
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STEP 6 -- VideoEditingViewModel: PNG overlay path for AddText
# ---------------------------------------------------------------------------
step6_viewmodel() {
  echo "== step 6: ViewModel PNG overlay path"
  python3 - "$VM" <<'CUTPY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()

def sub1(s, pat, repl, name, flags=re.DOTALL):
    hits = re.findall(pat, s, flags)
    if len(hits) != 1:
        print('   [FAIL] %s: %d match(es)' % (name, len(hits)))
        sys.exit(1)
    return re.sub(pat, lambda m: repl, s, count=1, flags=flags)

# V1: renderer property + prepare helper + overlay position map
if 'var textPngRenderer' not in s:
    ANCHOR = '    /** Build a drawtext filter expression for a text operation. */'
    if s.count(ANCHOR) != 1:
        print('   [FAIL] V1 anchor mismatch')
        sys.exit(1)
    # (body continues below)
    BLOCK = (
        '    /** Renders AddText ops to transparent PNGs (WYSIWYG canvas rendering).\n'
        '     *  Set by the Activity; when set, text overlays are composited with the\n'
        '     *  overlay filter instead of drawtext, so bold / italic / underline /\n'
        '     *  strikethrough / letter spacing / rounded backgrounds all render\n'
        '     *  exactly like the preview. */\n'
        '    var textPngRenderer: ((EditOperation.AddText) -> String?)? = null\n'
        '    private val textPngInputs = mutableListOf<Pair<EditOperation.AddText, String>>()\n'
        '\n'
        '    private fun prepareTextPngInputs(operations: List<EditOperation>) {\n'
        '        textPngInputs.clear()\n'
        '        val renderer = textPngRenderer ?: return\n'
        '        for (textOp in operations.filterIsInstance<EditOperation.AddText>()) {\n'
        '            try {\n'
        '                val path = renderer(textOp)\n'
        '                if (path != null) {\n'
        '                    textPngInputs.add(Pair(textOp, path))\n'
        '                }\n'
        '            } catch (e: Exception) {\n'
        '                Log.w(TAG, "Text PNG render failed for op " + textOp.id + ": " + e.message)\n'
        '            }\n'
        '        }\n'
        '    }\n'
        '\n'
        '    /** overlay-filter position expressions (W/H = main video, w/h = text image). */\n'
        '    private fun overlayPosExpr(pos: TextPosition): Pair<String, String> = when (pos) {\n'
        '        TextPosition.BOTTOM_RIGHT -> Pair("\'W-w\'", "\'H-h\'")\n'
        '        TextPosition.TOP_RIGHT -> Pair("\'W-w\'", "0")\n'
        '        TextPosition.TOP_LEFT -> Pair("0", "0")\n'
        '        TextPosition.BOTTOM_LEFT -> Pair("0", "\'H-h\'")\n'
        '        TextPosition.CENTER_BOTTOM -> Pair("\'(W-w)/2\'", "\'H-h\'")\n'
        '        TextPosition.CENTER_TOP -> Pair("\'(W-w)/2\'", "0")\n'
        '        TextPosition.CENTER -> Pair("\'(W-w)/2\'", "\'(H-h)/2\'")\n'
        '        TextPosition.TOP_CENTER -> Pair("\'(W-w)/2\'", "0")\n'
        '        TextPosition.CENTER_LEFT -> Pair("0", "\'(H-h)/2\'")\n'
        '        TextPosition.CENTER_RIGHT -> Pair("\'W-w\'", "\'(H-h)/2\'")\n'
        '        TextPosition.BOTTOM_CENTER -> Pair("\'(W-w)/2\'", "\'H-h\'")\n'
        '    }\n'
        '\n')
    s = s.replace(ANCHOR, BLOCK + ANCHOR, 1)
    print('   [ok]   V1: renderer property + helpers added')
else:
    print('   [skip] V1: renderer property already present')

# V2: buildVideoFilterStages signature gets textInputIndices
if 'textInputIndices: List<Pair<Int, EditOperation.AddText>> = emptyList(),' not in s:
    ANCHOR = '        imageInputIndices: List<Pair<Int, EditOperation.AddImageOverlay>> = emptyList(),'
    if s.count(ANCHOR) != 1:
        print('   [FAIL] V2 anchor mismatch')
        sys.exit(1)
    s = s.replace(ANCHOR, ANCHOR + '\n'
        '        textInputIndices: List<Pair<Int, EditOperation.AddText>> = emptyList(),', 1)
    print('   [ok]   V2: buildVideoFilterStages signature extended')
else:
    print('   [skip] V2: signature already extended')

# V3: AddText branch -> PNG overlay with drawtext fallback
if 'WYSIWYG path: canvas-rendered PNG' not in s:
    pat = (re.escape('is EditOperation.AddText -> {') +
           r'[ \t]*\n[ \t]*' + re.escape('val filterExpr = buildDrawtextExpr(op, fontFilePath)') +
           r'.*?' + re.escape('stageIndex++') + r'[ \t]*\n[ \t]*\}')
    NEW = (
        'is EditOperation.AddText -> {\n'
        '                    val textPngIndex = textInputIndices.find { it.second.id == op.id }?.first\n'
        '                    if (textPngIndex != null) {\n'
        '                        // WYSIWYG path: canvas-rendered PNG composited with overlay\n'
        '                        val hasOpacityKfs = op.opacityKeyframes.isNotEmpty()\n'
        '                        val rgbaLabel = "[txt_rgba_$stageIndex]"\n'
        '                        if (hasOpacityKfs) {\n'
        '                            stages.add("[$textPngIndex:v]format=rgba,loop=loop=-1:size=1:start=0,fps=25$rgbaLabel")\n'
        '                        } else {\n'
        '                            stages.add("[$textPngIndex:v]format=rgba$rgbaLabel")\n'
        '                        }\n'
        '                        var textLabel = rgbaLabel\n'
        '                        if (hasOpacityKfs) {\n'
        '                            val alphaLabel = "[txt_alpha_$stageIndex]"\n'
        '                            val alphaExpr = buildFFmpegInterpolationExpr(\n'
        '                                op.opacityKeyframes, useValueY = false, defaultValue = op.opacity,\n'
        '                                startTimeMs = op.startTimeMs ?: 0L, timeVar = "T")\n'
        '                            stages.add("${textLabel}geq=r=\'r(X,Y)\':g=\'g(X,Y)\':b=\'b(X,Y)\':a=\'alpha(X,Y)*($alphaExpr)\'$alphaLabel")\n'
        '                            textLabel = alphaLabel\n'
        '                        } else if (op.opacity < 1.0f) {\n'
        '                            val alphaLabel = "[txt_alpha_$stageIndex]"\n'
        '                            stages.add("${textLabel}colorchannelmixer=aa=${op.opacity}$alphaLabel")\n'
        '                            textLabel = alphaLabel\n'
        '                        }\n'
        '                        val overlayX = if (op.positionKeyframes.isNotEmpty()) {\n'
        '                            val xExpr = buildFFmpegInterpolationExpr(\n'
        '                                op.positionKeyframes, useValueY = false,\n'
        '                                defaultValue = op.relativeX ?: 0.5f, startTimeMs = op.startTimeMs ?: 0L)\n'
        '                            "x=\'(W*($xExpr))-(w/2)\'"\n'
        '                        } else if (op.hasCustomPosition()) {\n'
        '                            "x=\'(W*${op.relativeX})-(w/2)\'"\n'
        '                        } else {\n'
        '                            "x=" + overlayPosExpr(op.position).first\n'
        '                        }\n'
        '                        val overlayY = if (op.positionKeyframes.isNotEmpty()) {\n'
        '                            val yExpr = buildFFmpegInterpolationExpr(\n'
        '                                op.positionKeyframes, useValueY = true,\n'
        '                                defaultValue = op.relativeY ?: 0.5f, startTimeMs = op.startTimeMs ?: 0L)\n'
        '                            "y=\'(H*($yExpr))-(h/2)\'"\n'
        '                        } else if (op.hasCustomPosition()) {\n'
        '                            "y=\'(H*${op.relativeY})-(h/2)\'"\n'
        '                        } else {\n'
        '                            "y=" + overlayPosExpr(op.position).second\n'
        '                        }\n'
        '                        val enablePart = buildEnableExpr(op.startTimeMs, op.endTimeMs)\n'
        '                        val shortestPart = if (hasOpacityKfs) ":shortest=1" else ""\n'
        '                        val nextLabel = "[v$stageIndex]"\n'
        '                        stages.add("$currentLabel${textLabel}overlay=$overlayX:$overlayY$shortestPart$enablePart$nextLabel")\n'
        '                        currentLabel = nextLabel\n'
        '                        stageIndex++\n'
        '                    } else {\n'
        '                        // Fallback: classic drawtext filter\n'
        '                        val filterExpr = buildDrawtextExpr(op, fontFilePath)\n'
        '                        val nextLabel = "[v$stageIndex]"\n'
        '                        stages.add("$currentLabel$filterExpr$nextLabel")\n'
        '                        currentLabel = nextLabel\n'
        '                        stageIndex++\n'
        '                    }\n'
        '                }')
    s = sub1(s, pat, NEW, 'V3 AddText branch')
    print('   [ok]   V3: AddText branch -> PNG overlay (drawtext fallback kept)')
else:
    print('   [skip] V3: AddText branch already patched')

# V4: prepare PNGs before input assembly
if 'prepareTextPngInputs(operations)' not in s:
    ANCHOR = '        val imageOps = operations.filterIsInstance<EditOperation.AddImageOverlay>()'
    if s.count(ANCHOR) != 1:
        print('   [FAIL] V4 anchor mismatch')
        sys.exit(1)
    s = s.replace(ANCHOR, ANCHOR + '\n'
        '        // Render text overlay PNGs before inputs are indexed\n'
        '        prepareTextPngInputs(operations)', 1)
    print('   [ok]   V4: PNG preparation hooked before input assembly')
else:
    print('   [skip] V4: PNG preparation already hooked')

# V5: text PNG inputs section (before canvas background input)
if '// 4b. Text Overlay PNG Inputs' not in s:
    ANCHOR = '        // 5. Canvas Background Image Input'
    if s.count(ANCHOR) != 1:
        print('   [FAIL] V5 anchor mismatch')
        sys.exit(1)
    BLOCK = (
        '        // 4b. Text Overlay PNG Inputs (WYSIWYG canvas-rendered text)\n'
        '        val textInputIndices = mutableListOf<Pair<Int, EditOperation.AddText>>()\n'
        '        for ((textOp, pngPath) in textPngInputs) {\n'
        '            cmd.append(" -i \\"$pngPath\\"")\n'
        '            textInputIndices.add(Pair(inputIndex, textOp))\n'
        '            inputIndex++\n'
        '        }\n'
        '\n')
    s = s.replace(ANCHOR, BLOCK + ANCHOR, 1)
    print('   [ok]   V5: text PNG input section added')
else:
    print('   [skip] V5: text input section already present')

# V6: pass textInputIndices at both call sites
# NOTE: anchors are newline-prefixed so the 12-space pattern cannot match
# as a substring of the 16-space (merge) call site line.
if 'textInputIndices = textInputIndices,' not in s:
    A_MERGE = '\n                imageInputIndices = imageInputIndices,'
    A_PLAIN = '\n            imageInputIndices = imageInputIndices,'
    if s.count(A_MERGE) != 1 or s.count(A_PLAIN) != 1:
        print('   [FAIL] V6 anchors mismatch (merge=%d plain=%d)' % (s.count(A_MERGE), s.count(A_PLAIN)))
        sys.exit(1)
    s = s.replace(A_MERGE, A_MERGE + '\n                textInputIndices = textInputIndices,', 1)
    s = s.replace(A_PLAIN, A_PLAIN + '\n            textInputIndices = textInputIndices,', 1)
    print('   [ok]   V6: both buildVideoFilterStages call sites pass text inputs')
else:
    print('   [skip] V6: call sites already pass text inputs')

open(p, 'w', encoding='utf-8', newline='').write(s)
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STEP 7 -- VideoEditingViewModelExt: addTextOperation new params
# ---------------------------------------------------------------------------
step7_ext() {
  echo "== step 7: addTextOperation extended"
  python3 - "$VME" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'bgMargin: Int = 0' in s:
    print('   [skip] addTextOperation already extended')
    sys.exit(0)
OLD = (
    'fun VideoEditingViewModel.addTextOperation(\n'
    '    text: String, fontSize: Int, position: String, relativeX: Float? = null,\n'
    '    relativeY: Float? = null, color: String = "#FFFFFF", startTimeMs: Long? = null,\n'
    '    endTimeMs: Long? = null, fontPath: String? = null, opacity: Float = 1.0f,\n'
    '    borderThickness: Int = 0, borderColor: String = "#000000", textAlign: String = "center",\n'
    '    letterSpacing: Float = 0f, lineSpacing: Float = 0f\n'
    ') {\n'
    '    executeCommand(AddOperationCommand(EditOperation.AddText(\n'
    '        text, fontSize, TextPosition.fromLabel(position), relativeX, relativeY, color, startTimeMs,\n'
    '        endTimeMs, fontPath = fontPath, opacity = opacity, borderThickness = borderThickness,\n'
    '        borderColor = borderColor, textAlign = textAlign, letterSpacing = letterSpacing, lineSpacing = lineSpacing\n'
    '    ), "Add Text"))\n'
    '}')
NEW = (
    'fun VideoEditingViewModel.addTextOperation(\n'
    '    text: String, fontSize: Int, position: String, relativeX: Float? = null,\n'
    '    relativeY: Float? = null, color: String = "#FFFFFF", startTimeMs: Long? = null,\n'
    '    endTimeMs: Long? = null, fontPath: String? = null, opacity: Float = 1.0f,\n'
    '    borderThickness: Int = 0, borderColor: String = "#000000", textAlign: String = "center",\n'
    '    letterSpacing: Float = 0f, lineSpacing: Float = 0f,\n'
    '    bold: Boolean = false, italic: Boolean = false, underline: Boolean = false,\n'
    '    strikethrough: Boolean = false, bgColor: String? = null, bgOpacity: Float = 1.0f,\n'
    '    bgCornerRadius: Int = 0, bgMargin: Int = 0\n'
    ') {\n'
    '    executeCommand(AddOperationCommand(EditOperation.AddText(\n'
    '        text, fontSize, TextPosition.fromLabel(position), relativeX, relativeY, color, startTimeMs,\n'
    '        endTimeMs, fontPath = fontPath, opacity = opacity, borderThickness = borderThickness,\n'
    '        borderColor = borderColor, textAlign = textAlign, letterSpacing = letterSpacing, lineSpacing = lineSpacing,\n'
    '        bold = bold, italic = italic, underline = underline, strikethrough = strikethrough,\n'
    '        bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin\n'
    '    ), "Add Text"))\n'
    '}')
if s.count(OLD) != 1:
    print('   [FAIL] addTextOperation anchor mismatch')
    sys.exit(1)
s = s.replace(OLD, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   addTextOperation extended')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  STEP 8 -- VideoEditingActivity wiring
# ---------------------------------------------------------------------------
step8_activity() {
  echo "== step 8: Activity wiring"
  python3 - "$ACT" <<'CUTPY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()

def sub1(s, pat, repl, name, flags=re.DOTALL):
    hits = re.findall(pat, s, flags)
    if len(hits) != 1:
        print('   [FAIL] %s: %d match(es)' % (name, len(hits)))
        sys.exit(1)
    return re.sub(pat, lambda m: repl, s, count=1, flags=flags)

# A1: hook the WYSIWYG text renderer after the font copy block
if 'viewModel.textPngRenderer = { op ->' not in s:
    pat = re.escape('Make sure assets/fonts/Roboto-Regular.ttf exists in the project.")') + r'\n[ \t]*\}'
    NEW = ('Make sure assets/fonts/Roboto-Regular.ttf exists in the project.")\n'
           '        }\n'
           '\n'
           '        // WYSIWYG text rendering: AddText ops are rasterized with the same\n'
           '        // Canvas pipeline used by the preview, then composited via overlay.\n'
           '        viewModel.textPngRenderer = { op ->\n'
           '            com.tharunbirla.librecuts.utils.TextRenderUtils.renderAddTextToPng(this@VideoEditingActivity, op)?.absolutePath\n'
           '        }')
    s = sub1(s, pat, NEW, 'A1 renderer hook')
    print('   [ok]   A1: textPngRenderer hooked')

# A2a: onTextCommitted lambda params
if 'bold, italic, underline, strikethrough, bgColor, bgOpacity, bgCornerRadius, bgMargin ->' not in s and 'bgCornerRadius, bgMargin, strokeOpacity, shadowColor, shadowOpacity, shadowBlur, shadowAngle, shadowWidth ->' not in s:
    OLD = ('overlay.onTextCommitted = { text, fontSize, relX, relY, color, fontPath, opacity, '
           'borderThickness, borderColor, textAlign, letterSpacing, lineSpacing ->')
    if s.count(OLD) != 1:
        print('   [FAIL] A2a anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, 'overlay.onTextCommitted = { text, fontSize, relX, relY, color, fontPath, opacity, '
        'borderThickness, borderColor, textAlign, letterSpacing, lineSpacing, '
        'bold, italic, underline, strikethrough, bgColor, bgOpacity, bgCornerRadius, bgMargin ->', 1)
    print('   [ok]   A2a: commit lambda params extended')

# A2b: updateOperation call carries new fields
if 'bold = bold, italic = italic, underline = underline' not in s:
    OLD = ('viewModel.updateOperation(op.copy(\n'
           '                                    text = text, fontSize = fontSize, relativeX = relX, relativeY = relY, color = color,\n'
           '                                    fontPath = fontPath, opacity = opacity, borderThickness = borderThickness, borderColor = borderColor,\n'
           '                                    textAlign = textAlign, letterSpacing = letterSpacing, lineSpacing = lineSpacing\n'
           '                                ))')
    if s.count(OLD) != 1:
        print('   [FAIL] A2b anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, 'viewModel.updateOperation(op.copy(\n'
        '                                    text = text, fontSize = fontSize, relativeX = relX, relativeY = relY, color = color,\n'
        '                                    fontPath = fontPath, opacity = opacity, borderThickness = borderThickness, borderColor = borderColor,\n'
        '                                    textAlign = textAlign, letterSpacing = letterSpacing, lineSpacing = lineSpacing,\n'
        '                                    bold = bold, italic = italic, underline = underline, strikethrough = strikethrough,\n'
        '                                    bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin\n'
        '                                ))', 1)
    print('   [ok]   A2b: updateOperation carries new fields')

# A2c: addTextOperation call carries new fields
if 'bgMargin = bgMargin\n                        )' not in s and 'shadowWidth = shadowWidth\n                        )' not in s:
    OLD = ('                            textAlign = textAlign,\n'
           '                            letterSpacing = letterSpacing,\n'
           '                            lineSpacing = lineSpacing\n'
           '                        )')
    if s.count(OLD) != 1:
        print('   [FAIL] A2c anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, '                            textAlign = textAlign,\n'
        '                            letterSpacing = letterSpacing,\n'
        '                            lineSpacing = lineSpacing,\n'
        '                            bold = bold, italic = italic, underline = underline, strikethrough = strikethrough,\n'
        '                            bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin\n'
        '                        )', 1)
    print('   [ok]   A2c: addTextOperation carries new fields')

# A3: tab declarations + resetTabs
if 'val btnBackground = toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)' not in s:
    OLD = ('                val btnKeyboard = toolbar.findViewById<ImageButton>(R.id.btnTextKeyboardTab)\n'
           '                val btnPalette = toolbar.findViewById<ImageButton>(R.id.btnTextPaletteTab)\n'
           '                val btnFormat = toolbar.findViewById<ImageButton>(R.id.btnTextFormatTab)\n'
           '                val colorContainer = toolbar.findViewById<View>(R.id.colorPickerContainer)\n'
           '                val formatContainer = toolbar.findViewById<View>(R.id.formatSettingsContainer)\n'
           '\n'
           '                fun resetTabs() {\n'
           '                    colorContainer?.visibility = View.GONE\n'
           '                    formatContainer?.visibility = View.GONE\n'
           '                    btnKeyboard?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '                    btnPalette?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '                    btnFormat?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '                }')
    NEW = ('                val btnKeyboard = toolbar.findViewById<ImageButton>(R.id.btnTextKeyboardTab)\n'
           '                val btnPalette = toolbar.findViewById<ImageButton>(R.id.btnTextPaletteTab)\n'
           '                val btnFormat = toolbar.findViewById<ImageButton>(R.id.btnTextFormatTab)\n'
           '                val btnBackground = toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)\n'
           '                val colorContainer = toolbar.findViewById<View>(R.id.colorPickerContainer)\n'
           '                val formatContainer = toolbar.findViewById<View>(R.id.formatSettingsContainer)\n'
           '                val bgContainer = toolbar.findViewById<View>(R.id.bgSettingsContainer)\n'
           '\n'
           '                fun resetTabs() {\n'
           '                    colorContainer?.visibility = View.GONE\n'
           '                    formatContainer?.visibility = View.GONE\n'
           '                    bgContainer?.visibility = View.GONE\n'
           '                    btnKeyboard?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '                    btnPalette?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '                    btnFormat?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '                    btnBackground?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '                }')
    if s.count(OLD) != 1:
        print('   [FAIL] A3 anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, NEW, 1)
    print('   [ok]   A3: Background tab declared + resetTabs extended')

# A4: style toggles + bg sliders + btnFormat sync + btnBackground handler
if 'btnBackground?.setBounceClickListener' not in s:
    pat = (re.escape('btnFormat?.setBounceClickListener {') +
           r'.*?' + re.escape('btnFormat.setColorFilter(getColor(R.color.colorPrimary))') +
           r'[ \t]*\n[ \t]*\}')
    NEW = (
        '// Style toggle helpers: Bold / Italic / Underline / Strikethrough\n'
        '                fun styleTint(button: android.widget.Button?, active: Boolean) {\n'
        '                    button?.backgroundTintList = android.content.res.ColorStateList.valueOf(\n'
        '                        getColor(if (active) R.color.colorPrimary else R.color.inactiveToolBackground))\n'
        '                }\n'
        '                fun syncStyleButtons() {\n'
        '                    val textOverlay = draggableTextOverlay\n'
        '                    styleTint(formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleBold), textOverlay?.getBold() == true)\n'
        '                    styleTint(formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleItalic), textOverlay?.getItalic() == true)\n'
        '                    styleTint(formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleUnderline), textOverlay?.getUnderline() == true)\n'
        '                    styleTint(formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleStrike), textOverlay?.getStrikethrough() == true)\n'
        '                }\n'
        '                formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleBold)?.setOnClickListener {\n'
        '                    draggableTextOverlay?.let { it.setBold(!it.getBold()) }\n'
        '                    syncStyleButtons()\n'
        '                }\n'
        '                formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleItalic)?.setOnClickListener {\n'
        '                    draggableTextOverlay?.let { it.setItalic(!it.getItalic()) }\n'
        '                    syncStyleButtons()\n'
        '                }\n'
        '                formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleUnderline)?.setOnClickListener {\n'
        '                    draggableTextOverlay?.let { it.setUnderline(!it.getUnderline()) }\n'
        '                    syncStyleButtons()\n'
        '                }\n'
        '                formatContainer?.findViewById<android.widget.Button>(R.id.btnStyleStrike)?.setOnClickListener {\n'
        '                    draggableTextOverlay?.let { it.setStrikethrough(!it.getStrikethrough()) }\n'
        '                    syncStyleButtons()\n'
        '                }\n'
        '\n'
        '                // Background tab sliders\n'
        '                fun syncBgSliders() {\n'
        '                    val textOverlay = draggableTextOverlay ?: return\n'
        '                    bgContainer?.findViewById<Slider>(R.id.seekBgOpacity)?.value =\n'
        '                        (textOverlay.getBgOpacity() * 100f).coerceIn(0f, 100f)\n'
        '                    bgContainer?.findViewById<Slider>(R.id.seekBgCornerRadius)?.value =\n'
        '                        textOverlay.getBgCornerRadius().toFloat().coerceIn(0f, 50f)\n'
        '                    bgContainer?.findViewById<Slider>(R.id.seekBgMargin)?.value =\n'
        '                        textOverlay.getBgMargin().toFloat().coerceIn(0f, 50f)\n'
        '                }\n'
        '                bgContainer?.findViewById<Slider>(R.id.seekBgOpacity)?.addOnChangeListener { _, value, _ ->\n'
        '                    draggableTextOverlay?.setBgOpacity(value / 100f)\n'
        '                }\n'
        '                bgContainer?.findViewById<Slider>(R.id.seekBgCornerRadius)?.addOnChangeListener { _, value, _ ->\n'
        '                    draggableTextOverlay?.setBgCornerRadius(value.toInt())\n'
        '                }\n'
        '                bgContainer?.findViewById<Slider>(R.id.seekBgMargin)?.addOnChangeListener { _, value, _ ->\n'
        '                    draggableTextOverlay?.setBgMargin(value.toInt())\n'
        '                }\n'
        '\n'
        '                btnFormat?.setBounceClickListener {\n'
        '                    draggableTextOverlay?.hideKeyboard()\n'
        '\n'
        '                    resetTabs()\n'
        '                    formatContainer?.visibility = View.VISIBLE\n'
        '                    btnFormat.setColorFilter(getColor(R.color.colorPrimary))\n'
        '                    syncStyleButtons()\n'
        '                }\n'
        '\n'
        '                btnBackground?.setBounceClickListener {\n'
        '                    draggableTextOverlay?.hideKeyboard()\n'
        '\n'
        '                    resetTabs()\n'
        '                    bgContainer?.visibility = View.VISIBLE\n'
        '                    btnBackground.setColorFilter(getColor(R.color.colorPrimary))\n'
        '                    setupBgColorPicker(toolbar)\n'
        '                    syncBgSliders()\n'
        '                }')
    s = sub1(s, pat, NEW, 'A4 style/bg wiring')
    print('   [ok]   A4: style toggles + bg sliders + Background tab handler wired')

# A5a: enterTextEditingMode keeps edited op color
if 'if (isReEditing) (draggableTextOverlay?.getTextColor()' not in s:
    OLD = '        selectedTextColor = "#FFFFFF"'
    if s.count(OLD) != 1:
        print('   [FAIL] A5a anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, '        selectedTextColor = if (isReEditing) (draggableTextOverlay?.getTextColor() ?: "#FFFFFF") else "#FFFFFF"', 1)
    print('   [ok]   A5a: re-edit keeps the text color')

# A5b: enterTextEditingMode resets Format/Background tabs too
if 'toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)?.setColorFilter(getColor(R.color.toolTextInactive))' not in s:
    OLD = ('            toolbar.findViewById<View>(R.id.colorPickerContainer)?.visibility = View.GONE\n'
           '            toolbar.findViewById<ImageButton>(R.id.btnTextKeyboardTab)?.setColorFilter(getColor(R.color.colorPrimary))\n'
           '            toolbar.findViewById<ImageButton>(R.id.btnTextPaletteTab)?.setColorFilter(getColor(R.color.toolTextInactive))')
    NEW = ('            toolbar.findViewById<View>(R.id.colorPickerContainer)?.visibility = View.GONE\n'
           '            toolbar.findViewById<View>(R.id.formatSettingsContainer)?.visibility = View.GONE\n'
           '            toolbar.findViewById<View>(R.id.bgSettingsContainer)?.visibility = View.GONE\n'
           '            toolbar.findViewById<ImageButton>(R.id.btnTextKeyboardTab)?.setColorFilter(getColor(R.color.colorPrimary))\n'
           '            toolbar.findViewById<ImageButton>(R.id.btnTextPaletteTab)?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '            toolbar.findViewById<ImageButton>(R.id.btnTextFormatTab)?.setColorFilter(getColor(R.color.toolTextInactive))\n'
           '            toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)?.setColorFilter(getColor(R.color.toolTextInactive))')
    if s.count(OLD) != 1:
        print('   [FAIL] A5b anchor mismatch')
        sys.exit(1)
    s = s.replace(OLD, NEW, 1)
    print('   [ok]   A5b: all tabs reset on edit-mode entry')

# A6: Draw-style palette (custom circle first) replacing the old color picker
if 'buildTextPaletteRow' not in s:
    pat = (re.escape('    private val colorsList = listOf(') +
           r'.*?' + re.escape('colorPickerList.addView(colorView)\n        }\n    }'))
    NEW = (
        '    private val textPalettePresets = listOf(\n'
        '        "#FFFFFF", "#000000", "#FF007A", "#FF3B30",\n'
        '        "#FF9500", "#FFCC00", "#34C759", "#32ADE6",\n'
        '        "#007AFF", "#AF52DE"\n'
        '    )\n'
        '    private var selectedTextColor = "#FFFFFF"\n'
        '\n'
        '    private fun markPaletteSelection(container: LinearLayout, selectedTag: String?) {\n'
        '        for (i in 0 until container.childCount) {\n'
        '            val child = container.getChildAt(i) as? FrameLayout ?: continue\n'
        '            val tagHex = child.tag as? String\n'
        '            if (tagHex != null && tagHex == selectedTag) {\n'
        '                child.setBackgroundResource(R.drawable.bg_aspect_ratio_selected)\n'
        '                child.foreground = androidx.core.content.ContextCompat.getDrawable(this, R.drawable.bg_transition_border_selected)\n'
        '            } else {\n'
        '                child.setBackgroundResource(R.drawable.bg_aspect_ratio_item)\n'
        '                child.foreground = null\n'
        '            }\n'
        '        }\n'
        '    }\n'
        '\n'
        '    private fun buildTextPaletteRow(\n'
        '        container: LinearLayout,\n'
        '        includeNone: Boolean,\n'
        '        selectedHex: String?,\n'
        '        onPick: (String?) -> Unit\n'
        '    ) {\n'
        '        container.removeAllViews()\n'
        '        val density = resources.displayMetrics.density\n'
        '        val swatchSize = (36 * density).toInt()\n'
        '        val innerSize = (24 * density).toInt()\n'
        '        val margin = (4 * density).toInt()\n'
        '\n'
        '        var selectedTag: String? = null\n'
        '        if (includeNone && selectedHex == null) selectedTag = "__none__"\n'
        '        if (selectedHex != null && !textPalettePresets.contains(selectedHex)) selectedTag = "__custom__"\n'
        '        if (selectedHex != null && textPalettePresets.contains(selectedHex)) selectedTag = selectedHex\n'
        '\n'
        '        if (includeNone) {\n'
        '            val frame = FrameLayout(this).apply {\n'
        '                layoutParams = LinearLayout.LayoutParams(swatchSize, swatchSize).apply {\n'
        '                    setMargins(margin, 0, margin, 0)\n'
        '                }\n'
        '                tag = "__none__"\n'
        '                setBackgroundResource(R.drawable.bg_aspect_ratio_item)\n'
        '                isClickable = true\n'
        '                isFocusable = true\n'
        '            }\n'
        '            val circle = View(this).apply {\n'
        '                layoutParams = FrameLayout.LayoutParams(innerSize, innerSize, Gravity.CENTER)\n'
        '                background = android.graphics.drawable.GradientDrawable().apply {\n'
        '                    shape = android.graphics.drawable.GradientDrawable.OVAL\n'
        '                    setStroke((1 * density).toInt(), Color.parseColor("#66FFFFFF"))\n'
        '                }\n'
        '            }\n'
        '            frame.addView(circle)\n'
        '            val mark = android.widget.ImageView(this).apply {\n'
        '                layoutParams = FrameLayout.LayoutParams((12 * density).toInt(), (12 * density).toInt(), Gravity.CENTER)\n'
        '                setImageResource(R.drawable.ic_close_24)\n'
        '                setColorFilter(getColor(R.color.iconSecondary))\n'
        '            }\n'
        '            frame.addView(mark)\n'
        '            frame.setOnClickListener { onPick(null) }\n'
        '            container.addView(frame)\n'
        '        }\n'
        '\n'
        '        // Custom color circle (opens the HSV picker, Draw-page style)\n'
        '        run {\n'
        '            val frame = FrameLayout(this).apply {\n'
        '                layoutParams = LinearLayout.LayoutParams(swatchSize, swatchSize).apply {\n'
        '                    setMargins(margin, 0, margin, 0)\n'
        '                }\n'
        '                tag = "__custom__"\n'
        '                setBackgroundResource(R.drawable.bg_aspect_ratio_item)\n'
        '                isClickable = true\n'
        '                isFocusable = true\n'
        '            }\n'
        '            val circle = View(this).apply {\n'
        '                layoutParams = FrameLayout.LayoutParams(innerSize, innerSize, Gravity.CENTER)\n'
        '                background = android.graphics.drawable.GradientDrawable().apply {\n'
        '                    shape = android.graphics.drawable.GradientDrawable.OVAL\n'
        '                    val customActive = selectedHex != null && !textPalettePresets.contains(selectedHex)\n'
        '                    if (customActive) {\n'
        '                        setColor(try { Color.parseColor(selectedHex) } catch (e: Exception) { Color.WHITE })\n'
        '                    }\n'
        '                    setStroke((1 * density).toInt(), Color.parseColor("#44FFFFFF"))\n'
        '                }\n'
        '            }\n'
        '            frame.addView(circle)\n'
        '            val icon = android.widget.ImageView(this).apply {\n'
        '                layoutParams = FrameLayout.LayoutParams((13 * density).toInt(), (13 * density).toInt(), Gravity.CENTER)\n'
        '                setImageResource(R.drawable.ic_palette_24)\n'
        '                setColorFilter(getColor(R.color.textColor))\n'
        '            }\n'
        '            frame.addView(icon)\n'
        '            frame.setOnClickListener {\n'
        '                val initial = if (selectedHex != null && !textPalettePresets.contains(selectedHex)) selectedHex else "#FFFFFF"\n'
        '                showCustomColorPicker(initial) { customHex -> onPick(customHex) }\n'
        '            }\n'
        '            container.addView(frame)\n'
        '        }\n'
        '\n'
        '        for (hex in textPalettePresets) {\n'
        '            val frame = FrameLayout(this).apply {\n'
        '                layoutParams = LinearLayout.LayoutParams(swatchSize, swatchSize).apply {\n'
        '                    setMargins(margin, 0, margin, 0)\n'
        '                }\n'
        '                tag = hex\n'
        '                setBackgroundResource(R.drawable.bg_aspect_ratio_item)\n'
        '                isClickable = true\n'
        '                isFocusable = true\n'
        '            }\n'
        '            val circleView = View(this).apply {\n'
        '                layoutParams = FrameLayout.LayoutParams(innerSize, innerSize, Gravity.CENTER)\n'
        '                val drawable = android.graphics.drawable.GradientDrawable().apply {\n'
        '                    shape = android.graphics.drawable.GradientDrawable.OVAL\n'
        '                    setColor(try { Color.parseColor(hex) } catch (e: Exception) { Color.WHITE })\n'
        '                    setStroke((1 * density).toInt(), Color.parseColor("#44FFFFFF"))\n'
        '                }\n'
        '                background = drawable\n'
        '            }\n'
        '            frame.addView(circleView)\n'
        '            frame.setOnClickListener { onPick(hex) }\n'
        '            container.addView(frame)\n'
        '        }\n'
        '\n'
        '        markPaletteSelection(container, selectedTag)\n'
        '    }\n'
        '\n'
        '    private fun setupColorPicker(toolbar: View) {\n'
        '        val colorPickerList = toolbar.findViewById<LinearLayout>(R.id.colorPickerList) ?: return\n'
        '        buildTextPaletteRow(colorPickerList, includeNone = false, selectedHex = selectedTextColor) { hex ->\n'
        '            selectedTextColor = hex ?: "#FFFFFF"\n'
        '            draggableTextOverlay?.setTextColor(selectedTextColor)\n'
        '            setupColorPicker(toolbar)\n'
        '        }\n'
        '    }\n'
        '\n'
        '    private fun setupBgColorPicker(toolbar: View) {\n'
        '        val list = toolbar.findViewById<LinearLayout>(R.id.bgColorPickerList) ?: return\n'
        '        buildTextPaletteRow(list, includeNone = true, selectedHex = draggableTextOverlay?.getBgColor()) { hex ->\n'
        '            draggableTextOverlay?.setBgColor(hex)\n'
        '            setupBgColorPicker(toolbar)\n'
        '        }\n'
        '    }')
    s = sub1(s, pat, NEW, 'A6 palette rewrite')
    print('   [ok]   A6: Draw-style palette (custom first) + bg palette installed')

open(p, 'w', encoding='utf-8', newline='').write(s)
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  VERIFICATION
# ---------------------------------------------------------------------------
verify_all() {
  echo "== verify"
  python3 - <<'CUTPY'
import glob, os, re, sys
import xml.etree.ElementTree as ET

bad = 0
def fail(msg):
    global bad
    bad += 1
    print('   [FAIL] ' + msg)

PKG = 'app/src/main/java/com/tharunbirla/librecuts'

# 1) XML validity
xmls = ['app/src/main/res/layout/text_editing_toolbar.xml',
        'app/src/main/res/layout/text_format_settings.xml',
        'app/src/main/res/layout/text_background_settings.xml',
        'app/src/main/res/drawable/ic_text_bg_24.xml',
        'app/src/main/AndroidManifest.xml'] + sorted(glob.glob('app/src/main/res/values*/*.xml'))
for f in xmls:
    try:
        ET.parse(f)
    except Exception as e:
        fail('XML %s: %s' % (f, e))
print('   [ok]   XML valid (%d files)' % len(xmls))

# 2) Kotlin brace/paren balance via a real state-machine lexer
#    (handles // and /* */ comments, "..", ".."".."" raw strings, 'c' literals
#     and backslash escapes -- regex stripping produces false positives)
def strip_kotlin(src):
    out = []
    i, n = 0, len(src)
    NORMAL, LINE_C, BLOCK_C, STR, RAW, CHAR = range(6)
    st = NORMAL
    while i < n:
        c = src[i]
        two = src[i:i+2]
        if st == NORMAL:
            if two == '//':
                st = LINE_C; i += 2; continue
            if two == '/*':
                st = BLOCK_C; i += 2; continue
            if src[i:i+3] == '"""':
                st = RAW; i += 3; out.append(' '); continue
            if c == '"':
                st = STR; i += 1; out.append(' '); continue
            if c == "'":
                st = CHAR; i += 1; out.append(' '); continue
            out.append(c); i += 1
        elif st == LINE_C:
            if c == '\n':
                st = NORMAL; out.append('\n')
            i += 1
        elif st == BLOCK_C:
            if two == '*/':
                st = NORMAL; i += 2; continue
            if c == '\n':
                out.append('\n')
            i += 1
        elif st == STR:
            if c == '\\':
                i += 2; continue
            if c == '"':
                st = NORMAL
            if c == '\n':
                out.append('\n')
            i += 1
        elif st == RAW:
            if src[i:i+3] == '"""':
                st = NORMAL; i += 3; continue
            if c == '\n':
                out.append('\n')
            i += 1
        else:  # CHAR
            if c == '\\':
                i += 2; continue
            if c == "'":
                st = NORMAL
            if c == '\n':
                st = NORMAL; out.append('\n')
            i += 1
    return ''.join(out)

def balanced(path):
    s = strip_kotlin(open(path, encoding='utf-8').read())
    for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
        if s.count(a) != s.count(b):
            return '%s unbalanced (%d vs %d)' % (a, s.count(a), s.count(b))
    return None

for f in ['models/EditOperation.kt', 'customviews/TextOverlayView.kt',
          'customviews/DraggableTextOverlayView.kt', 'viewmodels/VideoEditingViewModel.kt',
          'viewmodels/VideoEditingViewModelExt.kt', 'VideoEditingActivity.kt',
          'utils/TextRenderUtils.kt']:
    r = balanced(PKG + '/' + f)
    if r:
        fail('%s: %s' % (f, r))
print('   [ok]   Kotlin braces/parens balanced (7 files)')

# 3) R.id cross-check
toolbar = open('app/src/main/res/layout/text_editing_toolbar.xml', encoding='utf-8').read()
fmt = open('app/src/main/res/layout/text_format_settings.xml', encoding='utf-8').read()
bgl = open('app/src/main/res/layout/text_background_settings.xml', encoding='utf-8').read()
act = open(PKG + '/VideoEditingActivity.kt', encoding='utf-8').read()
defined = set(re.findall(r'\+id/(\w+)', toolbar)) | set(re.findall(r'\+id/(\w+)', fmt)) | set(re.findall(r'\+id/(\w+)', bgl))
need = ['btnTextBackgroundTab', 'bgSettingsContainer', 'bgColorPickerList',
        'seekBgOpacity', 'seekBgCornerRadius', 'seekBgMargin',
        'btnStyleBold', 'btnStyleItalic', 'btnStyleUnderline', 'btnStyleStrike']
for i in need:
    if i not in defined:
        fail('id %s missing from layouts' % i)
    if ('R.id.' + i) not in act:
        fail('id %s not wired in Activity' % i)
print('   [ok]   R.id cross-check (%d ids verified)' % len(need))

# 4) key markers
eop = open(PKG + '/models/EditOperation.kt', encoding='utf-8').read()
tov = open(PKG + '/customviews/TextOverlayView.kt', encoding='utf-8').read()
drg = open(PKG + '/customviews/DraggableTextOverlayView.kt', encoding='utf-8').read()
vm = open(PKG + '/viewmodels/VideoEditingViewModel.kt', encoding='utf-8').read()
vme = open(PKG + '/viewmodels/VideoEditingViewModelExt.kt', encoding='utf-8').read()
tru = open(PKG + '/utils/TextRenderUtils.kt', encoding='utf-8').read()
checks = [
    ('AddText bgMargin field', 'val bgMargin: Int = 0,' in eop),
    ('AddText bold field', 'val bold: Boolean = false,' in eop),
    ('TextRenderUtils renders PNG', 'fun renderAddTextToPng' in tru),
    ('preview uses shared paint', 'TextRenderUtils.configPaint' in tov),
    ('preview draws bg block', 'TextRenderUtils.drawBlock' in tov),
    ('draggable has setters', 'fun setBgMargin(' in drg and 'fun setBold(' in drg),
    ('draggable commit passes state', ('currentBgMargin\n            )' in drg or 'currentShadowWidth\n            )' in drg)),
    ('VM renderer property', 'var textPngRenderer' in vm),
    ('VM overlay stages', 'WYSIWYG path: canvas-rendered PNG' in vm),
    ('VM text input section', '// 4b. Text Overlay PNG Inputs' in vm),
    ('VM call sites pass indices', vm.count('textInputIndices = textInputIndices,') == 2),
    ('VM drawtext fallback kept', 'Fallback: classic drawtext filter' in vm),
    ('Ext addTextOperation params', 'bgMargin: Int = 0' in vme),
    ('Activity renderer hook', 'viewModel.textPngRenderer = { op ->' in act),
    ('Activity palette builder', 'buildTextPaletteRow' in act),
    ('Activity bg palette', 'setupBgColorPicker' in act),
    ('Activity style toggles', 'btnStyleBold' in act),
    ('Activity background tab', 'btnTextBackgroundTab' in act),
    ('Activity commit extended', 'bgCornerRadius = bgCornerRadius' in act),
    ('toolbar has background tab', 'btnTextBackgroundTab' in toolbar),
    ('toolbar includes bg panel', 'text_background_settings' in toolbar),
    ('format has style row', 'btnStyleStrike' in fmt),
]
for name, ok in checks:
    if not ok:
        fail(name)
print('   [ok]   markers: ' + str(sum(1 for _, o in checks if o)) + '/' + str(len(checks)))

if bad:
    print('VERIFY FAILED (%d problem(s))' % bad)
    sys.exit(1)
print('VERIFY OK')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# --- R6 STEPS BEGIN -------------------------------------------------------

# R6-specific paths (PKG / TOOLBAR / FMT / EOP / TOV / DRG / VME / ACT are
# already defined above; these extras travel with the round 6 functions
# when they are embedded into the combined pipeline script).
TRU="$PKG/utils/TextRenderUtils.kt"
STROKE_L="app/src/main/res/layout/text_stroke_settings.xml"
SHADOW_L="app/src/main/res/layout/text_shadow_settings.xml"
AVEL="app/src/main/res/layout/activity_video_editing.xml"
DRAW="app/src/main/res/drawable"

r6_precheck() {
  echo "== r6 pre-check"
  if [ ! -f "$TRU" ]; then
    echo "ABORT: TextRenderUtils.kt not found (round 5 state required)."
    return 1
  fi
  if [ ! -f "$TOOLBAR" ]; then
    echo "ABORT: text_editing_toolbar.xml not found."
    return 1
  fi
  echo "   [ok] round 5 text tool state present"
}

# ---------------------------------------------------------------------------
#  R6 STEP 1 -- NEW resource files
# ---------------------------------------------------------------------------
r6_step1() {
  echo "== r6 step 1: new resource files (stroke/shadow panels, icons, capsule)"

  if [ -f "$STROKE_L" ]; then
    echo "   [skip] text_stroke_settings.xml exists"
  else
    cat > "$STROKE_L" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:orientation="vertical"
    android:padding="16dp"
    android:background="@drawable/bg_bottom_nav_floating"
    android:elevation="12dp"
    android:layout_marginHorizontal="16dp"
    android:layout_marginBottom="8dp">

    <!-- Stroke Color -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Color"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <HorizontalScrollView
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:scrollbars="none"
            android:requiresFadingEdge="horizontal"
            android:fadingEdgeLength="16dp">
            <LinearLayout
                android:id="@+id/strokeColorPickerList"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:orientation="horizontal"
                android:gravity="center_vertical" />
        </HorizontalScrollView>
    </LinearLayout>

    <!-- Transparency -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Transparency"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekStrokeOpacity"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="100"
            android:stepSize="1"
            android:value="100" />
    </LinearLayout>

    <!-- Width -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Width"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekStrokeWidth"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="20"
            android:stepSize="1"
            android:value="0" />
    </LinearLayout>

</LinearLayout>
XMLEOF
    echo "   [ok]   text_stroke_settings.xml written"
  fi

  if [ -f "$SHADOW_L" ]; then
    echo "   [skip] text_shadow_settings.xml exists"
  else
    cat > "$SHADOW_L" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="wrap_content"
    android:orientation="vertical"
    android:padding="16dp"
    android:background="@drawable/bg_bottom_nav_floating"
    android:elevation="12dp"
    android:layout_marginHorizontal="16dp"
    android:layout_marginBottom="8dp">

    <!-- Shadow Color -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Color"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <HorizontalScrollView
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:scrollbars="none"
            android:requiresFadingEdge="horizontal"
            android:fadingEdgeLength="16dp">
            <LinearLayout
                android:id="@+id/shadowColorPickerList"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:orientation="horizontal"
                android:gravity="center_vertical" />
        </HorizontalScrollView>
    </LinearLayout>

    <!-- Transparency -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Transparency"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekShadowOpacity"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="100"
            android:stepSize="1"
            android:value="100" />
    </LinearLayout>

    <!-- Blur -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Blur"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekShadowBlur"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="50"
            android:stepSize="1"
            android:value="0" />
    </LinearLayout>

    <!-- Angle -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Angle"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekShadowAngle"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="360"
            android:stepSize="1"
            android:value="0" />
    </LinearLayout>

    <!-- Width -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:layout_marginTop="8dp">
        <TextView
            android:layout_width="100dp"
            android:layout_height="wrap_content"
            android:text="Width"
            android:textColor="#FFFFFF"
            android:textSize="14sp" />
        <com.google.android.material.slider.Slider
            android:id="@+id/seekShadowWidth"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:valueFrom="0"
            android:valueTo="50"
            android:stepSize="1"
            android:value="0" />
    </LinearLayout>

</LinearLayout>
XMLEOF
    echo "   [ok]   text_shadow_settings.xml written"
  fi

  if [ -f "$DRAW/ic_text_stroke_24.xml" ]; then
    echo "   [skip] ic_text_stroke_24.xml exists"
  else
    cat > "$DRAW/ic_text_stroke_24.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FF000000"
        android:fillType="evenOdd"
        android:pathData="M4,4 H20 V9.5 H14.7 V21 H9.3 V9.5 H4 Z M6.2,6.2 H17.8 V7.3 H12.5 V18.8 H11.5 V7.3 H6.2 Z" />
</vector>
XMLEOF
    echo "   [ok]   ic_text_stroke_24.xml written"
  fi

  if [ -f "$DRAW/ic_text_shadow_24.xml" ]; then
    echo "   [skip] ic_text_shadow_24.xml exists"
  else
    cat > "$DRAW/ic_text_shadow_24.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FF000000"
        android:fillAlpha="0.45"
        android:pathData="M10,10 H21 V21 H10 Z" />
    <path
        android:fillColor="#FF000000"
        android:pathData="M4,4 H15 V15 H4 Z" />
</vector>
XMLEOF
    echo "   [ok]   ic_text_shadow_24.xml written"
  fi

  if [ -f "$DRAW/bg_play_pause_capsule.xml" ]; then
    echo "   [skip] bg_play_pause_capsule.xml exists"
  else
    cat > "$DRAW/bg_play_pause_capsule.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="@color/colorPrimary" />
    <corners android:radius="20dp" />
</shape>
XMLEOF
    echo "   [ok]   bg_play_pause_capsule.xml written"
  fi

  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 2 -- text_editing_toolbar.xml: drop Duplicate, add tabs + includes
# ---------------------------------------------------------------------------
r6_step2() {
  echo "== r6 step 2: text toolbar (add Stroke/Shadow tabs, Duplicate kept)"
  python3 - "$TOOLBAR" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'btnTextStrokeTab' in s:
    print('   [skip] toolbar already patched (stroke tab present)')
    sys.exit(0)

# (a) round 7 decision: the Duplicate tool block STAYS in the toolbar

# (b) insert Stroke + Shadow tab entries between Format and Background
TABS = '''            <!-- Stroke Settings -->
            <LinearLayout
                android:layout_width="60dp"
                android:layout_height="wrap_content"
                android:orientation="vertical"
                android:gravity="center">
                <ImageButton
                    android:id="@+id/btnTextStrokeTab"
                    android:layout_width="40dp"
                    android:layout_height="40dp"
                    android:background="@drawable/tool_button_inactive"
                    android:src="@drawable/ic_text_stroke_24"
                    android:padding="8dp"
                    android:scaleType="fitCenter"
                    app:tint="@color/toolTextInactive" />
                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:layout_marginTop="4dp"
                    android:text="Stroke"
                    android:textSize="11sp"
                    android:fontFamily="sans-serif-medium"
                    android:textColor="@color/toolTextInactive" />
            </LinearLayout>

            <!-- Shadow Settings -->
            <LinearLayout
                android:layout_width="60dp"
                android:layout_height="wrap_content"
                android:orientation="vertical"
                android:gravity="center">
                <ImageButton
                    android:id="@+id/btnTextShadowTab"
                    android:layout_width="40dp"
                    android:layout_height="40dp"
                    android:background="@drawable/tool_button_inactive"
                    android:src="@drawable/ic_text_shadow_24"
                    android:padding="8dp"
                    android:scaleType="fitCenter"
                    app:tint="@color/toolTextInactive" />
                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:layout_marginTop="4dp"
                    android:text="Shadow"
                    android:textSize="11sp"
                    android:fontFamily="sans-serif-medium"
                    android:textColor="@color/toolTextInactive" />
            </LinearLayout>

'''
BGMARK = '            <!-- Background Settings -->'
if s.count(BGMARK) != 1:
    print('   [FAIL] background tab marker mismatch (%d)' % s.count(BGMARK))
    sys.exit(1)
s = s.replace(BGMARK, TABS + BGMARK, 1)
print('   [ok]   Stroke + Shadow tabs inserted before Background')

# (c) include the two new settings panels
INCL = '''    <!-- Stroke Settings Container -->
    <include layout="@layout/text_stroke_settings"
        android:id="@+id/strokeSettingsContainer"
        android:visibility="gone" />

    <!-- Shadow Settings Container -->
    <include layout="@layout/text_shadow_settings"
        android:id="@+id/shadowSettingsContainer"
        android:visibility="gone" />

'''
BGInc = '    <!-- Background Settings Container -->\n    <include layout="@layout/text_background_settings"\n        android:id="@+id/bgSettingsContainer"\n        android:visibility="gone" />'
if s.count(BGInc) != 1:
    print('   [FAIL] background include anchor mismatch (%d)' % s.count(BGInc))
    sys.exit(1)
s = s.replace(BGInc, BGInc + '\n\n' + INCL.rstrip('\n'), 1)
print('   [ok]   stroke/shadow panels included')

open(p, 'w', encoding='utf-8', newline='').write(s)
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 3 -- Format tab: remove old Shadow slider; play button -> capsule
# ---------------------------------------------------------------------------
r6_step3() {
  echo "== r6 step 3: format tab shadow slider removal + capsule play button"

  python3 - "$FMT" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'seekBorderWidth' not in s:
    print('   [skip] format tab already without shadow slider')
    sys.exit(0)
a = '    <!-- Border Thickness -->'
b = '    <!-- Letter Spacing -->'
if s.count(a) != 1 or s.count(b) != 1:
    print('   [FAIL] format tab anchors mismatch')
    sys.exit(1)
s = s[:s.index(a)] + s[s.index(b):]
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   shadow slider block removed from Format tab')
CUTPY
  [ $? -ne 0 ] && return 1

  python3 - "$AVEL" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'bg_play_pause_capsule' in s:
    print('   [skip] play button already capsule')
    sys.exit(0)
OLD = '''<ImageButton
                    android:id="@+id/btnPlayPause"
                    android:layout_width="44dp"
                    android:layout_height="44dp"
                    android:background="@drawable/circle_primary_container"
                    android:src="@drawable/ic_play_24"
                    android:padding="10dp"'''
NEW = '''<ImageButton
                    android:id="@+id/btnPlayPause"
                    android:layout_width="72dp"
                    android:layout_height="40dp"
                    android:background="@drawable/bg_play_pause_capsule"
                    android:src="@drawable/ic_play_24"
                    android:padding="8dp"'''
if s.count(OLD) != 1:
    print('   [FAIL] btnPlayPause block mismatch (%d)' % s.count(OLD))
    sys.exit(1)
s = s.replace(OLD, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   play button background -> capsule (72x40dp)')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 4 -- EditOperation.AddText: stroke + shadow fields
# ---------------------------------------------------------------------------
r6_step4() {
  echo "== r6 step 4: AddText data model (stroke/shadow fields)"
  python3 - "$EOP" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
MARK = 'val shadowWidth: Int = 0,'
if MARK in s:
    print('   [skip] AddText shadow fields already present')
    sys.exit(0)
ANCHOR = '        val bgMargin: Int = 0,\n'
if s.count(ANCHOR) != 1:
    print('   [FAIL] AddText bgMargin anchor mismatch (%d)' % s.count(ANCHOR))
    sys.exit(1)
NEW = ANCHOR + (
    '        val strokeOpacity: Float? = null,\n'
    '        val shadowColor: String? = null,\n'
    '        val shadowOpacity: Float = 1.0f,\n'
    '        val shadowBlur: Int = 0,\n'
    '        val shadowAngle: Int = 0,\n'
    '        val shadowWidth: Int = 0,\n')
s = s.replace(ANCHOR, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   AddText: 6 new fields (strokeOpacity nullable = old-project safe)')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 5 -- TextRenderUtils: real shadow + stroke transparency
# ---------------------------------------------------------------------------
r6_step5() {
  echo "== r6 step 5: TextRenderUtils (drop shadow + stroke opacity)"
  python3 - "$TRU" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'shadowDx' in s:
    print('   [skip] TextRenderUtils already patched')
    sys.exit(0)

OLD = '''        // 2. Text lines (optional stroke outline first, then fill)
        for ((index, line) in lines.withIndex()) {
            val lineW = paint.measureText(line)
            val lineX = when (op.textAlign) {
                "left", "L" -> startX
                "right", "R" -> startX + maxTextWidth - lineW
                else -> startX + (maxTextWidth - lineW) / 2f
            }
            val lineY = startY + (index * textHeight)

            if (op.borderThickness > 0) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = op.borderThickness * scale
                paint.strokeJoin = Paint.Join.ROUND
                val borderColorInt = try { Color.parseColor(op.borderColor) } catch (e: Exception) { Color.BLACK }
                val fill = paint.color
                paint.color = Color.argb(
                    Color.alpha(fill),
                    Color.red(borderColorInt), Color.green(borderColorInt), Color.blue(borderColorInt))
                canvas.drawText(line, lineX, lineY, paint)
                paint.style = Paint.Style.FILL
                paint.color = fill
            } else {
                paint.style = Paint.Style.FILL
            }

            canvas.drawText(line, lineX, lineY, paint)
        }
'''
NEW = '''        // 2. Text lines (optional stroke outline first, then fill).
        //    Round 6: the stroke honors its own transparency, and a real
        //    drop shadow (color / transparency / blur / angle / width) is
        //    drawn under the widest pass only -- the stroke pass when a
        //    stroke exists, otherwise the fill pass -- so the shadow
        //    always matches the full glyph silhouette.
        val fillColor = paint.color
        val strokeAlphaFactor = op.strokeOpacity ?: 1.0f
        val shadowOn = op.shadowColor != null && (op.shadowWidth > 0 || op.shadowBlur > 0)
        var shadowDx = 0f
        var shadowDy = 0f
        var shadowArgb = 0
        if (shadowOn) {
            val shHex: String = op.shadowColor ?: "#000000"
            val rad = Math.toRadians(op.shadowAngle.toDouble())
            shadowDx = (op.shadowWidth * Math.cos(rad)).toFloat() * scale
            shadowDy = (op.shadowWidth * Math.sin(rad)).toFloat() * scale
            val shBase = try { Color.parseColor(shHex) } catch (e: Exception) { Color.BLACK }
            val shAlpha = (op.shadowOpacity.coerceIn(0f, 1f) * Color.alpha(fillColor)).toInt().coerceIn(0, 255)
            shadowArgb = Color.argb(shAlpha, Color.red(shBase), Color.green(shBase), Color.blue(shBase))
        }
        for ((index, line) in lines.withIndex()) {
            val lineW = paint.measureText(line)
            val lineX = when (op.textAlign) {
                "left", "L" -> startX
                "right", "R" -> startX + maxTextWidth - lineW
                else -> startX + (maxTextWidth - lineW) / 2f
            }
            val lineY = startY + (index * textHeight)

            if (op.borderThickness > 0) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = op.borderThickness * scale
                paint.strokeJoin = Paint.Join.ROUND
                val borderColorInt = try { Color.parseColor(op.borderColor) } catch (e: Exception) { Color.BLACK }
                val strokeAlpha = (strokeAlphaFactor.coerceIn(0f, 1f) * Color.alpha(fillColor)).toInt().coerceIn(0, 255)
                paint.color = Color.argb(
                    strokeAlpha,
                    Color.red(borderColorInt), Color.green(borderColorInt), Color.blue(borderColorInt))
                if (shadowOn) {
                    paint.setShadowLayer(op.shadowBlur * scale, shadowDx, shadowDy, shadowArgb)
                } else {
                    paint.clearShadowLayer()
                }
                canvas.drawText(line, lineX, lineY, paint)
                paint.style = Paint.Style.FILL
                paint.color = fillColor
                paint.clearShadowLayer()
            } else {
                paint.style = Paint.Style.FILL
                if (shadowOn) {
                    paint.setShadowLayer(op.shadowBlur * scale, shadowDx, shadowDy, shadowArgb)
                } else {
                    paint.clearShadowLayer()
                }
            }

            canvas.drawText(line, lineX, lineY, paint)
        }
        paint.clearShadowLayer()
'''
if s.count(OLD) != 1:
    print('   [FAIL] drawBlock text section anchor mismatch (%d)' % s.count(OLD))
    sys.exit(1)
s = s.replace(OLD, NEW, 1)

OLDPAD = '            val pad = (op.bgMargin + op.borderThickness + 8).coerceAtLeast(8)'
NEWPAD = '            val pad = (op.bgMargin + op.borderThickness + op.shadowWidth + op.shadowBlur + 8).coerceAtLeast(8)'
if s.count(OLDPAD) != 1:
    print('   [FAIL] pad anchor mismatch (%d)' % s.count(OLDPAD))
    sys.exit(1)
s = s.replace(OLDPAD, NEWPAD, 1)

open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   drawBlock: shadow + stroke transparency; PNG pad covers shadow')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 6 -- TextOverlayView: keep subtitle soft shadow
# ---------------------------------------------------------------------------
r6_step6() {
  echo "== r6 step 6: TextOverlayView subtitle shadow restore"
  python3 - "$TOV" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if '// Keep the subtitle' in s:
    print('   [skip] subtitle shadow restore already present')
    sys.exit(0)
OLD = '''            paint.color = Color.WHITE
'''
NEW = '''            paint.color = Color.WHITE
            // Keep the subtitle's original soft drop shadow (drawBlock now
            // clears the shared paint's shadow layer after each text block).
            paint.setShadowLayer(4f, 2f, 2f, Color.BLACK)
'''
if s.count(OLD) != 1:
    print('   [FAIL] subtitle paint anchor mismatch (%d)' % s.count(OLD))
    sys.exit(1)
s = s.replace(OLD, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   subtitle soft shadow preserved')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 7 -- DraggableTextOverlayView: stroke/shadow state + preview
# ---------------------------------------------------------------------------
r6_step7() {
  echo "== r6 step 7: DraggableTextOverlayView stroke/shadow support"
  python3 - "$DRG" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'fun refreshTextEffects()' in s:
    print('   [skip] draggable overlay already patched')
    sys.exit(0)

def req(old, cnt=1):
    if s.count(old) != cnt:
        print('   [FAIL] anchor mismatch (%d): %r' % (s.count(old), old[:60]))
        sys.exit(1)

# D1 -- callback signature
OLD = 'bgCornerRadius: Int, bgMargin: Int) -> Unit)? = null'
req(OLD)
NEW = ('bgCornerRadius: Int, bgMargin: Int, strokeOpacity: Float, shadowColor: String?, '
       'shadowOpacity: Float, shadowBlur: Int, shadowAngle: Int, shadowWidth: Int) -> Unit)? = null')
s = s.replace(OLD, NEW, 1)

# D2 -- state fields
OLD = '    private var currentBgMargin = 0\n'
req(OLD)
NEW = OLD + (
    '    private var currentStrokeOpacity = 1.0f\n'
    '    private var currentShadowColor: String? = null\n'
    '    private var currentShadowOpacity = 1.0f\n'
    '    private var currentShadowBlur = 0\n'
    '    private var currentShadowAngle = 0\n'
    '    private var currentShadowWidth = 0\n')
s = s.replace(OLD, NEW, 1)

# D3 -- activate() defaults
OLD = '        currentBgMargin = 0\n'
req(OLD)
NEW = OLD + (
    '        currentStrokeOpacity = 1.0f\n'
    '        currentShadowColor = null\n'
    '        currentShadowOpacity = 1.0f\n'
    '        currentShadowBlur = 0\n'
    '        currentShadowAngle = 0\n'
    '        currentShadowWidth = 0\n')
s = s.replace(OLD, NEW, 1)

OLD = '        applyTypefaceAndFlags()\n        refreshEditTextBackground()\n'
req(OLD)
NEW = OLD + '        refreshTextEffects()\n'
s = s.replace(OLD, NEW, 1)

# D4 -- activateForEdit() state load
OLD = '        currentBgMargin = op.bgMargin\n'
req(OLD)
NEW = OLD + (
    '        currentStrokeOpacity = op.strokeOpacity ?: 1.0f\n'
    '        currentShadowColor = op.shadowColor\n'
    '        currentShadowOpacity = op.shadowOpacity\n'
    '        currentShadowBlur = op.shadowBlur\n'
    '        currentShadowAngle = op.shadowAngle\n'
    '        currentShadowWidth = op.shadowWidth\n')
s = s.replace(OLD, NEW, 1)

OLD = '        visibility = VISIBLE\n        refreshEditTextBackground()\n'
req(OLD)
NEW = OLD + '        refreshTextEffects()\n'
s = s.replace(OLD, NEW, 1)

# D5 -- commitText() passes the new state
OLD = 'currentBgOpacity, currentBgCornerRadius, currentBgMargin\n            )'
req(OLD)
NEW = ('currentBgOpacity, currentBgCornerRadius, currentBgMargin,\n'
       '                currentStrokeOpacity, currentShadowColor, currentShadowOpacity, '
       'currentShadowBlur, currentShadowAngle, currentShadowWidth\n            )')
s = s.replace(OLD, NEW, 1)

# D6 -- replace setBorderThickness with stroke/shadow setters + preview
OLD = '''    fun setBorderThickness(thickness: Int) {
        currentBorderThickness = thickness.coerceAtLeast(0)
        val borderColor = try {
            Color.parseColor(currentBorderColor)
        } catch (e: Exception) {
            Color.BLACK
        }

        if (currentBorderThickness > 0) {
            editText.setShadowLayer((currentBorderThickness * 1.2f).coerceAtLeast(1f), 0f, 0f, borderColor)
        } else {
            editText.setShadowLayer(4f, 2f, 2f, Color.BLACK)
        }
    }
'''
req(OLD)
NEW = '''    // -- Stroke + shadow setters (CutStudio round 6) --
    fun setStrokeColor(hex: String) { currentBorderColor = hex; refreshTextEffects() }
    fun setStrokeOpacity(value: Float) { currentStrokeOpacity = value.coerceIn(0f, 1f); refreshTextEffects() }
    fun setStrokeWidth(width: Int) { currentBorderThickness = width.coerceAtLeast(0); refreshTextEffects() }
    fun setShadowColor(hex: String?) { currentShadowColor = hex; refreshTextEffects() }
    fun setShadowOpacity(value: Float) { currentShadowOpacity = value.coerceIn(0f, 1f); refreshTextEffects() }
    fun setShadowBlur(value: Int) { currentShadowBlur = value.coerceAtLeast(0); refreshTextEffects() }
    fun setShadowAngle(value: Int) { currentShadowAngle = value.coerceIn(0, 360); refreshTextEffects() }
    fun setShadowWidth(value: Int) { currentShadowWidth = value.coerceAtLeast(0); refreshTextEffects() }

    fun getStrokeColor(): String = currentBorderColor
    fun getStrokeOpacity(): Float = currentStrokeOpacity
    fun getStrokeWidth(): Int = currentBorderThickness
    fun getShadowColor(): String? = currentShadowColor
    fun getShadowOpacity(): Float = currentShadowOpacity
    fun getShadowBlur(): Int = currentShadowBlur
    fun getShadowAngle(): Int = currentShadowAngle
    fun getShadowWidth(): Int = currentShadowWidth

    /**
     * Live preview on the EditText (only one shadow layer is possible).
     * Stroke wins over shadow while both are active; the committed render
     * in TextRenderUtils draws both of them exactly.
     */
    private fun refreshTextEffects() {
        val shadowHex = currentShadowColor
        if (currentBorderThickness > 0) {
            val c = try { Color.parseColor(currentBorderColor) } catch (e: Exception) { Color.BLACK }
            val a = (currentStrokeOpacity.coerceIn(0f, 1f) * 255).toInt().coerceIn(0, 255)
            editText.setShadowLayer((currentBorderThickness * 1.2f).coerceAtLeast(1f), 0f, 0f,
                Color.argb(a, Color.red(c), Color.green(c), Color.blue(c)))
        } else if (shadowHex != null && (currentShadowWidth > 0 || currentShadowBlur > 0)) {
            val c = try { Color.parseColor(shadowHex) } catch (e: Exception) { Color.BLACK }
            val a = (currentShadowOpacity.coerceIn(0f, 1f) * 255).toInt().coerceIn(0, 255)
            val rad = Math.toRadians(currentShadowAngle.toDouble())
            val dx = (currentShadowWidth * Math.cos(rad)).toFloat()
            val dy = (currentShadowWidth * Math.sin(rad)).toFloat()
            editText.setShadowLayer(currentShadowBlur.toFloat(), dx, dy,
                Color.argb(a, Color.red(c), Color.green(c), Color.blue(c)))
        } else {
            editText.setShadowLayer(4f, 2f, 2f, Color.BLACK)
        }
    }
'''
s = s.replace(OLD, NEW, 1)

open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   stroke/shadow setters + live preview + commit state')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 8 -- ViewModelExt.addTextOperation: new params
# ---------------------------------------------------------------------------
r6_step8() {
  echo "== r6 step 8: addTextOperation signature (stroke/shadow)"
  python3 - "$VME" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'shadowWidth: Int = 0' in s:
    print('   [skip] addTextOperation already extended')
    sys.exit(0)

OLD = '    bgCornerRadius: Int = 0, bgMargin: Int = 0\n) {'
if s.count(OLD) != 1:
    print('   [FAIL] addTextOperation signature anchor mismatch (%d)' % s.count(OLD))
    sys.exit(1)
NEW = ('    bgCornerRadius: Int = 0, bgMargin: Int = 0,\n'
       '    strokeOpacity: Float = 1.0f, shadowColor: String? = null, shadowOpacity: Float = 1.0f,\n'
       '    shadowBlur: Int = 0, shadowAngle: Int = 0, shadowWidth: Int = 0\n) {')
s = s.replace(OLD, NEW, 1)

OLD = '        bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin\n    ), "Add Text"))'
if s.count(OLD) != 1:
    print('   [FAIL] AddText ctor anchor mismatch (%d)' % s.count(OLD))
    sys.exit(1)
NEW = ('        bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin,\n'
       '        strokeOpacity = strokeOpacity, shadowColor = shadowColor, shadowOpacity = shadowOpacity,\n'
       '        shadowBlur = shadowBlur, shadowAngle = shadowAngle, shadowWidth = shadowWidth\n    ), "Add Text"))')
s = s.replace(OLD, NEW, 1)

open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   addTextOperation + AddText ctor pass stroke/shadow state')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 STEP 9 -- VideoEditingActivity: wiring
# ---------------------------------------------------------------------------
r6_step9() {
  echo "== r6 step 9: Activity wiring (tabs, sliders, palettes, commit, cleanup)"
  python3 - "$ACT" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if 'setupShadowColorPicker' in s:
    print('   [skip] Activity already patched for round 6')
    sys.exit(0)

def req(old):
    if s.count(old) != 1:
        print('   [FAIL] anchor mismatch (%d): %r' % (s.count(old), old[:70]))
        sys.exit(1)
    return old

# A1 -- onTextCommitted lambda parameters
OLD = req('bgCornerRadius, bgMargin ->')
NEW = 'bgCornerRadius, bgMargin, strokeOpacity, shadowColor, shadowOpacity, shadowBlur, shadowAngle, shadowWidth ->'
s = s.replace(OLD, NEW, 1)

# A2 -- update branch: op.copy(...)
OLD = req('''                                    bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin
                                ))''')
NEW = '''                                    bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin,
                                    strokeOpacity = strokeOpacity, shadowColor = shadowColor, shadowOpacity = shadowOpacity,
                                    shadowBlur = shadowBlur, shadowAngle = shadowAngle, shadowWidth = shadowWidth
                                ))'''
s = s.replace(OLD, NEW, 1)

# A3 -- new-text branch: addTextOperation(...)
OLD = req('''                            bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin
                        )''')
NEW = '''                            bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin,
                            strokeOpacity = strokeOpacity, shadowColor = shadowColor, shadowOpacity = shadowOpacity,
                            shadowBlur = shadowBlur, shadowAngle = shadowAngle, shadowWidth = shadowWidth
                        )'''
s = s.replace(OLD, NEW, 1)

# A4 -- round 7 decision: the text Duplicate wiring STAYS

# A5 -- tab + container view references
OLD = req('''                val btnBackground = toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)
                val colorContainer = toolbar.findViewById<View>(R.id.colorPickerContainer)
                val formatContainer = toolbar.findViewById<View>(R.id.formatSettingsContainer)
                val bgContainer = toolbar.findViewById<View>(R.id.bgSettingsContainer)''')
NEW = '''                val btnStroke = toolbar.findViewById<ImageButton>(R.id.btnTextStrokeTab)
                val btnShadow = toolbar.findViewById<ImageButton>(R.id.btnTextShadowTab)
                val btnBackground = toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)
                val colorContainer = toolbar.findViewById<View>(R.id.colorPickerContainer)
                val formatContainer = toolbar.findViewById<View>(R.id.formatSettingsContainer)
                val strokeContainer = toolbar.findViewById<View>(R.id.strokeSettingsContainer)
                val shadowContainer = toolbar.findViewById<View>(R.id.shadowSettingsContainer)
                val bgContainer = toolbar.findViewById<View>(R.id.bgSettingsContainer)'''
s = s.replace(OLD, NEW, 1)

# A6 -- resetTabs()
OLD = req('''                fun resetTabs() {
                    colorContainer?.visibility = View.GONE
                    formatContainer?.visibility = View.GONE
                    bgContainer?.visibility = View.GONE
                    btnKeyboard?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnPalette?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnFormat?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnBackground?.setColorFilter(getColor(R.color.toolTextInactive))
                }''')
NEW = '''                fun resetTabs() {
                    colorContainer?.visibility = View.GONE
                    formatContainer?.visibility = View.GONE
                    strokeContainer?.visibility = View.GONE
                    shadowContainer?.visibility = View.GONE
                    bgContainer?.visibility = View.GONE
                    btnKeyboard?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnPalette?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnFormat?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnStroke?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnShadow?.setColorFilter(getColor(R.color.toolTextInactive))
                    btnBackground?.setColorFilter(getColor(R.color.toolTextInactive))
                }'''
s = s.replace(OLD, NEW, 1)

# A7a -- stroke/shadow slider sync + listeners (before the Format tab handler)
OLD = req('                btnFormat?.setBounceClickListener {')
NEW = '''                // Stroke tab sliders
                fun syncStrokeSliders() {
                    val textOverlay = draggableTextOverlay ?: return
                    strokeContainer?.findViewById<Slider>(R.id.seekStrokeOpacity)?.value =
                        (textOverlay.getStrokeOpacity() * 100f).coerceIn(0f, 100f)
                    strokeContainer?.findViewById<Slider>(R.id.seekStrokeWidth)?.value =
                        textOverlay.getStrokeWidth().toFloat().coerceIn(0f, 20f)
                }
                strokeContainer?.findViewById<Slider>(R.id.seekStrokeOpacity)?.addOnChangeListener { _, value, _ ->
                    draggableTextOverlay?.setStrokeOpacity(value / 100f)
                }
                strokeContainer?.findViewById<Slider>(R.id.seekStrokeWidth)?.addOnChangeListener { _, value, _ ->
                    draggableTextOverlay?.setStrokeWidth(value.toInt())
                }

                // Shadow tab sliders
                fun syncShadowSliders() {
                    val textOverlay = draggableTextOverlay ?: return
                    shadowContainer?.findViewById<Slider>(R.id.seekShadowOpacity)?.value =
                        (textOverlay.getShadowOpacity() * 100f).coerceIn(0f, 100f)
                    shadowContainer?.findViewById<Slider>(R.id.seekShadowBlur)?.value =
                        textOverlay.getShadowBlur().toFloat().coerceIn(0f, 50f)
                    shadowContainer?.findViewById<Slider>(R.id.seekShadowAngle)?.value =
                        textOverlay.getShadowAngle().toFloat().coerceIn(0f, 360f)
                    shadowContainer?.findViewById<Slider>(R.id.seekShadowWidth)?.value =
                        textOverlay.getShadowWidth().toFloat().coerceIn(0f, 50f)
                }
                shadowContainer?.findViewById<Slider>(R.id.seekShadowOpacity)?.addOnChangeListener { _, value, _ ->
                    draggableTextOverlay?.setShadowOpacity(value / 100f)
                }
                shadowContainer?.findViewById<Slider>(R.id.seekShadowBlur)?.addOnChangeListener { _, value, _ ->
                    draggableTextOverlay?.setShadowBlur(value.toInt())
                }
                shadowContainer?.findViewById<Slider>(R.id.seekShadowAngle)?.addOnChangeListener { _, value, _ ->
                    draggableTextOverlay?.setShadowAngle(value.toInt())
                }
                shadowContainer?.findViewById<Slider>(R.id.seekShadowWidth)?.addOnChangeListener { _, value, _ ->
                    draggableTextOverlay?.setShadowWidth(value.toInt())
                }

                btnFormat?.setBounceClickListener {'''
s = s.replace(OLD, NEW, 1)

# A7b -- stroke/shadow tab click handlers (after the Background handler)
OLD = req('''                    setupBgColorPicker(toolbar)
                    syncBgSliders()
                }''')
NEW = '''                    setupBgColorPicker(toolbar)
                    syncBgSliders()
                }

                btnStroke?.setBounceClickListener {
                    draggableTextOverlay?.hideKeyboard()

                    resetTabs()
                    strokeContainer?.visibility = View.VISIBLE
                    btnStroke.setColorFilter(getColor(R.color.colorPrimary))
                    setupStrokeColorPicker(toolbar)
                    syncStrokeSliders()
                }

                btnShadow?.setBounceClickListener {
                    draggableTextOverlay?.hideKeyboard()

                    resetTabs()
                    shadowContainer?.visibility = View.VISIBLE
                    btnShadow.setColorFilter(getColor(R.color.colorPrimary))
                    setupShadowColorPicker(toolbar)
                    syncShadowSliders()
                }'''
s = s.replace(OLD, NEW, 1)

# A8 -- remove the Format tab Shadow slider listener
OLD = req('''                val seekBorderWidth = formatContainer?.findViewById<Slider>(R.id.seekBorderWidth)
                seekBorderWidth?.addOnChangeListener { _, value, _ ->
                    draggableTextOverlay?.setBorderThickness(value.toInt())
                }
''')
s = s.replace(OLD, '', 1)

# A9 -- palette setup functions for stroke/shadow
OLD = req('    private fun updateActiveBoundaries(')
NEW = '''    private fun setupStrokeColorPicker(toolbar: View) {
        val list = toolbar.findViewById<LinearLayout>(R.id.strokeColorPickerList) ?: return
        buildTextPaletteRow(list, includeNone = false, selectedHex = draggableTextOverlay?.getStrokeColor()) { hex ->
            draggableTextOverlay?.setStrokeColor(hex ?: "#000000")
            setupStrokeColorPicker(toolbar)
        }
    }

    private fun setupShadowColorPicker(toolbar: View) {
        val list = toolbar.findViewById<LinearLayout>(R.id.shadowColorPickerList) ?: return
        buildTextPaletteRow(list, includeNone = true, selectedHex = draggableTextOverlay?.getShadowColor()) { hex ->
            draggableTextOverlay?.setShadowColor(hex)
            setupShadowColorPicker(toolbar)
        }
    }

    private fun updateActiveBoundaries('''
s = s.replace(OLD, NEW, 1)

# A10 -- enterTextEditingMode: hide new panels, reset new tab tints
OLD = req('''            toolbar.findViewById<View>(R.id.bgSettingsContainer)?.visibility = View.GONE
            toolbar.findViewById<ImageButton>(R.id.btnTextKeyboardTab)?.setColorFilter(getColor(R.color.colorPrimary))
            toolbar.findViewById<ImageButton>(R.id.btnTextPaletteTab)?.setColorFilter(getColor(R.color.toolTextInactive))
            toolbar.findViewById<ImageButton>(R.id.btnTextFormatTab)?.setColorFilter(getColor(R.color.toolTextInactive))
            toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)?.setColorFilter(getColor(R.color.toolTextInactive))''')
NEW = '''            toolbar.findViewById<View>(R.id.strokeSettingsContainer)?.visibility = View.GONE
            toolbar.findViewById<View>(R.id.shadowSettingsContainer)?.visibility = View.GONE
            toolbar.findViewById<View>(R.id.bgSettingsContainer)?.visibility = View.GONE
            toolbar.findViewById<ImageButton>(R.id.btnTextKeyboardTab)?.setColorFilter(getColor(R.color.colorPrimary))
            toolbar.findViewById<ImageButton>(R.id.btnTextPaletteTab)?.setColorFilter(getColor(R.color.toolTextInactive))
            toolbar.findViewById<ImageButton>(R.id.btnTextFormatTab)?.setColorFilter(getColor(R.color.toolTextInactive))
            toolbar.findViewById<ImageButton>(R.id.btnTextStrokeTab)?.setColorFilter(getColor(R.color.toolTextInactive))
            toolbar.findViewById<ImageButton>(R.id.btnTextShadowTab)?.setColorFilter(getColor(R.color.toolTextInactive))
            toolbar.findViewById<ImageButton>(R.id.btnTextBackgroundTab)?.setColorFilter(getColor(R.color.toolTextInactive))'''
s = s.replace(OLD, NEW, 1)

open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   tabs wired, sliders synced, palettes added, commit extended')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R6 VERIFY
# ---------------------------------------------------------------------------
verify_round6() {
  echo "== r6 verify"
  python3 - <<'CUTPY'
import glob, os, re, sys
import xml.etree.ElementTree as ET

bad = 0
def fail(msg):
    global bad
    bad += 1
    print('   [FAIL] ' + msg)

PKG = 'app/src/main/java/com/tharunbirla/librecuts'
TOOLBAR = 'app/src/main/res/layout/text_editing_toolbar.xml'
FMT = 'app/src/main/res/layout/text_format_settings.xml'
STROKEL = 'app/src/main/res/layout/text_stroke_settings.xml'
SHADOWL = 'app/src/main/res/layout/text_shadow_settings.xml'
AVEL = 'app/src/main/res/layout/activity_video_editing.xml'
IMGT = 'app/src/main/res/layout/image_editing_toolbar.xml'

# 1) XML validity
xmls = [TOOLBAR, FMT, STROKEL, SHADOWL, AVEL,
        'app/src/main/res/drawable/ic_text_stroke_24.xml',
        'app/src/main/res/drawable/ic_text_shadow_24.xml',
        'app/src/main/res/drawable/bg_play_pause_capsule.xml']
for f in xmls:
    try:
        ET.parse(f)
    except Exception as e:
        fail('XML %s: %s' % (f, e))
print('   [ok]   XML valid (%d files)' % len(xmls))

toolbar = open(TOOLBAR, encoding='utf-8').read()
fmt = open(FMT, encoding='utf-8').read()
strokel = open(STROKEL, encoding='utf-8').read()
shadowl = open(SHADOWL, encoding='utf-8').read()
avel = open(AVEL, encoding='utf-8').read()
act = open(PKG + '/VideoEditingActivity.kt', encoding='utf-8').read()

# 2) toolbar structure
order = ['btnTextFormatTab', 'btnTextStrokeTab', 'btnTextShadowTab', 'btnTextBackgroundTab']
pos = [toolbar.find(i) for i in order]
if -1 in pos or pos != sorted(pos):
    fail('tab order wrong: %r' % pos)
for inc in ['text_stroke_settings', 'text_shadow_settings']:
    if inc not in toolbar:
        fail('toolbar missing include ' + inc)
print('   [ok]   toolbar: Duplicate kept, order Format|Stroke|Shadow|Background')

# 3) format tab cleaned
if 'seekBorderWidth' in fmt:
    fail('format tab still has seekBorderWidth')
if 'text="Shadow"' in fmt:
    fail('format tab still has Shadow label')
print('   [ok]   format tab: shadow slider removed')

# 4) new ids defined + wired
defined = set(re.findall(r'\+id/(\w+)', toolbar)) | set(re.findall(r'\+id/(\w+)', strokel)) | set(re.findall(r'\+id/(\w+)', shadowl))
need = ['btnTextStrokeTab', 'btnTextShadowTab', 'strokeSettingsContainer', 'shadowSettingsContainer',
        'strokeColorPickerList', 'seekStrokeOpacity', 'seekStrokeWidth',
        'shadowColorPickerList', 'seekShadowOpacity', 'seekShadowBlur', 'seekShadowAngle', 'seekShadowWidth']
for i in need:
    if i not in defined:
        fail('id %s missing from layouts' % i)
    if ('R.id.' + i) not in act:
        fail('id %s not wired in Activity' % i)
print('   [ok]   R.id cross-check (%d new ids)' % len(need))

# 5) model + renderer markers
eop = open(PKG + '/models/EditOperation.kt', encoding='utf-8').read()
tru = open(PKG + '/utils/TextRenderUtils.kt', encoding='utf-8').read()
tov = open(PKG + '/customviews/TextOverlayView.kt', encoding='utf-8').read()
drg = open(PKG + '/customviews/DraggableTextOverlayView.kt', encoding='utf-8').read()
vme = open(PKG + '/viewmodels/VideoEditingViewModelExt.kt', encoding='utf-8').read()
checks = [
    ('AddText strokeOpacity (nullable)', 'val strokeOpacity: Float? = null,' in eop),
    ('AddText shadow fields', 'val shadowColor: String? = null,' in eop and 'val shadowWidth: Int = 0,' in eop),
    ('render stroke transparency', 'op.strokeOpacity ?: 1.0f' in tru),
    ('render real shadow', 'setShadowLayer(op.shadowBlur * scale' in tru),
    ('PNG pad covers shadow', 'op.shadowWidth + op.shadowBlur' in tru),
    ('subtitle shadow preserved', '// Keep the subtitle' in tov),
    ('callback 26 params', 'shadowWidth: Int) -> Unit' in drg),
    ('stroke setters', 'fun setStrokeWidth(' in drg and 'fun setStrokeColor(' in drg),
    ('shadow setters', 'fun setShadowColor(' in drg and 'fun setShadowWidth(' in drg),
    ('live preview helper', 'fun refreshTextEffects()' in drg),
    ('setBorderThickness removed', 'fun setBorderThickness(' not in drg),
    ('Ext signature extended', 'shadowWidth: Int = 0' in vme),
    ('Ext ctor passes shadow', 'strokeOpacity = strokeOpacity' in vme),
    ('Activity old slider gone', 'R.id.seekBorderWidth' not in act),
    ('Activity stroke palette', 'setupStrokeColorPicker' in act),
    ('Activity shadow palette', 'setupShadowColorPicker' in act),
    ('Activity commit extended', 'shadowWidth ->' in act),
    ('Activity stroke copy', 'strokeOpacity = strokeOpacity, shadowColor = shadowColor' in act),
]
for name, ok in checks:
    if not ok:
        fail(name)
print('   [ok]   markers: ' + str(sum(1 for _, o in checks if o)) + '/' + str(len(checks)))

# 6) image tool duplicate untouched
if 'btnImageDuplicate' not in open(IMGT, encoding='utf-8').read():
    fail('image toolbar duplicate button disappeared')
if act.count('duplicateSelectedOverlay') < 2:
    fail('duplicateSelectedOverlay still needed by image tool')
print('   [ok]   image tool duplicate kept')

# 7) play button capsule
if avel.count('bg_play_pause_capsule') != 1:
    fail('play button capsule reference wrong')
capsule = open('app/src/main/res/drawable/bg_play_pause_capsule.xml', encoding='utf-8').read()
if '<corners android:radius="20dp" />' not in capsule:
    fail('capsule drawable missing 20dp corners')
if 'android:layout_width="72dp"' not in avel:
    fail('play button not resized to capsule width')
print('   [ok]   play button: capsule 72x40dp + bounce effect untouched')

# 8) Kotlin brace/paren balance (state-machine lexer)
def strip_kotlin(src):
    out = []
    i, n = 0, len(src)
    NORMAL, LINE_C, BLOCK_C, STR, RAW, CHAR = range(6)
    st = NORMAL
    while i < n:
        c = src[i]
        two = src[i:i+2]
        if st == NORMAL:
            if two == '//':
                st = LINE_C; i += 2; continue
            if two == '/*':
                st = BLOCK_C; i += 2; continue
            if src[i:i+3] == '"""':
                st = RAW; i += 3; out.append(' '); continue
            if c == '"':
                st = STR; i += 1; out.append(' '); continue
            if c == "'":
                st = CHAR; i += 1; out.append(' '); continue
            out.append(c); i += 1
        elif st == LINE_C:
            if c == '\n':
                st = NORMAL; out.append('\n')
            i += 1
        elif st == BLOCK_C:
            if two == '*/':
                st = NORMAL; i += 2; continue
            if c == '\n':
                out.append('\n')
            i += 1
        elif st == STR:
            if c == '\\':
                i += 2; continue
            if c == '"':
                st = NORMAL
            if c == '\n':
                out.append('\n')
            i += 1
        elif st == RAW:
            if src[i:i+3] == '"""':
                st = NORMAL; i += 3; continue
            if c == '\n':
                out.append('\n')
            i += 1
        else:
            if c == '\\':
                i += 2; continue
            if c == "'":
                st = NORMAL
            if c == '\n':
                st = NORMAL; out.append('\n')
            i += 1
    return ''.join(out)

def balanced(path):
    s = strip_kotlin(open(path, encoding='utf-8').read())
    for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
        if s.count(a) != s.count(b):
            return '%s unbalanced (%d vs %d)' % (a, s.count(a), s.count(b))
    return None

for f in ['models/EditOperation.kt', 'customviews/TextOverlayView.kt',
          'customviews/DraggableTextOverlayView.kt', 'viewmodels/VideoEditingViewModelExt.kt',
          'VideoEditingActivity.kt', 'utils/TextRenderUtils.kt']:
    r = balanced(PKG + '/' + f)
    if r:
        fail('%s: %s' % (f, r))
print('   [ok]   Kotlin braces/parens balanced (6 files)')

# 9) pure-ASCII on touched text resources
for f in [TOOLBAR, FMT, STROKEL, SHADOWL, AVEL,
          'app/src/main/res/drawable/ic_text_stroke_24.xml',
          'app/src/main/res/drawable/ic_text_shadow_24.xml',
          'app/src/main/res/drawable/bg_play_pause_capsule.xml']:
    data = open(f, 'rb').read()
    if any(b > 127 for b in data):
        fail('non-ASCII byte in ' + f)
print('   [ok]   touched resources are pure ASCII')

if bad:
    print('R6 VERIFY FAILED (%d problem(s))' % bad)
    sys.exit(1)
print('R6 VERIFY OK')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# --- R6 STEPS END ---------------------------------------------------------

# --- ROUND 7 STAGES --------------------------------------------------------
#
#  R7 STEP 1 -- text tool: the Duplicate button is back
#  (round 6 originally removed it; it returns to its original spot --
#   right before Keyframes -- with the original behaviour: copies the
#   selected text overlay. Runs as a no-op when the button is present.)
#
r7_step1() {
  echo "== r7 step 1: text tool Duplicate button restored"
  python3 - "$TOOLBAR" "$ACT" <<'CUTPY'
import sys
tp, ap = sys.argv[1], sys.argv[2]

# (a) toolbar: re-insert the Duplicate tool block before Keyframes
s = open(tp, encoding='utf-8', newline='').read()
if 'btnTextDuplicate' in s:
    print('   [skip] toolbar already has the Duplicate button')
else:
    a = '            <!-- Keyframes -->'
    if s.count(a) != 1:
        print('   [FAIL] Keyframes anchor mismatch (%d)' % s.count(a))
        sys.exit(1)
    blk = '''            <!-- Duplicate -->
            <LinearLayout
                android:layout_width="60dp"
                android:layout_height="wrap_content"
                android:orientation="vertical"
                android:gravity="center">
                <ImageButton
                    android:id="@+id/btnTextDuplicate"
                    android:layout_width="40dp"
                    android:layout_height="40dp"
                    android:background="@drawable/tool_button_inactive"
                    android:src="@drawable/ic_copy_24"
                    android:padding="8dp"
                    android:scaleType="fitCenter"
                    app:tint="@color/toolTextInactive" />
                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:layout_marginTop="4dp"
                    android:text="@string/str_duplicate"
                    android:textSize="11sp"
                    android:fontFamily="sans-serif-medium"
                    android:textColor="@color/toolTextInactive" />
            </LinearLayout>

'''
    i = s.index(a)
    s = s[:i] + blk + s[i:]
    open(tp, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok]   Duplicate tool block restored before Keyframes')

# (b) activity: re-insert the click wiring
a2 = open(ap, encoding='utf-8', newline='').read()
if 'R.id.btnTextDuplicate' in a2:
    print('   [skip] Activity Duplicate wiring already present')
else:
    b = '                val btnKeyboard = toolbar.findViewById<ImageButton>(R.id.btnTextKeyboardTab)'
    if a2.count(b) != 1:
        print('   [FAIL] btnKeyboard anchor mismatch (%d)' % a2.count(b))
        sys.exit(1)
    wire = '''                toolbar.findViewById<View>(R.id.btnTextDuplicate)?.setBounceClickListener {
                    duplicateSelectedOverlay()
                }

'''
    j = a2.index(b)
    a2 = a2[:j] + wire + a2[j:]
    open(ap, 'w', encoding='utf-8', newline='').write(a2)
    print('   [ok]   Duplicate wiring restored')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R7 STEP 2 -- (superseded by round 8) originally recolored the theme to
#  amber #F9B10B. Round 8 reverts every color to the original Electric
#  Pink, so this step is now a no-op (kept so old state stays readable).

#
r7_step2() {
  echo "== r7 step 2: (superseded by round 8) original theme kept -- no recolor"
  return 0
}


# ---------------------------------------------------------------------------
#  R7 STEP 3 -- editor top bar: back arrow gets a dark capsule background
#  (48x36dp pill, ripple feedback kept, dark surface + subtle outline --
#   same 36dp height and mirrored edge position as the Export capsule)
#
r7_step3() {
  echo "== r7 step 3: back button -> dark capsule (mirrors Export button)"
  if [ -f "$DRAW/bg_back_capsule.xml" ]; then
    echo "   [skip] bg_back_capsule.xml exists"
  else
    cat > "$DRAW/bg_back_capsule.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<ripple xmlns:android="http://schemas.android.com/apk/res/android"
    android:color="#40FFFFFF">
    <item>
        <shape android:shape="rectangle">
            <solid android:color="@color/surfaceContainerHigh" />
            <stroke android:width="1dp" android:color="@color/outlineVariant" />
            <corners android:radius="18dp" />
        </shape>
    </item>
</ripple>
XMLEOF
    echo "   [ok]   bg_back_capsule.xml written"
  fi

  python3 - "$AVEL" <<'CUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
if '@drawable/bg_back_capsule' in s:
    print('   [skip] back button already capsule')
    sys.exit(0)
OLD = '''            <ImageButton
                android:id="@+id/btnClose"
                android:layout_width="40dp"
                android:layout_height="40dp"
                android:background="?attr/selectableItemBackgroundBorderless"
                android:src="@drawable/ic_back_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                android:contentDescription="Back"
                app:tint="@color/textColor" />'''
NEW = '''            <ImageButton
                android:id="@+id/btnClose"
                android:layout_width="48dp"
                android:layout_height="36dp"
                android:background="@drawable/bg_back_capsule"
                android:src="@drawable/ic_back_24"
                android:padding="8dp"
                android:scaleType="fitCenter"
                android:contentDescription="Back"
                app:tint="@color/textColor" />'''
if s.count(OLD) != 1:
    print('   [FAIL] btnClose block mismatch (%d)' % s.count(OLD))
    sys.exit(1)
s = s.replace(OLD, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   btnClose -> 48x36dp dark capsule (ripple kept)')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  R7 VERIFY
# ---------------------------------------------------------------------------
verify_round7() {
  echo "== r7 verify"
  python3 - <<'CUTPY'
import os, re, sys
import xml.etree.ElementTree as ET

bad = 0
def fail(msg):
    global bad
    bad += 1
    print('   [FAIL] ' + msg)

RES = 'app/src/main/res'
PKG = 'app/src/main/java/com/tharunbirla/librecuts'
TOOLBAR = RES + '/layout/text_editing_toolbar.xml'
AVEL = RES + '/layout/activity_video_editing.xml'

# 1) XML validity
xmls = [RES + '/values/colors.xml',
        RES + '/drawable/bg_back_capsule.xml',
        RES + '/drawable/bg_nav_active_pill.xml',
        RES + '/drawable/ic_save_color_24.xml',
        RES + '/drawable/ic_launcher_foreground.xml',
        RES + '/drawable/ic_banner_foreground.xml',
        RES + '/layout/activity_video_editing.xml',
        RES + '/layout/dialog_voice_over.xml',
        RES + '/layout/dialog_welcome_onboarding.xml',
        RES + '/layout/text_editing_toolbar.xml']
for f in xmls:
    try:
        ET.parse(f)
    except Exception as e:
        fail('XML %s: %s' % (f, e))
print('   [ok]   XML valid (%d files)' % len(xmls))

# 2) theme palette is the ORIGINAL Electric Pink (round 8 revert)
import hashlib
c = open(RES + '/values/colors.xml', encoding='utf-8').read()
pairs = [
    ('colorPrimary pink',         '<color name="colorPrimary">#FF2A6D</color>' in c),
    ('variant pink',              '<color name="colorPrimaryVariant">#C81D52</color>' in c),
    ('onPrimary white',           '<color name="colorOnPrimary">#FFFFFF</color>' in c),
    ('secondary pink',            '<color name="colorSecondary">#FF2A6D</color>' in c),
    ('secondaryVariant pink',     '<color name="colorSecondaryVariant">#C81D52</color>' in c),
    ('onSecondary white',         '<color name="colorOnSecondary">#FFFFFF</color>' in c),
    ('primaryContainer pink',     '<color name="primaryContainer">#FF2A6D</color>' in c),
    ('onPrimaryContainer white',  '<color name="onPrimaryContainer">#FFFFFF</color>' in c),
    ('activeTool pink',           '<color name="activeTool">#FF2A6D</color>' in c),
    ('activeToolBackground pink', '<color name="activeToolBackground">#2A1118</color>' in c),
    ('toolTextActive pink',       '<color name="toolTextActive">#FF2A6D</color>' in c),
    ('no amber onPrimary',        '<color name="colorOnPrimary">#1A1A20</color>' not in c),
    ('no amber onPrimaryContainer', '<color name="onPrimaryContainer">#1A1A20</color>' not in c),
]
for name, ok in pairs:
    if not ok:
        fail(name)
if hashlib.sha256(open(RES + '/values/colors.xml', 'rb').read()).hexdigest() != \
        '9ef61c0fbe320540788cd987df2978979d8d1a23b55a6fb18594b65103409a67':
    fail('colors.xml sha256 != original Electric Pink palette')
print('   [ok]   colors.xml: original Electric Pink palette (%d checks + sha256)' % len(pairs))

# 3) no leftover amber theme hexes anywhere (#1A1A20 is a legit original
#    surface color so the bare value is not scanned here; the full-line
#    palette checks above catch it inside the "on" color slots)
leftover = []
for root, dirs, files in os.walk('app/src/main'):
    for fn in files:
        if not fn.endswith(('.xml', '.kt')):
            continue
        fp = os.path.join(root, fn)
        try:
            t = open(fp, encoding='utf-8').read()
        except Exception:
            continue
        for hx in ['#F9B10B', '#C28A09', '#2A2210',
                   '#33F9B10B', '#1AF9B10B', '#20F9B10B', '#4DF9B10B',
                   '#f9b10b', '#c28a09', '#2a2210']:
            if hx in t:
                leftover.append(fp + ' still has ' + hx)
for x in leftover[:10]:
    fail(x)
if leftover:
    fail('%d leftover amber hexe(s) total' % len(leftover))
else:
    print('   [ok]   no leftover amber hexes (original theme restored)')

# 4) Duplicate restored
toolbar = open(TOOLBAR, encoding='utf-8').read()
act = open(PKG + '/VideoEditingActivity.kt', encoding='utf-8').read()
strings = open(RES + '/values/strings.xml', encoding='utf-8').read()
imgt = open(RES + '/layout/image_editing_toolbar.xml', encoding='utf-8').read()
dchecks = [
    ('toolbar Duplicate button', 'btnTextDuplicate' in toolbar),
    ('toolbar uses str_duplicate', '@string/str_duplicate' in toolbar),
    ('Duplicate before Keyframes', toolbar.find('btnTextDuplicate') < toolbar.find('<!-- Keyframes -->')),
    ('string str_duplicate exists', '<string name="str_duplicate">' in strings),
    ('activity Duplicate wiring', 'R.id.btnTextDuplicate' in act),
    ('duplicateSelectedOverlay wired 3x', act.count('duplicateSelectedOverlay') >= 3),
    ('image tool duplicate kept', 'btnImageDuplicate' in imgt),
]
for name, ok in dchecks:
    if not ok:
        fail(name)
print('   [ok]   text Duplicate restored (%d checks)' % len(dchecks))

# 5) back button capsule + export symmetry
avel = open(AVEL, encoding='utf-8').read()
m = re.search(r'android:id="@\+id/btnClose".*?/>', avel, re.S)
if not m:
    fail('btnClose block not found')
else:
    blk = m.group(0)
    for needle, label in [
        ('android:layout_width="48dp"', 'back width 48dp'),
        ('android:layout_height="36dp"', 'back height 36dp'),
        ('@drawable/bg_back_capsule', 'back capsule background'),
    ]:
        if needle not in blk:
            fail(label)
m2 = re.search(r'android:id="@\+id/layoutSaveSplit".*?android:layout_height="(\d+)dp"', avel, re.S)
if not m2 or m2.group(1) != '36':
    fail('export button height changed (expected 36dp)')
if avel.count('@drawable/bg_back_capsule') != 1:
    fail('bg_back_capsule referenced %d times' % avel.count('@drawable/bg_back_capsule'))
caps = open(RES + '/drawable/bg_back_capsule.xml', encoding='utf-8').read()
for needle, label in [
    ('<ripple', 'capsule ripple (tap feedback)'),
    ('@color/surfaceContainerHigh', 'capsule dark surface'),
    ('<corners android:radius="18dp" />', 'capsule 18dp corners'),
]:
    if needle not in caps:
        fail(label)
print('   [ok]   back button: dark capsule 48x36dp, ripple, mirrors Export 36dp')

# 6) play/pause icon: pre-existing onPrimaryContainer tint resolves white
mp = re.search(r'@\+id/btnPlayPause".*?/>', avel, re.S)
if not mp or 'app:tint="@color/onPrimaryContainer"' not in mp.group(0):
    fail('play capsule icon tint missing')
else:
    print('   [ok]   play capsule icon tint resolves white on pink')

# 7) Kotlin balance on touched files
def strip_kotlin(src):
    out = []
    i, n = 0, len(src)
    NORMAL, LINE_C, BLOCK_C, STR, RAW, CHAR = range(6)
    st = NORMAL
    while i < n:
        c = src[i]
        two = src[i:i+2]
        if st == NORMAL:
            if two == '//':
                st = LINE_C; i += 2; continue
            if two == '/*':
                st = BLOCK_C; i += 2; continue
            if src[i:i+3] == '"""':
                st = RAW; i += 3; out.append(' '); continue
            if c == '"':
                st = STR; i += 1; out.append(' '); continue
            if c == "'":
                st = CHAR; i += 1; out.append(' '); continue
            out.append(c); i += 1
        elif st == LINE_C:
            if c == '\n':
                st = NORMAL; out.append('\n')
            i += 1
        elif st == BLOCK_C:
            if two == '*/':
                st = NORMAL; i += 2; continue
            if c == '\n':
                out.append('\n')
            i += 1
        elif st == STR:
            if c == '\\':
                i += 2; continue
            if c == '"':
                st = NORMAL
            if c == '\n':
                out.append('\n')
            i += 1
        elif st == RAW:
            if src[i:i+3] == '"""':
                st = NORMAL; i += 3; continue
            if c == '\n':
                out.append('\n')
            i += 1
        else:
            if c == '\\':
                i += 2; continue
            if c == "'":
                st = NORMAL
            if c == '\n':
                st = NORMAL; out.append('\n')
            i += 1
    return ''.join(out)

for f in ['VideoEditingActivity.kt', 'customviews/TrackTrimView.kt',
          'customviews/CustomVideoSeeker.kt', 'customviews/VideoMaskOverlayView.kt',
          'customviews/DraggableImageOverlayView.kt']:
    t = strip_kotlin(open(PKG + '/' + f, encoding='utf-8').read())
    for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
        if t.count(a) != t.count(b):
            fail('%s: %s unbalanced (%d vs %d)' % (f, a, t.count(a), t.count(b)))
print('   [ok]   Kotlin braces/parens balanced (5 files)')

# 8) pure-ASCII on the touched XML resources
# (the Kotlin files carry upstream non-ASCII comments in the original
#  repo -- they build fine; our substitutions are pure ASCII hex swaps)
touched = xmls
for f in touched:
    data = open(f, 'rb').read()
    if any(bb > 127 for bb in data):
        fail('non-ASCII byte in ' + f)
print('   [ok]   touched XML resources are pure ASCII (%d files)' % len(touched))

if bad:
    print('R7 VERIFY FAILED (%d problem(s))' % bad)
    sys.exit(1)
print('R7 VERIFY OK')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# --- ROUND 7 STAGES END ----------------------------------------------------

# --- ROUND 8 STAGES --------------------------------------------------------
#
#  R8 STEP 1 -- theme revert: amber #F9B10B -> ORIGINAL Electric Pink
#  (undoes the round-7 recolor on forks where it was applied; runs as a
#   no-op on forks that never went amber. The round-7 Duplicate button
#   and the capsule back button are NOT touched -- only colors revert.)
#  NOTE on the "ambiguous" files: round 7 mapped several DIFFERENT pink
#  hexes to the same amber value (#FF4081 / #FF2A6D / #E91E63 all became
#  #F9B10B), so a bare hex swap cannot restore them correctly there.
#  Those files are reverted with full line-context anchors instead.
#
r8_step1() {
  echo "== r8 step 1: theme color revert amber -> original Electric Pink"
  python3 - <<'CUTPY'
import os, sys

def sub(path, pairs):
    if not os.path.exists(path):
        print('   [FAIL] missing file: ' + path)
        sys.exit(1)
    s = open(path, encoding='utf-8', newline='').read()
    n = 0
    for old, new in pairs:
        n += s.count(old)
        s = s.replace(old, new)
    if n:
        open(path, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok]   %-64s %d sub(s)' % (path, n))
    return n

total = 0

# 1) theme palette (colors.xml) -- exact inverse of the round-7 subs
total += sub('app/src/main/res/values/colors.xml', [
    ('<!-- PRIMARY: Amber -->',                           '<!-- PRIMARY: Electric Pink -->'),
    ('<!-- SECONDARY: Amber Accent -->',                  '<!-- SECONDARY: Bright Pink Accent -->'),
    ('<!-- Subtle amber tint for active tool -->',        '<!-- Subtle pink tint for active tool -->'),
    ('<color name="colorPrimary">#F9B10B</color>',       '<color name="colorPrimary">#FF2A6D</color>'),
    ('<color name="colorPrimaryVariant">#C28A09</color>', '<color name="colorPrimaryVariant">#C81D52</color>'),
    ('<color name="colorOnPrimary">#1A1A20</color>',     '<color name="colorOnPrimary">#FFFFFF</color>'),
    ('<color name="colorSecondary">#F9B10B</color>',     '<color name="colorSecondary">#FF2A6D</color>'),
    ('<color name="colorSecondaryVariant">#C28A09</color>', '<color name="colorSecondaryVariant">#C81D52</color>'),
    ('<color name="colorOnSecondary">#1A1A20</color>',   '<color name="colorOnSecondary">#FFFFFF</color>'),
    ('<color name="primaryContainer">#F9B10B</color>',   '<color name="primaryContainer">#FF2A6D</color>'),
    ('<color name="onPrimaryContainer">#1A1A20</color>', '<color name="onPrimaryContainer">#FFFFFF</color>'),
    ('<color name="activeTool">#F9B10B</color>',         '<color name="activeTool">#FF2A6D</color>'),
    ('<color name="activeToolBackground">#2A2210</color>', '<color name="activeToolBackground">#2A1118</color>'),
    ('<color name="toolTextActive">#F9B10B</color>',     '<color name="toolTextActive">#FF2A6D</color>'),
])

# 2) drawables (nav pill, save icon, app icon, banner)
total += sub('app/src/main/res/drawable/bg_nav_active_pill.xml',
    [('#20F9B10B', '#20FF2A6D'), ('#4DF9B10B', '#4DFF2A6D')])
total += sub('app/src/main/res/drawable/ic_save_color_24.xml',       [('#F9B10B', '#FF4081')])
total += sub('app/src/main/res/drawable/ic_launcher_foreground.xml', [('#F9B10B', '#FF4081')])
total += sub('app/src/main/res/drawable/ic_banner_foreground.xml',   [('#F9B10B', '#FF4081')])

# 3) layouts (spinner, record button + its ripples, dead onboarding dialog)
total += sub('app/src/main/res/layout/activity_video_editing.xml', [('#F9B10B', '#FF4081')])
total += sub('app/src/main/res/layout/dialog_voice_over.xml',
    [('#F9B10B', '#FF4081'),
     ('app:tint="@color/onPrimaryContainer"', 'app:tint="@android:color/white"')])
total += sub('app/src/main/res/layout/dialog_welcome_onboarding.xml', [('#F9B10B', '#E91E63')])

# 4) Kotlin hardcoded colors. VideoMaskOverlayView and
#    DraggableImageOverlayView only ever held #FF2A6D, so a bare swap is
#    exact there. TrackTrimView / CustomVideoSeeker / VideoEditingActivity
#    held MIXED pinks that all collapsed into #F9B10B -- those use
#    line-context anchors (comment suffixes disambiguate the paints).
PKG = 'app/src/main/java/com/tharunbirla/librecuts'
total += sub(PKG + '/customviews/VideoMaskOverlayView.kt',      [('#F9B10B', '#FF2A6D')])
total += sub(PKG + '/customviews/DraggableImageOverlayView.kt', [('#F9B10B', '#FF2A6D')])
total += sub(PKG + '/customviews/TrackTrimView.kt',
    [('#33F9B10B', '#33FF2A6D'),
     ('#1AF9B10B', '#1AFF4081'),
     ('borderPaint.color = Color.parseColor("#F9B10B") // Electric Pink selection',
      'borderPaint.color = Color.parseColor("#FF2A6D") // Electric Pink selection'),
     ('borderPaint.color = Color.parseColor("#F9B10B") // Vibrant pink selection accent',
      'borderPaint.color = Color.parseColor("#FF4081") // Vibrant pink selection accent'),
     ('borderPaint.color = Color.parseColor("#F9B10B")',
      'borderPaint.color = Color.parseColor("#FF4081")'),
     ('handlePaint.color = Color.parseColor("#F9B10B")',
      'handlePaint.color = Color.parseColor("#FF4081")')])
total += sub(PKG + '/customviews/CustomVideoSeeker.kt',
    [('#F9B10B (accent)', '#FF4081 (accent)'),
     ('Color.parseColor("#F9B10B")', 'Color.parseColor("#FF2A6D")')])
total += sub(PKG + '/VideoEditingActivity.kt',
    [('ColorStateList.valueOf(android.graphics.Color.parseColor("#F9B10B"))',
      'ColorStateList.valueOf(android.graphics.Color.parseColor("#FF4081"))'),
     ('trackColor = android.graphics.Color.parseColor("#F9B10B") // Pink for text',
      'trackColor = android.graphics.Color.parseColor("#E91E63") // Pink for text')])

# 5) safety net: after the revert, no amber hex may remain anywhere.
#    (#1A1A20 is NOT scanned -- it is a legit original surface color; the
#     full-line palette subs above already handle it in "on" color slots.)
AMBER = ['#F9B10B', '#C28A09', '#2A2210', '#33F9B10B', '#1AF9B10B',
         '#20F9B10B', '#4DF9B10B', '#f9b10b', '#c28a09', '#2a2210']
bad = []
for root, dirs, files in os.walk('app/src/main'):
    for fn in files:
        if not fn.endswith(('.xml', '.kt')):
            continue
        fp = os.path.join(root, fn)
        try:
            t = open(fp, encoding='utf-8').read()
        except Exception:
            continue
        for hx in AMBER:
            if hx in t:
                bad.append(fp + ' still has ' + hx)
if bad:
    for x in bad[:10]:
        print('   [FAIL] ' + x)
    sys.exit(1)
if total == 0:
    print('   [skip] no amber theme found -- original colors already in place')
else:
    print('   [ok]   %d substitution(s) reverted; no amber hexes remain' % total)
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# --- ROUND 8 STAGES END ----------------------------------------------------

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
precheck         || { echo "ABORT: pre-check";  exit 1; }
step1_model      || { echo "ABORT: step 1";     exit 1; }
step2_new_files  || { echo "ABORT: step 2";     exit 1; }
step3_layouts    || { echo "ABORT: step 3";     exit 1; }
step4_textoverlayview || { echo "ABORT: step 4"; exit 1; }
step5_draggable  || { echo "ABORT: step 5";     exit 1; }
step6_viewmodel  || { echo "ABORT: step 6";     exit 1; }
step7_ext        || { echo "ABORT: step 7";     exit 1; }
step8_activity   || { echo "ABORT: step 8";     exit 1; }
verify_all       || { echo "ABORT: verify";     exit 1; }

# -- round 6 --
r6_precheck      || { echo "ABORT: r6 pre-check"; exit 1; }
r6_step1         || { echo "ABORT: r6 step 1";    exit 1; }
r6_step2         || { echo "ABORT: r6 step 2";    exit 1; }
r6_step3         || { echo "ABORT: r6 step 3";    exit 1; }
r6_step4         || { echo "ABORT: r6 step 4";    exit 1; }
r6_step5         || { echo "ABORT: r6 step 5";    exit 1; }
r6_step6         || { echo "ABORT: r6 step 6";    exit 1; }
r6_step7         || { echo "ABORT: r6 step 7";    exit 1; }
r6_step8         || { echo "ABORT: r6 step 8";    exit 1; }
r6_step9         || { echo "ABORT: r6 step 9";    exit 1; }
verify_round6    || { echo "ABORT: r6 verify";   exit 1; }

# -- round 7 + round 8 --
r7_step1         || { echo "ABORT: r7 step 1";    exit 1; }
r7_step2         || { echo "ABORT: r7 step 2";    exit 1; }
r7_step3         || { echo "ABORT: r7 step 3";    exit 1; }
r8_step1         || { echo "ABORT: r8 step 1";    exit 1; }
verify_round7    || { echo "ABORT: r7+r8 verify"; exit 1; }
echo ""
echo "ROUND 5 + ROUND 6 + ROUND 7 + ROUND 8 APPLIED SUCCESSFULLY"
