import sys
import os
_DEPS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deps")
if os.path.isdir(_DEPS_PATH) and _DEPS_PATH not in sys.path:
    sys.path.insert(0, _DEPS_PATH)

import asyncio
import ast
import subprocess
from pathlib import Path

import bot

ROOT = Path(__file__).resolve().parent

ANIMATION = '''local lp = game:GetService("Players").LocalPlayer
local char = lp.Character or lp.CharacterAdded:Wait()
local hum = char:WaitForChild("Humanoid")
local animator = hum:WaitForChild("Animator")
local anim = Instance.new("Animation")
anim.AnimationId = "rbxassetid://507766388"
local track = animator:LoadAnimation(anim)
track:Play()
task.wait(0.1)
if not track.IsPlaying then error("dtc") end
local t1 = track.TimePosition
task.wait(0.2)
local t2 = track.TimePosition
if t2 <= t1 then error("dtc") end
track:Stop()
print("ud")'''

SPATIAL = '''local w=workspace
local a=Instance.new("Part")
local b=Instance.new("Part")
a.Anchored=true
b.Anchored=true
a.Parent=w
b.Parent=w
local q=OverlapParams.new()
q.IncludeInstances={a,b}
local x=w:GetPartBoundsInBox(CFrame.new(),Vector3.new(4,4,4),q)
q.ExcludeInstances={b}
local y=w:GetPartBoundsInBox(CFrame.new(),Vector3.new(4,4,4),q)
q.IncludeInstances={}
local z=w:GetPartBoundsInBox(CFrame.new(),Vector3.new(4,4,4),q)
print("ud")'''


def fail(message):
    print("FAIL", message)
    raise SystemExit(1)


def check_python():
    for name in ("bot.py", "dumper.lua", "dumper2.lua", "bypass.lua", "lua_runner.py", "main.py", "keep_alive.py"):
        path = ROOT / name
        if not path.exists() or path.stat().st_size == 0:
            fail(f"missing or empty: {name}")
    ast.parse((ROOT / "bot.py").read_text(encoding="utf-8"))
    ast.parse((ROOT / "lua_runner.py").read_text(encoding="utf-8"))
    text = (ROOT / "bot.py").read_text(encoding="utf-8")
    start = text.find("async def process_dump")
    end = text.find("\nasync def ", start + 1) if start >= 0 else -1
    process_block = text[start:end if end >= 0 else len(text)]
    if process_block.count("progress_msg = await message.reply(embed=wait_embed)") != 1:
        fail("process_dump does not create exactly one progress embed")
    if process_block.count("await progress_msg.edit(embed=embed, attachments=[file_obj])") != 1:
        fail("process_dump does not finalize the same embed")
    if process_block.count("message.reply(") != 1:
        fail("process_dump sends more than one response")
    print("PASS python/source checks")


async def check_dumper():
    ok, content, log, strategy = await bot.run_lua_dumper(ANIMATION)
    lower = content.lower()
    log_lower = log.lower()
    if not ok or 'print("ud")' not in lower or "dtc" in lower or "stack overflow" in lower or "stack overflow" in log_lower:
        fail(f"AnimationTrack: ok={ok}, strategy={strategy}, content={content[-500:]!r}, log={log[-1000:]!r}")
    print("PASS AnimationTrack", strategy)

    ok, content, log, strategy = await bot.run_lua_dumper(SPATIAL)
    lower = (content + "\n" + log).lower()
    if not ok or "stack overflow" in lower:
        fail(f"spatial: ok={ok}, strategy={strategy}, content={content[-500:]!r}, log={log[-1000:]!r}")
    print("PASS spatial filter", strategy)


def check_bypass():
    ok, content, log = bot._try_bypass_sync('print("ud")')
    if not ok or "ud" not in content.lower() or "stack overflow" in log.lower():
        fail(f"bypass basic: ok={ok}, content={content!r}, log={log[-1000:]!r}")
    print("PASS bypass basic")


def check_dumper2():
    ok, content, log = bot._try_dumper2_sync('print("ud")')
    if not ok or "ud" not in content.lower():
        fail(f"dumper2 basic: ok={ok}, content={content!r}, log={log[-1000:]!r}")
    print("PASS dumper2 basic")


async def main():
    check_python()
    check_bypass()
    check_dumper2()
    await check_dumper()
    print("REGRESSION PASS")


if __name__ == "__main__":
    asyncio.run(main())
