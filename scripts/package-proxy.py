"""Package an already-qualified macOS Envoy and matching Dataplane bundle."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import tarfile
import tempfile

spec = importlib.util.spec_from_file_location("owned", Path(__file__).with_name("package-owned.py"))
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)


def package(root, evidence, revision, output):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("full Dataplane revision required")
    binary = root / "out/envoy/envoy"
    bundle = root / "proxy/bundles/proxy/build/libproxy_bundle.so"
    proof = json.loads(evidence.read_text())
    if proof.get("status") != "passed" or proof.get("envoy_sha256") != owned.digest(binary) or proof.get("artifact_sha256") != owned.digest(bundle):
        raise ValueError("qualification must pass for these exact binaries")
    if proof.get("source_revision") != revision or proof.get("dirty", True):
        raise ValueError("qualification must use the clean pinned source revision")
    stages = {s["name"] for s in proof.get("stages", []) if s.get("exit_code") == 0}
    if not {"envoy", "runtime", "feature-toggles"} <= stages:
        raise ValueError("required native qualification stages missing")
    if owned.macos_minimum(bundle) != "13.0":
        raise ValueError("bundle must target macOS 13.0")
    # Reuse the owned receipt validation, including Mach-O and binary hashes.
    with tempfile.TemporaryDirectory() as directory:
        owned.package(binary, root / "out/envoy/provenance.json", "darwin-arm64", Path(directory), root / ".cache/envoy/LICENSE", root / ".cache/envoy/NOTICE")
    receipt = json.loads((root / "out/envoy/provenance.json").read_text())
    provenance = {
        "platform": "darwin-arm64", "minimumOS": "13.0",
        "dataplaneRevision": revision,
        "envoyRevision": receipt["revision"],
        "envoySha256": owned.digest(binary), "bundleSha256": owned.digest(bundle),
        "envoyBuildProfile": receipt["buildProfile"],
        "envoyPatches": receipt["patches"],
        "qualification": {"command": "make qualify-proxy", "status": "passed", "host": proof["platform"], "stages": [s["name"] for s in proof["stages"]]},
    }
    identity = hashlib.sha256(json.dumps(provenance, sort_keys=True).encode()).hexdigest()[:12]
    tag = f"dataplane-proxy-{revision[:12]}-{identity}-darwin-arm64"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{tag}.tar.gz"
    encoded = (json.dumps(provenance, indent=2) + "\n").encode()
    files = [("envoy", binary, 0o755), ("libproxy_bundle.so", bundle, 0o755),
             ("LICENSE.envoy", root / ".cache/envoy/LICENSE", 0o644),
             ("NOTICE.envoy", root / ".cache/envoy/NOTICE", 0o644),
             ("LICENSE.dataplane", root / "LICENSE", 0o644)]
    with archive.open("xb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed, tarfile.open(fileobj=compressed, mode="w") as tar:
        for name, path, mode in files:
            info = tarfile.TarInfo(name)
            info.size, info.mode = path.stat().st_size, mode
            with path.open("rb") as stream:
                tar.addfile(info, stream)
        info = tarfile.TarInfo("provenance.json")
        info.size, info.mode = len(encoded), 0o644
        tar.addfile(info, io.BytesIO(encoded))
    (output / f"{tag}.sha256").write_text(f"{owned.digest(archive)}  {archive.name}\n")
    (output / f"{tag}.provenance.json").write_bytes(encoded)
    return tag


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataplane", type=Path, required=True)
    parser.add_argument("--qualification", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--out", type=Path, default=Path("dist"))
    args = parser.parse_args()
    print(package(args.dataplane, args.qualification, args.revision, args.out))
