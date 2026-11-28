"""Reject commas that C preprocessing splits inside unparenthesized Objective-C expressions."""
from pathlib import Path
import re
import sys


def find_unprotected_commas(source):
    characters, offsets = [], []
    index = 0
    while index < len(source):
        if source.startswith('\\\r\n', index):
            index += 3
        elif source.startswith('\\\n', index):
            index += 2
        else:
            characters.append(source[index]); offsets.append(index); index += 1
    logical = ''.join(characters)
    pattern = r'''//[^\n]*|/\*[\s\S]*?\*/|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|[A-Za-z_]\w*|[^\s]'''
    tokens = [(match.group(), offsets[match.start()]) for match in re.finditer(pattern, logical)
              if not match.group().startswith(('//', '/*', '"', "'"))]
    failures = []
    for index, (name, _) in enumerate(tokens[:-1]):
        if not name.startswith('XCTAssert') or tokens[index+1][0] != '(':
            continue
        parentheses = 1
        brackets = braces = 0
        for token, offset in tokens[index+2:]:
            if token == '(':
                parentheses += 1
            elif token == ')':
                parentheses -= 1
                if not parentheses:
                    break
            elif token == '[':
                brackets += 1
            elif token == ']':
                brackets -= 1
            elif token == '{':
                braces += 1
            elif token == '}':
                braces -= 1
            elif token == ',' and parentheses == 1 and (brackets > 0 or braces > 0):
                failures.append((source.count('\n', 0, offset)+1,
                                 offset-source.rfind('\n', 0, offset), name))
    return failures


def main(paths=None):
    paths = paths if paths is not None else sys.argv[1:]
    directory = Path(__file__).resolve().parent/'ui'
    files = [Path(path) for path in paths] if paths else sorted([*directory.glob('*.m'), *directory.glob('*.mm')])
    failures = 0
    for path in files:
        for line, column, name in find_unprotected_commas(path.read_text(encoding='utf-8-sig')):
            print(f'{path}:{line}:{column}: {name}: parenthesize the Objective-C expression containing commas', file=sys.stderr)
            failures += 1
    if not failures:
        print(f'PASS: XCTest macro argument boundaries in {len(files)} source files')
    return bool(failures)


if __name__ == '__main__': raise SystemExit(main())
