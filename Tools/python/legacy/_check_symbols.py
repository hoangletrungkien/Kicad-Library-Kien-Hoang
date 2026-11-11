import glob
import os
import re
import subprocess

def count(t):
    return len(re.findall(r'^\t\(symbol "', t, re.M))

tot_head = tot_now = 0
rows = []
for p in sorted(glob.glob('Libraries/Symbols/Antmicro_*.kicad_sym')):
    rel = p.replace(os.sep, '/')
    h = subprocess.run(['git', 'show', 'HEAD:' + rel], capture_output=True).stdout.decode('utf-8', 'replace')
    n = open(p, encoding='utf-8', errors='replace').read()
    a, b = count(h), count(n)
    tot_head += a
    tot_now += b
    if a != b:
        rows.append((os.path.basename(p), a, b))
print("HEAD", tot_head, "NOW", tot_now)
for r in rows:
    print(r)
