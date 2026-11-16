
from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
for _cand in [os.path.join(_HERE, "deps"), "/app/applet/deps", "/app/deps"]:
    if os.path.isdir(_cand) and _cand not in sys.path:
        sys.path.insert(0, _cand)

import traceback
from typing import Optional


_RUNTIME_PREFERENCE = (
    "lua53",
    "lua52",
    "lua54",
    "lua51",
    "luajit21",
    "luajit20",
)

import re as _re

_OUTPUT_DENY_PATTERNS = [
    # Filesystem paths
    _re.compile(r'/home/[^\s"\'`\):]+',             _re.I),
    _re.compile(r'/root/[^\s"\'`\):]+',             _re.I),
    _re.compile(r'/etc/[^\s"\'`\):]+',              _re.I),
    _re.compile(r'/nix/[^\s"\'`\):]+',              _re.I),
    _re.compile(r'/proc/[^\s"\'`\):]+',             _re.I),
    _re.compile(r'/sys/[^\s"\'`\):]+',              _re.I),
    _re.compile(r'/run/[^\s"\'`\):]+',              _re.I),
    _re.compile(r'/tmp/[^\s"\'`\):]*',              _re.I),
    _re.compile(r'/var/tmp/[^\s"\'`\):]*',          _re.I),
    _re.compile(r'runner/workspace',                _re.I),
    _re.compile(r'[A-Za-z]:\\Users\\[^\s"\'`\)]+',  _re.I),
    _re.compile(r'[A-Za-z]:\\Downloads\\',          _re.I),
    # Credentials / tokens
    _re.compile(r'(?:TOKEN|SECRET|PASSWORD|API_KEY|WEBHOOK|DISCORD_TOKEN)\s*=\s*\S+', _re.I),
    _re.compile(r'Nz[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'),
    _re.compile(r'discord(?:app)?\.com/api/webhooks/', _re.I),
    _re.compile(r'ghp_[A-Za-z0-9]{20,}'),
    _re.compile(r'gho_[A-Za-z0-9]{20,}'),
    _re.compile(r'ghs_[A-Za-z0-9]{20,}'),
    _re.compile(r'ghr_[A-Za-z0-9]{20,}'),
    _re.compile(r'github_pat_[A-Za-z0-9_]{20,}',   _re.I),
    _re.compile(r'sk-[A-Za-z0-9]{20,}'),
    _re.compile(r'BEGIN\s+(?:RSA\s+)?(?:OPENSSH\s+)?PRIVATE\s+KEY', _re.I),
    _re.compile(r'\.ssh/',                           _re.I),
    _re.compile(r'id_rsa|id_ed25519|authorized_keys', _re.I),
    # dumper.lua unique internal identifiers
    _re.compile(r'\bproxyTable\b'),
    _re.compile(r'\b_CFunctionSet\b'),
    _re.compile(r'\bioLibrary\b'),
    _re.compile(r'\bosLibrary\b'),
    _re.compile(r'\berrorFunction\b'),
    _re.compile(r'\btypeFunction\b'),
    _re.compile(r'\bgetMetatableFunction\b'),
    _re.compile(r'\brawEqualFunction\b'),
    _re.compile(r'\btoStringFunction\b'),
    _re.compile(r'\btoNumberFunction\b'),
    _re.compile(r'\btableUnpackFunction\b'),
    _re.compile(r'\bdumperState\b'),
    _re.compile(r'\bMAX_DEPTH\b'),
    _re.compile(r'\bMIN_DEOBF_LENGTH\b'),
    _re.compile(r'\[Dumper\]'),
    # bypass.lua unique internal identifiers
    _re.compile(r'\b_HOOKOP\b'),
    _re.compile(r'__DUMPER_REAL_IO_OPEN'),
    _re.compile(r'__BYPASS_VERBOSE'),
    _re.compile(r'\b_bypassOnReset\b'),
    _re.compile(r'\b_native_debug\b'),
    _re.compile(r'\b_installAntiTamperWrappers\b'),
    _re.compile(r'\b_restricted_open\b'),
    _re.compile(r'flamedumper',                      _re.I),
    _re.compile(r'_PHYS_IO_OPEN'),
    # Lua bytecode (string.dump output) — magic header bytes
    _re.compile(r'\x1bLua'),
    _re.compile(r'string\.dump',                     _re.I),
    # Internal script filenames
    _re.compile(r'dumper\.lua',                      _re.I),
    _re.compile(r'bypass\.lua',                      _re.I),
    _re.compile(r'[Rr]evea\.lua'),
    _re.compile(r'lua_runner\.py',                   _re.I),
    _re.compile(r'\bbot\.py\b',                      _re.I),
    _re.compile(r'deobfuscator\.py',                 _re.I),
    # Byte-encoding exfiltration — attacker encodes content as decimal
    # byte values (e.g. "98,121,112,97,115,115,46,108,117,97" = "bypass.lua")
    # to bypass string pattern matching. Detect sequences of 8+ comma-
    # separated numbers which is a strong signal of encoded exfiltration.
    _re.compile(r'(?:\b\d{1,3}\b,){8,}\d{1,3}\b'),
]

