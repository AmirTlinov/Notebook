"""Fail-closed inventory resolution and runner reports for verification."""
import json
from pathlib import Path
import re

import notebook_release as release


def lines(path):
    release.require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 64 * 1024 * 1024,
                    "Нет ограниченного отчёта: " + str(path))
    try:
        return path.read_text().splitlines()
    except UnicodeError as error:
        raise release.ReleaseError("Malformed report: " + str(path)) from error


def object_rows(lines, path):
    try:
        values = [json.loads(line) for line in lines]
    except (ValueError, UnicodeError) as error:
        raise release.ReleaseError("Malformed report: " + str(path)) from error
    release.require(values and all(isinstance(value, dict) for value in values), "Malformed report: " + str(path))
    return values


def rows(path):
    return object_rows(lines(path), path)


def swift_test_products(description, root):
    """SwiftPM describes the actual test targets used by its per-target products."""
    release.require(isinstance(description, dict) and description.get("path") == str(root.resolve())
                    and isinstance(description.get("targets"), list) and description["targets"],
                    "Malformed Swift package description or another source.")
    targets, products = set(), []
    for target in description["targets"]:
        release.require(isinstance(target, dict) and isinstance(target.get("name"), str)
                        and target["name"] and target["name"] not in targets
                        and isinstance(target.get("type"), str), "Malformed/duplicate Swift package target.")
        targets.add(target["name"])
        if target["type"] == "test":
            release.require(re.fullmatch(r"[A-Za-z0-9_]+", target["name"])
                            and target.get("c99name") == target["name"], "Unsupported Swift test product name.")
            products.append(target["name"])
    release.require(products, "Пустой Swift test product inventory.")
    return sorted(products)


def resolve(selectors, inventory, *, core=False):
    release.require(isinstance(inventory, list) and inventory and all(isinstance(item, str) and item for item in inventory)
                    and len(set(inventory)) == len(inventory), "Пустой или неоднозначный инвентарь тестов.")
    selected = set()
    for selector in selectors:
        if selector == "*":
            matches = set(inventory)
        else:
            # Native IDs are target/suite/method. Swift Testing IDs include a
            # module, function signature and source location; match components
            # exactly, so a nearby spelling cannot accidentally satisfy a route.
            parts = selector.split("/")
            matches = set()
            for item in inventory:
                if not core:
                    matched = item == selector or item.startswith(selector + "/")
                else:
                    short = item.split(".", 1)[-1]
                    candidates = (item, short)
                    matched = any(all(index < len(candidate.split("/"))
                                  and candidate.split("/")[index].split("(", 1)[0] == part
                                  for index, part in enumerate(parts)) for candidate in candidates)
                    if len(parts) == 1:
                        matched |= selector == item.split(".", 1)[0]
                        matched |= any(part.split("(", 1)[0] == selector for part in short.split("/")[:2])
                if matched:
                    matches.add(item)
        release.require(matches, "Selector отсутствует в фактическом инвентаре: " + selector)
        selected.update(matches)
    release.require(bool(selected), "Не выбраны реальные тесты.")
    return sorted(selected)


NATIVE_BUNDLES = {"NotebookTests", "NotebookUITests", "NotebookMacTests",
                  "NotebookAcceptanceUITests"}
SWIFT_EVENTS = {"runStarted", "runEnded", "testStarted", "testEnded", "testSkipped", "testCancelled",
                "testCaseStarted", "testCaseEnded", "testCaseSkipped", "testCaseCancelled", "issueRecorded"}


def native_outcomes(tree):
    release.require(isinstance(tree, dict) and isinstance(tree.get("testNodes"), list)
                    and tree["testNodes"], "Malformed XCTest report: testNodes")
    results = {}

    def walk(node, target=""):
        release.require(isinstance(node, dict), "Malformed XCTest node")
        if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
            target = node.get("name", "")
        if node.get("nodeType") == "Test Case":
            test = node.get("nodeIdentifier")
            status = node.get("result")
            release.require(target in NATIVE_BUNDLES and isinstance(test, str)
                            and re.fullmatch(r"[A-Za-z0-9_]+/[A-Za-z0-9_]+(?:\(\))?", test)
                            and status in ("Passed", "Failed", "Skipped", "Expected Failure"),
                            "Malformed XCTest case or unknown bundle")
            identity = target + "/" + test.removesuffix("()")
            release.require(identity not in results, "Неоднозначный XCTest ID: " + identity)
            results[identity] = status
        children = node.get("children", [])
        release.require(isinstance(children, list), "Malformed XCTest children")
        for child in children:
            walk(child, target)

    for node in tree["testNodes"]:
        walk(node)
    release.require(bool(results), "XCTest не сообщил ни одного исполненного ID.")
    return results


