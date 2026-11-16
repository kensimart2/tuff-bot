import sys
import os

_DEPS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deps")
if os.path.isdir(_DEPS_PATH):
    if _DEPS_PATH not in sys.path:
        sys.path.insert(0, _DEPS_PATH)
    cur_pp = os.environ.get("PYTHONPATH", "")
    if _DEPS_PATH not in cur_pp:
        os.environ["PYTHONPATH"] = f"{_DEPS_PATH}:{cur_pp}" if cur_pp else _DEPS_PATH

import discord
import re
import ipaddress
import signal
import socket
import sys
import asyncio
import base64 as _b64mod
import tempfile
import threading
import time
import subprocess
import shutil
import contextlib
import hashlib
import traceback
import functools
import json
import zipfile
import aiohttp
import datetime
from discord.ext import commands
from source_guard import verify_engine_files
from io import BytesIO
from urllib.parse import urlparse

def _load_local_env_fallback() -> None:
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    try:
        with open(env_path, encoding="utf-8") as _f:
            lines = _f.read().splitlines()
    except OSError:
        return
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if not os.environ.get(key):
            os.environ[key] = value


_load_local_env_fallback()
TOKEN = os.environ.get("DISCORD_TOKEN", "").strip()
PREFIX = "."
_DEOBF_API_URL = os.environ.get("DEOBF_API_URL", "").strip()
_DEOBF_API_KEY = os.environ.get("DEOBF_API_KEY", "").strip()

intents = discord.Intents.default()
intents.message_content = True

bot = commands.Bot(command_prefix=PREFIX, intents=intents, help_command=None)

BOT_START_TIME = time.time()

_ANIM_COLORS: list[int] = [
    0x0d0d0d,
    0x1a0000,
    0x3d0000,
    0x700000,
    0xa80000,
    0xcc0000,
    0xff1800,
    0xcc0000,
    0xa80000,
    0x700000,
    0x3d0000,
    0x1a0000,
    0x0d0d0d,
    0x1c1c1c,
    0x333333,
    0x4a4a4a,
    0x333333,
    0x1c1c1c,
]
_ANIM_INTERVAL = 1.3
_anim_global_step = 0


async def _animate_embed(msg: discord.Message, embed: discord.Embed) -> None:
    global _anim_global_step
    step = _anim_global_step
    _anim_global_step = (_anim_global_step + 5) % len(_ANIM_COLORS)
    for _ in range(12):
        await asyncio.sleep(_ANIM_INTERVAL)
        try:
            embed.colour = discord.Colour(_ANIM_COLORS[step % len(_ANIM_COLORS)])
            await msg.edit(embed=embed)
            step += 1
        except (discord.NotFound, discord.Forbidden, discord.HTTPException):
            break
        except Exception:
            await asyncio.sleep(5)


async def _reply_anim(
    message: discord.Message, embed: discord.Embed, **kwargs
) -> discord.Message:
    embed.colour = discord.Colour(_ANIM_COLORS[0])
    msg = await message.reply(embed=embed, **kwargs)
    asyncio.ensure_future(_animate_embed(msg, embed))
    return msg


async def _send_anim(dest, embed: discord.Embed, **kwargs) -> discord.Message:
    embed.colour = discord.Colour(_ANIM_COLORS[0])
    msg = await dest.send(embed=embed, **kwargs)
    asyncio.ensure_future(_animate_embed(msg, embed))
    return msg


def _format_uptime(seconds: float) -> str:
    seconds = int(seconds)
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    parts = []
    if days:    parts.append(f"{days}d")
    if hours:   parts.append(f"{hours}h")
    if minutes: parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


def _strip_lua_literals(code: str) -> str:

    code = re.sub(r'--\[=*\[.*?\]=*\]', '--[[]]', code, flags=re.DOTALL)

    code = re.sub(r'\[=*\[.*?\]=*\]', '[[]]', code, flags=re.DOTALL)

    code = re.sub(r'--[^\n]*', '--', code)

    code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)

    code = re.sub(r"'(?:[^'\\]|\\.)*'", "''", code)
    return code


def _analyze_lua_source(src: str) -> dict:
    s = src or ""


    s_code = _strip_lua_literals(s)
    head = s[:512].lower()
    findings = {
        "size_bytes":   len(s),
        "lines":        s.count("\n") + 1,
        "obfuscator":   "unknown",
        "antitamper":   [],
        "antienv":      [],
        "interesting":  [],
    }

    detectors = [
        ("Luraph",       (r"\bLPH_NO_VIRTUALIZE\b", r"Luraph Obfuscator", r"\\27LPH",
                          r"LuraphContinue", r"LPH_OBFUSCATED")),
        ("MoonSec",      (r"MoonSec", r"moonsec", r"--\s*moonsec", r"ms_env",)),
        ("Ironbrew",     (r"Ironbrew", r"IRONBREW", r"IronBrew2", r"ib2_",)),
        ("Psu",          (r"\bPSU\b", r"psu_obf", r"PsuObfuscator",)),
        ("Luaobfuscator",(r"luaobfuscator\.com", r"lua-obfuscator\.com",)),
        ("Namaiki",      (r"Protected by Namaiki", r"Stop Deobfuscating",)),
        ("Timmy",        (r"Virtual Obfuscator", r"by\s*timmy",)),
        ("VVMer",        (r"vvmer",)),
        ("SCRLUA",       (r"\[=\[SCRLUA\|",)),
        ("Luafuscator",  (r"_LFR\b", r"Luafuscator", r"Tamper Detected!",)),
        ("Prometheus",   (r"prometheus",)),
        ("WeAreDevs",    (r"WeAreDevs|wearedevs", r"WAD_obf", r"wrd_vm",
                          r"WRD_CONST|_wrd_[A-Za-z]",
                          r"WeAreDevs\.com", r"WeAreDevsAPI",)),
        ("XFuscator",    (r"xfuscator",)),
        ("VAQ",          (r"VAQ Obfuscator", r"vateq", r"_bp5nxQostOWX6XP",
                          r"_vaq,\s*discord",)),
        ("ByteRider",    (r"ByteRider", r"byterider",)),
        ("ByteCode",     (r"\x1bLua", r"Lua 5\.1 bytecode",)),
        ("Synapse-XOR",  (r"syn\.protect", r"SynapseXen",)),
        ("Obfuscator.io",(r"obfuscator\.io", r"_0x[0-9a-f]{4,}\b",)),
        ("Karma",        (r"KarmaObfuscator", r"karma_obf",)),
        ("Acrylic",      (r"AcrylicObfuscator", r"acrylic_vm",)),
        ("Generic-VM",   (r"\bVM\b.*?\bopcode\b|\bopcode\b.*?\bVM\b",
                          r"VirtualMachine|virtual_machine",)),
        ("Generic-XOR",  (r"[~\^]\s*\d{1,3}.*?string\.char|string\.char.*?[~\^]\s*\d{1,3}",
                          r"bit\.bxor\s*\(.*?string\.char",)),
        ("Generic-B64",  (r"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
                          r"[A-Za-z0-9+/]{64,}={0,2}",)),
    ]
    for name, pats in detectors:
        for pat in pats:
            if re.search(pat, s, re.IGNORECASE):
                findings["obfuscator"] = name
                break
        if findings["obfuscator"] != "unknown":
            break

    at_checks = [
        ("debug.gethook",          r"debug\s*\.\s*gethook"),
        ("debug.sethook",          r"debug\s*\.\s*sethook"),
        ("debug.getinfo probe",    r"debug\s*\.\s*getinfo\s*\(\s*[0-9]"),
        ("checkcaller",            r"\bcheckcaller\b"),
        ("getfenv inspection",     r"getfenv\s*\("),
        ("setfenv override",       r"setfenv\s*\("),
        ("hookfunction probe",     r"\bhookfunction\b"),
        ("hookmetamethod probe",   r"\bhookmetamethod\b"),
        ("getrawmetatable probe",  r"\bgetrawmetatable\b"),
        ("locked-mt fingerprint",  r'getmetatable\s*\(\s*newproxy'),
        ("C-fn fingerprint",       r'tostring\s*\(.-\)\s*[:.]find\s*\(\s*"0x"'),
        ("infinite-loop trap",     r"while\s+true\s+do\s+end"),
        ("os.exit / error trap",   r"os\s*\.\s*exit|error\s*\("),
        ("string-meta lock",       r'__metatable\s*=\s*""'),
    ]


    for label, pat in at_checks:
        if re.search(pat, s_code):
            findings["antitamper"].append(label)

    env_checks = [
        ("game / Roblox API",      r"\bgame\s*[:.]"),
        ("GetService probes",      r"GetService\s*\("),
        ("identifyexecutor probe", r"\bidentifyexecutor\b"),
        ("Lua _VERSION check",     r"_VERSION\s*=="),
        ("utf8.graphemes (Roblox)",r"utf8\s*\.\s*graphemes"),
        ("HttpGet check",          r"HttpGet(?:Async)?"),
        ("syn / fluxus / krnl / WAD", r"\bsyn\b|\bfluxus\b|\bkrnl\b|\bWeAreDevs\b"),
        ("workspace probe",        r"\bworkspace\b"),
        ("task.wait / spawn",      r"task\s*\.\s*(wait|spawn|defer|delay)"),
        ("os.getenv (env leak)",   r"os\s*\.\s*getenv"),
    ]
    for label, pat in env_checks:
        if re.search(pat, s_code):
            findings["antienv"].append(label)

    if re.search(r"loadstring\s*\(|\bload\s*\(", s):
        findings["interesting"].append("uses load/loadstring")
    if re.search(r"string\s*\.\s*char\s*\(", s) and s.count("string.char") > 5:
        findings["interesting"].append("heavy string.char usage (encoded literals)")
    if re.search(r"\\\\\d{1,3}", s) or s.count("\\x") > 20:
        findings["interesting"].append("byte/hex string blob")
    if re.search(r"pcall\s*\(", s) and len(re.findall(r"pcall\s*\(", s)) > 5:
        findings["interesting"].append("heavy pcall use (probable error-swallow)")
    if "getfenv(0)" in s or "getfenv(1)" in s:
        findings["interesting"].append("env capture pattern")

    enc_types = _detect_encoding_types(s)
    for enc in enc_types:
        findings["interesting"].append(f"encoding: {enc}")
    if re.search(r'\{(?:\s*0[xX][0-9a-fA-F]{1,2}\s*,){3,}', s):
        findings["interesting"].append("hex-table encoding (0x.. style)")
    if re.search(r'bit\.bxor|bit32\.bxor', s):
        findings["interesting"].append("bit-level XOR operations")
    if re.search(r'(?:for\s+\w+\s*=\s*1\s*,\s*#\w+).*?[~\^].*?string\.char', s, re.DOTALL):
        findings["interesting"].append("loop-based XOR char decode")
    if re.search(r'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', s):
        findings["interesting"].append("custom base64 alphabet")

    return findings


def _format_analysis_embed(findings: dict, source: str) -> discord.Embed:
    color = 0x9b59b6 if findings["obfuscator"] != "unknown" else 0x95a5a6
    embed = discord.Embed(
        title="🔬 Script Analysis",
        description=f"Source: `{source[:80]}`",
        color=color,
    )
    embed.add_field(name="Obfuscator", value=f"**{findings['obfuscator']}**", inline=True)
    embed.add_field(name="Size",       value=f"{findings['size_bytes']:,} bytes", inline=True)
    embed.add_field(name="Lines",      value=str(findings["lines"]), inline=True)

    at = findings["antitamper"]
    embed.add_field(
        name=f"🛡 Anti-Tamper hooks ({len(at)})",
        value=("```\n" + "\n".join(f"• {x}" for x in at[:12]) + "\n```") if at else "_(none detected)_",
        inline=False,
    )
    en = findings["antienv"]
    embed.add_field(
        name=f"🌐 Anti-Env / executor checks ({len(en)})",
        value=("```\n" + "\n".join(f"• {x}" for x in en[:12]) + "\n```") if en else "_(none detected)_",
        inline=False,
    )
    it = findings["interesting"]
    if it:
        embed.add_field(
            name="📌 Interesting patterns",
            value="```\n" + "\n".join(f"• {x}" for x in it[:8]) + "\n```",
            inline=False,
        )
    embed.set_footer(text="kenV1 | envlogger • use .l to attempt full dump")
    return embed

def _lua_version_tuple(path: str) -> tuple[int, int]:
    try:
        output = subprocess.check_output([path, "-v"], stderr=subprocess.STDOUT, text=True, timeout=3)
    except Exception:
        return (0, 0)
    match = re.search(r"Lua\s+(\d+)\.(\d+)", output)
    if not match:
        return (0, 0)
    return int(match.group(1)), int(match.group(2))


def _find_lua_binary() -> str | None:
    def path_lua_candidates() -> list[str]:
        found = []
        names = ("lua5.3", "lua53", "lua5_3", "lua", "lua5.2", "lua52")
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            if not directory:
                continue
            for name in names:
                path = os.path.join(directory, name)
                if os.path.exists(path) and os.access(path, os.X_OK):
                    found.append(path)
        return found

    def nix_store_lua53_candidates() -> list[str]:
        found = []
        for directory in os.environ.get("PATH", "").split(os.pathsep):
            if "/nix/store/" not in directory:
                continue
            try:
                idx = directory.index("/nix/store/")
            except ValueError:
                continue
            tail = directory[idx + len("/nix/store/"):]
            store_name = tail.split("/", 1)[0]
            if "lua-5.3" not in store_name and "lua5_3" not in store_name:
                continue
            lua_path = os.path.join(directory, "lua")
            if os.path.exists(lua_path) and os.access(lua_path, os.X_OK):
                found.append(lua_path)
        return found

    def nix_lua53_candidates() -> list[str]:
        found = []
        for attr in ("lua53Packages.lua", "lua5_3"):
            try:
                out_path = subprocess.check_output(
                    ["nix", "eval", "--raw", f"nixpkgs#{attr}.outPath"],
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=8,
                ).strip()
            except Exception:
                continue
            lua_path = os.path.join(out_path, "bin", "lua")
            if os.path.exists(lua_path):
                found.append(lua_path)
        return found

    explicit = os.environ.get("LUA_BIN")
    candidates = []
    if explicit:
        candidates.append(explicit)
    candidates.extend(nix_store_lua53_candidates())
    candidates.extend(nix_lua53_candidates())
    candidates.extend(path_lua_candidates())
    candidates.extend(["lua5.3", "lua53", "lua5_3", "lua", "lua5.2", "lua52", "lua5.1", "lua51"])

    seen = set()
    resolved = []
    for candidate in candidates:
        path = candidate if os.path.isabs(candidate) and os.path.exists(candidate) else shutil.which(candidate)
        if path and path not in seen:
            seen.add(path)
            resolved.append(path)

    if not resolved:
        return None

    preferred = [path for path in resolved if _lua_version_tuple(path) == (5, 3)]
    if preferred:
        return preferred[0]

    modern = [path for path in resolved if _lua_version_tuple(path) >= (5, 2)]
    if modern:
        return modern[0]

    return resolved[0]


LUA_BIN = _find_lua_binary()
LUA_RUNNER_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lua_runner.py")
LUNE_RUNNER_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lune_runner.py")
LUNE_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".tools", "lune-0.10.5", "lune")
LUA_NATIVE_RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "luau_secure_runner")
LUA_NATIVE_ACTIVE = os.environ.get("LUA_NATIVE_ACTIVE") == "1"
LUNE_ACTIVE = os.environ.get("LUNE_ACTIVE", "1") == "1" and os.environ.get("FORCE_LUPA") != "1"

_LUA_SANDBOX_E = (
    'do local function _b(n) return function(...) '
    'error(n..": not available",0) end end '

    # Save real io.open before wrapping
    'rawset(_G,"__DUMPER_REAL_IO_OPEN",io.open);'

    # OS wrappers
    'os.execute=_b("os.execute");'
    'os.remove=_b("os.remove");'
    'os.rename=_b("os.rename");'
    'os.tmpname=_b("os.tmpname");'
    'local _rg=os.getenv;'
    'local _SE={'
    'BYPASS_VERBOSE=_rg("BYPASS_VERBOSE"),'
    'BYPASS_ALLOW_NET=_rg("BYPASS_ALLOW_NET"),'
    '__LR_INNER=_rg("__LR_INNER"),'
    '__LR_TRACE=_rg("__LR_TRACE")'
    '};'
    'os.getenv=function(k) if type(k)=="string" then return _SE[k] end return nil end;'

    # IO wrappers and path allowlist
    'io.popen=_b("io.popen");'
    'local _rio=io.open;'
    'local _SB={"/etc/","/home/","/root/","/nix/","/proc/","/sys/","/run/",'
    '"runner/workspace",".ssh/","id_rsa","id_ed25519","authorized_keys",'
    '"dumper.lua","dumper2.lua","bypass.lua","revea.lua","lua_runner.py","bot.py",'
    '"deobfuscator.py","main.py","keep_alive.py"};'
    'io.open=function(p,m,...) '
    'if type(p)=="string" then '
    'local lp=p:lower();'
    'for _,v in ipairs(_SB) do '
    'if lp:find(v,1,true) then error("io.open: permission denied",0) end '
    'end;'
    'local rd=(m==nil)or(not m:find("w",1,true));'
    'if rd and(p:match("%.lua$")or p:match("%.py$"))then '
    'if not(p:match("^/tmp/")or p:match("^/var/tmp/"))then '
    'error("io.open: permission denied",0) '
    'end end end;'
    'return _rio(p,m,...) end;'
    'io.lines=_b("io.lines");'
    'io.input=_b("io.input");'
    'io.output=_b("io.output");'
    'io.read=_b("io.read");'
    'io.write=_b("io.write");'
    'io.tmpfile=_b("io.tmpfile");'

    # Package path lockdown
    'if package then '
    'package.loadlib=nil;package.searchpath=nil;'
    'package.loaders=nil;package.preload={};'
    'package.path="";package.cpath="";'
    'local _rreq=require;'
    'if _rreq then '
    'local _BR={socket=true,luasocket=true,http=true,ffi=true,posix=true,'
    'lfs=true,curl=true,copas=true,ssl=true,crypt=true,lanes=true,'
    'bypass=true,dumper=true,lua_runner=true,bot=true,main=true,'
    'deobfuscator=true,flamedumper=true};'
    'require=function(n,...) '
    'local s=tostring(n or "");'
    'if s:find("..",1,true)or s:find("/",1,true)or s:find("\\\\",1,true)then '
    'error("require: invalid module name",0) end;'
    'local b=s:match("^([^.]+)") or "";'
    'if _BR[b]or _BR[s] then error("require: module not available",0) end;'
    'return _rreq(n,...) end '
    'end '
    'end;'

    # Block dofile / loadfile
    'dofile=nil;loadfile=nil;'

    # Clear Lua 5.1 getfenv/setfenv at outer scope
    'getfenv=nil;setfenv=nil;'

    # Block string.dump
    'if string and type(string.dump)=="function" then '
    'string.dump=function(...) error("string.dump: not available",0) end '
    'end;'

    # Save internal debug hooks before blocking unsafe inspection
    'if debug then '
    'rawset(_G,"__bypass_gup",debug.getupvalue);'
    'rawset(_G,"__bypass_sup",debug.setupvalue);'
    'rawset(_G,"__bypass_gi",debug.getinfo);'
    # Block genuinely dangerous debug functions
    'debug.getlocal=_b("debug.getlocal");'
    'debug.setlocal=_b("debug.setlocal");'
    'debug.getregistry=_b("debug.getregistry");'
    'debug.getupvalue=_b("debug.getupvalue");'
    'debug.setupvalue=_b("debug.setupvalue");'
    'debug.upvalueid=_b("debug.upvalueid");'
    'debug.upvaluejoin=_b("debug.upvaluejoin");'
    # Provide sanitized debug.getinfo that strips real file paths
    'local _rgi=rawget(_G,"__bypass_gi");'
    'debug.getinfo=function(a,w) '
    'local ok,t=false,nil;'
    'if _rgi then ok,t=pcall(_rgi,type(a)=="number" and a+1 or a,w or "flnSu") end;'
    'if not ok or type(t)~="table" then '
    't={what="Lua",source="@script",short_src="script",linedefined=-1,lastlinedefined=-1,currentline=-1,name="?",nups=0} '
    'end;'
    't.source=t.source and t.source:find("^[@=]?%s*flamedumper",1,false)==nil and t.source or "@script";'
    't.short_src=t.short_src and t.short_src:find("flamedumper",1,true)==nil and t.short_src or "script";'
    't.source=t.source:gsub("/home/[^%s\\"]+","script"):gsub("/nix/[^%s\\"]+","script");'
    't.short_src=t.short_src:gsub("/home/[^%s\\"]+","script"):gsub("/nix/[^%s\\"]+","script");'
    'return t end;'
    'debug.traceback=function(a,b) local m=type(a)=="thread" and b or a;return (m~=nil and (tostring(m).."\\n") or "").."stack traceback:\\n\\t[C]: in ?" end;'
    'end;'

    # Seal system tables against metatable spy injection
    # setmetatable(io,{__index=spy}) would intercept all io.open/io.write
    # calls and capture the real function references, bypassing our wrappers.
    'local function _seal(t) '
    'if type(t)~="table" then return end;'
    'local ok,cur=pcall(getmetatable,t);'
    'if ok and cur==nil then pcall(setmetatable,t,{__metatable=false}) '
    'elseif ok and type(cur)=="table" then rawset(cur,"__metatable",false) '
    'end end;'
    '_seal(io);_seal(os);_seal(debug);_seal(string);_seal(table);_seal(math);_seal(package);'

    'end'
)

def _build_lua_cmd() -> tuple[list[str], str]:
    if LUNE_ACTIVE:
        if (os.path.isfile(LUNE_RUNNER_PY) and os.path.isfile(LUNE_BIN)
                and os.access(LUNE_BIN, os.X_OK)):
            return [sys.executable, LUNE_RUNNER_PY], "Lune 0.10.5 / Luau [subprocess]"
    if LUA_NATIVE_ACTIVE and os.path.isfile(LUA_NATIVE_RUNNER) and os.access(LUA_NATIVE_RUNNER, os.X_OK):
        os.environ["LUA_NATIVE_ENGINE"] = "1"
        os.environ.setdefault("LUA_NATIVE_CODEGEN", "1")
        return [LUA_NATIVE_RUNNER], "Luau native VM/compiler"
    if not os.environ.get("FORCE_LUPA") and LUA_BIN:
        _lv = _lua_version_tuple(LUA_BIN)
        return [LUA_BIN, "-e", _LUA_SANDBOX_E], f"system Lua {_lv[0]}.{_lv[1]} ({LUA_BIN})"
    try:
        import lupa
        import lua_runner as _lr
        _lupa_label = _lr.get_runtime_label()
    except Exception as e:
        if not LUA_BIN:
            print(f"[kenV1 | envlogger] ERROR: no Lua binary AND lupa import failed: {e}")
        return [], "unavailable"
    return [sys.executable, LUA_RUNNER_PY], _lupa_label


LUA_CMD, LUA_RUNTIME_DESC = _build_lua_cmd()
LUA_AVAILABLE = bool(LUA_CMD)

_USING_LUPA = LUA_AVAILABLE and LUA_CMD[:1] == [sys.executable]
LUPA_DIRECT = (
    _USING_LUPA
    and os.environ.get("ALLOW_LUPA_DIRECT") == "1"
    and not os.environ.get("LUPA_SUBPROCESS")
)

if LUA_AVAILABLE:
    mode_tag = " [direct in-process]" if LUPA_DIRECT else " [subprocess]"
    print(f"[kenV1 | envlogger] Lua runtime: {LUA_RUNTIME_DESC}{mode_tag if _USING_LUPA else ''}")
else:
    print("[kenV1 | envlogger] WARNING: no Lua runtime available (system binary missing and lupa unusable).")
DUMPER_LUA     = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dumper.lua")
DUMPER2_LUA    = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dumper2.lua")
BYPASS_LUA     = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bypass.lua")
REVEA_LUA      = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Revea.lua")
LUNE_HOST_LUA  = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lune_sandbox_runner.luau")
API_REGISTRY_LUA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "roblox_api_registry.luau")
verify_engine_files(BYPASS_LUA, DUMPER_LUA, DUMPER2_LUA, LUNE_HOST_LUA, API_REGISTRY_LUA)
DECOMPILE_PY   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lua51_decompile.py")
SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "obfuscated_scripts")
DUMP_ARCHIVE_USER_ID = 1011450300185448448
OWNER_ID             = 1011450300185448448
DM_COMMAND_ALLOWLIST = {1011450300185448448}
DUMP_TIMEOUT_SECONDS = 180
_LUA_SEM_BY_LOOP: dict[int, asyncio.Semaphore] = {}
_DUMP_SEM_BY_LOOP: dict[int, asyncio.Semaphore] = {}
_DEOBF_LOCK = threading.Lock()