_MAX_OUTPUT_LINE_LEN = 8000


def _filter_output_lines(lines: list) -> None:
    i = 0
    while i < len(lines):
        line = lines[i]
        if not isinstance(line, str):
            i += 1
            continue
        if len(line) > _MAX_OUTPUT_LINE_LEN:
            lines[i] = "[OUTPUT_REDACTED: line too long]\n"
            i += 1
            continue
        blocked = any(p.search(line) for p in _OUTPUT_DENY_PATTERNS)
        if blocked:
            lines[i] = "[OUTPUT_REDACTED: sensitive content]\n"
        i += 1


def _load_runtime():
    try:
        import lupa
    except ImportError as ie:
        raise RuntimeError(f"lupa library not installed or not in sys.path: {ie}")

    # 1. Primary entry point: lupa.LuaRuntime
    if hasattr(lupa, "LuaRuntime"):
        try:
            rt_test = lupa.LuaRuntime(unpack_returned_tuples=True)
            lua_impl = getattr(rt_test, "lua_implementation", "") or "default"
            return lupa.LuaRuntime, f"default ({lua_impl})"
        except Exception:
            pass

    # 2. Submodule entry points
    last_err = None
    for name in _RUNTIME_PREFERENCE:
        try:
            if hasattr(lupa, name):
                sub = getattr(lupa, name)
                if hasattr(sub, "LuaRuntime"):
                    rt_test = sub.LuaRuntime(unpack_returned_tuples=True)
                    return sub.LuaRuntime, name
            mod = __import__("lupa." + name, fromlist=["LuaRuntime"])
            if hasattr(mod, "LuaRuntime"):
                rt_test = mod.LuaRuntime(unpack_returned_tuples=True)
                return mod.LuaRuntime, name
        except Exception as e:
            last_err = e
            continue

    raise RuntimeError(
        f"No usable Lua runtime found in lupa (last error: {last_err!r})"
    )


def _make_runtime():
    LuaRuntime, label = _load_runtime()
    rt = LuaRuntime(unpack_returned_tuples=True)
    return rt, label


def get_runtime_label() -> str:
    try:
        import lupa as _lupa
        lupa_ver = getattr(_lupa, "__version__", "?")
        rt, label = _make_runtime()
        lua_impl = getattr(rt, "lua_implementation", "")
        return f"lupa {lupa_ver} / {lua_impl} ({label})"
    except Exception as e:
        return f"lupa (unavailable: {e})"


