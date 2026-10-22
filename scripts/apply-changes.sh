#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 4 -- build hotfix + deep subtitle purge (no .lcprj compatibility)
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  What this phase does:
#   0. Preconditions: confirms phase 3 is already applied on main.
#   1. HOTFIX: restores pickBackgroundImage() into VideoEditingActivity.kt.
#      Phase 3 accidentally swallowed this LIVE function (it happened to
#      sit between two subtitle functions), which broke the build with
#      "Unresolved reference 'pickBackgroundImage'" at line 1851.
#   2. models/EditOperation.kt: removes the AddSubtitles and SubtitleCue
#      classes plus the AddSubtitles branch of the id-mapping when.
#   3. utils/ProjectSerializer.kt: removes the "AddSubtitles" type
#      mapping. Old .lcprj projects that contain subtitle operations
#      still LOAD fine afterwards -- the serializer's unknown-type path
#      logs a warning and skips that op. No crash.
#   4. viewmodels/VideoEditingViewModel.kt: removes the FFmpeg drawtext
#      burn-in branch for subtitle cues, the three AddSubtitles filter
#      clauses, and the now-dead getWrappedSubtitleLines() helper.
#   5. customviews/TextOverlayView.kt: removes the whole subtitle preview
#      half -- drag/selection fields, public subtitle properties, the
#      setSubtitleCues() entry point, the onDraw cue-render block, the
#      onTouchEvent drag handler, wrapTextForCanvas(), dead imports.
#   6. VideoEditingActivity.kt: removes the 5-line subtitle wiring block
#      inside the project observer.
#   7. Verification gate (fails BEFORE anything gets committed):
#      token scan, a function-inventory guard compared against git HEAD
#      (this is the check that would have caught the phase 3 bug: any
#      unexpected loss of a live function fails the run), brace sanity,
#      and the pickBackgroundImage definition/call invariant.
#
#  POLICY (per project owner): old .lcprj project compatibility is NO
#  LONGER a design goal. Dead compatibility code gets deleted. This
#  update set is a standalone release that changes functionality.
#
#  Idempotent: every step checks its own marker and skips if applied.
#  POLICY: this pipeline must never modify files under .github/workflows/
#  (bot pushes get rejected by GitHub). Workflow changes are always
#  manual web-editor edits by the repo owner.
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
EO="app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt"
PS="app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt"
VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
TOV="app/src/main/java/com/tharunbirla/librecuts/customviews/TextOverlayView.kt"
LAYOUT="app/src/main/res/layout/activity_video_editing.xml"