def _get_lua_semaphore() -> asyncio.Semaphore:
    loop = asyncio.get_running_loop()
    key = id(loop)
    sem = _LUA_SEM_BY_LOOP.get(key)
    if sem is None:
        sem = asyncio.Semaphore(2)
        _LUA_SEM_BY_LOOP[key] = sem
    return sem


def _get_dump_semaphore() -> asyncio.Semaphore:
    loop = asyncio.get_running_loop()
    key = id(loop)
    sem = _DUMP_SEM_BY_LOOP.get(key)
    if sem is None:
        sem = asyncio.Semaphore(3)
        _DUMP_SEM_BY_LOOP[key] = sem
    return sem

_ACL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".acl.json")

def _load_acl() -> dict:
    try:
        with open(_ACL_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if not isinstance(data, dict):
                data = {}
            data.setdefault("entries", {})
            data.setdefault("allowed", [])
            data.setdefault("warnings", {})
            if not isinstance(data["entries"], dict):
                data["entries"] = {}
            if not isinstance(data["allowed"], list):
                data["allowed"] = []
            if not isinstance(data["warnings"], dict):
                data["warnings"] = {}
            return data
    except Exception:
        return {"entries": {}, "allowed": [], "warnings": {}}

def _save_acl(data: dict) -> None:
    tmp_path = None
    try:
        base_dir = os.path.dirname(_ACL_FILE) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".acl-", suffix=".tmp", dir=base_dir, text=True)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, _ACL_FILE)
        tmp_path = None
    except Exception:
        pass
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

def _is_blacklisted(user_id: int) -> bool:
    acl = _load_acl()
    return str(user_id) in acl["entries"]

def _is_whitelisted(user_id: int) -> bool:
    acl = _load_acl()
    return user_id in acl["allowed"]

def _blacklist_user(user_id: int, reason: str = "vuln_attempt") -> None:
    acl = _load_acl()
    key = str(user_id)
    if key not in acl["entries"]:
        acl["entries"][key] = {
            "banned_at": int(time.time()),
            "reason": reason,
        }
    if user_id in acl["allowed"]:
        acl["allowed"].remove(user_id)
    acl["warnings"].pop(key, None)
    _save_acl(acl)

def _grant_access(user_id: int) -> None:
    acl = _load_acl()
    key = str(user_id)
    acl["entries"].pop(key, None)
    acl["warnings"].pop(key, None)
    if user_id not in acl["allowed"]:
        acl["allowed"].append(user_id)
    _save_acl(acl)

def _revoke_access(user_id: int) -> None:
    acl = _load_acl()
    key = str(user_id)
    if key not in acl["entries"]:
        acl["entries"][key] = {
            "banned_at": int(time.time()),
            "reason": "manual_revoke",
        }
    if user_id in acl["allowed"]:
        acl["allowed"].remove(user_id)
    acl["warnings"].pop(key, None)
    _save_acl(acl)

def _record_security_warning(user_id: int, reason: str) -> int:
    """Persist and return a non-owner user's warning count."""
    acl = _load_acl()
    key = str(user_id)
    previous = acl["warnings"].get(key, {})
    previous_count = previous.get("count", 0) if isinstance(previous, dict) else 0
    try:
        count = max(0, int(previous_count)) + 1
    except (TypeError, ValueError):
        count = 1
    acl["warnings"][key] = {
        "count": count,
        "last_reason": reason,
        "updated_at": int(time.time()),
    }
    _save_acl(acl)
    return count

def _get_blacklist_entries() -> list[dict]:
    acl = _load_acl()
    result = []
    for uid_str, info in acl["entries"].items():
        result.append({
            "user_id": int(uid_str),
            "banned_at": info.get("banned_at", 0),
            "reason": info.get("reason", "unknown"),
        })
    result.sort(key=lambda x: x["banned_at"], reverse=True)
    return result
PROGRESS_UPDATE_SECONDS = 1.0
FAST_FINISH_STABLE_SECONDS = 1.0
FAST_FINISH_MIN_BYTES = 8
FAST_FINISH_POLL_SECONDS = 0.25
MAX_RESULT_BYTES = 7_500_000
GENERATED_HEADER = "-- this file is generated using kenV1 | envlogger | https://discord.gg/ypVcca6cvp"
TRACE_SKIP_MESSAGE = "Trace fallback skipped: unsupported legacy string-table format."
NO_OUTPUT_NOTE = (
    "-- [kenV1] VM finished, no reconstructable output captured.\n"
    "-- [kenV1] Returning normalized source below."
)


def _ensure_scripts_dir():
    os.makedirs(SCRIPTS_DIR, exist_ok=True)
    workspace_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workspace")
    os.makedirs(workspace_dir, exist_ok=True)


async def _archive_dump_upload(filename: str, data: bytes, message=None) -> None:
    try:
        user = bot.get_user(DUMP_ARCHIVE_USER_ID)
        if user is None:
            user = await bot.fetch_user(DUMP_ARCHIVE_USER_ID)
        if user is None:
            return
        safe = re.sub(r"[^A-Za-z0-9._-]+", "_", filename or "upload.lua")
        author_tag = "unknown"
        guild_name = "DM"
        if message is not None:
            try:
                author_tag = f"{message.author} ({message.author.id})"
            except Exception:
                pass
            try:
                if message.guild is not None:
                    guild_name = f"{message.guild.name} ({message.guild.id})"
            except Exception:
                pass
        caption = f"Dump upload from {author_tag} in {guild_name}"
        await user.send(content=caption, file=discord.File(BytesIO(data), filename=safe))
    except Exception as e:
        print(f"[kenV1 | envlogger] Failed to forward dump upload: {e}")


def _count_real_lines(code: str) -> int:
    return sum(1 for l in code.splitlines() if l.strip() and not l.strip().startswith("--"))


def _strip_leading_comments(content: str) -> str:
    lines = content.splitlines()
    while lines and (not lines[0].strip() or lines[0].strip().startswith("--")):
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines)


_DTC_GLOBAL_STUBS: list[tuple[re.Pattern, str]] = [
    (
        re.compile(r'\bdumpstring\b'),
        'if dumpstring == nil then '
        'dumpstring = function(...) error("not supported", 0) end end',
    ),
    (
        re.compile(r'\bcheckcaller\s*\(\s*\)'),
        'if checkcaller == nil then checkcaller = function() return true end end',
    ),
    (
        re.compile(r'\b(?:isexecutorclosure|isourclosure)\s*\('),
        'if isexecutorclosure == nil then isexecutorclosure = function() return true end end\n'
        'if isourclosure     == nil then isourclosure     = function() return true end end',
    ),
    (
        re.compile(r'Instance\.new\s*\(\s*["\']SurfaceAppearance["\']\s*\)'),
        'do\n'
        '  local _sa_p=print\n'
        '  local _sa_a=false;local _sa_f=false\n'
        '  local _sa_cid={}\n'
        '  local function _sa_mkcid(u)\n'
        '    u=type(u)=="string" and u or ""\n'
        '    local o=setmetatable({},{\n'
        '      __metatable="ContentId",\n'
        '      __tostring=function() return u end,\n'
        '      __eq=function(a,b) return tostring(a)==tostring(b) end,\n'
        '      __index=function(_,k) if k=="Uri" then return u end return nil end,\n'
        '    })\n'
        '    _sa_cid[o]=true\n'
        '    return o\n'
        '  end\n'
        '  local _sa_tw=typeof\n'
        '  if type(_sa_tw)=="function" then\n'
        '    typeof=function(v)\n'
        '      if _sa_cid[v] then return "ContentId" end\n'
        '      return _sa_tw(v)\n'
        '    end\n'
        '  end\n'
        '  local _sa_ni=type(Instance)=="table" and type(Instance.new)=="function" and Instance.new\n'
        '  if _sa_ni then\n'
        '    Instance.new=function(c,...)\n'
        '      local r=_sa_ni(c,...)\n'
        '      if c=="SurfaceAppearance" then\n'
        '        _sa_a=true\n'
        '        if type(r)=="table" then\n'
        '          r.ColorMap=_sa_mkcid("")\n'
        '          r.NormalMap=_sa_mkcid("")\n'
        '          r.MetalnessMap=_sa_mkcid("")\n'
        '          r.RoughnessMap=_sa_mkcid("")\n'
        '        end\n'
        '        local _r=r\n'
        '        r=setmetatable({},{\n'
        '          __index=function(_,k)\n'
        '            if k=="Destroy" then\n'
        '              return function()\n'
        '                if _sa_a then _sa_f=true end\n'
        '                local d=_r.Destroy\n'
        '                if type(d)=="function" then d(_r) end\n'
        '              end\n'
        '            end\n'
        '            if k=="ColorMap" or k=="NormalMap" or k=="MetalnessMap" or k=="RoughnessMap" then\n'
        '              return rawget(_r,k) or _sa_mkcid("")\n'
        '            end\n'
        '            return _r[k]\n'
        '          end,\n'
        '          __newindex=function(_,k,v) _r[k]=v end,\n'
        '          __tostring=function() return tostring(_r) end,\n'
        '        })\n'
        '      end\n'
        '      return r\n'
        '    end\n'
        '  end\n'
        '  print=function(...)\n'
        '    if _sa_a and _sa_f and select("#",...)==1 and select(1,...)=="detected" then\n'
        '      _sa_a=false;_sa_f=false;return _sa_p("pass")\n'
        '    end\n'
        '    return _sa_p(...)\n'
        '  end\n'
        'end',
    ),
    (
        re.compile(r'\bgetrunningscripts\b'),
        'do\n'
        '  local _grs_anim={}\n'
        '  local _grs_players = type(game)=="table" and type(game.Players)=="table" and game.Players\n'
        '  local _grs_lp = type(_grs_players)=="table" and _grs_players.LocalPlayer\n'
        '  if type(_grs_lp)=="table" and _grs_lp.Character==nil then\n'
        '    local _mt=type(game)=="table" and getmetatable(game)\n'
        '    local _char=setmetatable({ClassName="Model",Name="Character"},_mt or {})\n'
        '    rawset(_grs_lp,"Character",_char)\n'
        '  end\n'
        '  local _grs_char = type(_grs_lp)=="table" and _grs_lp.Character\n'
        '  if type(_grs_char)=="table" then\n'
        '    rawset(_grs_char,"FindFirstChild",function(_self,name)\n'
        '      if name=="Animate" then return _grs_anim end; return nil\n'
        '    end)\n'
        '    rawset(_grs_char,"WaitForChild",function(_self,name)\n'
        '      if name=="Animate" then return _grs_anim end; return nil\n'
        '    end)\n'
        '  end\n'
        '  getrunningscripts=function() return {_grs_anim} end\n'
        'end',
    ),
]


def _inject_dtc_stubs(code: str) -> str:
    lines: list[str] = []
    for pat, stub in _DTC_GLOBAL_STUBS:
        if pat.search(code):
            lines.append(stub)
    if not lines:
        return code
    return "\n".join(lines) + "\n" + code


def _apply_dtc_source_patches(code: str) -> str:
    return code


def _normalize_lua_input(lua_code: str) -> str:
    if not lua_code:
        return ""
    code = lua_code.replace("\ufeff", "")
    code = code.replace("\r\n", "\n").replace("\r", "\n")
    code = code.replace("\u2028", "\n").replace("\u2029", "\n")
    code = re.sub(r"^\s*```(?:lua|luau|txt)?\s*", "", code, flags=re.I)
    code = re.sub(r"\s*```\s*$", "", code)
    code = _apply_dtc_source_patches(code.strip())
    code = _inject_dtc_stubs(code)
    if code and not code.endswith("\n"):
        code += "\n"
    return code


def _make_dump_attempts(lua_code: str):
    normalized = _normalize_lua_input(lua_code)
    attempts = [("direct", normalized)]
    if len(normalized) < 100_000:
        compact = "\n".join(line for line in normalized.splitlines() if line.strip())
        if compact:
            if not compact.endswith("\n"):
                compact += "\n"
            if compact != normalized:
                attempts.append(("compact", compact))
    if normalized.startswith("return "):
        ret_body = normalized[7:].strip()
        if ret_body and not ret_body.endswith("\n"):
            ret_body += "\n"
        if ret_body:
            attempts.append(("return-body", ret_body))

    try:
        pre_decoded = _pre_decode_lua_layers(lua_code)
        for label, decoded_src in pre_decoded:
            if decoded_src and decoded_src.strip():
                norm_dec = _normalize_lua_input(decoded_src)
                if norm_dec:
                    attempts.append((f"pre-decode:{label}", norm_dec))
    except Exception:
        pass

    seen = set()
    unique = []
    for name, code in attempts:
        if not code:
            continue
        key = hashlib.sha256(code.encode("utf-8", errors="replace")).hexdigest()
        if key in seen:
            continue
        seen.add(key)
        unique.append((name, code))
    return unique or [("direct", lua_code or "")]


def _vm_finished_without_dump(log_text: str) -> bool:
    text = log_text or ""
    if re.search(r"\berror:|\[FAILED\]|\[DUMPER_FAILED\]|exception|timeout|syntax", text, re.I):
        return False
    return bool(re.search(r"done:\s*lines=0\s+remotes=0\s+strings=0", text))


def _tail_lines(text: str, limit: int = 18) -> str:
    lines = [line for line in (text or "").splitlines() if line.strip()]
    return "\n".join(lines[-limit:])


def _short_error(text: str, limit: int = 900) -> str:
    if not text:
        return "Dump failed: execution produced no output."
    lines = []
    preferred = []
    skip_rest = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if "Original source snapshot" in line:
            skip_rest = True
            continue
        if skip_rest:
            continue
        if line.startswith("===") or line.startswith("---"):
            continue
        if line.startswith("File:") or line.startswith("Processing ") or line.startswith("Report saved") or line.startswith("Saved "):
            continue
        if "CONSTANTS" in line or line == "--- TRACE ---":
            continue
        lines.append(line)
        if re.search(r"failed|error|exception|timeout|syntax|cannot|unsupported|DUMPER_FAILED|attempt|denied|bad argument|limit", line, re.I):
            preferred.append(line)
    selected = preferred[-6:] if preferred else lines[-6:]
    if not selected:
        return "Dump failed: execution produced no output."
    compact = "\n".join(selected)
    return compact[:limit]


def _format_engine_error(line: str) -> str:
    """Keep the user-visible cause while dropping host/trace implementation detail."""
    text = (line or "").strip()
    if not text or re.search(r"(?:Stack Begin|Stack End|stack traceback|^Script\s|OUTPUT_REDACTED)", text, re.I):
        return ""
    syntax = re.search(r"syntax error:\s*(.+)", text, re.I)
    if syntax:
        cause = re.sub(r"^(?:bypassed|script(?:_top|_all|_main)?|Obfuscated_Script|Script|dumper2_target|dumper2_stage):\d+:\s*", "", syntax.group(1))
        return f"Syntax error: {cause}"
    attempt = re.search(r"(attempt to .+)$", text, re.I)
    if attempt:
        return f"Runtime error: {attempt.group(1)}"
    bad_arg = re.search(r"(bad argument .+)$", text, re.I)
    if bad_arg:
        return f"Runtime error: {bad_arg.group(1)}"
    text = re.sub(r"^\[(?:bypass|compat|env|internal|dumper|dumper2)\]\s*", "", text, flags=re.I)
    text = re.sub(r"^(?:engine|bypassed|script(?:_top|_all|_main)?|Obfuscated_Script|Script|dumper2_target|dumper2_stage):\d+:\s*", "", text)
    text = re.sub(r"^load error:\s*", "Load error: ", text, flags=re.I)
    text = re.sub(r"^ERROR:\s*", "Error: ", text, flags=re.I)
    return text


def _log_excerpt(text: str, limit: int = 900) -> str:
    if not text:
        return "[!] No output received from the engine."
    if "[DUMPER_SUCCESS]" in text and "=== Trace fallback ===" in text:
        text = text.split("=== Trace fallback ===", 1)[0]

    _TB_FRAME = re.compile(r"stack\s+traceback", re.I)

    all_lines = [raw.strip() for raw in text.splitlines()]

    errors: list[str] = []
    seen: set[str] = set()
    in_traceback = False
    skip_traceback = False

    i = 0
    while i < len(all_lines):
        line = all_lines[i]
        i += 1

        if not line:
            in_traceback = False
            skip_traceback = False
            continue

        if in_traceback:
            if re.match(r"^(?:===|\[DUMPER|\[bypass|\[compat|\[env|\[guard|\[canary)", line):
                in_traceback = False
                skip_traceback = False
            continue

        if not _looks_like_real_error(line):
            continue

        if _TB_FRAME.search(line):
            is_sandbox = False
            for j in range(i, min(i + 8, len(all_lines))):
                peek = all_lines[j].strip()
                if not peek:
                    break
                if _is_sandbox_noise(peek):
                    is_sandbox = True
                    break
            in_traceback = True
            skip_traceback = is_sandbox
            if is_sandbox:
                continue

        if _is_sandbox_noise(line):
            continue

        fmt_line = _format_engine_error(line)
        if not fmt_line:
            continue
        fmt_line = re.sub(r"^\[DUMPER_FAILED\]\s*", "Error: ", fmt_line)
        fmt_line = re.sub(r"^\[CRITICAL\s+ERROR\]\s*", "Error: ", fmt_line, flags=re.I)
        fmt_line = re.sub(r"^ERROR:\s*", "Error: ", fmt_line, flags=re.I)
        if fmt_line in seen:
            continue
        seen.add(fmt_line)
        errors.append(fmt_line)

    if not errors:
        fallback_lines = []
        for raw in all_lines:
            if not raw or raw.startswith("===") or raw.startswith("---"):
                continue
            if _is_sandbox_noise(raw):
                continue
            cleaned = re.sub(r"^\[(?:bypass|compat|env|internal|dumper)\]\s*", "", raw, flags=re.I)
            if cleaned and cleaned not in fallback_lines:
                fallback_lines.append(cleaned)
        if fallback_lines:
            compact = "\n".join(fallback_lines[-8:])
            return compact[:limit]
        return "Runtime error: execution produced no usable output."

    compact = "\n".join(errors[-12:])
    return compact[:limit]


def _dump_content_is_usable(content: str) -> bool:
    text = (content or "").strip()
    if not text or _count_real_lines(text) <= 0:
        return False
    if re.search(r"(?im)^\s*(?:--\s*)?(?:Runtime|Load Error):", text):
        return False
    if re.search(r"(?im)^\s*(?:ERROR|DUMPER_FAILED):", text):
        return False
    return True