def _install_collecting_io_bridge(rt, out_lines: list, err_lines: list) -> None:
    g = rt.globals()

    def _col_write_out(text):
        if text is not None:
            out_lines.append(str(text))

    def _col_write_err(text):
        if text is not None:
            err_lines.append(str(text))

    def _col_println(text):
        out_lines.append(("" if text is None else str(text)) + "\n")

    g["__py_write_raw"]     = _col_write_out
    g["__py_write_raw_err"] = _col_write_err
    g["__py_println_raw"]   = _col_println

    rt.execute(
        r"""
        local _w_out  = __py_write_raw
        local _w_err  = __py_write_raw_err
        local _println = __py_println_raw

        -- Remove Python bridge globals from _G immediately after capturing
        -- them into locals. This prevents user code from discovering and
        -- calling them directly (e.g. __py_write_raw("bypass.lua") to bypass
        -- the content filter, or via load("return __py_write_raw","t",env)).
        rawset(_G, "__py_write_raw",     nil)
        rawset(_G, "__py_write_raw_err", nil)
        rawset(_G, "__py_println_raw",   nil)

        local function join_args(sep, ...)
            local n = select("#", ...)
            local parts = {}
            for i = 1, n do
                local v = select(i, ...)
                parts[i] = (v == nil) and "nil" or tostring(v)
            end
            return table.concat(parts, sep)
        end

        print = function(...)
            _println(join_args("\t", ...))
        end

        if io then
            io.write = function(...)
                _w_out(join_args("", ...))
                return io
            end

            local function make_writer(writer_fn)
                local f = {}
                function f:write(...)
                    writer_fn(join_args("", ...))
                    return self
                end
                function f:close()  return true end
                function f:flush()  return self end
                function f:setvbuf() return self end
                function f:lines() return function() return nil end end
                function f:read()  return nil end
                function f:seek()  return 0 end
                return f
            end
            io.stderr = make_writer(_w_err)
            io.stdout = make_writer(_w_out)
        end
        """
    )


def run_script_collecting(
    script_path: str,
    script_args: list,
    out_lines: list,
    err_lines: list,
) -> int:
    if not os.path.exists(script_path):
        err_lines.append(f"lua_runner: script not found: {script_path}\n")
        return 2

    script_dir = os.path.dirname(os.path.abspath(script_path)) or "."

    rt, _version = _make_runtime()
    _install_security_sandbox(rt)
    _install_collecting_io_bridge(rt, out_lines, err_lines)
    _install_arg_table(rt, script_path, list(script_args))
    _resolve_dofile_paths(rt, script_dir)

    with open(script_path, "r", encoding="utf-8", errors="replace") as f:
        source = f.read()
    if source.startswith("\ufeff"):
        source = source[1:]

    try:
        rt.execute(source, name="@" + script_path)
        rc = 0
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 0
    except BaseException as e:
        err_lines.append(f"lua: {e}\n")
        if os.environ.get("LUA_RUNNER_DEBUG"):
            err_lines.append(traceback.format_exc())
        rc = 1

    _filter_output_lines(out_lines)
    _filter_output_lines(err_lines)
    return rc


