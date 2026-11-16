"""Subprocess bridge for the trusted Lune/Luau sandbox host.

Only project engine files may be passed to Lune. The child receives a minimal
environment, and Lune runs the engine through lune_sandbox_runner.luau, which
exposes only the specific temporary input/output paths to engine code.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path

from lua_runner import _filter_output_lines
from source_guard import verify_engine_files


HERE = Path(__file__).resolve().parent
LUNE_BIN = HERE / ".tools" / "lune-0.10.5" / "lune"
LUNE_HOST = HERE / "lune_sandbox_runner.luau"
API_REGISTRY = HERE / "roblox_api_registry.luau"
ALLOWED_ENGINES = {HERE / "dumper.lua", HERE / "dumper2.lua", HERE / "bypass.lua", HERE / "Revea.lua"}
_child: subprocess.Popen[str] | None = None


def _terminate_child(_signum: int, _frame: object) -> None:
    global _child
    if _child and _child.poll() is None:
        try:
            os.killpg(_child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    raise SystemExit(124)


def _minimal_environment() -> dict[str, str]:
    root = "/tmp/lune-runner-home"
    os.makedirs(root, exist_ok=True)
    return {
        "HOME": root,
        "TMPDIR": root,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }


def main() -> int:
    global _child
    if len(sys.argv) < 4:
        print("lune_runner: expected ENGINE INPUT OUTPUT", file=sys.stderr)
        return 2

    engine = Path(sys.argv[1]).resolve()
    arguments = sys.argv[2:]
    if engine not in ALLOWED_ENGINES:
        print("lune_runner: engine not allowed", file=sys.stderr)
        return 2
    if not LUNE_BIN.is_file() or not os.access(LUNE_BIN, os.X_OK):
        print("lune_runner: Lune binary unavailable", file=sys.stderr)
        return 2
    if not LUNE_HOST.is_file():
        print("lune_runner: Lune host unavailable", file=sys.stderr)
        return 2
    try:
        verify_engine_files(str(engine), str(LUNE_HOST), str(API_REGISTRY))
    except RuntimeError:
        print("lune_runner: engine integrity unavailable", file=sys.stderr)
        return 2

    try:
        timeout_s = float(os.environ.get("LUNE_RUNNER_TIMEOUT", "45"))
    except ValueError:
        timeout_s = 45.0
    timeout_s = max(5.0, min(timeout_s, 300.0))

    command = [str(LUNE_BIN), "run", str(LUNE_HOST), "--", str(engine), *arguments]
    signal.signal(signal.SIGTERM, _terminate_child)
    signal.signal(signal.SIGINT, _terminate_child)
    return_code = 1
    stdout = ""
    stderr = ""
    try:
        _child = subprocess.Popen(
            command,
            cwd=str(HERE),
            env=_minimal_environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            stdout, stderr = _child.communicate(timeout=timeout_s)
            return_code = int(_child.returncode or 0)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(_child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                stdout, stderr = _child.communicate(timeout=2)
            except Exception:
                stdout, stderr = "", ""
            stderr = (stderr or "") + f"\n[DUMPER_FAILED] Timeout ({timeout_s:.0f}s)\n"
            return_code = 124
    except Exception as exc:
        print(f"lune_runner: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    finally:
        if _child and _child.poll() is None:
            try:
                os.killpg(_child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        _child = None

    out_lines = stdout.splitlines(keepends=True)
    err_lines = stderr.splitlines(keepends=True)
    _filter_output_lines(out_lines)
    _filter_output_lines(err_lines)
    sys.stdout.writelines(out_lines)
    sys.stderr.writelines(err_lines)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
