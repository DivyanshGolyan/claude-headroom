#!/usr/bin/env python3
"""Build and compare owned release processes against a pinned baseline on macOS.

Uses real Keychain and HTTPS access. Never launches, terminates, or edits an
installed Headroom app. Generated source instrumentation is confined to output.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BASELINE = '47b109f9f0be4693cb0e7cf8401d920a280c4326'
FLAGS = ['-O', '-swift-version', '5', '-target', 'arm64-apple-macosx13.0']
spec = importlib.util.spec_from_file_location('measure_app', ROOT / 'scripts/measure-app.py')
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


def run(*args):
    return subprocess.check_output(args, cwd=ROOT)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError(f'Expected exactly one instrumentation anchor: {old!r}')
    return source.replace(old, new)


def instrument(source, variant, uses_engine=False, has_likely_out=False):
    if not uses_engine:
        source = replace_once(source,
            'private let historyStore = HistoryStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]\n        .appendingPathComponent("Headroom/history.json"))',
            'private let historyStore = HistoryStore(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["HEADROOM_PROBE_HISTORY"]!))')
    source = replace_once(source, '        item.autosaveName = "Headroom"\n', '')
    source = replace_once(source, '    private var item: NSStatusItem!', '''    private var probeRenderAttempts = 0
    private var probeDisplayCallbacks = 0
    private var probeFetchSuccesses = 0
    private var probeFetchFailures = 0
    private var probeSignal: DispatchSourceSignal?

    func installProbe() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.writeProbe() }
        source.resume()
        probeSignal = source
        writeProbe()
    }

    private func writeProbe() {
        let instant = ContinuousClock.now
        let forecast = timeline.forecast(at: instant)
        let category: String
        switch forecast {
        case .estimating: category = "estimating"
        case .awaitingUpdate: category = "awaitingUpdate"
        case .stale: category = "stale"
        case .ready: category = "ready"
        case .onTrack: category = "onTrack"
        case .gap: category = "gap"
        case .out: category = "out"
        case .spare: category = "spare"
        }
        let state: [String: Any] = [
            "render_attempts": probeRenderAttempts,
            "display_callbacks": probeDisplayCallbacks,
            "fetch_successes": probeFetchSuccesses,
            "fetch_failures": probeFetchFailures,
            "fetch_problem": problem.map { String(describing: $0) } ?? "none",
            "retry_in_seconds": instant.duration(to: refreshGate.earliestAutomaticAttempt(at: instant)).timeInterval,
            "forecast_category": category,
            "forecast_identity": String(describing: forecast),
            "wall_seconds": Date().timeIntervalSince1970,
            "uptime_seconds": ProcessInfo.processInfo.systemUptime,
            "next_display_seconds": PROBE_DEADLINE
        ]
        let path = ProcessInfo.processInfo.environment["HEADROOM_PROBE_SNAPSHOT"]!
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private var item: NSStatusItem!'''.replace('PROBE_DEADLINE',
        '(displayTimer?.fireDate.timeIntervalSinceNow ?? -1)' if variant == 'candidate'
        else '(timer?.fireDate.timeIntervalSinceNow ?? -1)'))
    source = replace_once(source, '    private func render() {',
        '    private func render() {\n        probeRenderAttempts += 1')
    if uses_engine:
        source = replace_once(source, '        let forecast = timeline.forecast(at: instant)',
            '        let snapshot = engine.status(at: instant)\n        let forecast = snapshot.forecast')
        source = source.replace('"fetch_successes": probeFetchSuccesses', '"fetch_successes": engine.probeFetchSuccesses')
        source = source.replace('"fetch_failures": probeFetchFailures', '"fetch_failures": engine.probeFetchFailures')
        source = source.replace('problem.map { String(describing: $0) }', 'snapshot.problem.map { String(describing: $0) }')
        source = source.replace('instant.duration(to: refreshGate.earliestAutomaticAttempt(at: instant)).timeInterval',
            'max(0, snapshot.retryAt?.timeIntervalSinceNow ?? 0)')
        source = replace_once(source, 'try server.start()',
            'try server.start(path: "/tmp/headroom-probe-\\(getpid())/control.sock")')
    else:
        source = replace_once(source, '                timeline.record(fetched)',
            '                probeFetchSuccesses += 1\n                timeline.record(fetched)')
        source = replace_once(source, '                failures += 1',
            '                probeFetchFailures += 1\n                failures += 1')
    if has_likely_out:
        source = replace_once(source, '        case .out: category = "out"',
            '        case .out: category = "out"\n        case .likelyOut: category = "likelyOut"')
    source = replace_once(source, 'Task { @MainActor in self?.render() }',
        'Task { @MainActor in\n                self?.probeDisplayCallbacks += 1\n                self?.render()\n            }')
    source = replace_once(source, '        app.delegate = delegate',
        '        delegate.installProbe()\n        app.delegate = delegate')
    return source


def prepare(output, baseline):
    revision = run('git', 'rev-parse', baseline).decode().strip()
    diff = run('git', 'diff', revision, '--', 'Sources', 'Info.plist', 'Resources')
    source_hashes = {}
    for variant in ('baseline', 'candidate'):
        directory = output / variant
        sources = directory / 'Sources'
        sources.mkdir(parents=True)
        if variant == 'baseline':
            names = run('git', 'ls-tree', '-r', '--name-only', revision, 'Sources').decode().splitlines()
            contents = {name: run('git', 'show', f'{revision}:{name}') for name in names if name.endswith('.swift')}
        else:
            contents = {str(path.relative_to(ROOT)): path.read_bytes() for path in sorted((ROOT / 'Sources').glob('*.swift'))}
        source_hashes[variant] = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
        for name, data in contents.items():
            target = sources / Path(name).name
            target.write_bytes(data)
        app_source = sources / 'App.swift'
        engine_source = sources / 'HeadroomEngine.swift'
        uses_engine = engine_source.exists()
        if uses_engine:
            engine = engine_source.read_text()
            engine = replace_once(engine, 'final class HeadroomEngine {',
                'final class HeadroomEngine {\n    var probeFetchSuccesses = 0\n    var probeFetchFailures = 0')
            engine = replace_once(engine, 'FileManager.default.urls(for: .applicationSupportDirectory,\n            in: .userDomainMask)[0].appendingPathComponent("Headroom/history.json")',
                'URL(fileURLWithPath: ProcessInfo.processInfo.environment["HEADROOM_PROBE_HISTORY"]!)')
            engine = replace_once(engine, '            timeline.record(fetched)',
                '            probeFetchSuccesses += 1\n            timeline.record(fetched)')
            engine = replace_once(engine, '            failures += 1',
                '            probeFetchFailures += 1\n            failures += 1')
            engine_source.write_text(engine)
        app_source.write_text(instrument(app_source.read_text(), variant, uses_engine,
            'case likelyOut(' in (sources / 'Forecast.swift').read_text()))
        app = directory / 'Headroom.app'
        macos = app / 'Contents/MacOS'
        resources = app / 'Contents/Resources'
        macos.mkdir(parents=True)
        resources.mkdir(parents=True)
        for original, destination in [('Info.plist', app / 'Contents/Info.plist'),
                                      ('Resources/Claude.svg', resources / 'Claude.svg'),
                                      ('LICENSE', resources / 'LICENSE.txt'),
                                      ('THIRD_PARTY_NOTICES.md', resources / 'THIRD_PARTY_NOTICES.md')]:
            destination.write_bytes(run('git', 'show', f'{revision}:{original}') if variant == 'baseline' else (ROOT / original).read_bytes())
        print(f'Building {variant}', flush=True)
        subprocess.run(['swiftc', *FLAGS, *map(str, sorted(sources.glob('*.swift'))), '-o', str(macos / 'Headroom')], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'com.divyanshgolyan.headroom', str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    metadata = {
        'created_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'baseline_revision': revision, 'candidate_head': run('git', 'rev-parse', 'HEAD').decode().strip(),
        'candidate_diff_sha256': hashlib.sha256(diff).hexdigest(), 'source_sha256': source_hashes,
        'build_flags': FLAGS, 'macos': platform.mac_ver()[0], 'architecture': platform.machine(),
        'logical_cpu_count': os.cpu_count(), 'load_average': os.getloadavg(),
        'swift_version': run('swiftc', '--version').decode().strip(),
        'scenario': 'Fresh isolated history, real successful live fetch, 10-second warm-up, idle status item; no menu interaction.',
        'limitations': ['Instrumented release builds; counters attach to each version\'s monitoring owner and display timer.',
            'App PID only: excludes credential helper and system-service CPU/memory.',
            'Kernel wakeup counters are not display timer callback counts.',
            'Sequential live quota responses and host background load can vary.',
            'Single-fetch idle scenario does not establish long-term, failure, menu, or sleep/wake performance.']}
    (output / 'candidate.diff').write_bytes(diff)
    write_json(output / 'metadata.json', metadata)


def snapshot(process, path):
    if process.poll() is not None:
        raise RuntimeError(f'Owned process exited with {process.returncode}')
    path.unlink(missing_ok=True)
    process.send_signal(signal.SIGUSR1)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists():
            return json.loads(path.read_text())
        if process.poll() is not None:
            raise RuntimeError('Owned process exited while collecting snapshot')
        time.sleep(0.05)
    raise RuntimeError('Snapshot timed out')


def validate(before, after, variant, duration):
    errors = []
    if before['fetch_successes'] != 1 or after['fetch_successes'] != 1:
        errors.append('Expected exactly one completed fetch before and after measurement')
    if before['fetch_failures'] or after['fetch_failures']:
        errors.append('Fetch failure occurred')
    if before['forecast_category'] not in ('ready', 'onTrack', 'spare', 'gap', 'out'):
        errors.append('Forecast is outside the stable comparison categories')
    if before['forecast_identity'] != after['forecast_identity']:
        errors.append('Forecast changed during measurement')
    callbacks = after['display_callbacks'] - before['display_callbacks']
    if after['render_attempts'] - before['render_attempts'] != callbacks:
        errors.append('Extra render attempts occurred during idle measurement')
    if callbacks != (1 if variant == 'baseline' else 0):
        errors.append(f'Unexpected display callbacks: {callbacks}')
    if variant == 'candidate' and 0 <= before['next_display_seconds'] <= duration + 2:
        errors.append('Display transition was due inside measurement window')
    wall = after['wall_seconds'] - before['wall_seconds']
    uptime = after['uptime_seconds'] - before['uptime_seconds']
    if abs(wall - uptime) > 1 or abs(uptime - duration) > 3:
        errors.append('Clock change, sleep, or excessive scheduling delay detected')
    return errors


def trial(output, variant, number, duration):
    directory = output / f'run-{number:02d}-{variant}'
    directory.mkdir()
    path = directory / 'snapshot.json'
    env = os.environ | {'HEADROOM_PROBE_HISTORY': str(directory / 'history.json'),
                        'HEADROOM_PROBE_SNAPSHOT': str(path)}
    binary = output / variant / 'Headroom.app/Contents/MacOS/Headroom'
    result = {'variant': variant, 'run': number, 'load_start': os.getloadavg()}
    with (directory / 'process.log').open('w') as log:
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 45
            # The initial snapshot proves SIGUSR1 is installed, even on a busy host.
            while not path.exists():
                if process.poll() is not None:
                    raise RuntimeError('Owned process exited before installing probe')
                if time.monotonic() >= deadline:
                    raise RuntimeError('Probe did not become ready within 45 seconds')
                time.sleep(0.05)
            while True:
                state = snapshot(process, path)
                result['startup_snapshot'] = state
                if state['fetch_failures']:
                    raise RuntimeError('Initial live fetch failed; no performance claim possible')
                if state['fetch_successes']:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('Initial live fetch did not complete within 45 seconds')
                time.sleep(1)
            time.sleep(10)
            before = snapshot(process, path)
            # Allow the snapshot handler to return before the counter baseline.
            time.sleep(0.1)
            samples = measurement.measure(measurement.ProcessReader(process.pid), duration, 5)
            after = snapshot(process, path)
            metrics = measurement.summarize(samples)
            metrics['timer_callback_count'] = after['display_callbacks'] - before['display_callbacks']
            result.update(before=before, after=after, metrics=metrics, samples=samples,
                          errors=validate(before, after, variant, duration), load_end=os.getloadavg())
            result['valid'] = not result['errors']
        except (RuntimeError, OSError, ValueError) as error:
            result.update(valid=False, errors=[str(error)])
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    shutil.rmtree(f'/tmp/headroom-probe-{process.pid}', ignore_errors=True)
    write_json(directory / 'result.json', result)
    return result


def summarize(results):
    summary = {'runs': results, 'all_valid': all(r['valid'] for r in results), 'aggregates': {}}
    for variant in ('baseline', 'candidate'):
        runs = [r for r in results if r['variant'] == variant and r['valid']]
        if not runs:
            continue
        values = {
            'cpu_ms_per_75_seconds': [r['metrics']['cpu_total_seconds'] * 1000 * 75 / r['metrics']['elapsed_seconds'] for r in runs],
            'physical_footprint_mib': [r['metrics']['physical_footprint_bytes']['median_sampled'] / 2**20 for r in runs],
            'package_idle_wakeups': [r['metrics']['package_idle_wakeups'] for r in runs],
            'interrupt_wakeups': [r['metrics']['interrupt_wakeups'] for r in runs],
            'display_callbacks': [r['metrics']['timer_callback_count'] for r in runs],
            'render_attempts': [r['after']['render_attempts'] - r['before']['render_attempts'] for r in runs],
        }
        summary['aggregates'][variant] = {key: {'median': statistics.median(v), 'minimum': min(v), 'maximum': max(v), 'values': v} for key, v in values.items()}
    summary['forecast_categories'] = sorted({r['before']['forecast_category'] for r in results if 'before' in r})
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--baseline-ref', default=BASELINE)
    parser.add_argument('--pairs', type=int, default=5)
    parser.add_argument('--duration', type=float, default=75)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--prepared', action='store_true', help='Use an existing --output build without rebuilding')
    args = parser.parse_args()
    if args.pairs < 1 or not 65 <= args.duration <= 90:
        parser.error('pairs must be positive; duration must be 65–90 seconds to cover exactly one minute callback')
    if args.prepared and args.output is None:
        parser.error('--prepared requires --output')
    output = (args.output or ROOT / 'build/comparison' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')).resolve()
    if not args.prepared:
        output.mkdir(parents=True, exist_ok=False)
        prepare(output, args.baseline_ref)
    elif not (output / 'metadata.json').exists():
        parser.error('Prepared output lacks metadata.json')
    print(f'Artifacts: {output}', flush=True)
    if args.prepare_only:
        return 0
    results = []
    for number in range(1, args.pairs + 1):
        for variant in ('baseline', 'candidate'):
            print(f'Pair {number}/{args.pairs}: {variant}, {args.duration:g}s measurement', flush=True)
            result = trial(output, variant, number, args.duration)
            if variant == 'candidate' and result['valid'] and results[-1]['valid']:
                if result['before']['forecast_category'] != results[-1]['before']['forecast_category']:
                    result['valid'] = False
                    result['errors'].append('Paired baseline and candidate forecast categories differ')
                    write_json(output / f'run-{number:02d}-{variant}' / 'result.json', result)
            results.append(result)
            summary = summarize(results)
            write_json(output / 'summary.json', summary)
            print(json.dumps({'variant': variant, 'valid': result['valid'], 'errors': result['errors'],
                              'metrics': result.get('metrics')}), flush=True)
            if not result['valid']:
                print('Comparison stopped: invalid run; inspect result.json.', flush=True)
                return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