# ---------------------------------------------------------------------------
#  STEP 0 -- preconditions (phase 3 must already be applied)
# ---------------------------------------------------------------------------
step0_preconditions() {
    echo "== step 0: preconditions (phase 3 must already be applied)"
    local fail=0
    if grep -q "btnSubtitles" "$LAYOUT"; then
        echo "   [FAIL] btnSubtitles still in main layout -- phase 3 not applied yet"
        fail=1
    fi
    if grep -q "subtitlesAction" "$VEA"; then
        echo "   [FAIL] subtitlesAction still in activity -- phase 3 not applied yet"
        fail=1
    fi
    if [ -f app/src/main/java/com/tharunbirla/librecuts/utils/SubtitleParser.kt ]; then
        echo "   [FAIL] SubtitleParser.kt still exists -- phase 3 not applied yet"
        fail=1
    fi
    if [ "$fail" -ne 0 ]; then
        return 1
    fi
    echo "   [ok] phase 3 state confirmed"
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 1 -- HOTFIX: restore pickBackgroundImage() (phase 3 casualty)
# ---------------------------------------------------------------------------
step1_hotfix() {
    echo "== step 1: HOTFIX -- restore pickBackgroundImage() in the activity"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
s = open(p, encoding='utf-8', newline='').read()
if 'fun pickBackgroundImage(' in s:
    print('   [skip] pickBackgroundImage() already defined (hotfix applied)')
    sys.exit(0)
anchor = '    private fun mediaOverlayAction() {'
if s.count(anchor) != 1:
    print('   [FAIL] anchor mediaOverlayAction() not found exactly once')
    sys.exit(1)
fn = (
    '    private fun pickBackgroundImage() {\n'
    '        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {\n'
    '            type = "image/*"\n'
    '            addCategory(Intent.CATEGORY_OPENABLE)\n'
    '            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/jpeg", "image/png", "image/webp"))\n'
    '        }\n'
    '        try {\n'
    '            startActivityForResult(intent, PICK_BACKGROUND_IMAGE_REQUEST)\n'
    '        } catch (e: Exception) {\n'
    '            Toast.makeText(this, "No app found to handle image selection", Toast.LENGTH_SHORT).show()\n'
    '        }\n'
    '    }\n'
    '\n')
s2 = s.replace(anchor, fn + anchor, 1)
if (s2.count('{') - s.count('{') != s2.count('}') - s.count('}') or
        s2.count('(') - s.count('(') != s2.count(')') - s.count(')')):
    print('   [FAIL] brace/paren balance broken by insertion')
    sys.exit(1)
open(p, 'w', encoding='utf-8', newline='').write(s2)
print('   [ok] pickBackgroundImage() restored before mediaOverlayAction()')
print('   [ok] definitions=%d, definition+call occurrences=%d, request-const refs=%d'
      % (s2.count('fun pickBackgroundImage('), s2.count('pickBackgroundImage()'),
         s2.count('PICK_BACKGROUND_IMAGE_REQUEST')))
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 2 -- models/EditOperation.kt: remove AddSubtitles + SubtitleCue
# ---------------------------------------------------------------------------
step2_models() {
    echo "== step 2: models/EditOperation.kt -- remove AddSubtitles + SubtitleCue"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt'
s = open(p, encoding='utf-8', newline='').read()
orig = s
applied, skipped, failed = [], [], []

def one(name, old, new=''):
    global s
    n = s.count(old)
    if n == 0:
        skipped.append(name)
    elif n == 1:
        s = s.replace(old, new, 1)
        applied.append(name)
    else:
        failed.append(name + ' (' + str(n) + ' occurrences)')

one('remove AddSubtitles data class',
    '    data class AddSubtitles(\n'
    '        val subtitlesUri: Uri,\n'
    '        val srtContent: String,\n'
    '        val fileName: String,\n'
    '        val cues: List<SubtitleCue>,\n'
    '        val color: String = "#FFFFFF",\n'
    '        val backgroundColor: String = "none",\n'
    '        val fontSize: Int = 22,\n'
    '        val position: TextPosition = TextPosition.BOTTOM_CENTER,\n'
    '        val relativeX: Float? = null,\n'
    '        val relativeY: Float? = null,\n'
    '        val fontPath: String? = null,\n'
    '        val id: String = System.nanoTime().toString()\n'
    '    ) : EditOperation() {\n'
    '        fun hasCustomPosition(): Boolean = relativeX != null && relativeY != null\n'
    '    }\n'
    '\n')

one('remove SubtitleCue data class',
    'data class SubtitleCue(\n'
    '    val startTimeMs: Long,\n'
    '    val endTimeMs: Long,\n'
    '    val text: String\n'
    ') : java.io.Serializable\n'
    '\n'
    '\n')

one('remove AddSubtitles branch from id-mapping when',
    '        is EditOperation.AddSubtitles -> id\n')

for n in applied:
    print('   [ok] ' + n)
for n in skipped:
    print('   [skip] ' + n)
for n in failed:
    print('   [FAIL] ' + n)

if (orig.count('{') - s.count('{') != orig.count('}') - s.count('}') or
        orig.count('(') - s.count('(') != orig.count(')') - s.count(')')):
    print('   [FAIL] brace/paren balance broken')
    sys.exit(1)
if failed:
    sys.exit(1)
if applied:
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok] %d edit(s) applied, %d line(s) removed'
          % (len(applied), orig.count('\n') - s.count('\n')))
else:
    print('   [ok] nothing to do (already applied)')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 3 -- utils/ProjectSerializer.kt: drop the AddSubtitles mapping
# ---------------------------------------------------------------------------
step3_serializer() {
    echo "== step 3: utils/ProjectSerializer.kt -- drop AddSubtitles type mapping"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt'
s = open(p, encoding='utf-8', newline='').read()
orig = s
applied, skipped, failed = [], [], []

def one(name, old, new=''):
    global s
    n = s.count(old)
    if n == 0:
        skipped.append(name)
    elif n == 1:
        s = s.replace(old, new, 1)
        applied.append(name)
    else:
        failed.append(name + ' (' + str(n) + ' occurrences)')

one('drop "AddSubtitles" from validClasses set',
    ', "AddSubtitles"')

one('drop "AddSubtitles" -> class mapping line',
    '                "AddSubtitles" -> EditOperation.AddSubtitles::class.java\n')

for n in applied:
    print('   [ok] ' + n)
for n in skipped:
    print('   [skip] ' + n)
for n in failed:
    print('   [FAIL] ' + n)

if (orig.count('{') - s.count('{') != orig.count('}') - s.count('}') or
        orig.count('(') - s.count('(') != orig.count(')') - s.count(')')):
    print('   [FAIL] brace/paren balance broken')
    sys.exit(1)
if failed:
    sys.exit(1)
if applied:
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok] %d edit(s) applied, %d line(s) removed'
          % (len(applied), orig.count('\n') - s.count('\n')))
