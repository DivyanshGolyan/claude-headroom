#!/usr/bin/env python3
"""Read-only macOS process measurements. Never launches or signals the target."""

import argparse
import ctypes
import datetime
import json
import math
import os
import platform
import statistics
import sys
import time
import uuid


# Darwin's public sys/resource.h RUSAGE_INFO_V0 ABI. Times are nanoseconds;
# process start/exit are Mach absolute ticks (used only as identity/liveness).
class RusageInfoV0(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups",
            "pageins", "wired_size", "resident_size", "phys_footprint",
            "proc_start_abstime", "proc_exit_abstime",
        )
    ]


class ProcessReader:
    def __init__(self, pid):
        if sys.platform != "darwin":
            raise RuntimeError("This measurement requires macOS proc_pid_rusage.")
        self.pid = pid
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int

    def read(self):
        usage = RusageInfoV0()
        if self.lib.proc_pid_rusage(self.pid, 0, ctypes.byref(usage)) != 0:
            error = ctypes.get_errno()
            raise RuntimeError(f"Cannot read PID {self.pid}: {os.strerror(error)}")
        if usage.proc_exit_abstime:
            raise RuntimeError(f"PID {self.pid} has exited; measurement invalid.")
        return {name: getattr(usage, name) for name, _ in usage._fields_ if name != "uuid"} | {
            "executable_uuid": str(uuid.UUID(bytes=bytes(usage.uuid))),
            "monotonic_seconds": time.monotonic(),
        }


def validate_sample(first, current):
    for field in ("proc_start_abstime", "executable_uuid"):
        if first[field] != current[field]:
            raise RuntimeError("Target process was replaced or executed a different binary.")
    for field in ("user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups"):
        if current[field] < first[field]:
            raise RuntimeError(f"Cumulative counter {field} decreased; measurement invalid.")


def summarize(samples):
    first, last = samples[0], samples[-1]
    for previous, current in zip(samples, samples[1:]):
        validate_sample(previous, current)
    elapsed = last["monotonic_seconds"] - first["monotonic_seconds"]
    if elapsed <= 0:
        raise ValueError("Measurement elapsed time must be positive.")
    user = (last["user_time"] - first["user_time"]) / 1e9
    system = (last["system_time"] - first["system_time"]) / 1e9
    footprint = [sample["phys_footprint"] for sample in samples]
    return {
        "elapsed_seconds": elapsed,
        "sample_count": len(samples),
        "cpu_user_seconds": user,
        "cpu_system_seconds": system,
        "cpu_total_seconds": user + system,
        "cpu_percent_one_core": 100 * (user + system) / elapsed,
        "physical_footprint_bytes": {
            "start": footprint[0], "end": footprint[-1],
            "minimum_sampled": min(footprint), "maximum_sampled": max(footprint),
            "median_sampled": statistics.median(footprint),
        },
        "package_idle_wakeups": last["pkg_idle_wkups"] - first["pkg_idle_wkups"],
        "interrupt_wakeups": last["interrupt_wkups"] - first["interrupt_wkups"],
        "timer_callback_count": None,
        "child_cpu_seconds": None,
    }


def measure(reader, duration, interval):
    samples = [reader.read()]
    deadline = samples[0]["monotonic_seconds"] + duration
    while samples[-1]["monotonic_seconds"] < deadline:
        time.sleep(max(0, min(interval, deadline - time.monotonic())))
        current = reader.read()
        validate_sample(samples[-1], current)
        samples.append(current)
    return samples


def positive_float(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return number


def positive_pid(value):
    number = int(value)
    if number <= 0 or number > 2**31 - 1:
        raise argparse.ArgumentTypeError("must be a positive PID")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=positive_pid, required=True)
    parser.add_argument("--duration", type=positive_float, default=300, help="seconds (default: 300)")
    parser.add_argument("--interval", type=positive_float, default=5, help="seconds (default: 5)")
    parser.add_argument("--build-label", required=True, help="release revision and variant; recorded as supplied")
    args = parser.parse_args()
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    load_start = os.getloadavg()
    try:
        samples = measure(ProcessReader(args.pid), args.duration, args.interval)
        result = {
            "schema_version": 1,
            "started_at_utc": started,
            "host": {"macos": platform.mac_ver()[0], "architecture": platform.machine(),
                     "logical_cpu_count": os.cpu_count(), "load_average_start": load_start,
                     "load_average_end": os.getloadavg()},
            "target": {"pid": args.pid, "build_label_unverified": args.build_label,
                       "executable_uuid": samples[0]["executable_uuid"],
                       "process_start_absolute_ticks": samples[0]["proc_start_abstime"]},
            "requested_duration_seconds": args.duration,
            "requested_interval_seconds": args.interval,
            "metrics": summarize(samples),
            "samples": samples,
            "limitations": [
                "Target PID only: excludes security helpers, children, and work in system services.",
                "Child CPU and timer callback counts are unavailable (null), not zero.",
                "Darwin package-idle and interrupt wakeups are kernel counters, not all timer callbacks; zero is the returned counter delta.",
                "Footprint extrema are sampled; transient peaks between samples are missed.",
                "Build label is user supplied; executable UUID identifies the loaded binary, not its optimization flags.",
                "Does not count app/network errors or validate behavior; record these separately for each scenario.",
            ],
        }
    except (RuntimeError, ValueError, OSError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
