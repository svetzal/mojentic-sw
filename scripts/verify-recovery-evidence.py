#!/usr/bin/env python3
"""Retrieve and checksum the retained recovery evidence, then recalculate correlation."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    root = Path(__file__).resolve().parents[1]
    directory = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'docs/evidence/transient-recovery'
    manifest = json.loads((directory / 'manifest.json').read_text())
    archive = directory / manifest['archive']['path']
    assert digest(archive.read_bytes()) == manifest['archive']['sha256'], 'archive checksum mismatch'
    with tarfile.open(archive, 'r:gz') as bundle:
        members = {m.name: m for m in bundle.getmembers() if m.isfile()}
        assert set(members) == set(manifest['members']), 'archive membership mismatch'
        for name, expected in manifest['members'].items():
            assert digest(bundle.extractfile(members[name]).read()) == expected, name
        contract = bundle.extractfile('retrieved/authoritative-contract.md').read()
        assert digest(contract) == manifest['authoritative_contract_sha256']
        # Check the original receipts too, independently of the new outer manifest.
        for prefix, filename in [('retrieved', 'manifest.json'), ('record-logs', 'archive-hashes.json')]:
            receipt = json.load(bundle.extractfile(f'{prefix}/{filename}'))
            for name, expected in receipt.items():
                assert digest(bundle.extractfile(f'{prefix}/{name}').read()) == expected, name
        # Re-run the existing executable correlator on the retained raw captures.
        with tempfile.TemporaryDirectory(prefix='recovery-evidence-') as temporary:
            temporary = Path(temporary)
            for prefix in ['retrieved/acceptance-traces', 'current/focused-traces']:
                destination = temporary / prefix
                destination.mkdir(parents=True)
                for name in members:
                    if name.startswith(prefix + '/') and name.endswith('.json'):
                        (destination / Path(name).name).write_bytes(bundle.extractfile(name).read())
                result = subprocess.run([
                    'python3', str(root / 'scripts/characterize-recovery-traces.py'),
                    str(destination), '--output', str(destination / 'correlation.out'),
                ], check=True)
                assert result.returncode == 0
    previous_end = 0
    for command in manifest['validation']:
        assert type(command['exit_code']) is int and command['exit_code'] == 0, command['name']
        assert previous_end <= command['start_unix_ns'] <= command['end_unix_ns']
        previous_end = command['end_unix_ns']
        for log in command['logs']:
            assert log in manifest['members'], log
    for name, expected in manifest['tested_source']['sha256'].items():
        assert digest((root / name).read_bytes()) == expected, f'tested source differs: {name}'
    print('PASS: archive, every member, original receipts, authoritative contract, command order/exits, '
          'tested source and both raw-capture correlations verified')
    print('Lifecycle semantics, delivered prefixes, zero tools and rollback also require the '
          'retained Swift assertions and independent review; checksums alone do not prove behavior.')


if __name__ == '__main__':
    main()
