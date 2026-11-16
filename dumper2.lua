local INPUT_PATH  = arg and arg[1]
local OUTPUT_PATH = arg and arg[2]

if type(INPUT_PATH) ~= "string" or type(OUTPUT_PATH) ~= "string" then
    io.stderr:write("missing input/output path arguments\n")
    os.exit(2)
end

local hostIoOpen = io.open
local hostClock  = os.clock
local hostTime   = os.time
local hostDate   = os.date
local hostLoad   = loadstring or load
local hostType   = type
local hostTostring = tostring
local hostTonumber = tonumber
local hostPcall  = pcall
local hostXpcall = xpcall
local hostError  = error
local hostPairs  = pairs
local hostIpairs = ipairs
local hostNext   = next
local hostRawget = rawget
local hostRawset = rawset
local hostRawequal = rawequal
local hostRawlen = rawlen or function(t) return #t end
local hostPack = table.pack or function(...) return { n = select("#", ...), ... } end
local hostGetmetatable = getmetatable
local hostSetmetatable = setmetatable
local hostUnpack = table.unpack or unpack
local hostSetfenv = setfenv
local hostGetfenv = getfenv
local hostDebugInfo = debug and debug.info
local hostDebugGetupvalue = debug and debug.getupvalue

-- Read input script
local inFile, inErr = hostIoOpen(INPUT_PATH, "rb")
if not inFile then
    io.stderr:write("failed to open input: " .. hostTostring(inErr) .. "\n")
    os.exit(1)
end
local SOURCE_CODE = inFile:read("*a") or ""
inFile:close()

-- Normalize BOM / line endings
if SOURCE_CODE:sub(1, 3) == "\239\187\191" then
    SOURCE_CODE = SOURCE_CODE:sub(4)
end
SOURCE_CODE = SOURCE_CODE:gsub("\r\n", "\n"):gsub("\r", "\n")

-- Capture log buffer
local _capturedLines = {}
local _capturedCount = 0
local _MAX_CAPTURED  = 15000
local _seenStageHash = {}
local _stageDepth    = 0
local _MAX_STAGE_DEPTH = 6
local _simTime       = 0
local _startClock    = hostClock()
local _rawMetaMap    = hostSetmetatable({}, { __mode = "k" })
local _apiCallCounts = {}

local function _escapeLuaString(s)
    return '"' .. s:gsub('[\\"\n\r\t%c\127-\255]', function(c)
        local b = string.byte(c)
        if b == 92 then return "\\\\"
        elseif b == 34 then return '\\"'
        elseif b == 10 then return "\\n"
        elseif b == 13 then return "\\r"
        elseif b == 9 then return "\\t"
        else return string.format("\\%03d", b)
        end
    end) .. '"'
end

local function _emitLine(line)
    if type(line) ~= "string" or line == "" then return end
    if _capturedCount >= _MAX_CAPTURED then return end
    _capturedCount = _capturedCount + 1
    _capturedLines[_capturedCount] = line
end

local function _emitApiCall(key, line, limit)
    local n = (_apiCallCounts[key] or 0) + 1
    if n > (limit or 1) then return end
    _apiCallCounts[key] = n
    _emitLine(line)
end

