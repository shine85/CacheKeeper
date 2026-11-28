"""Exercise Objective-C argument boundaries using the actual failed XCTest expression."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_xctest_macros import find_unprotected_commas

ROOT = Path(__file__).resolve().parents[1]
FAILED = 'XCTAssertTrue([@[@"imagePreparation",@"imageCollection"] containsObject:resumable.firstObject[@"nextPhase"]]);'
FIXED = 'XCTAssertTrue(([@[@"imagePreparation",@"imageCollection"] containsObject:resumable.firstObject[@"nextPhase"]]));'


class XCTestMacroTests(unittest.TestCase):
    def test_actual_failed_expression_is_rejected_and_parentheses_fix_it(self):
        self.assertEqual(len(find_unprotected_commas(FAILED)), 1)
        self.assertEqual(find_unprotected_commas(FIXED), [])

    def test_dictionary_second_argument_and_variadic_method_are_rejected(self):
        for source in ('XCTAssertEqualObjects(actual, @{@"a":@1,@"b":@2});',
                       'XCTAssertNotNil([NSString stringWithFormat:@"%@ %@", a, b]);'):
            with self.subTest(source=source):
                self.assertTrue(find_unprotected_commas(source))

    def test_normal_arguments_nested_calls_and_messages_are_accepted(self):
        source = '''XCTAssertEqual(count(a,b), expected, @"value %lu, %@", value, name);
XCTAssertEqualObjects(actual, (@{@"a":@1,@"b":@2}));
XCTAssertTrue([array containsObject:make(a,b)]);
XCTAssertNoThrow(call(@[@1,@2]));'''
        self.assertEqual(find_unprotected_commas(source), [])

    def test_block_body_comma_also_requires_parentheses(self):
        self.assertTrue(find_unprotected_commas('XCTAssertNoThrow(^{ int a=1,b=2; }());'))
        self.assertEqual(find_unprotected_commas('XCTAssertNoThrow((^{ int a=1,b=2; }()));'), [])

    def test_strings_character_literals_and_comments_do_not_create_calls(self):
        source = '''// XCTAssertTrue([@[@1,@2] count]);
/* XCTAssertTrue([@[@1,@2] count]); */
NSString *text=@"XCTAssertTrue([@[@1,@2] count]); \\\"";
char c=','; XCTAssertTrue(([@[@1, /* ), */ @2] count]) > 0);'''
        self.assertEqual(find_unprotected_commas(source), [])

    def test_multiline_and_nested_assertions_report_real_location(self):
        source = '/* comment */\nXCTAssertTrue(\n [@[@1,\n @2] count]);'
        self.assertEqual(find_unprotected_commas(source)[0], (3, 7, 'XCTAssertTrue'))
        self.assertEqual(len(find_unprotected_commas('XCTAssertNoThrow(XCTAssertTrue([@[@1,@2] count]));')), 1)

    def test_line_splicing_precedes_comments_and_identifiers(self):
        for newline in ('\n', '\r\n'):
            with self.subTest(newline=newline):
                self.assertEqual(find_unprotected_commas('// continued \\' + newline + FAILED), [])
                split='XCTAssert\\' + newline + 'True([@[@1,@2] count]);'
                found=find_unprotected_commas(split)
                self.assertEqual(len(found),1);self.assertEqual(found[0][0],2)

    def test_command_exit_reflects_fixture_and_scans_all_inputs(self):
        (ROOT/'tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='xctest-macros-', dir=ROOT/'tmp') as folder:
            bad=Path(folder)/'bad.m'; good=Path(folder)/'good.m'
            bad.write_text(FAILED,encoding='utf8');good.write_text(FIXED,encoding='utf8')
            command=[sys.executable,'-B',str(ROOT/'tests/check_xctest_macros.py')]
            result=subprocess.run(command+[str(good),str(bad)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,1);self.assertIn('bad.m:1:',result.stderr)
            self.assertEqual(subprocess.run(command+[str(good)],capture_output=True,timeout=10).returncode,0)


if __name__ == '__main__': unittest.main()
