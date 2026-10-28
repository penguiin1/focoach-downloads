"""Run the complete applicable suite; report the Unix-only Mac benchmark as skipped."""
from pathlib import Path
import sys
import unittest


def main():
    if sys.platform != "win32":
        raise SystemExit("This runner requires native Windows.")
    source = Path.cwd()
    tests = source / "LocalAgent" / "tests"
    sys.path[:0] = [str(tests), str(source / "LocalAgent")]
    modules = sorted(path.stem for path in tests.glob("test_*.py"))
    mac_only = "test_mac_youtube_benchmark"
    assert mac_only in modules

    @unittest.skip("Mac-only opt-in evaluator requires Unix fcntl; verified on Mac")
    class MacBenchmark(unittest.TestCase):
        def test_mac_benchmark_platform(self):
            pass

    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for module in modules:
        suite.addTests(loader.loadTestsFromTestCase(MacBenchmark) if module == mac_only
                       else loader.loadTestsFromName(module))
    print(f"Discovered {len(modules)} test modules; exactly one Mac-only module skipped.", flush=True)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
