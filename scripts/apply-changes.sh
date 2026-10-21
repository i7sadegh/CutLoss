#!/usr/bin/env bash
# ==========================================================================
#  CutStudio change pipeline -- scripts/apply-changes.sh
#  PHASE 0 -- repository cleanup
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  This script REPLACES the old round 5-9 pipeline. All round 5-9
#  patches are already committed to the repo, so the old 3888-line
#  script is obsolete. This new script performs only the phase-0
#  cleanup and is safe to re-run any number of times.
#
#  Phase 0 contents:
#   1. Delete dead code: ScratchTest.java / ScratchTest.kt (they were
#      compiled INTO the shipped APK) and the root-level test_exo.kt /
#      test_ext.kt / test_heavy.kt (never compiled, repo noise).
#   2. Fix .github/workflows/ci.yml: the "paths-ignore:" line was
#      indented with 8 spaces instead of 4, which made the whole file
#      invalid YAML. GitHub silently rejected the workflow, so CI
#      (build / lint / unit tests) has NEVER run on this fork.
#      After this fix the CI workflow becomes alive.
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
#  STEP 2 -- fix ci.yml paths-ignore indentation (invalid YAML -> alive CI)
# ---------------------------------------------------------------------------
step2_fix_ci() {
    echo "== step 2: fix ci.yml paths-ignore indentation"
    if [ ! -f ".github/workflows/ci.yml" ]; then
        echo "   [skip] .github/workflows/ci.yml not found (renamed?)"
        return 0
    fi
    python3 - <<'CUTPY'
import sys
p = '.github/workflows/ci.yml'
s = open(p, encoding='utf-8', newline='').read()
BAD = '\n        paths-ignore:\n'
GOOD = '\n    paths-ignore:\n'
if BAD not in s:
    if GOOD in s:
        print('   [skip] ci.yml already correctly indented')
        sys.exit(0)
    print('   [FAIL] ci.yml: no paths-ignore line found at all')
    sys.exit(1)
if s.count(BAD) != 1:
    print('   [FAIL] ci.yml: %d broken paths-ignore lines' % s.count(BAD))
    sys.exit(1)
s = s.replace(BAD, GOOD, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   ci.yml fixed: paths-ignore indent 8 -> 4 spaces (CI alive)')
CUTPY
    [ $? -ne 0 ] && return 1
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
step2_fix_ci      || FAILED=1
step3_minify      || FAILED=1
step4_proguard    || FAILED=1
echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 0 FAILED -- see the [FAIL] lines above"
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 0 cleanup complete. All steps ok or skipped."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
