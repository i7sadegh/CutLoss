#!/usr/bin/env bash
# ==========================================================================
#  CutStudio -> Cutloss rebrand pipeline -- scripts/apply-changes.sh
#  PHASE 1 -- rebrand the app to "Cutloss" (unique install identity)
#
#  This file is 100% pure ASCII on purpose (paste-safe through mobile
#  browsers into the GitHub web editor).
#
#  Why this is needed:
#   The fork still uses the ORIGINAL applicationId
#   (com.tharunbirla.librecuts). On Android the applicationId is the
#   install identity: two apps with the same id cannot coexist -- the
#   fork OVERWRITES (or fails to update) the original LibreCuts app.
#   Changing the applicationId to something unique lets Cutloss be
#   installed side-by-side with LibreCuts or any other video editor.
#
#  Phase 1 contents:
#   1. Launcher label: app_name -> "Cutloss" in values/strings.xml AND
#      every translated values-*/strings.xml (16 files, including the
#      Spanish "libreCuts" and Chinese translated names -- brand names
#      are not translated).
#   1b. Brand mentions inside OTHER user-visible string VALUES (export
#      location names "Downloads/CutStudio", help text, translate
#      button) -> "Cutloss" across all locale files. String KEYS (like
#      str_downloads_librecuts) are internal identifiers and stay.
#   2. Install identity: applicationId -> "com.i7sadegh.cutloss" in
#      app/build.gradle.
#      DELIBERATELY UNCHANGED: the gradle namespace, all Kotlin package
#      names/imports, the CutStudioApplication class and the ProGuard
#      keep rules (they reference Kotlin packages, which stay valid).
#      Zero code churn, zero R8 risk.
#   3. Internal broadcast action constants (ExportService x3,
#      ProxyGenerationService x1) -> new package prefix. They travel
#      over LocalBroadcastManager today (never leave the app), this is
#      prophylactic hygiene for any future migration to global
#      broadcasts.
#   4. User-visible "CutStudio" string literals -> "Cutloss" in the 3
#      files that show them: proxy notification title, exported file
#      name prefixes, media folder names (Movies/Music/Pictures),
#      snapshot frame names, export path preview labels, default track
#      title. Internal comments, log tags ("CutStudioCrash") and class
#      names stay untouched.
#   5. Fastlane store title (en-US) -> "Cutloss Beta". Store
#      descriptions stay untouched on purpose: they link to the real
#      upstream LibreCuts GitHub/wiki/Discord URLs, which must not be
#      rewritten to broken links.
#
#  NOTE for existing installs: after the applicationId change the new
#  APK installs NEXT TO the old build (Android treats it as a new app).
#  Uninstall the old "CutStudio" build manually if you want; .lcprj
#  project files live in Downloads/Documents and are not affected.
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
#  STEP 1 -- app_name -> Cutloss in every locale
# ---------------------------------------------------------------------------
step1_app_name() {
    echo "== step 1: app_name -> Cutloss (all locales)"
    python3 - <<'CUTPY'
import glob, re
pat = re.compile(r'(<string\s+name="app_name"[^>]*>)[^<]*(</string>)')
files = sorted(glob.glob('app/src/main/res/values*/strings.xml'))
if not files:
    print('   [FAIL] no values*/strings.xml found')
    raise SystemExit(1)
changed, already = 0, 0
for f in files:
    s = open(f, encoding='utf-8', newline='').read()
    m = pat.search(s)
    if not m:
        continue
    if 'Cutloss' in m.group(0):
        already += 1
        continue
    s = pat.sub(r'\1Cutloss\2', s, count=1)
    open(f, 'w', encoding='utf-8', newline='').write(s)
    changed += 1
    print('   [ok]   %s -> Cutloss' % f)
if changed == 0:
    print('   [skip] app_name already Cutloss everywhere (%d files)' % already)
else:
    print('   [ok]   %d locale file(s) updated, %d already ok' % (changed, already))
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 1b -- brand mentions in other user-visible string VALUES
# ---------------------------------------------------------------------------
step1b_brand_values() {
    echo "== step 1b: brand mentions in string values -> Cutloss"
    python3 - <<'CUTPY'
import glob, re
# Only the TEXT of <string> elements is rewritten; the name="..." keys
# (e.g. str_downloads_librecuts) are internal identifiers and stay put.
elem = re.compile(r'(<string\s+name="[^"]*"[^>]*>)([^<]*)(</string>)')
changed = [0]
def fix(m):
    v = m.group(2)
    v2 = v.replace('CutStudio', 'Cutloss').replace('LibreCuts', 'Cutloss').replace('libreCuts', 'Cutloss')
    if v2 != v:
        changed[0] += 1
    return m.group(1) + v2 + m.group(3)
files = sorted(glob.glob('app/src/main/res/values*/strings.xml'))
touched = 0
for f in files:
    s = open(f, encoding='utf-8', newline='').read()
    if not any(b in s for b in ('CutStudio', 'LibreCuts', 'libreCuts')):
        continue
    changed[0] = 0
    s2 = elem.sub(fix, s)
    if changed[0]:
        open(f, 'w', encoding='utf-8', newline='').write(s2)
        touched += 1
        print('   [ok]   %s: %d value(s) rebranded' % (f, changed[0]))
if touched == 0:
    print('   [skip] no brand mentions left in string values')
else:
    print('   [ok]   %d file(s) rebranded' % touched)
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 2 -- applicationId -> com.i7sadegh.cutloss
# ---------------------------------------------------------------------------
step2_application_id() {
    echo "== step 2: applicationId -> com.i7sadegh.cutloss"
    python3 - <<'CUTPY'
import sys
p = 'app/build.gradle'
s = open(p, encoding='utf-8', newline='').read()
NEW = 'applicationId "com.i7sadegh.cutloss"'
OLD = 'applicationId "com.tharunbirla.librecuts"'
if NEW in s:
    print('   [skip] applicationId already com.i7sadegh.cutloss')
    sys.exit(0)
if s.count(OLD) != 1:
    print('   [FAIL] expected exactly one applicationId line, found %d' % s.count(OLD))
    sys.exit(1)
s = s.replace(OLD, NEW, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   applicationId: com.tharunbirla.librecuts -> com.i7sadegh.cutloss')
print('   [ok]   namespace stays com.tharunbirla.librecuts (no code churn)')
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 3 -- broadcast action constants -> new package prefix
# ---------------------------------------------------------------------------
step3_actions() {
    echo "== step 3: broadcast action constants -> new package prefix"
    python3 - <<'CUTPY'
FILES = [
    'app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt',
    'app/src/main/java/com/tharunbirla/librecuts/services/ProxyGenerationService.kt',
]
OLDP = 'com.tharunbirla.librecuts.ACTION_'
NEWP = 'com.i7sadegh.cutloss.ACTION_'
total = 0
for p in FILES:
    s = open(p, encoding='utf-8', newline='').read()
    n = s.count(OLDP)
    if n == 0:
        if NEWP in s:
            print('   [skip] %s already migrated' % p.rsplit('/', 1)[-1])
        else:
            print('   [warn] %s: no action constants found (changed upstream?)' % p.rsplit('/', 1)[-1])
        continue
    s = s.replace(OLDP, NEWP)
    open(p, 'w', encoding='utf-8', newline='').write(s)
    total += n
    print('   [ok]   %s: %d action constant(s) migrated' % (p.rsplit('/', 1)[-1], n))
if total == 0:
    print('   [skip] no old action constants remain')
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 4 -- user-visible "CutStudio" literals -> "Cutloss"
# ---------------------------------------------------------------------------
step4_literals() {
    echo "== step 4: user-visible CutStudio literals -> Cutloss"
    python3 - <<'CUTPY'
FILES = [
    'app/src/main/java/com/tharunbirla/librecuts/services/ProxyGenerationService.kt',
    'app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt',
    'app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt',
    'app/src/main/res/layout/dialog_welcome_onboarding.xml',
]
# ORDER MATTERS: longer/specific patterns first, generic bare name last.
RULES = [
    ('"CutStudio_Audio_"',  '"Cutloss_Audio_"'),
    # Frame rule matches the TEMPLATE start ("CutStudio_Frame_${ ... )
    # because in source the literal continues with ${...}, not a quote.
    ('"CutStudio_Frame_${', '"Cutloss_Frame_${'),
    ('"CutStudio_"',        '"Cutloss_"'),
    ('"CutStudio (Default)"', '"Cutloss (Default)"'),
    ('"Downloads/CutStudio"', '"Downloads/Cutloss"'),
    ('"/CutStudio"',        '"/Cutloss"'),
    ('/CutStudio"',         '/Cutloss"'),
    ('"CutStudio App Icon"', '"Cutloss App Icon"'),
    ('"CutStudio"',         '"Cutloss"'),
]
stale = 0
for p in FILES:
    name = p.rsplit('/', 1)[-1]
    s = open(p, encoding='utf-8', newline='').read()
    hits = 0
    for old, new in RULES:
        if old in s:
            hits += s.count(old)
            s = s.replace(old, new)
    if hits:
        open(p, 'w', encoding='utf-8', newline='').write(s)
        print('   [ok]   %s: %d literal(s) renamed' % (name, hits))
    else:
        if '"Cutloss' in s:
            print('   [skip] %s already renamed' % name)
        else:
            print('   [warn] %s: no CutStudio literals found (nothing user-visible?)' % name)
    stale += s.count('"CutStudio')
if stale:
    print('   [FAIL] %d quoted CutStudio literal(s) still remain' % stale)
    raise SystemExit(1)
CUTPY
    [ $? -ne 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
#  STEP 5 -- fastlane store title -> Cutloss Beta
# ---------------------------------------------------------------------------
step5_title() {
    echo "== step 5: fastlane store title -> Cutloss Beta"
    if [ ! -f "fastlane/metadata/android/en-US/title.txt" ]; then
        echo "   [skip] fastlane title.txt not found"
        return 0
    fi
    python3 - <<'CUTPY'
import sys
p = 'fastlane/metadata/android/en-US/title.txt'
s = open(p, encoding='utf-8', newline='').read()
if 'Cutloss' in s:
    print('   [skip] title already Cutloss')
    sys.exit(0)
if 'LibreCuts' not in s:
    print('   [warn] title has no LibreCuts brand, leaving as-is: %r' % s.strip())
    sys.exit(0)
open(p, 'w', encoding='utf-8', newline='').write(s.replace('LibreCuts', 'Cutloss', 1))
print('   [ok]   fastlane title: LibreCuts -> Cutloss')
CUTPY
    return 0
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
echo "=========================================================="
echo " Cutloss rebrand (phase 1) -- start"
echo "=========================================================="
FAILED=0
step1_app_name     || FAILED=1
step1b_brand_values || FAILED=1
step2_application_id || FAILED=1
step3_actions      || FAILED=1
step4_literals     || FAILED=1
step5_title        || FAILED=1
echo "----------------------------------------------------------"
if [ "$FAILED" -ne 0 ]; then
    echo " PHASE 1 FAILED -- see the [FAIL] lines above"
    echo "----------------------------------------------------------"
    exit 1
fi
echo " Phase 1 rebrand complete. All steps ok or skipped."
echo " Result: label Cutloss, applicationId com.i7sadegh.cutloss."
echo " Installs side-by-side with LibreCuts (no conflicts)."
echo " Next: the workflow commits these changes and builds the APK."
echo "----------------------------------------------------------"
exit 0
