"""Compile and execute the production, portable resource classifier."""
import argparse,pathlib,shutil,subprocess,sys,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--cc');parser.add_argument('--include',type=pathlib.Path,default=ROOT);parser.add_argument('--expect-red');args=parser.parse_args()
    compiler=args.cc or shutil.which('clang') or shutil.which('cc')
    if not compiler:
        print('UNAVAILABLE: a C compiler is required; no resource layout test ran.');return 2
    (ROOT/'tmp').mkdir(exist_ok=True)
    output=pathlib.Path(tempfile.mkdtemp(prefix='resource-layout-',dir=ROOT/'tmp'))
    binary=output/('layout.exe' if sys.platform=='win32' else 'layout')
    command=[compiler]+(['cc'] if pathlib.Path(compiler).stem=='zig' else [])
    command+=['-std=c11','-Wall','-Wextra','-Werror','-I'+str(args.include),str(ROOT/'tests/resource_layout_tests.c'),'-o',str(binary)]
    built=subprocess.run(command,capture_output=True,text=True,timeout=60)
    (output/'build.log').write_text(built.stdout+built.stderr,encoding='utf-8')
    print('Artifacts:',output)
    if built.returncode:print(built.stdout+built.stderr);return built.returncode
    run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=60)
    (output/'run.log').write_text(run.stdout+run.stderr,encoding='utf-8');print(run.stdout+run.stderr,end='')
    if args.expect_red:
        expected='FAIL: resource-layout: '+args.expect_red
        if run.returncode!=1 or run.stderr.strip()!=expected:print('FAIL: precise RED not reached');return 1
        print('PASS: precise resource-layout RED');return 0
    return run.returncode
if __name__=='__main__':raise SystemExit(main())
