import os
import re

REPO = os.path.abspath('.')
TABLE = r'C:\Users\kien\AppData\Roaming\kicad\10.0\fp-lib-table'
OFFICIAL = r'C:\Program Files\KiCad\10.0\share\kicad\footprints'

text = open(TABLE, encoding='utf-8-sig', errors='replace').read()
entries = re.findall(r'\(lib \(name "([^"]+)"\) \(type "([^"]*)"\) \(uri "([^"]+)"', text)

libs = {}
for name, typ, uri in entries:
    if typ == 'Table':
        continue
    path = (uri.replace('${KICAD_ECO_ROOT}', REPO)
               .replace('${KICAD10_FOOTPRINT_DIR}', OFFICIAL)
               .replace('/', os.sep))
    if os.path.isdir(path):
        libs[name] = sorted(f[:-10] for f in os.listdir(path) if f.endswith('.kicad_mod'))

wanted = [
    ('PERSONAL_Analog Devices', 'MAX'),
    ('PERSONAL_Fanstel', ''),
    ('PERSONAL_MaxLinear', ''),
    ('PERSONAL_Recom', 'RAC'),
    ('PERSONAL_Package_DFN', 'DFN'),
    ('PERSONAL_uBlox', 'QC_'),
    ('PERSONAL_Wuerth', 'Barrel'),
    ('PERSONAL_Module', ''),
    ('PERSONAL_ESP32_mini', ''),
    ('PERSONAL_Bosch', 'LGA'),
    ('PERSONAL_Package_LGA', 'Bosch'),
    ('PERSONAL_Package_BGA', 'WLP'),
    ('PERSONAL_E-Switch', ''),
    ('PERSONAL_Package_SOIC', 'SOIC'),
    ('PERSONAL_Packages', 'SOIC'),
    ('PERSONAL_Connector_Generic', 'Barrel'),
]
for lib, needle in wanted:
    names = libs.get(lib)
    if names is None:
        print('==', lib, 'MISSING LIB')
        continue
    hits = [n for n in names if needle.lower() in n.lower()]
    print('==', lib, f'({len(names)} items)')
    for h in hits[:15]:
        print('    ', h)
