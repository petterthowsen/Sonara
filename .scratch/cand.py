import re,sys,json,subprocess
R='/home/peter/work/sonara-refactor/Engine/'
def parse(f):
    t=open(f).read(); out=[]
    for b in re.split(r'\n\n',t):
        if not b.startswith('warning') or 'generated' in b: continue
        head=b.split('\n')[0]
        if not re.match(r'warning: (function|method|methods|associated|constant|enum|struct|associated function|associated items|associated constant|associated functions)',head): continue
        loc=re.search(r'-->\s+(\S+?):(\d+):',b)
        file=loc.group(1)
        lines=b.split('\n')
        items=[]
        for i,l in enumerate(lines[:-1]):
            m=re.match(r'\s*(\d+) \|(.*)',l)
            if m and re.match(r'\s*\|\s*\^',lines[i+1]) :
                items.append((int(m.group(1)),m.group(2).strip()))
        if not items:
            items=[(int(loc.group(2)),'?')]
        for ln,txt in items: out.append((file,ln,txt,head))
    return out
cn=parse('/home/peter/work/sonara-refactor/.scratch/cn.txt'); ct=parse('/home/peter/work/sonara-refactor/.scratch/ct.txt')
ctk={(f,l) for f,l,_,_ in ct}
seen=set(); res=[]
for f,l,t,h in cn:
    if (f,l) in seen: continue
    seen.add((f,l)); res.append(dict(file=f,line=l,text=t,head=h,dead=(f,l) in ctk))
json.dump(res,open('/home/peter/work/sonara-refactor/.scratch/cand.json','w'),indent=1)
for r in res: print(('DEAD ' if r['dead'] else 'TEST ')+r['file']+':'+str(r['line'])+' '+r['text'][:90])
