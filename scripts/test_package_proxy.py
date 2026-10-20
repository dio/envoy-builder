import importlib.util
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_proxy', Path(__file__).with_name('package-proxy.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProxyPackageTest(unittest.TestCase):
    def test_exact_pair_clean_source_and_sanitized_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mach = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, 1, 13 << 16, 26 << 16, 0)
            for name in ['out/envoy/envoy', 'proxy/bundles/proxy/build/libproxy_bundle.so']:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(mach)
            for name in ['.cache/envoy/LICENSE', '.cache/envoy/NOTICE', 'LICENSE']:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('license fixture')
            revision = 'a' * 40
            checksum = module.owned.digest(root / 'out/envoy/envoy')
            (root / 'out/envoy/provenance.json').write_text(json.dumps(dict(repository='upstream', revision=revision, patches=[], binarySha256=checksum, version='/private/source/envoy '+revision, minimumOS='13.0', buildProfile={})))
            proof = dict(status='passed', envoy_sha256=checksum, artifact_sha256=checksum, source_revision=revision, dirty=False, platform=dict(os='Darwin', architecture='arm64'), stages=[dict(name=n, exit_code=0) for n in ['envoy', 'runtime', 'feature-toggles']])
            evidence = root / 'evidence.json'
            evidence.write_text(json.dumps(proof))
            out = root / 'dist'
            tag = module.package(root, evidence, revision, out)
            with tarfile.open(out / f'{tag}.tar.gz') as archive:
                self.assertEqual(len(archive.getmembers()), 6)
                self.assertEqual(archive.extractfile('libproxy_bundle.so').read(), mach)
                self.assertNotIn('/private', archive.extractfile('provenance.json').read().decode())
            with self.assertRaises(FileExistsError):
                module.package(root, evidence, revision, out)
            for key, value, message in [('dirty', True, 'clean pinned'), ('artifact_sha256', 'wrong', 'exact binaries'), ('stages', [], 'stages missing')]:
                changed = dict(proof, **{key: value})
                evidence.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, message):
                    module.package(root, evidence, revision, out)
