"""Package a locally qualified, owned Envoy build; never upload source or patches."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import tarfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def macos_minimum(binary):
    with binary.open('rb') as stream:
        header = stream.read(32)
        if len(header) != 32 or struct.unpack_from('<II', header) != (0xFEEDFACF, 0x0100000C):
            raise ValueError('expected arm64 Mach-O executable')
        for _ in range(struct.unpack_from('<I', header, 16)[0]):
            command, size = struct.unpack('<II', stream.read(8))
            if size < 8 or size > 1 << 20:
                raise ValueError('invalid Mach-O load command')
            data = stream.read(size - 8)
            if command == 0x32:
                value = struct.unpack_from('<I', data, 4)[0]
                return f'{value >> 16}.{(value >> 8) & 255}' + (f'.{value & 255}' if value & 255 else '')
    raise ValueError('missing macOS deployment target')


def package(binary, receipt, platform, output, license_file, notice_file):
    license_bytes = license_file.read_bytes()
    notice_bytes = notice_file.read_bytes()
    record = json.loads(receipt.read_text())
    revision = record['revision']
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('receipt must pin a full source revision')
    binary_hash = digest(binary)
    if binary_hash != record['binarySha256']:
        raise ValueError('binary does not match build receipt')
    if revision not in record['version']:
        raise ValueError('binary version does not contain the pinned revision')
    if platform == 'darwin-arm64' and record.get('minimumOS') != macos_minimum(binary):
        raise ValueError('receipt minimumOS does not match Mach-O deployment target')
    # An allowlist keeps local paths and future private receipt fields out of releases.
    provenance = {key: record[key] for key in (
        'repository', 'revision', 'patches', 'binarySha256', 'version')}
    for key in ('buildProfile', 'buildScriptSha256', 'minimumOS'):
        if key in record:
            provenance[key] = record[key]
    provenance['platform'] = platform
    provenance['qualification'] = 'See release notes for the tests and supported host baseline.'
    encoded = (json.dumps(provenance, indent=2) + '\n').encode()
    # Include the binary digest: same upstream SHA with different patches/build flags
    # must never replace a consumer's previously pinned release.
    tag = f'envoy-{revision[:12]}-{binary_hash[:12]}-{platform}'
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'{tag}.tar.gz'
    if archive.exists():
        raise ValueError(f'refusing to overwrite {archive}')
    with archive.open('xb') as raw:
        import gzip
        with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w') as tar:
                info = tarfile.TarInfo('envoy')
                info.size = binary.stat().st_size
                info.mode = 0o755
                with binary.open('rb') as stream:
                    tar.addfile(info, stream)
                info = tarfile.TarInfo('provenance.json')
                info.size = len(encoded)
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(encoded))
                for name, data in [('LICENSE', license_bytes), ('NOTICE', notice_bytes)]:
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    info.mode = 0o644
                    tar.addfile(info, io.BytesIO(data))
    (output / f'{tag}.sha256').write_text(f'{digest(archive)}  {archive.name}\n')
    (output / f'{tag}.provenance.json').write_bytes(encoded)
    return tag


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--receipt', required=True, type=Path)
    parser.add_argument('--platform', required=True, choices=['darwin-arm64', 'linux-arm64', 'linux-amd64'])
    parser.add_argument('--license', required=True, type=Path)
    parser.add_argument('--notice', required=True, type=Path)
    parser.add_argument('--out', type=Path, default=Path('dist'))
    args = parser.parse_args()
    print(package(args.binary, args.receipt, args.platform, args.out, args.license, args.notice))


if __name__ == '__main__':
    main()
