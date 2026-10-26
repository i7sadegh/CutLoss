#!/usr/bin/env bash
###############################################################################
# CutLoss phase 10.2 -- "trim + same as source must be a remux"
#
# User complaint this script answers: with ONLY a trim on the timeline and
# every setting on "same as source", the export dialog showed a giant
# -filter_complex re-encode command (canvas/scale/overlay/fps/format per
# input + concat filter + libx264) and the note "video edits present ->
# stream copy not possible". That is the phase-9 LEGACY preview: the
# phase-10 honest smart preview never reached a phone because CI failed
# to compile (ExportService.kt:232 return type mismatch).
#
# This script makes "just a trim" behave like LosslessCut out of the box:
#
#   1. FOLDS IN the phase-10.1 compile fix (runSmartExport mid-loop
#      return wraps its RenderResult in SmartExportOutcome). Skipped
#      automatically when the tree already contains the fix, so the
#      script works whether or not 10.1 was uploaded before this one.
#
#   2. keyframeCut DEFAULT false -> true (AdvancedExport): trim points
#      snap to the preceding keyframe, so every trimmed span becomes a
#      pure stream copy (-ss before -i + -c copy + -avoid_negative_ts
#      make_zero). Trim-only projects are now lossless + fast by default.
#      "Normal (accurate)" stays one tap away for frame-exact cuts.
#
#   3. Export resolution/fps DEFAULTS 1080/30 -> 0 (= same as input).
#      The old defaults silently disabled the smart stream-copy path for
#      any source that was not exactly 1080p/30fps (720x1280 portrait
#      phones included) and forced a pointless rescale. Now the dialog
#      opens with "Same as input" pre-selected on both rows.
#
#   4. The editor's quality bottom sheet gains "Same as input" chips
#      (it only had 360p..2160p / 24..60 and hardcoded 1080/30) and maps
#      value 0 <-> those chips, so both surfaces agree.
#
#   5. dialog_export_settings.xml: the statically checked Cut Mode chip
#      moves from "Normal (accurate)" to "Keyframe (fast, lossless)" to
#      match the new default before wireChipRow runs.
#
# Invariants: pure ASCII, idempotent (2nd run = all [skip], zero diff),
# hard verification gate exits 1 BEFORE anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase10.2] $*"; }
fail() { echo "[phase10.2][ERROR] $*" >&2; exit 1; }

VM="app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
EXPS="app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
SHEETXML="app/src/main/res/layout/export_quality_bottom_sheet_dialog.xml"
DLGXML="app/src/main/res/layout/dialog_export_settings.xml"

###############################################################################
# Step 0 -- preconditions (phase-10 base must already be in the tree)
###############################################################################
log "step0: checking preconditions"
[ -f "$VM" ]        || fail "VideoEditingViewModel.kt not found"
[ -f "$VEA" ]       || fail "VideoEditingActivity.kt not found"
[ -f "$ESD" ]       || fail "ExportSettingsDialog.kt not found"
[ -f "$EXPS" ]      || fail "ExportService.kt not found"
[ -f "$SHEETXML" ]  || fail "export_quality_bottom_sheet_dialog.xml not found"
[ -f "$DLGXML" ]    || fail "dialog_export_settings.xml not found"

grep -Fq "fun analyzeSmartExport(" app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt \
  || fail "phase-10 base required (analyzeSmartExport missing)"
grep -Fq "data class SmartExportOutcome(" "$EXPS" \
  || fail "phase-10 base required (SmartExportOutcome missing)"
grep -Fq "private suspend fun runSmartExport(planPath: String): SmartExportOutcome" "$EXPS" \
  || fail "phase-10 base required (runSmartExport signature missing)"
grep -Fq "cgCutMode" "$DLGXML" \
  || fail "phase-10 base required (cut mode chips missing)"
grep -Fq "keyframeCut = selKeyframeCut," "$ESD" \
  || fail "phase-10 base required (keyframe chip wiring missing)"

if grep -Fq "private val _exportResolution = MutableStateFlow(0)" "$VM"; then
  log "step0: phase-10.2 markers present -> partial SKIP mode (idempotent re-run)"
fi

###############################################################################
# Step 1 -- ExportService.kt compile fix (phase 10.1, folded in)
###############################################################################
if grep -Fq "return SmartExportOutcome(result, emptyList())" "$EXPS"; then
  log "step1: [skip] compile fix already applied"
else
python3 <<'FIXPY'
import sys

