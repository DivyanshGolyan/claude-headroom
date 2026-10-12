import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/measure-app.py"
SPEC = importlib.util.spec_from_file_location("measure_app", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sample(**changes):
    return dict(proc_start_abstime=1, executable_uuid="binary-a", user_time=1_000_000_000,
                system_time=2_000_000_000, pkg_idle_wkups=3, interrupt_wkups=4,
                phys_footprint=100, monotonic_seconds=10) | changes


class MeasurementTests(unittest.TestCase):
    def test_cpu_uses_cumulative_delta_and_actual_elapsed(self):
        result = MODULE.summarize([sample(), sample(user_time=2_000_000_000,
            system_time=2_500_000_000, monotonic_seconds=14, phys_footprint=200,
            pkg_idle_wkups=5)])
        self.assertEqual(result["cpu_total_seconds"], 1.5)
        self.assertEqual(result["cpu_percent_one_core"], 37.5)
        self.assertEqual(result["package_idle_wakeups"], 2)
        self.assertEqual(result["interrupt_wakeups"], 0)
        self.assertIsNone(result["child_cpu_seconds"])
        self.assertEqual(result["physical_footprint_bytes"]["median_sampled"], 150)

    def test_replacement_exec_and_counter_reset_rejected(self):
        for change in (dict(proc_start_abstime=2), dict(executable_uuid="binary-b"),
                       dict(user_time=0), dict(interrupt_wkups=0)):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                MODULE.validate_sample(sample(), sample(**change))

    def test_invalid_durations_rejected(self):
        for value in ("0", "-1", "nan", "inf"):
            with self.subTest(value=value), self.assertRaises(Exception):
                MODULE.positive_float(value)

    @unittest.skipUnless(sys.platform == "darwin", "macOS integration")
    def test_real_process_cpu_and_exit(self):
        process = subprocess.Popen([sys.executable, "-c",
            "print('ready', flush=True)\nwhile True: pass"], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            reader = MODULE.ProcessReader(process.pid)
            samples = MODULE.measure(reader, 0.3, 0.1)
            result = MODULE.summarize(samples)
            self.assertGreater(result["cpu_total_seconds"], 0)
            self.assertGreater(result["physical_footprint_bytes"]["end"], 0)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.wait()
            process.stdout.close()
        with self.assertRaises(RuntimeError):
            reader.read()


if __name__ == "__main__":
    unittest.main()
