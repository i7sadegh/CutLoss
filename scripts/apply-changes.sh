#!/usr/bin/env bash
# ==========================================================================
#  Cutloss simplification pipeline -- scripts/apply-changes.sh
#  PHASE 9 -- new launcher icon + stable CI signing + version bump
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  What this phase does:
#    1. Launcher icon: replaces the adaptive-icon foreground
#       (drawable/ic_launcher_foreground.xml) and the themed/monochrome
#       icon (drawable/ic_launcher_monochrome.xml) with the new design:
#       orange-gradient video frame + solid play triangle + one-line
#       black scissors + amber pivot screw, on the existing white
#       adaptive background (@color/ic_launcher_background).
#       The legacy raster mipmaps (mipmap-*/ic_launcher*.webp) still
#       carry the old logo and are dead weight at minSdk 26 (the
#       anydpi-v26 adaptive icon always wins), so they are deleted.
#    2. EditOperation.kt: removes the orphaned "Crop operation" KDoc
#       comment block left behind by phase 8 (last crop mention).
#    3. Stable debug signature: generates app/debug.keystore ONCE
#       (standard androiddebugkey, storepass/keypass "android") and
#       wires it into build.gradle via signingConfigs.debug. A
#       .gitignore exception (!app/debug.keystore) keeps the key
#       committed with the repo. Without
#       this every GitHub runner mints a fresh random debug key and
#       Android refuses to install the new APK over the previous one
#       (signature clash) no matter the versionCode. With it every CI
#       build keeps the same signature and installs cleanly over
#       older builds. NOTE: the APK currently installed on the phone
#       was signed by a random runner key, so it needs ONE last
#       uninstall before the first fixed-key build; never again after.
#    4. Version bump (intentionally NOT idempotent): every run of
#       this script advances the default versionCode by +1 and the
#       versionName beta number by +1 in app/build.gradle, so each CI
#       build can be installed over the previous one without a
#       downgrade error.
#    5. Workflow trigger check: verifies the push trigger of
#       .github/workflows/apply-and-build.yml is "branches: [main]"
#       and repairs the typo'd "branches: ain]" variant (a known
#       mobile-paste corruption) if it ever reappears, so uploading
#       this script keeps firing the pipeline automatically.
#
#  Verification gate (fails BEFORE the workflow commits anything):
#    icon content asserts + XML parse, adaptive wiring + manifest
#    references, raster mipmap removal, keystore validity + git
#    tracked-ness, gradle
#    wiring + exact version values + brace balance, workflow diff
#    exactness (exactly the one-line trigger repair), EditOperation
#    zero-crop assert + kept models, scope gate, untracked-file
#    policy (only app/debug.keystore), .github policy, ASCII
#    self-check.
#
#  Idempotent: every step checks its own post-state first -- EXCEPT
#  the version bump, which advances by exactly 1 on every run by
#  design (each pipeline run produces one installable-over APK).
# ==========================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FG="app/src/main/res/drawable/ic_launcher_foreground.xml"
MONO="app/src/main/res/drawable/ic_launcher_monochrome.xml"
EO="app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt"
GRADLE="app/build.gradle"
YML=".github/workflows/apply-and-build.yml"
MANIFEST="app/src/main/AndroidManifest.xml"
AVEM="app/src/main/res/layout/activity_video_editing.xml"
SELF="scripts/apply-changes.sh"
FAILED=0
NEW_VC=""
NEW_BETA=""

