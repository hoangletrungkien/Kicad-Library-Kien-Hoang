import os
import re
import collections

MODEL_RE = re.compile(r'\(model "([^"]*)"')

garbage = collections.defaultdict(list)
missing = []
ok = 0

for base, _dirs, files in os.walk('Libraries/Footprints'):
    for f in files:
        if not f.endswith('.kicad_mod'):
            continue
        p = os.path.join(base, f)
        text = open(p, encoding='utf-8', errors='replace').read()
        for m in MODEL_RE.finditer(text):
            v = m.group(1)
            if v.strip() in ('', '/', 's', '.', chr(92)):
                garbage[v].append(p)
                continue
            if '${KICAD_LIBRARY}' in v:
                rel = v.replace('${KICAD_LIBRARY}', 'Libraries/3D_Models/Personal')
            elif '${KICAD_ECO_ROOT}' in v:
                rel = v.replace('${KICAD_ECO_ROOT}', '.')
            elif '${KICAD10_3DMODEL_DIR}' in v:
                rel = v.replace('${KICAD10_3DMODEL_DIR}', 'Official/kicad-packages3d')
            elif '${KISYS3DMOD}' in v:
                rel = v.replace('${KISYS3DMOD}', 'Official/kicad-packages3d')
            else:
                missing.append((p, v, 'NOVAR'))
                continue
            if os.path.exists(rel):
                ok += 1
            else:
                missing.append((p, v, 'MISSING'))

print('ok', ok)
print('garbage', {k: len(v) for k, v in garbage.items()})
for k, v in garbage.items():
    for p in v:
        print(' garbage', repr(k), p)
print('missing', len(missing))
for m in missing:
    print(' missing', m)