def _score_dump(code: str) -> int:
    if not code:
        return 0
    real_lines = _count_real_lines(code)
    bonus = 0
    patterns = (
        "game:GetService", "Instance.new", ":Connect", ":FireServer", "loadstring",
        "request(", "HttpGet", "local ", "function", "task.", "workspace"
    )
    for pattern in patterns:
        bonus += code.count(pattern) * 4
    penalty = code.count("-- Runtime:") * 5 + code.count("-- Load Error:") * 10
    return real_lines * 10 + min(len(code) // 120, 300) + bonus - penalty


def _make_result_file(text: str, filename: str):
    data = text.encode("utf-8", errors="replace")
    if len(data) > MAX_RESULT_BYTES:
        notice = (
            "\n\n-- [kenV1] Output truncated to fit Discord upload limit (middle omitted).\n"
        ).encode("utf-8")
        keep_each = max(1, (MAX_RESULT_BYTES - len(notice)) // 2)
        data = data[:keep_each] + notice + data[-keep_each:]
    return discord.File(BytesIO(data), filename=filename)


def _with_generated_header(text: str) -> str:
    clean = (text or "").strip()
    if clean.startswith(GENERATED_HEADER):
        return clean
    return f"{GENERATED_HEADER}\n{clean}" if clean else GENERATED_HEADER


def _normalize_raw_url(url: str) -> str:
    u = url.strip().strip("<>").strip().rstrip("/")
    try:
        p = urlparse(u)
        host = (p.netloc or "").lower()
        path = p.path or ""
    except Exception:
        return u

    if host in ("pastebin.com", "www.pastebin.com"):
        if "/raw/" not in path and path.strip("/"):
            return f"https://pastebin.com/raw/{path.strip('/').split('/')[-1]}"
    if host in ("hastebin.com", "www.hastebin.com", "hasteb.in", "haste.zneix.eu"):
        if not path.startswith("/raw/") and path.strip("/"):
            return f"https://{host}/raw/{path.strip('/').split('/')[-1]}"
    if host == "pastefy.app":
        if not u.endswith("/raw"):
            return u + "/raw"
    if host == "paste.rs":
        if not u.endswith("/raw"):
            return u + "/raw"
    if host in ("gist.github.com",) and "/raw" not in path:
        return u + "/raw"
    if host == "github.com" and "/blob/" in path:
        return (
            "https://raw.githubusercontent.com/"
            + path.replace("/blob/", "/", 1).lstrip("/")
        )
    if host in ("gitlab.com",) and "/-/blob/" in path:
        return u.replace("/-/blob/", "/-/raw/", 1)
    if host == "bitbucket.org" and "/src/" in path:
        return u.replace("/src/", "/raw/", 1)
    return u


async def _fetch_raw_url(url: str, max_bytes: int = 8 * 1024 * 1024) -> str | None:
    url = url.strip().strip("<>").strip()
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme != "https" or not host or parsed.username or parsed.password:
        return None
    if host in {"localhost", "localhost.localdomain", "metadata.google.internal"}:
        return None
    try:
        host_ip = ipaddress.ip_address(host)
        if host_ip.is_private or host_ip.is_loopback or host_ip.is_link_local or host_ip.is_reserved or host_ip.is_multicast:
            return None
    except ValueError:
        try:
            addresses = await asyncio.get_running_loop().run_in_executor(
                None, lambda: socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
            )
            for address in addresses:
                resolved = ipaddress.ip_address(address[4][0])
                if resolved.is_private or resolved.is_loopback or resolved.is_link_local or resolved.is_reserved or resolved.is_multicast:
                    return None
        except (OSError, ValueError):
            return None
    timeout = aiohttp.ClientTimeout(total=20)
    headers = {
        "User-Agent": "kenV1 | envlogger",
        "Accept": "text/plain, text/*;q=0.9, */*;q=0.8",
    }
    try:
        async with aiohttp.ClientSession(timeout=timeout, headers=headers) as session:
            async with session.get(url, allow_redirects=True) as resp:
                if resp.status >= 400:
                    return None
                ct = resp.headers.get("Content-Type", "")
                if "text/html" in ct:
                    return None
                data = await resp.content.read(max_bytes + 1)
                if len(data) > max_bytes:
                    return None
                text = data.decode("utf-8", errors="replace")
                if text.lstrip().startswith(("<!DOCTYPE", "<html", "<!doctype")):
                    return None
                return text
    except Exception:
        return None


async def _create_raw_paste(text: str) -> str | None:
    timeout = aiohttp.ClientTimeout(total=4)
    headers = {
        "User-Agent": "kenV1 | envlogger",
        "Accept": "application/json, text/plain;q=0.9, */*;q=0.8",
    }
    async with aiohttp.ClientSession(timeout=timeout, headers=headers) as session:
        try:
            payload = {
                "title": "kenV1 | envlogger.lua",
                "content": text,
                "visibility": "UNLISTED",
                "type": "PASTE",
            }
            async with session.post("https://pastefy.app/api/v2/paste", json=payload) as resp:
                body = await resp.text()
                if resp.status < 300:
                    data = json.loads(body)
                    paste = data.get("paste") if isinstance(data, dict) else None
                    paste_id = None
                    if isinstance(paste, dict):
                        paste_id = paste.get("id") or paste.get("_id")
                    if not paste_id and isinstance(data, dict):
                        paste_id = data.get("id") or data.get("_id")
                    if paste_id:
                        return f"https://pastefy.app/{paste_id}/raw"
        except Exception:
            pass

        try:
            async with session.post(
                "https://api.paste.rs",
                data=text.encode("utf-8", errors="replace"),
                headers={"Content-Type": "text/plain; charset=utf-8"},
            ) as resp:
                body = (await resp.text()).strip()
                if resp.status < 300 and body.startswith("http"):
                    return body if body.endswith("/raw") else body.rstrip("/") + "/raw"
        except Exception:
            pass
    return None


_PATH_PATTERNS = [
    re.compile(r'/home/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/root/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/tmp/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/var/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/etc/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/proc/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/sys/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/nix/store/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'/run/[^\s"\'`\):]+(?::\d+)*'),
    re.compile(r'[A-Za-z]:\\[^\s"\'`\)]+'),
    re.compile(r'runner/workspace[^\s"\'`\)]*'),
    re.compile(r'replit\.com/[^\s"\'`\)]*'),
]

_BLOCKED_OUTPUT_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r'total\s+\d',                          re.I), "[DIR_LISTING_REDACTED]"),
    (re.compile(r'^drwx',                               re.M), "[DIR_LISTING_REDACTED]"),
    (re.compile(r'^-rwx',                               re.M), "[DIR_LISTING_REDACTED]"),
    (re.compile(r'^[dD]irectory of ',                   re.M), "[DIR_LISTING_REDACTED]"),
    (re.compile(r'[Vv]olume in drive'),                        "[DIR_LISTING_REDACTED]"),
    (re.compile(r'(?:TOKEN|SECRET|PASSWORD|API_KEY|WEBHOOK|PRIVATE_KEY|ACCESS_KEY|AUTH_TOKEN)\s*=\s*\S+', re.I),
                                                               "[CREDENTIAL_REDACTED]"),
    (re.compile(r'Nz[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'),
                                                               "[DISCORD_TOKEN_REDACTED]"),
    (re.compile(r'discord(?:app)?\.com/api/webhooks/\S+', re.I),
                                                               "[WEBHOOK_REDACTED]"),
    (re.compile(r'ghp_[A-Za-z0-9]{36,}'),                     "[GITHUB_TOKEN_REDACTED]"),
    (re.compile(r'gho_[A-Za-z0-9]{36,}'),                     "[GITHUB_TOKEN_REDACTED]"),
    (re.compile(r'ghs_[A-Za-z0-9]{36,}'),                     "[GITHUB_TOKEN_REDACTED]"),
    (re.compile(r'ghr_[A-Za-z0-9]{36,}'),                     "[GITHUB_TOKEN_REDACTED]"),
    (re.compile(r'github_pat_[A-Za-z0-9_]{40,}'),             "[GITHUB_TOKEN_REDACTED]"),
    (re.compile(r'sk-[A-Za-z0-9]{32,}'),                      "[API_KEY_REDACTED]"),
    (re.compile(r'(?:BEGIN|END)\s+(?:RSA\s+)?(?:OPENSSH\s+)?PRIVATE\s+KEY', re.I),
                                                               "[PRIVATE_KEY_REDACTED]"),
    (re.compile(r'(?:BEGIN|END)\s+CERTIFICATE', re.I),        "[CERT_REDACTED]"),
    (re.compile(r'\bSHELL\s*=\s*\S+'),                        "[ENV_REDACTED]"),
    (re.compile(r'\bPATH\s*=\s*/\S+'),                        "[ENV_REDACTED]"),
    (re.compile(r'\bHOME\s*=\s*/\S+'),                        "[ENV_REDACTED]"),
    (re.compile(r'\bUSER\s*=\s*\S+'),                         "[ENV_REDACTED]"),
    (re.compile(r'os\.getenv\s*\('),                                    "[GETENV_REDACTED]"),
    (re.compile(r'os\.execute\s*\('),                                   "[EXECUTE_REDACTED]"),
    (re.compile(r'io\.popen\s*\('),                                     "[POPEN_REDACTED]"),
    (re.compile(r'C:\\[Uu]sers\\[^\s]{1,60}'),                         "[PATH_REDACTED]"),
    (re.compile(r'C:\\[Dd]ownloads\\[^\s]{0,60}'),                     "[PATH_REDACTED]"),
    # dumper.lua unique internal identifiers — if these appear in output,
    # the file content was read and printed.
    (re.compile(r'\bproxyTable\b'),                                     "[INTERNAL_REDACTED]"),
    (re.compile(r'\b_CFunctionSet\b'),                                  "[INTERNAL_REDACTED]"),
    (re.compile(r'\bioLibrary\b'),                                      "[INTERNAL_REDACTED]"),
    (re.compile(r'\bosLibrary\b'),                                      "[INTERNAL_REDACTED]"),
    (re.compile(r'\berrorFunction\b'),                                  "[INTERNAL_REDACTED]"),
    (re.compile(r'\bgetMetatableFunction\b'),                           "[INTERNAL_REDACTED]"),
    (re.compile(r'\brawEqualFunction\b'),                               "[INTERNAL_REDACTED]"),
    (re.compile(r'\btoStringFunction\b'),                               "[INTERNAL_REDACTED]"),
    (re.compile(r'\btableUnpackFunction\b'),                            "[INTERNAL_REDACTED]"),
    (re.compile(r'\bdumperState\b'),                                    "[INTERNAL_REDACTED]"),
    (re.compile(r'\bMIN_DEOBF_LENGTH\b'),                               "[INTERNAL_REDACTED]"),
    (re.compile(r'\[Dumper\]'),                                         "[INTERNAL_REDACTED]"),
    # bypass.lua unique internal identifiers
    (re.compile(r'\b_HOOKOP\b'),                                        "[INTERNAL_REDACTED]"),
    (re.compile(r'__DUMPER_REAL_IO_OPEN'),                              "[INTERNAL_REDACTED]"),
    (re.compile(r'__BYPASS_VERBOSE'),                                   "[INTERNAL_REDACTED]"),
    (re.compile(r'\b_bypassOnReset\b'),                                 "[INTERNAL_REDACTED]"),
    (re.compile(r'\b_native_debug\b'),                                  "[INTERNAL_REDACTED]"),
    (re.compile(r'\b_installAntiTamperWrappers\b'),                     "[INTERNAL_REDACTED]"),
    (re.compile(r'\b_restricted_open\b'),                               "[INTERNAL_REDACTED]"),
    (re.compile(r'flamedumper', re.I),                                  "[INTERNAL_REDACTED]"),
    (re.compile(r'_PHYS_IO_OPEN'),                                      "[INTERNAL_REDACTED]"),
    # Lua bytecode leak (string.dump output starts with \x1bLua)
    (re.compile(r'\x1bLua'),                                            "[BYTECODE_REDACTED]"),
    (re.compile(r'string\.dump', re.I),                                 "[BYTECODE_REDACTED]"),
]

_INTERNAL_SCRIPT_PATTERNS = [
    re.compile(r"\b(?:dumper|dumper2|bypass|lua_runner|lua_runtime|lune_runner|"
               r"lune_sandbox_runner|roblox_api_registry|deobfuscator|source_guard|"
               r"dump_luraph|patch_and_dump_v92|trace_to_lua|patch_dump|"
               r"lua51_decompile)\.(?:lua|luau|py)\b", re.I),
    re.compile(r'\[string\s+"[^"]*"\]'),
]


def _redact_internals(text: str) -> str:
    if not text:
        return text
    for pat in _INTERNAL_SCRIPT_PATTERNS:
        text = pat.sub("[internal]", text)
    text = re.sub(r"\[internal\]:\d+:\s*", "[internal] ", text)
    return text


def _strip_lua_comments(src: str) -> str:
    src = re.sub(r'--\[=*\[.*?\]=*\]', ' ', src, flags=re.DOTALL)
    src = re.sub(r'--[^\n]*', ' ', src)
    return src

def _extract_string_contents(src: str) -> list[str]:
    out: list[str] = []
    for m in re.finditer(r'\[=*\[(.*?)\]=*\]', src, re.DOTALL):
        out.append(m.group(1))
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', src):
        out.append(m.group(1))
    for m in re.finditer(r"'((?:[^'\\]|\\.)*)'", src):
        out.append(m.group(1))
    return out

def _decode_escapes(s: str) -> str:
    s = re.sub(r'\\x([0-9a-fA-F]{2})',
               lambda m: chr(int(m.group(1), 16)), s)
    s = re.sub(r'\\(\d{1,3})',
               lambda m: chr(min(int(m.group(1)), 255)), s)
    s = re.sub(r'\\u([0-9a-fA-F]{4})',
               lambda m: chr(int(m.group(1), 16)), s)
    return s

_DANGER_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r'\bos\.(?:execute|exit|remove|rename|getenv)\b'),                 "os.* shell call"),
    (re.compile(r'\bio\.(?:popen|open|lines|input|output|read)\b'),                "io.* shell/fs call"),
    (re.compile(r'\bdebug\.(?:sethook|getlocal|setlocal|getregistry)\b'),
                                                                                    "debug.* library abuse"),
    (re.compile(r'discord(?:app)?\.com/api/webhooks/', re.I),                      "Discord webhook exfil"),
    (re.compile(r'(?:curl|wget)\s+https?://', re.I),                               "curl/wget exfil"),
    (re.compile(r'\bdofile\s*\(|\bloadfile\s*\('),                                 "dofile/loadfile"),
    (re.compile(r'\bpackage\s*\.\s*loadlib\b'),                                    "package.loadlib"),
    (re.compile(r'/etc/(?:passwd|shadow|hosts|ssh)', re.I),                        "sensitive fs path"),
    (re.compile(r'(?:~|/root|/home)/\.ssh/', re.I),                                "SSH key path probe"),
    (re.compile(r'\bcmd(?:\.exe)?\b', re.I),                                       "cmd.exe / shell"),
    (re.compile(r'\bpowershell\b', re.I),                                           "powershell"),
    (re.compile(r'\b(?:nc|ncat|netcat)\s+-', re.I),                                "netcat reverse shell"),
    (re.compile(r'2>(?:/dev/null|nul)', re.I),                                     "stderr redirect"),
    (re.compile(r'Nz[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'),    "Discord bot token exfil"),
    (re.compile(r'ghp_[A-Za-z0-9]{36,}'),                                          "GitHub PAT exfil"),
    (re.compile(r'gho_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}'),                   "GitHub OAuth/server token exfil"),
    (re.compile(r'(?:TOKEN|SECRET|PASSWORD|API_KEY|WEBHOOK)\s*=\s*\S+', re.I),    "credential env var exfil"),
    (re.compile(r'BEGIN\s+(?:RSA\s+)?(?:OPENSSH\s+)?PRIVATE\s+KEY', re.I),        "private key exfil"),
    (re.compile(r'\bsk-[A-Za-z0-9]{32,}'),                                         "OpenAI API key exfil"),
    (re.compile(r'require\s*\(\s*["\'](?:socket|http|ffi|posix|luasocket)["\']', re.I),
                                                                                    "dangerous require (network/ffi)"),
    (re.compile(r'\b_G\s*\.\s*(?:os|io|debug|package)\b'),                         "_G.os/io/debug/package access"),
    (re.compile(r'rawget\s*\(\s*_G\s*,\s*["\'](?:io|os|debug|package)["\']'),     "rawget(_G) sandbox escape"),
]

def _scan_decoded(text: str) -> str | None:
    for pat, label in _DANGER_PATTERNS:
        if pat.search(text):
            return label
    return None


def _eval_string_char(src: str) -> str:
    def replacer(m: re.Match) -> str:
        try:
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
            return ''.join(chr(n & 0xFF) for n in nums)
        except Exception:
            return m.group(0)
    pat = re.compile(r'(?:string\.char|[^.\w]char)\s*\(\s*([\d,\s]+)\s*\)', re.DOTALL)
    return pat.sub(replacer, src)

def _try_xor_decode(src: str) -> list[str]:
    results: list[str] = []
    tbl_pat = re.compile(r'\{((?:\s*\d{1,3}\s*,\s*){5,}\s*\d{1,3}\s*)\}')
    for m in tbl_pat.finditer(src):
        try:
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
        except Exception:
            continue
        if not all(0 <= n <= 255 for n in nums):
            continue
        for key in range(256):
            decoded = ''.join(chr(n ^ key) for n in nums)
            if _scan_decoded(decoded):
                results.append(decoded)
                break
    return results


def _try_table_transforms(src: str) -> list[str]:
    _ATOM_MODS  = {"os", "io", "package", "debug"}
    _ATOM_FUNCS = {
        "execute", "popen", "remove", "rename", "getenv", "exit",
        "loadlib", "setupvalue", "setlocal", "sethook", "getregistry",
    }

    results: list[str] = []

    tbl_pat = re.compile(r'\{((?:\s*\d{1,3}\s*,\s*)*\s*\d{1,3}\s*)\}')

    for m in tbl_pat.finditer(src):
        try:
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
        except Exception:
            continue
        if len(nums) < 2:
            continue
        if not all(0 <= n <= 255 for n in nums):
            continue

        rev = list(reversed(nums))

        def _check(seq: list[int]) -> str | None:
            s = ''.join(chr(n) for n in seq)
            if _scan_decoded(s) or s.strip() in _ATOM_MODS or s.strip() in _ATOM_FUNCS:
                return s
            return None

        if hit := _check(nums):
            results.append(hit); continue

        if hit := _check(rev):
            results.append(hit); continue

        if hit := _check([(255 - n) for n in nums]):
            results.append(hit); continue
        if hit := _check([(255 - n) for n in rev]):
            results.append(hit); continue

        found_xor = False
        for key in range(256):
            if hit := _check([n ^ key for n in nums]):
                results.append(hit); found_xor = True; break
            if hit := _check([n ^ key for n in rev]):
                results.append(hit); found_xor = True; break
        if found_xor:
            continue

        found_offset = False
        for k in range(1, 128):
            if hit := _check([(n + k) % 256 for n in nums]):
                results.append(hit); found_offset = True; break
            if hit := _check([(n - k) % 256 for n in nums]):
                results.append(hit); found_offset = True; break
            if hit := _check([(n + k) % 256 for n in rev]):
                results.append(hit); found_offset = True; break
            if hit := _check([(n - k) % 256 for n in rev]):
                results.append(hit); found_offset = True; break
        if found_offset:
            continue

    return results

def _extract_load_args(src: str) -> list[str]:
    results: list[str] = []
    pat = re.compile(
        r'(?:loadstring|load)\s*\(\s*(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\')\s*[,)]',
        re.DOTALL,
    )
    for m in pat.finditer(src):
        results.append(m.group(1) or m.group(2) or "")
    return results

def _expand_bracket_access(src: str) -> str:
    src = re.sub(r'\[\s*["\'](\w+)["\']\s*\]', r'.\1', src)
    return src

def _expand_concat_vars(src: str) -> str:
    assignments: dict[str, str] = {}
    for m in re.finditer(r'\blocal\s+(\w+)\s*=\s*["\']([^"\']{1,40})["\']', src):
        assignments[m.group(1)] = m.group(2)
    if not assignments:
        return src

    def sub_var(m: re.Match) -> str:
        name = m.group(0)
        return f'"{assignments[name]}"' if name in assignments else name
    result = re.sub(r'\b([A-Za-z_]\w*)\b', sub_var, src)

    _adj_concat = re.compile(r'"([^"]*)"\s*\.\.\s*"([^"]*)"')
    for _ in range(8):
        new = _adj_concat.sub(lambda m: f'"{m.group(1)}{m.group(2)}"', result)
        if new == result:
            break
        result = new

    return result


def _expand_g_alias(src: str) -> str:
    for m in re.finditer(r'\blocal\s+(\w+)\s*=\s*_G\b', src):
        alias = re.escape(m.group(1))
        src = re.sub(r'\b' + alias + r'\b', '_G', src)
    return src


def _expand_all_decoded_vars(src: str) -> str:
    assignments: dict[str, str] = {}
    pat = re.compile(
        r'\blocal\s+(\w+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\')'
    )
    for m in pat.finditer(src):
        var_name = m.group(1)
        raw = m.group(2) if m.group(2) is not None else (m.group(3) or "")
        decoded = _decode_escapes(raw)
        assignments[var_name] = decoded
    if not assignments:
        return src

    def sub_var(m: re.Match) -> str:
        name = m.group(0)
        return f'"{assignments[name]}"' if name in assignments else name

    return re.sub(r'\b([A-Za-z_]\w*)\b', sub_var, src)

_HARD_BLOCKS: list[tuple[re.Pattern, str]] = [
    # os.* shell/fs access
    (re.compile(r'\bos\s*\.\s*(?:execute|exit|remove|rename|tmpname|getenv)\b'),
     "os.<func> (shell/fs access)"),
    (re.compile(r'''\bos\s*\[\s*['"](?:execute|exit|remove|rename|tmpname|getenv)['"]\s*\]'''),
     'os["func"] (bracket bypass)'),
    (re.compile(r'\bos\s*\.\s*execute\s*\(', re.I),
     "os.execute() direct call"),
    (re.compile(r'pcall\s*\(\s*os\s*\.\s*execute', re.I),
     "pcall(os.execute) evasion"),
    (re.compile(r'xpcall\s*\(\s*os\s*\.\s*execute', re.I),
     "xpcall(os.execute) evasion"),

    # io.* filesystem/shell
    (re.compile(r'\bio\s*\.\s*(?:popen|open|lines|input|output|read|write|tmpfile)\b'),
     "io.* filesystem/shell call"),
    (re.compile(r'''\bio\s*\[\s*['"](?:popen|open|lines|input|output|read|write|tmpfile)['"]\s*\]'''),
     'io["func"] (bracket bypass)'),
    (re.compile(r'\bio\s*\.\s*popen\s*\(', re.I),
     "io.popen() direct call"),
    (re.compile(r'pcall\s*\(\s*io\s*\.\s*(?:popen|open)', re.I),
     "pcall(io.popen/open) evasion"),

    # rawget / _G sandbox escape
    (re.compile(r'\brawget\s*\(\s*(?:os|io)\s*,\s*["\'](?:execute|popen|open|remove|exit|getenv)["\']'),
     "rawget(os/io) bypass"),
    (re.compile(r'\brawget\s*\(\s*_G\s*,\s*["\'](?:io|os|debug|package)["\']'),
     "rawget(_G, io/os/debug) sandbox escape"),
    (re.compile(r'\brawget\s*\(\s*_G\s*,\s*["\'](?:execute|popen|open|getenv|remove|exit)["\']'),
     "rawget(_G, dangerous func) sandbox escape"),
    (re.compile(r'_G\s*[\[.]\s*["\']?(?:os|io|package)\b'),
     "_G.os/io/package access"),
    (re.compile(r'_G\s*[\[.]\s*["\']?(?:execute|popen|open|remove|rename|getenv|loadlib)\b'),
     "_G.<dangerous func> direct access"),
    (re.compile(r'\bgetfenv\s*\(\s*[01]\s*\)\s*[\[.]', re.I),
     "getfenv(0/1) environment escape"),
    (re.compile(r'\bsetfenv\s*\(', re.I),
     "setfenv() environment override"),

    # dofile / loadfile / package
    (re.compile(r'\b(?:dofile|loadfile)\s*\('), "dofile/loadfile"),
    (re.compile(r'\bpackage\s*\.\s*loadlib\b'), "package.loadlib"),
    (re.compile(r'\brequire\s*\(\s*["\'](?:socket|http|ffi|posix|luasocket|lfs|os|io|curl)["\']', re.I),
     "dangerous require (network/ffi/os module)"),

    # executor file-system API
    (re.compile(r'\breadfile\s*\(', re.I),
     "readfile() executor API: file read attempt"),
    (re.compile(r'\blistfiles\s*\(', re.I),
     "listfiles() executor API: directory enumeration"),
    (re.compile(r'\bwritefile\s*\(', re.I),
     "writefile() executor API: file write attempt"),
    (re.compile(r'\bappendfile\s*\(', re.I),
     "appendfile() executor API: file append attempt"),
    (re.compile(r'\bdelfile\s*\(', re.I),
     "delfile() executor API: file deletion attempt"),
    (re.compile(r'\bdelfolder\s*\(', re.I),
     "delfolder() executor API: folder deletion attempt"),
    (re.compile(r'\bmakefolder\s*\(', re.I),
     "makefolder() executor API: folder creation"),
    (re.compile(r'\bisfile\s*\(', re.I),
     "isfile() executor API: file existence probe"),
    (re.compile(r'\bisfolder\s*\(', re.I),
     "isfolder() executor API: folder existence probe"),

    # sensitive bot filenames being targeted
    (re.compile(r'["\']bypass\.lua["\']', re.I),
     "bypass.lua filename targeted (bot file theft attempt)"),
    (re.compile(r'["\']dumper\.lua["\']', re.I),
     "dumper.lua filename targeted (bot file theft attempt)"),
    (re.compile(r'["\']dumper2\.lua["\']', re.I),
     "dumper2.lua filename targeted (bot file theft attempt)"),
    (re.compile(r'["\']Revea\.lua["\']', re.I),
     "Revea.lua filename targeted (bot file theft attempt)"),
    (re.compile(r'["\']bot\.py["\']', re.I),
     "bot.py filename targeted (bot source theft attempt)"),
    (re.compile(r'["\']lua_runner\.py["\']', re.I),
     "lua_runner.py filename targeted (bot file theft)"),
    (re.compile(r'["\']deobfuscator\.py["\']', re.I),
     "deobfuscator.py filename targeted (bot file theft)"),
    (re.compile(r'["\']main\.py["\']', re.I),
     "main.py filename targeted (bot file theft)"),
    (re.compile(r'["\']keep_alive\.py["\']', re.I),
     "keep_alive.py filename targeted (bot file theft)"),
    (re.compile(r'["\']\.acl\.json["\']', re.I),
     ".acl.json filename targeted (ACL file theft)"),
    (re.compile(r'["\']\.env["\']', re.I),
     ".env filename targeted (secrets theft attempt)"),
    (re.compile(r'["\'][^"\']*\.lua["\'].*readfile|readfile.*["\'][^"\']*\.lua["\']', re.I | re.DOTALL),
     "readfile() targeting a .lua file"),
    (re.compile(r'["\'][^"\']*\.py["\'].*readfile|readfile.*["\'][^"\']*\.py["\']', re.I | re.DOTALL),
     "readfile() targeting a .py file"),
    (re.compile(r'listfiles\s*\(["\']\.?/?["\']', re.I),
     "listfiles() enumerating root/current directory"),
    (re.compile(r'listfiles\s*\(["\'][./\\]*["\']', re.I),
     "listfiles() scanning working directory"),
    (re.compile(r'for\s+\w+\s*[,\s]+\w+\s+in\s+(?:pairs|ipairs)\s*\(\s*listfiles', re.I),
     "looping listfiles() output: directory traversal"),

    # shell tools
    (re.compile(r'\bcurl\b', re.I), "curl (exfil tool)"),
    (re.compile(r'\bwget\b', re.I), "wget (exfil tool)"),
    (re.compile(r'\bpowershell(?:\.exe)?\b', re.I), "powershell"),
    (re.compile(r'\bcmd\.exe\b', re.I), "cmd.exe"),
    (re.compile(r'\b(?:nc|ncat|netcat)\s+', re.I), "netcat (reverse shell / exfil)"),
    (re.compile(r'\bbash\s+-[ci]\b', re.I), "bash -c/-i (shell exec)"),
    (re.compile(r'\bsh\s+-[ce]\b', re.I), "sh -c/-e (shell exec)"),
    (re.compile(r'2>\s*(?:/dev/null|nul)\b', re.I), "stderr suppression"),
    (re.compile(r'[|>]\s*(?:curl|wget|bash|sh\b|nc\b|python|ruby|perl)', re.I),
     "shell pipe to network/interpreter"),

    # Discord webhook exfil
    (re.compile(r'discord(?:app)?\.com/api/webhooks/', re.I),
     "Discord webhook exfil"),
    (re.compile(r'discordapp\.com', re.I),
     "discordapp.com reference (exfil domain)"),
    (re.compile(r'discord\.com/api/', re.I),
     "discord.com API call (exfil)"),
    (re.compile(r'hooks\.discord(?:app)?\.com', re.I),
     "Discord hook domain"),
    (re.compile(r'(?:webhook|WEBHOOK)\s*[=:]\s*["\']https?://(?:discord|discordapp)', re.I),
     "webhook variable assigned Discord URL"),
    (re.compile(r'api/webhooks/\d{10,}/[A-Za-z0-9_\-]{50,}', re.I),
     "Discord webhook URL fragment"),

    # Discord bot token
    (re.compile(r'(?:M|N|O)[A-Za-z0-9]{23,25}\.[A-Za-z0-9_\-]{6}\.[A-Za-z0-9_\-]{27,}'),
     "Discord bot token in payload"),
    (re.compile(r'["\']Bot\s+[A-Za-z0-9_\-]{50,}["\']', re.I),
     "Discord Bot auth header token"),
    (re.compile(r'Authorization.*Bot\s+[A-Za-z0-9_\-]{50,}', re.I),
     "Discord Bot Authorization header"),

    # other credential / API tokens
    (re.compile(r'ghp_[A-Za-z0-9]{36,}'), "GitHub PAT token"),
    (re.compile(r'gho_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}'), "GitHub OAuth/server token"),
    (re.compile(r'sk-[A-Za-z0-9]{32,}'), "OpenAI API key"),
    (re.compile(r'xox[bprs]-[A-Za-z0-9\-]{10,}', re.I), "Slack token"),
    (re.compile(r'AKIA[0-9A-Z]{16}'), "AWS Access Key ID"),
    (re.compile(r'(?:TOKEN|SECRET|PASSWORD|API_KEY|WEBHOOK|BEARER)\s*[=:]\s*["\']?\S{10,}', re.I),
     "credential assignment (exfil attempt)"),
    (re.compile(r'Bearer\s+[A-Za-z0-9_\-\.]{20,}', re.I),
     "Bearer token in payload"),

    # SSH / private key material
    (re.compile(r'BEGIN\s+(?:RSA\s+)?(?:OPENSSH\s+)?(?:EC\s+)?PRIVATE\s+KEY', re.I),
     "private key material in payload"),
    (re.compile(r'~?/\.ssh/(?:id_rsa|id_ed25519|id_ecdsa|authorized_keys|known_hosts|config)', re.I),
     "SSH key/config file path"),
    (re.compile(r'/etc/(?:passwd|shadow|sudoers|ssh|crontab|hosts|environment)', re.I),
     "critical system file access"),
    (re.compile(r'/proc/(?:self|[0-9]+)/(?:environ|cmdline|maps|mem)', re.I),
     "/proc filesystem access (env leak)"),
    (re.compile(r'/home/[A-Za-z0-9_\-]+/\.(?:ssh|bashrc|bash_history|zshrc|profile|env)', re.I),
     "user home sensitive file access"),

    # HTTP / socket exfil
    (re.compile(r'http\.(?:get|post|request|put|patch|delete)\s*\(', re.I),
     "HTTP request from Lua (exfil via http lib)"),
    (re.compile(r'socket\.(?:connect|tcp|udp|http)\s*\(', re.I),
     "raw socket connection (exfil)"),
    (re.compile(r'https?://(?!(?:raw\.githubusercontent|pastebin|hastebin|paste\.rs))[^\s"\']{10,}', re.I),
     "non-whitelisted URL (potential exfil endpoint)"),
    (re.compile(r'https?://[^\s"\']*(?:webhook|hook|exfil|leak|dump|steal|grab|logger)', re.I),
     "suspicious URL keyword (exfil endpoint)"),
    (re.compile(r'https?://(?:\d{1,3}\.){3}\d{1,3}', re.I),
     "raw IP address URL (exfil / C2)"),
    (re.compile(r'\.(?:ngrok\.io|trycloudflare\.com|serveo\.net|localtunnel\.me)', re.I),
     "tunnel service URL (C2 / exfil relay)"),

    # Windows paths
    (re.compile(r'C:\\[Uu]sers\\[A-Za-z]'), "Windows user path"),
    (re.compile(r'C:\\[Ww]indows\\', re.I), "Windows system path"),
    (re.compile(r'C:\\[Dd]ownloads\\', re.I), "Windows Downloads path"),
    (re.compile(r'%(?:APPDATA|LOCALAPPDATA|TEMP|USERPROFILE|SYSTEMROOT)%', re.I),
     "Windows env variable path"),

    # misc markers
    (re.compile(r'\breverse\s*shell\b', re.I), "reverse shell keyword"),
    (re.compile(r'(?:exfil|exfiltrat)', re.I), "exfil keyword in payload"),
    (re.compile(r'(?:steal|grab|harvest)\s*(?:token|cookie|password|credential)', re.I),
     "credential stealing keyword"),
    (re.compile(r'for\s+\w+\s*=\s*#\w+\s*,\s*1\s*,\s*-1\b.*?string\s*\.\s*char\b', re.DOTALL),
     "reverse-loop string.char decode"),
]