def die(m):
    print("[phase10.2][ERROR] " + m)
    sys.exit(1)

E = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
with open(E, "r", encoding="utf-8") as f:
    s = f.read()

old = """            if (result !is FFmpegRenderEngine.RenderResult.Success) {
                return result
            }
"""
new = """            if (result !is FFmpegRenderEngine.RenderResult.Success) {
                // Phase 10.1: wrap the render failure so the return type
                // matches SmartExportOutcome; outputFiles is only read on
                // success, so an empty list is correct here.
                return SmartExportOutcome(result, emptyList())
            }
"""
n = s.count(old)
if n == 0:
    die("compile-fix anchor not found (unexpected ExportService state)")
if n > 1:
    die("compile-fix anchor not unique (%d hits)" % n)

s = s.replace(old, new, 1)
with open(E, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase10.2] step1: ExportService compile fix applied (SmartExportOutcome wrap)")
FIXPY
fi

echo "[phase10.2] step1 done"

###############################################################################
# Step 2 -- VideoEditingViewModel.kt (lossless defaults)
###############################################################################
if grep -Fq "private val _exportResolution = MutableStateFlow(0)" "$VM"; then
  log "step2: [skip] VM defaults already flipped"
else
python3 <<'VMPY'
import sys

def die(m):
    print("[phase10.2][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def must_replace(s, old, new, what):
    if old not in s:
        die("VM anchor missing: " + what)
    if s.count(old) != 1:
        die("VM anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

V = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
s = rw(V)

# ---- 2a. resolution/fps defaults: 1080/30 -> 0 (same as input) ------------
old = """    private val _exportResolution = MutableStateFlow(1080)
    private val _exportFps = MutableStateFlow(30)
"""
new = """    private val _exportResolution = MutableStateFlow(0)   // 0 = same as input
    private val _exportFps = MutableStateFlow(0)          // 0 = same as input
"""
s = must_replace(s, old, new, "export resolution/fps defaults")

# ---- 2b. keyframeCut default: false -> true (lossless trims) --------------
old = """        val keyframeCut: Boolean = false,     // trim points snap to keyframes -> pure stream copy
"""
new = """        val keyframeCut: Boolean = true,      // DEFAULT: lossless keyframe trim (pure stream copy)
"""
s = must_replace(s, old, new, "keyframeCut default")

with open(V, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase10.2] step2: VM defaults flipped (res=0, fps=0, keyframeCut=true)")
VMPY
fi

echo "[phase10.2] step2 done"

###############################################################################
# Step 3 -- ExportSettingsDialog.kt (matching initial selections)
###############################################################################
if grep -Fq "private var selKeyframeCut = true" "$ESD"; then
  log "step3: [skip] ESD defaults already flipped"
else
python3 <<'ESDPY'
import sys

def die(m):
    print("[phase10.2][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def must_replace(s, old, new, what):
    if old not in s:
        die("ESD anchor missing: " + what)
    if s.count(old) != 1:
        die("ESD anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

D = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
s = rw(D)

# ---- 3a. resolution/fps initial values ------------------------------------
old = """    private var selRes = 1080            // 0 = same as input
    private var selFps = 30              // 0 = same as input
"""
new = """    private var selRes = 0               // 0 = same as input (default)
    private var selFps = 0               // 0 = same as input (default)
"""
s = must_replace(s, old, new, "selRes/selFps initial values")

# ---- 3b. keyframe cut initial value ---------------------------------------
old = """    private var selKeyframeCut = false
"""
new = """    private var selKeyframeCut = true
"""
s = must_replace(s, old, new, "selKeyframeCut initial value")

with open(D, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase10.2] step3: ESD initial selections flipped (same-as-input + keyframe)")
ESDPY
fi

echo "[phase10.2] step3 done"

###############################################################################
# Step 4 -- XML: sheet gains Same-as-input chips; dialog checked chip moves
###############################################################################
if grep -Fq '@+id/chipResSame' "$SHEETXML"; then
  log "step4: [skip] sheet XML already patched"
else
python3 <<'XMLPY'
import sys

def die(m):
    print("[phase10.2][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def must_replace(s, old, new, what):
    if old not in s:
        die("XML anchor missing: " + what)
    if s.count(old) != 1:
        die("XML anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

SEP = "                    \n"

# ---- 4a. bottom sheet: resolution "Same as input" chip --------------------
S = "app/src/main/res/layout/export_quality_bottom_sheet_dialog.xml"
s = rw(S)
old = """                <com.google.android.material.chip.Chip
                    android:id="@+id/chipRes360"
                    style="@style/Widget.MaterialComponents.Chip.Choice"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="360p" />
"""
new = """                <com.google.android.material.chip.Chip
                    android:id="@+id/chipResSame"
                    style="@style/Widget.MaterialComponents.Chip.Choice"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="Same as input" />
""" + SEP + old
s = must_replace(s, old, new, "sheet chipRes360 block")

# ---- 4b. bottom sheet: fps "Same as input" chip ---------------------------
old = """                <com.google.android.material.chip.Chip
                    android:id="@+id/chipFps24"
                    style="@style/Widget.MaterialComponents.Chip.Choice"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="24" />
"""
new = """                <com.google.android.material.chip.Chip
                    android:id="@+id/chipFpsSame"
                    style="@style/Widget.MaterialComponents.Chip.Choice"
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="Same as input" />
""" + SEP + old
s = must_replace(s, old, new, "sheet chipFps24 block")
with open(S, "w", encoding="utf-8") as f:
    f.write(s)

# ---- 4c. dialog: statically checked cut-mode chip -> Keyframe -------------
D = "app/src/main/res/layout/dialog_export_settings.xml"
s = rw(D)
old = '<com.google.android.material.chip.Chip android:id="@+id/chipCutNormal" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Normal (accurate)" android:checked="true" />'
new = '<com.google.android.material.chip.Chip android:id="@+id/chipCutNormal" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Normal (accurate)" />'
s = must_replace(s, old, new, "dialog chipCutNormal (drop checked)")

old = '<com.google.android.material.chip.Chip android:id="@+id/chipCutKeyframe" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Keyframe (fast, lossless)" />'
new = '<com.google.android.material.chip.Chip android:id="@+id/chipCutKeyframe" style="@style/Widget.MaterialComponents.Chip.Choice" android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="Keyframe (fast, lossless)" android:checked="true" />'
s = must_replace(s, old, new, "dialog chipCutKeyframe (add checked)")
with open(D, "w", encoding="utf-8") as f:
    f.write(s)

print("[phase10.2] step4: sheet Same-as-input chips added; dialog default cut chip = Keyframe")
XMLPY
fi

echo "[phase10.2] step4 done"

###############################################################################
# Step 5 -- VideoEditingActivity.kt (bottom sheet 0 <-> Same wiring)
###############################################################################
if grep -Fq "0 -> cgResolution.check(R.id.chipResSame)" "$VEA"; then
  log "step5: [skip] VEA sheet wiring already patched"
else
python3 <<'VEAPY'
import sys

def die(m):
    print("[phase10.2][ERROR] " + m)
    sys.exit(1)

def rw(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def must_replace(s, old, new, what):
    if old not in s:
        die("VEA anchor missing: " + what)
    if s.count(old) != 1:
        die("VEA anchor not unique (%d hits): %s" % (s.count(old), what))
    return s.replace(old, new, 1)

A = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
s = rw(A)

# ---- 5a. open-state: value 0 checks the Same chips -------------------------
old = """        when (currentRes) {
            360 -> cgResolution.check(R.id.chipRes360)
"""
new = """        when (currentRes) {
            0 -> cgResolution.check(R.id.chipResSame)
            360 -> cgResolution.check(R.id.chipRes360)
"""
s = must_replace(s, old, new, "when(currentRes) branch")

old = """        when (currentFps) {
            24 -> cgFps.check(R.id.chipFps24)
"""
new = """        when (currentFps) {
            0 -> cgFps.check(R.id.chipFpsSame)
            24 -> cgFps.check(R.id.chipFps24)
"""
s = must_replace(s, old, new, "when(currentFps) branch")

# ---- 5b. save: Same chips write value 0 ------------------------------------
old = """            val res = when (cgResolution.checkedChipId) {
                R.id.chipRes360 -> 360
"""
new = """            val res = when (cgResolution.checkedChipId) {
                R.id.chipResSame -> 0
                R.id.chipRes360 -> 360
"""
s = must_replace(s, old, new, "saveSettings res map")

old = """            val fps = when (cgFps.checkedChipId) {
                R.id.chipFps24 -> 24
"""
new = """            val fps = when (cgFps.checkedChipId) {
                R.id.chipFpsSame -> 0
                R.id.chipFps24 -> 24
"""
s = must_replace(s, old, new, "saveSettings fps map")

with open(A, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase10.2] step5: VEA bottom sheet wired for Same-as-input (0 <-> Same chips)")
VEAPY
fi

echo "[phase10.2] step5 done"

###############################################################################
# Step 6 -- verification gate (inventory, XML, balance, ASCII, survival)
#           exits 1 BEFORE anything commits
###############################################################################
log "step6: running verification gate"

python3 <<'GATEPY'
import subprocess
import sys
import xml.dom.minidom as minidom

def die(m):
    print("[phase10.2][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def head(p):
    r = subprocess.run(["git", "show", "HEAD:" + p], capture_output=True, text=True)
    if r.returncode != 0:
        die("git show failed for " + p)
    return r.stdout

VM = "app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"
ESD = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
EXPS = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
SHEET = "app/src/main/res/layout/export_quality_bottom_sheet_dialog.xml"
DLG = "app/src/main/res/layout/dialog_export_settings.xml"

vm, vea, esd, exps = rd(VM), rd(VEA), rd(ESD), rd(EXPS)
sheet, dlg = rd(SHEET), rd(DLG)

# ---- 6a. inventory ---------------------------------------------------------
inv = [
    (VM, vm, "private val _exportResolution = MutableStateFlow(0)"),
    (VM, vm, "private val _exportFps = MutableStateFlow(0)"),
    (VM, vm, "val keyframeCut: Boolean = true,"),
    (ESD, esd, "private var selRes = 0"),
    (ESD, esd, "private var selFps = 0"),
    (ESD, esd, "private var selKeyframeCut = true"),
    (VEA, vea, "0 -> cgResolution.check(R.id.chipResSame)"),
    (VEA, vea, "0 -> cgFps.check(R.id.chipFpsSame)"),
    (VEA, vea, "R.id.chipResSame -> 0"),
    (VEA, vea, "R.id.chipFpsSame -> 0"),
    (EXPS, exps, "return SmartExportOutcome(result, emptyList())"),
    (EXPS, exps, "private suspend fun runSmartExport(planPath: String): SmartExportOutcome"),
    (SHEET, sheet, '@+id/chipResSame'),
    (SHEET, sheet, '@+id/chipFpsSame'),
    (SHEET, sheet, 'android:text="Same as input"'),
    (DLG, dlg, 'android:text="Keyframe (fast, lossless)" android:checked="true"'),
]
for path, body, tok in inv:
    if tok not in body:
        die("inventory: expected token missing in %s: %r" % (path, tok))

# the old defaults must be gone
gone = [
    (VM, vm, "MutableStateFlow(1080)"),
    (VM, vm, "MutableStateFlow(30)"),
    (VM, vm, "val keyframeCut: Boolean = false,"),
    (ESD, esd, "private var selRes = 1080"),
    (ESD, esd, "private var selFps = 30"),
    (EXPS, exps, "\n                return result\n"),
    (DLG, dlg, 'android:text="Normal (accurate)" android:checked="true"'),
]
for path, body, tok in gone:
    if tok in body:
        die("inventory: stale token still present in %s: %r" % (path, tok))
print("[ok] inventory: 16 new tokens present, 7 stale tokens gone")

# ---- 6b. exact wiring counts ----------------------------------------------
checks = [
    (vm, vm.count("MutableStateFlow(0)"), 2, "VM MutableStateFlow(0) count"),
    (vm, vm.count("val keyframeCut: Boolean = true,"), 1, "VM keyframeCut=true decl"),
    (esd, esd.count("wireChipRow("), 13, "ESD wireChipRow decl+calls (1+12)"),
    (esd, esd.count("selKeyframeCut = true"), 1, "ESD selKeyframeCut=true"),
    (vea, vea.count("chipResSame"), 2, "VEA chipResSame refs (check + map)"),
    (vea, vea.count("chipFpsSame"), 2, "VEA chipFpsSame refs (check + map)"),
    (exps, exps.count("SmartExportOutcome("), 6, "EXPS SmartExportOutcome decl+ctors"),
    (exps, exps.count("return SmartExportOutcome("), 5, "EXPS return SmartExportOutcome count"),
    (exps, exps.count("saveVideoToGallery("), 3, "EXPS saveVideoToGallery decl+calls"),
]
for body, got, want, what in checks:
    if got != want:
        die("count gate: %s = %d, expected %d" % (what, got, want))
print("[ok] wiring counts: 9/9")

# ---- 6c. brace/paren balance vs HEAD --------------------------------------
for f in [VM, VEA, ESD, EXPS]:
    new, old = rd(f), head(f)
    db = new.count("{") - old.count("{") - (new.count("}") - old.count("}"))
    dp = new.count("(") - old.count("(") - (new.count(")") - old.count(")"))
    if db != 0:
        die("brace delta mismatch in %s (%+d)" % (f, db))
    if dp != 0:
        die("paren delta mismatch in %s (%+d)" % (f, dp))
print("[ok] brace/paren balance vs HEAD for 4 Kotlin files")

# ---- 6d. XML parse + ids --------------------------------------------------
for f, want_ids in [
    (SHEET, ["@+id/chipResSame", "@+id/chipFpsSame"]),
    (DLG, []),
]:
    try:
        dom = minidom.parse(f)
    except Exception as e:
        die("XML parse failed for %s: %s" % (f, str(e)))
    ids = [e.getAttribute("android:id") for e in dom.getElementsByTagName("*") if e.hasAttribute("android:id")]
    dup = [i for i in set(ids) if ids.count(i) > 1]
    if dup:
        die("duplicate android:id in %s: %s" % (f, ", ".join(dup)))
    for want in want_ids:
        if want not in ids:
            die("XML missing new id in %s: %s" % (f, want))
print("[ok] XML parses; sheet has chipResSame/chipFpsSame; no duplicate ids")

# ---- 6e. survival asserts (phase-9/10 machinery untouched) ----------------
surv = [
    (VM, vm, "fun setExportSettings("),
    (VM, vm, "private fun buildOutputScaleFilter("),
    (VM, vm, "private fun appendOutputContainerArgs("),
    (ESD, esd, "fun smartUnavailableNote(): String?"),
    (ESD, esd, "fun buildSmartSummary(): String?"),
    (ESD, esd, "fun smartEstimateBytes(): Double?"),
    (ESD, esd, "keyframeCut = selKeyframeCut,"),
    (ESD, esd, "exportSeparateFiles = selSeparateFiles,"),
    (ESD, esd, "R.id.chipResSame to 0"),
    (ESD, esd, "R.id.chipFpsSame to 0"),
    (VEA, vea, "keyframeCut = viewModel.advancedExport.value.keyframeCut,"),
    (VEA, vea, "SmartExportPlanner.planSmartExport("),
    (VEA, vea, "ExportService.EXTRA_SMART_PLAN_PATH"),
    (EXPS, exps, "EXTRA_SMART_PLAN_PATH"),
    (EXPS, exps, "val smartFiles = smartOutcome?.outputFiles ?: emptyList()"),
    (EXPS, exps, "files saved to gallery"),
]
for path, body, tok in surv:
    if tok not in body:
        die("survival: token missing in %s: %r" % (path, tok))
print("[ok] survival: %d kept-feature tokens present" % len(surv))

# ---- 6f. ASCII purity (no NEW non-ASCII bytes vs HEAD) --------------------
for f in [VM, VEA, ESD, EXPS, SHEET, DLG]:
    b = open(f, "rb").read()
    h = head(f).encode("utf-8", "surrogateescape")
    n_new = sum(1 for c in b if c > 127)
    n_old = sum(1 for c in h if c > 127)
    if n_new != n_old:
        die("non-ASCII byte count changed in %s (%d -> %d)" % (f, n_old, n_new))
print("[ok] ASCII purity: no new non-ASCII bytes in 6 modified files")

print("[phase10.2] step6: ALL GATES GREEN")
GATEPY

###############################################################################
# Step 7 -- scope + .github policy (final pre-commit safety net)
###############################################################################
log "step7: scope gate"

SCOPE_OK=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  path="$(echo "$line" | awk '{print $NF}')"
  case "$path" in
    "$VM"|"$VEA"|"$ESD"|"$EXPS"|"$SHEETXML"|"$DLGXML"|scripts/apply-changes.sh) ;;
    *) echo "[phase10.2][ERROR] out-of-scope change: $path" >&2; SCOPE_OK=1 ;;
  esac
done < <(git status --porcelain)

[ "$SCOPE_OK" = "0" ] || fail "scope gate failed (unexpected files modified)"

if git status --porcelain | grep -q "\.github/"; then
  fail "POLICY: workflow files must never be modified by this script"
fi

log "ALL DONE -- phase 10.2 applied cleanly"
log "summary: trim + same-as-source now defaults to lossless keyframe stream copy (res=0, fps=0, keyframeCut=true) + 10.1 compile fix folded in"
