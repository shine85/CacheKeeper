"""从真实发布标签之间的提交生成该版本日志，不复用固定的功能介绍。"""
import argparse
import pathlib
import re
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]


def git(*arguments):
    return subprocess.check_output(
        ['git', *arguments], cwd=ROOT, encoding='utf-8', errors='strict', timeout=30
    ).strip()


def generate_notes(version, source, repository):
    source = git('rev-parse', '--verify', source + '^{commit}')
    tag = 'v' + version
    tags = git('tag', '--merged', source, '--list', 'v[0-9]*').splitlines()
    previous = None
    if any(item != tag for item in tags):
        previous = git('describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*', '--exclude', tag, source)
    revision_range = f'{previous}..{source}' if previous else source
    commits = git('log', '--reverse', '--no-merges', '--format=%H%x09%s', revision_range).splitlines()
    control = (ROOT / 'control').read_text(encoding='utf-8')
    author = re.search(r'^Author: (.+)$', control, re.M)
    if not author:
        raise ValueError('control 缺少 Author，无法生成发布说明')
    repository_url = f'https://github.com/{repository}'
    lines = [f'## {version} 更新日志', '', f'作者：{author.group(1).strip()}', '']
    if previous:
        lines += [f'相较 {previous.removeprefix("v")}：', '']
    for commit in commits:
        sha, subject = commit.split('\t', 1)
        description = re.sub(r'^(feat|fix|docs|test|build|ci|chore|refactor|perf)(\([^)]*\))?!?:\s*', '', subject)
        lines.append(f'- {description}（[{sha[:7]}]({repository_url}/commit/{sha})）')
    if not commits:
        lines.append('- 使用相同源码重新构建，功能代码没有变化。')
    lines += ['', f'源码提交：`{source}`']
    if previous:
        lines += ['', f'[查看完整差异]({repository_url}/compare/{previous}...{source})']
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    notes = generate_notes(args.version, args.source, args.repository)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(notes, encoding='utf-8')
    print(f'PASS: {args.version} 更新日志已生成：{args.output}')