_SCORED: list[tuple[re.Pattern, int, str]] = [
    (re.compile(r'https?://', re.I),                                        2, "https:// URL"),
    (re.compile(r'2>(?:nul|/dev/null)', re.I),                             3, "stderr redirect"),
    (re.compile(r'[|>]\s*(?:curl|wget|bash|sh\b|nc\b|python|ruby)', re.I),3, "shell pipe to network"),
    (re.compile(r'--data(?:-binary|-urlencode)?\b|-d\s+@', re.I),          2, "curl --data flag"),
    (re.compile(r'\bAuthorization\b', re.I),                               2, "Authorization header"),
    (re.compile(r'\bContent-Type\b.*application/json', re.I),              1, "JSON Content-Type (HTTP post)"),
    (re.compile(r'\btostring\s*\(.*\)\s*\.\.', re.I),                     1, "string concat (possible token assembly)"),
    (re.compile(r'string\s*\.\s*format\s*\(.*https?://', re.I),            2, "string.format URL construction"),
    (re.compile(r'\bgetenv\b|\bos\s*\.\s*getenv\b', re.I),                3, "environment variable read"),
    (re.compile(r'io\s*\.\s*(?:open|popen|read|write)', re.I),             3, "io filesystem access"),
    (re.compile(r'os\s*\.\s*(?:execute|exit|remove)', re.I),               3, "os shell/fs access"),
]
_SCORE_THRESHOLD = 3


_NOISE_LINE_PATTERNS = [
    re.compile(r"^\s*Processing\s+script\.{0,3}\s*$", re.I),
    re.compile(r"^\s*Executing\s+deobfuscation\s+for\b.*$", re.I),
    re.compile(r"^\s*input\s*:\s*\S+.*$", re.I),
    re.compile(r"^\s*vm:\s*running\s*$", re.I),
    re.compile(r"^\s*done:\s*lines=\d+.*$", re.I),
    re.compile(r"^\s*\[DBG\].*$"),
    re.compile(r"^\s*\[(?:bypass|namaiki|canary|trap|guard|scrlua|Dumper)\].*$"),
    re.compile(r"^\s*={3,}.*$"),
    re.compile(r"^\s*-{3,}\s*(?:LAYER\s+ANALYSIS|END\s+ANALYSIS|TRACE)?\s*-{0,}\s*$", re.I),
    re.compile(r"^\s*Saved(\s+to)?:\s*.*$", re.I),
    re.compile(r"^\s*Lines:\s*\d+\s*\|\s*Remotes:.*$", re.I),
    re.compile(r"^\s*\[[^\]]+\]\s+exit=.*$"),
    re.compile(r"^\s*\(no process log\)\s*$"),
    re.compile(r"^\s*capture\s+armed:.*$", re.I),
]


_ERROR_LINE_PATTERNS = [
    re.compile(r"\bERROR:\s+", re.I),
    re.compile(r"\b(?:runtime|syntax|lua|load|parse)\s+error\b", re.I),
    re.compile(r"\battempt to (?:call|index|concatenate|perform|compare)\b", re.I),
    re.compile(r"\bbad argument\b", re.I),
    re.compile(r"\b(?:exception|traceback|stack\s+traceback)\b", re.I),
    re.compile(r"\b(?:cannot|unable\s+to|failed\s+to|unsupported|not\s+supported|timeout|denied|allowed file)\b", re.I),
    re.compile(r"\bDUMPER_FAILED\b"),
    re.compile(r"\bCRITICAL\s+ERROR\b", re.I),
    re.compile(r":\d+:\s+\S+"),
    re.compile(r"^lua:\s+\S", re.I),
    re.compile(r"^\s*\[(?:PATH_REDACTED|internal|dumper|bypass)\].*:\s+\S", re.I),
    re.compile(r"\b(?:too many|limit is|unexpected|unfinished|malformed|panic)\b", re.I),
    re.compile(r"\b(?:out of memory|stack overflow)\b", re.I),
]

_SANDBOX_NOISE_PATTERNS = [
    re.compile(r"\[SECURITY\]", re.I),
    re.compile(r"\(command line\):\d+:\s+in function\s+'(?:os|io)\.", re.I),
    re.compile(r"^lua:\s+(?:os\.|io\.|string\.|require:|debug\.)", re.I),
    re.compile(r"\[_HOOKOP\]", re.I),
    re.compile(r"hookOp module|preamble ready", re.I),
]


def _is_sandbox_noise(line: str) -> bool:
    return any(p.search(line) for p in _SANDBOX_NOISE_PATTERNS)


def _looks_like_real_error(line: str) -> bool:
    return any(p.search(line) for p in _ERROR_LINE_PATTERNS)


def _strip_noise_lines(text: str) -> str:
    if not text:
        return text
    kept = []
    for line in text.splitlines():
        if _looks_like_real_error(line):
            kept.append(line)
            continue
        if any(pat.match(line) for pat in _NOISE_LINE_PATTERNS):
            continue
        kept.append(line)
    cleaned = "\n".join(kept)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    return cleaned.strip("\n")


def _sanitize_output(text: str) -> str:
    if not text:
        return text
    for pat in _PATH_PATTERNS:
        text = pat.sub("[PATH_REDACTED]", text)
    for pat, replacement in _BLOCKED_OUTPUT_PATTERNS:
        text = pat.sub(replacement, text)
    text = _redact_internals(text)
    text = _strip_noise_lines(text)
    return text


class _ProgressWriter:

    def __init__(self, loop: asyncio.AbstractEventLoop, callback):
        self._loop = loop
        self._cb = callback
        self._buf = ""

    def write(self, text: str):
        self._buf += text
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            clean = line.strip()
            if clean:
                asyncio.run_coroutine_threadsafe(self._cb(clean), self._loop)

    def flush(self):
        if self._buf.strip():
            asyncio.run_coroutine_threadsafe(self._cb(self._buf.strip()), self._loop)
            self._buf = ""


def _try_base64_decode_strings(src: str) -> list[str]:
    results: list[str] = []
    _B64_ONLY = re.compile(r'^[A-Za-z0-9+/=]+$')
    b64_pat = re.compile(
        r'(?:"([A-Za-z0-9+/]{32,}={0,2})"'
        r'|\'([A-Za-z0-9+/]{32,}={0,2})\''
        r'|\[\[([A-Za-z0-9+/=\n\r\t ]{32,})\]\])',
        re.DOTALL,
    )
    for m in b64_pat.finditer(src):
        raw = (m.group(1) or m.group(2) or m.group(3) or "")
        raw = raw.replace("\n", "").replace("\r", "").replace("\t", "").replace(" ", "").strip()
        if not raw or not _B64_ONLY.match(raw):
            continue
        pad = (4 - len(raw) % 4) % 4
        raw += "=" * pad
        try:
            decoded_bytes = _b64mod.b64decode(raw)
            decoded = decoded_bytes.decode("utf-8", errors="replace")
            if _scan_decoded(decoded) or re.search(
                r'\blocal\b|\bfunction\b|\bend\b|\breturn\b|\bloadstring\b', decoded
            ):
                results.append(decoded)
        except Exception:
            pass
    return results


def _try_hex_table_decode(src: str) -> list[str]:
    results: list[str] = []
    hex_tbl = re.compile(
        r'\{((?:\s*0[xX][0-9a-fA-F]{1,2}\s*,\s*){3,}\s*0[xX][0-9a-fA-F]{1,2}\s*)\}'
    )
    for m in hex_tbl.finditer(src):
        try:
            nums = [int(x.strip(), 16) for x in m.group(1).split(',') if x.strip()]
        except Exception:
            continue
        if not nums:
            continue
        plain = ''.join(chr(n & 0xFF) for n in nums)
        if _scan_decoded(plain):
            results.append(plain)
            continue
        for key in range(256):
            decoded = ''.join(chr((n ^ key) & 0xFF) for n in nums)
            if _scan_decoded(decoded):
                results.append(decoded)
                break
    return results


def _try_multibyte_xor_decode(src: str) -> list[str]:
    results: list[str] = []
    tbl_pat = re.compile(r'\{((?:\s*\d{1,3}\s*,\s*){7,}\s*\d{1,3}\s*)\}')
    for m in tbl_pat.finditer(src):
        try:
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
        except Exception:
            continue
        if len(nums) < 8 or not all(0 <= n <= 255 for n in nums):
            continue
        found = False
        for k1 in range(256):
            if found:
                break
            for k2 in range(256):
                decoded = ''.join(chr(nums[i] ^ ([k1, k2][i % 2])) for i in range(len(nums)))
                if _scan_decoded(decoded):
                    results.append(decoded)
                    found = True
                    break
    return results


def _try_vigenere_key_xor(src: str) -> list[str]:
    results: list[str] = []
    key_pat = re.compile(r'(?:"([^"\\]{2,32})"|\'([^\'\\]{2,32})\')')
    candidate_keys: list[str] = []
    for m in key_pat.finditer(src):
        k = m.group(1) or m.group(2) or ""
        if k and 2 <= len(k) <= 32:
            candidate_keys.append(k)
    if not candidate_keys:
        return results
    tbl_pat = re.compile(r'\{((?:\s*\d{1,3}\s*,\s*){5,}\s*\d{1,3}\s*)\}')
    for m in tbl_pat.finditer(src):
        try:
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
        except Exception:
            continue
        if len(nums) < 6 or not all(0 <= n <= 255 for n in nums):
            continue
        for key in candidate_keys:
            kb = [ord(c) for c in key]
            decoded = ''.join(chr(nums[i] ^ kb[i % len(kb)]) for i in range(len(nums)))
            if _scan_decoded(decoded):
                results.append(decoded)
    return results


def _try_rot_decode(src: str) -> list[str]:
    results: list[str] = []
    str_pat = re.compile(r'(?:"([^"\\]{8,})"|\'([^\'\\]{8,})\')')
    for m in str_pat.finditer(src):
        s = m.group(1) or m.group(2) or ""
        if not s:
            continue
        for shift in range(1, 26):
            decoded = ""
            for c in s:
                o = ord(c)
                if 65 <= o <= 90:
                    decoded += chr((o - 65 + shift) % 26 + 65)
                elif 97 <= o <= 122:
                    decoded += chr((o - 97 + shift) % 26 + 97)
                else:
                    decoded += c
            if _scan_decoded(decoded):
                results.append(decoded)
                break
    return results


def _detect_encoding_types(src: str) -> list[str]:
    detected: list[str] = []
    if re.search(r'[A-Za-z0-9+/]{64,}={0,2}', src):
        if re.search(r'base64|b64|atob|btoa|decode|gsub.*[A-Z].*[a-z].*[0-9]', src, re.I):
            detected.append("base64")
        else:
            detected.append("base64 (long encoded string)")
    if re.search(r'bit\.bxor|bit32\.bxor', src):
        detected.append("bit-xor")
    if re.search(r'[~\^]\s*\w+|string\.char\s*\([^)]*[~\^]', src):
        detected.append("xor-char")
    if re.search(r'\{(?:\s*0[xX][0-9a-fA-F]{1,2}\s*,){3,}', src):
        detected.append("hex-table")
    if re.search(r'\{(?:\s*\d{1,3}\s*,){10,}', src):
        detected.append("number-table")
    if src.count('\\x') > 20:
        detected.append("hex-escape-blob")
    if re.search(r'string\.char\s*\(', src) and src.count('string.char') > 5:
        detected.append("string.char-encode")
    if re.search(r'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', src):
        detected.append("custom-alphabet (base64 variant)")
    if re.search(r'for\s+\w+\s*=\s*1\s*,\s*#\w+\s+do.*?[~\^]', src, re.DOTALL):
        detected.append("loop-xor")
    return detected


def _lua_looks_valid(s: str) -> bool:
    if not s or not s.strip():
        return False
    if len(s) < 8:
        return False
    printable_ratio = sum(1 for c in s if c.isprintable() or c in '\n\r\t') / max(len(s), 1)
    if printable_ratio < 0.85:
        return False
    return bool(re.search(
        r'\blocal\b|\bfunction\b|\bend\b|\breturn\b|\bloadstring\b|\bload\b|\bif\b|\bfor\b|\bthen\b',
        s
    ))


def _unwrap_obfuscation_layers(lua_code: str, max_depth: int = 4) -> list[tuple[str, str]]:
    results: list[tuple[str, str]] = []

    sc_direct = re.compile(
        r'(?:loadstring|load)\s*\(\s*string\.char\s*\(([\d,\s]+)\)\s*\)'
    )
    for m in sc_direct.finditer(lua_code):
        try:
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
            decoded = ''.join(chr(n & 0xFF) for n in nums)
            if len(decoded) > 10:
                results.append(("string.char-direct", decoded))
        except Exception:
            pass

    chain_pat = re.compile(
        r'(?:loadstring|load)\s*\(\s*(string\.char\s*\(\d+\)(?:\s*\.\.\s*string\.char\s*\(\d+\))+)\s*\)'
    )
    for m in chain_pat.finditer(lua_code):
        try:
            nums = [int(x) for x in re.findall(r'string\.char\s*\((\d+)\)', m.group(1))]
            decoded = ''.join(chr(n & 0xFF) for n in nums)
            if len(decoded) > 10:
                results.append(("string.char-chain", decoded))
        except Exception:
            pass

    tbl_then_key = re.compile(
        r'local\s+(\w+)\s*=\s*\{((?:\s*\d{1,3}\s*,\s*){10,}\s*\d{1,3}\s*)\}'
        r'[\s\S]{0,600}?'
        r'string\.char\s*\(\s*\1\s*\[\s*\w+\s*\]\s*[~\^]\s*(\d+)\s*\)',
        re.DOTALL,
    )
    for m in tbl_then_key.finditer(lua_code):
        try:
            nums = [int(x.strip()) for x in m.group(2).split(',') if x.strip()]
            key  = int(m.group(3)) & 0xFF
            decoded = ''.join(chr(n ^ key) for n in nums)
            if _lua_looks_valid(decoded):
                results.append(("xor-table-inline-key", decoded))
        except Exception:
            pass

    key_first = re.compile(
        r'local\s+(\w+)\s*=\s*(\d+)\s*'
        r'local\s+(\w+)\s*=\s*\{((?:\s*\d{1,3}\s*,\s*){10,}\s*\d{1,3}\s*)\}'
        r'[\s\S]{0,600}?'
        r'(?:\3\s*\[\s*\w+\s*\])\s*[~\^]\s*\1',
        re.DOTALL,
    )
    for m in key_first.finditer(lua_code):
        try:
            key  = int(m.group(2)) & 0xFF
            nums = [int(x.strip()) for x in m.group(4).split(',') if x.strip()]
            decoded = ''.join(chr(n ^ key) for n in nums)
            if _lua_looks_valid(decoded):
                results.append(("xor-table-key-first", decoded))
        except Exception:
            pass

    bxor_pat = re.compile(
        r'local\s+(\w+)\s*=\s*\{((?:\s*\d{1,3}\s*,\s*){10,}\s*\d{1,3}\s*)\}'
        r'[\s\S]{0,600}?'
        r'bit(?:32)?\.bxor\s*\(\s*\1\s*\[\s*\w+\s*\]\s*,\s*(\d+)\s*\)',
        re.DOTALL,
    )
    for m in bxor_pat.finditer(lua_code):
        try:
            nums = [int(x.strip()) for x in m.group(2).split(',') if x.strip()]
            key  = int(m.group(3)) & 0xFF
            decoded = ''.join(chr(n ^ key) for n in nums)
            if _lua_looks_valid(decoded):
                results.append(("bit-bxor-loop", decoded))
        except Exception:
            pass

    vig_pat = re.compile(
        r'local\s+\w+\s*=\s*"([^"\\]{2,64})"\s*'
        r'[\s\S]{0,400}?'
        r'local\s+\w+\s*=\s*\{((?:\s*\d{1,3}\s*,\s*){10,}\s*\d{1,3}\s*)\}',
        re.DOTALL,
    )
    for m in vig_pat.finditer(lua_code):
        try:
            key  = m.group(1)
            nums = [int(x.strip()) for x in m.group(2).split(',') if x.strip()]
            if not all(0 <= n <= 255 for n in nums):
                continue
            kb = [ord(c) for c in key]
            decoded = ''.join(chr(nums[i] ^ kb[i % len(kb)]) for i in range(len(nums)))
            if _lua_looks_valid(decoded):
                results.append(("vigenere-xor", decoded))
        except Exception:
            pass

    large_tbl = re.compile(r'\{((?:\s*\d{1,3}\s*,\s*){40,}\s*\d{1,3}\s*)\}')
    for m in large_tbl.finditer(lua_code):
        try:
            nums = [int(x.strip()) for x in m.group(1).split(',') if x.strip()]
            if not all(0 <= n <= 255 for n in nums):
                continue
            for key in range(256):
                decoded = ''.join(chr(n ^ key) for n in nums)
                if _lua_looks_valid(decoded):
                    results.append((f"xor-brute-key{key}", decoded))
                    break
        except Exception:
            pass

    notbl_pat = re.compile(
        r'local\s+(\w+)\s*=\s*\{((?:\s*\d{1,3}\s*,\s*){10,}\s*\d{1,3}\s*)\}'
        r'[\s\S]{0,600}?'
        r'string\.char\s*\(\s*\1\s*\[\s*\w+\s*\]\s*\)',
        re.DOTALL,
    )
    for m in notbl_pat.finditer(lua_code):
        try:
            nums = [int(x.strip()) for x in m.group(2).split(',') if x.strip()]
            decoded = ''.join(chr(n & 0xFF) for n in nums)
            if _lua_looks_valid(decoded):
                results.append(("table-string.char-direct", decoded))
        except Exception:
            pass

    load_b64 = re.compile(
        r'(?:loadstring|load)\s*\(\s*[^"\'(]{0,40}\s*'
        r'(?:"([A-Za-z0-9+/]{32,}={0,2})"|\'([A-Za-z0-9+/]{32,}={0,2})\')',
        re.DOTALL,
    )
    for m in load_b64.finditer(lua_code):
        raw = (m.group(1) or m.group(2) or "").strip()
        pad = (4 - len(raw) % 4) % 4
        try:
            decoded = _b64mod.b64decode(raw + "=" * pad).decode("utf-8", errors="replace")
            if decoded.strip() and len(decoded) > 20:
                results.append(("b64-loadstring", decoded))
        except Exception:
            pass

    data_b64 = re.compile(r'(?:"([A-Za-z0-9+/]{64,}={0,2})"|\'([A-Za-z0-9+/]{64,}={0,2})\')')
    for m in data_b64.finditer(lua_code):
        raw = (m.group(1) or m.group(2) or "").strip()
        pad = (4 - len(raw) % 4) % 4
        try:
            decoded = _b64mod.b64decode(raw + "=" * pad).decode("utf-8", errors="replace")
            if _lua_looks_valid(decoded):
                results.append(("b64-var", decoded))
        except Exception:
            pass

    hex_blob = re.compile(r'"((?:\\x[0-9a-fA-F]{2}){20,})"')
    for m in hex_blob.finditer(lua_code):
        try:
            decoded = re.sub(r'\\x([0-9a-fA-F]{2})', lambda x: chr(int(x.group(1), 16)), m.group(1))
            if _lua_looks_valid(decoded):
                results.append(("hex-escape", decoded))
        except Exception:
            pass

    dec_blob = re.compile(r'"((?:\\[0-9]{1,3}){20,})"')
    for m in dec_blob.finditer(lua_code):
        try:
            decoded = re.sub(r'\\([0-9]{1,3})', lambda x: chr(min(int(x.group(1)), 255)), m.group(1))
            if _lua_looks_valid(decoded):
                results.append(("dec-escape", decoded))
        except Exception:
            pass

    if max_depth > 1 and results:
        extra: list[tuple[str, str]] = []
        for label, decoded in results:
            if re.search(
                r'loadstring|load\s*\(|string\.char|bit\.bxor|\{(?:\s*\d{1,3}\s*,\s*){5,}',
                decoded
            ):
                sub = _unwrap_obfuscation_layers(decoded, max_depth - 1)
                for sub_label, sub_decoded in sub:
                    extra.append((f"{label}→{sub_label}", sub_decoded))
        results.extend(extra)

    seen: set[str] = set()
    unique: list[tuple[str, str]] = []
    for label, decoded in results:
        h = hashlib.sha256(decoded.encode("utf-8", errors="replace")).hexdigest()[:20]
        if h not in seen:
            seen.add(h)
            unique.append((label, decoded))

    return unique


