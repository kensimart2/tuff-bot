import re
import sys
import subprocess
import time
import os
import tempfile
import glob

from lua_runtime import lua_command as _lua_command, lua_available as _lua_available


def looks_like_supported_trace_input(content):
    return bool(re.search(r'\blocal\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*\{\s*(?:"|\'|\[\[|\[=*\[)', content or ""))


def deobfuscate_file(filepath):
    print("Processing script...")

    if ".deobf." in filepath or ".report." in filepath:
        return

    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
    except Exception as e:
        raise RuntimeError(f"Error reading script: {e}")

    match = re.search(r'\blocal\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*\{\s*(?:"|\'|\[\[|\[=*\[)', content)
    if not match:
        print("Trace fallback skipped: unsupported legacy string-table format.")
        return False
    var_name = match.group(1)

    mock_env_code = r"""
-- ============================================================
-- FlameDumperV1 - Enhanced Mock Environment
-- Full anti-tamper bypass: typeof, ClassName, IsA, MemStorage,
-- CollectionService, OverlapParams, timing, NaN, GetDebugId
-- ============================================================

local unpack = unpack or table.unpack
local _orig_getmetatable = getmetatable
local _orig_setmetatable = setmetatable
local _orig_rawequal = rawequal
local _orig_pairs = pairs
local _orig_ipairs = ipairs
local _orig_type = type
local _orig_tonumber = tonumber
local _orig_tostring = tostring
local _orig_print = print
local _orig_pcall = pcall
local _orig_xpcall = xpcall
local _orig_error = error
local _orig_next = next
local _orig_select = select
local _orig_unpack = unpack

local getfenv = getfenv or function(n)
    local f = debug.getinfo((n or 1) + 1, "f").func
    local t = {}
    local i = 0
    while true do
        i = i + 1
        local name, val = debug.getupvalue(f, i)
        if not name then break end
        t[name] = val
    end
    return _orig_setmetatable(t, {__index = _ENV or _G})
end

-- ============================================================
-- Typed dummy system: supports className, type overrides, IsA
-- ============================================================

local _dummy_id = 0

-- Inheritance map for IsA checks
local _ISA_PARENTS = {
    Instance = {"Instance"},
    AchievementService = {"AchievementService", "Instance"},
    PlayerViewService = {"PlayerViewService", "Instance"},
    AppLifecycleObserverService = {"AppLifecycleObserverService", "Instance"},
    LocalizationService = {"LocalizationService", "Instance"},
    HapticService = {"HapticService", "Instance"},
    Players = {"Players", "Instance"},
    MemStorageService = {"MemStorageService", "Instance"},
    CollectionService = {"CollectionService", "Instance"},
    SoundService = {"SoundService", "Instance"},
    CoreGui = {"CoreGui", "Instance"},
    ScreenGui = {"ScreenGui", "Instance"},
    Frame = {"Frame", "GuiObject", "GuiBase2d", "Instance"},
    TextLabel = {"TextLabel", "GuiObject", "GuiBase2d", "Instance"},
    AnimationClipProvider = {"AnimationClipProvider", "Instance"},
    MeshContentProvider = {"MeshContentProvider", "Instance"},
    StarterPlayer = {"StarterPlayer", "Instance"},
    AppUpdateService = {"AppUpdateService", "Instance"},
    TimerService = {"TimerService", "Instance"},
    CookiesService = {"CookiesService", "Instance"},
    HttpService = {"HttpService", "Instance"},
    AdService = {"AdService", "Instance"},
    CaptureService = {"CaptureService", "Instance"},
    ContextActionService = {"ContextActionService", "Instance"},
    LocalizationTable = {"LocalizationTable", "Instance"},
    Translator = {"Translator", "Instance"},
    RBXScriptConnection = {"RBXScriptConnection"},
    Part = {"Part", "BasePart", "Instance"},
    Workspace = {"Workspace", "WorldRoot", "Model", "Instance"},
    workspace = {"Workspace", "WorldRoot", "Model", "Instance"},
    game = {"DataModel", "Instance"},
}

-- MemStorageService real key-value store
local _MEMSTORAGE = {}

-- CollectionService real tag store: {tag -> {instance -> true}}
local _COLLECTION_TAGS = {}
local _COLLECTION_SIGNALS = {}

-- ContextActionService bound actions
local _BOUND_ACTIONS = {}

-- Unique debug IDs per instance
local _DEBUG_ID_MAP = {}
local _DEBUG_ID_COUNTER = 10000

local function _get_debug_id(inst)
    if not _DEBUG_ID_MAP[inst] then
        _DEBUG_ID_COUNTER = _DEBUG_ID_COUNTER + 1
        _DEBUG_ID_MAP[inst] = tostring(_DEBUG_ID_COUNTER) .. "-" .. tostring(_DEBUG_ID_COUNTER * 7 + 3)
    end
    return _DEBUG_ID_MAP[inst]
end

-- Forward declare create_dummy and create_typed_dummy
local create_dummy
local create_typed_dummy
local create_service

local function _is_mock(v)
    if _orig_type(v) ~= "table" then return false end
    local mt = _orig_getmetatable(v)
    return mt and mt.__is_mock_dummy == true
end

local function real_typeof(v)
    if _orig_type(v) ~= "table" then return _orig_type(v) end
    local mt = _orig_getmetatable(v)
    if not mt then return "table" end
    if mt.__mock_type then return mt.__mock_type end
    if mt.__is_mock_dummy then return "Instance" end
    return "table"
end

local function real_isa(inst, className)
    if not _is_mock(inst) then return false end
    local mt = _orig_getmetatable(inst)
    local cn = mt.__mock_classname or "Instance"
    local parents = _ISA_PARENTS[cn] or {"Instance"}
    for _, p in _orig_ipairs(parents) do
        if p == className then return true end
    end
    return false
end

local function real_type(v)
    local mt = _orig_getmetatable(v)
    if mt and mt.__is_mock_dummy then return "userdata" end
    return _orig_type(v)
end

local function real_tonumber(v, base)
    if _is_mock(v) then return 1 end
    return _orig_tonumber(v, base)
end

local function recursive_tostring(v, depth)
    depth = depth or 0
    if depth > 2 then return _orig_tostring(v) end
    if _orig_type(v) == "string" then
        return '"' .. v:gsub('"', '\\"') .. '"'
    elseif _orig_type(v) == "number" then
        if v == math.floor(v) and v >= -2147483648 and v <= 2147483647 then
            return _orig_tostring(math.floor(v))
        end
        return _orig_tostring(v)
    elseif _orig_type(v) == "boolean" then
        return _orig_tostring(v)
    elseif v == nil then
        return "nil"
    elseif _orig_type(v) == "table" then
        local mt = _orig_getmetatable(v)
        if mt and mt.__is_mock_dummy then return _orig_tostring(v) end
        local parts = {}
        local keys = {}
        for k in _orig_pairs(v) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return _orig_tostring(a) < _orig_tostring(b) end)
        for _, k in _orig_ipairs(keys) do
            local val = v[k]
            local k_str = _orig_tostring(k)
            if _orig_type(k) == "string" then k_str = '["' .. k .. '"]' end
            table.insert(parts, k_str .. " = " .. recursive_tostring(val, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif _orig_type(v) == "function" then
        return _orig_tostring(v)
    else
        return _orig_tostring(v)
    end
end

-- ============================================================
-- Core dummy factory
-- ============================================================

create_typed_dummy = function(typeName, className, extraProps)
    _dummy_id = _dummy_id + 1
    local id = _dummy_id
    local props = extraProps or {}
    local name = className or typeName or ("obj" .. id)

    local d = {}
    local mt = {
        __is_mock_dummy = true,
        __mock_type = typeName,       -- for typeof()
        __mock_classname = className, -- for ClassName / IsA()
        __mock_id = id,
        __index = function(self, k)
            -- ClassName
            if k == "ClassName" and className then
                return className
            end
            -- IsA
            if k == "IsA" then
                return function(_, cn)
                    return real_isa(self, cn)
                end
            end
            -- Connected (RBXScriptConnection)
            if k == "Connected" and className == "RBXScriptConnection" then
                return rawget(self, "_connected") ~= false
            end
            -- Parent
            if k == "Parent" then
                return rawget(self, "_parent") or create_service("game")
            end
            -- GetDebugId
            if k == "GetDebugId" then
                return function(_, depth)
                    return _get_debug_id(self)
                end
            end
            -- Check extra props
            if props[k] ~= nil then
                local pv = props[k]
                if _orig_type(pv) == "function" then
                    return function(...) return pv(...) end
                end
                return pv
            end
            -- Generic property / method
            _orig_print("ACCESSED --> " .. name .. "." .. k)
            return create_dummy(name .. "." .. k)
        end,
        __newindex = function(self, k, v)
            if k == "_connected" or k == "_parent" or k == "_raw" then
                rawset(self, k, v)
                return
            end
            local val_str = recursive_tostring(v, 0)
            _orig_print("PROP_SET --> " .. name .. "." .. k .. " = " .. val_str)
            rawset(self, k, v)
        end,
        __call = function(self, ...)
            local args = {...}
            local arg_parts = {}
            for _, v in _orig_ipairs(args) do
                table.insert(arg_parts, recursive_tostring(v))
            end
            local arg_str = table.concat(arg_parts, ", ")
            local safe_name = name:gsub("[^%w_]", "_")
            _dummy_id = _dummy_id + 1
            local vid = _dummy_id
            _orig_print("CALL_RESULT --> local " .. safe_name .. "_" .. vid .. " = " .. name .. "(" .. arg_str .. ")")

            for _, v in _orig_ipairs(args) do
                if _orig_type(v) == "function" then
                    _orig_print("--- ENTERING CLOSURE FOR " .. name .. " ---")
                    local ok, err = _orig_pcall(v,
                        create_dummy("arg1"), create_dummy("arg2"),
                        create_dummy("arg3"), create_dummy("arg4"))
                    if not ok then
                        _orig_print("-- CLOSURE ERROR: " .. _orig_tostring(err))
                    end
                    _orig_print("--- EXITING CLOSURE FOR " .. name .. " ---")
                end
            end
            return create_typed_dummy("Instance", className, props)
        end,
        __tostring = function() return name .. "#" .. id end,
        __concat = function(a, b) return _orig_tostring(a) .. _orig_tostring(b) end,
        __add = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "+" .. _orig_tostring(b) .. ")") end,
        __sub = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "-" .. _orig_tostring(b) .. ")") end,
        __mul = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "*" .. _orig_tostring(b) .. ")") end,
        __div = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "/" .. _orig_tostring(b) .. ")") end,
        __mod = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "%" .. _orig_tostring(b) .. ")") end,
        __pow = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "^" .. _orig_tostring(b) .. ")") end,
        __unm = function(a) return create_dummy("-" .. _orig_tostring(a)) end,
        __lt = function(a, b) return false end,
        __le = function(a, b) return true end,
        __eq = function(a, b) return _orig_rawequal(a, b) end,
        __len = function(a) return 2 end,
    }
    _orig_setmetatable(d, mt)
    return d
end

create_dummy = function(name)
    return create_typed_dummy("Instance", nil, nil)
end

-- Override create_dummy to use the name properly
local _orig_create_dummy = create_dummy
create_dummy = function(name)
    _dummy_id = _dummy_id + 1
    local id = _dummy_id
    local d = {}
    local mt = {
        __is_mock_dummy = true,
        __mock_type = "Instance",
        __mock_classname = nil,
        __mock_id = id,
        __index = function(self, k)
            if k == "ClassName" then
                return name:match("([^%.]+)$") or name
            end
            if k == "IsA" then
                return function(_, cn) return true end
            end
            if k == "Parent" then
                return rawget(self, "_parent") or create_service("game")
            end
            if k == "GetDebugId" then
                return function(_, depth) return _get_debug_id(self) end
            end
            if k == "HttpGet" or k == "HttpGetAsync" then
                return function(_, url, ...)
                    _orig_print("URL DETECTED --> " .. _orig_tostring(url))
                    return create_dummy("HttpGetResult")
                end
            end
            _orig_print("ACCESSED --> " .. name .. "." .. k)
            return create_dummy(name .. "." .. k)
        end,
        __newindex = function(self, k, v)
            if k == "_parent" or k == "_connected" then
                rawset(self, k, v)
                return
            end
            local val_str = recursive_tostring(v, 0)
            _orig_print("PROP_SET --> " .. name .. "." .. k .. " = " .. val_str)
            rawset(self, k, v)
        end,
        __call = function(self, ...)
            local args = {...}
            local arg_parts = {}
            for _, v in _orig_ipairs(args) do
                table.insert(arg_parts, recursive_tostring(v))
            end
            local arg_str = table.concat(arg_parts, ", ")
            local safe_name = name:gsub("[^%w_]", "_")
            _dummy_id = _dummy_id + 1
            local vid = _dummy_id
            _orig_print("CALL_RESULT --> local " .. safe_name .. "_" .. vid .. " = " .. name .. "(" .. arg_str .. ")")

            if name == "task.wait" or name == "wait" then
                -- no-op
            end

            for _, v in _orig_ipairs(args) do
                if _orig_type(v) == "function" then
                    _orig_print("--- ENTERING CLOSURE FOR " .. name .. " ---")
                    local ok, err = _orig_pcall(v,
                        create_dummy("arg1"), create_dummy("arg2"),
                        create_dummy("arg3"), create_dummy("arg4"))
                    if not ok then
                        _orig_print("-- CLOSURE ERROR: " .. _orig_tostring(err))
                    end
                    _orig_print("--- EXITING CLOSURE FOR " .. name .. " ---")
                end
            end
            return create_dummy(safe_name .. "_" .. vid)
        end,
        __tostring = function() return name end,
        __concat = function(a, b) return _orig_tostring(a) .. _orig_tostring(b) end,
        __add = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "+" .. _orig_tostring(b) .. ")") end,
        __sub = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "-" .. _orig_tostring(b) .. ")") end,
        __mul = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "*" .. _orig_tostring(b) .. ")") end,
        __div = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "/" .. _orig_tostring(b) .. ")") end,
        __mod = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "%" .. _orig_tostring(b) .. ")") end,
        __pow = function(a, b) return create_dummy("(" .. _orig_tostring(a) .. "^" .. _orig_tostring(b) .. ")") end,
        __unm = function(a) return create_dummy("-" .. _orig_tostring(a)) end,
        __lt = function(a, b) return false end,
        __le = function(a, b) return true end,
        __eq = function(a, b) return _orig_rawequal(a, b) end,
        __len = function(a) return 2 end,
    }
    _orig_setmetatable(d, mt)
    return d
end

-- ============================================================
-- RBXScriptConnection mock
-- ============================================================
local function create_connection()
    local conn = {}
    rawset(conn, "_connected", true)
    _orig_setmetatable(conn, {
        __is_mock_dummy = true,
        __mock_type = "RBXScriptConnection",
        __mock_classname = "RBXScriptConnection",
        __index = function(self, k)
            if k == "Connected" then return rawget(self, "_connected") end
            if k == "Disconnect" then
                return function(_)
                    rawset(self, "_connected", false)
                end
            end
            return create_dummy("RBXScriptConnection." .. k)
        end,
        __newindex = function(self, k, v) rawset(self, k, v) end,
        __tostring = function() return "RBXScriptConnection" end,
        __eq = function(a, b) return _orig_rawequal(a, b) end,
    })
    return conn
end

-- ============================================================
-- RBXScriptSignal mock
-- ============================================================
local function create_signal(name)
    local sig = {}
    _orig_setmetatable(sig, {
        __is_mock_dummy = true,
        __mock_type = "RBXScriptSignal",
        __mock_classname = "RBXScriptSignal",
        __index = function(self, k)
            if k == "Connect" then
                return function(_, callback)
                    _orig_print("--- ENTERING CLOSURE FOR " .. (name or "signal") .. " ---")
                    if _orig_type(callback) == "function" then
                        _orig_pcall(callback, create_dummy("signalArg1"))
                    end
                    _orig_print("--- EXITING CLOSURE FOR " .. (name or "signal") .. " ---")
                    return create_connection()
                end
            end
            if k == "Wait" then return function(_) return create_dummy("signalArg") end end
            if k == "Once" then
                return function(_, callback)
                    if _orig_type(callback) == "function" then
                        _orig_pcall(callback, create_dummy("signalArg1"))
                    end
                    return create_connection()
                end
            end
            return create_dummy((name or "Signal") .. "." .. k)
        end,
        __newindex = function(self, k, v) rawset(self, k, v) end,
        __tostring = function() return "Signal(" .. (name or "?") .. ")" end,
        __eq = function(a, b) return _orig_rawequal(a, b) end,
    })
    return sig
end

-- ============================================================
-- OverlapParams mock
-- ============================================================
local function create_overlap_params()
    local op = {
        MaxParts = 0,
        FilterType = nil,     -- filled below
        FilterDescendantsInstances = {},
    }
    -- We'll make FilterType look like Enum.RaycastFilterType.Exclude
    local enum_exclude = create_dummy("Enum.RaycastFilterType.Exclude")
    op.FilterType = enum_exclude
    _orig_setmetatable(op, {
        __is_mock_dummy = true,
        __mock_type = "OverlapParams",
        __mock_classname = "OverlapParams",
        __index = function(self, k)
            local rv = rawget(self, k)
            if rv ~= nil then return rv end
            return create_dummy("OverlapParams." .. k)
        end,
        __newindex = function(self, k, v)
            rawset(self, k, v)
        end,
        __tostring = function() return "OverlapParams" end,
        __eq = function(a, b) return _orig_rawequal(a, b) end,
    })
    return op
end

-- ============================================================
-- Service factory -- returns realistic service mocks
-- ============================================================

local _SINGLETON_SERVICES = {}

create_service = function(serviceName)
    if _SINGLETON_SERVICES[serviceName] then
        return _SINGLETON_SERVICES[serviceName]
    end

    local svc

    -- MemStorageService
    if serviceName == "MemStorageService" then
        svc = {}
        _orig_setmetatable(svc, {
            __is_mock_dummy = true,
            __mock_type = "Instance",
            __mock_classname = "MemStorageService",
            __index = function(self, k)
                if k == "ClassName" then return "MemStorageService" end
                if k == "IsA" then return function(_, cn) return cn == "MemStorageService" or cn == "Instance" end end
                if k == "SetItem" then
                    return function(_, key, value)
                        _MEMSTORAGE[_orig_tostring(key)] = _orig_tostring(value)
                    end
                end
                if k == "GetItem" then
                    return function(_, key)
                        return _MEMSTORAGE[_orig_tostring(key)]
                    end
                end
                if k == "RemoveItem" then
                    return function(_, key)
                        _MEMSTORAGE[_orig_tostring(key)] = nil
                    end
                end
                return create_dummy("MemStorageService." .. k)
            end,
            __newindex = function(self, k, v) rawset(self, k, v) end,
            __tostring = function() return "MemStorageService" end,
            __eq = function(a, b) return _orig_rawequal(a, b) end,
        })

    -- CollectionService
    elseif serviceName == "CollectionService" then
        svc = {}
        _orig_setmetatable(svc, {
            __is_mock_dummy = true,
            __mock_type = "Instance",
            __mock_classname = "CollectionService",
            __index = function(self, k)
                if k == "ClassName" then return "CollectionService" end
                if k == "IsA" then return function(_, cn) return cn == "CollectionService" or cn == "Instance" end end
                if k == "AddTag" then
                    return function(_, inst, tag)
                        tag = _orig_tostring(tag)
                        if not _COLLECTION_TAGS[tag] then _COLLECTION_TAGS[tag] = {} end
                        _COLLECTION_TAGS[tag][inst] = true
                    end
                end
                if k == "RemoveTag" then
                    return function(_, inst, tag)
                        tag = _orig_tostring(tag)
                        if _COLLECTION_TAGS[tag] then
                            _COLLECTION_TAGS[tag][inst] = nil
                        end
                    end
                end
                if k == "GetTagged" then
                    return function(_, tag)
                        tag = _orig_tostring(tag)
                        local result = {}
                        if _COLLECTION_TAGS[tag] then
                            for inst, _ in _orig_pairs(_COLLECTION_TAGS[tag]) do
                                table.insert(result, inst)
                            end
                        end
                        return result
                    end
                end
                if k == "HasTag" then
                    return function(_, inst, tag)
                        tag = _orig_tostring(tag)
                        return _COLLECTION_TAGS[tag] and _COLLECTION_TAGS[tag][inst] == true
                    end
                end
                if k == "GetInstanceAddedSignal" then
                    return function(_, tag)
                        tag = _orig_tostring(tag)
                        if not _COLLECTION_SIGNALS[tag] then
                            _COLLECTION_SIGNALS[tag] = create_signal("CollectionService.Added:" .. tag)
                        end
                        return _COLLECTION_SIGNALS[tag]
                    end
                end
                if k == "GetInstanceRemovedSignal" then
                    return function(_, tag)
                        return create_signal("CollectionService.Removed:" .. tag)
                    end
                end
                return create_dummy("CollectionService." .. k)
            end,
            __newindex = function(self, k, v) rawset(self, k, v) end,
            __tostring = function() return "CollectionService" end,
            __eq = function(a, b) return _orig_rawequal(a, b) end,
        })

    -- HttpService
    elseif serviceName == "HttpService" then
        svc = {}
        _orig_setmetatable(svc, {
            __is_mock_dummy = true,
            __mock_type = "Instance",
            __mock_classname = "HttpService",
            __index = function(self, k)
                if k == "ClassName" then return "HttpService" end
                if k == "IsA" then return function(_, cn) return cn == "HttpService" or cn == "Instance" end end
                if k == "JSONEncode" then
                    return function(_, t)
                        -- Simple JSON encoder
                        local function encode(v, depth)
                            depth = depth or 0
                            if _orig_type(v) == "string" then
                                return '"' .. v:gsub('"', '\\"') .. '"'
                            elseif _orig_type(v) == "number" then
                                return _orig_tostring(v)
                            elseif _orig_type(v) == "boolean" then
                                return _orig_tostring(v)
                            elseif _orig_type(v) == "table" and depth < 5 then
                                local parts = {}
                                -- Check if array
                                local is_array = true
                                local max_n = 0
                                for kk, _ in _orig_pairs(v) do
                                    if _orig_type(kk) ~= "number" then is_array = false break end
                                    if kk > max_n then max_n = kk end
                                end
                                if is_array and max_n == #v then
                                    for _, vv in _orig_ipairs(v) do
                                        table.insert(parts, encode(vv, depth + 1))
                                    end
                                    return "[" .. table.concat(parts, ",") .. "]"
                                else
                                    for kk, vv in _orig_pairs(v) do
                                        table.insert(parts, '"' .. _orig_tostring(kk) .. '":' .. encode(vv, depth + 1))
                                    end
                                    return "{" .. table.concat(parts, ",") .. "}"
                                end
                            end
                            return "null"
                        end
                        return encode(t)
                    end
                end
                if k == "JSONDecode" then
                    return function(_, s)
                        -- Minimal JSON decoder for simple objects
                        local ok, result = _orig_pcall(function()
                            -- Use pattern matching for simple cases
                            local t = {}
                            -- Try to extract key:value pairs
                            for key, val in s:gmatch('"([^"]+)":(%S+),?') do
                                local n = _orig_tonumber(val)
                                if n then
                                    t[key] = n
                                elseif val == "true" then
                                    t[key] = true
                                elseif val == "false" then
                                    t[key] = false
                                else
                                    t[key] = val:gsub('"', '')
                                end
                            end
                            -- nested
                            for key, inner in s:gmatch('"([^"]+)":{([^}]+)}') do
                                t[key] = {}
                                for k2, v2 in inner:gmatch('"([^"]+)":(%S+),?') do
                                    local n2 = _orig_tonumber(v2)
                                    if n2 then t[key][k2] = n2
                                    else t[key][k2] = v2:gsub('"', '') end
                                end
                            end
                            return t
                        end)
                        if ok then return result end
                        return {}
                    end
                end
                if k == "HttpGet" or k == "HttpGetAsync" then
                    return function(_, url, ...)
                        _orig_print("URL DETECTED --> " .. _orig_tostring(url))
                        return ""
                    end
                end
                return create_dummy("HttpService." .. k)
            end,
            __newindex = function(self, k, v) rawset(self, k, v) end,
            __tostring = function() return "HttpService" end,
            __eq = function(a, b) return _orig_rawequal(a, b) end,
        })

    -- LocalizationService
    elseif serviceName == "LocalizationService" then
        svc = {}
        _orig_setmetatable(svc, {
            __is_mock_dummy = true,
            __mock_type = "Instance",
            __mock_classname = "LocalizationService",
            __index = function(self, k)
                if k == "ClassName" then return "LocalizationService" end
                if k == "IsA" then return function(_, cn) return cn == "LocalizationService" or cn == "Instance" end end
                if k == "RobloxLocaleId" then return "en-us" end
                if k == "SystemLocaleId" then return "en-us" end
                if k == "GetCorescriptLocalizations" then
                    return function(_)
                        return { create_typed_dummy("Instance", "LocalizationTable") }
                    end
                end
                if k == "GetTranslatorForLocaleAsync" then
                    return function(_, locale)
                        local translator = create_typed_dummy("Instance", "Translator")
                        -- Attach LocaleId property
                        rawset(translator, "_localeId", _orig_tostring(locale or "en-us"))
                        return translator
                    end
                end
                return create_dummy("LocalizationService." .. k)
            end,
            __newindex = function(self, k, v)
                rawset(self, k, v)
            end,
            __tostring = function() return "LocalizationService" end,
            __eq = function(a, b) return _orig_rawequal(a, b) end,
        })

    -- Players
    elseif serviceName == "Players" then
        local localPlayer = create_typed_dummy("Instance", "Player")
        rawset(localPlayer, "_userId", 12345)
        local players_svc = {}
        _orig_setmetatable(players_svc, {
            __is_mock_dummy = true,
            __mock_type = "Instance",
            __mock_classname = "Players",
            __index = function(self, k)
                if k == "ClassName" then return "Players" end
                if k == "IsA" then return function(_, cn) return cn == "Players" or cn == "Instance" end end
                if k == "LocalPlayer" then return localPlayer end
                if k == "GetPlayers" then return function(_) return {localPlayer} end end
                if k == "GetCharacterAppearanceInfoAsync" then
                    return function(_, userId)
                        return {
                            assets = { {id = 1, assetType = {name = "Hat"}} },
                            bodyColors = { headColorId = 1, torsoColorId = 1 },
                            defaultPantsApplied = false,
                            defaultShirtApplied = false,
                            emotes = {},
                            playerAvatarType = "R15",
                            scales = {},
                        }
                    end
                end
                if k == "GetHumanoidDescriptionFromUserId" then
                    return function(_, userId)
                        local desc = create_typed_dummy("Instance", "HumanoidDescription")
                        rawset(desc, "_emotes", {Walk = {{animationId = 1}}})
                        return desc
                    end
                end
                if k == "GetDebugId" then
                    return function(_, depth) return _get_debug_id(self) end
                end
                _orig_print("ACCESSED --> Players." .. k)
                return create_dummy("Players." .. k)
            end,
            __newindex = function(self, k, v) rawset(self, k, v) end,
            __tostring = function() return "Players" end,
            __eq = function(a, b) return _orig_rawequal(a, b) end,
        })
        svc = players_svc

    -- HapticService
    elseif serviceName == "HapticService" then
        svc = create_typed_dummy("Instance", "HapticService", {
            IsVibrationSupported = function(_, inputType) return false end,
            IsMotorSupported = function(_, inputType, motor) return false end,
            SetMotor = function(...) end,
        })

    -- SoundService
    elseif serviceName == "SoundService" then
        svc = create_typed_dummy("Instance", "SoundService", {
            DistanceFactor = 3.33,
            DopplerScale = 1.0,
            RolloffScale = 1.0,
            AmbientReverb = 0,
        })

    -- ContextActionService
    elseif serviceName == "ContextActionService" then
        local cas = {}
        _orig_setmetatable(cas, {
            __is_mock_dummy = true,
            __mock_type = "Instance",
            __mock_classname = "ContextActionService",
            __index = function(self, k)
                if k == "ClassName" then return "ContextActionService" end
                if k == "IsA" then return function(_, cn) return cn == "ContextActionService" or cn == "Instance" end end
                if k == "BindAction" then
                    return function(_, actionName, callback, createTouchButton, ...)
                        local keys = {...}
                        _BOUND_ACTIONS[_orig_tostring(actionName)] = {
                            inputTypes = keys,
                            callbackName = actionName,
                            createTouchButton = createTouchButton,
                        }
                    end
                end
                if k == "UnbindAction" then
                    return function(_, actionName)
                        _BOUND_ACTIONS[_orig_tostring(actionName)] = nil
                    end
                end
                if k == "GetAllBoundActionInfo" then
                    return function(_)
                        return _BOUND_ACTIONS
                    end
                end
                return create_dummy("ContextActionService." .. k)
            end,
            __newindex = function(self, k, v) rawset(self, k, v) end,
            __tostring = function() return "ContextActionService" end,
            __eq = function(a, b) return _orig_rawequal(a, b) end,
        })
        svc = cas

    -- CaptureService
    elseif serviceName == "CaptureService" then
        svc = create_typed_dummy("Instance", "CaptureService", {
            CaptureBegan = nil, -- filled below
        })
        -- Attach signal properties
        local capBeganSignal = create_signal("CaptureService.CaptureBegan")
        local capEndedSignal = create_signal("CaptureService.CaptureEnded")
        rawset(svc, "_captureBegan", capBeganSignal)
        rawset(svc, "_captureEnded", capEndedSignal)
        local svc_mt = _orig_getmetatable(svc)
        local old_index = svc_mt.__index
        svc_mt.__index = function(self, k)
            if k == "CaptureBegan" then return rawget(self, "_captureBegan") end
            if k == "CaptureEnded" then return rawget(self, "_captureEnded") end
            return old_index(self, k)
        end

    -- CoreGui / workspace / game
    elseif serviceName == "CoreGui" or serviceName == "game" or serviceName == "workspace" then
        local label = serviceName
        svc = {}
        _orig_setmetatable(svc, {
            __is_mock_dummy = true,
            __mock_type = "Instance",
            __mock_classname = serviceName == "game" and "DataModel" or serviceName,
            __index = function(self, k)
                if k == "ClassName" then return (serviceName == "game" and "DataModel" or serviceName) end
                if k == "IsA" then
                    return function(_, cn)
                        local parents = _ISA_PARENTS[serviceName] or {"Instance"}
                        for _, p in _orig_ipairs(parents) do if p == cn then return true end end
                        return false
                    end
                end
                if k == "GetService" then
                    return function(_, name)
                        _orig_print("ACCESSED --> game.GetService")
                        -- Reject DebuggerManager (anti-tamper expects this to fail)
                        if name == "DebuggerManager" then
                            _orig_error("DebuggerManager is not accessible")
                        end
                        return create_service(name)
                    end
                end
                if k == "GetDebugId" then
                    return function(_, depth) return _get_debug_id(self) end
                end
                if k == "Players" then return create_service("Players") end
                if k == "WaitForChild" then
                    return function(_, childName, timeout)
                        return create_typed_dummy("Instance", childName)
                    end
                end
                if k == "FindFirstChild" then
                    return function(_, childName)
                        return create_typed_dummy("Instance", childName)
                    end
                end
                if k == "GetChildren" then
                    return function(_) return {} end
                end
                _orig_print("ACCESSED --> " .. label .. "." .. k)
                return create_dummy(label .. "." .. k)
            end,
            __newindex = function(self, k, v)
                local val_str = recursive_tostring(v, 0)
                _orig_print("PROP_SET --> " .. label .. "." .. k .. " = " .. val_str)
                rawset(self, k, v)
            end,
            __tostring = function() return label end,
            __eq = function(a, b) return _orig_rawequal(a, b) end,
        })

    else
        -- Generic service with ClassName set
        svc = create_typed_dummy("Instance", serviceName)
    end

    _SINGLETON_SERVICES[serviceName] = svc
    return svc
end

-- ============================================================
-- HumanoidDescription patch: GetEmotes returns non-empty table
-- ============================================================
local _hd_mt_patch
_hd_mt_patch = function(desc)
    local mt = _orig_getmetatable(desc)
    if not mt then return end
    local old_idx = mt.__index
    mt.__index = function(self, k)
        if k == "GetEmotes" then
            return function(_)
                return rawget(self, "_emotes") or {Walk = {{animationId = 507766388}}}
            end
        end
        if k == "LocaleId" then
            return rawget(self, "_localeId") or "en-us"
        end
        return old_idx(self, k)
    end
end

-- Patch Translator typeof
local function patch_translator(tr)
    local mt = _orig_getmetatable(tr)
    if not mt then return end
    mt.__mock_type = "Instance"
    mt.__mock_classname = "Translator"
    local old_idx = mt.__index
    mt.__index = function(self, k)
        if k == "LocaleId" then return rawget(self, "_localeId") or "en-us" end
        if k == "IsA" then return function(_, cn) return cn == "Translator" or cn == "Instance" end end
        if k == "ClassName" then return "Translator" end
        return old_idx(self, k)
    end
end

-- ============================================================
-- Enum mock
-- ============================================================
local _ENUM_CACHE = {}
local function get_enum(path)
    if _ENUM_CACHE[path] then return _ENUM_CACHE[path] end
    local e = {}
    _orig_setmetatable(e, {
        __is_mock_dummy = true,
        __mock_type = "EnumItem",
        __index = function(self, k)
            return get_enum(path .. "." .. k)
        end,
        __tostring = function() return "Enum." .. path end,
        __eq = function(a, b) return _orig_rawequal(a, b) end,
        __newindex = function() end,
    })
    _ENUM_CACHE[path] = e
    return e
end

local MockEnum = {}
_orig_setmetatable(MockEnum, {
    __index = function(_, k) return get_enum(k) end,
    __newindex = function() end,
    __tostring = function() return "Enum" end,
})

-- ============================================================
-- Instance.new mock
-- ============================================================
local function mock_instance_new(className, parent)
    local inst = create_typed_dummy("Instance", className)
    if parent then rawset(inst, "_parent", parent) end
    _orig_print("CALL_RESULT --> local " .. (className or "Instance") .. "_new = Instance.new(\"" .. (className or "") .. "\")")
    return inst
end

-- ============================================================
-- OverlapParams.new
-- ============================================================
local MockOverlapParams = {}
_orig_setmetatable(MockOverlapParams, {
    __index = function(_, k)
        if k == "new" then return create_overlap_params end
        return create_dummy("OverlapParams." .. k)
    end,
    __tostring = function() return "OverlapParams" end,
})

-- ============================================================
-- mock_pairs / mock_ipairs
-- ============================================================
local function mock_pairs(t)
    local mt = _orig_getmetatable(t)
    if mt and mt.__is_mock_dummy then
        local i = 0
        return function()
            i = i + 1
            if i <= 2 then
                return i, create_dummy(_orig_tostring(t) .. "_v" .. i)
            end
            return nil
        end
    end
    return _orig_pairs(t)
end

local function mock_ipairs(t)
    local mt = _orig_getmetatable(t)
    if mt and mt.__is_mock_dummy then
        local i = 0
        return function()
            i = i + 1
            if i <= 2 then
                return i, create_dummy(_orig_tostring(t) .. "_v" .. i)
            end
            return nil
        end
    end
    return _orig_ipairs(t)
end

-- ============================================================
-- game singleton
-- ============================================================
local _game = create_service("game")
local _workspace = create_service("workspace")

-- Patch _workspace GetDebugId
do
    local ws_mt = _orig_getmetatable(_workspace)
    local ws_old_idx = ws_mt.__index
    ws_mt.__index = function(self, k)
        if k == "GetDebugId" then return function(_, d) return _get_debug_id(self) end end
        return ws_old_idx(self, k)
    end
end

-- ============================================================
-- MockEnv
-- ============================================================
local MockEnv = {}
local _MockEnv_ref = MockEnv

local function table_concat(t, sep, i, j)
    local res = table.concat(t, sep, i, j)
    if _orig_type(res) == "string" then
        local url = res:match("https?://[%w%.%-%/%?%=&_]+")
        if url then _orig_print("URL DETECTED IN CONCAT --> " .. url) end
    end
    return res
end

local safe_globals = {
    ["string"] = string,
    ["table"] = {
        insert = table.insert, remove = table.remove, sort = table.sort,
        concat = table_concat, maxn = table.maxn or function(t) return #t end,
        move = table.move, unpack = table.unpack or unpack,
    },
    ["math"] = math,
    ["pairs"] = mock_pairs,
    ["ipairs"] = mock_ipairs,
    ["select"] = _orig_select,
    ["unpack"] = _orig_unpack,
    ["tonumber"] = real_tonumber,
    ["tostring"] = _orig_tostring,
    ["type"] = real_type,
    ["typeof"] = real_typeof,
    ["pcall"] = function(f, ...)
        local ok, err = _orig_pcall(f, ...)
        if not ok and _orig_type(err) == "string" then
            err = err:gsub("[Ss]tack [Oo]verflow", "recursion limit reached")
        end
        return ok, err
    end,
    ["xpcall"] = _orig_xpcall,
    ["getfenv"] = function(n) return _MockEnv_ref end,
    ["setmetatable"] = _orig_setmetatable,
    ["getmetatable"] = function(t)
        if _orig_rawequal(t, _MockEnv_ref) then return nil end
        return _orig_getmetatable(t)
    end,
    ["error"] = _orig_error,
    ["assert"] = assert,
    ["next"] = _orig_next,
    ["print"] = function(...)
        local args = {...}
        local parts = {}
        for _, v in _orig_ipairs(args) do table.insert(parts, _orig_tostring(v)) end
        _orig_print("TRACE_PRINT --> " .. table.concat(parts, "\t"))
    end,
    ["_VERSION"] = _VERSION,
    ["rawset"] = rawset,
    ["rawget"] = rawget,
    ["rawequal"] = rawequal,
    ["rawlen"] = rawlen,
    ["os"] = { clock = os.clock, time = os.time, date = os.date },
    ["debug"] = {
        traceback = function(a, b) local m = _orig_type(a) == "thread" and b or a; return (m ~= nil and (_orig_tostring(m) .. "\n") or "") .. "stack traceback:\n\t[C]: in ?" end,
        getinfo = function() return { source = "=[C]", short_src = "[C]", what = "C" } end,
        getmetatable = debug and debug.getmetatable or _orig_getmetatable,
        setmetatable = debug and debug.setmetatable or _orig_setmetatable,
    },
    ["OverlapParams"] = MockOverlapParams,
    ["Enum"] = MockEnum,
    ["Instance"] = {
        new = mock_instance_new,
    },
    ["loadstring"] = function(s)
        _orig_print("LOADSTRING DETECTED: size=" .. _orig_tostring(#s))
        _orig_print("LOADSTRING CONTENT START")
        _orig_print(s)
        _orig_print("LOADSTRING CONTENT END")
        return function() _orig_print("DUMMY FUNC CALLED") end
    end,
    ["load"] = function(chunk, chunkname, mode, env)
        if _orig_type(chunk) == "string" then
            _orig_print("LOAD DETECTED: size=" .. _orig_tostring(#chunk))
        end
        return function() _orig_print("DUMMY LOAD FUNC CALLED") end
    end,
}

_orig_setmetatable(MockEnv, {
    __index = function(t, k)
        if safe_globals[k] ~= nil then
            return safe_globals[k]
        end

        if k == "game" then
            _orig_print("ACCESSED --> game")
            return _game
        end
        if k == "workspace" or k == "Workspace" then
            return _workspace
        end
        if k == "script" then
            return create_typed_dummy("Instance", "LocalScript")
        end
        if k == "getgenv" or k == "getrenv" or k == "getreg" then
            return function() return MockEnv end
        end

        local exploit_funcs = {
            "getgc", "getinstances", "getnilinstances",
            "getloadedmodules", "getconnections", "firesignal", "fireclickdetector",
            "firetouchinterest", "isnetworkowner", "gethiddenproperty", "sethiddenproperty",
            "rconsoleprint", "rconsolewarn", "rconsoleerr", "rconsoleinfo",
            "rconsolename", "rconsoleclear", "consoleprint", "consolewarn",
            "consoleerr", "consoleinfo", "consolename", "consoleclear",
            "warn", "clonefunction", "hookfunction", "newcclosure", "replaceclosure",
            "restoreclosure", "islclosure", "iscclosure", "checkcaller",
            "getnamecallmethod", "setnamecallmethod", "getrawmetatable", "setrawmetatable",
            "setreadonly", "isreadonly", "iswindowactive",
            "keypress", "keyrelease", "mouse1click", "mouse1press", "mouse1release",
            "mousescroll", "mousemoverel", "mousemoveabs", "hookmetamethod",
            "getcallingscript",
            "bit", "bit32",
            "Vector2", "Vector3", "CFrame", "UDim2", "Color3", "Ray",
            "BrickColor", "NumberRange", "NumberSequence", "ColorSequence",
            "task", "coroutine", "Delay", "delay", "Spawn", "spawn", "Wait", "wait",
            "tick", "time", "elapsedTime", "utf8",
            "HttpService", "RunService", "UserInputService", "TweenService",
            "setsimulationradius",
        }
        for _, name in _orig_ipairs(exploit_funcs) do
            if k == name then
                _orig_print("ACCESSED --> " .. k)
                return create_dummy(k)
            end
        end

        _orig_print("ACCESSED (NIL) --> " .. k)
        return nil
    end,

    __newindex = function(t, k, v)
        local val_str
        if _orig_type(v) == "string" then
            val_str = '"' .. v:gsub('"', '\\"') .. '"'
        elseif _orig_type(v) == "number" or _orig_type(v) == "boolean" then
            val_str = _orig_tostring(v)
        else
            val_str = _orig_tostring(v)
        end
        _orig_print("SET GLOBAL --> " .. _orig_tostring(k) .. " = " .. val_str)
        rawset(t, k, v)
    end
})

safe_globals["_G"] = MockEnv
safe_globals["shared"] = MockEnv

getfenv = function(n) return _MockEnv_ref end
getmetatable = function(t)
    if _orig_rawequal(t, _MockEnv_ref) then return nil end
    return _orig_getmetatable(t)
end
"""

    idx_args = content.rfind("(getfenv")
    if idx_args == -1:
        idx_args = content.rfind("( getfenv")

    if idx_args == -1:
        idx_args = len(content)

    idx_ret = content.rfind("return(function", 0, idx_args)
    if idx_ret == -1:
        print(f"Could not find return(function injection point in {filepath}.")
        return

    dumper_code = f"""
    print("--- CONSTANTS START ---")
    if {var_name} then
        local sorted_keys = {{}}
        for k in pairs({var_name}) do table.insert(sorted_keys, k) end
        table.sort(sorted_keys)
        local out = "local Constants = {{"
        for i, k in ipairs(sorted_keys) do
            local v = {var_name}[k]
            local v_str = string.format("%q", tostring(v))
            out = out .. " [" .. tostring(k) .. "] = " .. v_str .. ","
        end
        out = out .. " }}"
        print(out)
    end
    print("--- CONSTANTS END ---")
    """

    new_content = mock_env_code + content[:idx_ret] + dumper_code + content[idx_ret:]

    new_content = re.sub(r'getfenv\s+and\s+getfenv\(\)\s*or\s*_ENV', 'MockEnv', new_content)

    temp_file = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as handle:
            handle.write(new_content)
            temp_file = handle.name
    except OSError as exc:
        print(f"Error writing temp file: {exc}")
        return

    print(f"Executing deobfuscation for {filepath}...")

    lua_cmd = _lua_command()
    if not _lua_available():
        print("Error: No Lua interpreter found. Please install Lua, "
              "or install the `lupa` Python package (pip install lupa).")
        return

    stdout_lines = []

    RELEVANT_PREFIXES = (
        "ACCESSED", "CALL_RESULT", "local Constants =",
        "URL DETECTED", "SET GLOBAL", "UNPACK CALLED",
        "CAPTURED CHUNK", "CLOSURE", "TRACE_PRINT",
        "PROP_SET", "LOADSTRING", "LOAD DETECTED",
        "--- CONSTANTS",
    )

    import queue
    import signal
    import threading

    start_time = time.time()
    deadline = start_time + 25.0
    process = None
    try:
        process = subprocess.Popen(
            [*lua_cmd, temp_file, "1"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        line_queue: queue.Queue = queue.Queue()

        def _read_stdout():
            try:
                assert process.stdout is not None
                for raw in iter(process.stdout.readline, b""):
                    line_queue.put(raw)
            except Exception:
                pass
            finally:
                line_queue.put(None)

        reader = threading.Thread(target=_read_stdout, daemon=True)
        reader.start()

        timed_out = False
        try:
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    timed_out = True
                    print("Timeout reached.")
                    break
                try:
                    raw = line_queue.get(timeout=min(0.25, remaining))
                except queue.Empty:
                    if process.poll() is not None and not reader.is_alive():
                        break
                    continue
                if raw is None:
                    break
                decoded_line = raw.decode('utf-8', errors='replace').rstrip()
                stdout_lines.append(decoded_line)
                if any(prefix in decoded_line for prefix in RELEVANT_PREFIXES):
                    print(decoded_line)
        except Exception as e:
            print(f"Error during execution: {e}")
            timed_out = True

        if timed_out and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=1.5)
            except Exception:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except Exception:
                    process.kill()

        try:
            _, err = process.communicate(timeout=2)
            if err:
                stderr_text = err.decode('utf-8', errors='replace').strip()
                if stderr_text:
                    print("STDERR:", stderr_text)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except Exception:
                process.kill()
        reader.join(timeout=1.0)

    except Exception as e:
        print(f"Failed to start Lua process: {e}")
        return
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except Exception:
                try:
                    process.kill()
                except Exception:
                    pass

    constants_str = ""
    trace_lines = []

    in_constants = False
    for line in stdout_lines:
        stripped = line.strip()
        if stripped == "--- CONSTANTS START ---":
            in_constants = True
            continue
        if stripped == "--- CONSTANTS END ---":
            in_constants = False
            continue

        if in_constants:
            constants_str += line + "\n"
        elif any(prefix in line for prefix in RELEVANT_PREFIXES):
            trace_lines.append(line)

    report_file = filepath + ".report.txt"
    try:
        with open(report_file, 'w', encoding='utf-8') as f:
            f.write("--- DEOBFUSCATION REPORT ---\n")
            f.write(f"File: {filepath}\n\n")
            f.write("--- TRACE ---\n")
            for line in trace_lines:
                f.write(line + "\n")
            f.write("\n--- CONSTANTS ---\n")
            f.write(constants_str)
    except Exception as e:
        raise RuntimeError(f"Error writing report: {e}")

    print(f"Report saved to {report_file}")

    try:
        import trace_to_lua
        import importlib
        importlib.reload(trace_to_lua)
        trace_to_lua.parse_trace(report_file)
    except Exception as e:
        print(f"Failed to convert trace: {e}")
        import traceback
        traceback.print_exc()

    if os.path.exists(temp_file):
        try:
            os.remove(temp_file)
        except Exception:
            pass


def main():
    target = "obfuscated_scripts"
    if len(sys.argv) > 1:
        target = sys.argv[1]

    if os.path.isfile(target):
        deobfuscate_file(target)
    elif os.path.isdir(target):
        files = glob.glob(os.path.join(target, "*.lua"))
        for file in sorted(files):
            if "temp_deob" in file or ".report.txt" in file or ".deobf." in file:
                continue
            deobfuscate_file(file)
            print("-" * 40)
    else:
        print(f"Invalid path: {target}")


if __name__ == "__main__":
    main()
