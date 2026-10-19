import re,sys
def tokenize(sql):
    """Возвращает список (kind, text): kind in ws, line, block, str, qid, dollar, other."""
    out=[];i=0;n=len(sql)
    def dollar_tag(i):
        m=re.match(r'\$[A-Za-z_]*\$',sql[i:i+40]); return m.group(0) if m else None
    while i<n:
        c=sql[i]
        if c=='-' and sql.startswith('--',i):
            j=sql.find('\n',i); j=n if j<0 else j
            out.append(('line',sql[i:j])); i=j; continue
        if c=='/' and sql.startswith('/*',i):
            depth=1;j=i+2
            while j<n and depth:
                if sql.startswith('/*',j): depth+=1;j+=2
                elif sql.startswith('*/',j): depth-=1;j+=2
                else: j+=1
            out.append(('block',sql[i:j])); i=j; continue
        if c=="'":
            j=i+1
            while j<n:
                if sql[j]=="'":
                    if j+1<n and sql[j+1]=="'": j+=2; continue
                    break
                j+=1
            out.append(('str',sql[i:j+1])); i=j+1; continue
        if c=='"':
            j=sql.find('"',i+1); j=n-1 if j<0 else j
            out.append(('qid',sql[i:j+1])); i=j+1; continue
        if c=='$':
            t=dollar_tag(i)
            if t:
                j=sql.find(t,i+len(t))
                if j<0: out.append(('other',sql[i:])); i=n; continue
                body=sql[i+len(t):j]
                out.append(('dollar_open',t)); out.extend(tokenize(body)); out.append(('dollar_close',t)); i=j+len(t); continue
        if c in ' \t\r\n':
            j=i
            while j<n and sql[j] in ' \t\r\n': j+=1
            out.append(('ws',sql[i:j])); i=j; continue
        j=i+1
        while j<n and sql[j] not in " \t\r\n'\"$-/": j+=1
        out.append(('other',sql[i:j])); i=j
    return out
def code_tokens(toks): return [t for t in toks if t[0] not in ('ws','line','block')]
def strip(sql):
    toks=tokenize(sql); out=[]
    for k,t in toks:
        if k in('line','block'): continue
        out.append(t)
    s=''.join(out)
    s=re.sub(r'[ \t]+\n','\n',s)
    s=re.sub(r'\n{3,}','\n\n',s)
    return s
if __name__=='__main__':
    src=open(sys.argv[1],encoding='utf-8').read()
    st=strip(src)
    a=code_tokens(tokenize(src)); b=code_tokens(tokenize(st))
    print('tokens equal:',a==b, len(a), len(b), 'bytes',len(src),'->',len(st))
    cyr=[l for l in st.split('\n') if re.search('[А-Яа-яЁё]',l)]
    print('cyrillic lines left:',len(cyr))
    for l in cyr[:40]: print('  ',l[:140])
