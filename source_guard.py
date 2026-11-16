from __future__ import annotations

import hashlib
import json
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
MANIFEST_PATH = BASE_DIR / ".engine_integrity.json"


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_engine_files(*paths: str | Path) -> None:
    if not MANIFEST_PATH.is_file():
        return
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Failed to read engine integrity manifest: {exc}") from exc

    expected_hashes = manifest.get("files")
    if not isinstance(expected_hashes, dict):
        raise RuntimeError("Invalid engine integrity manifest format.")

    for raw_path in paths:
        path = Path(raw_path)
        expected = expected_hashes.get(path.name)
        if not expected:
            continue
        if not path.is_file():
            raise RuntimeError(f"Missing engine file: {path.name}")
        actual = _sha256_file(path)
        if actual != expected:
            raise RuntimeError(
                f"Engine integrity mismatch for {path.name}: expected {expected}, got {actual}"
            )
