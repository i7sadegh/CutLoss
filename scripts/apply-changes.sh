#!/usr/bin/env bash
# ==========================================================================
#  CutStudio change pipeline -- scripts/apply-changes.sh
#  PHASE 0 (v2) -- repository cleanup
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  v2 CHANGE (after the first red run of v1):
#   v1 tried to fix .github/workflows/ci.yml itself. That is impossible
#   by design: this pipeline pushes with the built-in GITHUB_TOKEN, and
#   GitHub REFUSES to let a GitHub App / bot create or update workflow
#   files ("refusing to allow a GitHub App to create or update workflow
#   ... without workflows permission"). Only YOU, the repo owner logged
#   in, can edit workflow files through the web editor. Therefore this
#   script NEVER touches .github/workflows/ anymore; step 2 below only
#   CHECKS ci.yml and prints the exact manual fix if it is still broken.
#
#  This script REPLACES the old round 5-9 pipeline. All round 5-9
#  patches are already committed to the repo, so the old 3888-line
#  script is obsolete. This new script performs only the phase-0
#  cleanup and is safe to re-run any number of times.
#
#  Phase 0 (v2) contents:
#   1. Delete dead code: ScratchTest.java / ScratchTest.kt (they were
#      compiled INTO the shipped APK) and the root-level test_exo.kt /
#      test_ext.kt / test_heavy.kt (never compiled, repo noise).
#   2. CHECK .github/workflows/ci.yml (read-only): the "paths-ignore:"
#      line was indented with 8 spaces instead of 4, making the whole
#      file invalid YAML. GitHub silently rejected the workflow, so CI
#      (build / lint / unit tests) has NEVER run on this fork. This
#      step prints the 30-second manual fix; it cannot edit the file
#      for you (see v2 CHANGE above).
#   3. Enable R8 minification for release builds (minifyEnabled true)
#      in app/build.gradle -- smaller APK, dead-code elimination.
#   4. Rewrite app/proguard-rules.pro with safe keep rules:
#      - models package kept verbatim: ProjectSerializer stores the
#        runtime class simple name ("type": "Trim", "AddText", ...)
#        inside .lcprj project files, so renaming breaks old projects
#      - com.antonkarpenko.ffmpegkit kept: JNI resolves native methods
#        by name
#      - Signature/annotations kept for Gson generic type resolution
#      - enum values()/valueOf() kept for name-based serialization
#
#  Idempotent: every step checks its own marker and skips if applied.
#  POLICY: this pipeline must never modify files under .github/workflows/
#  (bot pushes get rejected by GitHub). Workflow changes are always
#  manual web-editor edits by the repo owner.
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# ---------------------------------------------------------------------------
#  STEP 1 -- delete dead code files
# ---------------------------------------------------------------------------
step1_delete_dead() {
    echo "== step 1: delete dead code files"
    local removed=0
    local f
    for f in \
        "app/src/main/java/com/tharunbirla/librecuts/ScratchTest.java" \
        "app/src/main/java/com/tharunbirla/librecuts/ScratchTest.kt" \
        "test_exo.kt" \
        "test_ext.kt" \
        "test_heavy.kt"
    do
        if [ -f "$f" ]; then
            rm -f "$f"
            echo "   [ok]   removed $f"
            removed=1
        else
            echo "   [skip] $f already absent"
        fi
    done
    if [ "$removed" -eq 1 ]; then
        echo "   [ok]   dead code cleanup complete (5 candidates checked)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 2 -- CHECK ci.yml (read-only; workflow files need manual edits)
# ---------------------------------------------------------------------------
step2_check_ci() {
    echo "== step 2: check ci.yml (read-only; workflows need manual edits)"
    if [ ! -f ".github/workflows/ci.yml" ]; then
        echo "   [warn] .github/workflows/ci.yml not found (renamed?)"
        return 0
    fi
    python3 - <<'CUTPY'
s = open('.github/workflows/ci.yml', encoding='utf-8', newline='').read()
BAD = '\n        paths-ignore:\n'
GOOD = '\n    paths-ignore:\n'
if GOOD in s and BAD not in s:
    print('   [ok]   ci.yml is valid: paths-ignore correctly indented')
elif BAD in s:
    print('   [warn] ci.yml is STILL BROKEN: paths-ignore uses 8 spaces')
    print('   [warn] GitHub rejects the whole workflow as invalid YAML,')
    print('   [warn] so CI (build/lint/test) never runs on this fork.')
    print('   [warn]')
    print('   [warn] FIX IT YOURSELF (30 seconds, web editor):')
    print('   [warn]   1. open .github/workflows/ci.yml on github.com')
    print('   [warn]   2. find the line:      paths-ignore:   (8 spaces)')
    print('   [warn]   3. change it to:   paths-ignore:   (4 spaces)')
    print('   [warn]   4. Commit directly to main.')
    print('   [warn] Bots cannot edit workflow files (GitHub blocks this')
    print('   [warn] on purpose), so this script cannot do it for you.')
else:
    print('   [warn] ci.yml has no paths-ignore line -- verify manually')
# warning only: never fail the pipeline over workflow files
CUTPY
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 3 -- enable R8 minification for release builds
# ---------------------------------------------------------------------------
step3_minify() {
    echo "== step 3: enable R8 minify for release builds"
    if [ ! -f "app/build.gradle" ]; then
        echo "   [FAIL] app/build.gradle not found"
        return 1
    fi
    python3 - <<'CUTPY'
import sys
p = 'app/build.gradle'
s = open(p, encoding='utf-8', newline='').read()
MARK = 'minifyEnabled true'
if MARK in s:
    print('   [skip] minifyEnabled already true')
    sys.exit(0)
ANCHOR = 'minifyEnabled false'
if s.count(ANCHOR) != 1:
    print('   [FAIL] expected exactly one minifyEnabled false, found %d'
          % s.count(ANCHOR))
    sys.exit(1)
NEW = (
    '// Phase 0 cleanup: enable R8 code shrinking/optimization for release\n'
    '            // builds. Safe rules for Gson-serialized models and ffmpeg-kit JNI\n'
    '            // bindings live in proguard-rules.pro.\n'
    '            minifyEnabled true')
s = s.replace(ANCHOR, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   minifyEnabled false -> true (release APK now shrunk)')
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 4 -- write safe ProGuard / R8 keep rules
# ---------------------------------------------------------------------------
step4_proguard() {
    echo "== step 4: write safe ProGuard / R8 keep rules"
    if [ ! -f "app/proguard-rules.pro" ]; then
        echo "   [FAIL] app/proguard-rules.pro not found"
        return 1
    fi
    if grep -q "CutStudio release ProGuard / R8 rules" app/proguard-rules.pro; then
        echo "   [skip] proguard-rules.pro already updated"
        return 0
    fi
    cat > app/proguard-rules.pro <<'PROEOF'
# ==========================================================================
#  CutStudio release ProGuard / R8 rules
#  Introduced with the phase-0 cleanup (minifyEnabled true).
#
#  IMPORTANT -- why these rules exist:
#   1. ProjectSerializer (utils/ProjectSerializer.kt) serializes the edit
#      graph to .lcprj project files using Gson REFLECTION and stores the
#      runtime class simple name ("type"/"operationType": "Trim",
#      "AddText", ...). If R8 renames any class or field in the models
#      package, every previously saved project file becomes unreadable.
#   2. ffmpeg-kit talks to native code through JNI. JNI resolves native
#      methods by class/method NAME, so renaming breaks the whole render
#      engine at runtime.
#   3. Gson resolves generic field types (List<EditOperation>, etc.) via
#      the Signature attribute -- it must be preserved.
# ==========================================================================

# ---- Keep stack traces readable in crash logs (name is still obfuscated,
#      but file/line numbers survive for error diagnostics) ----
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# ---- Required by Gson reflection (generic type resolution) ----
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*,AnnotationDefault

# ---- .lcprj project models: keep verbatim (class names + field names) ----
#  Covers EditOperation (sealed, all subclasses), EditRecipe, VideoProject,
#  SubtitleCue and anything else added to the models package later.
-keep class com.tharunbirla.librecuts.models.** { *; }

#  Serializable machinery for the same package (EditOperation : Serializable)
-keepclassmembers class com.tharunbirla.librecuts.models.** implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# ---- ffmpeg-kit (com.antonkarpenko repack): JNI bindings must keep names ----
-keep class com.antonkarpenko.ffmpegkit.** { *; }

# ---- Gson TypeToken (anonymous subclasses capture generic types) ----
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

# ---- Enums: Gson serializes by constant name; R8 must not rename them ----
-keepclassmembers enum com.tharunbirla.librecuts.** {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# ---- Lottie animations load by file name from assets (no rules needed),
#      ExoPlayer / Material / aboutlibraries ship their own consumer rules ----
PROEOF
    echo "   [ok]   proguard-rules.pro written (models + ffmpeg-kit + Gson kept)"
    return 0
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " CutStudio phase-0 cleanup -- start"
echo "=========================================================="
FAILED=0
step1_delete_dead || FAILED=1
step2_check_ci    || FAILED=1
step3_minify      || FAILED=1
step4_proguard    || FAILED=1
echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 0 FAILED -- see the [FAIL] lines above"
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 0 (v2) cleanup complete. All steps ok, skipped or warned."
echo " NOTE: if step 2 warned above, fix ci.yml manually in the web"
echo " editor -- bots cannot edit workflow files by design."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