def _install_security_sandbox(rt) -> None:
    def _py_os_exit(code=0):
        raise SystemExit(int(code) if code is not None else 0)

    g = rt.globals()
    g["__py_os_exit"] = _py_os_exit




    import os as _pyos
    g["__BYPASS_VERBOSE"]    = "1" if _pyos.environ.get("BYPASS_VERBOSE")    == "1" else "0"
    g["__BYPASS_ALLOW_NET"]  = "1" if _pyos.environ.get("BYPASS_ALLOW_NET")  == "1" else "0"
    g["__LR_INNER_PATH"]     = _pyos.environ.get("__LR_INNER",  "inner_luraph_v1.lua")
    g["__LR_TRACE_PATH"]     = _pyos.environ.get("__LR_TRACE",  "luraph_v92_trace.txt")

    rt.execute(
        r"""
        do
            local function _blocked(name)
                return function(...)
                    error(name .. ": not available", 0)
                end
            end

            -- Block dangerous OS functions.
            if os then
                -- Capture __py_os_exit into a local closure so the global
                -- can be immediately removed from _G (prevents attacker from
                -- accessing it via _G["__py_os_exit"] or load+custom-env).
                local _py_exit_fn = __py_os_exit
                rawset(_G, "__py_os_exit", nil)

                os.execute  = _blocked("os.execute")
                os.exit     = function(c) _py_exit_fn(c or 0) end
                os.remove   = _blocked("os.remove")
                os.rename   = _blocked("os.rename")
                os.tmpname  = _blocked("os.tmpname")

                -- Replace os.getenv with a safe wrapper.
                -- The scripts (dumper/bypass) need a small set of config vars
                -- that Python already pre-injected as Lua globals above.
                -- Capture them into a local table NOW (before the globals are
                -- hidden by the rawget hardening below), then serve them back
                -- for those specific keys only.  All other keys return nil
                -- silently — no error — so callers that check the return value
                -- work correctly without leaking real environment variables.
                local _SAFE_ENV = {
                    BYPASS_VERBOSE   = __BYPASS_VERBOSE,
                    BYPASS_ALLOW_NET = __BYPASS_ALLOW_NET,
                    __LR_INNER       = __LR_INNER_PATH,
                    __LR_TRACE       = __LR_TRACE_PATH,
                }
                os.getenv = function(key)
                    if type(key) == "string" then
                        return _SAFE_ENV[key]
                    end
                    return nil
                end
            end

            -- Safe IO proxy.
            -- Keep ordinary file IO available for user scripts and for the
            -- dumper's temporary input/output files. The previous policy
            -- rejected broad filesystem classes and every non-temporary Lua or
            -- Python file, which caused false positives for legitimate IO.
            --
            -- The proxy protects only the sensitive engine names and prevents a
            -- payload from replacing io.open/io.lines with an escape function.
            if io then
                local _real_io      = io
                local _real_rawget  = rawget
                local _real_rawset  = rawset
                local _io_overrides = {}
                local _locked_keys = {
                    open=true, lines=true, popen=true, tmpfile=true,
                    input=true, output=true,
                }
                local _protected_names = {
                    ["bypass.lua"] = true,
                    ["dumper.lua"] = true,
                    ["dumper2.lua"] = true,
                    ["lua_runner.py"] = true,
                    ["bot.py"] = true,
                    ["main.py"] = true,
                    ["keep_alive.py"] = true,
                    ["deobfuscator.py"] = true,
                    [".env"] = true,
                    [".engine_integrity.json"] = true,
                }

                local function _is_protected_path(path)
                    if type(path) ~= "string" then return false end
                    local p = path:gsub("\\\\", "/"):lower()
                    local base = p:match("([^/]+)$") or p
                    return _protected_names[base] == true
                end

                local _real_io_open  = _real_io.open
                local _real_io_lines = _real_io.lines
                local function _safe_open(path, mode, ...)
                    if _is_protected_path(path) then
                        error("io.open: permission denied", 0)
                    end
                    return _real_io_open(path, mode, ...)
                end
                local function _safe_lines(path, ...)
                    if path == nil or _is_protected_path(path) then
                        error("io.lines: permission denied", 0)
                    end
                    return _real_io_lines(path, ...)
                end

                _io_overrides.open    = _safe_open
                _io_overrides.lines   = _safe_lines
                _io_overrides.popen   = _blocked("io.popen")
                _io_overrides.tmpfile = _blocked("io.tmpfile")
                _io_overrides.input   = _blocked("io.input")
                _io_overrides.output  = _blocked("io.output")

                local _io_proxy = setmetatable({}, {
                    __index = function(_, key)
                        return _io_overrides[key] or _real_io[key]
                    end,
                    __newindex = function(_, key, value)
                        -- The output bridge may replace these three members.
                        if key == "write" or key == "stdout" or key == "stderr" then
                            _io_overrides[key] = value
                            return
                        end
                        if _locked_keys[key] then
                            error("io: protected member", 0)
                        end
                        _io_overrides[key] = value
                    end,
                    __metatable = "locked: io is protected",
                })

                rawget = function(t, key)
                    if t == _io_proxy then
                        return _io_overrides[key] or _real_io[key]
                    end
                    return _real_rawget(t, key)
                end
                rawset = function(t, key, value)
                    if t == _io_proxy and _locked_keys[key] then
                        error("io: protected member", 0)
                    end
                    return _real_rawset(t, key, value)
                end
                _real_rawset(_G, "io", _io_proxy)
            end

            -- Block dynamic library loading and dangerous require targets.
            if package then
                package.loadlib    = nil
                package.searchpath = nil
                -- Wipe filesystem paths so attackers cannot enumerate
                -- the real module search directories.
                package.path  = ""
                package.cpath = ""
                local _real_require = require
                if _real_require then
                    local _BLOCKED_REQUIRES = {
                        -- Network / FFI modules
                        socket=true, luasocket=true, http=true, ffi=true,
                        posix=true, lfs=true, curl=true, copas=true,
                        ssl=true, crypt=true, lanes=true,
                        -- Internal bot source files — require("bypass") would
                        -- loadfile("bypass.lua") via package.path, bypassing
                        -- our io.open wrapper entirely.
                        bypass=true, dumper=true,
                        lua_runner=true, bot=true, main=true,
                        deobfuscator=true, flamedumper=true,
                    }
                    require = function(name, ...)
                        local n = tostring(name or "")
                        -- Block path traversal: .., /, \ are never valid
                        -- in a plain module name and indicate an escape attempt.
                        if n:find("%.%.", 1, true) or
                           n:find("/",   1, true) or
                           n:find("\\",  1, true) then
                            error("require: invalid module name", 0)
                        end
                        -- Block by first component (catches "bypass.sub", etc.)
                        local base = n:match("^([^.]+)") or ""
                        if _BLOCKED_REQUIRES[base] or _BLOCKED_REQUIRES[n] then
                            error("require: module not available", 0)
                        end
                        return _real_require(name, ...)
                    end
                end
            end

            -- Block environment inspection / manipulation
            getfenv = nil
            setfenv = nil

            -- Block dangerous debug sub-functions.
            -- debug.getinfo / sethook / traceback are NOT fully blocked here
            -- because dumper.lua captures them at startup for legitimate use.
            -- However, debug.getinfo is WRAPPED to remove source path fields
            -- so it cannot be used for Universal Reader stack-walk attacks.
            if debug then
                -- Save real getupvalue/setupvalue before blocking so
                -- bypass.lua's setfenv/getfenv shim can use them.
                rawset(_G, "__bypass_gup", debug.getupvalue)
                rawset(_G, "__bypass_sup", debug.setupvalue)
                debug.getlocal    = _blocked("debug.getlocal")
                debug.setlocal    = _blocked("debug.setlocal")
                debug.getregistry = _blocked("debug.getregistry")
                debug.getupvalue  = _blocked("debug.getupvalue")
                debug.setupvalue  = _blocked("debug.setupvalue")
                debug.upvalueid   = _blocked("debug.upvalueid")
                debug.upvaluejoin = _blocked("debug.upvaluejoin")

                -- Wrap getinfo: strip source/short_src so no file path leaks.
                if type(debug.getinfo) == "function" then
                    local _real_getinfo = debug.getinfo
                    debug.getinfo = function(f, what, ...)
                        local ok, info = pcall(_real_getinfo, f, what, ...)
                        if not ok or type(info) ~= "table" then return info end
                        if info.source then
                            local src = tostring(info.source)
                            if src:sub(1,1) == "@"
                            or src == "<python>"
                            or src:find("<python>", 1, true)
                            or src:find("/tmp/",    1, true)
                            or src:find("/nix/",    1, true)
                            or src:find("runner/workspace", 1, true) then
                                info.source    = "[INTERNAL]"
                                info.short_src = "[INTERNAL]"
                                info.linedefined     = 0
                                info.lastlinedefined = 0
                                info.currentline     = -1
                            end
                        end
                        return info
                    end
                end
            end

            -- Block string.dump — converts Lua functions to bytecode.
            -- The bytecode embeds all string constants (variable names,
            -- file paths, internal identifiers) in plaintext, making it
            -- a direct content-leak vector.
            -- IMPORTANT: do NOT store the real dump in _G — that would
            -- create an escape hatch (rawget(_G,"__DUMPER_STRING_DUMP")).
            if string and type(string.dump) == "function" then
                string.dump = function(...)
                    error("string.dump: not available", 0)
                end
            end

            -- io.tmpfile is already disabled by the protected IO proxy.
            -- Do not assign it again here: the proxy intentionally rejects
            -- writes to security-critical IO members.

            -- Harden rawget / rawset so they cannot be used to escape the sandbox
            -- by pulling the real os/io/debug tables out of _G, or accessing
            -- Python-injected internal globals like __py_os_exit.
            local _BLOCKED_RAWGET_KEYS = {
                os=true, io=true, debug=true, package=true,
                -- Python-bridge functions injected by lua_runner.py
                __py_os_exit=true,
                __py_write_raw=true, __py_write_raw_err=true, __py_println_raw=true,
                -- Internal config globals
                __BYPASS_VERBOSE=true, __BYPASS_ALLOW_NET=true,
                __LR_INNER_PATH=true, __LR_TRACE_PATH=true,
                __lr_script=true, __lr_argv_json=true,
                -- Escape hatches
                __DUMPER_REAL_IO_OPEN=true, __DUMPER_STRING_DUMP=true,
                -- Saved real debug functions (consumed & cleared by bypass.lua)
                __bypass_gup=true, __bypass_sup=true,
            }
            local _real_rawget = rawget
            rawget = function(t, k, ...)
                if t == _G and type(k) == "string" and _BLOCKED_RAWGET_KEYS[k] then
                    -- Return sandboxed global for io/os/debug/package,
                    -- nil for internal Python bridge functions.
                    if k == "os" or k == "io" or k == "debug" or k == "package" then
                        return _G[k]
                    end
                    return nil  -- hide all internal Python-injected globals
                end
                return _real_rawget(t, k, ...)
            end

            -- Override pairs() and next() to hide sensitive _G keys from
            -- enumeration (prevents discovery via "for k,v in pairs(_G)").
            local _HIDDEN_G_KEYS = _BLOCKED_RAWGET_KEYS  -- same set
            local _real_next  = next
            local _real_pairs = pairs
            next = function(t, k)
                local key, val = _real_next(t, k)
                if t == _G then
                    while key ~= nil and _HIDDEN_G_KEYS[key] do
                        key, val = _real_next(t, key)
                    end
                end
                return key, val
            end
            pairs = function(t)
                if t == _G then
                    return next, t, nil
                end
                return _real_pairs(t)
            end

            -- ── SEAL SYSTEM TABLES AGAINST METATABLE INJECTION ───────────
            -- setmetatable(io, {__index=spy}) lets attackers intercept ALL
            -- accesses to io.open/io.write/etc and capture function references.
            -- Setting __metatable=false on a table makes setmetatable() error
            -- with "cannot change a protected metatable" on future calls.
            local function _seal(t)
                if type(t) ~= "table" then return end
                local ok, cur = pcall(getmetatable, t)
                if ok and cur == nil then
                    setmetatable(t, {__metatable = false})
                elseif ok and type(cur) == "table" then
                    rawset(cur, "__metatable", false)
                end
            end
            -- `io` is a protected proxy; sealing the real C table here would
            -- block legitimate bridge updates and is no longer necessary.
            _seal(os)
            _seal(debug)
            _seal(string)
            _seal(table)
            _seal(math)
            _seal(package)

            -- ── SEAL _G AGAINST METATABLE SPY INJECTION ──────────────────
            -- setmetatable(_G, {__index=spy}) would intercept ALL global
            -- reads, letting an attacker silently capture function refs
            -- (e.g. io.open, debug.getinfo) that were wrapped by the sandbox.
            -- Sealing _G with __metatable=false prevents any future
            -- setmetatable(_G, ...) call from succeeding.
            -- We intentionally do NOT install __index/__newindex on _G because
            -- that would interfere with legitimate global lookups.
            do
                local _ok, _cur = pcall(getmetatable, _G)
                if _ok and _cur == nil then
                    pcall(setmetatable, _G, {__metatable = "locked: _G is sealed"})
                end
            end

            -- ── SANITIZE debug.traceback ──────────────────────────────────
            -- debug.traceback() calls the C-level lua_getinfo, bypassing our
            -- Lua-level debug.getinfo wrapper. It can expose real file paths
            -- in three places: (1) the error message prefix, (2) "function
            -- </path/>" notation, (3) ordinary stack frame lines.
            --
            -- BUG IN OLD APPROACH: gsub with "[^\n\t]*" is greedy — it
            -- swallows the entire line before "/tmp/" can match, then
            -- backtracking behaviour is unreliable across Lua minor versions.
            --
            -- NEW APPROACH: split by newline, redact any line that contains
            -- a suspicious string. This is O(n) and has no regex edge cases.
            if debug and type(debug.traceback) == "function" then
                debug.traceback = function(a, b)
                    local msg = type(a) == "thread" and b or a
                    local prefix = msg ~= nil and (tostring(msg) .. "\n") or ""
                    return prefix .. "stack traceback:\n\t[C]: in ?"
                end
            end
        end
        """
    )


