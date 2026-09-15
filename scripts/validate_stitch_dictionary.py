#!/usr/bin/env python3
"""Check real offline content/translations; --self-test runs corrupt fixture CLI cases.

Standard library only. Structural checks cannot certify knitting correctness or
translation fluency. Run without --fixture for the complete shipping inventory.
"""
import argparse
import copy
import datetime
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = 'da de el en fi fr ja ko nb nl sv zh-Hans zh-Hant'.split()
ENTRY_IDS = 'knit purl slip-knitwise slip-purlwise yarn-over knit-front-back make-one-left make-one-right k2tog ssk skp p2tog centered-double-decrease cable-left-two cable-right-two'.split()
UI_KEYS = '''title search.prompt mode.list mode.symbols category.all category.basic category.increase
category.decrease category.cable empty.title empty.clear empty.switchToList error.title back
 detail.names detail.meaning detail.symbols detail.steps detail.count detail.notes detail.sources
 detail.related symbol.unavailable repeat.format count.consumes count.produces count.net count.value
 step.format legend.title legend.leftNeedle legend.rightNeedle legend.cableNeedle legend.workingYarn
 legend.oldLoop legend.newLoop legend.arrow name.zh-Hant name.zh-Hans name.en name.ja name.ko'''.split()
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|h|l|L|z|j|t)?([diuoxXfFeEgGaAcCsSp@])')
ROLES = set('leftNeedle rightNeedle cableNeedle workingYarn oldLoop newLoop arrow'.split())


def placeholders(value):
    value = value.replace('%%', '')
    if '%' in FORMAT.sub('', value):
        raise ValueError('invalid format placeholder')
    found = {}
    for index, match in enumerate(FORMAT.finditer(value), 1):
        position, kind = int(match.group(1) or index), (match.group(2) or '') + match.group(3)
        if position in found and found[position] != kind:
            raise ValueError('inconsistent positional format type')
        found[position] = kind
    return found


def referenced_keys(value):
    keys = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key.endswith('Key'):
                if not isinstance(child, str) or not child.strip():
                    raise ValueError('invalid localization key')
                keys.add(child)
            elif key == 'noteKeys':
                if not isinstance(child, list) or any(not isinstance(k, str) or not k.strip() for k in child):
                    raise ValueError('invalid noteKeys')
                keys.update(child)
            else:
                keys.update(referenced_keys(child))
    elif isinstance(value, list):
        for child in value:
            keys.update(referenced_keys(child))
    return keys


def unique(records, kind):
    ids = [r['id'] for r in records]
    if any(not isinstance(i, str) or not i.strip() for i in ids) or len(ids) != len(set(ids)):
        raise ValueError('empty or duplicate ' + kind + ' ID')
    return set(ids)


def validate(catalog, diagrams, strings, fixture=False):
    if catalog['schemaVersion'] != 1 or diagrams['schemaVersion'] != 1:
        raise ValueError('unsupported schema')
    entries = catalog['entries']
    entry_ids, sources, diagram_ids = unique(entries, 'entry'), unique(catalog['sources'], 'source'), unique(diagrams['diagrams'], 'diagram')
    unique([s for e in entries for s in e['symbols']], 'symbol')
    if not fixture and [e['id'] for e in entries] != ENTRY_IDS:
        raise ValueError('expected the 15 operations in reviewed order')
    for source in catalog['sources']:
        if not source['url'].startswith('https://') or not source['scope'].strip():
            raise ValueError('invalid source ' + source['id'])
        datetime.date.fromisoformat(source['checkedOn'])
    for entry in entries:
        if not entry['steps'] or entry['consumes'] < 0 or entry['produces'] < 0:
            raise ValueError('invalid operation ' + entry['id'])
        if any(not entry['names'].get(l, '').strip() for l in ('zh-Hant', 'zh-Hans', 'en', 'ja', 'ko')):
            raise ValueError('missing learning name ' + entry['id'])
        notation = entry.get('displayNotation')
        if notation is not None and (not isinstance(notation, str) or not notation.strip() or notation.lower() not in [a.lower() for a in entry['aliases']]):
            raise ValueError('invalid display notation ' + entry['id'])
        if not fixture and notation != dict(zip(ENTRY_IDS, ['k', 'p', 'sl1k', 'sl1p', 'yo', 'kfb', 'm1l', 'm1r', 'k2tog', 'ssk', 'skp', 'p2tog', 'cdd', '1/1 LC', '1/1 RC']))[entry['id']]:
            raise ValueError('missing reviewed display notation ' + entry['id'])
        if not entry['sourceIDs'] or not set(entry['sourceIDs']) <= sources:
            raise ValueError('missing entry source ' + entry['id'])
        if not set(entry['relatedIDs']) <= entry_ids:
            raise ValueError('missing related operation ' + entry['id'])
        for item in entry['steps'] + entry['symbols']:
            if item['diagramID'] not in diagram_ids:
                raise ValueError('missing diagram ' + item['diagramID'])
        for symbol in entry['symbols']:
            if not symbol['sourceIDs'] or not set(symbol['sourceIDs']) <= sources:
                raise ValueError('missing symbol source ' + symbol['id'])
    for diagram in diagrams['diagrams']:
        if not diagram['strokes']:
            raise ValueError('empty diagram ' + diagram['id'])
        for stroke in diagram['strokes']:
            if stroke['role'] not in ROLES or not stroke['commands'] or 'move' not in stroke['commands'][0]:
                raise ValueError('invalid stroke ' + diagram['id'])
            for command in stroke['commands']:
                if len(command) != 1:
                    raise ValueError('invalid command ' + diagram['id'])
                kind, payload = next(iter(command.items()))
                if kind in ('move', 'line'):
                    points = [payload['_0']]
                elif kind == 'curve':
                    points = [payload[k] for k in ('to', 'control1', 'control2')]
                elif kind == 'close':
                    points = []
                else:
                    raise ValueError('unknown command ' + kind)
                for point in points:
                    if any(not isinstance(point.get(a), (int, float)) or not math.isfinite(point[a]) or not 0 <= point[a] <= 1 for a in ('x', 'y')):
                        raise ValueError('invalid coordinate ' + diagram['id'])
    keys = referenced_keys(catalog) | referenced_keys(diagrams)
    keys |= {k for k in strings if k.startswith('stitchDictionary.')}
    if not fixture:
        keys |= {'stitchDictionary.' + k for k in UI_KEYS}
    for key in sorted(keys):
        localizations, signatures = strings.get(key, {}).get('localizations', {}), []
        for lang in LANGUAGES:
            unit = localizations.get(lang, {}).get('stringUnit', {})
            value = unit.get('value')
            if not isinstance(value, str) or not value.strip() or unit.get('state') != 'translated':
                raise ValueError('missing translated value: ' + key + ' [' + lang + ']')
            signatures.append(placeholders(value))
        if any(s != signatures[0] for s in signatures[1:]):
            raise ValueError('format type mismatch: ' + key)
    for key in ('repeat.format', 'step.format', 'count.value'):
        full = 'stitchDictionary.' + key
        if full in keys and placeholders(strings[full]['localizations']['en']['stringUnit']['value']) != {1: 'lld'}:
            raise ValueError('count must use %lld: ' + full)
    return len(entries), len(diagrams['diagrams']), len(keys)


