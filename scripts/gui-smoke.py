#!/usr/bin/env python3
"""Fixture-only GUI launcher. Fingerprints production files without SQLite connections."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import pwd
import shutil
import stat
import subprocess
import tempfile
import uuid

REPO = pathlib.Path(__file__).resolve().parent.parent


def fingerprint(directory):
    """Read-only bytes/stat, never sqlite3. Refuse unstable reads or unusual files."""
    result = {}
    for name in ('studio.sqlite', 'studio.sqlite-wal', 'studio.sqlite-shm'):
        path = directory / name
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            result[name] = {'exists': False}
            continue
        with os.fdopen(fd, 'rb') as file:
            before = os.fstat(file.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise RuntimeError('Fingerprint requires regular files.')
            digest = hashlib.file_digest(file, 'sha256').hexdigest()
            after = os.fstat(file.fileno())
            attrs = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if attrs(before) != attrs(after):
                raise RuntimeError('Production files changed during fingerprint; stop.')
            result[name] = {'exists': True, 'size': before.st_size, 'mtime_ns': before.st_mtime_ns,
                            'sha256': digest, 'device': before.st_dev, 'inode': before.st_ino}
    return result


def create_run():
    root = pathlib.Path(tempfile.mkdtemp(prefix='iterune-gui-', dir='/private/tmp'))
    root.chmod(0o700)
    token = uuid.uuid4().hex
    (root / '.run-owner').write_text(token)
    (root / '.run-owner').chmod(0o600)
    return root, token


def cleanup_owned_run(root, token):
    # Only a directory we just created, with its private token. No supplied cleanup target.
    if (root.is_symlink() or root.parent != pathlib.Path('/private/tmp') or
            not root.name.startswith('iterune-gui-') or (root / '.run-owner').read_text() != token):
        raise RuntimeError('Refusing cleanup outside the owned smoke directory.')
    shutil.rmtree(root)


def validate_bundle(app, output_root):
    if app != output_root / 'Iterune.app' or app.is_symlink():
        raise RuntimeError('Unexpected application path.')
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    expected = {'CFBundleName': 'Iterune', 'CFBundleDisplayName': 'Iterune',
                'CFBundleExecutable': 'Iterune', 'CFBundleIdentifier': 'dev.agentskillstudio.mac.development',
                'IteruneRuntimeDataMode': 'isolatedDevelopment'}
    if any(info.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Not the expected isolated development app.')
    exe = app / 'Contents/MacOS/Iterune'
    if exe.is_symlink() or not exe.is_file() or not os.access(exe, os.X_OK):
        raise RuntimeError('Unexpected executable.')
    if not exe.resolve().is_relative_to(output_root.resolve()):
        raise RuntimeError('Executable escaped the fresh output directory.')
    return exe


def clean_environment(run):
    # No host CLI authentication/configuration, ambient test opt-ins, signing or production prefs.
    env = {key: os.environ[key] for key in ('PATH', 'DEVELOPER_DIR', 'SDKROOT') if key in os.environ}
    for name in ('home', 'tmp', 'data'):
        (run / name).mkdir(mode=0o700)
    env.update(HOME=str(run / 'home'), CFFIXED_USER_HOME=str(run / 'home'), TMPDIR=str(run / 'tmp'),
               SKILL_STUDIO_DATA_DIR=str(run / 'data'), ITERUNE_RUNTIME_MODE='isolatedDevelopment',
               CODEX_HOME=str(run / 'home/.codex'), CLAUDE_CONFIG_DIR=str(run / 'home/.claude'),
               STUDIO_BUILD_DIR=str(run / 'build'), STUDIO_OUTPUT_DIR=str(run / 'output'),
               STUDIO_DEVELOPMENT='1', STUDIO_SIGN_IDENTITY='')
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--headless', action='store_true', help='Validate the fixture store without opening a window.')
    parser.add_argument('--seconds', type=int, help='Close only this launched preview after 1–120 seconds.')
    parser.add_argument('--cleanup', action='store_true', help='Remove only this run after successful verification.')
    args = parser.parse_args()
    if args.seconds is not None and not 1 <= args.seconds <= 120:
        parser.error('--seconds must be between 1 and 120')
    os.umask(0o077)
    run, token = create_run()
    print('Private smoke directory:', run, flush=True)
    production = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir) / 'Library/Application Support/AgentSkillStudio'
    result = {'gui': 'not started', 'production_unchanged': False}
    before = fingerprint(production)
    (run / 'production-before.json').write_text(json.dumps(before, indent=2))
    try:
        source = run / 'source'; source.mkdir(mode=0o700)
        # Export only the build inputs, without Git metadata, existing output, or private state.
        for name in ('Sources', 'Tests', 'scripts'):
            shutil.copytree(REPO / name, source / name, ignore=shutil.ignore_patterns('__pycache__', '.DS_Store'))
        for name in ('Package.swift', 'LICENSE', 'BRAND_ASSETS.md'):
            shutil.copyfile(REPO / name, source / name)
        env = clean_environment(run)
        with (run / 'build.log').open('wb') as log:
            subprocess.run(['bash', 'scripts/build-app.sh'], cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        exe = validate_bundle(run / 'output/Iterune.app', run / 'output')
        # This path was built above in a new directory; never probe an arbitrary old executable.
        with exe.open('rb') as binary:
            executable_hash = hashlib.file_digest(binary, 'sha256').hexdigest()
        identity = subprocess.check_output([str(exe), '--runtime-identity'], env=env, text=True).strip()
        if identity != 'iterune-isolation-v1:development':
            raise RuntimeError('Compiled development identity mismatch.')
        missing = dict(env); missing.pop('SKILL_STUDIO_DATA_DIR')
        with (run / 'missing-root-check.log').open('wb') as log:
            denied = subprocess.run([str(exe), '--check-data-isolation'], env=missing,
                                    stdout=log, stderr=subprocess.STDOUT)
        if denied.returncode != 1:
            raise RuntimeError('Missing isolation root did not fail closed.')
        result['missing_root_rejected'] = True
        with (run / 'store-check.log').open('wb') as log:
            subprocess.run([str(exe), '--check-data-isolation'], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        result.update(store_check='PASS', executable_sha256=executable_hash,
                      fixture_only=True, history_import=False, AI=False, Keychain=False, source_publish=False)
        if not args.headless:
            with exe.open('rb') as binary:
                if hashlib.file_digest(binary, 'sha256').hexdigest() != executable_hash:
                    raise RuntimeError('Executable changed before launch.')
            with (run / 'gui.log').open('wb') as log:
                process = subprocess.Popen([str(exe)], env=env, stdout=log, stderr=subprocess.STDOUT)
                result['pid'] = process.pid
                print('Launched exact development executable, PID', process.pid, flush=True)
                try:
                    status = process.wait(timeout=args.seconds)
                    if status != 0:
                        raise RuntimeError('GUI exited unsuccessfully; inspect the private log.')
                except subprocess.TimeoutExpired:
                    # This PID is our child only; no pgrep/killall or other application is touched.
                    process.terminate()
                    process.wait(timeout=15)
            result['gui'] = 'launched and exited; visual checks require UI access'
    finally:
        after = fingerprint(production)
        result['production_unchanged'] = before == after
        (run / 'production-after.json').write_text(json.dumps(after, indent=2))
        (run / 'result.json').write_text(json.dumps(result, indent=2))
        if before != after:
            raise RuntimeError('Production fingerprint changed. Stop; no recovery is attempted.')
    print('Fixture checks PASS; production DB/WAL/SHM fingerprints unchanged.', flush=True)
    if args.cleanup:
        cleanup_owned_run(run, token)
    else:
        print('Evidence retained in the private smoke directory.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Exceptions can include private paths; logs stay in the private run directory.
        print('Smoke stopped. Inspect its private logs. No production restore or cleanup was attempted.', flush=True)
        raise SystemExit(1)