def _install_io_bridge(rt) -> None:
    g = rt.globals()

    def _py_write_raw(text):
        sys.stdout.write("" if text is None else str(text))
        sys.stdout.flush()

    def _py_write_raw_err(text):
        sys.stderr.write("" if text is None else str(text))
        sys.stderr.flush()

    def _py_println_raw(text):
        sys.stdout.write("" if text is None else str(text))
        sys.stdout.write("\n")
        sys.stdout.flush()

    g["__py_write_raw"] = _py_write_raw
    g["__py_write_raw_err"] = _py_write_raw_err
    g["__py_println_raw"] = _py_println_raw

    rt.execute(
        r"""
        local _w_out = __py_write_raw
        local _w_err = __py_write_raw_err
        local _println = __py_println_raw

        local function join_args(sep, ...)
            local n = select("#", ...)
            local parts = {}
            for i = 1, n do
                local v = select(i, ...)
                parts[i] = (v == nil) and "nil" or tostring(v)
            end
            return table.concat(parts, sep)
        end

        print = function(...)
            _println(join_args("\t", ...))
        end

        if io then
            io.write = function(...)
                _w_out(join_args("", ...))
                return io
            end

            local function make_writer(writer_fn)
                local f = {}
                function f:write(...)
                    writer_fn(join_args("", ...))
                    return self
                end
                function f:close() return true end
                function f:flush() return self end
                function f:setvbuf() return self end
                function f:lines() return function() return nil end end
                function f:read() return nil end
                function f:seek() return 0 end
                return f
            end
            -- Replace io.stderr / io.stdout with Lua tables that route to our
            -- Python streams. Real file ops still work via io.open elsewhere.
            io.stderr = make_writer(_w_err)
            io.stdout = make_writer(_w_out)
        end
        """
    )