# ---------------------------------------------------------------------------
#  STEP 0 -- preconditions
# ---------------------------------------------------------------------------
step0_preconditions() {
    echo "== step 0: preconditions"
    local ok=1 f t
    for f in "$FG" "$MONO" "$EO" "$GRADLE" "$YML" "$MANIFEST" "$AVEM" \
             "app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml" \
             "app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml" \
             "app/src/main/res/values/ic_launcher_background.xml"; do
        if [ ! -f "$f" ]; then
            echo " [FAIL] missing file: $f"
            ok=0
        fi
    done
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo " [FAIL] not inside a git repository"
        ok=0
    fi
    for t in python3 sed grep git keytool; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo " [FAIL] required tool missing: $t"
            ok=0
        fi
    done
    # phase-8 must already be applied (crop + canvas fully gone)
    if [ -f app/src/main/java/com/tharunbirla/librecuts/customviews/CropOverlayView.kt ]; then
        echo " [FAIL] CropOverlayView.kt still exists -- phase 8 not applied (wrong base)"
        ok=0
    elif grep -q 'btnCrop' "$AVEM" 2>/dev/null; then
        echo " [FAIL] crop toolbar buttons still present -- phase 8 not applied (wrong base)"
        ok=0
    else
        echo " [ok] phase-8 base detected (crop + canvas already gone)"
    fi
    # phase-6 marker must still be present (timeline 200dp)
    if grep -q 'android:layout_height="200dp"' "$AVEM" 2>/dev/null; then
        echo " [ok] phase-6 marker detected (timeline 200dp)"
    else
        echo " [FAIL] phase-6 marker (timeline 200dp) missing -- wrong base"
        ok=0
    fi
    # the foreground must be either the old logo (fresh base) or the new
    # design (re-run); anything else means an unexpected icon file
    if grep -q 'M 265,215 L 265,297 L 335,256 Z' "$FG" 2>/dev/null; then
        echo " [ok] new icon already present -- phase-9 re-run"
    elif grep -q 'M11,9.16V2c-5,0.5' "$FG" 2>/dev/null; then
        echo " [ok] fresh phase-8 base detected (old logo present)"
    else
        echo " [FAIL] $FG carries an unexpected design -- refusing to touch it"
        ok=0
    fi
    [ "$ok" -eq 1 ] && echo " [ok] repo state matches the expected phase-8 base"
    [ "$ok" -eq 1 ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 1 -- new launcher foreground vector
# ---------------------------------------------------------------------------
step1_foreground() {
    echo "== step 1: new launcher foreground vector"
    if grep -q 'M 265,215 L 265,297 L 335,256 Z' "$FG" 2>/dev/null; then
        echo " [skip] foreground already carries the new design"
        return 0
    fi
    cat > "$FG" <<'ICONXML'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="512"
    android:viewportHeight="512">

    <group
        android:scaleX="0.65"
        android:scaleY="0.65"
        android:pivotX="256"
        android:pivotY="256">

        <!-- simple video frame -->
        <path
            android:pathData="M 210,150 H 410 A 20,20 0 0 1 430,170 V 342 A 20,20 0 0 1 410,362 H 210"
            android:strokeWidth="18"
            android:fillColor="#00000000"
            android:strokeLineCap="round"
            android:strokeLineJoin="round">
            <aapt:attr name="android:strokeColor">
                <gradient
                    android:startX="210"
                    android:startY="150"
                    android:endX="430"
                    android:endY="362"
                    android:type="linear">
                    <item android:offset="0.0" android:color="#FFB703" />
                    <item android:offset="1.0" android:color="#FB8500" />
                </gradient>
            </aapt:attr>
        </path>

        <!-- solid play triangle -->
        <path
            android:pathData="M 265,215 L 265,297 L 335,256 Z"
            android:strokeWidth="12"
            android:strokeLineCap="round"
            android:strokeLineJoin="round">
            <aapt:attr name="android:fillColor">
                <gradient
                    android:startX="265"
                    android:startY="215"
                    android:endX="335"
                    android:endY="297"
                    android:type="linear">
                    <item android:offset="0.0" android:color="#FFB703" />
                    <item android:offset="1.0" android:color="#FB8500" />
                </gradient>
            </aapt:attr>
            <aapt:attr name="android:strokeColor">
                <gradient
                    android:startX="265"
                    android:startY="215"
                    android:endX="335"
                    android:endY="297"
                    android:type="linear">
                    <item android:offset="0.0" android:color="#FFB703" />
                    <item android:offset="1.0" android:color="#FB8500" />
                </gradient>
            </aapt:attr>
        </path>

        <!-- one-line scissors (black) -->
        <path
            android:pathData="M 115,360 m -35,0 a 35,35 0 1,0 70,0 a 35,35 0 1,0 -70,0 M 215,360 m -35,0 a 35,35 0 1,0 70,0 a 35,35 0 1,0 -70,0 M 140,330 L 225,130 M 190,330 L 105,130"
            android:strokeWidth="18"
            android:strokeColor="#1A1A1A"
            android:fillColor="#00000000"
            android:strokeLineCap="round"
            android:strokeLineJoin="round" />

        <!-- scissors center pivot (on the exact crossing point) -->
        <path
            android:pathData="M 165,271.2 m -9,0 a 9,9 0 1,0 18,0 a 9,9 0 1,0 -18,0"
            android:fillColor="#FFB703" />
    </group>
</vector>
ICONXML
    if grep -q 'M 265,215 L 265,297 L 335,256 Z' "$FG"; then
        echo " [ok] foreground replaced with the new scissors + play design"
        return 0
    fi
    echo " [FAIL] foreground write did not land"
    return 1
}

# ---------------------------------------------------------------------------
#  STEP 2 -- new launcher monochrome (themed icon) vector
# ---------------------------------------------------------------------------
step2_monochrome() {
    echo "== step 2: new launcher monochrome (themed icon) vector"
    if grep -q 'M 265,215 L 265,297 L 335,256 Z' "$MONO" 2>/dev/null; then
        echo " [skip] monochrome already carries the new design"
        return 0
    fi
    if [ ! -f "$FG" ]; then
        echo " [FAIL] foreground missing -- cannot mirror it into the monochrome"
        return 1
    fi
    cp "$FG" "$MONO"
    if grep -q 'M 265,215 L 265,297 L 335,256 Z' "$MONO"; then
        echo " [ok] monochrome replaced (same geometry; themed icons use the alpha mask)"
        return 0
    fi
    echo " [FAIL] monochrome write did not land"
    return 1
}

# ---------------------------------------------------------------------------
#  STEP 3 -- delete the legacy raster launcher mipmaps
# ---------------------------------------------------------------------------
step3_legacy_rasters() {
    echo "== step 3: delete legacy raster launcher mipmaps (dead at minSdk 26)"
    local d f n=0
    for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
        for f in "app/src/main/res/mipmap-$d/ic_launcher.webp" \
                 "app/src/main/res/mipmap-$d/ic_launcher_round.webp"; do
            if [ -f "$f" ]; then
                rm -f "$f"
                n=$((n + 1))
            fi
        done
        rmdir "app/src/main/res/mipmap-$d" 2>/dev/null || true
    done
    if [ "$n" -eq 0 ]; then
        echo " [skip] no legacy raster launcher mipmaps left"
    else
        echo " [ok] deleted $n legacy webp mipmaps (anydpi-v26 adaptive icon covers API 26+)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 4 -- EditOperation.kt: drop the orphaned Crop KDoc
# ---------------------------------------------------------------------------
step4_orphan_kdoc() {
    echo "== step 4: EditOperation.kt -- drop the orphaned Crop KDoc"
    if ! grep -q 'Crop operation: Crops video to a specified aspect ratio' "$EO"; then
        echo " [skip] no orphaned Crop KDoc left"
        return 0
    fi
    python3 - <<'CUTPY' || return 1
import re, sys
p = 'app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt'
t = open(p, encoding='utf-8').read()
comment = (
    '    /**\n'
    '     * Crop operation: Crops video to a specified aspect ratio.\n'
    '     * Supported aspects: "16:9", "9:16", "1:1"\n'
    "     * Uses FFmpeg's crop filter with video re-encoding.\n"
    '     */\n'
)
# strip the comment plus exactly one following whitespace-only separator
# line (this file uses 4-space separator lines, not empty ones)
pat = re.compile(re.escape(comment) + r'[ \t]*\n')
t2, n = pat.subn('', t, count=1)
if n != 1:
    if comment in t:
        t2 = t.replace(comment, '', 1)
    else:
        print(' [FAIL] orphaned Crop KDoc block not found verbatim')
        sys.exit(1)
open(p, 'w', encoding='utf-8').write(t2)
print(' [ok] orphaned Crop KDoc removed (zero crop mentions remain)')
CUTPY
}

# ---------------------------------------------------------------------------
#  STEP 5 -- stable debug signing + version bump
# ---------------------------------------------------------------------------
step5_signing_and_version() {
    echo "== step 5: stable debug signing + version bump"

    # 5a: stable debug keystore (generated once, then committed with the repo)
    if [ -f app/debug.keystore ]; then
        echo " [skip] app/debug.keystore already exists"
    else
        if keytool -genkeypair \
                -keystore app/debug.keystore \
                -storetype PKCS12 -storepass android -keypass android \
                -alias androiddebugkey -keyalg RSA -keysize 2048 \
                -validity 10000 \
                -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1; then
            echo " [ok] generated app/debug.keystore (androiddebugkey / storepass android)"
        else
            echo " [FAIL] keytool could not generate the debug keystore"
            return 1
        fi
    fi

    # 5b: keep the keystore tracked (.gitignore exception)
    python3 - <<'CUTPY' || return 1
import re, sys
p = '.gitignore'
t = open(p, encoding='utf-8').read()
if re.search(r'(?m)^!app/debug\.keystore$', t):
    print(' [skip] .gitignore already exempts app/debug.keystore')
    sys.exit(0)
if not t.endswith('\n'):
    t += '\n'
t += (
    '\n'
    '# phase 9: the committed debug key is intentional -- it keeps every\n'
    '# CI build on the same signature so debug APKs install over each\n'
    '# other. Do not remove.\n'
    '!app/debug.keystore\n'
)
open(p, 'w', encoding='utf-8').write(t)
print(' [ok] .gitignore: added the !app/debug.keystore exception')
CUTPY

    # 5c: wire the keystore into build.gradle (idempotent)
    if grep -q 'signingConfigs {' "$GRADLE"; then
        echo " [skip] signingConfigs already present in build.gradle"
    else
        python3 - <<'CUTPY' || return 1
import sys
p = 'app/build.gradle'
t = open(p, encoding='utf-8').read()
anchor = '    buildTypes {'
if anchor not in t:
    print(' [FAIL] buildTypes anchor not found in build.gradle')
    sys.exit(1)
block = (
    '    signingConfigs {\n'
    '        debug {\n'
    '            // Phase 9: committed debug key so every CI build keeps\n'
    '            // the same signature and installs over previous debug\n'
    '            // APKs (see app/debug.keystore).\n'
    "            storeFile file('debug.keystore')\n"
    "            storePassword 'android'\n"
    "            keyAlias 'androiddebugkey'\n"
    "            keyPassword 'android'\n"
    '        }\n'
    '    }\n'
    '\n'
)
t = t.replace(anchor, block + anchor, 1)
open(p, 'w', encoding='utf-8').write(t)
print(' [ok] signingConfigs.debug wired to app/debug.keystore')
CUTPY
    fi

    # 5d: version bump -- advances by exactly 1 on EVERY run (by design)
    local old_vc old_beta
    old_vc=$(grep -oE "toInteger\(\) : [0-9]+" "$GRADLE" | head -1 | grep -oE "[0-9]+$" || true)
    if ! echo "$old_vc" | grep -qE '^[0-9]+$'; then
        echo " [FAIL] cannot read the default versionCode from build.gradle"
        return 1
    fi
    NEW_VC=$((old_vc + 1))
    if ! sed -i "s/toInteger() : ${old_vc}\$/toInteger() : ${NEW_VC}/" "$GRADLE"; then
        echo " [FAIL] versionCode sed failed"
        return 1
    fi
    old_beta=$(grep -oE 'versionName "1\.0-beta[0-9]+"' "$GRADLE" | head -1 | grep -oE 'beta[0-9]+' | grep -oE '[0-9]+' || true)
    if ! echo "$old_beta" | grep -qE '^[0-9]+$'; then
        echo " [FAIL] cannot read the versionName beta number from build.gradle"
        return 1
    fi
    NEW_BETA=$((old_beta + 1))
    sed -i "s/versionName \"1\.0-beta${old_beta}\"/versionName \"1.0-beta${NEW_BETA}\"/" "$GRADLE"
    if grep -q "toInteger() : ${NEW_VC}\$" "$GRADLE" \
       && grep -qF "versionName \"1.0-beta${NEW_BETA}\"" "$GRADLE"; then
        echo " [ok] version bumped: versionCode ${old_vc} -> ${NEW_VC}, versionName 1.0-beta${old_beta} -> 1.0-beta${NEW_BETA}"
        return 0
    fi
    echo " [FAIL] version bump did not land"
    return 1
}

# ---------------------------------------------------------------------------
#  STEP 6 -- verify the workflow push trigger
# ---------------------------------------------------------------------------
step6_workflow_trigger() {
    echo "== step 6: verify the workflow push trigger"
    if grep -q 'branches: \[main\]' "$YML"; then
        echo " [skip] push trigger already fixed (branches: [main])"
        return 0
    fi
    if ! grep -q 'branches: ain\]' "$YML"; then
        echo " [FAIL] neither 'branches: [main]' nor the typo 'branches: ain]' found -- unexpected workflow file"
        return 1
    fi
    sed -i 's/branches: ain\]/branches: [main]/' "$YML"
    if grep -q 'branches: \[main\]' "$YML" && ! grep -q 'branches: ain\]' "$YML"; then
        echo " [ok] push trigger repaired: uploading apply-changes.sh now fires the pipeline"
        return 0
    fi
    echo " [FAIL] workflow trigger repair did not land"
    return 1
}

# ---------------------------------------------------------------------------
#  STEP 7 -- verification gate
# ---------------------------------------------------------------------------
step7_verify() {
    echo "== step 7: verification gate"

    # 7a: icon content asserts
    python3 - <<'CUTPY' || return 1
import sys

def rd(p):
    return open(p, encoding='utf-8').read()

fg = rd('app/src/main/res/drawable/ic_launcher_foreground.xml')
mono = rd('app/src/main/res/drawable/ic_launcher_monochrome.xml')
errs = []

def need(text, tok, name):
    if tok not in text:
        errs.append('%s: missing %r' % (name, tok))

def gone(text, tok, name):
    if tok in text:
        errs.append('%s: still contains %r' % (name, tok))

for label, text in (('foreground', fg), ('monochrome', mono)):
    need(text, 'android:viewportWidth="512"', label)
    need(text, 'android:scaleX="0.65"', label)
    need(text, 'M 265,215 L 265,297 L 335,256 Z', label)      # play triangle
    need(text, 'M 115,360 m -35,0 a 35,35 0 1,0 70,0', label)  # scissors rings
    need(text, 'M 165,271.2 m -9,0 a 9,9 0 1,0 18,0', label)   # pivot screw
    need(text, '#FFB703', label)
    need(text, '#FB8500', label)
    need(text, '#1A1A1A', label)
    gone(text, 'M11,9.16V2c-5,0.5', label)                     # old logo path
    gone(text, 'android:tint="#FF4081"', label)                # old pink tint
    gone(text, 'android:viewportWidth="24"', label)            # old 24 viewport

if errs:
    for e in errs:
        print(' [FAIL] icon: ' + e)
    sys.exit(1)
print(' [ok] both icon vectors carry the new scissors + play design')
CUTPY

    # 7b: XML parse of the two icon vectors + both adaptive-icon wrappers
    python3 - <<'CUTPY' || return 1
import xml.dom.minidom as md
files = [
    'app/src/main/res/drawable/ic_launcher_foreground.xml',
    'app/src/main/res/drawable/ic_launcher_monochrome.xml',
    'app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    'app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml',
]
for f in files:
    md.parse(f)
print(' [ok] %d icon XML files parse cleanly' % len(files))
CUTPY

    # 7c: adaptive-icon wiring + manifest references intact
    python3 - <<'CUTPY' || return 1
import sys

def rd(p):
    return open(p, encoding='utf-8').read()

errs = []
for f in ('app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
          'app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml'):
    t = rd(f)
    for tok in ('<adaptive-icon', '@color/ic_launcher_background',
                '@drawable/ic_launcher_foreground',
                '@drawable/ic_launcher_monochrome'):
        if tok not in t:
            errs.append('%s: missing %r' % (f.split('/')[-1], tok))
man = rd('app/src/main/AndroidManifest.xml')
for tok in ('android:icon="@mipmap/ic_launcher"',
            'android:roundIcon="@mipmap/ic_launcher_round"'):
    if tok not in man:
        errs.append('AndroidManifest.xml: missing %r' % tok)
bgc = rd('app/src/main/res/values/ic_launcher_background.xml')
if '#FFFFFF' not in bgc:
    errs.append('ic_launcher_background.xml: white background expected')
if errs:
    for e in errs:
        print(' [FAIL] wiring: ' + e)
    sys.exit(1)
print(' [ok] adaptive-icon wiring + manifest references intact')
CUTPY

    # 7d: legacy raster mipmaps really gone
    local d f bad=0
    for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
        for f in "app/src/main/res/mipmap-$d/ic_launcher.webp" \
                 "app/src/main/res/mipmap-$d/ic_launcher_round.webp"; do
            if [ -f "$f" ]; then
                echo " [FAIL] legacy raster still present: $f"
                bad=1
            fi
        done
    done
    if [ "$bad" -ne 0 ]; then
        return 1
    fi
    echo " [ok] no legacy raster launcher mipmaps left"

    # 7e: keystore valid AND tracked (not swallowed by .gitignore)
    if git check-ignore -q app/debug.keystore; then
        echo " [FAIL] app/debug.keystore is still gitignored -- the bot commit would drop it"
        return 1
    fi
    if ! grep -q '^!app/debug\.keystore$' .gitignore; then
        echo " [FAIL] .gitignore is missing the !app/debug.keystore exception"
        return 1
    fi
    if ! keytool -list -keystore app/debug.keystore -storepass android 2>/dev/null \
         | grep -q 'androiddebugkey'; then
        echo " [FAIL] app/debug.keystore missing or alias androiddebugkey not resolvable"
        return 1
    fi
    echo " [ok] app/debug.keystore valid (alias androiddebugkey) and git-tracked"

    # 7f: build.gradle wiring + exact version values + brace balance
    if [ -z "$NEW_VC" ] || [ -z "$NEW_BETA" ]; then
        echo " [FAIL] version bump did not run -- cannot verify build.gradle"
        return 1
    fi
    python3 - "$NEW_VC" "$NEW_BETA" <<'CUTPY' || return 1
import re, sys
new_vc, new_beta = sys.argv[1], sys.argv[2]
t = open('app/build.gradle', encoding='utf-8').read()
errs = []
if not re.search(r"toInteger\(\) : %s$" % re.escape(new_vc), t, re.M):
    errs.append('versionCode default is not %s' % new_vc)
if 'versionName "1.0-beta%s"' % new_beta not in t:
    errs.append('versionName is not 1.0-beta%s' % new_beta)
for tok in ('signingConfigs {', "storeFile file('debug.keystore')",
            "storePassword 'android'", "keyAlias 'androiddebugkey'",
            "keyPassword 'android'"):
    if tok not in t:
        errs.append('build.gradle missing %r' % tok)
if t.count('{') != t.count('}'):
    errs.append('build.gradle brace balance broken (%d vs %d)'
                % (t.count('{'), t.count('}')))
if errs:
    for e in errs:
        print(' [FAIL] gradle: ' + e)
    sys.exit(1)
print(' [ok] build.gradle: versionCode %s / 1.0-beta%s + stable debug signing wired'
      % (new_vc, new_beta))
CUTPY

    # 7g: workflow file -- exactly the one-line trigger repair (or untouched)
    if git diff --quiet HEAD -- "$YML" 2>/dev/null; then
        echo " [skip] workflow file matches HEAD (fix already committed)"
    else
        local nlines plus minus
        nlines=$(git diff -U0 HEAD -- "$YML" 2>/dev/null | grep -cE '^[+-][^+-]' || true)
        plus=$(git diff -U0 HEAD -- "$YML" 2>/dev/null | grep -E '^\+[^+]' || true)
        minus=$(git diff -U0 HEAD -- "$YML" 2>/dev/null | grep -E '^-[^-]' || true)
        if [ "${nlines:-0}" -ne 2 ] \
           || ! echo "$plus" | grep -qE '^\+[[:space:]]*branches: \[main\]$' \
           || ! echo "$minus" | grep -qE '^-[[:space:]]*branches: ain\]$'; then
            echo " [FAIL] workflow diff must be exactly the one-line trigger repair; got:"
            git diff -U0 HEAD -- "$YML" 2>/dev/null
            return 1
        fi
        echo " [ok] workflow diff is exactly the one-line trigger repair"
    fi
    if python3 -c "import yaml" >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('.github/workflows/apply-and-build.yml'))" 2>/dev/null; then
            echo " [FAIL] workflow YAML no longer parses"
            return 1
        fi
        echo " [ok] workflow YAML parses"
    fi

    # 7h: EditOperation.kt -- zero crop mentions, kept models, braces ok
    if grep -qi 'crop' "$EO"; then
        echo " [FAIL] EditOperation.kt still mentions crop:"
        grep -ni 'crop' "$EO" | head -3
        return 1
    fi
    echo " [ok] EditOperation.kt carries zero crop references"
    python3 - <<'CUTPY' || return 1
import sys
eo = open('app/src/main/java/com/tharunbirla/librecuts/models/EditOperation.kt',
          encoding='utf-8').read()
errs = []
for tok in ('data class Trim(', 'data class SpeedMain(', 'data class AddText(',
            'data class Merge(', 'data class MuteAudio(', 'data class Transition(',
            'data class AddBackgroundAudio(', 'data class AddImageOverlay(',
            'data class KeyframePoint('):
    if tok not in eo:
        errs.append('missing %r' % tok)
if eo.count('{') != eo.count('}'):
    errs.append('brace balance broken')
if errs:
    for e in errs:
        print(' [FAIL] EditOperation survivors: ' + e)
    sys.exit(1)
print(' [ok] EditOperation.kt kept models intact, braces balanced')
CUTPY

    # 7i: scope gate -- only the expected file set may appear in the diff
    local bad
    bad=$(git status --porcelain 2>/dev/null | cut -c4- | grep -Ev \
'^(scripts/apply-changes\.sh|\.gitignore|app/src/main/res/drawable/ic_launcher_foreground\.xml|app/src/main/res/drawable/ic_launcher_monochrome\.xml|app/src/main/java/com/tharunbirla/librecuts/models/EditOperation\.kt|app/build\.gradle|\.github/workflows/apply-and-build\.yml|app/debug\.keystore|app/src/main/res/mipmap-(mdpi|hdpi|xhdpi|xxhdpi|xxxhdpi)/ic_launcher(_round)?\.webp)$' || true)
    if [ -n "$bad" ]; then
        echo " [FAIL] unexpected files in the working diff:"
        echo "$bad"
        return 1
    fi
    local untracked
    untracked=$(git status --porcelain 2>/dev/null | grep '^??' | cut -c4- \
                | grep -v '^app/debug\.keystore$' || true)
    if [ -n "$untracked" ]; then
        echo " [FAIL] unexpected untracked files (only app/debug.keystore may be new):"
        echo "$untracked"
        return 1
    fi
    echo " [ok] change scope is exactly the expected file set"

    # 7j: .github policy -- only the pipeline workflow itself
    local gh
    gh=$(git status --porcelain 2>/dev/null | cut -c4- | grep '^\.github/' \
         | grep -v '^\.github/workflows/apply-and-build\.yml$' || true)
    if [ -n "$gh" ]; then
        echo " [FAIL] .github/ files other than the pipeline workflow were modified:"
        echo "$gh"
        return 1
    fi
    echo " [ok] .github/ policy respected (only apply-and-build.yml, one-line diff)"

    # 7k: ASCII self-check
    local ascii
    ascii=$(LC_ALL=C grep -cP '[^\x00-\x7F]' "$SELF" 2>/dev/null || true)
    if [ "${ascii:-0}" -ne 0 ]; then
        echo " [FAIL] $SELF contains non-ASCII characters"
        return 1
    fi
    echo " [ok] script is 100% pure ASCII"
    return 0
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " Cutloss phase 9 -- new launcher icon (scissors + play),"
echo " stable CI debug signing, auto version bump, and a"
echo " workflow push-trigger check"
echo "=========================================================="
step0_preconditions || FAILED=1
if [ "$FAILED" -eq 0 ]; then
    step1_foreground          || FAILED=1
    step2_monochrome          || FAILED=1
    step3_legacy_rasters      || FAILED=1
    step4_orphan_kdoc         || FAILED=1
    step5_signing_and_version || FAILED=1
    step6_workflow_trigger    || FAILED=1
else
    echo " preconditions failed -- skipping the mutation steps"
fi
step7_verify || FAILED=1

echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 9 FAILED -- see the [FAIL] lines above."
    echo " Nothing was committed; main is untouched."
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 9 complete. Steps ok or skipped (version bump ran)."
echo "  - Launcher icon: new orange scissors + play design on the"
echo "    white adaptive background; themed/monochrome icon matches."
echo "  - Legacy raster launcher mipmaps deleted (minSdk 26)."
echo "  - app/debug.keystore committed (.gitignore exception added) ->"
echo "    every CI build now keeps"
echo "    the same signature, so new APKs install over old ones."
echo "    (The APK currently on the phone was signed by a random"
echo "    runner key, so uninstall it ONE last time before the first"
echo "    fixed-key build; after that, updates install in place.)"
echo "  - versionCode ${NEW_VC} / versionName 1.0-beta${NEW_BETA}."
echo "  - Workflow push trigger verified intact: uploading"
echo "    apply-changes.sh starts the pipeline by itself."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
