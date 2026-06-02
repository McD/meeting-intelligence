import os, re, sys


def _inline(text):
    text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
    text = re.sub(r'(?<![\w*])\*([^*\n]+?)\*(?![\w*])', r'<i>\1</i>', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
    return text


def _close_lists(out, state):
    if state['ul']: out.append('</ul>'); state['ul'] = False
    if state['ol']: out.append('</ol>'); state['ol'] = False


def md_to_html(path):
    lines = open(path).read().split('\n')
    out = []
    state = {'ul': False, 'ol': False}
    for line in lines:
        if line.startswith('# '):
            _close_lists(out, state)
            out.append(f'<h2 style="margin:0 0 4px 0">{_inline(line[2:])}</h2>')
        elif line.startswith('## '):
            _close_lists(out, state)
            out.append(f'<h3 style="margin:20px 0 4px 0;border-bottom:1px solid #eee;padding-bottom:4px">{_inline(line[3:])}</h3>')
        elif line.startswith('### '):
            _close_lists(out, state)
            out.append(f'<h4 style="margin:12px 0 2px 0">{_inline(line[4:])}</h4>')
        elif re.match(r'^\s*- ', line):
            if state['ol']: out.append('</ol>'); state['ol'] = False
            content = re.sub(r'^\s*- ', '', line)
            if not state['ul']: out.append('<ul style="margin:4px 0;padding-left:20px">'); state['ul'] = True
            out.append(f'<li style="margin:3px 0">{_inline(content)}</li>')
        elif re.match(r'^\s*\d+\.\s+', line):
            if state['ul']: out.append('</ul>'); state['ul'] = False
            content = re.sub(r'^\s*\d+\.\s+', '', line)
            if not state['ol']: out.append('<ol style="margin:4px 0;padding-left:24px">'); state['ol'] = True
            out.append(f'<li style="margin:3px 0">{_inline(content)}</li>')
        elif line.strip() == '':
            _close_lists(out, state)
            out.append('<div style="margin:6px 0"></div>')
        else:
            _close_lists(out, state)
            out.append(f'<p style="margin:3px 0">{_inline(line)}</p>')
    _close_lists(out, state)
    return '\n'.join(out)


def md_to_mrkdwn(path, max_chars=3000):
    text = open(path).read()
    text = re.sub(r'^### (.+)$', r'*\1*', text, flags=re.MULTILINE)
    text = re.sub(r'^## (.+)$', r'\n*\1*', text, flags=re.MULTILINE)
    text = re.sub(r'^# (.+)$', r'*\1*', text, flags=re.MULTILINE)
    text = re.sub(r'\*\*(.+?)\*\*', r'*\1*', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<\2|\1>', text)
    return text[:max_chars]


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python3 -m briefings_mcp.render <file.md> [html|mrkdwn]', file=sys.stderr)
        sys.exit(1)
    path = sys.argv[1]
    fmt = sys.argv[2] if len(sys.argv) > 2 else 'html'
    if fmt == 'mrkdwn':
        print(md_to_mrkdwn(path))
    else:
        print(md_to_html(path))