def _install_arg_table(rt, script_path: str, script_args: list[str]) -> None:
    g = rt.globals()
    g["__lr_script"] = script_path
    g["__lr_argv_json"] = "[" + ",".join(_lua_quote(a) for a in script_args) + "]"
    rt.execute(
        r"""
        local args = {}
        -- Tiny JSON-string-array parser (only handles strings, no escapes
        -- beyond \\, \", \n, \r, \t).
        local s = __lr_argv_json
        local i, n = 2, #s  -- skip leading '['
        while i <= n do
            local c = s:sub(i, i)
            if c == ']' then break end
            if c == ',' then i = i + 1
            elseif c == '"' then
                local j, buf = i + 1, {}
                while j <= n do
                    local cc = s:sub(j, j)
                    if cc == '\\' then
                        local nc = s:sub(j + 1, j + 1)
                        if nc == 'n' then buf[#buf+1] = '\n'
                        elseif nc == 'r' then buf[#buf+1] = '\r'
                        elseif nc == 't' then buf[#buf+1] = '\t'
                        else buf[#buf+1] = nc end
                        j = j + 2
                    elseif cc == '"' then
                        break
                    else
                        buf[#buf+1] = cc
                        j = j + 1
                    end
                end
                args[#args+1] = table.concat(buf)
                i = j + 1
            else
                i = i + 1
            end
        end
        arg = {}
        arg[0] = __lr_script
        for k = 1, #args do arg[k] = args[k] end
        arg.n = #args
        __lr_script = nil
        __lr_argv_json = nil
        """
    )