def self_test(catalog, diagrams, localizations):
    catalog = copy.deepcopy(catalog)
    catalog['entries'] = catalog['entries'][:1]
    catalog['entries'][0]['relatedIDs'] = []
    keys = referenced_keys(catalog) | {'stitchDictionary.repeat.format'}
    strings = {k: copy.deepcopy(localizations['strings'][k]) for k in keys}
    ids = {r['diagramID'] for r in catalog['entries'][0]['steps'] + catalog['entries'][0]['symbols']}
    diagrams = {'schemaVersion': 1, 'diagrams': [d for d in diagrams['diagrams'] if d['id'] in ids]}
    with tempfile.TemporaryDirectory(prefix='stitch-validator-') as directory:
        paths = [Path(directory) / n for n in ('catalog.json', 'diagrams.json', 'strings.xcstrings')]
        for case in ('valid', 'missing-korean-step', 'bad-format-type', 'missing-diagram', 'blank-translation', 'bad-coordinate', 'blank-notation', 'unrecorded-notation'):
            c, d, s = copy.deepcopy(catalog), copy.deepcopy(diagrams), copy.deepcopy(strings)
            step_key = c['entries'][0]['steps'][0]['textKey']
            if case == 'missing-korean-step':
                del s[step_key]['localizations']['ko']
            elif case == 'bad-format-type':
                s['stitchDictionary.repeat.format']['localizations']['ko']['stringUnit']['value'] = '%@번 반복'
            elif case == 'missing-diagram':
                c['entries'][0]['steps'][0]['diagramID'] = 'missing.step'
            elif case == 'blank-translation':
                s[step_key]['localizations']['fr']['stringUnit']['value'] = '  '
            elif case == 'blank-notation':
                c['entries'][0]['displayNotation'] = '   '
            elif case == 'unrecorded-notation':
                c['entries'][0]['displayNotation'] = 'unrecorded'
            elif case == 'bad-coordinate':
                d['diagrams'][0]['strokes'][0]['commands'][0]['move']['_0']['x'] = 2
            for path, value in zip(paths, (c, d, {'strings': s})):
                path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
            result = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--fixture', '--catalog', str(paths[0]), '--diagrams', str(paths[1]), '--localizations', str(paths[2])], capture_output=True, text=True)
            if result.returncode != (0 if case == 'valid' else 1):
                raise ValueError('self-test failed: ' + case + '\n' + result.stdout + result.stderr)
            print('PASS ' + case + ' (exit ' + str(result.returncode) + '): ' + (result.stdout + result.stderr).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=ROOT / 'Sources/KnitNoteCore/Resources/stitch-dictionary-v1.json')
    parser.add_argument('--diagrams', type=Path, default=ROOT / 'Sources/KnitNoteCore/Resources/stitch-diagrams-v1.json')
    parser.add_argument('--localizations', type=Path, default=ROOT / 'KnitNote/Localization/Localizable.xcstrings')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--fixture', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        c, d, l = [json.loads(p.read_text(encoding='utf-8')) for p in (args.catalog, args.diagrams, args.localizations)]
        counts = validate(c, d, l['strings'], fixture=args.fixture)
        print('OK: %d operations, %d diagrams, %d keys, 13 complete translations per key.' % counts)
        if args.self_test:
            self_test(c, d, l)
        return 0
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
