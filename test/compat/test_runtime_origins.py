#!/usr/bin/env python3
"""Negative tests for retained, rebuilt and added native provenance."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'make'))
import runtime_origins as origins
import native_runtime as native
spec = importlib.util.spec_from_file_location("native_test", ROOT / "test/release/test_native_runtime.py")
native_test = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native_test)

def image(machine=0x14c):
    data=bytearray(128)
    data[:2]=b'MZ'
    struct.pack_into('<I',data,60,64)
    data[64:68]=b'PE\0\0'
    struct.pack_into('<H',data,68,machine)
    struct.pack_into('<H',data,86,0x2000)
    struct.pack_into('<H',data,88,0x10b)
    return bytes(data)

class RuntimeOriginsTests(unittest.TestCase):
    def setUp(self):
        self.upstream={'bin/old%d.dll'%i:('old%d'%i).encode() for i in range(21)}
        self.upstream[origins.REBUILT_PATH]=b'old StormLib'
        self.source={'commit':'a'*40,'tree':'b'*40,'dirty':False,
                     'submodule_commits':{'3rd/stormlib':origins.STORMLIB_COMMIT,
                                          '3rd/zlib':origins.ZLIB_COMMIT}}
        self.content=image()
        self.probe=native_test.probe_fixture()
        self.abi=json.dumps(self.probe).encode()
        with tempfile.TemporaryDirectory() as directory:
            component=Path(directory)/'stormlib.dll'
            component.write_bytes(self.content)
            self.manifest=native.make_manifest(self.source['commit'],self.source['tree'],
                'windows-x86',component,self.probe,'test fixture','cmake test')
        self.item=self.manifest['components'][0]
        self.item['probe']['abi_sha256']=origins.digest(self.abi)

    def test_retained_bytes_and_inventory_are_enforced(self):
        files=dict(self.upstream)
        native=origins.apply_origins(files,self.upstream,self.source)
        self.assertEqual(origins.verify_origins(files,{'native_runtime':native,'source':self.source},self.upstream),22)
        files['bin/old0.dll']=b'changed'
        with self.assertRaisesRegex(ValueError,'Retained native'):
            origins.apply_origins(files,self.upstream,self.source)
        files=dict(self.upstream,**{'bin/unapproved.dll':b'new'})
        with self.assertRaisesRegex(ValueError,'Unexpected'):
            origins.apply_origins(files,self.upstream,self.source)

    def test_rebuilt_allowlist_pins_settings_and_evidence(self):
        origins.validate_rebuilt(self.manifest,self.source,self.abi,self.content)
        for key,value in [('path','bin/bee.dll'),('origin','retained'),('sha256','0'*64)]:
            manifest=copy.deepcopy(self.manifest)
            manifest['components'][0][key]=value
            with self.assertRaises(ValueError):
                origins.validate_rebuilt(manifest,self.source,self.abi,self.content)
        for key in ('unicode','static_zlib'):
            manifest=copy.deepcopy(self.manifest)
            manifest['components'][0]['build'][key]=False
            with self.assertRaisesRegex(ValueError,'settings'):
                origins.validate_rebuilt(manifest,self.source,self.abi,self.content)
        manifest=copy.deepcopy(self.manifest)
        manifest['components'][0]['probe']['data']['pointer_size']=8
        with self.assertRaisesRegex(ValueError,'differs'):
            origins.validate_rebuilt(manifest,self.source,self.abi,self.content)
        with self.assertRaisesRegex(ValueError,'source commit'):
            origins.validate_rebuilt(dict(self.manifest,source_commit='c'*40),self.source,self.abi,self.content)
        with self.assertRaisesRegex(ValueError,'checksum'):
            origins.validate_rebuilt(self.manifest,self.source,b'{}',self.content)
        bad_source=copy.deepcopy(self.source)
        bad_source['submodule_commits']['3rd/zlib']='c'*40
        with self.assertRaisesRegex(ValueError,'pins'):
            origins.validate_rebuilt(self.manifest,bad_source,self.abi,self.content)

    def test_package_and_independent_verifier_agree(self):
        with tempfile.TemporaryDirectory() as directory:
            directory=Path(directory)
            (directory/'bin').mkdir()
            (directory/origins.REBUILT_PATH).write_bytes(self.content)
            (directory/'manifest.json').write_text(json.dumps(self.manifest))
            (directory/'abi.json').write_bytes(self.abi)
            files=dict(self.upstream)
            native=origins.apply_origins(files,self.upstream,self.source,directory)
            self.assertEqual(origins.verify_origins(files,{'native_runtime':native,'source':self.source},self.upstream),21)
            broken=copy.deepcopy(native)
            broken['files_verified_unchanged'].append(origins.REBUILT_PATH)
            with self.assertRaisesRegex(ValueError,'Retained native list'):
                origins.verify_origins(files,{'native_runtime':broken,'source':self.source},self.upstream)
            files['NATIVE_ABI.json']=b'changed'
            with self.assertRaisesRegex(ValueError,'ABI evidence'):
                origins.verify_origins(files,{'native_runtime':native,'source':self.source},self.upstream)

    def test_wrong_architecture_and_unknown_tools_rejected(self):
        with self.assertRaisesRegex(ValueError,'x86'):
            origins.pe_x86(image(0x8664))
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'pjass.exe'
            p.write_bytes(image())
            with self.assertRaisesRegex(ValueError,'pjass checksum'):
                origins.apply_origins(dict(self.upstream),self.upstream,self.source,pjass=p)

if __name__=='__main__':
    unittest.main(verbosity=2)

