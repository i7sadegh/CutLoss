#!/usr/bin/env bash
###############################################################################
# CutLoss phase 19a -- the phase-19 scope-fix patch (build repair)
#
# User report (GitHub Actions build log):
#   :app:compileDebugKotlin FAILED with
#     SmartExportPlanner.kt:1140:25 Unresolved reference 'framesDir'.
#     SmartExportPlanner.kt:1144:21 Unresolved reference 'rightStartMs'.
#     SmartExportPlanner.kt:1144:69 Unresolved reference 'rightStartMs'.
#
# Root cause (verified against commit 8525ac2 "Apply changes from
# apply-changes.sh"):
#   The phase-19 edit moved the two local declarations
#       val rightStartMs = right.trimStartMs
#       val framesDir = File(workDir, "trans_" + gap)
#   INSIDE the new try { ... } finally { ... } block that shares one
#   MediaMetadataRetriever per clip path. But the transition segment
#   command builder that runs BELOW the finally block still reads both:
#       line 1140:  .append(framesDir.absolutePath).append("/frame_%04d.jpg")
#       line 1144:  if (rightStartMs > 0L) sb.append(" -ss ").append(ms(rightStartMs))
#   Kotlin block scoping makes them invisible there -> the three
#   unresolved-reference errors -> the whole build fails.
#
# Fix (1 file, 1 edit, zero behavior change):
#   SmartExportPlanner.kt: hoist the two declarations OUT of the try
#   block so they stay in scope for the whole addFreezeTransitionSegment
#   body. Runtime semantics are identical (the values never change
#   between declaration and use; the early `return false` paths still
#   run the finally block that releases the retrievers). Everything
#   else from phase 19 - the shared retrievers, the 1-14% preparation
#   progress ticks, the amber theme, the English-only resources, the
#   fullscreen-off default - is untouched.
#
# Idempotent: re-running skips the edit when already present.
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

if [ ! -f "$PLANNER" ]; then
  echo "FATAL: $PLANNER not found - run from the repository root at the expected commit"
  exit 1
fi

echo "== phase 19a: applying the phase-19 scope fix (framesDir / rightStartMs) =="

python3 - <<'PYEOF'
import sys

PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

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
# The single edit: hoist rightStartMs + framesDir out of the try block.
# ---------------------------------------------------------------------------
OLD = (
    "            var renderOk = false\n"
    "            var endA: android.graphics.Bitmap? = null\n"
    "            try {\n"
    "                endA = frameAt(\n"
    "                    leftRetriever, (left.trimEndMs - 1L).coerceAtLeast(left.trimStartMs)\n"
    "                )\n"
    "                if (endA == null) return false\n"
    "                val rightStartMs = right.trimStartMs\n"
    "                val framesDir = File(workDir, \"trans_\" + gap)\n"
    "                renderOk = TransitionFrameRenderer.renderTransitionFrames(\n"
)

NEW = (
    "            // phase 19a: scope fix - the segment command builder BELOW\n"
    "            // the finally block reads rightStartMs and framesDir, so both\n"
    "            // must be declared OUTSIDE the try (the phase-19 edit moved\n"
    "            // them inside and broke the build: unresolved references at\n"
    "            // the -i framesDir / -ss rightStartMs command lines)\n"
    "            val rightStartMs = right.trimStartMs\n"
    "            val framesDir = File(workDir, \"trans_\" + gap)\n"
    "            var renderOk = false\n"
    "            var endA: android.graphics.Bitmap? = null\n"
    "            try {\n"
    "                endA = frameAt(\n"
    "                    leftRetriever, (left.trimEndMs - 1L).coerceAtLeast(left.trimStartMs)\n"
    "                )\n"
    "                if (endA == null) return false\n"
    "                renderOk = TransitionFrameRenderer.renderTransitionFrames(\n"
)

apply_edit(PLANNER, OLD, NEW, "hoist rightStartMs/framesDir out of the try block")

print("edits applied: " + str(edits_applied) + ", skipped: " + str(edits_skipped))
PYEOF

echo "== phase 19a: gates =="

python3 - <<'PYEOF'
import sys

PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"

with open(PLANNER, "r") as f:
    s = f.read()

failures = []

def gate(name, ok, detail=""):
    print(("  [ OK ] " if ok else "  [FAIL] ") + name + ((" - " + detail) if detail else ""))
    if not ok:
        failures.append(name)

# 1. exactly one declaration of each hoisted local
gate("rightStartMs declared once", s.count("val rightStartMs = right.trimStartMs") == 1)
gate("framesDir declared once", s.count('val framesDir = File(workDir, "trans_" + gap)') == 1)

# 2. scope order: both declarations now sit BEFORE the try block that
#    guards the retriever lifecycle, i.e. before `var renderOk = false`
dec_rs = s.find("val rightStartMs = right.trimStartMs")
dec_fd = s.find('val framesDir = File(workDir, "trans_" + gap)')
anchor = s.find("var renderOk = false")
gate("rightStartMs above the try guard", 0 <= dec_rs < anchor,
     "decl@" + str(dec_rs) + " guard@" + str(anchor))
gate("framesDir above the try guard", 0 <= dec_fd < anchor,
     "decl@" + str(dec_fd) + " guard@" + str(anchor))

# 3. the downstream readers (the lines the compiler rejected) are intact
gate("framesDir.absolutePath reader intact", s.count('.append(framesDir.absolutePath).append("/frame_%04d.jpg\\"")') == 1)
gate("rightStartMs -ss reader intact", s.count("if (rightStartMs > 0L)") == 1)
gate("ms(rightStartMs) reader intact", s.count("ms(rightStartMs)") == 1)

# 4. the declaration lines are no longer INSIDE the try block: the try
#    guard must not appear between the retriever open lines and them
left_open = s.find("val leftRetriever = openRetriever(left.path)")
gate("declarations after retriever open", 0 <= left_open < dec_rs,
     "open@" + str(left_open) + " decl@" + str(dec_rs))

# 5. phase-19 machinery untouched
gate("onPrepareProgress param present", s.count("onPrepareProgress: ((Int, Int) -> Unit)? = null") == 2)
gate("openRetriever helper present", s.count("fun openRetriever(path: String)") == 1)
gate("frameAt helper present", s.count("fun frameAt(retriever: android.media.MediaMetadataRetriever?") == 1)
gate("prepFrameTick present", s.count("var prepFrameTick = 5") == 1)

# 6. the finally block still releases the shared retrievers
gate("finally releases endA", s.count("try { endA?.recycle() } catch (e: Exception) {}") == 1)
gate("finally releases leftRetriever", s.count("try { leftRetriever?.release() } catch (e: Exception) {}") == 1)
gate("finally releases distinct rightRetriever", s.count("if (rightRetriever !== leftRetriever)") == 1)

# 7. survival gates from the earlier phases
gate("filter_complex stays banned", "filter_complex" not in s)
gate("fpsCloseEnough survives", s.count("fun fpsCloseEnough(") == 1)

# 8. ASCII purity of the edited file
try:
    s.encode("ascii")
    gate("planner is pure ASCII", True)
except UnicodeEncodeError as e:
    gate("planner is pure ASCII", False, str(e))

# 9. brace/paren balance outside literals (kotlin-lite stack machine)
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
            if ch == "'" :
                stack.append(("char", 0))
                i += 1
                continue
            if ch == "{":
                depth += 1
                i += 1
                continue
            i += 1
            continue
        # code mode
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

errs = scan(s)
gate("kotlin-lite brace/paren balance", not errs, "; ".join(errs[:3]))

if failures:
    print("GATE FAILURES: " + ", ".join(failures))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 19a: done =="
