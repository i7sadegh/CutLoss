#!/usr/bin/env bash
# ==========================================================================
#  CutStudio change pipeline -- scripts/apply-changes.sh
#  ROUND 4 -- incremental fixes on top of the already-applied v3 state
#
#  IMPORTANT: this file is deliberately 100% pure ASCII. It gets pasted
#  through mobile browsers into the GitHub web editor, and non-ASCII
#  characters are double-encoded somewhere along that path (that is exactly
#  how the "Importing Video" title ended up showing garbage on screen).
#  Every special byte pattern below is written with \x escapes, so nothing
#  in this file can be mangled by copy/paste.
#
#  Round 4 contents:
#    A) strings cleanup -- every ellipsis variant (clean U+2026, single
#       mojibake, double mojibake, XML entity) is converted to plain "..."
#       in ALL res/values*/ xml files; the three known progress strings
#       ("Importing Video", "Saving video", "Analyzing beats") are forced
#       to exact ASCII text no matter what bytes they currently contain.
#    B) first-launch onboarding/welcome popup removed (MainActivity).
#    C) bitrate "Same as input" chip restyled to be IDENTICAL to every
#       other chip (same active color from the theme, NO check icon);
#       the three custom resources added for it in v3 are deleted.
#
#  Idempotent: every step skips itself when already applied.
#  Requires: v3 state (export settings panel) already applied.
# ==========================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

DLG="app/src/main/res/layout/dialog_export_settings.xml"
MAIN="app/src/main/java/com/tharunbirla/librecuts/MainActivity.kt"

# ---------------------------------------------------------------------------
#  PRE-CHECK -- this round expects the v3 export panel to exist already
# ---------------------------------------------------------------------------
precheck() {
  echo "== pre-check"
  if [ ! -f "$DLG" ] || ! grep -q "chipBitrateSame" "$DLG"; then
    echo "ABORT: dialog_export_settings.xml (v3 state) not found."
    echo "       This script is incremental; re-apply the previous full"
    echo "       apply-changes.sh first, then run this one."
    return 1
  fi
  echo "   [ok] v3 export panel present"
}