def _lua_quote(s: str) -> str:
    out = ['"']
    for ch in s:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\t':
            out.append('\\t')
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


_ALLOWED_LUA_FILES = frozenset({
    "bypass.lua", "dumper.lua", "dumper2.lua", "Revea.lua", "lune_sandbox_runner.luau", "roblox_api_registry.luau",
})

_HERE = os.path.dirname(os.path.abspath(__file__))


def _resolve_dofile_paths(rt, script_dir: str) -> None:
    g = rt.globals()
    real_dofile   = g["dofile"]
    real_loadfile = g["loadfile"]

    def _resolve_safe(path: str):
        if not isinstance(path, str):
            return None
        basename = os.path.basename(path)
        if basename not in _ALLOWED_LUA_FILES:
            return None
        candidate = os.path.join(script_dir, basename)
        if os.path.exists(candidate):
            return candidate
        candidate_here = os.path.join(_HERE, basename)
        if os.path.exists(candidate_here):
            return candidate_here
        return None

    def _py_dofile(path=None, *rest):
        if path is None:
            return real_dofile()
        resolved = _resolve_safe(path)
        if resolved is None:
            raise RuntimeError(
                f"dofile: access denied — '{path}' is not an allowed file"
            )
        return real_dofile(resolved, *rest)

    def _py_loadfile(path=None, *rest):
        if path is None:
            return real_loadfile()
        resolved = _resolve_safe(path)
        if resolved is None:
            return None, f"loadfile: access denied — '{path}' is not an allowed file"
        return real_loadfile(resolved, *rest)

    g["dofile"]   = _py_dofile
    g["loadfile"] = _py_loadfile


