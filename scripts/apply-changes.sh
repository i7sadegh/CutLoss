#!/usr/bin/env bash
###############################################################################
# CutLoss phase 10.1 -- hotfix for the phase-10 compile error
#
# CI failure that this script repairs:
#   ExportService.kt:232:24 Return type mismatch: expected
#   'ExportService.SmartExportOutcome', actual
#   'FFmpegRenderEngine.RenderResult'
#
# Root cause: the phase-10 script retyped runSmartExport's HEAD to return
# SmartExportOutcome (step 3d) but left the phase-9 command loop body
# untouched; its mid-loop early return still returned the raw
# RenderResult value ("return result"). Fix: wrap it ->
# return SmartExportOutcome(result, emptyList()). The caller reads
# outputFiles only inside the Success branch, so an empty output list on
# failure/cancel is the correct semantics (and the smart workdir is
# cleaned up right afterwards anyway).
#
# This script REPLACES the phase-10 apply-changes.sh (phase-10 content is
# already committed in the tree at 649bd0c). Precondition: the phase-10
# state must be present; on any other tree state the script fails fast
# with a clear message instead of guessing.
#
# Invariants: pure ASCII, idempotent (2nd run = [skip], zero diff),
# touches exactly one source file, hard verification gate exits 1 BEFORE
# anything can be committed.
###############################################################################
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

log()  { echo "[phase10.1] $*"; }
fail() { echo "[phase10.1][ERROR] $*" >&2; exit 1; }

EXPS="app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"

###############################################################################
# Step 0 -- preconditions (phase-10 base must already be in the tree)
###############################################################################
log "step0: checking preconditions"
[ -f "$EXPS" ] || fail "ExportService.kt not found"
grep -Fq "data class SmartExportOutcome(" "$EXPS" \
  || fail "phase-10 base required (SmartExportOutcome missing from ExportService)"
grep -Fq "private suspend fun runSmartExport(planPath: String): SmartExportOutcome" "$EXPS" \
  || fail "phase-10 runSmartExport signature missing (unexpected tree state)"
grep -Fq "private fun parseSmartPlan(" "$EXPS" \
  || fail "phase-10 parseSmartPlan missing (unexpected tree state)"
grep -Fq "runSmartExport(smartPlanPath)" "$EXPS" \
  || fail "smart outcome wiring missing (unexpected tree state)"

###############################################################################
# Step 1 -- the fix (idempotent)
###############################################################################
if grep -Fq "return SmartExportOutcome(result, emptyList())" "$EXPS"; then
  log "step1: [skip] hotfix already applied"
else
python3 <<'FIXPY'
import sys

def die(m):
    print("[phase10.1][ERROR] " + m)
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
    if "return SmartExportOutcome(result, emptyList())" in s:
        die("inconsistent state: fixed line present but bash wrapper did not skip")
    die("buggy snippet not found -- tree state not understood")
if n > 1:
    die("buggy snippet not unique (%d hits)" % n)

s = s.replace(old, new, 1)
with open(E, "w", encoding="utf-8") as f:
    f.write(s)
print("[phase10.1] step1: ExportService.kt patched (mid-loop return wraps RenderResult in SmartExportOutcome)")
FIXPY
fi

echo "[phase10.1] step1 done"

###############################################################################
# Step 2 -- verification gate (inventory, counts, balance, ASCII, survival)
#           exits 1 BEFORE anything commits
###############################################################################
log "step2: running verification gate"

python3 <<'GATEPY'
import subprocess
import sys

def die(m):
    print("[phase10.1][ERROR] " + m)
    sys.exit(1)

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def head(p):
    r = subprocess.run(["git", "show", "HEAD:" + p], capture_output=True, text=True)
    if r.returncode != 0:
        die("git show failed for " + p)
    return r.stdout

E = "app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt"
s = rd(E)