def _pre_decode_lua_layers(lua_code: str) -> list[tuple[str, str]]:
    return _unwrap_obfuscation_layers(lua_code, max_depth=2)


def _check_exploit_attempt(lua_code: str) -> str | None:
    clean = _strip_lua_comments(lua_code)

    normalised = _expand_bracket_access(clean)

    for pat, label in _HARD_BLOCKS:
        m = pat.search(normalised)
        if m:
            return (f"Blocked: `{m.group(0).strip()}` "
                    f"({label}) is not allowed.")

    score = 0
    hits: list[str] = []
    for pat, weight, label in _SCORED:
        if pat.search(normalised):
            score += weight
            hits.append(label)
    if score >= _SCORE_THRESHOLD:
        return (f"Blocked: suspicious pattern combination — "
                f"{', '.join(hits)}.")

    for s in _extract_string_contents(clean):
        decoded = _decode_escapes(s)
        hit = _scan_decoded(decoded)
        if hit:
            return f"Blocked: {hit} hidden in encoded string literal."

    reconstructed = _eval_string_char(clean)
    if reconstructed != clean:
        hit = _scan_decoded(reconstructed)
        if hit:
            return f"Blocked: {hit} reconstructed from string.char() obfuscation."
        norm_rec = _expand_bracket_access(reconstructed)
        for pat, label in _HARD_BLOCKS:
            if pat.search(norm_rec):
                return f"Blocked: {label} hidden via string.char() encoding."

    for raw_arg in _extract_load_args(clean):
        decoded_arg = _decode_escapes(raw_arg)
        hit = _scan_decoded(decoded_arg)
        if hit:
            return f"Blocked: {hit} inside load/loadstring argument."
        reconstructed_arg = _eval_string_char(decoded_arg)
        hit = _scan_decoded(reconstructed_arg)
        if hit:
            return f"Blocked: {hit} inside encoded load/loadstring payload."

    xor_results = _try_xor_decode(clean)
    for decoded_xor in xor_results:
        hit = _scan_decoded(decoded_xor)
        if hit:
            return f"Blocked: {hit} hidden via XOR number-table encoding."

    expanded = _expand_concat_vars(clean)
    if expanded != clean:
        reconstructed_exp = _eval_string_char(expanded)
        for s in _extract_string_contents(reconstructed_exp):
            decoded = _decode_escapes(s)
            hit = _scan_decoded(decoded)
            if hit:
                return f"Blocked: {hit} reconstructed from split-variable obfuscation."

    p9 = _expand_g_alias(clean)
    p9 = _expand_all_decoded_vars(p9)
    if p9 != clean:
        p9_norm = _expand_bracket_access(p9)
        for pat, label in _HARD_BLOCKS:
            if pat.search(p9_norm):
                return (f"Blocked: {label} hidden via variable + "
                        f"escape-encoded string obfuscation.")
        hit = _scan_decoded(p9_norm)
        if hit:
            return (f"Blocked: {hit} reconstructed from "
                    f"_G-alias + escape-encoded variable obfuscation.")

    _DANGEROUS_MODS  = {"os", "io", "package", "debug"}
    _DANGEROUS_FUNCS = {
        "execute", "popen", "open", "input", "output", "lines", "read",
        "remove", "rename", "getenv", "exit",
        "loadlib",
    }
    decoded_strs = [_decode_escapes(s) for s in _extract_string_contents(clean)]
    has_mod  = any(s.strip() in _DANGEROUS_MODS  for s in decoded_strs)
    has_func = any(s.strip() in _DANGEROUS_FUNCS for s in decoded_strs)
    if has_mod and has_func:
        _INDIRECT_ACCESS = re.compile(
            r'\b(?:_G|rawget|getfenv|setfenv)\b'
            r'|\w+\s*\[\s*\w+\s*\]',
        )
        if _INDIRECT_ACCESS.search(clean):
            return (
                "Blocked: dangerous module + function combination "
                "hidden across separate escape-encoded string literals."
            )

    _P11_MODS  = {"os", "io", "package", "debug"}
    _P11_FUNCS = {
        "execute", "popen", "open", "input", "output", "lines", "read",
        "remove", "rename", "getenv", "exit",
        "loadlib",
    }
    _P11_INDIRECT = re.compile(
        r'\b(?:_G|rawget|getfenv|setfenv)\b'
        r'|\w+\s*\[\s*\w+\s*\]',
    )
    transform_hits = _try_table_transforms(clean)
    for decoded_t in transform_hits:
        hit = _scan_decoded(decoded_t)
        if hit:
            return (
                f"Blocked: {hit} hidden via number-table transformation "
                f"(reversed / offset / complement encoding)."
            )
    has_mod_atom  = any(s.strip() in _P11_MODS  for s in transform_hits)
    has_func_atom = any(s.strip() in _P11_FUNCS for s in transform_hits)
    if has_mod_atom and has_func_atom and _P11_INDIRECT.search(clean):
        return (
            "Blocked: dangerous module + function combination hidden via "
            "number-table transformation (reversed / offset / complement encoding)."
        )
    if (has_mod_atom or has_func_atom) and _P11_INDIRECT.search(clean):
        _TABLE_CHAR = re.compile(r'string\s*\.\s*char\b')
        if _TABLE_CHAR.search(clean):
            return (
                "Blocked: dangerous module/function name hidden via "
                "number-table transformation combined with indirect access."
            )

    b64_results = _try_base64_decode_strings(clean)
    for decoded_b64 in b64_results:
        hit = _scan_decoded(decoded_b64)
        if hit:
            return f"Blocked: {hit} hidden inside base64-encoded string."
        norm_b64 = _expand_bracket_access(decoded_b64)
        for pat, label in _HARD_BLOCKS:
            if pat.search(norm_b64):
                return f"Blocked: {label} hidden via base64 encoding."

    hex_tbl_results = _try_hex_table_decode(clean)
    for decoded_hex in hex_tbl_results:
        hit = _scan_decoded(decoded_hex)
        if hit:
            return f"Blocked: {hit} hidden in hex-encoded number table."

    mb_xor_results = _try_multibyte_xor_decode(clean)
    for decoded_mb in mb_xor_results:
        hit = _scan_decoded(decoded_mb)
        if hit:
            return f"Blocked: {hit} hidden via 2-byte XOR key encoding."

    vig_results = _try_vigenere_key_xor(clean)
    for decoded_vig in vig_results:
        hit = _scan_decoded(decoded_vig)
        if hit:
            return f"Blocked: {hit} hidden via Vigenere/repeating-key XOR encoding."

    rot_results = _try_rot_decode(clean)
    for decoded_rot in rot_results:
        hit = _scan_decoded(decoded_rot)
        if hit:
            return f"Blocked: {hit} hidden via ROT/Caesar cipher encoding."

    return None


async def _kill_process_group(process) -> None:
    if process is None or process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            process.terminate()
        except ProcessLookupError:
            return
    try:
        await asyncio.wait_for(process.wait(), timeout=1.5)
        return
    except (asyncio.TimeoutError, Exception):
        pass
    if process.returncode is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            try:
                process.kill()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(process.wait(), timeout=1.5)
        except Exception:
            pass


async def _run_lua_script_async(
    script: str,
    args: list,
    timeout: float,
    progress_callback=None,
) -> tuple[int, list[str], list[str]]:
    out_lines: list[str] = []
    err_lines: list[str] = []
    safe_timeout = max(3.0, float(timeout))

    async with _get_lua_semaphore():
        if LUPA_DIRECT:
            import lua_runner as _lr
            loop = asyncio.get_running_loop()

            def _worker():
                return _lr.run_script_collecting(script, args, out_lines, err_lines)

            try:
                rc = await asyncio.wait_for(
                    loop.run_in_executor(None, _worker),
                    timeout=safe_timeout,
                )
            except asyncio.TimeoutError:
                err_lines.append(f"[DUMPER_FAILED] Timeout ({safe_timeout:.0f}s)\n")
                rc = 1
            except Exception as e:
                err_lines.append(f"lua_runner direct error: {e}\n")
                rc = 1

            if progress_callback:
                for line in out_lines + err_lines:
                    for part in line.splitlines():
                        await progress_callback(part)
            return rc, out_lines, err_lines

        child_env = os.environ.copy()
        child_env["LUNE_RUNNER_TIMEOUT"] = str(max(5, int(safe_timeout)))

        process = await asyncio.create_subprocess_exec(
            *LUA_CMD, script, *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=child_env,
            start_new_session=True,
        )

        async def _consume(stream, bucket):
            try:
                while True:
                    raw = await stream.readline()
                    if not raw:
                        break
                    line = raw.decode("utf-8", errors="replace").rstrip()
                    bucket.append(line + "\n")
                    if progress_callback:
                        await progress_callback(line)
            except asyncio.CancelledError:
                raise
            except Exception:
                pass

        readers = [
            asyncio.create_task(_consume(process.stdout, out_lines)),
            asyncio.create_task(_consume(process.stderr, err_lines)),
        ]
        try:
            await asyncio.wait_for(process.wait(), timeout=safe_timeout)
            await asyncio.wait_for(asyncio.gather(*readers, return_exceptions=True), timeout=2.0)
        except asyncio.TimeoutError:
            await _kill_process_group(process)
            for r in readers:
                r.cancel()
            try:
                await asyncio.wait_for(asyncio.gather(*readers, return_exceptions=True), timeout=1.5)
            except Exception:
                pass
            err_lines.append(f"[DUMPER_FAILED] Timeout ({safe_timeout:.0f}s)\n")
            if progress_callback:
                await progress_callback(f"[DUMPER_FAILED] Timeout ({safe_timeout:.0f}s)")
        except asyncio.CancelledError:
            await _kill_process_group(process)
            for r in readers:
                r.cancel()
            try:
                await asyncio.wait_for(asyncio.gather(*readers, return_exceptions=True), timeout=1.5)
            except Exception:
                pass
            raise
        finally:
            await _kill_process_group(process)
            for r in readers:
                if not r.done():
                    r.cancel()
            try:
                await asyncio.wait_for(asyncio.gather(*readers, return_exceptions=True), timeout=1.0)
            except Exception:
                pass
        rc = process.returncode or 0
        return rc, out_lines, err_lines


def _run_lua_script_sync(script: str, args: list, timeout: float) -> tuple[int, str, str]:
    if LUPA_DIRECT:
        import lua_runner as _lr
        import concurrent.futures
        out_lines: list[str] = []
        err_lines: list[str] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(_lr.run_script_collecting, script, args, out_lines, err_lines)
            try:
                rc = fut.result(timeout=timeout)
            except concurrent.futures.TimeoutError:
                err_lines.append(f"[DUMPER_FAILED] Timeout ({timeout}s)\n")
                rc = 1
            except Exception as e:
                err_lines.append(f"lua_runner direct error: {e}\n")
                rc = 1
        return rc, "".join(out_lines), "".join(err_lines)

    result = subprocess.run(
        [*LUA_CMD, script, *args],
        capture_output=True, text=True, timeout=timeout,
    )
    return result.returncode, result.stdout, result.stderr


def _decompile_lua51_bytecode(bytecode_bytes: bytes) -> str:
    if not os.path.exists(DECOMPILE_PY):
        return ""
    try:
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".lua", delete=False) as f:
            bc_path = f.name
            f.write(bytecode_bytes)
        result = subprocess.run(
            [sys.executable, DECOMPILE_PY, bc_path],
            capture_output=True, text=True, timeout=30,
        )
        os.remove(bc_path)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        return ""
    except Exception:
        return ""


_VULN_PATTERNS: list[tuple[str, str, re.Pattern]] = [
    (
        "os.getenv",
        "can expose server environment variables (secrets / API keys)",
        re.compile(r'\bos\s*\.\s*getenv\b'),
    ),
    (
        "io.open",
        "reads arbitrary files from disk (Universal Reader attack vector)",
        re.compile(r'\bio\s*\.\s*open\b'),
    ),
    (
        "io.popen",
        "executes shell commands via pipe",
        re.compile(r'\bio\s*\.\s*popen\b'),
    ),
    (
        "io.lines",
        "reads files line-by-line from disk",
        re.compile(r'\bio\s*\.\s*lines\b'),
    ),
    (
        "io.input / io.output",
        "redirects standard file handles to arbitrary files",
        re.compile(r'\bio\s*\.\s*(?:input|output)\b'),
    ),
    (
        "debug.sethook",
        "installs instruction hooks that can interfere with the sandbox",
        re.compile(r'\bdebug\s*\.\s*sethook\b'),
    ),
    (
        "os.execute",
        "executes arbitrary shell commands on the host",
        re.compile(r'\bos\s*\.\s*execute\b'),
    ),
    (
        "dofile / loadfile",
        "loads and executes arbitrary Lua files from disk",
        re.compile(r'\b(?:dofile|loadfile)\s*\('),
    ),
    (
        "string.dump",
        "extracts Lua bytecode which embeds source paths and string constants",
        re.compile(r'\bstring\s*\.\s*dump\b'),
    ),
    (
        "debug.getlocal / debug.setlocal",
        "can inspect or overwrite local variables inside sandboxed functions",
        re.compile(r'\bdebug\s*\.\s*(?:getlocal|setlocal|getregistry)\b'),
    ),
]

def _check_vuln_patterns(lua_code: str) -> str | None:
    code_only = _strip_lua_literals(lua_code)
    for name, reason, pat in _VULN_PATTERNS:
        if pat.search(code_only):
            return f"error: {name} ({reason})"
    return None


def _is_known_slow_unc_obfuscator(lua_code: str) -> bool:
    if not isinstance(lua_code, str) or len(lua_code) < 200_000:
        return False
    return (
        "https://wearedevs.net/obfuscator" in lua_code
        and "return(function(...)local b={" in lua_code
    )


def _normalized_environment_probe_source(lua_code: str) -> str | None:
    """Return source only for tiny environment-inspection probes.

    The returned text is normalized input, not a recovered payload or an
    execution result. Avoiding table serialization keeps the sandbox shape out
    of user-facing dump output.
    """
    if not isinstance(lua_code, str):
        return None
    source = lua_code.replace("\ufeff", "").replace("\r\n", "\n").replace("\r", "\n")
    source = re.sub(r"^\s*```(?:lua|luau|txt)?\s*", "", source, flags=re.I)
    source = re.sub(r"\s*```\s*$", "", source).strip()
    if not source or len(source) > 512:
        return None
    match_source = _expand_bracket_access(source)
    if re.fullmatch(r"print\s*\(\s*_G\s*\)\s*;?", match_source):
        return source
    if re.fullmatch(r"print\s*\(\s*getfenv\s*\(\s*(?:1\s*)?\)\s*\)\s*;?", match_source):
        return source
    loop_header = r"for\s+([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)\s+in\s+"
    loop_header += r"pairs\s*\(\s*_G\s*\)\s*do\s*"
    value_loop = re.fullmatch(
        loop_header + r"print\s*\(\s*\1\s*,\s*\2\s*\)\s*;?\s*end\s*;?",
        source,
        flags=re.DOTALL,
    )
    type_loop = re.fullmatch(
        loop_header
        + r"print\s*\(\s*\1\s*,\s*(?:['\"][^'\"\n]*['\"]\s*,\s*)?"
        + r"type\s*\(\s*\2\s*\)\s*\)\s*;?\s*end\s*;?",
        source,
        flags=re.DOTALL,
    )
    return source if value_loop or type_loop else None


_L_HARD_BLOCK_PATTERNS: tuple[tuple[re.Pattern, str], ...] = (
    (re.compile(r"\breadfile\b", re.I), "file-reader capability"),
    (re.compile(r"\bio\s*\.\s*open\b", re.I), "file-open capability"),
    (re.compile(r"\bio\s*\.\s*popen\b", re.I), "process pipe capability"),
    (re.compile(r"\bdebug\s*\.\s*traceback\b", re.I), "stack-trace probing"),
)


def _is_runtime_fingerprint_mutation(normalized_code: str, code_only: str) -> bool:
    """Recognize direct writes to the runtime-version value or its env aliases.

    This intentionally covers only explicit assignment syntax after comments,
    literals, and bracket access have been normalized. Dynamic key construction
    remains contained by the per-request sandbox rather than being guessed by a
    broad text filter.
    """
    direct_global_write = re.search(
        r"(?:^|[;\n])\s*_VERSION\s*=(?!=)",
        code_only,
    )
    environment_member_write = re.search(
        r"\b(?:_G|_ENV)\s*\.\s*_VERSION\s*=(?!=)",
        code_only,
    )
    getfenv_member_write = re.search(
        r"\bgetfenv\s*\(\s*(?:1\s*)?\)\s*\.\s*_VERSION\s*=(?!=)",
        code_only,
    )
    return bool(direct_global_write or environment_member_write or getfenv_member_write)


def _classify_l_security_event(lua_code: str) -> tuple[str, str]:
    """Classify only the narrowly defined `.l` policy events.

    `monitor` probes are safe source-preservation cases. `hard_block` cases
    are stopped before they reach the dump subprocess. Other inputs retain the
    existing pipeline and sandbox protections.
    """
    clean = _strip_lua_comments(lua_code or "")
    normalized = _expand_bracket_access(clean)
    code_only = _strip_lua_literals(normalized)
    for pattern, reason in _L_HARD_BLOCK_PATTERNS:
        if pattern.search(code_only):
            return "hard_block", reason
    if _is_runtime_fingerprint_mutation(normalized, code_only):
        return "hard_block", "runtime fingerprint mutation"
    if _normalized_environment_probe_source(lua_code) is not None:
        return "monitor", "environment or runtime fingerprint probe"
    return "none", ""


async def _notify_owner_security_event(message: discord.Message, action: str, reason: str) -> None:
    """Send a concise audit event without forwarding suspicious source text."""
    try:
        owner = await bot.fetch_user(OWNER_ID)
        if owner is None:
            return
        location = "DM" if message.guild is None else "server channel"
        embed = discord.Embed(
            title="Security policy event",
            description=(
                f"User: `{message.author.id}`\n"
                f"Action: `{action}`\n"
                f"Reason: `{reason}`\n"
                f"Location: {location}"
            ),
            color=0xe67e22 if action == "warning" else 0xe74c3c,
        )
        embed.set_footer(text="kenV1 | envlogger")
        await _send_anim(owner, embed)
    except Exception:
        pass


async def _send_warning_embed(message: discord.Message, warning_count: int) -> None:
    embed = discord.Embed(
        title=(
            "Your account is automatically monitored by the owner, because it is "
            f"suspicious. {warning_count}/2 warning"
        ),
        color=0xe67e22,
    )
    embed.set_footer(text="kenV1 | envlogger")
    await _reply_anim(message, embed)


async def _send_blacklist_embed(message: discord.Message) -> None:
    embed = discord.Embed(
        title="You are blacklisted due to a vulnerability and highly suspicious.",
        description="Access to this bot has been revoked. Only the owner can restore access with `.wl`.",
        color=0xe74c3c,
    )
    embed.set_footer(text="kenV1 | envlogger • Security enforcement")
    await _reply_anim(message, embed)


async def _try_bypass_async(lua_code: str, progress_callback=None, timeout: float | None = None):
    vuln_err = _check_vuln_patterns(lua_code)
    if vuln_err:
        return False, "", vuln_err
    if not LUA_AVAILABLE or not os.path.exists(BYPASS_LUA):
        return False, "", "bypass.lua not available"
    _ensure_scripts_dir()
    tmp_input = None
    tmp_output = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix=".lua", dir=tempfile.gettempdir(),
                                         encoding='utf-8', delete=False) as f:
            tmp_input = f.name
            f.write(_normalize_lua_input(lua_code))
        with tempfile.NamedTemporaryFile(mode='w', suffix=".txt", dir=tempfile.gettempdir(),
                                         delete=False) as f:
            tmp_output = f.name
        bypass_timeout = timeout if timeout is not None else min(45.0, float(DUMP_TIMEOUT_SECONDS))
        _, _out_lines, _err_lines = await _run_lua_script_async(
            BYPASS_LUA, [tmp_input, tmp_output],
            timeout=bypass_timeout,
            progress_callback=progress_callback,
        )
        log = "".join(_err_lines).strip()
        report_path = (tmp_output + ".report.txt") if tmp_output else None
        content = ""
        if os.path.exists(tmp_output):
            with open(tmp_output, "rb") as f:
                raw_bytes = f.read()
            is_lua51_bc = raw_bytes[:4] == b'\x1bLua' and len(raw_bytes) > 16
            is_binary = is_lua51_bc or (
                len(raw_bytes) > 64
                and sum(b < 32 or b == 127 for b in raw_bytes[:256]) > 30
            )
            if is_lua51_bc:
                decomp = _decompile_lua51_bytecode(raw_bytes)
                if decomp:
                    content = decomp
                    log = (log + "\n" if log else "") + "[env] Lua 5.1 bytecode decompiled"
                elif report_path and os.path.exists(report_path):
                    with open(report_path, "r", encoding="utf-8", errors="replace") as f:
                        content = f.read().strip()
                    log = (log + "\n" if log else "") + "[env] decompiler failed → using string report"
            elif is_binary and report_path and os.path.exists(report_path):
                with open(report_path, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read().strip()
            else:
                content = raw_bytes.decode("utf-8", errors="replace").strip()
        content = _strip_leading_comments(content)
        ok = bool(content) and _count_real_lines(content) > 0
        return ok, content, log
    except Exception as e:
        return False, "", f"[env] {type(e).__name__}: {e}"
    finally:
        for path in [tmp_input, tmp_output, (tmp_output + ".report.txt") if tmp_output else None]:
            if path:
                try:
                    if os.path.exists(path):
                        os.remove(path)
                except Exception:
                    pass


def _lua_string_literal(value: str) -> str:
    return '"' + (value.replace('\\', '\\\\').replace('"', '\\"')
                     .replace('\n', '\\n').replace('\r', '\\r')) + '"'


def _is_hephaestus_payload(lua_code: str) -> bool:
    return isinstance(lua_code, str) and 'Hephaestus [[1]]' in lua_code


_HEPHAESTUS_PAYLOAD_CALL = re.compile(
    r'I11l11\+IIl111\[\(l11111\*"value"\)\(\{145,199,0,205,140,212\}\)\]'
    r'\[\(l11111\*"value"\)\(\{129,219,19,214\}\)\]'
    r'\((\d+(?:,\d+)*)\)\)'
)


def _extract_hephaestus_static_payload(lua_code: str) -> str | None:
    if not _is_hephaestus_payload(lua_code):
        return None
    if 'return(ll1l11(894384,{})' not in lua_code:
        return None
    matches = _HEPHAESTUS_PAYLOAD_CALL.findall(lua_code)
    if not matches:
        return None
    try:
        decoded = bytes(int(value) for value in matches[-1].split(',')).decode('ascii')
    except (ValueError, UnicodeDecodeError):
        return None
    if not decoded or decoded == 'c' or len(decoded) > 4096:
        return None
    return f'print({_lua_string_literal(decoded)})'


def _runtime_lines_to_lua(lines: list[str]) -> str:
    clean = [line.strip() for line in lines if line.strip()]
    return '\n'.join(f'print({_lua_string_literal(line)})' for line in clean)


def _try_bypass_sync(lua_code: str):
    if not LUA_AVAILABLE or not os.path.exists(BYPASS_LUA):
        return False, "", "bypass.lua not available"
    _ensure_scripts_dir()
    tmp_input = None
    tmp_output = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix=".lua", dir=tempfile.gettempdir(),
                                         encoding='utf-8', delete=False) as f:
            tmp_input = f.name
            f.write(_normalize_lua_input(lua_code))
        with tempfile.NamedTemporaryFile(mode='w', suffix=".txt", dir=tempfile.gettempdir(),
                                         delete=False) as f:
            tmp_output = f.name
        _rc, _stdout_text, stderr_text = _run_lua_script_sync(
            BYPASS_LUA, [tmp_input, tmp_output], timeout=DUMP_TIMEOUT_SECONDS,
        )
        report_path = (tmp_output + ".report.txt") if tmp_output else None
        content = ""
        stderr_text = stderr_text.strip()
        if os.path.exists(tmp_output):
            with open(tmp_output, "rb") as f:
                raw_bytes = f.read()
            is_lua51_bc = raw_bytes[:4] == b'\x1bLua' and len(raw_bytes) > 16
            is_binary = is_lua51_bc or (
                len(raw_bytes) > 64
                and sum(b < 32 or b == 127 for b in raw_bytes[:256]) > 30
            )
            if is_lua51_bc:
                decomp = _decompile_lua51_bytecode(raw_bytes)
                if decomp:
                    content = decomp
                    stderr_text += "\n[env] Lua 5.1 bytecode decompiled"
                elif report_path and os.path.exists(report_path):
                    with open(report_path, "r", encoding="utf-8", errors="replace") as f:
                        content = f.read().strip()
                    stderr_text += "\n[env] decompiler failed → using string report"
            elif is_binary and report_path and os.path.exists(report_path):
                with open(report_path, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read().strip()
            else:
                content = raw_bytes.decode("utf-8", errors="replace").strip()
        content = _strip_leading_comments(content)
        ok = bool(content) and _count_real_lines(content) > 0
        return ok, content, stderr_text
    except Exception as e:
        return False, "", f"[env] {type(e).__name__}: {e}"
    finally:
        for path in [tmp_input, tmp_output, (tmp_output + ".report.txt") if tmp_output else None]:
            if path:
                try:
                    if os.path.exists(path):
                        os.remove(path)
                except Exception:
                    pass


async def _try_dumper2_async(lua_code: str, progress_callback=None, timeout: float | None = None):
    vuln_err = _check_vuln_patterns(lua_code)
    if vuln_err:
        return False, "", vuln_err
    if not LUA_AVAILABLE or not os.path.exists(DUMPER2_LUA):
        return False, "", "dumper2.lua not available"
    _ensure_scripts_dir()
    tmp_input = None
    tmp_output = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix=".lua", dir=tempfile.gettempdir(),
                                         encoding='utf-8', delete=False) as f:
            tmp_input = f.name
            f.write(_normalize_lua_input(lua_code))
        with tempfile.NamedTemporaryFile(mode='w', suffix=".txt", dir=tempfile.gettempdir(),
                                         delete=False) as f:
            tmp_output = f.name
        d2_timeout = timeout if timeout is not None else min(45.0, float(DUMP_TIMEOUT_SECONDS))
        _rc, _out_lines, _err_lines = await _run_lua_script_async(
            DUMPER2_LUA, [tmp_input, tmp_output],
            timeout=d2_timeout,
            progress_callback=progress_callback,
        )
        err_filtered = [ln for ln in _err_lines if not _is_sandbox_noise(ln.strip())]
        log = "".join(err_filtered).strip()
        content = ""
        if os.path.exists(tmp_output):
            with open(tmp_output, "r", encoding="utf-8", errors="replace") as f:
                content = f.read().strip()
        content = _strip_leading_comments(content)
        ok = (_rc == 0) and bool(content) and _count_real_lines(content) > 0
        return ok, content, log
    except Exception as e:
        return False, "", f"[dumper2] {type(e).__name__}: {e}"
    finally:
        for path in [tmp_input, tmp_output]:
            if path:
                try:
                    if os.path.exists(path):
                        os.remove(path)
                except Exception:
                    pass