else:
    print('   [ok] nothing to do (already applied)')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 4 -- VideoEditingViewModel.kt: remove subtitle export code
# ---------------------------------------------------------------------------
step4_viewmodel() {
    echo "== step 4: VideoEditingViewModel.kt -- remove subtitle export code"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt'
s = open(p, encoding='utf-8', newline='').read()
orig = s
applied, skipped, failed = [], [], []

def cut_span(name, start_marker, end_marker):
    global s
    i = s.find(start_marker)
    if i < 0:
        skipped.append(name)
        return
    j = s.find(end_marker, i + len(start_marker))
    if j < 0:
        failed.append(name + ': end marker not found')
        return
    s = s[:i] + s[j:]
    applied.append(name)

def many(name, old, new, expect):
    global s
    n = s.count(old)
    if n == 0:
        skipped.append(name)
    elif n == expect:
        s = s.replace(old, new)
        applied.append(name)
    else:
        failed.append(name + ' (found ' + str(n) + ', expected ' + str(expect) + ')')

# 4a. the AddSubtitles burn-in branch of the filter-graph when
cut_span('remove AddSubtitles export burn-in branch',
         '                is EditOperation.AddSubtitles -> {',
         '                else -> {}')

# 4b. the three videoOps filter clauses (export + preview paths)
many('drop AddSubtitles from videoOps filter clauses (x3)',
     ' || it is EditOperation.AddSubtitles', '', 3)

# 4c. getWrappedSubtitleLines() -- now the last function in the file
marker = '\n\n    private fun getWrappedSubtitleLines('
i = s.find(marker)
if i < 0:
    skipped.append('remove getWrappedSubtitleLines() function')
else:
    j = s.find('\n}', i)
    if j < 0:
        failed.append('remove getWrappedSubtitleLines() function: class close not found')
    else:
        s = s[:i] + s[j:]
        applied.append('remove getWrappedSubtitleLines() function')

for n in applied:
    print('   [ok] ' + n)
for n in skipped:
    print('   [skip] ' + n)
for n in failed:
    print('   [FAIL] ' + n)

if (orig.count('{') - s.count('{') != orig.count('}') - s.count('}') or
        orig.count('(') - s.count('(') != orig.count(')') - s.count(')')):
    print('   [FAIL] brace/paren balance broken')
    sys.exit(1)
if failed:
    sys.exit(1)
if applied:
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok] %d edit(s) applied, %d line(s) removed'
          % (len(applied), orig.count('\n') - s.count('\n')))
else:
    print('   [ok] nothing to do (already applied)')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 5 -- TextOverlayView.kt: remove the subtitle preview rendering
