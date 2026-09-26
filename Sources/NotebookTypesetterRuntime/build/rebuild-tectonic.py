#!/usr/bin/env python3
"""Rebuild the pinned guest kernel; never installs or changes a tracked pin."""
from pathlib import Path
import argparse, gzip, json, os, platform, shutil, subprocess, sys, tarfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "Sources/NotebookTypesetterRuntime"
sys.path.insert(0, str(ROOT / "Applications"))
from prepare_notebook_distribution import obtain, digest, verify


def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def test_fontmap(upstream, work):
    source = SOURCE / "build/fontmap-test.c"
    source_sha = digest(source)
    pdf_io = upstream / "crates/pdf_io/pdf_io"
    binary = work / "fontmap-test"
    log = work / "fontmap-test.log"
    with log.open("w") as output:
        run(["xcrun", "clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
             "-Wno-sign-compare", "-Wno-deprecated-declarations", "-fsanitize=address,undefined",
             "-fno-omit-frame-pointer", "-Dmemcmp=fontmap_test_memcmp",
             "-I" + str(pdf_io), "-I" + str(upstream / "crates/bridge_core/support"),
             "-I" + str(upstream / "crates/bridge_flate/include"),
             source, pdf_io / "dpx-dpxutil.c", "-Wl,-dead_strip", "-o", binary],
            stdout=output, stderr=subprocess.STDOUT)
        run([binary], stdout=output, stderr=subprocess.STDOUT)
    if digest(source) != source_sha:
        raise RuntimeError("Font-map regression changed during execution")
    return {"sourceSHA256": source_sha, "logSHA256": digest(log), "passed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=ROOT / ".build/typesetter-build/tectonic-rebuild")
    args = parser.parse_args()
    lock_bytes = (SOURCE / "Runtime.lock.json").read_bytes()
    lock = json.loads(lock_bytes)
    engine, pin = lock["engineSource"], lock["engineSource"]["build"]
    if platform.system() != "Darwin" or platform.machine() != "arm64" or pin["host"] != "arm64-macos":
        raise RuntimeError("This pinned kernel recipe targets Apple Silicon macOS")
    for name in ["RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_TARGET_WASM32_WASIP1_RUSTFLAGS"]:
        if name in os.environ:
            raise RuntimeError(f"Unset {name}; it overrides the pinned guest linker contract")
    work = args.work.resolve()
    if work.exists() and any(work.iterdir()):
        raise RuntimeError(f"Use a fresh build directory; existing artifacts are preserved: {work}")
    work.mkdir(parents=True, exist_ok=True)
    (work / "Runtime.lock.json").write_bytes(lock_bytes)
    os.environ["RUSTUP_AUTO_INSTALL"] = "0"
    # Fail before downloads if the explicitly pinned Rust target/tools are absent.
    toolchain = lock["rustToolchain"]
    run(["rustc", "+" + toolchain, "--version"])
    targets = subprocess.check_output(["rustup", "target", "list", "--installed", "--toolchain", toolchain], text=True)
    if "wasm32-wasip1" not in targets.splitlines():
        raise RuntimeError(f"Install explicit target first: rustup target add --toolchain {toolchain} wasm32-wasip1")
    for tool in ["git", "cmake", "make"]:
        if not shutil.which(tool):
            raise RuntimeError("Missing required build tool: " + tool)
    downloads = work / "downloads"
    downloads.mkdir()
    sdk_archive = obtain(pin["sdk"], downloads)
    sdk_root = work / "toolchain"
    sdk_root.mkdir()
    with tarfile.open(sdk_archive) as archive:
        archive.extractall(sdk_root, filter="data")
    sdk = sdk_root / pin["sdk"]["name"].removesuffix(".tar.gz")
    run([sdk / "bin/clang", "--version"])
    config_sub = obtain(pin["configSub"], downloads)
    upstream = work / "upstream"
    run(["git", "init", upstream])
    run(["git", "-C", upstream, "remote", "add", "origin", engine["url"]])
    run(["git", "-C", upstream, "fetch", "--depth=1", "origin", engine["revision"]])
    run(["git", "-C", upstream, "checkout", "--detach", "FETCH_HEAD"])
    revision = subprocess.check_output(["git", "-C", upstream, "rev-parse", "HEAD"], text=True).strip()
    if revision != engine["revision"]:
        raise RuntimeError("Upstream revision differs")
    run(["git", "-C", upstream, "submodule", "update", "--init", "--depth=1", "crates/bridge_harfbuzz/harfbuzz"])
    harfbuzz = subprocess.check_output(["git", "-C", upstream / "crates/bridge_harfbuzz/harfbuzz", "rev-parse", "HEAD"], text=True).strip()
    if harfbuzz != pin["harfbuzzRevision"]:
        raise RuntimeError("HarfBuzz revision differs")
    patch = work / "tectonic.patch"
    patch.write_bytes((SOURCE / engine["patch"]).read_bytes())
    run(["git", "-C", upstream, "apply", "--check", patch])
    run(["git", "-C", upstream, "apply", patch])
    fontmap_regression = test_fontmap(upstream, work)
    dependency_sources = upstream / "wasi-deps/src"
    dependency_sources.mkdir(parents=True)
    for artifact in pin["dependencies"]:
        shutil.copyfile(obtain(artifact, downloads), dependency_sources / artifact["name"])
        verify(dependency_sources / artifact["name"], artifact)
    env = dict(os.environ, WASI_SDK_PATH=str(sdk), TECTONIC_CONFIG_SUB=str(config_sub),
               RUSTUP_TOOLCHAIN=toolchain, CARGO_HOME=str(work / "cargo-home"),
               CARGO_TARGET_DIR=str(upstream / "target"))
    for script, log in [("wasi-deps/build-wasi-deps.sh", "dependencies.log"), ("build-wasi.sh", "kernel.log")]:
        with (work / log).open("w") as output:
            run(["bash", upstream / script], cwd=upstream, env=env, stdout=output, stderr=subprocess.STDOUT)
    kernel = upstream / "target/wasm32-wasip1/release/tectonic_wasi.wasm"
    shutil.copyfile(kernel, work / "tectonic.wasm")
    packed = work / "tectonic.wasm.gz"
    packed.write_bytes(gzip.compress(kernel.read_bytes(), compresslevel=9, mtime=0))
    if (SOURCE / "Runtime.lock.json").read_bytes() != lock_bytes or digest(SOURCE / engine["patch"]) != digest(patch):
        raise RuntimeError("Tracked kernel inputs changed during build; preserved output is not verified")
    receipt = {"format": 1, "upstreamRevision": revision, "patchSHA256": digest(patch),
               "lockSHA256": digest(work / "Runtime.lock.json"), "cargoLockSHA256": digest(upstream / "Cargo.lock"),
               "rustToolchain": toolchain, "buildInputs": pin, "fontmapRegression": fontmap_regression,
               "kernel": {"bytes": kernel.stat().st_size, "sha256": digest(kernel), "packedSHA256": digest(packed)},
               "compiler": subprocess.check_output([sdk / "bin/clang", "--version"], text=True),
               "rustc": subprocess.check_output(["rustc", "+" + toolchain, "-vV"], text=True)}
    (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(work / "receipt.json")


if __name__ == "__main__":
    main()
