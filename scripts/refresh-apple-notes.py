#!/usr/bin/env python3
# Rafraîchit le contenu des notes liées à Apple Notes (HTML -> Markdown) via l API locale d Organizer.
# Usage : python3 -I scripts/refresh-apple-notes.py ["début de titre à afficher"]
import json, os, re, subprocess, sys, urllib.request
from html.parser import HTMLParser

info = json.load(open(os.path.expanduser('~/Library/Application Support/Organizer/api.json')))
B, T = info['base_url'], info['token']
def call(method, path, body=None):
    req = urllib.request.Request(B + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + T, 'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req))

class MD(HTMLParser):
    """Apple Notes HTML -> blocks of Markdown."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.blocks = []      # (kind, text, depth)
        self.buf = ''
        self.lists = []       # stack of 'ul'/'ol' with counters
        self.counters = []
        self.kind = 'p'
        self.href = None
        self.row = None
        self.table = None
    def flush(self, kind=None):
        t = self.buf.strip()
        if t:
            self.blocks.append((kind or self.kind, t, len(self.lists)))
        self.buf = ''
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ('h1', 'h2', 'h3'):
            self.flush(); self.kind = tag
        elif tag == 'div':
            self.flush(); self.kind = 'p'
        elif tag in ('ul', 'ol'):
            self.flush(); self.lists.append(tag); self.counters.append(0)
        elif tag == 'li':
            self.flush()
            self.counters[-1] += 1
            self.kind = ('ol%d' % self.counters[-1]) if self.lists[-1] == 'ol' else 'li'
        elif tag in ('b', 'strong'): self.buf += '**'
        elif tag in ('i', 'em'): self.buf += '*'
        elif tag in ('tt', 'code'): self.buf += '`'
        elif tag == 'a': self.href = a.get('href'); self.buf += '['
        elif tag == 'br': self.buf += '\n'
        elif tag == 'table': self.flush(); self.table = []
        elif tag == 'tr': self.row = []
        elif tag in ('td', 'th'): self.flush_cell_start = len(self.buf)
    def handle_endtag(self, tag):
        if tag in ('h1', 'h2', 'h3', 'div', 'li'):
            if self.table is None: self.flush()
            if tag == 'li': self.kind = 'p'
        elif tag in ('ul', 'ol'):
            self.flush(); self.lists.pop(); self.counters.pop(); self.kind = 'p'
        elif tag in ('b', 'strong'): self.buf += '**'
        elif tag in ('i', 'em'): self.buf += '*'
        elif tag in ('tt', 'code'): self.buf += '`'
        elif tag == 'a':
            self.buf += '](%s)' % (self.href or ''); self.href = None
        elif tag in ('td', 'th') and self.row is not None:
            self.row.append(self.buf.strip().replace('\n', ' ')); self.buf = ''
        elif tag == 'tr' and self.table is not None:
            self.table.append(self.row); self.row = None
        elif tag == 'table':
            self.blocks.append(('table', self.table, 0)); self.table = None
    def handle_data(self, data):
        self.buf += data

def to_markdown(html, title):
    p = MD(); p.feed(html); p.flush()
    blocks = [b for b in p.blocks if not (b[0] == 'p' and re.fullmatch(r'[\s*]*', b[1]))]
    # drop the leading h1 that repeats the note title
    if blocks and blocks[0][0] in ('h1', 'p') and blocks[0][1].strip('* ').strip() == title.strip():
        blocks = blocks[1:]
    out = []
    for i, (kind, text, depth) in enumerate(blocks):
        nxt = blocks[i + 1][0] if i + 1 < len(blocks) else None
        ind = '  ' * max(0, depth - 1)
        if kind == 'table':
            rows = ['| ' + ' | '.join(r) + ' |' for r in text if r]
            out.append('\n'.join(rows)); continue
        text = text.replace('\n', '  \n' + ind)
        if kind == 'h1': out.append('## ' + text)
        elif kind == 'h2': out.append('### ' + text)
        elif kind == 'h3': out.append('### ' + text)
        elif kind == 'li': out.append(ind + '- ' + text)
        elif kind.startswith('ol'): out.append(ind + kind[2:] + '. ' + text)
        else:
            bare = text.strip('* ')
            is_label = len(bare) <= 70 and not bare.endswith(('.', ',', ';')) and (nxt in ('li',) or (nxt or '').startswith('ol'))
            all_bold = text.startswith('**') and text.endswith('**') and text.count('**') == 2
            if is_label or (all_bold and len(bare) <= 90):
                out.append('### ' + bare)
            else:
                out.append(text)
    # blank line between blocks, but keep consecutive list items tight
    md = ''
    for i, line in enumerate(out):
        is_item = re.match(r'\s*(- |\d+\. )', line)
        prev_item = i > 0 and re.match(r'\s*(- |\d+\. )', out[i - 1])
        md += ('\n' if (is_item and prev_item) else '\n\n') + line if i else line
    return md.strip()

notes = [n for n in call('GET', '/notes') if n['external_id'] and not n['external_id'].startswith('gcal:')]
ids = [n['external_id'] for n in notes]
jxa = '''function run(argv){const ids=JSON.parse(argv[0]);const N=Application("Notes");const out={};
for(const id of ids){try{out[id]=N.notes.byId(id).body();}catch(e){}}return JSON.stringify(out);}'''
res = subprocess.run(['osascript', '-l', 'JavaScript', '-e', jxa, json.dumps(ids)], capture_output=True, text=True, timeout=300)
html = json.loads(res.stdout or '{}')
updated = 0
for n in notes:
    h = html.get(n['external_id'])
    if not h: continue
    md = to_markdown(h, n['title'])
    call('PATCH', '/notes/' + n['id'], {'body': md, 'updated_at': n['updated_at']})
    updated += 1
print(updated, '/', len(notes), 'notes reconverties')
if len(sys.argv) > 1:  # optional: print one note to check
    n = next(x for x in call('GET', '/notes') if x['title'].startswith(sys.argv[1]))
    print('----', n['title']); print(n['body'][:1200])
