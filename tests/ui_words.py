"""Keeps Switchboard's controls short: a button, toggle or menu row says what it
does in four words or fewer, and a tooltip adds one short line of eight words or
fewer. Reads Sources/, so a wordy control fails here before anyone sees it.
Prints each offender as file:line and exits 1 when there are any.

    python3 tests/ui_words.py [Sources dir]
"""
import pathlib
import re
import sys

MAX_LABEL, MAX_TIP = 4, 8
LABEL = re.compile(r'\b(?:Button|Toggle|Label|Menu|Link)\(\s*"')
TIP = re.compile(r'\.help\(\s*"')


def literal(line: str, start: int) -> str:
    """The Swift string literal opening at `start`, with each \\( ... ) interpolation
    replaced by one placeholder word, since it shows as one value on screen."""
    out, i, depth = [], start, 0
    while i < len(line):
        c = line[i]
        if depth:
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if not depth:
                    out.append('X')
            elif c == '"':
                # a string inside an interpolation: skip to its end
                j = line.index('"', i + 1) if '"' in line[i + 1:] else len(line)
                i = j
        elif c == '\\' and i + 1 < len(line) and line[i + 1] == '(':
            depth, i = 1, i + 1
        elif c == '\\':
            i += 1
        elif c == '"':
            break
        else:
            out.append(c)
        i += 1
    return ''.join(out)


def words(s: str) -> int:
    return len(s.split())


def scan(root: pathlib.Path) -> list[str]:
    bad = []
    for f in sorted(root.glob('*.swift')):
        for n, line in enumerate(f.read_text().splitlines(), 1):
            for rx, cap, kind in ((LABEL, MAX_LABEL, 'label'), (TIP, MAX_TIP, 'tooltip')):
                for m in rx.finditer(line):
                    text = literal(line, m.end())
                    if words(text) > cap:
                        bad.append(f'{f.name}:{n} {kind} of {words(text)} words: {text}')
    return bad


if __name__ == '__main__':
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent / 'Sources')
    found = scan(root)
    print('\n'.join(found) if found else 'every control is short')
    sys.exit(1 if found else 0)