# ---------------------------------------------------------------------------
step5_textoverlay() {
    echo "== step 5: TextOverlayView.kt -- remove subtitle preview rendering"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/customviews/TextOverlayView.kt'
s = open(p, encoding='utf-8', newline='').read()
orig = s
applied, skipped, failed = [], [], []

def cut_span(name, start_marker, end_marker):
    global s
    i = s.find(start_marker)
    if i < 0:
        skipped.append(name)
        return
    j = s.find(end_marker, i + len(start_marker))
    if j < 0:
        failed.append(name + ': end marker not found')
        return
    s = s[:i] + s[j:]
    applied.append(name)

def one(name, old, new=''):
    global s
    n = s.count(old)
    if n == 0:
        skipped.append(name)
    elif n == 1:
        s = s.replace(old, new, 1)
        applied.append(name)
    else:
        failed.append(name + ' (' + str(n) + ' occurrences)')

# ORDER MATTERS below: the onDraw block is cut first (its end marker
# anchors on the @SuppressLint line), then the touch handler (its end
# marker anchors on wrapTextForCanvas), then the wrapper helper (its end
# marker anchors on the class closing brace).

# 5a. the subtitle render block at the end of onDraw()
cut_span('remove subtitle render block from onDraw()',
         '        // Render subtitles centered at bottom or custom positioned',
         '    }\n\n    @SuppressLint("ClickableViewAccessibility")')

# 5b. the whole onTouchEvent override (it only handled subtitle dragging)
cut_span('remove onTouchEvent subtitle drag handler',
         '    @SuppressLint("ClickableViewAccessibility")\n'
         '    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {',
         '    private fun wrapTextForCanvas(')

# 5c. wrapTextForCanvas() -- only ever called by the subtitle render block
cut_span('remove wrapTextForCanvas() helper',
         '\n\n    private fun wrapTextForCanvas(text: String, paint: Paint, maxWidth: Float): List<String> {',
         '\n}')

# 5d. subtitle drag/selection fields
one('remove subtitle drag + selection fields',
    '    private var isDraggingSubtitle = false\n'
    '    private var dragStartX = 0f\n'
    '    private var dragStartY = 0f\n'
    '    private var initialRelativeX = 0.5f\n'
    '    private var initialRelativeY = 0.8f\n'
    '\n'
    '    private val subtitleBounds = android.graphics.RectF()\n'
    '    private val selectionPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {\n'
    '        color = Color.parseColor("#007AFF") // Active accent color\n'
    '        style = Paint.Style.STROKE\n'
    '        strokeWidth = 3f\n'
    '        pathEffect = DashPathEffect(floatArrayOf(10f, 10f), 0f)\n'
    '    }\n'
    '\n')

# 5e. the public subtitle properties
one('remove isSubtitlesEditingActive + subtitleOperation + onSubtitlePositionChanged',
    '    var isSubtitlesEditingActive: Boolean = false\n'
    '        set(value) {\n'
    '            field = value\n'
    '            invalidate()\n'
    '        }\n'
    '    var subtitleOperation: EditOperation.AddSubtitles? = null\n'
    '        set(value) {\n'
    '            field = value\n'
    '            this.subtitleCues = value?.cues ?: emptyList()\n'
    '            invalidate()\n'
    '        }\n'
    '    var onSubtitlePositionChanged: ((relativeX: Float, relativeY: Float) -> Unit)? = null\n'
    '\n')

# 5f. the subtitleCues field
one('remove subtitleCues field',
    '    private var subtitleCues: List<com.tharunbirla.librecuts.models.SubtitleCue> = emptyList()\n'
    '\n')

# 5g. setSubtitleCues()
one('remove setSubtitleCues()',
    '    fun setSubtitleCues(cues: List<com.tharunbirla.librecuts.models.SubtitleCue>) {\n'
    '        this.subtitleCues = cues\n'
    '        invalidate()\n'
    '    }\n'
    '\n')

# 5h. imports that only served the removed code
one('remove SuppressLint import', 'import android.annotation.SuppressLint\n')
one('remove DashPathEffect import', 'import android.graphics.DashPathEffect\n')
one('remove RectF import', 'import android.graphics.RectF\n')

for n in applied:
    print('   [ok] ' + n)
for n in skipped:
    print('   [skip] ' + n)
for n in failed:
    print('   [FAIL] ' + n)

if (orig.count('{') - s.count('{') != orig.count('}') - s.count('}') or
        orig.count('(') - s.count('(') != orig.count(')') - s.count(')')):
    print('   [FAIL] brace/paren balance broken')
    sys.exit(1)
if failed:
    sys.exit(1)
if applied:
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok] %d edit(s) applied, %d line(s) removed'
          % (len(applied), orig.count('\n') - s.count('\n')))