def run_script(script_path: str, script_args: list[str]) -> int:
    if not os.path.exists(script_path):
        sys.stderr.write(f"lua_runner: script not found: {script_path}\n")
        sys.stderr.flush()
        return 2

    script_dir = os.path.dirname(os.path.abspath(script_path)) or "."

    rt, version = _make_runtime()
    _install_security_sandbox(rt)
    _install_io_bridge(rt)
    _install_arg_table(rt, script_path, list(script_args))
    _resolve_dofile_paths(rt, script_dir)

    with open(script_path, "r", encoding="utf-8", errors="replace") as f:
        source = f.read()

    if source.startswith("\ufeff"):
        source = source[1:]

    try:
        rt.execute(source, name="@" + script_path)
        return 0
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 0
        return code
    except BaseException as e:
        msg = str(e)
        sys.stderr.write(f"lua: {msg}\n")
        if os.environ.get("LUA_RUNNER_DEBUG"):
            sys.stderr.write(traceback.format_exc())
        sys.stderr.flush()
        return 1


def run_inline(code: str, script_args: list[str]) -> int:
    rt, _ = _make_runtime()
    _install_security_sandbox(rt)
    _install_io_bridge(rt)
    _install_arg_table(rt, "=(command line)", list(script_args))
    _resolve_dofile_paths(rt, os.getcwd())
    try:
        rt.execute(code, name="=(command line)")
        return 0
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 0
    except BaseException as e:
        sys.stderr.write(f"lua: {e}\n")
        if os.environ.get("LUA_RUNNER_DEBUG"):
            sys.stderr.write(traceback.format_exc())
        sys.stderr.flush()
        return 1


def _print_help() -> None:
    sys.stderr.write(
        "usage: python lua_runner.py <script.lua> [arg1 arg2 ...]\n"
        "       python lua_runner.py -e <code> [arg1 arg2 ...]\n"
        "       python lua_runner.py --version\n"
    )


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        _print_help()
        return 64

    i = 1
    inline_chunks: list[str] = []
    script_path: Optional[str] = None
    while i < len(argv):
        token = argv[i]
        if token in ("-h", "--help"):
            _print_help()
            return 0
        if token in ("-v", "--version"):
            try:
                rt, label = _make_runtime()
                sys.stdout.write(f"lua_runner ({label}): {rt.lua_implementation}\n")
                return 0
            except Exception as e:
                sys.stderr.write(f"lua_runner: cannot init runtime: {e}\n")
                return 1
        if token == "-e":
            if i + 1 >= len(argv):
                sys.stderr.write("lua_runner: -e requires an argument\n")
                return 64
            inline_chunks.append(argv[i + 1])
            i += 2
            continue
        script_path = token
        script_args = argv[i + 1:]
        break
    else:
        script_args = []

    if inline_chunks and script_path is None:
        return run_inline("\n".join(inline_chunks), script_args)

    if script_path is None:
        _print_help()
        return 64

    if inline_chunks:
        rt, _ = _make_runtime()
        _install_security_sandbox(rt)
        _install_io_bridge(rt)
        _install_arg_table(rt, script_path, list(script_args))
        _resolve_dofile_paths(
            rt, os.path.dirname(os.path.abspath(script_path)) or "."
        )
        try:
            rt.execute("\n".join(inline_chunks), name="=(command line)")
            with open(script_path, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
            if src.startswith("\ufeff"):
                src = src[1:]
            rt.execute(src, name="@" + script_path)
            return 0
        except SystemExit as e:
            return e.code if isinstance(e.code, int) else 0
        except BaseException as e:
            sys.stderr.write(f"lua: {e}\n")
            if os.environ.get("LUA_RUNNER_DEBUG"):
                sys.stderr.write(traceback.format_exc())
            sys.stderr.flush()
            return 1

    return run_script(script_path, script_args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