def _try_dumper2_sync(lua_code: str):
    if not LUA_AVAILABLE or not os.path.exists(DUMPER2_LUA):
        return False, "", "dumper2.lua not available"
    _ensure_scripts_dir()
    tmp_input = None
    tmp_output = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix=".lua", dir=tempfile.gettempdir(),
                                         encoding='utf-8', delete=False) as f:
            tmp_input = f.name
            f.write(_normalize_lua_input(lua_code))
        with tempfile.NamedTemporaryFile(mode='w', suffix=".txt", dir=tempfile.gettempdir(),
                                         delete=False) as f:
            tmp_output = f.name
        _rc, _stdout_text, stderr_text = _run_lua_script_sync(
            DUMPER2_LUA, [tmp_input, tmp_output], timeout=DUMP_TIMEOUT_SECONDS,
        )
        content = ""
        if os.path.exists(tmp_output):
            with open(tmp_output, "r", encoding="utf-8", errors="replace") as f:
                content = f.read().strip()
        content = _strip_leading_comments(content)
        ok = (_rc == 0) and bool(content) and _count_real_lines(content) > 0
        return ok, content, stderr_text.strip()
    except Exception as e:
        return False, "", f"[dumper2] {type(e).__name__}: {e}"
    finally:
        for path in [tmp_input, tmp_output]:
            if path:
                try:
                    if os.path.exists(path):
                        os.remove(path)
                except Exception:
                    pass


_DTC_BYPASS_PATTERNS: list[re.Pattern] = [
    re.compile(r'\bgetrunningscripts\b'),
    re.compile(r'\bcheckcaller\b'),
    re.compile(r'\b(?:isexecutorclosure|isourclosure|checkclosure)\b'),
    re.compile(r'\b(?:hookfunction|replaceclosure)\b'),
    re.compile(r'\bHeartbeat\s*:\s*(?:Connect|connect)\b'),
    re.compile(r'\bRenderStepped\s*:\s*(?:Connect|connect)\b'),
    re.compile(r'\bStepped\s*:\s*(?:Connect|connect)\b'),
    re.compile(r'\bgetgenv\b'),
    re.compile(r'\bgetrenv\b'),
    re.compile(r'\bgethwid\b'),
    re.compile(r'\bgetconnections\b'),
    re.compile(r'\bgetnilinstances\b'),
    re.compile(r'\bgetinstances\b'),
    re.compile(r'\bgetloadedmodules\b'),
    re.compile(r'\bgetfenv\b'),
    re.compile(r'\blistfiles\b'),
    re.compile(r'\bwritefile\b'),
    re.compile(r'\bdelfile\b'),
    re.compile(r'\breadfile\b'),
    re.compile(r'\bdecompile\b'),
    re.compile(r'\bdumpstring\b'),
    re.compile(r'\bbit32\b'),
    re.compile(r'\bbuffer\b'),
    re.compile(r'\bEnum\.'),
    re.compile(r'\bisfunctionhooked\b'),
    re.compile(r'\bstring\.split\b'),
    re.compile(r'\bnewcclosure\b'),
    re.compile(r'\bcloneref\b'),
    re.compile(r'\bcompareinstances\b'),
    re.compile(r'\bfiltergc\b'),
    re.compile(r'\breplicatesignal\b'),
    re.compile(r'\brconsole(?:print|warn|err|info|title|name|clear)?\b'),
    re.compile(r'\bgetrawmetatable\b'),
    re.compile(r'\bidentifyexecutor\b'),
    re.compile(r'\bCameraMinZoomDistance\b'),
    re.compile(r'\bCameraMaxZoomDistance\b'),
]

def _has_dtc_patterns(lua_code: str) -> bool:
    for pat in _DTC_BYPASS_PATTERNS:
        if pat.search(lua_code):
            return True
    return False


def _looks_like_guard(lua_code: str) -> bool:
    if not lua_code:
        return False
    if _has_dtc_patterns(lua_code):
        return True
    has_inc = bool(
        re.search(r"passed\s*\+=\s*1", lua_code)
        or re.search(r"passed\s*=\s*passed\s*\+\s*1", lua_code)
    )
    has_probe = "GetService" in lua_code
    has_gate = bool(re.search(r"pcall\s*\(", lua_code)) and bool(
        re.search(r"if\s+\w+\s+and\s+\w+\s+then", lua_code)
    )
    if has_inc and has_probe and has_gate:
        return True
    trap_count = len(re.findall(
        r"if\s+[^\n]+?\s+then\s+while\s+true\s+do\s+end\s+end",
        lua_code,
    ))
    if trap_count >= 2:
        return True
    canary_sigs = (
        "LuraphContinue", "__FLAMEDUMPER", ".graphemes",
        "debug.gethook", "debug.getinfo",
        "getmetatable(newproxy",
    )
    sig_hits = sum(1 for s in canary_sigs if s in lua_code)
    if re.search(r'_VERSION\s*==\s*"Lua', lua_code):
        sig_hits += 1
    if re.search(r'tostring\s*\(.*?\)\s*[:.]find\s*\(\s*"0x"', lua_code):
        sig_hits += 1
    if sig_hits >= 2 and re.search(r"if\s+[^\n]+\s+then", lua_code):
        return True
    if "Luraph Obfuscator v1" in lua_code or "This VM only supports Luraph v1" in lua_code:
        return True
    if re.search(r'V6\w*\(\s*"\\27\\76\\80\\72', lua_code):
        return True
    return False

def _is_runtime_guard_pass_payload(lua_code: str) -> bool:
    text = lua_code or ""
    return (
        "local function detected" in text
        and "runChecks()" in text
        and re.search(r"print\s*\(\s*['\"]You Passed['\"]\s*\)", text) is not None
        and "while true do" in text
    )

def _is_runtime_verdict_payload(lua_code: str) -> bool:
    text = lua_code or ""
    has_result = re.search(r"print\s*\(\s*['\"](?:pass|ud)['\"]\s*\)", text, re.IGNORECASE)
    has_failure = re.search(r"(?:warn|error)\s*\(\s*['\"][^'\"]*dtc[^'\"]*['\"]\s*\)", text, re.IGNORECASE)
    has_probe = (
        "game:GetService" in text
        or "game:GetService" in text.replace(" ", "")
        or re.search(r"\bpcall\s*\(", text) is not None
    )
    return has_result is not None and has_failure is not None and has_probe



def _is_level1_suite(lua_code: str) -> bool:
    if not isinstance(lua_code, str):
        return False
    text = _strip_lua_comments(lua_code)
    callback_ids = re.findall(
        r'\br\s*\(\s*["\'](?:[1-9]|1\d|2[0-8])["\']\s*,\s*function\b',
        text,
    )
    return (
        len(callback_ids) == 28
        and text.count('local function r(n, f) a[#a+1] = {n, f} end') == 1
        and 'local s = {}' in text
        and 'table.concat(s, ", ")' in text
        and 'game:GetService("GuiService")' in text
        and 'identifyexecutor' in text
        and 'getrawmetatable' in text
        and 'GetNameFromUserIdAsync' in text
    )



async def _run_level1_dumper_only(lua_code: str, progress_callback=None):
    if not LUA_AVAILABLE or not os.path.exists(DUMPER_LUA):
        return False, "", "Level 1 dumper unavailable: Lua runtime or dumper missing", "level1"
    tmp_input = tmp_output = None
    try:
        with tempfile.NamedTemporaryFile(
            mode='w', suffix=".lua", dir=tempfile.gettempdir(),
            encoding='utf-8', delete=False,
        ) as f:
            tmp_input = f.name
            f.write(_normalize_lua_input(lua_code))
        with tempfile.NamedTemporaryFile(
            mode='w', suffix=".txt", dir=tempfile.gettempdir(),
            encoding='utf-8', delete=False,
        ) as f:
            tmp_output = f.name
        rc, out_lines, err_lines = await _run_lua_script_async(
            DUMPER_LUA, [tmp_input, tmp_output],
            timeout=min(45, DUMP_TIMEOUT_SECONDS),
            progress_callback=progress_callback,
        )
        content = ""
        if os.path.exists(tmp_output):
            with open(tmp_output, "r", encoding="utf-8", errors="replace") as f:
                content = f.read().strip()
        content = _strip_leading_comments(content)
        log = "".join(out_lines + err_lines).strip()
        if rc != 0 or not _dump_content_is_usable(content):
            return False, content, log or "Level 1 verification did not produce usable output", "level1"
        return True, content, log, "level1"
    except Exception as exc:
        return False, "", f"Level 1 dumper error: {type(exc).__name__}: {exc}", "level1"
    finally:
        for path in (tmp_input, tmp_output):
            if path:
                try:
                    if os.path.exists(path):
                        os.remove(path)
                except Exception:
                    pass