# ---------------------------------------------------------------------------
#  FIX A -- strings ellipsis / mojibake cleanup (byte level, all locales)
# ---------------------------------------------------------------------------
fix_a_strings() {
  echo "== fix A: strings ellipsis / mojibake cleanup (byte level)"
  python3 - <<'CUTPY'
import glob, re, sys

# byte patterns -> replacement. ALL written as \x escapes on purpose:
# this keeps the whole script pure ASCII (paste-safe on mobile).
PATTERNS = [
    # single-layer mojibake (UTF-8 bytes re-decoded as CP1252, re-encoded)
    (b'\xc3\xa2\xe2\x82\xac\xc2\xa6', b'...'),     # broken ellipsis on screen
    (b'\xc3\xa2\xe2\x82\xac\xe2\x84\xa2', b"'"),   # broken right single quote
    (b'\xc3\xa2\xe2\x82\xac\xe2\x80\xb9', b"'"),   # broken left single quote
    (b'\xc3\xa2\xe2\x82\xac\xc5\x93',     b'"'),   # broken left double quote
    (b'\xc3\xa2\xe2\x82\xac\xc2\x9d',     b'"'),   # broken right double quote
    (b'\xc3\xa2\xe2\x82\xac\xe2\x80\x94', b'-'),   # broken em dash
    (b'\xc3\xa2\xe2\x82\xac\xe2\x80\x93', b'-'),   # broken en dash
    # double-layer mojibake (encoding mangled twice)
    (b'\xc3\x83\xc2\xa2\xc3\xa2\xe2\x80\x9a\xc2\xac\xc3\x82\xc2\xa6', b'...'),
    # clean forms
    (b'\xe2\x80\xa6', b'...'),                     # clean U+2026 ellipsis
    # XML entities
    (b'&#8230;',  b'...'),
    (b'&#x2026;', b'...'),
]

# the three progress strings the user actually sees during import/export
FORCE_STRINGS = [
    ('loading',               'Importing Video...'),
    ('str_saving_video',      'Saving video...'),
    ('toast_analyzing_beats', 'Analyzing beats...'),
]

files = sorted(glob.glob('app/src/main/res/values*/*.xml'))
if not files:
    print('   [FAIL] no res/values*/ xml files found')
    sys.exit(1)

written = 0
for f in files:
    try:
        data = open(f, 'rb').read()
    except Exception as e:
        print('   [FAIL] cannot read %s: %s' % (f, e))
        sys.exit(1)
    orig = data
    hits = 0
    for pat, rep in PATTERNS:
        if pat in data:
            hits += data.count(pat)
            data = data.replace(pat, rep)
    if f == 'app/src/main/res/values/strings.xml':
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError as e:
            print('   [FAIL] %s is not valid UTF-8: %s' % (f, e))
            sys.exit(1)
        for key, val in FORCE_STRINGS:
            text = re.sub(r'(<string name="' + key + r'">)[^<]*(</string>)',
                          r'\g<1>' + val + r'\g<2>', text)
        data = text.encode('utf-8')
    if data != orig:
        open(f, 'wb').write(data)
        written += 1
        print('   [ok]   fixed (%d hit(s)): %s' % (hits, f) if hits
              else '   [ok]   normalized: %s' % f)
if written == 0:
    print('   [skip] all values xml files already clean')
print('   fix A done: %d file(s) written' % written)
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  FIX B -- remove the first-launch onboarding popup (MainActivity)
# ---------------------------------------------------------------------------
fix_b_onboarding() {
  echo "== fix B: remove first-launch onboarding popup"
  python3 - "$MAIN" <<'CUTPY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
MARKER = '// Onboarding / Welcome Dialog removed (CutStudio)'
if MARKER in s:
    print('   [skip] onboarding call already removed')
    sys.exit(0)
pat = re.compile(
    r'[ \t]*// Onboarding / Welcome Dialog\r?\n'
    r'[ \t]*val isFirstLaunch = prefs\.getBoolean\("first_launch_v1", true\)\r?\n'
    r'[ \t]*if \(isFirstLaunch\) \{\r?\n'
    r'[ \t]*showOnboardingDialog\(prefs\)\r?\n'
    r'[ \t]*\}\r?\n')
m = pat.search(s)
if not m:
    print('   [FAIL] onboarding block not found in MainActivity.kt')
    sys.exit(1)
nl = '\r\n' if '\r\n' in s else '\n'
s = s[:m.start()] + ' ' * 8 + MARKER + nl + s[m.end():]
open(p, 'w', encoding='utf-8', newline='').write(s)
print('   [ok]   onboarding popup call removed (dialog will never show)')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  FIX C -- bitrate "Same as input" chip: same style/color as all other
#           chips, no check icon; delete the 3 custom v3 resources
# ---------------------------------------------------------------------------
fix_c_chip() {
  echo "== fix C: bitrate Same-as-input chip -> plain style like the others"
  python3 - "$DLG" <<'CUTPY'
import glob, os, re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
i = s.find('chipBitrateSame')
if i == -1:
    print('   [FAIL] chipBitrateSame not found in dialog layout')
    sys.exit(1)
start = s.rfind('<com.google.android.material.chip.Chip', 0, i)
end = s.find('/>', i)
if start == -1 or end == -1:
    print('   [FAIL] chip tag boundaries not found')
    sys.exit(1)
end += 2
block = s[start:end]
if 'Chip.Choice' in block and 'checkedIcon' not in block:
    print('   [skip] chip already plain Choice style')
else:
    nl = '\r\n' if '\r\n' in s else '\n'
    new_block = (
        '            <com.google.android.material.chip.Chip android:id="@+id/chipBitrateSame"'
        + nl +
        '                style="@style/Widget.MaterialComponents.Chip.Choice"'
        + nl +
        '                android:layout_width="wrap_content" android:layout_height="wrap_content"'
        + nl +
        '                android:layout_marginStart="10dp" android:text="Same as input" android:checked="true" />'
    )
    s = s[:start] + new_block + s[end:]
    open(p, 'w', encoding='utf-8', newline='').write(s)
    print('   [ok]   chipBitrateSame now identical in style to all other chips')

# --- delete the now-unused custom resources (with reference safety net) ---
targets = [
    'app/src/main/res/drawable/ic_dialog_check.xml',
    'app/src/main/res/color/chip_bitrate_same_bg.xml',
    'app/src/main/res/color/chip_bitrate_same_text.xml',
]
refs = []
scan_files = []
for ext in ('.xml', '.kt', '.java'):
    scan_files += glob.glob('app/src/main/**/*' + ext, recursive=True)
for f in scan_files:
    if f in targets:
        continue
    try:
        t = open(f, encoding='utf-8', errors='replace').read()
    except Exception:
        continue
    if 'ic_dialog_check' in t or 'chip_bitrate_same' in t:
        refs.append(f)
if refs:
    print('   [FAIL] custom resources still referenced in: ' + ', '.join(refs))
    sys.exit(1)
for f in targets:
    if os.path.exists(f):
        os.remove(f)
        print('   [ok]   deleted ' + f)
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

# 1) XML validity
xmls = ['app/src/main/res/layout/dialog_export_settings.xml',
        'app/src/main/AndroidManifest.xml'] + sorted(glob.glob('app/src/main/res/values*/*.xml'))
for f in xmls:
    try:
        ET.parse(f)
    except Exception as e:
        fail('XML %s: %s' % (f, e))
print('   [ok]   XML valid (%d files)' % len(xmls))

# 2) strings: no forbidden byte patterns left in any values xml
FORBIDDEN = [
    (b'\xe2\x80\xa6',      'clean ellipsis'),
    (b'\xc3\xa2\xe2\x82\xac', 'mojibake sequence'),
    (b'\xc3\x83\xc2\xa2',  'double mojibake'),
    (b'&#8230;',           'ellipsis entity'),
    (b'&#x2026;',          'ellipsis hex entity'),
]
for f in sorted(glob.glob('app/src/main/res/values*/*.xml')):
    d = open(f, 'rb').read()
    for pat, name in FORBIDDEN:
        if pat in d:
            fail('%s still present in %s' % (name, f))
sts = open('app/src/main/res/values/strings.xml', 'rb').read()
for line in [b'<string name="loading">Importing Video...</string>',
             b'<string name="str_saving_video">Saving video...</string>',
             b'<string name="toast_analyzing_beats">Analyzing beats...</string>']:
    if line not in sts:
        fail('missing exact string: ' + line.decode())
print('   [ok]   strings: every ellipsis variant gone, progress strings exact')

# 3) repo-wide mojibake scan (xml/kt/java under app/src/main)
scan = []
for f in glob.glob('app/src/main/**/*', recursive=True):
    if os.path.isfile(f) and f.endswith(('.xml', '.kt', '.java')):
        d = open(f, 'rb').read()
        if b'\xc3\xa2\xe2\x82\xac' in d or b'\xc3\x83\xc2\xa2' in d:
            scan.append(f)
if scan:
    for f in scan:
        fail('mojibake bytes still in ' + f)
else:
    print('   [ok]   repo-wide mojibake scan clean')

# 4) MainActivity: popup removed + braces balanced
m = open('app/src/main/java/com/tharunbirla/librecuts/MainActivity.kt', encoding='utf-8').read()
if '// Onboarding / Welcome Dialog removed' not in m:
    fail('onboarding marker missing')
if 'showOnboardingDialog(prefs)' in m:
    fail('onboarding call still present')
if m.count('{') != m.count('}'):
    fail('MainActivity braces unbalanced')
print('   [ok]   MainActivity: popup gone, braces balanced')

# 5) chip styling + custom resources gone
x = open('app/src/main/res/layout/dialog_export_settings.xml', encoding='utf-8').read()
i = x.find('chipBitrateSame')
if i == -1:
    fail('chipBitrateSame missing from layout')
else:
    blk = x[max(0, x.rfind('<com.google.android.material.chip.Chip', 0, i)): x.find('/>', i) + 2]
    if 'Chip.Choice' not in blk:
        fail('chipBitrateSame is not plain Choice style')
if 'checkedIcon' in x:
    fail('checkedIcon still present in dialog layout')
if 'ic_dialog_check' in x or 'chip_bitrate_same' in x:
    fail('custom chip resources still referenced in dialog layout')
for f in ['app/src/main/res/drawable/ic_dialog_check.xml',
          'app/src/main/res/color/chip_bitrate_same_bg.xml',
          'app/src/main/res/color/chip_bitrate_same_text.xml']:
    if os.path.exists(f):
        fail('stale resource still exists: ' + f)
print('   [ok]   bitrate chip identical to siblings; custom resources deleted')

# 6) R.id cross-check dialog <-> ExportSettingsDialog.kt
k = open('app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt', encoding='utf-8').read()
used = set(re.findall(r'R\.id\.(\w+)', k))
defined = set(re.findall(r'\+id/(\w+)', x))
missing = used - defined
if missing:
    fail('R.id missing in layout: ' + str(sorted(missing)))
else:
    print('   [ok]   R.id cross-check (%d ids)' % len(used))

if bad:
    print('VERIFY FAILED (%d problem(s))' % bad)
    sys.exit(1)
print('VERIFY OK')
CUTPY
  [ $? -ne 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  MAIN
# ---------------------------------------------------------------------------
precheck          || { echo "ABORT: pre-check"; exit 1; }
fix_a_strings     || { echo "ABORT: fix A";     exit 1; }
fix_b_onboarding  || { echo "ABORT: fix B";     exit 1; }
fix_c_chip        || { echo "ABORT: fix C";     exit 1; }
verify_all        || { echo "ABORT: verify";    exit 1; }
echo ""
echo "ROUND 4 APPLIED SUCCESSFULLY"
