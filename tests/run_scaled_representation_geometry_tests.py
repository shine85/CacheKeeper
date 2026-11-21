"""Execute the fixed-source geometry reference; no host images or private ABI."""
import argparse,pathlib,shutil,subprocess,sys,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--cc');args=p.parse_args()
    cc=args.cc or shutil.which('clang') or shutil.which('cc')
    if not cc:print('UNAVAILABLE: scaled geometry needs a C compiler; no tests ran');return 2
    (ROOT/'tmp').mkdir(exist_ok=True);out=pathlib.Path(tempfile.mkdtemp(prefix='scaled-geometry-',dir=ROOT/'tmp'))
    source=(ROOT/'tests/ScaledRepresentationGeometry.h').read_text(encoding='utf-8')
    gate='if(w>bound.width)'
    if source.count(gate)!=1:raise SystemExit('FAIL: ambiguous no-upscale control')
    for role in ('red','green'):
        folder=out/role;folder.mkdir();(folder/'ScaledRepresentationGeometry.h').write_text(source.replace(gate,'if(w!=bound.width)') if role=='red' else source,encoding='utf-8')
        test=folder/'test.c';test.write_bytes((ROOT/'tests/scaled_representation_geometry_tests.c').read_bytes())
        exe=folder/('test.exe' if sys.platform=='win32' else 'test');command=[cc]+(['cc'] if pathlib.Path(cc).stem=='zig' else [])
        run=subprocess.run(command+['-std=c11','-Wall','-Wextra','-Werror','-I'+str(folder),str(test),'-lm','-o',str(exe)],capture_output=True,timeout=60)
        (folder/'compile.log').write_bytes(run.stdout+run.stderr)
        if run.returncode:print(run.stderr.decode(errors='replace'));return run.returncode
        run=subprocess.run([str(exe)],capture_output=True,timeout=30);(folder/'run.log').write_bytes(run.stdout+run.stderr)
        if role=='red':
            if run.returncode!=1 or run.stdout or run.stderr.strip()!=b'FAIL: scaled-representation: small original is never enlarged':raise SystemExit('FAIL: no-upscale negative control did not reach exact assertion')
            print('PASS: precise no-upscale negative control')
        else:
            print(run.stdout.decode(),end='')
            if run.returncode:print(run.stderr.decode());return run.returncode
    print('Artifacts:',out);return 0
if __name__=='__main__':raise SystemExit(main())
