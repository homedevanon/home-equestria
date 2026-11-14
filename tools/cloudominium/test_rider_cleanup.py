#!/usr/bin/env python3
"""Run the cloud rider regression without game assets, autoloads or player data."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, required=True, help='Godot 4.5-compatible Linux executable')
    parser.add_argument('--source-ref', help='test the cloud script from a Git revision instead of this checkout')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    resource = 'world/buildings/cloudominium/cloud_drift.gd'
    source = subprocess.check_output(['git', 'show', args.source_ref + ':' + resource], cwd=repo) if args.source_ref else (repo / resource).read_bytes()
    with tempfile.TemporaryDirectory(prefix='cloud-rider-test-') as temporary:
        project = Path(temporary)
        (project / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Cloud rider regression"\n')
        cache = project / '.godot'
        cache.mkdir()
        (cache / 'global_script_class_cache.cfg').write_text('list=[]\n')
        # A release executable otherwise mounts its adjacent game pack even
        # with --path. The copy has no adjacent PCK, extensions or autoloads.
        engine = project / 'godot'
        shutil.copy2(args.engine.resolve(), engine)
        script = project / 'cloud_drift.gd'
        script.write_bytes(source)
        env = os.environ.copy()
        env['XDG_DATA_HOME'] = str(project / 'data')
        result = subprocess.run([
            str(engine), '--headless', '--xr-mode', 'off', '--audio-driver', 'Dummy',
            '--path', str(project), '--script', str(Path(__file__).with_suffix('.gd').resolve()),
            '--', str(script),
        ], cwd=project, env=env, timeout=60)
        return 128 - result.returncode if result.returncode < 0 else result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