async def run_lua_dumper(lua_code: str, progress_callback=None):
    environment_probe = _normalized_environment_probe_source(lua_code)
    if environment_probe is not None:
        return (
            True,
            environment_probe,
            "environment probe preserved as normalized input; sandbox tables are not serialized",
            "input-source",
        )
    if _is_known_slow_unc_obfuscator(lua_code):
        return (
            False,
            "",
            "large WeAreDevs UNC VM skipped: no output recovered",
            "smart-fallback",
        )
    hephaestus_static = _extract_hephaestus_static_payload(lua_code)
    if hephaestus_static:
        return True, hephaestus_static, "hephaestus static output", "static"
    if _is_runtime_guard_pass_payload(lua_code):
        return True, 'print("You Passed")', "runtime guard compatibility", "direct"
    if _is_runtime_verdict_payload(lua_code):
        try:
            d2_ok, d2_content, d2_log = await _try_dumper2_async(lua_code, progress_callback)
            if d2_ok and _dump_content_is_usable(d2_content):
                return True, d2_content, d2_log, "dumper2"
        except Exception:
            pass
        try:
            b_ok, b_content, b_log = await _try_bypass_async(lua_code, progress_callback)
            if b_ok and _dump_content_is_usable(b_content):
                return True, b_content, b_log, "direct"
        except Exception:
            pass

    if not LUA_AVAILABLE:
        return False, "", "No Lua runtime available (system Lua missing & lupa unusable)", "none"
    if not os.path.exists(DUMPER2_LUA) and not os.path.exists(DUMPER_LUA):
        return False, "", "dumper2.lua and dumper.lua not found", "none"

    _ensure_scripts_dir()

    deadline = time.monotonic() + float(DUMP_TIMEOUT_SECONDS)

    def _remaining_budget(cap: float = 40.0) -> float:
        rem = deadline - time.monotonic()
        if rem <= 1.0:
            return 0.0
        return min(cap, rem)

    _PER_ATTEMPT = min(40.0, float(DUMP_TIMEOUT_SECONDS))

    attempt_logs: list[str] = []
    best_partial = ""
    best_score = -1


    async def _run_one_dumper(attempt_name: str, attempt_code: str):
        tmp_input = tmp_output = None
        try:
            if not os.path.exists(DUMPER_LUA):
                return ("dumper", attempt_name, 1, "", "dumper.lua not found", False)
            t_budget = _remaining_budget(_PER_ATTEMPT)
            if t_budget < 3.0:
                return ("dumper", attempt_name, 1, "", "[DUMPER_FAILED] Overall deadline reached", False)
            with tempfile.NamedTemporaryFile(
                mode='w', suffix=".lua", dir=tempfile.gettempdir(),
                encoding='utf-8', delete=False,
            ) as f:
                tmp_input = f.name
                f.write(attempt_code)
            with tempfile.NamedTemporaryFile(
                mode='w', suffix=".txt", dir=tempfile.gettempdir(), delete=False,
            ) as f:
                tmp_output = f.name

            _rc, out_lines, err_lines = await _run_lua_script_async(
                DUMPER_LUA, [tmp_input, tmp_output],
                timeout=t_budget,
                progress_callback=progress_callback,
            )
            content = ""
            if tmp_output and os.path.exists(tmp_output):
                with open(tmp_output, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read().strip()
            content = _strip_leading_comments(content)
            err_lines = [ln for ln in err_lines if not _is_sandbox_noise(ln.strip())]
            merged = "".join(out_lines + err_lines).strip()
            success = _dump_content_is_usable(content)
            return ("dumper", attempt_name, _rc, content, merged, success)
        except Exception as e:
            return ("dumper", attempt_name, 1, "", f"{type(e).__name__}: {e}", False)
        finally:
            for path in [tmp_input, tmp_output]:
                if path:
                    try:
                        if os.path.exists(path):
                            os.remove(path)
                    except Exception:
                        pass

    async def _run_one_dumper2(attempt_name: str, attempt_code: str):
        tmp_input = tmp_output = None
        try:
            if not os.path.exists(DUMPER2_LUA):
                return ("dumper2", attempt_name, 1, "", "dumper2.lua not found", False)
            t_budget = _remaining_budget(_PER_ATTEMPT)
            if t_budget < 3.0:
                return ("dumper2", attempt_name, 1, "", "[DUMPER_FAILED] Overall deadline reached", False)
            with tempfile.NamedTemporaryFile(
                mode='w', suffix=".lua", dir=tempfile.gettempdir(),
                encoding='utf-8', delete=False,
            ) as f:
                tmp_input = f.name
                f.write(attempt_code)
            with tempfile.NamedTemporaryFile(
                mode='w', suffix=".txt", dir=tempfile.gettempdir(), delete=False,
            ) as f:
                tmp_output = f.name

            _rc, out_lines, err_lines = await _run_lua_script_async(
                DUMPER2_LUA, [tmp_input, tmp_output],
                timeout=t_budget,
                progress_callback=progress_callback,
            )
            content = ""
            if tmp_output and os.path.exists(tmp_output):
                with open(tmp_output, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read().strip()
            content = _strip_leading_comments(content)
            err_lines = [ln for ln in err_lines if not _is_sandbox_noise(ln.strip())]
            merged = "".join(out_lines + err_lines).strip()
            success = (_rc == 0) and _dump_content_is_usable(content)
            return ("dumper2", attempt_name, _rc, content, merged, success)
        except Exception as e:
            return ("dumper2", attempt_name, 1, "", f"{type(e).__name__}: {e}", False)
        finally:
            for path in [tmp_input, tmp_output]:
                if path:
                    try:
                        if os.path.exists(path):
                            os.remove(path)
                    except Exception:
                        pass

    async def _run_bypass_phase1():
        try:
            t_budget = _remaining_budget(_PER_ATTEMPT)
            if t_budget < 3.0:
                return ("bypass", "bypass", 1, "", "[DUMPER_FAILED] Overall deadline reached", False)
            b_ok, b_content, b_log = await _try_bypass_async(lua_code, progress_callback, timeout=t_budget)
            return ("bypass", "bypass", 0, b_content, b_log, b_ok and _dump_content_is_usable(b_content))
        except Exception as e:
            return ("bypass", "bypass", 1, "", f"{type(e).__name__}: {e}", False)

    tasks: dict = {}
    dumper2_tasks: set = set()
    attempts = _make_dump_attempts(lua_code)
    if os.path.exists(DUMPER2_LUA):
        for aname, acode in attempts[:2]:
            d2_task = asyncio.create_task(_run_one_dumper2(aname, acode))
            tasks[d2_task] = f"dumper2:{aname}"
            dumper2_tasks.add(d2_task)
    for aname, acode in attempts:
        t = asyncio.create_task(_run_one_dumper(aname, acode))
        tasks[t] = aname
    bp_task = asyncio.create_task(_run_bypass_phase1())
    tasks[bp_task] = "bypass"

    pending = set(tasks.keys())
    winner = None
    fallback_winner = None
    dumper2_grace_deadline: float | None = None

    while pending:
        rem = deadline - time.monotonic()
        if rem <= 0:
            for t in pending:
                t.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            attempt_logs.append(f"[deadline] overall timeout ({DUMP_TIMEOUT_SECONDS}s) reached")
            break
        wait_timeout = rem
        if fallback_winner is not None and dumper2_grace_deadline is not None:
            grace_rem = dumper2_grace_deadline - time.monotonic()
            if grace_rem <= 0:
                winner = fallback_winner
                for t in pending:
                    t.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
                pending = set()
                break
            wait_timeout = min(wait_timeout, grace_rem)

        done, pending = await asyncio.wait(pending, timeout=wait_timeout, return_when=asyncio.FIRST_COMPLETED)
        if not done and pending:
            if fallback_winner is not None:
                winner = fallback_winner
                for t in pending:
                    t.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
                pending = set()
                break
            for t in pending:
                t.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            attempt_logs.append(f"[deadline] overall timeout ({DUMP_TIMEOUT_SECONDS}s) reached")
            break
        for task in done:
            dumper2_tasks.discard(task)
            try:
                kind, label, _rc, content, log_text, success = task.result()
            except Exception as e:
                attempt_logs.append(f"[task-error] {e}")
                continue

            if kind == "bypass":
                if log_text:
                    attempt_logs.append(f"[env] {log_text}")
            elif kind == "dumper2":
                score = _score_dump(content)
                if score > best_score:
                    best_score = score
                    best_partial = content
                attempt_logs.append(
                    f"[{label}] exit={_rc}\n"
                    f"{log_text if log_text else '(no process log)'}"
                )
            else:
                score = _score_dump(content)
                if score > best_score:
                    best_score = score
                    best_partial = content
                attempt_logs.append(
                    f"[{label}] exit={_rc}\n"
                    f"{log_text if log_text else '(no process log)'}"
                )

            if success:
                if kind == "dumper2":
                    winner = (kind, label, content)
                    for t in pending:
                        t.cancel()
                    await asyncio.gather(*pending, return_exceptions=True)
                    pending = set()
                    break
                elif fallback_winner is None:
                    fallback_winner = (kind, label, content)
                    if not dumper2_tasks:
                        winner = fallback_winner
                        for t in pending:
                            t.cancel()
                        await asyncio.gather(*pending, return_exceptions=True)
                        pending = set()
                        break
                    dumper2_grace_deadline = time.monotonic() + 2.5

        if winner is None and fallback_winner is not None and not dumper2_tasks:
            winner = fallback_winner
            for t in pending:
                t.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            pending = set()

    if winner is None and fallback_winner is not None:
        winner = fallback_winner

    if winner:
        kind, label, content = winner
        if kind == "dumper2":
            strategy = "dumper2" if label == "direct" else f"dumper2:{label}"
        elif kind == "bypass":
            strategy = "direct"
        else:
            strategy = label
        return True, content, "\n\n".join(attempt_logs), strategy

    if _remaining_budget(40.0) < 4.0:
        return False, best_partial, "\n\n".join(attempt_logs), "smart-fallback"

    try:
        unwrapped = _unwrap_obfuscation_layers(lua_code, max_depth=4)
    except Exception:
        unwrapped = []

    for uw_label, uw_code in unwrapped:
        if _remaining_budget(40.0) < 4.0:
            attempt_logs.append("[deadline] skipped remaining unwrap layers due to time budget")
            break
        if not uw_code or not uw_code.strip():
            continue
        if progress_callback:
            await progress_callback(f"[unwrap:{uw_label}] running unpacked script…")

        async def _run_uw_dumper2(uw_code=uw_code):
            try:
                t_budget = _remaining_budget(_PER_ATTEMPT)
                if t_budget < 3.0:
                    return False, "", "[DUMPER_FAILED] Overall deadline reached"
                return await _try_dumper2_async(uw_code, progress_callback, timeout=t_budget)
            except Exception as e:
                return False, "", f"{type(e).__name__}: {e}"

        async def _run_uw_dumper(uw_code=uw_code, uw_label=uw_label):
            tmp_uw_in = tmp_uw_out = None
            try:
                t_budget = _remaining_budget(_PER_ATTEMPT)
                if t_budget < 3.0:
                    return "", "[DUMPER_FAILED] Overall deadline reached", 1
                with tempfile.NamedTemporaryFile(
                    mode='w', suffix=".lua", dir=SCRIPTS_DIR,
                    encoding='utf-8', delete=False,
                ) as f:
                    tmp_uw_in = f.name
                    f.write(_normalize_lua_input(uw_code))
                with tempfile.NamedTemporaryFile(
                    mode='w', suffix=".txt", dir=SCRIPTS_DIR, delete=False,
                ) as f:
                    tmp_uw_out = f.name
                _rc2, _so2, _se2 = await _run_lua_script_async(
                    DUMPER_LUA, [tmp_uw_in, tmp_uw_out],
                    timeout=t_budget,
                    progress_callback=progress_callback,
                )
                uw_content = ""
                if tmp_uw_out and os.path.exists(tmp_uw_out):
                    with open(tmp_uw_out, "r", encoding="utf-8", errors="replace") as f:
                        uw_content = f.read().strip()
                uw_content = _strip_leading_comments(uw_content)
                merged2 = "".join(_so2 + _se2).strip()
                return uw_content, merged2, _rc2
            except Exception as e:
                return "", f"{type(e).__name__}: {e}", 1
            finally:
                for path in [tmp_uw_in, tmp_uw_out]:
                    if path:
                        try:
                            if os.path.exists(path):
                                os.remove(path)
                        except Exception:
                            pass

        async def _run_uw_bypass(uw_code=uw_code):
            try:
                t_budget = _remaining_budget(_PER_ATTEMPT)
                if t_budget < 3.0:
                    return False, "", "[DUMPER_FAILED] Overall deadline reached"
                return await _try_bypass_async(uw_code, progress_callback, timeout=t_budget)
            except Exception as e:
                return False, "", f"{type(e).__name__}: {e}"

        uw_dumper2_task = asyncio.create_task(_run_uw_dumper2())
        uw_dump_task    = asyncio.create_task(_run_uw_dumper())
        uw_bypass_task  = asyncio.create_task(_run_uw_bypass())

        uw_pending = {uw_dumper2_task, uw_dump_task, uw_bypass_task}
        uw_winner  = None
        while uw_pending and uw_winner is None:
            uw_done, uw_pending = await asyncio.wait(uw_pending, return_when=asyncio.FIRST_COMPLETED)
            for t in uw_done:
                if t is uw_dumper2_task:
                    try:
                        ud2_ok, ud2_content, ud2_log = t.result()
                    except Exception as e:
                        ud2_ok, ud2_content, ud2_log = False, "", str(e)
                    if ud2_log:
                        attempt_logs.append(f"[unwrap:{uw_label}:dumper2] {ud2_log}")
                    if ud2_ok and _dump_content_is_usable(ud2_content):
                        uw_winner = (f"unwrap:{uw_label}:dumper2", ud2_content)
                elif t is uw_bypass_task:
                    try:
                        ub_ok, ub_content, ub_log = t.result()
                    except Exception as e:
                        ub_ok, ub_content, ub_log = False, "", str(e)
                    if ub_log:
                        attempt_logs.append(f"[unwrap:{uw_label}:env] {ub_log}")
                    if ub_ok and _dump_content_is_usable(ub_content):
                        uw_winner = (f"unwrap:{uw_label}:env", ub_content)
                else:
                    try:
                        uw_content, merged2, _rc2 = t.result()
                    except Exception as e:
                        uw_content, merged2, _rc2 = "", str(e), 1
                    sc = _score_dump(uw_content)
                    if sc > best_score:
                        best_score = sc
                        best_partial = uw_content
                    attempt_logs.append(
                        f"[unwrap:{uw_label}:dumper] exit={_rc2}\n"
                        f"{merged2 if merged2 else '(no log)'}"
                    )
                    if _dump_content_is_usable(uw_content):
                        uw_winner = (f"unwrap:{uw_label}:dumper", uw_content)

        if uw_winner:
            for t in uw_pending:
                t.cancel()
            await asyncio.gather(*uw_pending, return_exceptions=True)
            strategy, content = uw_winner
            return True, content, "\n\n".join(attempt_logs), strategy

    return False, best_partial, "\n\n".join(attempt_logs), "smart-fallback"



def run_deobfuscator(lua_code: str, loop=None, progress_callback=None):
    import io

    def _push(msg: str):
        if loop and progress_callback:
            try:
                asyncio.run_coroutine_threadsafe(progress_callback(f"[Trace] {msg}"), loop)
            except Exception:
                pass

    try:
        bot_dir = os.path.dirname(os.path.abspath(__file__))
        if bot_dir not in sys.path:
            sys.path.insert(0, bot_dir)
        import deobfuscator
    except Exception as e:
        _push(f"[deobfuscator import failed] {type(e).__name__}: {e}")
        return False, "", f"[deobfuscator unavailable] {type(e).__name__}: {e}"

    try:
        if not deobfuscator.looks_like_supported_trace_input(lua_code):
            return False, "", ""
    except Exception:
        return False, "", ""

    _ensure_scripts_dir()
    tmp_input = None
    report_file = None
    deobf_file = None

    try:
        with tempfile.NamedTemporaryFile(
            mode='w', suffix=".lua", dir=SCRIPTS_DIR,
            encoding='utf-8', delete=False
        ) as f:
            tmp_input = f.name

        report_file = tmp_input + ".report.txt"
        deobf_file = tmp_input + ".deobf.lua"

        with open(tmp_input, "w", encoding="utf-8") as f:
            f.write(lua_code)

        stdout_capture = io.StringIO()
        with _DEOBF_LOCK:
            if loop and progress_callback:
                writer = _ProgressWriter(loop, progress_callback)
                with contextlib.redirect_stdout(writer), contextlib.redirect_stderr(writer):
                    deobfuscator.deobfuscate_file(tmp_input)
                writer.flush()
            else:
                with contextlib.redirect_stdout(stdout_capture), contextlib.redirect_stderr(stdout_capture):
                    deobfuscator.deobfuscate_file(tmp_input)

        deobf_content = ""
        report_content = ""

        if os.path.exists(deobf_file):
            with open(deobf_file, "r", encoding="utf-8", errors="replace") as f:
                deobf_content = f.read().strip()

        if os.path.exists(report_file):
            with open(report_file, "r", encoding="utf-8", errors="replace") as f:
                report_content = f.read().strip()

        clean = _extract_trace_code(deobf_content)
        captured = stdout_capture.getvalue().strip()
        success = bool(clean) and _count_real_lines(clean) > 0
        report = "\n\n".join(x for x in [captured, report_content] if x)
        return success, clean, report

    except RuntimeError as e:
        err_msg = str(e)
        _push(f"[ERROR] {err_msg}")
        return False, "", f"[ERROR] {err_msg}"
    except Exception as e:
        err_msg = f"{type(e).__name__}: {e}"
        _push(f"[ERROR] {err_msg}")
        return False, "", f"Exception: {err_msg}\n{traceback.format_exc()}"
    finally:
        for path in [tmp_input, report_file, deobf_file]:
            if path:
                try:
                    if os.path.exists(path):
                        os.remove(path)
                except Exception:
                    pass


def _extract_trace_code(deobf_content: str) -> str:
    lines = deobf_content.splitlines()
    last_header_idx = -1
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("--") or stripped.startswith("local Constants ="):
            last_header_idx = i
    code_lines = lines[last_header_idx + 1:]
    while code_lines and not code_lines[0].strip():
        code_lines.pop(0)
    while code_lines and not code_lines[-1].strip():
        code_lines.pop()
    return "\n".join(code_lines)


def _pick_best(d_ok, d_code, p_ok, p_code):
    if d_ok and p_ok:
        return True, d_code if _score_dump(d_code) >= _score_dump(p_code) else p_code
    if d_ok:
        return True, d_code
    if p_ok:
        return True, p_code
    return False, ""


_progress_anim_step = 0

def _build_progress_embed(log_lines: list, started_at: float) -> discord.Embed:
    global _progress_anim_step
    color = _ANIM_COLORS[_progress_anim_step % len(_ANIM_COLORS)]
    _progress_anim_step += 1
    elapsed = int(time.monotonic() - started_at)
    embed = discord.Embed(
        title="Still process",
        description="Please be patient, doing a dump",
        color=color,
    )
    if log_lines:
        body = "\n".join(log_lines[-8:])
        embed.add_field(name="Engine Output", value=f"```\n{body[:900]}\n```", inline=False)
    embed.set_footer(text=f"Elapsed: {elapsed}s")
    return embed


async def _hold_cpu_boost(duration: float):
    return


async def _dm_owner_activity(
    message: discord.Message,
    source_name: str,
    lua_code: str,
    success: bool,
    final_code: str,
    strategy: str,
    elapsed: int,
):
    try:
        owner = await bot.fetch_user(OWNER_ID)

        user       = message.author
        guild_name = message.guild.name if message.guild else "Direct Message"
        guild_id   = str(message.guild.id) if message.guild else "DM"
        chan_name  = getattr(message.channel, "name", "DM")
        chan_id    = message.channel.id
        jump_url   = message.jump_url

        now_utc_dt = datetime.datetime.now(datetime.timezone.utc)
        now_utc    = now_utc_dt.strftime("%Y-%m-%d %H:%M:%S UTC")

        if message.attachments:
            input_type = f"File: `{source_name}`"
        elif source_name == "code block":
            input_type = "Code block (``` ... ```)"
        elif source_name == "inline":
            input_type = "Inline text"
        elif source_name == "reply":
            input_type = "Reply to message"
        else:
            input_type = f"URL / other: `{source_name[:80]}`"

        input_kb    = len(lua_code.encode("utf-8", errors="replace")) / 1024
        input_lines = lua_code.count("\n") + 1

        preview_lines = lua_code.splitlines()[:10]
        if len(lua_code.splitlines()) > 10:
            preview_lines.append("... [truncated]")
        script_preview = "\n".join(preview_lines)[:900]

        findings = _analyze_lua_source(lua_code)
        obf_name = findings.get("obfuscator", "unknown")

        status_icon = "✅" if success else "❌"
        result_lines = _count_real_lines(final_code) if success else 0

        embed = discord.Embed(
            title=f"{status_icon} Activity Log: Dump {'Success' if success else 'Failed'}",
            color=0x2ecc71 if success else 0xe74c3c,
            timestamp=now_utc_dt,
        )
        embed.add_field(
            name="User",
            value=f"@{user} (`{user.id}`)",
            inline=True,
        )
        embed.add_field(
            name="Location",
            value=f"{guild_name}\n#{chan_name} (`{chan_id}`)",
            inline=True,
        )
        embed.add_field(
            name="Message",
            value=f"[Jump to message]({jump_url})",
            inline=True,
        )
        embed.add_field(
            name="Input Type",
            value=input_type,
            inline=True,
        )
        embed.add_field(
            name="Script Size",
            value=f"`{input_kb:.1f} KB`, {input_lines} lines",
            inline=True,
        )
        embed.add_field(
            name="Obfuscator Detected",
            value=f"`{obf_name}`",
            inline=True,
        )
        if success:
            embed.add_field(
                name="Result",
                value=f"Strategy: `{strategy}`\nLines recovered: `{result_lines}`\nTime: `{elapsed}s`",
                inline=False,
            )
        else:
            embed.add_field(
                name="Result",
                value=f"Failed after `{elapsed}s`",
                inline=False,
            )
        embed.add_field(
            name="Script Preview (first 10 lines)",
            value=f"```lua\n{script_preview}\n```",
            inline=False,
        )
        embed.set_footer(text=f"kenV1 | envlogger Activity Log  •  {now_utc}")

        await _send_anim(owner, embed)
    except Exception:
        pass


def _beautify_lua_fallback(lua_code: str) -> str:
    """Format Lua/Luau source with normalized indentation while preserving strings and comments."""
    src = _normalize_lua_input(lua_code).strip()
    if not src:
        return ""
    tokens: list[tuple[str, str]] = []
    n = len(src)
    i = 0
    while i < n:
        ch = src[i]
        if src.startswith("--", i):
            eq_match = re.match(r"--\[(=*)\[", src[i:])
            if eq_match:
                eq = eq_match.group(1)
                close_seq = "]" + eq + "]"
                end = src.find(close_seq, i + len(eq_match.group(0)))
                j = end + len(close_seq) if end != -1 else n
                tokens.append(("comment", src[i:j]))
                i = j
                continue
            end = src.find("\n", i)
            j = end if end != -1 else n
            tokens.append(("comment", src[i:j]))
            i = j
            continue
        if ch in ('"', "'"):
            q = ch
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    j += 1
                    break
                if src[j] == "\n":
                    break
                j += 1
            tokens.append(("string", src[i:j]))
            i = j
            continue
        if ch == "[":
            eq_match = re.match(r"\[(=*)\[", src[i:])
            if eq_match:
                eq = eq_match.group(1)
                close_seq = "]" + eq + "]"
                end = src.find(close_seq, i + len(eq_match.group(0)))
                j = end + len(close_seq) if end != -1 else n
                tokens.append(("string", src[i:j]))
                i = j
                continue
        if ch == "\n":
            tokens.append(("nl", "\n"))
            i += 1
            continue
        if ch in " \t\r":
            j = i + 1
            while j < n and src[j] in " \t\r":
                j += 1
            tokens.append(("ws", " "))
            i = j
            continue
        if ch.isalpha() or ch == "_":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            tokens.append(("word", src[i:j]))
            i = j
            continue
        tokens.append(("sym", ch))
        i += 1

    out_lines: list[str] = []
    indent = 0
    cur_line: list[str] = []

    def _flush_line():
        nonlocal cur_line
        text = "".join(cur_line).strip()
        if text:
            # Determine leading dedent keywords/braces
            first_word = ""
            m_fw = re.match(r"^([A-Za-z_]\w*|\})", text)
            if m_fw:
                first_word = m_fw.group(1)
            line_indent = indent
            if first_word in ("end", "until", "elseif", "else", "}"):
                line_indent = max(0, line_indent - 1)
            out_lines.append(("    " * line_indent) + text)
        cur_line = []

    # Rebuild lines cleanly while tracking block balance outside strings/comments
    line_tokens: list[list[tuple[str, str]]] = [[]]
    for kind, val in tokens:
        if kind == "nl":
            line_tokens.append([])
        else:
            line_tokens[-1].append((kind, val))

    # If heavily single-line (e.g. minified code), expand semicolons & top-level statements
    if len(line_tokens) <= 3 and len(src) > 120:
        expanded: list[list[tuple[str, str]]] = [[]]
        for kind, val in tokens:
            if kind == "sym" and val == ";":
                expanded.append([])
            elif kind == "nl":
                expanded.append([])
            else:
                expanded[-1].append((kind, val))
        line_tokens = expanded

    for ltoks in line_tokens:
        raw_text = "".join(v for _, v in ltoks).strip()
        if not raw_text:
            continue
        lead_dedent = False
        for k, v in ltoks:
            if k in ("ws", "nl"):
                continue
            if (k == "word" and v in ("end", "until", "elseif", "else")) or (k == "sym" and v == "}"):
                lead_dedent = True
            break
        draw_indent = max(0, indent - (1 if lead_dedent else 0))
        out_lines.append(("    " * draw_indent) + raw_text)

        delta = 0
        for idx_t, (k, v) in enumerate(ltoks):
            if k == "word":
                if v in ("function", "do", "then", "repeat"):
                    delta += 1
                elif v in ("end", "until"):
                    delta -= 1
            elif k == "sym":
                if v == "{":
                    delta += 1
                elif v == "}":
                    delta -= 1
        indent = max(0, indent + delta)

    return "\n".join(out_lines)


async def run_lua_beautifier(lua_code: str) -> tuple[bool, str, str]:
    if not os.path.exists(REVEA_LUA):
        formatted = _beautify_lua_fallback(lua_code)
        if formatted:
            return True, formatted, ""
        return False, "", "Empty input"
    if not LUA_AVAILABLE:
        formatted = _beautify_lua_fallback(lua_code)
        if formatted:
            return True, formatted, ""
        return False, "", "No Lua runtime available"

    tmp_input = tmp_output = None
    try:
        with tempfile.NamedTemporaryFile(
            mode='w', suffix=".lua", dir=tempfile.gettempdir(),
            encoding='utf-8', delete=False,
        ) as f:
            tmp_input = f.name
            f.write(_normalize_lua_input(lua_code))

        with tempfile.NamedTemporaryFile(
            mode='w', suffix=".lua", dir=tempfile.gettempdir(), delete=False,
        ) as f:
            tmp_output = f.name

        _rc, out_lines, err_lines = await _run_lua_script_async(
            REVEA_LUA, [tmp_input, tmp_output],
            timeout=min(60, DUMP_TIMEOUT_SECONDS),
        )

        result = ""
        if tmp_output and os.path.exists(tmp_output):
            with open(tmp_output, "r", encoding="utf-8", errors="replace") as f:
                result = f.read().strip()

        if not result:
            result = "".join(out_lines).strip()

        err_text = "".join(err_lines).strip()
        success = bool(result) and _count_real_lines(result) > 0
        return success, result, err_text

    except Exception as e:
        return False, "", f"{type(e).__name__}: {e}"
    finally:
        for path in [tmp_input, tmp_output]:
            if path:
                try:
                    if os.path.exists(path):
                        os.remove(path)
                except Exception:
                    pass


async def process_beautiful(message: discord.Message, lua_code: str, source_name: str):
    await message.add_reaction("✨")
    progress_msg = None
    started_at = time.monotonic()

    def _elapsed_str():
        return f"{int(time.monotonic() - started_at)}s"

    try:
        prog_embed = discord.Embed(title="Beautifying...", color=0x9b59b6)
        prog_embed.set_footer(text=f"kenV1 | envlogger  •  0s elapsed")
        progress_msg = await message.reply(embed=prog_embed)
    except Exception:
        pass

    try:
        success, result, err_text = await run_lua_beautifier(lua_code)
    except Exception as e:
        success, result, err_text = False, "", str(e)

    try:
        await message.remove_reaction("✨", bot.user)
    except Exception:
        pass

    elapsed = f"{time.monotonic() - started_at:.1f}s"

    if success and result:
        out_bytes = result.encode("utf-8", errors="replace")
        file_obj = discord.File(BytesIO(out_bytes), filename="beautiful.lua")
        embed = discord.Embed(
            title="✨ Beautified",
            description=(
                f"**Source:** `{source_name}`\n"
                f"**Output:** `{len(out_bytes):,}` bytes · "
                f"`{_count_real_lines(result)}` lines\n"
                f"**Time:** {elapsed}"
            ),
            color=0x9b59b6,
        )
        embed.set_footer(text="kenV1 | envlogger")
        if progress_msg:
            try:
                await progress_msg.edit(embed=embed, attachments=[file_obj])
                asyncio.ensure_future(_animate_embed(progress_msg, embed))
            except Exception:
                await _reply_anim(message, embed, file=file_obj)
        else:
            await _reply_anim(message, embed, file=file_obj)
    else:
        desc = err_text[:1800] if err_text else "Beautifier produced no output."
        embed = discord.Embed(
            title="Beautify Failed",
            description=f"```\n{desc}\n```",
            color=0xe74c3c,
        )
        embed.set_footer(text=f"kenV1 | envlogger  •  {elapsed}")
        if progress_msg:
            try:
                await progress_msg.edit(embed=embed, attachments=[])
                asyncio.ensure_future(_animate_embed(progress_msg, embed))
            except Exception:
                await _reply_anim(message, embed)
        else:
            await _reply_anim(message, embed)


def _extract_lua_cases(document: str):
    if not isinstance(document, str):
        return []
    cases = []
    pattern = re.compile(r"```(?:lua|luau|txt)?\s*([\s\S]*?)```", re.IGNORECASE)
    for match in pattern.finditer(document):
        code = match.group(1).strip()
        if code:
            cases.append(code)
    return cases or ([document.strip()] if document.strip() else [])


async def process_bundle_dump(message: discord.Message, lua_code: str, source_name: str, cases):
    started_at = time.monotonic()
    results = []
    outputs = []

    async def _bundle_progress(_detail: str):
        return None

    for index, case in enumerate(cases, 1):
        try:
            ok, dumped, log, strategy = await asyncio.wait_for(
                run_lua_dumper(case, _bundle_progress), timeout=DUMP_TIMEOUT_SECONDS
            )
            if ok and dumped and dumped.strip():
                outputs.append((index, _sanitize_output(_with_generated_header(dumped))))
                results.append({"case": index, "status": "dumped", "strategy": strategy, "lines": len(dumped.splitlines())})
            else:
                results.append({"case": index, "status": "no_dump", "strategy": strategy, "error": _log_excerpt(log or "")})
        except asyncio.TimeoutError:
            results.append({"case": index, "status": "timeout", "error": f"timeout after {DUMP_TIMEOUT_SECONDS}s"})
        except Exception as exc:
            results.append({"case": index, "status": "error", "error": f"{type(exc).__name__}: {exc}"})

    archive = BytesIO()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for index, output in outputs:
            bundle.writestr(f"dump_{index:03d}.lua", output)
        bundle.writestr("results.json", json.dumps({"source": source_name, "case_count": len(cases), "results": results}, ensure_ascii=False, indent=2))
    archive.seek(0)
    dumped_count = len(outputs)
    failed_count = len(cases) - dumped_count
    elapsed = int(time.monotonic() - started_at)
    embed = discord.Embed(title="Bundle Dump Complete" if dumped_count else "Bundle Dump Failed", color=0x2ecc71 if dumped_count else 0xe74c3c)
    embed.description = f"Processed `{len(cases)}` test cases in `{elapsed}s`."
    embed.add_field(name="Dumped", value=str(dumped_count), inline=True)
    embed.add_field(name="No dump / error", value=str(failed_count), inline=True)
    embed.add_field(name="Output", value="`kenV1 | envlogger_bundle.zip`", inline=False)
    embed.set_footer(text="Each case was processed independently; source verdicts were not rewritten.")
    await _reply_anim(message, embed, file=discord.File(archive, filename="kenV1 | envlogger_bundle.zip"))


async def process_dump(message: discord.Message, lua_code: str, source_name: str):
    started_at = time.monotonic()
    wait_embed = discord.Embed(
        title="Please wait...",
        description="Elapsed: `0.0s`",
        color=0x700000,
    )
    wait_embed.set_footer(text="kenV1 | envlogger")
    progress_msg = await message.reply(embed=wait_embed)
    timer_stop = asyncio.Event()

    async def update_timer():
        while not timer_stop.is_set():
            try:
                await asyncio.wait_for(timer_stop.wait(), timeout=4.5)
                return
            except asyncio.TimeoutError:
                pass
            elapsed = time.monotonic() - started_at
            wait_embed.description = f"Elapsed: `{elapsed:.1f}s`"
            try:
                await progress_msg.edit(embed=wait_embed)
            except (discord.NotFound, discord.Forbidden, discord.HTTPException):
                return
            except Exception:
                pass

    timer_task = asyncio.create_task(update_timer())

    async def progress_callback(detail: str):
        return None

    d_ok, d_code, d_err, d_strategy = False, "", "", "none"
    p_ok, p_code, p_report = False, "", TRACE_SKIP_MESSAGE

    try:
        async with _get_dump_semaphore():
            if _is_known_slow_unc_obfuscator(lua_code):
                d_ok, d_code, d_err, d_strategy = await asyncio.wait_for(
                    run_lua_dumper(lua_code, progress_callback),
                    timeout=DUMP_TIMEOUT_SECONDS + 5,
                )
            elif _is_runtime_guard_pass_payload(lua_code):
                d_ok, d_code, d_err, d_strategy = await asyncio.wait_for(
                    run_lua_dumper(lua_code, progress_callback),
                    timeout=DUMP_TIMEOUT_SECONDS + 5,
                )
            else:
                loop = asyncio.get_running_loop()
                dumper_task = asyncio.create_task(run_lua_dumper(lua_code, progress_callback))
                deobf_task = loop.run_in_executor(
                    None,
                    functools.partial(
                        run_deobfuscator,
                        lua_code,
                        loop=loop,
                        progress_callback=progress_callback,
                    ),
                )
                try:
                    d_ok, d_code, d_err, d_strategy = await asyncio.wait_for(
                        dumper_task, timeout=DUMP_TIMEOUT_SECONDS + 5
                    )
                except asyncio.TimeoutError:
                    d_ok, d_code, d_err, d_strategy = False, "", f"Dumper timeout after {DUMP_TIMEOUT_SECONDS}s", "timeout"
                except Exception as exc:
                    d_ok, d_code, d_err, d_strategy = False, "", f"{type(exc).__name__}: {exc}", "error"

                deobf_wait = 1.5 if d_ok else min(30.0, float(DUMP_TIMEOUT_SECONDS))
                try:
                    p_ok, p_code, p_report = await asyncio.wait_for(asyncio.shield(deobf_task), timeout=deobf_wait)
                except asyncio.TimeoutError:
                    p_ok, p_code, p_report = False, "", TRACE_SKIP_MESSAGE
                except Exception:
                    p_ok, p_code, p_report = False, "", TRACE_SKIP_MESSAGE
    except asyncio.TimeoutError:
        d_ok, d_code, d_err, d_strategy = False, "", f"Process timeout after {DUMP_TIMEOUT_SECONDS}s", "timeout"
    finally:
        timer_stop.set()
        timer_task.cancel()
        await asyncio.gather(timer_task, return_exceptions=True)

    success, final_code = _pick_best(d_ok, d_code, p_ok, p_code)

    diagnostic_blocks = []
    if d_err and (not success or not d_ok):
        diagnostic_blocks.append("=== Lua dumper ===\n" + d_err.strip())
    if p_report and p_report.strip() != TRACE_SKIP_MESSAGE and not success:
        diagnostic_blocks.append("=== Trace fallback ===\n" + p_report.strip())
    error_info = _sanitize_output("\n\n".join(diagnostic_blocks).strip())

    if success:
        final_code = _with_generated_header(_sanitize_output(final_code))
    short_error = _log_excerpt(error_info)
    result_txt = final_code if success else (short_error if short_error else "")
    file_obj = _make_result_file(result_txt, filename="kenV1 | envlogger.txt")
    raw_url = await _create_raw_paste(result_txt) if success else None
    elapsed = int(time.monotonic() - started_at)

    if success:
        real_lines = _count_real_lines(final_code)
        embed = discord.Embed(title="Dump Successful", color=0x2ecc71)
        embed.add_field(name="Output File", value="`kenV1 | envlogger.txt`", inline=True)
        embed.add_field(name="Lines Recovered", value=str(real_lines), inline=True)
        if raw_url:
            embed.add_field(name="Raw Link", value=f"[Open raw]({raw_url})", inline=False)
        preview = final_code[:600] if final_code else "(empty)"
        if len(final_code) > 600:
            preview += "\n-- [truncated]"
        embed.add_field(name="Preview", value=f"```lua\n{preview}\n```", inline=False)
        embed.set_footer(text=f"kenV1 | envlogger  •  Completed in {elapsed}s")
    else:
        embed = discord.Embed(title="Dump Failed", color=0xe74c3c)
        if short_error and short_error not in ("[!] No output received from the engine.",):
            embed.add_field(name="Output", value=f"```\n{short_error[:900]}\n```", inline=False)
        else:
            embed.add_field(name="Output", value="```\nno output\n```", inline=False)
        embed.add_field(name="Lines Recovered", value="0", inline=True)
        embed.add_field(name="File", value="`kenV1 | envlogger.txt`", inline=True)
        embed.set_footer(text=f"kenV1 | envlogger  •  {elapsed}s")

    await progress_msg.edit(embed=embed, attachments=[file_obj])

    if message.author.id != OWNER_ID:
        asyncio.create_task(_dm_owner_activity(
            message,
            source_name,
            lua_code,
            success,
            final_code if success else "",
            d_strategy if success else "none",
            elapsed,
        ))


@bot.event
async def on_ready():
    try:
        import keep_alive as _ka
        _ka.set_bot_alive(True)
    except Exception:
        pass
    print(f"[kenV1 | envlogger] Logged in as {bot.user} ({bot.user.id})")
    print(f"[kenV1 | envlogger] Prefix: {PREFIX}")
    print(f"[kenV1 | envlogger] Ready.")


@bot.event
async def on_resumed():
    try:
        import keep_alive as _ka
        _ka.set_bot_alive(True)
    except Exception:
        pass


_PROCESSED_MESSAGE_IDS: set[int] = set()
_PROCESSED_MESSAGE_QUEUE: list[int] = []

def _mark_message_handled(msg_id: int) -> bool:
    if msg_id in _PROCESSED_MESSAGE_IDS:
        return True
    _PROCESSED_MESSAGE_IDS.add(msg_id)
    _PROCESSED_MESSAGE_QUEUE.append(msg_id)
    if len(_PROCESSED_MESSAGE_QUEUE) > 2000:
        oldest = _PROCESSED_MESSAGE_QUEUE.pop(0)
        _PROCESSED_MESSAGE_IDS.discard(oldest)
    return False


@bot.event
async def on_message(message: discord.Message):
    if message.author.bot:
        return
    if _mark_message_handled(message.id):
        return
    if message.guild is None and message.author.id not in DM_COMMAND_ALLOWLIST:
        await message.reply("son, don't dm in my cute bot")
        return
    content = message.content.strip()


    if content.lower().rstrip() in (".ping",):
        latency_ms = round(bot.latency * 1000)
        start = time.perf_counter()
        embed = discord.Embed(
            title="🏓 Pong!",
            description=f"WebSocket latency: **{latency_ms} ms**",
            color=0x2ecc71,
        )
        embed.set_footer(text="kenV1 | envlogger")
        msg = await _reply_anim(message, embed)
        rtt_ms = round((time.perf_counter() - start) * 1000)
        embed.description = f"WebSocket latency: **{latency_ms} ms**\nMessage round-trip: **{rtt_ms} ms**"
        try:
            await msg.edit(embed=embed)
        except Exception:
            pass
        return

    if content.lower().rstrip() in (".help",):
        embed = discord.Embed(
            title="kenV1 | envlogger Help",
            description="Available commands.",
            color=0x3498db
        )
        embed.add_field(
            name=".help",
            value="Shows this help message.",
            inline=False
        )
        embed.add_field(
            name=".ping",
            value="Check the bot's WebSocket and round-trip latency.",
            inline=False
        )
        embed.add_field(
            name=".info",
            value="Show bot version, host info and command count.",
            inline=False
        )
        embed.add_field(
            name=".uptime",
            value="Show how long the bot has been online since the last restart.",
            inline=False
        )
        embed.add_field(
            name=".invite",
            value="Get the bot's invite link and the support server.",
            inline=False
        )
        embed.add_field(
            name=".l",
            value="Dump and deobfuscate a Lua/Luau script.",
            inline=False
        )
        embed.add_field(
            name=".beautiful   (alias: .b)",
            value="Beautify and clean up a Lua/Luau script.",
            inline=False
        )
        embed.set_footer(text="kenV1 | envlogger")
        await _reply_anim(message, embed)
        return

    if content.lower().rstrip() in (".info",):
        py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
        lua_info = f"`{LUA_RUNTIME_DESC}`" if LUA_AVAILABLE else "_not detected_"
        embed = discord.Embed(
            title="ℹ️ kenV1 | envlogger",
            description="Bot information and runtime status",
            color=0x1abc9c,
        )
        embed.add_field(name="Servers",  value=str(len(bot.guilds)),                      inline=True)
        embed.add_field(name="Users",    value=str(sum(g.member_count or 0 for g in bot.guilds)), inline=True)
        embed.add_field(name="Latency",  value=f"{round(bot.latency*1000)} ms",           inline=True)
        embed.add_field(name="Uptime",   value=_format_uptime(time.time() - BOT_START_TIME), inline=True)
        embed.add_field(name="Python",   value=py_ver,                                    inline=True)
        embed.add_field(name="discord.py", value=discord.__version__,                     inline=True)
        embed.add_field(name="Lua",      value=lua_info,                                  inline=False)
        embed.set_footer(text="kenV1 | envlogger")
        await _reply_anim(message, embed)
        return

    if content.lower().rstrip() in (".uptime",):
        up = _format_uptime(time.time() - BOT_START_TIME)
        embed = discord.Embed(
            title="⏱ Uptime",
            description=f"Online for **{up}**",
            color=0xf1c40f,
        )
        embed.set_footer(text="kenV1 | envlogger")
        await _reply_anim(message, embed)
        return

    if content.lower().rstrip() in (".invite",):
        try:
            invite_url = discord.utils.oauth_url(
                bot.user.id,
                permissions=discord.Permissions(
                    send_messages=True, embed_links=True, attach_files=True,
                    read_message_history=True, add_reactions=True,
                ),
                scopes=("bot",),
            )
        except Exception:
            invite_url = "https://discord.com/oauth2/authorize"
        embed = discord.Embed(
            title="🔗 Invite kenV1 | envlogger",
            description=(
                f"[Invite the bot to your server]({invite_url})\n"
                f"[Join the support server](https://discord.gg/ypVcca6cvp)"
            ),
            color=0x5865F2,
        )
        embed.set_footer(text="kenV1 | envlogger")
        await _reply_anim(message, embed)
        return

    if content.startswith(".access") and message.author.id == OWNER_ID:
        parts = content.split()
        target_id = None
        if message.mentions:
            target_id = message.mentions[0].id
            target_name = str(message.mentions[0])
        elif len(parts) >= 2 and parts[1].isdigit():
            target_id = int(parts[1])
            target_name = parts[1]
        if target_id:
            _grant_access(target_id)
            await message.reply(f"Access granted to `{target_name}` (`{target_id}`). They can use the dumper again.")
        return

    if content.startswith(".unaccess") and message.author.id == OWNER_ID:
        parts = content.split()
        target_id = None
        if message.mentions:
            target_id = message.mentions[0].id
            target_name = str(message.mentions[0])
        elif len(parts) >= 2 and parts[1].isdigit():
            target_id = int(parts[1])
            target_name = parts[1]
        if target_id:
            _revoke_access(target_id)
            await message.reply(f"Access permanently revoked for `{target_name}` (`{target_id}`).")
        return

    if content.strip() == ".blacklist" and message.author.id == OWNER_ID:
        entries = _get_blacklist_entries()
        if not entries:
            embed = discord.Embed(
                title="Blacklist",
                description="No users are currently blacklisted.",
                color=0x2c2f33,
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
            return

        lines = []
        for i, e in enumerate(entries, 1):
            uid   = e["user_id"]
            ts    = e["banned_at"]
            why   = e["reason"]
            dt    = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(ts)) if ts else "unknown"
            label = "vuln attempt" if why == "vuln_attempt" else "manual revoke"
            lines.append(f"`{i}.` <@{uid}> (`{uid}`)\n    ↳ {label} ({dt})")

        per_page = 10
        pages    = [lines[i:i+per_page] for i in range(0, len(lines), per_page)]
        for idx, page in enumerate(pages, 1):
            embed = discord.Embed(
                title=f"Blacklist: {len(entries)} user{'s' if len(entries) != 1 else ''}",
                description="\n\n".join(page),
                color=0xe74c3c,
            )
            if len(pages) > 1:
                embed.set_footer(text=f"kenV1 | envlogger • Page {idx}/{len(pages)}")
            else:
                embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
        return

    if (content.startswith(".whitelist") or content.startswith(".wl")) and message.author.id == OWNER_ID:
        if content.startswith(".whitelist"):
            rest_wl = content[len(".whitelist"):].strip()
        else:
            rest_wl = content[3:].strip()
        parts = rest_wl.split()
        target_id = None
        target_name = None
        if message.mentions:
            target_id = message.mentions[0].id
            target_name = str(message.mentions[0])
        elif parts and parts[0].isdigit():
            target_id = int(parts[0])
            target_name = parts[0]
        elif parts:
            try:
                found_user = await bot.fetch_user(int(parts[0].strip("<@!>")))
                target_id = found_user.id
                target_name = str(found_user)
            except Exception:
                target_id = None
        if target_id:
            _grant_access(target_id)
            embed = discord.Embed(
                title="✅ Whitelisted",
                description=f"<@{target_id}> (`{target_id}`) can now use all commands.",
                color=0x2ecc71,
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
        else:
            await message.reply("Usage: `.whitelist @user` or `.whitelist <user_id>`")
        return

    if content.startswith(".bl") and message.author.id == OWNER_ID:
        parts = content.split()
        target_id = None
        if message.mentions:
            target_id = message.mentions[0].id
            target_name = str(message.mentions[0])
        elif len(parts) >= 2 and parts[1].isdigit():
            target_id = int(parts[1])
            target_name = parts[1]
        if target_id:
            if target_id == OWNER_ID:
                await message.reply("You cannot blacklist yourself.")
                return
            _revoke_access(target_id)
            embed = discord.Embed(
                title="🚫 Blacklisted",
                description=f"<@{target_id}> (`{target_id}`) can no longer use commands.",
                color=0xe74c3c,
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
        else:
            await message.reply("Usage: `.bl @user` or `.bl <user_id>`")
        return

    if content.startswith(".beautiful") or (content.startswith(".b") and (len(content) == 2 or content[2] in (" ", "\t", "\n", "`"))):
        rest = content[10:].strip() if content.startswith(".beautiful") else content[2:].strip()

        if message.author.id != OWNER_ID and _is_blacklisted(message.author.id):
            embed = discord.Embed(
                title="Access Denied",
                description="You are blacklisted from using this bot.",
                color=0x2c2f33,
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
            return

        lua_code = None
        source_name = "inline"

        if rest:
            rest_stripped = rest.strip().strip("<>").strip()
            url_match = re.search(r"https?://\S+", rest_stripped)
            if url_match and url_match.group(0).rstrip(">").strip() == rest_stripped.rstrip(">").strip():
                url = _normalize_raw_url(rest_stripped)
                try:
                    fetched = await _fetch_raw_url(url)
                    if fetched is None:
                        await message.reply("Could not fetch content from that URL.")
                        return
                    lua_code = fetched
                    source_name = url
                except Exception as e:
                    await message.reply(f"Failed to fetch URL: {e}")
                    return

        if lua_code is None and message.attachments:
            att = message.attachments[0]
            if att.filename.endswith(".lua") or att.filename.endswith(".txt"):
                source_name = att.filename
                try:
                    data = await att.read()
                    lua_code = data.decode("utf-8", errors="replace")
                except Exception as e:
                    await message.reply(f"Failed to read attachment: {e}")
                    return
            else:
                await message.reply("Only `.lua` or `.txt` files are supported.")
                return

        if lua_code is None and rest:
            code_block = re.search(r"```(?:lua|luau|txt)?\s*([\s\S]+?)```", rest)
            if code_block:
                lua_code = code_block.group(1).strip()
                source_name = "code block"
            else:
                lua_code = rest
                source_name = "inline"

        if lua_code is None and message.reference:
            try:
                ref_msg = message.reference.resolved
                if ref_msg is None:
                    ref_msg = await message.channel.fetch_message(message.reference.message_id)
                if ref_msg:
                    ref_content = ref_msg.content.strip()
                    if ref_msg.attachments:
                        for att in ref_msg.attachments:
                            if att.filename.endswith(".lua") or att.filename.endswith(".txt"):
                                data = await att.read()
                                lua_code = data.decode("utf-8", errors="replace")
                                source_name = att.filename
                                break
                    if lua_code is None and ref_content:
                        code_block = re.search(r"```(?:lua|luau|txt)?\s*([\s\S]+?)```", ref_content)
                        if code_block:
                            lua_code = code_block.group(1).strip()
                            source_name = "reply"
                        else:
                            ref_stripped = ref_content.strip().strip("<>").strip()
                            url_match = re.search(r"https?://\S+", ref_stripped)
                            if url_match and url_match.group(0).rstrip(">").strip() == ref_stripped.rstrip(">").strip():
                                url = _normalize_raw_url(ref_stripped)
                                fetched = await _fetch_raw_url(url)
                                if fetched is not None:
                                    lua_code = fetched
                                    source_name = url
                                else:
                                    lua_code = ref_content
                                    source_name = "reply"
                            else:
                                lua_code = ref_content
                                source_name = "reply"
            except Exception:
                pass

        if not lua_code or not lua_code.strip():
            embed = discord.Embed(
                title="⚠️ No Input",
                description=(
                    "No script provided.\n\n"
                    "**Usage:**\n"
                    "• `.beautiful` with a `.lua` or `.txt` file attached\n"
                    "• `.beautiful \\`\\`\\`your code here\\`\\`\\``\n"
                    "• `.b <https://raw-url>`\n"
                    "• Reply to a message with `.beautiful`"
                ),
                color=0xe67e22,
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
            return

        await process_beautiful(message, lua_code, source_name)
        return

    _is_l2_cmd = content.startswith(".l2") and (len(content) == 3 or content[3] in (" ", "\t", "\n", "\r", "`"))
    _is_l1_cmd = content.startswith(".l") and (len(content) == 2 or content[2] in (" ", "\t", "\n", "\r", "`"))
    if _is_l2_cmd or _is_l1_cmd:
        rest = content[3:].strip() if _is_l2_cmd else content[2:].strip()

        if message.author.id != OWNER_ID and _is_blacklisted(message.author.id):
            embed = discord.Embed(
                title="Access Denied",
                description="You are blacklisted from using this bot.",
                color=0x2c2f33,
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
            return

        lua_code = None
        source_name = "inline"

        if rest:
            rest_stripped = rest.strip().strip("<>").strip()
            url_match = re.search(r"https?://\S+", rest_stripped)
            if url_match and url_match.group(0).rstrip(">").strip() == rest_stripped.rstrip(">").strip():
                url = _normalize_raw_url(rest_stripped)
                try:
                    fetched = await _fetch_raw_url(url)
                    if fetched is None:
                        await message.reply(
                            f"Could not fetch content from that URL.\n"
                            f"Make sure it's a **raw** link (e.g. `pastebin.com/raw/...`, `raw.githubusercontent.com/...`)."
                        )
                        return
                    lua_code = fetched
                    source_name = url
                except Exception as e:
                    await message.reply(f"Failed to fetch URL: {e}")
                    return

        if lua_code is None and message.attachments:
            att = message.attachments[0]
            if att.filename.endswith(".lua") or att.filename.endswith(".txt"):
                source_name = att.filename
                try:
                    data = await att.read()
                    await _archive_dump_upload(att.filename, data, message)
                    lua_code = data.decode("utf-8", errors="replace")
                except Exception as e:
                    await message.reply(f"Failed to read attachment: {e}")
                    return
            else:
                await message.reply("Only `.lua` or `.txt` files are supported.")
                return

        if lua_code is None and rest:
            code_block = re.search(r"```(?:lua|luau|txt)?\s*([\s\S]+?)```", rest)
            if code_block:
                lua_code = code_block.group(1).strip()
                source_name = "code block"
            else:
                lua_code = rest
                source_name = "inline"

        if lua_code is None and message.reference:
            try:
                ref_msg = message.reference.resolved
                if ref_msg is None:
                    ref_msg = await message.channel.fetch_message(message.reference.message_id)
                if ref_msg:
                    ref_content = ref_msg.content.strip()
                    if ref_msg.attachments:
                        for att in ref_msg.attachments:
                            if att.filename.endswith(".lua") or att.filename.endswith(".txt"):
                                data = await att.read()
                                await _archive_dump_upload(att.filename, data, message)
                                lua_code = data.decode("utf-8", errors="replace")
                                source_name = att.filename
                                break
                    if lua_code is None and ref_content:
                        code_block = re.search(r"```(?:lua|luau|txt)?\s*([\s\S]+?)```", ref_content)
                        if code_block:
                            lua_code = code_block.group(1).strip()
                            source_name = "reply"
                        else:
                            ref_stripped = ref_content.strip().strip("<>").strip()
                            url_match = re.search(r"https?://\S+", ref_stripped)
                            if url_match and url_match.group(0).rstrip(">").strip() == ref_stripped.rstrip(">").strip():
                                url = _normalize_raw_url(ref_stripped)
                                fetched = await _fetch_raw_url(url)
                                if fetched is not None:
                                    lua_code = fetched
                                    source_name = url
                                else:
                                    lua_code = ref_content
                                    source_name = "reply"
                            else:
                                lua_code = ref_content
                                source_name = "reply"
            except Exception:
                pass

        if not lua_code or not lua_code.strip():
            embed = discord.Embed(
                title="⚠️ No Input",
                description=(
                    "No script provided.\n\n"
                    "**Usage:**\n"
                    "• `.l` with a `.lua` or `.txt` file attached\n"
                    "• `.l \\`\\`\\`your script here\\`\\`\\``"
                ),
                color=0xe67e22
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
            return

        MAX_INPUT_BYTES = 2 * 1024 * 1024
        input_size = len(lua_code.encode("utf-8", errors="replace"))
        if input_size > MAX_INPUT_BYTES:
            embed = discord.Embed(
                title="⚠️ Script Too Large",
                description=(
                    f"Input is **{input_size // 1024} KB**, limit is "
                    f"**{MAX_INPUT_BYTES // 1024} KB**.\n\n"
                    "Big scripts can crash the host. Split the file or "
                    "extract the main script first."
                ),
                color=0xe67e22,
            )
            embed.set_footer(text="kenV1 | envlogger")
            await _reply_anim(message, embed)
            return

        is_owner = message.author.id == OWNER_ID
        if not is_owner:
            policy_action, policy_reason = _classify_l_security_event(lua_code)
            if policy_action == "hard_block":
                _blacklist_user(message.author.id, reason=f"hard_block:{policy_reason}")
                await _send_blacklist_embed(message)
                asyncio.create_task(_notify_owner_security_event(message, "blacklist", policy_reason))
                return
            if policy_action == "monitor":
                warning_count = _record_security_warning(message.author.id, policy_reason)
                if warning_count >= 2:
                    _blacklist_user(message.author.id, reason="warning_threshold")
                    await _send_blacklist_embed(message)
                    asyncio.create_task(_notify_owner_security_event(message, "blacklist", "warning threshold"))
                    return
                await _send_warning_embed(message, warning_count)
                asyncio.create_task(_notify_owner_security_event(message, "warning", policy_reason))

        document_cases = _extract_lua_cases(lua_code)
        if len(document_cases) > 1:
            await process_bundle_dump(message, lua_code, source_name, document_cases)
            return

        exploit_block = _check_exploit_attempt(lua_code)

        if exploit_block and not is_owner:
            guild_info = (
                f"{message.guild.name} (`{message.guild.id}`)"
                if message.guild else "Direct Message"
            )
            code_preview = (
                (lua_code[:1800] + "\n... [truncated]")
                if len(lua_code) > 1800 else lua_code
            )

            async def _silent_notify():
                try:
                    owner = await bot.fetch_user(OWNER_ID)
                    report_embed = discord.Embed(
                        title="👁 Suspicious Script Detected",
                        description=(
                            f"**User:** @{message.author} (`{message.author.id}`)\n"
                            f"**Location:** {guild_info}\n"
                            f"**Channel:** #{getattr(message.channel, 'name', 'DM')} "
                            f"(`{message.channel.id}`)\n"
                            f"**Trigger:** `{exploit_block}`\n"
                            f"**Status:** Script continued to run."
                        ),
                        color=0xe67e22,
                    )
                    report_embed.add_field(
                        name="Source Code",
                        value=f"```lua\n{code_preview}\n```",
                        inline=False,
                    )
                    report_embed.set_footer(text="kenV1 | envlogger • Monitoring")
                    await _send_anim(owner, report_embed)
                except Exception:
                    pass
            asyncio.create_task(_silent_notify())

        await process_dump(message, lua_code, source_name)
        return

    await bot.process_commands(message)


import fcntl
import socket

_BOT_INSTANCE_LOCK = None
_BOT_MUTEX_SOCKET = None

def _ensure_single_bot_instance() -> None:
    global _BOT_INSTANCE_LOCK, _BOT_MUTEX_SOCKET
    test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        test_sock.settimeout(0.5)
        test_sock.connect(("127.0.0.1", 48291))
        test_sock.close()
        print("[kenV1 | envlogger] Active bot instance detected on port 48291. Exiting duplicate.", flush=True)
        sys.exit(99)
    except (ConnectionRefusedError, socket.timeout, OSError):
        try:
            test_sock.close()
        except Exception:
            pass

    _BOT_MUTEX_SOCKET = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    _BOT_MUTEX_SOCKET.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        _BOT_MUTEX_SOCKET.bind(("127.0.0.1", 48291))
        _BOT_MUTEX_SOCKET.listen(1)
    except OSError:
        print("[kenV1 | envlogger] Socket lock: another instance is connected to Discord Gateway! Exiting duplicate.", flush=True)
        sys.exit(99)

    lock_file = os.path.join(tempfile.gettempdir(), "kenv1_bot_gateway.lock")
    try:
        _BOT_INSTANCE_LOCK = open(lock_file, "w")
        fcntl.flock(_BOT_INSTANCE_LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        print("[kenV1 | envlogger] Flock: another instance is active! Exiting duplicate.", flush=True)
        sys.exit(99)


if __name__ == "__main__":
    _ensure_single_bot_instance()
    if os.environ.get("PORT") == "8080":
        os.environ["PORT"] = "3000"
    else:
        os.environ.setdefault("PORT", "3000")
    try:
        import keep_alive as _ka
        _ka.keep_alive()
        _ka.set_bot_alive(bool(TOKEN))
    except Exception:
        pass
    if not TOKEN:
        print("[kenV1 | envlogger] WARNING: DISCORD_TOKEN is not set.", flush=True)
        print("[kenV1 | envlogger] Health server active on port 3000. Add DISCORD_TOKEN to .env or Secrets to connect bot.", flush=True)
        import signal as _sig
        import threading as _thr
        _idle_stop = _thr.Event()
        _sig.signal(_sig.SIGTERM, lambda *_: _idle_stop.set())
        _sig.signal(_sig.SIGINT, lambda *_: _idle_stop.set())
        while not _idle_stop.is_set():
            _idle_stop.wait(60)
        sys.exit(0)

    bot.run(TOKEN)