def native_inventory(report):
    """Xcode's flat enumeration owns qualified identifiers, never suite labels."""
    identifiers = []
    release.require(isinstance(report, (dict, list)), "Malformed Xcode inventory")

    def walk(value):
        if isinstance(value, dict):
            release.require(not value.get("errors"), "Xcode inventory содержит ошибки.")
            for key, child in value.items():
                if key in ("identifier", "testIdentifier", "nodeIdentifier") and isinstance(child, str):
                    identity = child.removesuffix("()")
                    if re.fullmatch(r"(?:" + "|".join(sorted(NATIVE_BUNDLES)) + r")/[A-Za-z0-9_]+/[A-Za-z0-9_]+", identity):
                        identifiers.append(identity)
                elif key == "tests" and isinstance(child, list) and all(isinstance(item, str) for item in child):
                    identifiers.extend(item.removesuffix("()") for item in child)
                elif isinstance(child, (dict, list)):
                    walk(child)
        elif isinstance(value, list):
            for child in value:
                release.require(isinstance(child, (dict, list)), "Malformed Xcode inventory row")
                walk(child)

    walk(report)
    release.require(identifiers and len(set(identifiers)) == len(identifiers)
                    and all(re.fullmatch(r"(?:" + "|".join(sorted(NATIVE_BUNDLES)) + r")/[A-Za-z0-9_]+/[A-Za-z0-9_]+", identity) for identity in identifiers),
                    "Пустой, malformed или неоднозначный Xcode inventory.")
    return sorted(identifiers)


def validate_summary(summary, outcomes=None):
    release.require(isinstance(summary, dict)
                    and all(type(summary.get(key)) is int for key in ("passedTests", "failedTests", "skippedTests"))
                    and summary["passedTests"] > 0 and summary["failedTests"] == 0 and summary["skippedTests"] == 0
                    and summary.get("runtimeWarnings") == [],
                    "Нужны исполненные тесты без ошибок, пропусков и runtime warnings.")
    if outcomes is not None:
        release.require(summary["passedTests"] == len(outcomes) and set(outcomes.values()) == {"Passed"},
                        "XCTest summary не совпадает с исполненными IDs.")


def native_execution(tree, selectors, inventory=None):
    outcomes = native_outcomes(tree)
    release.require(set(outcomes.values()) == {"Passed"}, "XCTest сообщил failed/skipped/неполный результат.")
    expected = resolve(selectors, inventory if inventory is not None else list(outcomes))
    release.require(set(expected) == set(outcomes) if inventory is not None else set(expected).issubset(outcomes),
                    "Запланированные и исполненные XCTest IDs различаются.")
    return {"format": 1, "planned": expected, "executed": sorted(outcomes), "skipped": [], "failed": []}


def swift_inventory(records, root, product=None):
    release.require(isinstance(records, list) and records and all(isinstance(record, dict) for record in records),
                    "Malformed Swift Testing records")
    release.require(product is None or isinstance(product, str) and re.fullmatch(r"[A-Za-z0-9_]+", product),
                    "Неверный Swift test product.")
    tests, seen = {}, set()
    for record in records:
        release.require(record.get("version") == "6.4.0", "Неизвестная версия Swift Testing report.")
        payload = record.get("payload")
        release.require(isinstance(payload, dict), "Malformed Swift Testing payload")
        release.require(record.get("kind") in ("test", "event"), "Malformed Swift Testing record kind")
        if record["kind"] != "test":
            release.require(payload.get("kind") in SWIFT_EVENTS, "Неизвестный Swift Testing event.")
            continue
        release.require(payload.get("kind") in ("suite", "function"), "Malformed Swift Testing test kind")
        identity = payload.get("id")
        location = payload.get("sourceLocation")
        release.require(isinstance(identity, str) and identity and identity not in seen
                        and isinstance(payload.get("name"), str) and payload["name"]
                        and isinstance(location, dict) and isinstance(location.get("fileID"), str)
                        and location["fileID"] and type(location.get("line")) is int and location["line"] > 0
                        and type(location.get("column")) is int and location["column"] > 0,
                        "Malformed/duplicate Swift Testing ID")
        seen.add(identity)
        release.require(product is None or identity.startswith(product + ".")
                        and location["fileID"].startswith(product + "/"),
                        "Swift Testing report содержит другой test product.")
        source = location.get("filePath")
        release.require(isinstance(source, str) and Path(source).resolve().is_relative_to(root.resolve()),
                        "Swift Testing inventory compiled from another source.")
        if payload["kind"] == "suite":
            continue
        release.require(type(payload.get("isParameterized")) is bool, "Malformed Swift parameterization flag")
        tests[identity] = payload
    release.require(bool(tests), "Пустой Swift Testing inventory.")
    return tests


