import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import struct
import unittest

spec = importlib.util.spec_from_file_location('package_owned', Path(__file__).with_name('package-owned.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageTest(unittest.TestCase):
    def test_macos_minimum(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'envoy'
            header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
            binary.write_bytes(header + struct.pack('<6I', 0x32, 24, 1, 13 << 16, 26 << 16, 0))
            self.assertEqual(module.macos_minimum(binary), '13.0')
            binary.write_bytes(b'not mach-o')
            with self.assertRaisesRegex(ValueError, 'Mach-O'):
                module.macos_minimum(binary)

    def test_integrity_and_private_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'envoy'
            binary.write_bytes(b'test binary')
            receipt = root / 'receipt.json'
            receipt.write_text(json.dumps(dict(repository='https://github.com/envoyproxy/envoy.git', revision='a'*40,
                version='envoy '+ 'a'*40, patches=[], binarySha256=module.digest(binary), privatePath='/private/source')))
            license_file = root / 'LICENSE'
            license_file.write_text('Apache-2.0')
            notice_file = root / 'NOTICE'
            notice_file.write_text('Envoy authors')
            out = root / 'out'
            tag = module.package(binary, receipt, 'linux-arm64', out, license_file, notice_file)
            with tarfile.open(out / f'{tag}.tar.gz') as tar:
                self.assertEqual(tar.getnames(), ['envoy', 'provenance.json', 'LICENSE', 'NOTICE'])
                self.assertEqual(tar.extractfile('envoy').read(), b'test binary')
                self.assertNotIn('privatePath', json.load(tar.extractfile('provenance.json')))
            with self.assertRaisesRegex(ValueError, 'overwrite'):
                module.package(binary, receipt, 'linux-arm64', out, license_file, notice_file)
            binary.write_bytes(b'changed binary')
            with self.assertRaisesRegex(ValueError, 'does not match'):
                module.package(binary, receipt, 'linux-arm64', out, license_file, notice_file)


if __name__ == '__main__':
    unittest.main()
