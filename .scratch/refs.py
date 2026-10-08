import json,re,subprocess
c=json.load(open('/home/peter/work/sonara-refactor/.scratch/cand.json'))
for r in c:
    m=re.search(r'(?:fn|const|enum|struct)\s+(\w+)',r['text'])
    if not m: print('??',r); continue
    n=m.group(1)
    out=subprocess.run(['grep','-rnw',n,'src'],capture_output=True,text=True).stdout.splitlines()
    out=[o for o in out if not o.startswith(r['file']+':%d:'%r['line'])]
    # classify
    def intest(o):
        f,l,_=o.split(':',2); l=int(l)
        txt=open(f).read().split('\n')
        for i,t in enumerate(txt):
            if t.startswith('mod tests') or t.strip()=='mod tests {' :
                return l>i
        return False
    nt=[o for o in out if not intest(o) and not re.match(r'\S+:\d+:\s*//',o)]
    print(f"{r['file']}:{r['line']} {n}: total={len(out)} nontest={len(nt)}")
    for o in nt[:4]: print('     ',o[:150])