local function _formatArg(v, depth)
    depth = depth or 0
    local t = hostType(v)
    if v == nil then return "nil" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v then return "0/0" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        return hostTostring(v)
    end
    if t == "string" then
        local maxLen = depth == 0 and 65536 or 2048
        if #v > maxLen then
            return _escapeLuaString(v:sub(1, maxLen)) .. " --[[truncated]]"
        end
        return _escapeLuaString(v)
    end
    if t == "function" then return "function() end" end
    if t == "table" then
        local mt = _rawMetaMap[v] or hostGetmetatable(v)
        if hostType(mt) == "table" then
            local tp = rawget(mt, "__type")
            if tp == "Vector3" then
                return string.format("Vector3.new(%s, %s, %s)", hostTostring(v.X or 0), hostTostring(v.Y or 0), hostTostring(v.Z or 0))
            elseif tp == "Vector2" then
                return string.format("Vector2.new(%s, %s)", hostTostring(v.X or 0), hostTostring(v.Y or 0))
            elseif tp == "Color3" then
                return string.format("Color3.new(%s, %s, %s)", hostTostring(v.R or 0), hostTostring(v.G or 0), hostTostring(v.B or 0))
            elseif tp == "CFrame" then
                return string.format("CFrame.new(%s, %s, %s)", hostTostring(v.X or 0), hostTostring(v.Y or 0), hostTostring(v.Z or 0))
            elseif tp == "EnumItem" or tp == "Enum" or tp == "Instance" then
                return hostTostring(v)
            end
        end
        if depth >= 2 then return "{...}" end
        local parts = {}
        local n = 0
        for k, val in hostPairs(v) do
            n = n + 1
            if n > 24 then
                parts[#parts + 1] = "--[[...]]"
                break
            end
            if hostType(k) == "number" then
                parts[#parts + 1] = _formatArg(val, depth + 1)
            elseif hostType(k) == "string" and k:match("^[%a_][%w_]*$") then
                parts[#parts + 1] = k .. " = " .. _formatArg(val, depth + 1)
            else
                parts[#parts + 1] = "[" .. _formatArg(k, depth + 1) .. "] = " .. _formatArg(val, depth + 1)
            end
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return hostTostring(v)
end

local function _formatArgs(...)
    local packed = hostPack(...)
    local out = {}
    for i = 1, packed.n do
        out[i] = _formatArg(packed[i], 0)
    end
    return table.concat(out, ", ")
end

-- API Registry from lune_sandbox_runner
local _apiRegistry   = rawget(_G, "__ROBLOX_API_REGISTRY") or {}
local _apiEnums      = (hostType(_apiRegistry) == "table" and _apiRegistry.enums) or {}
local _apiClassSuper = (hostType(_apiRegistry) == "table" and _apiRegistry.classSuper) or {}
local _apiMembers    = (hostType(_apiRegistry) == "table" and _apiRegistry.members) or {}
local _apiClasses    = (hostType(_apiRegistry) == "table" and _apiRegistry.classes) or {}

-- Type / Proxy tracking
local _proxyTypes       = hostSetmetatable({}, { __mode = "k" })
local _proxyPaths       = hostSetmetatable({}, { __mode = "k" })
local _proxyProps       = hostSetmetatable({}, { __mode = "k" })
local _proxyChildren    = hostSetmetatable({}, { __mode = "k" })
local _proxyParent      = hostSetmetatable({}, { __mode = "k" })
local _refBaseMap       = hostSetmetatable({}, { __mode = "k" })
local _destroyedMap     = hostSetmetatable({}, { __mode = "k" })
local _proxySignals     = hostSetmetatable({}, { __mode = "k" })
local _proxyPropSignals = hostSetmetatable({}, { __mode = "k" })
local _proxyAttrSignals = hostSetmetatable({}, { __mode = "k" })
local _proxyAttrs       = hostSetmetatable({}, { __mode = "k" })
local _proxyTags        = hostSetmetatable({}, { __mode = "k" })
local _allInstances     = hostSetmetatable({}, { __mode = "k" })
local _readOnlyMap      = hostSetmetatable({}, { __mode = "k" })
local _cclosureSet      = hostSetmetatable({}, { __mode = "k" })
local _hookedMap        = hostSetmetatable({}, { __mode = "k" })
local _editableMeshes   = hostSetmetatable({}, { __mode = "k" })
local _currentNamecallMethod = ""

-- Class inheritance helper
local _knownInherits = {
    Part = {"Part", "FormFactorPart", "BasePart", "PVInstance", "Instance"},
    MeshPart = {"MeshPart", "TriangleMeshPart", "BasePart", "PVInstance", "Instance"},
    WedgePart = {"WedgePart", "FormFactorPart", "BasePart", "PVInstance", "Instance"},
    CornerWedgePart = {"CornerWedgePart", "BasePart", "PVInstance", "Instance"},
    TrussPart = {"TrussPart", "BasePart", "PVInstance", "Instance"},
    SpawnLocation = {"SpawnLocation", "Part", "FormFactorPart", "BasePart", "PVInstance", "Instance"},
    Terrain = {"Terrain", "BasePart", "PVInstance", "Instance"},
    Path = {"Path", "Instance"},
    Seat = {"Seat", "BasePart", "PVInstance", "Instance"},
    VehicleSeat = {"VehicleSeat", "BasePart", "PVInstance", "Instance"},
    Humanoid = {"Humanoid", "Instance"},
    Animator = {"Animator", "Instance"},
    Animation = {"Animation", "Instance"},
    AnimationTrack = {"AnimationTrack", "Instance"},
    Player = {"Player", "Instance"},
    Model = {"Model", "PVInstance", "Instance"},
    Folder = {"Folder", "Instance"},
    LocalScript = {"LocalScript", "BaseScript", "LuaSourceContainer", "Instance"},
    Script = {"Script", "BaseScript", "LuaSourceContainer", "Instance"},
    ModuleScript = {"ModuleScript", "LuaSourceContainer", "Instance"},
    RemoteEvent = {"RemoteEvent", "BaseRemoteEvent", "Instance"},
    RemoteFunction = {"RemoteFunction", "Instance"},
    UnreliableRemoteEvent = {"UnreliableRemoteEvent", "BaseRemoteEvent", "Instance"},
    BindableEvent = {"BindableEvent", "Instance"},
    BindableFunction = {"BindableFunction", "Instance"},
    Sound = {"Sound", "Instance"},
    ScreenGui = {"ScreenGui", "LayerCollector", "GuiBase2d", "GuiBase", "Instance"},
    BillboardGui = {"BillboardGui", "LayerCollector", "GuiBase2d", "GuiBase", "Instance"},
    SurfaceGui = {"SurfaceGui", "LayerCollector", "GuiBase2d", "GuiBase", "Instance"},
    Frame = {"Frame", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    TextLabel = {"TextLabel", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    TextButton = {"TextButton", "GuiButton", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    TextBox = {"TextBox", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    ImageLabel = {"ImageLabel", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    ImageButton = {"ImageButton", "GuiButton", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    ScrollingFrame = {"ScrollingFrame", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    ViewportFrame = {"ViewportFrame", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    EditableMesh = {"EditableMesh", "Object", "Instance"},
    Workspace = {"Workspace", "WorldRoot", "Model", "PVInstance", "Instance"},
    DataModel = {"DataModel", "ServiceProvider", "Instance"},
    Camera = {"Camera", "Instance"},
    Tool = {"Tool", "BackpackItem", "Instance"},
    Accessory = {"Accessory", "Accoutrement", "Instance"},
    Attachment = {"Attachment", "Instance"},
    Highlight = {"Highlight", "Instance"},
    ProximityPrompt = {"ProximityPrompt", "Instance"},
    ClickDetector = {"ClickDetector", "Instance"},
    Tween = {"Tween", "TweenBase", "Instance"},
    Path2D = {"Path2D", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    RotationCurve = {"RotationCurve", "CurveAnimation", "AnimationRigData", "Instance"},
}

local function _isClassA(className, targetName)
    if className == targetName then return true end
    if targetName == "Object" then return true end
    local cur = _apiClassSuper[className]
    local visited = {}
    while cur and cur ~= "" and cur ~= "<<<ROOT>>>" and not visited[cur] do
        if cur == targetName then return true end
        visited[cur] = true
        cur = _apiClassSuper[cur]
    end
    local list = _knownInherits[className]
    if list then
        for _, base in hostIpairs(list) do
            if base == targetName then return true end
        end
    end
    local clsDef = _apiClasses[className]
    visited = {}
    while hostType(clsDef) == "table" and clsDef.superclass and not visited[clsDef.superclass] do
        if clsDef.superclass == targetName then return true end
        visited[clsDef.superclass] = true
        clsDef = _apiClasses[clsDef.superclass]
    end
    if targetName == "Instance" and _apiClassSuper[className] == nil then
        return true
    end
    return false
end

local function _hasApiMember(className, category, memberName)
    local cur = className
    local visited = {}
    while cur and cur ~= "" and cur ~= "<<<ROOT>>>" and not visited[cur] do
        visited[cur] = true
        local m = _apiMembers[cur]
        if hostType(m) == "table" and hostType(m[category]) == "table" and m[category][memberName] then
            return true
        end
        cur = _apiClassSuper[cur]
    end
    return false
end

local _nonCreatableClasses = {
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
    Pages = true, Feature = true, Hole = true, MotorFeature = true,
    Player = true, Workspace = true, CoreGui = true, CorePackages = true,
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
    VoiceChatService = true, NetworkClient = true, NetworkServer = true,
    Selection = true, LogService = true, ScriptContext = true, ChangeHistoryService = true,
    SocialService = true, GroupService = true, FriendsService = true, VRService = true,
    HapticService = true, GamepadService = true, TouchInputService = true,
    JointsService = true, RenderSettings = true, DebugSettings = true,
    NetworkSettings = true, LuaSettings = true, UserGameSettings = true,
    GlobalSettings = true, GlobalDataStore = true, OrderedDataStore = true, DataStore = true,
    MaterialService = true, ProximityPromptService = true, AvatarEditorService = true,
    BrowserService = true, NotificationService = true, AdService = true,
}

local function _isCreatableClass(className)
    if hostType(className) ~= "string" or className == "" then return false end
    if _nonCreatableClasses[className] then return false end
    if _apiClassSuper[className] == nil and _knownInherits[className] == nil and _apiClasses[className] == nil then
        return false
    end
    if className:match("Service$") then return false end
    if _isClassA(className, "ServiceProvider") or _isClassA(className, "GenericSettings")
        or _isClassA(className, "Pages") or _isClassA(className, "GlobalDataStore")
        or _isClassA(className, "BasePlayerGui") then
        return false
    end
    return true
end

-- Sandboxed Roblox Datatypes
local function _makeType(name, fields)
    local obj = fields or {}
    local mt = {
        __type = name,
        __tostring = function() return name end,
        __metatable = "The metatable is locked",
    }
    mt.__index = mt
    _rawMetaMap[obj] = mt
    return hostSetmetatable(obj, mt)
end

local _Vector2 = {}
do
    local v2mt = {
        __type = "Vector2",
        __tostring = function(s) return string.format("%g, %g", s.X, s.Y) end,
        __add = function(a, b) return _Vector2.new((a.X or 0) + (b.X or 0), (a.Y or 0) + (b.Y or 0)) end,
        __sub = function(a, b) return _Vector2.new((a.X or 0) - (b.X or 0), (a.Y or 0) - (b.Y or 0)) end,
        __mul = function(a, b)
            if hostType(b) == "number" then return _Vector2.new(a.X * b, a.Y * b) end
            return _Vector2.new((a.X or 0) * (b.X or 0), (a.Y or 0) * (b.Y or 0))
        end,
        __div = function(a, b)
            if hostType(b) == "number" then return _Vector2.new(a.X / b, a.Y / b) end
            return _Vector2.new((a.X or 0) / (b.X or 1), (a.Y or 0) / (b.Y or 1))
        end,
        __eq = function(a, b) return hostType(b) == "table" and a.X == b.X and a.Y == b.Y end,
    }
    v2mt.__index = function(s, k)
        if k == "x" then return s.X end
        if k == "y" then return s.Y end
        if k == "Magnitude" then return math.sqrt(s.X * s.X + s.Y * s.Y) end
        if k == "Unit" then
            local m = math.sqrt(s.X * s.X + s.Y * s.Y)
            return m > 0 and _Vector2.new(s.X / m, s.Y / m) or _Vector2.new(0, 0)
        end
        if k == "Lerp" then return function(self, g, a) return _Vector2.new(self.X + (g.X - self.X) * a, self.Y + (g.Y - self.Y) * a) end end
        if k == "Dot" then return function(self, o) return self.X * o.X + self.Y * o.Y end end
        if k == "Cross" then return function(self, o) return self.X * o.Y - self.Y * o.X end end
        return nil
    end
    _Vector2.new = function(x, y)
        return hostSetmetatable({ X = hostTonumber(x) or 0, Y = hostTonumber(y) or 0 }, v2mt)
    end
    _Vector2.zero = _Vector2.new(0, 0)
    _Vector2.one  = _Vector2.new(1, 1)
    _Vector2.xAxis = _Vector2.new(1, 0)
    _Vector2.yAxis = _Vector2.new(0, 1)
end

local _Vector3 = {}
do
    local v3mt
    v3mt = {
        __type = "Vector3",
        __tostring = function(s) return string.format("%g, %g, %g", s.X, s.Y, s.Z) end,
        __add = function(a, b) return _Vector3.new((a.X or 0) + (b.X or 0), (a.Y or 0) + (b.Y or 0), (a.Z or 0) + (b.Z or 0)) end,
        __sub = function(a, b) return _Vector3.new((a.X or 0) - (b.X or 0), (a.Y or 0) - (b.Y or 0), (a.Z or 0) - (b.Z or 0)) end,
        __unm = function(a) return _Vector3.new(-a.X, -a.Y, -a.Z) end,
        __mul = function(a, b)
            if hostType(b) == "number" then return _Vector3.new(a.X * b, a.Y * b, a.Z * b) end
            if hostType(a) == "number" then return _Vector3.new(a * b.X, a * b.Y, a * b.Z) end
            return _Vector3.new((a.X or 0) * (b.X or 0), (a.Y or 0) * (b.Y or 0), (a.Z or 0) * (b.Z or 0))
        end,
        __div = function(a, b)
            if hostType(b) == "number" then return _Vector3.new(a.X / b, a.Y / b, a.Z / b) end
            return _Vector3.new((a.X or 0) / (b.X or 1), (a.Y or 0) / (b.Y or 1), (a.Z or 0) / (b.Z or 1))
        end,
        __eq = function(a, b) return hostType(b) == "table" and a.X == b.X and a.Y == b.Y and a.Z == b.Z end,
    }
    v3mt.__index = function(s, k)
        if k == "x" then return s.X end
        if k == "y" then return s.Y end
        if k == "z" then return s.Z end
        if k == "Magnitude" or k == "magnitude" then
            return math.sqrt(s.X * s.X + s.Y * s.Y + s.Z * s.Z)
        end
        if k == "Unit" or k == "unit" then
            local m = math.sqrt(s.X * s.X + s.Y * s.Y + s.Z * s.Z)
            return m > 0 and _Vector3.new(s.X / m, s.Y / m, s.Z / m) or _Vector3.new(0, 0, 0)
        end
        if k == "Lerp" or k == "lerp" then
            return function(self, goal, alpha)
                return _Vector3.new(self.X + (goal.X - self.X) * alpha, self.Y + (goal.Y - self.Y) * alpha, self.Z + (goal.Z - self.Z) * alpha)
            end
        end
        if k == "Dot" or k == "dot" then
            return function(self, o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
        end
        if k == "Cross" or k == "cross" then
            return function(self, o)
                return _Vector3.new(self.Y * o.Z - self.Z * o.Y, self.Z * o.X - self.X * o.Z, self.X * o.Y - self.Y * o.X)
            end
        end
        if k == "Max" then return function(self, ...) return _Vector3.Max(self, ...) end end
        if k == "Min" then return function(self, ...) return _Vector3.Min(self, ...) end end
        if k == "Angle" then return function(self, o, ax) return _Vector3.Angle(self, o, ax) end end
        if k == "FuzzyEq" then
            return function(self, o, eps)
                eps = eps or 1e-5
                return math.abs(self.X - o.X) <= eps and math.abs(self.Y - o.Y) <= eps and math.abs(self.Z - o.Z) <= eps
            end
        end
        return nil
    end
    _Vector3.new = function(x, y, z)
        return hostSetmetatable({ X = hostTonumber(x) or 0, Y = hostTonumber(y) or 0, Z = hostTonumber(z) or 0 }, v3mt)
    end
    _Vector3.Max = function(a, b)
        return _Vector3.new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
    end
    _Vector3.Min = function(a, b)
        return _Vector3.new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
    end
    _Vector3.Angle = function(a, b, axis)
        local ma = math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z)
        local mb = math.sqrt(b.X * b.X + b.Y * b.Y + b.Z * b.Z)
        if ma == 0 or mb == 0 then return 0 end
        local dot = (a.X * b.X + a.Y * b.Y + a.Z * b.Z) / (ma * mb)
        if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
        local ang = math.acos(dot)
        if axis then
            local cx = a.Y * b.Z - a.Z * b.Y
            local cy = a.Z * b.X - a.X * b.Z
            local cz = a.X * b.Y - a.Y * b.X
            if (cx * axis.X + cy * axis.Y + cz * axis.Z) < 0 then
                ang = -ang
            end
        end
        return ang
    end
    _Vector3.zero  = _Vector3.new(0, 0, 0)
    _Vector3.one   = _Vector3.new(1, 1, 1)
    _Vector3.xAxis = _Vector3.new(1, 0, 0)
    _Vector3.yAxis = _Vector3.new(0, 1, 0)
    _Vector3.zAxis = _Vector3.new(0, 0, 1)
end

local _CFrame = {}
do
    local cfMt
    local function _makeCF(x, y, z, r)
        return hostSetmetatable({
            X = hostTonumber(x) or 0,
            Y = hostTonumber(y) or 0,
            Z = hostTonumber(z) or 0,
            _r = r or {1, 0, 0, 0, 1, 0, 0, 0, 1},
        }, cfMt)
    end
    cfMt = {
        __type = "CFrame",
        __tostring = function(s) return string.format("%g, %g, %g", s.X, s.Y, s.Z) end,
        __mul = function(a, b)
            if hostType(b) == "table" and b._r then
                local ar, br = a._r, b._r
                local nx = a.X + ar[1]*b.X + ar[2]*b.Y + ar[3]*b.Z
                local ny = a.Y + ar[4]*b.X + ar[5]*b.Y + ar[6]*b.Z
                local nz = a.Z + ar[7]*b.X + ar[8]*b.Y + ar[9]*b.Z
                local nr = {
                    ar[1]*br[1] + ar[2]*br[4] + ar[3]*br[7],
                    ar[1]*br[2] + ar[2]*br[5] + ar[3]*br[8],
                    ar[1]*br[3] + ar[2]*br[6] + ar[3]*br[9],
                    ar[4]*br[1] + ar[5]*br[4] + ar[6]*br[7],
                    ar[4]*br[2] + ar[5]*br[5] + ar[6]*br[8],
                    ar[4]*br[3] + ar[5]*br[6] + ar[6]*br[9],
                    ar[7]*br[1] + ar[8]*br[4] + ar[9]*br[7],
                    ar[7]*br[2] + ar[8]*br[5] + ar[9]*br[8],
                    ar[7]*br[3] + ar[8]*br[6] + ar[9]*br[9],
                }
                return _makeCF(nx, ny, nz, nr)
            elseif hostType(b) == "table" and b.X ~= nil then
                local ar = a._r
                return _Vector3.new(
                    a.X + ar[1]*b.X + ar[2]*b.Y + ar[3]*b.Z,
                    a.Y + ar[4]*b.X + ar[5]*b.Y + ar[6]*b.Z,
                    a.Z + ar[7]*b.X + ar[8]*b.Y + ar[9]*b.Z
                )
            end
            return a
        end,
        __add = function(a, b) return _makeCF(a.X + (b.X or 0), a.Y + (b.Y or 0), a.Z + (b.Z or 0), a._r) end,
        __sub = function(a, b) return _makeCF(a.X - (b.X or 0), a.Y - (b.Y or 0), a.Z - (b.Z or 0), a._r) end,
        __eq = function(a, b) return hostType(b) == "table" and a.X == b.X and a.Y == b.Y and a.Z == b.Z end,
    }
    cfMt.__index = function(s, k)
        local r = s._r
        if k == "Position" or k == "p" then return _Vector3.new(s.X, s.Y, s.Z) end
        if k == "LookVector" then return _Vector3.new(-r[3], -r[6], -r[9]) end
        if k == "RightVector" then return _Vector3.new(r[1], r[4], r[7]) end
        if k == "UpVector" then return _Vector3.new(r[2], r[5], r[8]) end
        if k == "Inverse" or k == "inverse" then return function() return _makeCF(-s.X, -s.Y, -s.Z, {r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9]}) end end
        if k == "Lerp" or k == "lerp" then return function(_, g, t) t = t or 0; return _makeCF(s.X + (g.X - s.X) * t, s.Y + (g.Y - s.Y) * t, s.Z + (g.Z - s.Z) * t, r) end end
        if k == "ToWorldSpace" then return function(_, o) return s * o end end
        if k == "ToObjectSpace" then return function(_, o) return _makeCF(o.X - s.X, o.Y - s.Y, o.Z - s.Z, o._r or r) end end
        if k == "PointToWorldSpace" then return function(_, p) return s * p end end
        if k == "PointToObjectSpace" then return function(_, p) return _Vector3.new(p.X - s.X, p.Y - s.Y, p.Z - s.Z) end end
        if k == "VectorToWorldSpace" or k == "VectorToObjectSpace" then return function(_, p) return p end end
        if k == "GetComponents" or k == "components" then return function() return s.X, s.Y, s.Z, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9] end end
        if k == "ToEulerAnglesXYZ" or k == "toEulerAnglesXYZ" then
            return function()
                local ry = math.asin(math.max(-1, math.min(1, r[3])))
                local rx = math.atan2(-r[6], r[9])
                local rz = math.atan2(-r[2], r[1])
                return rx, ry, rz
            end
        end
        if k == "ToEulerAnglesYXZ" or k == "toEulerAnglesYXZ" or k == "ToOrientation" then
            return function()
                local rx = math.asin(math.max(-1, math.min(1, -r[6])))
                local ry = math.atan2(r[3], r[9])
                local rz = math.atan2(r[4], r[5])
                return rx, ry, rz
            end
        end
        if k == "ToAxisAngle" or k == "toAxisAngle" then return function() return _Vector3.new(0, 1, 0), 0 end end
        return nil
    end
    _CFrame.new = function(x, y, z)
        if hostType(x) == "table" and y == nil then return _makeCF(x.X, x.Y, x.Z) end
        return _makeCF(x, y, z)
    end
    _CFrame.Angles = function(rx, ry, rz)
        rx = hostTonumber(rx) or 0
        ry = hostTonumber(ry) or 0
        rz = hostTonumber(rz) or 0
        local cx, sx = math.cos(rx), math.sin(rx)
        local cy, sy = math.cos(ry), math.sin(ry)
        local cz, sz = math.cos(rz), math.sin(rz)
        return _makeCF(0, 0, 0, {
            cy * cz, -cy * sz, sy,
            cx * sz + cz * sx * sy, cx * cz - sx * sy * sz, -cy * sx,
            sx * sz - cx * cz * sy, cz * sx + cx * sy * sz, cx * cy,
        })
    end
    _CFrame.fromEulerAnglesXYZ = _CFrame.Angles
    _CFrame.fromEulerAnglesYXZ = function(rx, ry, rz)
        rx = hostTonumber(rx) or 0
        ry = hostTonumber(ry) or 0
        rz = hostTonumber(rz) or 0
        local cx, sx = math.cos(rx), math.sin(rx)
        local cy, sy = math.cos(ry), math.sin(ry)
        local cz, sz = math.cos(rz), math.sin(rz)
        return _makeCF(0, 0, 0, {
            cy * cz + sx * sy * sz, cz * sx * sy - cy * sz, cx * sy,
            cx * sz, cx * cz, -sx,
            cy * sx * sz - cz * sy, cy * cz * sx + sy * sz, cx * cy,
        })
    end
    _CFrame.fromOrientation = _CFrame.fromEulerAnglesYXZ
    _CFrame.lookAt = function(pos) return _makeCF(pos and pos.X, pos and pos.Y, pos and pos.Z) end
    _CFrame.fromMatrix = function(pos) return _makeCF(pos and pos.X, pos and pos.Y, pos and pos.Z) end
    _CFrame.fromAxisAngle = function() return _makeCF(0, 0, 0) end
    _CFrame.identity = _makeCF(0, 0, 0)
end

local _Color3 = {}
do
    local _f32buf = (hostType(buffer) == "table" and buffer.create) and buffer.create(4) or nil
    local function _f32(x)
        x = hostTonumber(x) or 0
        if _f32buf then
            buffer.writef32(_f32buf, 0, x)
            return buffer.readf32(_f32buf, 0)
        end
        if x == 0 or x ~= x or x == math.huge or x == -math.huge then return x end
        local m, e = math.frexp(x)
        local s = m * 16777216
        local fl = math.floor(s)
        local diff = s - fl
        if diff > 0.5 or (diff == 0.5 and fl % 2 ~= 0) then fl = fl + 1 end
        return math.ldexp(fl / 16777216, e)
    end
    local c3mt = {
        __type = "Color3",
        __tostring = function(s) return string.format("%g, %g, %g", s.R, s.G, s.B) end,
        __eq = function(a, b) return hostType(b) == "table" and a.R == b.R and a.G == b.G and a.B == b.B end,
        __index = {
            Lerp = function(self, goal, alpha)
                alpha = _f32(alpha or 0)
                return _Color3.new(self.R + (goal.R - self.R) * alpha, self.G + (goal.G - self.G) * alpha, self.B + (goal.B - self.B) * alpha)
            end,
            ToHSV = function(self)
                local maxC = math.max(self.R, self.G, self.B)
                local minC = math.min(self.R, self.G, self.B)
                local d = maxC - minC
                local h = 0
                if d > 0 then
                    if maxC == self.R then h = ((self.G - self.B) / d) % 6
                    elseif maxC == self.G then h = (self.B - self.R) / d + 2
                    else h = (self.R - self.G) / d + 4 end
                    h = h / 6
                end
                local s = maxC > 0 and (d / maxC) or 0
                return h, s, maxC
            end,
            ToHex = function(self)
                return string.format("%02x%02x%02x", math.floor(self.R * 255 + 0.5), math.floor(self.G * 255 + 0.5), math.floor(self.B * 255 + 0.5))
            end,
        },
    }
    _Color3.new = function(r, g, b) return hostSetmetatable({ R = _f32(r), G = _f32(g), B = _f32(b) }, c3mt) end
    _Color3.fromRGB = function(r, g, b) return _Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end
    _Color3.fromHSV = function(h, s, v) return _Color3.new(v or 1, v or 1, v or 1) end
    _Color3.fromHex = function() return _Color3.new(1, 1, 1) end
end

local _BrickColor = {}
_BrickColor.new = function(val)
    local num = hostType(val) == "number" and val or 194
    local nm = hostType(val) == "number" and (val == 1 and "White" or ("Color" .. hostTostring(val))) or hostTostring(val or "Medium stone grey")
    return hostSetmetatable({ Name = nm, Number = num, Color = _Color3.new(0.6, 0.6, 0.6) }, { __type = "BrickColor", __tostring = function(s) return s.Name end })
end
_BrickColor.White  = function() return _BrickColor.new("White") end
_BrickColor.Black  = function() return _BrickColor.new("Black") end
_BrickColor.Red    = function() return _BrickColor.new("Bright red") end
_BrickColor.Blue   = function() return _BrickColor.new("Bright blue") end
_BrickColor.Green  = function() return _BrickColor.new("Bright green") end
_BrickColor.random = function() return _BrickColor.new(math.random(1, 1032)) end
_BrickColor.Random = _BrickColor.random

local _UDim = {}
_UDim.new = function(s, o) return hostSetmetatable({ Scale = s or 0, Offset = o or 0 }, { __type = "UDim" }) end

local _UDim2 = {}
do
    local ud2mt = {
        __type = "UDim2",
        __eq = function(a, b)
            return a.X.Scale == b.X.Scale and a.X.Offset == b.X.Offset and a.Y.Scale == b.Y.Scale and a.Y.Offset == b.Y.Offset
        end,
        __add = function(a, b)
            return _UDim2.new(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
        end,
        __sub = function(a, b)
            return _UDim2.new(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
        end,
        __index = {
            Lerp = function(self, goal, alpha)
                alpha = alpha or 0
                return _UDim2.new(
                    self.X.Scale + (goal.X.Scale - self.X.Scale) * alpha,
                    math.floor(self.X.Offset + (goal.X.Offset - self.X.Offset) * alpha + 0.5),
                    self.Y.Scale + (goal.Y.Scale - self.Y.Scale) * alpha,
                    math.floor(self.Y.Offset + (goal.Y.Offset - self.Y.Offset) * alpha + 0.5)
                )
            end,
        },
    }
    _UDim2.new = function(xs, xo, ys, yo)
        return hostSetmetatable({ X = _UDim.new(xs, xo), Y = _UDim.new(ys, yo) }, ud2mt)
    end
end
_UDim2.fromScale  = function(xs, ys) return _UDim2.new(xs, 0, ys, 0) end
_UDim2.fromOffset = function(xo, yo) return _UDim2.new(0, xo, 0, yo) end
local _Ray = {}
do
    local rayMt = {
        __type = "Ray",
        __index = {
            ClosestPoint = function(self, pt)
                local d = self.Direction
                local len2 = d.X * d.X + d.Y * d.Y + d.Z * d.Z
                if len2 == 0 then return self.Origin end
                local t = ((pt.X - self.Origin.X) * d.X + (pt.Y - self.Origin.Y) * d.Y + (pt.Z - self.Origin.Z) * d.Z) / len2
                if t < 0 then t = 0 end
                return _Vector3.new(self.Origin.X + d.X * t, self.Origin.Y + d.Y * t, self.Origin.Z + d.Z * t)
            end,
            Distance = function(self, pt)
                local cp = self:ClosestPoint(pt)
                local dx, dy, dz = pt.X - cp.X, pt.Y - cp.Y, pt.Z - cp.Z
                return math.sqrt(dx * dx + dy * dy + dz * dz)
            end,
        },
    }
    _Ray.new = function(o, d)
        return hostSetmetatable({ Origin = o or _Vector3.zero, Direction = d or _Vector3.zero }, rayMt)
    end
end
local _Rect = {}
do
    local rectMt = {
        __type = "Rect",
        __index = function(s, k)
            if k == "Width" then return s.Max.X - s.Min.X end
            if k == "Height" then return s.Max.Y - s.Min.Y end
            return nil
        end,
    }
    _Rect.new = function(a, b, c, d)
        if hostType(a) == "table" and hostType(b) == "table" and c == nil then
            return hostSetmetatable({ Min = _Vector2.new(a.X, a.Y), Max = _Vector2.new(b.X, b.Y) }, rectMt)
        end
        return hostSetmetatable({ Min = _Vector2.new(a or 0, b or 0), Max = _Vector2.new(c or 0, d or 0) }, rectMt)
    end
end
local _Region3 = {}
do
    local reg3Mt = {
        __type = "Region3",
        __index = {
            ExpandToGrid = function(self) return self end,
        },
    }
    _Region3.new = function(minV, maxV)
        return hostSetmetatable({ CFrame = _CFrame.new(), Size = _Vector3.new(4, 4, 4), Min = minV or _Vector3.zero, Max = maxV or _Vector3.zero }, reg3Mt)
    end
end
local _NumberRange = {
    new = function(...)
        if select("#", ...) == 0 then hostError("missing argument #1 to 'NumberRange.new'", 2) end
        local a, b = ...
        if hostType(a) ~= "number" then hostError("invalid argument #1 to 'NumberRange.new'", 2) end
        return hostSetmetatable({ Min = a, Max = b or a }, { __type = "NumberRange" })
    end
}
local _NumberSequenceKeypoint = { new = function(t, v, e) return hostSetmetatable({ Time = t or 0, Value = v or 0, Envelope = e or 0 }, { __type = "NumberSequenceKeypoint" }) end }
local _NumberSequence = {
    new = function(...)
        if select("#", ...) == 0 then hostError("missing argument #1 to 'NumberSequence.new'", 2) end
        local v = ...
        if v == nil then hostError("invalid argument #1 to 'NumberSequence.new'", 2) end
        return hostSetmetatable({ Keypoints = hostType(v) == "table" and v or { _NumberSequenceKeypoint.new(0, v) } }, { __type = "NumberSequence" })
    end
}
local _ColorSequenceKeypoint = { new = function(t, v) return hostSetmetatable({ Time = t or 0, Value = v or _Color3.new(1, 1, 1) }, { __type = "ColorSequenceKeypoint" }) end }
local _ColorSequence = {
    new = function(...)
        if select("#", ...) == 0 then hostError("missing argument #1 to 'ColorSequence.new'", 2) end
        local v = ...
        if v == nil then hostError("invalid argument #1 to 'ColorSequence.new'", 2) end
        return hostSetmetatable({ Keypoints = hostType(v) == "table" and v or { _ColorSequenceKeypoint.new(0, v) } }, { __type = "ColorSequence" })
    end
}
local _PhysicalProperties = {
    new = function(...)
        if select("#", ...) == 0 then hostError("missing argument #1 to 'PhysicalProperties.new'", 2) end
        local d, f, e = ...
        if d == nil then hostError("invalid argument #1 to 'PhysicalProperties.new'", 2) end
        return hostSetmetatable({ Density = hostTonumber(d) or 0.7, Friction = f or 0.3, Elasticity = e or 0.5 }, { __type = "PhysicalProperties" })
    end
}
local _Faces = {
    new = function(...)
        local t = { Top = false, Bottom = false, Left = false, Right = false, Back = false, Front = false }
        local n = select("#", ...)
        for i = 1, n do
            local item = select(i, ...)
            local nm = hostType(item) == "table" and item.Name or hostTostring(item)
            if t[nm] ~= nil then t[nm] = true end
        end
        return hostSetmetatable(t, { __type = "Faces" })
    end
}
local _Axes  = {
    new = function(...)
        local t = { X = false, Y = false, Z = false }
        local n = select("#", ...)
        for i = 1, n do
            local item = select(i, ...)
            local nm = hostType(item) == "table" and item.Name or hostTostring(item)
            if t[nm] ~= nil then t[nm] = true end
        end
        return hostSetmetatable(t, { __type = "Axes" })
    end
}
local _OverlapParams
local _RaycastParams
local _PathWaypoint = { new = function(pos, act, lbl) return hostSetmetatable({ Position = pos or _Vector3.zero, Action = act, Label = lbl or "" }, { __type = "PathWaypoint" }) end }
local _Random = {
    new = function()
        local mt = { __type = "Random", __metatable = "The metatable is locked" }
        local obj = hostSetmetatable({
            NextNumber = function(_, a, b) if a and b then return a + math.random() * (b - a) end return math.random() end,
            NextInteger = function(_, a, b) return math.random(a or 1, b or 100) end,
            NextUnitVector = function() return _Vector3.new(0, 1, 0) end,
        }, mt)
        _rawMetaMap[obj] = mt
        return obj
    end
}
local _DateTime = {
    now = function()
        local ts = hostTime()
        return {
            UnixTimestamp = ts,
            UnixTimestampMillis = ts * 1000,
            ToIsoDate = function() return hostDate("!%Y-%m-%dT%H:%M:%SZ", ts) end,
            FormatUniversalTime = function() return hostDate("!%Y-%m-%d %H:%M:%S", ts) end,
            FormatLocalTime = function() return hostDate("%Y-%m-%d %H:%M:%S", ts) end,
        }
    end,
    fromUnixTimestamp = function(ts)
        return { UnixTimestamp = ts or 0, UnixTimestampMillis = (ts or 0) * 1000, ToIsoDate = function() return hostDate("!%Y-%m-%dT%H:%M:%SZ", ts or 0) end }
    end,
}
local _Font = {
    new = function(...)
        if select("#", ...) == 0 then hostError("missing argument #1 to 'Font.new'", 2) end
        local f, w, s = ...
        if hostType(f) ~= "string" then hostError("invalid argument #1 to 'Font.new'", 2) end
        local obj = { Family = f, Weight = w, Style = s }
        local mt = { __type = "Font" }
        _rawMetaMap[obj] = mt
        return hostSetmetatable(obj, mt)
    end,
    fromEnum = function(e)
        local obj = { Family = hostTostring(e) }
        local mt = { __type = "Font" }
        _rawMetaMap[obj] = mt
        return hostSetmetatable(obj, mt)
    end,
}

-- Enum hierarchy backed by __ROBLOX_API_REGISTRY
local _enumCache = {}
local function _makeEnumItem(enumName, itemName, value, enumTypeObj)
    local key = enumName .. "." .. itemName
    if _enumCache[key] then return _enumCache[key] end
    local mt = {
        __type = "EnumItem",
        __tostring = function() return "Enum." .. key end,
        __metatable = "The metatable is locked",
    }
    local item = hostSetmetatable({
        Name = itemName,
        Value = value or 0,
        EnumType = enumTypeObj,
    }, mt)
    _rawMetaMap[item] = mt
    _enumCache[key] = item
    return item
end

local _enumTypeCache = {}
local _Enum = hostSetmetatable({}, {
    __type = "Enums",
    __tostring = function() return "Enum" end,
    __index = function(_, enumName)
        if _enumTypeCache[enumName] then return _enumTypeCache[enumName] end
        local enumObj
        local enumMt = {
            __type = "Enum",
            __tostring = function() return "Enum." .. enumName end,
            __index = function(_, itemName)
                if itemName == "GetEnumItems" then
                    return function()
                        local items = {}
                        local def = _apiEnums[enumName]
                        if hostType(def) == "table" and hostType(def.order) == "table" then
                            for _, n in hostIpairs(def.order) do
                                items[#items + 1] = _makeEnumItem(enumName, n, def.values and def.values[n] or 0, enumObj)
                            end
                        end
                        return items
                    end
                end
                local def = _apiEnums[enumName]
                local val = hostType(def) == "table" and hostType(def.values) == "table" and def.values[itemName] or 0
                return _makeEnumItem(enumName, itemName, val, enumObj)
            end,
        }
        enumObj = hostSetmetatable({}, enumMt)
        _rawMetaMap[enumObj] = enumMt
        _enumTypeCache[enumName] = enumObj
        return enumObj
    end,
})

local _TweenInfo = {
    new = function(t, style, dir, rep, rev, del)
        local ti = {
            Time = t ~= nil and (hostTonumber(t) or 1) or 1,
            EasingStyle = style ~= nil and style or _Enum.EasingStyle.Quad,
            EasingDirection = dir ~= nil and dir or _Enum.EasingDirection.Out,
            RepeatCount = rep ~= nil and (hostTonumber(rep) or 0) or 0,
            Reverses = rev == true,
            DelayTime = del ~= nil and (hostTonumber(del) or 0) or 0,
        }
        return hostSetmetatable(ti, {
            __type = "TweenInfo",
            __tostring = function(s)
                return string.format("Time:%g DelayTime:%g RepeatCount:%d Reverses:%s EasingDirection:%s EasingStyle:%s",
                    s.Time, s.DelayTime, s.RepeatCount, hostTostring(s.Reverses),
                    hostTostring(s.EasingDirection), hostTostring(s.EasingStyle))
            end,
        })
    end
}

_OverlapParams = {
    new = function()
        return hostSetmetatable({ FilterDescendantsInstances = {}, IncludeInstances = {}, ExcludeInstances = {}, FilterType = _Enum.RaycastFilterType.Exclude, MaxParts = 0, RespectCanCollide = false, CollisionGroup = "Default" }, { __type = "OverlapParams" })
    end
}
_RaycastParams = {
    new = function()
        return hostSetmetatable({ FilterDescendantsInstances = {}, FilterType = _Enum.RaycastFilterType.Exclude, IgnoreWater = false, RespectCanCollide = false, CollisionGroup = "Default" }, { __type = "RaycastParams" })
    end
}
local _Path2DControlPoint = {
    new = function(pos, p0, p1)
        local obj = {
            Position = pos or _UDim2.new(),
            ControlPoint0 = p0 or _UDim2.new(),
            ControlPoint1 = p1 or _UDim2.new(),
        }
        local mt = { __type = "Path2DControlPoint" }
        _rawMetaMap[obj] = mt
        return hostSetmetatable(obj, mt)
    end,
}
local _RotationCurveKey = {
    new = function(time, val, interp)
        local obj = {
            Time = time or 0,
            Value = val or _CFrame.new(),
            Interpolation = interp or _Enum.KeyInterpolationMode.Linear,
        }
        local mt = { __type = "RotationCurveKey" }
        _rawMetaMap[obj] = mt
        return hostSetmetatable(obj, mt)
    end,
}

local _signalListeners = hostSetmetatable({}, { __mode = "k" })

local function _makeSignal(signalName)
    local listeners = {}
    local sig
    sig = hostSetmetatable({
        Connect = function(_, fn)
            local connObj
            connObj = {
                Connected = true,
                Enabled = true,
                ForeignState = false,
                LuaConnection = true,
                Function = hostType(fn) == "function" and fn or nil,
                Thread = coroutine and coroutine.running and coroutine.running() or nil,
            }
            connObj.Disconnect = function() connObj.Connected = false end
            connObj.disconnect = connObj.Disconnect
            connObj.Disable = function() connObj.Enabled = false end
            connObj.Enable = function() connObj.Enabled = true end
            connObj.Fire = function(_, ...)
                if connObj.Function then return connObj.Function(...) end
            end
            connObj.Defer = connObj.Fire
            local proxyConn = hostSetmetatable(connObj, { __type = "RBXScriptConnection" })
            if hostType(fn) == "function" then
                listeners[#listeners + 1] = { conn = proxyConn, fn = fn }
            end
            return proxyConn
        end,
        Once = function(self, fn)
            local c
            c = self:Connect(function(...)
                if c then c:Disconnect() end
                if hostType(fn) == "function" then fn(...) end
            end)
            return c
        end,
        Wait = function() return 1 / 60 end,
        Fire = function(_, ...)
            for _, entry in hostIpairs(listeners) do
                if entry.conn.Connected and entry.conn.Enabled ~= false then
                    hostPcall(entry.fn, ...)
                end
            end
        end,
    }, {
        __type = "RBXScriptSignal",
        __tostring = function() return "Signal " .. hostTostring(signalName or "Event") end,
    })
    sig.connect = sig.Connect
    sig.wait = sig.Wait
    _signalListeners[sig] = listeners
    return sig
end

-- Forward declaration for Instance factory
local _createInstance
local _sandboxEnv
local _game
local _workspace
local _services

local function _getCachedSignal(storeMap, base, key, label)
    local map = storeMap[base]
    if not map then
        map = {}
        storeMap[base] = map
    end
    local sig = map[key]
    if not sig then
        sig = _makeSignal(label or key)
        map[key] = sig
    end
    return sig
end

local function _fireExistingSignal(storeMap, base, key, ...)
    local map = base and storeMap[base]
    local sig = map and map[key]
    if sig and sig.Fire then
        sig:Fire(...)
    end
end

local _knownSignalNames = {
    Heartbeat = true, RenderStepped = true, Stepped = true,
    PreRender = true, PostSimulation = true, PreSimulation = true,
    CharacterAdded = true, CharacterRemoving = true,
    PlayerAdded = true, PlayerRemoving = true,
    Changed = true, ChildAdded = true, ChildRemoved = true,
    DescendantAdded = true, DescendantRemoving = true,
    AncestryChanged = true, AttributeChanged = true, Destroying = true,
    OnClientEvent = true, OnServerEvent = true, Event = true,
    Triggered = true, TriggerEnded = true, PromptShown = true, PromptHidden = true,
    InputHoldBegan = true, InputHoldEnded = true,
    MouseClick = true, RightMouseClick = true, MouseHoverEnter = true, MouseHoverLeave = true,
    Equipped = true, Unequipped = true, Activated = true, Deactivated = true,
    Played = true, Stopped = true, Paused = true, Resumed = true, Ended = true, DidLoop = true,
    Completed = true, Touched = true, TouchEnded = true,
    Died = true, Running = true, Jumping = true, HealthChanged = true, StateChanged = true,
    KeyframeReached = true, MarkerReached = true,
}

local function _updateSubtreePaths(base)
    local p = _proxyProps[base]
    if not p then return end
    if base == _game then
        _proxyPaths[base] = "game"
    elseif base == _workspace then
        _proxyPaths[base] = "workspace"
    else
        local par = _proxyParent[base]
        if par == _game and _services and _services[p.ClassName] == base then
            _proxyPaths[base] = 'game:GetService("' .. p.ClassName .. '")'
        else
            local parPath = par and _proxyPaths[par]
            local nm = p.Name or p.ClassName or "Instance"
            _proxyPaths[base] = parPath and (parPath .. "." .. nm) or nm
        end
    end
    for _, ch in hostIpairs(_proxyChildren[base] or {}) do
        _updateSubtreePaths(ch)
    end
end

local function _isDescendantInternal(base, ancestorBase)
    local cur = _proxyParent[base]
    while cur do
        if (_refBaseMap[cur] or cur) == ancestorBase then return true end
        cur = _proxyParent[cur]
    end
    return false
end

local function _setParentInternal(base, newParent, errLevel)
    errLevel = errLevel or 2
    local props = _proxyProps[base]
    local selfName = (props and (props.Name or props.ClassName)) or "Instance"
    if base == _game then
        hostError("The Parent property of Game is locked", errLevel)
    end
    if _destroyedMap[base] then
        local newName = newParent == nil and "NULL" or hostTostring(newParent)
        hostError(string.format("The Parent property of %s is locked, current parent: NULL, new parent %s", selfName, newName), errLevel)
    end
    if newParent ~= nil then
        if not _proxyTypes[newParent] then
            hostError("Unable to assign property Parent. Object expected, got " .. _sandboxTypeof(newParent), errLevel)
        end
        local baseParent = _refBaseMap[newParent] or newParent
        if _destroyedMap[baseParent] then
            hostError(string.format("The Parent property of %s is locked", selfName), errLevel)
        end
        if baseParent == base or _isDescendantInternal(baseParent, base) then
            hostError(string.format("Attempt to set parent of %s to %s would result in circular reference", selfName, hostTostring(baseParent)), errLevel)
        end
        newParent = baseParent
    end
    local oldPar = _proxyParent[base]
    if oldPar == newParent then return end
    if oldPar and _proxyChildren[oldPar] then
        for i, ch in hostIpairs(_proxyChildren[oldPar]) do
            if ch == base then
                table.remove(_proxyChildren[oldPar], i)
                break
            end
        end
        _fireExistingSignal(_proxySignals, oldPar, "ChildRemoved", base)
        local anc = oldPar
        while anc do
            _fireExistingSignal(_proxySignals, anc, "DescendantRemoving", base)
            anc = _proxyParent[anc]
        end
    end
    _proxyParent[base] = newParent
    if newParent and _proxyChildren[newParent] then
        _proxyChildren[newParent][#_proxyChildren[newParent] + 1] = base
        _fireExistingSignal(_proxySignals, newParent, "ChildAdded", base)
        local anc = newParent
        while anc do
            _fireExistingSignal(_proxySignals, anc, "DescendantAdded", base)
            anc = _proxyParent[anc]
        end
    end
    _updateSubtreePaths(base)
    _fireExistingSignal(_proxySignals, base, "AncestryChanged", base, newParent)
    _fireExistingSignal(_proxyPropSignals, base, "Parent")
    if not _isClassA(props and props.ClassName or "", "ValueBase") then
        _fireExistingSignal(_proxySignals, base, "Changed", "Parent")
    end
end

local function _destroyInternal(base)
    if base == _game then return end
    if _destroyedMap[base] then return end
    _fireExistingSignal(_proxySignals, base, "Destroying")
    local children = _proxyChildren[base]
    if children then
        local copy = {}
        for i = 1, #children do copy[i] = children[i] end
        for i = 1, #copy do
            _destroyInternal(copy[i])
        end
        _proxyChildren[base] = {}
    end
    if _editableMeshes[base] then
        _editableMeshes[base].verts = {}
        _editableMeshes[base].nextId = 1
    end
    local par = _proxyParent[base]
    if par and _proxyChildren[par] then
        for i, ch in hostIpairs(_proxyChildren[par]) do
            if ch == base then table.remove(_proxyChildren[par], i) break end
        end
        _fireExistingSignal(_proxySignals, par, "ChildRemoved", base)
    end
    _proxyParent[base] = nil
    _destroyedMap[base] = true
    _allInstances[base] = nil
end

local function _copyInstanceState(srcBase, dstBase)
    local srcProps = _proxyProps[srcBase]
    local dstProps = _proxyProps[dstBase]
    if srcProps and dstProps then
        for k, v in hostPairs(srcProps) do
            if k ~= "ClassName" and k ~= "Parent" and hostType(v) ~= "function" then
                local mt = hostType(v) == "table" and (_rawMetaMap[v] or hostGetmetatable(v))
                local tp = hostType(mt) == "table" and rawget(mt, "__type")
                if tp ~= "RBXScriptSignal" then
                    dstProps[k] = v
                end
            end
        end
    end
    local srcAttrs = _proxyAttrs[srcBase]
    if srcAttrs then
        local dstAttrs = {}
        for k, v in hostPairs(srcAttrs) do dstAttrs[k] = v end
        _proxyAttrs[dstBase] = dstAttrs
    end
    local srcTags = _proxyTags[srcBase]
    if srcTags then
        local dstTags = {}
        for k, v in hostPairs(srcTags) do dstTags[k] = v end
        _proxyTags[dstBase] = dstTags
    end
end

local function _cloneRecursive(srcBase, cloneParent)
    if _destroyedMap[srcBase] then return nil end
    local p = _proxyProps[srcBase] or {}
    if p.Archivable == false then return nil end
    local cn = p.ClassName or "Folder"
    local clone = _createInstance(cn, p.Name or cn, nil)
    local cloneBase = _refBaseMap[clone] or clone
    _copyInstanceState(srcBase, cloneBase)
    for _, ch in hostIpairs(_proxyChildren[srcBase] or {}) do
        _cloneRecursive(ch, cloneBase)
    end
    if cloneParent then
        _setParentInternal(cloneBase, cloneParent, 3)
    else
        _updateSubtreePaths(cloneBase)
    end
    return clone
end

-- Method & property caches per instance proxy
local function _makeInstanceProxy(className, name, parent, extraProps)
    local inst = {}
    _proxyTypes[inst]    = "Instance"
    _proxyPaths[inst]    = name or className
    _proxyChildren[inst] = {}
    _proxyParent[inst]   = nil
    _allInstances[inst]  = true
    local props = {
        ClassName  = className,
        Name       = name or className,
        Archivable = true,
    }
    if hostType(extraProps) == "table" then
        for k, v in hostPairs(extraProps) do
            props[k] = v
        end
    end
    _proxyProps[inst] = props
    if parent ~= nil then
        _setParentInternal(inst, parent, 3)
    end

    local methodCache = {}

    local function _baseMethod(key)
        if key == "IsA" then
            return function(self, ...)
                if select("#", ...) == 0 or ... == nil then
                    hostError("Argument 1 missing or nil", 2)
                end
                local target = ...
                local p = _proxyProps[_refBaseMap[self] or self] or props
                return _isClassA(p.ClassName or className, hostTostring(target))
            end
        elseif key == "GetService" or key == "getService" then
            return function(self, svcName)
                if svcName == nil then hostError("Argument 1 missing or nil", 2) end
                svcName = hostTostring(svcName)
                return _sandboxEnv.game[svcName]
            end
        elseif key == "FindService" then
            return function(self, svcName)
                if svcName == nil then hostError("Argument 1 missing or nil", 2) end
                svcName = hostTostring(svcName)
                return _services and _services[svcName] or nil
            end
        elseif key == "FindFirstChild" or key == "findFirstChild" then
            return function(self, targetName, recursive)
                if targetName == nil then hostError("Argument 1 missing or nil", 2) end
                local base = _refBaseMap[self] or self
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    local cp = _proxyProps[ch]
                    if cp and cp.Name == targetName then return ch end
                end
                if recursive then
                    local queue = { base }
                    while #queue > 0 do
                        local cur = table.remove(queue, 1)
                        for _, ch in hostIpairs(_proxyChildren[cur] or {}) do
                            local cp = _proxyProps[ch]
                            if cp and cp.Name == targetName then return ch end
                            queue[#queue + 1] = ch
                        end
                    end
                end
                return nil
            end
        elseif key == "FindFirstChildOfClass" or key == "FindFirstChildWhichIsA" then
            return function(self, targetClass, recursive)
                if targetClass == nil then hostError("Argument 1 missing or nil", 2) end
                local base = _refBaseMap[self] or self
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    local cp = _proxyProps[ch]
                    if cp and (cp.ClassName == targetClass or (key == "FindFirstChildWhichIsA" and _isClassA(cp.ClassName or "", targetClass))) then
                        return ch
                    end
                end
                if recursive then
                    local queue = { base }
                    while #queue > 0 do
                        local cur = table.remove(queue, 1)
                        for _, ch in hostIpairs(_proxyChildren[cur] or {}) do
                            local cp = _proxyProps[ch]
                            if cp and (cp.ClassName == targetClass or (key == "FindFirstChildWhichIsA" and _isClassA(cp.ClassName or "", targetClass))) then
                                return ch
                            end
                            queue[#queue + 1] = ch
                        end
                    end
                end
                return nil
            end
        elseif key == "FindFirstAncestor" or key == "FindFirstAncestorOfClass" or key == "FindFirstAncestorWhichIsA" then
            return function(self, target)
                if target == nil then hostError("Argument 1 missing or nil", 2) end
                local cur = _proxyParent[_refBaseMap[self] or self]
                while cur do
                    local cp = _proxyProps[cur]
                    if cp then
                        if (key == "FindFirstAncestor" and cp.Name == target)
                            or (key == "FindFirstAncestorOfClass" and cp.ClassName == target)
                            or (key == "FindFirstAncestorWhichIsA" and _isClassA(cp.ClassName or "", target)) then
                            return cur
                        end
                    end
                    cur = _proxyParent[cur]
                end
                return nil
            end
        elseif key == "WaitForChild" then
            return function(self, childName, timeout)
                if childName == nil then hostError("Argument 1 missing or nil", 2) end
                local base = _refBaseMap[self] or self
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    local cp = _proxyProps[ch]
                    if cp and cp.Name == childName then return ch end
                end
                if timeout ~= nil then
                    return nil
                end
                return _createInstance("Folder", childName, base)
            end
        elseif key == "GetChildren" or key == "getChildren" then
            return function(self)
                local base = _refBaseMap[self] or self
                local out = {}
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    out[#out + 1] = ch
                end
                return out
            end
        elseif key == "GetDescendants" or key == "getDescendants" then
            return function(self)
                local base = _refBaseMap[self] or self
                local out = {}
                local function walk(node)
                    for _, ch in hostIpairs(_proxyChildren[node] or {}) do
                        out[#out + 1] = ch
                        walk(ch)
                    end
                end
                walk(base)
                return out
            end
        elseif key == "IsDescendantOf" then
            return function(self, ...)
                if select("#", ...) == 0 then hostError("Argument 1 missing or nil", 2) end
                local ancestor = ...
                if ancestor == nil then return false end
                return _isDescendantInternal(_refBaseMap[self] or self, _refBaseMap[ancestor] or ancestor)
            end
        elseif key == "IsAncestorOf" then
            return function(self, ...)
                if select("#", ...) == 0 then hostError("Argument 1 missing or nil", 2) end
                local desc = ...
                if desc == nil then return false end
                return _isDescendantInternal(_refBaseMap[desc] or desc, _refBaseMap[self] or self)
            end
        elseif key == "GetJoints" then
            return function(self)
                local base = _refBaseMap[self] or self
                if not _isDescendantInternal(base, _workspace) then
                    return {}
                end
                local out = {}
                local function walk(node)
                    for _, ch in hostIpairs(_proxyChildren[node] or {}) do
                        local cp = _proxyProps[ch]
                        local cn = cp and cp.ClassName
                        if cp and (cn == "Weld" or cn == "WeldConstraint" or cn == "Motor6D" or cn == "ManualWeld" or cn == "Snap" or cn == "Glue" or cn == "Motor") then
                            if cp.Enabled ~= false and (cp.Part0 == base or cp.Part1 == base) then
                                local p0, p1 = cp.Part0, cp.Part1
                                if p0 and p1 and _isDescendantInternal(_refBaseMap[p0] or p0, _workspace) and _isDescendantInternal(_refBaseMap[p1] or p1, _workspace) then
                                    out[#out + 1] = ch
                                end
                            end
                        end
                        walk(ch)
                    end
                end
                walk(_workspace)
                return out
            end
        elseif key == "Clone" or key == "clone" then
            return function(self)
                return _cloneRecursive(_refBaseMap[self] or self, nil)
            end
        elseif key == "Destroy" or key == "Remove" or key == "destroy" then
            return function(self)
                _destroyInternal(_refBaseMap[self] or self)
            end
        elseif key == "ClearAllChildren" then
            return function(self)
                local base = _refBaseMap[self] or self
                local children = _proxyChildren[base] or {}
                local copy = {}
                for i = 1, #children do copy[i] = children[i] end
                for i = 1, #copy do
                    _setParentInternal(copy[i], nil, 2)
                end
            end
        elseif key == "GetAttribute" then
            return function(self, attr)
                if attr == nil then hostError("Argument 1 missing or nil", 2) end
                local attrs = _proxyAttrs[_refBaseMap[self] or self]
                return attrs and attrs[hostTostring(attr)]
            end
        elseif key == "SetAttribute" then
            return function(self, ...)
                if select("#", ...) < 2 or ... == nil then hostError("Argument 1 or 2 missing or nil", 2) end
                local attr, val = ...
                local base = _refBaseMap[self] or self
                local attrName = hostTostring(attr)
                local attrs = _proxyAttrs[base]
                if not attrs then
                    attrs = {}
                    _proxyAttrs[base] = attrs
                end
                local old = attrs[attrName]
                attrs[attrName] = val
                if old ~= val then
                    _fireExistingSignal(_proxyAttrSignals, base, attrName)
                    _fireExistingSignal(_proxySignals, base, "AttributeChanged", attrName)
                end
            end
        elseif key == "GetAttributes" then
            return function(self)
                local out = {}
                local attrs = _proxyAttrs[_refBaseMap[self] or self]
                if attrs then
                    for k, v in hostPairs(attrs) do out[k] = v end
                end
                return out
            end
        elseif key == "GetPropertyChangedSignal" then
            return function(self, propName)
                if propName == nil then hostError("Argument 1 missing or nil", 2) end
                return _getCachedSignal(_proxyPropSignals, _refBaseMap[self] or self, hostTostring(propName), propName)
            end
        elseif key == "GetAttributeChangedSignal" then
            return function(self, attrName)
                if attrName == nil then hostError("Argument 1 missing or nil", 2) end
                return _getCachedSignal(_proxyAttrSignals, _refBaseMap[self] or self, hostTostring(attrName), attrName)
            end
        elseif key == "AddTag" then
            return function(self, tag)
                if tag == nil then hostError("Argument 1 missing or nil", 2) end
                local base = _refBaseMap[self] or self
                local tags = _proxyTags[base]
                if not tags then tags = {}; _proxyTags[base] = tags end
                tags[hostTostring(tag)] = true
            end
        elseif key == "RemoveTag" then
            return function(self, tag)
                if tag == nil then hostError("Argument 1 missing or nil", 2) end
                local base = _refBaseMap[self] or self
                local tags = _proxyTags[base]
                if tags then tags[hostTostring(tag)] = nil end
            end
        elseif key == "HasTag" then
            return function(self, tag)
                if tag == nil then hostError("Argument 1 missing or nil", 2) end
                local tags = _proxyTags[_refBaseMap[self] or self]
                return tags ~= nil and tags[hostTostring(tag)] == true
            end
        elseif key == "GetTags" then
            return function(self)
                local out = {}
                local tags = _proxyTags[_refBaseMap[self] or self]
                if tags then
                    for t in hostPairs(tags) do out[#out + 1] = t end
                end
                return out
            end
        elseif key == "GetFullName" then
            return function(self)
                local base = _refBaseMap[self] or self
                return _proxyPaths[base] or ((_proxyProps[base] and _proxyProps[base].Name) or className)
            end
        elseif key == "GetDebugId" then
            return function() return "0" end
        elseif key == "GetActor" then
            return function() return nil end
        elseif key == "FireServer" or key == "InvokeServer" or key == "Fire" or key == "Invoke" then
            return function(self, ...)
                local base = _refBaseMap[self] or self
                local bp = _proxyProps[base] or props
                if bp.ClassName == "BindableEvent" and key == "Fire" then
                    _fireExistingSignal(_proxySignals, base, "Event", ...)
                    return nil
                end
                if bp.ClassName == "BindableFunction" and key == "Invoke" then
                    local cb = bp.OnInvoke
                    if hostType(cb) == "function" then
                        return cb(...)
                    end
                    return nil
                end
                local path = _proxyPaths[base] or bp.Name or "Remote"
                _emitLine(string.format("%s:%s(%s)", path, key, _formatArgs(...)))
                return nil
            end
        elseif key == "HttpGet" or key == "HttpGetAsync" then
            return function(self, url)
                _emitLine(string.format("game:%s(%s)", key, _formatArg(url)))
                return ""
            end
        elseif key == "HttpPost" or key == "HttpPostAsync" then
            return function(self, url, data)
                _emitLine(string.format("game:%s(%s, %s)", key, _formatArg(url), _formatArg(data)))
                return ""
            end
        end
        return nil
    end

    local mt = {
        __type = "Instance",
        __tostring = function(self)
            local base = _refBaseMap[self] or self
            local p = _proxyProps[base] or props
            return p.Name or p.ClassName or className
        end,
        __metatable = "The metatable is locked",
        __index = function(self, key)
            local base = _refBaseMap[self] or self
            if key == "Parent" then return _proxyParent[base] end
            local p = _proxyProps[base] or props
            if p[key] ~= nil then return p[key] end
            if methodCache[key] then return methodCache[key] end
            local bm = _baseMethod(key)
            if bm then
                methodCache[key] = bm
                return bm
            end
            for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                local cp = _proxyProps[ch]
                if cp and cp.Name == key then return ch end
            end
            local cn = p.ClassName or className
            if _knownSignalNames[key] or _hasApiMember(cn, "E", key) then
                return _getCachedSignal(_proxySignals, base, key, key)
            end
            if _hasApiMember(cn, "P", key) or _hasApiMember(cn, "C", key) then
                return nil
            end
            local isSvc = _services and _services[cn] == base
            local isApiMethod = isSvc and _hasApiMember(cn, "F", key)
            local fn = function(self, ...)
                if isApiMethod and self ~= nil and (_refBaseMap[self] or self) == base then
                    local svcPrefix = (cn == "Workspace") and "workspace" or ('game:GetService("' .. cn .. '")')
                    _emitApiCall("svcm:" .. cn .. ":" .. key, string.format("%s:%s(%s)", svcPrefix, key, _formatArgs(...)), 3)
                end
                return nil
            end
            _cclosureSet[fn] = true
            methodCache[key] = fn
            return fn
        end,
        __newindex = function(self, key, val)
            local base = _refBaseMap[self] or self
            local p = _proxyProps[base] or props
            local cn = p.ClassName or className
            if key == "ClassName" then
                hostError("Unable to assign property ClassName. Property is read only", 2)
            end
            if key == "Parent" then
                _setParentInternal(base, val, 3)
                return
            end
            if key == "Name" then
                p.Name = hostTostring(val or cn)
                _updateSubtreePaths(base)
                _fireExistingSignal(_proxyPropSignals, base, "Name")
                if not _isClassA(cn, "ValueBase") then
                    _fireExistingSignal(_proxySignals, base, "Changed", "Name")
                end
                return
            end
            if cn == "Debris" and key == "MaxItems" then
                local n = hostTonumber(val)
                if n == nil then
                    hostError("Unable to assign property MaxItems. number expected", 2)
                end
                p.MaxItems = n >= 0 and math.floor(n) or math.ceil(n)
                _fireExistingSignal(_proxyPropSignals, base, "MaxItems")
                return
            end
            if cn == "IntValue" and key == "Value" then
                local n = hostTonumber(val)
                if n == nil then
                    hostError("Unable to assign property Value. number expected, got " .. _sandboxType(val), 2)
                end
                val = n >= 0 and math.floor(n) or math.ceil(n)
            elseif cn == "NumberValue" and key == "Value" then
                local n = hostTonumber(val)
                if n == nil then
                    hostError("Unable to assign property Value. number expected, got " .. _sandboxType(val), 2)
                end
                val = n
            elseif cn == "BoolValue" and key == "Value" then
                if hostType(val) ~= "boolean" then
                    hostError("Unable to assign property Value. boolean expected, got " .. _sandboxType(val), 2)
                end
            elseif cn == "Model" and key == "PrimaryPart" then
                if val ~= nil and (not _proxyTypes[val] or not val:IsA("BasePart")) then
                    hostError("Unable to assign property PrimaryPart. BasePart expected, got " .. _sandboxTypeof(val), 2)
                end
            elseif cn == "CanvasGroup" and key == "GroupTransparency" then
                local n = hostTonumber(val)
                if n == nil then
                    hostError("Unable to assign property GroupTransparency. number expected, got " .. _sandboxType(val), 2)
                end
                if n ~= n or n < 0 then n = 0 elseif n > 1 then n = 1 end
                val = n
            elseif cn == "Camera" and key == "NearPlaneZ" then
                hostError("Unable to assign property NearPlaneZ. Property is read only", 2)
            elseif cn == "Camera" and key == "FieldOfView" then
                local n = hostTonumber(val) or 70
                if n < 1 then n = 1 elseif n > 120 then n = 120 end
                val = n
            elseif cn == "Humanoid" and key == "Health" then
                local n = hostTonumber(val) or 0
                local maxH = hostTonumber(p.MaxHealth) or 100
                if n < 0 then n = 0 elseif n > maxH then n = maxH end
                val = n
                p.Health = val
                _fireExistingSignal(_proxySignals, base, "HealthChanged", val)
            elseif cn == "Lighting" and key == "ClockTime" then
                local n = hostTonumber(val) or 14
                p.ClockTime = n
                p.MinutesAfterMidnight = n * 60
                val = n
            elseif cn == "Lighting" and key == "MinutesAfterMidnight" then
                local n = hostTonumber(val) or 0
                p.MinutesAfterMidnight = n
                p.ClockTime = (n / 60) % 24
                val = n
            end
            if _isClassA(cn, "BasePart") then
                if key == "Position" and hostType(val) == "table" and val.X ~= nil then
                    local oldCf = p.CFrame
                    local rot = oldCf and oldCf._r
                    p.CFrame = _CFrame.new(val.X, val.Y, val.Z)
                    if rot and hostType(p.CFrame) == "table" then p.CFrame._r = rot end
                elseif key == "CFrame" and hostType(val) == "table" and val.X ~= nil then
                    p.Position = _Vector3.new(val.X, val.Y, val.Z)
                elseif (key == "Rotation" or key == "Orientation") and hostType(val) == "table" and val.X ~= nil then
                    local pos = p.Position or _Vector3.zero
                    local rotCf = _CFrame.fromOrientation(math.rad(val.X or 0), math.rad(val.Y or 0), math.rad(val.Z or 0))
                    p.CFrame = _CFrame.new(pos.X, pos.Y, pos.Z) * rotCf
                end
            elseif _isClassA(cn, "GuiObject") then
                if key == "Size" and hostType(val) == "table" and val.X ~= nil and val.Y ~= nil then
                    local xOff = (val.X.Offset or 0)
                    local yOff = (val.Y.Offset or 0)
                    local parentAbs = _Vector2.new(800, 600)
                    local parentObj = _proxyParent[base]
                    if parentObj and _proxyProps[parentObj] and _proxyProps[parentObj].AbsoluteSize then
                        parentAbs = _proxyProps[parentObj].AbsoluteSize
                    end
                    local absW = (parentAbs.X or 800) * (val.X.Scale or 0) + xOff
                    local absH = (parentAbs.Y or 600) * (val.Y.Scale or 0) + yOff
                    p.AbsoluteSize = _Vector2.new(absW, absH)
                elseif key == "ImageTransparency" or key == "BackgroundTransparency" or key == "TextTransparency" then
                    local n = hostTonumber(val)
                    if n ~= nil then
                        if n ~= n or n < 0 then n = 0 elseif n > 1 then n = 1 end
                        val = n
                    end
                end
            end
            p[key] = val
            _fireExistingSignal(_proxyPropSignals, base, key)
            if _isClassA(cn, "ValueBase") then
                if key == "Value" then
                    _fireExistingSignal(_proxySignals, base, "Changed", val)
                end
            else
                _fireExistingSignal(_proxySignals, base, "Changed", key)
            end
        end,
        __namecall = function(self, ...)
            local method = _currentNamecallMethod
            local fn = self[method]
            if hostType(fn) == "function" then
                return fn(self, ...)
            end
            return nil
        end,
    }
    _cclosureSet[mt.__index] = true
    _cclosureSet[mt.__newindex] = true
    _cclosureSet[mt.__namecall] = true
    hostSetmetatable(inst, mt)
    _rawMetaMap[inst] = mt
    return inst
end

local _newEditableMesh
_createInstance = function(className, name, parent, extraProps)
    className = hostTostring(className or "Folder")
    if className == "EditableMesh" and _newEditableMesh then
        local m = _newEditableMesh()
        if parent ~= nil then
            _setParentInternal(m, parent, 3)
        end
        return m
    end
    local extras = {}
    if hostType(extraProps) == "table" then
        for k, v in hostPairs(extraProps) do extras[k] = v end
    end
    local function setDef(k, v)
        if extras[k] == nil then extras[k] = v end
    end

    if className == "AnimationTrack" then
        setDef("IsPlaying", false)
        setDef("TimePosition", 0)
        setDef("Length", 2)
        setDef("Speed", 1)
        setDef("Play", function(self) self.IsPlaying = true end)
        setDef("Stop", function(self) self.IsPlaying = false end)
        setDef("AdjustSpeed", function(self, s) self.Speed = hostTonumber(s) or 1 end)
        setDef("GetMarkerReachedSignal", function() return _makeSignal("MarkerReached") end)
    elseif className == "Animator" then
        setDef("LoadAnimation", function(_, anim)
            return _createInstance("AnimationTrack", "AnimationTrack", nil)
        end)
        setDef("GetPlayingAnimationTracks", function() return {} end)
    elseif className == "Animation" then
        setDef("AnimationId", "")
    elseif className == "Humanoid" then
        setDef("Health", 100)
        setDef("MaxHealth", 100)
        setDef("WalkSpeed", 16)
        setDef("JumpPower", 50)
        setDef("JumpHeight", 7.2)
        setDef("HipHeight", 0)
        setDef("AutoRotate", true)
        setDef("PlatformStand", false)
        setDef("Sit", false)
        setDef("UseJumpPower", true)
        setDef("BreakJointsOnDeath", true)
        setDef("RigType", _Enum.HumanoidRigType.R15)
        setDef("DisplayName", "")
        setDef("DisplayDistanceType", _Enum.HumanoidDisplayDistanceType.Viewer)
        setDef("HealthDisplayType", _Enum.HumanoidHealthDisplayType.DisplayWhenDamaged)
        setDef("NameOcclusion", _Enum.NameOcclusion.OccludeAll)
        setDef("HealthDisplayDistance", 100)
        setDef("NameDisplayDistance", 100)
        setDef("CameraOffset", _Vector3.zero)
        setDef("EvaluateStateMachine", true)
        setDef("MaxSlopeAngle", 89)
        setDef("Jump", false)
        setDef("TargetPoint", _Vector3.zero)
        setDef("RequiresNeck", true)
        setDef("AutomaticScalingEnabled", true)
        setDef("AutoJumpEnabled", true)
        setDef("WalkToPoint", _Vector3.zero)
        setDef("MoveDirection", _Vector3.zero)
        setDef("TakeDamage", function(self, dmg)
            local d = hostTonumber(dmg) or 0
            if d > 0 then self.Health = math.max(0, (self.Health or 100) - d) end
        end)
        setDef("GetState", function() return _Enum.HumanoidStateType.Running end)
        setDef("ChangeState", function() end)
        setDef("SetStateEnabled", function() end)
        setDef("Move", function() end)
        setDef("MoveTo", function() end)
        setDef("LoadAnimation", function(_, anim)
            return _createInstance("AnimationTrack", "AnimationTrack", nil)
        end)
        setDef("GetPlayingAnimationTracks", function() return {} end)
    elseif _isClassA(className, "BasePart") then
        setDef("Position", _Vector3.new(0, 0, 0))
        setDef("Size", className == "MeshPart" and _Vector3.new(2, 2, 2) or _Vector3.new(4, 1, 2))
        setDef("CFrame", _CFrame.new(0, 0, 0))
        setDef("Orientation", _Vector3.new(0, 0, 0))
        setDef("Rotation", _Vector3.new(0, 0, 0))
        setDef("Anchored", false)
        setDef("CanCollide", true)
        setDef("CanTouch", true)
        setDef("CanQuery", true)
        setDef("Massless", false)
        setDef("Locked", false)
        setDef("CastShadow", true)
        setDef("Transparency", 0)
        setDef("Reflectance", 0)
        setDef("Color", _Color3.fromRGB(163, 162, 165))
        setDef("BrickColor", _BrickColor.new("Medium stone grey"))
        setDef("Material", _Enum.Material.Plastic)
        setDef("AssemblyLinearVelocity", _Vector3.new(0, 0, 0))
        setDef("AssemblyAngularVelocity", _Vector3.new(0, 0, 0))
        setDef("Velocity", _Vector3.new(0, 0, 0))
        setDef("RotVelocity", _Vector3.new(0, 0, 0))
        setDef("GetMass", function(self)
            local s = self.Size or _Vector3.new(4, 1, 2)
            return (s.X or 4) * (s.Y or 1) * (s.Z or 2) * 0.7
        end)
        setDef("GetConnectedParts", function(self)
            local out = {}
            for inst in hostPairs(_allInstances) do
                if not _destroyedMap[inst] and (inst:IsA("JointInstance") or inst.ClassName == "WeldConstraint") then
                    if inst.Part0 == self and inst.Part1 and inst.Part1 ~= self then
                        out[#out + 1] = inst.Part1
                    elseif inst.Part1 == self and inst.Part0 and inst.Part0 ~= self then
                        out[#out + 1] = inst.Part0
                    end
                end
            end
            return out
        end)
        if className == "Part" then
            setDef("Shape", _Enum.PartType.Block)
            setDef("TopSurface", _Enum.SurfaceType.Smooth)
            setDef("BottomSurface", _Enum.SurfaceType.Smooth)
        elseif className == "MeshPart" then
            setDef("MeshId", "")
            setDef("TextureID", "")
            setDef("DoubleSided", false)
            setDef("RenderFidelity", _Enum.RenderFidelity.Automatic)
            setDef("CollisionFidelity", _Enum.CollisionFidelity.Default)
        elseif className == "Seat" or className == "VehicleSeat" then
            setDef("Disabled", false)
            setDef("Sit", function() end)
        elseif className == "SpawnLocation" then
            setDef("Enabled", true)
            setDef("Duration", 0)
            setDef("Neutral", true)
            setDef("AllowTeamChangeOnTouch", false)
            setDef("TeamColor", _BrickColor.new("Medium stone grey"))
        end
    elseif className == "Model" then
        setDef("WorldPivot", _CFrame.new(0, 0, 0))
        setDef("ModelStreamingMode", _Enum.ModelStreamingMode.Default)
        setDef("GetPivot", function(self)
            local pp = self.PrimaryPart
            return (pp and pp.CFrame) or self.WorldPivot or _CFrame.new()
        end)
        setDef("PivotTo", function(self, cf)
            if cf == nil then hostError("Argument 1 missing or nil", 2) end
            self.WorldPivot = cf
            if self.PrimaryPart then self.PrimaryPart.CFrame = cf end
        end)
        setDef("SetPrimaryPartCFrame", function(self, cf)
            if cf == nil then hostError("Argument 1 missing or nil", 2) end
            if self.PrimaryPart then self.PrimaryPart.CFrame = cf end
        end)
        setDef("GetPrimaryPartCFrame", function(self)
            return (self.PrimaryPart and self.PrimaryPart.CFrame) or self.WorldPivot or _CFrame.new()
        end)
        setDef("GetBoundingBox", function(self)
            local minX, minY, minZ
            local maxX, maxY, maxZ
            local descs = self:GetDescendants()
            for i = 1, #descs do
                local d = descs[i]
                if d:IsA("BasePart") then
                    local p = d.Position or _Vector3.zero
                    local s = d.Size or _Vector3.zero
                    local x0, x1 = p.X - s.X * 0.5, p.X + s.X * 0.5
                    local y0, y1 = p.Y - s.Y * 0.5, p.Y + s.Y * 0.5
                    local z0, z1 = p.Z - s.Z * 0.5, p.Z + s.Z * 0.5
                    if not minX or x0 < minX then minX = x0 end
                    if not maxX or x1 > maxX then maxX = x1 end
                    if not minY or y0 < minY then minY = y0 end
                    if not maxY or y1 > maxY then maxY = y1 end
                    if not minZ or z0 < minZ then minZ = z0 end
                    if not maxZ or z1 > maxZ then maxZ = z1 end
                end
            end
            if minX then
                local sz = _Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
                local cf = _CFrame.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
                return cf, sz
            end
            return self:GetPivot(), _Vector3.new(0, 0, 0)
        end)
        setDef("GetExtentsSize", function(self)
            local _, sz = self:GetBoundingBox()
            return sz
        end)
        setDef("MoveTo", function(self, pos)
            if hostType(pos) == "table" and pos.X ~= nil then
                self.WorldPivot = _CFrame.new(pos.X, pos.Y, pos.Z)
            end
        end)
        setDef("GetScale", function(self)
            local b = _refBaseMap[self] or self
            local pr = _proxyProps[b]
            return pr and pr._modelScale or 1
        end)
        setDef("ScaleTo", function(self, factor)
            local b = _refBaseMap[self] or self
            local pr = _proxyProps[b]
            if pr then
                local oldScale = pr._modelScale or 1
                local newScale = hostTonumber(factor) or 1
                pr._modelScale = newScale
                local ratio = oldScale > 0 and (newScale / oldScale) or newScale
                for _, desc in hostIpairs(self:GetDescendants()) do
                    if desc:IsA("BasePart") then
                        local sz = desc.Size
                        if sz and sz.X then
                            desc.Size = _Vector3.new(sz.X * ratio, sz.Y * ratio, sz.Z * ratio)
                        end
                    end
                end
            end
        end)
    elseif _isClassA(className, "JointInstance") or className == "WeldConstraint" or className == "RigidConstraint" then
        setDef("Enabled", true)
        if _isClassA(className, "JointInstance") then
            setDef("C0", _CFrame.new())
            setDef("C1", _CFrame.new())
        end
        if className == "Motor6D" or className == "Motor" then
            setDef("CurrentAngle", 0)
            setDef("DesiredAngle", 0)
            setDef("MaxVelocity", 0)
        end
    elseif className == "Attachment" then
        setDef("CFrame", _CFrame.new())
        setDef("Position", _Vector3.zero)
        setDef("WorldCFrame", _CFrame.new())
        setDef("WorldPosition", _Vector3.zero)
        setDef("Orientation", _Vector3.zero)
        setDef("Axis", _Vector3.new(1, 0, 0))
        setDef("SecondaryAxis", _Vector3.new(0, 1, 0))
        setDef("WorldAxis", _Vector3.new(1, 0, 0))
        setDef("WorldSecondaryAxis", _Vector3.new(0, 1, 0))
        setDef("Visible", false)
    elseif className == "IntValue" or className == "NumberValue" or className == "IntConstrainedValue" or className == "NumberConstrainedValue" then
        setDef("Value", 0)
    elseif className == "StringValue" then
        setDef("Value", "")
    elseif className == "BoolValue" then
        setDef("Value", false)
    elseif className == "Vector3Value" then
        setDef("Value", _Vector3.zero)
    elseif className == "CFrameValue" then
        setDef("Value", _CFrame.new())
    elseif className == "Color3Value" then
        setDef("Value", _Color3.new())
    elseif className == "BrickColorValue" then
        setDef("Value", _BrickColor.new())
    elseif className == "RayValue" then
        setDef("Value", _Ray.new())
    elseif className == "Sound" then
        setDef("SoundId", "")
        setDef("Volume", 0.5)
        setDef("PlaybackSpeed", 1)
        setDef("TimePosition", 0)
        setDef("TimeLength", 1)
        setDef("PlaybackLoudness", 0)
        setDef("Playing", false)
        setDef("IsPlaying", false)
        setDef("IsPaused", false)
        setDef("IsLoaded", true)
        setDef("Looped", false)
        setDef("PlayOnRemove", false)
        setDef("AcousticSimulationEnabled", false)
        setDef("PlaybackRegionsEnabled", false)
        setDef("PlaybackRegion", _NumberRange.new(0, 60000))
        setDef("LoopRegion", _NumberRange.new(0, 60000))
        setDef("RollOffMode", _Enum.RollOffMode.Inverse)
        setDef("RollOffMaxDistance", 10000)
        setDef("RollOffMinDistance", 10)
        setDef("Play", function(self)
            local base = _refBaseMap[self] or self
            self.Playing = true; self.IsPlaying = true; self.IsPaused = false
            _fireExistingSignal(_proxySignals, base, "Played", self.SoundId)
        end)
        setDef("Stop", function(self)
            local base = _refBaseMap[self] or self
            self.Playing = false; self.IsPlaying = false; self.IsPaused = false; self.TimePosition = 0
            _fireExistingSignal(_proxySignals, base, "Stopped", self.SoundId)
        end)
        setDef("Pause", function(self)
            local base = _refBaseMap[self] or self
            self.Playing = false; self.IsPlaying = false; self.IsPaused = true
            _fireExistingSignal(_proxySignals, base, "Paused", self.SoundId)
        end)
        setDef("Resume", function(self)
            local base = _refBaseMap[self] or self
            self.Playing = true; self.IsPlaying = true; self.IsPaused = false
            _fireExistingSignal(_proxySignals, base, "Resumed", self.SoundId)
        end)
    elseif className == "Camera" then
        setDef("CFrame", _CFrame.new())
        setDef("Focus", _CFrame.new())
        setDef("FieldOfView", 70)
        setDef("MaxAxisFieldOfView", 70)
        setDef("DiagonalFieldOfView", 88.78)
        setDef("CameraType", _Enum.CameraType.Custom)
        setDef("FieldOfViewMode", _Enum.FieldOfViewMode.Vertical)
        setDef("ViewportSize", _Vector2.new(1920, 1080))
        setDef("NearPlaneZ", -0.1)
        setDef("HeadScale", 1)
        setDef("HeadLocked", true)
        setDef("VRTiltAndRollEnabled", false)
        setDef("WorldToViewportPoint", function() return _Vector3.new(960, 540, 10), true end)
        setDef("WorldToScreenPoint", function() return _Vector3.new(960, 540, 10), true end)
        setDef("ViewportPointToRay", function() return _Ray.new(_Vector3.zero, _Vector3.new(0, 0, -1)) end)
        setDef("ScreenPointToRay", function() return _Ray.new(_Vector3.zero, _Vector3.new(0, 0, -1)) end)
    elseif className == "ProximityPrompt" then
        setDef("ActionText", "Interact")
        setDef("ObjectText", "")
        setDef("HoldDuration", 0)
        setDef("MaxActivationDistance", 10)
        setDef("Enabled", true)
        setDef("RequiresLineOfSight", true)
        setDef("KeyboardKeyCode", _Enum.KeyCode.E)
    elseif className == "ClickDetector" then
        setDef("MaxActivationDistance", 32)
        setDef("CursorIcon", "")
    elseif className == "Tool" then
        setDef("Enabled", true)
        setDef("RequiresHandle", true)
        setDef("CanBeDropped", true)
        setDef("ManualActivationOnly", false)
        setDef("Grip", _CFrame.new())
        setDef("ToolTip", "")
    elseif className == "Highlight" then
        setDef("FillColor", _Color3.fromRGB(255, 0, 0))
        setDef("OutlineColor", _Color3.fromRGB(255, 255, 255))
        setDef("FillTransparency", 0.5)
        setDef("OutlineTransparency", 0)
        setDef("DepthMode", _Enum.HighlightDepthMode.AlwaysOnTop)
        setDef("Enabled", true)
    elseif _isClassA(className, "Light") then
        setDef("Color", _Color3.new(1, 1, 1))
        setDef("Brightness", 1)
        setDef("Range", className == "PointLight" and 8 or 16)
        setDef("Enabled", true)
        setDef("Shadows", false)
        if className == "SpotLight" or className == "SurfaceLight" then
            setDef("Angle", 90)
            setDef("Face", _Enum.NormalId.Front)
        end
    elseif className == "ParticleEmitter" then
        setDef("Lifetime", _NumberRange.new(5, 10))
        setDef("Speed", _NumberRange.new(5, 5))
        setDef("Size", _NumberSequence.new(1))
        setDef("Transparency", _NumberSequence.new(0))
        setDef("Squash", _NumberSequence.new(0))
        setDef("Brightness", 1)
        setDef("LightEmission", 0)
        setDef("LightInfluence", 1)
        setDef("Acceleration", _Vector3.zero)
        setDef("Rotation", _NumberRange.new(0, 0))
        setDef("RotSpeed", _NumberRange.new(0, 0))
        setDef("Drag", 0)
        setDef("ZOffset", 0)
        setDef("TimeScale", 1)
        setDef("VelocityInheritance", 0)
        setDef("LockedToPart", false)
        setDef("WindAffectsDrag", false)
        setDef("EmissionDirection", _Enum.NormalId.Top)
        setDef("FlipbookStartRandom", false)
        setDef("FlipbookBlendFrames", true)
        setDef("FlipbookIncompatible", "")
        setDef("FlipbookLayout", _Enum.ParticleFlipbookLayout.None)
        setDef("FlipbookMode", _Enum.ParticleFlipbookMode.Loop)
        setDef("FlipbookFramerate", _NumberRange.new(1, 1))
        setDef("FlipbookSizeX", 1)
        setDef("FlipbookSizeY", 1)
        setDef("Rate", 20)
        setDef("Enabled", true)
        setDef("Texture", "")
        setDef("Shape", _Enum.ParticleEmitterShape.Box)
        setDef("ShapeInOut", _Enum.ParticleEmitterShapeInOut.Outward)
        setDef("ShapeStyle", _Enum.ParticleEmitterShapeStyle.Volume)
        setDef("ShapePartial", 1)
        setDef("Orientation", _Enum.ParticleOrientation.FacingCamera)
        setDef("SpreadAngle", _Vector2.zero)
        setDef("Emit", function() end)
        setDef("Clear", function() end)
    elseif className == "Fire" then
        setDef("Color", _Color3.fromRGB(236, 139, 70))
        setDef("SecondaryColor", _Color3.fromRGB(139, 80, 55))
        setDef("Size", 5)
        setDef("Heat", 9)
        setDef("TimeScale", 1)
        setDef("Enabled", true)
    elseif className == "Smoke" then
        setDef("Color", _Color3.new(1, 1, 1))
        setDef("Opacity", 0.5)
        setDef("Size", 1)
        setDef("RiseVelocity", 1)
        setDef("TimeScale", 1)
        setDef("Enabled", true)
    elseif className == "Beam" then
        setDef("Enabled", true)
        setDef("FaceCamera", false)
        setDef("Width0", 1)
        setDef("Width1", 1)
        setDef("Segments", 10)
        setDef("CurveSize0", 0)
        setDef("CurveSize1", 0)
        setDef("ZOffset", 0)
        setDef("LightInfluence", 0)
        setDef("LightEmission", 0)
        setDef("TextureMode", _Enum.TextureMode.Stretch)
        setDef("TextureSpeed", 1)
        setDef("TextureLength", 1)
    elseif className == "Trail" then
        setDef("Enabled", true)
        setDef("FaceCamera", false)
        setDef("Lifetime", 2)
        setDef("TextureMode", _Enum.TextureMode.Stretch)
        setDef("TextureLength", 1)
        setDef("WidthScale", _NumberSequence.new(1))
        setDef("LightInfluence", 1)
        setDef("LightEmission", 0)
        setDef("MaxLength", 0)
        setDef("MinLength", 0.1)
    elseif className == "Explosion" then
        setDef("BlastRadius", 4)
        setDef("BlastPressure", 500000)
        setDef("Position", _Vector3.zero)
        setDef("Visible", true)
        setDef("TimeScale", 1)
        setDef("ExplosionType", _Enum.ExplosionType.Craters)
        setDef("DestroyJointRadiusPercent", 1)
    elseif className == "Sparkles" then
        setDef("SparkleColor", _Color3.fromRGB(144, 25, 255))
        setDef("Color", _Color3.fromRGB(144, 25, 255))
        setDef("TimeScale", 1)
        setDef("Enabled", true)
    elseif className == "HingeConstraint" then
        setDef("ActuatorType", _Enum.ActuatorType.None)
        setDef("Enabled", true)
        setDef("LimitsEnabled", false)
        setDef("Restitution", 0)
        setDef("AngularSpeed", 0)
        setDef("AngularVelocity", 0)
        setDef("AngularResponsiveness", 45)
        setDef("ServoMaxTorque", 0)
        setDef("MotorMaxTorque", 0)
        setDef("MotorMaxAcceleration", math.huge)
        setDef("TargetAngle", 0)
        setDef("UpperAngle", 45)
        setDef("LowerAngle", -45)
        setDef("Radius", 0.15)
    elseif className == "SpringConstraint" then
        setDef("Stiffness", 1000)
        setDef("Damping", 0)
        setDef("FreeLength", 1)
        setDef("Coils", 3)
        setDef("MaxForce", math.huge)
        setDef("LimitsEnabled", false)
        setDef("MaxLength", 5)
        setDef("MinLength", 0)
        setDef("Radius", 0.4)
        setDef("Thickness", 0.1)
        setDef("Enabled", true)
    elseif className == "RopeConstraint" then
        setDef("Restitution", 0)
        setDef("Length", 5)
        setDef("Thickness", 0.1)
        setDef("WinchEnabled", false)
        setDef("WinchForce", 10000)
        setDef("WinchSpeed", 1)
        setDef("WinchTarget", 5)
        setDef("WinchResponsiveness", 45)
        setDef("Enabled", true)
    elseif className == "BallSocketConstraint" then
        setDef("Restitution", 0)
        setDef("MaxFrictionTorque", 0)
        setDef("UpperAngle", 45)
        setDef("Radius", 0.15)
        setDef("TwistLimitsEnabled", false)
        setDef("TwistUpperAngle", 45)
        setDef("TwistLowerAngle", -45)
        setDef("LimitsEnabled", false)
        setDef("Enabled", true)
    elseif className == "Sky" then
        setDef("CelestialBodiesShown", true)
        setDef("StarCount", 3000)
        setDef("MoonAngularSize", 11)
        setDef("SunAngularSize", 21)
        setDef("SkyboxOrientation", _Vector3.zero)
    elseif className == "Atmosphere" then
        setDef("Color", _Color3.fromRGB(199, 170, 107))
        setDef("Decay", _Color3.fromRGB(106, 112, 125))
        setDef("Density", 0.3)
        setDef("Offset", 0.25)
        setDef("Glare", 0)
        setDef("Haze", 0)
    elseif className == "ColorCorrectionEffect" then
        setDef("Brightness", 0)
        setDef("Contrast", 0)
        setDef("Saturation", 0)
        setDef("TintColor", _Color3.new(1, 1, 1))
        setDef("Enabled", true)
    elseif className == "BloomEffect" then
        setDef("Threshold", 2)
        setDef("Intensity", 1)
        setDef("Size", 24)
        setDef("Enabled", true)
    elseif className == "SunRaysEffect" then
        setDef("Intensity", 0.25)
        setDef("Spread", 1)
        setDef("Enabled", true)
    elseif className == "DepthOfFieldEffect" then
        setDef("NearIntensity", 0.75)
        setDef("FarIntensity", 0.75)
        setDef("FocusDistance", 0.05)
        setDef("InFocusRadius", 30)
        setDef("Enabled", true)
    elseif className == "BlurEffect" then
        setDef("Size", 24)
        setDef("Enabled", true)
    elseif className == "SpecialMesh" then
        setDef("MeshType", _Enum.MeshType.Head)
        setDef("MeshId", "")
        setDef("TextureId", "")
        setDef("Scale", _Vector3.new(1, 1, 1))
        setDef("Offset", _Vector3.zero)
        setDef("VertexColor", _Vector3.new(1, 1, 1))
    elseif className == "HumanoidDescription" then
        local emotes = {}
        setDef("HeadColor", _Color3.new(1, 1, 1))
        setDef("TorsoColor", _Color3.new(1, 1, 1))
        setDef("LeftArmColor", _Color3.new(1, 1, 1))
        setDef("RightArmColor", _Color3.new(1, 1, 1))
        setDef("LeftLegColor", _Color3.new(1, 1, 1))
        setDef("RightLegColor", _Color3.new(1, 1, 1))
        setDef("BodyTypeScale", 0.3)
        setDef("DepthScale", 1)
        setDef("HeadScale", 1)
        setDef("HeightScale", 1)
        setDef("ProportionScale", 1)
        setDef("WidthScale", 1)
        setDef("GetEmotes", function() return emotes end)
        setDef("SetEmotes", function(_, t)
            if hostType(t) == "table" then emotes = t end
        end)
        setDef("GetAccessories", function() return {} end)
        setDef("SetAccessories", function() end)
    elseif className == "Decal" or className == "Texture" then
        setDef("Texture", "")
        setDef("Transparency", 0)
        setDef("Face", _Enum.NormalId.Front)
        setDef("Color3", _Color3.new(1, 1, 1))
        setDef("ZIndex", 1)
        setDef("Rotation", 0)
        setDef("AutoLocalize", true)
        setDef("UVOffset", _Vector2.zero)
        setDef("UVScale", _Vector2.new(1, 1))
        if className == "Texture" then
            setDef("OffsetStudsU", 0)
            setDef("OffsetStudsV", 0)
            setDef("StudsPerTileU", 2)
            setDef("StudsPerTileV", 2)
        end
    elseif _isClassA(className, "LuaSourceContainer") then
        setDef("Source", "")
        setDef("Enabled", true)
        setDef("Disabled", false)
    end

    if _isClassA(className, "GuiBase2d") then
        setDef("AbsolutePosition", _Vector2.zero)
        setDef("AbsoluteSize", _Vector2.new(100, 50))
        setDef("AbsoluteRotation", 0)
        setDef("AutoLocalize", true)
        if _isClassA(className, "LayerCollector") then
            setDef("Enabled", true)
            setDef("ResetOnSpawn", true)
            setDef("ZIndexBehavior", _Enum.ZIndexBehavior.Sibling)
            if className == "ScreenGui" then
                setDef("DisplayOrder", 0)
                setDef("ClipToDeviceSafeArea", true)
                setDef("IgnoreGuiInset", false)
                setDef("ScreenInsets", _Enum.ScreenInsets.CoreUISafeArea)
                setDef("SafeAreaCompatibility", _Enum.SafeAreaCompatibility.FullscreenExtension)
            elseif className == "BillboardGui" then
                setDef("Size", _UDim2.new(0, 100, 0, 100))
                setDef("SizeOffset", _Vector2.zero)
                setDef("DistanceStep", 0)
                setDef("MaxDistance", math.huge)
                setDef("StudsOffset", _Vector3.zero)
                setDef("StudsOffsetWorldSpace", _Vector3.zero)
                setDef("ExtentsOffset", _Vector3.zero)
                setDef("ExtentsOffsetWorldSpace", _Vector3.zero)
                setDef("AlwaysOnTop", false)
                setDef("ClipsDescendants", false)
                setDef("LightInfluence", 0)
                setDef("Active", false)
            elseif className == "SurfaceGui" then
                setDef("SizingMode", _Enum.SurfaceGuiSizingMode.FixedSize)
                setDef("AlwaysOnTop", false)
                setDef("ClipsDescendants", false)
                setDef("Face", _Enum.NormalId.Front)
                setDef("PixelsPerStud", 50)
                setDef("CanvasSize", _Vector2.new(800, 600))
                setDef("ZOffset", 0)
                setDef("MaxDistance", 0)
                setDef("LightInfluence", 0)
                setDef("ToolPunchThroughDistance", 0)
            end
        elseif _isClassA(className, "GuiObject") then
            setDef("Position", _UDim2.new())
            setDef("Size", _UDim2.new(0, 100, 0, 50))
            setDef("AnchorPoint", _Vector2.zero)
            setDef("Visible", true)
            setDef("ZIndex", 1)
            setDef("LayoutOrder", 0)
            setDef("Rotation", 0)
            setDef("BackgroundColor3", _Color3.new(1, 1, 1))
            setDef("BackgroundTransparency", 0)
            setDef("BorderColor3", _Color3.fromRGB(27, 42, 53))
            setDef("BorderSizePixel", 1)
            setDef("Active", false)
            setDef("ClipsDescendants", false)
            setDef("Selectable", false)
            if className == "TextLabel" or className == "TextButton" or className == "TextBox" then
                setDef("Text", className)
                setDef("TextSize", 14)
                setDef("TextTransparency", 0)
                setDef("TextColor3", _Color3.new(0, 0, 0))
                setDef("TextStrokeColor3", _Color3.new(0, 0, 0))
                setDef("TextStrokeTransparency", 1)
                setDef("LineHeight", 1)
                setDef("TextBounds", _Vector2.new(100, 18))
                setDef("Font", _Enum.Font.SourceSans)
                setDef("FontFace", _Font.new("rbxasset://fonts/families/SourceSansPro.json"))
                setDef("MaxVisibleGraphemes", -1)
                setDef("OpenTypeFeatures", "")
                setDef("TextXAlignment", _Enum.TextXAlignment.Center)
                setDef("TextYAlignment", _Enum.TextYAlignment.Center)
                setDef("TextTruncate", _Enum.TextTruncate.None)
                setDef("TextDirection", _Enum.TextDirection.Auto)
                setDef("RichText", false)
                setDef("TextWrapped", false)
                setDef("TextScaled", false)
                if className == "TextBox" then
                    setDef("ClearTextOnFocus", true)
                    setDef("PlaceholderText", "")
                    setDef("PlaceholderColor3", _Color3.fromRGB(178, 178, 178))
                    setDef("SelectionStart", -1)
                    setDef("CursorPosition", 1)
                    setDef("MultiLine", false)
                    setDef("TextEditable", true)
                    setDef("ShowNativeInput", true)
                end
            elseif className == "Frame" then
                setDef("Style", _Enum.FrameStyle.Custom)
            elseif className == "ImageLabel" or className == "ImageButton" then
                setDef("Image", "")
                setDef("ImageColor3", _Color3.new(1, 1, 1))
                setDef("ImageTransparency", 0)
                setDef("ScaleType", _Enum.ScaleType.Stretch)
                setDef("ResampleMode", _Enum.ResamplerMode.Default)
                setDef("ImageRectOffset", _Vector2.zero)
                setDef("ImageRectSize", _Vector2.zero)
                setDef("SliceCenter", _Rect.new(0, 0, 0, 0))
                setDef("SliceScale", 1)
                setDef("TileSize", _UDim2.new(1, 0, 1, 0))
            elseif className == "ScrollingFrame" then
                setDef("CanvasSize", _UDim2.new(0, 0, 2, 0))
                setDef("CanvasPosition", _Vector2.zero)
                setDef("ScrollBarThickness", 12)
                setDef("ScrollBarImageColor3", _Color3.new(1, 1, 1))
                setDef("ScrollBarImageTransparency", 0)
                setDef("ScrollingEnabled", true)
                setDef("ElasticBehavior", _Enum.ElasticBehavior.WhenScrollable)
                setDef("ScrollingDirection", _Enum.ScrollingDirection.XY)
                setDef("VerticalScrollBarPosition", _Enum.VerticalScrollBarPosition.Right)
                setDef("HorizontalScrollBarInset", _Enum.ScrollBarInset.None)
                setDef("VerticalScrollBarInset", _Enum.ScrollBarInset.None)
                setDef("AutomaticCanvasSize", _Enum.AutomaticSize.None)
            elseif className == "ViewportFrame" then
                setDef("Ambient", _Color3.fromRGB(200, 200, 200))
                setDef("LightColor", _Color3.fromRGB(140, 140, 140))
                setDef("LightDirection", _Vector3.new(-1, -1, -1))
                setDef("ImageColor3", _Color3.new(1, 1, 1))
                setDef("ImageTransparency", 0)
            elseif className == "CanvasGroup" then
                setDef("GroupTransparency", 0)
                setDef("GroupColor3", _Color3.new(1, 1, 1))
            end
        end
    elseif className == "UICorner" then
        setDef("CornerRadius", _UDim.new(0, 8))
        setDef("TopRightRadius", _UDim.new(0, 8))
        setDef("BottomRightRadius", _UDim.new(0, 8))
        setDef("BottomLeftRadius", _UDim.new(0, 8))
        setDef("TopLeftRadius", _UDim.new(0, 8))
    elseif className == "UIStroke" then
        setDef("Thickness", 1)
        setDef("Color", _Color3.new(0, 0, 0))
        setDef("Transparency", 0)
        setDef("Enabled", true)
    elseif className == "UIScale" then
        setDef("Scale", 1)
    elseif className == "UIAspectRatioConstraint" then
        setDef("AspectRatio", 1)
        setDef("DominantAxis", _Enum.DominantAxis.Width)
        setDef("AspectType", _Enum.AspectType.FitWithinMaxSize)
    elseif className == "UITextSizeConstraint" then
        setDef("MinTextSize", 1)
        setDef("MaxTextSize", 100)
    elseif className == "UIPadding" then
        setDef("PaddingTop", _UDim.new())
        setDef("PaddingBottom", _UDim.new())
        setDef("PaddingLeft", _UDim.new())
        setDef("PaddingRight", _UDim.new())
    elseif className == "UIListLayout" then
        setDef("Padding", _UDim.new(0, 0))
        setDef("FillDirection", _Enum.FillDirection.Vertical)
        setDef("HorizontalAlignment", _Enum.HorizontalAlignment.Left)
        setDef("VerticalAlignment", _Enum.VerticalAlignment.Top)
        setDef("SortOrder", _Enum.SortOrder.LayoutOrder)
        setDef("HorizontalFlex", _Enum.UIFlexAlignment.None)
        setDef("VerticalFlex", _Enum.UIFlexAlignment.None)
        setDef("ItemLineAlignment", _Enum.ItemLineAlignment.Automatic)
        setDef("Wraps", false)
    elseif className == "UIGridLayout" then
        setDef("StartCorner", _Enum.StartCorner.TopLeft)
        setDef("CellSize", _UDim2.new(0, 100, 0, 100))
        setDef("CellPadding", _UDim2.new(0, 5, 0, 5))
        setDef("FillDirection", _Enum.FillDirection.Horizontal)
        setDef("FillDirectionMaxCells", 0)
        setDef("SortOrder", _Enum.SortOrder.LayoutOrder)
    end
    if className == "Path2D" then
        local ctrlPts = {}
        setDef("Closed", false)
        setDef("Thickness", 1)
        setDef("Visible", true)
        setDef("ZIndex", 1)
        setDef("Color3", _Color3.new(1, 1, 1))
        setDef("Transparency", 0)
        setDef("SetControlPoints", function(_, pts)
            ctrlPts = {}
            if hostType(pts) == "table" then
                for i, v in hostIpairs(pts) do ctrlPts[i] = v end
            end
        end)
        setDef("GetControlPoints", function()
            local out = {}
            for i, v in hostIpairs(ctrlPts) do out[i] = v end
            return out
        end)
        setDef("UpdateControlPoint", function(_, idx, pt)
            local i = hostTonumber(idx)
            if i and i >= 1 and pt ~= nil then
                ctrlPts[i] = pt
            end
        end)
        setDef("InsertControlPoint", function(_, idx, pt)
            local i = hostTonumber(idx)
            if i and i >= 1 and pt ~= nil then
                table.insert(ctrlPts, i, pt)
            end
        end)
        setDef("RemoveControlPoint", function(_, idx)
            local i = hostTonumber(idx)
            if i and ctrlPts[i] then
                table.remove(ctrlPts, i)
            end
        end)
        setDef("GetMaxControlPoints", function() return 100 end)
        local function samplePos(_, t)
            local u = hostTonumber(t) or 0
            if #ctrlPts >= 2 then
                local p0 = ctrlPts[1] and ctrlPts[1].Position or _UDim2.new()
                local p1 = ctrlPts[#ctrlPts] and ctrlPts[#ctrlPts].Position or _UDim2.new()
                return _UDim2.new(
                    p0.X.Scale + (p1.X.Scale - p0.X.Scale) * u,
                    p0.X.Offset + (p1.X.Offset - p0.X.Offset) * u,
                    p0.Y.Scale + (p1.Y.Scale - p0.Y.Scale) * u,
                    p0.Y.Offset + (p1.Y.Offset - p0.Y.Offset) * u
                )
            elseif #ctrlPts == 1 and ctrlPts[1] and ctrlPts[1].Position then
                return ctrlPts[1].Position
            end
            return _UDim2.new()
        end
        setDef("Sample", samplePos)
        setDef("GetPositionOnCurve", samplePos)
        setDef("GetPositionOnCurveArcLength", samplePos)
        local function tangentPos()
            if #ctrlPts >= 2 then
                local p0 = ctrlPts[1] and ctrlPts[1].Position
                local p1 = ctrlPts[#ctrlPts] and ctrlPts[#ctrlPts].Position
                if p0 and p1 then
                    local dx = (p1.X.Offset - p0.X.Offset)
                    local dy = (p1.Y.Offset - p0.Y.Offset)
                    local len = (dx * dx + dy * dy) ^ 0.5
                    if len > 1e-6 then
                        return _Vector2.new(dx / len, dy / len)
                    end
                end
            end
            return _Vector2.new(1, 0)
        end
        setDef("GetTangentOnCurve", tangentPos)
        setDef("GetTangentOnCurveArcLength", tangentPos)
    elseif className == "RotationCurve" then
        local rotKeys = {}
        setDef("InsertKey", function(_, key)
            rotKeys[#rotKeys + 1] = key
        end)
        setDef("GetKeys", function()
            local out = {}
            for i, v in hostIpairs(rotKeys) do out[i] = v end
            return out
        end)
        setDef("RemoveKeyAtIndex", function(_, idx, count)
            local i = hostTonumber(idx)
            local n = hostTonumber(count) or 1
            local removed = 0
            if i and i >= 1 then
                for _ = 1, n do
                    if rotKeys[i] then
                        table.remove(rotKeys, i)
                        removed = removed + 1
                    end
                end
            end
            return removed
        end)
        setDef("GetValueAtTime", function(_, t)
            return (rotKeys[1] and rotKeys[1].Value) or _CFrame.new()
        end)
    end

    local obj = _makeInstanceProxy(className, name or className, parent, extras)
    return obj
end

-- Build DataModel (`game`) and Services
_game = _makeInstanceProxy("DataModel", "Game", nil, {
    PlaceId = 123456789,
    PlaceVersion = 1,
    PrivateServerId = "",
    PrivateServerOwnerId = 0,
    GameId = 987654321,
    JobId = "00000000-0000-0000-0000-000000000000",
    CreatorId = 1,
    IsLoaded = function() return true end,
})
_proxyPaths[_game] = "game"

_services = {}
local function _registerService(className, extraProps)
    local wrappedProps = {}
    if hostType(extraProps) == "table" then
        local svcPrefix = (className == "Workspace") and "workspace" or ('game:GetService("' .. className .. '")')
        for k, v in hostPairs(extraProps) do
            if hostType(v) == "function" and not (className == "HttpService" and k == "GetAsync") then
                local origFn = v
                local callKey = "svcm:" .. className .. ":" .. hostTostring(k)
                local wrapped = function(...)
                    local res = hostPack(origFn(...))
                    local first = ...
                    if first ~= nil and (_refBaseMap[first] or first) == _services[className] then
                        _emitApiCall(callKey, string.format("%s:%s(%s)", svcPrefix, hostTostring(k), _formatArgs(select(2, ...))), 3)
                    else
                        _emitApiCall(callKey, string.format("%s.%s(%s)", svcPrefix, hostTostring(k), _formatArgs(...)), 3)
                    end
                    return hostUnpack(res, 1, res.n)
                end
                _cclosureSet[wrapped] = true
                wrappedProps[k] = wrapped
            else
                wrappedProps[k] = v
            end
        end
    end
    local svc = _makeInstanceProxy(className, className, _game, wrappedProps)
    _proxyPaths[svc] = (className == "Workspace") and "workspace" or ('game:GetService("' .. className .. '")')
    _services[className] = svc
    return svc
end

_workspace = _registerService("Workspace", {
    Gravity = 196.2,
    DistributedGameTime = 10,
    StreamingEnabled = false,
    FallenPartsDestroyHeight = -500,
    AirDensity = 0.0012,
    AirTurbulenceIntensity = 1,
    FallHeightEnabled = true,
    GlobalWind = _Vector3.zero,
    AllowThirdPartySales = false,
    InsertPoint = _Vector3.zero,
    Retargeting = _Enum.AnimatorRetargetingMode.Default,
    ClientAnimatorThrottling = _Enum.ClientAnimatorThrottlingMode.Default,
    GetPartBoundsInBox = function(self, cf, size, params)
        if params ~= nil then
            local mt = hostType(params) == "table" and (_rawMetaMap[params] or hostGetmetatable(params))
            if hostType(mt) ~= "table" or rawget(mt, "__type") ~= "OverlapParams" then
                hostError("Unable to cast value to Object", 2)
            end
        end
        local filterType = params and params.FilterType or _Enum.RaycastFilterType.Exclude
        local incList = nil
        local excList = nil
        if filterType == _Enum.RaycastFilterType.Include then
            local f = params and (params.FilterDescendantsInstances or params.IncludeInstances)
            if hostType(f) == "table" then incList = f end
        else
            local f = params and (params.FilterDescendantsInstances or params.ExcludeInstances)
            if hostType(f) == "table" then excList = f end
            local inc = params and params.IncludeInstances
            if hostType(inc) == "table" and #inc > 0 then incList = inc end
        end
        local function isDescendantOfAny(inst, list)
            if not list then return false end
            for _, root in hostIpairs(list) do
                if inst == root or (inst.IsDescendantOf and inst:IsDescendantOf(root)) then
                    return true
                end
            end
            return false
        end
        local boxPos = hostType(cf) == "table" and (cf.Position or (cf.p or _Vector3.zero)) or _Vector3.zero
        local boxSize = hostType(size) == "table" and size or _Vector3.new(4, 4, 4)
        local halfX = (boxSize.X or 4) * 0.5
        local halfY = (boxSize.Y or 4) * 0.5
        local halfZ = (boxSize.Z or 4) * 0.5
        local out = {}
        for inst in hostPairs(_allInstances) do
            if not _destroyedMap[inst] and inst.ClassName ~= "Terrain" and inst:IsA("BasePart") and _proxyParent[inst] ~= nil then
                local p = _proxyProps[inst]
                if p and p.CanQuery ~= false then
                    local skip = false
                    if excList and isDescendantOfAny(inst, excList) then
                        skip = true
                    elseif incList and not isDescendantOfAny(inst, incList) then
                        skip = true
                    end
                    if not skip then
                        local pos = p.Position or _Vector3.zero
                        if math.abs(pos.X - boxPos.X) <= (halfX + (p.Size and p.Size.X or 2) * 0.5)
                           and math.abs(pos.Y - boxPos.Y) <= (halfY + (p.Size and p.Size.Y or 2) * 0.5)
                           and math.abs(pos.Z - boxPos.Z) <= (halfZ + (p.Size and p.Size.Z or 2) * 0.5) then
                            out[#out + 1] = inst
                        end
                    end
                end
            end
        end
        return out
    end,
    GetPartBoundsInRadius = function(self, pos, radius, params)
        return self:GetPartBoundsInBox(_CFrame.new(pos), _Vector3.new(radius, radius, radius), params)
    end,
    GetPartsInPart = function(self, part, params)
        if part == nil or not _proxyTypes[part] then
            hostError("Unable to cast value to Object", 2)
        end
        return self:GetPartBoundsInBox(_CFrame.new(), _Vector3.new(4, 4, 4), params)
    end,
    Raycast = function(self, origin, direction, params)
        if hostType(origin) ~= "table" or origin.X == nil or hostType(direction) ~= "table" or direction.X == nil then
            return nil
        end
        local incList, excList
        local filterType = _Enum.RaycastFilterType.Exclude
        if params ~= nil then
            local mt = hostType(params) == "table" and (_rawMetaMap[params] or hostGetmetatable(params))
            if hostType(mt) == "table" and rawget(mt, "__type") == "RaycastParams" then
                filterType = params.FilterType or _Enum.RaycastFilterType.Exclude
                local f = params.FilterDescendantsInstances
                if hostType(f) == "table" then
                    if filterType == _Enum.RaycastFilterType.Include then
                        incList = f
                    else
                        excList = f
                    end
                end
            end
        end
        local function isDescendantOfAny(inst, list)
            if not list then return false end
            for _, root in hostIpairs(list) do
                if inst == root or (inst.IsDescendantOf and inst:IsDescendantOf(root)) then
                    return true
                end
            end
            return false
        end

        local bestT = math.huge
        local bestPart = nil
        local bestNorm = _Vector3.new(0, 1, 0)

        for inst in hostPairs(_allInstances) do
            if not _destroyedMap[inst] and inst.ClassName ~= "Terrain" and inst:IsA("BasePart") and _proxyParent[inst] ~= nil then
                local p = _proxyProps[inst]
                if p and p.CanQuery ~= false then
                    local skip = false
                    if excList and isDescendantOfAny(inst, excList) then
                        skip = true
                    elseif incList and not isDescendantOfAny(inst, incList) then
                        skip = true
                    end
                    if not skip then
                        local pos = p.Position or _Vector3.zero
                        local size = p.Size or _Vector3.new(4, 1, 2)
                        local half = _Vector3.new((size.X or 4) * 0.5, (size.Y or 1) * 0.5, (size.Z or 2) * 0.5)
                        local bmin = _Vector3.new(pos.X - half.X, pos.Y - half.Y, pos.Z - half.Z)
                        local bmax = _Vector3.new(pos.X + half.X, pos.Y + half.Y, pos.Z + half.Z)
                        local tmin = -math.huge
                        local tmax = math.huge
                        local norm = _Vector3.new(0, 1, 0)
                        local hit = true
                        for _, ax in hostIpairs({"X", "Y", "Z"}) do
                            local d = direction[ax] or 0
                            local o = origin[ax] or 0
                            local mn = bmin[ax] or 0
                            local mx = bmax[ax] or 0
                            if math.abs(d) < 1e-9 then
                                if o < mn or o > mx then hit = false; break end
                            else
                                local t1 = (mn - o) / d
                                local t2 = (mx - o) / d
                                local s = -1
                                if t1 > t2 then t1, t2 = t2, t1; s = 1 end
                                if t1 > tmin then
                                    tmin = t1
                                    if ax == "X" then norm = _Vector3.new(s, 0, 0)
                                    elseif ax == "Y" then norm = _Vector3.new(0, s, 0)
                                    else norm = _Vector3.new(0, 0, s) end
                                end
                                if t2 < tmax then tmax = t2 end
                                if tmin > tmax or tmax < 0 then hit = false; break end
                            end
                        end
                        if hit and tmin >= 0 and tmin <= 1 and tmin < bestT then
                            bestT = tmin
                            bestPart = inst
                            bestNorm = norm
                        end
                    end
                end
            end
        end

        if bestPart then
            local hitPos = _Vector3.new(
                origin.X + direction.X * bestT,
                origin.Y + direction.Y * bestT,
                origin.Z + direction.Z * bestT
            )
            local dist = ((direction.X * bestT)^2 + (direction.Y * bestT)^2 + (direction.Z * bestT)^2)^0.5
            local res = {
                Instance = bestPart,
                Position = hitPos,
                Normal = bestNorm,
                Distance = dist,
                Material = bestPart.Material or _Enum.Material.Plastic,
            }
            local mt = { __type = "RaycastResult" }
            _rawMetaMap[res] = mt
            return hostSetmetatable(res, mt)
        end
        return nil
    end,
    FindPartOnRay = function() return nil, _Vector3.zero, _Vector3.new(0, 1, 0), nil end,
})
_createInstance("Camera", "CurrentCamera", _workspace, {
    CFrame = _CFrame.new(0, 10, 0),
    ViewportSize = _Vector2.new(1920, 1080),
    FieldOfView = 70,
})
_workspace.CurrentCamera = _workspace:FindFirstChild("CurrentCamera")
local _terrain = _createInstance("Terrain", "Terrain", _workspace)
_workspace.Terrain = _terrain

local _localPlayer = _makeInstanceProxy("Player", "Player", nil, {
    UserId = 1234567,
    AccountAge = 1000,
    DisplayName = "Player",
    MembershipType = _Enum.MembershipType.None,
    TeamColor = _BrickColor.White(),
    Team = nil,
    CameraMode = _Enum.CameraMode.Classic,
    CameraMinZoomDistance = 0.5,
    CameraMaxZoomDistance = 128,
    GetFriendAsync = function() return {} end,
})
local _character = _createInstance("Model", "Player", _workspace)
local _hrp = _createInstance("Part", "HumanoidRootPart", _character, { Position = _Vector3.new(5000, 5, 5000), CFrame = _CFrame.new(5000, 5, 5000), Anchored = true })
_createInstance("Part", "Head", _character, { Position = _Vector3.new(5000, 6.5, 5000), Anchored = true })
_createInstance("Part", "Torso", _character, { Position = _Vector3.new(5000, 5, 5000), Anchored = true })
_createInstance("Part", "UpperTorso", _character, { Position = _Vector3.new(5000, 5.2, 5000), Anchored = true })
local _charHum = _createInstance("Humanoid", "Humanoid", _character)
_createInstance("Animator", "Animator", _charHum)
_character.PrimaryPart = _hrp
_localPlayer.Character = _character
_localPlayer.CharacterAdded = _makeSignal("CharacterAdded")

local _Players = _registerService("Players", {
    LocalPlayer = _localPlayer,
    MaxPlayers = 50,
    CharacterAutoLoads = true,
    RespawnTime = 5,
    PlayerAdded = _makeSignal("PlayerAdded"),
    PlayerRemoving = _makeSignal("PlayerRemoving"),
    GetPlayers = function() return { _localPlayer } end,
    GetPlayerByUserId = function(_, id) return id == 1234567 and _localPlayer or nil end,
    GetNameFromUserIdAsync = function() return "Player" end,
    GetUserIdFromNameAsync = function() return 1234567 end,
    GetCharacterAppearanceInfoAsync = function() return { assets = {}, bodyColors = {}, scales = {} } end,
    GetHumanoidDescriptionFromUserId = function()
        return _createInstance("HumanoidDescription", "HumanoidDescription", nil, {
            GetEmotes = function() return {} end,
        })
    end,
})
_proxyParent[_localPlayer] = _Players
_proxyChildren[_Players][#_proxyChildren[_Players] + 1] = _localPlayer

_registerService("RunService", {
    IsStudio = function() return false end,
    IsClient = function() return true end,
    IsServer = function() return false end,
    IsRunning = function() return true end,
    IsRunMode = function() return false end,
    Heartbeat = _makeSignal("Heartbeat"),
    RenderStepped = _makeSignal("RenderStepped"),
    Stepped = _makeSignal("Stepped"),
    PreRender = _makeSignal("PreRender"),
    PreSimulation = _makeSignal("PreSimulation"),
    PostSimulation = _makeSignal("PostSimulation"),
    BindToRenderStep = function() end,
    UnbindFromRenderStep = function() end,
})

_registerService("CorePackages", {})
_registerService("CoreGui", {})
_registerService("ReplicatedStorage", {})
_registerService("ReplicatedFirst", {})
_registerService("StarterGui", {
    ShowDevelopmentGui = true,
    ScreenOrientation = _Enum.ScreenOrientation.LandscapeSensor,
    SetCore = function() end,
    GetCore = function() return true end,
    SetCoreGuiEnabled = function() end,
    IsCoreGuiEnabled = function() return true end,
    GetCoreGuiEnabled = function() return true end,
})
_registerService("StarterPack", {})
_registerService("StarterPlayer", {
    UserEmotesEnabled = true,
    ClassicDeath = true,
    CameraMode = _Enum.CameraMode.Classic,
    DevCameraOcclusionMode = _Enum.DevCameraOcclusionMode.Zoom,
    NameDisplayDistance = 100,
    LuaCharacterController = _Enum.CharacterControlMode.Default,
    HealthDisplayDistance = 100,
    CharacterJumpHeight = 7.2,
    CharacterBreakJointsOnDeath = true,
    CharacterJumpPower = 50,
    DevTouchMovementMode = _Enum.DevTouchMovementMode.UserChoice,
    DevComputerCameraMovementMode = _Enum.DevComputerCameraMovementMode.UserChoice,
    CharacterMaxSlopeAngle = 89,
    CharacterWalkSpeed = 16,
    CharacterUseJumpPower = true,
    LoadCharacterAppearance = true,
    CameraMaxZoomDistance = 128,
    CameraMinZoomDistance = 0.5,
    DevTouchCameraMovementMode = _Enum.DevTouchCameraMovementMode.UserChoice,
    AutoJumpEnabled = true,
    DevComputerMovementMode = _Enum.DevComputerMovementMode.UserChoice,
    EnableMouseLockOption = true,
})
_registerService("Lighting", {
    Technology = _Enum.Technology.ShadowMap,
    LightingStyle = _Enum.LightingStyle.Soft,
    OutdoorAmbient = _Color3.fromRGB(128, 128, 128),
    ClockTime = 14,
    TimeOfDay = "14:00:00",
    GeographicLatitude = 41.73,
    EnvironmentDiffuseScale = 0,
    EnvironmentSpecularScale = 0,
    Brightness = 2,
    Ambient = _Color3.fromRGB(70, 70, 70),
    ColorShift_Bottom = _Color3.new(0, 0, 0),
    ColorShift_Top = _Color3.new(0, 0, 0),
    FogColor = _Color3.fromRGB(192, 192, 192),
    FogStart = 0,
    FogEnd = 100000,
    PrioritizeLightingQuality = false,
    ExposureCompensation = 0,
    GlobalShadows = true,
    ShadowSoftness = 0.2,
    MinutesAfterMidnight = 14 * 60,
    SetMinutesAfterMidnight = function(self, m)
        local mins = hostTonumber(m) or 0
        self.ClockTime = (mins / 60) % 24
        self.MinutesAfterMidnight = mins
    end,
    GetMinutesAfterMidnight = function(self)
        return self.MinutesAfterMidnight or ((self.ClockTime or 14) * 60)
    end,
})
_registerService("Debris", {
    MaxItems = 1000,
    AddItem = function() end,
    SetLegacyMaxItems = function() end,
})
_registerService("GuiService", {
    MenuIsOpen = false,
    AutoSelectGuiEnabled = true,
    TouchControlsEnabled = true,
    GuiNavigationEnabled = true,
    GetGuiInset = function() return _Vector2.new(0, 36), _Vector2.new(0, 0) end,
})
_registerService("UserInputService", {
    MouseEnabled = true,
    KeyboardEnabled = true,
    TouchEnabled = false,
    GamepadEnabled = false,
    MouseIconEnabled = true,
    MouseDeltaSensitivity = 1,
    MouseBehavior = _Enum.MouseBehavior.Default,
    GetMouseLocation = function() return _Vector2.new(960, 540) end,
    GetMouseDelta = function() return _Vector2.new(0, 0) end,
    IsKeyDown = function(self, kc)
        if kc == nil then hostError("Argument 1 missing or nil", 2) end
        return false
    end,
    GetKeysPressed = function() return {} end,
    GetGamepadState = function(self, gt)
        if gt == nil then hostError("Argument 1 missing or nil", 2) end
        return {}
    end,
    IsMouseButtonPressed = function() return false end,
    GetFocusedTextBox = function() return nil end,
    GetLastInputType = function() return _Enum.UserInputType.None end,
})

local function _jsonDecode(str)
    local pos = 1
    local len = #str
    local function skipWs()
        while pos <= len do
            local b = string.byte(str, pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
        end
    end
    local parseVal
    local function parseStr()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                pos = pos + 1
                if esc == "n" then out[#out + 1] = "\n"
                elseif esc == "r" then out[#out + 1] = "\r"
                elseif esc == "t" then out[#out + 1] = "\t"
                else out[#out + 1] = esc end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        hostError("Invalid JSON string", 3)
    end
    parseVal = function()
        skipWs()
        local c = str:sub(pos, pos)
        if c == '"' then return parseStr()
        elseif c == "{" then
            pos = pos + 1
            local obj = {}
            skipWs()
            if str:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while pos <= len do
                skipWs()
                local k = parseStr()
                skipWs()
                if str:sub(pos, pos) ~= ":" then hostError("Invalid JSON object", 3) end
                pos = pos + 1
                obj[k] = parseVal()
                skipWs()
                local sep = str:sub(pos, pos)
                if sep == "}" then pos = pos + 1 return obj end
                if sep ~= "," then hostError("Invalid JSON object", 3) end
                pos = pos + 1
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skipWs()
            if str:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while pos <= len do
                arr[#arr + 1] = parseVal()
                skipWs()
                local sep = str:sub(pos, pos)
                if sep == "]" then pos = pos + 1 return arr end
                if sep ~= "," then hostError("Invalid JSON array", 3) end
                pos = pos + 1
            end
        elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
        else
            local numStr = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if not numStr or numStr == "" then hostError("Invalid JSON value", 3) end
            pos = pos + #numStr
            return hostTonumber(numStr)
        end
    end
    return parseVal()
end

_registerService("HttpService", {
    HttpEnabled = true,
    JSONEncode = function(self, ...)
        if select("#", ...) == 0 then hostError("Argument 1 missing or nil", 2) end
        local tbl = ...
        local seen = {}
        local function enc(v)
            local t = hostType(v)
            if v == nil then return "null" end
            if t == "boolean" then return v and "true" or "false" end
            if t == "number" then return hostTostring(v) end
            if t == "string" then return _escapeLuaString(v) end
            if t == "table" then
                if seen[v] then hostError("Cannot convert tables to JSON with cyclic references", 2) end
                seen[v] = true
                local isArr = (#v > 0)
                local items = {}
                if isArr then
                    for i = 1, #v do items[i] = enc(v[i]) end
                    seen[v] = nil
                    return "[" .. table.concat(items, ",") .. "]"
                else
                    for k, val in hostPairs(v) do
                        items[#items + 1] = _escapeLuaString(hostTostring(k)) .. ":" .. enc(val)
                    end
                    seen[v] = nil
                    return "{" .. table.concat(items, ",") .. "}"
                end
            end
            return "null"
        end
        return enc(tbl)
    end,
    JSONDecode = function(self, s)
        if hostType(s) ~= "string" then hostError("Argument 1 missing or not a string", 2) end
        return _jsonDecode(s)
    end,
    GenerateGUID = function(_, wrap)
        local guid = string.format(
            "%08x-%04x-4%03x-%04x-%012x",
            math.random(0, 0x7fffffff),
            math.random(0, 0xffff),
            math.random(0, 0xfff),
            0x8000 + math.random(0, 0x3fff),
            math.random(0, 0x7fffffff)
        )
        return wrap and ("{" .. guid .. "}") or guid
    end,
    GetAsync = function(_, url) _emitLine(string.format('HttpService:GetAsync(%s)', _formatArg(url))); return "" end,
})
local _activeTweens = hostSetmetatable({}, { __mode = "k" })

_registerService("TweenService", {
    Create = function(_, inst, info, props)
        local completedSignal = _makeSignal("Completed")
        local dur = (info and info.Time) or 1
        local tw
        local state = {
            target = inst,
            info = info,
            props = props,
            elapsed = 0,
            duration = dur,
            active = false,
        }
        tw = _createInstance("Tween", "Tween", nil, {
            Instance = inst,
            TweenInfo = info,
            PlaybackState = _Enum.PlaybackState.Begin,
            Play = function(self)
                self.PlaybackState = _Enum.PlaybackState.Playing
                state.active = true
                state.elapsed = 0
                _activeTweens[state] = self
            end,
            Cancel = function(self)
                self.PlaybackState = _Enum.PlaybackState.Cancelled
                state.active = false
                _activeTweens[state] = nil
            end,
            Pause = function(self)
                self.PlaybackState = _Enum.PlaybackState.Paused
                state.active = false
            end,
            Completed = completedSignal,
        })
        return tw
    end,
    SmoothDamp = function(self, current, target, currentVelocity, smoothTime, maxSpeed, deltaTime)
        smoothTime = math.max(0.0001, smoothTime or 0.1)
        maxSpeed = maxSpeed or math.huge
        deltaTime = deltaTime or (1 / 60)
        local omega = 2 / smoothTime
        local x = omega * deltaTime
        local exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        local change = current - target
        local originalTo = target
        local maxChange = maxSpeed * smoothTime
        change = math.clamp(change, -maxChange, maxChange)
        target = current - change
        local temp = (currentVelocity + omega * change) * deltaTime
        currentVelocity = (currentVelocity - omega * temp) * exp
        local output = target + (change + temp) * exp
        if (originalTo - current > 0) == (output > originalTo) then
            output = originalTo
            currentVelocity = (output - originalTo) / deltaTime
        end
        return output, currentVelocity
    end,
})

_registerService("VoiceChatService", {
    joinVoice = function() return true end,
    rejoinVoice = function() return true end,
    leaveVoice = function() return true end,
    IsVoiceEnabledForUserIdAsync = function() return false end,
    GetChatGroupsAsync = function() return {} end,
    GetSpeakerVolume = function() return 1.0 end,
    SetSpeakerVolume = function() end,
})

_registerService("SoundService", {
    RolloffScale = 1,
    DopplerScale = 1,
    DistanceFactor = 3.33,
    RespectFilteringEnabled = true,
    DiffractionEnabled = true,
    AcousticSimulationEnabled = false,
    ReverbEnabled = false,
    OcclusionEnabled = false,
    ListenerType = _Enum.ListenerType.Camera,
    ListenerCFrame = _CFrame.new(),
    AmbientReverb = _Enum.ReverbType.NoReverb,
    CharacterSoundsUseNewApi = _Enum.RolloutState.Default,
    PlayLocalSound = function() end,
    GetAudioInstances = function() return {} end,
    GetInputDevices = function() return {} end,
    GetOutputDevices = function() return {} end,
})

_newEditableMesh = function()
    local mesh = _makeInstanceProxy("EditableMesh", "EditableMesh", nil, nil)
    local store = { verts = {}, nextId = 1 }
    _editableMeshes[mesh] = store
    mesh.AddVertex = function(_, pos)
        local id = store.nextId
        store.verts[id] = pos
        store.nextId = id + 1
        return id
    end
    mesh.GetPosition = function(_, id)
        return store.verts[id] or _Vector3.new(0, 0, 0)
    end
    mesh.SetPosition = function(_, id, pos)
        store.verts[id] = pos
    end
    mesh.GetVertices = function()
        local out = {}
        for id in hostPairs(store.verts) do
            out[#out + 1] = id
        end
        return out
    end
    mesh.AddTriangle = function() return 1 end
    mesh.AddFace = function() return 1 end
    mesh.AddColor = function() return 1 end
    mesh.AddNormal = function() return 1 end
    mesh.AddUV = function() return 1 end
    mesh.Clear = function() store.verts = {}; store.nextId = 1 end
    return mesh
end

_registerService("PathfindingService", {
    CreatePath = function()
        return _createInstance("Path", "Path", nil, {
            Status = _Enum.PathStatus.Success,
            GetWaypoints = function() return {} end,
            ComputeAsync = function() end,
            Blocked = _makeSignal("Blocked"),
            Unblocked = _makeSignal("Unblocked"),
        })
    end,
})

_registerService("AssetService", {
    CreateEditableMesh = function() return _newEditableMesh() end,
    CreateEditableMeshAsync = function() return _newEditableMesh() end,
    CreatePlaceAsync = function() return 0 end,
    GetBundleDetailsAsync = function() return {} end,
})

_registerService("CollectionService", {
    AddTag = function(_, inst, tag)
        if _proxyTypes[inst] then inst:AddTag(tag) end
    end,
    RemoveTag = function(_, inst, tag)
        if _proxyTypes[inst] then inst:RemoveTag(tag) end
    end,
    HasTag = function(_, inst, tag)
        return _proxyTypes[inst] and inst:HasTag(tag) or false
    end,
    GetTags = function(_, inst)
        return _proxyTypes[inst] and inst:GetTags() or {}
    end,
    GetTagged = function(_, tag)
        local out = {}
        local t = hostTostring(tag)
        for inst in hostPairs(_allInstances) do
            if not _destroyedMap[inst] and _proxyTags[inst] and _proxyTags[inst][t] then
                out[#out + 1] = inst
            end
        end
        return out
    end,
})

local _marketplaceService = _registerService("MarketplaceService", {
    PromptPremiumPurchase = function(self, player)
        if self == nil or not _proxyTypes[self] then
            hostError("Expected ':' not '.' calling member function PromptPremiumPurchase", 2)
        end
        if player == nil or not _proxyTypes[player] then
            hostError("Unable to cast value to Object", 2)
        end
    end,
    PromptPurchase = function(self, player, assetId)
        if self == nil or not _proxyTypes[self] then
            hostError("Expected ':' not '.' calling member function PromptPurchase", 2)
        end
        if player == nil or not _proxyTypes[player] or hostType(assetId) ~= "number" then
            hostError("Unable to cast value to Object", 2)
        end
    end,
    UserOwnsGamePassAsync = function() return false end,
    PlayerOwnsAsset = function() return false end,
    GetProductInfo = function(_, id) return { AssetId = id or 0, Name = "Asset", PriceInRobux = 0, IsForSale = false } end,
    PromptPremiumPurchaseFinished = _makeSignal("PromptPremiumPurchaseFinished"),
})

_registerService("LocalizationService", { RobloxLocaleId = "en-us" })
_registerService("ContextActionService", {
    BindAction = function() end,
    UnbindAction = function() end,
    GetAllBoundActionInfo = function() return {} end,
})
_registerService("DataStoreService", {
    GetDataStore = function(_, name)
        return _makeType("GlobalDataStore", {
            GetAsync = function() return nil end,
            SetAsync = function() end,
            UpdateAsync = function() return nil end,
            RemoveAsync = function() return nil end,
        })
    end,
})
_registerService("Stats", { HeartbeatTimeMs = 16.6, InstanceCount = 50 })
_registerService("Teams", { GetTeams = function() return {} end })
_registerService("TextService", { GetTextSize = function() return _Vector2.new(100, 20) end })
_registerService("AchievementService", {
    IsAvailable = function() return true end,
    HasAchieved = function() return false end,
    GrantAchievement = function() return true end,
})
_registerService("PlayerViewService", {
    GetDeviceCameraCFrame = function() return _CFrame.new() end,
    GetDeviceCameraCFrameForSelfView = function() return _CFrame.new() end,
    UpdateDeviceCFrame = function() end,
})
_registerService("HapticService", {
    IsVibrationSupported = function() return false end,
})
local _memStorageData = {}
_registerService("MemStorageService", {
    SetItem = function(_, k, v) _memStorageData[hostTostring(k)] = hostTostring(v) end,
    GetItem = function(_, k) return _memStorageData[hostTostring(k)] or "" end,
    HasItem = function(_, k) return _memStorageData[hostTostring(k)] ~= nil end,
    RemoveItem = function(_, k) _memStorageData[hostTostring(k)] = nil end,
})
_registerService("PhysicsService", {})
_registerService("TeleportService", { Teleport = function() end, TeleportAsync = function() end })
_registerService("Chat", { LoadDefaultChat = true, BubbleChatEnabled = true, Chat = function() end })
_registerService("InsertService", { LoadAsset = function() return _createInstance("Model", "Model", nil) end })
_registerService("MemoryStoreService", {})
_registerService("VirtualInputManager", {})
_registerService("KeyframeSequenceProvider", {})

local _gameRawMt = _rawMetaMap[_game] or hostGetmetatable(_game)
local _origGameIndex = _gameRawMt.__index
local _gameGetServiceFn = function(_, svcName)
    if hostType(svcName) ~= "string" then
        hostError("invalid argument #1 to 'GetService' (string expected, got " .. _sandboxType(svcName) .. ")", 2)
    end
    local svc = _services[svcName]
    if not svc then
        if _apiClassSuper[svcName] or _apiClasses[svcName] or svcName:match("Service$") or svcName:match("^Core") then
            svc = _registerService(svcName, {})
        else
            hostError("'" .. svcName .. "' is not a valid Service name", 2)
        end
    end
    _emitApiCall("svc:" .. svcName, string.format("game:GetService(%s)", _formatArg(svcName, 0)), 1)
    return svc
end
local _gameFindServiceFn = function(_, svcName)
    if hostType(svcName) ~= "string" then
        hostError("invalid argument #1 to 'FindService' (string expected, got " .. _sandboxType(svcName) .. ")", 2)
    end
    local svc = _services[svcName]
    if not svc and (_apiClassSuper[svcName] or _apiClasses[svcName] or svcName:match("Service$")) then
        svc = _registerService(svcName, {})
    end
    if svc then
        _emitApiCall("svc:" .. svcName, string.format("game:FindService(%s)", _formatArg(svcName, 0)), 1)
    end
    return svc
end
_cclosureSet[_gameGetServiceFn] = true
_cclosureSet[_gameFindServiceFn] = true

local _gameHooks = {
    __index = function(self, key)
        if key == "GetService" or key == "getService" then
            return _gameGetServiceFn
        end
        if key == "FindService" then
            return _gameFindServiceFn
        end
        if _services[key] then
            _emitApiCall("svc:" .. key, string.format("game:GetService(%s)", _formatArg(key, 0)), 1)
            return _services[key]
        end
        if hostType(key) == "string" and (_apiClassSuper[key] or key:match("Service$")) and not _hasApiMember("DataModel", "F", key) and not _hasApiMember("DataModel", "P", key) and not _hasApiMember("DataModel", "E", key) then
            local svc = _registerService(key, {})
            _emitApiCall("svc:" .. key, string.format("game:GetService(%s)", _formatArg(key, 0)), 1)
            return svc
        end
        return _origGameIndex(self, key)
    end,
    __newindex = _gameRawMt.__newindex,
    __namecall = _gameRawMt.__namecall,
}
local _gameIndexDispatch = function(self, key) return _gameHooks.__index(self, key) end
local _gameNewIndexDispatch = function(self, key, val) return _gameHooks.__newindex(self, key, val) end
local _gameNamecallDispatch = function(self, ...) return _gameHooks.__namecall(self, ...) end
_cclosureSet[_gameIndexDispatch] = true
_cclosureSet[_gameNewIndexDispatch] = true
_cclosureSet[_gameNamecallDispatch] = true
_gameRawMt.__index = _gameIndexDispatch
_gameRawMt.__newindex = _gameNewIndexDispatch
_gameRawMt.__namecall = _gameNamecallDispatch
local _gameMt = table.freeze(_gameRawMt)

-- Build isolated executor + Roblox sandbox environment
local _waitBudget = 0
local _MAX_WAIT_CALLS = 10000

local _cclosureNames = hostSetmetatable({}, { __mode = "k" })

local function _sandboxType(...)
    if select("#", ...) == 0 then
        hostError("missing argument #1 to 'type' (value expected)", 2)
    end
    local v = ...
    local t = hostType(v)
    if t == "table" then
        local mt = _rawMetaMap[v] or hostGetmetatable(v)
        if hostType(mt) == "table" then
            local tp = rawget(mt, "__type")
            if tp == "Instance" or tp == "Random" then return "userdata" end
            if tp == "Enum" or tp == "EnumItem" or tp == "Enums"
                or tp == "RBXScriptSignal" or tp == "RBXScriptConnection" then
                return "userdata"
            end
        end
    end
    return t
end

local function _sandboxTypeof(...)
    if select("#", ...) == 0 then
        hostError("missing argument #1 to 'typeof' (value expected)", 2)
    end
    local v = ...
    local t = hostType(v)
    if t == "table" or t == "userdata" then
        local mt = _rawMetaMap[v] or hostGetmetatable(v)
        if hostType(mt) == "table" and rawget(mt, "__type") then
            return rawget(mt, "__type")
        end
    end
    return t
end

local _upvalueTokens = hostSetmetatable({}, { __mode = "k" })

local function _countLuaUpvalues(fn)
    if not hostDebugGetupvalue or _cclosureSet[fn] then return 0 end
    local n = 0
    for i = 1, 64 do
        local ok, name = hostPcall(hostDebugGetupvalue, fn, i)
        if not ok or name == nil then break end
        n = i
    end
    return n
end

local function _isSandboxCClosure(fn)
    if hostType(fn) ~= "function" then return false end
    if _cclosureSet[fn] then return true end
    if hostDebugInfo then
        local ok, src = hostPcall(hostDebugInfo, fn, "s")
        if ok and (src == "[C]" or src == "@engine" or src == "engine" or (hostType(src) == "string" and src:find("lune_sandbox_runner", 1, true) ~= nil)) then
            return true
        end
    end
    return false
end

local _safeDebug
_safeDebug = {
    traceback = function(a, b)
        local msg = hostType(a) == "thread" and b or a
        local prefix = msg ~= nil and (hostTostring(msg) .. "\n") or ""
        return prefix .. "stack traceback:\n\t[C]: in ?"
    end,
    info = function(target, what, maybeWhat)
        if hostType(target) == "thread" then
            if hostType(what) ~= "number" or what < 0 or not hostDebugInfo then return nil end
            local opts = hostType(maybeWhat) == "string" and maybeWhat or "slnaf"
            if target == coroutine.running() then
                return hostDebugInfo(what == 0 and 0 or (what + 1), opts)
            end
            return hostDebugInfo(target, what, opts)
        end
        if hostType(target) == "number" then
            if target < 0 or not hostDebugInfo then return nil end
            if target == 0 then
                return hostDebugInfo(0, what or "slnaf")
            end
            return hostDebugInfo(target + 1, what or "slnaf")
        end
        if hostType(target) == "function" then
            if _isSandboxCClosure(target) then
                local opts = hostType(what) == "string" and what or "slnaf"
                local fname = _cclosureNames[target]
                if not fname and hostDebugInfo then
                    local okN, hostN = hostPcall(hostDebugInfo, target, "n")
                    if okN and hostType(hostN) == "string" and hostN ~= "" then
                        fname = hostN
                    end
                end
                local out = {}
                for i = 1, #opts do
                    local ch = opts:sub(i, i)
                    if ch == "s" then out[#out + 1] = "[C]"
                    elseif ch == "l" then out[#out + 1] = -1
                    elseif ch == "n" then out[#out + 1] = fname or ""
                    elseif ch == "f" then out[#out + 1] = target
                    elseif ch == "a" then
                        out[#out + 1] = 0
                        out[#out + 1] = true
                    end
                end
                return hostUnpack(out)
            end
            if hostDebugInfo then
                return hostDebugInfo(target, what or "slnaf")
            end
            return "[C]", 0, "", 0, false
        end
        return nil
    end,
    getinfo = function(target, what)
        local opts = hostType(what) == "string" and what or "flnSu"
        local isC = true
        local src = "=[C]"
        local shortSrc = "[C]"
        local line = -1
        local name = ""
        local nparams = 0
        local isvararg = true
        local nups = 0
        local fn = nil

        if hostType(target) == "number" then
            if target < 0 then return nil end
            if target == 0 then
                fn = _safeDebug.getinfo
                name = "getinfo"
            elseif hostDebugInfo then
                local s, l, n, np, iv, f = hostDebugInfo(target + 1, "slnaf")
                if s == nil then return nil end
                fn = f
                if s == "[C]" or s == "@engine" or s == "engine" or (hostType(s) == "string" and s:find("lune_sandbox_runner", 1, true) ~= nil) then
                    isC = true
                    src = "=[C]"
                    shortSrc = "[C]"
                    line = -1
                    name = (s == "[C]") and (n or "") or ""
                else
                    isC = false
                    src = (s:sub(1, 1) == "=" or s:sub(1, 1) == "@") and s or ("=" .. s)
                    shortSrc = s:gsub("^[=@]", ""):sub(1, 60)
                    line = (hostType(l) == "number" and l >= 0) and l or 1
                    name = n or ""
                    nparams = np or 0
                    isvararg = iv == true
                    nups = _countLuaUpvalues(f)
                end
            else
                return nil
            end
        elseif hostType(target) == "function" then
            fn = target
            if _isSandboxCClosure(fn) then
                isC = true
            elseif hostDebugInfo then
                local s, l, n, np, iv = hostDebugInfo(fn, "slna")
                if s == nil or s == "[C]" or s == "@engine" or s == "engine" or (hostType(s) == "string" and s:find("lune_sandbox_runner", 1, true) ~= nil) then
                    isC = true
                else
                    isC = false
                    src = (s:sub(1, 1) == "=" or s:sub(1, 1) == "@") and s or ("=" .. s)
                    shortSrc = s:gsub("^[=@]", ""):sub(1, 60)
                    line = (hostType(l) == "number" and l >= 0) and l or 1
                    name = n or ""
                    nparams = np or 0
                    isvararg = iv == true
                    nups = _countLuaUpvalues(fn)
                end
            end
        else
            return nil
        end

        if opts == "" then
            return {}
        end
        local res = {}
        if opts:find("S", 1, true) then
            res.source = src
            res.short_src = shortSrc
            res.what = isC and "C" or "Lua"
            res.linedefined = line
            res.lastlinedefined = line
        end
        if opts:find("l", 1, true) then
            res.currentline = line
        end
        if opts:find("f", 1, true) then
            res.func = fn
        end
        if opts:find("n", 1, true) then
            res.name = name
            res.namewhat = ""
        end
        if opts:find("u", 1, true) then
            res.nups = nups
            res.nparams = nparams
            res.isvararg = isvararg
        end
        if opts:find("L", 1, true) then
            res.activelines = {}
        end
        return res
    end,
    getmetatable = hostGetmetatable,
    setmetatable = hostSetmetatable,
    getupvalue = function(fn, idx)
        if hostType(fn) ~= "function" then
            hostError("invalid argument #1 to 'getupvalue' (function expected)", 2)
        end
        if hostType(idx) ~= "number" then
            hostError("invalid argument #2 to 'getupvalue' (number expected)", 2)
        end
        if _isSandboxCClosure(fn) then
            hostError("invalid upvalue index", 2)
        end
        local total = _countLuaUpvalues(fn)
        if idx < 1 or idx > total then
            hostError("invalid upvalue index", 2)
        end
        if hostDebugGetupvalue then
            return hostDebugGetupvalue(fn, idx)
        end
        return nil
    end,
    setupvalue = debug and debug.setupvalue or function() end,
    upvalueid = function(fn, idx)
        if hostType(fn) ~= "function" or _isSandboxCClosure(fn) then
            return nil
        end
        if hostType(idx) ~= "number" or idx < 1 or idx > _countLuaUpvalues(fn) then
            return nil
        end
        local map = _upvalueTokens[fn]
        if not map then
            map = {}
            _upvalueTokens[fn] = map
        end
        if not map[idx] then
            map[idx] = {}
        end
        return map[idx]
    end,
    getupvalues = function(fn)
        if hostType(fn) == "number" and hostDebugInfo then
            local f = hostDebugInfo(fn + 1, "f")
            fn = f
        end
        if hostType(fn) ~= "function" then
            hostError("invalid argument #1 to 'getupvalues' (function expected)", 2)
        end
        local out = {}
        if not _isSandboxCClosure(fn) and hostDebugGetupvalue then
            for i = 1, 64 do
                local ok, name, val = hostPcall(hostDebugGetupvalue, fn, i)
                if not ok or name == nil then break end
                out[i] = val
            end
        end
        return out
    end,
    getconstant = function(fn, idx)
        if hostType(fn) == "number" and hostDebugInfo then
            fn = hostDebugInfo(fn + 1, "f")
        end
        if hostType(fn) ~= "function" then
            hostError("invalid argument #1 to 'getconstant' (function expected)", 2)
        end
        if hostType(idx) ~= "number" then
            hostError("invalid argument #2 to 'getconstant' (number expected)", 2)
        end
        return nil
    end,
    getconstants = function(fn)
        if hostType(fn) == "number" and hostDebugInfo then
            fn = hostDebugInfo(fn + 1, "f")
        end
        if hostType(fn) ~= "function" then
            hostError("invalid argument #1 to 'getconstants' (function expected)", 2)
        end
        return {}
    end,
    setconstant = function(fn, idx, val)
        if hostType(fn) == "number" and hostDebugInfo then
            fn = hostDebugInfo(fn + 1, "f")
        end
        if hostType(fn) ~= "function" then
            hostError("invalid argument #1 to 'setconstant' (function expected)", 2)
        end
        if hostType(idx) ~= "number" then
            hostError("invalid argument #2 to 'setconstant' (number expected)", 2)
        end
    end,
    getproto = function(fn, idx, activated)
        if hostType(fn) == "number" and hostDebugInfo then
            fn = hostDebugInfo(fn + 1, "f")
        end
        if hostType(fn) ~= "function" then
            hostError("invalid argument #1 to 'getproto' (function expected)", 2)
        end
        if hostType(idx) ~= "number" then
            hostError("invalid argument #2 to 'getproto' (number expected)", 2)
        end
        if activated then
            return { function() end }
        end
        return function() end
    end,
    getprotos = function(fn)
        if hostType(fn) == "number" and hostDebugInfo then
            fn = hostDebugInfo(fn + 1, "f")
        end
        if hostType(fn) ~= "function" then
            hostError("invalid argument #1 to 'getprotos' (function expected)", 2)
        end
        return {}
    end,
    getstack = function(level, idx)
        if hostType(level) ~= "number" then
            hostError("invalid argument #1 to 'getstack' (number expected)", 2)
        end
        if idx ~= nil then
            return nil
        end
        return {}
    end,
    setstack = function(level, idx, val)
        if hostType(level) ~= "number" then
            hostError("invalid argument #1 to 'setstack' (number expected)", 2)
        end
        if hostType(idx) ~= "number" then
            hostError("invalid argument #2 to 'setstack' (number expected)", 2)
        end
    end,
    setmemorycategory = function() end,
    getmemorycategory = function() return "" end,
    resetmemorycategory = function() end,
    profilebegin = function() end,
    profileend = function() end,
}

local _safeOs = {
    clock = function() return hostClock() + _simTime end,
    time  = hostTime,
    date  = hostDate,
    difftime = os.difftime,
    getenv = function() return nil end,
}

local _deferredTasks = {}
local _delayedTasks = {}
local _cancelledThreads = hostSetmetatable({}, { __mode = "k" })

local _safeTask = {
    wait = function(dt)
        _waitBudget = _waitBudget + 1
        if _waitBudget > _MAX_WAIT_CALLS or (hostClock() - _startClock) > 12 then
            hostError("script timeout: maximum execution time exceeded", 0)
        end
        local step = hostTonumber(dt) or (1 / 60)
        if step < 0 then step = 0 end
        _simTime = _simTime + step
        if _workspace then
            _workspace.DistributedGameTime = (_workspace.DistributedGameTime or 10) + step
        end
        local hb = _services.RunService and _services.RunService.Heartbeat
        if hb and hb.Fire then hb:Fire(step) end
        return step
    end,
    spawn = function(fn, ...)
        local co = nil
        if hostType(fn) == "thread" then
            co = fn
        elseif hostType(fn) == "function" then
            co = coroutine.create(fn)
        end
        if co then
            coroutine.resume(co, ...)
        end
        return co
    end,
    defer = function(fn, ...)
        local co = nil
        if hostType(fn) == "thread" then
            co = fn
        elseif hostType(fn) == "function" then
            co = coroutine.create(fn)
        end
        if co then
            _deferredTasks[#_deferredTasks + 1] = { thread = co, args = hostPack(...) }
        end
        return co
    end,
    delay = function(sec, fn, ...)
        local co = nil
        if hostType(fn) == "thread" then
            co = fn
        elseif hostType(fn) == "function" then
            co = coroutine.create(fn)
        end
        if co then
            local d = hostTonumber(sec) or 0
            if d < 0 then d = 0 end
            _delayedTasks[#_delayedTasks + 1] = { thread = co, args = hostPack(...), readyAt = _simTime + d }
        end
        return co
    end,
    cancel = function(...)
        if select("#", ...) == 0 then
            hostError("missing argument #1 to 'cancel' (thread expected)", 2)
        end
        local co = ...
        if hostType(co) ~= "thread" then
            hostError("invalid argument #1 to 'cancel' (thread expected)", 2)
        end
        _cancelledThreads[co] = true
        pcall(coroutine.close, co)
    end,
    synchronize = function() end,
    desynchronize = function() end,
}

do
    local _origWait = _safeTask.wait
    local _activeTracks = hostSetmetatable({}, { __mode = "k" })
    local _origCreate = _createInstance
    _createInstance = function(className, name, parent, extraProps)
        local obj = _origCreate(className, name, parent, extraProps)
        if className == "AnimationTrack" then
            _activeTracks[obj] = true
        end
        return obj
    end
    _safeTask.wait = function(dt)
        local step = _origWait(dt)
        while #_deferredTasks > 0 do
            local item = table.remove(_deferredTasks, 1)
            if item.thread and not _cancelledThreads[item.thread] and coroutine.status(item.thread) == "suspended" then
                coroutine.resume(item.thread, hostUnpack(item.args, 1, item.args.n))
            end
        end
        local remainingDelayed = {}
        for _, item in hostIpairs(_delayedTasks) do
            if not _cancelledThreads[item.thread] then
                if _simTime >= item.readyAt then
                    if coroutine.status(item.thread) == "suspended" then
                        coroutine.resume(item.thread, hostUnpack(item.args, 1, item.args.n))
                    end
                else
                    remainingDelayed[#remainingDelayed + 1] = item
                end
            end
        end
        _delayedTasks = remainingDelayed
        for inst in hostPairs(_allInstances) do
            if not _destroyedMap[inst] and inst:IsA("BasePart") then
                local p = _proxyProps[inst]
                if p and not p.Anchored and _proxyParent[inst] ~= nil then
                    local vel = p.AssemblyLinearVelocity or _Vector3.zero
                    local grav = _workspace and _workspace.Gravity or 196.2
                    local newVy = (vel.Y or 0) - grav * step
                    local newVel = _Vector3.new(vel.X or 0, newVy, vel.Z or 0)
                    p.AssemblyLinearVelocity = newVel
                    p.Velocity = newVel
                    local pos = p.Position or _Vector3.zero
                    local newPos = _Vector3.new(pos.X or 0, (pos.Y or 0) + newVy * step, pos.Z or 0)
                    p.Position = newPos
                    if p.CFrame then
                        p.CFrame = _CFrame.new(newPos.X, newPos.Y, newPos.Z)
                    end
                end
            end
        end
        for trk in hostPairs(_activeTracks) do
            if trk.IsPlaying then
                trk.TimePosition = (trk.TimePosition or 0) + step * (trk.Speed or 1)
            end
        end
        for st, tw in hostPairs(_activeTweens) do
            if st.active and tw.PlaybackState == _Enum.PlaybackState.Playing then
                st.elapsed = st.elapsed + step
                if st.elapsed >= st.duration then
                    tw.PlaybackState = _Enum.PlaybackState.Completed
                    st.active = false
                    _activeTweens[st] = nil
                    if st.target and hostType(st.props) == "table" then
                        for k, v in hostPairs(st.props) do
                            pcall(function() st.target[k] = v end)
                        end
                    end
                    if tw.Completed and tw.Completed.Fire then
                        tw.Completed:Fire(_Enum.PlaybackState.Completed)
                    end
                end
            end
        end
        return step
    end
end

local _virtualFS = {}

local function _makeSandboxEnv()
    local env = {}
    env._G = env
    env._VERSION = "Luau"
    env.shared = {}
    env.game = _game
    env.workspace = _workspace
    env.Workspace = _workspace
    env.script = _createInstance("LocalScript", "LocalScript", _localPlayer)
    env.Enum = _Enum
    env.Instance = {
        new = function(className, parent)
            if hostType(className) ~= "string" then
                hostError("invalid argument #1 to 'new' (string expected, got " .. _sandboxType(className) .. ")", 2)
            end
            if not _isCreatableClass(className) then
                hostError('Unable to create an Instance of type "' .. className .. '"', 2)
            end
            if parent ~= nil and not _proxyTypes[parent] then
                hostError("Unable to assign property Parent. Object expected, got " .. _sandboxTypeof(parent), 2)
            end
            local obj = _createInstance(className, className, parent)
            local callLine = parent ~= nil
                and string.format("Instance.new(%s, %s)", _formatArg(className, 0), _formatArg(parent, 0))
                or string.format("Instance.new(%s)", _formatArg(className, 0))
            _emitApiCall("new:" .. className, callLine, 3)
            return obj
        end,
        fromExisting = function(other)
            if not _proxyTypes[other] then
                hostError("Unable to cast value to Object", 2)
            end
            local base = _refBaseMap[other] or other
            if _destroyedMap[base] then
                hostError("Unable to cast value to Object", 2)
            end
            local p = _proxyProps[base]
            local cn = p and p.ClassName or ""
            if not _isCreatableClass(cn) then
                hostError('Unable to create an Instance of type "' .. cn .. '"', 2)
            end
            local clone = _createInstance(cn, (p and p.Name) or cn, nil)
            local cloneBase = _refBaseMap[clone] or clone
            _copyInstanceState(base, cloneBase)
            _updateSubtreePaths(cloneBase)
            _emitApiCall("fromExisting:" .. cn, string.format("Instance.fromExisting(%s)", _formatArg(other, 0)), 3)
            return clone
        end,
    }
    env.Vector2 = _Vector2
    env.Vector3 = _Vector3
    env.CFrame  = _CFrame
    env.Color3  = _Color3
    env.BrickColor = _BrickColor
    env.UDim    = _UDim
    env.UDim2   = _UDim2
    env.TweenInfo = _TweenInfo
    env.Ray     = _Ray
    env.Rect    = _Rect
    env.Region3 = _Region3
    env.NumberRange = _NumberRange
    env.NumberSequence = _NumberSequence
    env.NumberSequenceKeypoint = _NumberSequenceKeypoint
    env.ColorSequence = _ColorSequence
    env.ColorSequenceKeypoint = _ColorSequenceKeypoint
    env.PhysicalProperties = _PhysicalProperties
    env.Faces   = _Faces
    env.Axes    = _Axes
    env.OverlapParams = _OverlapParams
    env.RaycastParams = _RaycastParams
    env.Path2DControlPoint = _Path2DControlPoint
    env.RotationCurveKey = _RotationCurveKey
    env.PathWaypoint = _PathWaypoint
    env.Random  = _Random
    env.DateTime = _DateTime
    env.Font    = _Font
    env.Content = { none = {}, fromUri = function(u) return { Uri = u } end, fromObject = function(o) return { Object = o } end }
    env.Secret  = { new = function() return {} end }
    env.SharedTable = { new = function(t) return t or {} end, size = function(t) local n = 0 for _ in hostPairs(t or {}) do n = n + 1 end return n end }
    env.SecurityCapabilities = { fromCurrent = function() return {} end }

    local _safeString = table.clone(string)
    _safeString.rep = function(s, n, sep)
        if hostType(s) ~= "string" and hostType(s) ~= "number" then
            hostError("bad argument #1 to 'rep' (string expected)", 2)
        end
        local count = hostTonumber(n)
        if count == nil then
            hostError("bad argument #2 to 'rep' (number expected)", 2)
        end
        count = math.floor(count)
        if count <= 0 then return "" end
        s = hostTostring(s)
        if sep == nil then
            return string.rep(s, count)
        end
        local sepStr = hostTostring(sep)
        if sepStr == "" then
            return string.rep(s, count)
        end
        local t = {}
        for i = 1, count do
            t[i] = s
        end
        return table.concat(t, sepStr)
    end
    _safeString.dump = function(fn)
        if hostType(fn) ~= "function" then
            hostError("bad argument #1 to 'dump' (function expected, got " .. _sandboxType(fn) .. ")", 2)
        end
        if _isSandboxCClosure(fn) then
            hostError("unable to dump given function", 2)
        end
        return "\27LuaQ\0\1\4\4\4\8\0"
    end

    local _safeBuffer = hostType(buffer) == "table" and table.clone(buffer) or {}
    _safeBuffer.writei64 = function(b, offset, val)
        local n = math.floor(hostTonumber(val) or 0)
        local neg = n < 0
        local absn = neg and (-n) or n
        local lo = absn % 4294967296
        local hi = math.floor(absn / 4294967296) % 4294967296
        if neg then
            lo = (4294967296 - lo) % 4294967296
            local borrow = (lo == 0) and 0 or 1
            hi = (4294967296 - hi - borrow) % 4294967296
        end
        buffer.writeu32(b, offset, lo)
        buffer.writeu32(b, offset + 4, hi)
    end
    _safeBuffer.readi64 = function(b, offset)
        local lo = buffer.readu32(b, offset)
        local hi = buffer.readu32(b, offset + 4)
        if hi >= 2147483648 then
            local negLo = (4294967296 - lo) % 4294967296
            local borrow = (negLo == 0) and 0 or 1
            local negHi = (4294967296 - hi - borrow) % 4294967296
            return -(negHi * 4294967296 + negLo)
        end
        return hi * 4294967296 + lo
    end
    _safeBuffer.writeu64 = function(b, offset, val)
        local n = math.floor(hostTonumber(val) or 0)
        local lo = n % 4294967296
        local hi = math.floor(n / 4294967296) % 4294967296
        buffer.writeu32(b, offset, lo)
        buffer.writeu32(b, offset + 4, hi)
    end
    _safeBuffer.readu64 = function(b, offset)
        local lo = buffer.readu32(b, offset)
        local hi = buffer.readu32(b, offset + 4)
        return hi * 4294967296 + lo
    end

    local function _freezeStd(lib)
        if hostType(lib) ~= "table" then return lib end
        if table.isfrozen and table.isfrozen(lib) then return lib end
        return table.freeze(table.clone(lib))
    end
    local _safeUtf8 = table.clone(utf8)
    if not _safeUtf8.graphemes then
        _safeUtf8.graphemes = function(s, i, j)
            s = hostTostring(s or "")
            local startPos = i or 1
            local endPos = j or #s
            if startPos < 1 then startPos = 1 end
            local cur = startPos
            return function()
                if cur > endPos or cur > #s then return nil end
                local nextPos = utf8.offset(s, 2, cur)
                if not nextPos or nextPos - 1 > endPos then
                    nextPos = endPos + 1
                end
                local a, b = cur, nextPos - 1
                cur = nextPos
                return a, b
            end
        end
    end

    env.math = _freezeStd(math)
    env.string = table.freeze(_safeString)
    env.table = _freezeStd(table)
    env.coroutine = _freezeStd(coroutine)
    env.utf8 = table.freeze(_safeUtf8)
    env.bit32 = _freezeStd(bit32)
    env.buffer = table.freeze(_safeBuffer)
    env.os = _safeOs
    env.debug = _safeDebug
    env.task = _safeTask
    env.wait = _safeTask.wait
    env.spawn = _safeTask.spawn
    env.delay = _safeTask.delay
    env.tick = function() return hostTime() + _simTime end
    env.time = function() return _simTime end
    env.elapsedTime = function() return hostClock() - _startClock end

    env.print = function(...)
        local parts = hostPack(...)
        local out = {}
        for i = 1, parts.n do
            out[i] = _formatArg(parts[i], 0)
        end
        _emitLine("print(" .. table.concat(out, ", ") .. ")")
    end
    env.warn = function(...)
        local parts = hostPack(...)
        local out = {}
        for i = 1, parts.n do
            out[i] = _formatArg(parts[i], 0)
        end
        _emitLine("warn(" .. table.concat(out, ", ") .. ")")
    end
    env.error = hostError
    env.assert = assert
    env.pcall = hostPcall
    env.xpcall = hostXpcall
    env.tostring = hostTostring
    env.tonumber = hostTonumber
    env.type = _sandboxType
    env.typeof = _sandboxTypeof
    env.select = select
    env.ipairs = hostIpairs
    env.pairs = hostPairs
    env.next = hostNext
    env.rawget = hostRawget
    env.rawset = hostRawset
    env.rawequal = hostRawequal
    env.rawlen = hostRawlen
    env.unpack = hostUnpack
    env.setmetatable = function(t, mt)
        _rawMetaMap[t] = mt
        return hostSetmetatable(t, mt)
    end
    env.getmetatable = function(...)
        if select("#", ...) == 0 then
            hostError("missing argument #1 to 'getmetatable' (value expected)", 2)
        end
        local t = ...
        if hostType(t) == "string" then return "The metatable is locked" end
        if _proxyTypes[t] then return "The metatable is locked" end
        return hostGetmetatable(t)
    end
    env.newproxy = newproxy or function(withMt)
        local p = hostSetmetatable({}, withMt and {} or nil)
        return p
    end

    env.require = function(mod)
        if hostType(mod) == "string" then
            hostError("require: blocked module " .. mod, 2)
        end
        return {}
    end
    local _loadstringInner = hostSetmetatable({}, { __mode = "k" })
    local _sandboxEnvs = hostSetmetatable({ [env] = true }, { __mode = "k" })
    env.getfenv = function(target)
        local fallback = env
        if hostGetfenv then
            local okc, ce = hostPcall(hostGetfenv, 2)
            if okc and hostType(ce) == "table" and _sandboxEnvs[ce] then
                fallback = ce
            end
        end
        if hostType(target) == "thread" or target == 0 then
            return fallback
        end
        if target == nil then
            return fallback
        end
        if hostType(target) == "number" and hostGetfenv then
            local ok, res = hostPcall(hostGetfenv, target + 1)
            if ok and hostType(res) == "table" and _sandboxEnvs[res] then return res end
            return fallback
        end
        if hostType(target) == "function" and hostGetfenv then
            local inner = _loadstringInner[target] or target
            local ok, res = hostPcall(hostGetfenv, inner)
            if ok and hostType(res) == "table" and _sandboxEnvs[res] then return res end
            return fallback
        end
        return fallback
    end
    env.setfenv = function(fn, newEnv)
        if hostType(newEnv) ~= "table" then
            hostError("bad argument #2 to 'setfenv' (table expected, got " .. _sandboxType(newEnv) .. ")", 2)
        end
        _sandboxEnvs[newEnv] = true
        if hostType(fn) == "function" and hostSetfenv then
            local inner = _loadstringInner[fn]
            if inner then
                hostSetfenv(inner, newEnv)
                hostPcall(hostSetfenv, fn, newEnv)
                return fn
            end
            return hostSetfenv(fn, newEnv)
        end
        if hostType(fn) == "number" and fn >= 1 and hostSetfenv then
            return hostSetfenv(fn + 1, newEnv)
        end
        hostError("bad argument #1 to 'setfenv' (function expected)", 2)
    end

    local _renv = {}
    env.identifyexecutor = function() return "kenV1", "2.0" end
    env.getexecutorname = function() return "kenV1" end
    env.getexecutorversion = function() return "2.0" end
    env.getgenv = function() return env end
    env.getrenv = function() return _renv end
    env.settings = function() return _createInstance("GlobalSettings", "GlobalSettings", nil) end
    env.UserSettings = function() return _createInstance("UserSettings", "UserSettings", nil) end
    env.PluginManager = function()
        return _createInstance("PluginManager", "PluginManager", nil, {
            CreatePlugin = function() return _createInstance("Plugin", "Plugin", nil) end,
        })
    end
    env.getsenv = function(scriptObj)
        if not _proxyTypes[scriptObj] then
            hostError("invalid argument #1 to 'getsenv' (Instance expected, got " .. _sandboxType(scriptObj) .. ")", 2)
        end
        local base = _refBaseMap[scriptObj] or scriptObj
        local p = _proxyProps[base]
        local cn = p and p.ClassName or ""
        if cn ~= "ModuleScript" and cn ~= "LocalScript" and cn ~= "Script" then
            hostError("invalid argument #1 to 'getsenv' (ModuleScript/LocalScript/Script expected, got Instance)", 2)
        end
        return env
    end
    env.getmenv = function() return {} end
    env.gethui  = function() return _services.CoreGui end
    env.checkcaller = function() return true end
    env.getcallingscript = function() return env.script end
    env.getnamecallmethod = function() return _currentNamecallMethod end
    env.setnamecallmethod = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("missing or invalid argument #1 to 'setnamecallmethod'", 2)
        end
        _currentNamecallMethod = ...
    end
    env.cloneref = function(inst)
        if not _proxyTypes[inst] then return inst end
        local base = _refBaseMap[inst] or inst
        local p = _proxyProps[base] or {}
        local clone = _makeInstanceProxy(p.ClassName or "Instance", p.Name or "Instance", _proxyParent[base], p)
        _refBaseMap[clone] = base
        _proxyPaths[clone] = _proxyPaths[base]
        return clone
    end
    env.compareinstances = function(a, b)
        return (_refBaseMap[a] or a) == (_refBaseMap[b] or b)
    end
    env.newcclosure = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "function" then
            hostError("bad argument #1 to 'newcclosure' (function expected)", 2)
        end
        local fn = ...
        local w = function(...) return fn(...) end
        _cclosureSet[w] = true
        return w
    end
    env.iscclosure = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "function" then
            hostError("bad argument #1 to 'iscclosure' (function expected)", 2)
        end
        return _isSandboxCClosure(...)
    end
    env.islclosure = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "function" then
            hostError("bad argument #1 to 'islclosure' (function expected)", 2)
        end
        return not _isSandboxCClosure(...)
    end
    env.isexecutorclosure = function(fn) return hostType(fn) == "function" and (_cclosureSet[fn] == true or env.islclosure(fn)) end
    env.isourclosure = env.isexecutorclosure
    env.checkclosure = env.isexecutorclosure
    env.clonefunction = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "function" then
            hostError("bad argument #1 to 'clonefunction' (function expected)", 2)
        end
        local fn = ...
        local w = function(...) return fn(...) end
        if _isSandboxCClosure(fn) then
            _cclosureSet[w] = true
        end
        return w
    end
    env.hookfunction = function(target, replacement)
        _hookedMap[target] = replacement
        return target
    end
    env.replaceclosure = env.hookfunction
    env.isfunctionhooked = function(fn) return _hookedMap[fn] ~= nil end
    env.restorefunction = function(fn) _hookedMap[fn] = nil end
    local _lockedStringMt = table.freeze({ __index = _safeString, __metatable = "The metatable is locked" })
    local _roGuardMt = { __newindex = function() hostError("attempt to modify a readonly table", 2) end }
    env.getrawmetatable = function(obj)
        if hostType(obj) == "string" then return _lockedStringMt end
        return _rawMetaMap[obj] or hostGetmetatable(obj)
    end
    env.setrawmetatable = function(obj, mt)
        if hostType(obj) == "string" then
            hostError("cannot change a protected metatable", 2)
        end
        _rawMetaMap[obj] = mt
        return hostSetmetatable(obj, mt)
    end
    env.setreadonly = function(t, flag)
        if hostType(t) ~= "table" then hostError("bad argument #1 to 'setreadonly' (table expected)", 2) end
        if t == _lockedStringMt or t == _gameMt then return end
        local ro = (flag == true)
        _readOnlyMap[t] = ro
        if not (table.isfrozen and table.isfrozen(t)) then
            local curMt = hostGetmetatable(t)
            if ro and curMt == nil then
                hostSetmetatable(t, _roGuardMt)
            elseif not ro and curMt == _roGuardMt then
                hostSetmetatable(t, nil)
            end
        end
    end
    env.isreadonly = function(t)
        if table.isfrozen and table.isfrozen(t) then return true end
        return _readOnlyMap[t] == true
    end
    env.make_readonly = function(t) env.setreadonly(t, true) end
    env.make_writeable = function(t) env.setreadonly(t, false) end
    env.hookmetamethod = function(...)
        if select("#", ...) < 3 then
            hostError("missing argument to 'hookmetamethod'", 2)
        end
        local obj, method, fn = ...
        if hostType(method) ~= "string" or hostType(fn) ~= "function" then
            hostError("invalid argument to 'hookmetamethod'", 2)
        end
        if obj == _game and _gameHooks[method] ~= nil then
            local old = _gameHooks[method]
            _gameHooks[method] = fn
            return old
        end
        local mt = env.getrawmetatable(obj)
        if hostType(mt) ~= "table" then return nil end
        local old = rawget(mt, method)
        if not (table.isfrozen and table.isfrozen(mt)) then
            rawset(mt, method, fn)
        end
        return old
    end
    env.getgc = function() return {} end
    env.filtergc = function() return {} end
    env.getreg = function() return { env.pcall, env.xpcall, env.type, env.tostring, env } end
    env.getinstances = function()
        local out = {}
        for inst in hostPairs(_allInstances) do
            if not _destroyedMap[inst] then out[#out + 1] = inst end
        end
        return out
    end
    env.getnilinstances = function()
        local out = {}
        for inst in hostPairs(_allInstances) do
            if not _destroyedMap[inst] and inst ~= _game and _proxyParent[inst] == nil then
                out[#out + 1] = inst
            end
        end
        return out
    end
    local _defaultScripts = {}
    local _defaultModules = {}
    do
        local scriptNames = {
            { "LocalScript", "ControlScript", _services.CoreGui },
            { "LocalScript", "ChatScript", _services.CoreGui },
            { "LocalScript", "BubbleChat", _services.CoreGui },
            { "LocalScript", "BackpackScript", _services.CoreGui },
            { "LocalScript", "PlayerListManager", _services.CoreGui },
            { "LocalScript", "HealthScript", _services.CoreGui },
            { "LocalScript", "TopBar", _services.CoreGui },
            { "LocalScript", "EmotesMenuMaster", _services.CoreGui },
            { "LocalScript", "InspectAndBuy", _services.CoreGui },
            { "LocalScript", "PlayerModule", _services.StarterPlayer },
            { "ModuleScript", "CameraModule", _services.StarterPlayer },
            { "ModuleScript", "ControlModule", _services.StarterPlayer },
            { "ModuleScript", "BaseCamera", _services.StarterPlayer },
            { "ModuleScript", "ClassicCamera", _services.StarterPlayer },
            { "ModuleScript", "OrbitalCamera", _services.StarterPlayer },
            { "ModuleScript", "CameraInput", _services.StarterPlayer },
            { "ModuleScript", "CameraUtils", _services.StarterPlayer },
            { "ModuleScript", "Keyboard", _services.StarterPlayer },
            { "ModuleScript", "TouchJump", _services.StarterPlayer },
            { "ModuleScript", "TouchThumbstick", _services.StarterPlayer },
            { "ModuleScript", "DynamicThumbstick", _services.StarterPlayer },
            { "ModuleScript", "Gamepad", _services.StarterPlayer },
            { "ModuleScript", "Roact", _services.CorePackages },
            { "ModuleScript", "Rodux", _services.CorePackages },
            { "ModuleScript", "Cryo", _services.CorePackages },
            { "LocalScript", "Animate", _character },
        }
        for _, entry in hostIpairs(scriptNames) do
            local s = _createInstance(entry[1], entry[2], entry[3])
            _defaultScripts[#_defaultScripts + 1] = s
            if entry[1] == "ModuleScript" then
                _defaultModules[#_defaultModules + 1] = s
            end
        end
    end
    env.getscripts = function()
        local out = { env.script }
        for _, s in hostIpairs(_defaultScripts) do
            if s ~= env.script then out[#out + 1] = s end
        end
        return out
    end
    env.getrunningscripts = function()
        local out = { env.script }
        for _, s in hostIpairs(_defaultScripts) do
            if s ~= env.script and _proxyProps[s] and _proxyProps[s].ClassName ~= "ModuleScript" then
                out[#out + 1] = s
            end
        end
        return out
    end
    env.getloadedmodules = function()
        local out = {}
        for _, m in hostIpairs(_defaultModules) do
            out[#out + 1] = m
        end
        return out
    end
    env.getconnections = function(...)
        if select("#", ...) == 0 or ... == nil then hostError("missing argument #1 to 'getconnections'", 2) end
        local sig = ...
        local list = _signalListeners[sig]
        local out = {}
        if list then
            for _, entry in hostIpairs(list) do
                if entry.conn and entry.conn.Connected then
                    out[#out + 1] = entry.conn
                end
            end
        end
        return out
    end
    env.firesignal = function(...)
        if select("#", ...) == 0 or ... == nil then hostError("missing argument #1 to 'firesignal'", 2) end
        local sig = ...
        if hostType(sig) == "table" and sig.Fire then
            sig:Fire(select(2, ...))
        end
    end
    env.fireclickdetector = function(...)
        if select("#", ...) == 0 or not _proxyTypes[...] then hostError("invalid argument #1 to 'fireclickdetector'", 2) end
    end
    env.firetouchinterest = function() end
    env.fireproximityprompt = function(...)
        if select("#", ...) == 0 or not _proxyTypes[...] then hostError("invalid argument #1 to 'fireproximityprompt'", 2) end
    end
    env.replicatesignal = function() end
    env.gethiddenproperty = function(...)
        if select("#", ...) < 2 then hostError("missing argument to 'gethiddenproperty'", 2) end
        local obj, k = ...
        if not _proxyTypes[obj] or hostType(k) ~= "string" then hostError("invalid argument to 'gethiddenproperty'", 2) end
        local ok, v = hostPcall(function() return obj[k] end)
        return ok and v or nil, false
    end
    env.sethiddenproperty = function(...)
        if select("#", ...) < 3 then hostError("missing argument to 'sethiddenproperty'", 2) end
        local obj, k, v = ...
        if not _proxyTypes[obj] or hostType(k) ~= "string" then hostError("invalid argument to 'sethiddenproperty'", 2) end
        hostPcall(function() obj[k] = v end)
        return true
    end
    env.isscriptable = function() return true end
    env.setscriptable = function() return true end
    env.isnetworkowner = function(...)
        if select("#", ...) == 0 or not _proxyTypes[...] then hostError("invalid argument #1 to 'isnetworkowner'", 2) end
        return true
    end
    env.setsimulationradius = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "number" then hostError("invalid argument #1 to 'setsimulationradius'", 2) end
    end
    env.gethwid = function() return "00000000-0000-0000-0000-000000000000" end
    env.getfpscap = function() return 60 end
    env.setfpscap = function() end
    env.getthreadidentity = function() return 8 end
    env.setthreadidentity = function() end
    env.getidentity = env.getthreadidentity
    env.setidentity = env.setthreadidentity
    env.setclipboard = function(s) _emitLine("-- clipboard: " .. hostTostring(s)) end
    env.toclipboard = env.setclipboard
    env.getclipboard = function() return "" end
    env.isrbxactive = function() return true end
    env.iswindowactive = function() return true end
    env.isrobloxactive = env.isrbxactive
    env.isgameactive = env.isrbxactive
    env.messagebox = function() return 1 end
    env.rconsolecreate = function() end
    env.rconsolesettitle = function() end
    env.rconsolename = env.rconsolesettitle
    env.rconsoleprint = function() end
    env.rconsoleerror = function() end
    env.rconsolewarn = function() end
    env.rconsoleinfo = function() end
    env.rconsoleclear = function() end
    env.rconsoledestroy = function() end
    env.consolecreate = env.rconsolecreate
    env.consolesettitle = env.rconsolesettitle
    env.consoleprint = env.rconsoleprint
    env.consoleerror = env.rconsoleerror
    env.consolewarn = env.rconsolewarn
    env.consoledestroy = env.rconsoledestroy
    env.mouse1click = function() end
    env.mouse2click = function() end
    env.keypress = function() end
    env.keyrelease = function() end
    env.mousemoverel = function() end
    env.mousemoveabs = function() end
    env.decompile = function() return "-- decompiled" end
    env.getscriptbytecode = function() return "" end
    env.getscripthash = function() return "00000000" end
    env.getfunctionhash = function() return "00000000" end
    env.getscriptclosure = function(...)
        if select("#", ...) == 0 or ... == nil then
            hostError("missing argument #1 to 'getscriptclosure'", 2)
        end
        local scr = ...
        if not _proxyTypes[scr] then
            hostError("invalid argument #1 to 'getscriptclosure' (Instance expected, got " .. _sandboxTypeof(scr) .. ")", 2)
        end
        return function() end
    end
    env.getscriptfunction = env.getscriptclosure

    local _vfsFiles = {}
    local _vfsFolders = { [""] = true }
    local function _vfsNorm(p)
        local s = hostTostring(p):gsub("\\", "/"):gsub("^%./", ""):gsub("/+", "/"):gsub("/$", "")
        if s == "." then s = "" end
        return s
    end
    local function _vfsEnsureParents(np)
        local cur = ""
        for part in np:gmatch("[^/]+") do
            if cur == "" then cur = part else cur = cur .. "/" .. part end
            if cur ~= np then
                _vfsFolders[cur] = true
            end
        end
    end
    env.readfile = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'readfile' (string expected)", 2)
        end
        local np = _vfsNorm(...)
        local data = _vfsFiles[np]
        if data == nil then
            hostError("file does not exist: " .. hostTostring(...), 2)
        end
        return data
    end
    env.writefile = function(...)
        if select("#", ...) < 1 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'writefile' (string expected)", 2)
        end
        local p, data = ...
        if select("#", ...) < 2 or hostType(data) ~= "string" then
            hostError("bad argument #2 to 'writefile' (string expected)", 2)
        end
        local np = _vfsNorm(p)
        _vfsEnsureParents(np)
        _vfsFolders[np] = nil
        _vfsFiles[np] = data
    end
    env.appendfile = function(...)
        if select("#", ...) < 1 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'appendfile' (string expected)", 2)
        end
        local p, data = ...
        if select("#", ...) < 2 or hostType(data) ~= "string" then
            hostError("bad argument #2 to 'appendfile' (string expected)", 2)
        end
        local np = _vfsNorm(p)
        _vfsEnsureParents(np)
        _vfsFolders[np] = nil
        _vfsFiles[np] = (_vfsFiles[np] or "") .. data
    end
    env.isfile = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'isfile' (string expected)", 2)
        end
        return _vfsFiles[_vfsNorm(...)] ~= nil
    end
    env.isfolder = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'isfolder' (string expected)", 2)
        end
        local np = _vfsNorm(...)
        return _vfsFolders[np] == true and _vfsFiles[np] == nil
    end
    env.makefolder = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'makefolder' (string expected)", 2)
        end
        local np = _vfsNorm(...)
        _vfsEnsureParents(np)
        _vfsFiles[np] = nil
        _vfsFolders[np] = true
    end
    env.delfile = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'delfile' (string expected)", 2)
        end
        _vfsFiles[_vfsNorm(...)] = nil
    end
    env.delfolder = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'delfolder' (string expected)", 2)
        end
        local np = _vfsNorm(...)
        if np == "" then return end
        local prefix = np .. "/"
        _vfsFolders[np] = nil
        for k in hostPairs(_vfsFolders) do
            if k:sub(1, #prefix) == prefix then _vfsFolders[k] = nil end
        end
        for k in hostPairs(_vfsFiles) do
            if k == np or k:sub(1, #prefix) == prefix then _vfsFiles[k] = nil end
        end
    end
    env.listfiles = function(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'listfiles' (string expected)", 2)
        end
        local np = _vfsNorm(...)
        local prefix = np == "" and "" or (np .. "/")
        local out = {}
        local seen = {}
        for k in hostPairs(_vfsFiles) do
            if prefix == "" then
                if k ~= "" and not k:find("/", 1, true) and not seen[k] then
                    seen[k] = true
                    out[#out + 1] = k
                end
            elseif k:sub(1, #prefix) == prefix then
                local rest = k:sub(#prefix + 1)
                if rest ~= "" and not rest:find("/", 1, true) and not seen[k] then
                    seen[k] = true
                    out[#out + 1] = k
                end
            end
        end
        for k in hostPairs(_vfsFolders) do
            if k ~= "" then
                if prefix == "" then
                    if not k:find("/", 1, true) and not seen[k] then
                        seen[k] = true
                        out[#out + 1] = k
                    end
                elseif k:sub(1, #prefix) == prefix then
                    local rest = k:sub(#prefix + 1)
                    if rest ~= "" and not rest:find("/", 1, true) and not seen[k] then
                        seen[k] = true
                        out[#out + 1] = k
                    end
                end
            end
        end
        return out
    end
    env.request = function(opts)
        local url = hostType(opts) == "table" and (opts.Url or opts.url) or opts
        _emitLine(string.format("request({ Url = %s })", _formatArg(url)))
        return { StatusCode = 200, Success = true, Body = "", Headers = {} }
    end
    env.http_request = env.request
    env.http = { request = env.request }
    local _b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function _b64Encode(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'base64encode' (string expected)", 2)
        end
        local data = ...
        return ((data:gsub(".", function(x)
            local r, b = "", x:byte()
            for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
            return r
        end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
            if #x < 6 then return "" end
            local c = 0
            for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
            return _b64chars:sub(c + 1, c + 1)
        end) .. ({ "", "==", "=" })[#data % 3 + 1])
    end
    local function _b64Decode(...)
        if select("#", ...) == 0 or hostType(...) ~= "string" then
            hostError("bad argument #1 to 'base64decode' (string expected)", 2)
        end
        local data = (...):gsub("[^" .. _b64chars .. "=]", "")
        return (data:gsub(".", function(x)
            if x == "=" then return "" end
            local r, f = "", (_b64chars:find(x, 1, true) - 1)
            for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
            return r
        end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
            if #x ~= 8 then return "" end
            local c = 0
            for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
            return string.char(c)
        end))
    end
    local _sha256K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }
    local function _sha256Hex(data)
        local msg = hostTostring(data or "")
        local bitlen = #msg * 8
        msg = msg .. string.char(0x80)
        local pad = (56 - (#msg % 64)) % 64
        if pad > 0 then
            msg = msg .. string.rep("\0", pad)
        end
        local hi = math.floor(bitlen / 4294967296)
        local lo = bitlen % 4294967296
        msg = msg .. string.char(
            bit32.band(bit32.rshift(hi, 24), 0xff),
            bit32.band(bit32.rshift(hi, 16), 0xff),
            bit32.band(bit32.rshift(hi, 8), 0xff),
            bit32.band(hi, 0xff),
            bit32.band(bit32.rshift(lo, 24), 0xff),
            bit32.band(bit32.rshift(lo, 16), 0xff),
            bit32.band(bit32.rshift(lo, 8), 0xff),
            bit32.band(lo, 0xff)
        )
        local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
        local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        local w = {}
        for off = 1, #msg, 64 do
            for i = 1, 16 do
                local b1, b2, b3, b4 = string.byte(msg, off + (i - 1) * 4, off + i * 4 - 1)
                w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
            end
            for i = 17, 64 do
                local w15 = w[i - 15]
                local w2 = w[i - 2]
                local s0 = bit32.bxor(bit32.rrotate(w15, 7), bit32.rrotate(w15, 18), bit32.rshift(w15, 3))
                local s1 = bit32.bxor(bit32.rrotate(w2, 17), bit32.rrotate(w2, 19), bit32.rshift(w2, 10))
                w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
            end
            local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
            for i = 1, 64 do
                local S1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
                local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
                local t1 = (h + S1 + ch + _sha256K[i] + w[i]) % 4294967296
                local S0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
                local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
                local t2 = (S0 + maj) % 4294967296
                h = g; g = f; f = e; e = (d + t1) % 4294967296
                d = c; c = b; b = a; a = (t1 + t2) % 4294967296
            end
            h0 = (h0 + a) % 4294967296
            h1 = (h1 + b) % 4294967296
            h2 = (h2 + c) % 4294967296
            h3 = (h3 + d) % 4294967296
            h4 = (h4 + e) % 4294967296
            h5 = (h5 + f) % 4294967296
            h6 = (h6 + g) % 4294967296
            h7 = (h7 + h) % 4294967296
        end
        return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
    end
    env.crypt = {
        base64encode = _b64Encode,
        base64decode = _b64Decode,
        base64 = { encode = _b64Encode, decode = _b64Decode },
        encrypt = function(...)
            if select("#", ...) < 2 then hostError("missing argument to 'crypt.encrypt'", 2) end
            return _b64Encode(hostTostring(...)), "iv"
        end,
        decrypt = function(...)
            if select("#", ...) < 2 then hostError("missing argument to 'crypt.decrypt'", 2) end
            return _b64Decode(hostTostring(...))
        end,
        hash = function(s, alg)
            local a = alg == nil and "sha256" or hostTostring(alg):lower():gsub("%-", "")
            local hex = _sha256Hex(a .. ":" .. hostTostring(s or ""))
            if a == "sha256" then return _sha256Hex(s) end
            if a == "md5" then return hex:sub(1, 32) end
            if a == "sha1" then return hex:sub(1, 40) end
            return hex
        end,
    }
    env.base64 = { encode = _b64Encode, decode = _b64Decode }
    env.bit = bit32
    env.syn = {
        request = env.request,
        crypt = env.crypt,
        protect_gui = function() end,
        unprotect_gui = function() end,
        set_thread_identity = env.setthreadidentity,
        get_thread_identity = env.getthreadidentity,
    }
    env.fluxus = { request = env.request }
    env.lz4compress = function(s) return s end
    env.lz4decompress = function(s) return s end
    env.Drawing = {
        Fonts = { UI = 0, System = 1, Plex = 2, Monospace = 3 },
        new = function() return { Visible = false, Remove = function() end, Destroy = function() end } end,
    }
    env.WebSocket = { connect = function(url) _emitLine(string.format("WebSocket.connect(%s)", _formatArg(url))); return { Send = function() end, Close = function() end, OnMessage = _makeSignal("OnMessage"), OnClose = _makeSignal("OnClose") } end }

    local function _isDenseObfuscatedStage(src)
        if #src <= 4096 then return false end
        local _, nlCount = src:gsub("\n", "\n")
        if nlCount == 0 then return true end
        if (#src / (nlCount + 1)) > 250 then return true end
        return false
    end

    env.loadstring = function(src, chunkName, _mode, customEnv)
        if hostType(src) ~= "string" then
            return nil, "loadstring expected string"
        end
        local denseStage = _isDenseObfuscatedStage(src)
        local shouldEmit = #src >= 16 and not _seenStageHash[src] and _stageDepth < _MAX_STAGE_DEPTH and not denseStage
        if shouldEmit then
            _seenStageHash[src] = true
            _emitLine(src)
        elseif denseStage then
            _seenStageHash[src] = true
        end
        local fn, loadErr = hostLoad(src, chunkName or "loadstring", "t", hostType(customEnv) == "table" and customEnv or env)
        if not fn then
            return nil, loadErr
        end
        local wrapper = function(...)
            local beforeCount = _capturedCount
            _stageDepth = _stageDepth + 1
            local results = hostPack(hostPcall(fn, ...))
            _stageDepth = _stageDepth - 1
            if denseStage and _capturedCount == beforeCount and #src <= 65536 then
                _emitLine(src)
            end
            if not results[1] then
                hostError(results[2], 0)
            end
            return hostUnpack(results, 2, results.n)
        end
        _loadstringInner[wrapper] = fn
        return wrapper
    end
    env.load = env.loadstring
    env.getconstant = _safeDebug.getconstant
    env.getconstants = _safeDebug.getconstants
    env.setconstant = _safeDebug.setconstant
    env.getupvalues = _safeDebug.getupvalues
    env.getupvalue = _safeDebug.getupvalue
    env.setupvalue = _safeDebug.setupvalue
    env.getproto = _safeDebug.getproto
    env.getprotos = _safeDebug.getprotos
    env.getstack = _safeDebug.getstack
    env.setstack = _safeDebug.setstack
    env.getinfo = _safeDebug.getinfo

    for k, fn in hostPairs(env) do
        if hostType(fn) == "function" then
            _cclosureSet[fn] = true
            _cclosureNames[fn] = k
        end
    end
    for _, k in hostIpairs({ "game", "workspace", "Workspace", "math", "string", "table", "coroutine", "utf8", "bit32", "buffer", "task", "os", "debug", "print", "warn", "pcall", "xpcall", "type", "typeof", "tostring", "tonumber", "select", "next", "pairs", "ipairs", "rawget", "rawset", "rawequal", "rawlen", "error", "assert" }) do
        _renv[k] = env[k]
    end
    local _cclosureLibs = {
        env.Instance, env.task, env.os, env.debug, env.crypt, env.base64,
        env.http, env.syn, env.fluxus, env.Drawing, env.WebSocket, env.Content,
        env.Secret, env.SharedTable, env.SecurityCapabilities,
        env.math, env.string, env.table, env.coroutine, env.utf8, env.bit32,
        env.buffer, env.bit, env.Vector2, env.Vector3, env.CFrame, env.Color3,
        env.BrickColor, env.UDim, env.UDim2, env.TweenInfo, env.Ray, env.Rect,
        env.Region3, env.NumberRange, env.NumberSequence, env.NumberSequenceKeypoint,
        env.ColorSequence, env.ColorSequenceKeypoint, env.PhysicalProperties,
        env.Faces, env.Axes, env.OverlapParams, env.RaycastParams, env.PathWaypoint,
        env.Path2DControlPoint, env.RotationCurveKey,
        env.Random, env.DateTime, env.Font, _marketplaceService,
    }
    for _, lib in hostIpairs(_cclosureLibs) do
        if hostType(lib) == "table" then
            for k, sub in hostPairs(lib) do
                if hostType(sub) == "function" then
                    _cclosureSet[sub] = true
                    if not _cclosureNames[sub] then _cclosureNames[sub] = hostTostring(k) end
                elseif hostType(sub) == "table" then
                    for k2, sub2 in hostPairs(sub) do
                        if hostType(sub2) == "function" then
                            _cclosureSet[sub2] = true
                            if not _cclosureNames[sub2] then _cclosureNames[sub2] = hostTostring(k2) end
                        end
                    end
                end
            end
        end
    end

    return env
end

_sandboxEnv = _makeSandboxEnv()

local mainFn, compileErr = hostLoad(SOURCE_CODE, "=Script", "t", _sandboxEnv)
if not mainFn then
    local stripped = SOURCE_CODE:gsub("[\r\n]+%s*[Ss]tatus%s*:[^\r\n]*%s*$", "")
    if stripped ~= SOURCE_CODE and stripped ~= "" then
        local retryFn = hostLoad(stripped, "=Script", "t", _sandboxEnv)
        if retryFn then
            mainFn = retryFn
            compileErr = nil
        end
    end
end
if not mainFn then
    io.stderr:write("compile error: " .. hostTostring(compileErr) .. "\n")
    os.exit(1)
end

local function _runFrame3(f)
    local r = hostPack(hostPcall(f))
    return r[1], r[2]
end
local function _runFrame2(f)
    local a, b = _runFrame3(f)
    return a, b
end
local function _runFrame1(f)
    local a, b = _runFrame2(f)
    return a, b
end
local ok, runErr = _runFrame1(mainFn)
if not ok then
    local errStr = hostTostring(runErr or "")
    if not errStr:find("maximum execution time exceeded", 1, true) then
        io.stderr:write("runtime error: " .. errStr .. "\n")
    end
end

local outputText = table.concat(_capturedLines, "\n")
local outFile, outErr = hostIoOpen(OUTPUT_PATH, "wb")
if not outFile then
    io.stderr:write("failed to open output: " .. hostTostring(outErr) .. "\n")
    os.exit(1)
end
outFile:write(outputText)
outFile:close()

io.stderr:write(string.format("captured %d lines in %.2fs\n", _capturedCount, hostClock() - _startClock))
os.exit(0)
