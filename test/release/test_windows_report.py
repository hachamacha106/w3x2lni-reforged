#!/usr/bin/env python3
"""Reject incomplete or mismatched 1.1 Windows acceptance evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from release_artifact import validate_windows_report, sha256, PJASS_RELEASE, PJASS_SHA256

spec = importlib.util.spec_from_file_location('native_tests', Path(__file__).with_name('test_native_runtime.py'))
native_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native_tests)


def fixture():
    abi = native_tests.probe_fixture()
    files = {'NATIVE_ABI.json': json.dumps(abi).encode(), 'bin/stormlib.dll': b'test-only DLL bytes'}
    passed = {'before': 'Passed', 'after': 'Passed'}
    cases = []
    for name, status, dataset in (
        ('current-valid','Passed','warcraft-current'), ('legacy-127-valid','Passed','enUS-1.27.1'),
        ('legacy-124-valid','Passed','zhCN-1.24.4'), ('modern-current','Passed','warcraft-current'),
        ('current-fixture','Passed','warcraft-current'), ('invalid-syntax','Failed','warcraft-current'),
        ('invalid-type','Failed','warcraft-current'), ('modern-legacy-mismatch','Failed','enUS-1.27.1'),
        ('suppressed-errors','Failed','warcraft-current'), ('lua-skipped','Skipped','warcraft-current')):
        cases.append({'name':name,'status':status,'dataset':dataset,
            'checker_exit_code':None if status=='Skipped' else (1 if status=='Failed' and name!='suppressed-errors' else 0),
            'ignored_errors':1 if name=='suppressed-errors' else 0,
            'diagnostic_count':1 if status=='Failed' else 0, 'raw_output_bytes':0 if status=='Skipped' else 100})
    report = {'version':'1.1.0','status':'passed','archive_sha256':'a'*64,
        'archive_unchanged':True,'packaged_inputs_unchanged':True,'native_windows_execution':True,
        'public_archive_actions_removed':True,
        'conversion_count':4,'conversions':[{'name':name,'errors':0,'warnings':0,
            'native_contents_verified':True,'pjass':dict(passed)} for name in ('obj','lni','lni-to-obj','slk')],
        'steps':[{'name':'native-test','exit_code':0}],
        'pjass_verification':{'status':'passed','report_only':True,'release':PJASS_RELEASE,
            'checker_sha256':PJASS_SHA256,'checks':cases,'report_only_conversion':{
                'errors':0,'warnings':0,'mode':'obj','pjass':{'before':'Failed','after':'Failed'},
                'output_exists':True,'output_script_preserved':True,'input_unchanged':True,'output_sha256':'b'*64}},
        'native_abi_verification':{'status':'passed','abi_sha256':sha256(files['NATIVE_ABI.json']),
            'dll_sha256':sha256(files['bin/stormlib.dll']),'pointer_size':4,'dword_size':4,'create_size':48,'find_size':296,
            'create_offsets_verified':12,'find_offsets_verified':10,'exports_verified':len(abi['exports']),
            'constants_queried':[name for name in abi['constants'] if name!='MPQ_COMPRESSION_ZLIB'],
            'native_file_info_verified':True},
        'gui_archive_actions':{'status':'passed','headless':True,'internal_regression_only':True,'interactive_dialog_tested':False,
            'dialog_abi_verified':True,'dialog_unicode_buffers_verified':True,'dialog_cancel_and_errors_verified':True,
            'native_dialog':{'status':'passed','isolated_desktop':True,'hook_used':False,
                'input_desktop_switched':False,'interactive_dialog_tested':False,'gui_rendering_tested':False,
                'owner_error_ffff_reproduced':True,'invalid_owner_discarded':True,'unowned_retry_verified':True,
                'unicode_verified':True,'cancellation_verified':True,'inputs_unchanged':True,'output_entry_verified':True},
            'lni_folder_analyzed':True,'lni_marker_analyzed':True,'lni_project_unchanged':True,
            'optimization_worker_verified':True,'failure_reports_verified':True,'failure_recovery_verified':True},
        'lossless_archive':{'status':'passed','internal_regression_only':True,'source_unchanged':True,'decoded_payloads_equal':True,
            'bookkeeping_equal':True,'outer_header_equal':True,'unicode_paths_tested':True,
            'unknown_editor_hd_data_preserved':True,'existing_output_refused':True,'output_race_preserved':True,
            'cancellation_cleaned_up':True,'cli_cancellation_verified':True,'attempted_sector_sizes':[512,4096,65536],
            'verified_sector_sizes':[4096,65536],'skipped_sector_sizes':[512],
            'native_savings':128,'native_output_bytes':2048,'native_selected_sector_size':65536,
            'cli_savings':128,'cli_output_sha256':'c'*64,
            'pjass':{'analyze_input':'Passed','optimize_input':'Passed','optimize_output':'Passed'}}}
    return report,files


class WindowsReportTests(unittest.TestCase):
    def verify(self, report, files):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'report.json';path.write_text(json.dumps(report),encoding='utf-8')
            return validate_windows_report(path,'a'*64,'1.1.0',files)

    def test_full_evidence_accepts_report_only_script_failure(self):
        report,files=fixture()
        self.assertEqual(self.verify(report,files),report)

    def test_missing_groups_and_other_archive_or_version_rejected(self):
        original,files=fixture()
        mutations=[lambda r:r.pop('pjass_verification'),lambda r:r.pop('native_abi_verification'),
                   lambda r:r.pop('lossless_archive'),lambda r:r.pop('gui_archive_actions'),lambda r:r.update(version='1.0.0'),
                   lambda r:r.update(archive_sha256='d'*64)]
        for mutation in mutations:
            report=copy.deepcopy(original);mutation(report)
            with self.subTest(report=report),self.assertRaises(AssertionError):self.verify(report,files)

    def test_retired_archive_actions_cannot_be_public_or_mislabeled(self):
        original,files=fixture()
        mutations=[lambda r:r.pop('public_archive_actions_removed'),
                   lambda r:r.update(public_archive_actions_removed=False),
                   lambda r:r['gui_archive_actions'].pop('internal_regression_only'),
                   lambda r:r['lossless_archive'].update(internal_regression_only=False)]
        for mutation in mutations:
            report=copy.deepcopy(original);mutation(report)
            with self.subTest(report=report),self.assertRaises(AssertionError):self.verify(report,files)
        for action in ('analyze','optimize'):
            public_files=dict(files, **{'script/backend/cli/' + action + '.lua': b'public action'})
            with self.subTest(action=action),self.assertRaises(AssertionError):self.verify(original,public_files)

    def test_failed_checks_and_suppressed_errors_cannot_be_hidden(self):
        original,files=fixture()
        mutations=[lambda r:r['pjass_verification']['report_only_conversion'].update(output_exists=False),
                   lambda r:r['pjass_verification']['report_only_conversion']['pjass'].update(after='Passed'),
                   lambda r:r['pjass_verification']['checks'][0].update(ignored_errors=1),
                   lambda r:r['pjass_verification']['checks'][-2].update(ignored_errors=0),
                   lambda r:r['pjass_verification']['checks'][1].update(dataset='warcraft-current')]
        for mutation in mutations:
            report=copy.deepcopy(original);mutation(report)
            with self.subTest(report=report),self.assertRaises(AssertionError):self.verify(report,files)

    def test_gui_worker_checks_cannot_be_skipped_or_claim_interactive_testing(self):
        original,files=fixture()
        for key in ('dialog_abi_verified','dialog_unicode_buffers_verified','dialog_cancel_and_errors_verified',
                    'lni_folder_analyzed','lni_marker_analyzed','lni_project_unchanged',
                    'optimization_worker_verified','failure_reports_verified','failure_recovery_verified','headless'):
            report=copy.deepcopy(original);report['gui_archive_actions'][key]=False
            with self.subTest(key=key),self.assertRaises(AssertionError):self.verify(report,files)
        report=copy.deepcopy(original);report['gui_archive_actions']['interactive_dialog_tested']=True
        with self.assertRaises(AssertionError):self.verify(report,files)

    def test_actual_save_dialog_evidence_cannot_be_missing_or_simulated(self):
        original,files=fixture()
        mutations=[lambda r:r['gui_archive_actions'].pop('native_dialog'),
                   lambda r:r['gui_archive_actions']['native_dialog'].update(status='failed'),
                   lambda r:r['gui_archive_actions']['native_dialog'].update(hook_used=True)]
        for key in ('input_desktop_switched','interactive_dialog_tested','gui_rendering_tested'):
            mutations.append(lambda r,key=key:r['gui_archive_actions']['native_dialog'].update({key:True}))
        for key in ('isolated_desktop','owner_error_ffff_reproduced','invalid_owner_discarded',
                    'unowned_retry_verified','unicode_verified','cancellation_verified','inputs_unchanged','output_entry_verified'):
            mutations.append(lambda r,key=key:r['gui_archive_actions']['native_dialog'].update({key:False}))
        for mutation in mutations:
            report=copy.deepcopy(original);mutation(report)
            with self.subTest(report=report),self.assertRaises(AssertionError):self.verify(report,files)

    def test_dll_abi_and_preservation_evidence_bound_to_package(self):
        original,files=fixture()
        mutations=[lambda r:r['native_abi_verification'].update(dll_sha256='d'*64),
                   lambda r:r['native_abi_verification'].update(find_size=300),
                   lambda r:r['native_abi_verification'].update(exports_verified=1),
                   lambda r:r['lossless_archive'].update(decoded_payloads_equal=False),
                   lambda r:r['lossless_archive'].update(cancellation_cleaned_up=False),
                   lambda r:r['lossless_archive'].update(verified_sector_sizes=[512,4096,65536]),
                   lambda r:r['lossless_archive'].update(cli_savings=0)]
        for mutation in mutations:
            report=copy.deepcopy(original);mutation(report)
            with self.subTest(report=report),self.assertRaises(AssertionError):self.verify(report,files)


if __name__=='__main__':
    unittest.main(verbosity=2)
