"""Execute production effect accounting; keep precise faulty-classifier control."""
import argparse,pathlib,shutil,subprocess,sys,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--cc');args=p.parse_args()
    cc=args.cc or shutil.which('clang') or shutil.which('cc')
    if not cc:print('UNAVAILABLE: image effect requires C compiler; no tests ran');return 2
    out=pathlib.Path(tempfile.mkdtemp(prefix='image-effect-',dir=ROOT/'tmp'))
    source=(ROOT/'AxsCacheKeeperImageEffect.h').read_text()
    gate='return after.files ? AxsCacheKeeperImageEffectResidual : AxsCacheKeeperImageEffectEmpty;'
    if source.count(gate)!=1:raise SystemExit('FAIL: precise effect control unavailable')
    for role in ('red','green'):
        folder=out/role;folder.mkdir();(folder/'AxsCacheKeeperImageEffect.h').write_text(source.replace(gate,'return AxsCacheKeeperImageEffectEmpty;') if role=='red' else source)
        exe=folder/('test.exe' if sys.platform=='win32' else 'test')
        command=[cc]+(['cc'] if pathlib.Path(cc).stem=='zig' else [])
        built=subprocess.run(command+['-std=c11','-Wall','-Wextra','-Werror','-I'+str(folder),str(ROOT/'tests/image_effect_tests.c'),'-o',str(exe)],capture_output=True,timeout=60)
        (folder/'build.log').write_bytes(built.stdout+built.stderr)
        if built.returncode:print(built.stderr.decode(errors='replace'));return built.returncode
        run=subprocess.run([str(exe)],capture_output=True,timeout=30);(folder/'run.log').write_bytes(run.stdout+run.stderr)
        if role=='red':
            if run.returncode!=1 or run.stdout or run.stderr.strip()!=b'FAIL: image-effect: API return cannot hide residual files':raise SystemExit('FAIL: precise residual control not reached')
            print('PASS: precise residual negative control')
        else:
            print(run.stdout.decode(),end='')
            if run.returncode:print(run.stderr.decode());return run.returncode
    print('Artifacts:',out);return 0
if __name__=='__main__':raise SystemExit(main())
