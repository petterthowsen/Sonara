import sys,re
R='/home/peter/work/sonara-refactor/Engine/'
def span(lines,idx):
    # idx 0-based line of item name
    s=idx
    while s>0 and re.match(r'\s*(///|#\[|//)',lines[s-1]): s-=1
    depth=0; opened=False; i=idx
    while i<len(lines):
        l=lines[i]
        l2=re.sub(r'"(\\.|[^"\\])*"','""',l)
        l2=re.sub(r"'(\\.|[^'\\])'","''",l2)
        l2=re.sub(r'//.*','',l2)
        for ch in l2:
            if ch in '([{':
                depth+=1
                if ch=='{': opened=True
            elif ch in ')]}':
                depth-=1
                if ch=='}' and depth==0 and opened: return s,i
            elif ch==';' and depth==0: return s,i
        i+=1
    raise Exception('no end')
def apply(file,ops):
    # ops: list of (line, 'del'|'cfgtest')
    p=R+file; lines=open(p).read().split('\n')
    for ln,op in sorted(ops,reverse=True):
        s,e=span(lines,ln-1)
        if op=='del':
            del lines[s:e+1]
            if s<len(lines) and s>0 and lines[s].strip()=='' and lines[s-1].strip()=='': del lines[s]
        else:
            ind=re.match(r'\s*',lines[ln-1]).group(0)
            lines.insert(ln-1,ind+'#[cfg(test)]')
    open(p,'w').write('\n'.join(lines))
if __name__=='__main__':
    # args: file op line [line...]
    f=sys.argv[1]; op=sys.argv[2]; apply(f,[(int(x),op) for x in sys.argv[3:]])
