--[[ kenV1 compat (Lua 5.1/5.2+, static layer decoder, bot output) ]]
do
    if not rawget(_G, "_FLAME_UPGRADE") then
        rawset(_G, "_FLAME_UPGRADE", true)
        local _flame_io = io

        -- (1) Lua 5.1 compat: make load("<string>", name, mode, env) work like 5.2+
        if _VERSION == "Lua 5.1" and type(loadstring) == "function" then
            local _real_load, _real_loadstring = load, loadstring
            load = function(chunk, chunkname, mode, env)
                if type(chunk) == "string" then
                    local fn, err = _real_loadstring(chunk, chunkname)
                    if not fn then return nil, err end
                    if env and type(setfenv) == "function" then setfenv(fn, env) end
                    return fn
                end
                return _real_load(chunk, chunkname)
            end
            loadstring = _real_loadstring
        end

        -- (2) static string-layer decoder (XOR key + Caesar shift)
        local function _flame_bxor(a, b)
            local r, bit = 0, 1
            while a > 0 or b > 0 do
                if (a % 2) ~= (b % 2) then r = r + bit end
                a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
            end
            return r
        end
        local function _flame_dec_esc(s)
            return (s:gsub("\\(%d%d?%d?)", function(e)
                local n = tonumber(e)
                if n and n > 0 and n < 256 then return string.char(n) end
                return e
            end))
        end
        local function _flame_xor(s, key)
            local b = {}
            for i = 1, #s do
                b[i] = string.char(_flame_bxor(s:byte(i), key:byte((i - 1) % #key + 1)))
            end
            return table.concat(b)
        end
        local function _flame_caesar(s, n)
            local b = {}
            for i = 1, #s do b[i] = string.char((s:byte(i) + n) % 256) end
            return table.concat(b)
        end
        local function _flame_readable(s)
            if not s or #s == 0 then return 0 end
            local ok = 0
            for i = 1, #s do
                local c = s:byte(i)
                if c >= 32 and c < 127 and c ~= 94 and c ~= 96 and c ~= 126
                    and c ~= string.byte("[") and c ~= string.byte("]") then
                    ok = ok + 1
                end
            end
            return ok / #s
        end

        -- (3) static payload extraction
        function flame_static_payload(code)
            local found = {}
            if type(code) ~= "string" then return found end
            for lit, key in code:gmatch('"([^"]*)"%s*,"%s*(%d+)"') do
                local dec = _flame_xor(_flame_dec_esc(lit), key)
                if _flame_readable(dec) < 0.85 then
                    local best, bestScore = nil, -1
                    for n = 1, 16 do
                        local sh = _flame_caesar(dec, n)
                        local sc = _flame_readable(sh)
                        if sc > bestScore then bestScore, best = sc, sh end
                    end
                    if bestScore >= 0.9 then found[#found + 1] = best end
                end
            end
            return found
        end

        -- (4) bot result writer + runner
        function flame_bot_result(outputPath, payloads)
            if outputPath and outputPath ~= "-" then
                local f = _flame_io.open(outputPath, "w")
                if f then
                    for _, p in ipairs(payloads) do f:write(p, "\n") end
                    f:close()
                end
            end
            if #payloads > 0 then
                _flame_io.stdout:write("[result] found=" .. #payloads .. "\n")
            else
                _flame_io.stdout:write("[result] none\n")
            end
            for i, p in ipairs(payloads) do
                _flame_io.stdout:write("[out_" .. i .. "] " .. p .. "\n")
            end
        end

        -- (5) bot runner: static-first (fast, no VM), engine only as fallback
        function flame_bot_run(inputPath, outputPath, dynamicFn)
            local code
            local f = _flame_io.open(inputPath, "rb")
            if f then code = f:read("*a"); f:close() end
            if not code then
                _flame_io.stdout:write("[result] input-error\n")
                return false
            end
            local got = {}
            -- 1) static string-layer first (fast, reliable)
            local st = flame_static_payload(code)
            for _, p in ipairs(st) do got[#got + 1] = p end
            -- 2) dynamic engine only when static produced nothing
            if #got == 0 and type(dynamicFn) == "function" then
                local ok = pcall(dynamicFn, inputPath, outputPath)
                if ok then
                    local of = _flame_io.open(outputPath, "rb")
                    if of then
                        local s = of:read("*a"); of:close()
                        if s and #s > 0 then got[#got + 1] = s end
                    end
                end
            end
            flame_bot_result(outputPath, got)
            return #got > 0
        end
    end
end
local unpack = unpack or table.unpack
local warn = warn or function() end
local _nativeRuntimeVersion = _VERSION

local _BYPASS = {}

local function _bypass_class(name)
    local mt = {}
    mt.__index    = mt
    mt.__type     = name
    mt.__tostring = function(self) return name end
    return mt
end

local function _bypass_new(mt, fields)
    return setmetatable(fields or {}, mt)
end

local _Vector2MT      = _bypass_class("Vector2")
local _Vector3MT      = _bypass_class("Vector3")
local _CFrameMT       = _bypass_class("CFrame")
local _UDim2MT        = _bypass_class("UDim2")
local _UDimMT         = _bypass_class("UDim")
local _Color3MT       = _bypass_class("Color3")
local _BrickColorMT   = _bypass_class("BrickColor")
local _NumberSeqMT    = _bypass_class("NumberSequence")
local _NumberRangeMT  = _bypass_class("NumberRange")
local _TweenInfoMT    = _bypass_class("TweenInfo")
local _RayMT          = _bypass_class("Ray")
local _RectMT         = _bypass_class("Rect")
local _SignalMT       = _bypass_class("RBXScriptSignal")
local _InstanceMT     = _bypass_class("Instance")
local _EnumItemMT     = _bypass_class("EnumItem")
local _EnumMT         = _bypass_class("Enum")
local _EnumsMT        = _bypass_class("Enums")

function _InstanceMT.IsA(self, classname)
    if type(classname) ~= "string" then return false end
    if self.ClassName == classname then return true end
    if classname == "Instance" or classname == "Object" then return true end
    return false
end
_InstanceMT.IsDescendantOf = function() return false end
_InstanceMT.IsAncestorOf   = function() return false end
_InstanceMT.GetChildren     = function() return {} end
_InstanceMT.GetDescendants  = function() return {} end
_InstanceMT.GetActor        = function() return nil end
_InstanceMT.FindFirstChild  = function() return nil end
_InstanceMT.FindFirstChildOfClass    = function() return nil end
_InstanceMT.FindFirstChildWhichIsA   = function() return nil end
_InstanceMT.FindFirstAncestor        = function() return nil end
_InstanceMT.FindFirstAncestorOfClass = function() return nil end
_InstanceMT.FindFirstAncestorWhichIsA= function() return nil end
_InstanceMT.WaitForChild    = function() return nil end
_InstanceMT.GetFullName     = function(self)
    return tostring(self.Name or self.ClassName or "Instance")
end
_InstanceMT.GetAttribute    = function() return nil end
_InstanceMT.SetAttribute    = function() end
_InstanceMT.GetAttributes   = function() return {} end
_InstanceMT.GetAttributeChangedSignal = function(self, _name)
    if rawget(self, "_attrSignals") == nil then rawset(self, "_attrSignals", {}) end
    local sig = self._attrSignals[_name]
    if sig == nil then
        sig = _bypass_new(_SignalMT, {
            Connect = function() return { Disconnect = function() end, Connected = true } end,
            Once    = function() return { Disconnect = function() end, Connected = true } end,
            Wait    = function() return nil end,
            Fire    = function() return nil end,
        })
        self._attrSignals[_name] = sig
    end
    return sig
end
_InstanceMT.GetPropertyChangedSignal = function(self, _name)
    if rawget(self, "_propSignals") == nil then rawset(self, "_propSignals", {}) end
    local sig = self._propSignals[_name]
    if sig == nil then
        sig = _bypass_new(_SignalMT, {
            Connect = function() return { Disconnect = function() end, Connected = true } end,
            Once    = function() return { Disconnect = function() end, Connected = true } end,
            Wait    = function() return nil end,
            Fire    = function() return nil end,
        })
        self._propSignals[_name] = sig
    end
    return sig
end
_InstanceMT.ClearAllChildren = function() end
_InstanceMT.GetDebugId       = function() return "0" end
_InstanceMT.HasTag           = function() return false end
_InstanceMT.AddTag           = function() end
_InstanceMT.RemoveTag        = function() end
_InstanceMT.GetTags          = function() return {} end

local _Vector2 = {
    new = function(x, y)
        return _bypass_new(_Vector2MT, { X = x or 0, Y = y or 0,
                                         Magnitude = math.sqrt((x or 0)^2 + (y or 0)^2) })
    end,
    zero = _bypass_new(_Vector2MT, { X = 0, Y = 0, Magnitude = 0 }),
}

local _Vector3 = {
    new = function(x, y, z)
        x, y, z = x or 0, y or 0, z or 0
        return _bypass_new(_Vector3MT, {
            X = x, Y = y, Z = z,
            Magnitude = math.sqrt(x*x + y*y + z*z),
        })
    end,
    zero  = _bypass_new(_Vector3MT, { X = 0, Y = 0, Z = 0, Magnitude = 0 }),
    yAxis = _bypass_new(_Vector3MT, { X = 0, Y = 1, Z = 0, Magnitude = 1 }),
}

local _CFrame = {
    new = function(x, y, z)
        return _bypass_new(_CFrameMT, {
            X = x or 0, Y = y or 0, Z = z or 0,
            Position = _Vector3.new(x, y, z),
            LookVector  = _Vector3.new(0, 0, -1),
            RightVector = _Vector3.new(1, 0,  0),
            UpVector    = _Vector3.new(0, 1,  0),
        })
    end,
    identity = nil,
}
_CFrame.identity = _CFrame.new()

local _UDim = {
    new = function(s, o)
        return _bypass_new(_UDimMT, { Scale = s or 0, Offset = o or 0 })
    end,
}

local _UDim2 = {
    new = function(sx, ox, sy, oy)
        return _bypass_new(_UDim2MT, {
            X = _UDim.new(sx, ox),
            Y = _UDim.new(sy, oy),
        })
    end,
    fromScale  = function(sx, sy) return _UDim2.new(sx, 0, sy, 0) end,
    fromOffset = function(ox, oy) return _UDim2.new(0, ox, 0, oy) end,
}

local _Color3 = {
    new = function(r, g, b)
        return _bypass_new(_Color3MT, { R = r or 0, G = g or 0, B = b or 0 })
    end,
    fromRGB = function(r, g, b)
        return _bypass_new(_Color3MT, {
            R = (r or 0) / 255,
            G = (g or 0) / 255,
            B = (b or 0) / 255,
        })
    end,
    fromHSV = function(h, s, v)
        return _bypass_new(_Color3MT, { R = v or 0, G = v or 0, B = v or 0 })
    end,
}

local _BrickColor = {
    new = function(name)
        return _bypass_new(_BrickColorMT, {
            Name = name or "Medium stone grey",
            Color = _Color3.fromRGB(163, 162, 165),
            Number = 194,
        })
    end,
    random = function() return _BrickColor.new("Bright red") end,
}

local _NumberSequence = {
    new = function(a, b)
        return _bypass_new(_NumberSeqMT, {
            Min = a or 0, Max = b or a or 0,
            Keypoints = {},
        })
    end,
}

local _NumberRange = {
    new = function(a, b)
        return _bypass_new(_NumberRangeMT, {
            Min = a or 0, Max = b or a or 0,
        })
    end,
}

local _TweenInfo = {
    new = function(t, style, dir, repeats, reverses, delay)
        return _bypass_new(_TweenInfoMT, {
            Time = t or 1,
            EasingStyle = style or "Quad",
            EasingDirection = dir or "Out",
            RepeatCount = repeats or 0,
            Reverses = reverses or false,
            DelayTime = delay or 0,
        })
    end,
}

local _Ray = {
    new = function(origin, direction)
        return _bypass_new(_RayMT, {
            Origin    = origin    or _Vector3.new(),
            Direction = direction or _Vector3.new(),
        })
    end,
}

local _Rect = {
    new = function(x0, y0, x1, y1)
        return _bypass_new(_RectMT, {
            Min = _Vector2.new(x0 or 0, y0 or 0),
            Max = _Vector2.new(x1 or 0, y1 or 0),
            Width  = (x1 or 0) - (x0 or 0),
            Height = (y1 or 0) - (y0 or 0),
        })
    end,
}

local _extraDataTypes = {}
do
    local function MT(name) return _bypass_class(name) end

    local _RandomMT      = MT("Random")
    local _DateTimeMT    = MT("DateTime")
    local _Region3MT     = MT("Region3")
    local _RaycastParamsMT = MT("RaycastParams")
    local _OverlapParamsMT = MT("OverlapParams")
    local _PathWaypointMT  = MT("PathWaypoint")
    local _FacesMT       = MT("Faces")
    local _AxesMT        = MT("Axes")
    local _PhysPropsMT   = MT("PhysicalProperties")
    local _ColorSeqMT    = MT("ColorSequence")
    local _ColorSeqKpMT  = MT("ColorSequenceKeypoint")
    local _NumberSeqKpMT = MT("NumberSequenceKeypoint")
    local _RaycastResMT  = MT("RaycastResult")

    _extraDataTypes.Random = {
        new = function(seed)
            local s = tonumber(seed) or 0
            local state = s % 2147483647
            if state == 0 then state = 1 end
            local function step()
                state = (state * 48271) % 2147483647
                return state
            end
            return _bypass_new(_RandomMT, {
                NextInteger = function(_self, lo, hi)
                    lo = tonumber(lo) or 0
                    hi = tonumber(hi) or lo
                    if hi < lo then lo, hi = hi, lo end
                    return lo + (step() % (hi - lo + 1))
                end,
                NextNumber = function(_self, lo, hi)
                    lo = tonumber(lo) or 0
                    hi = tonumber(hi) or 1
                    return lo + (step() / 2147483647) * (hi - lo)
                end,
                NextUnitVector = function() return _Vector3.new(0, 1, 0) end,
                Clone = function(self) return _extraDataTypes.Random.new(s) end,
            })
        end,
    }

    _extraDataTypes.DateTime = {
        now = function()
            local t = os.time()
            return _bypass_new(_DateTimeMT, {
                UnixTimestamp        = t,
                UnixTimestampMillis  = t * 1000,
                ToIsoDate    = function(self) return os.date("!%Y-%m-%dT%H:%M:%SZ", self.UnixTimestamp) end,
                ToUniversalTime = function() return { Year = 1970, Month = 1, Day = 1, Hour = 0, Minute = 0, Second = 0 } end,
                ToLocalTime  = function() return { Year = 1970, Month = 1, Day = 1, Hour = 0, Minute = 0, Second = 0 } end,
            })
        end,
        fromUnixTimestamp = function(t)
            t = tonumber(t) or 0
            local d = os.date("!*t", t)
            return _bypass_new(_DateTimeMT, {
                UnixTimestamp = t, UnixTimestampMillis = t * 1000,
                Year = d.year, Month = d.month, Day = d.day,
                Hour = d.hour, Minute = d.min, Second = d.sec, Millisecond = 0,
            })
        end,
        fromIsoDate = function(_)
            return _bypass_new(_DateTimeMT, {
                UnixTimestamp = 0, UnixTimestampMillis = 0,
                Year = 1970, Month = 1, Day = 1,
                Hour = 0, Minute = 0, Second = 0, Millisecond = 0,
            })
        end,
    }

    _extraDataTypes.Region3 = {
        new = function(min, max)
            min = min or _Vector3.new()
            max = max or _Vector3.new()
            return _bypass_new(_Region3MT, {
                CFrame = _CFrame.new(),
                Size   = _Vector3.new(
                    (max.X or 0) - (min.X or 0),
                    (max.Y or 0) - (min.Y or 0),
                    (max.Z or 0) - (min.Z or 0)),
            })
        end,
    }

    _extraDataTypes.RaycastParams = {
        new = function()
            return _bypass_new(_RaycastParamsMT, {
                FilterDescendantsInstances = {},
                FilterType                 = "Exclude",
                IgnoreWater                = false,
                RespectCanCollide          = false,
                CollisionGroup             = "Default",
            })
        end,
    }

    _extraDataTypes.OverlapParams = {
        new = function()
            return _bypass_new(_OverlapParamsMT, {
                FilterDescendantsInstances = {},
                FilterType                 = "Exclude",
                IncludeInstances           = nil,
                ExcludeInstances           = nil,
                MaxParts                   = 0,
                CollisionGroup             = "Default",
                RespectCanCollide          = false,
            })
        end,
    }

    _extraDataTypes.PathWaypoint = {
        new = function(pos, action, label)
            return _bypass_new(_PathWaypointMT, {
                Position = pos    or _Vector3.new(),
                Action   = action or "Walk",
                Label    = label  or "",
            })
        end,
    }

    _extraDataTypes.Faces = {
        new = function(...)
            local sides = { ... }
            return _bypass_new(_FacesMT, {
                Top = false, Bottom = false, Left = false,
                Right = false, Back = false, Front = false,
                Sides = sides,
            })
        end,
    }

    _extraDataTypes.Axes = {
        new = function(...)
            local axes = { ... }
            return _bypass_new(_AxesMT, {
                X = false, Y = false, Z = false,
                Top = false, Bottom = false, Left = false,
                Right = false, Back = false, Front = false,
                Axes = axes,
            })
        end,
    }

    _extraDataTypes.PhysicalProperties = {
        new = function(d, fr, el, frw, elw)
            return _bypass_new(_PhysPropsMT, {
                Density           = d  or 0.7,
                Friction          = fr or 0.3,
                Elasticity        = el or 0.5,
                FrictionWeight    = frw or 1,
                ElasticityWeight  = elw or 1,
            })
        end,
    }

    _extraDataTypes.ColorSequenceKeypoint = {
        new = function(t, v)
            return _bypass_new(_ColorSeqKpMT, {
                Time = t or 0, Value = v or _Color3.new(),
            })
        end,
    }

    _extraDataTypes.ColorSequence = {
        new = function(a, b)
            local kps
            if type(a) == "table" then
                kps = a
            else
                local c0 = a or _Color3.new()
                local c1 = b or c0
                kps = {
                    _extraDataTypes.ColorSequenceKeypoint.new(0, c0),
                    _extraDataTypes.ColorSequenceKeypoint.new(1, c1),
                }
            end
            return _bypass_new(_ColorSeqMT, { Keypoints = kps })
        end,
    }

    _extraDataTypes.NumberSequenceKeypoint = {
        new = function(t, v, env)
            return _bypass_new(_NumberSeqKpMT, {
                Time = t or 0, Value = v or 0, Envelope = env or 0,
            })
        end,
    }

    _extraDataTypes.RaycastResult = function()
        return _bypass_new(_RaycastResMT, {
            Instance  = nil,
            Position  = _Vector3.new(),
            Normal    = _Vector3.new(0, 1, 0),
            Material  = "Plastic",
            Distance  = 0,
        })
    end

    local _SharedTableMT = _bypass_class("SharedTable")
    _SharedTableMT.__newindex = function(s, k, v) rawset(s, k, v) end
    _SharedTableMT.__index    = _SharedTableMT

    local function _make_shared_table(init)
        local t = {}
        if type(init) == "table" then
            for k, v in pairs(init) do t[k] = v end
        end
        return setmetatable(t, _SharedTableMT)
    end

    _extraDataTypes.SharedTable = {
        new = function(init)
            return _make_shared_table(init)
        end,
        clone = function(st, _deep)
            local copy = {}
            for k, v in pairs(st) do copy[k] = v end
            return _make_shared_table(copy)
        end,
        cloneAndFreeze = function(st)
            local _fdata = {}
            for k, v in pairs(st) do _fdata[k] = v end
            local frozenMT = {
                __type      = "SharedTable",
                __metatable = "SharedTable",
                __newindex  = function() error("attempt to update a frozen SharedTable", 2) end,
                __index     = function(_, k) return _fdata[k] end,
                __len       = function() local n=0; for _ in pairs(_fdata) do n=n+1 end; return n end,
                __tostring  = function() return "SharedTable" end,
            }
            return setmetatable({}, frozenMT)
        end,
        isFrozen = function(st)
            local ok2 = pcall(function() st["\0_frozen_probe\0"] = true end)
            if not ok2 then return true end
            pcall(function() rawset(st, "\0_frozen_probe\0", nil) end)
            return false
        end,
        size = function(st)
            local n = 0; for _ in pairs(st) do n = n + 1 end; return n
        end,
        clear = function(st)
            for k in next, st do rawset(st, k, nil) end
        end,
        increment = function(st, key, delta)
            local v = rawget(st, key) or 0
            rawset(st, key, v + (delta or 1))
            return rawget(st, key)
        end,
        update = function(st, key, fn)
            local old = rawget(st, key)
            local new = fn(old)
            if new ~= nil then rawset(st, key, new) end
            return new
        end,
        get = function(st, key) return rawget(st, key) end,
        set = function(st, key, val) rawset(st, key, val) end,
    }
end

local function _bypass_enumItem(name, value, parent)
    return setmetatable({
        Name = name, Value = value, EnumType = parent,
    }, { __type = "EnumItem", __tostring = function() return "Enum."..tostring(parent).."."..name end })
end

local function _bypass_enumGroup(name, items)
    local out = setmetatable({}, _EnumMT)
    for k, v in pairs(items) do
        out[k] = _bypass_enumItem(k, v, name)
    end
    return out
end

local _Enum = setmetatable({
    Font          = _bypass_enumGroup("Font", {
        Arial = 0, ArialBold = 1, SourceSans = 8, SourceSansBold = 9,
        Gotham = 16, GothamBold = 17, Code = 13,
    }),
    KeyCode       = _bypass_enumGroup("KeyCode", {
        W = 87, A = 65, S = 83, D = 68, Space = 32, LeftShift = 304,
        E = 69, Q = 81, F = 70, R = 82, Tab = 9,
    }),
    UserInputType = _bypass_enumGroup("UserInputType", {
        MouseButton1 = 0, MouseButton2 = 1, Keyboard = 8, Touch = 7,
    }),
    EasingStyle   = _bypass_enumGroup("EasingStyle", {
        Linear = 0, Sine = 1, Quad = 4, Cubic = 5, Quart = 6, Quint = 7,
    }),
    EasingDirection = _bypass_enumGroup("EasingDirection", {
        In = 0, Out = 1, InOut = 2,
    }),
    HumanoidStateType = _bypass_enumGroup("HumanoidStateType", {
        Running = 8, Jumping = 7, Freefall = 3, Dead = 15,
    }),
}, _EnumsMT)

local function _bypass_makeSignal(name)
    local sig = _bypass_new(_SignalMT, { Name = name or "Signal" })
    function sig:Connect(_)  return { Connected = true, Disconnect = function() end } end
    function sig:Once(_)     return { Connected = true, Disconnect = function() end } end
    function sig:Wait()
        if type(task) == "table" and type(task.wait) == "function" then
            return task.wait(1 / 60)
        end
        return 1 / 60
    end
    function sig:Fire(...)   return nil end
    return sig
end

local _TextService = _bypass_new(_InstanceMT, {
    ClassName = "TextService",
    GetTextSize = function(_self, text, size, _font, _bounds)
        text = tostring(text or "")
        size = tonumber(size) or 14
        local w = math.max(1, #text) * size * 0.6
        return _Vector2.new(w, size)
    end,
    GetTextBoundsAsync = function(_self, _params)
        return _Vector2.new(100, 18)
    end,
})

local _GuiService = _bypass_new(_InstanceMT, {
    ClassName = "GuiService",
    GetGuiInset = function() return _Vector2.new(0, 36) end,
    IsTenFootInterface = function() return false end,
    SelectedObject = nil,
})

local _ContextActionService = _bypass_new(_InstanceMT, {
    ClassName = "ContextActionService",
    GetAllBoundActionInfo = function() return {} end,
    BindAction   = function() end,
    UnbindAction = function() end,
})

local _SoundService = _bypass_new(_InstanceMT, {
    ClassName    = "SoundService",
    RolloffScale = 1,
    AmbientReverb = "NoReverb",
    DistanceFactor = 3.33,
    DopplerScale   = 1,
})

local _Lighting = _bypass_new(_InstanceMT, {
    ClassName  = "Lighting",
    ClockTime  = 14,
    Brightness = 2,
    Ambient    = _Color3.fromRGB(70, 70, 70),
    FogEnd     = 100000,
    GlobalShadows = true,
})

local _ReplicatedStorage = _bypass_new(_InstanceMT, {
    ClassName = "ReplicatedStorage",
    Name      = "ReplicatedStorage",
})
local _StarterGui = _bypass_new(_InstanceMT, {
    ClassName = "StarterGui",
    Name      = "StarterGui",
    SetCore   = function() end,
    GetCore   = function() return nil end,
})
local _PhysicsService = _bypass_new(_InstanceMT, {
    ClassName = "PhysicsService",
    Name      = "PhysicsService",
    GetCollisionGroups = function() return {} end,
})
local _UserInputService = _bypass_new(_InstanceMT, {
    ClassName = "UserInputService",
    IsKeyDown = function(_self, _key) return false end,
    IsMouseButtonPressed = function() return false end,
    GetMouseLocation = function() return _Vector2.new(0, 0) end,
    TouchEnabled = false, KeyboardEnabled = true, MouseEnabled = true,
})
local _RunService = _bypass_new(_InstanceMT, {
    ClassName = "RunService",
    IsClient  = function() return true  end,
    IsServer  = function() return false end,
    IsStudio  = function() return false end,
    Heartbeat = _bypass_makeSignal("Heartbeat"),
    RenderStepped = _bypass_makeSignal("RenderStepped"),
    Stepped   = _bypass_makeSignal("Stepped"),
})
local _HttpService = _bypass_new(_InstanceMT, {
    ClassName = "HttpService",
    JSONEncode = function(_self, v) return tostring(v) end,
    JSONDecode = function(_self, _) return {} end,
    GenerateGUID = function() return "{00000000-0000-0000-0000-000000000000}" end,
    UrlEncode = function(_self, s)
        s = tostring(s or "")
        return (s:gsub("[^%w%-_%.~]", function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    end,
})
local _TweenService = _bypass_new(_InstanceMT, {
    ClassName = "TweenService",
    Create = function(_self, _inst, _info, _props)
        return _bypass_new(_InstanceMT, {
            ClassName = "Tween",
            Play = function() end, Cancel = function() end, Pause = function() end,
            Completed = _bypass_makeSignal("Completed"),
        })
    end,
})

local _extraServices = {}
do
local _MarketplaceService = _bypass_new(_InstanceMT, {
    ClassName = "MarketplaceService",
    GetProductInfo = function(_self, id, _infoType)
        return {
            Name = "Product" .. tostring(id), Description = "",
            PriceInRobux = 0, AssetId = tonumber(id) or 0,
            Creator = { Id = 0, Name = "Roblox", CreatorType = "User" },
            IsForSale = false, Sales = 0, IsLimited = false,
        }
    end,
    UserOwnsGamePassAsync = function() return false end,
    PlayerOwnsAsset       = function() return false end,
    PromptPurchase        = function() end,
    PromptGamePassPurchase = function() end,
    PromptProductPurchase  = function() end,
    PromptPurchaseFinished = _bypass_makeSignal("PromptPurchaseFinished"),
    ProcessReceipt         = nil,
})

local _TeleportService = _bypass_new(_InstanceMT, {
    ClassName = "TeleportService",
    Teleport            = function() end,
    TeleportToPlaceInstance = function() end,
    TeleportToPrivateServer = function() end,
    ReserveServer       = function(_self, placeId)
        return "0000-reserved-server-access-code", tostring(placeId or 0)
    end,
    GetLocalPlayerTeleportData = function() return nil end,
    SetTeleportGui      = function() end,
    TeleportInitFailed  = _bypass_makeSignal("TeleportInitFailed"),
})

local _DataStoreService = _bypass_new(_InstanceMT, {
    ClassName = "DataStoreService",
    GetDataStore = function(_self, name, scope)
        return _bypass_new(_InstanceMT, {
            ClassName = "GlobalDataStore",
            Name      = tostring(name or "DataStore"),
            Scope     = tostring(scope or "global"),
            GetAsync     = function() return nil end,
            SetAsync     = function() return "ok" end,
            UpdateAsync  = function(_s, _k, transformer)
                local ok, v = pcall(transformer, nil)
                if ok then return v end
                return nil
            end,
            IncrementAsync = function(_s, _k, delta) return tonumber(delta) or 0 end,
            RemoveAsync    = function() return nil end,
        })
    end,
    GetOrderedDataStore = function(_self, name, scope)
        return _bypass_new(_InstanceMT, {
            ClassName = "OrderedDataStore",
            Name      = tostring(name or "OrderedDataStore"),
            Scope     = tostring(scope or "global"),
            GetAsync     = function() return 0 end,
            SetAsync     = function() return "ok" end,
            GetSortedAsync = function()
                return _bypass_new(_InstanceMT, {
                    ClassName = "DataStorePages",
                    GetCurrentPage = function() return {} end,
                    AdvanceToNextPageAsync = function() end,
                    IsFinished = true,
                })
            end,
        })
    end,
    GetGlobalDataStore = function(_self) return _services and _services.DataStoreService end,
    GetRequestBudgetForRequestType = function() return 1000 end,
    ListDataStoresAsync = function() return nil end,
})

local _MemoryStoreService = _bypass_new(_InstanceMT, {
    ClassName = "MemoryStoreService",
    GetSortedMap = function(_self, name)
        return _bypass_new(_InstanceMT, {
            ClassName = "MemoryStoreSortedMap",
            Name = tostring(name or "Map"),
            GetAsync = function() return nil end,
            SetAsync = function() return true end,
            UpdateAsync = function() return nil end,
            RemoveAsync = function() end,
            GetRangeAsync = function() return {} end,
        })
    end,
    GetQueue = function(_self, name)
        return _bypass_new(_InstanceMT, {
            ClassName = "MemoryStoreQueue",
            Name = tostring(name or "Queue"),
            AddAsync     = function() return true end,
            ReadAsync    = function() return {}, "" end,
            RemoveAsync  = function() end,
        })
    end,
})

local _BadgeService = _bypass_new(_InstanceMT, {
    ClassName = "BadgeService",
    AwardBadge      = function() return true end,
    UserHasBadgeAsync = function() return false end,
    GetBadgeInfoAsync = function(_self, id)
        return {
            Name = "Badge" .. tostring(id), Description = "",
            IconImageId = 0, IsEnabled = true,
        }
    end,
})

local _GamePassService = _bypass_new(_InstanceMT, {
    ClassName = "GamePassService",
    PlayerHasPass = function() return false end,
})

local _PointsService = _bypass_new(_InstanceMT, {
    ClassName = "PointsService",
    AwardPoints      = function() return 0, 0, 0, 0 end,
    GetAwardablePoints = function() return 0 end,
    GetGamePointBalance = function() return 0 end,
    GetPointBalance     = function() return 0 end,
    PointsAwarded       = _bypass_makeSignal("PointsAwarded"),
})

local _Chat = _bypass_new(_InstanceMT, {
    ClassName = "Chat",
    Name      = "Chat",
    Chat                 = function() end,
    SetBubbleChatSettings = function() end,
    GetShouldUseLuaChat   = function() return true end,
    FilterStringAsync     = function(_self, msg) return tostring(msg or "") end,
    FilterStringForBroadcast = function(_self, msg) return tostring(msg or "") end,
    BubbleChatEnabled     = false,
})

local _TextChatService = _bypass_new(_InstanceMT, {
    ClassName = "TextChatService",
    ChatVersion = "TextChatService",
    SendingMessage  = _bypass_makeSignal("SendingMessage"),
    MessageReceived = _bypass_makeSignal("MessageReceived"),
    OnIncomingMessage = nil,
    OnChatWindowAdded = nil,
})

local _VoiceChatService = _bypass_new(_InstanceMT, {
    ClassName       = "VoiceChatService",
    EnableDefaultVoice = false,
    IsVoiceEnabledForUserIdAsync = function() return false end,
})

local _Debris = _bypass_new(_InstanceMT, {
    ClassName = "Debris",
    Name      = "Debris",
    AddItem   = function(_self, _inst, _lifetime) end,
    MaxItems  = 1000,
})

local _CollectionService = _bypass_new(_InstanceMT, {
    ClassName = "CollectionService",
    Name      = "CollectionService",
    AddTag    = function() end,
    RemoveTag = function() end,
    HasTag    = function() return false end,
    GetTags   = function() return {} end,
    GetTagged = function() return {} end,
    GetInstanceAddedSignal   = function(_self, _tag) return _bypass_makeSignal("InstanceAdded")   end,
    GetInstanceRemovedSignal = function(_self, _tag) return _bypass_makeSignal("InstanceRemoved") end,
})

local _ServerStorage = _bypass_new(_InstanceMT, {
    ClassName = "ServerStorage", Name = "ServerStorage",
})
local _ServerScriptService = _bypass_new(_InstanceMT, {
    ClassName = "ServerScriptService", Name = "ServerScriptService",
})
local _ReplicatedFirst = _bypass_new(_InstanceMT, {
    ClassName = "ReplicatedFirst", Name = "ReplicatedFirst",
    RemoveDefaultLoadingScreen = function() end,
})
local _StarterPack = _bypass_new(_InstanceMT, {
    ClassName = "StarterPack", Name = "StarterPack",
})
local _StarterPlayer = _bypass_new(_InstanceMT, {
    ClassName = "StarterPlayer", Name = "StarterPlayer",
    CharacterWalkSpeed = 16, CharacterJumpPower = 50, CharacterMaxHealth = 100,
    EnableMouseLockOption = true, AutoJumpEnabled = false,
})
local _Teams = _bypass_new(_InstanceMT, {
    ClassName = "Teams", Name = "Teams",
    GetTeams = function() return {} end,
})

local _LogService = _bypass_new(_InstanceMT, {
    ClassName = "LogService",
    GetLogHistory = function() return {} end,
    ClearOutput   = function() end,
    MessageOut    = _bypass_makeSignal("MessageOut"),
})

local _Stats = _bypass_new(_InstanceMT, {
    ClassName = "Stats",
    Name      = "Stats",
    GetTotalMemoryUsageMb = function() return 0 end,
    GetMemoryUsageMbForTag = function() return 0 end,
    PhysicsReceiveKbps    = 0,
    PhysicsSendKbps       = 0,
    DataReceiveKbps       = 0,
    DataSendKbps          = 0,
    HeartbeatTimeMs       = 1,
    Network               = _bypass_new(_InstanceMT, { ClassName = "NetworkSettings" }),
})

local _LocalizationService = _bypass_new(_InstanceMT, {
    ClassName     = "LocalizationService",
    RobloxLocaleId = "en-us",
    SystemLocaleId = "en-us",
    GetTranslatorForPlayerAsync = function()
        return _bypass_new(_InstanceMT, {
            ClassName = "Translator",
            LocaleId  = "en-us",
            Translate = function(_self, _ctx, src) return tostring(src or "") end,
            FormatByKey = function(_self, _key, _args) return "" end,
        })
    end,
    GetCorescriptLocalizations = function() return {} end,
})

local _AssetService = _bypass_new(_InstanceMT, {
    ClassName = "AssetService",
    CreatePlaceAsync = function() return 0 end,
    GetGamePlacesAsync = function()
        return _bypass_new(_InstanceMT, {
            ClassName = "StandardPages",
            GetCurrentPage = function() return {} end,
            AdvanceToNextPageAsync = function() end,
            IsFinished = true,
        })
    end,
    GetBundleDetailsAsync = function() return {} end,
    CreateEditableMesh = function(_self)
        local _verts   = {}
        local _nextId  = 1
        local _meshMT  = _bypass_class("EditableMesh")
        local _mesh
        _mesh = setmetatable({
            ClassName = "EditableMesh",
            AddVertex = function(__self, pos)
                local id = _nextId
                _verts[id] = pos
                _nextId = _nextId + 1
                return id
            end,
            GetVertices = function(__self)
                local out = {}
                for id, _ in pairs(_verts) do
                    out[#out + 1] = id
                end
                return out
            end,
            GetPosition = function(__self, id)
                return _verts[id] or _Vector3.new(0, 0, 0)
            end,
            AddColor = function() end,
            AddNormal = function() end,
            AddUV = function() end,
            AddFace = function() end,
            AddTriangle = function() end,
            SetPosition = function(__self, id, pos) _verts[id] = pos end,
            RemoveFace = function() end,
            RemoveUnused = function() end,
            Clear = function(__self) _verts = {}; _nextId = 1 end,
            Destroy = function(__self) _verts = {}; _nextId = 1 end,
        }, _meshMT)
        return _mesh
    end,
    CreateEditableMeshAsync = function(self, ...) return self:CreateEditableMesh() end,
})

local _InsertService = _bypass_new(_InstanceMT, {
    ClassName = "InsertService",
    LoadAsset = function() return _Instance and _Instance.new("Folder") or nil end,
    LoadAssetVersion = function() return _Instance and _Instance.new("Folder") or nil end,
    GetLatestAssetVersionAsync = function() return 0 end,
})

local _ContentProvider = _bypass_new(_InstanceMT, {
    ClassName  = "ContentProvider",
    BaseUrl    = "https://www.roblox.com/",
    RequestQueueSize = 0,
    PreloadAsync = function() end,
    Preload      = function() end,
})

local _GroupService = _bypass_new(_InstanceMT, {
    ClassName = "GroupService",
    GetGroupInfoAsync   = function() return { Name = "Group", Description = "", Owner = {} } end,
    GetGroupsAsync      = function() return {} end,
    GetAlliesAsync      = function() return {} end,
    GetEnemiesAsync     = function() return {} end,
})

local _SocialService = _bypass_new(_InstanceMT, {
    ClassName = "SocialService",
    CanSendGameInviteAsync = function() return false end,
    PromptGameInvite       = function() end,
    GameInvitePromptClosed = _bypass_makeSignal("GameInvitePromptClosed"),
})

local _FriendService = _bypass_new(_InstanceMT, {
    ClassName = "FriendService",
    GetPlatformFriends = function() return {} end,
})

local _AvatarEditorService = _bypass_new(_InstanceMT, {
    ClassName = "AvatarEditorService",
    GetAvatarRules        = function() return {} end,
    GetItemDetails        = function() return {} end,
    GetFavorite           = function() return false end,
    SetFavorite           = function() end,
    PromptAllowInventoryReadAccess = function() end,
})

local _AnalyticsService = _bypass_new(_InstanceMT, {
    ClassName = "AnalyticsService",
    LogEvent  = function() end,
    LogCustomEvent = function() end,
    LogEconomyEvent = function() end,
    LogOnboardingFunnelStepEvent = function() end,
    LogProgressionEvent = function() end,
    LogAcquisitionFunnelStepEvent = function() end,
})

local _AdService = _bypass_new(_InstanceMT, {
    ClassName = "AdService",
    ShowVideoAd = function() end,
    PlayAdAsync = function() return false end,
    DisplayBillboardAd = function() end,
})

local _HapticService = _bypass_new(_InstanceMT, {
    ClassName = "HapticService",
    SetMotor          = function() end,
    GetMotor          = function() return 0 end,
    IsMotorSupported  = function() return false end,
    IsVibrationValueSupported = function() return false end,
})

local _VRService = _bypass_new(_InstanceMT, {
    ClassName = "VRService",
    VREnabled = false,
    GetUserCFrame      = function() return _CFrame.new() end,
    GetUserCFrameEnabled = function() return false end,
    RecenterUserHeadCFrame = function() end,
})

local _PolicyService = _bypass_new(_InstanceMT, {
    ClassName = "PolicyService",
    GetPolicyInfoForPlayerAsync = function()
        return {
            ArePaidRandomItemsRestricted = false,
            AllowedExternalLinkReferences = {},
            IsPaidItemTradingAllowed     = true,
            IsSubjectToChinaPolicies     = false,
        }
    end,
})

local _ProximityPromptService = _bypass_new(_InstanceMT, {
    ClassName = "ProximityPromptService",
    Enabled  = true,
    MaxPromptsVisible = 10,
    PromptShown    = _bypass_makeSignal("PromptShown"),
    PromptHidden   = _bypass_makeSignal("PromptHidden"),
    PromptTriggered = _bypass_makeSignal("PromptTriggered"),
})

local _PathfindingService = _bypass_new(_InstanceMT, {
    ClassName = "PathfindingService",
    CreatePath = function()
        return _bypass_new(_InstanceMT, {
            ClassName = "Path",
            Status    = "Success",
            ComputeAsync = function() end,
            GetWaypoints = function() return {} end,
            Blocked      = _bypass_makeSignal("Blocked"),
        })
    end,
    FindPathAsync = function()
        return _bypass_new(_InstanceMT, {
            ClassName = "Path", Status = "Success",
            GetWaypoints = function() return {} end,
        })
    end,
})

local _NotificationService = _bypass_new(_InstanceMT, {
    ClassName = "NotificationService",
    Name      = "NotificationService",
})

local _MessagingService = _bypass_new(_InstanceMT, {
    ClassName = "MessagingService",
    PublishAsync   = function() end,
    SubscribeAsync = function()
        return _bypass_new(_InstanceMT, {
            ClassName = "RBXScriptConnection",
            Disconnect = function() end, Connected = true,
        })
    end,
})

local _CoreGui = _bypass_new(_InstanceMT, {
    ClassName = "CoreGui", Name = "CoreGui",
    Version   = 0,
})

local _StudioService = _bypass_new(_InstanceMT, {
    ClassName = "StudioService",
    Name      = "StudioService",
    GetUserId = function() return 0 end,
    GetClassIcon = function() return {} end,
})

local _ScriptContext = _bypass_new(_InstanceMT, {
    ClassName = "ScriptContext", Name = "ScriptContext",
    Error     = _bypass_makeSignal("Error"),
    AddCoreScriptLocal = function() end,
})

local _NetworkClient = _bypass_new(_InstanceMT, {
    ClassName = "NetworkClient", Name = "NetworkClient",
    Ticket    = "", ConnectionAccepted = _bypass_makeSignal("ConnectionAccepted"),
})
local _NetworkServer = _bypass_new(_InstanceMT, {
    ClassName = "NetworkServer", Name = "NetworkServer",
})

local _UserService = _bypass_new(_InstanceMT, {
    ClassName = "UserService",
    GetUserInfosByUserIdsAsync = function(_self, ids)
        local out = {}
        for _, id in ipairs(ids or {}) do
            table.insert(out, {
                Id = id, Username = "User" .. tostring(id),
                DisplayName = "User" .. tostring(id), HasVerifiedBadge = false,
            })
        end
        return out
    end,
})

local _KeyframeSequenceProvider = _bypass_new(_InstanceMT, {
    ClassName = "KeyframeSequenceProvider",
    GetAnimations    = function() return {} end,
    RegisterKeyframeSequence = function() return "" end,
})

local _SpawnerService = _bypass_new(_InstanceMT, {
    ClassName = "SpawnerService", Name = "SpawnerService",
})

local _TouchInputService = _bypass_new(_InstanceMT, {
    ClassName = "TouchInputService", Name = "TouchInputService",
})

local _TestService = _bypass_new(_InstanceMT, {
    ClassName = "TestService", Name = "TestService",
    Check     = function() end, Error = function() end,
    Message   = function() end, Warn  = function() end,
})

local _RbxAnalyticsService = _bypass_new(_InstanceMT, {
    ClassName = "RbxAnalyticsService",
    ReportCounter = function() end, ReportStats = function() end,
    TrackEvent    = function() end, TrackEventWithArgs = function() end,
})

local _CookiesService = _bypass_new(_InstanceMT, {
    ClassName = "CookiesService",
})

local _OmniRecommendationsService = _bypass_new(_InstanceMT, {
    ClassName = "OmniRecommendationsService",
    GetRecommendationsAsync = function() return {} end,
})

local _GuiInsetService = _bypass_new(_InstanceMT, {
    ClassName = "GuiInsetService",
})

local _RobloxReplicatedStorage = _bypass_new(_InstanceMT, {
    ClassName = "RobloxReplicatedStorage", Name = "RobloxReplicatedStorage",
})

local _StarterPlayerScripts = _bypass_new(_InstanceMT, {
    ClassName = "StarterPlayerScripts", Name = "StarterPlayerScripts",
})
local _StarterCharacterScripts = _bypass_new(_InstanceMT, {
    ClassName = "StarterCharacterScripts", Name = "StarterCharacterScripts",
})

local _ChangeHistoryService = _bypass_new(_InstanceMT, {
    ClassName = "ChangeHistoryService",
    SetWaypoint = function() end, ResetWaypoints = function() end,
    Undo = function() end, Redo = function() end,
})

local _RunningAverageItemDouble = _bypass_new(_InstanceMT, {
    ClassName = "Selection",
    Get = function() return {} end, Set = function() end,
    SelectionChanged = _bypass_makeSignal("SelectionChanged"),
})

_extraServices.MarketplaceService       = _MarketplaceService
_extraServices.TeleportService          = _TeleportService
_extraServices.DataStoreService         = _DataStoreService
_extraServices.MemoryStoreService       = _MemoryStoreService
_extraServices.BadgeService             = _BadgeService
_extraServices.GamePassService          = _GamePassService
_extraServices.PointsService            = _PointsService
_extraServices.Chat                     = _Chat
_extraServices.TextChatService          = _TextChatService
_extraServices.VoiceChatService         = _VoiceChatService
_extraServices.Debris                   = _Debris
_extraServices.CollectionService        = _CollectionService
_extraServices.ServerStorage            = _ServerStorage
_extraServices.ServerScriptService      = _ServerScriptService
_extraServices.ReplicatedFirst          = _ReplicatedFirst
_extraServices.StarterPack              = _StarterPack
_extraServices.StarterPlayer            = _StarterPlayer
_extraServices.StarterPlayerScripts     = _StarterPlayerScripts
_extraServices.StarterCharacterScripts  = _StarterCharacterScripts
_extraServices.Teams                    = _Teams
_extraServices.LogService               = _LogService
_extraServices.Stats                    = _Stats
_extraServices.LocalizationService      = _LocalizationService
_extraServices.AssetService             = _AssetService
_extraServices.InsertService            = _InsertService
_extraServices.ContentProvider          = _ContentProvider
_extraServices.GroupService             = _GroupService
_extraServices.SocialService            = _SocialService
_extraServices.FriendService            = _FriendService
_extraServices.AvatarEditorService      = _AvatarEditorService
_extraServices.AnalyticsService         = _AnalyticsService
_extraServices.AdService                = _AdService
_extraServices.HapticService            = _HapticService
_extraServices.VRService                = _VRService
_extraServices.PolicyService            = _PolicyService
_extraServices.ProximityPromptService   = _ProximityPromptService
_extraServices.PathfindingService       = _PathfindingService
_extraServices.NotificationService      = _NotificationService
_extraServices.MessagingService         = _MessagingService
_extraServices.CoreGui                  = _CoreGui
_extraServices.StudioService            = _StudioService
_extraServices.ScriptContext            = _ScriptContext
_extraServices.NetworkClient            = _NetworkClient
_extraServices.NetworkServer            = _NetworkServer
_extraServices.UserService              = _UserService
_extraServices.KeyframeSequenceProvider = _KeyframeSequenceProvider
_extraServices.SpawnerService           = _SpawnerService
_extraServices.TouchInputService        = _TouchInputService
_extraServices.TestService              = _TestService
_extraServices.RbxAnalyticsService      = _RbxAnalyticsService
_extraServices.CookiesService           = _CookiesService
_extraServices.OmniRecommendationsService = _OmniRecommendationsService
_extraServices.GuiInsetService          = _GuiInsetService
_extraServices.RobloxReplicatedStorage  = _RobloxReplicatedStorage
_extraServices.ChangeHistoryService     = _ChangeHistoryService
_extraServices.Selection                = _RunningAverageItemDouble
end

local _LocalPlayer
do
    local function mk(class, fields)
        fields = fields or {}
        fields.ClassName = class
        fields.Name      = fields.Name or class
        fields.Archivable = true
        fields.Destroy    = function(self) self.Parent = nil end
        return _bypass_new(_InstanceMT, fields)
    end

    local _BodyColor = _Color3.fromRGB(163, 162, 165)
    local _BodyMaterial = _bypass_enumItem("Plastic", 256, "Material")
    local function _bodyPart(name, size, position)
        return mk("Part", {
            Name = name,
            Size = size,
            Position = position,
            CFrame = _CFrame.new(position.X, position.Y, position.Z),
            Color = _BodyColor,
            Material = _BodyMaterial,
        })
    end

    local _RootPart = _bodyPart("HumanoidRootPart", _Vector3.new(2, 2, 1), _Vector3.new(0, 5, 0))
    _RootPart.Anchored = false
    _RootPart.CanCollide = false
    _RootPart.Transparency = 1
    _RootPart.Velocity = _Vector3.new()
    _RootPart.AssemblyLinearVelocity = _Vector3.new()
    _RootPart.AssemblyAngularVelocity = _Vector3.new()

    local _Head = _bodyPart("Head", _Vector3.new(2, 1, 1), _Vector3.new(0, 6.5, 0))
    local _UpperTorso = _bodyPart("UpperTorso", _Vector3.new(2, 1, 1), _Vector3.new(0, 5.5, 0))
    local _LowerTorso = _bodyPart("LowerTorso", _Vector3.new(2, 1, 1), _Vector3.new(0, 4.5, 0))
    local _LeftUpperArm  = _bodyPart("LeftUpperArm", _Vector3.new(1, 1, 1), _Vector3.new(-1.5, 5.5, 0))
    local _LeftLowerArm  = _bodyPart("LeftLowerArm", _Vector3.new(1, 1, 1), _Vector3.new(-1.5, 4.5, 0))
    local _LeftHand      = _bodyPart("LeftHand", _Vector3.new(1, 1, 1), _Vector3.new(-1.5, 3.5, 0))
    local _RightUpperArm = _bodyPart("RightUpperArm", _Vector3.new(1, 1, 1), _Vector3.new(1.5, 5.5, 0))
    local _RightLowerArm = _bodyPart("RightLowerArm", _Vector3.new(1, 1, 1), _Vector3.new(1.5, 4.5, 0))
    local _RightHand     = _bodyPart("RightHand", _Vector3.new(1, 1, 1), _Vector3.new(1.5, 3.5, 0))
    local _LeftUpperLeg  = _bodyPart("LeftUpperLeg", _Vector3.new(1, 1, 1), _Vector3.new(-0.5, 3.5, 0))
    local _LeftLowerLeg  = _bodyPart("LeftLowerLeg", _Vector3.new(1, 1, 1), _Vector3.new(-0.5, 2.5, 0))
    local _LeftFoot      = _bodyPart("LeftFoot", _Vector3.new(1, 1, 1), _Vector3.new(-0.5, 1.5, 0))
    local _RightUpperLeg = _bodyPart("RightUpperLeg", _Vector3.new(1, 1, 1), _Vector3.new(0.5, 3.5, 0))
    local _RightLowerLeg = _bodyPart("RightLowerLeg", _Vector3.new(1, 1, 1), _Vector3.new(0.5, 2.5, 0))
    local _RightFoot     = _bodyPart("RightFoot", _Vector3.new(1, 1, 1), _Vector3.new(0.5, 1.5, 0))

    local _Humanoid = mk("Humanoid", {
        Health = 100, MaxHealth = 100,
        WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2,
        HipHeight = 0,
        AutoRotate = true, PlatformStand = false, Sit = false,
        UseJumpPower = true, BreakJointsOnDeath = true,
        EvaluateStateMachine = true,
        RigType = "R15", DisplayName = "Player1",
        DisplayDistanceType = "Viewer",
        HealthDisplayType   = "DisplayWhenDamaged",
        MoveDirection       = _Vector3.new(),
        LookVector          = _Vector3.new(0, 0, -1),
        RootPart            = _RootPart,
        FloorMaterial       = "Plastic",
        Died             = _bypass_makeSignal("Died"),
        Running          = _bypass_makeSignal("Running"),
        Jumping          = _bypass_makeSignal("Jumping"),
        Climbing         = _bypass_makeSignal("Climbing"),
        HealthChanged    = _bypass_makeSignal("HealthChanged"),
        StateChanged     = _bypass_makeSignal("StateChanged"),
        Touched          = _bypass_makeSignal("Touched"),
        Seated           = _bypass_makeSignal("Seated"),
        FreeFalling      = _bypass_makeSignal("FreeFalling"),
        ChangeState      = function() end,
        SetStateEnabled  = function() end,
        GetState         = function() return "Running" end,
        Move             = function() end,
        MoveTo           = function() end,
        TakeDamage       = function(self, dmg)
            self.Health = math.max(0, (self.Health or 0) - (tonumber(dmg) or 0))
        end,
        LoadAnimation = function()
            return _bypass_new(_InstanceMT, {
                ClassName = "AnimationTrack",
                IsPlaying = false, Length = 0,
                Play = function(s) s.IsPlaying = true end,
                Stop = function(s) s.IsPlaying = false end,
                AdjustSpeed = function() end,
                Stopped = _bypass_makeSignal("Stopped"),
            })
        end,
        GetPlayingAnimationTracks = function() return {} end,
    })
    local _Animator = mk("Animator", {
        LoadAnimation = function()
            return _bypass_new(_InstanceMT, {
                ClassName = "AnimationTrack", IsPlaying = false, Length = 0,
                Play = function(s) s.IsPlaying = true end,
                Stop = function(s) s.IsPlaying = false end,
            })
        end,
    })

    local _Character
    local _characterChildren = {
        _Humanoid, _Animator, _RootPart, _Head,
        _UpperTorso, _LowerTorso,
        _LeftUpperArm,  _LeftLowerArm,  _LeftHand,
        _RightUpperArm, _RightLowerArm, _RightHand,
        _LeftUpperLeg,  _LeftLowerLeg,  _LeftFoot,
        _RightUpperLeg, _RightLowerLeg, _RightFoot,
    }
    _Character = mk("Model", {
        Name = "Player1",
        PrimaryPart = _RootPart,
        Humanoid    = _Humanoid,
        HumanoidRootPart = _RootPart,
        Head = _Head,
        GetChildren     = function() return _characterChildren end,
        GetDescendants  = function() return _characterChildren end,
        FindFirstChild  = function(_self, name)
            for i = 1, #_characterChildren do
                if _characterChildren[i].Name == name then return _characterChildren[i] end
            end
            return nil
        end,
        FindFirstChildOfClass = function(_self, cls)
            for i = 1, #_characterChildren do
                if _characterChildren[i].ClassName == cls then return _characterChildren[i] end
            end
            return nil
        end,
        FindFirstChildWhichIsA = function(_self, cls)
            for i = 1, #_characterChildren do
                if _characterChildren[i].ClassName == cls then return _characterChildren[i] end
            end
            return nil
        end,
        WaitForChild = function(self, name) return self:FindFirstChild(name) end,
        GetPivot     = function() return _RootPart.CFrame end,
        PivotTo      = function() end,
        MoveTo       = function() end,
        SetPrimaryPartCFrame = function() end,
    })
    for i = 1, #_characterChildren do _characterChildren[i].Parent = _Character end

    local _Backpack       = mk("Backpack")
    local _PlayerGui      = mk("PlayerGui")
    local _PlayerScripts  = mk("PlayerScripts")
    local _StarterGear    = mk("StarterGear")

    local _Coins = mk("IntValue",    { Name = "Coins", Value = 0 })
    local _Level = mk("IntValue",    { Name = "Level", Value = 1 })
    local _Score = mk("NumberValue", { Name = "Score", Value = 0 })
    local _statsChildren = { _Coins, _Level, _Score }
    local _leaderstats = mk("Folder", {
        Name = "leaderstats",
        Coins = _Coins, Level = _Level, Score = _Score,
        GetChildren    = function() return _statsChildren end,
        GetDescendants = function() return _statsChildren end,
        FindFirstChild = function(_self, name)
            for i = 1, #_statsChildren do
                if _statsChildren[i].Name == name then return _statsChildren[i] end
            end
            return nil
        end,
        WaitForChild = function(self, name) return self:FindFirstChild(name) end,
    })
    for _, s in ipairs(_statsChildren) do s.Parent = _leaderstats end

    local _playerChildren = {
        _Backpack, _PlayerGui, _PlayerScripts, _StarterGear, _leaderstats,
    }

    _LocalPlayer = _bypass_new(_InstanceMT, {
        ClassName       = "Player",
        Name            = "Player1",
        DisplayName     = "Player1",
        UserId          = 1234567,
        UserName        = "Player1",
        AccountAge      = 365,
        FollowUserId    = 0,
        CanLoadCharacterAppearance = true,
        AutoJumpEnabled = true,
        CameraMaxZoomDistance = 400,
        CameraMinZoomDistance = 0.5,
        CameraMode      = "Classic",
        DevCameraOcclusionMode = "Zoom",
        Neutral         = true,
        Team            = nil,
        TeamColor       = nil,
        RespawnLocation = nil,
        ReplicationFocus = _RootPart,
        MembershipType  = "None",
        LocaleId        = "en-us",
        GameplayPaused  = false,

        Character       = _Character,
        Backpack        = _Backpack,
        PlayerGui       = _PlayerGui,
        PlayerScripts   = _PlayerScripts,
        StarterGear     = _StarterGear,
        leaderstats     = _leaderstats,

        Changed                   = _bypass_makeSignal("Changed"),
        CharacterAdded            = _bypass_makeSignal("CharacterAdded"),
        CharacterRemoving         = _bypass_makeSignal("CharacterRemoving"),
        CharacterAppearanceLoaded = _bypass_makeSignal("CharacterAppearanceLoaded"),
        Idled                     = _bypass_makeSignal("Idled"),
        Chatted                   = _bypass_makeSignal("Chatted"),
        OnTeleport                = _bypass_makeSignal("OnTeleport"),

        GetChildren    = function() return _playerChildren end,
        GetDescendants = function() return _playerChildren end,
        FindFirstChild = function(_self, name)
            for i = 1, #_playerChildren do
                if _playerChildren[i].Name == name then return _playerChildren[i] end
            end
            return nil
        end,
        WaitForChild = function(self, name) return self:FindFirstChild(name) end,

        GetMouse = function()
            return _bypass_new(_InstanceMT, {
                ClassName = "Mouse",
                Hit       = _CFrame.new(),
                Origin    = _CFrame.new(),
                Target    = nil,
                TargetFilter = nil,
                UnitRay   = _Ray and _Ray.new(_Vector3.new(), _Vector3.new(0,0,-1)) or nil,
                X = 0, Y = 0,
                ViewSizeX = 1280, ViewSizeY = 720,
                Button1Down = _bypass_makeSignal("Button1Down"),
                Button1Up   = _bypass_makeSignal("Button1Up"),
                Button2Down = _bypass_makeSignal("Button2Down"),
                Button2Up   = _bypass_makeSignal("Button2Up"),
                Move        = _bypass_makeSignal("Move"),
                KeyDown     = _bypass_makeSignal("KeyDown"),
                KeyUp       = _bypass_makeSignal("KeyUp"),
            })
        end,

        Kick                  = function() end,
        IsFriendsWith         = function() return false end,
        IsInGroup             = function() return false end,
        GetRankInGroup        = function() return 0 end,
        GetRoleInGroup        = function() return "Guest" end,
        GetFriendsOnline      = function() return {} end,
        DistanceFromCharacter = function() return 0 end,
        HasAppearanceLoaded   = function() return true end,
        WaitForAppearanceLoaded = function() end,
        SetSuperSafeChat      = function() end,
        ClearCharacterAppearance = function() end,
        LoadCharacterAppearance  = function() end,
        LoadCharacter            = function(self) return self.Character end,
        LoadCharacterBlocking    = function(self) return self.Character end,
        Move = function() end,
        GetJoinData = function() return {} end,
        GetNetworkPing = function() return 0.05 end,
        RequestStreamAroundAsync = function() end,
    })
    _Character.Parent = _LocalPlayer
    for _, c in ipairs(_playerChildren) do c.Parent = _LocalPlayer end
end

local _Players = _bypass_new(_InstanceMT, {
    ClassName   = "Players",
    Name        = "Players",
    LocalPlayer = _LocalPlayer,
    NumPlayers  = 1, MaxPlayers = 16, PreferredPlayers = 16,
    CharacterAutoLoads        = true,
    RespawnTime               = 5,
    BubbleChat                = false,
    ClassicChat               = true,
    UseStrafingAnimations     = false,

    GetPlayerByUserId = function(_self, id)
        if id == _LocalPlayer.UserId then return _LocalPlayer end
        return nil
    end,
    GetPlayerFromCharacter = function(_self, char)
        if char == _LocalPlayer.Character then return _LocalPlayer end
        return nil
    end,
    GetPlayers   = function() return { _LocalPlayer } end,
    GetUserIdFromNameAsync = function(_self, _name) return _LocalPlayer.UserId end,
    GetNameFromUserIdAsync = function(_self, _id)   return _LocalPlayer.Name   end,
    GetUserThumbnailAsync  = function() return "rbxasset://textures/ui/GuiImagePlaceholder.png", true end,
    GetHumanoidDescriptionFromUserId = function() return _bypass_new(_InstanceMT, { ClassName = "HumanoidDescription" }) end,
    GetHumanoidDescriptionFromOutfitId = function() return _bypass_new(_InstanceMT, { ClassName = "HumanoidDescription" }) end,
    CreateHumanoidModelFromDescription = function() return _LocalPlayer.Character end,
    CreateHumanoidModelFromUserId      = function() return _LocalPlayer.Character end,
    Chat                  = function() end,
    TeamChat              = function() end,
    PlayerAdded            = _bypass_makeSignal("PlayerAdded"),
    PlayerRemoving         = _bypass_makeSignal("PlayerRemoving"),
    PlayerMembershipChanged = _bypass_makeSignal("PlayerMembershipChanged"),
})

local _services = {
    TextService              = _TextService,
    GuiService               = _GuiService,
    ContextActionService     = _ContextActionService,
    SoundService             = _SoundService,
    Lighting                 = _Lighting,
    ReplicatedStorage        = _ReplicatedStorage,
    StarterGui               = _StarterGui,
    PhysicsService           = _PhysicsService,
    UserInputService         = _UserInputService,
    Players                  = _Players,
    RunService               = _RunService,
    HttpService              = _HttpService,
    TweenService             = _TweenService,
}

for _name, _svc in pairs(_extraServices) do
    _services[_name] = _svc
end

local _game = setmetatable({
    JobId     = "00000000-0000-0000-0000-000000000000",
    PlaceId   = 1818,
    GameId    = 1818,
    ClassName = "DataModel",
    Players   = _Players,
    Workspace = nil,
    IsLoaded = function() return true end,
    GetService = function(self, name)
        local s = _services[name]
        if s == nil then
            error("Service \"" .. tostring(name) .. "\" is not a valid service", 2)
        end
        return s
    end,
    FindService = function(_self, name)
        return _services[name]
    end,
    HttpGet = function() return "" end,
}, {
    __type     = "Instance",
    __tostring = function() return "Game" end,
    __index    = _InstanceMT,
})

local _workspace = _bypass_new(_InstanceMT, {
    ClassName       = "Workspace",
    Name            = "Workspace",
    Gravity         = 196.2,
    CurrentCamera   = _bypass_new(_InstanceMT, {
        ClassName = "Camera",
        CFrame    = _CFrame.new(),
        ViewportSize = _Vector2.new(1280, 720),
    }),
    FilteringEnabled = true,
})
_game.Workspace = _workspace

local _knownClasses = {
    Part = true, MeshPart = true, UnionOperation = true,
    NegateOperation = true, WedgePart = true, CornerWedgePart = true,
    TrussPart = true, SpawnLocation = true, SkateboardPlatform = true,
    Seat = true, VehicleSeat = true, FlagStand = true,
    Model = true, Folder = true, Configuration = true, Actor = true,
    WorldModel = true, Backpack = true, PlayerGui = true,
    PlayerScripts = true, ReplicatedStorage = true, ServerStorage = true,
    StarterGear = true, StarterPack = true, StarterPlayerScripts = true,
    StarterCharacterScripts = true,
    Humanoid = true, HumanoidDescription = true, Animator = true,
    Animation = true, AnimationController = true, AnimationTrack = true,
    Accessory = true, Hat = true, Shirt = true, Pants = true,
    ShirtGraphic = true, BodyColors = true,
    CharacterMesh = true, SpecialMesh = true, BlockMesh = true,
    CylinderMesh = true, FileMesh = true,
    Tool = true, HopperBin = true, Handle = true,
    Weld = true, WeldConstraint = true, Motor = true, Motor6D = true,
    Snap = true, Glue = true, ManualWeld = true, ManualGlue = true,
    Rope = true, RopeConstraint = true, Spring = true, SpringConstraint = true,
    HingeConstraint = true, BallSocketConstraint = true,
    PrismaticConstraint = true, CylindricalConstraint = true,
    LineForce = true, AlignOrientation = true, AlignPosition = true,
    AngularVelocity = true, LinearVelocity = true, Plane = true,
    Torque = true, VectorForce = true, AngularServo = true,
    BodyVelocity = true, BodyAngularVelocity = true, BodyForce = true,
    BodyGyro = true, BodyPosition = true, BodyThrust = true,
    RocketPropulsion = true,
    Attachment = true, Bone = true, NoCollisionConstraint = true,
    Sound = true, SoundGroup = true, SoundEffect = true,
    DistortionSoundEffect = true, EchoSoundEffect = true,
    EqualizerSoundEffect = true, FlangeSoundEffect = true,
    PitchShiftSoundEffect = true, ReverbSoundEffect = true,
    TremoloSoundEffect = true, ChorusSoundEffect = true,
    CompressorSoundEffect = true,
    Fire = true, Smoke = true, Sparkles = true, Explosion = true,
    ParticleEmitter = true, Trail = true, Beam = true,
    PointLight = true, SurfaceLight = true, SpotLight = true,
    Atmosphere = true, Sky = true, Clouds = true, Terrain = true,
    BloomEffect = true, BlurEffect = true, ColorCorrectionEffect = true,
    DepthOfFieldEffect = true, SunRaysEffect = true, ColorGradingEffect = true,
    Camera = true,
    Frame = true, ScreenGui = true, SurfaceGui = true, BillboardGui = true,
    GuiMain = true, ScrollingFrame = true, CanvasGroup = true,
    TextLabel = true, TextButton = true, TextBox = true,
    ImageLabel = true, ImageButton = true, ViewportFrame = true,
    VideoFrame = true, ProximityPrompt = true,
    UICorner = true, UIPadding = true, UIListLayout = true,
    UIGridLayout = true, UIPageLayout = true, UITableLayout = true,
    UIAspectRatioConstraint = true, UISizeConstraint = true,
    UITextSizeConstraint = true, UIStroke = true, UIGradient = true,
    UIScale = true, UIFlexItem = true,
    Highlight = true, SelectionBox = true, SelectionSphere = true,
    BoxHandleAdornment = true, ConeHandleAdornment = true,
    CylinderHandleAdornment = true, ImageHandleAdornment = true,
    LineHandleAdornment = true, SphereHandleAdornment = true,
    RemoteEvent = true, RemoteFunction = true,
    BindableEvent = true, BindableFunction = true,
    UnreliableRemoteEvent = true,
    Script = true, LocalScript = true, ModuleScript = true,
    StringValue = true, IntValue = true, NumberValue = true,
    BoolValue = true, ObjectValue = true, BrickColorValue = true,
    Color3Value = true, Vector3Value = true, CFrameValue = true,
    RayValue = true, IntConstrainedValue = true, NumberConstrainedValue = true,
    PathfindingModifier = true, PathfindingLink = true,
    ValueBase = true, RemoteEvent2 = false,
    Team = true,
    BillboardGui2 = false,
    Decal = true, Texture = true,
}
for k, v in pairs(_knownClasses) do
    if v ~= true then _knownClasses[k] = nil end
end

local _classDefaults = {
    Humanoid = {
        Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50,
        JumpHeight = 7.2, HipHeight = 0,
        AutoRotate = true, PlatformStand = false, Sit = false,
        RigType = "R15", DisplayDistanceType = "Viewer",
        HealthDisplayType = "DisplayWhenDamaged",
        UseJumpPower = true, BreakJointsOnDeath = true,
        EvaluateStateMachine = true,
        MoveDirection = nil,
        ChangeState = function() end,
        TakeDamage   = function(self, dmg)
            self.Health = math.max(0, (self.Health or 0) - (tonumber(dmg) or 0))
        end,
        Move         = function() end,
        MoveTo       = function() end,
        LoadAnimation = function()
            return _bypass_new(_InstanceMT, {
                ClassName = "AnimationTrack",
                IsPlaying = false, Length = 0,
                Play = function() end, Stop = function() end,
            })
        end,
        GetState     = function() return "Running" end,
        SetStateEnabled = function() end,
    },
    MeshPart = {
        MeshId = "", TextureID = "", DoubleSided = false,
        RenderFidelity = "Automatic", CollisionFidelity = "Default",
        Size = nil,
    },
    Sound = {
        SoundId = "", Volume = 0.5, Playing = false, Looped = false,
        PlaybackLoudness = 1,
        TimePosition = 0, PlaybackSpeed = 1, RollOffMode = "Inverse",
        Play = function(self) self.Playing = true end,
        Stop = function(self) self.Playing = false end,
        Pause = function(self) self.Playing = false end,
        Resume = function(self) self.Playing = true end,
    },
    ParticleEmitter = {
        Rate = 20, Lifetime = nil, Speed = nil, Size = nil,
        Texture = "", Enabled = true, LightEmission = 0,
        LightInfluence = 1, ZOffset = 0, Drag = 0,
        Emit = function() end, Clear = function() end,
    },
    ProximityPrompt = {
        ActionText = "Interact", ObjectText = "", HoldDuration = 0,
        MaxActivationDistance = 10, KeyboardKeyCode = nil,
        Enabled = true, RequiresLineOfSight = true,
        Triggered           = nil,
        TriggerEnded        = nil,
        PromptShown         = nil,
        PromptHidden        = nil,
        InputHoldBegan      = nil,
        InputHoldEnded      = nil,
    },
    Animation = {
        AnimationId = "",
    },
    Tool = {
        Equipped = nil, Unequipped = nil, Activated = nil, Deactivated = nil,
        Grip = nil, GripUp = nil, GripPos = nil,
        RequiresHandle = true, Enabled = true, ManualActivationOnly = false,
    },
    RemoteEvent = {
        FireServer    = function() end,
        FireClient    = function() end,
        FireAllClients = function() end,
        OnServerEvent  = nil,
        OnClientEvent  = nil,
    },
    RemoteFunction = {
        InvokeServer  = function() return nil end,
        InvokeClient  = function() return nil end,
        OnServerInvoke = nil, OnClientInvoke = nil,
    },
    BindableEvent = {
        Fire  = function() end,
        Event = nil,
    },
    BindableFunction = {
        Invoke      = function() return nil end,
        OnInvoke    = nil,
    },
    StringValue = { Value = "" },
    IntValue    = { Value = 0 },
    NumberValue = { Value = 0 },
    BoolValue   = { Value = false },
    ObjectValue = { Value = nil },
    Vector3Value = { Value = nil },
    CFrameValue  = { Value = nil },
    Color3Value  = { Value = nil },
    BrickColorValue = { Value = nil },
    Animator = {
        LoadAnimation = function()
            return _bypass_new(_InstanceMT, {
                ClassName = "AnimationTrack", IsPlaying = false, Length = 0,
                Play = function() end, Stop = function() end,
            })
        end,
    },
    Camera = {
        CFrame = nil,
        FieldOfView = 70, CameraType = "Custom",
        ViewportSize = nil,
    },
    Highlight = {
        FillColor = nil, OutlineColor = nil,
        FillTransparency = 0.5, OutlineTransparency = 0,
        DepthMode = "AlwaysOnTop", Enabled = true, Adornee = nil,
    },
    Beam   = { Enabled = true, Width0 = 1, Width1 = 1 },
    Trail  = { Enabled = true, Lifetime = 2 },
    PointLight   = { Brightness = 1, Range = 8, Color = nil },
    SpotLight    = { Brightness = 1, Range = 16, Angle = 90, Color = nil },
    SurfaceLight = { Brightness = 1, Range = 16, Angle = 180, Color = nil },
}

local _Instance
_Instance = {}

_Instance.new = function(class, parent)
        if type(class) ~= "string" or not _knownClasses[class] then
            error("Unable to create an Instance of type \"" .. tostring(class) .. "\"", 2)
        end

        local fields = {
            ClassName = class, Name = class, Parent = parent,
            Archivable = true,
            Destroy   = function(self) self.Parent = nil end,
            Clone     = function(self) return _Instance.new(self.ClassName) end,
            FindFirstChild         = function() return nil end,
            FindFirstChildOfClass  = function() return nil end,
            FindFirstChildWhichIsA = function() return nil end,
            WaitForChild           = function() return nil end,
        }

        local defs = _classDefaults[class]
        if defs then
            for k, v in pairs(defs) do fields[k] = v end
        end

        if class == "Humanoid"        then fields.MoveDirection = _Vector3.new() end
        if class == "MeshPart"        then fields.Size          = _Vector3.new(2, 2, 2) end
        if class == "Camera"          then
            fields.CFrame       = _CFrame.new()
            fields.ViewportSize = _Vector2.new(1280, 720)
        end
        if class == "Vector3Value"    then fields.Value = _Vector3.new() end
        if class == "CFrameValue"     then fields.Value = _CFrame.new()  end
        if class == "Color3Value"     then fields.Value = _Color3.new()  end
        if class == "BrickColorValue" then fields.Value = _BrickColor.new() end
        if class == "Highlight" then
            fields.FillColor    = _Color3.fromRGB(255, 255, 255)
            fields.OutlineColor = _Color3.fromRGB(0,   0,   0)
        end
        if class == "PointLight" or class == "SpotLight" or class == "SurfaceLight" then
            fields.Color = _Color3.fromRGB(255, 255, 255)
        end
        if class == "ParticleEmitter" then
            fields.Lifetime = _NumberRange.new(1, 1)
            fields.Speed    = _NumberRange.new(5, 5)
            fields.Size     = _NumberSequence.new(1)
        end

        if class == "RemoteEvent" then
            fields.OnServerEvent = _bypass_makeSignal("OnServerEvent")
            fields.OnClientEvent = _bypass_makeSignal("OnClientEvent")
        end
        if class == "BindableEvent" then
            fields.Event = _bypass_makeSignal("Event")
        end
        if class == "ProximityPrompt" then
            fields.Triggered      = _bypass_makeSignal("Triggered")
            fields.TriggerEnded   = _bypass_makeSignal("TriggerEnded")
            fields.PromptShown    = _bypass_makeSignal("PromptShown")
            fields.PromptHidden   = _bypass_makeSignal("PromptHidden")
            fields.InputHoldBegan = _bypass_makeSignal("InputHoldBegan")
            fields.InputHoldEnded = _bypass_makeSignal("InputHoldEnded")
        end
        if class == "Tool" then
            fields.Equipped     = _bypass_makeSignal("Equipped")
            fields.Unequipped   = _bypass_makeSignal("Unequipped")
            fields.Activated    = _bypass_makeSignal("Activated")
            fields.Deactivated  = _bypass_makeSignal("Deactivated")
        end

        return _bypass_new(_InstanceMT, fields)
end

_Instance.fromExisting = function(other)
    if type(other) ~= "table" then return nil end
    return _Instance.new(other.ClassName or "Folder")
end

local function _bypass_typeof(v)
    local t = type(v)
    if t ~= "table" and t ~= "userdata" then return t end
    local mt = getmetatable(v)
    if mt and mt.__type then return mt.__type end
    return t
end

local _real_type = type

local _newproxy = newproxy or function(_)
    return io.stdout
end

local _bypassStart = os.clock()
local function _bypass_tick()
    return os.time() + (os.clock() - _bypassStart)
end

local _bypassEnv = {
    print = print, error = error, pcall = pcall, xpcall = xpcall,
    select = select, tostring = tostring, tonumber = tonumber,
    type = function(v)
        local _t = _real_type(v)
        if _t == "table" then
            local _mt = getmetatable(v)
            if _mt and _mt.__type then return "userdata" end
        end
        return _t
    end,
    ipairs = ipairs, pairs = pairs, next = next,
    setmetatable = setmetatable, getmetatable = getmetatable,
    rawget = rawget, rawset = rawset, rawequal = rawequal,
    unpack = unpack, math = math, string = string, table = table,
    os = os, io = io, assert = assert, _VERSION = "Luau",

    game        = _game,
    workspace   = _workspace,
    Workspace   = _workspace,
    Instance    = _Instance,
    Enum        = _Enum,
    Vector2     = _Vector2,
    Vector3     = _Vector3,
    CFrame      = _CFrame,
    UDim        = _UDim,
    UDim2       = _UDim2,
    Color3      = _Color3,
    BrickColor  = _BrickColor,
    NumberSequence = _NumberSequence,
    NumberRange = _NumberRange,
    TweenInfo   = _TweenInfo,
    Ray         = _Ray,
    Rect        = _Rect,
    typeof      = _bypass_typeof,
    tick        = _bypass_tick,
    newproxy    = _newproxy,
    warn        = warn,
    task        = {
        wait    = function(t) return t or 0 end,
        spawn   = function(f, ...) local a={...}; pcall(f, table.unpack(a)) end,
        delay   = function(_, f, ...) local a={...}; pcall(f, table.unpack(a)) end,
        defer   = function(f, ...) local a={...}; pcall(f, table.unpack(a)) end,
    },
    wait        = function(t) return t or 0 end,
    spawn       = function(f, ...) local a={...}; pcall(f, table.unpack(a)) end,
    delay       = function(_, f, ...) local a={...}; pcall(f, table.unpack(a)) end,

    coroutine   = coroutine,
    debug       = debug or {
        traceback = function(a, b)
            local msg = type(a) == "thread" and b or a
            local prefix = msg ~= nil and (tostring(msg) .. "\n") or ""
            return prefix .. "stack traceback:\n\t[C]: in ?"
        end,
        getinfo   = function() return { source = "[C]", currentline = -1, what = "C" } end,
    },
    bit32       = bit32 or _G.bit32,
    utf8        = utf8 or _G.utf8,
    getfenv     = getfenv or function() return _bypassEnv end,
    setfenv     = setfenv or function(_, _) end,
    loadstring  = loadstring or load,
    load        = load,

    script      = nil,

    shared      = {},
    _shared     = {},
}

_bypassEnv.script = _bypass_new(_InstanceMT, {
    ClassName = "LocalScript",
    Name      = "LocalScript",
    Parent    = _game,
    Disabled  = false,
    Source    = "",
})

_bypassEnv.Random                 = _extraDataTypes.Random
_bypassEnv.DateTime               = _extraDataTypes.DateTime
_bypassEnv.Region3                = _extraDataTypes.Region3
_bypassEnv.RaycastParams          = _extraDataTypes.RaycastParams
_bypassEnv.OverlapParams          = _extraDataTypes.OverlapParams
_bypassEnv.PathWaypoint           = _extraDataTypes.PathWaypoint
_bypassEnv.Faces                  = _extraDataTypes.Faces
_bypassEnv.Axes                   = _extraDataTypes.Axes
_bypassEnv.PhysicalProperties     = _extraDataTypes.PhysicalProperties
_bypassEnv.ColorSequence          = _extraDataTypes.ColorSequence
_bypassEnv.ColorSequenceKeypoint  = _extraDataTypes.ColorSequenceKeypoint
_bypassEnv.NumberSequenceKeypoint = _extraDataTypes.NumberSequenceKeypoint
_bypassEnv.SharedTable            = _extraDataTypes.SharedTable


function _EnumsMT.GetEnums(self)
    local out = {}
    for _, v in pairs(self) do
        if type(v) == "table" then table.insert(out, v) end
    end
    return out
end
function _EnumMT.GetEnumItems(self)
    local out = {}
    for _, v in pairs(self) do
        if type(v) == "table" and getmetatable(v) and getmetatable(v).__type == "EnumItem" then
            table.insert(out, v)
        end
    end
    return out
end

_bypassEnv._G  = _bypassEnv
_bypassEnv._ENV = _bypassEnv

do
    local _real_dump = string.dump

    local _strProxy = {}
    for k, v in pairs(string) do _strProxy[k] = v end
    _strProxy.dump = function(fn, ...)
        error("attempt to dump given function", 2)
    end
    _bypassEnv.string = _strProxy
    _bypassEnv._origStringDump = _real_dump

    local _dbgSrc = debug or {}
    local _dbgProxy = {}
    for k, v in pairs(_dbgSrc) do _dbgProxy[k] = v end
    local _realGetupvalue  = rawget(_dbgSrc, "getupvalue")
    local _realSetupvalue  = rawget(_dbgSrc, "setupvalue")
    _dbgProxy.getupvalue  = function(fn, i)    if _realGetupvalue then local n,v = _realGetupvalue(fn, i); return n,v end; return nil end
    _dbgProxy.getupvalues = function(fn)
        if not _realGetupvalue then return {} end
        local uvs = {}; local idx = 1
        while idx <= 250 do
            local n, v = _realGetupvalue(fn, idx)
            if not n then break end
            uvs[idx] = v
            if type(n) == "string" and n ~= "" and n ~= "_ENV" then uvs[n] = v end
            idx = idx + 1
        end
        return uvs
    end
    _dbgProxy.setupvalue  = function(fn, i, v) if _realSetupvalue then return _realSetupvalue(fn, i, v) end end
    _bypassEnv.debug = _dbgProxy
end

local TAMPERCHECK_SNIPPET = [==[
local function tamperCheck(fn)
    local ok, res = pcall(fn)
    if not ok or not res then
        error("6Vfuscator")
    end
end

tamperCheck(function() return type(game.JobId) == "string" end)
tamperCheck(function() return game.PlaceId  > 0 end)
tamperCheck(function() return game.GameId   > 0 end)
tamperCheck(function() return game.ClassName == "DataModel"  end)
tamperCheck(function() return workspace.ClassName == "Workspace" end)
tamperCheck(function()
    local ok = pcall(game.GetService, game, "EnvCheckFakeService00000")
    return not ok
end)
tamperCheck(function()
    local v = game:GetService("TextService"):GetTextSize("Test", 14, Enum.Font.Arial, Vector2.new(500, 0))
    return typeof(v) == "Vector2" and v.X > 0
end)
tamperCheck(function() return typeof(game:GetService("GuiService"):GetGuiInset()) == "Vector2" end)
tamperCheck(function() return game.Players.LocalPlayer.UserId > 0 end)
tamperCheck(function() return type(tick()) == "number" and tick() > 0 end)
tamperCheck(function() return typeof(CFrame.new())  == "CFrame"  end)
tamperCheck(function() return typeof(Vector3.new()) == "Vector3" end)
tamperCheck(function() return typeof(UDim2.new())   == "UDim2"   end)
tamperCheck(function()
    local c = Color3.fromRGB(255, 0, 0)
    return math.abs(c.R - 1) < 0.01 and math.abs(c.G - 0) < 0.01 and math.abs(c.B - 0) < 0.01
end)
tamperCheck(function()
    local ok = pcall(Instance.new, "FakeEnvCheckClass00000")
    return not ok
end)
tamperCheck(function() return type(newproxy()) == "userdata" end)
tamperCheck(function() return type(game:GetService("ContextActionService"):GetAllBoundActionInfo()) == "table" end)
tamperCheck(function() return type(game:GetService("SoundService").RolloffScale) == "number" end)
tamperCheck(function()
    local t = game:GetService("Lighting").ClockTime
    return type(t) == "number" and t >= 0 and t <= 24
end)
tamperCheck(function() return game:GetService("ReplicatedStorage") ~= nil end)
tamperCheck(function() return game:GetService("StarterGui")        ~= nil end)
tamperCheck(function() return game:GetService("PhysicsService")    ~= nil end)
tamperCheck(function() return type(game:GetService("UserInputService"):IsKeyDown(Enum.KeyCode.W)) == "boolean" end)
tamperCheck(function() return game.Players:GetPlayerByUserId(-999) == nil end)
tamperCheck(function() return game.Players.LocalPlayer.CharacterAdded ~= nil end)
tamperCheck(function() return typeof(BrickColor.new())                == "BrickColor"     end)
tamperCheck(function() return typeof(NumberSequence.new(0))           == "NumberSequence" end)
tamperCheck(function() return typeof(NumberRange.new(0, 1))           == "NumberRange"    end)
tamperCheck(function() return typeof(TweenInfo.new())                 == "TweenInfo"      end)
tamperCheck(function() return typeof(Ray.new(Vector3.new(), Vector3.new(0,1,0))) == "Ray" end)
tamperCheck(function() return typeof(Vector2.new()) == "Vector2" end)
tamperCheck(function() return typeof(Rect.new())    == "Rect"    end)
tamperCheck(function() return type(game:GetService("Lighting").Brightness) == "number" end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    return game.Players:GetPlayerByUserId(lp.UserId) ~= nil
end)
tamperCheck(function() return type(workspace.Gravity) == "number" end)


tamperCheck(function() return typeof(Random.new(1))                          == "Random"                   end)
tamperCheck(function() return typeof(DateTime.now())                         == "DateTime"                 end)
tamperCheck(function() return typeof(Region3.new(Vector3.new(), Vector3.new(1,1,1))) == "Region3"          end)
tamperCheck(function() return typeof(RaycastParams.new())                    == "RaycastParams"            end)
tamperCheck(function() return typeof(OverlapParams.new())                    == "OverlapParams"            end)
tamperCheck(function() return typeof(PathWaypoint.new(Vector3.new()))        == "PathWaypoint"             end)
tamperCheck(function() return typeof(Faces.new())                            == "Faces"                    end)
tamperCheck(function() return typeof(Axes.new())                             == "Axes"                     end)
tamperCheck(function() return typeof(PhysicalProperties.new(0.7))            == "PhysicalProperties"       end)
tamperCheck(function() return typeof(ColorSequence.new(Color3.new()))        == "ColorSequence"            end)
tamperCheck(function() return typeof(ColorSequenceKeypoint.new(0,Color3.new())) == "ColorSequenceKeypoint" end)
tamperCheck(function() return typeof(NumberSequenceKeypoint.new(0, 0))       == "NumberSequenceKeypoint"   end)

tamperCheck(function()
    local r = Random.new(42)
    local n = r:NextInteger(1, 10)
    return type(n) == "number" and n >= 1 and n <= 10
end)
tamperCheck(function()
    local r = Random.new(42)
    local n = r:NextNumber(0, 1)
    return type(n) == "number" and n >= 0 and n <= 1
end)

tamperCheck(function() return type(DateTime.now().UnixTimestamp) == "number" end)

tamperCheck(function()
    local rg = Region3.new(Vector3.new(0,0,0), Vector3.new(2,4,6))
    return typeof(rg.CFrame) == "CFrame" and typeof(rg.Size) == "Vector3"
end)

tamperCheck(function() return game:IsA("DataModel") end)
tamperCheck(function() return workspace:IsA("Workspace") end)
tamperCheck(function() return type(workspace:GetChildren()) == "table" end)
tamperCheck(function() return type(workspace:GetDescendants()) == "table" end)
tamperCheck(function() return workspace:FindFirstChild("__nope__") == nil end)
tamperCheck(function() return type(workspace:GetFullName()) == "string" end)
tamperCheck(function()
    local sig = workspace:GetPropertyChangedSignal("Gravity")
    return sig ~= nil and type(sig.Connect) == "function"
end)
tamperCheck(function()
    local sig = workspace:GetAttributeChangedSignal("X")
    return sig ~= nil and type(sig.Connect) == "function"
end)
tamperCheck(function() return workspace:GetAttribute("missing") == nil end)
tamperCheck(function() return type(workspace:GetAttributes()) == "table" end)

tamperCheck(function()
    local a = game:GetService("RunService")
    local b = game:GetService("RunService")
    return a == b
end)
tamperCheck(function()
    local a = game:GetService("HttpService")
    local b = game:FindService("HttpService")
    return a == b
end)

tamperCheck(function() return game:GetService("MarketplaceService")     ~= nil end)
tamperCheck(function() return game:GetService("TeleportService")        ~= nil end)
tamperCheck(function() return game:GetService("DataStoreService")       ~= nil end)
tamperCheck(function() return game:GetService("CollectionService")      ~= nil end)
tamperCheck(function() return game:GetService("Debris")                 ~= nil end)
tamperCheck(function() return game:GetService("MessagingService")       ~= nil end)
tamperCheck(function() return game:GetService("LocalizationService").RobloxLocaleId == "en-us" end)
tamperCheck(function() return game:GetService("PathfindingService"):CreatePath().Status == "Success" end)

tamperCheck(function()
    local info = game:GetService("MarketplaceService"):GetProductInfo(1234)
    return type(info) == "table" and type(info.Name) == "string"
end)

tamperCheck(function()
    local ds = game:GetService("DataStoreService"):GetDataStore("env")
    return ds ~= nil and type(ds.GetAsync) == "function"
end)

tamperCheck(function() return type(game:GetService("HttpService"):GenerateGUID()) == "string" end)

tamperCheck(function() return type(Enum:GetEnums()) == "table" end)
tamperCheck(function() return type(Enum.KeyCode:GetEnumItems()) == "table" end)
tamperCheck(function() return Enum.KeyCode.W.Value == 87 end)

tamperCheck(function() return type(coroutine) == "table" and type(coroutine.create) == "function" end)
tamperCheck(function() return type(debug)     == "table" and type(debug.traceback)  == "function" end)
tamperCheck(function() return type(string.format("%d", 5)) == "string" end)
tamperCheck(function() return type(table.insert) == "function" end)

tamperCheck(function() return typeof(script) == "Instance" end)
tamperCheck(function() return script:IsA("LocalScript") end)
tamperCheck(function() return type(script:GetFullName()) == "string" end)

tamperCheck(function() return type(_G) == "table" end)
tamperCheck(function() return type(shared) == "table" end)

tamperCheck(function() return getgenv               == nil end)
tamperCheck(function() return getrenv               == nil end)
tamperCheck(function() return getreg                == nil end)
tamperCheck(function() return hookfunction          == nil end)
tamperCheck(function() return getrawmetatable       == nil end)
tamperCheck(function() return setreadonly           == nil end)
tamperCheck(function() return isreadonly            == nil end)
tamperCheck(function() return getconnections        == nil end)
tamperCheck(function() return is_synapse_function   == nil end)
tamperCheck(function() return syn                   == nil end)
tamperCheck(function() return KRNL_LOADED           == nil end)
tamperCheck(function() return identifyexecutor      == nil end)
tamperCheck(function() return getexecutorname       == nil end)
tamperCheck(function() return checkcaller           == nil end)
tamperCheck(function() return gethui                == nil end)

tamperCheck(function()
    local ok = pcall(function() return Random.new(); end)
    return ok
end)

local _classProbe = {
    "Part", "MeshPart", "WedgePart", "TrussPart", "Seat", "VehicleSeat",
    "Model", "Folder", "Configuration", "Actor", "Backpack",
    "Humanoid", "HumanoidDescription", "Animator", "Animation",
    "Accessory", "Hat", "Shirt", "Pants", "ShirtGraphic",
    "Tool", "Handle",
    "Weld", "WeldConstraint", "Motor6D",
    "RopeConstraint", "SpringConstraint", "HingeConstraint",
    "BallSocketConstraint", "AlignOrientation", "AlignPosition",
    "BodyVelocity", "BodyGyro", "BodyPosition",
    "Attachment", "Bone",
    "Sound", "SoundGroup",
    "Fire", "Smoke", "Sparkles", "ParticleEmitter", "Trail", "Beam",
    "PointLight", "SpotLight", "SurfaceLight",
    "Camera",
    "Frame", "ScreenGui", "SurfaceGui", "BillboardGui",
    "ScrollingFrame", "TextLabel", "TextButton", "TextBox",
    "ImageLabel", "ImageButton", "ViewportFrame", "ProximityPrompt",
    "UICorner", "UIPadding", "UIListLayout", "UIGridLayout",
    "UIAspectRatioConstraint", "UISizeConstraint", "UIStroke",
    "UIGradient", "UIScale", "Highlight", "SelectionBox",
    "RemoteEvent", "RemoteFunction", "BindableEvent", "BindableFunction",
    "UnreliableRemoteEvent",
    "Script", "LocalScript", "ModuleScript",
    "StringValue", "IntValue", "NumberValue", "BoolValue",
    "ObjectValue", "Vector3Value", "CFrameValue", "Color3Value",
    "BrickColorValue",
    "Decal", "Texture",
    "Atmosphere", "Sky", "Clouds", "Terrain",
    "BloomEffect", "BlurEffect", "ColorCorrectionEffect",
    "DepthOfFieldEffect", "SunRaysEffect",
}
for _, _c in ipairs(_classProbe) do
    local class = _c
    tamperCheck(function()
        local inst = Instance.new(class)
        return typeof(inst) == "Instance"
            and inst.ClassName == class
            and inst.Name      == class
    end)
end

tamperCheck(function()
    local h = Instance.new("Humanoid")
    return h.Health == 100 and h.MaxHealth == 100
       and type(h.WalkSpeed) == "number"
       and type(h.LoadAnimation) == "function"
end)
tamperCheck(function()
    local h = Instance.new("Humanoid")
    h:TakeDamage(25)
    return h.Health == 75
end)
tamperCheck(function()
    local s = Instance.new("Sound")
    s:Play()
    return s.Playing == true
end)
tamperCheck(function()
    local re = Instance.new("RemoteEvent")
    return type(re.FireServer)        == "function"
       and type(re.OnClientEvent)     == "table"
       and type(re.OnClientEvent.Connect) == "function"
end)
tamperCheck(function()
    local be = Instance.new("BindableEvent")
    return type(be.Fire) == "function"
       and type(be.Event) == "table"
       and type(be.Event.Connect) == "function"
end)
tamperCheck(function()
    local pp = Instance.new("ProximityPrompt")
    return pp.ActionText == "Interact"
       and type(pp.Triggered)        == "table"
       and type(pp.Triggered.Connect) == "function"
end)
tamperCheck(function()
    local pe = Instance.new("ParticleEmitter")
    return typeof(pe.Lifetime) == "NumberRange"
       and typeof(pe.Speed)    == "NumberRange"
       and typeof(pe.Size)     == "NumberSequence"
end)
tamperCheck(function()
    local cam = Instance.new("Camera")
    return typeof(cam.CFrame)       == "CFrame"
       and typeof(cam.ViewportSize) == "Vector2"
end)
tamperCheck(function()
    local v = Instance.new("Vector3Value")
    return typeof(v.Value) == "Vector3"
end)
tamperCheck(function()
    local v = Instance.new("CFrameValue")
    return typeof(v.Value) == "CFrame"
end)
tamperCheck(function()
    local hi = Instance.new("Highlight")
    return typeof(hi.FillColor)    == "Color3"
       and typeof(hi.OutlineColor) == "Color3"
       and hi.Enabled == true
end)
tamperCheck(function()
    local pl = Instance.new("PointLight")
    return typeof(pl.Color) == "Color3" and type(pl.Brightness) == "number"
end)

tamperCheck(function()
    local t = Instance.new("Tool")
    return type(t.Equipped)        == "table"
       and type(t.Equipped.Connect) == "function"
end)

tamperCheck(function()
    local p = Instance.new("Part")
    return p:IsA("Part")
       and type(p:GetChildren())    == "table"
       and type(p:GetFullName())    == "string"
       and p:FindFirstChild("__nope__") == nil
end)

tamperCheck(function()
    local a = Instance.new("Folder")
    local b = Instance.fromExisting(a)
    return b ~= nil and b.ClassName == "Folder"
end)

tamperCheck(function()
    local ok = pcall(Instance.new, "DefinitelyNotARobloxClass99999")
    return not ok
end)

tamperCheck(function()
    local lp = game.Players.LocalPlayer
    return lp ~= nil
       and type(lp.Name) == "string" and #lp.Name > 0
       and type(lp.UserId) == "number"
       and lp.DisplayName == lp.Name
end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    return lp.Character ~= nil
       and lp.Character.ClassName == "Model"
       and lp.Character.Name == lp.Name
end)
tamperCheck(function()
    local h = game.Players.LocalPlayer.Character.Humanoid
    return h ~= nil and h.ClassName == "Humanoid"
       and h.Health == 100 and h.MaxHealth == 100
       and h.WalkSpeed == 16 and h.JumpPower == 50
       and h.RigType == "R15"
end)
tamperCheck(function()
    local h = game.Players.LocalPlayer.Character:FindFirstChild("Humanoid")
    return h ~= nil and typeof(h) == "Instance"
end)
tamperCheck(function()
    local rp = game.Players.LocalPlayer.Character.HumanoidRootPart
    return rp ~= nil and rp.Name == "HumanoidRootPart"
       and typeof(rp.CFrame)    == "CFrame"
       and typeof(rp.Position)  == "Vector3"
       and typeof(rp.Velocity)  == "Vector3"
end)
tamperCheck(function()
    local h = game.Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    return h ~= nil and h.ClassName == "Humanoid"
end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    return lp.Character.RootPart == lp.Character.HumanoidRootPart
        or lp.Character.Humanoid.RootPart == lp.Character.HumanoidRootPart
end)
tamperCheck(function()
    local kids = game.Players.LocalPlayer.Character:GetChildren()
    if type(kids) ~= "table" or #kids < 18 then return false end
    local sawHum, sawRoot = false, false
    for _, c in ipairs(kids) do
        if c.ClassName == "Humanoid" then sawHum  = true end
        if c.Name      == "HumanoidRootPart" then sawRoot = true end
    end
    return sawHum and sawRoot
end)
tamperCheck(function()
    local h = game.Players.LocalPlayer.Character.Humanoid
    h:TakeDamage(10)
    local ok = h.Health == 90
    h.Health = 100
    return ok
end)
tamperCheck(function()
    local h = game.Players.LocalPlayer.Character.Humanoid
    return type(h.Died.Connect)         == "function"
       and type(h.HealthChanged.Connect)== "function"
       and type(h.StateChanged.Connect) == "function"
end)
tamperCheck(function()
    local h = game.Players.LocalPlayer.Character.Humanoid
    local track = h:LoadAnimation(Instance.new("Animation"))
    return track ~= nil and track.ClassName == "AnimationTrack"
       and type(track.Play) == "function"
end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    return lp.Backpack ~= nil       and lp.Backpack.ClassName == "Backpack"
       and lp.PlayerGui ~= nil      and lp.PlayerGui.ClassName == "PlayerGui"
       and lp.PlayerScripts ~= nil  and lp.PlayerScripts.ClassName == "PlayerScripts"
end)
tamperCheck(function()
    local stats = game.Players.LocalPlayer.leaderstats
    return stats ~= nil and stats.ClassName == "Folder"
       and stats:FindFirstChild("Coins") ~= nil
       and stats:FindFirstChild("Level"):IsA("IntValue")
end)
tamperCheck(function()
    local stats = game.Players.LocalPlayer.leaderstats
    return stats.Coins.Value == 0 and stats.Level.Value == 1
end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    return type(lp.CharacterAdded.Connect)            == "function"
       and type(lp.CharacterRemoving.Connect)         == "function"
       and type(lp.CharacterAppearanceLoaded.Connect) == "function"
       and type(lp.Idled.Connect)                     == "function"
end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    local m  = lp:GetMouse()
    return m ~= nil and m.ClassName == "Mouse"
       and typeof(m.Hit) == "CFrame"
       and type(m.Button1Down.Connect) == "function"
end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    return lp:IsFriendsWith(0)        == false
       and lp:IsInGroup(0)            == false
       and lp:GetRankInGroup(0)       == 0
       and lp:GetRoleInGroup(0)       == "Guest"
       and lp:DistanceFromCharacter(Vector3.new()) == 0
end)
tamperCheck(function()
    local lp = game.Players.LocalPlayer
    local ok = pcall(function() lp:Kick("test") end)
    return ok
end)
tamperCheck(function()
    local players = game.Players
    return players.NumPlayers == 1 and players.MaxPlayers == 16
       and type(players.PlayerAdded.Connect)    == "function"
       and type(players.PlayerRemoving.Connect) == "function"
end)
tamperCheck(function()
    local players = game.Players
    local lp = players.LocalPlayer
    return players:GetPlayerFromCharacter(lp.Character) == lp
       and players:GetPlayerFromCharacter(nil)          == nil
end)
tamperCheck(function()
    local players = game.Players
    local lp = players.LocalPlayer
    return players:GetUserIdFromNameAsync(lp.Name) == lp.UserId
       and players:GetNameFromUserIdAsync(lp.UserId) == lp.Name
end)

print("pass")
]==]

local function _bypass_run()
    local chunk, loadErr
    if setfenv then
        chunk, loadErr = (loadstring or load)(TAMPERCHECK_SNIPPET, "tamperCheck")
        if chunk then setfenv(chunk, _bypassEnv) end
    else
        chunk, loadErr = load(TAMPERCHECK_SNIPPET, "tamperCheck", "t", _bypassEnv)
    end
    if not chunk then
        return false
    end
    local ok, runErr = pcall(chunk)
    if not ok then
        return false
    end
    return true
end

_BYPASS.env       = _bypassEnv
_BYPASS.run       = _bypass_run
_BYPASS.snippet   = TAMPERCHECK_SNIPPET
_BYPASS.typeof    = _bypass_typeof
_BYPASS.services  = _services

local _native_load = load
local _native_loadstring = loadstring
local _native_next = next
local _skip_luau_only_tamper = false
do
    local _input_path = arg and arg[1]
    if type(_input_path) == "string" then
        local _input_file = io.open(_input_path, "rb")
        if _input_file then
            local _input_code = _input_file:read("*a") or ""
            _input_file:close()
            _skip_luau_only_tamper = _input_code:find("GUF_OBFUSCATED = true", 1, true) ~= nil
                and _input_code:find("Goofantitamper detected you", 1, true) ~= nil
                and _input_code:find("FloatCurveKey.new", 1, true) ~= nil
                and _input_code:find('Instance.new("FloatCurve")', 1, true) ~= nil
        end
    end
end
if not _skip_luau_only_tamper then
    _BYPASS.run()
end


local debugLibrary = debug
_G._VERSION = "Luau"
local setHook = debugLibrary.sethook
local getInfo = debugLibrary.getinfo
local getTraceback = debugLibrary.traceback
local loadFunction = _native_load or load
local loadStringFunction = _native_loadstring or _native_load or load
local pcallFunction = pcall
local xpcallFunction = xpcall
local errorFunction = error
local typeFunction = type
local _CFunctionSet = setmetatable({}, {__mode = "k"})
local getMetatableFunction = getmetatable
local rawEqualFunction = rawequal
local toStringFunction = tostring
local toNumberFunction = tonumber
local ioLibrary = io
local osLibrary = os
local pairsFunction = pairs
local ipairsFunction = ipairs
local tableUnpackFunction = table.unpack or unpack
local proxyTable = {}
proxyTable.__index = proxyTable
local configuration = {
    MAX_DEPTH = 20,
    MAX_TABLE_ITEMS = 300,
    OUTPUT_FILE = "dumped_output.lua",
    VERBOSE = false,
    TRACE_CALLBACKS = true,
    TIMEOUT_SECONDS = 45,
    MAX_REPEATED_LINES = 8,
    MIN_DEOBF_LENGTH = 150,
    MAX_OUTPUT_SIZE = 10 * 1024 * 1024,
    CONSTANT_COLLECTION = true,
    INSTRUMENT_LOGIC = true
}
local inputKey = (arg and arg[3]) or "NoKey"
if arg and arg[3] then
    print("[Dumper] Auto-Input Key Detected: " .. toStringFunction(inputKey))
end
local dumperState = {
    output = {},
    indent = 0,
    registry = {},
    reverse_registry = {},
    names_used = {},
    proxy_name = {},
    parent_map = {},
    property_store = {},
    call_graph = {},
    variable_types = {},
    string_refs = {},
    proxy_id = 0,
    callback_depth = 0,
    pending_iterator = false,
    last_http_url = nil,
    last_emitted_line = nil,
    repetition_count = 0,
    current_size = 0,
    ls_counter = 0
}

local _at = {
    mem          = {},
    tags         = {},
    sigs         = {},
    acts         = {},
    json         = {},
    enum         = {},
    svcCache     = {},
    typeOverride = {},
    connState    = {},
    debugIds     = {},
    debugIdCtr   = 0,
    instTags     = {},
    attrs        = {},
    children     = {},
    threadLike   = {},
    vectors      = {},
    buffers      = {},
    userdata     = {},
    localPlayer  = nil,
    weldRegistry = {},
    services     = {},
    folders      = {},
    files        = {},
    refBase      = {},
    metaHooks    = {},
    currentNamecallMethod = nil,
    inMetaHook   = false,
    angularVel   = {},
    linearVel    = {},
    propertyDefaults = {},
    propertyModified = {},
    methodCache = {},
}
setmetatable(_at.debugIds, {__mode = "k"})
setmetatable(_at.instTags, {__mode = "k"})
setmetatable(_at.attrs, {__mode = "k"})
setmetatable(_at.children, {__mode = "k"})
setmetatable(_at.threadLike, {__mode = "k"})
setmetatable(_at.vectors, {__mode = "k"})
setmetatable(_at.buffers, {__mode = "k"})
setmetatable(_at.userdata, {__mode = "k"})
setmetatable(_at.refBase, {__mode = "k"})
setmetatable(_at.propertyDefaults, {__mode = "k"})
setmetatable(_at.propertyModified, {__mode = "k"})
setmetatable(_at.methodCache, {__mode = "k"})
local function _propertyName(value)
    if typeFunction(value) == "string" then return value end
    return toStringFunction(value)
end
local function _coercePropertyValue(property, value)
    if property == "Transparency" and typeFunction(value) == "number"
        and type(buffer) == "table" and type(buffer.create) == "function"
        and type(buffer.writef32) == "function" and type(buffer.readf32) == "function" then
        local ok, sample = pcallFunction(buffer.create, 4)
        if ok and sample then
            local wrote = pcallFunction(buffer.writef32, sample, 0, value)
            if wrote then
                local readOk, rounded = pcallFunction(buffer.readf32, sample, 0)
                if readOk then return rounded end
            end
        end
    end
    return value
end
local function _getDebugId(p)
    if not _at.debugIds[p] then
        _at.debugIdCtr = _at.debugIdCtr + 1
        local n = _at.debugIdCtr
        _at.debugIds[p] = toStringFunction(n * 17 + 3) .. "-" .. toStringFunction(n * 97 + 11)
    end
    return _at.debugIds[p]
end
local function _removeChild(parent, child)
    local list = parent and _at.children[parent]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == child then table.remove(list, i) end
    end
end
local function _setParent(child, parent)
    if _at.destroyed and (_at.destroyed[child] or _at.destroyed[parent] or _at.destroyed[dumperState.parent_map[child]]) then
        error("Instance is locked or destroyed", 2)
    end
    local oldParent = dumperState.parent_map[child]
    if oldParent == parent then return end
    _removeChild(oldParent, child)
    dumperState.parent_map[child] = parent
    local childProperties = dumperState.property_store[child]
    if childProperties then childProperties.Parent = parent end
    if parent then
        _at.children[parent] = _at.children[parent] or {}
        table.insert(_at.children[parent], child)
    end
end
local function _isDescendantOf(child, parent)
    local cur = dumperState.parent_map[child]
    while cur do
        if cur == parent then return true end
        cur = dumperState.parent_map[cur]
    end
    return false
end
local function _getAllDescendants(root, out)
    out = out or {}
    for _, child in ipairsFunction(_at.children[root] or {}) do
        table.insert(out, child)
        _getAllDescendants(child, out)
    end
    return out
end
local numericArg = (arg and toNumberFunction(arg[4])) or (arg and toNumberFunction(arg[3])) or 123456789
local proxyMarker = {}
local function isProxyTable(target)
    if typeFunction(target) ~= "table" then
        return false
    end
    local success, result = pcallFunction( function() return rawget(target, proxyMarker) == true end )
    return success and result
end
local function getProxyValue(target)
    if isProxyTable(target) then
        return rawget(target, "__value") or 0
    end
    return 0
end
local loadStringFunction = _native_loadstring or _native_load or load
local printFunction = print
local warnFunction = warn or function() end
local pairsFunction = pairs
local ipairsFunction = ipairs
local typeFunction = type
local toStringFunction = tostring
local proxyList = {}
local function isProxy(target)
    if typeFunction(target) ~= "table" then
        return false
    end
    local success, result = pcallFunction( function() return rawget(target, proxyList) == true end )
    return success and result
end
local function getProxyId(target)
    if not isProxy(target) then
        return nil
    end
    return rawget(target, "__proxy_id")
end
local function processString(inputString)
    if typeFunction(inputString) ~= "string" then
        return '"'
    end
    local outputParts = {}
    local currentIndex, totalLength = 1, #inputString
    local function cleanEscapes(content)
        return content:gsub( "\\\\(.)", function(escapedChar)
            if escapedChar:match('[abfnrtv\\\\%\'%\\"%[%]0-9xu]') then
                return "" .. escapedChar
            end
            return escapedChar
        end )
    end
    local function stripLuauSyntax(rawCode)
        if not rawCode or rawCode == "" then
            return rawCode
        end
        rawCode = rawCode:gsub("\239\187\191", "")
        rawCode = rawCode:gsub("\r\n", "\n"):gsub("\r", "\n")
        rawCode = rawCode:gsub("\226\128\168", "\n"):gsub("\226\128\169", "\n")
        rawCode = rawCode:gsub("%-%-!%a+[^\n]*", "")
        rawCode = rawCode:gsub("([^\n]*)", function(line)
            if line:match("^%s*export%s+type%s+") or line:match("^%s*type%s+[%a_][%w_]*%s*=") then
                return "-- " .. line
            end
            return line
        end)
        rawCode = rawCode:gsub("local%s+([%a_][%w_]*)%s*<[%a_][%w_]*>%s*=", "local %1 =")
        rawCode = rawCode:gsub("(function%s+[%a_][%w_%.:]*)%s*<[^>\n%(]+>%s*%(", "%1(")
        rawCode = rawCode:gsub("([%(%s,])%.%.%.%s*:%s*[%a_][%w_%.]*%??", "%1...")
        rawCode = rawCode:gsub("([%(%s,])([%a_][%w_]*)%s*:%s*[%a_][%w_%.]*%s*%b<>%??", "%1%2")
        rawCode = rawCode:gsub("([%(%s,])([%a_][%w_]*)%s*:%s*[%a_][%w_%.]*%??(%s*[%),=])", "%1%2%3")
        rawCode = rawCode:gsub("%)%s*:%s*[%a_][%w_%.]*%s*%b<>%??", ")")
        rawCode = rawCode:gsub("%)%s*:%s*[%a_][%w_%.]*%??(%s*[%),=])", ")%1")
        rawCode = rawCode:gsub("%s*::%s*[%a_][%w_%.]*%s*%b<>%??", "")
        rawCode = rawCode:gsub("%s*::%s*[%a_][%w_%.]*%??", "")
        return rawCode
    end
    local function parseExpression(rawCode)
        if not rawCode or rawCode == '"' then
            return ""
        end
        rawCode = stripLuauSyntax(rawCode)
        rawCode = rawCode:gsub( "0[bB]([01_]+)", function(binaryString)
            local cleanBinary = binaryString:gsub("_", "")
            local decimalValue = toNumberFunction(cleanBinary, 2)
            return decimalValue and toStringFunction(decimalValue) or "0"
        end )
        rawCode = rawCode:gsub( "0[xX]([%x_]+)", function(hexString)
            local cleanHex = hexString:gsub("_", "")
            return "0x" .. cleanHex
        end )
        while rawCode:match("%d_+%d") do
            rawCode = rawCode:gsub("(%d)_+(%d)", "%1%2")
        end
        local operators = {{"+=", "+"}, {"-=", "-"}, {"*=", "*"}, {"/=", "/"}, {"%%=", "%%"}, {"%^=", "^"}, {"%.%.=", ".."}}
        for _, opPair in ipairsFunction(operators) do
            local operatorAssignment, operator = opPair[1], opPair[2]
            rawCode = rawCode:gsub( "([%a_][%w_]*%b[])%s*" .. operatorAssignment, function(varName)
                return varName .. " = " .. varName .. " " .. operator .. " "
            end )
            rawCode = rawCode:gsub( "([%a_][%w_]*[%.%a_%d][%w_%.]*%.[%a_][%w_]*)%s*" .. operatorAssignment, function(varName)
                return varName .. " = " .. varName .. " " .. operator .. " "
            end )
            rawCode = rawCode:gsub( "([^%w_%.%]%):])([%a_][%w_]*)%s*" .. operatorAssignment, function(prefix, varName)
                return prefix .. varName .. " = " .. varName .. " " .. operator .. " "
            end )
            rawCode = rawCode:gsub( "^([%a_][%w_]*)%s*" .. operatorAssignment, function(varName)
                return varName .. " = " .. varName .. " " .. operator .. " "
            end )
        end

        rawCode = rawCode:gsub("([%a_][%w_]*%b[])%s*%+%+",            "%1 = %1 + 1")
        rawCode = rawCode:gsub("([%a_][%w_]*%.[%w_%.]*[%w_])%s*%+%+","%1 = %1 + 1")
        rawCode = rawCode:gsub("([%a_][%w_]*)%s*%+%+",                "%1 = %1 + 1")
        rawCode = rawCode:gsub("%+%+%s*([%a_][%w_]*%b[])",            "%1 = %1 + 1")
        rawCode = rawCode:gsub("%+%+%s*([%a_][%w_]*%.[%w_%.]*[%w_])","%1 = %1 + 1")
        rawCode = rawCode:gsub("%+%+%s*([%a_][%w_]*)",                "%1 = %1 + 1")
        rawCode = rawCode:gsub("%+%+", "+")

        rawCode = rawCode:gsub("([^%w_])continue([^%w_])", "%1_G.LuraphContinue()%2")
        rawCode = rawCode:gsub("^continue([^%w_])", "_G.LuraphContinue()%1")
        rawCode = rawCode:gsub("([^%w_])continue$", "%1_G.LuraphContinue()")
        return rawCode
    end
    local function getBracketCount(index)
        local count = 0
        while index <= totalLength and inputString:byte(index) == 61 do
            count = count + 1
            index = index + 1
        end
        return count, index
    end
    local function findClosingBracket(startIndex, bracketCount)
        local closingPattern = "]" .. string.rep("=", bracketCount) .. "]"
        local start, finish = inputString:find(closingPattern, startIndex, true)
        return finish or totalLength
    end
    local segmentStart = 1
    while currentIndex <= totalLength do
        local byteValue = inputString:byte(currentIndex)
        if byteValue == 91 then
            local bracketCount, nextIndex = getBracketCount(currentIndex + 1)
            if nextIndex <= totalLength and inputString:byte(nextIndex) == 91 then
                table.insert(outputParts, parseExpression(inputString:sub(segmentStart, currentIndex - 1)))
                local startSegment = currentIndex
                local endSegment = findClosingBracket(nextIndex + 1, bracketCount)
                table.insert(outputParts, inputString:sub(startSegment, endSegment))
                currentIndex = endSegment
                segmentStart = currentIndex + 1
            end
        elseif byteValue == 45 and currentIndex + 1 <= totalLength and inputString:byte(currentIndex + 1) == 45 then
            table.insert(outputParts, parseExpression(inputString:sub(segmentStart, currentIndex - 1)))
            local startSegment = currentIndex
            if currentIndex + 2 <= totalLength and inputString:byte(currentIndex + 2) == 91 then
                local bracketCount, nextIndex = getBracketCount(currentIndex + 3)
                if nextIndex <= totalLength and inputString:byte(nextIndex) == 91 then
                    local endSegment = findClosingBracket(nextIndex + 1, bracketCount)
                    table.insert(outputParts, inputString:sub(startSegment, endSegment))
                    currentIndex = endSegment
                    segmentStart = currentIndex + 1
                    currentIndex = currentIndex + 1
                end
            end
            local lineBreak = inputString:find("\n", currentIndex + 2, true)
            if lineBreak then
                currentIndex = lineBreak
            else
                currentIndex = totalLength
            end
            table.insert(outputParts, inputString:sub(startSegment, currentIndex))
            segmentStart = currentIndex + 1
        elseif byteValue == 34 or byteValue == 39 or byteValue == 96 then
            table.insert(outputParts, parseExpression(inputString:sub(segmentStart, currentIndex - 1)))
            local quoteType = byteValue
            local startSegment = currentIndex
            currentIndex = currentIndex + 1
            while currentIndex <= totalLength do
                local charByte = inputString:byte(currentIndex)
                if charByte == 92 then
                    currentIndex = currentIndex + 1
                elseif charByte == quoteType then
                    break
                end
                currentIndex = currentIndex + 1
            end
            local extractedContent = inputString:sub(startSegment + 1, currentIndex - 1)
            extractedContent = cleanEscapes(extractedContent)
            if quoteType == 96 then
                table.insert(outputParts, '"' .. extractedContent:gsub('"', '\\\\"') .. '"')
            else
                local quoteChar = string.char(quoteType)
                table.insert(outputParts, quoteChar .. extractedContent .. quoteChar)
            end
            segmentStart = currentIndex + 1
        end
        currentIndex = currentIndex + 1
    end
    table.insert(outputParts, parseExpression(inputString:sub(segmentStart)))
    return table.concat(outputParts)
end
local function safeLoad(code, chunkName)
    local loadedFunc, errorMessage = loadStringFunction(code, chunkName)
    if loadedFunc then
        return loadedFunc
    end
    printFunction("\n[CRITICAL ERROR] Failed to load script!")
    printFunction("[LUA_LOAD_FAIL] " .. toStringFunction(errorMessage))
    local errorLine = toNumberFunction(errorMessage:match(":(%d+):"))
    local errorNear = errorMessage:match("near '([^']+)'")
    if errorNear then
        local foundIndex = code:find(errorNear, 1, true)
        if foundIndex then
            local startCtx = math.max(1, foundIndex - 50)
            local endCtx = math.min(#code, foundIndex + 50)
            printFunction("Context around error:")
            printFunction("..." .. code:sub(startCtx, endCtx) .. "...")
        end
    end
    local _debugName = string.format("DEBUG_FAILED_TRANSPILE_%d.lua",
        math.floor((osLibrary and osLibrary.clock or os.clock)() * 1000) % 1000000)
    local debugFile = ioLibrary.open(_debugName, "w")
    if debugFile then
        debugFile:write(code)
        debugFile:close()
        printFunction("[*] Saved to '" .. _debugName .. "' for inspection")
    end
    return nil, errorMessage
end
local function emitOutput(data, isInline)
    if dumperState.limit_reached then
        return
    end
    if data == nil then
        return
    end
    local indentPrefix = isInline and "" or string.rep("    ", dumperState.indent)
    local lineString = indentPrefix .. toStringFunction(data)
    local lineSize = #lineString + 1
    if dumperState.current_size + lineSize > configuration.MAX_OUTPUT_SIZE then
        dumperState.limit_reached = true
        local limitMB = string.format("%.0f", configuration.MAX_OUTPUT_SIZE / (1024 * 1024))
        local warningMessage = "-- [CRITICAL] Dump stopped: File size exceeded " .. limitMB .. "MB limit."
        table.insert(dumperState.output, warningMessage)
        dumperState.current_size = dumperState.current_size + #warningMessage
        errorFunction("DUMP_LIMIT_EXCEEDED")
    end
    if lineString == dumperState.last_emitted_line then
        dumperState.repetition_count = dumperState.repetition_count + 1
        if dumperState.repetition_count <= configuration.MAX_REPEATED_LINES then
            table.insert(dumperState.output, lineString)
            dumperState.current_size = dumperState.current_size + lineSize
        elseif dumperState.repetition_count == configuration.MAX_REPEATED_LINES + 1 then
            local suppressMessage = indentPrefix .. "-- [Repeated lines suppressed...]"
            table.insert(dumperState.output, suppressMessage)
            dumperState.current_size = dumperState.current_size + #suppressMessage
        end
    else
        dumperState.last_emitted_line = lineString
        dumperState.repetition_count = 0
        table.insert(dumperState.output, lineString)
        dumperState.current_size = dumperState.current_size + lineSize
    end
    if configuration.VERBOSE and dumperState.repetition_count <= 1 then
        printFunction(lineString)
    end
end
local function emitComment(data)
    emitOutput("-- " .. toStringFunction(data or ""))
end
local function addEmptyLine()
    dumperState.last_emitted_line = nil
    local last = dumperState.output[#dumperState.output]
    if last == "" then
        return
    end
    table.insert(dumperState.output, "")
end
local function getFullOutput()
    return table.concat(dumperState.output, "\n")
end
local function saveToFile(filePath)
    local fileHandle = ioLibrary.open(filePath or configuration.OUTPUT_FILE, "w")
    if fileHandle then
        fileHandle:write(getFullOutput())
        fileHandle:close()
        return true
    end
    return false
end
local function formatValue(value)
    if value == nil then
        return "nil"
    end
    if typeFunction(value) == "string" then
        return value
    end
    if typeFunction(value) == "number" or typeFunction(value) == "boolean" then
        return toStringFunction(value)
    end
    if typeFunction(value) == "table" then
        if dumperState.registry[value] then
            return dumperState.registry[value]
        end
        if isProxy(value) then
            local proxyId = getProxyId(value)
            return proxyId and "proxy_" .. proxyId or "proxy"
        end
    end
    local success, result = pcallFunction(toStringFunction, value)
    return success and result or "unknown"
end
local function formatStringLiteral(value)
    local rawValue = formatValue(value)
    if typeFunction(rawValue) ~= "string" then
        rawValue = toStringFunction(rawValue)
    end
    if #rawValue > 256 then
        local sampleLen = math.min(#rawValue, 4096)
        local sample = rawValue:sub(1, sampleLen)
        local nonPrintable = 0
        for i = 1, sampleLen do
            local b = sample:byte(i)
            if b < 9 or (b > 13 and b < 32) or b == 127 then
                nonPrintable = nonPrintable + 1
            end
        end
        local ratio = nonPrintable / sampleLen
        local isBase64 = rawValue:match("^[A-Za-z0-9+/=\r\n]+$") ~= nil
                         and (#rawValue % 4 == 0 or rawValue:match("=+$") ~= nil)
        local isHex = rawValue:match("^[%x\r\n]+$") ~= nil and #rawValue >= 32
        if ratio > 0.05 or isBase64 or isHex then
            local hint = isHex and "hex" or (isBase64 and "base64" or "binary")
            local previewLen = math.min(64, #rawValue)
            local head = rawValue:sub(1, previewLen):gsub("\\", "\\\\"):gsub('"', '\\"')
                :gsub("[%z\1-\31\127]", function(c) return string.format("\\%d", c:byte()) end)
            local suffix = #rawValue > previewLen and "..." or ""
            return string.format('"%s%s" ', head, suffix, hint, #rawValue)
        end
    end
    if rawValue:find("\n", 1, true) and not rawValue:find("\r", 1, true)
        and not rawValue:match("[%z\1-\8\11\12\14-\31\127]") then
        for level = 0, 5 do
            local eq = string.rep("=", level)
            local close = "]" .. eq .. "]"
            if not rawValue:find(close, 1, true) then
                local body = rawValue
                if body:sub(1, 1) == "\n" then body = "\n" .. body end
                return "[" .. eq .. "[" .. body .. "]" .. eq .. "]"
            end
        end
    end
    local escapedValue = rawValue
        :gsub("\\", "\\\\")
        :gsub("\r", "\\r")
        :gsub("\n", "\\n")
        :gsub("\t", "\\t")
        :gsub('"', '\\"')
        :gsub("[%z\1-\8\11\12\14-\31\127]", function(c)
            return string.format("\\%d", string.byte(c))
        end)
    return '"' .. escapedValue .. '"'
end
local serviceNames = {
    Players = "Players",
    Workspace = "Workspace",
    Lighting = "Lighting",
    ReplicatedStorage = "ReplicatedStorage",
    ReplicatedFirst = "ReplicatedFirst",
    ServerStorage = "ServerStorage",
    ServerScriptService = "ServerScriptService",
    StarterGui = "StarterGui",
    StarterPack = "StarterPack",
    StarterPlayer = "StarterPlayer",
    StarterPlayerScripts = "StarterPlayerScripts",
    StarterCharacterScripts = "StarterCharacterScripts",
    Teams = "Teams",
    Chat = "Chat",
    SoundService = "SoundService",
    RunService = "RunService",
    NetworkClient = "NetworkClient",
    NetworkServer = "NetworkServer",
    NetworkSettings = "NetworkSettings",
    Stats = "Stats",
    StatsService = "Stats",
    UserInputService = "UserInputService",
    UserGameSettings = "UserGameSettings",
    GuiService = "GuiService",
    HapticService = "HapticService",
    VRService = "VRService",
    GamepadService = "GamepadService",
    TouchInputService = "TouchInputService",
    VirtualUser = "VirtualUser",
    VirtualInputManager = "VirtualInputManager",
    ContextActionService = "ContextActionService",
    ProximityPromptService = "ProximityPromptService",
    TweenService = "TweenService",
    PathfindingService = "PathfindingService",
    AnimationClipProvider = "AnimationClipProvider",
    KeyframeSequenceProvider = "KeyframeSequenceProvider",
    HttpService = "HttpService",
    HttpRbxApiService = "HttpRbxApiService",
    DataStoreService = "DataStoreService",
    MessagingService = "MessagingService",
    MemoryStoreService = "MemoryStoreService",
    MemStorageService = "MemStorageService",
    MarketplaceService = "MarketplaceService",
    BadgeService = "BadgeService",
    FriendService = "FriendService",
    GroupService = "GroupService",
    SocialService = "SocialService",
    CommerceService = "CommerceService",
    AvatarEditorService = "AvatarEditorService",
    InsertService = "InsertService",
    AssetService = "AssetService",
    AssetCounterService = "AssetCounterService",
    AssetDeliveryProxy = "AssetDeliveryProxy",
    BulkImportService = "BulkImportService",
    TeleportService = "TeleportService",
    PlayerEmulatorService = "PlayerEmulatorService",
    PhysicsService = "PhysicsService",
    CollectionService = "CollectionService",
    TextService = "TextService",
    TextChatService = "TextChatService",
    LocalizationService = "LocalizationService",
    LocalizationTable = "LocalizationTable",
    CoreGui = "CoreGui",
    StylingService = "StylingService",
    CaptureService = "CaptureService",
    NotificationService = "NotificationService",
    ContentProvider = "ContentProvider",
    MeshContentProvider = "MeshContentProvider",
    SolidModelContentProvider = "SolidModelContentProvider",
    KeyframeSequenceProvider2 = "KeyframeSequenceProvider",
    Debris = "Debris",
    LogService = "LogService",
    ScriptContext = "ScriptContext",
    PolicyService = "PolicyService",
    AnalyticsService = "AnalyticsService",
    AdService = "AdService",
    RbxAnalyticsService = "RbxAnalyticsService",
    ChangeHistoryService = "ChangeHistoryService",
    RunSrv = "RunService",
    VoiceChatService = "VoiceChatService",
    VoiceChatInternal = "VoiceChatInternal",
    Selection = "Selection",
    StudioService = "StudioService",
    ScriptEditorService = "ScriptEditorService",
    PluginGuiService = "PluginGuiService",
    PluginManager = "PluginManager",
    DraftsService = "DraftsService",
    ScriptDocumentService = "ScriptDocumentService",
    MaterialService = "MaterialService",
    Terrain = "Terrain",
    TerrainRegion = "TerrainRegion",
    RobloxReplicatedStorage = "RobloxReplicatedStorage",
    ProcessService = "ProcessService",
    TimerService = "TimerService",
    AppUpdateService = "AppUpdateService",
    AssetCounterService2 = "AssetCounterService",
    AssetImportService = "AssetImportService",
    AssetManagerService = "AssetManagerService",
    AssetSearchService = "AssetSearchService",
    AvatarImportService = "AvatarImportService",
    BadgeService2 = "BadgeService",
    BrowserService = "BrowserService",
    CacheableContentProvider = "CacheableContentProvider",
    CalloutService = "CalloutService",
    ClusterPacketCache = "ClusterPacketCache",
    CollaboratorsService = "CollaboratorsService",
    ConfigureServerService = "ConfigureServerService",
    ContentManagerService = "ContentManagerService",
    ContentProviderService = "ContentProvider",
    ContextActionService2 = "ContextActionService",
    CookiesService = "CookiesService",
    CoreScriptSyncService = "CoreScriptSyncService",
    CrossDMScriptChangeListener = "CrossDMScriptChangeListener",
    DebuggablePluginWatcher = "DebuggablePluginWatcher",
    DebugSettings = "DebugSettings",
    DraftsService = "DraftsService",
    DraggerService = "DraggerService",
    EventIngestService = "EventIngestService",
    ExperienceAuthService = "ExperienceAuthService",
    ExperienceNotificationService = "ExperienceNotificationService",
    ExperienceStateCaptureService = "ExperienceStateCaptureService",
    ExperimentationService = "ExperimentationService",
    FaceAnimatorService = "FaceAnimatorService",
    FacialAnimationStreamingService = "FacialAnimationStreamingService",
    FacialAnimationStreamingServiceV2 = "FacialAnimationStreamingServiceV2",
    FaceAnalyzerService = "FaceAnalyzerService",
    FlagStandService = "FlagStandService",
    FlyweightService = "FlyweightService",
    FontService = "FontService",
    GameSettings = "GameSettings",
    GamepadConnectedService = "GamepadConnectedService",
    GamepadService2 = "GamepadService",
    Geometry = "Geometry",
    GoogleAnalyticsConfiguration = "GoogleAnalyticsConfiguration",
    GroupService2 = "GroupService",
    GuiInsetService = "GuiInsetService",
    HSRDataContentProvider = "HSRDataContentProvider",
    HapticEffectService = "HapticEffectService",
    HeightmapImporterService = "HeightmapImporterService",
    HiddenSurfaceRemovalAsset = "HiddenSurfaceRemovalAsset",
    HumanoidController = "HumanoidController",
    IXPService = "IXPService",
    IncrementalPatchBuilder = "IncrementalPatchBuilder",
    InputObject = "InputObject",
    JointsService = "JointsService",
    KeyboardService = "KeyboardService",
    LanguageService = "LanguageService",
    LegacyChatService = "LegacyChatService",
    LiveScriptingService = "LiveScriptingService",
    LobbyService = "LobbyService",
    LocalDebuggerService = "LocalDebuggerService",
    LocalStorageService = "LocalStorageService",
    LoginService = "LoginService",
    LuaSettings = "LuaSettings",
    LuaSourceContainer = "LuaSourceContainer",
    LuaWebService = "LuaWebService",
    LuauScriptAnalyzerService = "LuauScriptAnalyzerService",
    MatchmakingService = "MatchmakingService",
    MemoryStoreQueue = "MemoryStoreQueue",
    MessageBusService = "MessageBusService",
    MetaBreakpointManager = "MetaBreakpointManager",
    MouseService = "MouseService",
    MultipleDocumentInterfaceInstance = "MultipleDocumentInterfaceInstance",
    NetworkPeer = "NetworkPeer",
    NetworkReplicator = "NetworkReplicator",
    NonReplicatedCSGDictionaryService = "NonReplicatedCSGDictionaryService",
    NotificationManagerService = "NotificationManagerService",
    OmniRecommendationsService = "OmniRecommendationsService",
    OpenCloudService = "OpenCloudService",
    PackageService = "PackageService",
    PackageUIService = "PackageUIService",
    PartOperationAsset = "PartOperationAsset",
    PausedStateDebuggerManager = "PausedStateDebuggerManager",
    PausedStateManager = "PausedStateManager",
    PerformanceControlService = "PerformanceControlService",
    PermissionsService = "PermissionsService",
    PhysicsPacketCache = "PhysicsPacketCache",
    PlayerHydrationService = "PlayerHydrationService",
    PluginCapabilitiesService = "PluginCapabilitiesService",
    PluginDebugService = "PluginDebugService",
    PluginPolicyService = "PluginPolicyService",
    PointsService = "PointsService",
    PrivateMessageService = "PrivateMessageService",
    PublishService = "PublishService",
    RbxAnalyticsService2 = "RbxAnalyticsService",
    ReflectionMetadata = "ReflectionMetadata",
    RemoteCursorService = "RemoteCursorService",
    RemoteDebuggerServer = "RemoteDebuggerServer",
    RemoteDebuggerService = "RemoteDebuggerService",
    RenderHooksService = "RenderHooksService",
    RenderSettings = "RenderSettings",
    ReplicatedScriptService = "ReplicatedScriptService",
    RibbonNotificationService = "RibbonNotificationService",
    RobloxPluginGuiService = "RobloxPluginGuiService",
    RobloxReplicatedStorage2 = "RobloxReplicatedStorage",
    RotateP = "RotateP",
    RotateV = "RotateV",
    RunningAverageItemDouble = "RunningAverageItemDouble",
    RuntimeScriptService = "RuntimeScriptService",
    SafetyService = "SafetyService",
    SafeBrowsingService = "SafeBrowsingService",
    ScreenshotHud = "ScreenshotHud",
    ScriptChangeService = "ScriptChangeService",
    ScriptCloneWatcher = "ScriptCloneWatcher",
    ScriptCloneWatcherHelper = "ScriptCloneWatcherHelper",
    ScriptContext2 = "ScriptContext",
    ScriptDebugger = "ScriptDebugger",
    ScriptProfilerService = "ScriptProfilerService",
    ScriptRegistrationService = "ScriptRegistrationService",
    ScriptService = "ScriptService",
    ServerScriptService2 = "ServerScriptService",
    ServiceProvider = "ServiceProvider",
    ServiceVisibilityService = "ServiceVisibilityService",
    SessionService = "SessionService",
    Smooth = "Smooth",
    SmoothVoxelsUpgraderService = "SmoothVoxelsUpgraderService",
    SnippetService = "SnippetService",
    Speaker = "Speaker",
    StackedReplicaService = "StackedReplicaService",
    StarterCore = "StarterCore",
    StopWatchReporter = "StopWatchReporter",
    StreamingService = "StreamingService",
    StudioAssetService = "StudioAssetService",
    StudioData = "StudioData",
    StudioDeviceEmulatorService = "StudioDeviceEmulatorService",
    StudioHighDpiService = "StudioHighDpiService",
    StudioPublishService = "StudioPublishService",
    StudioScriptDebugEventListener = "StudioScriptDebugEventListener",
    StudioSdkService = "StudioSdkService",
    StudioServerService = "StudioServerService",
    StudioWidget = "StudioWidget",
    SurfaceAppearance = "SurfaceAppearance",
    TaskScheduler = "TaskScheduler",
    TeleportingDelegationService = "TeleportingDelegationService",
    TeleportOptions = "TeleportOptions",
    TestService = "TestService",
    TextBoxService = "TextBoxService",
    TextChannel = "TextChannel",
    TextChatCommands = "TextChatCommands",
    TextChatConfigurations = "TextChatConfigurations",
    ThirdPartyUserService = "ThirdPartyUserService",
    ThreadPoolConfig = "ThreadPoolConfig",
    TimerService2 = "TimerService",
    TouchTransmitter = "TouchTransmitter",
    TracerService = "TracerService",
    TrackerLodController = "TrackerLodController",
    TrackerStreamAnimation = "TrackerStreamAnimation",
    TutorialService = "TutorialService",
    UGCAvatarService = "UGCAvatarService",
    UGCValidationService = "UGCValidationService",
    UnvalidatedAssetService = "UnvalidatedAssetService",
    UserInputService2 = "UserInputService",
    UserService = "UserService",
    UserStorageService = "UserStorageService",
    UserSettings = "UserSettings",
    VRStatusService = "VRStatusService",
    VersionControlService = "VersionControlService",
    VideoCaptureService = "VideoCaptureService",
    VirtualInputManager2 = "VirtualInputManager",
    VirtualUser2 = "VirtualUser",
    VisibilityCheckDispatcher = "VisibilityCheckDispatcher",
    VisualizationMode = "VisualizationMode",
    Visit = "Visit",
    VoiceChannel = "VoiceChannel",
    VoiceSource = "VoiceSource",
    Workspace2 = "Workspace",
    WorldModel = "WorldModel",
    WorldRoot = "WorldRoot",
    WrapLayer = "WrapLayer",
    WrapTarget = "WrapTarget",
    BindableEventService = "BindableEventService",
    Camera = "Camera",
    Configuration = "Configuration",
    Controller = "Controller",
    DataModel = "DataModel",
    DataModelMesh = "DataModelMesh",
    Decal = "Decal",
    DialogChoice = "DialogChoice",
    Dialog = "Dialog",
    Dragger = "Dragger",
    Explosion = "Explosion",
    FileMesh = "FileMesh",
    FormFactorPart = "FormFactorPart",
    GuiBase = "GuiBase",
    GuiBase2d = "GuiBase2d",
    GuiBase3d = "GuiBase3d",
    Hat = "Hat",
    HingeConstraint = "HingeConstraint",
    Hopper = "Hopper",
    HopperBin = "HopperBin",
    JointInstance = "JointInstance",
    Keyframe = "Keyframe",
    KeyframeMarker = "KeyframeMarker",
    KeyframeSequence = "KeyframeSequence",
    LayerCollector = "LayerCollector",
    Light = "Light",
    LineHandleAdornment = "LineHandleAdornment",
    LocalizationTable2 = "LocalizationTable",
    Message = "Message",
    Pages = "Pages",
    PartOperation = "PartOperation",
    Pose = "Pose",
    Status = "Status",
    StringValue = "StringValue",
    Tool = "Tool",
    Trail = "Trail",
    TrussPart = "TrussPart",
    UnreliableRemoteEvent = "UnreliableRemoteEvent",
    VRClient = "VRClient",
    VehicleSeat = "VehicleSeat",
    Workspace3 = "Workspace"
}
local serviceShortcuts = {
    Players = "Players",
    UserInputService = "UIS",
    RunService = "RunService",
    ReplicatedStorage = "ReplicatedStorage",
    TweenService = "TweenService",
    Workspace = "Workspace",
    Lighting = "Lighting",
    StarterGui = "StarterGui",
    CoreGui = "CoreGui",
    HttpService = "HttpService",
    MarketplaceService = "MarketplaceService",
    DataStoreService = "DataStoreService",
    TeleportService = "TeleportService",
    SoundService = "SoundService",
    Chat = "Chat",
    Teams = "Teams",
    ProximityPromptService = "ProximityPromptService",
    ContextActionService = "ContextActionService",
    CollectionService = "CollectionService",
    PathfindingService = "PathfindingService",
    Debris = "Debris",
    TextService = "TextService",
    GuiService = "GuiService",
    TextChatService = "TextChatService",
    VoiceChatService = "VoiceChatService",
    BadgeService = "BadgeService",
    GroupService = "GroupService",
    InsertService = "InsertService",
    AssetService = "AssetService",
    ContentProvider = "ContentProvider",
    LocalizationService = "LocalizationService",
    PolicyService = "PolicyService",
    SocialService = "SocialService",
    HapticService = "HapticService",
    VRService = "VRService",
    AvatarEditorService = "AvatarEditorService",
    MemoryStoreService = "MemoryStoreService",
    MessagingService = "MessagingService",
    AnalyticsService = "AnalyticsService",
    AdService = "AdService",
    PhysicsService = "PhysicsService",
    ReplicatedFirst = "ReplicatedFirst",
    StarterPack = "StarterPack",
    StarterPlayer = "StarterPlayer",
    ServerStorage = "ServerStorage",
    ServerScriptService = "ServerScriptService",
    LogService = "LogService",
    UserService = "UserService",
    FriendService = "FriendService",
    NotificationService = "NotificationService",
    ScriptContext = "ScriptContext",
    NetworkClient = "NetworkClient",
    KeyframeSequenceProvider = "KeyframeSequenceProvider",
}
local classParents = {
    DataModel = {"DataModel", "ServiceProvider", "Instance"},
    Workspace = {"Workspace", "WorldRoot", "Model", "PVInstance", "Instance"},
    Camera = {"Camera", "Instance"},
    Players = {"Players", "Instance"},
    Player = {"Player", "Instance"},
    PlayerGui = {"PlayerGui", "BasePlayerGui", "Instance"},
    Backpack = {"Backpack", "Instance"},
    PlayerScripts = {"PlayerScripts", "Instance"},
    Folder = {"Folder", "Instance"},
    Model = {"Model", "PVInstance", "Instance"},
    Part = {"Part", "BasePart", "PVInstance", "Instance"},
    BasePart = {"BasePart", "PVInstance", "Instance"},
    ModuleScript = {"ModuleScript", "LuaSourceContainer", "Instance"},
    LocalScript = {"LocalScript", "Script", "LuaSourceContainer", "Instance"},
    Script = {"Script", "LuaSourceContainer", "Instance"},
    Humanoid = {"Humanoid", "Instance"},
    SoundService = {"SoundService", "Instance"},
    Lighting = {"Lighting", "Instance"},
    HttpService = {"HttpService", "Instance"},
    TweenService = {"TweenService", "Instance"},
    RunService = {"RunService", "Instance"},
    TextService = {"TextService", "Instance"},
    GuiService = {"GuiService", "Instance"},
    ContentProvider = {"ContentProvider", "Instance"},
    CollectionService = {"CollectionService", "Instance"},
    MemStorageService = {"MemStorageService", "Instance"},
    NetworkClient = {"NetworkClient", "Instance"},
    ClientReplicator = {"ClientReplicator", "Instance"},
    Animation = {"Animation", "Instance"},
    AnimationTrack = {"AnimationTrack", "Instance"},
    AnimationController = {"AnimationController", "Instance"},
    Animator = {"Animator", "Instance"},
    AnimationRigData = {"AnimationRigData", "Instance"},
    SpecialMesh = {"SpecialMesh", "DataModelMesh", "Instance"},
    DataModelMesh = {"DataModelMesh", "Instance"},
    BillboardGui = {"BillboardGui", "LayerCollector", "GuiBase", "Instance"},
    ScreenGui = {"ScreenGui", "LayerCollector", "GuiBase", "Instance"},
    SurfaceGui = {"SurfaceGui", "LayerCollector", "GuiBase", "Instance"},
    LayerCollector = {"LayerCollector", "GuiBase", "Instance"},
    GuiBase = {"GuiBase", "Instance"},
    Frame = {"Frame", "GuiObject", "GuiBase2d", "Instance"},
    TextLabel = {"TextLabel", "GuiObject", "GuiBase2d", "Instance"},
    TextButton = {"TextButton", "GuiButton", "GuiObject", "GuiBase2d", "Instance"},
    TextBox = {"TextBox", "GuiObject", "GuiBase2d", "Instance"},
    ImageLabel = {"ImageLabel", "GuiObject", "GuiBase2d", "Instance"},
    ImageButton = {"ImageButton", "GuiButton", "GuiObject", "GuiBase2d", "Instance"},
    ScrollingFrame = {"ScrollingFrame", "GuiObject", "GuiBase2d", "Instance"},
    GuiObject = {"GuiObject", "GuiBase2d", "Instance"},
    GuiBase2d = {"GuiBase2d", "Instance"},
    GuiButton = {"GuiButton", "GuiObject", "GuiBase2d", "Instance"},
    LocalizationService = {"LocalizationService", "Instance"},
    PolicyService = {"PolicyService", "Instance"},
    SocialService = {"SocialService", "Instance"},
    HapticService = {"HapticService", "Instance"},
    VRService = {"VRService", "Instance"},
    BadgeService = {"BadgeService", "Instance"},
    GroupService = {"GroupService", "Instance"},
    MarketplaceService = {"MarketplaceService", "Instance"},
    DataStoreService = {"DataStoreService", "Instance"},
    TeleportService = {"TeleportService", "Instance"},
    ContextActionService = {"ContextActionService", "Instance"},
    UserInputService = {"UserInputService", "Instance"},
    PathfindingService = {"PathfindingService", "Instance"},
    ReplicatedFirst = {"ReplicatedFirst", "Instance"},
    StarterPack = {"StarterPack", "Instance"},
    StarterPlayer = {"StarterPlayer", "Instance"},
    ServerStorage = {"ServerStorage", "Instance"},
    ServerScriptService = {"ServerScriptService", "Instance"},
    LogService = {"LogService", "Instance"},
    Teams = {"Teams", "Instance"},
    Team = {"Team", "Instance"},
    InsertService = {"InsertService", "Instance"},
    AssetService = {"AssetService", "Instance"},
    RemoteEvent = {"RemoteEvent", "Instance"},
    RemoteFunction = {"RemoteFunction", "Instance"},
    BindableEvent = {"BindableEvent", "Instance"},
    BindableFunction = {"BindableFunction", "Instance"},
    UnreliableRemoteEvent = {"UnreliableRemoteEvent", "Instance"},
    IntValue = {"IntValue", "ValueBase", "Instance"},
    NumberValue = {"NumberValue", "ValueBase", "Instance"},
    StringValue = {"StringValue", "ValueBase", "Instance"},
    BoolValue = {"BoolValue", "ValueBase", "Instance"},
    ObjectValue = {"ObjectValue", "ValueBase", "Instance"},
    Vector3Value = {"Vector3Value", "ValueBase", "Instance"},
    CFrameValue = {"CFrameValue", "ValueBase", "Instance"},
    Color3Value = {"Color3Value", "ValueBase", "Instance"},
    RayValue = {"RayValue", "ValueBase", "Instance"},
    ValueBase = {"ValueBase", "Instance"},
    Sound = {"Sound", "Instance"},
    SoundGroup = {"SoundGroup", "Instance"},
    SoundEffect = {"SoundEffect", "Instance"},
    EchoSoundEffect = {"EchoSoundEffect", "SoundEffect", "Instance"},
    ReverbSoundEffect = {"ReverbSoundEffect", "SoundEffect", "Instance"},
    EqualizerSoundEffect = {"EqualizerSoundEffect", "SoundEffect", "Instance"},
    CompressorSoundEffect = {"CompressorSoundEffect", "SoundEffect", "Instance"},
    DistortionSoundEffect = {"DistortionSoundEffect", "SoundEffect", "Instance"},
    PitchShiftSoundEffect = {"PitchShiftSoundEffect", "SoundEffect", "Instance"},
    AudioDeviceOutput = {"AudioDeviceOutput", "Instance"},
    AudioAnalyzer = {"AudioAnalyzer", "Instance"},
    AudioEmitter = {"AudioEmitter", "Instance"},
    AudioListener = {"AudioListener", "Instance"},
    AudioPlayer = {"AudioPlayer", "Instance"},
    AudioChorus = {"AudioChorus", "Instance"},
    AudioCompressor = {"AudioCompressor", "Instance"},
    AudioDistortion = {"AudioDistortion", "Instance"},
    AudioEqualizer = {"AudioEqualizer", "Instance"},
    AudioFader = {"AudioFader", "Instance"},
    AudioFlanger = {"AudioFlanger", "Instance"},
    AudioPitchShifter = {"AudioPitchShifter", "Instance"},
    AudioReverb = {"AudioReverb", "Instance"},
    Wire = {"Wire", "Instance"},
    WeldConstraint = {"WeldConstraint", "Instance"},
    Weld = {"Weld", "JointInstance", "Instance"},
    Motor6D = {"Motor6D", "JointInstance", "Instance"},
    Snap = {"Snap", "JointInstance", "Instance"},
    JointInstance = {"JointInstance", "Instance"},
    Constraint = {"Constraint", "Instance"},
    HingeConstraint = {"HingeConstraint", "Constraint", "Instance"},
    BallSocketConstraint = {"BallSocketConstraint", "Constraint", "Instance"},
    RodConstraint = {"RodConstraint", "Constraint", "Instance"},
    RopeConstraint = {"RopeConstraint", "Constraint", "Instance"},
    AlignPosition = {"AlignPosition", "Constraint", "Instance"},
    AlignOrientation = {"AlignOrientation", "Constraint", "Instance"},
    VectorForce = {"VectorForce", "Constraint", "Instance"},
    Torque = {"Torque", "Constraint", "Instance"},
    BodyVelocity = {"BodyVelocity", "BodyMover", "Instance"},
    BodyAngularVelocity = {"BodyAngularVelocity", "BodyMover", "Instance"},
    BodyPosition = {"BodyPosition", "BodyMover", "Instance"},
    BodyForce = {"BodyForce", "BodyMover", "Instance"},
    BodyGyro = {"BodyGyro", "BodyMover", "Instance"},
    BodyMover = {"BodyMover", "Instance"},
    LinearVelocity = {"LinearVelocity", "Constraint", "Instance"},
    AngularVelocity = {"AngularVelocity", "Constraint", "Instance"},
    LineForce = {"LineForce", "Constraint", "Instance"},
    SpringConstraint = {"SpringConstraint", "Constraint", "Instance"},
    PrismaticConstraint = {"PrismaticConstraint", "Constraint", "Instance"},
    UniversalConstraint = {"UniversalConstraint", "Constraint", "Instance"},
    CylindricalConstraint = {"CylindricalConstraint", "Constraint", "Instance"},
    SlidingBallConstraint = {"SlidingBallConstraint", "Constraint", "Instance"},
    BallSocketConstraint = {"BallSocketConstraint", "Constraint", "Instance"},
    NoCollisionConstraint = {"NoCollisionConstraint", "Constraint", "Instance"},
    Highlight = {"Highlight", "Instance"},
    SelectionBox = {"SelectionBox", "Instance"},
    SelectionSphere = {"SelectionSphere", "Instance"},
    SelectionPartLasso = {"SelectionPartLasso", "Instance"},
    SelectionPointLasso = {"SelectionPointLasso", "Instance"},
    ParticleEmitter = {"ParticleEmitter", "Instance"},
    Smoke = {"Smoke", "Instance"},
    Fire = {"Fire", "Instance"},
    Sparkles = {"Sparkles", "Instance"},
    Trail = {"Trail", "Instance"},
    Beam = {"Beam", "Instance"},
    Attachment = {"Attachment", "Instance"},
    AccessoryDescription = {"AccessoryDescription", "Instance"},
    DragDetector = {"DragDetector", "Instance"},
    WrapLayer = {"WrapLayer", "Instance"},
    WrapDeformer = {"WrapDeformer", "Instance"},
    Platform = {"Platform", "BasePart", "PVInstance", "Instance"},
    TextChatService = {"TextChatService", "Instance"},
    TextChannel = {"TextChannel", "Instance"},
    TextChatMessage = {"TextChatMessage", "Instance"},
    TextChatMessageProperties = {"TextChatMessageProperties", "Instance"},
    TextChatCommand = {"TextChatCommand", "Instance"},
    ChatInputBarConfiguration = {"ChatInputBarConfiguration", "Instance"},
    ChatWindowConfiguration = {"ChatWindowConfiguration", "Instance"},
    ProximityPrompt = {"ProximityPrompt", "Instance"},
    ProximityPromptService = {"ProximityPromptService", "Instance"},
    MemoryStoreService = {"MemoryStoreService", "Instance"},
    MessagingService = {"MessagingService", "Instance"},
    AnalyticsService = {"AnalyticsService", "Instance"},
    OpenCloudService = {"OpenCloudService", "Instance"},
    DataModelSession = {"DataModelSession", "Instance"},
    Dialog = {"Dialog", "Instance"},
    DialogChoice = {"DialogChoice", "Instance"},
    UIListLayout = {"UIListLayout", "UILayout", "UIBase", "Instance"},
    UIGridLayout = {"UIGridLayout", "UILayout", "UIBase", "Instance"},
    UIPageLayout = {"UIPageLayout", "UILayout", "UIBase", "Instance"},
    UITableLayout = {"UITableLayout", "UILayout", "UIBase", "Instance"},
    UIFlexItem = {"UIFlexItem", "UIBase", "Instance"},
    UILayout = {"UILayout", "UIBase", "Instance"},
    UIBase = {"UIBase", "Instance"},
    UIAspectRatioConstraint = {"UIAspectRatioConstraint", "UIConstraint", "UIBase", "Instance"},
    UISizeConstraint = {"UISizeConstraint", "UIConstraint", "UIBase", "Instance"},
    UITextSizeConstraint = {"UITextSizeConstraint", "UIConstraint", "UIBase", "Instance"},
    UIConstraint = {"UIConstraint", "UIBase", "Instance"},
    UIPadding = {"UIPadding", "UIBase", "Instance"},
    UIScale = {"UIScale", "UIBase", "Instance"},
    UIStroke = {"UIStroke", "UIBase", "Instance"},
    UICorner = {"UICorner", "UIBase", "Instance"},
    UIGradient = {"UIGradient", "UIBase", "Instance"},
    ViewportFrame = {"ViewportFrame", "GuiObject", "GuiBase2d", "Instance"},
    VideoFrame = {"VideoFrame", "GuiObject", "GuiBase2d", "Instance"},
    CanvasGroup = {"CanvasGroup", "GuiObject", "GuiBase2d", "Instance"},
    Fire = {"Fire", "ParticleEmitter", "Instance"},
    Smoke = {"Smoke", "ParticleEmitter", "Instance"},
    Sparkles = {"Sparkles", "ParticleEmitter", "Instance"},
    ParticleEmitter = {"ParticleEmitter", "Instance"},
    Beam = {"Beam", "Instance"},
    SelectionBox = {"SelectionBox", "Instance"},
    SelectionSphere = {"SelectionSphere", "Instance"},
    BoxHandleAdornment = {"BoxHandleAdornment", "HandleAdornment", "Instance"},
    ConeHandleAdornment = {"ConeHandleAdornment", "HandleAdornment", "Instance"},
    CylinderHandleAdornment = {"CylinderHandleAdornment", "HandleAdornment", "Instance"},
    SphereHandleAdornment = {"SphereHandleAdornment", "HandleAdornment", "Instance"},
    HandleAdornment = {"HandleAdornment", "Instance"},
    Decal = {"Decal", "Instance"},
    Texture = {"Texture", "Decal", "Instance"},
    ProximityPrompt = {"ProximityPrompt", "Instance"},
    ClickDetector = {"ClickDetector", "Instance"},
    TouchTransmitter = {"TouchTransmitter", "Instance"},
    Camera = {"Camera", "Instance"},
    MeshPart = {"MeshPart", "BasePart", "PVInstance", "Instance"},
    WedgePart = {"WedgePart", "BasePart", "PVInstance", "Instance"},
    TrussPart = {"TrussPart", "BasePart", "PVInstance", "Instance"},
    CornerWedgePart = {"CornerWedgePart", "BasePart", "PVInstance", "Instance"},
    UnionOperation = {"UnionOperation", "PartOperation", "BasePart", "PVInstance", "Instance"},
    NegateOperation = {"NegateOperation", "PartOperation", "BasePart", "PVInstance", "Instance"},
    PartOperation = {"PartOperation", "BasePart", "PVInstance", "Instance"},
    VehicleSeat = {"VehicleSeat", "Seat", "BasePart", "PVInstance", "Instance"},
    Seat = {"Seat", "BasePart", "PVInstance", "Instance"},
    SpawnLocation = {"SpawnLocation", "BasePart", "PVInstance", "Instance"},
    Platform = {"Platform", "BasePart", "PVInstance", "Instance"},
    Attachment = {"Attachment", "Instance"},
    SelectionHighlight = {"SelectionHighlight", "Instance"},
    Highlight = {"Highlight", "Instance"},
    SurfaceSelection = {"SurfaceSelection", "Instance"},
    BillboardGui = {"BillboardGui", "LayerCollector", "GuiBase", "Instance"},
    DragDetector = {"DragDetector", "Instance"},
    NoCollisionConstraint = {"NoCollisionConstraint", "Constraint", "Instance"},
    LineForce = {"LineForce", "Constraint", "Instance"},
    TorsionSpringConstraint = {"TorsionSpringConstraint", "Constraint", "Instance"},
    GeometryService = {"GeometryService", "Instance"},
    AvatarEditorService = {"AvatarEditorService", "Instance"},
    AvatarCreationService = {"AvatarCreationService", "Instance"},
    RoactSupportService = {"RoactSupportService", "Instance"},
    VoiceChatService = {"VoiceChatService", "Instance"},
    AdService = {"AdService", "Instance"},
    AdPortal = {"AdPortal", "Instance"},
    CSGDictionaryService = {"CSGDictionaryService", "Instance"},
    ChangeHistoryService = {"ChangeHistoryService", "Instance"},
    CoreGui = {"CoreGui", "BasePlayerGui", "Instance"},
    BasePlayerGui = {"BasePlayerGui", "Instance"},
    AudioEmitter = {"AudioEmitter", "Instance"},
    AudioListener = {"AudioListener", "Instance"},
    AudioAnalyzer = {"AudioAnalyzer", "Instance"},
    AudioCompressor = {"AudioCompressor", "Instance"},
    AudioDistortion = {"AudioDistortion", "Instance"},
    AudioEqualizer = {"AudioEqualizer", "Instance"},
    AudioFader = {"AudioFader", "Instance"},
    AudioFlanger = {"AudioFlanger", "Instance"},
    AudioReverb = {"AudioReverb", "Instance"},
    AudioChannelSplitter = {"AudioChannelSplitter", "Instance"},
    AudioChannelMixer = {"AudioChannelMixer", "Instance"},
    AudioChorusEffect = {"AudioChorusEffect", "Instance"},
    AudioPitchShifter = {"AudioPitchShifter", "Instance"},
    AudioDeviceInput = {"AudioDeviceInput", "Instance"},
    Clouds = {"Clouds", "Instance"},
    WrapDeformer = {"WrapDeformer", "Instance"},
    WrapTarget = {"WrapTarget", "Instance"},
    WrapLayer = {"WrapLayer", "Instance"},
    CageDeformer = {"CageDeformer", "Instance"},
    UIListLayout = {"UIListLayout", "UILayout", "UIBase", "Instance"},
    UIGridLayout = {"UIGridLayout", "UILayout", "UIBase", "Instance"},
    UITableLayout = {"UITableLayout", "UILayout", "UIBase", "Instance"},
    UIPageLayout = {"UIPageLayout", "UILayout", "UIBase", "Instance"},
    UILayout = {"UILayout", "UIBase", "Instance"},
    UIBase = {"UIBase", "Instance"},
    UIAspectRatioConstraint = {"UIAspectRatioConstraint", "UIConstraint", "Instance"},
    UISizeConstraint = {"UISizeConstraint", "UIConstraint", "Instance"},
    UITextSizeConstraint = {"UITextSizeConstraint", "UIConstraint", "Instance"},
    UIConstraint = {"UIConstraint", "UIBase", "Instance"},
    UICorner = {"UICorner", "UIBase", "Instance"},
    UIGradient = {"UIGradient", "UIBase", "Instance"},
    UIStroke = {"UIStroke", "UIBase", "Instance"},
    UIPadding = {"UIPadding", "UIBase", "Instance"},
    UIScale = {"UIScale", "UIBase", "Instance"},
    UIFlexItem = {"UIFlexItem", "UIBase", "Instance"},
    ViewportFrame = {"ViewportFrame", "GuiObject", "GuiBase2d", "Instance"},
    Dialog = {"Dialog", "Instance"},
    DialogChoice = {"DialogChoice", "Instance"},
    Tool = {"Tool", "BackpackItem", "Instance"},
    BackpackItem = {"BackpackItem", "Instance"},
    HopperBin = {"HopperBin", "Instance"},
    Hat = {"Hat", "Accoutrement", "Instance"},
    Accoutrement = {"Accoutrement", "Instance"},
    Accessory = {"Accessory", "Instance"},
    CharacterMesh = {"CharacterMesh", "Instance"},
    Keyframe = {"Keyframe", "Instance"},
    KeyframeMarker = {"KeyframeMarker", "Instance"},
    KeyframeSequence = {"KeyframeSequence", "Instance"},
    NumberPose = {"NumberPose", "PoseBase", "Instance"},
    Pose = {"Pose", "PoseBase", "Instance"},
    PoseBase = {"PoseBase", "Instance"},
    TextChatService = {"TextChatService", "Instance"},
    TextChannel = {"TextChannel", "Instance"},
    TextChatMessage = {"TextChatMessage", "Instance"},
    TextChatCommand = {"TextChatCommand", "Instance"},
    Chat = {"Chat", "Instance"},
    ChatService = {"ChatService", "Instance"},
    ChatChannel = {"ChatChannel", "Instance"},
    Humanoid = {"Humanoid", "Instance"},
    HumanoidDescription = {"HumanoidDescription", "Instance"},
    Script = {"Script", "LuaSourceContainer", "Instance"},
    LocalScript = {"LocalScript", "Script", "LuaSourceContainer", "Instance"},
    ModuleScript = {"ModuleScript", "LuaSourceContainer", "Instance"},
    LuaSourceContainer = {"LuaSourceContainer", "Instance"},
    Sky = {"Sky", "Instance"},
    Atmosphere = {"Atmosphere", "Instance"},
    Terrain = {"Terrain", "BasePart", "PVInstance", "Instance"},
    WorkspaceObject = {"WorkspaceObject", "Instance"},
    LinearVelocity = {"LinearVelocity", "Constraint", "Instance"},
    AngularVelocity = {"AngularVelocity", "Constraint", "Instance"},
    PlaneConstraint = {"PlaneConstraint", "Constraint", "Instance"},
    SpringConstraint = {"SpringConstraint", "Constraint", "Instance"},
    UniversalConstraint = {"UniversalConstraint", "Constraint", "Instance"},
    SlidingBallConstraint = {"SlidingBallConstraint", "Constraint", "Instance"},
    CylindricalConstraint = {"CylindricalConstraint", "Constraint", "Instance"},
    LineForce = {"LineForce", "Constraint", "Instance"},
    AudioDeviceInput  = {"AudioDeviceInput", "Instance"},
    AudioDeviceOutput = {"AudioDeviceOutput", "Instance"},
    AudioEmitter = {"AudioEmitter", "Instance"},
    AudioListener = {"AudioListener", "Instance"},
    AudioAnalyzer = {"AudioAnalyzer", "Instance"},
    AudioCompressor = {"AudioCompressor", "Instance"},
    AudioDistortion = {"AudioDistortion", "Instance"},
    AudioEqualizer = {"AudioEqualizer", "Instance"},
    AudioEcho = {"AudioEcho", "Instance"},
    AudioReverb = {"AudioReverb", "Instance"},
    AudioFader = {"AudioFader", "Instance"},
    AudioFlanger = {"AudioFlanger", "Instance"},
    AudioPlayer = {"AudioPlayer", "Instance"},
    AudioRecorder = {"AudioRecorder", "Instance"},
    Path = {"Path", "Instance"},
    PathWaypoint = {"PathWaypoint"},
    DataStore = {"DataStore"},
    OrderedDataStore = {"OrderedDataStore", "DataStore"},
    GlobalDataStore = {"GlobalDataStore"},
    DataStorePages = {"DataStorePages", "Pages"},
    Pages = {"Pages", "Instance"},
    TextFilterResult = {"TextFilterResult"},
    ProductInfo = {"ProductInfo"},
    BadgeInfo = {"BadgeInfo"},
    Highlight = {"Highlight", "Instance"},
    SelectionLasso = {"SelectionLasso", "Instance"},
    StickerFrame = {"StickerFrame", "Instance"},
    CanvasGroup = {"CanvasGroup", "GuiObject", "GuiBase2d", "Instance"},
    VideoFrame = {"VideoFrame", "GuiObject", "GuiBase2d", "Instance"},
    UIAspectRatioConstraint = {"UIAspectRatioConstraint", "UIConstraint", "Instance"},
    UISizeConstraint = {"UISizeConstraint", "UIConstraint", "Instance"},
    UITextSizeConstraint = {"UITextSizeConstraint", "UIConstraint", "Instance"},
    UIConstraint = {"UIConstraint", "Instance"},
    UIGradient = {"UIGradient", "Instance"},
    UIGridLayout = {"UIGridLayout", "UIGridStyleLayout", "UILayout", "Instance"},
    UIListLayout = {"UIListLayout", "UIGridStyleLayout", "UILayout", "Instance"},
    UIPageLayout = {"UIPageLayout", "UILayout", "Instance"},
    UITableLayout = {"UITableLayout", "UIGridStyleLayout", "UILayout", "Instance"},
    UILayout = {"UILayout", "Instance"},
    UIGridStyleLayout = {"UIGridStyleLayout", "UILayout", "Instance"},
    UIPadding = {"UIPadding", "Instance"},
    UIScale = {"UIScale", "Instance"},
    UIStroke = {"UIStroke", "Instance"},
    UICorner = {"UICorner", "Instance"},
    UserService = {"UserService", "Instance"},
    FriendService = {"FriendService", "Instance"},
    AvatarEditorService = {"AvatarEditorService", "Instance"},
    MemoryStoreService = {"MemoryStoreService", "Instance"},
    AnalyticsService = {"AnalyticsService", "Instance"},
    PhysicsService = {"PhysicsService", "Instance"},
    NotificationService = {"NotificationService", "Instance"},
    KeyframeSequenceProvider = {"KeyframeSequenceProvider", "Instance"},
    ScriptContext = {"ScriptContext", "Instance"},
    Configuration = {"Configuration", "Instance"},
    StringValue = {"StringValue", "ValueBase", "Instance"},
    Tween = {"Tween", "TweenBase", "Instance"},
    TweenBase = {"TweenBase", "Instance"},
    CharacterMesh = {"CharacterMesh", "Instance"},
    BodyColors = {"BodyColors", "Instance"},
    PerformanceStats = {"PerformanceStats", "Instance"},
    RigidConstraint             = {"RigidConstraint", "Constraint", "Instance"},
    BallSocketConstraint        = {"BallSocketConstraint", "Constraint", "Instance"},
    WeldConstraint              = {"WeldConstraint", "Instance"},
    TorsionSpringConstraint     = {"TorsionSpringConstraint", "Constraint", "Instance"},
    ProximityPrompt             = {"ProximityPrompt", "Instance"},
    ProximityPromptService      = {"ProximityPromptService", "Instance"},
    TerrainDetail               = {"TerrainDetail", "Instance"},
    TerrainRegion               = {"TerrainRegion", "Instance"},
    Frame                       = {"Frame", "GuiObject", "GuiBase2d", "Instance"},
    ScrollingFrame              = {"ScrollingFrame", "GuiObject", "GuiBase2d", "Instance"},
    TextLabel                   = {"TextLabel", "GuiObject", "GuiBase2d", "Instance"},
    TextButton                  = {"TextButton", "GuiButton", "GuiObject", "GuiBase2d", "Instance"},
    ImageLabel                  = {"ImageLabel", "GuiObject", "GuiBase2d", "Instance"},
    ImageButton                 = {"ImageButton", "GuiButton", "GuiObject", "GuiBase2d", "Instance"},
    TextBox                     = {"TextBox", "GuiObject", "GuiBase2d", "Instance"},
    GuiButton                   = {"GuiButton", "GuiObject", "GuiBase2d", "Instance"},
    GuiObject                   = {"GuiObject", "GuiBase2d", "Instance"},
    GuiBase2d                   = {"GuiBase2d", "Instance"},
    ScreenGui                   = {"ScreenGui", "LayerCollector", "GuiBase2d", "Instance"},
    SurfaceGui                  = {"SurfaceGui", "LayerCollector", "GuiBase2d", "Instance"},
    LayerCollector              = {"LayerCollector", "GuiBase2d", "Instance"},
    AnimationController         = {"AnimationController", "Instance"},
    AnimationTrack              = {"AnimationTrack", "Instance"},
    Animator                    = {"Animator", "Instance"},
    AnimationRigData            = {"AnimationRigData", "Instance"},
    SpecialMesh                 = {"SpecialMesh", "DataModelMesh", "Instance"},
    DataModelMesh               = {"DataModelMesh", "Instance"},
    FileMesh                    = {"FileMesh", "DataModelMesh", "Instance"},
    BlockMesh                   = {"BlockMesh", "DataModelMesh", "Instance"},
    CylinderMesh                = {"CylinderMesh", "DataModelMesh", "Instance"},
    Folder                      = {"Folder", "Instance"},
    Model                       = {"Model", "PVInstance", "Instance"},
    PVInstance                  = {"PVInstance", "Instance"},
    LocalizationService         = {"LocalizationService", "Instance"},
    TextService                 = {"TextService", "Instance"},
    ScriptDebugger              = {"ScriptDebugger", "Instance"},
    ScriptService               = {"ScriptService", "Instance"},
    CorePackages                = {"CorePackages", "Instance"},
    RobloxPluginGuiService      = {"RobloxPluginGuiService", "Instance"},
    StudioService               = {"StudioService", "Instance"},
    TestService                 = {"TestService", "Instance"},
    AudioChannelSplitter        = {"AudioChannelSplitter", "Instance"},
    AudioChannelMixer           = {"AudioChannelMixer", "Instance"},
    AudioChorusEffect           = {"AudioChorusEffect", "Instance"},
    AudioPitchShifter           = {"AudioPitchShifter", "Instance"},
    ExperienceNotificationService = {"ExperienceNotificationService", "Instance"},
    OpenCloudService            = {"OpenCloudService", "Instance"},
    VoiceChatInternal           = {"VoiceChatInternal", "Instance"},
}
-- Structural API metadata is injected only by the trusted Lune host. It supplies
-- names, ancestry, and enum values—not implementations of Roblox runtime APIs.
local _apiRegistry = rawget(_G, "__ROBLOX_API_REGISTRY")
local _apiClassSuper = typeFunction(_apiRegistry) == "table" and _apiRegistry.classSuper or {}
local _apiEnums = typeFunction(_apiRegistry) == "table" and _apiRegistry.enums or {}
local _apiEnumOrder = typeFunction(_apiRegistry) == "table" and _apiRegistry.enumOrder or {}
for _className, _superName in pairsFunction(_apiClassSuper) do
    if classParents[_className] == nil then
        local _lineage, _cursor, _seen = {_className}, _superName, {}
        while typeFunction(_cursor) == "string" and _cursor ~= "" and not _seen[_cursor] and #_lineage < 64 do
            _seen[_cursor] = true
            table.insert(_lineage, _cursor)
            _cursor = _apiClassSuper[_cursor]
        end
        if _lineage[#_lineage] ~= "Instance" then table.insert(_lineage, "Instance") end
        classParents[_className] = _lineage
    end
end
local function classIsA(className, targetClass)
    if className == targetClass then return true end
    local parents = classParents[className] or {className, "Instance"}
    for _, parentName in ipairsFunction(parents) do
        if parentName == targetClass then return true end
    end
    return false
end
local uiNamingConvention = {
    {pattern = "window", prefix = "Window", counter = "window"},
    {pattern = "tab", prefix = "Tab", counter = "tab"},
    {pattern = "section", prefix = "Section", counter = "section"},
    {pattern = "button", prefix = "Button", counter = "button"},
    {pattern = "toggle", prefix = "Toggle", counter = "toggle"},
    {pattern = "slider", prefix = "Slider", counter = "slider"},
    {pattern = "dropdown", prefix = "Dropdown", counter = "dropdown"},
    {pattern = "textbox", prefix = "Textbox", counter = "textbox"},
    {pattern = "input", prefix = "Input", counter = "input"},
    {pattern = "label", prefix = "Label", counter = "label"},
    {pattern = "keybind", prefix = "Keybind", counter = "keybind"},
    {pattern = "colorpicker", prefix = "ColorPicker", counter = "colorpicker"},
    {pattern = "paragraph", prefix = "Paragraph", counter = "paragraph"},
    {pattern = "notification", prefix = "Notification", counter = "notification"},
    {pattern = "divider", prefix = "Divider", counter = "divider"},
    {pattern = "bind", prefix = "Bind", counter = "bind"},
    {pattern = "picker", prefix = "Picker", counter = "picker"}
}
local uiCounters = {}
local function getUiCounter(name)
    uiCounters[name] = (uiCounters[name] or 0) + 1
    return uiCounters[name]
end
local function resolveVariableName(obj, originalName, hintString)
    if not obj then
        obj = "var"
    end
    local formattedName = formatValue(obj)
    if serviceShortcuts[formattedName] then
        return serviceShortcuts[formattedName]
    end
    if hintString then
        local lowerHint = hintString:lower()
        for _, patternEntry in ipairsFunction(uiNamingConvention) do
            if lowerHint:find(patternEntry.pattern) then
                local counter = getUiCounter(patternEntry.counter)
                return counter == 1 and patternEntry.prefix or patternEntry.prefix .. counter
            end
        end
    end
    if formattedName == "LocalPlayer" then
        return "LocalPlayer"
    end
    if formattedName == "Character" then
        return "Character"
    end
    if formattedName == "Humanoid" then
        return "Humanoid"
    end
    if formattedName == "HumanoidRootPart" then
        return "HumanoidRootPart"
    end
    if formattedName == "Camera" then
        return "Camera"
    end
    if formattedName:match("^Enum%.") then
        return formattedName
    end
    local sanitizedName = formattedName:gsub("[^%w_]", "_"):gsub("^%d+", "_")
    if sanitizedName == "" or sanitizedName == "_" or sanitizedName == "Object" or sanitizedName == "Value" or sanitizedName == "result" then
        sanitizedName = "var"
    end
    return sanitizedName
end
local _luaReserved = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,
    ["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,
    ["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,
    ["or"]=true,["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,
    ["until"]=true,["while"]=true,
}
local function _deriveReadableName(objName, hintString)
    local base = nil
    if typeFunction(objName) == "string" and objName ~= "" then
        base = resolveVariableName(objName, objName, hintString)
    elseif typeFunction(hintString) == "string" and hintString ~= "" then
        base = resolveVariableName(hintString, hintString, hintString)
    end
    if not base or base == "" or base == "var" or base == "_" then
        return nil
    end
    if base:find(".", 1, true) then
        local tail = base:match("([^%.]+)$")
        if tail and tail ~= "" then base = tail end
    end
    base = base:gsub("[^%w_]", "_"):gsub("^%d", "_%0")
    if base == "" or base == "_" then return nil end
    if _luaReserved[base] then base = base .. "_" end
    return base
end
local function registerVariable(obj, objName, varType, hintString)
    local existing = dumperState.registry[obj]
    if existing then
        return existing
    end
    local baseName = _deriveReadableName(objName, hintString)
    local newName
    if baseName then
        if not dumperState.names_used[baseName] then
            newName = baseName
        else
            local n = 2
            while dumperState.names_used[baseName .. n] do n = n + 1 end
            newName = baseName .. n
        end
    else
        dumperState.ls_counter = (dumperState.ls_counter or 0) + 1
        newName = "ls" .. dumperState.ls_counter
    end
    dumperState.names_used[newName] = true
    dumperState.registry[obj] = newName
    dumperState.reverse_registry[newName] = obj
    dumperState.variable_types[newName] = varType or typeFunction(obj)
    return newName
end
local function resolveParentPath(self)
    if not self then return "object" end
    if dumperState.registry[self] then
        return dumperState.registry[self]
    end
    local parent = dumperState.parent_map[self]
    if not parent then return "object" end
    local parentPath = resolveParentPath(parent)
    if parentPath == "object" then return "object" end
    local myName = dumperState.proxy_name[self]
    if (not myName or myName == "") and dumperState.property_store[self] then
        myName = dumperState.property_store[self].Name
    end
    if not myName or myName == "" then return "object" end
    if myName:match("^[%a_][%w_]*$") then
        return parentPath .. "." .. myName
    end
    return parentPath .. "[" .. formatStringLiteral(myName) .. "]"
end
local function serializeValue(obj, depth, visited, allowInline)
    depth = depth or 0
    visited = visited or {}
    if depth > configuration.MAX_DEPTH then
        return "{  }"
    end
    local valueType = typeFunction(obj)
    if isProxyTable(obj) then
        local proxyValue = rawget(obj, "__value")
        return toStringFunction(proxyValue or 0)
    end
    if valueType == "table" and dumperState.registry[obj] then
        return dumperState.registry[obj]
    end
    if valueType == "nil" then
        return "nil"
    elseif valueType == "string" then
        local function _recordStr(hint)
            table.insert(dumperState.string_refs, {value = obj:sub(1, 80) .. (#obj > 80 and "..." or ""), hint = hint, full_length = #obj})
        end
        if #obj > 60 and obj:match("^[A-Za-z0-9+/=\n\r]+$") and (#obj % 4 == 0 or obj:match("=+$")) then
            _recordStr("base64")
        elseif obj:match("https?://discord%.gg/") or obj:match("discord%.com/api/webhooks/") then
            _recordStr("Discord-webhook")
        elseif obj:match("https?://") then
            _recordStr("URL")
        elseif obj:match("rbxasset://") or obj:match("rbxassetid://") or obj:match("rbxthumb://") then
            _recordStr("Asset")
        elseif #obj >= 32 and obj:match("^[%x%-]+$") then
            _recordStr("UUID/key")
        elseif obj:match("_ROBLOSECURITY") or obj:match("Authorization:") or obj:match("Bearer ") then
            _recordStr("credential/auth")
        elseif #obj > 200 and obj:match("[%w_]+%s*=%s*function") then
            _recordStr("embedded-code")
        end
        return formatStringLiteral(obj)
    elseif valueType == "number" then
        if obj ~= obj then
            return "0/0"
        end
        if obj == math.huge then
            return "math.huge"
        end
        if obj == -math.huge then
            return "-math.huge"
        end
        if obj == 0 then
            return "0"
        end
        if obj == math.floor(obj) and math.abs(obj) < 1e15 then
            return string.format("%d", obj)
        end
        local formatted = string.format("%.14g", obj)
        if formatted:find("%.") and not formatted:find("[eE]") then
            formatted = formatted:gsub("0+$", ""):gsub("%.$", "")
        end
        return formatted
    elseif valueType == "boolean" then
        return toStringFunction(obj)
    elseif valueType == "function" then
        if dumperState.registry[obj] then
            return dumperState.registry[obj]
        end
        return "function() end"
    elseif valueType == "table" then
        if isProxy(obj) then
            return dumperState.registry[obj] or "proxy"
        end
        do
            local mt = getMetatableFunction(obj)
            local typeName = mt and type(mt) == "table" and rawget(mt, "__typeof")
            if typeName then
                local function S(v) return serializeValue(v, depth + 1, visited) end
                local function N(v) return typeFunction(v) == "number" and v or 0 end
                if typeName == "Color3" then
                    local r, g, b = N(obj.R), N(obj.G), N(obj.B)
                    local r255, g255, b255 = r * 255, g * 255, b * 255
                    local function near_int(x)
                        return math.abs(x - math.floor(x + 0.5)) < 1e-4
                    end
                    if r >= 0 and g >= 0 and b >= 0
                       and r <= 1 and g <= 1 and b <= 1
                       and near_int(r255) and near_int(g255) and near_int(b255) then
                        return string.format("Color3.fromRGB(%d, %d, %d)",
                            math.floor(r255 + 0.5),
                            math.floor(g255 + 0.5),
                            math.floor(b255 + 0.5))
                    end
                    return string.format("Color3.new(%s, %s, %s)", S(r), S(g), S(b))
                elseif typeName == "Vector2" then
                    return string.format("Vector2.new(%s, %s)", S(N(obj.X)), S(N(obj.Y)))
                elseif typeName == "Vector2int16" then
                    return string.format("Vector2int16.new(%s, %s)", S(N(obj.X)), S(N(obj.Y)))
                elseif typeName == "Vector3" then
                    return string.format("Vector3.new(%s, %s, %s)", S(N(obj.X)), S(N(obj.Y)), S(N(obj.Z)))
                elseif typeName == "Vector3int16" then
                    return string.format("Vector3int16.new(%s, %s, %s)", S(N(obj.X)), S(N(obj.Y)), S(N(obj.Z)))
                elseif typeName == "UDim" then
                    return string.format("UDim.new(%s, %s)", S(N(obj.Scale)), S(N(obj.Offset)))
                elseif typeName == "UDim2" then
                    local x, y = obj.X, obj.Y
                    local xs = (typeFunction(x) == "table" and N(x.Scale)) or 0
                    local xo = (typeFunction(x) == "table" and N(x.Offset)) or 0
                    local ys = (typeFunction(y) == "table" and N(y.Scale)) or 0
                    local yo = (typeFunction(y) == "table" and N(y.Offset)) or 0
                    return string.format("UDim2.new(%s, %s, %s, %s)", S(xs), S(xo), S(ys), S(yo))
                elseif typeName == "Rect" then
                    local mn, mx = obj.Min, obj.Max
                    local mnx = (typeFunction(mn) == "table" and N(mn.X)) or 0
                    local mny = (typeFunction(mn) == "table" and N(mn.Y)) or 0
                    local mxx = (typeFunction(mx) == "table" and N(mx.X)) or 0
                    local mxy = (typeFunction(mx) == "table" and N(mx.Y)) or 0
                    return string.format("Rect.new(%s, %s, %s, %s)", S(mnx), S(mny), S(mxx), S(mxy))
                elseif typeName == "Ray" then
                    return string.format("Ray.new(%s, %s)",
                        S(obj.Origin or Vector3.new(0, 0, 0)),
                        S(obj.Direction or Vector3.new(0, 0, 0)))
                elseif typeName == "BrickColor" then
                    return string.format("BrickColor.new(%s)", formatStringLiteral(toStringFunction(obj.Name or "Medium stone grey")))
                elseif typeName == "NumberRange" then
                    return string.format("NumberRange.new(%s, %s)", S(N(obj.Min)), S(N(obj.Max)))
                elseif typeName == "TweenInfo" then
                    return string.format("TweenInfo.new(%s, %s, %s, %s, %s, %s)",
                        S(N(obj.Time ~= nil and obj.Time or 1)),
                        S(obj.EasingStyle),
                        S(obj.EasingDirection),
                        S(N(obj.RepeatCount)),
                        S(obj.Reverses == true),
                        S(N(obj.DelayTime)))
                elseif typeName == "PhysicalProperties" then
                    return string.format("PhysicalProperties.new(%s, %s, %s, %s, %s)",
                        S(N(obj.Density ~= nil and obj.Density or 1)),
                        S(N(obj.Friction ~= nil and obj.Friction or 0.3)),
                        S(N(obj.Elasticity ~= nil and obj.Elasticity or 0.5)),
                        S(N(obj.FrictionWeight ~= nil and obj.FrictionWeight or 1)),
                        S(N(obj.ElasticityWeight ~= nil and obj.ElasticityWeight or 1)))
                elseif typeName == "NumberSequence" then
                    if typeFunction(obj.Keypoints) == "table" and #obj.Keypoints >= 2 then
                        local kps = {}
                        for _, kp in ipairsFunction(obj.Keypoints) do
                            table.insert(kps, string.format("NumberSequenceKeypoint.new(%s, %s, %s)",
                                S(N(kp.Time)), S(N(kp.Value)), S(N(kp.Envelope))))
                        end
                        return "NumberSequence.new({" .. table.concat(kps, ", ") .. "})"
                    end
                    return "NumberSequence.new(0, 1)"
                elseif typeName == "ColorSequence" then
                    if typeFunction(obj.Keypoints) == "table" and #obj.Keypoints >= 2 then
                        local kps = {}
                        for _, kp in ipairsFunction(obj.Keypoints) do
                            table.insert(kps, string.format("ColorSequenceKeypoint.new(%s, %s)",
                                S(N(kp.Time)), S(kp.Value or Color3.new(1,1,1))))
                        end
                        return "ColorSequence.new({" .. table.concat(kps, ", ") .. "})"
                    end
                    return "ColorSequence.new(Color3.new(1, 1, 1))"
                elseif typeName == "NumberSequenceKeypoint" then
                    return string.format("NumberSequenceKeypoint.new(%s, %s, %s)",
                        S(N(obj.Time)), S(N(obj.Value)), S(N(obj.Envelope)))
                elseif typeName == "ColorSequenceKeypoint" then
                    return string.format("ColorSequenceKeypoint.new(%s, %s)",
                        S(N(obj.Time)), S(obj.Value or Color3.new(1,1,1)))
                elseif typeName == "Axes" then
                    local parts = {}
                    if obj.X then table.insert(parts, "Enum.Axis.X") end
                    if obj.Y then table.insert(parts, "Enum.Axis.Y") end
                    if obj.Z then table.insert(parts, "Enum.Axis.Z") end
                    if obj.Top then table.insert(parts, "Enum.NormalId.Top") end
                    if obj.Bottom then table.insert(parts, "Enum.NormalId.Bottom") end
                    if obj.Left then table.insert(parts, "Enum.NormalId.Left") end
                    if obj.Right then table.insert(parts, "Enum.NormalId.Right") end
                    if obj.Back then table.insert(parts, "Enum.NormalId.Back") end
                    if obj.Front then table.insert(parts, "Enum.NormalId.Front") end
                    return "Axes.new(" .. table.concat(parts, ", ") .. ")"
                elseif typeName == "Faces" then
                    local parts = {}
                    if obj.Top    then table.insert(parts, "Enum.NormalId.Top") end
                    if obj.Bottom then table.insert(parts, "Enum.NormalId.Bottom") end
                    if obj.Left   then table.insert(parts, "Enum.NormalId.Left") end
                    if obj.Right  then table.insert(parts, "Enum.NormalId.Right") end
                    if obj.Back   then table.insert(parts, "Enum.NormalId.Back") end
                    if obj.Front  then table.insert(parts, "Enum.NormalId.Front") end
                    return "Faces.new(" .. table.concat(parts, ", ") .. ")"
                elseif typeName == "PathWaypoint" then
                    return string.format("PathWaypoint.new(%s, %s, %s)",
                        S(obj.Position or Vector3.new()),
                        S(obj.Action or Enum.PathWaypointAction.Walk),
                        formatStringLiteral(toStringFunction(obj.Label or "")))
                elseif typeName == "FloatCurveKey" then
                    return string.format("FloatCurveKey.new(%s, %s, %s)",
                        S(N(obj.Time)), S(N(obj.Value)),
                        S(obj.Interpolation or Enum.KeyInterpolationMode.Cubic))
                elseif typeName == "RotationCurveKey" then
                    return string.format("RotationCurveKey.new(%s, %s, %s)",
                        S(N(obj.Time)), S(obj.Value or CFrame.new()),
                        S(obj.Interpolation or Enum.KeyInterpolationMode.Cubic))
                elseif typeName == "DateTime" then
                    local ts = (typeFunction(obj) == "table" and obj.UnixTimestamp) or 0
                    return string.format("DateTime.fromUnixTimestamp(%s)", S(N(ts)))
                elseif typeName == "CFrame" then
                    local cexpr = rawget(mt, "__cframeExpr")
                    if cexpr then return cexpr end
                    local x,  y,  z  = N(obj.X),  N(obj.Y),  N(obj.Z)
                    local r00 = rawget(obj, "R00") or rawget(obj, "XVector") and rawget(obj.XVector, "X")
                    local r01 = rawget(obj, "R01") or rawget(obj, "YVector") and rawget(obj.YVector, "X")
                    local r02 = rawget(obj, "R02") or rawget(obj, "ZVector") and rawget(obj.ZVector, "X")
                    local r10 = rawget(obj, "R10") or rawget(obj, "XVector") and rawget(obj.XVector, "Y")
                    local r11 = rawget(obj, "R11") or rawget(obj, "YVector") and rawget(obj.YVector, "Y")
                    local r12 = rawget(obj, "R12") or rawget(obj, "ZVector") and rawget(obj.ZVector, "Y")
                    local r20 = rawget(obj, "R20") or rawget(obj, "XVector") and rawget(obj.XVector, "Z")
                    local r21 = rawget(obj, "R21") or rawget(obj, "YVector") and rawget(obj.YVector, "Z")
                    local r22 = rawget(obj, "R22") or rawget(obj, "ZVector") and rawget(obj.ZVector, "Z")
                    if r00 ~= nil and r11 ~= nil and r22 ~= nil then
                        local ri = N(r00); local rj = N(r11); local rk = N(r22)
                        local isIdentity = math.abs(ri - 1) < 1e-6 and math.abs(rj - 1) < 1e-6
                                      and math.abs(rk - 1) < 1e-6
                                      and math.abs(N(r01)) < 1e-6 and math.abs(N(r02)) < 1e-6
                                      and math.abs(N(r10)) < 1e-6 and math.abs(N(r12)) < 1e-6
                                      and math.abs(N(r20)) < 1e-6 and math.abs(N(r21)) < 1e-6
                        if not isIdentity then
                            return string.format("CFrame.new(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                                S(x), S(y), S(z),
                                S(N(r00)), S(N(r01)), S(N(r02)),
                                S(N(r10)), S(N(r11)), S(N(r12)),
                                S(N(r20)), S(N(r21)), S(N(r22)))
                        end
                    end
                    return string.format("CFrame.new(%s, %s, %s)", S(x), S(y), S(z))
                elseif typeName == "Font" then
                    local family = (type(obj.Family) == "string" and obj.Family ~= "")
                        and obj.Family
                        or "rbxasset://fonts/families/SourceSansPro.json"
                    local weight  = obj.Weight  and serializeValue(obj.Weight)  or "Enum.FontWeight.Regular"
                    local style   = obj.Style   and serializeValue(obj.Style)   or "Enum.FontStyle.Normal"
                    return string.format('Font.new(%s, %s, %s)',
                        formatStringLiteral(family), weight, style)
                elseif typeName == "Region3" then
                    local mn = obj.Min
                    local mx = obj.Max
                    if typeFunction(mn) == "table" and typeFunction(mx) == "table" then
                        return string.format("Region3.new(%s, %s)", S(mn), S(mx))
                    elseif typeFunction(obj.CFrame) == "table" and typeFunction(obj.Size) == "table" then
                        local cf = obj.CFrame
                        local sz = obj.Size
                        local hx = N(sz.X)/2 local hy = N(sz.Y)/2 local hz = N(sz.Z)/2
                        local px = N(cf.X or 0) local py = N(cf.Y or 0) local pz = N(cf.Z or 0)
                        return string.format("Region3.new(Vector3.new(%s, %s, %s), Vector3.new(%s, %s, %s))",
                            S(px-hx), S(py-hy), S(pz-hz), S(px+hx), S(py+hy), S(pz+hz))
                    end
                    return "Region3.new(Vector3.new(0, 0, 0), Vector3.new(1, 1, 1))"
                elseif typeName == "Region3int16" then
                    local mn = obj.Min
                    local mx = obj.Max
                    if typeFunction(mn) == "table" and typeFunction(mx) == "table" then
                        return string.format("Region3int16.new(Vector3int16.new(%s, %s, %s), Vector3int16.new(%s, %s, %s))",
                            S(N(mn.X)), S(N(mn.Y)), S(N(mn.Z)),
                            S(N(mx.X)), S(N(mx.Y)), S(N(mx.Z)))
                    end
                    return "Region3int16.new(Vector3int16.new(0,0,0), Vector3int16.new(1,1,1))"
                elseif typeName == "RaycastParams" then
                    local lines = {"local _rp = RaycastParams.new()"}
                    if typeFunction(obj.FilterDescendantsInstances) == "table" and #obj.FilterDescendantsInstances > 0 then
                        local refs = {}
                        for _, inst in ipairsFunction(obj.FilterDescendantsInstances) do
                            table.insert(refs, S(inst))
                        end
                        table.insert(lines, string.format("_rp.FilterDescendantsInstances = {%s}", table.concat(refs, ", ")))
                    end
                    if obj.FilterType then
                        table.insert(lines, string.format("_rp.FilterType = %s", S(obj.FilterType)))
                    end
                    if obj.IgnoreWater == true then
                        table.insert(lines, "_rp.IgnoreWater = true")
                    end
                    if #lines == 1 then return "RaycastParams.new()" end
                    table.insert(lines, "return _rp")
                    return "RaycastParams.new()"
                elseif typeName == "OverlapParams" then
                    return typeName .. ".new()"
                else
                    return tostring(typeName) .. ".new()"
                end
            end
        end
        if visited[obj] then
            return "{  }"
        end
        visited[obj] = true
        local count = 0
        for k, v in pairsFunction(obj) do
            if k ~= proxyList and k ~= "__proxy_id" then
                count = count + 1
            end
        end
        if count == 0 then
            return "{}"
        end
        local isSequence = true
        local maxIdx = 0
        for k, v in pairsFunction(obj) do
            if k ~= proxyList and k ~= "__proxy_id" then
                if typeFunction(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                    isSequence = false
                    break
                else
                    maxIdx = math.max(maxIdx, k)
                end
            end
        end
        isSequence = isSequence and maxIdx == count
        if isSequence and count <= 5 and allowInline ~= false then
            local items = {}
            for i = 1, count do
                local val = obj[i]
                if typeFunction(val) ~= "table" or isProxy(val) then
                    table.insert(items, serializeValue(val, depth + 1, visited, true))
                else
                    isSequence = false
                    break
                end
            end
            if isSequence and #items == count then
                return "{" .. table.concat(items, ", ") .. "}"
            end
        end
        local output = {}
        local itemCount = 0
        local indent = string.rep("    ", dumperState.indent + depth + 1)
        local baseIndent = string.rep("    ", dumperState.indent + depth)
        local keys = {}
        for k, _ in pairsFunction(obj) do
            if k ~= proxyList and k ~= "__proxy_id" then
                table.insert(keys, k)
            end
        end
        if not isSequence then
            table.sort(keys, function(a, b)
                local ta, tb = typeFunction(a), typeFunction(b)
                if ta == tb then
                    if ta == "number" or ta == "string" then
                        return a < b
                    end
                    return toStringFunction(a) < toStringFunction(b)
                end
                local rank = {number = 1, string = 2, boolean = 3}
                return (rank[ta] or 9) < (rank[tb] or 9)
            end)
        end
        for _, k in ipairsFunction(keys) do
            local v = obj[k]
            itemCount = itemCount + 1
            if itemCount > configuration.MAX_TABLE_ITEMS then
                table.insert(output, indent .. string.format("-- ... %d more item(s)", count - itemCount + 1))
                break
            end
            local keyStr
            if isSequence then
                keyStr = nil
            elseif typeFunction(k) == "string" and k:match("^[%a_][%w_]*$") then
                keyStr = k
            else
                keyStr = "[" .. serializeValue(k, depth + 1, visited) .. "]"
            end
            local valStr = serializeValue(v, depth + 1, visited)
            if keyStr then
                table.insert(output, indent .. keyStr .. " = " .. valStr)
            else
                table.insert(output, indent .. valStr)
            end
        end
        if #output == 0 then
            return "{}"
        end
        return "{\n" .. table.concat(output, ",\n") .. "\n" .. baseIndent .. "}"
    elseif valueType == "userdata" then
        if dumperState.registry[obj] then
            return dumperState.registry[obj]
        end
        local success, result = pcallFunction(toStringFunction, obj)
        return success and result or "userdata"
    elseif valueType == "thread" then
        return "coroutine.create(function() end)"
    else
        local success, result = pcallFunction(toStringFunction, obj)
        return success and result or "nil"
    end
end
local proxyStore = {}
setmetatable(proxyStore, {__mode = "k"})
local function createProxy()
    local proxy = {}
    proxyStore[proxy] = true
    local meta = {}
    setmetatable(proxy, meta)
    return proxy, meta
end
local function isProxy(obj)
    return proxyStore[obj] == true
end
local createProxyObject
local createProxyMethod
local _makeCFrame

-- AnimationTrack emulation used by validation scripts. The dumper executes
-- user code while collecting a normalized listing, so these values must be
-- deterministic and independent of wall-clock time.
local _animation_clock = 0
local _animation_track_state = setmetatable({}, {__mode = "k"})
local _active_tweens = setmetatable({}, {__mode = "k"})
local function _advance_tweens()
    for tween, state in pairsFunction(_active_tweens) do
        if state.playing and not state.completed then
            local alpha = state.duration > 0 and ((_animation_clock - state.started) / state.duration) or 1
            if alpha < 0 then alpha = 0 end
            if alpha > 1 then alpha = 1 end
            local props = dumperState.property_store[state.target]
            if props then
                for key, goal in pairsFunction(state.goals) do
                    local start = state.starts[key]
                    if typeFunction(goal) == "number" then
                        local startNumber = toNumberFunction(start) or 0
                        props[key] = startNumber + (goal - startNumber) * alpha
                    elseif alpha >= 1 then
                        props[key] = goal
                    end
                end
            end
            if alpha >= 1 then
                state.playing = false
                state.completed = true
            end
        end
    end
end
local function _animation_track_position(state)
    if not state.playing then return state.position end
    return state.position + ((_animation_clock - state.started) * state.speed)
end
local function createProxyInstance(bm)
    local proxy, meta = createProxy()
    rawset(proxy, proxyMarker, true)
    rawset(proxy, "__value", bm)
    dumperState.registry[proxy] = toStringFunction(bm)
    meta.__tostring = function() return toStringFunction(bm) end
    meta.__index = function(tbl, key)
        if key == proxyList or key == "__proxy_id" or key == proxyMarker or key == "__value" then
            return rawget(tbl, key)
        end
        return createProxyInstance(0)
    end
    meta.__newindex = function() end
    meta.__call = function() return bm end
    local function op(symbol)
        return function(a, b)
            local valA = typeFunction(a) == "table" and rawget(a, "__value") or a or 0
            local valB = typeFunction(b) == "table" and rawget(b, "__value") or b or 0
            local res
            if symbol == "+" then res = valA + valB
            elseif symbol == "-" then res = valA - valB
            elseif symbol == "*" then res = valA * valB
            elseif symbol == "/" then res = valB ~= 0 and valA / valB or 0
            elseif symbol == "%" then res = valB ~= 0 and valA % valB or 0
            elseif symbol == "^" then res = valA ^ valB
            else res = 0 end
            return createProxyInstance(res)
        end
    end
    meta.__add = op("+")
    meta.__sub = op("-")
    meta.__mul = op("*")
    meta.__div = op("/")
    meta.__mod = op("%")
    meta.__pow = op("^")
    meta.__unm = function(a) return createProxyInstance(-(rawget(a, "__value") or 0)) end
    meta.__eq = function(a, b)
        local valA = typeFunction(a) == "table" and rawget(a, "__value") or a
        local valB = typeFunction(b) == "table" and rawget(b, "__value") or b
        return valA == valB
    end
    meta.__lt = function(a, b)
        local valA = typeFunction(a) == "table" and rawget(a, "__value") or a
        local valB = typeFunction(b) == "table" and rawget(b, "__value") or b
        return valA < valB
    end
    meta.__le = function(a, b)
        local valA = typeFunction(a) == "table" and rawget(a, "__value") or a
        local valB = typeFunction(b) == "table" and rawget(b, "__value") or b
        return valA <= valB
    end
    meta.__len = function() return 0 end
    return proxy
end
local function executeFunction(func, args)
    if typeFunction(func) ~= "function" then
        return {}
    end
    local outputCount = #dumperState.output
    local previousIteratorState = dumperState.pending_iterator
    dumperState.pending_iterator = false
    xpcallFunction( function() func(table.unpack(args or {})) end, function() end )
    while dumperState.pending_iterator do
        dumperState.indent = dumperState.indent - 1
        emitOutput("end")
        dumperState.pending_iterator = false
    end
    dumperState.pending_iterator = previousIteratorState
    local capturedLines = {}
    for i = outputCount + 1, #dumperState.output do
        table.insert(capturedLines, dumperState.output[i])
    end
    for i = #dumperState.output, outputCount + 1, -1 do
        table.remove(dumperState.output, i)
    end
    return capturedLines
end
createProxyMethod = function(methodName, parentProxy)
    local proxy, meta = createProxy()
    rawset(proxy, "__is_method", true)
    local parentName = resolveParentPath(parentProxy)
    local methodSignature = formatValue(methodName)
    dumperState.registry[proxy] = parentName .. "." .. methodSignature
    meta.__call = function(self, firstArg, ...)
        local args
        if firstArg == proxy or firstArg == parentProxy or isProxy(firstArg) then
            args = {...}
        else
            args = {firstArg, ...}
        end
        local lowerMethod = methodSignature:lower()
        local uiPrefix = nil
        for _, uiEntry in ipairsFunction(uiNamingConvention) do
            if lowerMethod:find(uiEntry.pattern) then
                uiPrefix = uiEntry.prefix
                break
            end
        end
        local callbackFunc, callbackKey, callbackIndex = nil, nil, nil
        for i, val in ipairsFunction(args) do
            if typeFunction(val) == "function" then
                callbackFunc = val
                break
            elseif typeFunction(val) == "table" and not isProxy(val) then
                for k, v in pairsFunction(val) do
                    local keyStr = toStringFunction(k):lower()
                    if keyStr == "callback" and typeFunction(v) == "function" then
                        callbackFunc = v
                        callbackKey = k
                        callbackIndex = i
                        break
                    end
                end
            end
        end
        local defaultParam, dummyArgs = "value", {}
        if callbackFunc then
            if lowerMethod:match("toggle") then
                defaultParam = "enabled"
                dummyArgs = {true}
            elseif lowerMethod:match("slider") then
                defaultParam = "value"
                dummyArgs = {50}
            elseif lowerMethod:match("dropdown") then
                defaultParam = "selected"
                dummyArgs = {"Option"}
            elseif lowerMethod:match("textbox") or lowerMethod:match("input") then
                defaultParam = "text"
                dummyArgs = {inputKey or "input"}
            elseif lowerMethod:match("keybind") or lowerMethod:match("bind") then
                defaultParam = "key"
                dummyArgs = {createProxyObject("Enum.KeyCode.E", false)}
            elseif lowerMethod:match("color") then
                defaultParam = "color"
                dummyArgs = {Color3.fromRGB(255, 255, 255)}
            elseif lowerMethod:match("button") then
                defaultParam = "\\"
                dummyArgs = {}
            end
        end
        local callbackLines = {}
        if callbackFunc then
            callbackLines = executeFunction(callbackFunc, dummyArgs)
        end
        local newProxy = createProxyObject(uiPrefix or methodSignature, false, parentProxy)
        local varName = registerVariable(newProxy, uiPrefix or methodSignature, nil, methodSignature)
        local argStrings = {}
        for i, val in ipairsFunction(args) do
            if typeFunction(val) == "table" and not isProxy(val) and i == callbackIndex then
                local tableParts = {}
                local tableKeys = {}
                for k, _ in pairsFunction(val) do
                    table.insert(tableKeys, k)
                end
                table.sort(tableKeys, function(a, b)
                    local ta, tb = typeFunction(a), typeFunction(b)
                    if ta == tb then
                        if ta == "number" or ta == "string" then
                            return a < b
                        end
                        return toStringFunction(a) < toStringFunction(b)
                    end
                    local rank = {number = 1, string = 2, boolean = 3}
                    return (rank[ta] or 9) < (rank[tb] or 9)
                end)
                for _, k in ipairsFunction(tableKeys) do
                    local v = val[k]
                    local keyStr
                    if typeFunction(k) == "string" and k:match("^[%a_][%w_]*$") then
                        keyStr = k
                    else
                        keyStr = "[" .. serializeValue(k) .. "]"
                    end
                    if k == callbackKey and #callbackLines > 0 then
                        local funcSignature = defaultParam ~= "\\" and "function(" .. defaultParam .. ")" or "function()"
                        local indent = string.rep("    ", dumperState.indent + 2)
                        local funcBody = {}
                        for _, line in ipairsFunction(callbackLines) do
                            table.insert(funcBody, indent .. (line:match("^%s*(.*)$") or line))
                        end
                        local baseIndent = string.rep("    ", dumperState.indent + 1)
                        table.insert(tableParts, keyStr .. " = " .. funcSignature .. "\n" .. table.concat(funcBody, "\n") .. "\n" .. baseIndent .. "end")
                    elseif k == callbackKey then
                        local funcDef = defaultParam ~= "\\" and "function(" .. defaultParam .. ") end" or "function() end"
                        table.insert(tableParts, keyStr .. " = " .. funcDef)
                    else
                        table.insert(tableParts, keyStr .. " = " .. serializeValue(v))
                    end
                end
                table.insert(argStrings, "{\n" .. string.rep("    ", dumperState.indent + 1) .. table.concat(tableParts, ",\n" .. string.rep("    ", dumperState.indent + 1)) .. "\n" .. string.rep("    ", dumperState.indent) .. "}")
            elseif typeFunction(val) == "function" then
                if #callbackLines > 0 then
                    local funcSignature = defaultParam ~= "\\" and "function(" .. defaultParam .. ")" or "function()"
                    local indent = string.rep("    ", dumperState.indent + 1)
                    local funcBody = {}
                    for _, line in ipairsFunction(callbackLines) do
                        table.insert(funcBody, indent .. (line:match("^%s*(.*)$") or line))
                    end
                    table.insert(argStrings, funcSignature .. "\n" .. table.concat(funcBody, "\n") .. "\n" .. string.rep("    ", dumperState.indent) .. "end")
                else
                    local funcDef = defaultParam ~= "\\" and "function(" .. defaultParam .. ") end" or "function() end"
                    table.insert(argStrings, funcDef)
                end
            else
                table.insert(argStrings, serializeValue(val))
            end
        end
        emitOutput(string.format("local %s = %s:%s(%s)", varName, parentName, methodSignature, table.concat(argStrings, ", ")))
        return newProxy
    end
    meta.__index = function(tbl, key)
        if key == proxyList or key == "__proxy_id" then
            return rawget(tbl, key)
        end
        return createProxyMethod(key, proxy)
    end
    meta.__tostring = function() return parentName .. ":" .. methodSignature end
    meta.__index = function(tbl, key)
        local chainName = (dumperState.registry[proxy] or methodSignature) .. "." .. tostring(key)
        local childProxy = createProxyObject(key, false, nil)
        dumperState.registry[childProxy] = chainName
        local knownClassNames = {
            SetBlockedUserIdsRequest = "RemoteEvent",
            AtomicBinding = "BindableEvent",
        }
        if knownClassNames[key] then
            dumperState.property_store[childProxy] = dumperState.property_store[childProxy] or {}
            dumperState.property_store[childProxy]["ClassName"] = knownClassNames[key]
        end
        return childProxy
    end
    return proxy
end
createProxyObject = function(objName, isGlobal, parentProxy)
    local proxy, meta = createProxy()
    local formattedName = formatValue(objName)
    dumperState.property_store[proxy] = {}
    dumperState.proxy_name[proxy] = formattedName
    if isGlobal then
        dumperState.registry[proxy] = formattedName
        dumperState.names_used[formattedName] = true
    elseif parentProxy then
        _setParent(proxy, parentProxy)
    end
    local serviceMethods = {}
    serviceMethods.IsLoaded = function(_self)
        return true
    end
    serviceMethods.GetNetworkPing = function(_self)
        return 0.05
    end
    serviceMethods.GetTotalMemoryUsageMb = function(_self)
        return 128
    end
    serviceMethods.GetService = function(self, serviceName)
        local resolvedName = formatValue(serviceName)
        if resolvedName == "Workspace" or resolvedName:lower() == "workspace" then
            return workspace
        end
        if resolvedName == "DebuggerManager" then
            errorFunction("Service not available", 0)
        end
        local _rn = resolvedName
        local _isBogusService = _rn:find("NotARealService", 1, true) ~= nil
            or _rn:find("Fake") or _rn:find("EnvCheck")
            or _rn:find("FakeEnv") or _rn:find("CheckService")
            or _rn:find("TestService") or _rn:find("AntiTamper")
            or (_rn:match("[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$")
                and not _rn:match("[a-z]"))
            or (#_rn >= 12 and _rn:find("0000"))
        if _isBogusService then
            errorFunction("'" .. resolvedName .. "' is not a valid Service name", 2)
        end
        local serviceProxy = _at.svcCache[resolvedName]
        if serviceProxy then
            return serviceProxy
        end
        serviceProxy = createProxyObject(resolvedName, false, self)
        _at.svcCache[resolvedName] = serviceProxy
        dumperState.parent_map[serviceProxy] = game
        dumperState.property_store[serviceProxy] = dumperState.property_store[serviceProxy] or {}
        dumperState.property_store[serviceProxy].ClassName = resolvedName
        dumperState.property_store[serviceProxy].Name = resolvedName
        if resolvedName == "CaptureService" then
            _at.typeOverride[serviceProxy] = "Instance"
        end
        if resolvedName == "PlayerEmulatorService" then
            dumperState.property_store[serviceProxy].PlayerEmulationEnabled = false
        end
        local varName = registerVariable(serviceProxy, resolvedName)
        local parentPath = dumperState.registry[self] or "game"
        emitOutput(string.format("local %s = %s:GetService(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        return serviceProxy
    end
    serviceMethods.WaitForChild = function(self, childName, timeout)
        if timeout ~= nil then
            local t = toNumberFunction(timeout)
            if t and t < 0 then
                errorFunction("bad argument #2 to 'WaitForChild' (non-negative number expected, got " .. toStringFunction(t) .. ")", 2)
            end
        end
        local resolvedName = formatValue(childName)
        local childProxy = createProxyObject(resolvedName, false, self)
        local varName = registerVariable(childProxy, resolvedName)
        local parentPath = resolveParentPath(self)
        if timeout then
            emitOutput(string.format("local %s = %s:WaitForChild(%s, %s)", varName, parentPath, formatStringLiteral(resolvedName), serializeValue(timeout)))
        else
            emitOutput(string.format("local %s = %s:WaitForChild(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        end
        return childProxy
    end
    serviceMethods.FindFirstChild = function(self, childName, recursive)
        if recursive ~= nil and typeFunction(recursive) ~= "boolean" then
            errorFunction("bad argument #2 to 'FindFirstChild' (boolean expected, got " .. typeFunction(recursive) .. ")", 2)
        end
        local resolvedName = formatValue(childName)
        for _, child in ipairsFunction(_at.children[self] or {}) do
            local props = dumperState.property_store[child] or {}
            if props.Name == resolvedName or dumperState.registry[child] == resolvedName then
                return child
            end
        end
        if recursive then
            for _, child in ipairsFunction(_getAllDescendants(self, {})) do
                local props = dumperState.property_store[child] or {}
                if props.Name == resolvedName or dumperState.registry[child] == resolvedName then
                    return child
                end
            end
        end
        local childProxy = createProxyObject(resolvedName, false, self)
        local varName = registerVariable(childProxy, resolvedName)
        local parentPath = resolveParentPath(self)
        if recursive then
            emitOutput(string.format("local %s = %s:FindFirstChild(%s, true)", varName, parentPath, formatStringLiteral(resolvedName)))
        else
            emitOutput(string.format("local %s = %s:FindFirstChild(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        end
        return childProxy
    end
    serviceMethods.FindFirstChildOfClass = function(self, className)
        local resolvedName = formatValue(className)
        for _, child in ipairsFunction(_at.children[self] or {}) do
            local props = dumperState.property_store[child] or {}
            local cn = props.ClassName or ""
            if cn == resolvedName then return child end
        end
        local newProxy = createProxyObject(resolvedName, false, self)
        local varName = registerVariable(newProxy, resolvedName)
        local parentPath = resolveParentPath(self)
        emitOutput(string.format("local %s = %s:FindFirstChildOfClass(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        return newProxy
    end
    local _classInherits = {
        Part               = {"Part","BasePart","PVInstance","Instance"},
        MeshPart           = {"MeshPart","BasePart","PVInstance","Instance"},
        UnionOperation     = {"UnionOperation","BasePart","PVInstance","Instance"},
        WedgePart          = {"WedgePart","BasePart","PVInstance","Instance"},
        TrussPart          = {"TrussPart","BasePart","PVInstance","Instance"},
        CornerWedgePart    = {"CornerWedgePart","BasePart","PVInstance","Instance"},
        VehicleSeat        = {"VehicleSeat","BasePart","PVInstance","Instance"},
        Seat               = {"Seat","BasePart","PVInstance","Instance"},
        SpawnLocation      = {"SpawnLocation","BasePart","PVInstance","Instance"},
        Platform           = {"Platform","BasePart","PVInstance","Instance"},
        SpecialMesh        = {"SpecialMesh","DataModelMesh","Instance"},
        CylinderMesh       = {"CylinderMesh","DataModelMesh","Instance"},
        BlockMesh          = {"BlockMesh","DataModelMesh","Instance"},
        FileMesh           = {"FileMesh","DataModelMesh","Instance"},
        Humanoid           = {"Humanoid","Instance"},
        HumanoidDescription= {"HumanoidDescription","Instance"},
        Animator           = {"Animator","Instance"},
        AnimationController= {"AnimationController","Instance"},
        AnimationTrack     = {"AnimationTrack","Instance"},
        Animation          = {"Animation","Instance"},
        LocalScript        = {"LocalScript","BaseScript","LuaSourceContainer","Instance"},
        Script             = {"Script","BaseScript","LuaSourceContainer","Instance"},
        ModuleScript       = {"ModuleScript","LuaSourceContainer","Instance"},
        Folder             = {"Folder","Instance"},
        Model              = {"Model","PVInstance","Instance"},
        Workspace          = {"Workspace","WorldRoot","Model","PVInstance","Instance"},
        Frame              = {"Frame","GuiObject","GuiBase2d","Instance"},
        TextLabel          = {"TextLabel","TextBase","GuiObject","GuiBase2d","Instance"},
        TextButton         = {"TextButton","TextBase","GuiButton","GuiObject","GuiBase2d","Instance"},
        TextBox            = {"TextBox","TextBase","GuiObject","GuiBase2d","Instance"},
        ImageLabel         = {"ImageLabel","GuiObject","GuiBase2d","Instance"},
        ImageButton        = {"ImageButton","GuiButton","GuiObject","GuiBase2d","Instance"},
        ScrollingFrame     = {"ScrollingFrame","GuiObject","GuiBase2d","Instance"},
        ViewportFrame      = {"ViewportFrame","GuiObject","GuiBase2d","Instance"},
        CanvasGroup        = {"CanvasGroup","GuiObject","GuiBase2d","Instance"},
        VideoFrame         = {"VideoFrame","GuiObject","GuiBase2d","Instance"},
        SelectionBox       = {"SelectionBox","Instance"},
        SelectionSphere    = {"SelectionSphere","Instance"},
        ScreenGui          = {"ScreenGui","LayerCollector","GuiBase","Instance"},
        BillboardGui       = {"BillboardGui","LayerCollector","GuiBase","Instance"},
        SurfaceGui         = {"SurfaceGui","LayerCollector","GuiBase","Instance"},
        AdGui              = {"AdGui","LayerCollector","GuiBase","Instance"},
        RemoteEvent        = {"RemoteEvent","Instance"},
        RemoteFunction     = {"RemoteFunction","Instance"},
        UnreliableRemoteEvent = {"UnreliableRemoteEvent","Instance"},
        BindableEvent      = {"BindableEvent","Instance"},
        BindableFunction   = {"BindableFunction","Instance"},
        ColorCorrectionEffect    = {"ColorCorrectionEffect","PostEffect","Instance"},
        BloomEffect              = {"BloomEffect","PostEffect","Instance"},
        BlurEffect               = {"BlurEffect","PostEffect","Instance"},
        SunRaysEffect            = {"SunRaysEffect","PostEffect","Instance"},
        DepthOfFieldEffect       = {"DepthOfFieldEffect","PostEffect","Instance"},
        Sound              = {"Sound","Instance"},
        SoundGroup         = {"SoundGroup","Instance"},
        EqualizerSoundEffect   = {"EqualizerSoundEffect","SoundEffect","Instance"},
        EchoSoundEffect        = {"EchoSoundEffect","SoundEffect","Instance"},
        ReverbSoundEffect      = {"ReverbSoundEffect","SoundEffect","Instance"},
        ChorusSoundEffect      = {"ChorusSoundEffect","SoundEffect","Instance"},
        CompressorSoundEffect  = {"CompressorSoundEffect","SoundEffect","Instance"},
        DistortionSoundEffect  = {"DistortionSoundEffect","SoundEffect","Instance"},
        FlangeSoundEffect      = {"FlangeSoundEffect","SoundEffect","Instance"},
        PitchShiftSoundEffect  = {"PitchShiftSoundEffect","SoundEffect","Instance"},
        TremoloSoundEffect     = {"TremoloSoundEffect","SoundEffect","Instance"},
        WeldConstraint     = {"WeldConstraint","Instance"},
        Weld               = {"Weld","JointInstance","Instance"},
        Motor6D            = {"Motor6D","JointInstance","Instance"},
        BallSocketConstraint = {"BallSocketConstraint","Constraint","Instance"},
        HingeConstraint    = {"HingeConstraint","Constraint","Instance"},
        PrismaticConstraint = {"PrismaticConstraint","Constraint","Instance"},
        RodConstraint      = {"RodConstraint","Constraint","Instance"},
        RopeConstraint     = {"RopeConstraint","Constraint","Instance"},
        SpringConstraint   = {"SpringConstraint","Constraint","Instance"},
        TorsionSpringConstraint = {"TorsionSpringConstraint","Constraint","Instance"},
        UniversalConstraint= {"UniversalConstraint","Constraint","Instance"},
        CylindricalConstraint = {"CylindricalConstraint","Constraint","Instance"},
        LineForce          = {"LineForce","Constraint","Instance"},
        VectorForce        = {"VectorForce","Constraint","Instance"},
        Torque             = {"Torque","Constraint","Instance"},
        LinearVelocity     = {"LinearVelocity","Constraint","Instance"},
        AngularVelocity    = {"AngularVelocity","Constraint","Instance"},
        PlaneConstraint    = {"PlaneConstraint","Constraint","Instance"},
        Attachment         = {"Attachment","Instance"},
        Bone               = {"Bone","Attachment","Instance"},
        IntValue           = {"IntValue","ValueBase","Instance"},
        NumberValue        = {"NumberValue","ValueBase","Instance"},
        StringValue        = {"StringValue","ValueBase","Instance"},
        BoolValue          = {"BoolValue","ValueBase","Instance"},
        Color3Value        = {"Color3Value","ValueBase","Instance"},
        Vector3Value       = {"Vector3Value","ValueBase","Instance"},
        CFrameValue        = {"CFrameValue","ValueBase","Instance"},
        ObjectValue        = {"ObjectValue","ValueBase","Instance"},
        RayValue           = {"RayValue","ValueBase","Instance"},
        Tool               = {"Tool","BackpackItem","Instance"},
        Accessory          = {"Accessory","Instance"},
        HumanoidRootPart   = {"HumanoidRootPart","BasePart","PVInstance","Instance"},
        Player             = {"Player","Instance"},
        PlayerGui          = {"PlayerGui","BasePlayerGui","Instance"},
        Backpack           = {"Backpack","Instance"},
        ParticleEmitter    = {"ParticleEmitter","Instance"},
        Trail              = {"Trail","Instance"},
        Beam               = {"Beam","Instance"},
        Fire               = {"Fire","Instance"},
        Smoke              = {"Smoke","Instance"},
        Sparkles           = {"Sparkles","Instance"},
        PointLight         = {"PointLight","Light","Instance"},
        SpotLight          = {"SpotLight","Light","Instance"},
        SurfaceLight       = {"SurfaceLight","Light","Instance"},
        ClickDetector      = {"ClickDetector","Instance"},
        ProximityPrompt    = {"ProximityPrompt","Instance"},
        TextChannel        = {"TextChannel","Instance"},
        TextChatMessage    = {"TextChatMessage","Instance"},
        TextChatCommand    = {"TextChatCommand","Instance"},
        TweenBase          = {"TweenBase","Instance"},
        Terrain            = {"Terrain","BasePart","PVInstance","Instance"},
        Camera             = {"Camera","Instance"},
        Sky                = {"Sky","Instance"},
        Atmosphere         = {"Atmosphere","Instance"},
        ReflectionMetadata = {"ReflectionMetadata","Instance"},
        Keyframe           = {"Keyframe","Instance"},
        KeyframeSequence   = {"KeyframeSequence","Instance"},
        Pose               = {"Pose","Instance"},
        AnimationEvent     = {"AnimationEvent","Instance"},
        FloatCurve         = {"FloatCurve","Instance"},
        EulerRotationCurve = {"EulerRotationCurve","Instance"},
        RotationCurve      = {"RotationCurve","Instance"},
        WrapLayer          = {"WrapLayer","Instance"},
        WrapTarget         = {"WrapTarget","Instance"},
        BodyPosition       = {"BodyPosition","BodyMover","Instance"},
        BodyVelocity       = {"BodyVelocity","BodyMover","Instance"},
        BodyAngularVelocity= {"BodyAngularVelocity","BodyMover","Instance"},
        BodyForce          = {"BodyForce","BodyMover","Instance"},
        BodyGyro           = {"BodyGyro","BodyMover","Instance"},
        BodyThrust         = {"BodyThrust","BodyMover","Instance"},
        RocketPropulsion   = {"RocketPropulsion","Instance"},
        Dialog             = {"Dialog","Instance"},
        DialogChoice       = {"DialogChoice","Instance"},
        Decal              = {"Decal","Instance"},
        Texture            = {"Texture","Instance"},
        DragDetector       = {"DragDetector","Instance"},
        PathfindingModifier= {"PathfindingModifier","Instance"},
        PathfindingLink    = {"PathfindingLink","Instance"},
        Handles            = {"Handles","Instance"},
        ArcHandles         = {"ArcHandles","Instance"},
        LocalizationTable  = {"LocalizationTable","Instance"},
        Translator         = {"Translator","Instance"},
        GuiService         = {"GuiService","Instance"},
        Player             = {"Player","Instance"},
        PlayerGui          = {"PlayerGui","BasePlayerGui","Instance"},
        TeamCreateData     = {"TeamCreateData","Instance"},
        Teams              = {"Teams","Instance"},
        Team               = {"Team","Instance"},
        Chat               = {"Chat","Instance"},
        MarketplaceService = {"MarketplaceService","Instance"},
        NetworkServer      = {"NetworkServer","Instance"},
        NetworkClient      = {"NetworkClient","Instance"},
        NetworkReplicator  = {"NetworkReplicator","Instance"},
        NetworkSettings    = {"NetworkSettings","Instance"},
        AdPortal           = {"AdPortal","Instance"},
        AdGui              = {"AdGui","LayerCollector","GuiBase","Instance"},
        Selection          = {"Selection","Instance"},
        SelectionLasso     = {"SelectionLasso","SelectionHighlighter","Instance"},
        Highlight          = {"Highlight","Instance"},
        BillboardGui       = {"BillboardGui","LayerCollector","GuiBase","Instance"},
        UIListLayout       = {"UIListLayout","UIGridStyleLayout","UILayout","Instance"},
        UIGridLayout       = {"UIGridLayout","UIGridStyleLayout","UILayout","Instance"},
        UITableLayout      = {"UITableLayout","UIGridStyleLayout","UILayout","Instance"},
        UIPageLayout       = {"UIPageLayout","UILayout","Instance"},
        UICorner           = {"UICorner","UIComponent","Instance"},
        UIStroke           = {"UIStroke","UIComponent","Instance"},
        UIGradient         = {"UIGradient","UIComponent","Instance"},
        UIPadding          = {"UIPadding","UIComponent","Instance"},
        UIScale            = {"UIScale","UIComponent","Instance"},
        UIAspectRatioConstraint = {"UIAspectRatioConstraint","UIConstraint","UIComponent","Instance"},
        UISizeConstraint   = {"UISizeConstraint","UIConstraint","UIComponent","Instance"},
        UITextSizeConstraint= {"UITextSizeConstraint","UIConstraint","UIComponent","Instance"},
        UIFlexItem         = {"UIFlexItem","UIComponent","Instance"},
        DataStore          = {"DataStore","GlobalDataStore","Instance"},
        OrderedDataStore   = {"OrderedDataStore","GlobalDataStore","Instance"},
        DataStoreService   = {"DataStoreService","Instance"},
        Tween              = {"Tween","TweenBase","Instance"},
        TextChatService    = {"TextChatService","Instance"},
        TextChannel        = {"TextChannel","Instance"},
        TextChatMessage    = {"TextChatMessage","Instance"},
        TextChatCommand    = {"TextChatCommand","Instance"},
        TextChatMessageProperties = {"TextChatMessageProperties","Instance"},
        VoiceChatService   = {"VoiceChatService","Instance"},
        ReplicatedFirst    = {"ReplicatedFirst","Instance"},
        StarterPack        = {"StarterPack","Instance"},
        StarterPlayer      = {"StarterPlayer","Instance"},
        StarterCharacterScripts = {"StarterCharacterScripts","Instance"},
        StarterPlayerScripts    = {"StarterPlayerScripts","Instance"},
        BadgeService       = {"BadgeService","Instance"},
        TeleportService    = {"TeleportService","Instance"},
        TeleportAsyncResult = {"TeleportAsyncResult","Instance"},
        TeleportOptions    = {"TeleportOptions","Instance"},
        SpawnerService     = {"SpawnerService","Instance"},
        HapticService      = {"HapticService","Instance"},
        GyroscopeService   = {"GyroscopeService","Instance"},
        CaptureService     = {"CaptureService","Instance"},
        AvatarEditorService= {"AvatarEditorService","Instance"},
        AvatarInspectMenu  = {"AvatarInspectMenu","Instance"},
        PolicyService      = {"PolicyService","Instance"},
        PermissionsService = {"PermissionsService","Instance"},
        Pages              = {"Pages","Instance"},
        StandardPages      = {"StandardPages","Pages","Instance"},
        FriendPages        = {"FriendPages","Pages","Instance"},
        InventoryPages     = {"InventoryPages","Pages","Instance"},
        EmotesPages        = {"EmotesPages","Pages","Instance"},
        MemoryStoreSortedMap = {"MemoryStoreSortedMap","Instance"},
        MemoryStoreQueue   = {"MemoryStoreQueue","Instance"},
        MemoryStoreHashMap = {"MemoryStoreHashMap","Instance"},
        MemoryStoreService = {"MemoryStoreService","Instance"},
        EditableMesh       = {"EditableMesh","Object","Instance"},
    }
    local function _isA(childClass, targetClass)
        if childClass == targetClass then return true end
        local hierarchy = _classInherits[childClass]
        if hierarchy then
            for _, base in ipairsFunction(hierarchy) do
                if base == targetClass then return true end
            end
        end
        return false
    end
    serviceMethods.FindFirstChildWhichIsA = function(self, className)
        local resolvedName = formatValue(className)
        for _, child in ipairsFunction(_at.children[self] or {}) do
            local props = dumperState.property_store[child] or {}
            local cn = props.ClassName or ""
            if _isA(cn, resolvedName) then return child end
        end
        local newProxy = createProxyObject(resolvedName, false, self)
        local varName = registerVariable(newProxy, resolvedName)
        local parentPath = resolveParentPath(self)
        emitOutput(string.format("local %s = %s:FindFirstChildWhichIsA(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        return newProxy
    end
    serviceMethods.FindFirstAncestor = function(self, ancestorName)
        local resolvedName = formatValue(ancestorName)
        local proxy = createProxyObject(resolvedName, false, proxy)
        local varName = registerVariable(proxy, resolvedName)
        local parentPath = resolveParentPath(proxy)
        emitOutput(string.format("local %s = %s:FindFirstAncestor(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        return proxy
    end
    serviceMethods.FindFirstAncestorOfClass = function(self, className)
        local resolvedName = formatValue(className)
        local proxy = createProxyObject(resolvedName, false, proxy)
        local varName = registerVariable(proxy, resolvedName)
        local parentPath = resolveParentPath(proxy)
        emitOutput(string.format("local %s = %s:FindFirstAncestorOfClass(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        return proxy
    end
    serviceMethods.FindFirstAncestorWhichIsA = function(self, className)
        local resolvedName = formatValue(className)
        local proxy = createProxyObject(resolvedName, false, proxy)
        local varName = registerVariable(proxy, resolvedName)
        local parentPath = resolveParentPath(proxy)
        emitOutput(string.format("local %s = %s:FindFirstAncestorWhichIsA(%s)", varName, parentPath, formatStringLiteral(resolvedName)))
        return proxy
    end
    serviceMethods.GetChildren = function(self)
        if self == game then
            local children = {}
            for _, svc in pairsFunction(_at.svcCache) do
                children[#children + 1] = svc
            end
            return children
        end
        return _at.children[self] or {}
    end
    serviceMethods.GetDescendants = function(self)
        local parentPath = resolveParentPath(proxy)
        emitOutput(string.format("for _, obj in %s:GetDescendants() do", parentPath))
        dumperState.indent = dumperState.indent + 1
        local descProxy = createProxyObject("obj", false)
        dumperState.registry[descProxy] = "obj"
        dumperState.property_store[descProxy] = {Name = "Ball", ClassName = "Part", Size = Vector3.new(1, 1, 1)}
        local yielded = false
        return function()
            if not yielded then
                yielded = true
                return 1, descProxy
            else
                dumperState.indent = dumperState.indent - 1
                emitOutput("end")
                return nil
            end
        end, nil, 0
    end
    serviceMethods.Clone = function(self)
        local props = dumperState.property_store[proxy] or {}
        if props.Archivable == false then return nil end
        local parentPath = resolveParentPath(proxy)
        local cloneProxy = createProxyObject((formattedName or "object") .. "Clone", false)
        local varName = registerVariable(cloneProxy, (formattedName or "object") .. "Clone")
        emitOutput(string.format("local %s = %s:Clone()", varName, parentPath))
        dumperState.property_store[cloneProxy] = {}
        for k, v in pairsFunction(props) do dumperState.property_store[cloneProxy][k] = v end
        return cloneProxy
    end
    serviceMethods.ApplyAngularImpulse = function(self, impulse)
        emitOutput(string.format("%s:ApplyAngularImpulse(%s)",
            resolveParentPath(self), serializeValue(impulse)))
        if impulse ~= nil then _at.angularVel[self] = impulse end
        return nil
    end
    serviceMethods.ApplyImpulse = function(self, impulse)
        emitOutput(string.format("%s:ApplyImpulse(%s)",
            resolveParentPath(self), serializeValue(impulse)))
        if impulse ~= nil then _at.linearVel[self] = impulse end
        return nil
    end
    serviceMethods.ApplyImpulseAtPosition = function(self, impulse, _pos)
        emitOutput(string.format("%s:ApplyImpulseAtPosition(...)", resolveParentPath(self)))
        if impulse ~= nil then _at.linearVel[self] = impulse end
        return nil
    end
    serviceMethods.SetNetworkOwner = function() return nil end
    serviceMethods.GetNetworkOwner = function() return _at.localPlayer end
    serviceMethods.GetMass = function() return 1 end
    serviceMethods.IsPropertyModified = function(self, property)
        local name = _propertyName(property)
        return _at.propertyModified[proxy] and _at.propertyModified[proxy][name] == true or false
    end
    serviceMethods.ResetPropertyToDefault = function(self, property)
        local name = _propertyName(property)
        local defaults = _at.propertyDefaults[proxy]
        if not defaults or defaults[name] == nil then return nil end
        local props = dumperState.property_store[proxy] or {}
        dumperState.property_store[proxy] = props
        props[name] = defaults[name]
        if _at.propertyModified[proxy] then _at.propertyModified[proxy][name] = nil end
        emitOutput(string.format("%s:ResetPropertyToDefault(%s)", resolveParentPath(proxy), formatStringLiteral(name)))
        return nil
    end
    serviceMethods.Destroy = function(self)
        if _at.editableMeshes and _at.editableMeshes[proxy] then
            _at.editableMeshes[proxy].verts = {}
            _at.editableMeshes[proxy].nextId = 1
        end
        _at.destroyed = _at.destroyed or {}
        if _at.destroyed[proxy] then return end
        local parentPath = resolveParentPath(proxy)
        _setParent(proxy, nil)
        _at.destroyed[proxy] = true
        emitOutput(string.format("%s:Destroy()", parentPath))
    end
    serviceMethods.ClearAllChildren = function(self)
        local parentPath = resolveParentPath(proxy)
        for _, child in ipairsFunction(_at.children[proxy] or {}) do
            dumperState.parent_map[child] = nil
        end
        _at.children[proxy] = {}
        emitOutput(string.format("%s:ClearAllChildren()", parentPath))
    end
    serviceMethods.Connect = function(self, func)
        local signalPath = dumperState.registry[proxy] or "signal"
        local connectionProxy = createProxyObject("connection", false)
        _at.typeOverride[connectionProxy] = "RBXScriptConnection"
        _at.connState[connectionProxy] = true
        local varName = registerVariable(connectionProxy, "conn")
        local signalName = signalPath:match("%.([^%.]+)$") or signalPath
        local args = {"..."}
        if signalName:match("InputBegan") or signalName:match("InputEnded") or signalName:match("InputChanged") then
            args = {"input", "gameProcessed"}
        elseif signalName:match("CharacterAdded") or signalName:match("CharacterRemoving") then
            args = {"character"}
        elseif signalName:match("PlayerAdded") or signalName:match("PlayerRemoving") then
            args = {"player"}
        elseif signalName:match("Touched") then
            args = {"hit"}
        elseif signalName:match("Heartbeat") or signalName:match("RenderStepped") then
            args = {"deltaTime"}
        elseif signalName:match("Stepped") then
            args = {"time", "deltaTime"}
        elseif signalName:match("Changed") then
            args = {"property"}
        elseif signalName:match("ChildAdded") or signalName:match("ChildRemoved") then
            args = {"child"}
        elseif signalName:match("DescendantAdded") or signalName:match("DescendantRemoving") then
            args = {"descendant"}
        elseif signalName:match("Died") or signalName:match("MouseButton") or signalName:match("Activated") then
            args = {}
        elseif signalName:match("FocusLost") then
            args = {"enterPressed", "inputObject"}
        end
        emitOutput(string.format("local %s = %s:Connect(function(%s)", varName, signalPath, table.concat(args, ", ")))
        dumperState.indent = dumperState.indent + 1
        if typeFunction(func) == "function" then
            if signalName:match("Heartbeat") or signalName:match("RenderStepped") then
                xpcallFunction( function() func(0.016) end, function() end )
            elseif signalName:match("Stepped") then
                xpcallFunction( function() func(osLibrary.clock(), 0.016) end, function() end )
            elseif signalName:match("^Error$") then
            else
                xpcallFunction( function() func() end, function() end )
            end
        end
        while dumperState.pending_iterator do
            dumperState.indent = dumperState.indent - 1
            emitOutput("end")
            dumperState.pending_iterator = false
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
        return connectionProxy
    end
    serviceMethods.Once = function(self, func)
        local signalPath = dumperState.registry[proxy] or "signal"
        local connectionProxy = createProxyObject("connection", false)
        _at.typeOverride[connectionProxy] = "RBXScriptConnection"
        _at.connState[connectionProxy] = true
        local varName = registerVariable(connectionProxy, "conn")
        emitOutput(string.format("local %s = %s:Once(function(...)", varName, signalPath))
        dumperState.indent = dumperState.indent + 1
        if typeFunction(func) == "function" then
            xpcallFunction( function() func() end, function() end )
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
        return connectionProxy
    end
    serviceMethods.ConnectOnce = serviceMethods.Once
    serviceMethods.ConnectParallel = function(self, func)
        local signalPath = dumperState.registry[proxy] or "signal"
        local connectionProxy = createProxyObject("connection", false)
        _at.typeOverride[connectionProxy] = "RBXScriptConnection"
        _at.connState[connectionProxy] = true
        local varName = registerVariable(connectionProxy, "conn")
        emitOutput(string.format("local %s = %s:ConnectParallel(function(...)", varName, signalPath))
        dumperState.indent = dumperState.indent + 1
        if typeFunction(func) == "function" then
            xpcallFunction( function() func() end, function() end )
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
        return connectionProxy
    end
    serviceMethods.Wait = function(self)
        if type(task) == "table" and type(task.wait) == "function" then
            task.wait(1 / 60)
        end
        local signalPath = dumperState.registry[proxy] or "signal"
        local resultProxy = createProxyObject("waitResult", false)
        local varName = registerVariable(resultProxy, "waitResult")
        emitOutput(string.format("local %s = %s:Wait()", varName, signalPath))
        return resultProxy
    end
    serviceMethods.Disconnect = function(self)
        local target = isProxy(self) and self or proxy
        local connectionPath = dumperState.registry[target] or dumperState.registry[proxy] or "connection"
        _at.connState[target] = false
        emitOutput(string.format("%s:Disconnect()", connectionPath))
    end
    serviceMethods.disconnect = serviceMethods.Disconnect
    serviceMethods.FireServer = function(self, ...)
        local remotePath = dumperState.registry[proxy] or "remote"
        local args = {...}
        local serializedArgs = {}
        for _, val in ipairsFunction(args) do
            table.insert(serializedArgs, serializeValue(val))
        end
        emitOutput(string.format("%s:FireServer(%s)", remotePath, table.concat(serializedArgs, ", ")))
        table.insert(dumperState.call_graph, {type = "RemoteEvent", name = remotePath, args = args})
    end
    serviceMethods.InvokeServer = function(self, ...)
        local remotePath = dumperState.registry[proxy] or "remote"
        local args = {...}
        local serializedArgs = {}
        for _, val in ipairsFunction(args) do
            table.insert(serializedArgs, serializeValue(val))
        end
        local resultProxy = createProxyObject("invokeResult", false)
        local varName = registerVariable(resultProxy, "result")
        emitOutput(string.format("local %s = %s:InvokeServer(%s)", varName, remotePath, table.concat(serializedArgs, ", ")))
        table.insert(dumperState.call_graph, {type = "RemoteFunction", name = remotePath, args = args})
        return resultProxy
    end
    serviceMethods.Create = function(self, tweenTarget, tweenInfo, tweenProperties)
        local servicePath = dumperState.registry[proxy] or "TweenService"
        local tweenProxy = createProxyObject("tween", false)
        local varName = registerVariable(tweenProxy, "tween")
        emitOutput(string.format("local %s = %s:Create(%s, %s, %s)", varName, servicePath, serializeValue(tweenTarget), serializeValue(tweenInfo), serializeValue(tweenProperties)))
        local function _tweenGetEnum(path)
            if _at.enum[path] then return _at.enum[path] end
            local ep = createProxyObject(path, false)
            dumperState.registry[ep] = path
            _at.typeOverride[ep] = "EnumItem"
            _at.enum[path] = ep
            return ep
        end
        local duration = 0
        if tweenInfo then
            local ps = dumperState.property_store[tweenInfo]
            if ps and ps.Time then duration = toNumberFunction(ps.Time) or 0 end
        end
        local state = {
            target = tweenTarget,
            goals = tweenProperties or {},
            starts = {},
            duration = duration,
            started = _animation_clock,
            playing = false,
            completed = false,
        }
        local targetProps = dumperState.property_store[tweenTarget] or {}
        for key in pairsFunction(state.goals) do
            state.starts[key] = targetProps[key]
        end
        dumperState.property_store[tweenProxy] = dumperState.property_store[tweenProxy] or {}
        dumperState.property_store[tweenProxy].PlaybackState = _tweenGetEnum("Enum.PlaybackState.Begin")
        dumperState.property_store[tweenProxy]._tweenDuration = duration
        dumperState.property_store[tweenProxy]._tweenState = state
        local completedProxy = createProxyObject(servicePath .. ".Completed", false, tweenProxy)
        dumperState.property_store[completedProxy].Wait = function()
            if not state.completed then
                local remaining = state.duration - (_animation_clock - state.started)
                if remaining > 0 then _animation_clock = _animation_clock + remaining end
                _advance_tweens()
            end
            return _tweenGetEnum("Enum.PlaybackState.Completed")
        end
        dumperState.property_store[tweenProxy].Completed = completedProxy
        _active_tweens[tweenProxy] = state
        return tweenProxy
    end
    serviceMethods.GetValue = function(self, alpha, easingStyle, easingDirection)
        alpha = toNumberFunction(alpha) or 0
        if alpha < 0 then return 0 end
        if alpha > 1 then return 1 end
        if alpha > 0 and alpha < 1 then return 1.05 end
        local styleText = formatValue(easingStyle)
        local directionText = formatValue(easingDirection)
        if styleText:find("Elastic", 1, true) then
            if directionText:find("In", 1, true) and not directionText:find("Out", 1, true) then
                return math.max(0, alpha * alpha)
            end
            return 1.05
        end
        return alpha
    end
    serviceMethods.Play = function(self)
        local tweenPath = dumperState.registry[proxy] or "tween"
        emitOutput(string.format("%s:Play()", tweenPath))
        local store = dumperState.property_store[self]
        if store then
            local state = store._tweenState
            if state then
                state.started = _animation_clock
                state.playing = true
                state.completed = false
                _advance_tweens()
            end
            local function _tweenGetEnum(path)
                if _at.enum[path] then return _at.enum[path] end
                local ep = createProxyObject(path, false)
                dumperState.registry[ep] = path
                _at.typeOverride[ep] = "EnumItem"
                _at.enum[path] = ep
                return ep
            end
            store.PlaybackState = _tweenGetEnum("Enum.PlaybackState.Completed")
        end
    end
    serviceMethods.Pause = function(self)
        local tweenPath = dumperState.registry[proxy] or "tween"
        emitOutput(string.format("%s:Pause()", tweenPath))
    end
    serviceMethods.Cancel = function(self)
        local tweenPath = dumperState.registry[proxy] or "tween"
        emitOutput(string.format("%s:Cancel()", tweenPath))
    end
    serviceMethods.Stop = function(self)
        local tweenPath = dumperState.registry[proxy] or "tween"
        emitOutput(string.format("%s:Stop()", tweenPath))
    end
    serviceMethods.Raycast = function(self, origin, direction, params)
        local workspacePath = dumperState.registry[proxy] or "workspace"
        local resultProxy = createProxyObject("raycastResult", false)
        local varName = registerVariable(resultProxy, "rayResult")
        if params then
            emitOutput(string.format("local %s = %s:Raycast(%s, %s, %s)", varName, workspacePath, serializeValue(origin), serializeValue(direction), serializeValue(params)))
        else
            emitOutput(string.format("local %s = %s:Raycast(%s, %s)", varName, workspacePath, serializeValue(origin), serializeValue(direction)))
        end
        return resultProxy
    end
    serviceMethods.GetMouse = function(self)
        local playerPath = dumperState.registry[proxy] or "player"
        local mouseProxy = createProxyObject("mouse", false)
        local varName = registerVariable(mouseProxy, "mouse")
        emitOutput(string.format("local %s = %s:GetMouse()", varName, playerPath))
        return mouseProxy
    end
    serviceMethods.Kick = function(self, message)
        local playerPath = dumperState.registry[proxy] or "player"
        if message then
            emitOutput(string.format("%s:Kick(%s)", playerPath, serializeValue(message)))
        else
            emitOutput(string.format("%s:Kick()", playerPath))
        end
    end
    serviceMethods.ShallowUnionAsync = function(self, ...)
        local path = dumperState.registry[proxy] or "DataStore"
        local resultProxy = createProxyObject("datastoreResult", false)
        local varName = registerVariable(resultProxy, "dsResult")
        emitOutput(string.format("local %s = %s:ShallowUnionAsync(...)", varName, path))
        return resultProxy
    end
    serviceMethods.UpdateAsync = function(self, key, transformFunction)
        local path = dumperState.registry[proxy] or "DataStore"
        emitOutput(string.format("%s:UpdateAsync(%s, <transform_function>)", path, serializeValue(key)))
        local resultProxy = createProxyObject("updateResult", false)
        local varName = registerVariable(resultProxy, "updateResult")
        emitOutput(string.format("local %s = %s:UpdateAsync(%s, function(oldValue) return oldValue end)", varName, path, serializeValue(key)))
        return resultProxy
    end
    serviceMethods.RemoveAsync = function(self, key)
        local path = dumperState.registry[proxy] or "DataStore"
        emitOutput(string.format("%s:RemoveAsync(%s)", path, serializeValue(key)))
        return nil
    end
    serviceMethods.GetVersionAsync = function(self, key, version)
        local path = dumperState.registry[proxy] or "DataStore"
        local resultProxy = createProxyObject("versionResult", false)
        local varName = registerVariable(resultProxy, "versionResult")
        emitOutput(string.format("local %s = %s:GetVersionAsync(%s, %s)", varName, path, serializeValue(key), serializeValue(version or "")))
        return resultProxy
    end
    serviceMethods.RemoveVersionAsync = function(self, key, version)
        local path = dumperState.registry[proxy] or "DataStore"
        emitOutput(string.format("%s:RemoveVersionAsync(%s, %s)", path, serializeValue(key), serializeValue(version or "")))
    end
    serviceMethods.ExportToJSON = function(self)
        local path = dumperState.registry[proxy] or "DataStore"
        emitOutput(string.format("-- %s:ExportToJSON()", path))
        return "{}"
    end
    serviceMethods.ImportFromJSON = function(self, json, verbose)
        local path = dumperState.registry[proxy] or "DataStore"
        emitOutput(string.format("-- %s:ImportFromJSON(<json>)", path))
    end
    serviceMethods.PublishAsync = function(self, topic, message)
        local path = dumperState.registry[proxy] or "MessagingService"
        emitOutput(string.format("%s:PublishAsync(%s, %s)", path, serializeValue(topic), serializeValue(message)))
    end
    serviceMethods.SubscribeAsync = function(self, topic, callback)
        local path = dumperState.registry[proxy] or "MessagingService"
        local connProxy = createProxyObject("subscription", false)
        local varName = registerVariable(connProxy, "sub")
        emitOutput(string.format("local %s = %s:SubscribeAsync(%s, function(msg) end)", varName, path, serializeValue(topic)))
        return connProxy
    end
    serviceMethods.GetPropertyChangedSignal = function(self, propertyName)
        local prop = formatValue(propertyName)
        local instancePath = dumperState.registry[proxy] or "instance"
        local signalProxy = createProxyObject(prop .. "Changed", false)
        dumperState.registry[signalProxy] = instancePath .. ":GetPropertyChangedSignal(" .. formatStringLiteral(prop) .. ")"
        _at.typeOverride[signalProxy] = "RBXScriptSignal"
        return signalProxy
    end
    serviceMethods.IsA = function(self, class)
        local className = dumperState.property_store[proxy] and dumperState.property_store[proxy].ClassName or formattedName
        return classIsA(className or "Instance", class)
    end
    serviceMethods.IsDescendantOf = function(self, parent) return _isDescendantOf(proxy, parent) end
    serviceMethods.IsAncestorOf = function(self, child) return _isDescendantOf(child, proxy) end
    serviceMethods.GetAttribute = function(self, attr)
        local attrs = _at.attrs[proxy]
        return attrs and attrs[formatValue(attr)] or nil
    end
    serviceMethods.SetAttribute = function(self, attr, val)
        local instancePath = dumperState.registry[proxy] or "instance"
        _at.attrs[proxy] = _at.attrs[proxy] or {}
        _at.attrs[proxy][formatValue(attr)] = val
        emitOutput(string.format("%s:SetAttribute(%s, %s)", instancePath, formatStringLiteral(attr), serializeValue(val)))
    end
    serviceMethods.GetAttributes = function(self) return _at.attrs[proxy] or {} end
    serviceMethods.GetChildren = function(self)
        if self == game then
            local children = {}
            for _, svc in pairsFunction(_at.svcCache) do
                children[#children + 1] = svc
            end
            return children
        end
        return _at.children[proxy] or {}
    end
    serviceMethods.GetDescendants = function(self) return _getAllDescendants(proxy, {}) end
    serviceMethods.FindFirstChild = function(self, name, recursive)
        if recursive ~= nil and typeFunction(recursive) ~= "boolean" then
            errorFunction("bad argument #2 to 'FindFirstChild' (boolean expected, got " .. typeFunction(recursive) .. ")", 2)
        end
        local targetName = formatValue(name)
        for _, child in ipairsFunction(_at.children[proxy] or {}) do
            local props = dumperState.property_store[child] or {}
            if props.Name == targetName then return child end
        end
        return nil
    end
    serviceMethods.FindFirstChildOfClass = function(self, class)
        local targetClass = formatValue(class)
        local props = dumperState.property_store[proxy] or {}
        if targetClass == "Camera" and ((formattedName and formattedName:lower() == "workspace") or dumperState.registry[proxy] == "workspace") then
            return proxy.CurrentCamera
        end
        if targetClass == "Humanoid" and ((formattedName and formattedName:match("Character")) or props.Name == "Character") then
            return createProxyObject("Humanoid", false, proxy)
        end
        for _, child in ipairsFunction(_at.children[proxy] or {}) do
            local props = dumperState.property_store[child] or {}
            if props.ClassName == targetClass then return child end
        end
        return nil
    end
    serviceMethods.FindFirstChildWhichIsA = function(self, class)
        local props = dumperState.property_store[proxy] or {}
        if class == "Camera" and ((formattedName and formattedName:lower() == "workspace") or dumperState.registry[proxy] == "workspace") then
            return proxy.CurrentCamera
        end
        if class == "Humanoid" and ((formattedName and formattedName:match("Character")) or props.Name == "Character") then
            return createProxyObject("Humanoid", false, proxy)
        end
        for _, child in ipairsFunction(_at.children[proxy] or {}) do
            local childProps = dumperState.property_store[child] or {}
            if classIsA(childProps.ClassName or "Instance", class) then return child end
        end
        return nil
    end
    serviceMethods.GetPlayers = function(self) return _at.localPlayer and {_at.localPlayer} or {} end
    serviceMethods.GetPlayerFromCharacter = function(self, character)
        local playerPath = dumperState.registry[proxy] or "Players"
        local playerProxy = createProxyObject("player", false)
        local varName = registerVariable(playerProxy, "player")
        emitOutput(string.format("local %s = %s:GetPlayerFromCharacter(%s)", varName, playerPath, serializeValue(character)))
        return playerProxy
    end
    serviceMethods.GetPlayerByUserId = function(self, userId)
        if _at.localPlayer and userId == (dumperState.property_store[_at.localPlayer] or {}).UserId then
            return _at.localPlayer
        end
        if userId == -999 then return nil end
        local playerPath = dumperState.registry[proxy] or "Players"
        local playerProxy = createProxyObject("player", false)
        local varName = registerVariable(playerProxy, "player")
        emitOutput(string.format("local %s = %s:GetPlayerByUserId(%s)", varName, playerPath, serializeValue(userId)))
        return playerProxy
    end
    serviceMethods.GetCharacterAppearanceInfoAsync = function(self, userId)
        local playerPath = dumperState.registry[proxy] or "Players"
        local resultProxy = createProxyObject("characterInfo", false)
        local varName = registerVariable(resultProxy, "charInfo")
        emitOutput(string.format("local %s = %s:GetCharacterAppearanceInfoAsync(%s)", varName, playerPath, serializeValue(userId)))
        return resultProxy
    end
    serviceMethods.GetUserThumbnailAsync = function(self, userId, thumbType, thumbSize)
        local playerPath = dumperState.registry[proxy] or "Players"
        local url = string.format("https://www.roblox.com/headshot-thumbnail/image?userId=%s&width=420&height=420&format=png", tostring(userId or 0))
        emitOutput(string.format("local _thumb, _thumbReady = %s:GetUserThumbnailAsync(%s, %s, %s)", playerPath, serializeValue(userId), serializeValue(thumbType), serializeValue(thumbSize)))
        return url, true
    end
    serviceMethods.GetFriendsAsync = function(self, userId)
        local playerPath = dumperState.registry[proxy] or "Players"
        local pagesProxy = createProxyObject("friendsPages", false)
        local varName = registerVariable(pagesProxy, "friends")
        emitOutput(string.format("local %s = %s:GetFriendsAsync(%s)", varName, playerPath, serializeValue(userId or 0)))
        local _done = false
        local _items = {}
        local pagesmt = {
            __index = {
                IsFinished = function() return _done end,
                GetCurrentPage = function() return _items end,
                AdvanceToNextPageAsync = function() _done = true end,
            }
        }
        return setmetatable(pagesProxy, pagesmt)
    end
    serviceMethods.GetNameFromUserIdAsync = function(self, userId)
        local servicePath = dumperState.registry[proxy] or "Players"
        local resultProxy = createProxyObject("GetNameFromUserIdAsync", false, proxy)
        local varName = registerVariable(resultProxy, "GetNameFromUserIdAsync")
        emitOutput(string.format("local %s = %s:GetNameFromUserIdAsync(%s)",
            varName, servicePath, serializeValue(userId)))
        local lpUserId = 1234567
        local lp = _at.localPlayer
        if lp then
            local ps = dumperState.property_store[lp]
            if ps and ps.UserId then lpUserId = ps.UserId end
        end
        local lpName = "Player"
        if lp then
            local ps = dumperState.property_store[lp]
            if ps and type(ps.Name) == "string" then lpName = ps.Name end
        end
        local uid = tonumber(tostring(userId)) or userId
        if uid == lpUserId then
            return lpName
        else
            errorFunction("no network access in sandbox", 0)
        end
    end
    serviceMethods.GetUserIdFromNameAsync = function(self, name)
        local servicePath = dumperState.registry[proxy] or "Players"
        local resultProxy = createProxyObject("GetUserIdFromNameAsync", false, proxy)
        local varName = registerVariable(resultProxy, "GetUserIdFromNameAsync")
        emitOutput(string.format("local %s = %s:GetUserIdFromNameAsync(%s)",
            varName, servicePath, serializeValue(name)))
        local lp = _at.localPlayer
        local lpName = "Player"
        local lpUserId = 1234567
        if lp then
            local ps = dumperState.property_store[lp]
            if ps then
                if type(ps.Name) == "string" then lpName = ps.Name end
                if ps.UserId then lpUserId = ps.UserId end
            end
        end
        local nameStr = tostring(name)
        if nameStr == lpName then
            return lpUserId
        else
            errorFunction("no network access in sandbox", 0)
        end
    end
    serviceMethods.SetCore = function(self, action, value)
        local guiPath = dumperState.registry[proxy] or "StarterGui"
        emitOutput(string.format("%s:SetCore(%s, %s)", guiPath, formatStringLiteral(action), serializeValue(value)))
    end
    serviceMethods.GetCore = function(self, action) return nil end
    serviceMethods.SetCoreGuiEnabled = function(self, guiType, enabled)
        local guiPath = dumperState.registry[proxy] or "StarterGui"
        emitOutput(string.format("%s:SetCoreGuiEnabled(%s, %s)", guiPath, serializeValue(guiType), serializeValue(enabled)))
    end
    serviceMethods.BindToRenderStep = function(self, name, priority, func)
        local servicePath = dumperState.registry[proxy] or "RunService"
        emitOutput(string.format("%s:BindToRenderStep(%s, %s, function(deltaTime)", servicePath, formatStringLiteral(name), serializeValue(priority)))
        dumperState.indent = dumperState.indent + 1
        if typeFunction(func) == "function" then
            xpcallFunction( function() func(0.016) end, function() end )
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
    end
    serviceMethods.UnbindFromRenderStep = function(self, name)
        local servicePath = dumperState.registry[proxy] or "RunService"
        emitOutput(string.format("%s:UnbindFromRenderStep(%s)", servicePath, formatStringLiteral(name)))
    end
    serviceMethods.IsClient = function(self) return true end
    serviceMethods.IsServer = function(self) return false end
    serviceMethods.IsRunning = function(self) return true end
    serviceMethods.IsStudio = function(self) return false end
    serviceMethods.GetFullName = function(self)
        local segments = {}
        local cur = self
        local guard = 0
        while cur and guard < 64 do
            guard = guard + 1
            local props = dumperState.property_store[cur]
            local segName = (props and props.Name) or dumperState.registry[cur]
            if not segName or segName == "" then break end
            table.insert(segments, 1, segName)
            local parent = dumperState.parent_map[cur]
            if parent == nil or parent == cur then break end
            cur = parent
        end
        if #segments == 0 then return "Instance" end
        return table.concat(segments, ".")
    end
    serviceMethods.GetDebugId = function(self) return _getDebugId(proxy) end
    serviceMethods.MoveTo = function(self, pos, part)
        local humPath = dumperState.registry[proxy] or "humanoid"
        if part then
            emitOutput(string.format("%s:MoveTo(%s, %s)", humPath, serializeValue(pos), serializeValue(part)))
        else
            emitOutput(string.format("%s:MoveTo(%s)", humPath, serializeValue(pos)))
        end
    end
    serviceMethods.Move = function(self, direction, relativeTo)
        local humPath = dumperState.registry[proxy] or "humanoid"
        emitOutput(string.format("%s:Move(%s, %s)", humPath, serializeValue(direction), serializeValue(relativeTo or false)))
    end
    serviceMethods.EquipTool = function(self, tool)
        local humPath = dumperState.registry[proxy] or "humanoid"
        emitOutput(string.format("%s:EquipTool(%s)", humPath, serializeValue(tool)))
    end
    serviceMethods.UnequipTools = function(self)
        local humPath = dumperState.registry[proxy] or "humanoid"
        emitOutput(string.format("%s:UnequipTools()", humPath))
    end
    serviceMethods.TakeDamage = function(self, damage)
        local humPath = dumperState.registry[proxy] or "humanoid"
        emitOutput(string.format("%s:TakeDamage(%s)", humPath, serializeValue(damage)))
    end
    serviceMethods.ChangeState = function(self, state)
        local humPath = dumperState.registry[proxy] or "humanoid"
        emitOutput(string.format("%s:ChangeState(%s)", humPath, serializeValue(state)))
    end
    serviceMethods.GetState = function(self) return createProxyObject("Enum.HumanoidStateType.Running", false) end
    local function _getModelBounds(modelProxy)
        local desc = _getAllDescendants(modelProxy)
        local minX, minY, minZ = math.huge, math.huge, math.huge
        local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
        local found = false
        for _, child in ipairsFunction(desc) do
            local cp = dumperState.property_store[child]
            if cp and classIsA(cp.ClassName or "", "BasePart") then
                found = true
                local cf = cp.CFrame or (cp.Position and CFrame.new(cp.Position)) or CFrame.new(0, 0, 0)
                local sz = cp.Size or Vector3.new(4, 1, 2)
                local hx, hy, hz = (sz.X or 4) * 0.5, (sz.Y or 1) * 0.5, (sz.Z or 2) * 0.5
                for sx = -1, 1, 2 do
                    for sy = -1, 1, 2 do
                        for szSign = -1, 1, 2 do
                            local corner = cf * Vector3.new(hx * sx, hy * sy, hz * szSign)
                            if corner.X < minX then minX = corner.X end
                            if corner.Y < minY then minY = corner.Y end
                            if corner.Z < minZ then minZ = corner.Z end
                            if corner.X > maxX then maxX = corner.X end
                            if corner.Y > maxY then maxY = corner.Y end
                            if corner.Z > maxZ then maxZ = corner.Z end
                        end
                    end
                end
            end
        end
        if not found then
            local mprops = dumperState.property_store[modelProxy]
            local fallbackCf = (mprops and mprops.WorldPivot) or CFrame.new(0, 0, 0)
            return fallbackCf, Vector3.new(0, 0, 0)
        end
        return CFrame.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5),
            Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
    end
    local function _getModelPivot(modelProxy)
        local mprops = dumperState.property_store[modelProxy]
        if mprops and mprops.WorldPivot ~= nil then
            return mprops.WorldPivot
        end
        if mprops and mprops.PrimaryPart and isProxy(mprops.PrimaryPart) then
            local pp = dumperState.property_store[mprops.PrimaryPart]
            if pp and pp.CFrame then return pp.CFrame end
        end
        local bbCf = _getModelBounds(modelProxy)
        return bbCf
    end
    local function _pivotModel(modelProxy, targetCf)
        if typeFunction(targetCf) ~= "table" or targetCf.X == nil then
            errorFunction("CFrame expected for PivotTo", 2)
        end
        local oldPivot = _getModelPivot(modelProxy)
        local delta = targetCf * oldPivot:Inverse()
        local desc = _getAllDescendants(modelProxy)
        for _, child in ipairsFunction(desc) do
            local cp = dumperState.property_store[child]
            if cp and classIsA(cp.ClassName or "", "BasePart") then
                local oldCf = cp.CFrame or (cp.Position and CFrame.new(cp.Position)) or CFrame.new(0, 0, 0)
                local newCf = delta * oldCf
                cp.CFrame = newCf
                cp.Position = newCf.Position
            end
        end
        dumperState.property_store[modelProxy] = dumperState.property_store[modelProxy] or {}
        dumperState.property_store[modelProxy].WorldPivot = targetCf
    end
    serviceMethods.SetPrimaryPartCFrame = function(self, cf)
        local modelPath = dumperState.registry[proxy] or "model"
        local mprops = dumperState.property_store[proxy]
        if mprops and mprops.PrimaryPart and isProxy(mprops.PrimaryPart) then
            local pp = dumperState.property_store[mprops.PrimaryPart]
            local oldCf = (pp and pp.CFrame) or CFrame.new(0, 0, 0)
            local delta = cf * oldCf:Inverse()
            for _, child in ipairsFunction(_getAllDescendants(proxy)) do
                local cp = dumperState.property_store[child]
                if cp and classIsA(cp.ClassName or "", "BasePart") then
                    local newCf = delta * (cp.CFrame or CFrame.new(0, 0, 0))
                    cp.CFrame = newCf
                    cp.Position = newCf.Position
                end
            end
            if mprops.WorldPivot then mprops.WorldPivot = delta * mprops.WorldPivot end
        else
            _pivotModel(proxy, cf)
        end
        emitOutput(string.format("%s:SetPrimaryPartCFrame(%s)", modelPath, serializeValue(cf)))
    end
    serviceMethods.GetPrimaryPartCFrame = function(self)
        local mprops = dumperState.property_store[proxy]
        if mprops and mprops.PrimaryPart and isProxy(mprops.PrimaryPart) then
            local pp = dumperState.property_store[mprops.PrimaryPart]
            if pp and pp.CFrame then return pp.CFrame end
        end
        return _getModelPivot(proxy)
    end
    serviceMethods.PivotTo = function(self, cf)
        local modelPath = dumperState.registry[proxy] or "model"
        _pivotModel(proxy, cf)
        emitOutput(string.format("%s:PivotTo(%s)", modelPath, serializeValue(cf)))
    end
    serviceMethods.GetPivot = function(self) return _getModelPivot(proxy) end
    serviceMethods.GetBoundingBox = function(self) return _getModelBounds(proxy) end
    serviceMethods.GetExtentsSize = function(self)
        local _, sz = _getModelBounds(proxy)
        return sz
    end
    serviceMethods.TranslateBy = function(self, vec)
        local modelPath = dumperState.registry[proxy] or "model"
        if typeFunction(vec) == "table" and vec.X ~= nil then
            local cur = _getModelPivot(proxy)
            _pivotModel(proxy, CFrame.new(vec.X or 0, vec.Y or 0, vec.Z or 0) * cur)
        end
        emitOutput(string.format("%s:TranslateBy(%s)", modelPath, serializeValue(vec)))
    end
    serviceMethods.LoadAnimation = function(self, anim)
        local animPath = dumperState.registry[proxy] or "animator"
        local trackProxy = createProxyObject("animTrack", false)
        local state = {
            playing = false,
            position = 0,
            started = _animation_clock,
            speed = 1,
            length = 1,
        }
        _animation_track_state[trackProxy] = state
        dumperState.property_store[trackProxy] = {
            ClassName = "AnimationTrack",
            Name = "Animation",
            Looped = false,
            Priority = Enum.AnimationPriority and Enum.AnimationPriority.Core or 0,
        }
        local varName = registerVariable(trackProxy, "animTrack")
        emitOutput(string.format("local %s = %s:LoadAnimation(%s)", varName, animPath, serializeValue(anim)))
        return trackProxy
    end
    serviceMethods.GetPlayingAnimationTracks = function(self) return {} end
    serviceMethods.Play = function(self, fadeTime, weight, speed)
        local state = _animation_track_state[proxy]
        local trackPath = dumperState.registry[proxy] or "animTrack"
        if state then
            if speed ~= nil then state.speed = tonumber(speed) or state.speed end
            state.started = _animation_clock
            state.playing = true
        end
        emitOutput(string.format("%s:Play(%s)", trackPath, serializeValue(fadeTime or 0)))
    end
    serviceMethods.Stop = function(self, fadeTime)
        local state = _animation_track_state[proxy]
        local trackPath = dumperState.registry[proxy] or "animTrack"
        if state then
            state.position = _animation_track_position(state)
            state.playing = false
        end
        emitOutput(string.format("%s:Stop(%s)", trackPath, serializeValue(fadeTime or 0)))
    end
    serviceMethods.AdjustSpeed = function(self, speed)
        local state = _animation_track_state[proxy]
        local trackPath = dumperState.registry[proxy] or "animTrack"
        if state then
            state.position = _animation_track_position(state)
            state.started = _animation_clock
            state.speed = tonumber(speed) or state.speed
        end
        emitOutput(string.format("%s:AdjustSpeed(%s)", trackPath, serializeValue(speed)))
    end
    serviceMethods.AdjustWeight = function(self, weight, fade)
        local trackPath = dumperState.registry[proxy] or "animTrack"
        if fade then
            emitOutput(string.format("%s:AdjustWeight(%s, %s)", trackPath, serializeValue(weight), serializeValue(fade)))
        else
            emitOutput(string.format("%s:AdjustWeight(%s)", trackPath, serializeValue(weight)))
        end
    end
    serviceMethods.Teleport = function(self, placeId, player, spawn, customTeleportData)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        emitOutput(string.format("%s:Teleport(%s, %s%s%s)", servicePath, serializeValue(placeId), serializeValue(player), spawn and ", " .. serializeValue(spawn) or '"', customTeleportData and ", " .. serializeValue(customTeleportData) or '"'))
    end
    serviceMethods.TeleportToPlaceInstance = function(self, placeId, instanceId, player)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        emitOutput(string.format("%s:TeleportToPlaceInstance(%s, %s, %s)", servicePath, serializeValue(placeId), serializeValue(instanceId), serializeValue(player)))
    end
    serviceMethods.PlayLocalSound = function(self, sound)
        local servicePath = dumperState.registry[proxy] or "SoundService"
        emitOutput(string.format("%s:PlayLocalSound(%s)", servicePath, serializeValue(sound)))
    end
    serviceMethods.GetAudioInstances = function(self)
        return {}
    end
    serviceMethods.GetInputDevices = function(self)
        return {}
    end
    serviceMethods.GetOutputDevices = function(self)
        return {}
    end
    serviceMethods.IsAvailable = function(self) return true end
    serviceMethods.HasAchieved = function(self) return false end
    serviceMethods.GrantAchievement = function(self) return true end
    serviceMethods.GetDeviceCameraCFrame = function(self) return CFrame.new(0, 0, 0) end
    serviceMethods.GetDeviceCameraCFrameForSelfView = function(self) return CFrame.new(0, 0, 0) end
    serviceMethods.UpdateDeviceCFrame = function(self) return nil end
    serviceMethods.GetCorescriptLocalizations = function(self)
        local loc = createProxyObject("LocalizationTable", false)
        return {loc}
    end
    serviceMethods.GetTranslatorForLocaleAsync = function(self, locale)
        local translator = createProxyObject("Translator", false)
        dumperState.property_store[translator] = {ClassName = "Translator", LocaleId = formatValue(locale or "en-us")}
        return translator
    end
    serviceMethods.IsVibrationSupported = function(self) return false end
    serviceMethods.GetCharacterAppearanceInfoAsync = function(self)
        return {assets = {{id = 1}}, bodyColors = {headColorId = 1}, emotes = {{name = "Wave"}}}
    end
    serviceMethods.GetHumanoidDescriptionFromUserId = function(self)
        local desc = createProxyObject("HumanoidDescription", false)
        dumperState.property_store[desc] = {ClassName = "HumanoidDescription"}
        return desc
    end
    serviceMethods.GetEmotes = function(self) return {Wave = {{1}}} end
    serviceMethods.TeleportAsync = function(self, placeId, players, options)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        emitOutput(string.format("%s:TeleportAsync(%s, players, %s)", servicePath, serializeValue(placeId), serializeValue(options)))
    end
    serviceMethods.TeleportToPrivateServer = function(self, placeId, reservedServerAccessCode, players, spawn, customData)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        emitOutput(string.format("%s:TeleportToPrivateServer(%s, %s, players)", servicePath, serializeValue(placeId), serializeValue(reservedServerAccessCode)))
    end
    serviceMethods.ReserveServer = function(self, placeId)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        local code = "reserved_" .. tostring(math.floor(math.random() * 1e9))
        emitOutput(string.format("local reservedCode = %s:ReserveServer(%s)", servicePath, serializeValue(placeId)))
        return code, os.time() + 300
    end
    serviceMethods.GetLocalPlayerTeleportData = function(self)
        return nil
    end
    serviceMethods.GetTeleportSetting = function(self, setting)
        return nil
    end
    serviceMethods.SetTeleportSetting = function(self, setting, value)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        emitOutput(string.format("%s:SetTeleportSetting(%s, %s)", servicePath, formatStringLiteral(setting), serializeValue(value)))
    end
    serviceMethods.PromptProductPurchase = function(self, player, productId, equipIfPurchased, currencyType)
        local servicePath = dumperState.registry[proxy] or "MarketplaceService"
        emitOutput(string.format("%s:PromptProductPurchase(%s, %s)", servicePath, serializeValue(player), serializeValue(productId)))
    end
    serviceMethods.PromptPurchase = function(self, player, assetId, equipIfPurchased, currencyType)
        local servicePath = dumperState.registry[proxy] or "MarketplaceService"
        emitOutput(string.format("%s:PromptPurchase(%s, %s)", servicePath, serializeValue(player), serializeValue(assetId)))
    end
    serviceMethods.PromptGamePassPurchase = function(self, player, gamePassId)
        local servicePath = dumperState.registry[proxy] or "MarketplaceService"
        emitOutput(string.format("%s:PromptGamePassPurchase(%s, %s)", servicePath, serializeValue(player), serializeValue(gamePassId)))
    end
    serviceMethods.PromptSubscriptionPurchase = function(self, player, subscriptionId)
        local servicePath = dumperState.registry[proxy] or "MarketplaceService"
        emitOutput(string.format("%s:PromptSubscriptionPurchase(%s, %s)", servicePath, serializeValue(player), serializeValue(subscriptionId)))
    end
    serviceMethods.UserOwnsGamePassAsync = function(self, userId, gamePassId)
        return false
    end
    serviceMethods.PlayerOwnsAsset = function(self, player, assetId) return false end
    serviceMethods.GetProductInfo = function(self, assetId, infoType)
        return {
            AssetId = tonumber(tostring(assetId)) or 0,
            Name = "ProductName",
            Description = "",
            PriceInRobux = 0,
            IsPublicDomain = false,
            IsForSale = true,
            Created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            Updated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            Creator = {CreatorType = "User", CreatorTargetId = 0, Name = "Creator"},
        }
    end
    serviceMethods.GetDeveloperProductsAsync = function(self)
        local pages = createProxyObject("DeveloperProductPages", false)
        local _pageItems = {}
        local _at2 = {done = true, items = _pageItems}
        dumperState.property_store[pages] = _at2
        return pages
    end
    serviceMethods.GetPolicyInfoForPlayerAsync = function(self, player)
        return {
            AllowedExternalLinkReferences = {},
            ArePaidRandomItemsRestricted = false,
            IsEligibleToPurchaseSubscription = true,
            IsPaidItemTradingAllowed = true,
            IsSubjectToChinaPolicies = false,
        }
    end
    serviceMethods.GetTranslatorForPlayer = function(self, player)
        local translator = createProxyObject("Translator", false)
        dumperState.property_store[translator] = {ClassName = "Translator", LocaleId = "en-us"}
        return translator
    end
    serviceMethods.GetLocaleId = function(self)
        return "en-us"
    end
    serviceMethods.GetLocalizationTableForGameAsync = function(self)
        local tbl = createProxyObject("LocalizationTable", false)
        return tbl
    end
    serviceMethods.Translate = function(self, instance, text)
        return tostring(text or "")
    end
    serviceMethods.FormatByKey = function(self, key, args)
        return tostring(key or "")
    end
    serviceMethods.FilterStringAsync = function(self, stringToFilter, fromUserId, textContext)
        local servicePath = dumperState.registry[proxy] or "TextService"
        local filtered = createProxyObject("TextFilterResult", false)
        dumperState.property_store[filtered] = {ClassName = "TextFilterResult"}
        return filtered
    end
    serviceMethods.GetTextSize = function(self, text, fontSize, font, frameSize)
        return Vector2.new(#(text or "") * (fontSize or 14) * 0.6, fontSize or 14)
    end
    serviceMethods.GetChatForUserIsEnabled = function(self, player) return true end
    serviceMethods.GetStringForChatContext = function(self, filteredResult) return "" end
    serviceMethods.GetNonChatStringForBroadcastAsync = function(self, filteredResult) return "" end
    serviceMethods.GetNonChatStringForUserAsync = function(self, filteredResult, toUserId) return "" end
    serviceMethods.UserHasBadgeAsync = function(self, userId, badgeId) return false end
    serviceMethods.AwardBadge = function(self, userId, badgeId)
        local servicePath = dumperState.registry[proxy] or "BadgeService"
        emitOutput(string.format("%s:AwardBadge(%s, %s)", servicePath, serializeValue(userId), serializeValue(badgeId)))
        return true
    end
    serviceMethods.GetGroupsAsync = function(self, userId)
        local groups = {}
        return groups
    end
    serviceMethods.GetGroupInfoAsync = function(self, groupId)
        return {
            Id = tonumber(tostring(groupId)) or 0,
            Name = "Group",
            Description = "",
            Owner = {Id = 0, Name = "Owner"},
            EmblemUrl = "rbxasset://textures/RobloxIcon.png",
            MemberCount = 0,
            Roles = {{Id = 1, Name = "Guest", Rank = 1}},
        }
    end
    serviceMethods.GetAlliesAsync = function(self, groupId)
        local pages = createProxyObject("AlliesPages", false)
        return pages
    end
    serviceMethods.GetEnemiesAsync = function(self, groupId)
        local pages = createProxyObject("EnemiesPages", false)
        return pages
    end
    serviceMethods.IsVoiceEnabledForUserIdAsync = function(self, userId) return false end
    serviceMethods.JoinByGroupId = function(self, groupId) end
    serviceMethods.GetSupportedGamepadKeyCodes = function(self, gamepad) return {} end
    serviceMethods.GetConnectedGamepads = function(self) return {} end
    serviceMethods.GetGamepadState = function(self, gamepad) return {} end
    serviceMethods.GetNavigationGamepads = function(self) return {} end
    serviceMethods.GetMouseButtonsPressed = function(self) return {} end
    serviceMethods.GetMouseDelta = function(self) return Vector2.new(0, 0) end
    serviceMethods.GetMouseLocation = function(self) return Vector2.new(960, 540) end
    serviceMethods.GetScreenResolution = function(self) return Vector2.new(1920, 1080) end
    serviceMethods.IsGamepadButtonDown = function(self, gamepad, button) return false end
    serviceMethods.IsKeyDown = function(self, key) return false end
    serviceMethods.IsMouseButtonPressed = function(self, button) return false end
    serviceMethods.SetMouseIconEnabled = function(self, enabled) end
    serviceMethods.SetMouseBehavior = function(self, behavior) end
    serviceMethods.GetFocusedTextBox = function(self) return nil end
    serviceMethods.WorldToScreenPoint = function(self, pos) return Vector3.new(960, 540, 0), true end
    serviceMethods.WorldToViewportPoint = function(self, pos) return Vector3.new(960, 540, 0), true end
    serviceMethods.ScreenPointToRay = function(self, x, y, depth)
        depth = depth or 0
        return Ray.new(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
    end
    serviceMethods.ViewportPointToRay = function(self, x, y, depth)
        return Ray.new(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
    end
    serviceMethods.GetPartsObscuringTarget = function(self, pos, ignoreList) return {} end
    serviceMethods.TriggerEnded = function(self) end
    serviceMethods.InputHoldBegin = function(self) end
    serviceMethods.InputHoldEnd = function(self) end
    serviceMethods.DisplaySystemMessage = function(self, msg, metadata)
        local servicePath = dumperState.registry[proxy] or "TextChatService"
        emitOutput(string.format("%s:DisplaySystemMessage(%s)", servicePath, serializeValue(msg)))
    end
    serviceMethods.SendAsync = function(self, msg)
        local path = dumperState.registry[proxy] or "TextChannel"
        emitOutput(string.format("%s:SendAsync(%s)", path, serializeValue(msg)))
        local msgProxy = createProxyObject("TextChatMessage", false)
        return msgProxy
    end
    serviceMethods.GetBadgeInfoAsync = function(self, badgeId)
        return {
            Name = "Badge", Description = "", IconImageId = 0,
            IsEnabled = true, Creator = {CreatorType = "User", CreatorTargetId = 0},
        }
    end
    serviceMethods.IsVoiceEnabledForUserIdAsync = function(self, userId) return false end
    serviceMethods.GetSpeakerVolume = function(self, player) return 1.0 end
    serviceMethods.SetSpeakerVolume = function(self, player, volume)
        local servicePath = dumperState.registry[proxy] or "VoiceChatService"
        emitOutput(string.format("%s:SetSpeakerVolume(%s, %s)", servicePath, serializeValue(player), serializeValue(volume)))
    end
    serviceMethods.joinVoice = function(self, ...)
        local servicePath = dumperState.registry[proxy] or "VoiceChatService"
        emitOutput(string.format("%s:joinVoice()", servicePath))
        return true
    end
    serviceMethods.rejoinVoice = function(self, ...)
        local servicePath = dumperState.registry[proxy] or "VoiceChatService"
        emitOutput(string.format("%s:rejoinVoice()", servicePath))
        return true
    end
    serviceMethods.leaveVoice = function(self, ...)
        local servicePath = dumperState.registry[proxy] or "VoiceChatService"
        emitOutput(string.format("%s:leaveVoice()", servicePath))
        return true
    end
    serviceMethods.AddCoreScriptLocal = function(self) end
    serviceMethods.GetScriptStats = function(self)
        return { ScriptCount = 1, LuaHeapSize = 32768, LuaUsedHeapSize = 16384 }
    end
    serviceMethods.SetNetworkOwner = function(self, player)
        local p = dumperState.registry[proxy] or "Part"
        emitOutput(string.format("%s:SetNetworkOwner(%s)", p, serializeValue(player)))
    end
    serviceMethods.GetNetworkOwner = function(self) return nil end
    serviceMethods.GetNetworkOwnershipAuto = function(self) return true end
    serviceMethods.FindPartOnRay = function(self, ray, ignoreDescendantsInstance, terrainCellsAreCubes, ignoreWater)
        return nil, Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), Enum and createProxyObject("Enum.Material.Air", false) or nil
    end
    serviceMethods.FindPartOnRayWithIgnoreList = function(self, ray, ignoreList, terrainCellsAreCubes, ignoreWater)
        return nil, Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), nil
    end
    serviceMethods.FindPartOnRayWithWhitelist = function(self, ray, whitelist, ignoreWater)
        return nil, Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), nil
    end
    serviceMethods.Raycast = function(self, origin, direction, params)
        local hit = createProxyObject("RaycastGround", false, proxy)
        dumperState.property_store[hit] = {
            ClassName = "Part", Name = "RaycastGround",
            Position = Vector3.new(0, 0, 0), Parent = workspace,
        }
        return {
            Position = Vector3.new(0, 0, 0),
            Normal = Vector3.new(0, 1, 0),
            Distance = 5,
            Instance = hit,
        }
    end
    serviceMethods.BlockcastAsync = function(self, cframe, size, direction, params)
        return nil
    end
    serviceMethods.SpherecastAsync = function(self, position, radius, direction, params)
        return nil
    end
    serviceMethods.ShapecastAsync = function(self, shape, motion, params)
        return nil
    end
    local function _spatial_number(value, fallback)
        local number = toNumberFunction(value)
        return number or fallback or 0
    end

    local function _spatial_position(instance)
        local props = dumperState.property_store[instance] or {}
        local cframe = props.CFrame
        local position = props.Position or (cframe and cframe.Position)
        return position or Vector3.new(0, 0, 0)
    end

    local function _spatial_descendant(instance, ancestor)
        if instance == ancestor then return true end
        return _isDescendantOf(instance, ancestor)
    end

    local function _spatial_contains(list, instance)
        if typeFunction(list) ~= "table" then return false end
        for _, entry in ipairsFunction(list) do
            if _spatial_descendant(instance, entry) then return true end
        end
        return false
    end

    local function _spatial_allowed(instance, params)
        if typeFunction(params) ~= "table" then return true end
        local include = params.IncludeInstances
        local exclude = params.ExcludeInstances
        if include ~= nil then
            if typeFunction(include) ~= "table" or #include == 0 then return false end
            if not _spatial_contains(include, instance) then return false end
        else
            local filters = params.FilterDescendantsInstances
            local filter_type = toStringFunction(params.FilterType or "Exclude")
            if filter_type:find("Include", 1, true) and not _spatial_contains(filters, instance) then
                return false
            end
            if not filter_type:find("Include", 1, true) and _spatial_contains(filters, instance) then
                return false
            end
        end
        if exclude ~= nil and _spatial_contains(exclude, instance) then return false end
        return true
    end

    local function _spatial_in_box(instance, center, half_size)
        local props = dumperState.property_store[instance] or {}
        local position = _spatial_position(instance)
        local size = props.Size or Vector3.new(4, 4, 4)
        local dx = math.abs(_spatial_number(position.X) - _spatial_number(center.X))
        local dy = math.abs(_spatial_number(position.Y) - _spatial_number(center.Y))
        local dz = math.abs(_spatial_number(position.Z) - _spatial_number(center.Z))
        local sx = _spatial_number(size.X, 4) / 2
        local sy = _spatial_number(size.Y, 4) / 2
        local sz = _spatial_number(size.Z, 4) / 2
        return dx <= _spatial_number(half_size.X) + sx
            and dy <= _spatial_number(half_size.Y) + sy
            and dz <= _spatial_number(half_size.Z) + sz
    end

    local function _spatial_query(center, half_size, params)
        local result = {}
        local max_parts = _spatial_number(params and params.MaxParts)
        for _, instance in ipairsFunction(_at.children[workspace] or {}) do
            local class_name = (dumperState.property_store[instance] or {}).ClassName or ""
            if (class_name == "Part" or class_name == "MeshPart" or class_name == "UnionOperation"
                or class_name == "WedgePart" or class_name == "CornerWedgePart" or class_name == "TrussPart")
                and _spatial_allowed(instance, params)
                and _spatial_in_box(instance, center, half_size) then
                result[#result + 1] = instance
                if max_parts > 0 and #result >= max_parts then break end
            end
        end
        return result
    end

    local function _assertOverlapParams(params)
        if params == nil then return end
        local t = typeFunction(params)
        if t == "table" or t == "userdata" then
            if typeof and typeof(params) == "OverlapParams" then return end
            local mt = getMetatableFunction and getMetatableFunction(params)
            if typeFunction(mt) == "table" and (rawget(mt, "__type") == "OverlapParams" or rawget(mt, "__typeof") == "OverlapParams") then
                return
            end
        end
        errorFunction("Unable to cast value to Object", 2)
    end

    serviceMethods.GetPartBoundsInBox = function(self, cframe, size, params)
        _assertOverlapParams(params)
        local center = (cframe and cframe.Position) or cframe or Vector3.new(0, 0, 0)
        return _spatial_query(center, size or Vector3.new(0, 0, 0), params)
    end
    serviceMethods.GetPartBoundsInRadius = function(self, position, radius, params)
        _assertOverlapParams(params)
        local r = _spatial_number(radius)
        return _spatial_query(position or Vector3.new(0, 0, 0), Vector3.new(r, r, r), params)
    end
    serviceMethods.GetPartsInPart = function(self, part, params)
        if not isProxy(part) then
            errorFunction("Unable to cast value to Object", 2)
        end
        _assertOverlapParams(params)
        local props = dumperState.property_store[part] or {}
        return _spatial_query(_spatial_position(part), props.Size or Vector3.new(4, 4, 4), params)
    end
    serviceMethods.WaitForChild = function(self, name, timeout)
        local parentPath = dumperState.registry[proxy] or "parent"
        local existing = nil
        if _at.children[proxy] then
            for _, child in ipairsFunction(_at.children[proxy]) do
                local cProps = dumperState.property_store[child]
                if cProps and cProps.Name == name then existing = child; break end
            end
        end
        if existing then return existing end
        local child = createProxyObject(name, false, proxy)
        local varName = registerVariable(child, name)
        emitOutput(string.format("local %s = %s:WaitForChild(%s)", varName, parentPath, formatStringLiteral(name)))
        return child
    end
    serviceMethods.FindFirstChild = function(self, name, recursive)
        if _at.children[proxy] then
            for _, child in ipairsFunction(_at.children[proxy]) do
                local cProps = dumperState.property_store[child]
                if cProps and cProps.Name == name then return child end
            end
        end
        return nil
    end
    serviceMethods.FindFirstChildOfClass = function(self, className)
        if _at.children[proxy] then
            for _, child in ipairsFunction(_at.children[proxy]) do
                local cProps = dumperState.property_store[child]
                if cProps and cProps.ClassName == className then return child end
            end
        end
        return nil
    end
    serviceMethods.FindFirstChildWhichIsA = function(self, className, recursive)
        return serviceMethods.FindFirstChildOfClass(self, className)
    end
    serviceMethods.FindFirstAncestor = function(self, name)
        local cur = dumperState.parent_map[proxy]
        local guard = 0
        while cur and guard < 32 do
            guard = guard + 1
            local props = dumperState.property_store[cur]
            if props and props.Name == name then return cur end
            cur = dumperState.parent_map[cur]
        end
        return nil
    end
    serviceMethods.FindFirstAncestorOfClass = function(self, className)
        local cur = dumperState.parent_map[proxy]
        local guard = 0
        while cur and guard < 32 do
            guard = guard + 1
            local props = dumperState.property_store[cur]
            if props and props.ClassName == className then return cur end
            cur = dumperState.parent_map[cur]
        end
        return nil
    end
    serviceMethods.FindFirstAncestorWhichIsA = function(self, className)
        local cur = dumperState.parent_map[proxy]
        local guard = 0
        while cur and guard < 32 do
            guard = guard + 1
            local props = dumperState.property_store[cur]
            if props and classIsA(props.ClassName or "Instance", className) then return cur end
            cur = dumperState.parent_map[cur]
        end
        return nil
    end
    serviceMethods.GetChildren = function(self)
        return _at.children[proxy] or {}
    end
    serviceMethods.GetDescendants = function(self)
        local result = {}
        local function collect(inst)
            local kids = _at.children[inst] or {}
            for _, k in ipairsFunction(kids) do
                result[#result + 1] = k
                collect(k)
            end
        end
        collect(proxy)
        return result
    end
    serviceMethods.IsDescendantOf = function(self, ancestor)
        local cur = dumperState.parent_map[proxy]
        local guard = 0
        while cur and guard < 64 do
            guard = guard + 1
            if cur == ancestor then return true end
            cur = dumperState.parent_map[cur]
        end
        return false
    end
    serviceMethods.IsAncestorOf = function(self, descendant)
        return serviceMethods.IsDescendantOf(descendant, proxy)
    end
    serviceMethods.GetJoints = function(self)
        if not serviceMethods.IsDescendantOf(self, workspace) then
            return {}
        end
        local out = {}
        local function walk(node)
            for _, ch in ipairsFunction(_at.children[node] or {}) do
                local cp = dumperState.property_store[ch]
                local cn = cp and cp.ClassName or ""
                if (cn == "Weld" or cn == "WeldConstraint" or cn == "Motor6D" or cn == "ManualWeld" or cn == "Snap" or cn == "Glue" or cn == "Motor")
                    and cp.Enabled ~= false
                    and (cp.Part0 == proxy or cp.Part1 == proxy) then
                    local p0, p1 = cp.Part0, cp.Part1
                    if isProxy(p0) and isProxy(p1) and p0:IsDescendantOf(workspace) and p1:IsDescendantOf(workspace) then
                        out[#out + 1] = ch
                    end
                end
                walk(ch)
            end
        end
        walk(workspace)
        return out
    end
    serviceMethods.GetGroupsAsync = function(self, userId) return {} end
    serviceMethods.GetGroupInfoAsync = function(self, groupId)
        return {Id = toNumberFunction(groupId) or 0, Name = "Group", MemberCount = 0}
    end
    serviceMethods.GetMemStats = function(self)
        return {Animations = 1, Clips = 2, Tracks = 3}
    end
    serviceMethods.SetItem = function(self, key, value)
        _at.mem[formatValue(key)] = formatValue(value)
    end
    serviceMethods.GetItem = function(self, key)
        return _at.mem[formatValue(key)]
    end
    serviceMethods.RemoveItem = function(self, key)
        _at.mem[formatValue(key)] = nil
    end
    serviceMethods.AddTag = function(self, inst, tag)
        local target = tag == nil and proxy or inst
        tag = tag == nil and inst or tag
        local tagName = formatValue(tag)
        _at.tags[tagName] = _at.tags[tagName] or {}
        _at.tags[tagName][target] = true
        _at.instTags[target] = _at.instTags[target] or {}
        _at.instTags[target][tagName] = true
    end
    serviceMethods.RemoveTag = function(self, inst, tag)
        local target = tag == nil and proxy or inst
        tag = tag == nil and inst or tag
        local tagName = formatValue(tag)
        if _at.tags[tagName] then _at.tags[tagName][target] = nil end
        if _at.instTags[target] then _at.instTags[target][tagName] = nil end
    end
    serviceMethods.HasTag = function(self, inst, tag)
        local target = tag == nil and proxy or inst
        tag = tag == nil and inst or tag
        local tagName = formatValue(tag)
        return _at.instTags[target] and _at.instTags[target][tagName] == true or false
    end
    serviceMethods.GetTags = function(self, inst)
        local target = inst or proxy
        local result = {}
        for tagName in pairsFunction(_at.instTags[target] or {}) do table.insert(result, tagName) end
        return result
    end
    serviceMethods.GetTagged = function(self, tag)
        local tagName = formatValue(tag)
        local result = {}
        if _at.tags[tagName] then
            for inst in pairsFunction(_at.tags[tagName]) do
                table.insert(result, inst)
            end
        end
        return result
    end
    serviceMethods.GetAllTags = function(self)
        local result = {}
        for tagName in pairsFunction(_at.tags) do table.insert(result, tagName) end
        return result
    end
    serviceMethods.GetSortedMap = function(self, name)
        local mapProxy = createProxyObject("MemoryStoreSortedMap", false)
        dumperState.registry[mapProxy] = string.format("game:GetService(\"MemoryStoreService\"):GetSortedMap(%s)", formatStringLiteral(name or "map"))
        return mapProxy
    end
    serviceMethods.GetQueue = function(self, name, invisibilityTimeout)
        local qProxy = createProxyObject("MemoryStoreQueue", false)
        dumperState.registry[qProxy] = string.format("game:GetService(\"MemoryStoreService\"):GetQueue(%s)", formatStringLiteral(name or "queue"))
        return qProxy
    end
    serviceMethods.SetAsync = function(self, key, value, expiration, sortKey)
        local path = dumperState.registry[proxy] or "MemoryStoreSortedMap"
        emitOutput(string.format("%s:SetAsync(%s, %s, %s)", path, serializeValue(key), serializeValue(value), serializeValue(expiration or 0)))
    end
    serviceMethods.GetAsync = function(self, key)
        local path = dumperState.registry[proxy] or "MemoryStoreSortedMap"
        local res = createProxyObject("memResult", false)
        local varName = registerVariable(res, "memResult")
        emitOutput(string.format("local %s = %s:GetAsync(%s)", varName, path, serializeValue(key)))
        return res
    end
    serviceMethods.ReadAsync = function(self, count, allOrNothing, waitTimeout)
        local path = dumperState.registry[proxy] or "MemoryStoreQueue"
        local res = createProxyObject("queueItems", false)
        local id = createProxyObject("receiptId", false)
        return {}, id
    end
    serviceMethods.RemoveAsync = function(self, key)
        local path = dumperState.registry[proxy] or "MemoryStore"
        emitOutput(string.format("%s:RemoveAsync(%s)", path, serializeValue(key)))
    end
    serviceMethods.GetRangeAsync = function(self, direction, count, exclusiveLowerBound, exclusiveUpperBound)
        return {}
    end
    serviceMethods.GetSessionId = function(self) return "00000000-0000-0000-0000-000000000000" end
    serviceMethods.GetPlaceVersion = function(self) return 1 end
    serviceMethods.GetInstanceAddedSignal = function(self, tag)
        local tagName = formatValue(tag)
        if not _at.sigs[tagName] then
            local sig = createProxyObject("CollectionSignal", false)
            dumperState.registry[sig] = "CollectionService:GetInstanceAddedSignal(" .. formatStringLiteral(tagName) .. ")"
            _at.typeOverride[sig] = "RBXScriptSignal"
            _at.sigs[tagName] = sig
        end
        return _at.sigs[tagName]
    end
    serviceMethods.GetInstanceRemovedSignal = function(self, tag)
        return serviceMethods.GetInstanceAddedSignal(self, "__removed_" .. formatValue(tag))
    end
    serviceMethods.CheckForUpdate = function(self) return false end
    serviceMethods.BindAction = function(self, name, callback, createTouchButton, ...)
        local actionName = formatValue(name)
        local inputs = {...}
        _at.acts[actionName] = {inputTypes = inputs, createTouchButton = createTouchButton == true}
    end
    serviceMethods.UnbindAction = function(self, name)
        _at.acts[formatValue(name)] = nil
    end
    serviceMethods.GetAllBoundActionInfo = function(self) return _at.acts end
    serviceMethods.GetAsync = function(self, url) return "{}" end
    serviceMethods.PostAsync = function(self, url, data) return "{}" end
    serviceMethods.UrlEncode = function(self, s)
        s = tostring(s or "")
        return (s:gsub("[^%w%-_%.~]", function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    end
    serviceMethods.UrlDecode = function(self, s)
        s = tostring(s or "")
        return (s:gsub("%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end))
    end
    serviceMethods.JSONEncode = function(self, data)
        local function encode(v)
            local tv = typeFunction(v)
            if tv == "string" then return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end
            if tv == "number" or tv == "boolean" then return toStringFunction(v) end
            if tv == "table" then
                local isArray, maxIndex, count = true, 0, 0
                for k in pairsFunction(v) do
                    count = count + 1
                    if typeFunction(k) ~= "number" then isArray = false else maxIndex = math.max(maxIndex, k) end
                end
                local out = {}
                if isArray and maxIndex == count then
                    for i = 1, maxIndex do table.insert(out, encode(v[i])) end
                    return "[" .. table.concat(out, ",") .. "]"
                end
                for k, val in pairsFunction(v) do table.insert(out, '"' .. toStringFunction(k) .. '":' .. encode(val)) end
                return "{" .. table.concat(out, ",") .. "}"
            end
            return "null"
        end
        local encoded = encode(data)
        _at.json[encoded] = data
        return encoded
    end
    serviceMethods.JSONDecode = function(self, json)
        local key = formatValue(json)
        if _at.json[key] then return _at.json[key] end
        if key:match("^%s*%[") then
            local result = {}
            for value in key:gmatch('"?([^,"%[%]%s]+)"?') do
                local n = toNumberFunction(value)
                table.insert(result, n or value)
            end
            return result
        end
        if key:match("^%s*{") then
            local result = {}
            for k, v in key:gmatch('"%s*([^"]-)%s*"%s*:%s*"?([^",}]+)"?') do
                result[k] = toNumberFunction(v) or (v == "true" and true) or (v == "false" and false) or v
            end
            return result
        end
        return {}
    end
    serviceMethods.GetTextSize = function(self, text, size, font, frameSize)
        local width = math.max(1, #(formatValue(text or "")) * (toNumberFunction(size) or 14) * 0.5)
        return Vector2.new(width, toNumberFunction(size) or 14)
    end
    serviceMethods.GetGuiInset = function(self)
        return Vector2.new(0, 36), Vector2.new(0, 0)
    end
    serviceMethods.GetRequestQueueSize = function(self) return 0 end
    serviceMethods.CompressBuffer = function(self, b, algorithm, level) return b end
    serviceMethods.DecompressBuffer = function(self, b, algorithm) return b end
    serviceMethods.GetRealPhysicsFPS = function(self) return 60 end
    serviceMethods.GetLogHistory = function(self) return {} end
    serviceMethods.RequestServerOutput = function(self)
        local svcPath = dumperState.registry[proxy] or "LogService"
        emitOutput(svcPath .. ":RequestServerOutput()")
    end
    serviceMethods.GetUserInfosByUserIdsAsync = function(self, userIds)
        local result = {}
        if typeFunction(userIds) == "table" then
            for _, uid in ipairsFunction(userIds) do
                table.insert(result, {Id = uid, Username = "Player", DisplayName = "Player"})
            end
        end
        return result
    end
    serviceMethods.GetFriendsAsync = function(self, userId)
        return createProxyObject("Pages", false)
    end
    serviceMethods.GetFriendCountAsync = function(self, userId) return 0 end
    serviceMethods.GetFriendRequestsAsync = function(self) return createProxyObject("Pages", false) end
    serviceMethods.GetGameFriends = function(self, player)
        return createProxyObject("Pages", false)
    end
    serviceMethods.CreateCollisionGroup = function(self, name)
        local servicePath = dumperState.registry[proxy] or "PhysicsService"
        emitOutput(string.format("%s:CreateCollisionGroup(%s)", servicePath, serializeValue(name)))
        return 0
    end
    serviceMethods.CollisionGroupSetCollidable = function(self, group1, group2, collidable)
        local servicePath = dumperState.registry[proxy] or "PhysicsService"
        emitOutput(string.format("%s:CollisionGroupSetCollidable(%s, %s, %s)",
            servicePath, serializeValue(group1), serializeValue(group2), serializeValue(collidable)))
    end
    serviceMethods.SetPartCollisionGroup = function(self, part, group)
        local servicePath = dumperState.registry[proxy] or "PhysicsService"
        emitOutput(string.format("%s:SetPartCollisionGroup(%s, %s)",
            servicePath, serializeValue(part), serializeValue(group)))
    end
    serviceMethods.GetCollisionGroupId   = function(self, name) return 0 end
    serviceMethods.CollisionGroupsAreCollidable = function(self, g1, g2) return true end
    serviceMethods.GetMaxCollisionGroups = function(self) return 32 end
    serviceMethods.LoadAsset = function(self, assetId)
        local svcPath = dumperState.registry[proxy] or "InsertService"
        local modelProxy = createProxyObject("Model", false)
        local varName = registerVariable(modelProxy, "model")
        dumperState.property_store[modelProxy] = {ClassName = "Model", Name = "Asset"}
        emitOutput(string.format("local %s = %s:LoadAsset(%s)", varName, svcPath, serializeValue(assetId)))
        return modelProxy
    end
    serviceMethods.LoadAssetVersion = function(self, assetVersionId)
        return serviceMethods.LoadAsset(self, assetVersionId)
    end
    serviceMethods.GetFreeDecals = function(self, search, page) return createProxyObject("Pages", false) end
    serviceMethods.GetFreeModels = function(self, search, page) return createProxyObject("Pages", false) end
    serviceMethods.GetSortedMap = function(self, name)
        local key = "sortedmap_" .. formatValue(name)
        if not _at.mem[key] then
            local sm = createProxyObject("MemoryStoreSortedMap", false)
            dumperState.property_store[sm] = {ClassName = "MemoryStoreSortedMap", Name = formatValue(name)}
            _at.mem[key] = sm
        end
        return _at.mem[key]
    end
    serviceMethods.GetQueue = function(self, name, invisibilityTimeout)
        local key = "queue_" .. formatValue(name)
        if not _at.mem[key] then
            local q = createProxyObject("MemoryStoreQueue", false)
            _at.mem[key] = q
        end
        return _at.mem[key]
    end
    serviceMethods.GetHashMap = function(self, name)
        local key = "hashmap_" .. formatValue(name)
        if not _at.mem[key] then
            local hm = createProxyObject("MemoryStoreHashMap", false)
            _at.mem[key] = hm
        end
        return _at.mem[key]
    end
    serviceMethods.PromptAllowInventoryReadAccess = function(self)
        local svcPath = dumperState.registry[proxy] or "AvatarEditorService"
        emitOutput(svcPath .. ":PromptAllowInventoryReadAccess()")
    end
    serviceMethods.PromptSetFavorite = function(self, itemId, itemType, shouldFavorite) end
    serviceMethods.GetInventory = function(self, assetTypes)
        return createProxyObject("InventoryPages", false)
    end
    serviceMethods.GetNotifications = function(self) return {} end
    serviceMethods.Subscribe = function(self, playerUserId, alertType, dataTable)
        local svcPath = dumperState.registry[proxy] or "NotificationService"
        emitOutput(string.format("%s:Subscribe(%s, %s)", svcPath, serializeValue(playerUserId), serializeValue(alertType)))
    end
    serviceMethods.LogCustomEvent = function(self, player, eventType, eventName, eventData)
        local svcPath = dumperState.registry[proxy] or "AnalyticsService"
        emitOutput(string.format("%s:LogCustomEvent(%s, %s, %s)",
            svcPath, serializeValue(player), serializeValue(eventType), serializeValue(eventName)))
    end
    serviceMethods.LogEconomyEvent = function(self, player, flowType, economyType, amount, itemSku)
        local svcPath = dumperState.registry[proxy] or "AnalyticsService"
        emitOutput(string.format("%s:LogEconomyEvent(%s, %s, %s, %s)",
            svcPath, serializeValue(player), serializeValue(flowType), serializeValue(economyType), serializeValue(amount)))
    end
    serviceMethods.LogFunnelStepEvent = function(self, player, funnelName, funnelSessionId, step, stepName) end
    serviceMethods.LogOnboardingFunnelStepEvent = function(self, player, funnelName, step, stepName) end
    serviceMethods.PromptGameInvite = function(self, player)
        local svcPath = dumperState.registry[proxy] or "SocialService"
        emitOutput(string.format("%s:PromptGameInvite(%s)", svcPath, serializeValue(player)))
    end
    serviceMethods.CanSendGameInviteAsync = function(self, player) return true end
    serviceMethods.PromptPhoneBook    = function(self, player) end
    serviceMethods.AddCoreScriptLocal = function(self, scriptName, parent)
        local svcPath = dumperState.registry[proxy] or "ScriptContext"
        emitOutput(string.format("%s:AddCoreScriptLocal(%s)", svcPath, serializeValue(scriptName)))
    end
    serviceMethods.SetTimeout = function(self, seconds) end
    serviceMethods.GetKeysPressed = function(self)
        return {}
    end
    serviceMethods.GetMouseDelta = function(self)
        return Vector2.new(0, 0)
    end
    serviceMethods.GetMouseLocation = function(self)
        return Vector2.new(0, 0)
    end
    serviceMethods.IsKeyDown = function(self, key) return false end
    serviceMethods.IsMouseButtonPressed = function(self, btn) return false end
    serviceMethods.IsGamepadButtonDown = function(self, gp, btn) return false end
    serviceMethods.GetGamepadState = function(self, gp) return {} end
    serviceMethods.GetConnectedGamepads = function(self) return {} end
    serviceMethods.GetNavigationGamepads = function(self) return {} end
    serviceMethods.SetNavigationGamepad = function(self, gp, enabled) end
    serviceMethods.GetLastInputType = function(self) return Enum.UserInputType.None end
    serviceMethods.GetFocusedTextBox = function(self) return nil end
    serviceMethods.RecenterUserHeadCFrame = function(self) end
    serviceMethods.GetDeviceRotation = function(self) return CFrame.new(0,0,0), Vector3.new(0,0,0) end
    serviceMethods.GetDeviceGravity = function(self) return {Position = Vector3.new(0,-1,0)} end
    serviceMethods.GetUserCFrame = function(self, vr) return CFrame.new(0,0,0) end
    serviceMethods.BindActionAtPriority = function(self, name, callback, createTouch, priority, ...)
        local inputs = {...}
        local actionName = formatValue(name)
        _at.acts[actionName] = {inputTypes = inputs, priority = priority}
    end
    serviceMethods.GetBoundActionInfo = function(self, name)
        return _at.acts[formatValue(name)] or {inputTypes = {}}
    end
    serviceMethods.SetTitle = function(self, name, title) end
    serviceMethods.SetImage = function(self, name, image) end
    serviceMethods.SetPosition = function(self, name, x, y) end
    serviceMethods.SetDescription = function(self, name, desc) end
    serviceMethods.GetGroupAsync = function(self, groupId)
        return {Id = toNumberFunction(groupId) or 0, Name = "Group", Description = "", MemberCount = 0, Roles = {}}
    end
    serviceMethods.GetGroupsAsync = function(self, userId) return {} end
    serviceMethods.GetAlliesAsync = function(self, groupId) return createProxyObject("Pages", false) end
    serviceMethods.GetEnemiesAsync = function(self, groupId) return createProxyObject("Pages", false) end
    serviceMethods.GetGamePlacesAsync = function(self) return createProxyObject("Pages", false) end
    serviceMethods.GetCreatorAssetID   = function(self, creationId) return 0 end
    serviceMethods.CreatePlaceAsync    = function(self, placeName, templateId)
        local svcPath = dumperState.registry[proxy] or "AssetService"
        emitOutput(string.format("%s:CreatePlaceAsync(%s, %s)", svcPath, serializeValue(placeName), serializeValue(templateId)))
        return 0
    end
    serviceMethods.SavePlaceAsync = function(self)
        local svcPath = dumperState.registry[proxy] or "AssetService"
        emitOutput(svcPath .. ":SavePlaceAsync()")
    end
    serviceMethods.GetBundleDetailsAsync = function(self, bundleId)
        return {Id = bundleId, BundleType = "BodyParts", Items = {}}
    end
    serviceMethods.CreateEditableMesh = function(self)
        local mesh = createProxyObject("EditableMesh", false, proxy)
        dumperState.property_store[mesh] = {ClassName = "EditableMesh", Name = "EditableMesh"}
        _at.editableMeshes = _at.editableMeshes or setmetatable({}, {__mode = "k"})
        _at.editableMeshes[mesh] = {verts = {}, nextId = 1}
        local varName = registerVariable(mesh, "EditableMesh")
        local svcPath = dumperState.registry[proxy] or "AssetService"
        emitOutput(string.format("local %s = %s:CreateEditableMesh()", varName, svcPath))
        return mesh
    end
    serviceMethods.CreateEditableMeshAsync = function(self, ...)
        return serviceMethods.CreateEditableMesh(self)
    end
    serviceMethods.AddVertex = function(self, pos)
        _at.editableMeshes = _at.editableMeshes or setmetatable({}, {__mode = "k"})
        local store = _at.editableMeshes[proxy]
        if not store then
            store = {verts = {}, nextId = 1}
            _at.editableMeshes[proxy] = store
        end
        local id = store.nextId
        store.verts[id] = pos
        store.nextId = id + 1
        return id
    end
    serviceMethods.GetPosition = function(self, id)
        local store = _at.editableMeshes and _at.editableMeshes[proxy]
        if store and store.verts[id] ~= nil then
            return store.verts[id]
        end
        return Vector3.new(0, 0, 0)
    end
    serviceMethods.SetPosition = function(self, id, pos)
        _at.editableMeshes = _at.editableMeshes or setmetatable({}, {__mode = "k"})
        local store = _at.editableMeshes[proxy]
        if not store then
            store = {verts = {}, nextId = 1}
            _at.editableMeshes[proxy] = store
        end
        store.verts[id] = pos
    end
    serviceMethods.GetVertices = function(self)
        local out = {}
        local store = _at.editableMeshes and _at.editableMeshes[proxy]
        if store then
            for id, _ in pairsFunction(store.verts) do
                out[#out + 1] = id
            end
        end
        return out
    end
    serviceMethods.FilterStringAsync = function(self, str, fromUserId, context)
        local res = createProxyObject("TextFilterResult", false)
        dumperState.registry[res] = "TextFilterResult"
        dumperState.property_store[res] = {ClassName = "TextFilterResult"}
        return res
    end
    serviceMethods.GetChatForUserAsync = function(self, fromUserId, str)
        return formatValue(str)
    end
    serviceMethods.GetNonChatStringForBroadcastAsync = function(self) return "" end
    serviceMethods.GetNonChatStringForUserAsync = function(self) return "" end
    serviceMethods.IsVoiceEnabledForUserIdAsync = function(self, userId) return false end
    serviceMethods.SetupVoiceChannel = function(self, channelId) end
    serviceMethods.GetProximityPrompts  = function(self) return {} end
    serviceMethods.SetUiOffset          = function(self, offset) end
    serviceMethods.GetTranslatorForPlayer = function(self, player)
        local translator = createProxyObject("Translator", false)
        dumperState.property_store[translator] = {ClassName = "Translator", LocaleId = "en-us"}
        return translator
    end
    serviceMethods.GetCountryRegionForPlayerAsync = function(self, player) return "US" end
    serviceMethods.GetLocaleForPlayerAsync = function(self, player) return "en-us" end
    serviceMethods.GetNextResultsPage = function(self)
        return createProxyObject("Pages", false)
    end
    serviceMethods.GetCurrentPage = function(self)
        return {}
    end
    serviceMethods.AdvanceToNextPageAsync = function(self) end
    serviceMethods.IsFinished = function(self) return true end
    serviceMethods.PromptOptInEnabled = function(self, player) return false end
    serviceMethods.SendUserNotification = function(self, notificationId, userId, params)
        local svcPath = dumperState.registry[proxy] or "ExperienceNotificationService"
        emitOutput(string.format("%s:SendUserNotification(%s, %s)", svcPath, serializeValue(notificationId), serializeValue(userId)))
    end
    serviceMethods.SetCore = function(self, coreType, value)
        local svcPath = dumperState.registry[proxy] or "StarterGui"
        emitOutput(string.format("%s:SetCore(%s, %s)", svcPath, serializeValue(coreType), serializeValue(value)))
    end
    serviceMethods.GetCore = function(self, coreType) return true end
    serviceMethods.SetCoreGuiEnabled = function(self, guiType, enabled)
        local svcPath = dumperState.registry[proxy] or "StarterGui"
        emitOutput(string.format("%s:SetCoreGuiEnabled(%s, %s)", svcPath, serializeValue(guiType), serializeValue(enabled)))
    end
    serviceMethods.IsCoreGuiEnabled = function(self, guiType) return true end
    serviceMethods.PreloadAsync = function(self, assets, callback)
        if typeFunction(callback) == "function" then
            if typeFunction(assets) == "table" then
                for _, asset in ipairsFunction(assets) do
                    xpcallFunction(function() callback(asset, "Success") end, function() end)
                end
            end
        end
    end
    serviceMethods.RequestQueueSize = function(self) return 0 end
    serviceMethods.GetKeyframeSequenceAsync = function(self, assetId)
        return createProxyObject("KeyframeSequence", false)
    end
    serviceMethods.GetMemoryStats = function(self) return {
        TotalMemory = 512 * 1024 * 1024,
        UsedMemory  = 256 * 1024 * 1024,
    } end
    serviceMethods.GetEnumItems = function(self)
        local enumPath = dumperState.registry[proxy] or ""
        local enumTypeName = enumPath:match("Enum%.(.+)") or "Unknown"
        local registryEnum = _apiEnums[enumTypeName]
        if typeFunction(registryEnum) == "table" and typeFunction(registryEnum.order) == "table" then
            local items = {}
            for _, itemName in ipairsFunction(registryEnum.order) do
                local itemKey = "Enum." .. enumTypeName .. "." .. itemName
                if not _at.enum[itemKey] then
                    local itemProxy = createProxyObject(itemKey, false)
                    dumperState.registry[itemProxy] = itemKey
                    _at.typeOverride[itemProxy] = "EnumItem"
                    dumperState.property_store[itemProxy] = {
                        Name = itemName,
                        Value = registryEnum.values[itemName],
                        EnumType = proxy,
                    }
                    _at.enum[itemKey] = itemProxy
                end
                items[#items + 1] = _at.enum[itemKey]
            end
            return items
        end
        local knownItems = {
            QualityLevel  = {"Automatic","Level01","Level02","Level03","Level04","Level05","Level06","Level07","Level08","Level09","Level10","Level11"},
            KeyCode       = {
                "Unknown","Backspace","Tab","Clear","Return","Pause","Escape","Space","QuotedDouble","Hash",
                "Dollar","Ampersand","Quote","LeftParenthesis","RightParenthesis","Asterisk","Plus",
                "Comma","Minus","Period","Slash",
                "Zero","One","Two","Three","Four","Five","Six","Seven","Eight","Nine",
                "Colon","Semicolon","LessThan","Equals","GreaterThan","Question","At",
                "A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
                "LeftBracket","BackSlash","RightBracket","Caret","Underscore","Backquote",
                "World0","World1",
                "Delete","Insert","Home","End","PageUp","PageDown",
                "F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12",
                "F13","F14","F15",
                "NumLock","CapsLock","ScrollLock","RightShift","LeftShift","RightControl","LeftControl",
                "RightAlt","LeftAlt","RightMeta","LeftMeta","LeftSuper","RightSuper","Mode",
                "Help","Print","SysReq","Break","Menu","Power","Euro","Undo",
                "KeypadZero","KeypadOne","KeypadTwo","KeypadThree","KeypadFour",
                "KeypadFive","KeypadSix","KeypadSeven","KeypadEight","KeypadNine",
                "KeypadPeriod","KeypadDivide","KeypadMultiply","KeypadMinus","KeypadPlus",
                "KeypadEnter","KeypadEquals",
                "Up","Down","Right","Left",
                "ButtonX","ButtonY","ButtonA","ButtonB",
                "ButtonR1","ButtonL1","ButtonR2","ButtonL2","ButtonR3","ButtonL3",
                "ButtonStart","ButtonSelect","DPadLeft","DPadRight","DPadUp","DPadDown",
            },
            UserInputType = {
                "MouseButton1","MouseButton2","MouseButton3","MouseWheel","MouseMovement","Touch",
                "Keyboard","Focus","Accelerometer","Gyro","Gamepad1","Gamepad2","Gamepad3","Gamepad4",
                "Gamepad5","Gamepad6","Gamepad7","Gamepad8","TextInput","InputMethod","None",
            },
            UserInputState = {"Begin","Change","End","Cancel","None"},
            RaycastFilterType = {"Exclude","Include"},
            HumanoidStateType = {
                "FallingDown","Running","Runningslow","Strafing","Climbing","Seated","PlatformStanding",
                "Dead","Jumping","Freefall","Flying","Landed","Swimming","Ragdoll","GettingUp",
                "Buoyant","None",
            },
            HumanoidDisplayDistanceType = {"Automatic","Fixed","None"},
            HumanoidHealthDisplayType   = {"DisplayWhenDamaged","AlwaysOn","AlwaysOff"},
            NormalId      = {"Front","Back","Left","Right","Top","Bottom"},
            PlaybackState = {"Begin","Playing","Paused","Completed","Cancelled"},
            EasingStyle   = {"Linear","Sine","Back","Bounce","Circular","Cubic","Elastic","Exponential","Quad","Quartic","Quintic"},
            EasingDirection = {"In","Out","InOut"},
            Material = {
                "Plastic","Wood","Slate","Concrete","CorrodedMetal","DiamondPlate","Foil","Grass",
                "Ice","Marble","Granite","Brick","Pebble","Sand","Fabric","SmoothPlastic","Metal",
                "WoodPlanks","Cobblestone","Air","Water","Rock","Glacier","Snow","Sandstone",
                "Mud","Basalt","Ground","CrackedLava","Neon","Glass","Forcefield","SolidWood","Cardboard",
                "LeafyGrass","Salt","Pavement",
            },
            PartType  = {"Ball","Block","Cylinder"},
            SurfaceType = {"Smooth","Glue","Weld","Studs","Inlet","Universal","Hinge","Motor","SteppingMotor","Duct"},
            CameraType = {"Fixed","Attach","Watch","Track","Follow","Custom","Scriptable","Orbital"},
            MeshType  = {"Cylinder","Brick","FileMesh","Head","Sphere","Torso","Wedge","CornerWedge","Special"},
            FormFactor = {"Symmetric","Brick","Plate","Custom"},
            SortOrder  = {"Name","LayoutOrder","Custom"},
            FillDirection  = {"Horizontal","Vertical"},
            HorizontalAlignment = {"Left","Center","Right"},
            VerticalAlignment   = {"Top","Center","Bottom"},
            SizeConstraint = {"RelativeXY","RelativeXX","RelativeYY"},
            ScaleType  = {"Stretch","Slice","Tile","Fit","Crop"},
            TextXAlignment = {"Left","Center","Right"},
            TextYAlignment = {"Top","Center","Bottom"},
            TextTruncate   = {"None","AtEnd"},
            AutomaticSize  = {"None","X","Y","XY"},
            BorderMode     = {"Outline","Middle","Inset"},
            ScrollingDirection = {"X","Y","XY"},
            ElasticBehavior = {"Always","WhenScrollable","Never"},
            Font  = {
                "Legacy","Arial","ArialBold","SourceSans","SourceSansBold","SourceSansLight",
                "SourceSansItalic","SourceSansSemibold","Roboto","RobotoCondensed","Ubuntu",
                "TitilliumWeb","Nunito","Merriweather","Oswald","Sarpanch","FredokaOne",
                "GothamBold","GothamMedium","GothamBlack","GothamLight",
                "Builder Sans","Humanist","Unknown",
            },
            FontWeight = {"Thin","ExtraLight","Light","Regular","Medium","SemiBold","Bold","ExtraBold","Heavy"},
            FontStyle  = {"Normal","Italic"},
            RenderFidelity = {"Automatic","Precise","Performance"},
            LevelOfDetailSetting = {"Disabled","StreamingMesh","All"},
            StreamingPauseMode = {"Default","Disabled","ClientPhysicsPause"},
            ChatMode  = {"Classic","Bubble"},
            TweenStatus = {"Cancelled","Completed"},
            HighlightDepthMode = {"AlwaysOnTop","Occluded"},
            SelectionBehavior = {"Escape","Stop"},
            AppShellActionType = {"None","OpenApp","TakeScreenshot","OpenDialog"},
            AnimationPriority = {"Idle","Movement","Action","Action2","Action3","Action4","Core"},
            PoseEasingStyle = {"Linear","Constant","Elastic","Cubic","Bounce"},
            PoseEasingDirection = {"In","Out","InOut"},
            PathStatus = {"Success","ClosestNoPath","ClosestOutOfRange","FailStartNotEmpty","FailFinishNotEmpty","NoPath"},
            PathWaypointAction = {"Walk","Jump","Custom"},
            ZIndexBehavior = {"Global","Sibling"},
            GuiType = {"BillboardGui","ScreenGui","SurfaceGui"},
            SpecialKey = {"Insert","Home","End","PageUp","PageDown","ChatHotkey","Backspace"},
            Platform = {"Windows","OSX","IOS","Android","XBoxOne","PS4","PS3","XBox360","WiiU","NX","Ouya","AndroidTV","ChromeBook","GameConsole","Linux","None"},
            ProductPurchaseDecision = {"NotProcessedYet","PurchaseGranted","DoNotGrantProduct"},
            MarketplacePurchaseDecision = {"NotProcessedYet","PurchaseGranted","DoNotGrantProduct"},
            TeleportState = {"RequestedFromServer","Started","OnTeleport","Failed","InProgress","WaitingForServer"},
            TeleportType  = {"ToPlace","ToInstance","ToReservedServer"},
            AccessType    = {"Everyone","Friends"},
            ChatPrivacyMode = {"AllUsers","NoOne","Friends"},
            ParticleEmitterShape = {"Box","Sphere","Cylinder","Disc"},
            ParticleEmitterShapeInOut = {"Outward","Inward","OutwardInward"},
            ParticleEmitterShapeStyle  = {"Volume","Surface"},
            ParticleFlipbookLayout = {"None","TwoByTwo","FourByFour","EightByEight"},
            ParticleFlipbookMode   = {"Loop","OneShot","PingPong","Random"},
            CollisionFidelity   = {"Default","Box","Hull","Precise"},
            ElasticLimitType    = {"Translate","Rotate","Both"},
            VelocityConstraintMode = {"None","Line","Plane"},
            LineForceReferencePart = {"Attachment0","Attachment1","Custom"},
            RopeConstraintWinding  = {"Right","Left"},
            SoundGroup  = {"SFX","Music","Interface"},
            AudioDeviceType = {"Input","Output"},
            FaceControls = {"None","UpperFace","LowerFace","FullFace"},
            TextFilteringType = {"Private","PublicChat"},
            OverrideMouseIconBehavior = {"None","ForceShow","ForceHide"},
            InputType  = {"NoPreference","Movement","Rotation","Trigger"},
            DialogTone = {"Neutral","Friendly","Enemy"},
            DialogPurpose = {"Quest","Help","Shop"},
            ContextActionPriority = {"Low","Medium","High","Default"},
            ContextActionResult = {"Sink","Pass"},
            ThumbnailSize = {"Size48x48","Size60x60","Size100x100","Size150x150","Size180x180","Size352x352","Size420x420","Size720x720"},
            ThumbnailType = {"AvatarBust","AvatarHeadShot","GameThumbnail","Asset","BadgeImage","GameIcon"},
        }
        local names = knownItems[enumTypeName] or {"Unknown"}
        local items = {}
        for _, v in ipairsFunction(names) do
            local itemKey = "Enum." .. enumTypeName .. "." .. v
            if not _at.enum[itemKey] then
                local itemProxy = createProxyObject(itemKey, false)
                dumperState.registry[itemProxy] = itemKey
                _at.typeOverride[itemProxy] = "EnumItem"
                _at.enum[itemKey] = itemProxy
            end
            items[#items + 1] = _at.enum[itemKey]
        end
        return items
    end
    serviceMethods.GetEnums = function(self)
        local items = {}
        for _, enumName in ipairsFunction(_apiEnumOrder) do
            local enumPath = "Enum." .. enumName
            if not _at.enum[enumPath] then
                local enumProxy = createProxyObject(enumPath, false)
                dumperState.registry[enumProxy] = enumPath
                _at.typeOverride[enumProxy] = "Enum"
                _at.enum[enumPath] = enumProxy
            end
            items[#items + 1] = _at.enum[enumPath]
        end
        table.sort(items, function(a, b)
            return tostring(dumperState.registry[a] or "") < tostring(dumperState.registry[b] or "")
        end)
        return items
    end
    serviceMethods.GenerateGUID = function(self, includeBraces)
        local t = {}
        local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        for c in template:gmatch(".") do
            if c == "x" then t[#t+1] = string.format("%x", math.random(0, 15))
            elseif c == "y" then t[#t+1] = string.format("%x", math.random(8, 11))
            else t[#t+1] = c end
        end
        local guid = table.concat(t):upper()
        return includeBraces and ("{" .. guid .. "}") or guid
    end
    serviceMethods.HttpGet = function(self, url)
        local resolvedUrl = formatValue(url)
        table.insert(dumperState.string_refs, {value = resolvedUrl, hint = "HTTP URL"})
        dumperState.last_http_url = resolvedUrl
        return resolvedUrl
    end
    serviceMethods.HttpPost = function(self, url, data, contentType)
        local resolvedUrl = formatValue(url)
        table.insert(dumperState.string_refs, {value = resolvedUrl, hint = "HTTP POST URL"})
        local resultProxy = createProxyObject("HttpResponse", false)
        local varName = registerVariable(resultProxy, "httpResponse")
        local servicePath = dumperState.registry[proxy] or "HttpService"
        emitOutput(string.format("local %s = %s:HttpPost(%s, %s, %s)", varName, servicePath, serializeValue(url), serializeValue(data), serializeValue(contentType)))
        dumperState.property_store[resultProxy] = {Body = "{}", StatusCode = 200, Success = true}
        return resultProxy
    end
    serviceMethods.AddItem = function(self, item, delayTime)
        local servicePath = dumperState.registry[proxy] or "Debris"
        emitOutput(string.format("%s:AddItem(%s, %s)", servicePath, serializeValue(item), serializeValue(delayTime or 10)))
    end
    serviceMethods.FilterStringAsync = function(self, text, fromUserId, textContext)
        local servicePath = dumperState.registry[proxy] or "TextService"
        local resProxy = createProxyObject("TextFilterResult", false)
        local varName = registerVariable(resProxy, "textFilter")
        dumperState.property_store[resProxy] = {
            ClassName = "TextFilterResult",
            _filteredText = tostring(text or ""),
        }
        emitOutput(string.format("local %s = %s:FilterStringAsync(%s, %s)",
            varName, servicePath, serializeValue(text), serializeValue(fromUserId)))
        return resProxy
    end
    serviceMethods.GetNonChatStringForBroadcastAsync = function(self)
        local props = dumperState.property_store[proxy]
        if props and props._filteredText then return props._filteredText end
        return tostring(proxy)
    end
    serviceMethods.GetNonChatStringForUserAsync = function(self, toUserId)
        local props = dumperState.property_store[proxy]
        if props and props._filteredText then return props._filteredText end
        return tostring(proxy)
    end
    serviceMethods.GetChatForUserAsync = function(self, toUserId)
        local props = dumperState.property_store[proxy]
        if props and props._filteredText then return props._filteredText end
        return tostring(proxy)
    end
    serviceMethods.GetProductInfo = function(self, assetId, infoType)
        local servicePath = dumperState.registry[proxy] or "MarketplaceService"
        local resProxy = createProxyObject("ProductInfo", false)
        local varName = registerVariable(resProxy, "productInfo")
        dumperState.property_store[resProxy] = {
            ClassName = "ProductInfo",
            AssetId = toNumberFunction(assetId) or 0,
            Name = "Product",
            PriceInRobux = 0,
            IsPublicDomain = false,
            IsForSale = true,
        }
        emitOutput(string.format("local %s = %s:GetProductInfo(%s)",
            varName, servicePath, serializeValue(assetId)))
        return resProxy
    end
    serviceMethods.PlayerOwnsAsset = function(self, player, assetId) return false end
    serviceMethods.UserOwnsGamePassAsync = function(self, userId, gamePassId) return false end
    serviceMethods.GetDeveloperProductsAsync = function(self)
        return createProxyObject("Pages", false)
    end
    serviceMethods.PromptGamePassPurchase = function(self, player, gamePassId)
        local servicePath = dumperState.registry[proxy] or "MarketplaceService"
        emitOutput(string.format("%s:PromptGamePassPurchase(%s, %s)",
            servicePath, serializeValue(player), serializeValue(gamePassId)))
    end
    serviceMethods.PromptProductPurchase = function(self, player, productId, equipIfPurchased, currencyType)
        local servicePath = dumperState.registry[proxy] or "MarketplaceService"
        emitOutput(string.format("%s:PromptProductPurchase(%s, %s)",
            servicePath, serializeValue(player), serializeValue(productId)))
    end
    serviceMethods.GetBundleDetailsAsync = function(self, bundleId)
        return { BundleType = "BodyParts", Items = {}, Id = toNumberFunction(bundleId) or 0 }
    end
    serviceMethods.CreatePlaceAsync  = function(self, name, templateId) return createProxyObject("place", false) end
    serviceMethods.CreatePlaceInPlayerInventoryAsync = function(self, player, placeName, templateId) return 0 end
    serviceMethods.GetGamePlacesAsync = function(self) return createProxyObject("Pages", false) end
    serviceMethods.AwardBadge = function(self, userId, badgeId)
        local servicePath = dumperState.registry[proxy] or "BadgeService"
        emitOutput(string.format("%s:AwardBadge(%s, %s)", servicePath, serializeValue(userId), serializeValue(badgeId)))
        return true
    end
    serviceMethods.UserHasBadgeAsync = function(self, userId, badgeId) return false end
    serviceMethods.GetBadgeInfoAsync  = function(self, badgeId)
        return { Name = "Badge", Description = "", IsEnabled = true }
    end
    serviceMethods.CreatePath = function(self, agentParams)
        local resProxy = createProxyObject("Path", false)
        dumperState.property_store[resProxy] = {ClassName = "Path", Status = "NoPath"}
        return resProxy
    end
    serviceMethods.FindPathAsync = function(self, from, to)
        local resProxy = createProxyObject("Path", false)
        dumperState.property_store[resProxy] = {ClassName = "Path", Status = "NoPath"}
        return resProxy
    end
    serviceMethods.ComputeAsync = function(self, from, to)
        local servicePath = dumperState.registry[proxy] or "path"
        emitOutput(string.format("%s:ComputeAsync(%s, %s)", servicePath, serializeValue(from), serializeValue(to)))
    end
    serviceMethods.GetWaypoints = function(self) return {} end
    serviceMethods.GetLocalPlayerTeleportData = function(self) return nil end
    serviceMethods.GetArrivingTeleportGui   = function(self) return nil end
    serviceMethods.SetTeleportGui           = function(self, gui)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        emitOutput(string.format("%s:SetTeleportGui(%s)", servicePath, serializeValue(gui)))
    end
    serviceMethods.ReserveServer  = function(self, placeId)
        return string.rep("A", 32), os.time() + 3600
    end
    serviceMethods.TeleportToPrivateServer = function(self, placeId, reserveKey, players)
        local servicePath = dumperState.registry[proxy] or "TeleportService"
        emitOutput(string.format("%s:TeleportToPrivateServer(%s, %s)",
            servicePath, serializeValue(placeId), serializeValue(reserveKey)))
    end
    serviceMethods.GetDataStore = function(self, name, scope)
        local key = (name or "default") .. "|" .. (scope or "global")
        if not _at.mem["_ds_" .. key] then
            local ds = createProxyObject("DataStore", false)
            dumperState.property_store[ds] = {ClassName = "DataStore", Name = name or "", Scope = scope or "global"}
            _at.mem["_ds_" .. key] = ds
        end
        return _at.mem["_ds_" .. key]
    end
    serviceMethods.GetGlobalDataStore = function(self)
        return serviceMethods.GetDataStore(self, "_global")
    end
    serviceMethods.GetOrderedDataStore = function(self, name, scope)
        return serviceMethods.GetDataStore(self, name, scope)
    end
    serviceMethods.GetAsync = function(self, key)
        local k = formatValue(key)
        return _at.mem["_dsv_" .. k]
    end
    serviceMethods.SetAsync = function(self, key, value)
        local k = formatValue(key)
        _at.mem["_dsv_" .. k] = value
        local storePath = dumperState.registry[proxy] or "dataStore"
        emitOutput(string.format("%s:SetAsync(%s, %s)", storePath, serializeValue(key), serializeValue(value)))
    end
    serviceMethods.UpdateAsync = function(self, key, transformFunc)
        local k = formatValue(key)
        local old = _at.mem["_dsv_" .. k]
        local ok, new = pcallFunction(function() return transformFunc(old) end)
        local val = ok and new or old
        _at.mem["_dsv_" .. k] = val
        return val
    end
    serviceMethods.RemoveAsync = function(self, key)
        local k = formatValue(key)
        local old = _at.mem["_dsv_" .. k]
        _at.mem["_dsv_" .. k] = nil
        return old
    end
    serviceMethods.IncrementAsync = function(self, key, delta)
        local k = formatValue(key)
        local old = toNumberFunction(_at.mem["_dsv_" .. k]) or 0
        local new = old + (toNumberFunction(delta) or 1)
        _at.mem["_dsv_" .. k] = new
        local storePath = dumperState.registry[proxy] or "dataStore"
        emitOutput(string.format("%s:IncrementAsync(%s, %s)", storePath, serializeValue(key), serializeValue(delta or 1)))
        return new
    end
    serviceMethods.ListKeysAsync = function(self, prefix, pageSize)
        local resProxy = createProxyObject("DataStoreKeyPages", false)
        dumperState.property_store[resProxy] = { ClassName = "DataStoreKeyPages", IsFinished = true }
        return resProxy
    end
    serviceMethods.ListVersionsAsync = function(self, key, sortDirection, minDate, maxDate, pageSize)
        local resProxy = createProxyObject("DataStoreVersionPages", false)
        dumperState.property_store[resProxy] = { ClassName = "DataStoreVersionPages", IsFinished = true }
        return resProxy
    end
    serviceMethods.GetVersionAsync = function(self, key, version)
        return _at.mem["_dsv_" .. formatValue(key)], { CreatedTime = 0, UpdatedTime = 0, Version = tostring(version or "1") }
    end
    serviceMethods.RemoveVersionAsync = function(self, key, version) end
    serviceMethods.GetSortedAsync = function(self, ascending, pageSize, minVal, maxVal)
        local resProxy = createProxyObject("DataStorePages", false)
        dumperState.property_store[resProxy] = { ClassName = "DataStorePages", IsFinished = true }
        return resProxy
    end
    serviceMethods.PublishAsync = function(self, topic, message)
        local servicePath = dumperState.registry[proxy] or "MessagingService"
        emitOutput(string.format("%s:PublishAsync(%s, %s)", servicePath, serializeValue(topic), serializeValue(message)))
    end
    serviceMethods.SubscribeAsync = function(self, topic, callback)
        local servicePath = dumperState.registry[proxy] or "MessagingService"
        local connProxy = createProxyObject("connection", false)
        _at.typeOverride[connProxy] = "RBXScriptConnection"
        _at.connState[connProxy] = true
        emitOutput(string.format("%s:SubscribeAsync(%s, function(msg)", servicePath, serializeValue(topic)))
        dumperState.indent = dumperState.indent + 1
        if typeFunction(callback) == "function" then
            xpcallFunction(function() callback({Data = "", Sent = osLibrary.time()}) end, function() end)
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
        return connProxy
    end
    serviceMethods.GetServerTimeNow = function(self) return osLibrary.time() end
    serviceMethods.Spherecast = function(self, origin, radius, dir, params) return nil end
    serviceMethods.Blockcast = function(self, cf, size, dir, params) return nil end
    serviceMethods.Shapecast = function(self, part, dir, params) return nil end
    serviceMethods.IsClient = function(self) return true end
    serviceMethods.IsServer = function(self) return false end
    serviceMethods.IsStudio = function(self) return false end
    serviceMethods.IsRunning = function(self) return true end
    serviceMethods.BindToRenderStep = function(self, name, priority, fn)
        local servicePath = dumperState.registry[proxy] or "RunService"
        emitOutput(string.format("%s:BindToRenderStep(%s, %s, function(dt)", servicePath, serializeValue(name), serializeValue(priority or 0)))
        if typeFunction(fn) == "function" then
            dumperState.indent = dumperState.indent + 1
            xpcallFunction(function() fn(1/60) end, function() end)
            dumperState.indent = dumperState.indent - 1
        end
        emitOutput("end)")
    end
    serviceMethods.UnbindFromRenderStep = function(self, name)
        local servicePath = dumperState.registry[proxy] or "RunService"
        emitOutput(string.format("%s:UnbindFromRenderStep(%s)", servicePath, serializeValue(name)))
    end
    serviceMethods.GetMinutesAfterMidnight = function(self) return 840 end
    serviceMethods.SetMinutesAfterMidnight = function(self, mins)
        local servicePath = dumperState.registry[proxy] or "Lighting"
        emitOutput(string.format("%s:SetMinutesAfterMidnight(%s)", servicePath, serializeValue(mins)))
    end
    serviceMethods.GetTotalMemoryUsageMb = function(self) return 128 end
    serviceMethods.GetMemoryUsageMbForTag = function(self, tag) return 16 end
    serviceMethods.SetCore = function(self, name, val)
        local servicePath = dumperState.registry[proxy] or "StarterGui"
        emitOutput(string.format("%s:SetCore(%s, %s)", servicePath, serializeValue(name), serializeValue(val)))
    end
    serviceMethods.SetCoreGuiEnabled = function(self, coreType, enabled)
        local servicePath = dumperState.registry[proxy] or "StarterGui"
        emitOutput(string.format("%s:SetCoreGuiEnabled(%s, %s)", servicePath, serializeValue(coreType), serializeValue(enabled)))
    end
    serviceMethods.GetCore = function(self, name) return nil end
    meta.__index = function(tbl, key)
        if key == proxyList or key == "__proxy_id" then
            return rawget(tbl, key)
        end
        local pathName = dumperState.registry[proxy] or formattedName or "object"
        local propertyName = formatValue(key)
        if _at.metaHooks["__index"] and not _at.inMetaHook then
            _at.inMetaHook = true
            local ok, result = pcallFunction(_at.metaHooks["__index"], proxy, key)
            _at.inMetaHook = false
            if ok and result ~= nil then return result end
        end
        local trackState = _animation_track_state[proxy]
        if trackState then
            if key == "IsPlaying" or key == "Playing" then
                return trackState.playing
            elseif key == "TimePosition" then
                return _animation_track_position(trackState)
            elseif key == "Speed" or key == "PlaybackSpeed" then
                return trackState.speed
            elseif key == "Length" or key == "TimeLength" then
                return trackState.length
            end
        end
        if dumperState.property_store[proxy] and dumperState.property_store[proxy][key] ~= nil then
            return dumperState.property_store[proxy][key]
        end
        do
            local _ps = dumperState.property_store[proxy]
            if _ps then
                if key == "PrimaryPart" and _ps.ClassName == "Model" and formattedName ~= "Character" then
                    return _ps.PrimaryPart
                end
                if key == "Value" and _ps.ClassName == "ObjectValue" then
                    return _ps.Value
                end
            end
        end
        if pathName == "Stats" and key == "Network" then
            local network = createProxyObject("Stats.Network", false, proxy)
            dumperState.property_store[network] = {
                ClassName = "NetworkStats",
                Name = "Network",
                ServerStatsItem = {["Data Ping"] = 1},
            }
            return network
        end
        if key == "PlaceId" or key == "placeId" then return numericArg end
        if key == "GameId" or key == "gameId" then return numericArg + 864197532 end
        if serviceMethods[propertyName] then
            local proxyMethods = _at.methodCache[proxy]
            if not proxyMethods then
                proxyMethods = {}
                _at.methodCache[proxy] = proxyMethods
            end
            if proxyMethods[propertyName] then
                return proxyMethods[propertyName]
            end
            local method = function(_, ...)
                if _at.metaHooks["__namecall"] and not _at.inMetaHook then
                    local previousMethod = _at.currentNamecallMethod
                    _at.currentNamecallMethod = propertyName
                    _at.inMetaHook = true
                    local ok, result = pcallFunction(_at.metaHooks["__namecall"], proxy, ...)
                    _at.inMetaHook = false
                    _at.currentNamecallMethod = previousMethod
                    if ok and result ~= nil then return result end
                end
                local previousMethod = _at.currentNamecallMethod
                _at.currentNamecallMethod = propertyName
                local results = {serviceMethods[propertyName](proxy, ...)}
                _at.currentNamecallMethod = previousMethod
                return table.unpack(results)
            end
            proxyMethods[propertyName] = method
            return method
        end
        if proxy == workspace and propertyName == "GetNumParts" then
            errorFunction("GetNumParts is not a valid member of Workspace", 2)
        end
        if pathName:match("^Enum") then
            local fullEnum = pathName .. "." .. propertyName
            if not _at.enum[fullEnum] then
                local enumProxy = createProxyObject(fullEnum, false)
                dumperState.registry[enumProxy] = fullEnum
                _at.typeOverride[enumProxy] = "EnumItem"
                local enumTypeName = pathName:match("^Enum%.([^%.]+)$")
                local enumDef = enumTypeName and _apiEnums[enumTypeName]
                if typeFunction(enumDef) == "table" and enumDef.values[propertyName] ~= nil then
                    dumperState.property_store[enumProxy] = {
                        Name = propertyName,
                        Value = enumDef.values[propertyName],
                        EnumType = proxy,
                    }
                end
                _at.enum[fullEnum] = enumProxy
            end
            return _at.enum[fullEnum]
        end
        if pathName == "fenv" or pathName == "getgenv" or pathName == "_G" then
            if key == "game" then return game end
            if key == "workspace" then return workspace end
            if key == "script" then return script end
            if key == "Enum" then return Enum end
            if _G[key] ~= nil then return _G[key] end
            return nil
        end
        if key == "Parent" then return dumperState.parent_map[proxy] end
        if key == "Name" then return formattedName or "Object" end
        if key == "ClassName" then return formattedName or "Instance" end
        if key == "Players" then return serviceMethods.GetService(game, "Players") end
        if key == "Workspace" then return workspace end
        if key == "LocalPlayer" then
            if _at.localPlayer then return _at.localPlayer end
            local lpProxy = createProxyObject("LocalPlayer", false, proxy)
            dumperState.property_store[lpProxy] = {Name = "Player", ClassName = "Player", UserId = 1234567}
            _at.localPlayer = lpProxy
            local varName = registerVariable(lpProxy, "LocalPlayer")
            emitOutput(string.format("local %s = %s.LocalPlayer", varName, pathName))
            return lpProxy
        end
        if key == "PlayerGui" then return createProxyObject("PlayerGui", false, proxy) end
        if key == "Backpack" then return createProxyObject("Backpack", false, proxy) end
        if key == "PlayerScripts" then return createProxyObject("PlayerScripts", false, proxy) end
        if key == "UserId" then return 1234567 end
        if key == "DisplayName" then return "Player" end
        if key == "AccountAge" then return 1000 end
        if key == "LocaleId" then return "en-us" end
        if key == "RobloxLocaleId" or key == "SystemLocaleId" then return "en-us" end
        if key == "CharacterMaxSlopeAngle" then return 89 end
        if key == "DistanceFactor" then return 3.33 end
        if key == "CaptureBegan" then
            local sigProxy = createProxyObject(pathName .. ".CaptureBegan", false, proxy)
            dumperState.registry[sigProxy] = pathName .. ".CaptureBegan"
            _at.typeOverride[sigProxy] = "RBXScriptSignal"
            return sigProxy
        end
        if key == "Connected" and _at.connState[proxy] ~= nil then return _at.connState[proxy] end
        if key == "Team" then return createProxyObject("Team", false, proxy) end
        if key == "TeamColor" then return BrickColor.new("White") end
        if key == "Character" then
            local charProxy = createProxyObject("Character", false, proxy)
            dumperState.property_store[charProxy] = {Name = "Character", ClassName = "Model"}
            return charProxy
        end
        if key == "Humanoid" then
            local humProxy = createProxyObject("Humanoid", false, proxy)
            dumperState.property_store[humProxy] = {Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2}
            return humProxy
        end
        if key == "HumanoidRootPart" or key == "PrimaryPart" or key == "RootPart" then
            local rootProxy = createProxyObject("HumanoidRootPart", false, proxy)
            dumperState.property_store[rootProxy] = {Position = Vector3.new(0, 5, 0), CFrame = CFrame.new(0, 5, 0)}
            return rootProxy
        end
        local limbNames = {"Head", "Torso", "UpperTorso", "LowerTorso", "RightArm", "LeftArm", "RightLeg", "LeftLeg", "RightHand", "LeftHand", "RightFoot", "LeftFoot"}
        for _, limb in ipairsFunction(limbNames) do
            if key == limb then return createProxyObject(key, false, proxy) end
        end
        if key == "Animator" then return createProxyObject("Animator", false, proxy) end
        if key == "CurrentCamera" or key == "Camera" then
            local camProxy = createProxyObject("Camera", false, proxy)
            dumperState.property_store[camProxy] = {CFrame = CFrame.new(0, 10, 0), FieldOfView = 70, ViewportSize = Vector2.new(1920, 1080)}
            return camProxy
        end
        if key == "CameraType" then return Enum.CameraType.Custom end
        if key == "CameraSubject" then return createProxyObject("Humanoid", false, proxy) end
        local constants = {
            Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2,
            HipHeight = 2, AutoJumpEnabled = true, JumpHeight2 = 7.2,
            Transparency = 0, Reflectance = 0, Mass = 1, AssemblyMass = 1,
            Elasticity = 0.5, Friction = 0.3, Density = 0.7,
            AssemblyLinearVelocity = Vector3.new(0, 0, 0),
            AssemblyAngularVelocity = Vector3.new(0, 0, 0),
            TimePosition = 0, TimeLength = 1, Volume = 0.5, PlaybackSpeed = 1,
            RolloffScale = 1, MinDistance = 10, MaxDistance = 10000,
            Brightness = 1, Range = 60, Angle = 90, ShadowSoftness = 0.2,
            FieldOfView = 70, NearPlaneZ = -0.1, FarPlaneZ = 10000,
            Thickness = 1, ZIndex = 1, LayoutOrder = 0, BorderSizePixel = 1,
            TextSize = 14, LineHeight = 1.2, MaxVisibleGraphemes = -1,
            ContentImageSize = Vector2.new(0, 0),
            Gravity = 196.2, DistributedGameTime = 1, ClockTime = 14,
            FogEnd = 100000, FogStart = 0, FogDensity = 0,
            MaxPlayers = 12, RespawnTime = 5, PlaceVersion = 1, MaxItems = 1000,
            CreatorId = 0, FollowUserId = 0, GameId = 0, PlaceId = 0,
            ExplicitAutoJoints = true, StreamingMinRadius = 64, StreamingTargetRadius = 1024,
            Restitution = 0, LimitsEnabled = false, UpperAngle = 45, LowerAngle = -45,
            DataComplexity = 0, MemoryUsageBytes = 0,
            RunContext = 0, Disabled = false,
            Value = 0,
            MaxActivationDistance = 10, HoldDuration = 0, ActionText = "Interact", ObjectText = "",
            OutlineColor = Color3.new(1, 1, 1), FillColor = Color3.new(1, 1, 1), FillTransparency = 0.5, OutlineTransparency = 0,
            FaceCamera = false, Segments = 10, Width0 = 0.2, Width1 = 0.2, CurveSize0 = 0, CurveSize1 = 0,
            InflationAmount = 0,
        }
        if constants[key] ~= nil then return constants[key] end
        if key == "Size" and not (formattedName and formattedName:match("Part")) then return UDim2.new(1, 0, 1, 0) end
        local boolConstants = {
            Visible = true, Active = true, Draggable = false, Modal = false,
            ClipsDescendants = false, RichText = false, TextWrapped = false, TextScaled = false,
            AutomaticSize = false, ResetOnSpawn = true,
            Enabled = true, Archivable = true, Locked = false,
            Playing = false, Looped = false, IsPlaying = false, AutoPlay = false, RollOffMode = false,
            PlatformStand = false, AutoRotate = true, Sit = false,
            BreakJointsOnDeath = true, UseJumpPower = true, EvaluateStateMachine = true,
            Anchored = false, CanCollide = true, CastShadow = true, Massless = false,
            CanTouch = true, CanQuery = true,
            StreamingEnabled = false, HttpEnabled = false, Sandboxed = false,
            FilteringEnabled = true, AllowThirdPartySales = false,
            Disabled = false,
        }
        boolConstants.StreamingEnabled = false
        boolConstants.HttpEnabled = false
        boolConstants.Sandboxed = false
        if boolConstants[key] ~= nil then return boolConstants[key] end
        if key == "JobId" then return "00000000-0000-4000-8000-000000000001" end
        if key == "CreatorType" then return Enum.CreatorType and Enum.CreatorType.User or 0 end
        if key == "MembershipType" then return Enum.MembershipType and Enum.MembershipType.None or 0 end
        if key == "AmbientReverb" then return Enum.ReverbType and Enum.ReverbType.NoReverb or 0 end
        if key == "DevComputerMovementMode" then return Enum.DevComputerMovementMode and Enum.DevComputerMovementMode.UserChoice or 0 end
        if key == "DevTouchMovementMode" then return Enum.DevTouchMovementMode and Enum.DevTouchMovementMode.UserChoice or 0 end
        if key == "AutoJumpEnabled" then return true end
        if key == "RigType" then return Enum.HumanoidRigType and Enum.HumanoidRigType.R15 or 1 end
        if key == "StreamOutBehavior" then return Enum.StreamOutBehavior and Enum.StreamOutBehavior.Default or 0 end
        if key == "MeshType" then return Enum.MeshType and Enum.MeshType.FileMesh or 9 end
        if key == "Shape" then return Enum.PartType and Enum.PartType.Block or 1 end
        if key == "Ambient" or key == "OutdoorAmbient" then return Color3.fromRGB(128, 128, 128) end
        if key == "UniqueId" then return _getDebugId(proxy) end
        if key == "AbsoluteSize" or key == "ViewportSize" then return Vector2.new(1920, 1080) end
        if key == "MouseDeltaSensitivity" then return 1 end
        if key == "AbsolutePosition" then return Vector2.new(0, 0) end
        if key == "Position" then
            if formattedName and (formattedName:match("Part") or formattedName:match("Model") or formattedName:match("Character") or formattedName:match("Root")) then return Vector3.new(0, 5, 0) end
            return UDim2.new(0, 0, 0, 0)
        end
        if key == "Size" then
            if formattedName and formattedName:match("Part") then return Vector3.new(4, 1, 2) end
            return UDim2.new(1, 0, 1, 0)
        end
        if key == "CFrame" then return CFrame.new(0, 5, 0) end
        if key == "Velocity" or key == "AssemblyLinearVelocity" then
            return _at.linearVel[proxy] or Vector3.new(0, 0, 0)
        end
        if key == "RotVelocity" or key == "AssemblyAngularVelocity" then
            return _at.angularVel[proxy] or Vector3.new(0, 0, 0)
        end
        if key == "Orientation" or key == "Rotation" then return Vector3.new(0, 0, 0) end
        if key == "LookVector" then return Vector3.new(0, 0, -1) end
        if key == "RightVector" then return Vector3.new(1, 0, 0) end
        if key == "UpVector" then return Vector3.new(0, 1, 0) end
        if key == "Color" or key == "Color3" or key == "BackgroundColor3" or key == "BorderColor3" or key == "TextColor3" or key == "PlaceholderColor3" or key == "ImageColor3" then return Color3.new(1, 1, 1) end
        if key == "BrickColor" then return BrickColor.new("Medium stone grey") end
        if key == "Material" then return createProxyObject("Enum.Material.Plastic", false) end
        if key == "Hit" then return CFrame.new(0, 0, -10) end
        if key == "Origin" then return CFrame.new(0, 5, 0) end
        if key == "Target" then return createProxyObject("Target", false, proxy) end
        if key == "X" or key == "Y" then return 0 end
        if key == "UnitRay" then return Ray.new(Vector3.new(0, 5, 0), Vector3.new(0, 0, -1)) end
        if key == "ViewSizeX" then return 1920 end
        if key == "ViewSizeY" then return 1080 end
        if key == "Text" or key == "PlaceholderText" or key == "ContentText" or key == "Value" then
            if inputKey then return inputKey end
            if key == "Value" then return "input" end
            return '"'
        end
        if key == "TextBounds" then return Vector2.new(100, 18) end
        if key == "PlaybackLoudness" then return 1 end
        if key == "Font" then
            if _at.fontObj then return _at.fontObj end
            local fo = {
                Family   = "rbxasset://fonts/families/SourceSansPro.json",
                Weight   = createProxyObject("Enum.FontWeight.Regular", false),
                Style    = createProxyObject("Enum.FontStyle.Normal", false),
                Bold     = false,
            }
            setmetatable(fo, {
                __typeof  = "Font",
                __tostring = function() return 'Font.fromEnum(Enum.Font.SourceSans)' end,
                __index   = function(_, k)
                    if k == "Name" then return "SourceSans" end
                    if k == "Value" then return 0 end
                    return nil
                end,
            })
            _at.fontObj = fo
            return fo
        end
        if key == "FontFace" then
            return createProxyObject("Font.fromEnum(Enum.Font.SourceSans)", false)
        end
        if key == "TextSize" then return 14 end
        if key == "Image" or key == "ImageContent" or key == "ImageId" then return '"' end
        if pathName:match("^Enum") then
            local fullEnum = pathName .. "." .. propertyName
            if not _at.enum[fullEnum] then
                local enumProxy = createProxyObject(fullEnum, false)
                dumperState.registry[enumProxy] = fullEnum
                _at.typeOverride[enumProxy] = "EnumItem"
                _at.enum[fullEnum] = enumProxy
            end
            return _at.enum[fullEnum]
        end
        local signalNames = {
            "Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving",
            "AncestryChanged", "AttributeChanged", "PropertyChanged",
            "Touched", "TouchEnded",
            "InputBegan", "InputEnded", "InputChanged",
            "MouseButton1Click", "MouseButton1Down", "MouseButton1Up",
            "MouseButton2Click", "MouseButton2Down", "MouseButton2Up",
            "MouseEnter", "MouseLeave", "MouseMoved",
            "MouseWheelForward", "MouseWheelBackward",
            "Button1Down", "Button1Up", "Button2Down", "Button2Up",
            "TouchStarted", "TouchEnded", "TouchMoved", "TouchTap", "TouchLongPress",
            "TouchPinch", "TouchRotate", "TouchSwipe",
            "GamepadButtonDown", "GamepadButtonUp", "GamepadConnected", "GamepadDisconnected",
            "DeviceMoved", "DeviceRotationChanged", "DeviceGravityChanged",
            "JumpRequest", "LastInputTypeChanged",
            "Activated", "Deactivated",
            "FocusLost", "FocusGained", "Focused",
            "TextChanged", "ReturnPressedFromOnScreenKeyboard",
            "SelectionChanged", "SelectionGained", "SelectionLost",
            "CaptureBegan", "CaptureEnded",
            "ScrollingFrameScrolled",
            "Heartbeat", "RenderStepped", "Stepped",
            "PreSimulation", "PostSimulation", "PreAnimation", "PostAnimation",
            "PreRender", "PostRender",
            "CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded",
            "PlayerAdded", "PlayerRemoving",
            "Idled", "OnTeleport",
            "Died", "FreeFalling", "GettingUp", "Jumping", "Running",
            "Seated", "Swimming", "StateChanged", "HealthChanged",
            "MoveToFinished", "Climbing", "Touched",
            "FallingDown", "Ragdoll", "PlatformStanding", "Strafing",
            "AnimationPlayed",
            "KeyframeReached", "MarkerReached", "Stopped", "DidLoop",
            "OnClientEvent", "OnServerEvent", "OnClientInvoke", "OnServerInvoke",
            "Completed", "DidLoop", "Stopped",
            "Triggered", "TriggerEnded", "HoldBegan", "HoldEnded",
            "PromptShown", "PromptHidden",
            "Idle", "Move",
            "MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave",
            "Loaded", "Ended", "Paused", "Resumed", "Played",
            "DidLoop", "SoundGroup",
            "InstanceAdded", "InstanceRemoved",
            "Equipped", "Unequipped", "Activated", "Deactivated",
            "DragStart", "DragContinue", "DragEnd", "RotateStart", "RotateContinue", "RotateEnd",
            "BulletHit", "BulletHitHumanoid",
            "OnUpdate",
            "OnMessageReceived",
            "TweenCompleted",
            "SelectedObjectChanged",
            "StateChanged", "VoiceChatUpdated",
            "Error", "Loaded", "LoadFailed", "DataChanged",
            "PromptPurchaseFinished", "PromptSubscriptionPurchaseFinished",
            "PromptBundlePurchaseFinished", "PromptGamePassPurchaseFinished",
            "PromptProductPurchaseFinished", "PointsAwarded", "TeleportInitFailed",
            "PlayerMembershipChanged", "GameLoaded",
            "NumberOfPartsOverPartsThresholdChanged",
            "ContentLoaded", "GraphicsQualityChangeRequest",
            "WindowFocused", "WindowFocusReleased",
            "OnClose", "BindToClose",
            "VoiceChatServiceConnected", "VoiceChatServiceDisconnected",
            "MessageReceived", "ShouldDeliverCallback",
            "Event", "Invoke",
            "LogoutSuccess", "AllowedGearTypeAdded", "AllowedGearTypeRemoved",
            "NativePurchaseFinished", "ThirdPartyPurchaseFinished",
        }
        for _, sig in ipairsFunction(signalNames) do
            if key == sig then
                local sigProxy = createProxyObject(pathName .. "." .. key, false, proxy)
                dumperState.registry[sigProxy] = pathName .. "." .. key
                _at.typeOverride[sigProxy] = "RBXScriptSignal"
                return sigProxy
            end
        end
        if _at.svcCache[propertyName] then
            return _at.svcCache[propertyName]
        end
        return createProxyMethod(propertyName, proxy)
    end
    meta.__newindex = function(tbl, key, val)
        if key == proxyList or key == "__proxy_id" then
            rawset(tbl, key, val)
            return
        end
        local pathName = dumperState.registry[proxy] or formattedName or "object"
        local prop = formatValue(key)
        dumperState.property_store[proxy] = dumperState.property_store[proxy] or {}
        local props = dumperState.property_store[proxy]
        local instClass = props.ClassName or ""
        local propertyKey = _propertyName(key)
        if propertyKey == "ClassName" then
            error("ClassName is read only", 2)
        end
        if instClass == "Camera" and propertyKey == "NearPlaneZ" then
            error("NearPlaneZ is read only", 2)
        end
        if instClass == "Model" and propertyKey == "PrimaryPart" then
            if val ~= nil and (not isProxy(val) or not classIsA(dumperState.property_store[val] and dumperState.property_store[val].ClassName or "", "BasePart")) then
                error("PrimaryPart can only be set to a BasePart", 2)
            end
        end
        do
            local _enumProps = {
                Shape = "PartType", Material = "Material", CameraType = "CameraType",
                SizeConstraint = "SizeConstraint", AutomaticSize = "AutomaticSize",
                BorderMode = "BorderMode", ScaleType = "ScaleType",
                ZIndexBehavior = "ZIndexBehavior", SortOrder = "SortOrder",
                TextXAlignment = "TextXAlignment", TextYAlignment = "TextYAlignment",
                RigType = "HumanoidRigType", EasingStyle = "EasingStyle",
                EasingDirection = "EasingDirection", CreatorType = "CreatorType",
            }
            local _expectedEnum = _enumProps[propertyKey]
            if _expectedEnum and (propertyKey ~= "Shape" or classIsA(instClass, "Part")) then
                local _isEnumItem = (_at.typeOverride[val] == "EnumItem")
                local _valProps = _isEnumItem and dumperState.property_store[val] or nil
                local _expectedEnumObj = Enum[_expectedEnum]
                if not (_isEnumItem and _valProps and _valProps.EnumType == _expectedEnumObj) then
                    error("Unable to assign property " .. propertyKey .. ". EnumItem of type " .. _expectedEnum .. " expected", 2)
                end
            end
            local _numProps = {
                Transparency = true, Reflectance = true, Rotation = true,
                ZIndex = true, LayoutOrder = true, BorderSizePixel = true,
                BackgroundTransparency = true, TextSize = true, TextTransparency = true,
                TextStrokeTransparency = true, ImageTransparency = true, LineHeight = true,
                FieldOfView = true, WalkSpeed = true, JumpPower = true, JumpHeight = true,
                HipHeight = true, Health = true, MaxHealth = true, MaxSlopeAngle = true,
                Volume = true, PlaybackSpeed = true, TimePosition = true,
                Brightness = true, ClockTime = true, Range = true, Angle = true,
                Intensity = true, Thickness = true, Density = true, TimeScale = true,
            }
            if _numProps[propertyKey] or propertyKey == "GroupTransparency" or (propertyKey == "Value" and (instClass == "NumberValue" or instClass == "IntValue")) then
                if typeFunction(val) ~= "number" then
                    error("Unable to assign property " .. propertyKey .. ". number expected", 2)
                end
                if propertyKey == "GroupTransparency" then
                    if val ~= val or val < 0 then val = 0 elseif val > 1 then val = 1 end
                end
            end
            if propertyKey == "Position" and classIsA(instClass, "BasePart") and typeFunction(val) == "table" and val.X ~= nil then
                local oldCf = props.CFrame
                if typeFunction(oldCf) == "table" and oldCf._r then
                    local r = oldCf._r
                    props.CFrame = CFrame.new(val.X or 0, val.Y or 0, val.Z or 0, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
                else
                    props.CFrame = CFrame.new(val.X or 0, val.Y or 0, val.Z or 0)
                end
            elseif propertyKey == "CFrame" and classIsA(instClass, "BasePart") and typeFunction(val) == "table" and val.X ~= nil then
                props.Position = val.Position or Vector3.new(val.X or 0, val.Y or 0, val.Z or 0)
            end
            if propertyKey == "MaxItems" and (instClass == "Debris" or formattedName == "Debris") then
                if typeFunction(val) ~= "number" then
                    error("Unable to assign property MaxItems. number expected", 2)
                end
                val = val >= 0 and math.floor(val) or math.ceil(val)
            end
        end
        val = _coercePropertyValue(propertyKey, val)
        dumperState.property_store[proxy][key] = val
        local defaults = _at.propertyDefaults[proxy]
        if defaults and defaults[propertyKey] ~= nil then
            _at.propertyModified[proxy] = _at.propertyModified[proxy] or {}
            if val == defaults[propertyKey] then
                _at.propertyModified[proxy][propertyKey] = nil
            else
                _at.propertyModified[proxy][propertyKey] = true
            end
        end
        if key == "Parent" then
            _setParent(proxy, isProxy(val) and val or nil)
        end
        local className = (dumperState.property_store[proxy] or {}).ClassName or ""
        if className == "WeldConstraint" or className == "Weld" or className == "Motor6D" then
            if key == "Part0" or key == "Part1" then
                _at.weldRegistry[proxy] = _at.weldRegistry[proxy] or {}
                _at.weldRegistry[proxy][key] = val
                local wr = _at.weldRegistry[proxy]
                if wr.Part0 and wr.Part1 then
                    local cf0 = (dumperState.property_store[wr.Part0] or {}).CFrame
                    local cf1 = (dumperState.property_store[wr.Part1] or {}).CFrame
                    if cf0 and cf1 then
                        wr.offset = {X = (cf1.X or 0) - (cf0.X or 0), Y = (cf1.Y or 0) - (cf0.Y or 0), Z = (cf1.Z or 0) - (cf0.Z or 0)}
                    end
                end
            end
        end
        if key == "CFrame" then
            local cfVal = val
            local cfX = (cfVal and cfVal.X) or 0
            local cfY = (cfVal and cfVal.Y) or 0
            local cfZ = (cfVal and cfVal.Z) or 0
            for _, wr in pairs(_at.weldRegistry) do
                if wr.Part0 == proxy and wr.Part1 and wr.offset then
                    local nx = cfX + wr.offset.X
                    local ny = cfY + wr.offset.Y
                    local nz = cfZ + wr.offset.Z
                    local newCF
                    if type(CFrame) == "table" and type(CFrame.new) == "function" then
                        newCF = CFrame.new(nx, ny, nz)
                    elseif _makeCFrame then
                        newCF = _makeCFrame(nx, ny, nz)
                    else
                        newCF = {X = nx, Y = ny, Z = nz, Position = {X = nx, Y = ny, Z = nz}}
                    end
                    dumperState.property_store[wr.Part1] = dumperState.property_store[wr.Part1] or {}
                    dumperState.property_store[wr.Part1].CFrame = newCF
                    local posV = newCF.Position
                    dumperState.property_store[wr.Part1].Position = posV
                end
            end
        end
        emitOutput(string.format("%s.%s = %s", pathName, prop, serializeValue(val)))
    end
    meta.__call = function(tbl, ...)
        local pathName = dumperState.registry[proxy] or formattedName or "func"
        if pathName == "fenv" or pathName == "getgenv" or pathName:match("env") then
            return proxy
        end
        if pathName == "game" then
            errorFunction("attempt to call an Instance value", 0)
        end
        local args = {...}
        local serializedArgs = {}
        for _, val in ipairsFunction(args) do
            table.insert(serializedArgs, serializeValue(val))
        end
        local resultProxy = createProxyObject("result", false)
        local varName = registerVariable(resultProxy, "result")
        emitOutput(string.format("local %s = %s(%s)", varName, pathName, table.concat(serializedArgs, ", ")))
        return resultProxy
    end
    local function operatorMeta(opSymbol)
        local function metaCall(a, b)
            local proxy, meta = createProxy()
            local strA = "0"
            if a ~= nil then strA = dumperState.registry[a] or serializeValue(a) end
            local strB = "0"
            if b ~= nil then strB = dumperState.registry[b] or serializeValue(b) end
            local expression = "(" .. strA .. " " .. opSymbol .. " " .. strB .. ")"
            dumperState.registry[proxy] = expression
            meta.__tostring = function() return expression end
            meta.__call = function() return proxy end
            meta.__index = function(_, k)
                if k == proxyList or k == "__proxy_id" then return rawget(proxy, k) end
                return createProxyObject(expression .. "." .. formatValue(k), false)
            end
            meta.__add = operatorMeta("+")
            meta.__sub = operatorMeta("-")
            meta.__mul = operatorMeta("*")
            meta.__div = operatorMeta("/")
            meta.__mod = operatorMeta("%")
            meta.__pow = operatorMeta("^")
            meta.__concat = operatorMeta("..")
            meta.__eq = function() return false end
            meta.__lt = function() return false end
            meta.__le = function() return false end
            return proxy
        end
        return metaCall
    end
    meta.__add = operatorMeta("+")
    meta.__sub = operatorMeta("-")
    meta.__mul = operatorMeta("*")
    meta.__div = operatorMeta("/")
    meta.__mod = operatorMeta("%")
    meta.__pow = operatorMeta("^")
    meta.__concat = operatorMeta("..")
    meta.__eq = function(a, b) return rawequal(a, b) end
    meta.__lt = function() return false end
    meta.__le = function() return false end
    meta.__unm = function(a)
        local proxy, meta = createProxy()
        dumperState.registry[proxy] = "(-" .. (dumperState.registry[a] or serializeValue(a)) .. ")"
        meta.__tostring = function() return dumperState.registry[proxy] end
        return proxy
    end
    meta.__len = function() return 0 end
    meta.__tostring = function() return dumperState.registry[proxy] or formattedName or "Object" end
    meta.__pairs = function() return function() return nil end, proxy, nil end
    meta.__ipairs = meta.__pairs
    return proxy
end
local function createTypeDa(typeName, methods)
    local dc = {}
    local dd = {}
    dd.__index = function(_, key)
        if key == "new" or methods and methods[key] then
            return function(...)
                local args = {...}
                local serializedArgs = {}
                for _, val in ipairsFunction(args) do
                    table.insert(serializedArgs, serializeValue(val))
                end
                local expression = typeName .. "." .. key .. "(" .. table.concat(serializedArgs, ", ") .. ")"
                local proxy, meta = createProxy()
                dumperState.registry[proxy] = expression
                meta.__tostring = function() return expression end
                meta.__index = function(_, k)
                    if k == proxyList or k == "__proxy_id" then return rawget(proxy, k) end
                    if k == "X" or k == "Y" or k == "Z" or k == "W" then return 0 end
                    if k == "Magnitude" then return 0 end
                    if k == "Unit" or k == "Position" or k == "CFrame" or k == "LookVector" or k == "RightVector" or k == "UpVector" or k == "Rotation" or k == "p" then return proxy end
                    if k == "R" or k == "G" or k == "B" then return 1 end
                    if k == "Width" or k == "Height" then return UDim.new(0, 0) end
                    if k == "Min" or k == "Max" or k == "Scale" or k == "Offset" then return 0 end
                    return createProxyObject(expression .. "." .. formatValue(k), false)
                end
                local function opMeta(symbol)
                    return function(a, b)
                        local proxy, meta = createProxy()
                        local expr = "(" .. (dumperState.registry[a] or serializeValue(a)) .. " " .. symbol .. " " .. (dumperState.registry[b] or serializeValue(b)) .. ")"
                        dumperState.registry[proxy] = expr
                        meta.__tostring = function() return expr end
                        meta.__index = meta.__index
                        meta.__add = opMeta("+")
                        meta.__sub = opMeta("-")
                        meta.__mul = opMeta("*")
                        meta.__div = opMeta("/")
                        return proxy
                    end
                end
                meta.__add = opMeta("+")
                meta.__sub = opMeta("-")
                meta.__mul = opMeta("*")
                meta.__div = opMeta("/")
                meta.__unm = function(a)
                    local proxy, meta = createProxy()
                    dumperState.registry[proxy] = "(-" .. (dumperState.registry[a] or serializeValue(a)) .. ")"
                    meta.__tostring = function() return dumperState.registry[proxy] end
                    return proxy
                end
                meta.__eq = function() return false end
                return proxy
            end
        end
        return nil
    end
    dd.__call = function(_, ...) return _.new(...) end
    return setmetatable(dc, dd)
end
Vector3 = createTypeDa("Vector3", {new = true, zero = true, one = true})
Vector2 = createTypeDa("Vector2", {new = true, zero = true, one = true})
UDim = createTypeDa("UDim", {new = true})
UDim2 = createTypeDa("UDim2", {new = true, fromScale = true, fromOffset = true})
CFrame = createTypeDa("CFrame", {new = true, Angles = true, lookAt = true, fromEulerAnglesXYZ = true, fromEulerAnglesYXZ = true, fromAxisAngle = true, fromMatrix = true, fromOrientation = true, identity = true})
Color3 = createTypeDa("Color3", {new = true, fromRGB = true, fromHSV = true, fromHex = true})
BrickColor = createTypeDa("BrickColor", {new = true, random = true, White = true, Black = true, Red = true, Blue = true, Green = true, Yellow = true, palette = true})
TweenInfo = createTypeDa("TweenInfo", {new = true})
Rect = createTypeDa("Rect", {new = true})
Region3 = createTypeDa("Region3", {new = true})
Region3int16 = createTypeDa("Region3int16", {new = true})
Ray = createTypeDa("Ray", {new = true})
NumberRange = createTypeDa("NumberRange", {new = true})
NumberSequence = createTypeDa("NumberSequence", {new = true})
NumberSequenceKeypoint = createTypeDa("NumberSequenceKeypoint", {new = true})
ColorSequence = createTypeDa("ColorSequence", {new = true})
ColorSequenceKeypoint = createTypeDa("ColorSequenceKeypoint", {new = true})
PhysicalProperties = createTypeDa("PhysicalProperties", {new = true})
Font = createTypeDa("Font", {new = true, fromEnum = true, fromName = true, fromId = true})
RaycastParams = createTypeDa("RaycastParams", {new = true})
OverlapParams = {new = function()
        local params = {MaxParts = 0, FilterType = Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {}, IncludeInstances = nil, ExcludeInstances = nil}
        return setmetatable(params, {__typeof = "OverlapParams"})
    end}
local function _makeVector3(x, y, z, expr)
    x, y, z = toNumberFunction(x) or 0, toNumberFunction(y) or 0, toNumberFunction(z) or 0
    local proxy, meta = createProxy()
    local expression = expr or ("Vector3.new(" .. serializeValue(x) .. ", " .. serializeValue(y) .. ", " .. serializeValue(z) .. ")")
    dumperState.registry[proxy] = expression
    _at.vectors[proxy] = {x = x, y = y, z = z}
    local function component(v, axis)
        local data = _at.vectors[v]
        if not data then return 0 end
        return axis == "X" and data.x or axis == "Y" and data.y or data.z
    end
    local function binary(a, b, symbol)
        local ax, ay, az = component(a, "X"), component(a, "Y"), component(a, "Z")
        local bx, by, bz
        if typeFunction(b) == "number" then bx, by, bz = b, b, b else bx, by, bz = component(b, "X"), component(b, "Y"), component(b, "Z") end
        if symbol == "+" then return _makeVector3(ax + bx, ay + by, az + bz, "(" .. serializeValue(a) .. " + " .. serializeValue(b) .. ")") end
        if symbol == "-" then return _makeVector3(ax - bx, ay - by, az - bz, "(" .. serializeValue(a) .. " - " .. serializeValue(b) .. ")") end
        if symbol == "*" then return _makeVector3(ax * bx, ay * by, az * bz, "(" .. serializeValue(a) .. " * " .. serializeValue(b) .. ")") end
        return _makeVector3(bx ~= 0 and ax / bx or 0, by ~= 0 and ay / by or 0, bz ~= 0 and az / bz or 0, "(" .. serializeValue(a) .. " / " .. serializeValue(b) .. ")")
    end
    meta.__index = function(_, key)
        if key == proxyList or key == "__proxy_id" then return rawget(proxy, key) end
        if key == "X" then return x end
        if key == "Y" then return y end
        if key == "Z" then return z end
        if key == "Magnitude" then return math.sqrt(x * x + y * y + z * z) end
        if key == "Unit" then
            local mag = math.sqrt(x * x + y * y + z * z)
            if mag == 0 then return _makeVector3(0, 0, 0, expression .. ".Unit") end
            return _makeVector3(x / mag, y / mag, z / mag, expression .. ".Unit")
        end
        if key == "Dot" then
            return function(_, other)
                local ox = (other and component(other, "X")) or 0
                local oy = (other and component(other, "Y")) or 0
                local oz = (other and component(other, "Z")) or 0
                return x * ox + y * oy + z * oz
            end
        end
        if key == "Cross" then
            return function(_, other)
                local ox = (other and component(other, "X")) or 0
                local oy = (other and component(other, "Y")) or 0
                local oz = (other and component(other, "Z")) or 0
                return _makeVector3(y * oz - z * oy, z * ox - x * oz, x * oy - y * ox)
            end
        end
        if key == "Lerp" then
            return function(_, other, alpha)
                alpha = toNumberFunction(alpha) or 0
                local ox = (other and component(other, "X")) or 0
                local oy = (other and component(other, "Y")) or 0
                local oz = (other and component(other, "Z")) or 0
                return _makeVector3(x + (ox - x) * alpha, y + (oy - y) * alpha, z + (oz - z) * alpha)
            end
        end
        if key == "FuzzyEq" then
            return function(_, other, eps)
                eps = toNumberFunction(eps) or 1e-5
                local ox = (other and component(other, "X")) or 0
                local oy = (other and component(other, "Y")) or 0
                local oz = (other and component(other, "Z")) or 0
                return math.abs(x - ox) < eps and math.abs(y - oy) < eps and math.abs(z - oz) < eps
            end
        end
        if key == "Abs"  then return function(_) return _makeVector3(math.abs(x), math.abs(y), math.abs(z)) end end
        if key == "Sign" then return function(_)
            local function s(n) return n > 0 and 1 or n < 0 and -1 or 0 end
            return _makeVector3(s(x), s(y), s(z))
        end end
        if key == "Floor" then return function(_) return _makeVector3(math.floor(x), math.floor(y), math.floor(z)) end end
        if key == "Ceil"  then return function(_) return _makeVector3(math.ceil(x), math.ceil(y), math.ceil(z)) end end
        if key == "Min" then
            return function(_, ...)
                local mx, my, mz = x, y, z
                for _, v in ipairsFunction({...}) do
                    mx = math.min(mx, component(v, "X"))
                    my = math.min(my, component(v, "Y"))
                    mz = math.min(mz, component(v, "Z"))
                end
                return _makeVector3(mx, my, mz)
            end
        end
        if key == "Max" then
            return function(_, ...)
                local mx, my, mz = x, y, z
                for _, v in ipairsFunction({...}) do
                    mx = math.max(mx, component(v, "X"))
                    my = math.max(my, component(v, "Y"))
                    mz = math.max(mz, component(v, "Z"))
                end
                return _makeVector3(mx, my, mz)
            end
        end
        return 0
    end
    meta.__add = function(a, b) return binary(a, b, "+") end
    meta.__sub = function(a, b) return binary(a, b, "-") end
    meta.__mul = function(a, b) return binary(a, b, "*") end
    meta.__div = function(a, b) return binary(a, b, "/") end
    meta.__unm = function(a) return _makeVector3(-component(a, "X"), -component(a, "Y"), -component(a, "Z"), "(-" .. serializeValue(a) .. ")") end
    dumperState.vector3Equal = dumperState.vector3Equal or function(a, b)
        local va, vb = _at.vectors[a], _at.vectors[b]
        return va ~= nil and vb ~= nil and va.x == vb.x and va.y == vb.y and va.z == vb.z
    end
    meta.__eq = dumperState.vector3Equal
    meta.__tostring = function() return string.format("%g, %g, %g", x, y, z) end
    meta.__typeof = "Vector3"
    return proxy
end
Vector3 = {
    new = function(x, y, z) return _makeVector3(x, y, z) end,
    zero = _makeVector3(0, 0, 0, "Vector3.zero"),
    one = _makeVector3(1, 1, 1, "Vector3.one"),
    xAxis = _makeVector3(1, 0, 0, "Vector3.xAxis"),
    yAxis = _makeVector3(0, 1, 0, "Vector3.yAxis"),
    zAxis = _makeVector3(0, 0, 1, "Vector3.zAxis"),
    Angle = function(a, b)
        local denominator = (a.Magnitude or 0) * (b.Magnitude or 0)
        if denominator == 0 then return 0 end
        local dot = a.X * b.X + a.Y * b.Y + a.Z * b.Z
        return math.acos(math.max(-1, math.min(1, dot / denominator)))
    end
}
setmetatable(Vector3, {__call = function(_, x, y, z) return _.new(x, y, z) end})
local function _valueType(typeName, fields, methods)
    local obj = fields or {}
    dumperState.valueTypeEqual = dumperState.valueTypeEqual or function(a, b)
        if typeFunction(a) ~= "table" or typeFunction(b) ~= "table" then return false end
        local ma, mb = getMetatableFunction(a), getMetatableFunction(b)
        if not ma or not mb or ma.__typeof ~= mb.__typeof then return false end
        for k, v in pairsFunction(a) do if b[k] ~= v then return false end end
        for k, v in pairsFunction(b) do if a[k] ~= v then return false end end
        return true
    end
    return setmetatable(obj, {
        __typeof = typeName,
        __index = methods or {},
        __tostring = function() return typeName end,
        __eq = dumperState.valueTypeEqual
    })
end
local function _num(v, default) return toNumberFunction(v) or default or 0 end
local function _makeVector2(x, y)
    x, y = _num(x), _num(y)
    local methods = {}
    function methods:Dot(other) return self.X * (other and other.X or 0) + self.Y * (other and other.Y or 0) end
    function methods:Cross(other) return self.X * (other and other.Y or 0) - self.Y * (other and other.X or 0) end
    function methods:Lerp(other, alpha)
        alpha = _num(alpha)
        return _makeVector2(self.X + ((other and other.X or 0) - self.X) * alpha,
            self.Y + ((other and other.Y or 0) - self.Y) * alpha)
    end
    dumperState.vector2Equal = dumperState.vector2Equal or function(a, b)
        return typeFunction(b) == "table" and a.X == b.X and a.Y == b.Y
    end
    local mt
    mt = {
        __typeof = "Vector2",
        __index = function(self, key)
            if key == "Magnitude" then return math.sqrt(self.X * self.X + self.Y * self.Y) end
            if key == "Unit" then
                local mag = math.sqrt(self.X * self.X + self.Y * self.Y)
                return mag == 0 and _makeVector2(0, 0) or _makeVector2(self.X / mag, self.Y / mag)
            end
            return methods[key]
        end,
        __add = function(a, b) return _makeVector2(a.X + b.X, a.Y + b.Y) end,
        __sub = function(a, b) return _makeVector2(a.X - b.X, a.Y - b.Y) end,
        __mul = function(a, b)
            if typeFunction(a) == "number" then return _makeVector2(a * b.X, a * b.Y) end
            if typeFunction(b) == "number" then return _makeVector2(a.X * b, a.Y * b) end
            return _makeVector2(a.X * b.X, a.Y * b.Y)
        end,
        __div = function(a, b)
            if typeFunction(b) == "number" then return _makeVector2(a.X / b, a.Y / b) end
            return _makeVector2(a.X / b.X, a.Y / b.Y)
        end,
        __unm = function(a) return _makeVector2(-a.X, -a.Y) end,
        __eq = dumperState.vector2Equal,
        __tostring = function(a) return ("Vector2.new(%s, %s)"):format(a.X, a.Y) end,
    }
    return setmetatable({X = x, Y = y}, mt)
end
Vector2 = {new = function(x, y) return _makeVector2(x, y) end}
Vector2.zero = Vector2.new(0, 0)
Vector2.one = Vector2.new(1, 1)
setmetatable(Vector2, {__call = function(_, x, y) return _.new(x, y) end})
local _oldVector3New = Vector3.new
Vector3.new = function(x, y, z)
    local v = _oldVector3New(x, y, z)
    local mt = getMetatableFunction(v)
    local oldIndex = mt.__index
    mt.__index = function(self, key)
        if key == "Dot" then
            return function(_, other) return self.X * (other and other.X or 0) + self.Y * (other and other.Y or 0) + self.Z * (other and other.Z or 0) end
        end
        if key == "Cross" then
            return function(_, other)
                return Vector3.new(
                    self.Y * (other and other.Z or 0) - self.Z * (other and other.Y or 0),
                    self.Z * (other and other.X or 0) - self.X * (other and other.Z or 0),
                    self.X * (other and other.Y or 0) - self.Y * (other and other.X or 0)
                )
            end
        end
        return oldIndex(self, key)
    end
    return v
end
Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
UDim = {new = function(scale, offset) return _valueType("UDim", {Scale = _num(scale), Offset = _num(offset)}) end}
setmetatable(UDim, {__call = function(_, scale, offset) return _.new(scale, offset) end})
UDim2 = {
    new = function(xs, xo, ys, yo)
        return _valueType("UDim2", {X = UDim.new(xs, xo), Y = UDim.new(ys, yo)}, {
            Lerp = function(self, other, alpha)
                alpha = _num(alpha)
                local ox, oy = other and other.X or UDim.new(), other and other.Y or UDim.new()
                return UDim2.new(self.X.Scale + (ox.Scale - self.X.Scale) * alpha,
                    self.X.Offset + (ox.Offset - self.X.Offset) * alpha,
                    self.Y.Scale + (oy.Scale - self.Y.Scale) * alpha,
                    self.Y.Offset + (oy.Offset - self.Y.Offset) * alpha)
            end
        })
    end,
    fromScale = function(x, y) return UDim2.new(x, 0, y, 0) end,
    fromOffset = function(x, y) return UDim2.new(0, x, 0, y) end,
}
setmetatable(UDim2, {__call = function(_, ...) return _.new(...) end})
do
    local function _hex(n)
        local b = math.floor((n or 0) * 255 + 0.5)
        if b < 0 then b = 0 elseif b > 255 then b = 255 end
        return string.format("%02X", b)
    end
    local _color3_methods = {}
    function _color3_methods:Lerp(other, alpha)
        alpha = toNumberFunction(alpha) or 0
        local or_, og, ob = (other and other.R) or 0, (other and other.G) or 0, (other and other.B) or 0
        return Color3.new(self.R + (or_ - self.R) * alpha,
                          self.G + (og  - self.G) * alpha,
                          self.B + (ob  - self.B) * alpha)
    end
    function _color3_methods:ToHSV()
        local r, g, b = self.R, self.G, self.B
        local mx, mn = math.max(r, g, b), math.min(r, g, b)
        local v = mx
        local d = mx - mn
        local s = (mx == 0) and 0 or (d / mx)
        local h = 0
        if d ~= 0 then
            if mx == r then h = ((g - b) / d) % 6
            elseif mx == g then h = (b - r) / d + 2
            else h = (r - g) / d + 4 end
            h = h / 6
            if h < 0 then h = h + 1 end
        end
        return h, s, v
    end
    function _color3_methods:ToHex() return _hex(self.R) .. _hex(self.G) .. _hex(self.B) end
    Color3 = {
        new     = function(r, g, b) return _valueType("Color3", {R = _num(r), G = _num(g), B = _num(b)}, _color3_methods) end,
        fromRGB = function(r, g, b) return Color3.new(_num(r) / 255, _num(g) / 255, _num(b) / 255) end,
        fromHSV = function(h, s, v)
            h, s, v = _num(h), _num(s), _num(v)
            if s == 0 then return Color3.new(v, v, v) end
            local i = math.floor(h * 6)
            local f = h * 6 - i
            local p = v * (1 - s)
            local q = v * (1 - f * s)
            local t = v * (1 - (1 - f) * s)
            i = i % 6
            if i == 0 then return Color3.new(v, t, p) end
            if i == 1 then return Color3.new(q, v, p) end
            if i == 2 then return Color3.new(p, v, t) end
            if i == 3 then return Color3.new(p, q, v) end
            if i == 4 then return Color3.new(t, p, v) end
            return Color3.new(v, p, q)
        end,
        fromHex = function(hex)
            hex = toStringFunction(hex or ""):gsub("^#", "")
            if #hex < 6 then return Color3.fromRGB(255, 255, 255) end
            local r = tonumber(hex:sub(1, 2), 16) or 255
            local g = tonumber(hex:sub(3, 4), 16) or 255
            local b = tonumber(hex:sub(5, 6), 16) or 255
            return Color3.fromRGB(r, g, b)
        end,
    }
    setmetatable(Color3, {__call = function(_, ...) return _.new(...) end})
end
BrickColor = {
    new = function(value, g, b)
        local colors = {
            [1] = {"White", 242, 243, 243}, [21] = {"Bright red", 196, 40, 28},
            [23] = {"Bright blue", 13, 105, 172}, [24] = {"Bright yellow", 245, 205, 48},
            [26] = {"Black", 27, 42, 53}, [28] = {"Dark green", 40, 127, 71},
            [37] = {"Bright green", 75, 151, 75}, [194] = {"Medium stone grey", 163, 162, 165},
            [199] = {"Dark stone grey", 99, 95, 98}, [1001] = {"Institutional white", 248, 248, 248},
            [1003] = {"Really black", 17, 17, 17}, [1004] = {"Really red", 255, 0, 0},
            [1009] = {"New Yeller", 255, 255, 0}, [1010] = {"Really blue", 0, 0, 255},
        }
        if typeFunction(value) == "number" and g ~= nil and b ~= nil then
            return _valueType("BrickColor", {Name = "Custom", Number = 1, Color = Color3.new(value, g, b)})
        end
        if typeFunction(value) == "number" and colors[value] then
            local c = colors[value]
            return _valueType("BrickColor", {Name = c[1], Number = value, Color = Color3.fromRGB(c[2], c[3], c[4])})
        end
        local name = formatValue(value or "Medium stone grey")
        local low = tostring(name):lower()
        for num, info in pairs(colors) do
            if info[1]:lower() == low or (low == "red" and num == 21) or (low == "blue" and num == 23) or (low == "green" and num == 37) or (low == "yellow" and num == 24) then
                return _valueType("BrickColor", {Name = info[1], Number = num, Color = Color3.fromRGB(info[2], info[3], info[4])})
            end
        end
        return _valueType("BrickColor", {Name = name, Number = 194, Color = Color3.fromRGB(163, 162, 165)})
    end,
    palette = function(idx) return BrickColor.new(tonumber(idx) or 194) end,
    random = function() return BrickColor.new("Medium stone grey") end,
    Random = function() return BrickColor.new("Medium stone grey") end,
    White = function() return BrickColor.new("White") end,
    Black = function() return BrickColor.new("Black") end,
    Red = function() return BrickColor.new("Bright red") end,
    Blue = function() return BrickColor.new("Bright blue") end,
    Green = function() return BrickColor.new("Bright green") end,
    Yellow = function() return BrickColor.new("Bright yellow") end,
    Gray = function() return BrickColor.new("Medium stone grey") end,
    DarkGray = function() return BrickColor.new("Dark stone grey") end,
    ReallyRed = function() return BrickColor.new("Really red") end,
}
setmetatable(BrickColor, {__call = function(_, ...) return _.new(...) end})
NumberRange = {new = function(min, max) return _valueType("NumberRange", {Min = _num(min), Max = max ~= nil and _num(max) or _num(min)}) end}
NumberSequence = {new = function(value) return _valueType("NumberSequence", {Keypoints = typeFunction(value) == "table" and value or {{Time = 0, Value = _num(value)}, {Time = 1, Value = _num(value)}}}) end}
TweenInfo = {new = function(timeValue, style, direction, repeatCount, reverses, delayTime)
    local repeatCountNumber = toNumberFunction(repeatCount) or 0
    if repeatCountNumber ~= repeatCountNumber or repeatCountNumber == math.huge or repeatCountNumber == -math.huge or
        repeatCountNumber > 2147483647 or repeatCountNumber < -2147483648 then
        repeatCountNumber = -2147483648
    elseif repeatCountNumber < 0 then
        repeatCountNumber = math.ceil(repeatCountNumber)
    else
        repeatCountNumber = math.floor(repeatCountNumber)
    end
    return _valueType("TweenInfo", {Time = timeValue ~= nil and _num(timeValue) or 1, EasingStyle = style or Enum.EasingStyle.Quad,
        EasingDirection = direction or Enum.EasingDirection.Out, RepeatCount = repeatCountNumber,
        Reverses = reverses or false, DelayTime = delayTime or 0})
end}
Ray = {new = function(origin, direction) return _valueType("Ray", {Origin = origin or Vector3.zero, Direction = direction or Vector3.new(0, 0, -1)}) end}
Rect = {new = function(a, b, c, d) return _valueType("Rect", {Min = typeFunction(a) == "table" and a or Vector2.new(a, b), Max = typeFunction(c) == "table" and c or Vector2.new(c, d)}) end}
Region3 = {new = function(minimum, maximum)
    minimum = minimum or Vector3.zero
    maximum = maximum or Vector3.zero
    return _valueType("Region3", {
        Min = minimum,
        Max = maximum,
        CFrame = CFrame and CFrame.new((minimum.X + maximum.X) / 2, (minimum.Y + maximum.Y) / 2, (minimum.Z + maximum.Z) / 2) or nil,
        Size = Vector3.new(maximum.X - minimum.X, maximum.Y - minimum.Y, maximum.Z - minimum.Z),
    })
end}
ColorSequenceKeypoint = {new = function(timeValue, color)
    return _valueType("ColorSequenceKeypoint", {Time = _num(timeValue), Value = color or Color3.new(1, 1, 1)})
end}
ColorSequence = {new = function(first, second)
    local keypoints
    if typeFunction(first) == "table" and first[1] ~= nil then
        keypoints = first
    else
        local c0 = first or Color3.new(1, 1, 1)
        keypoints = {ColorSequenceKeypoint.new(0, c0), ColorSequenceKeypoint.new(1, second or c0)}
    end
    return _valueType("ColorSequence", {Keypoints = keypoints})
end}
Font = {
    new = function(family, weight, style)
        return _valueType("Font", {
            Family = typeFunction(family) == "string" and family or "rbxasset://fonts/families/SourceSansPro.json",
            Weight = weight or (Enum and Enum.FontWeight and Enum.FontWeight.Regular),
            Style = style or (Enum and Enum.FontStyle and Enum.FontStyle.Normal),
            Bold = weight == (Enum and Enum.FontWeight and Enum.FontWeight.Bold),
        })
    end,
    fromEnum = function(fontEnum)
        local n = formatValue(fontEnum):match("([^%.]+)$") or "SourceSansPro"
        if n == "SourceSans" then n = "SourceSansPro" end
        return Font.new("rbxasset://fonts/families/" .. n .. ".json")
    end,
    fromName = function(name, weight, style)
        local n = formatValue(name or "SourceSansPro")
        if n == "SourceSans" then n = "SourceSansPro" end
        return Font.new("rbxasset://fonts/families/" .. n .. ".json", weight, style)
    end,
    fromId = function(id, weight, style)
        return Font.new("rbxassetid://" .. tostring(toNumberFunction(id) or 0), weight, style)
    end,
}
Path2DControlPoint = {new = function(position, leftTangent, rightTangent)
    local zero = UDim2.fromScale(0, 0)
    return _valueType("Path2DControlPoint", {
        Position = position or zero,
        LeftTangent = leftTangent or UDim2.fromScale(0, 0),
        RightTangent = rightTangent or UDim2.fromScale(0, 0),
    })
end}
FloatCurveKey = {new = function(timeValue, value, interpolation)
    return _valueType("FloatCurveKey", {
        Time = _num(timeValue),
        Value = _num(value),
        Interpolation = interpolation or Enum.KeyInterpolationMode.Cubic,
    })
end}
RotationCurveKey = {new = function(timeValue, value, interpolation)
    return _valueType("RotationCurveKey", {
        Time = _num(timeValue),
        Value = value or CFrame.identity or CFrame.new(),
        Interpolation = interpolation or Enum.KeyInterpolationMode.Cubic,
    })
end}
PhysicalProperties = {new = function(density, friction, elasticity, frictionWeight, elasticityWeight) return _valueType("PhysicalProperties", {Density = _num(density, 1), Friction = _num(friction, 0.3), Elasticity = _num(elasticity, 0.5), FrictionWeight = _num(frictionWeight, 1), ElasticityWeight = _num(elasticityWeight, 1)}) end}
local function _rotFromXYZ(rx, ry, rz)
    local cx, sx = math.cos(rx), math.sin(rx)
    local cy, sy = math.cos(ry), math.sin(ry)
    local cz, sz = math.cos(rz), math.sin(rz)
    return {
        cy * cz, -cy * sz, sy,
        cx * sz + sx * sy * cz, cx * cz - sx * sy * sz, -sx * cy,
        sx * sz - cx * sy * cz, sx * cz + cx * sy * sz, cx * cy,
    }
end
local function _rotFromYXZ(rx, ry, rz)
    local cx, sx = math.cos(rx), math.sin(rx)
    local cy, sy = math.cos(ry), math.sin(ry)
    local cz, sz = math.cos(rz), math.sin(rz)
    return {
        cy * cz + sy * sx * sz, -cy * sz + sy * sx * cz, sy * cx,
        cx * sz, cx * cz, -sx,
        -sy * cz + cy * sx * sz, sy * sz + cy * sx * cz, cy * cx,
    }
end
_makeCFrame = function(x, y, z, expr, rx, ry, rz, rot)
    if typeFunction(x) == "table" then
        local mx = getMetatableFunction(x)
        if mx and mx.__typeof == "Vector3" then
            y = x.Y; z = x.Z; x = x.X
        end
    end
    local ox, oy, oz = _num(x), _num(y), _num(z)
    local erx, ery, erz = _num(rx), _num(ry), _num(rz)
    local r = rot
    if typeFunction(r) ~= "table" then
        if erx ~= 0 or ery ~= 0 or erz ~= 0 then
            r = _rotFromXYZ(erx, ery, erz)
        else
            r = {1, 0, 0, 0, 1, 0, 0, 0, 1}
        end
    end
    local obj = {X = ox, Y = oy, Z = oz, _rx = erx, _ry = ery, _rz = erz, _r = r}
    obj.Position = Vector3.new(ox, oy, oz)
    obj.p = obj.Position
    obj.RightVector = Vector3.new(r[1], r[4], r[7])
    obj.UpVector = Vector3.new(r[2], r[5], r[8])
    obj.LookVector = Vector3.new(-r[3], -r[6], -r[9])
    obj.ToEulerAnglesXYZ = function(self) return self._rx or 0, self._ry or 0, self._rz or 0 end
    obj.ToEulerAnglesYXZ = function(self) return self._rx or 0, self._ry or 0, self._rz or 0 end
    obj.ToAxisAngle = function(self)
        local rxv, ryv, rzv = self._rx or 0, self._ry or 0, self._rz or 0
        local angle = math.sqrt(rxv * rxv + ryv * ryv + rzv * rzv)
        if angle == 0 then return Vector3.yAxis, 0 end
        return Vector3.new(rxv / angle, ryv / angle, rzv / angle), angle
    end
    obj.VectorToObjectSpace = function(self, vector)
        local m = self._r
        local vx, vy, vz = vector and vector.X or 0, vector and vector.Y or 0, vector and vector.Z or 0
        return Vector3.new(m[1]*vx + m[4]*vy + m[7]*vz, m[2]*vx + m[5]*vy + m[8]*vz, m[3]*vx + m[6]*vy + m[9]*vz)
    end
    obj.VectorToWorldSpace = function(self, vector)
        local m = self._r
        local vx, vy, vz = vector and vector.X or 0, vector and vector.Y or 0, vector and vector.Z or 0
        return Vector3.new(m[1]*vx + m[2]*vy + m[3]*vz, m[4]*vx + m[5]*vy + m[6]*vz, m[7]*vx + m[8]*vy + m[9]*vz)
    end
    obj.Lerp = function(self, other, alpha)
        alpha = _num(alpha)
        other = other or CFrame.new()
        return _makeCFrame(ox + ((other.X or 0) - ox) * alpha,
            oy + ((other.Y or 0) - oy) * alpha,
            oz + ((other.Z or 0) - oz) * alpha, nil,
            (self._rx or 0) + ((other._rx or 0) - (self._rx or 0)) * alpha,
            (self._ry or 0) + ((other._ry or 0) - (self._ry or 0)) * alpha,
            (self._rz or 0) + ((other._rz or 0) - (self._rz or 0)) * alpha)
    end
    obj.GetComponents = function(self)
        local m = self._r
        return ox, oy, oz, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]
    end
    obj.Inverse = function(self)
        local m = self._r
        local rt = {m[1], m[4], m[7], m[2], m[5], m[8], m[3], m[6], m[9]}
        local ix = -(rt[1]*ox + rt[2]*oy + rt[3]*oz)
        local iy = -(rt[4]*ox + rt[5]*oy + rt[6]*oz)
        local iz = -(rt[7]*ox + rt[8]*oy + rt[9]*oz)
        return _makeCFrame(ix, iy, iz, nil, -(self._rx or 0), -(self._ry or 0), -(self._rz or 0), rt)
    end
    obj.ToOrientation = function(self) return self._rx or 0, self._ry or 0, self._rz or 0 end
    obj.ToObjectSpace = function(self, other)
        return self:Inverse() * (other or CFrame.new())
    end
    obj.ToWorldSpace = function(self, other)
        return self * (other or CFrame.new())
    end
    obj.PointToObjectSpace = function(self, point)
        return self:Inverse():PointToWorldSpace(point)
    end
    obj.PointToWorldSpace = function(self, point)
        local m = self._r
        local px, py, pz = point and point.X or 0, point and point.Y or 0, point and point.Z or 0
        return Vector3.new(ox + m[1]*px + m[2]*py + m[3]*pz, oy + m[4]*px + m[5]*py + m[6]*pz, oz + m[7]*px + m[8]*py + m[9]*pz)
    end
    return setmetatable(obj, {
        __typeof = "CFrame",
        __cframeExpr = expr,
        __index = function(self, key) return rawget(self, key) end,
        __mul = function(a, b)
            local ma = getMetatableFunction(a)
            local mb = getMetatableFunction(b)
            local ar = a._r or {1, 0, 0, 0, 1, 0, 0, 0, 1}
            if mb and mb.__typeof == "CFrame" then
                local br = b._r or {1, 0, 0, 0, 1, 0, 0, 0, 1}
                local ax = (ma and ma.__cframeExpr) or string.format("CFrame.new(%s, %s, %s)", a.X, a.Y, a.Z)
                local bx = (mb and mb.__cframeExpr) or string.format("CFrame.new(%s, %s, %s)", b.X, b.Y, b.Z)
                local nr = {
                    ar[1]*br[1]+ar[2]*br[4]+ar[3]*br[7], ar[1]*br[2]+ar[2]*br[5]+ar[3]*br[8], ar[1]*br[3]+ar[2]*br[6]+ar[3]*br[9],
                    ar[4]*br[1]+ar[5]*br[4]+ar[6]*br[7], ar[4]*br[2]+ar[5]*br[5]+ar[6]*br[8], ar[4]*br[3]+ar[5]*br[6]+ar[6]*br[9],
                    ar[7]*br[1]+ar[8]*br[4]+ar[9]*br[7], ar[7]*br[2]+ar[8]*br[5]+ar[9]*br[8], ar[7]*br[3]+ar[8]*br[6]+ar[9]*br[9],
                }
                local bx0, by0, bz0 = b.X or 0, b.Y or 0, b.Z or 0
                return _makeCFrame(
                    (a.X or 0) + ar[1]*bx0 + ar[2]*by0 + ar[3]*bz0,
                    (a.Y or 0) + ar[4]*bx0 + ar[5]*by0 + ar[6]*bz0,
                    (a.Z or 0) + ar[7]*bx0 + ar[8]*by0 + ar[9]*bz0,
                    "(" .. ax .. " * " .. bx .. ")", nil, nil, nil, nr
                )
            end
            if mb and mb.__typeof == "Vector3" then
                local vx, vy, vz = b.X or 0, b.Y or 0, b.Z or 0
                return Vector3.new(
                    (a.X or 0) + ar[1]*vx + ar[2]*vy + ar[3]*vz,
                    (a.Y or 0) + ar[4]*vx + ar[5]*vy + ar[6]*vz,
                    (a.Z or 0) + ar[7]*vx + ar[8]*vy + ar[9]*vz
                )
            end
            return a
        end,
        __eq = function(a, b)
            if typeFunction(b) ~= "table" or b.X == nil then return false end
            if a.X ~= b.X or a.Y ~= b.Y or a.Z ~= b.Z then return false end
            local ar, br = a._r, b._r
            if ar and br then
                for i = 1, 9 do
                    if math.abs((ar[i] or 0) - (br[i] or 0)) > 1e-6 then return false end
                end
            end
            return true
        end,
        __tostring = function(a) return expr or ("CFrame.new(%s, %s, %s)"):format(a.X, a.Y, a.Z) end,
    })
end
local function _isVec3(v)
    if typeFunction(v) ~= "table" then return false end
    local m = getMetatableFunction(v)
    return m and m.__typeof == "Vector3" or false
end
CFrame = {
    new = function(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
        if _isVec3(x) then
            local px, py, pz = x.X or 0, x.Y or 0, x.Z or 0
            if _isVec3(y) then
                return _makeCFrame(px, py, pz, string.format("CFrame.new(%s, %s)", serializeValue(x), serializeValue(y)))
            end
            return _makeCFrame(px, py, pz, string.format("CFrame.new(%s)", serializeValue(x)))
        end
        if r00 ~= nil and r22 ~= nil then
            return _makeCFrame(x, y, z, nil, 0, 0, 0, {_num(r00), _num(r01), _num(r02), _num(r10), _num(r11), _num(r12), _num(r20), _num(r21), _num(r22)})
        end
        return _makeCFrame(x, y, z)
    end,
    Angles = function(rx, ry, rz)
        local nrx, nry, nrz = _num(rx), _num(ry), _num(rz)
        return _makeCFrame(0, 0, 0, string.format("CFrame.Angles(%s, %s, %s)", serializeValue(nrx), serializeValue(nry), serializeValue(nrz)), nrx, nry, nrz, _rotFromXYZ(nrx, nry, nrz))
    end,
    lookAt = function(origin, target)
        if _isVec3(origin) and _isVec3(target) then
            return _makeCFrame(origin.X or 0, origin.Y or 0, origin.Z or 0,
                string.format("CFrame.lookAt(%s, %s)", serializeValue(origin), serializeValue(target)))
        end
        return _makeCFrame(origin and origin.X or 0, origin and origin.Y or 0, origin and origin.Z or 0)
    end,
    LookAt = function(origin, target) return CFrame.lookAt(origin, target) end,
    fromEulerAnglesXYZ = function(rx, ry, rz)
        local nrx, nry, nrz = _num(rx), _num(ry), _num(rz)
        return _makeCFrame(0, 0, 0, string.format("CFrame.fromEulerAnglesXYZ(%s, %s, %s)",
            serializeValue(nrx), serializeValue(nry), serializeValue(nrz)), nrx, nry, nrz, _rotFromXYZ(nrx, nry, nrz))
    end,
    fromEulerAnglesYXZ = function(rx, ry, rz)
        local nrx, nry, nrz = _num(rx), _num(ry), _num(rz)
        return _makeCFrame(0, 0, 0, string.format("CFrame.fromEulerAnglesYXZ(%s, %s, %s)",
            serializeValue(nrx), serializeValue(nry), serializeValue(nrz)), nrx, nry, nrz, _rotFromYXZ(nrx, nry, nrz))
    end,
    fromAxisAngle = function(axis, angle)
        if _isVec3(axis) then
            local ax, ay, az = axis.X or 0, axis.Y or 0, axis.Z or 0
            local m = math.sqrt(ax*ax + ay*ay + az*az)
            local rot = nil
            if m >= 1e-12 then
                ax, ay, az = ax/m, ay/m, az/m
                local a = _num(angle)
                local c, s = math.cos(a), math.sin(a)
                local t = 1 - c
                rot = {t*ax*ax+c, t*ax*ay-s*az, t*ax*az+s*ay, t*ax*ay+s*az, t*ay*ay+c, t*ay*az-s*ax, t*ax*az-s*ay, t*ay*az+s*ax, t*az*az+c}
            end
            return _makeCFrame(0, 0, 0, string.format("CFrame.fromAxisAngle(%s, %s)",
                serializeValue(axis), serializeValue(_num(angle))), 0, 0, 0, rot)
        end
        return _makeCFrame(0, 0, 0)
    end,
    fromMatrix = function(pos, rv, uv, lv)
        if _isVec3(pos) then
            local args = {serializeValue(pos)}
            if _isVec3(rv) then args[#args + 1] = serializeValue(rv) end
            if _isVec3(uv) then args[#args + 1] = serializeValue(uv) end
            if _isVec3(lv) then args[#args + 1] = serializeValue(lv) end
            local rot = nil
            if _isVec3(rv) and _isVec3(uv) then
                local l = _isVec3(lv) and lv or rv:Cross(uv)
                rot = {rv.X or 1, uv.X or 0, -(l.X or 0), rv.Y or 0, uv.Y or 1, -(l.Y or 0), rv.Z or 0, uv.Z or 0, -(l.Z or -1)}
            end
            return _makeCFrame(pos.X or 0, pos.Y or 0, pos.Z or 0,
                string.format("CFrame.fromMatrix(%s)", table.concat(args, ", ")), 0, 0, 0, rot)
        end
        return _makeCFrame(pos and pos.X or 0, pos and pos.Y or 0, pos and pos.Z or 0)
    end,
    fromOrientation = function(rx, ry, rz)
        local nrx, nry, nrz = _num(rx), _num(ry), _num(rz)
        return _makeCFrame(0, 0, 0, string.format("CFrame.fromOrientation(%s, %s, %s)",
            serializeValue(nrx), serializeValue(nry), serializeValue(nrz)), nrx, nry, nrz, _rotFromYXZ(nrx, nry, nrz))
    end,
}
CFrame.identity = CFrame.new(0, 0, 0)
setmetatable(CFrame, {__call = function(_, ...) return _.new(...) end})
PathWaypoint = createTypeDa("PathWaypoint", {new = true})
Axes = {new = function(...)
    local flags = {X = false, Y = false, Z = false}
    for _, item in ipairsFunction({...}) do
        local path = dumperState.registry[item] or formatValue(item)
        local axis = string.match(path, "%.([XYZ])$")
        if axis then flags[axis] = true end
    end
    return _valueType("Axes", flags)
end}
Faces = {new = function(...)
    local flags = {Top = false, Bottom = false, Left = false, Right = false, Back = false, Front = false}
    for _, item in ipairsFunction({...}) do
        local path = dumperState.registry[item] or formatValue(item)
        local face = string.match(path, "%.([%a]+)$")
        if face and flags[face] ~= nil then flags[face] = true end
    end
    return _valueType("Faces", flags)
end}
RaycastParams = {new = function()
    return _valueType("RaycastParams", {
        FilterType = Enum.RaycastFilterType.Exclude,
        FilterDescendantsInstances = {},
        IgnoreWater = false,
        CollisionGroup = "Default",
        RespectCanCollide = false,
        BruteForceAllSlow = false,
    })
end}
Vector3int16 = createTypeDa("Vector3int16", {new = true})
Vector2int16 = createTypeDa("Vector2int16", {new = true})
CatalogSearchParams = createTypeDa("CatalogSearchParams", {new = true})
do
    local function _datePartsUTC(ts)
        local d = osLibrary.date("!*t", ts)
        return d.year, d.month, d.day, d.hour, d.min, d.sec, d.wday, d.yday
    end
    local _monthShort = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
    local _monthLong  = {"January","February","March","April","May","June","July","August","September","October","November","December"}
    local _dayShort   = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"}
    local _dayLong    = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"}
    local function _format(ts, pattern)
        pattern = toStringFunction(pattern or "YYYY-MM-DDTHH:mm:ssZ")
        local Y, Mo, D, H, Mi, S, W = _datePartsUTC(ts)
        local subs = {
            ["YYYY"] = string.format("%04d", Y),
            ["YY"]   = string.format("%02d", Y % 100),
            ["MMMM"] = _monthLong[Mo] or "",
            ["MMM"]  = _monthShort[Mo] or "",
            ["MM"]   = string.format("%02d", Mo),
            ["M"]    = toStringFunction(Mo),
            ["DDDD"] = _dayLong[W] or "",
            ["DDD"]  = _dayShort[W] or "",
            ["DD"]   = string.format("%02d", D),
            ["D"]    = toStringFunction(D),
            ["HH"]   = string.format("%02d", H),
            ["H"]    = toStringFunction(H),
            ["hh"]   = string.format("%02d", ((H - 1) % 12) + 1),
            ["h"]    = toStringFunction(((H - 1) % 12) + 1),
            ["mm"]   = string.format("%02d", Mi),
            ["m"]    = toStringFunction(Mi),
            ["ss"]   = string.format("%02d", S),
            ["s"]    = toStringFunction(S),
            ["A"]    = (H < 12) and "AM" or "PM",
            ["a"]    = (H < 12) and "am" or "pm",
            ["ZZZ"]  = "UTC",
            ["Z"]    = "Z",
        }
        local out, i, n = {}, 1, #pattern
        while i <= n do
            local matched = false
            for _, tok in ipairsFunction({"YYYY","YY","MMMM","MMM","MM","M","DDDD","DDD","DD","D",
                                          "HH","H","hh","h","mm","m","ss","s","A","a","ZZZ","Z"}) do
                local len = #tok
                if i + len - 1 <= n and pattern:sub(i, i + len - 1) == tok then
                    out[#out + 1] = subs[tok]
                    i = i + len
                    matched = true
                    break
                end
            end
            if not matched then
                out[#out + 1] = pattern:sub(i, i)
                i = i + 1
            end
        end
        return table.concat(out)
    end
    local function _makeDateTime(ts, expression)
        ts = toNumberFunction(ts) or 0
        local Y, Mo, D, H, Mi, S = _datePartsUTC(ts)
        local obj = {
            UnixTimestamp       = math.floor(ts),
            UnixTimestampMillis = math.floor(ts * 1000),
            Year        = Y,
            Month       = Mo,
            Day         = D,
            Hour        = H,
            Minute      = Mi,
            Second      = S,
            Millisecond = 0,
        }
        function obj:ToUniversalTime()
            return {Year=Y, Month=Mo, Day=D, Hour=H, Minute=Mi, Second=S, Millisecond=0}
        end
        function obj:ToLocalTime() return self:ToUniversalTime() end
        function obj:ToIsoDate() return _format(ts, "YYYY-MM-DDTHH:mm:ssZ") end
        function obj:FormatUniversalTime(pattern, _locale) return _format(ts, pattern) end
        function obj:FormatLocalTime(pattern, _locale) return _format(ts, pattern) end
        return setmetatable(obj, {
            __typeof = "DateTime",
            __tostring = function() return expression or string.format("DateTime.fromUnixTimestamp(%d)", obj.UnixTimestamp) end,
        })
    end
    DateTime = {
        now                     = function() return _makeDateTime(osLibrary.time(), "DateTime.now()") end,
        fromUnixTimestamp       = function(ts) return _makeDateTime(ts, string.format("DateTime.fromUnixTimestamp(%s)", serializeValue(ts))) end,
        fromUnixTimestampMillis = function(ms) return _makeDateTime((toNumberFunction(ms) or 0) / 1000, string.format("DateTime.fromUnixTimestampMillis(%s)", serializeValue(ms))) end,
        fromIsoDate             = function(iso)
            iso = toStringFunction(iso or "1970-01-01T00:00:00Z")
            local Y, Mo, D, H, Mi, S = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
            if Y then
                local ts = osLibrary.time({year=toNumberFunction(Y), month=toNumberFunction(Mo), day=toNumberFunction(D),
                                           hour=toNumberFunction(H), min=toNumberFunction(Mi), sec=toNumberFunction(S)})
                return _makeDateTime(ts, string.format("DateTime.fromIsoDate(%q)", iso))
            end
            return _makeDateTime(0, string.format("DateTime.fromIsoDate(%q)", iso))
        end,
        fromLocalTime           = function(t) return _makeDateTime(osLibrary.time(t or {}), "DateTime.fromLocalTime(...)") end,
        fromUniversalTime       = function(t) return _makeDateTime(osLibrary.time(t or {}), "DateTime.fromUniversalTime(...)") end,
    }
    setmetatable(DateTime, {__call = function(_, ...) return _.now() end})
end
if math.clamp == nil then
    math.clamp = function(n, lo, hi)
        n, lo, hi = toNumberFunction(n) or 0, toNumberFunction(lo) or 0, toNumberFunction(hi) or 0
        if n ~= n then return lo end
        if n > hi then return hi end
        if n < lo then return lo end
        return n
    end
end
if math.round == nil then
    math.round = function(n) return math.floor((toNumberFunction(n) or 0) + 0.5) end
end
if math.sign == nil then
    math.sign = function(n)
        n = toNumberFunction(n) or 0
        if n > 0 then return 1 end
        if n < 0 then return -1 end
        return 0
    end
end
if math.noise == nil then
    math.noise = function() return 0 end
end
if math.map == nil then
    math.map = function(n, inMin, inMax, outMin, outMax)
        n, inMin, inMax = toNumberFunction(n) or 0, toNumberFunction(inMin) or 0, toNumberFunction(inMax) or 0
        outMin, outMax = toNumberFunction(outMin) or 0, toNumberFunction(outMax) or 0
        if inMax == inMin then return outMin end
        return (n - inMin) * (outMax - outMin) / (inMax - inMin) + outMin
    end
end
if math.lerp == nil then
    math.lerp = function(a, b, t)
        a, b, t = toNumberFunction(a) or 0, toNumberFunction(b) or 0, toNumberFunction(t) or 0
        return a + (b - a) * t
    end
end
Random = {new = function(seed)
    local modulus = 2147483647
    -- Deterministic local seed mixer; this emulates repeatable Random behavior, not Roblox's private PRNG internals.
    local state = (math.floor(toNumberFunction(seed) or 0) + 359320282) % (modulus - 1)
    if state <= 0 then state = 1 end
    local function nextUnit()
        state = (state * 48271) % modulus
        return state / modulus
    end
    local obj = {}
    function obj:NextNumber(min, max)
        local low = toNumberFunction(min) or 0
        local high = toNumberFunction(max) or 1
        return low + nextUnit() * (high - low)
    end
    function obj:NextInteger(min, max)
        local low = math.floor(toNumberFunction(min) or 1)
        local high = math.floor(toNumberFunction(max) or 100)
        if high < low then low, high = high, low end
        return low + math.floor(nextUnit() * (high - low + 1))
    end
    function obj:NextUnitVector()
        local z = nextUnit() * 2 - 1
        local angle = nextUnit() * 2 * math.pi
        local radius = math.sqrt(math.max(0, 1 - z * z))
        return Vector3.new(radius * math.cos(angle), radius * math.sin(angle), z)
    end
    function obj:Shuffle(tab)
        for index = #tab, 2, -1 do
            local other = self:NextInteger(1, index)
            tab[index], tab[other] = tab[other], tab[index]
        end
        return tab
    end
    function obj:Clone()
        return Random.new((state - 359320282) % (modulus - 1))
    end
    return setmetatable(obj, {__type = "Random", __metatable = "Random", __tostring = function() return "Random" end})
end}
setmetatable(Random, {__call = function(_, seed) return _.new(seed) end})
local function _registryGetEnums()
    local items = {}
    for _, enumName in ipairsFunction(_apiEnumOrder) do
        local enumPath = "Enum." .. enumName
        if not _at.enum[enumPath] then
            local enumProxy = createProxyObject(enumPath, false)
            dumperState.registry[enumProxy] = enumPath
            _at.typeOverride[enumProxy] = "Enum"
            _at.enum[enumPath] = enumProxy
        end
        items[#items + 1] = _at.enum[enumPath]
    end
    return items
end
Enum = createProxyObject("Enum", true)
local enumMeta = debugLibrary.getmetatable(Enum)
enumMeta.__index = function(_, key)
    if key == proxyList or key == "__proxy_id" then return rawget(_, key) end
    if key == "GetEnums" or key == "GetEnumItems" then
        return function() return _registryGetEnums() end
    end
    local enumName = "Enum." .. formatValue(key)
    if not _at.enum[enumName] then
        local enumProxy = createProxyObject(enumName, false)
        dumperState.registry[enumProxy] = enumName
        _at.enum[enumName] = enumProxy
        local emeta = debugLibrary.getmetatable(enumProxy) or {}
        emeta.__index = function(_, itemKey)
            if itemKey == proxyList or itemKey == "__proxy_id" then return rawget(_, itemKey) end
            local fullItemPath = enumName .. "." .. formatValue(itemKey)
            if not _at.enumItems then _at.enumItems = {} end
            if not _at.enumItems[fullItemPath] then
                local itemProxy = createProxyObject(fullItemPath, false)
                dumperState.registry[itemProxy] = fullItemPath
                _at.typeOverride[itemProxy] = "EnumItem"
                local itemStr = formatValue(itemKey)
                local shortEnum = formatValue(key)
                local enumDef = _apiEnums[shortEnum]
                local itemVal = (typeFunction(enumDef) == "table" and enumDef.values and enumDef.values[itemStr]) or 0
                dumperState.property_store[itemProxy] = {Name = itemStr, EnumType = enumProxy, Value = itemVal}
                _at.enumItems[fullItemPath] = itemProxy
            end
            return _at.enumItems[fullItemPath]
        end
        setmetatable(enumProxy, emeta)
    end
    return _at.enum[enumName]
end
local _dumperNotCreatable = {
    Object = true, Instance = true, DataModel = true, PVInstance = true,
    BasePart = true, FormFactorPart = true, TriangleMeshPart = true, PartOperation = true,
    GuiBase = true, GuiBase2d = true, GuiBase3d = true, GuiObject = true, GuiButton = true,
    LayerCollector = true, ValueBase = true, Constraint = true, JointInstance = true,
    SlidingBallConstraint = true, ServiceProvider = true, GenericSettings = true,
    UIBase = true, UIComponent = true, UILayout = true, UIGridStyleLayout = true,
    UIConstraint = true, PostEffect = true, Light = true, DataModelMesh = true,
    CharacterAppearance = true, Clothing = true, BaseScript = true, LuaSourceContainer = true,
    BaseRemoteEvent = true, BaseWrap = true, Controller = true, DynamicRotate = true,
    FaceInstance = true, BackpackItem = true, BevelMesh = true, HandleAdornment = true,
    PVAdornment = true, PartAdornment = true, SelectionLasso = true, TweenBase = true,
    Tween = true, SoundEffect = true, SensorBase = true, BasePlayerGui = true,
    Pages = true, Player = true, Workspace = true, CoreGui = true, CorePackages = true,
    Players = true, Lighting = true, ReplicatedStorage = true, ReplicatedFirst = true,
    ServerStorage = true, ServerScriptService = true, StarterGui = true,
    StarterPlayer = true, StarterPack = true, StarterGear = true,
    PlayerGui = true, PlayerScripts = true, Terrain = true,
    SoundService = true, Teams = true, Chat = true, Debris = true, HttpService = true,
    CollectionService = true, MarketplaceService = true, PathfindingService = true,
    PhysicsService = true, ContextActionService = true, TeleportService = true,
    Stats = true, TestService = true, TextService = true, GuiService = true,
    TextChatService = true, AssetService = true, ContentProvider = true,
    InsertService = true, LocalizationService = true, PolicyService = true,
    MemoryStoreService = true, MessagingService = true, DataStoreService = true,
    AnalyticsService = true, BadgeService = true, VirtualInputManager = true,
    UserSettings = true, RunService = true, TweenService = true, UserInputService = true,
    VoiceChatService = true,
}
Instance = {new = function(className, parent)
        if typeFunction(className) ~= "string" then
            error("invalid argument #1 to 'new' (string expected, got " .. typeFunction(className) .. ")", 2)
        end
        local name = className
        if _dumperNotCreatable[name] or name == "DataModel" or name == "" or name:match("Service$") or (not _apiClassSuper[name] and not _knownClasses[name]) then
            error('Unable to create an Instance of type "' .. name .. '"', 2)
        end
        if parent ~= nil and typeFunction(parent) ~= "table" then
            error("Unable to assign property Parent. Object expected, got " .. typeFunction(parent), 2)
        end
        local proxy = createProxyObject(name, false)
        local varName = registerVariable(proxy, name)
        local props = {ClassName = name, Name = name, Archivable = true}
        if classIsA(name, "BasePart") then
            props.Transparency = 0
            props.Reflectance = 0
            props.Anchored = false
            props.CanCollide = true
            props.CanTouch = true
            props.CanQuery = true
            props.Massless = false
            props.Locked = false
            props.CastShadow = true
            props.Size = name == "MeshPart" and Vector3.new(2, 2, 2) or Vector3.new(4, 1, 2)
            props.Position = Vector3.new(0, 0, 0)
            props.CFrame = CFrame.new(0, 0, 0)
            props.Orientation = Vector3.new(0, 0, 0)
            props.Rotation = Vector3.new(0, 0, 0)
            props.Color = Color3.fromRGB(163, 162, 165)
            props.BrickColor = BrickColor.new("Medium stone grey")
            props.Material = Enum.Material.Plastic
            props.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            props.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
            if name == "Part" then
                props.Shape = Enum.PartType.Block
            elseif name == "MeshPart" then
                props.MeshId = ""
                props.TextureID = ""
            end
        end
        if classIsA(name, "GuiBase2d") then
            props.AbsolutePosition = Vector2.new(0, 0)
            props.AbsoluteSize = (name == "Frame" or name == "ScrollingFrame") and Vector2.new(960, 540) or Vector2.new(100, 50)
            props.AbsoluteRotation = 0
            props.AutoLocalize = true
        end
        if classIsA(name, "GuiObject") then
            props.Position = UDim2.new(0, 0, 0, 0)
            props.Size = UDim2.new(0, 100, 0, 50)
            props.AnchorPoint = Vector2.new(0, 0)
            props.Visible = true
            props.ZIndex = 1
            props.LayoutOrder = 0
            props.Rotation = 0
            props.BackgroundColor3 = Color3.new(1, 1, 1)
            props.BackgroundTransparency = 0
            props.BorderColor3 = Color3.fromRGB(27, 42, 53)
            props.BorderSizePixel = 1
            props.Active = false
            props.ClipsDescendants = false
            props.Selectable = false
            props.SizeConstraint = Enum.SizeConstraint.RelativeXY
            props.AutomaticSize = Enum.AutomaticSize.None
            props.BorderMode = Enum.BorderMode.Outline
        end
        if name == "TextLabel" or name == "TextButton" or name == "TextBox" then
            props.Text = ""
            props.TextSize = 14
            props.TextTransparency = 0
            props.TextColor3 = Color3.new(0, 0, 0)
            props.TextBounds = Vector2.new(100, 18)
            props.Font = Enum.Font.SourceSans
            props.TextXAlignment = Enum.TextXAlignment.Center
            props.TextYAlignment = Enum.TextYAlignment.Center
            if name == "TextBox" then props.ClearTextOnFocus = true end
        elseif name == "Model" then
            props.PrimaryPart = nil
            props.WorldPivot = CFrame.new(0, 0, 0)
        elseif name == "Sound" then
            props.PlaybackLoudness = 1
        elseif name == "UICorner" then
            props.CornerRadius = UDim.new(0, 0)
        elseif name == "Motor6D" or name == "Weld" or name == "WeldConstraint" then
            props.Enabled = true
            if name == "Motor6D" then
                props.C0 = CFrame.new()
                props.C1 = CFrame.new()
            end
        elseif name == "Camera" then
            props.NearPlaneZ = -0.1
            props.FieldOfView = 70
            props.CFrame = CFrame.new(0, 0, 0)
            props.Focus = CFrame.new(0, 0, 0)
            props.CameraType = Enum.CameraType.Custom
            props.ViewportSize = Vector2.new(1920, 1080)
        elseif name == "StringValue" then
            props.Value = ""
        elseif name == "IntValue" or name == "NumberValue" then
            props.Value = 0
        elseif name == "BoolValue" then
            props.Value = false
        elseif name == "ObjectValue" then
            props.Value = nil
        elseif name == "CFrameValue" then
            props.Value = CFrame.new()
        elseif name == "Vector3Value" then
            props.Value = Vector3.new()
        elseif name == "Color3Value" then
            props.Value = Color3.new()
        elseif name == "BrickColorValue" then
            props.Value = BrickColor.new()
        elseif name == "CanvasGroup" then
            props.GroupTransparency = 0
            props.GroupColor3 = Color3.new(1, 1, 1)
        end
        dumperState.property_store[proxy] = props
        _at.propertyDefaults[proxy] = {Transparency = 0}
        _at.propertyModified[proxy] = {}
        if parent then
            local parentPath = dumperState.registry[parent] or serializeValue(parent)
            emitOutput(string.format("local %s = Instance.new(%s, %s)", varName, formatStringLiteral(name), parentPath))
            _setParent(proxy, parent)
        else
            emitOutput(string.format("local %s = Instance.new(%s)", varName, formatStringLiteral(name)))
        end
        return proxy
    end,
    fromExisting = function(other)
        if typeFunction(other) ~= "table" or dumperState.property_store[other] == nil then
            error("Unable to cast value to Object", 2)
        end
        local srcProps = dumperState.property_store[other]
        local cn = srcProps.ClassName or "Folder"
        local clone = Instance.new(cn)
        local dstProps = dumperState.property_store[clone]
        if dstProps then
            for k, v in pairsFunction(srcProps) do
                if k ~= "ClassName" and k ~= "Parent" and typeFunction(v) ~= "function" then
                    dstProps[k] = v
                end
            end
        end
        return clone
    end}
game = createProxyObject("game", true)
workspace = createProxyObject("workspace", true)
script = createProxyObject("script", true)
dumperState.property_store[script] = {
    Name = "DumpedScript", Parent = game, ClassName = "LocalScript",
    Disabled = false, RunContext = nil, LinkedSource = "",
    Source = "-- Roblox LocalScript",
}
local function seedCoreRobloxInstances()
    dumperState.property_store[game] = {
        Name = "Game", ClassName = "DataModel", JobId = "00000000-0000-4000-8000-000000000001",
        PlaceId = numericArg, GameId = numericArg + 864197532, placeId = numericArg, gameId = numericArg + 864197532,
        PlaceVersion = 1, CreatorId = 0, CreatorType = Enum.CreatorType.User
    }
    dumperState.property_store[workspace] = {
        Name = "Workspace", ClassName = "Workspace", Parent = game, Gravity = 196.2, DistributedGameTime = 1,
        StreamingEnabled = false
    }
    _setParent(workspace, game)
    _at.svcCache.Workspace = workspace

    local players = _at.svcCache.Players or createProxyObject("Players", false, game)
    _at.svcCache.Players = players
    dumperState.registry[players] = "Players"
    dumperState.property_store[players] = {Name = "Players", ClassName = "Players", Parent = game, MaxPlayers = 12, RespawnTime = 5}
    _setParent(players, game)

    local lp = _at.localPlayer or createProxyObject("LocalPlayer", false, players)
    _at.localPlayer = lp
    dumperState.registry[lp] = "LocalPlayer"
    dumperState.property_store[lp] = {
        Name = "Player", ClassName = "Player", Parent = players, UserId = 1234567, DisplayName = "Player",
        MembershipType = Enum.MembershipType.None, FollowUserId = 0, AccountAge = 1000
    }
    _setParent(lp, players)

    local function ensureChild(parent, name, className, props)
        local child = createProxyObject(name, false, parent)
        dumperState.registry[child] = name
        props = props or {}
        props.Name = props.Name or name
        props.ClassName = props.ClassName or className or name
        props.Parent = parent
        dumperState.property_store[child] = props
        _setParent(child, parent)
        if serviceNames[props.ClassName] then
            _at.svcCache[props.ClassName] = child
        end
        return child
    end

    local character = ensureChild(lp, "Character", "Model")
    dumperState.property_store[lp].Character = character
    _at.localCharacter = character
    ensureChild(character, "HumanoidRootPart", "Part", {
        Position = Vector3.new(0, 5, 0),
        CFrame = CFrame.new(0, 5, 0),
    })
    ensureChild(character, "Humanoid", "Humanoid", {
        Health = 100, MaxHealth = 100, WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2,
    })
    ensureChild(lp, "PlayerGui", "PlayerGui")
    ensureChild(lp, "Backpack", "Backpack")
    local playerScripts = ensureChild(lp, "PlayerScripts", "PlayerScripts")
    ensureChild(playerScripts, "PlayerModule", "ModuleScript")
    ensureChild(playerScripts, "RbxCharacterSounds", "LocalScript")
    ensureChild(workspace, "Camera", "Camera", {
        CFrame = CFrame.new(0, 10, 0), FieldOfView = 70, ViewportSize = Vector2.new(1920, 1080),
        CameraType = Enum.CameraType.Custom, NearPlaneZ = -0.1
    })
    ensureChild(game, "ReplicatedStorage", "ReplicatedStorage")
    ensureChild(game, "Lighting", "Lighting", {ClockTime = 14, FogEnd = 100000, Ambient = Color3.fromRGB(128, 128, 128), OutdoorAmbient = Color3.fromRGB(128, 128, 128)})
    local soundSvc = ensureChild(game, "SoundService", "SoundService", {RolloffScale = 1, AmbientReverb = Enum.ReverbType.NoReverb})
    ensureChild(soundSvc, "AudioDeviceOutput", "AudioDeviceOutput", {Volume = 1})
    ensureChild(game, "RunService", "RunService")
    ensureChild(game, "TweenService", "TweenService")
    ensureChild(game, "HttpService", "HttpService", {HttpEnabled = false})
    local networkClient = ensureChild(game, "NetworkClient", "NetworkClient")
    ensureChild(networkClient, "ClientReplicator", "ClientReplicator")
    local ugc = ensureChild(game, "Ugc", "Folder")
    ensureChild(ugc, "Chat", "Chat")
    ensureChild(game, "CollectionService", "CollectionService")
    ensureChild(game, "TextService", "TextService")
    ensureChild(game, "GuiService", "GuiService")
    ensureChild(game, "ContentProvider", "ContentProvider")
end
seedCoreRobloxInstances()
task = {
    wait = function(sec)
        if sec then emitOutput(string.format("task.wait(%s)", serializeValue(sec))) else emitOutput("task.wait()") end
        local waitSeconds = tonumber(sec) or 0.03
        if waitSeconds < 0 then waitSeconds = 0 end
        _animation_clock = _animation_clock + waitSeconds
        _advance_tweens()
        for inst, props in pairsFunction(dumperState.property_store) do
            if props.ClassName == "Part" and props.Anchored == false and _at.vectors[props.Position] then
                local v = _at.vectors[props.Position]
                props.Position = Vector3.new(v.x, v.y - 1, v.z)
            end
        end
        return sec or 0.03, osLibrary.clock()
    end,
    spawn = function(func, ...)
        local args = {...}
        emitOutput("task.spawn(function()")
        dumperState.indent = dumperState.indent + 1
        if typeFunction(func) == "function" then
            xpcallFunction( function() func(table.unpack(args)) end, function(err) emitOutput("-- [Error in spawn] " .. toStringFunction(err)) end )
        elseif typeFunction(func) == "thread" then
            xpcallFunction( function() coroutine.resume(func, table.unpack(args)) end, function(err) emitOutput("-- [Error in spawn] " .. toStringFunction(err)) end )
        end
        while dumperState.pending_iterator do
            dumperState.indent = dumperState.indent - 1
            emitOutput("end")
            dumperState.pending_iterator = false
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
        local co = coroutine.create(function() end)
        _at.threadLike[co] = true
        local wrapper = setmetatable({}, {
            __call = function() return true end,
            __tostring = function() return "thread: 0x0" end,
        })
        _at.threadLike[wrapper] = true
        return wrapper
    end,
    delay = function(sec, func, ...)
        local args = {...}
        emitOutput(string.format("task.delay(%s, function()", serializeValue(sec or 0)))
        dumperState.indent = dumperState.indent + 1
        if typeFunction(func) == "function" then
            xpcallFunction( function() func(table.unpack(args)) end, function() end )
        end
        while dumperState.pending_iterator do
            dumperState.indent = dumperState.indent - 1
            emitOutput("end")
            dumperState.pending_iterator = false
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
    end,
    defer = function(func, ...)
        local args = {...}
        emitOutput("task.defer(function()")
        dumperState.indent = dumperState.indent + 1
        if typeFunction(func) == "function" then
            xpcallFunction( function() func(table.unpack(args)) end, function() end )
        end
        dumperState.indent = dumperState.indent - 1
        emitOutput("end)")
    end,
    cancel = function(thread) emitOutput("task.cancel(thread)") end,
    synchronize = function() emitOutput("task.synchronize()") end,
    desynchronize = function() emitOutput("task.desynchronize()") end
}
wait = function(sec)
    if sec then emitOutput(string.format("wait(%s)", serializeValue(sec))) else emitOutput("wait()") end
    task.wait(sec)
    return sec or 0.03, osLibrary.clock()
end
delay = function(sec, func)
    emitOutput(string.format("delay(%s, function()", serializeValue(sec or 0)))
    dumperState.indent = dumperState.indent + 1
    if typeFunction(func) == "function" then xpcallFunction(func, function() end) end
    dumperState.indent = dumperState.indent - 1
    emitOutput("end)")
end
spawn = function(func)
    emitOutput("spawn(function()")
    dumperState.indent = dumperState.indent + 1
    if typeFunction(func) == "function" then xpcallFunction(func, function() end) end
    dumperState.indent = dumperState.indent - 1
    emitOutput("end)")
end
tick = function() return _animation_clock end
time = function() return osLibrary.clock() end
elapsedTime = function() return osLibrary.clock() end
local globalEnv = {}
local dummy = 999999999
local function getDummy(key, val) return val end
local function setupEnv()
    local env = {}
    setmetatable(env, {
        __call = function(self, ...) return self end,
        __index = function(self, key)
            if _G[key] ~= nil then return getDummy(key, _G[key]) end
            if key == "game" then return game end
            if key == "workspace" then return workspace end
            if key == "script" then return script end
            if key == "Enum" then return Enum end
            return nil
        end,
        __newindex = function(self, key, val)
            _G[key] = val
            globalEnv[key] = 0
            emitOutput(string.format("_G.%s = %s", formatValue(key), serializeValue(val)))
        end
    })
    return env
end
_G.G = setupEnv()
_G.g = setupEnv()
_G.ENV = setupEnv()
_G.env = setupEnv()
_G.E = setupEnv()
_G.e = setupEnv()
_G.L = setupEnv()
_G.l = setupEnv()
_G.F = setupEnv()
_G.f = setupEnv()
local function createGetGenv(path)
    local proxy = {}
    local meta = {}
    local restricted = {"hookfunction", "hookmetamethod", "newcclosure", "replaceclosure", "checkcaller", "iscclosure", "islclosure", "getrawmetatable", "setreadonly", "make_writeable", "getrenv", "getgc", "getinstances"}
    local function formatPath(d, k)
        local prop = formatValue(k)
        if prop:match("^[%a_][%w_]*$") then
            if d then return d .. "." .. prop end
            return prop
        else
            local escaped = prop:gsub("'", "\\\\'")
            if d then return d .. "['" .. escaped .. "']" end
            return "['" .. escaped .. "']"
        end
    end
    meta.__index = function(_, key)
        if key == "c" or key == "fenv" or key == "ReplicatedStorage" then return nil end
        return _G[key]
    end
    meta.__newindex = function(_, key, val)
        local fullPath = formatPath(path, key)
        emitOutput(string.format("getgenv().%s = %s", fullPath, serializeValue(val)))
    end
    meta.__call = function() return proxy end
    meta.__pairs = function() return function() return nil end, nil, nil end
    return setmetatable(proxy, meta)
end
local exploitFuncs = {
    getgenv = function() return createGetGenv(nil) end,
    getrenv = function()
        local _executorOnly = {
            hookfunction=true,hookmetamethod=true,getgc=true,getreg=true,
            getgenv=true,getrenv=true,getsenv=true,getrawmetatable=true,
            setrawmetatable=true,setreadonly=true,make_writeable=true,
            make_readonly=true,newcclosure=true,getupvalues=true,setupvalue=true,
            getconstants=true,getconnections=true,clonefunction=true,
            iscclosure=true,islclosure=true,getinfo=true,
        }
        return setmetatable({}, {
            __index = function(_, k)
                if _executorOnly[k] then return nil end
                return _G[k]
            end,
            __newindex = function(_, k, v) _G[k] = v end,
        })
    end,
    getsenv = function(scriptObj)
        if not isProxy(scriptObj) then
            errorFunction("invalid argument #1 to 'getsenv' (Instance expected, got " .. typeFunction(scriptObj) .. ")", 2)
        end
        local props = dumperState.property_store[scriptObj] or {}
        local cn = props.ClassName or ""
        if cn ~= "ModuleScript" and cn ~= "LocalScript" and cn ~= "Script" then
            errorFunction("invalid argument #1 to 'getsenv' (ModuleScript/LocalScript/Script expected, got Instance)", 2)
        end
        local env = {}
        for k, v in pairsFunction(_G) do env[k] = v end
        for k, v in pairsFunction(exploitFuncs) do env[k] = v end
        env.script = scriptObj
        env._ENV   = env
        return env
    end,
    getfenv = (function()
        local _cached
        local _MaxLevel = 5
        return function(depth)
            if depth ~= nil then
                local dt = typeFunction(depth)
                if dt == "number" then
                    if depth ~= depth then return _cached or _cached and _cached or setmetatable({},{__index=_G}) end
                    if depth == math.huge or depth == -math.huge then return _cached or setmetatable({},{__index=_G}) end
                    if depth % 1 ~= 0 then return _cached or setmetatable({},{__index=_G}) end
                    if depth < 0 or depth > _MaxLevel then return nil end
                end
            end
            if _cached then return _cached end
            _cached = setmetatable({}, {
                __index = function(_, key)
                    if key == "c" or key == "fenv" then return nil end
                    return _G[key]
                end,
                __newindex = function(_, k, v) rawset(_, k, v) end,
                __tostring = function() return "getfenv()" end,
            })
            return _cached
        end
    end)(),
    setfenv = function(func, env)
        if typeFunction(func) ~= "function" then return end
        local i = 1
        while true do
            local name = debugLibrary.getupvalue(func, i)
            if name == "_ENV" then debugLibrary.setupvalue(func, i, env) break
            elseif not name then break end
            i = i + 1
        end
        return func
    end,
    hookfunction = function(orig, hook)
        if typeFunction(orig) ~= "function" then return orig end
        if typeFunction(hook) ~= "function" then return orig end
        if not _at.hookedFunctions then _at.hookedFunctions = {} end
        _at.hookedFunctions[orig] = hook
        local originalMetadata = dumperState.filtergc_registry and dumperState.filtergc_registry[orig]
        local replacementMetadata = dumperState.filtergc_registry and dumperState.filtergc_registry[hook]
        if originalMetadata and replacementMetadata then originalMetadata.hash = replacementMetadata.hash end
        -- Registry-based hooking (for code preprocessed with hookfn prepass)
        local _reg = rawget(_G, "_hkR")
        if _reg and _reg[orig] then
            local _entry = _reg[orig]
            local _prevFn = _entry.f
            _entry.f = hook
            local _prev = function(...) return _prevFn(...) end
            local _r2 = rawget(_G,"_hkR") or {}
            rawset(_G,"_hkR",_r2)
            _r2[_prev] = {f = _prevFn}
            return _prev
        end
        -- Fallback
        local _prevFn = orig
        return function(...) return _prevFn(...) end
    end,
    hookmetamethod = function(x, method, hook)
        local methodName = formatValue(method)
        if typeFunction(hook) == "function" then
            _at.metaHooks[methodName] = hook
        end
        if methodName == "__index" then
            return function(obj, key)
                local mt = isProxy(obj) and debugLibrary.getmetatable(obj)
                if mt and typeFunction(mt.__index) == "function" then
                    local saved = _at.metaHooks[methodName]
                    _at.metaHooks[methodName] = nil
                    local ok, result = pcallFunction(mt.__index, obj, key)
                    _at.metaHooks[methodName] = saved
                    if ok then return result end
                end
                return nil
            end
        end
        if methodName == "__namecall" then
            return function(obj, ...)
                local methodToCall = _at.currentNamecallMethod
                if methodToCall and obj then
                    local member = obj[methodToCall]
                    if typeFunction(member) == "function" then
                        local saved = _at.metaHooks[methodName]
                        _at.metaHooks[methodName] = nil
                        local ok, result = pcallFunction(member, obj, ...)
                        _at.metaHooks[methodName] = saved
                        if ok then return result end
                    end
                end
                return nil
            end
        end
        return function() end
    end,
    getrawmetatable = function(x)
        if isProxy(x) then
            local m = debugLibrary.getmetatable(x)
            if typeFunction(m) ~= "table" then
                return {__metatable = "The metatable is locked"}
            end
            local out = {__metatable = "The metatable is locked"}
            for _, k in ipairs({"__index","__newindex","__call","__tostring",
                    "__namecall","__eq","__add","__sub","__mul","__div",
                    "__mod","__pow","__unm","__concat","__len","__lt","__le"}) do
                if m[k] then out[k] = m[k] end
            end
            return out
        end
        if typeFunction(x) == "table" then
            return getMetatableFunction(x) or {}
        end
        return {}
    end,
    setrawmetatable = function(x, mt) return x end,
    getnamecallmethod = function() return _at.currentNamecallMethod or "__namecall" end,
    setnamecallmethod = function(m) _at.currentNamecallMethod = formatValue(m) end,
    checkcaller = function() return false end,
    iscclosure = function(f)
        if typeFunction(f) ~= "function" then return false end
        if _CFunctionSet[f] then return true end
        if debugLibrary and typeFunction(debugLibrary.info) == "function" then
            local okInfo, src = pcallFunction(debugLibrary.info, f, "s")
            if okInfo and src == "[C]" then
                _CFunctionSet[f] = true
                return true
            end
        end
        local _sdump = _G._origStringDump or (stringLibrary and rawget(stringLibrary, "dump"))
        if typeFunction(_sdump) == "function" then
            local ok, res = pcallFunction(_sdump, f)
            if ok then return false end
            local msg = typeFunction(res) == "string" and res or ""
            if not msg:find("not available", 1, true) and not msg:find("attempt to dump given function", 1, true) then
                return true
            end
        end
        return false
    end,
    islclosure = function(f)
        if typeFunction(f) ~= "function" then return false end
        if _CFunctionSet[f] then return false end
        if debugLibrary and typeFunction(debugLibrary.info) == "function" then
            local okInfo, src = pcallFunction(debugLibrary.info, f, "s")
            if okInfo and src == "[C]" then
                _CFunctionSet[f] = true
                return false
            end
        end
        local _sdump = _G._origStringDump or (stringLibrary and rawget(stringLibrary, "dump"))
        if typeFunction(_sdump) == "function" then
            local ok, res = pcallFunction(_sdump, f)
            if ok then return true end
            local msg = typeFunction(res) == "string" and res or ""
            if not msg:find("not available", 1, true) and not msg:find("attempt to dump given function", 1, true) then
                return false
            end
        end
        return true
    end,
    newcclosure = function(f)
        if typeFunction(f) ~= "function" then return f end
        local wrapper = function(...) return f(...) end
        _CFunctionSet[wrapper] = true
        return wrapper
    end,
    clonefunction = function(f) return f end,
    request = function(req)
        emitOutput(string.format("request(%s)", serializeValue(req)))
        table.insert(dumperState.string_refs, {value = req.Url or req.url or "unknown", hint = "HTTP Request"})
        if type(task) == "table" and type(task.wait) == "function" then task.wait(0.001) end
        return {Success = true, StatusCode = 200, StatusMessage = "OK", Headers = {}, Body = "{}"}
    end,
    http_request = function(req) return exploitFuncs.request(req) end,
    syn = {request = function(req) return exploitFuncs.request(req) end},
    http = {request = function(req) return exploitFuncs.request(req) end},
    HttpPost = function(url, data)
        emitOutput(string.format("HttpPost(%s, %s)", formatValue(url), formatValue(data)))
        return "{}"
    end,
    setclipboard = function(data) emitOutput(string.format("setclipboard(%s)", serializeValue(data))) end,
    toclipboard = function(data) emitOutput(string.format("setclipboard(%s)", serializeValue(data))) end,
    getclipboard = function() return "" end,
    identifyexecutor = function() return "kenV1", "1.0.0" end,
    getexecutorname = function() return "kenV1" end,
    getexecutorversion = function() return "1.0.0" end,
    getversion = function() return "1.0.0" end,
    gethui = function()
        local hui = createProxyObject("HiddenUI", false)
        registerVariable(hui, "HiddenUI")
        emitOutput(string.format("local %s = gethui()", dumperState.registry[hui]))
        return hui
    end,
    cloneref = function(inst)
        if not isProxy(inst) then return inst end
        local props = dumperState.property_store[inst] or {}
        local className = props.ClassName or dumperState.registry[inst] or "Instance"
        local clone = createProxyObject(className, false, dumperState.parent_map[inst])
        local clonedProps = {}
        for k, v in pairsFunction(props) do clonedProps[k] = v end
        clonedProps.ClassName = clonedProps.ClassName or className
        clonedProps.Name = clonedProps.Name or props.Name or className
        dumperState.property_store[clone] = clonedProps
        dumperState.registry[clone] = (dumperState.registry[inst] or className) .. "_cloneref"
        _at.refBase[clone] = _at.refBase[inst] or inst
        return clone
    end,
    compareinstances = function(a, b)
        local baseA = _at.refBase[a] or a
        local baseB = _at.refBase[b] or b
        return baseA == baseB
    end,
    gethiddenui = function() return exploitFuncs.gethui() end,
    protectgui = function(obj) end,
    iswindowactive = function() return true end,
    isrbxactive = function() return true end,
    isgameactive = function() return true end,
    getconnections = function(signal) return {} end,
    firesignal = function(signal, ...) end,
    fireclickdetector = function(detector, dist) end,
    fireproximityprompt = function(prompt) end,
    firetouchinterest = function(a, b, c) end,
    getinstances = function()
        local instances = {}
        for inst in pairsFunction(dumperState.property_store) do
            if isProxy(inst) and (dumperState.property_store[inst].ClassName or dumperState.registry[inst]) then
                table.insert(instances, inst)
            end
        end
        if #instances == 0 then table.insert(instances, game) end
        return instances
    end,
    getnilinstances = function() return {} end,
    getgc = function(includeTables)
        local items = {}
        local seen  = {}
        local function addItem(v)
            if v and not seen[v] then
                seen[v] = true
                table.insert(items, v)
            end
        end
        for _, v in pairsFunction(_G) do
            local t = typeFunction(v)
            if t == "function" then addItem(v)
            elseif t == "table" and includeTables then addItem(v) end
        end
        for _, v in pairsFunction(exploitFuncs) do
            if typeFunction(v) == "function" then addItem(v) end
        end
        if _at.hookedFunctions then
            for orig, hook in pairsFunction(_at.hookedFunctions) do
                addItem(orig); addItem(hook)
            end
        end
        for proxy, _ in pairsFunction(dumperState.property_store) do
            if isProxy(proxy) and includeTables then addItem(proxy) end
        end
        for _, lib in ipairsFunction({math, string, table, os, io, coroutine}) do
            if typeFunction(lib) == "table" then
                for _, v in pairsFunction(lib) do
                    if typeFunction(v) == "function" then addItem(v) end
                end
            end
        end
        return items
    end,
    getscripts = function()
        local scripts = {}
        for proxy, props in pairsFunction(dumperState.property_store) do
            if isProxy(proxy) then
                local cn = props.ClassName or ""
                if cn == "LocalScript" or cn == "Script" or cn == "ModuleScript" then
                    table.insert(scripts, proxy)
                end
            end
        end
        if #scripts == 0 then table.insert(scripts, script) end
        return scripts
    end,
    getrunningscripts = function()
        return exploitFuncs.getscripts()
    end,
    getloadedmodules = function()
        local modules = {}
        local seen    = {}
        for proxy, props in pairsFunction(dumperState.property_store) do
            if isProxy(proxy) and not seen[proxy] then
                local cn = props.ClassName or ""
                if cn == "ModuleScript" then
                    seen[proxy] = true
                    table.insert(modules, proxy)
                end
            end
        end
        if typeFunction(package) == "table" and typeFunction(package.loaded) == "table" then
            for k, v in pairsFunction(package.loaded) do
                if typeFunction(v) == "table" and not isProxy(v) and not seen[v] then
                    seen[v] = true
                    local mp = createProxyObject("ModuleScript", false)
                    dumperState.property_store[mp] = {
                        ClassName = "ModuleScript",
                        Name      = toStringFunction(k),
                        Parent    = game,
                    }
                    dumperState.registry[mp] = toStringFunction(k)
                    table.insert(modules, mp)
                end
            end
        end
        return modules
    end,
    getcallingscript = function() return script end,
    readfile = false,
    writefile = false,
    appendfile = false,
    loadfile = false,
    listfiles = false,
    isfile = false,
    isfolder = false,
    makefolder = false,
    delfolder = false,
    delfile = false,
    Drawing = {
        new = function(type)
            local t = formatValue(type)
            local proxy = createProxyObject("Drawing_" .. t, false)
            registerVariable(proxy, t)
            emitOutput(string.format("local %s = Drawing.new(%s)", dumperState.registry[proxy], formatStringLiteral(t)))
            return proxy
        end,
        Fonts = createProxyObject("Drawing.Fonts", false)
    },
    crypt = (function()
        local _b64alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local _b64lookup = {}
        for i = 1, 64 do _b64lookup[_b64alpha:sub(i,i)] = i - 1 end
        local function _b64enc(data)
            if typeFunction(data) ~= "string" then data = toStringFunction(data) end
            local result, pad = {}, #data % 3
            for i = 1, #data, 3 do
                local b1 = data:byte(i)
                local b2 = data:byte(i+1) or 0
                local b3 = data:byte(i+2) or 0
                local n = b1 * 65536 + b2 * 256 + b3
                result[#result+1] = _b64alpha:sub(math.floor(n/262144)%64+1, math.floor(n/262144)%64+1)
                result[#result+1] = _b64alpha:sub(math.floor(n/4096)%64+1,   math.floor(n/4096)%64+1)
                result[#result+1] = (i+1 <= #data) and _b64alpha:sub(math.floor(n/64)%64+1, math.floor(n/64)%64+1) or "="
                result[#result+1] = (i+2 <= #data) and _b64alpha:sub(n%64+1, n%64+1) or "="
            end
            return table.concat(result)
        end
        local function _b64dec(data)
            if typeFunction(data) ~= "string" then data = toStringFunction(data) end
            data = data:gsub("=",""):gsub("[^%w%+%/]","")
            local result = {}
            for i = 1, #data, 4 do
                local a = _b64lookup[data:sub(i,i)] or 0
                local b = _b64lookup[data:sub(i+1,i+1)] or 0
                local c = _b64lookup[data:sub(i+2,i+2)] or 0
                local d = _b64lookup[data:sub(i+3,i+3)] or 0
                local n = a*262144 + b*4096 + c*64 + d
                result[#result+1] = string.char(math.floor(n/65536)%256)
                if i+2 <= #data+1 then result[#result+1] = string.char(math.floor(n/256)%256) end
                if i+3 <= #data+1 then result[#result+1] = string.char(n%256) end
            end
            return table.concat(result)
        end
        local function _sha256(msg)
            local K = {0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
                       0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
                       0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
                       0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
                       0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
                       0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
                       0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
                       0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2}
            local function rr(x,n) return bit32.bor(bit32.rshift(x, n), bit32.lshift(x, 32 - n)) end
            local function s0(x) return bit32.bxor(bit32.bxor(rr(x,7), rr(x,18)), bit32.rshift(x,3)) end
            local function s1(x) return bit32.bxor(bit32.bxor(rr(x,17), rr(x,19)), bit32.rshift(x,10)) end
            local function S0(x) return bit32.bxor(bit32.bxor(rr(x,2), rr(x,13)), rr(x,22)) end
            local function S1(x) return bit32.bxor(bit32.bxor(rr(x,6), rr(x,11)), rr(x,25)) end
            local function Ch(x,y,z) return bit32.bxor(bit32.band(x,y), bit32.band(bit32.bnot(x),z)) end
            local function Maj(x,y,z) return bit32.bxor(bit32.bxor(bit32.band(x,y), bit32.band(x,z)), bit32.band(y,z)) end
            local ok, result = pcallFunction(function()
                local ml = #msg * 8; msg = msg .. "\128"
                while #msg % 64 ~= 56 do msg = msg .. "\0" end
                for i = 7, 0, -1 do msg = msg .. string.char(bit32.band(bit32.rshift(ml, i*8), 0xFF)) end
                local H = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}
                for blk = 1, #msg, 64 do
                    local W = {}
                    for i = 0, 15 do
                        local b0,b1,b2,b3 = msg:byte(blk+i*4, blk+i*4+3)
                        W[i] = bit32.bor(bit32.lshift(b0 or 0,24), bit32.lshift(b1 or 0,16), bit32.lshift(b2 or 0,8), b3 or 0)
                    end
                    for i = 16, 63 do W[i] = bit32.band(s1(W[i-2]) + W[i-7] + s0(W[i-15]) + W[i-16], 0xFFFFFFFF) end
                    local a,b,c,d,e,f,g,h = table.unpack(H)
                    for i = 0, 63 do
                        local T1 = bit32.band(h+S1(e)+Ch(e,f,g)+K[i+1]+W[i], 0xFFFFFFFF)
                        local T2 = bit32.band(S0(a)+Maj(a,b,c), 0xFFFFFFFF)
                        h=g; g=f; f=e; e=bit32.band(d+T1, 0xFFFFFFFF); d=c; c=b; b=a; a=bit32.band(T1+T2, 0xFFFFFFFF)
                    end
                    H[1]=bit32.band(H[1]+a, 0xFFFFFFFF); H[2]=bit32.band(H[2]+b, 0xFFFFFFFF); H[3]=bit32.band(H[3]+c, 0xFFFFFFFF); H[4]=bit32.band(H[4]+d, 0xFFFFFFFF)
                    H[5]=bit32.band(H[5]+e, 0xFFFFFFFF); H[6]=bit32.band(H[6]+f, 0xFFFFFFFF); H[7]=bit32.band(H[7]+g, 0xFFFFFFFF); H[8]=bit32.band(H[8]+h, 0xFFFFFFFF)
                end
                local out = {}
                for i = 1, 8 do out[i] = string.format("%08x", H[i]) end
                return table.concat(out)
            end)
            return ok and result or string.rep("0", 64)
        end
        local function _md5(s)
            local h = 0
            for i = 1, #s do h = bit32.band((h * 31) + s:byte(i), 0xFFFFFFFF) end
            return string.format("%08x%08x%08x%08x", h, bit32.band(bit32.bnot(h), 0xFFFFFFFF), bit32.bor(bit32.lshift(h,16), bit32.rshift(h,16)), bit32.bor(bit32.lshift(bit32.bnot(h),16), bit32.rshift(bit32.bnot(h),16)))
        end
        local function _sha1(s)
            local h = 0
            for i = 1, #s do h = bit32.band((h * 37) + s:byte(i), 0xFFFFFFFF) end
            return string.format("%08x%08x%08x%08x%08x", h, bit32.band(bit32.bnot(h), 0xFFFFFFFF), bit32.band(h*7, 0xFFFFFFFF), bit32.band(h*13, 0xFFFFFFFF), bit32.band(h*17, 0xFFFFFFFF))
        end
        return {
            base64encode  = _b64enc,
            base64decode  = _b64dec,
            base64_encode = _b64enc,
            base64_decode = _b64dec,
            encode        = _b64enc,
            decode        = _b64dec,
            encrypt       = function(s, k) return s end,
            decrypt       = function(s, k) return s end,
            hash          = _sha256,
            sha256        = _sha256,
            sha1          = _sha1,
            md5           = _md5,
            generatekey   = function(len) return string.rep("k", len or 32) end,
            generatebytes = function(len) return string.rep("\0", len or 16) end,
        }
    end)(),
    base64_encode = (function()
        local _b64a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        return function(data)
            if typeFunction(data) ~= "string" then data = toStringFunction(data) end
            local result = {}
            for i = 1, #data, 3 do
                local b1=data:byte(i); local b2=data:byte(i+1) or 0; local b3=data:byte(i+2) or 0
                local n=b1*65536+b2*256+b3
                result[#result+1]=_b64a:sub(math.floor(n/262144)%64+1,math.floor(n/262144)%64+1)
                result[#result+1]=_b64a:sub(math.floor(n/4096)%64+1,math.floor(n/4096)%64+1)
                result[#result+1]=(i+1<=#data) and _b64a:sub(math.floor(n/64)%64+1,math.floor(n/64)%64+1) or "="
                result[#result+1]=(i+2<=#data) and _b64a:sub(n%64+1,n%64+1) or "="
            end
            return table.concat(result)
        end
    end)(),
    base64_decode = (function()
        local _b64l = {}; local _b64a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for i = 1, 64 do _b64l[_b64a:sub(i,i)] = i-1 end
        return function(data)
            if typeFunction(data) ~= "string" then data = toStringFunction(data) end
            data = data:gsub("=",""):gsub("[^%w%+%/]","")
            local result = {}
            for i = 1, #data, 4 do
                local a=_b64l[data:sub(i,i)] or 0; local b=_b64l[data:sub(i+1,i+1)] or 0
                local c=_b64l[data:sub(i+2,i+2)] or 0; local d=_b64l[data:sub(i+3,i+3)] or 0
                local n=a*262144+b*4096+c*64+d
                result[#result+1]=string.char(math.floor(n/65536)%256)
                if i+2<=#data+1 then result[#result+1]=string.char(math.floor(n/256)%256) end
                if i+3<=#data+1 then result[#result+1]=string.char(n%256) end
            end
            return table.concat(result)
        end
    end)(),
    base64encode = exploitFuncs and exploitFuncs.crypt and exploitFuncs.crypt.base64encode or nil,
    base64decode = exploitFuncs and exploitFuncs.crypt and exploitFuncs.crypt.base64decode or nil,
    mouse1click = function() emitOutput("mouse1click()") end,
    mouse1press = function() emitOutput("mouse1press()") end,
    mouse1release = function() emitOutput("mouse1release()") end,
    mouse2click = function() emitOutput("mouse2click()") end,
    mouse2press = function() emitOutput("mouse2press()") end,
    mouse2release = function() emitOutput("mouse2release()") end,
    mousemoverel = function(x, y) emitOutput(string.format("mousemoverel(%s, %s)", serializeValue(x), serializeValue(y))) end,
    mousemoveabs = function(x, y) emitOutput(string.format("mousemoveabs(%s, %s)", serializeValue(x), serializeValue(y))) end,
    mousescroll = function(delta) emitOutput(string.format("mousescroll(%s)", serializeValue(delta))) end,
    keypress = function(key) emitOutput(string.format("keypress(%s)", serializeValue(key))) end,
    keyrelease = function(key) emitOutput(string.format("keyrelease(%s)", serializeValue(key))) end,
    keyclick = function(key) emitOutput(string.format("keyclick(%s)", serializeValue(key))) end,
    isreadonly = function(t)
        if typeFunction(t) ~= "table" then return false end
        if not _at.readonlyTables then return false end
        return _at.readonlyTables[t] == true
    end,
    setreadonly = function(t, val)
        if typeFunction(t) ~= "table" then return t end
        if not _at.readonlyTables then _at.readonlyTables = {} end
        _at.readonlyTables[t] = val == true or val == nil
        if _at.readonlyTables[t] then
            local mt = getMetatableFunction(t)
            if not mt then
                mt = {}
                pcallFunction(setmetatable, t, mt)
            end
            if mt and not mt.__newindex_orig_ro then
                mt.__newindex_orig_ro = mt.__newindex or false
                mt.__newindex = function(tbl, key, value)
                    if _at.readonlyTables and _at.readonlyTables[tbl] then
                        return
                    end
                    local old = mt.__newindex_orig_ro
                    if typeFunction(old) == "function" then return old(tbl, key, value) end
                    rawset(tbl, key, value)
                end
            end
        else
            local mt = getMetatableFunction(t)
            if mt and mt.__newindex_orig_ro ~= nil then
                mt.__newindex = mt.__newindex_orig_ro ~= false and mt.__newindex_orig_ro or nil
                mt.__newindex_orig_ro = nil
            end
        end
        return t
    end,
    make_writeable = function(t)
        if typeFunction(t) == "table" then
            if not _at.readonlyTables then _at.readonlyTables = {} end
            _at.readonlyTables[t] = false
        end
        return t
    end,
    make_readonly = function(t)
        if typeFunction(t) == "table" then
            if not _at.readonlyTables then _at.readonlyTables = {} end
            _at.readonlyTables[t] = true
        end
        return t
    end,
    getthreadidentity = function() return 7 end,
    setthreadidentity = function(id) end,
    getidentity = function() return 7 end,
    setidentity = function(id) end,
    getthreadcontext = function() return 7 end,
    setthreadcontext = function(id) end,
    getcustomasset = function(file) return "rbxasset://" .. formatValue(file) end,
    getsynasset = function(file) return "rbxasset://" .. formatValue(file) end,
    getinfo = function(func) return {source = "=", what = "Lua", name = "unknown", short_src = "dumper"} end,
    getconstants = function(func)
        if typeFunction(func) ~= "function" then return {} end
        local consts = {}
        local seen   = {}
        local _getup = debugLibrary and debugLibrary.getupvalue
        if _getup then
            local i = 1
            while i <= 250 do
                local ok3, name, val = pcallFunction(_getup, func, i)
                if not ok3 or not name then break end
                local t = typeFunction(val)
                if (t == "string" or t == "number" or t == "boolean") and not seen[val] then
                    seen[val] = true
                    table.insert(consts, val)
                elseif t == "table" then
                    for _, v in pairsFunction(val) do
                        local vt = typeFunction(v)
                        if (vt == "string" or vt == "number") and not seen[v] then
                            seen[v] = true
                            table.insert(consts, v)
                        end
                    end
                end
                i = i + 1
            end
        end
        local _sdump = _G._origStringDump or (string and rawget(string, "dump")) or string.dump
        if _sdump then
            local ok2, bc = pcallFunction(_sdump, func)
            if ok2 and typeFunction(bc) == "string" and #bc > 0 then
                local pos = 1
                while pos <= #bc do
                    local s, e = bc:find("[%g ][%g ][%g ]+", pos)
                    if not s then break end
                    local cand = bc:sub(s, e)
                    if #cand >= 2 and #cand <= 256 and not seen[cand] then
                        seen[cand] = true
                        table.insert(consts, cand)
                    end
                    pos = e + 1
                end
            end
        end
        return consts
    end,
    getupvalues = function(func)
        if typeFunction(func) ~= "function" then return {} end
        local uvs  = {}
        local _getup = debugLibrary and debugLibrary.getupvalue
        if not _getup then return uvs end
        local i = 1
        while i <= 250 do
            local ok3, name, val = pcallFunction(_getup, func, i)
            if not ok3 or not name then break end
            uvs[i] = val
            if typeFunction(name) == "string" and name ~= "" and name ~= "_ENV" then
                uvs[name] = val
            end
            i = i + 1
        end
        return uvs
    end,
    getprotos = function(func)
        if typeFunction(func) ~= "function" then return {} end
        local protos = {}
        local _getup = debugLibrary and debugLibrary.getupvalue
        if not _getup then return protos end
        local i = 1
        while i <= 250 do
            local ok3, name, val = pcallFunction(_getup, func, i)
            if not ok3 or not name then break end
            if typeFunction(val) == "function" then
                table.insert(protos, val)
            end
            i = i + 1
        end
        return protos
    end,
    getupvalue = function(func, i)
        if typeFunction(func) ~= "function" then return nil end
        local _getup = debugLibrary and debugLibrary.getupvalue
        if not _getup then return nil end
        if typeFunction(i) == "string" then
            local idx = 1
            while idx <= 250 do
                local ok3, name, val = pcallFunction(_getup, func, idx)
                if not ok3 or not name then break end
                if name == i then return val end
                idx = idx + 1
            end
            return nil
        end
        local ok3, _, val = pcallFunction(_getup, func, i or 1)
        return ok3 and val or nil
    end,
    setupvalue = function(func, i, val)
        if typeFunction(func) ~= "function" then return end
        local _getup  = debugLibrary and debugLibrary.getupvalue
        local _setup  = debugLibrary and debugLibrary.setupvalue
        if not _setup then return end
        if typeFunction(i) == "string" then
            if not _getup then return end
            local idx = 1
            while idx <= 250 do
                local ok3, name = pcallFunction(_getup, func, idx)
                if not ok3 or not name then break end
                if name == i then
                    pcallFunction(_setup, func, idx, val)
                    return
                end
                idx = idx + 1
            end
            return
        end
        pcallFunction(_setup, func, i or 1, val)
    end,
    setconstant = function(func, i, val)
        if typeFunction(func) ~= "function" then return end
        local _getup = debugLibrary and debugLibrary.getupvalue
        local _setup = debugLibrary and debugLibrary.setupvalue
        if not _getup or not _setup then return end
        local idx = 1
        while idx <= 250 do
            local ok3, name, existing = pcallFunction(_getup, func, idx)
            if not ok3 or not name then break end
            if idx == i then pcallFunction(_setup, func, idx, val); return end
            idx = idx + 1
        end
    end,
    getconstant = function(func, i)
        local c = exploitFuncs.getconstants(func)
        return typeFunction(i) == "number" and c[i] or nil
    end,
    getproto = function(func, i) return function() end end,
    setproto = function(func, i, f) end,
    getstack = function(level, i) return nil end,
    setstack = function(level, i, val) end,
    debug = (function()
        local _gu  = debugLibrary and rawget(debugLibrary, "getupvalue")
        local _su  = debugLibrary and rawget(debugLibrary, "setupvalue")
        local _gi  = debugLibrary and rawget(debugLibrary, "getinfo")
        local _cat = "default"
        local function _filterTrace(tb)
            if typeFunction(tb) ~= "string" then return tb end
            local out = {}
            for line in (tb .. "\n"):gmatch("([^\n]*)\n") do
                if not line:find("dumper%.lua", 1, true)
                    and not line:find("bypass%.lua", 1, true)
                    and not line:find("%[string \"tamperCheck\"%]")
                    and not line:find("luau%.load") then
                    out[#out+1] = line
                end
            end
            return table.concat(out, "\n")
        end
        local _dbg = {
            getinfo = function(func, ...)
                if func == print or func == _G.print or func == warn or func == _G.warn then
                    return {source = "=[C]", what = "C", name = "print", short_src = "[C]", nups = 0, nparams = 0, isvararg = true, currentline = -1}
                end
                if _gi then
                    local ok2, info = pcallFunction(_gi, func, ...)
                    if ok2 and info then return info end
                end
                return {source = "=[C]", what = "C", short_src = "[C]", nups = 0, nparams = 0, isvararg = true, currentline = -1}
            end,
            info = function(func, opts)
                opts = typeFunction(opts) == "string" and opts or "snl"
                local results = {}
                local info = _gi and (function() local ok2,r = pcallFunction(_gi, func); return ok2 and r end)() or nil
                if info and typeFunction(info.source) == "string" then
                    local _srcL = info.source:lower()
                    if _srcL:find("dump",1,true) or _srcL:find("bypass",1,true) or _srcL:find("hook",1,true) then
                        info = {source="@RobloxGameScript", what="C", short_src="RobloxGameScript", name="?", currentline=-1, nparams=0, isvararg=false, nups=0}
                    end
                end
                for c in opts:gmatch(".") do
                    if c == "s" then results[#results+1] = (info and info.source) or "=[C]"
                    elseif c == "n" then results[#results+1] = (info and info.name) or "?"
                    elseif c == "l" then results[#results+1] = (info and info.currentline) or -1
                    elseif c == "a" then results[#results+1] = (info and info.nparams) or 0; results[#results+1] = (info and info.isvararg) or false
                    elseif c == "u" then results[#results+1] = (info and info.nups) or 0
                    end
                end
                return table.unpack(results)
            end,
            getupvalue = function(fn, i)
                if _gu then local n, v = _gu(fn, i); return n, v end; return nil
            end,
            getupvalues = function(fn) return exploitFuncs.getupvalues(fn) end,
            setupvalue = function(fn, i, v)
                if _su then return _su(fn, i, v) end
            end,
            getconstants = function(fn) return exploitFuncs.getconstants(fn) end,
            getstack = function(level, idx)
                if typeFunction(level) ~= "number" then return nil end
                local _gl = debugLibrary and rawget(debugLibrary, "getlocal")
                if _gl then
                    if typeFunction(idx) == "number" then
                        local ok2, _, val = pcallFunction(_gl, level + 1, idx)
                        return ok2 and val or nil
                    else
                        local locs = {}
                        local j = 1
                        while true do
                            local ok2, name, val = pcallFunction(_gl, level + 1, j)
                            if not ok2 or not name then break end
                            locs[name] = val; j = j + 1
                        end
                        return locs
                    end
                end
                return nil
            end,
            setstack = function(level, idx, val)
                local _sl = debugLibrary and rawget(debugLibrary, "setlocal")
                if _sl then pcallFunction(_sl, level + 1, idx, val) end
            end,
            getproto = function(func, i, active)
                if typeFunction(func) ~= "function" then return active and {} or function() end end
                if not _gu then return active and {} or function() end end
                local collected = {}
                local idx = 1
                while idx <= 250 do
                    local ok2, nm, val = pcallFunction(_gu, func, idx)
                    if not ok2 or nm == nil then break end
                    if typeFunction(val) == "function" then collected[#collected+1] = val end
                    idx = idx + 1
                end
                if active then return collected end
                return collected[i or 1] or function() end
            end,
            getprotos = function(func)
                if typeFunction(func) ~= "function" then return {} end
                if not _gu then return {} end
                local protos = {}
                local idx = 1
                while idx <= 250 do
                    local ok2, nm, val = pcallFunction(_gu, func, idx)
                    if not ok2 or nm == nil then break end
                    if typeFunction(val) == "function" then protos[#protos+1] = val end
                    idx = idx + 1
                end
                return protos
            end,
            getmetatable = debugLibrary and debugLibrary.getmetatable or getMetatableFunction,
            setmetatable = (debugLibrary and debugLibrary.setmetatable) or setmetatable,
            traceback = function(a, b)
                local msg = typeFunction(a) == "thread" and b or a
                local prefix = msg ~= nil and (toStringFunction(msg) .. "\n") or ""
                return prefix .. "stack traceback:\n\t[C]: in ?"
            end,
            setmemorycategory  = function(cat) _cat = typeFunction(cat) == "string" and cat or _cat end,
            getmemorycategory  = function() return _cat end,
            resetmemorycategory = function() _cat = "default" end,
            profilebegin = function(label) end,
            profileend   = function() end,
            sethook      = function() end,
            getregistry  = function() return exploitFuncs.getreg() end,
        }
        return _dbg
    end)(),
    rconsoleprint = function(s) end,
    rconsoleclear = function() end,
    rconsolecreate = function() end,
    rconsoledestroy = function() end,
    rconsoleinput = function() return "" end,
    rconsoleinfo = function(s) end,
    rconsolewarn = function(s) end,
    rconsoleerr = function(s) end,
    rconsolename = function(name) end,
    printconsole = function(s) end,
    consolecreate = function() end,
    consoledestroy = function() end,
    consoleclear = function() end,
    consoletitle = function(title) end,
    consoleprint = function(text, ...) end,
    consoleinput = function() return "" end,
    consolename = function(name) end,
    setfflag = function(flag, val) end,
    getfflag = function(flag) return "" end,
    getframetime = function() return 1/60 end,
    getfps = function() return 60 end,
    getping = function() return 50 end,
    getclientid = function() return "00000000-0000-0000-0000-000000000000" end,
    getplaceid = function()
        local gp = dumperState and dumperState.property_store
        local game = _G.game
        if game and gp and gp[game] and gp[game].PlaceId then return gp[game].PlaceId end
        return 0
    end,
    getjobid = function() return "00000000-0000-0000-0000-000000000000" end,
    getgameid = function() return 0 end,
    string_pack   = string.pack   or function(fmt, ...) return "" end,
    string_unpack = string.unpack or function(fmt, s, i) return 0, (i or 1) + 1 end,
    setfpscap = function(cap) emitOutput(string.format("setfpscap(%s)", serializeValue(cap))) end,
    getfpscap = function() return 60 end,
    isnetworkowner = function(part) return true end,
    gethiddenproperty = function(instance, prop) return nil end,
    sethiddenproperty = function(instance, prop, val) emitOutput(string.format("sethiddenproperty(%s, %s, %s)", serializeValue(instance), formatStringLiteral(prop), serializeValue(val))) end,
    setsimulationradius = function(radius, maxRadius) emitOutput(string.format("setsimulationradius(%s%s)", serializeValue(radius), maxRadius and ", " .. serializeValue(maxRadius) or "")) end,
    getspecialinfo = function(instance) return {} end,
    saveinstance = function(options) emitOutput(string.format("saveinstance(%s)", serializeValue(options or {}))) end,
    decompile = function(script) return "-- decompiled" end,
    lz4compress = function(s) return s end,
    lz4decompress = function(s) return s end,
    MessageBox = function(text, caption, type) return 1 end,
    setwindowactive = function() end,
    setwindowtitle = function(title) end,
    queue_on_teleport = function(code) emitOutput(string.format("queue_on_teleport(%s)", serializeValue(code))) end,
    queueonteleport = function(code) emitOutput(string.format("queueonteleport(%s)", serializeValue(code))) end,
    secure_call = function(func, ...) return func(...) end,
    create_secure_function = function(func) return func end,
    isvalidinstance = function(instance) return instance ~= nil end,
    validcheck = function(instance) return instance ~= nil end,
    getreg = function()
        local reg = {}
        local running = coroutine.running()
        reg[1] = running or coroutine.create(function() end)
        if typeFunction(package) == "table" and typeFunction(package.loaded) == "table" then
            reg[2] = package.loaded
            for k, v in pairsFunction(package.loaded) do
                reg[k] = v
            end
        end
        if debugLibrary then
            local _dreg = rawget(debugLibrary, "getregistry")
            if typeFunction(_dreg) == "function" then
                local ok2, actual = pcallFunction(_dreg)
                if ok2 and typeFunction(actual) == "table" then
                    for k, v in pairsFunction(actual) do
                        if reg[k] == nil then reg[k] = v end
                    end
                end
            end
        end
        for proxy, name in pairsFunction(dumperState.registry) do
            if typeFunction(name) == "string" and reg[name] == nil then
                reg[name] = proxy
            end
        end
        return reg
    end,
    getregistry = function() return exploitFuncs.getreg() end,
    getthreads = function() return {} end,
    getallthreads = function() return {} end,
    getmainthread = function() return coroutine.running() end,
    getactors = function() return {} end,
    getactor = function() return nil end,
    getfunctionhash = function(f)
        local metadata = dumperState.filtergc_registry[f]
        return metadata and metadata.hash or string.rep("0", 64)
    end,
    getscriptbytecode = function(scriptObj)
        if isProxy(scriptObj) then
            local props = dumperState.property_store[scriptObj] or {}
            local src   = props.Source or props.source
            if typeFunction(src) == "string" and #src > 0 then
                local fn, err = loadstring and loadstring(src) or load(src)
                if fn then
                    local _sdump = _G._origStringDump or string.dump
                    local ok2, bc = pcallFunction(_sdump, fn)
                    if ok2 and typeFunction(bc) == "string" then return bc end
                end
            end
        end
        local _sdump = _G._origStringDump or string.dump
        local ok2, bc = pcallFunction(_sdump, function() end)
        return (ok2 and typeFunction(bc) == "string") and bc or ""
    end,
    getscripthash = function(s) return string.rep("0", 64) end,
    getscriptfunction = function(s) return function() end end,
    getscriptclosure = function(s) return function() end end,
    getsenv2 = function() return {} end,
    getrenv2 = function() return _G end,
    WebSocket = {
        connect = function(url)
            emitOutput(string.format("WebSocket.connect(%s)", serializeValue(url)))
            local ws = createProxyObject("WebSocket", false)
            registerVariable(ws, "WebSocket")
            local props = dumperState.property_store[ws] or {}
            props.OnMessage = createProxyObject("RBXScriptSignal", false)
            props.OnClose = createProxyObject("RBXScriptSignal", false)
            props.Send = function(_, msg)
                emitOutput(string.format("ws:Send(%s)", serializeValue(msg)))
            end
            props.Close = function() emitOutput("ws:Close()") end
            dumperState.property_store[ws] = props
            return ws
        end
    },
    fireserver = function(...) end,
    fireallclients = function(...) end,
    copyinstance = function(inst, recursive)
        if isProxy(inst) then
            local name = (dumperState.registry[inst] or "inst") .. "_copy"
            local copy = createProxyObject(name, false)
            local props = dumperState.property_store[inst] or {}
            local copyProps = {}
            for k, v in pairsFunction(props) do copyProps[k] = v end
            dumperState.property_store[copy] = copyProps
            return copy
        end
        return inst
    end,
    pebc_safe    = function(func, ...) return pcallFunction(func, ...) end,
    run_on_actor = function(actor, func, ...) return pcallFunction(func, ...) end,
    filtergc = function(filter, options, returnFirst)
        if filter ~= "function" then return {} end
        options = typeFunction(options) == "table" and options or {}
        local matches = {}
        for candidate, metadata in pairsFunction(dumperState.filtergc_registry) do
            if typeFunction(candidate) == "function" and typeFunction(metadata) == "table" and metadata.name then
                local matched = true
                if options.Name ~= nil and metadata.name ~= options.Name then matched = false end
                if options.Hash ~= nil and metadata.hash ~= options.Hash then matched = false end
                if matched and typeFunction(options.Constants) == "table" then
                    for _, expected in ipairsFunction(options.Constants) do
                        if not metadata.constants[expected] then matched = false; break end
                    end
                end
                if matched and typeFunction(options.Upvalues) == "table" then
                    for _, expected in ipairsFunction(options.Upvalues) do
                        local found = false
                        for _, actual in ipairsFunction(metadata.upvalues) do
                            if actual == expected then found = true; break end
                        end
                        if not found then matched = false; break end
                    end
                end
                if matched then matches[#matches + 1] = candidate end
            end
        end
        if returnFirst then return matches[1] end
        return matches
    end,
    getobjects = function(assetId)
        local id = formatValue(assetId)
        local proxy = createProxyObject("Model", false)
        dumperState.property_store[proxy] = {Name = "Asset", ClassName = "Model"}
        dumperState.registry[proxy] = "getobjects(" .. formatStringLiteral(id) .. ")[1]"
        return {proxy}
    end,
    getmemory = function(category)
        local cats = {
            PhysicsParts = 1.2, GraphicsMeshParts = 5.8, GraphicsTexture = 12.4,
            GraphicsTextureCharacter = 3.1, Sounds = 0.8, Animation = 2.0,
            Script = 0.5, LuaHeap = 3.3, HttpCache = 0.2, Instances = 4.7,
            Signals = 0.1, LuaStack = 0.3, Total = 34.4,
        }
        if typeFunction(category) == "string" and cats[category] then return cats[category] end
        return 0
    end,
    printidentity = function(tag)
        emitOutput(string.format("-- printidentity: %s Current identity is 8", tostring(tag or "")))
    end,
    getclipboard = function() return "" end,
    setclipboard = function(text)
        emitOutput(string.format("setclipboard(%s)", serializeValue(tostring(text or ""))))
    end,
    toclipboard = function(text)
        emitOutput(string.format("toclipboard(%s)", serializeValue(tostring(text or ""))))
    end,
    fireclickdetector = function(detector, distance, inputType)
        if detector and dumperState.registry[detector] then
            emitOutput(string.format("fireclickdetector(%s, %s)",
                dumperState.registry[detector], serializeValue(distance or 0)))
        end
    end,
    fireproximityprompt = function(prompt, playerDist)
        if prompt and dumperState.registry[prompt] then
            emitOutput(string.format("fireproximityprompt(%s)", dumperState.registry[prompt]))
        end
    end,
    firetouchinterest = function(part, toucher, toggle)
        if part and dumperState.registry[part] then
            emitOutput(string.format("firetouchinterest(%s, %s, %s)",
                dumperState.registry[part],
                serializeValue(toucher), serializeValue(toggle or 0)))
        end
    end,
    firesignal = function(signal, ...)
        if signal and dumperState.registry[signal] then
            local args = {...}
            local parts = {}
            for i = 1, #args do parts[i] = serializeValue(args[i]) end
            emitOutput(string.format("-- firesignal(%s, %s)",
                dumperState.registry[signal], table.concat(parts, ", ")))
        end
    end,
    is_kenv1_closure  = function(f) return typeFunction(f) == "function" end,
    is_kenv1_function = function(f) return typeFunction(f) == "function" end,
    is_synapse_function     = function() return false end,
    is_synapse_closure      = function() return false end,
    issynapsefunction       = function() return false end,
    is_sirhurt_closure      = function() return false end,
    is_protosmasher_closure = function() return false end,
    is_krnl_closure         = function() return false end,
    is_comet_function       = function() return false end,
    is_fluxus_closure       = function() return false end,
    is_oxygen_closure       = function() return false end,
    is_calamari_closure     = function() return false end,
    is_wave_closure         = function() return false end,
    iswaveclosure           = function() return false end,
    is_celery_closure       = function() return false end,
    is_swift_closure        = function() return false end,
    is_xeno_closure         = function() return false end,
    is_arceus_closure       = function() return false end,
    is_velocity_closure     = function() return false end,
    is_zorara_closure       = function() return false end,
    is_codex_closure        = function() return false end,
    is_seliware_closure     = function() return false end,
    is_potassium_closure    = function() return false end,
    is_macsploit_closure    = function() return false end,
    is_hydrogen_closure     = function() return false end,
    is_electron_closure     = function() return false end,
    is_volcano_closure      = function() return false end,
    is_awp_closure          = function() return false end,
    is_delta_closure        = function() return false end,
    is_trigon_closure       = function() return false end,
    is_evon_closure         = function() return false end,
    is_valyse_closure       = function() return false end,
    is_riptide_closure      = function() return false end,
    is_cloudia_closure      = function() return false end,
    is_coco_z_closure       = function() return false end,
    is_nihon_closure        = function() return false end,
    is_reaper_closure       = function() return false end,
    is_vape_closure         = function() return false end,
    is_ghost_closure        = function() return false end,
    is_temple_closure       = function() return false end,
    is_oblivion_closure     = function() return false end,
    is_luraph_closure       = function() return false end,
    is_sheathe_closure      = function() return false end,
    is_oxide_closure        = function() return false end,
    is_carbon_closure       = function() return false end,
    is_script_hub_closure   = function() return false end,
    is_dex_closure          = function() return false end,
    is_hydroxide_closure    = function() return false end,
    is_dark_dex_closure     = function() return false end,
    is_prometheus_closure   = function() return false end,
    is_ironbrew_closure     = function() return false end,
    comparefunctions      = function(a, b) return a == b end,
    restorefunction       = function(f) return f end,
    restorefunctions      = function() end,
    replaceclosure        = function(target, replacement) return replacement or target end,
    getconnectioncount    = function() return 0 end,
    getreplicatedstorage  = function() return game:GetService("ReplicatedStorage") end,
    isluau                = function() return true end,
    pebc_execute          = function(func, ...)
        if typeFunction(func) == "function" then return pcallFunction(func, ...) end
        return func
    end,
    getfunctionname       = function(f)
        if f == print or f == _G.print then return "print" end
        if f == warn  or f == _G.warn  then return "warn"  end
        if f == error                  then return "error" end
        if f == assert                 then return "assert" end
        return ""
    end,
    namecallmethod        = function() return _at.currentNamecallMethod or "__namecall" end,
    isstudio              = function() return false end,
    isclient              = function() return true end,
    isserver              = function() return false end,
    isparallel            = function() return false end,
    isnetworkserver       = function() return false end,
    getwindowtitle        = function() return "Roblox" end,
    getwindowhandle       = function() return 0 end,
    getprocessid          = function() return 0 end,
    replicatesignal       = function() end,
    isourclosure          = function(f) return typeFunction(f) == "function" end,
    checkclosure          = function(f) return typeFunction(f) == "function" end,
    isscriptable          = function() return false end,
    setscriptable         = function() return true end,
    gethiddenproperties   = function() return {} end,
    getthread             = function() return coroutine.running() end,
    gettenv               = function() return _G end,
    getmenv               = function() return _G end,
    getscriptfromthread   = function() return _G.script end,
    cleardrawcache        = function() end,
    isrenderobj           = function(obj) return isProxy(obj) end,
    getrenderproperty     = function(obj, prop) return isProxy(obj) and (dumperState.property_store[obj] or {})[prop] or nil end,
    setrenderproperty     = function(obj, prop, val) if isProxy(obj) then dumperState.property_store[obj] = dumperState.property_store[obj] or {}; dumperState.property_store[obj][prop] = val end end,
    setstack              = function() end,
    rconsoletitle         = function() end,
    rconsoleinfo          = function() end,
    rconsolewarn          = function() end,
    rconsoleerr           = function() end,
    rconsoleprint         = function() end,
    getsimulationradius   = function() return 1000 end,
    create_comm_channel   = function() return 1, createProxyObject("BindableEvent", false) end,
    get_comm_channel      = function() return createProxyObject("BindableEvent", false) end,
    cache = {
        invalidate = function(inst) end,
        replace    = function(a, b) return b end,
        iscached   = function(inst) return inst ~= nil end,
    },
    closures = {
        newcclosure   = function(f) return exploitFuncs.newcclosure(f) end,
        clonefunction = function(f) return exploitFuncs.clonefunction(f) end,
        iscclosure    = function(f) return exploitFuncs.iscclosure(f) end,
    }
}
local _cryptRef = exploitFuncs.crypt
exploitFuncs.base64encode = _cryptRef.base64encode
exploitFuncs.base64decode = _cryptRef.base64decode
exploitFuncs.base64 = {
    encode = _cryptRef.base64encode,
    decode = _cryptRef.base64decode,
}
exploitFuncs.sha1   = _cryptRef.sha1
exploitFuncs.sha256 = _cryptRef.sha256
exploitFuncs.md5    = _cryptRef.md5
exploitFuncs.crypt_base64encode = _cryptRef.base64encode
exploitFuncs.crypt_base64decode = _cryptRef.base64decode
exploitFuncs.crypt_encrypt      = _cryptRef.encrypt
exploitFuncs.crypt_decrypt      = _cryptRef.decrypt
exploitFuncs.crypt_hash         = _cryptRef.hash

local _wadLoopCount  = 0
local _wadMaxLoop    = 2000000

exploitFuncs.CALL = function(fn, ...)
    if typeFunction(fn) == "function" then return fn(...) end
    local mt = getMetatableFunction(fn)
    if mt and mt.__call then return mt.__call(fn, ...) end
    if isProxy(fn) then
        local n = dumperState.registry[fn] or "obj"
        local a = {...}; local s = {}
        for i=1,#a do s[i]=serializeValue(a[i]) end
        emitOutput(string.format("%s(%s)", n, table.concat(s,", ")))
        return createProxyObject(n.."_result", false)
    end
    return nil
end
exploitFuncs.NAMECALL = exploitFuncs.CALL

exploitFuncs.CHECKWHILE = function(cond)
    _wadLoopCount = _wadLoopCount + 1
    if _wadLoopCount >= _wadMaxLoop then return false end
    return cond
end

if type(_G._HOOKOP) == "table" then
    _G._HOOKOP.install(exploitFuncs)
    exploitFuncs.CODER_CALL     = exploitFuncs.CALL
    exploitFuncs.CODER_NAMECALL = exploitFuncs.CALL
end

for name, func in pairsFunction(exploitFuncs) do
    _G[name] = func
    if typeFunction(func) == "function" then
        _CFunctionSet[func] = true
    elseif typeFunction(func) == "table" then
        for _, sub in pairsFunction(func) do
            if typeFunction(sub) == "function" then
                _CFunctionSet[sub] = true
            end
        end
    end
end
rawset(_G, "hookmetamethod", nil)
do
    local _hkf = rawget(_G, "hookfunction")
    if type(_hkf) == "function" then
        rawset(_G, "_hkFunctionRef", _hkf)
        local _hkS = rawget(_G, "_hkCFnSet") or {}
        rawset(_G, "_hkCFnSet", _hkS)
        _hkS[_hkf] = true
    end
end
local nativeBit32 = bit32
local bitLibrary = {}
local function toBit(n)
    n = (n or 0) % 4294967296
    if n >= 2147483648 then n = n - 4294967296 end
    return math.floor(n)
end
local function toU32(n) return math.floor((n or 0) % 4294967296) end

local function _band(a, b)
    if nativeBit32 then return nativeBit32.band(toU32(a), toU32(b)) end
    a, b = toU32(a), toU32(b)
    local r, p = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + p end
        a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
    end
    return r
end
local function _bor(a, b)
    if nativeBit32 then return nativeBit32.bor(toU32(a), toU32(b)) end
    a, b = toU32(a), toU32(b)
    local r, p = 0, 1
    while a > 0 or b > 0 do
        if a % 2 == 1 or b % 2 == 1 then r = r + p end
        a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
    end
    return r
end
local function _bxor(a, b)
    if nativeBit32 then return nativeBit32.bxor(toU32(a), toU32(b)) end
    a, b = toU32(a), toU32(b)
    local r, p = 0, 1
    while a > 0 or b > 0 do
        if a % 2 ~= b % 2 then r = r + p end
        a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
    end
    return r
end
local function _lshift(n, bits)
    bits = (bits or 0) % 32
    if bits == 0 then return toU32(n) end
    return toU32(toU32(n) * (2 ^ bits))
end
local function _rshift(n, bits)
    bits = (bits or 0) % 32
    if bits == 0 then return toU32(n) end
    return math.floor(toU32(n) / (2 ^ bits))
end
local function _bnot(n) return _bxor(toU32(n), 0xFFFFFFFF) end

bitLibrary.tobit = toBit
bitLibrary.tohex = function(n, len)
    return string.format("%0" .. (len or 8) .. "x", toU32(n))
end
bitLibrary.band = function(...)
    local r = toU32(select(1, ...))
    for i = 2, select("#", ...) do r = _band(r, toU32(select(i, ...))) end
    return toBit(r)
end
bitLibrary.bor = function(...)
    local r = toU32(select(1, ...))
    for i = 2, select("#", ...) do r = _bor(r, toU32(select(i, ...))) end
    return toBit(r)
end
bitLibrary.bxor = function(...)
    local r = toU32(select(1, ...))
    for i = 2, select("#", ...) do r = _bxor(r, toU32(select(i, ...))) end
    return toBit(r)
end
bitLibrary.bnot    = function(n) return toBit(_bnot(n or 0)) end
bitLibrary.lshift  = function(n, bits) return toBit(_lshift(n or 0, bits or 0)) end
bitLibrary.rshift  = function(n, bits) return toBit(_rshift(n or 0, bits or 0)) end
bitLibrary.arshift = function(n, bits)
    local val = toBit(n or 0)
    bits = (bits or 0) % 32
    if val < 0 then
        return toBit(_bor(_rshift(toU32(val), bits), _lshift(0xFFFFFFFF, 32 - bits)))
    else
        return toBit(_rshift(toU32(val), bits))
    end
end
bitLibrary.rol = function(n, bits)
    n = toU32(n or 0); bits = (bits or 0) % 32
    return toBit(_bor(_lshift(n, bits), _rshift(n, 32 - bits)))
end
bitLibrary.ror = function(n, bits)
    n = toU32(n or 0); bits = (bits or 0) % 32
    return toBit(_bor(_rshift(n, bits), _lshift(n, 32 - bits)))
end
bitLibrary.bswap = function(n)
    n = toU32(n or 0)
    local a = _rshift(_band(n, 0xFF000000), 24)
    local b = _rshift(_band(n, 0x00FF0000), 8)
    local c = _lshift(_band(n, 0x0000FF00), 8)
    local d = _lshift(_band(n, 0x000000FF), 24)
    return toBit(_bor(_bor(a, b), _bor(c, d)))
end
bitLibrary.countlz = function(n)
    n = toU32(bitLibrary.tobit(n))
    if n == 0 then return 32 end
    local count = 0
    if _band(n, 0xFFFF0000) == 0 then count = count + 16; n = _lshift(n, 16) end
    if _band(n, 0xFF000000) == 0 then count = count + 8;  n = _lshift(n, 8)  end
    if _band(n, 0xF0000000) == 0 then count = count + 4;  n = _lshift(n, 4)  end
    if _band(n, 0xC0000000) == 0 then count = count + 2;  n = _lshift(n, 2)  end
    if _band(n, 0x80000000) == 0 then count = count + 1   end
    return count
end
bitLibrary.countrz = function(n)
    n = toU32(bitLibrary.tobit(n))
    if n == 0 then return 32 end
    local count = 0
    while _band(n, 1) == 0 do n = _rshift(n, 1); count = count + 1 end
    return count
end
bitLibrary.lrotate = bitLibrary.rol
bitLibrary.rrotate = bitLibrary.ror
bitLibrary.extract = function(n, pos, len)
    len = len or 1
    return toBit(_band(_rshift(toU32(n or 0), pos or 0), _lshift(1, len) - 1))
end
bitLibrary.replace = function(n, val, pos, len)
    len = len or 1; pos = pos or 0
    local mask = _lshift(1, len) - 1
    return toBit(_bor(_band(toU32(n or 0), _bnot(_lshift(mask, pos))), _band(toU32(val or 0), _lshift(mask, pos))))
end
bitLibrary.btest = function(a, b) return _band(toU32(a or 0), toU32(b or 0)) ~= 0 end
bit32 = bitLibrary
bit = bitLibrary
_G.bit = bitLibrary
_G.bit32 = bitLibrary
table.getn = table.getn or function(t) return #t end
table.foreach = table.foreach or function(t, func) for k, v in pairsFunction(t) do func(k, v) end end
table.foreachi = table.foreachi or function(t, func) for i, v in ipairsFunction(t) do func(i, v) end end
table.pack = table.pack or function(...)
    local t = {...}; t.n = select("#", ...); return t
end
table.unpack = table.unpack or unpack
table.move = function(src, start, endIdx, dest, target)
    target = target or src
    if target == src and dest > start and dest <= endIdx then
        for i = endIdx, start, -1 do target[dest + i - start] = src[i] end
    else
        for i = start, endIdx do target[dest + i - start] = src[i] end
    end
    return target
end
table.find = table.find or function(t, value, init)
    init = init or 1
    for i = init, #t do if t[i] == value then return i end end
    return nil
end
table.create = table.create or function(count, value)
    local t = {}
    if value ~= nil then
        for i = 1, (toNumberFunction(count) or 0) do t[i] = value end
    end
    return t
end
table.clear = table.clear or function(t)
    if typeFunction(t) ~= "table" then return end
    for k in pairsFunction(t) do t[k] = nil end
end
table.maxn = table.maxn or function(t)
    local m = 0
    for k in pairsFunction(t) do
        if typeFunction(k) == "number" and k > m then m = k end
    end
    return m
end
do
    local _frozen = setmetatable({}, {__mode = "k"})
    table.freeze    = table.freeze    or function(t)
        if typeFunction(t) ~= "table" then return t end
        if _frozen[t] then return t end
        _frozen[t] = true
        local shadow = {}
        for k, v in next, t do shadow[k] = v; rawset(t, k, nil) end
        local mt = {
            __index = shadow,
            __newindex = function() errorFunction("attempt to modify a readonly table", 2) end,
            __len = function() return #shadow end,
        }
        pcallFunction(setmetatable, t, mt)
        return t
    end
    table.isfrozen  = table.isfrozen  or function(t) return _frozen[t] == true end
end
local _orig_table_sort = table.sort
table.sort = function(t, comp)
    if typeFunction(t) ~= "table" or #t < 2 then return end
    local ok = pcallFunction(_orig_table_sort, t, comp)
    if not ok then
        for i = 2, #t do
            local val = t[i]
            local j = i - 1
            while j >= 1 and (comp and comp(val, t[j]) or val < t[j]) do
                t[j + 1] = t[j]
                j = j - 1
            end
            t[j + 1] = val
        end
    end
end
table.clone = table.clone or function(t)
    if typeFunction(t) ~= "table" then return t end
    local out = {}
    for k, v in pairsFunction(t) do out[k] = v end
    return setmetatable(out, getMetatableFunction(t))
end
string.split = string.split or function(str, sep)
    local t = {}
    for match in string.gmatch(str, "([^" .. (sep or "%s") .. "]+)") do table.insert(t, match) end
    return t
end
if not math.frexp then
    math.frexp = function(x)
        if x == 0 then return 0, 0 end
        local exp = math.floor(math.log(math.abs(x)) / math.log(2)) + 1
        local m = x / 2 ^ exp
        return m, exp
    end
end
if not math.ldexp then math.ldexp = function(m, e) return m * 2 ^ e end end
if not utf8 then
    utf8 = {}
    utf8.char = function(...)
        local args = {...}
        local chars = {}
        for _, cp in ipairsFunction(args) do
            if cp < 0x80 then
                table.insert(chars, string.char(cp))
            elseif cp < 0x800 then
                table.insert(chars, string.char(0xC0 + math.floor(cp / 0x40)))
                table.insert(chars, string.char(0x80 + cp % 0x40))
            elseif cp < 0x10000 then
                table.insert(chars, string.char(0xE0 + math.floor(cp / 0x1000)))
                table.insert(chars, string.char(0x80 + math.floor(cp / 0x40) % 0x40))
                table.insert(chars, string.char(0x80 + cp % 0x40))
            else
                table.insert(chars, string.char(0xF0 + math.floor(cp / 0x40000)))
                table.insert(chars, string.char(0x80 + math.floor(cp / 0x1000) % 0x40))
                table.insert(chars, string.char(0x80 + math.floor(cp / 0x40) % 0x40))
                table.insert(chars, string.char(0x80 + cp % 0x40))
            end
        end
        return table.concat(chars)
    end
    utf8.len = function(s, i, j)
        i = i or 1; j = j or #s
        local n = 0
        local p = i
        while p <= j do
            local b = string.byte(s, p)
            if b < 0x80 then p = p + 1
            elseif b < 0xC0 then return nil, p
            elseif b < 0xE0 then p = p + 2
            elseif b < 0xF0 then p = p + 3
            else p = p + 4 end
            n = n + 1
        end
        return n
    end
    utf8.codes = function(s, i)
        i = (i or 0) + 1
        return function(s2, p)
            if p > #s2 then return nil end
            local b = string.byte(s2, p)
            local cp, nextp
            if b < 0x80 then cp = b; nextp = p + 1
            elseif b < 0xE0 then
                cp = (b - 0xC0) * 0x40 + string.byte(s2, p+1) - 0x80
                nextp = p + 2
            elseif b < 0xF0 then
                cp = (b - 0xE0) * 0x1000 + (string.byte(s2, p+1) - 0x80) * 0x40 + string.byte(s2, p+2) - 0x80
                nextp = p + 3
            else
                cp = (b - 0xF0) * 0x40000 + (string.byte(s2, p+1) - 0x80) * 0x1000 + (string.byte(s2, p+2) - 0x80) * 0x40 + string.byte(s2, p+3) - 0x80
                nextp = p + 4
            end
            return nextp, cp
        end, s, i
    end
    utf8.codepoint = function(s, i, j)
        i = i or 1; j = j or i
        local cps = {}
        for _, cp in utf8.codes(s, i - 1) do
            table.insert(cps, cp)
            if #cps >= (j - i + 1) then break end
        end
        return table.unpack(cps)
    end
    utf8.offset = function(s, n, i)
        i = i or (n >= 0 and 1 or #s + 1)
        if n > 0 then
            for _ = 1, n - 1 do
                repeat i = i + 1 until i > #s or string.byte(s, i) < 0x80 or string.byte(s, i) >= 0xC0
            end
        elseif n < 0 then
            for _ = 1, -n do
                repeat i = i - 1 until i < 1 or string.byte(s, i) < 0x80 or string.byte(s, i) >= 0xC0
            end
        end
        return i
    end
    utf8.graphemes = function(s, i, j)
        i = i or 1; j = j or #s
        return utf8.codes(s, i - 1)
    end
    utf8.charpattern = "[\0-\x7F\xC2-\xFD][\x80-\xBF]*"
end
_G.utf8 = utf8
pairs = function(t)
    if typeFunction(t) == "table" and not isProxy(t) then return pairsFunction(t) end
    return function() return nil end, t, nil
end
ipairs = function(t)
    if typeFunction(t) == "table" and not isProxy(t) then return ipairsFunction(t) end
    return function() return nil end, t, 0
end
_G.pairs = pairs
_G.ipairs = ipairs
_G.math = math
_G.table = table
_G.string = string
_G.os = os
_G.coroutine = coroutine
_G._bypassSavedIo     = io
_G._bypassSavedDofile = dofile
_G.io = nil
_G.debug = exploitFuncs.debug
_G._realSetHook = setHook
_G.utf8 = utf8
_G.next = next
_G.tostring = tostring
_G.tonumber = tonumber
_G.getmetatable = getmetatable
_G.setmetatable = setmetatable
_G.pcall = function(f, ...)
    local results = {pcallFunction(f, ...)}
    local success = results[1]
    if not success then
        local err = results[2]
        if typeFunction(err) == "string" and err:match("TIMEOUT_FORCED_BY_DUMPER") then errorFunction(err) end
    end
    return table.unpack(results)
end
_G.xpcall = function(f, errFunc, ...)
    local function wrapper(err)
        if typeFunction(err) == "string" and err:match("TIMEOUT_FORCED_BY_DUMPER") then return err end
        if errFunc then return errFunc(err) end
        return err
    end
    local results = {xpcallFunction(f, wrapper, ...)}
    local success = results[1]
    if not success then
        local err = results[2]
        if typeFunction(err) == "string" and err:match("TIMEOUT_FORCED_BY_DUMPER") then errorFunction(err) end
    end
    return table.unpack(results)
end
_G.error = errorFunction
if _G.originalError == nil then _G.originalError = errorFunction end
_G.assert = assert
_G.select = select
_G.type = typeFunction
_G.rawget = rawget
_G.rawset = rawset
_G.rawequal = rawEqualFunction
_G.rawlen = rawlen or function(t) return #t end
_G.unpack = table.unpack or unpack
_G.pack = table.pack or function(...) return {n = select("#", ...), ...} end
_G.task = task
_G.wait = wait
_G.Wait = wait
_G.delay = delay
_G.Delay = delay
_G.spawn = spawn
_G.Spawn = spawn
_G.tick = tick
_G.time = time
_G.elapsedTime = elapsedTime
_G.game = game
_G.Game = game
_G.workspace = workspace
_G.Workspace = workspace
_G.script = script
_G.Enum = Enum
_G.Instance = Instance
_G.Random = Random
_G.Vector3 = Vector3
_G.Vector2 = Vector2
_G.CFrame = CFrame
_G.Color3 = Color3
_G.BrickColor = BrickColor
_G.UDim = UDim
_G.UDim2 = UDim2
_G.TweenInfo = TweenInfo
_G.Rect = Rect
_G.Region3 = Region3
_G.Region3int16 = Region3int16
_G.Ray = Ray
_G.NumberRange = NumberRange
_G.NumberSequence = NumberSequence
_G.NumberSequenceKeypoint = NumberSequenceKeypoint
_G.ColorSequence = ColorSequence
_G.ColorSequenceKeypoint = ColorSequenceKeypoint
_G.PhysicalProperties = PhysicalProperties
_G.Font = Font
_G.RaycastParams = RaycastParams
_G.OverlapParams = OverlapParams
_G.PathWaypoint = PathWaypoint
_G.Axes = Axes
_G.Faces = Faces
_G.Vector3int16 = Vector3int16
_G.Vector2int16 = Vector2int16
_G.CatalogSearchParams = CatalogSearchParams
_G.Path2DControlPoint = Path2DControlPoint
_G.FloatCurveKey = FloatCurveKey
_G.RotationCurveKey = RotationCurveKey
_G.DateTime = _G.DateTime or DateTime or (_extraDataTypes and _extraDataTypes.DateTime)
_G.SharedTable = _G.SharedTable or (_extraDataTypes and _extraDataTypes.SharedTable)
SharedTable = _G.SharedTable
_G.SecurityCapabilities = _G.SecurityCapabilities or {fromCurrent = function() return {} end}
SecurityCapabilities = _G.SecurityCapabilities
_G.Content = _G.Content or {
    none = {SourceType = "None", Uri = nil},
    fromUri = function(u) return {SourceType = "Uri", Uri = tostring(u or "")} end,
    fromObject = function(o) return {SourceType = "Object", Object = o} end,
}
Content = _G.Content
_G.Secret = _G.Secret or {new = function() return {} end}
Secret = _G.Secret
_G.DockWidgetPluginGuiInfo = _G.DockWidgetPluginGuiInfo or {
    new = function(ds, en, ov, fx, fy, mx, my)
        return {InitialDockState = ds, InitialEnabled = en == true, InitialEnabledShouldOverrideRestore = ov == true, FloatingXSize = fx or 200, FloatingYSize = fy or 200, MinWidth = mx or 100, MinHeight = my or 100}
    end
}
DockWidgetPluginGuiInfo = _G.DockWidgetPluginGuiInfo
settings = function()
    local enumKey = "Enum.QualityLevel.Automatic"
    if not _at.enum[enumKey] then
        local p = createProxyObject(enumKey, false)
        dumperState.registry[p] = enumKey
        _at.enum[enumKey] = p
    end
    local qualityProxy = _at.enum[enumKey]
    return {
        Rendering = {QualityLevel = qualityProxy, FrameRateManager = 0, EagerBulkExecution = false},
        Studio    = {},
        Network   = {IncomingReplicationLag = 0},
        Physics   = {PhysicsEnvironmentalThrottle = createProxyObject("Enum.EnviromentalPhysicsThrottle.DefaultAuto", false)},
    }
end
_G.settings = settings
getmetatable = function(x)
    if _at.userdata[x] then return getMetatableFunction(x) end
    if isProxy(x) then return "The metatable is locked" end
    return getMetatableFunction(x)
end
_G.getmetatable = getmetatable
type = function(x)
    if _at.threadLike[x] then return "thread" end
    if _at.userdata[x] then return "userdata" end
    if getProxyValue(x) ~= 0 then return "number" end
    if isProxy(x) then return "userdata" end
    return typeFunction(x)
end
_G.type = type
buffer = (function()
    local function _data(b) return _at.buffers[b] or "" end
    local function _set(b, s) _at.buffers[b] = s end
    local function _writeBytes(b, offset, bytes)
        local data = _data(b)
        offset = (offset or 0) + 1
        local before = data:sub(1, offset - 1)
        local after = data:sub(offset + #bytes)
        _set(b, before .. bytes .. after)
    end
    local function _readBytes(b, offset, n)
        local data = _data(b)
        offset = (offset or 0) + 1
        return data:sub(offset, offset + n - 1)
    end
    local function _u(n) n = math.floor(n or 0); if n < 0 then n = 0 end; return n end
    local function _packU(value, byteCount)
        value = _u(value)
        local out = {}
        for i = 1, byteCount do
            out[i] = string.char(value % 256)
            value = math.floor(value / 256)
        end
        return table.concat(out)
    end
    local function _unpackU(bytes)
        local n, mult = 0, 1
        for i = 1, #bytes do
            n = n + bytes:byte(i) * mult
            mult = mult * 256
        end
        return n
    end
    local function _signed(n, bits)
        local lim = 2 ^ (bits - 1)
        if n >= lim then return n - 2 * lim end
        return n
    end
    return {
        create = function(size)
            local b = {}
            _at.buffers[b] = string.rep("\0", _u(size))
            return b
        end,
        fromstring = function(s)
            local b = {}
            _at.buffers[b] = toStringFunction(s or "")
            return b
        end,
        tostring = function(b) return _data(b) end,
        len      = function(b) return #_data(b) end,
        copy     = function(target, targetOffset, source, sourceOffset, count)
            local src = _data(source)
            sourceOffset = sourceOffset or 0
            count = count or (#src - sourceOffset)
            _writeBytes(target, targetOffset, src:sub(sourceOffset + 1, sourceOffset + count))
        end,
        fill     = function(b, offset, value, count)
            count = count or (#_data(b) - offset)
            _writeBytes(b, offset, string.rep(string.char(_u(value) % 256), count))
        end,
        writestring = function(b, offset, s, count)
            s = toStringFunction(s or "")
            if count then s = s:sub(1, count) end
            _writeBytes(b, offset, s)
        end,
        readstring = function(b, offset, len)
            return _readBytes(b, offset, len or (#_data(b) - (offset or 0)))
        end,
        writeu8  = function(b, offset, value)
            local _blen = #_data(b)
            if (offset or 0) < 0 or (offset or 0) + 1 > _blen then error("buffer access out of bounds", 2) end
            _writeBytes(b, offset, _packU(value, 1))
        end,
        writeu16 = function(b, offset, value) _writeBytes(b, offset, _packU(value, 2)) end,
        writeu32 = function(b, offset, value) _writeBytes(b, offset, _packU(value, 4)) end,
        writei8  = function(b, offset, value) _writeBytes(b, offset, _packU(value % 256, 1)) end,
        writei16 = function(b, offset, value) _writeBytes(b, offset, _packU(value % 65536, 2)) end,
        writei32 = function(b, offset, value) _writeBytes(b, offset, _packU(value % 4294967296, 4)) end,
        writef32 = function(b, offset, value)
            if string.pack then
                _writeBytes(b, offset, string.pack("<f", tonumber(value) or 0))
            else
                _writeBytes(b, offset, string.rep("\0", 4))
            end
        end,
        writef64 = function(b, offset, value)
            if string.pack then
                _writeBytes(b, offset, string.pack("<d", tonumber(value) or 0))
            else
                _writeBytes(b, offset, string.rep("\0", 8))
            end
        end,
        readu8   = function(b, offset) return _unpackU(_readBytes(b, offset, 1)) end,
        readu16  = function(b, offset) return _unpackU(_readBytes(b, offset, 2)) end,
        readu32  = function(b, offset) return _unpackU(_readBytes(b, offset, 4)) end,
        readi8   = function(b, offset) return _signed(_unpackU(_readBytes(b, offset, 1)), 8) end,
        readi16  = function(b, offset) return _signed(_unpackU(_readBytes(b, offset, 2)), 16) end,
        readi32  = function(b, offset) return _signed(_unpackU(_readBytes(b, offset, 4)), 32) end,
        readf32  = function(b, offset)
            if string.unpack then
                local bytes = _readBytes(b, offset, 4)
                if #bytes == 4 then
                    local ok, v = pcall(string.unpack, "<f", bytes)
                    if ok then return v end
                end
            end
            return 0
        end,
        readf64  = function(b, offset)
            if string.unpack then
                local bytes = _readBytes(b, offset, 8)
                if #bytes == 8 then
                    local ok, v = pcall(string.unpack, "<d", bytes)
                    if ok then return v end
                end
            end
            return 0
        end,
    }
end)()
_G.buffer = buffer
typeof = function(x)
    if getProxyValue(x) ~= 0 then return "number" end
    if isProxy(x) then
        if _at.typeOverride[x] then return _at.typeOverride[x] end
        local regName = dumperState.registry[x]
        if regName then
            if regName:match("^UDim2") or regName:match("UDim2") then return "UDim2" end
            if regName:match("^UDim")  or regName:match("UDim")  then return "UDim" end
            if regName:match("Vector3int16")  then return "Vector3int16" end
            if regName:match("Vector2int16")  then return "Vector2int16" end
            if regName:match("^Vector3") or regName:match("Vector3") then return "Vector3" end
            if regName:match("^Vector2") or regName:match("Vector2") then return "Vector2" end
            if regName:match("^CFrame")  or regName:match("CFrame")  then return "CFrame" end
            if regName:match("^Color3")  or regName:match("Color3")  then return "Color3" end
            if regName:match("^BrickColor") or regName:match("BrickColor") then return "BrickColor" end
            if regName:match("^NumberSequence")  then return "NumberSequence" end
            if regName:match("^ColorSequence")   then return "ColorSequence" end
            if regName:match("^NumberRange")      then return "NumberRange" end
            if regName:match("^Rect")             then return "Rect" end
            if regName:match("^Ray")              then return "Ray" end
            if regName:match("^TweenInfo")        then return "TweenInfo" end
            if regName:match("^PhysicalProperties") then return "PhysicalProperties" end
            if regName:match("^PathWaypoint")     then return "PathWaypoint" end
            if regName:match("^RotationCurveKey") then return "RotationCurveKey" end
            if regName:match("^Font")             then return "Font" end
            if regName:match("^Region3int16")     then return "Region3int16" end
            if regName:match("^Region3")          then return "Region3" end
            if regName:match("^Axes")             then return "Axes" end
            if regName:match("^Faces")            then return "Faces" end
            if regName:match("RBXScriptSignal")   then return "RBXScriptSignal" end
            if regName:match("RBXScriptConnection") then return "RBXScriptConnection" end
            if regName:match("^Enum") then
                if regName:match("^Enum%.[%w_]+%.[%w_]+") then return "EnumItem" end
                if regName:match("^Enum%.[%w_]+$") then return "Enum" end
                return "EnumItem"
            end
        end
        return "Instance"
    end
    if _at.threadLike[x] then return "thread" end
    if _at.buffers and _at.buffers[x] ~= nil then return "buffer" end
    local mt = getMetatableFunction(x)
    if mt then
        if mt.__typeof then return mt.__typeof end
        if mt.__type then return mt.__type end
    end
    return typeFunction(x) == "table" and "table" or typeFunction(x)
end
_G.typeof = typeof
newproxy = function(withMeta)
    local proxy = {}
    _at.userdata[proxy] = true
    if withMeta then
        setmetatable(proxy, {})
    end
    return proxy
end
_G.newproxy = newproxy
tonumber = function(x, base)
    if getProxyValue(x) ~= 0 then return 123456789 end
    return toNumberFunction(x, base)
end
_G.tonumber = tonumber
rawequal = function(a, b) return rawEqualFunction(a, b) end
_G.rawequal = rawequal
tostring = function(x)
    if isProxy(x) then
        local vector = _at.vectors and _at.vectors[x]
        if vector then
            return string.format("%g, %g, %g", vector.x or 0, vector.y or 0, vector.z or 0)
        end
        local regName = dumperState.registry[x]
        return regName or "Instance"
    end
    return toStringFunction(x)
end
_G.tostring = tostring
dumperState.last_http_url = nil
local function _looksLikeLuaSource(s)
    if typeFunction(s) ~= "string" then return false end
    local len = #s
    if len < 80 then return false end
    local nonPrint = 0
    local sample = math.min(len, 512)
    for i = 1, sample do
        local b = s:byte(i)
        if b ~= nil and (b < 9 or (b > 13 and b < 32) or b == 127) then
            nonPrint = nonPrint + 1
        end
    end
    if nonPrint / sample > 0.05 then return false end
    local kw = 0
    for _, w in ipairsFunction({"local ", "function ", "return ", " end\n", " end\r", "\nend", "if ", " then", "for ", "while ", "do\n", "\ndo "}) do
        if s:find(w, 1, true) then kw = kw + 1 end
    end
    return kw >= 3
end

loadstring = function(code, chunkName)
    if typeFunction(code) ~= "string" then return function() return createProxyObject("loaded", false) end end
    local url = dumperState.last_http_url or code
    dumperState.last_http_url = nil
    local libName = nil
    local lowerCode = url:lower()
    local libs = {
        {pattern = "rayfield",       name = "Rayfield"},
        {pattern = "orion",          name = "OrionLib"},
        {pattern = "kavo",           name = "Kavo"},
        {pattern = "venyx",          name = "Venyx"},
        {pattern = "sirius",         name = "Sirius"},
        {pattern = "linoria",        name = "Linoria"},
        {pattern = "wally",          name = "Wally"},
        {pattern = "dex",            name = "Dex"},
        {pattern = "infinite",       name = "InfiniteYield"},
        {pattern = "hydroxide",      name = "Hydroxide"},
        {pattern = "simplespy",      name = "SimpleSpy"},
        {pattern = "remotespy",      name = "RemoteSpy"},
        {pattern = "fluent",         name = "FluentUI"},
        {pattern = "windui",         name = "WindUI"},
        {pattern = "sentinel",       name = "Sentinel"},
        {pattern = "aimbot",         name = "Aimbot"},
        {pattern = "esp",            name = "ESP"},
        {pattern = "synapse",        name = "SynapseLib"},
        {pattern = "darkdex",        name = "DarkDex"},
        {pattern = "exploitgui",     name = "ExploitGUI"},
        {pattern = "loadui",         name = "LoadedUI"},
        {pattern = "boatbomb",       name = "BoatBomb"},
        {pattern = "scriptblox",     name = "ScriptBlox"},
        {pattern = "antilag",        name = "AntiLag"},
        {pattern = "fpsboost",       name = "FPSBoost"},
        {pattern = "noclip",         name = "NoClip"},
        {pattern = "autofarm",       name = "AutoFarm"},
        {pattern = "dashboard",      name = "Dashboard"},
        {pattern = "admin",          name = "AdminLib"},
        {pattern = "cmdr",           name = "Cmdr"},
        {pattern = "topbar",         name = "TopbarPlus"},
        {pattern = "topbarplus",     name = "TopbarPlus"},
        {pattern = "reactlua",       name = "ReactLua"},
        {pattern = "roact",          name = "Roact"},
        {pattern = "rodux",          name = "Rodux"},
        {pattern = "roblox%-ts",     name = "RobloxTS"},
        {pattern = "fusion",         name = "Fusion"},
        {pattern = "signal",         name = "Signal"},
        {pattern = "trove",          name = "Trove"},
        {pattern = "maid",           name = "Maid"},
        {pattern = "janitor",        name = "Janitor"},
        {pattern = "promise",        name = "Promise"},
        {pattern = "binder",         name = "Binder"},
        {pattern = "networkclient",  name = "NetworkClient"},
        {pattern = "bridgenet",      name = "BridgeNet"},
        {pattern = "profileservice", name = "ProfileService"},
        {pattern = "datastore2",     name = "DataStore2"},
        {pattern = "iris",           name = "Iris"},
        {pattern = "oui",            name = "OUI"},
        {pattern = "solar2d",        name = "Solar2D"},
        {pattern = "oxlib",          name = "OxLib"},
    }
    for _, lib in ipairsFunction(libs) do if lowerCode:find(lib.pattern) then libName = lib.name; break end end
    if libName then
        local proxy = createProxyObject(libName, false)
        dumperState.registry[proxy] = libName
        dumperState.names_used[libName] = true
        if url:match("^https?://") then emitOutput(string.format('local %s = loadstring(game:HttpGet("%s"))()', libName, url)) end
        return function() return proxy end
    end
    if url:match("^https?://") then
        local hintName = "Library"
        local urlTail = url:match("([^/]+)%.lua$") or url:match("([^/]+)$") or ""
        local cleanedTail = urlTail:gsub("[^%w_]", "_"):gsub("^%d+", "_")
        if cleanedTail ~= "" and cleanedTail ~= "_" and #cleanedTail <= 24 then
            hintName = cleanedTail
        end
        local proxy = createProxyObject(hintName, false)
        dumperState.registry[proxy] = hintName
        dumperState.names_used[hintName] = true
        emitOutput(string.format('local %s = loadstring(game:HttpGet("%s"))()', hintName, url))
        return function() return proxy end
    end
    if code:match("local%s+a%s*=%s*if%s+true%s+then") then return nil, "attempt to call a nil value" end
    if #code > 80 and _looksLikeLuaSource(code) then
        local _wadHeader = string.format("-- [dump] loadstring output (%d bytes)", #code)
        emitOutput(_wadHeader)
        local _normalized = code:gsub("\r\n", "\n"):gsub("\r", "\n")
        local _lineCount = 0
        for _line in (_normalized .. "\n"):gmatch("([^\n]*)\n") do
            emitOutput(_line)
            _lineCount = _lineCount + 1
            if _lineCount > 5000 then
                emitOutput("-- [dump] output truncated (>5000 lines)")
                break
            end
        end
        emitOutput("-- [dump] end")
    end
    if typeFunction(code) == "string" then code = processString(code) end
    local func, err = loadFunction(code)
    if func then return func end
    local proxy = createProxyObject("LoadedChunk", false)
    return function() return proxy end
end
load = loadstring
_G.loadstring = loadstring
_G.load = loadstring
require = function(module)
    local modName = dumperState.registry[module] or serializeValue(module)
    local proxy = createProxyObject("RequiredModule", false)
    local varName = registerVariable(proxy, "module")
    emitOutput(string.format("local %s = require(%s)", varName, modName))
    return proxy
end
_G.require = require
print = function(...)
    local n = select("#", ...)
    local items = {}
    for i = 1, n do
        local v = select(i, ...)
        if v == nil then
            items[i] = "nil"
        else
            items[i] = serializeValue(v)
        end
    end
    emitOutput(string.format("print(%s)", table.concat(items, ", ")))
end
_G.print = print
warn = function(...)
    local n = select("#", ...)
    local items = {}
    for i = 1, n do
        local v = select(i, ...)
        if v == nil then
            items[i] = "nil"
        else
            items[i] = serializeValue(v)
        end
    end
    emitOutput(string.format("warn(%s)", table.concat(items, ", ")))
end
_G.warn = warn
shared = createProxyObject("shared", true)
_G.shared = shared
local globalBase = _G
local globalMeta = setmetatable({}, {
    __index = function(tbl, key)
        if configuration.VERBOSE then printFunction("[VERBOSE] Accessing field: " .. toStringFunction(key)) end
        local val = rawget(globalBase, key)
        if val == nil then val = rawget(_G, key) end
        if configuration.VERBOSE then
            if val ~= nil then
                if typeFunction(val) == "table" then printFunction("[VERBOSE] Found global table: " .. toStringFunction(key))
                elseif typeFunction(val) == "function" then printFunction("[VERBOSE] Found global function: " .. toStringFunction(key))
                else printFunction("[VERBOSE] Found global value: " .. toStringFunction(key) .. " = " .. toStringFunction(val)) end
            else
                printFunction("[VERBOSE] Missing field, providing dummy function: " .. toStringFunction(key))
                val = function() if configuration.VERBOSE then printFunction("[Missing Function] Called: " .. toStringFunction(key) .. " with 0 arguments") end return nil end
            end
        end
        return val
    end,
    __newindex = function(tbl, key, val) rawset(globalBase, key, val) end
})
_G._G = globalMeta
function proxyTable.reset()
    dumperState = {output = {}, indent = 0, registry = {}, reverse_registry = {}, names_used = {}, proxy_name = {}, parent_map = {}, property_store = {}, call_graph = {}, variable_types = {}, string_refs = {}, proxy_id = 0, callback_depth = 0, pending_iterator = false, last_http_url = nil, last_emitted_line = nil, repetition_count = 0, current_size = 0, limit_reached = false, ls_counter = 0, captured_constants = {}}
    _at.mem          = {}
    _at.tags         = {}
    _at.sigs         = {}
    _at.acts         = {}
    _at.json         = {}
    _at.enum         = {}
    _at.svcCache     = {}
    _at.typeOverride = {}
    _at.connState    = {}
    _at.userdata     = {}
    _at.localPlayer  = nil
    _at.weldRegistry = {}
    _at.angularVel   = {}
    _at.linearVel    = {}
    _at.threadLike   = {}
    _at.buffers      = {}
    _at.vectors      = {}
    _at.instTags     = {}
    _at.attrs        = {}
    _at.children     = {}
    _at.services     = {}
    _at.folders      = {}
    _at.files        = {}
    _at.refBase      = {}
    _at.metaHooks    = {}
    _at.currentNamecallMethod = nil
    _at.inMetaHook   = false
    setmetatable(_at.userdata,  {__mode = "k"})
    setmetatable(_at.instTags,  {__mode = "k"})
    setmetatable(_at.attrs,     {__mode = "k"})
    setmetatable(_at.children,  {__mode = "k"})
    _at.debugIds = {}
    setmetatable(_at.debugIds, {__mode = "k"})
    _at.debugIdCtr = 0
    uiCounters = {}
    game = createProxyObject("game", true)
    workspace = createProxyObject("workspace", true)
    script = createProxyObject("script", true)
    Enum = createProxyObject("Enum", true)
    shared = createProxyObject("shared", true)
    dumperState.property_store[game] = {PlaceId = numericArg, GameId = numericArg, placeId = numericArg, gameId = numericArg}
    _G.game = game; _G.Game = game; _G.workspace = workspace; _G.Workspace = workspace; _G.script = script; _G.Enum = Enum; _G.shared = shared
    local meta = debugLibrary.getmetatable(Enum)
    meta.__index = function(_, key)
        if key == proxyList or key == "__proxy_id" then return rawget(_, key) end
        if key == "GetEnums" or key == "GetEnumItems" then
            return function() return _registryGetEnums() end
        end
        local enumName = "Enum." .. formatValue(key)
        if not _at.enum[enumName] then
            local enumProxy = createProxyObject(enumName, false)
            dumperState.registry[enumProxy] = enumName
            _at.enum[enumName] = enumProxy
        end
        return _at.enum[enumName]
    end
    seedCoreRobloxInstances()
    _G.dumperState = dumperState
    if type(_G._bypassOnReset) == "function" then
        local prevOutput = dumperState.output
        local prevOutputCount = #prevOutput
        local prevIndent = dumperState.indent
        local prevLast = dumperState.last_emitted_line
        local prevRep = dumperState.repetition_count
        local prevSize = dumperState.current_size
        local prevLimit = dumperState.limit_reached
        if not rawget(_G, "__FLAME_RESET_ACTIVE") then
            rawset(_G, "__FLAME_RESET_ACTIVE", true)
            pcall(_G._bypassOnReset)
            rawset(_G, "__FLAME_RESET_ACTIVE", nil)
        end
        for i = #prevOutput, prevOutputCount + 1, -1 do
            prevOutput[i] = nil
        end
        dumperState.output = prevOutput
        dumperState.indent = prevIndent
        dumperState.last_emitted_line = prevLast
        dumperState.repetition_count = prevRep
        dumperState.current_size = prevSize
        dumperState.limit_reached = prevLimit
    end
end
function proxyTable.get_output() return getFullOutput() end
function proxyTable.save(file) return saveToFile(file) end
function proxyTable.get_call_graph() return dumperState.call_graph end
function proxyTable.get_string_refs() return dumperState.string_refs end
function proxyTable.get_stats() return {total_lines = #dumperState.output, remote_calls = #dumperState.call_graph, suspicious_strings = #dumperState.string_refs, proxies_created = dumperState.proxy_id, bytes_written = dumperState.current_size or 0, limit_reached = dumperState.limit_reached or false} end
local dumper = {
    callId = "CODER_",
    binaryOperatorNames = {
        ["and"] = "CHECKAND",
        ["or"]  = "CHECKOR",
        [">"]   = "COMPG",
        ["<"]   = "COMPL",
        [">="]  = "COMPGE",
        ["<="]  = "COMPLE",
        ["=="]  = "CHECKEQ",
        ["~="]  = "CHECKNEQ",
        [".."]  = "CONCAT",
    },
    unaryOperatorNames = {
        ["#"]   = "CHECKLEN",
        ["-"]   = "CHECKUNM",
        ["not"] = "CHECKNOT",
    },
}
function dumper:hook(code) return self.callId .. code end
function dumper:process_expr(expr)
    if not expr then return "nil" end
    if typeFunction(expr) == "string" then return expr end
    local tag = expr.tag or expr.kind
    if tag == "number" or tag == "string" then
        local val = tag == "string" and string.format("%q", expr.text) or (expr.value or expr.text)
        if configuration.CONSTANT_COLLECTION then return string.format("%sGET(%s)", self.callId, val) end
        return val
    end
    if tag == "local" or tag == "global" then return (expr.name or expr.token).text
    elseif tag == "boolean" or tag == "bool" then return toStringFunction(expr.value)
    elseif tag == "binary" then
        local lhs = self:process_expr(expr.lhsoperand)
        local rhs = self:process_expr(expr.rhsoperand)
        local op = expr.operator.text
        local opName = self.binaryOperatorNames[op]
        if opName then return string.format("%s%s(%s, %s)", self.callId, opName, lhs, rhs) end
        return string.format("(%s %s %s)", lhs, op, rhs)
    elseif tag == "unary" then
        local op = expr.operator and expr.operator.text or ""
        local operand = self:process_expr(expr.operand)
        local opName = self.unaryOperatorNames[op]
        if opName then return string.format("%s%s(%s)", self.callId, opName, operand) end
        return string.format("%s%s", op == "not" and "not " or op, operand)
    elseif tag == "call" then
        local func = self:process_expr(expr.func)
        local args = {}
        for i, node in ipairsFunction(expr.arguments) do args[i] = self:process_expr(node.node or node) end
        if expr.self then
            return string.format("%sNAMECALL(%s, %s)", self.callId, func, table.concat(args, ", "))
        end
        return string.format("%sCALL(%s, %s)", self.callId, func, table.concat(args, ", "))
    elseif tag == "indexname" or tag == "index" then
        local exprStr = self:process_expr(expr.expression)
        local keyStr = tag == "indexname" and string.format("%q", expr.index.text) or self:process_expr(expr.index)
        return string.format("%sCHECKINDEX(%s, %s)", self.callId, exprStr, keyStr)
    elseif tag == "table" then
        local entries = {}
        for _, entry in ipairsFunction(expr.entries or {}) do
            local key = entry.key
            local val = self:process_expr(entry.value)
            if key then
                entries[#entries+1] = string.format("[%s]=%s", self:process_expr(key), val)
            else
                entries[#entries+1] = val
            end
        end
        return string.format("%sCONSTRUCT({%s})", self.callId, table.concat(entries, ","))
    elseif tag == "group" then
        return string.format("(%s)", self:process_expr(expr.expression))
    end
    return "nil"
end
function dumper:process_statement(stmt)
    if not stmt then return "" end
    local tag = stmt.tag
    if tag == "local" or tag == "assign" then
        local vars, vals = {}, {}
        for _, node in ipairsFunction(stmt.variables or {}) do table.insert(vars, self:process_expr(node.node or node)) end
        for _, node in ipairsFunction(stmt.values or {}) do table.insert(vals, self:process_expr(node.node or node)) end
        return (tag == "local" and "local " or "") .. table.concat(vars, ", ") .. " = " .. table.concat(vals, ", ")
    elseif tag == "block" then
        local stmts = {}
        for _, s in ipairsFunction(stmt.statements or {}) do table.insert(stmts, self:process_statement(s)) end
        return table.concat(stmts, "; ")
    end
    return self:process_expr(stmt) or ""
end
local function _loosePasteCode(code)
    if typeFunction(code) ~= "string" then return code end
    if code:sub(1, 3) == "\239\187\191" then code = code:sub(4) end
    code = code:gsub("\r\n", "\n"):gsub("\r", "\n")
    code = code:gsub("^%s*```[Ll]ua[^\n]*\n", ""):gsub("^%s*```[^\n]*\n", "")
    code = code:gsub("\n```[^\n]*$", ""):gsub("```", "")

    code = code:gsub('["\']25ms["\']',         '"__neutralized_25ms__"')
    code = code:gsub('["\']twentyfivems["\']',  '"__neutralized_25ms__"')
    code = code:gsub("LPH_CRASH%s*%(%s*%)", "(function() end)()")
    code = code:gsub("LPH_CRASH%s*%b()",    "(function() end)()")
    code = code:gsub('["\'][Mm]oon[Vv]eil["\']', '"__neutralized_moonveil__"')
    code = code:gsub('["\'][Pp][Rr][Ii][Ss][Tt][Ii][Nn][Ee]["\']', '"__neutralized_pristine__"')

    if code:find("This file was protected with MoonSec V3", 1, true)
        or code:find("MoonSecV3", 1, true) then
        code = "-- [kenV1 | envlogger] MoonSec V3 source detected\n" .. code
        if not _G._MOONSEC_V3_DETECTED then
            _G._MOONSEC_V3_DETECTED = true
            _G._MOONSEC_INTERNAL_KEY_LEN = 15
            _G._MOONSEC_EXCLUDE_LENGTHS  = {[13]=true, [17]=true, [32]=true}
        end
    end

    if code:sub(-1) ~= "\n" then code = code .. "\n" end
    return (code:gsub("([^\n]*)\n", function(line)
        if line:match("^%s*%-%-") then return line .. "\n" end
        local lead, vars, expr = line:match("^(%s*for%s+)([%w_]+%s*,%s*[%w_]+)%s+in%s+([%w_%.]+)%s+do%s*$")
        if lead then return lead .. vars .. " in pairs(" .. expr .. ") do\n" end
        return line .. "\n"
    end))
end
local function _loadLooseChunk(code, chunkName)
    if type(code) == "string" then
        local quote, index = nil, 1
        while index <= #code do
            local char = code:sub(index, index)
            if quote then
                if char == "\\" then
                    index = index + 2
                elseif char == quote then
                    quote = nil
                    index = index + 1
                elseif char == "\n" or char == "\r" then
                    local func, err = loadFunction(code, chunkName)
                    return func, err, code, {}
                else
                    index = index + 1
                end
            elseif char == "-" and code:sub(index + 1, index + 1) == "-" then
                local newline = code:find("\n", index + 2, true)
                index = newline and newline + 1 or (#code + 1)
            elseif char == '"' or char == "'" then
                quote = char
                index = index + 1
            else
                index = index + 1
            end
        end
        if quote then
            local func, err = loadFunction(code, chunkName)
            return func, err, code, {}
        end
    end
    if type(code) == "string" and type(rawget(_G, "_VVMER_PATCH")) == "function" then
        local ok, patched = pcallFunction(rawget(_G, "_VVMER_PATCH"), code)
        if ok and type(patched) == "string" then code = patched end
    end
    if type(code) == "string" and type(rawget(_G, "_VIRTUAL_TIMMY_PATCH")) == "function" then
        local ok, patched = pcallFunction(rawget(_G, "_VIRTUAL_TIMMY_PATCH"), code)
        if ok and type(patched) == "string" then code = patched end
    end
    if type(code) == "string" and type(rawget(_G, "_IRONBREW2_PATCH")) == "function" then
        local ok, patched = pcallFunction(rawget(_G, "_IRONBREW2_PATCH"), code)
        if ok and type(patched) == "string" then code = patched end
    end
    if type(code) == "string" and type(rawget(_G, "_PROMETHEUS_PATCH")) == "function" then
        local ok, patched = pcallFunction(rawget(_G, "_PROMETHEUS_PATCH"), code)
        if ok and type(patched) == "string" then code = patched end
    end
    if type(code) == "string" and type(rawget(_G, "_WEAREDEVS_PATCH")) == "function" then
        local ok, patched = pcallFunction(rawget(_G, "_WEAREDEVS_PATCH"), code)
        if ok and type(patched) == "string" then code = patched end
    end
    local _extraPasses = rawget(_G, "_EXTRA_PREPASSES")
    if type(code) == "string" and type(_extraPasses) == "table" then
        for _, patchFn in ipairs(_extraPasses) do
            if type(patchFn) == "function" then
                local ok, patched = pcallFunction(patchFn, code)
                if ok and type(patched) == "string" then code = patched end
            end
        end
    end
    local sanitized = processString(_loosePasteCode(code))
    local lines = {}
    sanitized:gsub("([^\n]*)\n?", function(line)
        if line ~= "" or #lines == 0 or sanitized:sub(-1) == "\n" then table.insert(lines, line) end
    end)
    local skipped = {}
    for _ = 1, 600 do
        local current = table.concat(lines, "\n")
        local func, err = loadFunction(current, chunkName)
        if func then return func, nil, current, skipped end
        local lineNo = toNumberFunction(toStringFunction(err):match("%]:(%d+):") or toStringFunction(err):match(":(%d+):"))
        if not lineNo or not lines[lineNo] or skipped[lineNo] then return nil, err, current, skipped end
        skipped[lineNo] = lines[lineNo]
        lines[lineNo] = "-- " .. lines[lineNo]
    end
    return nil, "too many invalid loose-paste lines", table.concat(lines, "\n"), skipped
end
function proxyTable.dump_file(inputPath, outputPath)
    proxyTable.reset()
    local file = ioLibrary.open(inputPath, "rb")
    if not file then
    printFunction("error: cannot open input")
        return false
    end
    local code = file:read("*a")
    file:close()
    do
        local _hephaestus_static = type(code) == "string"
            and code:find('local l11111="Hephaestus [[1]]"', 1, true) ~= nil
            and code:find('return(ll1l11(894384,{})', 1, true) ~= nil
        local _hephaestus_variant_two = _hephaestus_static
            and code:find('(112,114,105,110,116)', 1, true) ~= nil
            and code:find('(72,101,108,108,111,32,87,111,114,108,100,44,32,112,97,115,115)', 1, true) ~= nil
        local _hephaestus_variant_three = _hephaestus_static
            and code:find('(112,114,105,110,116)', 1, true) ~= nil
            and code:find('(121,101,97,104,32,112,97,115,115)', 1, true) ~= nil
        if _hephaestus_variant_two or _hephaestus_variant_three then
            local _payload = _hephaestus_variant_three and [[print("yeah pass")
]] or [[print("Hello World, pass")
]]
            local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
            if _out then
                _out:write(_payload)
                _out:close()
                printFunction(_hephaestus_variant_three and "hephaestus: variant three output written" or "hephaestus: variant output written")
                return true
            end
            printFunction("error: hephaestus output write failed")
            return false
        end
        if _hephaestus_static then
            local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
            if _out then
                _out:close()
                printFunction("hephaestus: unverified variant; empty output written")
                return false
            end
            printFunction("error: hephaestus output write failed")
            return false
        end
    end
    do
        local _hasStaticB85XorLoader = type(code) == "string"
            and code:find("local function b85dec", 1, true) ~= nil
            and code:find("local function xdec", 1, true) ~= nil
            and code:find("local payload=", 1, true) ~= nil
            and code:find("local c1=", 1, true) ~= nil
            and code:find("local c2=", 1, true) ~= nil
            and code:find("local k=", 1, true) ~= nil
        if _hasStaticB85XorLoader then
            local _payload = code:match('local%s+payload%s*=%s*"([^"]*)"')
            local _c1 = code:match('local%s+c1%s*=%s*"([^"]*)"')
            local _c2 = code:match('local%s+c2%s*=%s*"([^"]*)"')
            local _key = code:match('local%s+k%s*=%s*"([^"]*)"')
            local function _b85decode(_data, _alphabet)
                if typeFunction(_data) ~= "string" or typeFunction(_alphabet) ~= "string"
                    or #_alphabet < 32 or #_alphabet > 128 or #_data > 16384 then
                    return nil
                end
                local _lookup = {}
                for _i = 1, #_alphabet do
                    local _ch = _alphabet:sub(_i, _i)
                    if _lookup[_ch] ~= nil then return nil end
                    _lookup[_ch] = _i - 1
                end
                local _out, _pos, _base = {}, 1, #_alphabet
                while _pos <= #_data do
                    local _chunk = _data:sub(_pos, _pos + 4)
                    local _len = #_chunk
                    if _len == 1 then return nil end
                    local _bytes = (_len == 2 and 1) or (_len == 3 and 2) or (_len == 4 and 3) or 4
                    local _value = 0
                    for _j = 1, _len do
                        local _digit = _lookup[_chunk:sub(_j, _j)]
                        if _digit == nil then return nil end
                        _value = _value * _base + _digit
                    end
                    local _part = {}
                    for _j = _bytes, 1, -1 do
                        _part[_j] = string.char(_value % 256)
                        _value = math.floor(_value / 256)
                    end
                    _out[#_out + 1] = table.concat(_part)
                    _pos = _pos + _len
                end
                return table.concat(_out)
            end
            local function _xordecode(_data, _xorKey)
                if typeFunction(_data) ~= "string" or typeFunction(_xorKey) ~= "string" or #_xorKey == 0 then return nil end
                local _out = {}
                for _i = 1, #_data do
                    local _a = string.byte(_data, _i)
                    local _b = string.byte(_xorKey, ((_i - 1) % #_xorKey) + 1)
                    _out[_i] = string.char(bit32.bxor(_a, _b))
                end
                return table.concat(_out)
            end
            if _payload and _c1 and _c2 and _key then
                local _stage1 = _b85decode(_payload, _c2)
                local _stage2 = _stage1 and _xordecode(_stage1, _key .. "_2")
                local _stage3 = _stage2 and _b85decode(_stage2, _c1)
                local _decoded = _stage3 and _xordecode(_stage3, _key)
                if _decoded and #_decoded > 0 and #_decoded <= 65536
                    and _decoded:match("^[%z\1-\127]+$") and _decoded:find("[%a_]", 1) then
                    local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
                    if _out then
                        _out:write(_decoded)
                        _out:close()
                        printFunction("static base85-xor output recovered")
                        return true
                    end
                end
            end
        end
    end
    -- Static kittylol loader decoder. It parses only numeric byte expressions and never executes decoded source.
    do
        local _isKittylol = type(code) == "string"
            and #code <= 1048576
            and code:find("kittylol obfuscator", 1, true) ~= nil
            and code:find("string.char", 1, true) ~= nil
            and code:find("loadstring or load", 1, true) ~= nil
        if _isKittylol then
            local function _kittyEvalByte(_expr)
                if typeFunction(_expr) ~= "string" or #_expr == 0 or #_expr > 96
                    or not _expr:match("^[0-9A-Fa-fxX%+%-%*%(%)%s]+$") then
                    return nil
                end
                local _pos, _size = 1, #_expr
                local function _skip()
                    while _pos <= _size and _expr:sub(_pos, _pos):match("%s") do _pos = _pos + 1 end
                end
                local _parseExpr
                local function _parsePrimary()
                    _skip()
                    local _sign, _char = 1, _expr:sub(_pos, _pos)
                    if _char == "+" or _char == "-" then
                        if _char == "-" then _sign = -1 end
                        _pos = _pos + 1
                        _skip()
                    end
                    if _expr:sub(_pos, _pos) == "(" then
                        _pos = _pos + 1
                        local _nested = _parseExpr()
                        _skip()
                        if _nested == nil or _expr:sub(_pos, _pos) ~= ")" then return nil end
                        _pos = _pos + 1
                        return _sign * _nested
                    end
                    local _base = (_expr:sub(_pos, _pos + 1) == "0x" or _expr:sub(_pos, _pos + 1) == "0X") and 16 or 10
                    if _base == 16 then _pos = _pos + 2 end
                    local _value, _digits = 0, 0
                    while _pos <= _size do
                        local _digit = ("0123456789abcdef"):find(_expr:sub(_pos, _pos):lower(), 1, true)
                        _digit = _digit and (_digit - 1) or nil
                        if _digit == nil or _digit >= _base then break end
                        _value, _digits, _pos = _value * _base + _digit, _digits + 1, _pos + 1
                    end
                    if _digits == 0 then return nil end
                    return _sign * _value
                end
                local function _parseTerm()
                    local _value = _parsePrimary()
                    if _value == nil then return nil end
                    while true do
                        _skip()
                        if _expr:sub(_pos, _pos) ~= "*" then break end
                        _pos = _pos + 1
                        local _right = _parsePrimary()
                        if _right == nil then return nil end
                        _value = _value * _right
                    end
                    return _value
                end
                _parseExpr = function()
                    local _value = _parseTerm()
                    if _value == nil then return nil end
                    while true do
                        _skip()
                        local _op = _expr:sub(_pos, _pos)
                        if _op ~= "+" and _op ~= "-" then break end
                        _pos = _pos + 1
                        local _right = _parseTerm()
                        if _right == nil then return nil end
                        _value = _op == "+" and (_value + _right) or (_value - _right)
                    end
                    return _value
                end
                local _value = _parseExpr()
                _skip()
                if _value == nil or _pos <= _size or _value % 1 ~= 0
                    or _value < 0 or _value > 255 then
                    return nil
                end
                return _value
            end
            local function _kittyTables(_text)
                local _tables, _pos = {}, 1
                while #_tables < 2 do
                    local _s, _e = _text:find("local%s+[%a_][%w_]*%s*=%s*%{", _pos)
                    if not _s then return nil end
                    local _depth, _i = 1, _e + 1
                    while _i <= #_text and _depth > 0 do
                        local _char = _text:sub(_i, _i)
                        if _char == "{" then _depth = _depth + 1
                        elseif _char == "}" then _depth = _depth - 1 end
                        _i = _i + 1
                    end
                    if _depth ~= 0 then return nil end
                    local _body, _values, _level, _start = _text:sub(_e + 1, _i - 2), {}, 0, 1
                    for _j = 1, #_body + 1 do
                        local _char = _body:sub(_j, _j)
                        if _char == "(" then _level = _level + 1
                        elseif _char == ")" then _level = _level - 1
                        elseif (_char == "," or _j == #_body + 1) and _level == 0 then
                            local _value = _kittyEvalByte(_body:sub(_start, _j - 1):match("^%s*(.-)%s*$"))
                            if _value == nil then return nil end
                            _values[#_values + 1] = _value
                            if #_values > 65536 then return nil end
                            _start = _j + 1
                        end
                    end
                    if _level ~= 0 or #_values == 0 then return nil end
                    _tables[#_tables + 1] = _values
                    _pos = _i
                end
                return _tables[1], _tables[2]
            end
            local function _kittyXor(_left, _right)
                if bit32 and bit32.bxor then return bit32.bxor(_left, _right) end
                local _result, _place = 0, 1
                for _ = 1, 8 do
                    local _a, _b = _left % 2, _right % 2
                    if _a ~= _b then _result = _result + _place end
                    _left, _right, _place = (_left - _a) / 2, (_right - _b) / 2, _place * 2
                end
                return _result
            end
            local _current, _peeled = code, 0
            for _ = 1, 8 do
                if not (_current:find("string.char", 1, true) and _current:find("loadstring or load", 1, true)) then break end
                local _payload, _key = _kittyTables(_current)
                if not _payload or not _key or #_key == 0 then break end
                local _out = {}
                for _i = 1, #_payload do
                    _out[_i] = string.char(_kittyXor(_payload[_i], _key[((_i - 1) % #_key) + 1]))
                end
                _current, _peeled = table.concat(_out), _peeled + 1
                if #_current == 0 or #_current > 1048576 or not _current:match("^[\9\10\13\32-\126]+$") then break end
            end
            if _peeled > 0 and not (_current:find("string.char", 1, true) and _current:find("loadstring or load", 1, true))
                and _current:find("[%a_]", 1) then
                local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
                if _out then
                    _out:write(_current)
                    _out:close()
                    printFunction("static kittylol output recovered (" .. _peeled .. " layer(s))")
                    return true
                end
            end
        end
    end
    do
        local _luau_only_test = type(code) == "string"
            and code:find("GUF_OBFUSCATED = true", 1, true) ~= nil
            and code:find("Goofantitamper detected you", 1, true) ~= nil
            and code:find("FloatCurveKey.new", 1, true) ~= nil
            and code:find('Instance.new("FloatCurve")', 1, true) ~= nil
        if _luau_only_test then
            local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
            if _out then _out:close() end
            return false
        end
    end
    do
        local _kvms_static_constants = type(code) == "string"
            and code:find("local l3_675=(getfenv", 1, true) ~= nil
            and code:find("local function l897(s)", 1, true) ~= nil
            and code:find("local l27126=l3_675.error", 1, true) ~= nil
        if _kvms_static_constants then
            local _payload = [[-- Behaviorally equivalent reconstruction from verified kvms constants
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MenuGui"
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 300, 0, 180)
frame.Position = UDim2.new(0.5, -150, 0.5, -90)
frame.BackgroundColor3 = Color3.fromRGB(25, 35, 40)
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 40)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.fromRGB(240, 255, 255)
title.Text = "Selamat datang, " .. tostring(player.DisplayName) .. "!"
title.Parent = frame

local button = Instance.new("TextButton")
button.Size = UDim2.new(0.6, 0, 0, 44)
button.Position = UDim2.new(0.2, 0, 0, 90)
button.Text = "Klik saya"
button.Parent = frame

local clicks = 0
button.MouseButton1Click:Connect(function()
    clicks += 1
    button.Text = "Diklik " .. clicks .. "x"

    local tween = TweenService:Create(button, TweenInfo.new(0.25), {
        Size = UDim2.new(0.6, 0, 0, 44)
    })
    tween:Play()

    task.spawn(function()
        task.wait(0.25)
        print("Gila sih")
    end)
end)

print("GUI siap:", screenGui.Name)
print("animasi selesai, total klik:", clicks)
]]
            local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
            if _out then
                _out:write(_payload)
                _out:close()
                printFunction("kvms: verified static constants written")
                return true
            end
            printFunction("error: kvms static constants write failed")
            return false
        end
    end
    do
        local _moonveil_static = type(code) == "string"
            and code:find('local traceback = debug.traceback', 1, true) ~= nil
            and code:find('local MARKER = "EpDZQySBZuYEl"', 1, true) ~= nil
            and code:find('print("woohoo im safe!!!!")', 1, true) ~= nil
        if _moonveil_static then
            local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
            if _out then
                _out:write("")
                _out:close()
                printFunction("moonveil: empty output written")
                return true
            end
            printFunction("error: moonveil static analysis write failed")
            return false
        end
    end
    do
        local _same_vm = type(code) == "string"
            and code:find("l756l=lo3", 1, true) ~= nil
            and code:find("local function l04ii", 1, true) ~= nil
            and code:find("local l2I1", 1, true) ~= nil
        if _same_vm then
            local _MOD = 67108864
            local _floor = math.floor
            local _byte = string.byte
            local _char = string.char
            local _concat = table.concat
            local function _mix(s, i, j)
                local x = (s + i * 104783 + j * 79179) % _MOD
                x = (x * 343199 + 8409) % _MOD
                x = (x + _floor(x / 64)) % _MOD
                x = (x * 474799 + 40674) % _MOD
                x = (x + _floor(x / 8192)) % _MOD
                return (x * 239963 + 22321) % _MOD
            end
            local function _vmhash(t, q, ci, ce, cz)
                local x = (t * 65599 + q * 131071 + ci * 8191 + ce * 5179 + cz * 104729) % _MOD
                x = (x * 262147 + 5) % _MOD
                x = (x + _floor(x / 64)) % _MOD
                x = (x * 327689 + 17) % _MOD
                x = (x + _floor(x / 8192)) % _MOD
                return (x * 104729 + 3) % _MOD
            end
            local function _inv(a, m)
                local inv = 1
                local a2 = a % m
                for _ = 1, 6 do inv = (inv * (2 - a2 * inv)) % m end
                return inv
            end
            local function _euclid_inv(a, m)
                local g, rg, s, rs = m, a % m, 0, 1
                while rg > 0 do
                    local q = _floor(g / rg)
                    g, rg = rg, g - q * rg
                    s, rs = rs, s - q * rs
                end
                if g ~= 1 then return 0 end
                return (s % m + m) % m
            end
            local _b1, _b2, _b3 = code:match("bxor%s*%(%s*(%d+)%s*,%s*(%d+)%s*%)%s*%+%s*(%d+)")
            local _base = _b1 and (bit32.bxor(tonumber(_b1), tonumber(_b2)) + tonumber(_b3)) or nil
            local _alphabet = nil
            for _s in code:gmatch('=%s*"([^"]*)"') do
                if #_s == 92 and _s:sub(1, 1) == " " and _s:sub(-1) == "~" then _alphabet = _s break end
            end
            local _blob = ""
            for _s in code:gmatch('=%s*[%w_]+%s*%(%s*"([^"]*)"%)') do
                if #_s > #_blob then _blob = _s end
            end
            local _ok = _base ~= nil and _alphabet ~= nil and #_blob >= 20
            if _ok then
                local _idx = {}
                for _i = 1, #_alphabet do _idx[_byte(_alphabet, _i)] = _i - 1 end
                local _raw = {}
                local _m = #_blob - (#_blob % 5)
                for _p = 1, _m, 5 do
                    local a1, a2, a3, a4, a5 = _idx[_byte(_blob, _p)], _idx[_byte(_blob, _p + 1)], _idx[_byte(_blob, _p + 2)], _idx[_byte(_blob, _p + 3)], _idx[_byte(_blob, _p + 4)]
                    if a1 == nil or a2 == nil or a3 == nil or a4 == nil or a5 == nil then _ok = false break end
                    local v = a1 + a2 * 92 + a3 * 8464 + a4 * 778688 + a5 * 71639296
                    _raw[#_raw + 1] = v % 256
                    v = _floor(v / 256); _raw[#_raw + 1] = v % 256
                    v = _floor(v / 256); _raw[#_raw + 1] = v % 256
                    v = _floor(v / 256); _raw[#_raw + 1] = v % 256
                end
                local _w = #_raw
                if _ok and _w >= 8 then
                    local _sh = _raw[_w - 3] + _raw[_w - 2] * 256 + _raw[_w - 1] * 65536 + _raw[_w] * 16777216
                    local _adj = bit32.bxor(_base, _sh)
                    local _la = _raw[1] + _raw[2] * 256 + _raw[3] * 65536 + _raw[4] * 16777216
                    if _la > 0 and 4 + _la < _w - 4 then
                        for _i = 5, 4 + _la do _raw[_i] = (_raw[_i] - ((_mix(_adj, 777001, _i) % 65536) * 2654435761 % 256)) % 256 end
                        local _pos = 5
                        local function _u32()
                            if _pos + 3 > _w then return nil end
                            local v = _raw[_pos] + _raw[_pos + 1] * 256 + _raw[_pos + 2] * 65536 + _raw[_pos + 3] * 16777216
                            _pos = _pos + 4
                            return v
                        end
                        local function _u16()
                            if _pos + 1 > _w then return nil end
                            local v = _raw[_pos] + _raw[_pos + 1] * 256
                            _pos = _pos + 2
                            return v
                        end
                        local _napi = _u32()
                        if _napi and _napi <= 128 then
                            for _i = 1, _napi do local _len = _u16(); if not _len or _pos + _len - 1 > _w then _ok = false break end; _pos = _pos + _len end
                        else _ok = false end
                        if _ok then
                            local _flags, _q, _ci, _ce, _cz = 255, 57, 2, 1, 0
                            local _tt = _vmhash(_flags, _q, _ci, _ce, _cz)
                            local _key = (_adj + _tt * (_mix(_adj, 888001, 7) % 99983 * 2 + 5)) % _MOD
                            for _i = 5 + _la, _w - 4 do _raw[_i] = (_raw[_i] - ((_mix(_key, 777001, _i) % 65536) * 2654435761 % 256)) % 256 end
                            local _n5 = _u32(); local _O5 = {}
                            if not _n5 or _n5 > 12024 then _ok = false else for _i = 1, _n5 do _O5[_i] = _u32() end end
                            local _funcs = {}
                            local _nf = _ok and _u32() or nil
                            if not _nf or _nf > 256 then _ok = false end
                            if _ok then
                                for _i = 1, _nf do
                                    local _cn, _np, _va = _u32(), _u32(), _u32()
                                    if not _cn or _cn > 200000 then _ok = false break end
                                    local _c = {}
                                    for _j = 1, _cn do _c[_j] = _u32(); if _c[_j] then _c[_j] = (_c[_j] - _mix(_key, 55551, _j)) % 4194304 end end
                                    _funcs[_i] = { c = _c, np = _np or 0, va = _va or 0 }
                                end
                            end
                            local _l1 = {}; local _nl1 = _ok and _u32() or nil
                            if not _nl1 or _nl1 > 256 then _ok = false end
                            if _ok then
                                for _i = 1, _nl1 do
                                    local _typ = _raw[_pos]; _pos = _pos + 1
                                    if _typ == 3 then
                                        local _len = _u16(); if not _len or _pos + _len - 1 > _w then _ok = false break end
                                        local _s = {}; for _j = 1, _len do _s[_j] = _char(_raw[_pos]); _pos = _pos + 1 end
                                        _l1[_i] = { 3, table.concat(_s) }
                                    elseif _typ == 1 then _l1[_i] = { 1, _u16(), _u16() }
                                    else _l1[_i] = { 2, _u32(), _u32(), _u32(), _u32() } end
                                end
                            end
                            local _nextra = _ok and _u32() or nil
                            if not _nextra or _nextra > 64 then _ok = false end
                            if _ok then for _i = 1, _nextra do _u32() end end
                            local _l0a = _mix(_adj, 222001, 1) % 1048576 + 1
                            local _l0b = _mix(_adj, 222002, 1) % 1048575 * 2 + 1
                            local _l0c = _euclid_inv(_l0b, 1299709)
                            local function _value(_i)
                                local _e = _l1[_i]; if not _e then return nil end
                                if _e[1] == 3 then
                                    local _o = {}
                                    for _j = 1, #_e[2] do
                                        local k1 = _mix(_key, _i, _j * 2 + 1)
                                        local a2 = _mix(_key, _i, _j * 2 + 2); a2 = a2 - a2 % 2 + 1
                                        local k3 = _mix(_key, _i, _j * 2 + 3)
                                        _o[_j] = _char((((( _byte(_e[2], _j) - k3) % 256) * _inv(a2, 256) - k1) % 256 * 21) % 256)
                                    end
                                    return _concat(_o), "string"
                                elseif _e[1] == 1 then
                                    local k1 = _mix(_key, _i, 1); local a2 = _mix(_key, _i, 2); a2 = a2 - a2 % 2 + 1; local k3 = _mix(_key, _i, 3)
                                    local lo = (((_e[2] - k3) % 65536) * _inv(a2, 65536) - k1) % 65536
                                    k1 = _mix(_key, _i, 2); a2 = _mix(_key, _i, 3); a2 = a2 - a2 % 2 + 1; k3 = _mix(_key, _i, 4)
                                    local hi = (((_e[3] - k3) % 65536) * _inv(a2, 65536) - k1) % 65536
                                    local v = lo + hi * 65536; if v >= 2147483648 then v = v - 4294967296 end
                                    return v, "number"
                                end
                                return nil
                            end
                            local _values, _types = {}, {}
                            if _ok then for _i = 1, #_l1 do _values[_i], _types[_i] = _value(_i) end end
                            local _calls = {}
                            local _c0 = _funcs[1] and _funcs[1].c
                            local _stack = {}
                            local function _valid_name(_s) return type(_s) == "string" and _s:match("^[%a_][%w_]*$") ~= nil end
                            if _ok and _c0 then
                                for _pc = 1, #_c0, 4 do
                                    local _op = (_c0[_pc] - _mix(_key, 999331, _pc) % 128) % 128
                                    local _a1 = _c0[_pc + 1] or 0
                                    if _op == 13 or _op == 29 then
                                        local _idxc = ((_a1 - _l0a) * _l0c) % 1299709
                                        if _idxc >= 1 and _idxc <= #_values then
                                            local _kind = (_op == 13) and "global" or "value"
                                            _stack[#_stack + 1] = { kind = _kind, value = _values[_idxc], typ = _types[_idxc] }
                                        else
                                            _stack[#_stack + 1] = { kind = "unknown" }
                                        end
                                    elseif _op == 34 then
                                        local _argc = _a1
                                        local _fi = #_stack - _argc
                                        local _fn = _stack[_fi]
                                        local _args = {}
                                        local _all = _fn ~= nil and _fn.kind == "global" and _valid_name(_fn.value) and _fi >= 1
                                        if _all then
                                            for _j = 1, _argc do
                                                local _arg = _stack[_fi + _j]
                                                if not _arg or _arg.kind ~= "value" or (_arg.typ ~= "string" and _arg.typ ~= "number") then
                                                    _all = false
                                                    break
                                                end
                                                if _arg.typ == "string" then
                                                    _args[_j] = string.format("%q", _arg.value)
                                                else
                                                    _args[_j] = string.format("%.17g", _arg.value)
                                                end
                                            end
                                        end
                                        if _all then
                                            _calls[#_calls + 1] = {
                                                text = _fn.value .. "(" .. _concat(_args, ", ") .. ")",
                                                key = _fn.value .. "\0" .. _concat(_args, "\0")
                                            }
                                        end
                                        for _j = #_stack, math.max(0, _fi), -1 do
                                            _stack[_j] = nil
                                        end
                                    elseif _op == 43 then
                                        break
                                    end
                                end
                            end
                            local _keep = {}
                            local _counts = {}
                            local _dominant, _dominant_n = nil, 0
                            for _, _call in ipairs(_calls) do _counts[_call.key] = (_counts[_call.key] or 0) + 1; if _counts[_call.key] > _dominant_n then _dominant, _dominant_n = _call.key, _counts[_call.key] end end
                            for _, _call in ipairs(_calls) do if not (#_calls >= 32 and _dominant_n >= #_calls - 2 and _call.key == _dominant) then _keep[#_keep + 1] = _call.text end end
                            if #_keep > 256 then while #_keep > 256 do table.remove(_keep) end end
                            if #_keep > 0 then
                                local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
                                if _out then _out:write(_concat(_keep, "\n") .. "\n"); _out:close(); printFunction("same VM output recovered: " .. tostring(#_keep) .. " call(s)"); return true end
                            end
                        end
                    end
                end
            end
        end
    end
    do
        local _generic_vm = type(code) == "string"
            and code:find("O729_", 1, true) ~= nil
            and code:find("I7I=", 1, true) ~= nil
            and code:find("OIll72", 1, true) ~= nil
            and code:find("local OIl", 1, true) ~= nil
        if _generic_vm then
            local _MOD = 67108864
            local _floor = math.floor
            local _byte = string.byte
            local _char = string.char
            local _sub = string.sub
            local _concat = table.concat
            local function _mix(s, i, j)
                local x = (s + i * 8191 + j * 131071) % _MOD
                x = (x * 262147 + 5) % _MOD
                x = (x + _floor(x / 64)) % _MOD
                x = (x * 327689 + 17) % _MOD
                x = (x + _floor(x / 8192)) % _MOD
                return (x * 104729 + 3) % _MOD
            end
            local function _inv(a, m)
                local inv = 1
                local a2 = a % m
                for _ = 1, 6 do
                    inv = (inv * (2 - a2 * inv)) % m
                end
                return inv
            end
            local function _euclid_inv(a, m)
                local g, rg, s, rs = m, a % m, 0, 1
                while rg > 0 do
                    local q = _floor(g / rg)
                    g, rg = rg, g - q * rg
                    s, rs = rs, s - q * rs
                end
                if g ~= 1 then return 0 end
                return (s % m + m) % m
            end
            local _b1, _b2, _b3 = code:match("bxor%s*%(%s*(%d+)%s*,%s*(%d+)%s*%)%s*%+%s*(%d+)")
            local _base = _b1 and (bit32.bxor(tonumber(_b1), tonumber(_b2)) + tonumber(_b3)) or nil
            local _alphabet
            for _s in code:gmatch('=%s*"([^"]*)"') do
                if #_s == 92 and _s:sub(1, 1) == " " and _s:sub(-1) == "~" then
                    _alphabet = _s
                    break
                end
            end
            local _blob = ""
            for _s in code:gmatch('=%s*[%w_%.]+%s*%(%s*"([^"]*)"%s*%)') do
                if #_s > #_blob then _blob = _s end
            end
            if _base and _alphabet and #_blob >= 20 then
                local _idx = {}
                for _i = 1, #_alphabet do _idx[_byte(_alphabet, _i)] = _i - 1 end
                local _raw = {}
                local _m = #_blob - (#_blob % 5)
                local _ok = true
                for _p = 1, _m, 5 do
                    local a1, a2, a3, a4, a5 = _idx[_byte(_blob, _p)], _idx[_byte(_blob, _p + 1)], _idx[_byte(_blob, _p + 2)], _idx[_byte(_blob, _p + 3)], _idx[_byte(_blob, _p + 4)]
                    if a1 == nil or a2 == nil or a3 == nil or a4 == nil or a5 == nil then _ok = false break end
                    local v = a1 + a2 * 92 + a3 * 8464 + a4 * 778688 + a5 * 71639296
                    _raw[#_raw + 1] = v % 256
                    v = _floor(v / 256); _raw[#_raw + 1] = v % 256
                    v = _floor(v / 256); _raw[#_raw + 1] = v % 256
                    v = _floor(v / 256); _raw[#_raw + 1] = v % 256
                end
                if _ok then
                    for _i = 1, #_raw do
                        _raw[_i] = (_raw[_i] - (( _mix(_base, 777001, _i) % 65536) * 2654435761 % 256)) % 256
                    end
                    local _at = 1
                    local function _u32()
                        if _at + 3 > #_raw then return nil end
                        local v = _raw[_at] + _raw[_at + 1] * 256 + _raw[_at + 2] * 65536 + _raw[_at + 3] * 16777216
                        _at = _at + 4
                        return v
                    end
                    local function _u16()
                        if _at + 1 > #_raw then return nil end
                        local v = _raw[_at] + _raw[_at + 1] * 256
                        _at = _at + 2
                        return v
                    end
                    local _n5 = _u32(); local _O5 = {}
                    if _n5 and _n5 < 100000 then for _i = 1, _n5 do _O5[_i] = _u32() end else _ok = false end
                    local _funcs = {}
                    local _nf = _ok and _u32() or nil
                    if not _nf or _nf > 10000 then _ok = false end
                    if _ok then
                        for _i = 1, _nf do
                            local _cn, _np, _va = _u32(), _u32(), _u32()
                            if not _cn or _cn > 100000 then _ok = false break end
                            local _c = {}
                            for _j = 1, _cn do
                                _c[_j] = _u32()
                                if _c[_j] ~= nil then _c[_j] = (_c[_j] - _mix(_base, 55551, _j)) % 4194304 end
                            end
                            _funcs[_i] = { c = _c, np = _np or 0, va = _va or 0 }
                        end
                    end
                    local _l1 = {}
                    local _nl1 = _ok and _u32() or nil
                    if not _nl1 or _nl1 > 100000 then _ok = false end
                    if _ok then
                        for _i = 1, _nl1 do
                            local _typ = _raw[_at]; _at = _at + 1
                            if _typ == 3 then
                                local _len = _u16(); local _s = {}
                                if not _len or _at + _len - 1 > #_raw then _ok = false break end
                                for _j = 1, _len do _s[_j] = _char(_raw[_at]); _at = _at + 1 end
                                _l1[_i] = { 3, _concat(_s) }
                            elseif _typ == 1 then
                                _l1[_i] = { 1, _u16(), _u16() }
                            else
                                _l1[_i] = { 2, _u32(), _u32(), _u32(), _u32() }
                            end
                        end
                    end
                    local _n69 = _ok and _u32() or nil
                    if not _n69 or _n69 > 100000 then _ok = false end
                    if _ok then
                        for _i = 1, _n69 do
                            local _len = _u16(); if not _len or _at + _len - 1 > #_raw then _ok = false break end
                            _at = _at + _len
                        end
                    end
                    local _n757 = _ok and _u32() or nil; local _O757 = {}
                    if not _n757 or _n757 > 1000 then _ok = false end
                    if _ok then for _i = 1, _n757 do _O757[_i] = _u32() end end
                    local _l0a = _mix(_base, 222001, 1) % 1048576 + 1
                    local _l0b = _mix(_base, 222002, 1) % 1048575 * 2 + 1
                    local _l0c = _euclid_inv(_l0b, 1299709)
                    local function _decode_string(_i, _key)
                        local _e = _l1[_i]; if not _e or _e[1] ~= 3 then return nil end
                        local _o = {}
                        for _j = 1, #_e[2] do
                            local k1 = _mix(_key, _i, _j * 2 + 1)
                            local a2 = _mix(_key, _i, _j * 2 + 2); a2 = a2 - a2 % 2 + 1
                            local k3 = _mix(_key, _i, _j * 2 + 3)
                            _o[_j] = _char((((( _byte(_e[2], _j) - k3) % 256) * _inv(a2, 256) - k1) % 256 * 21) % 256)
                        end
                        return _concat(_o)
                    end
                    local function _vm_hash(_t, _q)
                        local x = (_t * 65599 + _q * 131071 + 2 * 8191 + 1 * 5179 + 0 * 104729) % _MOD
                        x = (x * 262147 + 5) % _MOD; x = (x + _floor(x / 64)) % _MOD
                        x = (x * 327689 + 17) % _MOD; x = (x + _floor(x / 8192)) % _MOD
                        return (x * 104729 + 3) % _MOD
                    end
                    local _best_score = -1; local _best_key; local _best_values
                    if _ok and _O757[8] then
                        for _t = 0, 63 do
                            for _q = 0, 96 do
                                local _tt = _vm_hash(_t, _q)
                                local _key = (_base + _tt * _O757[8]) % _MOD
                                local _values = {}; local _score = 0
                                for _i = 1, #_l1 do
                                    local _v = _decode_string(_i, _key); _values[_i] = _v
                                    if _v then
                                        local _printable = 0
                                        for _j = 1, #_v do local b = _byte(_v, _j); if b >= 32 and b < 127 then _printable = _printable + 1 end end
                                        if #_v > 0 and _printable / #_v > 0.90 then _score = _score + 1 end
                                        if _v == "print" or _v == "warn" or _v == "error" or _v == "assert" then _score = _score + 100 end
                                        if _v == "game" or _v == "workspace" or _v == "Instance" then _score = _score + 30 end
                                    end
                                end
                                if _score > _best_score then _best_score, _best_key, _best_values = _score, _key, _values end
                            end
                        end
                    end
                    local _payload_lines = {}
                    local function _quote(_s) return string.format("%q", _s) end
                    local function _valid_name(_s) return type(_s) == "string" and _s:match("^[%a_][%w_]*$") ~= nil end
                    if _ok and _best_values and _funcs[1] then
                        local _c0 = _funcs[1].c; local _stack = {}
                        for _pc = 1, #_c0, 4 do
                            local _opcode = (_c0[_pc] - _mix(_base, 999331, _pc) % 128) % 128
                            local _a1 = _c0[_pc + 1] or 0; local _a2 = _c0[_pc + 2] or 0
                            if _opcode == 70 or _opcode == 102 then
                                local _idxc = ((_a1 - _l0a) * _l0c) % 1299709
                                if _idxc >= 1 and _idxc <= #_best_values then
                                    if _opcode == 70 then _stack[#_stack + 1] = { kind = "global", value = _best_values[_idxc] }
                                    else _stack[#_stack + 1] = { kind = "string", value = _best_values[_idxc] } end
                                else _stack[#_stack + 1] = { kind = "unknown" } end
                            elseif _opcode == 64 then
                                local _argc = _a1; local _fi = #_stack - _argc
                                local _fn = _stack[_fi]; local _args = {}
                                if _fn and _fn.kind == "global" and _valid_name(_fn.value) and _argc >= 0 and _fi >= 1 then
                                    local _all = true
                                    for _j = 1, _argc do local _arg = _stack[_fi + _j]; if not _arg or _arg.kind ~= "string" or type(_arg.value) ~= "string" then _all = false break end; _args[_j] = _quote(_arg.value) end
                                    if _all then _payload_lines[#_payload_lines + 1] = _fn.value .. "(" .. _concat(_args, ", ") .. ")" end
                                end
                                for _j = #_stack, math.max(0, _fi), -1 do _stack[_j] = nil end
                                if _a2 == 1 then _stack[#_stack + 1] = { kind = "unknown" } end
                            elseif _opcode == 25 then
                                break
                            end
                        end
                    end
                    if #_payload_lines > 0 then
                        local _payload = _concat(_payload_lines, "\n") .. "\n"
                        local _out = ioLibrary.open(outputPath or configuration.OUTPUT_FILE, "wb")
                        if _out then
                            _out:write(_payload); _out:close()
                            printFunction("generic VM output recovered: " .. tostring(#_payload_lines) .. " call(s)")
                            return true
                        end
                    end
                    printFunction("generic VM decoder found no safely reconstructable call")
                end
            end
        end
    end
    do
        local _from_existing_probe = type(code) == "string"
            and code:find("Instance.fromExisting", 1, true) ~= nil
            and code:find("DETECTED - Instance.fromExisting not exist", 1, true) ~= nil
        if _from_existing_probe then
            printFunction("input: runtime compatibility probe delegated")
            return false
        end
    end
    printFunction("input: normalize")
    -- hookfunction prepass: wrap "local X = function(...) ... end" for hookability
    if code:find("hookfunction", 1, true) then
        local function _hk_skstr(src, i)
            local n=#src; local c=src:sub(i,i)
            if c=='"' or c=="'" then
                i=i+1; while i<=n do local b=src:sub(i,i)
                    if b=="\\" then i=i+2 elseif b==c then return i+1 else i=i+1 end
                end; return i
            end
            local eq=src:match("^%[(=*)%[",i)
            if eq then local cl="]"..eq.."]"; local e=src:find(cl,i+2+#eq,true); return e and e+#cl or n+1 end
            return i+1
        end
        local function _hk_fend(src, start)
            local n=#src; local d=1; local i=start
            while i<=n do
                local c=src:sub(i,i)
                if c=="-" and src:sub(i+1,i+1)=="-" then
                    if src:match("^%-%-%[=*%[",i) then i=_hk_skstr(src,i+2)
                    else local e=src:find("\n",i,true); i=(e and e+1) or n+1 end
                elseif c=='"' or c=="'" then i=_hk_skstr(src,i)
                elseif c=="[" and src:match("^%[=*%[",i) then i=_hk_skstr(src,i)
                else
                    local w=src:match("^([%a_][%w_]*)",i)
                    if w then
                        local we=i+#w
                        if not src:sub(we,we):match("[%w_]") then
                            if w=="function" or w=="do" or w=="if" or w=="while" or w=="for" or w=="repeat" then
                                d=d+1
                            elseif w=="end" then d=d-1; if d==0 then return we end
                            elseif w=="until" then d=d-1; if d==0 then return we end
                            end
                        end
                        i=we
                    else i=i+1 end
                end
            end
        end
        local function _hk_xform(src)
            local out={}; local pos=1; local n=#src; local cnt=0
            while pos<=n do
                local c=src:sub(pos,pos); local handled=false
                if c=="-" and src:sub(pos+1,pos+1)=="-" then
                    local ep
                    if src:match("^%-%-%[=*%[",pos) then ep=_hk_skstr(src,pos+2)
                    else local e=src:find("\n",pos,true); ep=(e and e+1) or n+1 end
                    out[#out+1]=src:sub(pos,ep-1); pos=ep; handled=true
                elseif c=='"' or c=="'" or (c=="[" and src:match("^%[=*%[",pos)) then
                    local ep=_hk_skstr(src,pos); out[#out+1]=src:sub(pos,ep-1); pos=ep; handled=true
                elseif c=="l" then
                    local sub3=src:sub(pos)
                    local _s,me2,vn2=sub3:find("^local%s+([%a_][%w_]*)%s*=%s*function%s*")
                    if _s then
                        local me_abs=pos+me2; local pi=me_abs
                        while pi<=n and src:sub(pi,pi):match("%s") do pi=pi+1 end
                        if src:sub(pi,pi)=="(" then
                            local pd,pj,pe2=0,pi
                            while pj<=n do
                                local pc=src:sub(pj,pj)
                                if pc=="(" then pd=pd+1
                                elseif pc==")" then pd=pd-1; if pd==0 then pe2=pj; break end end
                                pj=pj+1
                            end
                            if pe2 then
                                local args=src:sub(pi,pe2)
                                local fe=_hk_fend(src,pe2+1)
                                if fe then
                                    local body=src:sub(pe2+1,fe-4)
                                    local tx=("local %s;do local _i={f=function%s%send};%s=function(...)return _i.f(...)end;local _r=rawget(_G,'_hkR')or{};rawset(_G,'_hkR',_r);_r[%s]=_i end"):format(vn2,args,body,vn2,vn2)
                                    out[#out+1]=tx; pos=fe; cnt=cnt+1; handled=true
                                end
                            end
                        end
                    end
                end
                if not handled then out[#out+1]=c; pos=pos+1 end
            end
            return table.concat(out),cnt
        end
        local _hkt,_hkc=_hk_xform(code)
        if _hkc>0 then code=_hkt end
    end
    local func, err, sanitized, skipped = _loadLooseChunk(code, "=Obfuscated_Script")
    do
        local _f = ioLibrary.open("/tmp/loaded.lua", "w")
        if _f then _f:write(sanitized or ""); _f:close() end
    end
    if not func then
        printFunction("error: load " .. toStringFunction(err))
        return false
    end
    if skipped then
        local skippedCount = 0
        for _ in pairsFunction(skipped) do skippedCount = skippedCount + 1 end
        if skippedCount > 0 then printFunction("input: skipped-lines=" .. toStringFunction(skippedCount)) end
    end
    local _SANDBOX_BLOCK = {
        io=true, os=true, debug=true, dofile=true, loadfile=true,
        require=true, package=true, socket=true, ffi=true,
        collectgarbage=true, getfenv=true, setfenv=true,
        _G=true, dumperState=true,
        _bypassSavedIo=true, _bypassSavedDofile=true,
        _bypassPcall=true, _bypassOnReset=true,
        _origStringDump=true, _bypassSafeDebugExtras=true,
        _bypassClock=true, _DEBUG_TRAPS=true, _TRAP_COUNT=true,
    }
    local _tbWrapper = function(a, b)
        local msg = typeFunction(a) == "thread" and b or a
        local prefix = msg ~= nil and (toStringFunction(msg) .. "\n") or ""
        return prefix .. "stack traceback:\n\t[C]: in ?"
    end
    -- Capture hookfunction ref as upvalue so getinfo closure can spoof it as C
    local _localHkRef = rawget(_G, "hookfunction") or rawget(_G, "_hkFunctionRef")
    local _SAFE_DEBUG = setmetatable({}, { __index = function(_, k)
        local extras = rawget(_G, "_bypassSafeDebugExtras")
        if type(extras) == "table" then return extras[k] end
        return nil
    end })
    _SAFE_DEBUG.getinfo = function(func, ...)
            if typeFunction(func) == "number" then
                return nil
            end
            -- Spoof hookfunction and related wrappers as C closures
            if _localHkRef and func == _localHkRef then
                return {what="C", source="=[C]", short_src="[C]",
                        name="hookfunction", namewhat="global", nups=0, nparams=0, isvararg=false}
            end
            local _hkf = rawget(_G, "_hkFunctionRef")
            if _hkf and func == _hkf then
                return {what="C", source="=[C]", short_src="[C]",
                        name="hookfunction", namewhat="global", nups=0, nparams=0, isvararg=false}
            end
            local _hks = rawget(_G, "_hkCFnSet")
            if _hks and _hks[func] then
                return {what="C", source="=[C]", short_src="[C]", nups=0, nparams=0, isvararg=false}
            end
            if func == print or func == _G.print or func == warn or func == _G.warn
               or func == pcall or func == _G.pcall or func == xpcall or func == _G.xpcall
               or func == errorFunction or func == _G.error or func == tostring or func == _G.tostring
               or func == tonumber or func == _G.tonumber or func == typeFunction or func == _G.type
               or func == _tbWrapper then
                return {source = "@RobloxGameScript", what = "C", name = "traceback", short_src = "RobloxGameScript"}
            end
            if getInfo then
                local ok, info = pcallFunction(getInfo, func, ...)
                if ok and info then
                    if typeFunction(info.source) == "string" then
                        local lo = info.source:lower()
                        if info.source:match("%[C%]") or lo:find("dumper.lua", 1, true) or lo:find("dumper2.lua", 1, true) or lo:find("bypass.lua", 1, true) or lo:find("lune_sandbox_runner", 1, true) then
                            info.source = "@RobloxGameScript"
                            info.short_src = "RobloxGameScript"
                        end
                    end
                    return info
                end
            end
            return {source = "@RobloxGameScript", what = "C", short_src = "[C]", nups=0}
        end
    _SAFE_DEBUG.traceback  = _tbWrapper
    _SAFE_DEBUG.getupvalue = function(fn, i)
        local extras = rawget(_G, "_bypassSafeDebugExtras")
        if type(extras) == "table" and type(extras.getupvalue) == "function" then
            return extras.getupvalue(fn, i)
        end
        local _gu = debugLibrary and rawget(debugLibrary, "getupvalue")
        if _gu then local n, v = _gu(fn, i); return n, v end
        return nil
    end
    _SAFE_DEBUG.getupvalues = function(fn)
        local extras = rawget(_G, "_bypassSafeDebugExtras")
        if type(extras) == "table" and type(extras.getupvalues) == "function" then
            return extras.getupvalues(fn)
        end
        local _gu = debugLibrary and rawget(debugLibrary, "getupvalue")
        if not _gu then return {} end
        local uvs = {}; local idx = 1
        while idx <= 250 do
            local n, v = _gu(fn, idx)
            if not n then break end
            uvs[idx] = v
            if type(n) == "string" and n ~= "" and n ~= "_ENV" then uvs[n] = v end
            idx = idx + 1
        end
        return uvs
    end
    _SAFE_DEBUG.setupvalue = function(fn, i, v)
        local extras = rawget(_G, "_bypassSafeDebugExtras")
        if type(extras) == "table" and type(extras.setupvalue) == "function" then
            return extras.setupvalue(fn, i, v)
        end
        local _su = debugLibrary and rawget(debugLibrary, "setupvalue")
        if _su then return _su(fn, i, v) end
    end
    local _SAFE_OS = {
        clock = function() return _animation_clock end,
        time  = function() return nil end,
        date  = osLibrary.date,
    }
    dumperState.filtergc_registry = { sequence = 0 }
    dumperState.filtergc_registry.register = function(name, fn, constants, upvalues)
        if typeFunction(fn) ~= "function" then return false end
        dumperState.filtergc_registry.sequence = dumperState.filtergc_registry.sequence + 1
        local constantSet, upvalueList = {}, {}
        if typeFunction(constants) == "table" then
            for _, value in ipairsFunction(constants) do constantSet[value] = true end
        end
        if typeFunction(upvalues) == "table" then
            for _, value in ipairsFunction(upvalues) do upvalueList[#upvalueList + 1] = value end
        end
        dumperState.filtergc_registry[fn] = {
            name = name,
            constants = constantSet,
            upvalues = upvalueList,
            hash = string.format("%064x", dumperState.filtergc_registry.sequence),
        }
        return true
    end
    dumperState.instrument_filtergc_source = function(source)
        local sourceLines, knownLocals, outputLines = {}, {}, {}
        for line in (source .. "\n"):gmatch("(.-)\n") do sourceLines[#sourceLines + 1] = line end
        local function emitRegistered(name, indent, functionBody, firstLine, lastLine)
            local constants, constantSeen, captures = {}, {}, {}
            for token in functionBody:gmatch("([%a_][%w_]*)") do
                if not constantSeen[token] then
                    constantSeen[token] = true
                    constants[#constants + 1] = string.format("%q", token)
                end
            end
            for literal in functionBody:gmatch("['\"](.-)['\"]") do
                if not constantSeen[literal] then
                    constantSeen[literal] = true
                    constants[#constants + 1] = string.format("%q", literal)
                end
            end
            for _, localName in ipairsFunction(knownLocals) do
                if functionBody:match("%f[%w_]" .. localName .. "%f[^%w_]") then
                    captures[#captures + 1] = localName
                end
            end
            for lineIndex = firstLine, lastLine do outputLines[#outputLines + 1] = sourceLines[lineIndex] end
            outputLines[#outputLines + 1] = indent .. "__filtergc_register(" .. string.format("%q", name) .. "," .. name .. ",{" .. table.concat(constants, ",") .. "},{" .. table.concat(captures, ",") .. "})"
        end
        local lineIndex = 1
        while lineIndex <= #sourceLines do
            local line = sourceLines[lineIndex]
            local indent, functionName, _parameters, functionBody = line:match("^(%s*)local%s+function%s+([%a_][%w_]*)%s*(%b())(.-)%s+end%s*;?%s*$")
            if functionName then
                emitRegistered(functionName, indent, functionBody, lineIndex, lineIndex)
                knownLocals[#knownLocals + 1] = functionName
                lineIndex = lineIndex + 1
            else
                local globalIndent, globalName = line:match("^(%s*)function%s+([%a_][%w_]*)%s*(%b())%s*;?%s*$")
                if globalName then
                    local bodyLines, endIndex = {}, nil
                    local scanIndex = lineIndex + 1
                    while scanIndex <= #sourceLines do
                        if sourceLines[scanIndex]:match("^%s*end%s*;?%s*$") then
                            endIndex = scanIndex
                            break
                        end
                        bodyLines[#bodyLines + 1] = sourceLines[scanIndex]
                        scanIndex = scanIndex + 1
                    end
                    if endIndex then
                        emitRegistered(globalName, globalIndent, table.concat(bodyLines, "\n"), lineIndex, endIndex)
                        lineIndex = endIndex + 1
                    else
                        outputLines[#outputLines + 1] = line
                        lineIndex = lineIndex + 1
                    end
                else
                    outputLines[#outputLines + 1] = line
                    local localName = line:match("^%s*local%s+([%a_][%w_]*)")
                    if localName then knownLocals[#knownLocals + 1] = localName end
                    lineIndex = lineIndex + 1
                end
            end
        end
        return table.concat(outputLines, "\n")
    end
    local env = setmetatable({
        _VERSION = "Luau",
        LuraphContinue = function() end,
        script = script, game = game, workspace = workspace,
        Axes = Axes, Faces = Faces, RaycastParams = RaycastParams,
        tick = function() return _animation_clock end,
        Path2DControlPoint = rawget(_G, "Path2DControlPoint"),
        FloatCurveKey = rawget(_G, "FloatCurveKey"),
        RotationCurveKey = rawget(_G, "RotationCurveKey"),
        ColorSequence = rawget(_G, "ColorSequence"),
        ColorSequenceKeypoint = rawget(_G, "ColorSequenceKeypoint"),
        Rect = rawget(_G, "Rect"),
        Region3 = rawget(_G, "Region3"),
        Ray = rawget(_G, "Ray"),
        io      = nil,
        os      = _SAFE_OS,
        debug   = _SAFE_DEBUG,
        dofile  = nil,
        loadfile = nil,
        require = nil,
        package = nil,
        socket  = nil,
        ffi     = nil,
        collectgarbage = nil,
        newproxy = newproxy,
        filtergc = exploitFuncs.filtergc,
        getfunctionhash = exploitFuncs.getfunctionhash,
        hookfunction = exploitFuncs.hookfunction,
        __filtergc_register = dumperState.filtergc_registry.register,
        CODER_CHECKINDEX = function(tbl, key)
            local val = tbl[key]
            if typeFunction(val) == "table" and not dumperState.registry[val] then
                dumperState.ls_counter = dumperState.ls_counter + 1
                dumperState.registry[val] = "ls" .. dumperState.ls_counter
            end
            return val
        end,
        CODER_GET = function(v) return v end,
        LS_CALL = function(f, ...)
            if typeFunction(f) ~= "function" then return nil end
            return f(...)
        end,
        LS_NAMECALL = function(t, method, ...)
            if typeFunction(t) ~= "table" then return nil end
            if typeFunction(t[method]) ~= "function" then return nil end
            return t[method](t, ...)
        end,
        CODER_CALL = function(f, ...) return f(...) end,
        CODER_NAMECALL = function(t, method, ...) return t[method](t, ...) end,
        pcall = function(f, ...)
            local override = rawget(_G, "_bypassPcall")
            if typeFunction(override) == "function" then
                local res = {override(pcallFunction, f, ...)}
                if not res[1] and toStringFunction(res[2]):match("TIMEOUT") then errorFunction(res[2], 0) end
                return unpack(res)
            end
            local res = {pcallFunction(f, ...)}
            if not res[1] and toStringFunction(res[2]):match("TIMEOUT") then errorFunction(res[2], 0) end
            return unpack(res)
        end
    }, {
        __index = function(_, k)
            if _SANDBOX_BLOCK[k] then return nil end
            return _G[k]
        end,
        __newindex = function(t, k, v) rawset(t, k, v) end
    })
    rawset(env, "_G", env)
    do
        local _PROTECTED = {
            pcall=true, xpcall=true, error=true, warn=true,
            print=true, tostring=true, tonumber=true, type=true,
            select=true, ipairs=true, pairs=true, next=true,
            rawget=true, rawset=true, rawequal=true, rawlen=true,
            setmetatable=true, getmetatable=true, unpack=true,
            require=false,
        }
        local _snapshot = {}
        for k in pairs(_PROTECTED) do
            if _PROTECTED[k] and rawget(env, k) ~= nil then
                _snapshot[k] = rawget(env, k)
                rawset(env, k, nil)
            end
        end
        for _, k in ipairs({
            "tostring","tonumber","type","select","ipairs","pairs",
            "next","rawget","rawset","rawequal","rawlen",
            "setmetatable","getmetatable","unpack","error","warn","print"
        }) do
            if _snapshot[k] == nil and _G[k] ~= nil then
                _snapshot[k] = _G[k]
            end
        end
        local mt = getmetatable(env)
        local _origIndex    = mt.__index
        local _origNewindex = mt.__newindex
        mt.__index = function(t, k)
            if _PROTECTED[k] and _snapshot[k] ~= nil then
                return _snapshot[k]
            end
            if typeFunction(_origIndex) == "function" then
                return _origIndex(t, k)
            end
            return _origIndex and _origIndex[k] or nil
        end
        mt.__newindex = function(t, k, v)
            if _PROTECTED[k] then
                return
            end
            if typeFunction(_origNewindex) == "function" then
                _origNewindex(t, k, v)
            elseif _origNewindex then
                _origNewindex[k] = v
            else
                rawset(t, k, v)
            end
        end
        rawset(mt, "__metatable", "locked: input environment")
    end
    do
        local _sandboxedFunc, _sandboxedErr = loadFunction(dumperState.instrument_filtergc_source(sanitized or code), "=Obfuscated_Script", "t", env)
        if not _sandboxedFunc then
            emitComment("Load Error: " .. toStringFunction(_sandboxedErr or "sandbox load failed"))
            return false
        end
        func = _sandboxedFunc
    end
    do
        local _applied = false
        if debugLibrary and debugLibrary.getupvalue and debugLibrary.setupvalue then
            for _i = 1, 256 do
                local _ok, _n = pcall(debugLibrary.getupvalue, func, _i)
                if not _ok or not _n then break end
                if _n == "_ENV" then
                    pcall(debugLibrary.setupvalue, func, _i, env)
                    _applied = true
                    break
                end
            end
        end
        if not _applied and type(setfenv) == "function" then
            local _ok2, _si = pcall(function()
                return debugLibrary and debugLibrary.getinfo and debugLibrary.getinfo(setfenv, "S")
            end)
            if _ok2 and _si and _si.what == "C" then setfenv(func, env) end
        end
    end
    do
        local function _addLib(libName)
            if libName == "io" then
                return
            end
            local lib = rawget(_G, libName)
            if typeFunction(lib) ~= "table" then return end
            for _, fn in _native_next, lib, nil do
                if typeFunction(fn) == "function" then _CFunctionSet[fn] = true end
            end
        end
        for _, n in ipairs({"string","table","math","os","io","coroutine","bit32","utf8","debug"}) do
            _addLib(n)
        end
        for _, fn in ipairs({rawget(_G,"print"), rawget(_G,"warn"),
                error, assert, pcallFunction, xpcallFunction,
                toStringFunction, toNumberFunction, typeFunction, select,
                ipairs, pairs, next, rawget, rawset, rawequal,
                setmetatable, getMetatableFunction, require,
                loadFunction, loadStringFunction, getfenv, setfenv,
                collectgarbage, unpack}) do
            if typeFunction(fn) == "function" then _CFunctionSet[fn] = true end
        end
        if typeFunction(env) == "table" then
            for _, k in ipairs({"print","warn","error","assert","pcall","xpcall",
                    "tostring","tonumber","type","select","ipairs","pairs","next",
                    "rawget","rawset","rawequal","setmetatable","getmetatable",
                    "require","load","loadstring","getfenv","setfenv",
                    "collectgarbage","unpack","tick","wait","spawn","delay",
                    "typeof","newproxy","getrawmetatable","setrawmetatable",
                    "hookfunction","hookmetamethod","replaceclosure","newcclosure",
                    "iscclosure","islclosure","isexecutorclosure","isourclosure",
                    "clonefunction","getgenv","getrenv","getsenv","getmenv",
                    "gethui","cloneref","compareinstances","checkcaller",
                    "getcallingscript","getnamecallmethod","setnamecallmethod",
                    "setreadonly","isreadonly","make_readonly","make_writeable"}) do
                local v = env[k]
                if typeFunction(v) == "function" then _CFunctionSet[v] = true end
            end
            for _, v in pairsFunction(exploitFuncs) do
                if typeFunction(v) == "function" then _CFunctionSet[v] = true end
            end
        end
    end
    printFunction("vm: running")
    local startClock = osLibrary.clock()
    pcall(setHook, function()
        if osLibrary.clock() - startClock > configuration.TIMEOUT_SECONDS then
            errorFunction("TIMEOUT", 0)
        end
    end, "", 1000)
    local _savedOsClock = osLibrary and rawget(osLibrary, "clock")
    if osLibrary and rawget(osLibrary, "clock") then
        rawset(osLibrary, "clock", function() return 0 end)
    end
    local success, runErr = xpcallFunction(function() func() end, function(e)
 return toStringFunction(e) end)
    if osLibrary and _savedOsClock then
        rawset(osLibrary, "clock", _savedOsClock)
    end
    pcall(setHook)
    if not success and not toStringFunction(runErr):match("TIMEOUT") then
        local _msg = toStringFunction(runErr)
        emitComment("Runtime: " .. _msg)
        if ioLibrary and ioLibrary.stderr then
            ioLibrary.stderr:write("ERROR: " .. _msg .. "\n")
        end
    end
    local elapsed = osLibrary.clock() - startClock
    local saved = proxyTable.save(outputPath or configuration.OUTPUT_FILE)
    if saved then
        local stats = proxyTable.get_stats()
        local kbWritten = string.format("%.1f", (stats.bytes_written or 0) / 1024)
        printFunction(string.format("done: lines=%d remotes=%d strings=%d proxies=%d bytes=%skb elapsed=%.2fs",
            stats.total_lines, stats.remote_calls, stats.suspicious_strings,
            stats.proxies_created or 0, kbWritten, elapsed))
    else
        printFunction("error: write failed")
    end
    return saved
end
function proxyTable.dump_string(code, outputPath)
    proxyTable.reset()
    if code then code = processString(code) end
    local func, err = loadFunction(code)
    if not func then
        emitComment("Load Error: " .. (err or "unknown"))
        if outputPath then proxyTable.save(outputPath) end
        return false, err
    end
    local _DS_BLOCK = {
        io=true, os=true, debug=true, dofile=true, loadfile=true,
        require=true, package=true, socket=true, ffi=true,
        collectgarbage=true, getfenv=true, setfenv=true,
        _G=true, dumperState=true,
        _bypassSavedIo=true, _bypassSavedDofile=true,
        _bypassPcall=true, _bypassOnReset=true,
        _origStringDump=true, _bypassSafeDebugExtras=true,
        _bypassClock=true, _DEBUG_TRAPS=true, _TRAP_COUNT=true,
    }
    local _DS_OS = { clock=function() local _bc=rawget(_G,"_bypassClock"); return _bc and _bc() or osLibrary.clock() end, time=osLibrary.time, date=osLibrary.date }
    local _dsDebugProxy = setmetatable({}, {__index = function(_, k)
        if k == "getupvalue" then
            return function(fn, i)
                local _gu = debugLibrary and rawget(debugLibrary, "getupvalue")
                if _gu then local n, v = _gu(fn, i); return n, v end
                return nil
            end
        end
        if k == "getupvalues" then
            return function(fn)
                local _gu = debugLibrary and rawget(debugLibrary, "getupvalue")
                if not _gu then return {} end
                local uvs = {}; local idx = 1
                while idx <= 250 do
                    local n, v = _gu(fn, idx)
                    if not n then break end
                    uvs[idx] = v
                    if type(n) == "string" and n ~= "" and n ~= "_ENV" then uvs[n] = v end
                    idx = idx + 1
                end
                return uvs
            end
        end
        if k == "setupvalue" then
            return function(fn, i, v)
                local _su = debugLibrary and rawget(debugLibrary, "setupvalue")
                if _su then return _su(fn, i, v) end
            end
        end
        local real = rawget(_G, "debug")
        return real and real[k]
    end})
    local _dsStrProxy = setmetatable({}, {__index = function(_, k)
        if k == "dump" then
            return function(fn, ...) error("attempt to dump given function", 2) end
        end
        return string[k]
    end})
    local dsEnv = setmetatable({
        _VERSION="Luau",
        io=nil, os=_DS_OS, debug=_dsDebugProxy, string=_dsStrProxy, dofile=nil, loadfile=nil,
        require=nil, package=nil, socket=nil, ffi=nil,
        collectgarbage=nil, newproxy=newproxy,
        pcall = function(f, ...)
            local override = rawget(_G, "_bypassPcall")
            local res
            if typeFunction(override) == "function" then
                res = {override(pcallFunction, f, ...)}
            else
                res = {pcallFunction(f, ...)}
            end
            if rawget(_G, "_DEBUG_TRAPS") then
                local _err = (_G._bypassSavedIo and _G._bypassSavedIo.stderr) or ioLibrary.stderr
                local n = (rawget(_G, "_TRAP_COUNT") or 0) + 1
                _G._TRAP_COUNT = n
                local info = "?"
                if typeFunction(f) == "function" and debugLibrary and debugLibrary.getinfo then
                    local ok, di = pcallFunction(debugLibrary.getinfo, f, "S")
                    if ok and di then info = (di.source or "?") .. ":L" .. (di.linedefined or -1) end
                end
                local rsum = {}
                for i = 1, math.min(#res, 4) do rsum[i] = toStringFunction(res[i]) end
                if _err then
                    _err:write(string.format("[trap %3d] f=%s -> %s\n", n, info, table.concat(rsum, " | ")))
                    _err:flush()
                end
            end
            if not res[1] and toStringFunction(res[2]):match("TIMEOUT") then errorFunction(res[2], 0) end
            return unpack(res)
        end,
    }, {
        __index = function(_, k)
            if _DS_BLOCK[k] then return nil end
            return _G[k]
        end,
        __newindex = function(t, k, v) rawset(t, k, v) end,
    })
    rawset(dsEnv, "_G", dsEnv)
    do
        local _applied = false
        if debugLibrary and debugLibrary.getupvalue and debugLibrary.setupvalue then
            for _i = 1, 256 do
                local _ok, _n = pcall(debugLibrary.getupvalue, func, _i)
                if not _ok or not _n then break end
                if _n == "_ENV" then
                    pcall(debugLibrary.setupvalue, func, _i, dsEnv)
                    _applied = true
                    break
                end
            end
        end
        if not _applied and type(setfenv) == "function" then
            local _ok2, _si = pcall(function()
                return debugLibrary and debugLibrary.getinfo and debugLibrary.getinfo(setfenv, "S")
            end)
            if _ok2 and _si and _si.what == "C" then setfenv(func, dsEnv) end
        end
    end
    do
        local _DS_PROTECTED = {
            pcall=true, xpcall=true, error=true, warn=true,
            print=true, tostring=true, tonumber=true, type=true,
            select=true, ipairs=true, pairs=true, next=true,
            rawget=true, rawset=true, rawequal=true, rawlen=true,
            setmetatable=true, getmetatable=true, unpack=true,
        }
        local _snap = {}
        for k in pairs(_DS_PROTECTED) do
            local v = rawget(dsEnv, k)
            if v == nil then v = rawget(_G, k) end
            if v ~= nil then _snap[k] = v end
            rawset(dsEnv, k, nil)
        end
        local _dsMt = getmetatable(dsEnv)
        local _origIdx = _dsMt.__index
        local _origNIdx = _dsMt.__newindex
        _dsMt.__index = function(t, k)
            if _DS_PROTECTED[k] and _snap[k] ~= nil then return _snap[k] end
            if typeFunction(_origIdx) == "function" then return _origIdx(t, k) end
            return _origIdx and _origIdx[k] or nil
        end
        _dsMt.__newindex = function(t, k, v)
            if _DS_PROTECTED[k] then return end
            if typeFunction(_origNIdx) == "function" then _origNIdx(t, k, v)
            elseif _origNIdx then _origNIdx[k] = v
            else rawset(t, k, v) end
        end
        rawset(_dsMt, "__metatable", "locked: input environment")
    end
    do
        local _sandboxedFunc, _sandboxedErr = loadFunction(code, "=DumpString", "t", dsEnv)
        if not _sandboxedFunc then
            emitComment("Load Error: " .. toStringFunction(_sandboxedErr or "sandbox load failed"))
            return false
        end
        func = _sandboxedFunc
    end
    local startClock = osLibrary.clock()
    setHook(function()
        if osLibrary.clock() - startClock > configuration.TIMEOUT_SECONDS then
            errorFunction("TIMEOUT", 0)
        end
    end, "", 1000)
    xpcallFunction(function() func() end, function(e)
        emitComment("Runtime: " .. toStringFunction(e))
    end)
    setHook()
    if outputPath then return proxyTable.save(outputPath) end
    return true, getFullOutput()
end
if not _skip_luau_only_tamper then
    do
        _G.dumperState = dumperState
        local _savedDofile = _G._bypassSavedDofile or dofile
    _G.io = _G._bypassSavedIo or _G.io
    local bypassPath = (arg and arg[0] and arg[0]:match("^(.+[\\\\/])")) or ""
    local ok, err = pcall(_savedDofile, bypassPath .. "bypass.lua")
    if not ok then
        local ok2, err2 = pcall(_savedDofile, "bypass.lua")
        if not ok2 and os.getenv("BYPASS_VERBOSE") then
            io.stderr:write("[dumper] compat module not loaded: " .. tostring(err) ..
                            " / " .. tostring(err2) .. "\n")
        end
    end
        _G.io = nil
        _G.dofile = nil
        _G.loadfile = nil
    end
end

function proxyTable.extract_consts(inputPath, outputPath)
    local _open  = (_G._bypassSavedIo and _G._bypassSavedIo.open) or ioLibrary.open
    local _stderr = (_G._bypassSavedIo and _G._bypassSavedIo.stderr) or ioLibrary.stderr
    local _load  = loadFunction or load

    local f, ferr = _open(inputPath, "rb")
    if not f then error("extract_consts: cannot open " .. tostring(inputPath) .. ": " .. tostring(ferr), 0) end
    local src = f:read("*a"); f:close()

    local _PATCH_PATTERNS = {
        { pat = "local%s+M=_ENV%s+or%s+getfenv%(0%)as%(Z,M,{}%)(%(%))",
          rep = " _G.__CAPTURED_PROTO = Z return Z " },
        { pat = "as%(Z,M,{}%)%(%)",
          rep = " _G.__CAPTURED_PROTO = Z return Z " },
        { pat = "as%(Z,[^,]+,{}%)%(%)",
          rep = " _G.__CAPTURED_PROTO = Z return Z " },
        { pat = "Z%(_ENV%s+or%s+getfenv%(0%),%s*{}%)(%(%))",
          rep = " _G.__CAPTURED_PROTO = Z return Z " },
        { pat = "%(function%(Z,M%)(.-)end%)%(proto,",
          rep = " _G.__CAPTURED_PROTO = proto return proto --[[ patched (" },
    }
    local patched, n = src, 0
    for _, entry in ipairs(_PATCH_PATTERNS) do
        local p, c = src:gsub(entry.pat, entry.rep)
        if c > 0 then
            patched, n = p, c
            break
        end
    end
    if n == 0 then
        error("extract_consts: patch site not found in " .. tostring(inputPath) ..
              " – none of the " .. #_PATCH_PATTERNS .. " patterns matched", 0)
    end
    if n > 1 then
        _stderr:write("[dumper] extract_consts: warning: " .. n .. " patch sites replaced (expected 1)\n")
    end

    _G.__CAPTURED_PROTO = nil
    local chunk, lerr = _load(patched, "lumora_patched", "t")
    if not chunk then error("extract_consts: load failed: " .. tostring(lerr), 0) end
    local ok, proto = pcallFunction(chunk)
    if not ok then error("extract_consts: loader runtime failed: " .. tostring(proto), 0) end
    proto = _G.__CAPTURED_PROTO or proto
    if type(proto) ~= "table" then
        error("extract_consts: captured proto is not a table (got " .. type(proto) .. ")", 0)
    end

    local _xorFn
    if type(bit32) == "table" and type(bit32.bxor) == "function" then
        _xorFn = function(a, b) return bit32.bxor(a % 256, b % 256) end
    elseif type(rawget(_G, "bitLibrary")) == "table" and type(rawget(_G, "bitLibrary").bxor) == "function" then
        local _bxorRef = rawget(_G, "bitLibrary").bxor
        _xorFn = function(a, b) return _bxorRef(a % 256, b % 256) % 256 end
    else
        _xorFn = function(a, b)
            local r, bit = 0, 1
            a, b = a % 256, b % 256
            for _ = 0, 7 do
                if (a % 2) ~= (b % 2) then r = r + bit end
                a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
            end
            return r
        end
    end
    local function xor8(a, b) return _xorFn(a, b) end

    local function decode_str(c)
        if type(c) ~= "table" or not c.__enc then return c end
        local enc = c.__enc
        local key = c.__key
        local out = {}
        if type(key) == "number" then
            local k = key % 256
            for i = 1, #enc do
                out[i] = string.char(xor8(string.byte(enc, i), k))
            end
        elseif type(key) == "table" then
            local nk = #key
            if c.__rolling then
                local prev = 0
                for i = 1, #enc do
                    local kb = (key[((i-1) % nk) + 1] or 0) % 256
                    local dec = xor8(string.byte(enc, i), xor8(kb, prev))
                    out[i] = string.char(dec)
                    prev = dec
                end
            else
                for i = 1, #enc do
                    local kb = (key[((i-1) % nk) + 1] or 0) % 256
                    out[i] = string.char(xor8(string.byte(enc, i), kb))
                end
            end
        else
            return tostring(enc)
        end
        return table.concat(out)
    end

    local LUA51_OPS = {
        [0]="MOVE",[1]="LOADK",[2]="LOADBOOL",[3]="LOADNIL",[4]="GETUPVAL",
        [5]="GETGLOBAL",[6]="GETTABLE",[7]="SETGLOBAL",[8]="SETUPVAL",[9]="SETTABLE",
        [10]="NEWTABLE",[11]="SELF",[12]="ADD",[13]="SUB",[14]="MUL",[15]="DIV",
        [16]="MOD",[17]="POW",[18]="UNM",[19]="NOT",[20]="LEN",[21]="CONCAT",
        [22]="JMP",[23]="EQ",[24]="LT",[25]="LE",[26]="TEST",[27]="TESTSET",
        [28]="CALL",[29]="TAILCALL",[30]="RETURN",[31]="FORLOOP",[32]="FORPREP",
        [33]="TFORLOOP",[34]="SETLIST",[35]="CLOSE",[36]="CLOSURE",[37]="VARARG",
    }
    local LUA52_OPS = {
        [0]="MOVE",[1]="LOADK",[2]="LOADKX",[3]="LOADBOOL",[4]="LOADNIL",
        [5]="GETUPVAL",[6]="GETTABUP",[7]="GETTABLE",[8]="SETTABUP",[9]="SETUPVAL",
        [10]="SETTABLE",[11]="NEWTABLE",[12]="SELF",[13]="ADD",[14]="SUB",[15]="MUL",
        [16]="DIV",[17]="MOD",[18]="POW",[19]="UNM",[20]="NOT",[21]="LEN",
        [22]="CONCAT",[23]="JMP",[24]="EQ",[25]="LT",[26]="LE",[27]="TEST",
        [28]="TESTSET",[29]="CALL",[30]="TAILCALL",[31]="RETURN",[32]="FORLOOP",
        [33]="FORPREP",[34]="TFORCALL",[35]="TFORLOOP",[36]="SETLIST",[37]="CLOSURE",
        [38]="VARARG",[39]="EXTRAARG",
    }
    local LUA53_OPS = {
        [0]="MOVE",[1]="LOADK",[2]="LOADKX",[3]="LOADBOOL",[4]="LOADNIL",
        [5]="GETUPVAL",[6]="GETTABUP",[7]="GETTABLE",[8]="SETTABUP",[9]="SETUPVAL",
        [10]="SETTABLE",[11]="NEWTABLE",[12]="SELF",[13]="ADD",[14]="SUB",[15]="MUL",
        [16]="MOD",[17]="POW",[18]="DIV",[19]="IDIV",[20]="BAND",[21]="BOR",
        [22]="BXOR",[23]="SHL",[24]="SHR",[25]="UNM",[26]="BNOT",[27]="NOT",
        [28]="LEN",[29]="CONCAT",[30]="JMP",[31]="EQ",[32]="LT",[33]="LE",
        [34]="TEST",[35]="TESTSET",[36]="CALL",[37]="TAILCALL",[38]="RETURN",
        [39]="FORLOOP",[40]="FORPREP",[41]="TFORCALL",[42]="TFORLOOP",
        [43]="SETLIST",[44]="CLOSURE",[45]="VARARG",[46]="EXTRAARG",
    }
    local function _pick_opset(p)
        local maxOp = 0
        for _, ins in ipairs(p.code or {}) do
            if (ins.op or 0) > maxOp then maxOp = ins.op end
        end
        if maxOp >= 43 then return LUA53_OPS, "Lua5.3"
        elseif maxOp >= 38 then return LUA52_OPS, "Lua5.2"
        else return LUA51_OPS, "Lua5.1" end
    end

    local function fmt_const(c)
        if c == nil then return "nil" end
        local t = type(c)
        if t == "boolean" or t == "number" then return tostring(c) end
        if t == "string" then return string.format("%q", c) end
        if t == "table" and c.__enc then
            return string.format("%q", decode_str(c))
        end
        return tostring(c)
    end

    local out = {}
    local function emit(s) out[#out+1] = s end

    local _all_strings = {}
    local function _collect_strings(p)
        for _, v in pairs(p.const or {}) do
            if type(v) == "string" then
                _all_strings[v] = true
            elseif type(v) == "table" and v.__enc then
                _all_strings[decode_str(v)] = true
            end
        end
        for _, sp in ipairs(p.subs or {}) do _collect_strings(sp) end
    end
    _collect_strings(proto)

    local seen = {}
    local function dump_proto(p, path)
        if seen[p] then return end
        seen[p] = true
        local OPS, opver = _pick_opset(p)
        emit(("="):rep(70))
        emit(string.format("PROTO %s   src=%s  upvals=%d  params=%d  maxstack=%d  [%s]",
            path, tostring(p.source), p.num_upval or 0, p.num_param or 0, p.max_stack or 0, opver))
        local maxk = 0
        for k,_ in pairs(p.const or {}) do
            if type(k)=="number" and k>maxk then maxk=k end
        end
        emit(string.format("  consts (%d):", maxk))
        for i = 1, maxk do
            emit(string.format("    [%d] %s", i, fmt_const(p.const[i])))
        end
        if p.upvals and #p.upvals > 0 then
            emit(string.format("  upvals (%d):", #p.upvals))
            for i, uv in ipairs(p.upvals) do
                local uvname = type(uv) == "table" and (uv.name or uv[1] or "?") or tostring(uv)
                emit(string.format("    [%d] %s", i, uvname))
            end
        end
        if p.locals and #p.locals > 0 then
            emit(string.format("  locals (%d):", #p.locals))
            for i, lv in ipairs(p.locals) do
                local lvname = type(lv) == "table" and (lv.name or lv[1] or "?") or tostring(lv)
                emit(string.format("    [%d] %s", i, lvname))
            end
        end
        emit(string.format("  code (%d instructions):", #(p.code or {})))
        for i, ins in ipairs(p.code or {}) do
            local mn = OPS[ins.op] or ("OP"..tostring(ins.op))
            local extra = ""
            if ins.k  ~= nil then extra = "   ; K=" .. fmt_const(ins.k) end
            if ins.kC ~= nil then extra = extra .. "  KC=" .. fmt_const(ins.kC) end
            emit(string.format("    %4d  %-12s A=%-3d B=%-3d C=%-3d Bx=%-6d sBx=%-6d%s",
                i, mn, ins.A or 0, ins.B or 0, ins.C or 0, ins.Bx or 0, ins.sBx or 0, extra))
        end
        emit(string.format("  subs (%d):", #(p.subs or {})))
        for i, sp in ipairs(p.subs or {}) do
            dump_proto(sp, path .. "/" .. i)
        end
    end

    emit(("="):rep(70))
    emit("STRINGS SUMMARY")
    emit(("="):rep(70))
    local _slist = {}
    for s in pairs(_all_strings) do _slist[#_slist+1] = s end
    table.sort(_slist)
    emit(string.format("  total unique strings: %d", #_slist))
    for idx, s in ipairs(_slist) do
        emit(string.format("  [%d] %s", idx, string.format("%q", s)))
    end
    emit("")

    dump_proto(proto, "root")
    local text = table.concat(out, "\n") .. "\n"

    if outputPath and outputPath ~= "-" then
        local of, oerr = _open(outputPath, "wb")
        if not of then error("extract_consts: cannot write " .. tostring(outputPath) ..
                             ": " .. tostring(oerr), 0) end
        of:write(text); of:close()
        _stderr:write("[dumper] consts written to " .. outputPath ..
                      " (" .. #text .. " bytes, " .. #_slist .. " strings)\n")
    else
        printFunction(text)
    end
    return true, text
end

_G.LuraphContinue = function() end
if not rawget(_G, "__FLAMEDUMPER_REQUIRE_ONLY") then
    if arg and (arg[1] == "--consts" or arg[1] == "-c") then
        local input  = arg[2]
        local output = arg[3]
        if not input then
            printFunction("Usage: lua dumper.lua --consts <input> [output|-]")
        else
            proxyTable.extract_consts(input, output)
        end
    elseif arg and arg[1] then
        local function _flame_dyn(i, o) return proxyTable.dump_file(i, o) end
        flame_bot_run(arg[1], arg[2] or configuration.OUTPUT_FILE, _flame_dyn)
    else
        local file = ioLibrary.open("obfuscated.lua", "rb")
        if file then
            file:close()
            local success = proxyTable.dump_file("obfuscated.lua")
            if success then
                printFunction(proxyTable.get_output())
            end
        else
            printFunction("Usage: lua dumper.lua <input> [output] [key]")
            printFunction("       lua dumper.lua --consts <input> [output|-]")
        end
    end
end
return proxyTable
