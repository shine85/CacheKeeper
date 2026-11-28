"""Require missing automatic root restoration to hit the actual no-click UIKit assertion."""
from pathlib import Path
import json
import hashlib
import subprocess
import sys


def main():
    root=Path(__file__).resolve().parents[1];out=root/'tmp/collection-return-red';out.mkdir(parents=True,exist_ok=True)
    source=(root/'Prefs/Settings.m').read_text(encoding='utf8')
    original=source
    start=source.index('- (void)axs_cachekeeper_restore_collection {')
    end=source.index('- (void)tabChanged:',start)
    source=source[:start]+'- (void)axs_cachekeeper_restore_collection {}\n'+source[end:]
    # Copy only the implementation mutation; all dependencies and tests remain current.
    for header in ('DiagnosticsPage.h','CollectionNavigation.h','SearchInput.h','SearchDiagnostics.h','SearchNavigation.h','SearchHitRouting.h'):
        source=source.replace('"'+header+'"','"../../Prefs/'+header+'"')
    source=source.replace('"../Axs','"../../Axs')
    (out/'Settings.m').write_text(source,encoding='utf8')
    (out/'source-manifest.json').write_text(json.dumps({'mutation':'remove automatic collection root navigation only','sourceSHA256':hashlib.sha256(original.encode()).hexdigest(),'mutatedSHA256':hashlib.sha256(source.encode()).hexdigest(),'expectedFailure':'COLLECTION_AUTO_RETURN'},indent=2),encoding='utf8')
    spec=(root/'tests/ui/project.yml').read_text(encoding='utf8-sig');anchor='../../Prefs/Settings.m';assert spec.count(anchor)==1
    (out/'project.yml').write_text(spec.replace(anchor,'../../tmp/collection-return-red/Settings.m'),encoding='utf8')
    subprocess.run(['xcodegen','generate','--spec',str(out/'project.yml'),'--project',str(out),'--project-root',str(out)],check=True,timeout=60)
    method='testRecreatedRootAutomaticallyReturnsToOriginalImageWithoutContinue'
    options=['-project',str(out/'CacheKeeperInputTests.xcodeproj'),'-scheme','InputHarness','-destination',f'platform=iOS Simulator,id={sys.argv[1]}',
             '-derivedDataPath',str(out/'DerivedData'),'-only-testing:ScanPageTests/AxsCollectionReturnTests/'+method,'CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-']
    with (out/'build.log').open('w',encoding='utf8') as log:
        subprocess.run(['xcodebuild','build-for-testing',*options],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
    result=out/'RedResults.xcresult'
    with (out/'red.log').open('w',encoding='utf8') as log:
        test=subprocess.run(['xcodebuild','test-without-building',*options,'-resultBundlePath',str(result),'-parallel-testing-enabled','NO'],stdout=log,stderr=subprocess.STDOUT,timeout=420)
    summary=json.loads(subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',str(result),'--format','json'],text=True,timeout=60))
    (out/'red-summary.json').write_text(json.dumps(summary,indent=2),encoding='utf8')
    failures=summary.get('testFailures',[])
    assert test.returncode==65 and summary['failedTests']==summary['totalTestCount']==1 and failures
    assert all(method in str(failure) and 'COLLECTION_AUTO_RETURN' in failure.get('failureText','') for failure in failures),failures
    print('PASS: absent automatic return reaches exact real root navigation RED',flush=True)


if __name__=='__main__':main()