def swift_execution(records, expected, root, product=None):
    discovered = swift_inventory(records, root, product)
    suites = {record["payload"].get("id") for record in records
              if record.get("kind") == "test" and record["payload"].get("kind") == "suite"}
    started, ended, skipped, failed = set(), set(), set(), set()
    case_started, case_ended = {}, {}
    run_started = run_ended = 0
    for record in records:
        if record.get("kind") != "event":
            continue
        event = record["payload"]
        kind, identity = event.get("kind"), event.get("testID")
        if kind == "runStarted":
            release.require(run_started == run_ended == 0, "Malformed Swift run start")
            run_started += 1
        elif kind == "runEnded":
            release.require(run_started == 1 and run_ended == 0, "Malformed Swift run end")
            run_ended += 1
        elif kind == "issueRecorded":
            # Known issues and cancelled/disabled work cannot certify a release.
            failed.add(identity or "<run>")
        elif identity in discovered:
            release.require(run_started == 1 and run_ended == 0, "Swift test event outside its run")
            if kind == "testStarted":
                release.require(identity not in started, "Duplicate Swift test start: " + identity)
                started.add(identity)
            elif kind == "testEnded":
                release.require(identity in started and identity not in ended, "Malformed Swift test end: " + identity)
                release.require(case_started.get(identity, 0) == case_ended.get(identity, 0), "Swift test ended before its cases")
                ended.add(identity)
            elif kind in ("testSkipped", "testCancelled", "testCaseSkipped", "testCaseCancelled"):
                skipped.add(identity)
            elif kind == "testCaseStarted":
                release.require(identity in started and identity not in ended, "Swift case started outside its test")
                case_started[identity] = case_started.get(identity, 0) + 1
            elif kind == "testCaseEnded":
                release.require(identity in started and identity not in ended
                                and case_ended.get(identity, 0) < case_started.get(identity, 0), "Malformed Swift case end")
                case_ended[identity] = case_ended.get(identity, 0) + 1
        elif kind in SWIFT_EVENTS - {"runStarted", "runEnded", "issueRecorded"}:
            release.require(identity in suites, "Swift event names an undiscovered test ID")
            release.require(run_started == 1 and run_ended == 0, "Swift suite event outside its run")
            if kind in ("testSkipped", "testCancelled", "testCaseSkipped", "testCaseCancelled"):
                skipped.add(identity)
    release.require(run_started == run_ended == 1 and not skipped and not failed and case_started == case_ended
                    and set(expected) == started == ended == set(discovered),
                    "Swift Testing: planned/executed/skipped IDs или завершение отчёта не совпадают.")
    release.require(all(not test.get("isParameterized") or case_started.get(identity, 0) > 0
                        for identity, test in discovered.items()), "Параметризованный Swift тест не исполнил случаи.")
    return {"format": 1, "planned": sorted(expected), "executed": sorted(ended),
            "executions": {identity: case_started.get(identity, 1) for identity in sorted(ended)},
            "skipped": [], "failed": []}


def python_execution(inventory, execution, script, reported_script=None):
    identity = {"script": str((reported_script or script).resolve()), "sha256": release.file_digest(script)}
    release.require(isinstance(inventory, dict) and isinstance(execution, dict)
                    and all(document.get("format") == 1 and all(document.get(key) == value for key, value in identity.items())
                            for document in (inventory, execution)), "Python report исполнил другой источник.")
    planned = resolve(("*",), inventory.get("tests"))
    results = execution.get("tests")
    release.require(isinstance(results, dict) and set(results) == set(planned) and set(results.values()) == {"passed"}
                    and execution.get("completed") is True and execution.get("successful") is True,
                    "Python report: incomplete/failed/skipped execution.")
    return {"format": 1, "planned": planned, "executed": sorted(results), "skipped": [], "failed": []}


def node_execution(records, scripts, root):
    scripts = {str(script.resolve()) for script in scripts}
    queued, outcomes, covered = set(), {}, set()
    final = None
    for record in records:
        kind, data = record.get("type"), record.get("data")
        release.require(isinstance(data, dict), "Malformed Node event")
        if kind == "test:summary":
            if "file" not in data:
                release.require(final is None, "Duplicate Node summary")
                final = data
            continue
        release.require(kind in ("test:enqueue", "test:pass", "test:fail")
                        and isinstance(data.get("file"), str) and isinstance(data.get("name"), str)
                        and type(data.get("line")) is int and type(data.get("column")) is int,
                        "Malformed Node test event")
        source = str(Path(data["file"]).resolve())
        release.require(source in scripts, "Node report исполнил другой источник: " + source)
        if str(Path(data["name"]).resolve()) == source or data.get("type", data.get("details", {}).get("type")) == "suite":
            continue
        identity = str(Path(source).relative_to(root.resolve())) + ":" + str(data["line"]) + ":" + str(data["column"]) + ":" + data["name"]
        covered.add(source)
        if kind == "test:enqueue":
            release.require(identity not in queued, "Duplicate Node test ID: " + identity)
            queued.add(identity)
        else:
            release.require(identity in queued and identity not in outcomes, "Malformed Node test outcome: " + identity)
            outcomes[identity] = "passed" if kind == "test:pass" and not data.get("skip") and not data.get("todo") else "failed"
    counts = final.get("counts", {}) if isinstance(final, dict) else {}
    release.require(final is not None and final.get("success") is True and queued and covered == scripts
                    and queued == set(outcomes) and set(outcomes.values()) == {"passed"}
                    and all(type(counts.get(key)) is int for key in ("tests", "passed", "failed", "cancelled", "skipped", "todo"))
                    and counts["tests"] == counts["passed"] == len(outcomes)
                    and all(counts[key] == 0 for key in ("failed", "cancelled", "skipped", "todo")),
                    "Node report: incomplete/failed/skipped execution.")
    return {"format": 1, "planned": sorted(queued), "executed": sorted(outcomes), "skipped": [], "failed": []}