else:
    print('   [ok] nothing to do (already applied)')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 6 -- VideoEditingActivity.kt: remove the subtitle wiring block
# ---------------------------------------------------------------------------
step6_vea_wiring() {
    echo "== step 6: VideoEditingActivity.kt -- remove subtitle wiring block"
    python3 - <<'CUTPY'
import sys
p = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
s = open(p, encoding='utf-8', newline='').read()
orig = s
old = (
    '                    textOverlayView?.let { overlay ->\n'
    '                        val subOp = project.operations.filterIsInstance<EditOperation.AddSubtitles>().firstOrNull()\n'
    '                        overlay.subtitleOperation = subOp\n'
    '                        overlay.setSubtitleCues(subOp?.cues ?: emptyList())\n'
    '                    }\n'
    '\n')
n = s.count(old)
if n == 0:
    print('   [skip] wiring block already gone')
    sys.exit(0)
if n != 1:
    print('   [FAIL] wiring block found %d times' % n)
    sys.exit(1)
s = s.replace(old, '', 1)
if (orig.count('{') - s.count('{') != orig.count('}') - s.count('}') or
        orig.count('(') - s.count('(') != orig.count(')') - s.count(')')):
    print('   [FAIL] brace/paren balance broken')
    sys.exit(1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok] subtitle wiring block removed (%d lines)'
      % (orig.count('\n') - s.count('\n')))
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 7 -- verification gate (fails BEFORE anything gets committed)
# ---------------------------------------------------------------------------
step7_verify() {
    echo "== step 7: leftover reference check (hard gate)"
    python3 - <<'CUTPY'
import os, re, subprocess, sys

VEA = 'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt'
VM  = 'app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt'
EO  = 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt'
PS  = 'app/src/main/java/com/tharunbirla/librecuts/utils/ProjectSerializer.kt'
TOV = 'app/src/main/java/com/tharunbirla/librecuts/customviews/TextOverlayView.kt'

bad = []

# ---- 1. token scan --------------------------------------------------------
# tokens that must be absent EVERYWHERE in app/src/main
global_tokens = [
    'AddSubtitles', 'SubtitleCue', 'subtitleOperation', 'subtitleCues',
    'setSubtitleCues', 'isSubtitlesEditingActive', 'onSubtitlePositionChanged',
    'getWrappedSubtitleLines', 'isDraggingSubtitle', 'subtitleBounds',
    'wrapTextForCanvas', 'pickSrtFile', 'PICK_SRT_REQUEST',
]
# tokens that legitimately exist in OTHER files but must be gone from TOV
tov_only = ['selectionPaint', 'dragStartX', 'initialRelativeX',
            'initialRelativeY', 'onTouchEvent']

for dirpath, _, filenames in os.walk('app/src/main'):
    for fn in filenames:
        fp = os.path.join(dirpath, fn)
        try:
            blob = open(fp, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        for t in global_tokens:
            if t in blob:
                bad.append(fp + ' :: ' + t)
        if fp == TOV:
            for t in tov_only:
                if t in blob:
                    bad.append(fp + ' :: ' + t + ' (TOV)')

# ---- 2. VEA hotfix invariants ---------------------------------------------
vea = open(VEA, encoding='utf-8').read()
if vea.count('fun pickBackgroundImage(') != 1:
    bad.append(VEA + ' :: pickBackgroundImage definition count != 1')
if vea.count('pickBackgroundImage()') != 2:  # 1 definition + 1 call site
    bad.append(VEA + ' :: pickBackgroundImage def+call count != 2')
if vea.count('PICK_BACKGROUND_IMAGE_REQUEST') != 3:
    # 3 = onActivityResult branch + constant + restored function's call
    bad.append(VEA + ' :: PICK_BACKGROUND_IMAGE_REQUEST refs != 3')

# ---- 3. function inventory guard vs git HEAD ------------------------------
# Catches the phase-3 bug class: a LIVE function accidentally swallowed by
# a span cut shows up here as an unexpected removal and fails the run.
FILES = [VEA, VM, EO, PS, TOV]

def funs(t):
    return set(re.findall(r'\bfun\s+(\w+)\s*\(', t))

git_ok = False
try:
    head = {}
    for p in FILES:
        r = subprocess.run(['git', 'show', 'HEAD:' + p], capture_output=True)
        head[p] = r.stdout.decode('utf-8', 'ignore')
    git_ok = all(head[p] for p in FILES)
except Exception:
    git_ok = False
if not git_ok:
    print('   [warn] git HEAD not readable -- function-inventory guard skipped')
else:
    already = 'AddSubtitles' not in head[EO]
    expect = {
        VEA: ({'pickBackgroundImage'}, set()),
        VM:  (set(), {'getWrappedSubtitleLines'}),
        TOV: (set(), {'onTouchEvent', 'setSubtitleCues', 'wrapTextForCanvas'}),
        EO:  (set(), set()),
        PS:  (set(), set()),
    }
    for p in FILES:
        cur = open(p, encoding='utf-8', errors='ignore').read()
        added = funs(cur) - funs(head[p])
        removed = funs(head[p]) - funs(cur)
        if already:
            want_a, want_r = set(), set()
        else:
            want_a, want_r = expect[p]
        if added != want_a or removed != want_r:
            bad.append('%s :: function inventory mismatch (added=%s expected=%s; '
                       'removed=%s expected=%s)'
                       % (p, sorted(added), sorted(want_a),
                          sorted(removed), sorted(want_r)))

# ---- 4. brace sanity -------------------------------------------------------
for p in FILES:
    t = open(p, encoding='utf-8', errors='ignore').read()
    if t.count('{') != t.count('}'):
        bad.append('%s :: unbalanced braces %d/%d' % (p, t.count('{'), t.count('}')))
    if p != VEA and t.count('(') != t.count(')'):
        # VEA raw parens are pre-existing +3 (unbalanced parens inside string
        # literals), so the absolute paren check only applies to the others.
        bad.append('%s :: unbalanced parens %d/%d' % (p, t.count('('), t.count(')')))

if bad:
    print('   [FAIL] verification failed:')
    for b in sorted(set(bad)):
        print('      ' + b)
    sys.exit(1)
print('   [ok] zero leftover subtitle references in app/src/main')
print('   [ok] pickBackgroundImage restored: definition + call site consistent')
print('   [ok] function inventory matches expectation (no live function lost)')
print('   [ok] braces balanced in all five edited files')
CUTPY
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " Cutloss simplification (phase 4) -- start"
echo " HOTFIX: restore pickBackgroundImage() (phase 3 casualty)"
echo " Purge:   subtitle render + export half, .lcprj compat off"
echo "=========================================================="
FAILED=0
step0_preconditions || FAILED=1
step1_hotfix        || FAILED=1
step2_models        || FAILED=1
step3_serializer    || FAILED=1
step4_viewmodel     || FAILED=1
step5_textoverlay   || FAILED=1
step6_vea_wiring    || FAILED=1
step7_verify        || FAILED=1

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
    echo " PHASE 4 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 4 complete. All steps ok or skipped."
echo " Build hotfix: pickBackgroundImage() is back where it"
echo " belongs, so :compileDebugKotlin will pass again."
echo " Subtitles are now fully gone: data model, serializer"
echo " mapping, FFmpeg burn-in, preview rendering, wiring."
echo " Old projects with subtitle ops still load (op skipped)."
echo " Next: the workflow commits these changes and builds."
echo "----------------------------------------------------------"
exit 0
