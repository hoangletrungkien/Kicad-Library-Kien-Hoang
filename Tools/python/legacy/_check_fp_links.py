import os
import re
import collections

REPO = os.path.abspath('.')
TABLE = r'C:\Users\kien\AppData\Roaming\kicad\10.0\fp-lib-table'
OFFICIAL = r'C:\Program Files\KiCad\10.0\share\kicad\footprints'

text = open(TABLE, encoding='utf-8-sig', errors='replace').read()
entries = re.findall(r'\(lib \(name "([^"]+)"\) \(type "([^"]*)"\) \(uri "([^"]+)"', text)

lib_fps = {}
for name, typ, uri in entries:
    if typ == 'Table':
        continue
    path = (uri.replace('${KICAD_ECO_ROOT}', REPO)
               .replace('${KICAD10_FOOTPRINT_DIR}', OFFICIAL)
               .replace('/', os.sep))
    if os.path.isdir(path):
        lib_fps[name] = {f[:-10] for f in os.listdir(path) if f.endswith('.kicad_mod')}

registered = set(lib_fps)
problems = collections.Counter()
samples = collections.defaultdict(list)

for root, _d, files in os.walk('Libraries/Symbols'):
    for f in files:
        if not f.endswith('.kicad_sym'):
            continue
        body = open(os.path.join(root, f), encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'\(property "Footprint" "([^"]*)"', body):
            v = m.group(1)
            if not v.strip():
                continue
            if '[' in v or "'" in v:
                problems['BRACKET'] += 1
                samples['BRACKET'].append((f, v))
                continue
            if ':' not in v:
                problems['NO_NICKNAME'] += 1
                samples['NO_NICKNAME'].append((f, v))
                continue
            nick, fp = v.split(':', 1)
            if nick in registered:
                if fp not in lib_fps[nick]:
                    problems['FP_NOT_FOUND'] += 1
                    samples['FP_NOT_FOUND'].append((f, v))
                continue
            if 'PERSONAL_' + nick in registered:
                problems['OLD_NICK'] += 1
                found = fp in lib_fps['PERSONAL_' + nick]
                samples['OLD_NICK'].append((f, v, 'fp_exists=' + str(found)))
                if not found:
                    problems['OLD_NICK_FP_MISSING'] += 1
                continue
            problems['NICK_NOT_REGISTERED'] += 1
            samples['NICK_NOT_REGISTERED'].append((f, v))

print(dict(problems))
for k in samples:
    print('---', k, len(samples[k]))
    seen = set()
    for item in samples[k]:
        if item[1] in seen:
            continue
        seen.add(item[1])
        print('  ', ' | '.join(item))
