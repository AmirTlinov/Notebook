#!/usr/bin/env python3
"""Report unittest inventory and actual outcomes for one registered source."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest


def write(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def cases(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from cases(test)
        else:
            yield test


class Outcomes(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.rows = {}

    def startTest(self, test):
        super().startTest(test)
        if test.id() in self.rows:
            raise RuntimeError("Duplicate unittest ID: " + test.id())
        self.rows[test.id()] = "started"

    def addSuccess(self, test):
        super().addSuccess(test)
        self.rows[test.id()] = "passed"

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.rows[test.id()] = "skipped"

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.rows[test.id()] = "failed"

    def addError(self, test, error):
        super().addError(test, error)
        self.rows[test.id()] = "failed"

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.rows[test.id()] = "failed"

    def addExpectedFailure(self, test, error):
        super().addExpectedFailure(test, error)
        self.rows[test.id()] = "failed"

    def addSubTest(self, test, subtest, error):
        super().addSubTest(test, subtest, error)
        if error is not None:
            self.rows[test.id()] = "failed"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--check", required=True)
    args = parser.parse_args()
    script = args.script.resolve(strict=True)
    # Importing preserves the script's normal __file__ and import paths while
    # leaving its __main__ runner to this reporter.
    spec = importlib.util.spec_from_file_location("notebook_checked_tests", script)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.path.insert(0, str(script.parent))
    spec.loader.exec_module(module)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    inventory = sorted(test.id() for test in cases(suite))
    if not inventory or len(set(inventory)) != len(inventory):
        raise RuntimeError("Empty or ambiguous unittest inventory")
    identity = {"script": str(script), "sha256": hashlib.sha256(script.read_bytes()).hexdigest()}
    write(args.evidence / (args.check + "-inventory.json"), {"format": 1, **identity, "tests": inventory})
    result = unittest.TextTestRunner(verbosity=2, resultclass=Outcomes).run(suite)
    write(args.evidence / (args.check + "-execution.json"), {"format": 1, **identity,
          "tests": result.rows, "completed": result.testsRun == len(inventory),
          "successful": result.wasSuccessful()})
    return 0 if result.wasSuccessful() and all(status == "passed" for status in result.rows.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
