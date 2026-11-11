import os
import re

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

by_name = {}
for lib, names in lib_fps.items():
    for n in names:
        by_name.setdefault(n, []).append(lib)

queries = [
    ('MAX8616', 'exact'), ('MAX8616', 'sub'),
    ('Bosch_LGA-8_2.5x2.5mm_P0.65mm_ClockwisePinNumbering', 'exact'),
    ('Bosch_LGA-8_2.5x2.5mm_P0.65mm_ClockwisePinNumbering', 'sub'),
    ('Bosch_LGA-8_3x3mm_P0.8mm_ClockwisePinNumbering', 'exact'),
    ('Bosch_LGA-14_3x2.5mm_P0.5mm_LayoutBorder3x4y', 'exact'),
    ('Bosch_LGA-10_2x2mm_P0.5mm_ClockwisePinNumbering', 'exact'),
    ('AT90USBKey', 'sub'), ('ParticleArgon', 'sub'), ('ESP32_Mini', 'sub'),
    ('QC_1500x1100x450_10p', 'sub'), ('QC_1400x1100x450_5P', 'sub'),
    ('CONV_RAC05-05SK_277_W', 'sub'), ('RAC05', 'sub'),
    ('DFN5', 'sub'), ('WLP-4_0.83x0.83mm_P0.4mm', 'exact'),
    ('WLCSP-35_3.1x2.4mm_P0.42mm', 'sub'),
    ('WSON-8-1EP_2x2mm_P0.5mm_EP0.9x1.6mm', 'sub'),
    ('BC15C', 'sub'), ('BarrelJack_Wuerth_6941xx301002', 'exact'),
    ('JS1400', 'sub'), ('SOIC127P600X175-8N', 'sub'),
]

for q, mode in queries:
    if mode == 'exact':
        hits = by_name.get(q, [])
    else:
        hits = [(n, libs) for n, libs in by_name.items() if q.lower() in n.lower()]
    print('==', q, mode, '->', hits if mode == 'exact' else hits[:8])
