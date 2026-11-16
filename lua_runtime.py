from __future__ import annotations

import os
import sys

_DEPS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deps")
if os.path.isdir(_DEPS_PATH) and _DEPS_PATH not in sys.path:
    sys.path.insert(0, _DEPS_PATH)

import shutil

_HERE = os.path.dirname(os.path.abspath(__file__))
_NATIVE_LUAU = os.path.join(_HERE, "luau_secure_runner")

_LUA_CANDIDATES = [
    "lua", "lua5.3", "lua5.4", "lua5.2", "lua5.1", "luajit",
]

_KNOWN_PATHS = [
    "/nix/store/j6ascsn1lm31m7386iznbjjak3m41760-lua-5.3.6/bin/lua",
    "/usr/bin/lua", "/usr/local/bin/lua",
    "/usr/bin/lua5.3", "/usr/bin/lua5.4",
]


def _find_system_lua() -> str | None:
    if os.environ.get("FORCE_LUPA"):
        return None
    for path in _KNOWN_PATHS:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    for name in _LUA_CANDIDATES:
        found = shutil.which(name)
        if found:
            return found
    return None


def _lupa_ok() -> bool:
    try:
        import lupa
        return True
    except Exception:
        return False


def lua_command() -> list[str]:
    if os.environ.get("LUA_NATIVE_ACTIVE") == "1" and os.path.isfile(_NATIVE_LUAU) and os.access(_NATIVE_LUAU, os.X_OK):
        return [_NATIVE_LUAU]
    bin_path = _find_system_lua()
    if bin_path:
        return [bin_path]
    if _lupa_ok():
        runner = os.path.join(_HERE, "lua_runner.py")
        if os.path.isfile(runner):
            return [sys.executable, runner]
    return []


def lua_available() -> bool:
    return bool(lua_command())


def native_luau_available() -> bool:
    return os.path.isfile(_NATIVE_LUAU) and os.access(_NATIVE_LUAU, os.X_OK)