# ---- 2a. inventory: the fix is in, the bug is out -------------------------
inv = [
    "return SmartExportOutcome(result, emptyList())",
    "private suspend fun runSmartExport(planPath: String): SmartExportOutcome",
    "data class SmartExportOutcome(",
    "private data class ParsedPlan(",
    "private fun parseSmartPlan(",
    "return SmartExportOutcome(lastResult, parsed.outputs.map { File(it) })",
    "val smartOutcome: SmartExportOutcome?",
    "smartOutcome.result",
]
for tok in inv:
    if tok not in s:
        die("inventory: expected token missing: %r" % tok)
if "return result" in s:
    die("inventory: bare 'return result' still present (raw RenderResult leak)")
if s.count("return SmartExportOutcome(result, emptyList())") != 1:
    die("inventory: fixed line count != 1")
print("[ok] inventory: fix present, bug gone (%d tokens)" % len(inv))

# ---- 2b. exact wiring counts ----------------------------------------------
n_ctor = s.count("SmartExportOutcome(")
if n_ctor != 6:
    die("count gate: SmartExportOutcome( = %d, expected 6 (1 data class decl + 5 ctor calls)" % n_ctor)
n_ret = s.count("return SmartExportOutcome(")
if n_ret != 5:
    die("count gate: return SmartExportOutcome( = %d, expected 5 (4 early + 1 final)" % n_ret)
n_save = s.count("saveVideoToGallery(")
if n_save != 3:
    die("count gate: saveVideoToGallery( = %d, expected 3 (decl + 2 calls)" % n_save)
print("[ok] wiring counts: SmartExportOutcome 6 / returns 5 / saveVideoToGallery 3")

# ---- 2c. brace/paren balance vs HEAD --------------------------------------
old = head(E)
db = s.count("{") - old.count("{") - (s.count("}") - old.count("}"))
dp = s.count("(") - old.count("(") - (s.count(")") - old.count(")"))
if db != 0:
    die("brace delta mismatch (%+d)" % db)
if dp != 0:
    die("paren delta mismatch (%+d)" % dp)
print("[ok] brace/paren balance vs HEAD (delta 0/0)")

# ---- 2d. survival asserts (phase-9/10 machinery untouched) ----------------
surv = [
    "EXTRA_SMART_PLAN_PATH",
    "EXTRA_COMMAND",
    "val smartFiles = smartOutcome?.outputFiles ?: emptyList()",
    "files saved to gallery",
    "ACTION_EXPORT_SUCCESS",
    "ACTION_EXPORT_FAILURE",
    "private fun saveVideoToGallery(",
    "private fun broadcastProgress(",
    "private fun parseSmartPlan(",
    "override fun onBind(",
]
for tok in surv:
    if tok not in s:
        die("survival: token missing: %r" % tok)
print("[ok] survival: %d kept-feature tokens present" % len(surv))

# ---- 2e. ASCII purity (no NEW non-ASCII bytes) ----------------------------
b = open(E, "rb").read()
h = old.encode("utf-8", "surrogateescape")
n_new = sum(1 for c in b if c > 127)
n_old = sum(1 for c in h if c > 127)
if n_new != n_old:
    die("non-ASCII byte count changed (%d -> %d)" % (n_old, n_new))
print("[ok] ASCII purity: no new non-ASCII bytes")

print("[phase10.1] step2: ALL GATES GREEN")
GATEPY

###############################################################################
# Step 3 -- scope + .github policy (final pre-commit safety net)
###############################################################################
log "step3: scope gate"

SCOPE_OK=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  path="$(echo "$line" | awk '{print $NF}')"
  case "$path" in
    "$EXPS"|scripts/apply-changes.sh) ;;
    *) echo "[phase10.1][ERROR] out-of-scope change: $path" >&2; SCOPE_OK=1 ;;
  esac
done < <(git status --porcelain)

[ "$SCOPE_OK" = "0" ] || fail "scope gate failed (unexpected files modified)"

if git status --porcelain | grep -q "\.github/"; then
  fail "POLICY: workflow files must never be modified by this script"
fi

log "ALL DONE -- phase 10.1 hotfix applied cleanly"
log "summary: ExportService.kt mid-loop return now wraps the RenderResult in SmartExportOutcome (CI compile error fixed)"
