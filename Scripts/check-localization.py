#!/usr/bin/env python3
"""Checks the String Catalogs against what the compiler extracted.

Build the three app targets first, with one derived-data folder, e.g.

    xcodebuild -project FTX1RemoteMac/FTX1RemoteMac.xcodeproj -scheme FTX1RemoteMac \
        -destination platform=macOS -derivedDataPath build/l10n build
    (same for FTX1RemoteiOS and FTX1RemoteiPad with 'generic/platform=iOS Simulator')

then run  Scripts/check-localization.py [build/l10n]

Fails if a namespaced key ("settings.hub.address") used in code is missing
from its target's Localizable.xcstrings, if its English has a different
number of placeholders than the code passes, or if package code
(Sources/FTX1Core, Sources/FTX1CW) looks a key up without
`bundle: .module` — that lookup would search the app's catalog and show
the raw key.
"""
import glob, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'build/l10n')
CATALOGS = {
    'Sources/FTX1Core/': 'Sources/FTX1Core/Resources/Localizable.xcstrings',
    'Sources/FTX1CW/': 'Sources/FTX1CW/Resources/Localizable.xcstrings',
    'Apps/Mac/': 'Apps/Mac/FTX1RemoteMac/Localizable.xcstrings',
    'Apps/iOS/': 'Apps/iOS/FTX1RemoteiOS/Localizable.xcstrings',
    'Apps/iPad/': 'Apps/iPad/FTX1RemoteiPad/Localizable.xcstrings',
}
KEY = re.compile(r'^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+$')
SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSaAp]|%(?:\d+\$)?#@\w+@')

catalogs = {p: json.load(open(os.path.join(ROOT, c)))['strings'] for p, c in CATALOGS.items()}
problems = []
seen = 0
for path in glob.glob(os.path.join(DERIVED, '**/*.stringsdata'), recursive=True):
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', path]))
    source = os.path.relpath(data.get('source', ''), ROOT)
    prefix = next((p for p in CATALOGS if source.startswith(p)), None)
    if prefix is None:
        continue
    for entries in data.get('tables', {}).values():
        for entry in entries:
            key = entry['key']
            if not KEY.match(key.split(' ')[0]):
                continue  # English left as is: radio terms, units, formats
            seen += 1
            where = f"{source}:{entry['location']['startingLine']}"
            item = catalogs[prefix].get(key)
            if item is None:
                problems.append(f'{where}: "{key}" is not in {CATALOGS[prefix]}')
                continue
            en = item.get('localizations', {}).get('en', {})
            value = en.get('stringUnit', {}).get('value')
            if value is None and 'variations' not in en:
                problems.append(f'{where}: "{key}" has no English value')
            elif value is not None and 'substitutions' not in en:
                if len(SPEC.findall(key)) != len(SPEC.findall(value.replace('%%', ''))):
                    problems.append(f'{where}: "{key}" vs "{value}": placeholder count differs')

lookup = re.compile(r'(Text|String\(localized:)\(?\s*"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+)\b[^"]*"(?!\s*,\s*bundle: \.module)')
for path in glob.glob(os.path.join(ROOT, 'Sources/FTX1C*/**/*.swift'), recursive=True):
    for n, line in enumerate(open(path), 1):
        line = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '', line)  # drop \(...) interpolations
        for m in lookup.finditer(line):
            problems.append(f'{os.path.relpath(path, ROOT)}:{n}: "{m.group(2)}" looked up without bundle: .module')

print(f'{seen} localized sites checked')
print('\n'.join(problems) or 'all keys resolve')
sys.exit(1 if problems else 0)
