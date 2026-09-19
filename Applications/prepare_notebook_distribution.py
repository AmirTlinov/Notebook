"""Build-only pinned TeX distribution; no compiler or runtime process lives here."""
from pathlib import Path, PurePosixPath
import hashlib, shutil, tarfile, urllib.request, zipfile, zlib

def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def verify(path: Path, expected: dict) -> None:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"Missing regular TeX resource: {path}")
    if path.stat().st_size != expected["bytes"] or digest(path) != expected["sha256"]:
        raise RuntimeError(f"TeX resource does not match its source pin: {path}")


def obtain(artifact: dict, cache: Path) -> Path:
    path = cache / artifact["name"]
    if path.exists():
        verify(path, artifact)
        return path
    partial = path.with_name(path.name + ".downloading")
    print(f"Preparing pinned TeX input: {artifact['name']} ({artifact['bytes']} bytes)", flush=True)
    request = urllib.request.Request(artifact["url"], headers={"User-Agent": "Notebook-TeX-Resource-Builder/1"})
    try:
        with urllib.request.urlopen(request, timeout=60) as source, partial.open("wb") as output:
            shutil.copyfileobj(source, output, 1024 * 1024)
        verify(partial, artifact)
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)
    return path


def create_distribution(archive: Path, target: Path, pin: dict) -> dict:
    names: set[str] = set()
    source_bytes = 0
    forbidden = []
    bundle_digest = None
    # Fixed timestamps, mode, order and compression settings make the output
    # repeatable. A zlib change must explicitly update the checked output pin.
    with tarfile.open(archive, "r:") as source, zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as output:
        for member in source:
            name = member.name
            if not member.isfile() or PurePosixPath(name).name != name or name in (".", "..") or name in names:
                raise RuntimeError(f"Unexpected distribution member: {name}")
            # The official distribution contains package illustrations/PDFs.
            # It contains no user's documents, logs, auxiliaries or formats.
            if Path(name).suffix.lower() in (".fmt", ".aux", ".log"):
                forbidden.append(name)
            names.add(name)
            source_bytes += member.size
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry._compresslevel = 6
            with source.extractfile(member) as data:
                if name == "SHA256SUM":
                    contents = data.read()
                    bundle_digest = contents.decode("ascii").strip()
                    output.writestr(entry, contents)
                else:
                    with output.open(entry, "w") as destination:
                        shutil.copyfileobj(data, destination, 1024 * 1024)
    if forbidden or bundle_digest != pin["bundleDigest"] or len(names) != pin["fileCount"]:
        raise RuntimeError(f"Unexpected TeX inventory: forbidden={forbidden}, digest={bundle_digest}, count={len(names)}")
    return {"fileCount": len(names), "sourceBytes": source_bytes, "privateFormats": 0,
            "auxiliaries": 0, "logs": 0, "bundleDigest": bundle_digest, "zlib": zlib.ZLIB_VERSION}

