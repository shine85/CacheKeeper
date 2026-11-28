"""Run the real launcher against a bounded bootstrap-command fixture, no device."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE=Path(__file__).resolve().parents[1]
BASH=shutil.which('bash')

@unittest.skipUnless(BASH,'bash unavailable')
class LauncherTests(unittest.TestCase):
    def test_missing_roothide_never_starts(self):
        result=subprocess.run([BASH,str(SOURCE/'tools/diagnose/run.sh')],text=True,capture_output=True,timeout=10)
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('"state":"started"',result.stdout)
        self.assertIn('jbroot',result.stderr)

    @unittest.skipIf(os.name=='nt','native symlink semantics exercised on POSIX CI')
    def test_verified_bootstrap_link_and_existing_link(self):
        # Only the platform path commands are replaced. The production shell,
        # real symlink/stat checks and argument transfer run unchanged.
        (SOURCE/'tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='ck-launcher-',dir=SOURCE/'tmp') as name:
            base=Path(name);tools=base/'bin';tools.mkdir();root=base/'bootstrap';(root/'usr/lib').mkdir(parents=True)
            (root/'usr/lib/libroothide.dylib').write_bytes(b'fixture-library')
            package=base/'诊断 工具包 中文';package.mkdir();shutil.copyfile(SOURCE/'tools/diagnose/run.sh',package/'run.sh')
            def executable(path,text):path.write_text(text);path.chmod(0o755)
            executable(tools/'jbroot','#!/bin/sh\nif [ "$1" = / ]; then printf "%s\\n" "$CK_FIXTURE_ROOT"; else printf "%s\\n" "$1"; fi\n')
            executable(tools/'rootfs','#!/bin/sh\nprintf "%s\\n" "$1"\n')
            if sys.platform=='darwin':
                actual_stat=shutil.which('stat')
                executable(tools/'stat',f'#!/bin/sh\n[ "$1" = -L ] && [ "$2" = -c ] && [ "$3" = %d:%i ] && [ "$4" = -- ] && [ "$#" = 5 ] || exit 98\nexec "{actual_stat}" -L -f %d:%i "$5"\n')
            actual_ln=shutil.which('ln')
            executable(tools/'ln',f'#!/bin/sh\n[ "$1" = -s ] && [ "$2" = / ] || exit 99\nexec "{actual_ln}" -s "$CK_FIXTURE_ROOT" "$3"\n')
            executable(package/'ckdiagnose','#!/bin/sh\n[ "$1" = --background ] && [ "$2" = --output ] && [ -d "$3" ] && [ "$4" = --duration ] && [ "$5" = 90 ] || exit 90\nprintf \'{"state":"started"}\\n\'\n')
            environment=dict(os.environ,PATH=str(tools)+os.pathsep+os.environ['PATH'],CK_FIXTURE_ROOT=str(root))
            for _ in range(2):
                result=subprocess.run([BASH,str(package/'run.sh')],env=environment,text=True,capture_output=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('"state":"started"',result.stdout)
            self.assertTrue((package/'.jbroot').is_symlink())
            self.assertEqual((package/'.jbroot/usr/lib/libroothide.dylib').stat().st_ino,(root/'usr/lib/libroothide.dylib').stat().st_ino)
            (package/'.jbroot').unlink();wrong=base/'wrong';(wrong/'usr/lib').mkdir(parents=True);(wrong/'usr/lib/libroothide.dylib').write_bytes(b'other')
            (package/'.jbroot').symlink_to(wrong,target_is_directory=True)
            result=subprocess.run([BASH,str(package/'run.sh')],env=environment,text=True,capture_output=True,timeout=10)
            self.assertNotEqual(result.returncode,0)
            self.assertNotIn('"state":"started"',result.stdout)

if __name__=='__main__':unittest.main(verbosity=2)
