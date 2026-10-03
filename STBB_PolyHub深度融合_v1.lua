-- STBB / 封锁战线 修正版 v2
-- 修复重点：加载容错、技能回放时间/InvokeServer/Remote路径、角色状态切换、移动控制冲突、
-- 自动战斗物理对象误删、材料交互循环、商店价格读取、快速互动恢复、画质恢复、山本特效误删 Remote 等。
-- 注意：保留 Astro 模式原有固定路线坐标（按要求不改第8项）。

print("[ST脚本] 开始执行（修正版 v4）...")

pcall(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
end)
task.wait(0.35)

-- ==================== Rayfield 加载 ====================
-- 使用官方当前推荐入口；失败时输出明确错误，避免静默中断。
local Rayfield
local rayfieldLoadError

local function loadRayfield(url)
    if type(loadstring) ~= "function" then
        return nil, "当前执行器不支持 loadstring"
    end
    local ok, result = pcall(function()
        local source = game:HttpGet(url)
        if type(source) ~= "string" or #source == 0 then
            error("HttpGet 返回空内容")
        end
        local chunk = loadstring(source)
        if type(chunk) ~= "function" then
            error("Rayfield 源码编译失败")
        end
        return chunk()
    end)
    if not ok then
        return nil, tostring(result)
    end
    if type(result) ~= "table" or type(result.CreateWindow) ~= "function" then
        return nil, "返回对象不是有效 Rayfield"
    end
    return result
end

local rayfieldUrls = {
    "https://sirius.menu/rayfield",
    "https://raw.githubusercontent.com/sirius-menu/rayfield/refs/heads/main/source.lua",
}

for i, url in ipairs(rayfieldUrls) do
    local result, err = loadRayfield(url)
    if result then
        Rayfield = result
        print("[ST脚本] Rayfield 加载成功 (源" .. i .. ")")
        break
    end
    rayfieldLoadError = "源" .. i .. ": " .. tostring(err)
    warn("[ST脚本] Rayfield 加载失败：" .. rayfieldLoadError)
    if i < #rayfieldUrls then task.wait(0.25) end
end

if not Rayfield then
    warn("[ST脚本] Rayfield 无法加载，脚本停止。最后错误：" .. tostring(rayfieldLoadError))
    return
end

-- ==================== 服务 ====================
local function safeGetService(name)
    local ok, svc = pcall(function()
        return game:GetService(name)
    end)
    if ok then return svc end
    return nil
end

local Players = safeGetService("Players")
local RS = safeGetService("RunService")
local SG = safeGetService("StarterGui")
local RepStorage = safeGetService("ReplicatedStorage")
local Workspace = safeGetService("Workspace")
local Lighting = safeGetService("Lighting")
local UIS = safeGetService("UserInputService")
local HttpService = safeGetService("HttpService")
local CoreGui = safeGetService("CoreGui")
local TeleportService = safeGetService("TeleportService")
local VirtualInputManager = safeGetService("VirtualInputManager")
local TweenService = safeGetService("TweenService")
local GuiService = safeGetService("GuiService")
local ReplicatedFirst = safeGetService("ReplicatedFirst")

if not Players or not RS or not RepStorage or not Workspace or not Lighting then
    warn("[ST脚本] 关键 Roblox 服务获取失败，脚本安全停止。")
    return
end

local LP = Players.LocalPlayer
if not LP then
    warn("[ST脚本] LocalPlayer 尚未准备好，脚本安全停止。")
    return
end

local function getUiParent()
    if CoreGui then return CoreGui end
    return LP:FindFirstChild("PlayerGui") or LP
end

local function notify(title, text, dur)
    if SG then
        pcall(function()
            SG:SetCore("SendNotification", {
                Title = tostring(title),
                Text = tostring(text),
                Duration = dur or 2,
            })
        end)
    end
end

local remoteCache = {}

local function isRemoteObject(obj)
    return obj and (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction"))
end

local function findRemote(name, timeout)
    if type(name) ~= "string" or name == "" then return nil end
    timeout = tonumber(timeout) or 0

    local cached = remoteCache[name]
    if isRemoteObject(cached) and cached.Parent then
        return cached
    end
    remoteCache[name] = nil

    -- STBB 的公开脚本通常使用 ReplicatedStorage 直属 Remote；如果更新后
    -- 被放进文件夹/子系统，这里再递归找，避免所有功能同时失效。
    local found = RepStorage:FindFirstChild(name, true)
    if isRemoteObject(found) then
        remoteCache[name] = found
        return found
    end

    -- 少数版本会把接口临时放到 Workspace/其他容器；只做一次递归兜底。
    if Workspace then
        pcall(function()
            found = Workspace:FindFirstChild(name, true)
        end)
        if isRemoteObject(found) then
            remoteCache[name] = found
            return found
        end
    end

    local deadline = tick() + timeout
    repeat
        found = RepStorage:FindFirstChild(name, true)
        if isRemoteObject(found) then
            remoteCache[name] = found
            return found
        end
        if timeout <= 0 then break end
        task.wait(0.15)
    until tick() >= deadline

    -- 最后一层兼容：名字大小写变化时也尝试一次。
    local lname = name:lower()
    local ok = pcall(function()
        for _, obj in ipairs(RepStorage:GetDescendants()) do
            if isRemoteObject(obj) and obj.Name:lower() == lname then
                found = obj
                break
            end
        end
    end)
    if ok and isRemoteObject(found) then
        remoteCache[name] = found
        return found
    end
    return nil
end

local function fireRemote(name, ...)
    local r = findRemote(name, 1.5)
    if not r then return false, "找不到 Remote: " .. tostring(name) end
    local args = { ... }
    local ok, result = pcall(function()
        if r:IsA("RemoteEvent") then
            r:FireServer(table.unpack(args))
            return true
        elseif r:IsA("RemoteFunction") then
            return r:InvokeServer(table.unpack(args))
        else
            error("不是 RemoteEvent/RemoteFunction")
        end
    end)
    if not ok then return false, result end
    return true, result
end

pcall(function()
    UIS.MouseIconEnabled = true
end)

-- ==================== Anti AFK ====================
local idleConn
local function setupAntiAFK()
    if idleConn or not LP.Idled then return end
    idleConn = LP.Idled:Connect(function()
        task.wait(0.1)
        pcall(function()
            local vu = game:GetService("VirtualUser")
            local cam = Workspace.CurrentCamera
            if cam then vu:Button2Down(Vector2.new(0, 0), cam.CFrame) end
        end)
        task.wait(1)
        pcall(function()
            local vu = game:GetService("VirtualUser")
            local cam = Workspace.CurrentCamera
            if cam then vu:Button2Up(Vector2.new(0, 0), cam.CFrame) end
        end)
    end)
end
pcall(setupAntiAFK)

-- ==================== 通用工具 ====================
local function setGuiOpen(obj, state)
    if not obj then return false end
    local ok = pcall(function()
        if obj:IsA("ScreenGui") or obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then
            obj.Enabled = state
        elseif obj:IsA("GuiObject") then
            obj.Visible = state
        end
    end)
    return ok
end

local function findGuiByNames(root, names)
    if not root then return nil end
    for _, name in ipairs(names) do
        local obj = root:FindFirstChild(name, true)
        if obj then return obj end
    end
    return nil
end

local function parseNumberText(text)
    if type(text) ~= "string" or text == "" then return 0 end
    text = text:gsub(",", ""):gsub("%s", "")
    local num = tonumber(text:match("([%d%.]+)"))
    if not num then return 0 end
    local lower = text:lower()
    if lower:find("k", 1, true) then return num * 1000 end
    if lower:find("m", 1, true) then return num * 1000000 end
    if lower:find("b", 1, true) then return num * 1000000000 end
    return num
end

local function getMapMoney()
    -- 先走旧版已知路径。
    local pg = LP:FindFirstChild("PlayerGui")
    local handler = pg and pg:FindFirstChild("UIHandlerPlayer")
    local main = handler and handler:FindFirstChild("Main")
    local bottom = main and main:FindFirstChild("Bottom")
    local main2 = bottom and bottom:FindFirstChild("Main")
    local v1 = main2 and main2:FindFirstChild("V1")
    local ui = v1 and v1:FindFirstChild("UI")
    local coin = ui and ui:FindFirstChild("Coin")
    local ui2 = coin and coin:FindFirstChild("UI")
    local txt = ui2 and ui2:FindFirstChild("Text")
    local count = txt and txt:FindFirstChild("Count")
    if count and typeof(count.Text) == "string" then
        local n = parseNumberText(count.Text)
        if n >= 0 then return n end
    end

    -- 新版/事件模式兼容：优先找名称或属性明确带有 Cen/Coin/Money/Cash 的数值。
    local found = -1
    local candidates = {
        cen = true, cens = true, coin = true, coins = true, money = true, cash = true,
        credits = true, credit = true, currency = true, currentcen = true, currentmoney = true,
    }
    local function takeText(obj, text)
        if type(text) ~= "string" or text == "" then return end
        local n = parseNumberText(text)
        if n <= 0 then return end
        local nm = tostring(obj.Name or ""):lower():gsub("[%s_%-]", "")
        local parentName = obj.Parent and tostring(obj.Parent.Name or ""):lower():gsub("[%s_%-]", "") or ""
        if candidates[nm] or candidates[parentName] then found = n end
    end
    pcall(function()
        local ls = LP:FindFirstChild("leaderstats")
        if ls then
            for _, v in ipairs(ls:GetChildren()) do
                local nm = tostring(v.Name or ""):lower():gsub("[%s_%-]", "")
                if candidates[nm] and (v:IsA("IntValue") or v:IsA("NumberValue")) then
                    found = tonumber(v.Value) or found
                end
            end
        end
    end)
    if found > 0 then return found end

    pcall(function()
        for _, obj in ipairs(pg and pg:GetDescendants() or {}) do
            if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
                takeText(obj, obj.Text)
                if found > 0 then break end
            end
        end
    end)
    if found > 0 then return found end

    -- 最后读取玩家属性，兼容部分界面重构。
    for _, nm in ipairs({ "Cen", "Cens", "Coin", "Coins", "Money", "Cash", "Credits" }) do
        local ok, v = pcall(function() return LP:GetAttribute(nm) end)
        if ok and type(v) == "number" then return v end
    end
    return -1
end

local function getCharacter()
    local c = LP.Character
    if not c then return nil end
    return c
end

local function getHRP()
    local c = getCharacter()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local c = getCharacter()
    return c and c:FindFirstChildWhichIsA("Humanoid")
end

-- ==================== UI ====================
local okWindow, Window = pcall(function()
    return Rayfield:CreateWindow({
        Name = "封锁战线脚本（修正版）",
        LoadingTitle = "封锁战线脚本",
        LoadingSubtitle = "ST封锁战线 v2",
        ShowText = "封锁战线脚本",
        Icon = 0,
        Theme = "Default",
        DisableRayfieldPrompts = true,
        DisableBuildWarnings = true,
        ConfigurationSaving = { Enabled = false },
    })
end)

if not okWindow or not Window then
    warn("[ST脚本] Rayfield 窗口创建失败：" .. tostring(Window))
    return
end

local function safeCreateTab(name)
    local ok, tab = pcall(function() return Window:CreateTab(name) end)
    if ok and tab then return tab end
    warn("[ST脚本] Tab 创建失败: " .. tostring(name))
    return nil
end

local Tab1 = safeCreateTab("主要功能")
local Tab2 = safeCreateTab("其它")
local Tab3 = safeCreateTab("自动化")
local Tab4 = safeCreateTab("选择特殊泰坦")
local Tab5 = safeCreateTab("商店")
local Tab6 = safeCreateTab("付费功能")

if not Tab1 or not Tab2 or not Tab3 or not Tab4 or not Tab5 or not Tab6 then
    warn("[ST脚本] 部分 Tab 无法创建。脚本停止 UI 功能注册，但不会继续执行危险的半初始化逻辑。")
    return
end

-- ==================== 白名单 ====================
local _WLGuard = (function()
    local M = 2147483647
    local function djb2(s)
        local h = 5381
        for i = 1, #s do
            h = (h * 33 + s:byte(i)) % M
        end
        return h
    end
    local H = { [695095133] = true, [16031421] = true }
    local EXPECTED_COUNT = 2
    local sealed = false
    local api = {}
    function api.check(name)
        if sealed then return false end
        if type(name) ~= "string" or #name == 0 or #name > 64 then return false end
        return H[djb2(name)] == true
    end
    function api.verify()
        if type(H) ~= "table" then return false end
        local c = 0
        for _ in pairs(H) do c = c + 1 end
        return c == EXPECTED_COUNT
    end
    function api.seal() sealed = true end
    return api
end)()

local function checkIsWhitelisted()
    if type(_WLGuard) ~= "table" or not _WLGuard.verify() then return false end
    return _WLGuard.check(LP.Name) or _WLGuard.check(LP.DisplayName)
end

local function integrityCheck()
    if type(checkIsWhitelisted) ~= "function" then return false end
    if type(_WLGuard) ~= "table" or type(_WLGuard.verify) ~= "function" then return false end
    if not _WLGuard.verify() then return false end
    local ok, n = pcall(function() return LP.Name end)
    return ok and type(n) == "string"
end

-- ==================== 状态管理 ====================
local isCastingSkill = false
local isAstroRunning = false
local isTeleportingToMaterial = false
local isSkillPlaying = false
local autoTraceMaterialEnabled = false
local currentTraceTarget = nil
local autoAttackEnabled = false
local autoFireGunEnabled = false
local isShopping = false
local autoFlushBusy = false
local lockCameraEnabled = false
local currentTarget = nil
local cachedEnemy = nil
local lastHrpPosition = nil
local combatCooldownUntil = 0
local DISPLACEMENT_THRESHOLD = 8
local COOLDOWN_AFTER_DISPLACE = 0.8
local _materialTpCounter = 0

-- 当前角色/泰坦状态：只读取公开的 Attribute/Tool 信息；未知字段保持 nil，不猜测。
local CharacterState = {
    Titan = nil,
    Form = nil,
    Arm = nil,
    Alive = false,
    EquippedTool = nil,
}

local function refreshCharacterState()
    local c = getCharacter()
    local hum = getHumanoid()
    if not c then
        CharacterState.Titan = nil
        CharacterState.Form = nil
        CharacterState.Arm = nil
        CharacterState.Alive = false
        CharacterState.EquippedTool = nil
        return CharacterState
    end
    local function attr(...)
        local names = { ... }
        for _, name in ipairs(names) do
            local v = c:GetAttribute(name)
            if v ~= nil then return v end
        end
        return nil
    end
    CharacterState.Titan = attr("Titan", "Character", "Unit", "TitanName")
    CharacterState.Form = attr("Form", "State", "Mode", "TitanForm")
    CharacterState.Arm = attr("Arm", "Weapon", "EquippedArm")
    CharacterState.Alive = hum ~= nil and hum.Health > 0
    local held = c:FindFirstChildWhichIsA("Tool")
    CharacterState.EquippedTool = held and held.Name or nil
    return CharacterState
end

local function snapshotSkillState()
    refreshCharacterState()
    return {
        Titan = CharacterState.Titan,
        Form = CharacterState.Form,
        Arm = CharacterState.Arm,
        EquippedTool = CharacterState.EquippedTool,
    }
end

local function skillStateCompatible(state)
    if type(state) ~= "table" then return true end
    refreshCharacterState()
    for _, key in ipairs({ "Titan", "Form", "Arm" }) do
        local expected = state[key]
        if expected ~= nil and CharacterState[key] ~= nil and tostring(expected) ~= tostring(CharacterState[key]) then
            return false, key .. " 不匹配"
        end
    end
    return true
end

local function hardMovementBlocked()
    return isAstroRunning or isSkillPlaying or isShopping or isTeleportingToMaterial or autoFlushBusy
end


-- ==================== PolyHub 恢复状态 ====================
local Recovered = {
    autoFarmMode = "Tween", farmSpeed = 100, autoFarmTarget = nil, currentFarmTween = nil, lastLmbAttack = 0,
    faceNearestEnabled = false, faceTarget = nil, faceTargetStamp = 0, aimAttachment = nil, aimAlignOrientation = nil,
    hitboxEnabled = false, hitboxSize = 5, hitboxOriginals = {},
    espEnabled = false, espLinesEnabled = false, espColor = Color3.fromRGB(255, 0, 0), espLineColor = Color3.fromRGB(255, 0, 0),
    espSelection = {}, espBillboards = {}, espTracers = {},
    antiLagEnabled = false, antiLagOriginals = {},
    fullbrightEnabled = false, fullbrightOriginal = nil,
    walkSpeedEnabled = false, walkSpeedValue = 16, jumpPowerEnabled = false, jumpPowerValue = 50,
    fovEnabled = false, fovValue = 70, maxZoomEnabled = false, maxZoomValue = 128,
    antiJeffreyEnabled = false, currentMaterialJob = nil,
    flyVelocity = nil, flyGyro = nil,
    hitboxTargetParts = {"Head", "Fake Head", "Toilet"}
}

function Recovered.isEnemy(model)
    if not model or not model:IsA("Model") then return false end
    if model == getCharacter() then return false end
    if Players:GetPlayerFromCharacter(model) then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart")
    return hum ~= nil and hum.Health > 0 and root ~= nil
end

function Recovered.getClosestEnemy()
    local myRoot = getHRP()
    local living = Workspace:FindFirstChild("Living")
    if not myRoot or not living then return nil end
    local closest, closestDistance = nil, math.huge
    for _, obj in ipairs(living:GetChildren()) do
        if Recovered.isEnemy(obj) then
            local targetRoot = obj:FindFirstChild("HumanoidRootPart")
            local distance = (targetRoot.Position - myRoot.Position).Magnitude
            if distance < closestDistance then
                closestDistance = distance
                closest = obj
            end
        end
    end
    return closest
end

function Recovered.getCombatPart(model)
    if not model then return nil end
    local part = model:FindFirstChild("Fake Head") or model:FindFirstChild("Head")
    if model.Name == "Ginger Toilet" then
        part = model:FindFirstChild("Toilet") or part
    end
    return part or model:FindFirstChild("HumanoidRootPart")
end

function Recovered.createAimController()
    local humanoid, root = getHumanoid(), getHRP()
    if not humanoid or not root then return end
    if Recovered.aimAlignOrientation and Recovered.aimAlignOrientation.Parent == root then return end
    if Recovered.aimAlignOrientation then pcall(function() Recovered.aimAlignOrientation:Destroy() end) end
    if Recovered.aimAttachment then pcall(function() Recovered.aimAttachment:Destroy() end) end
    humanoid.AutoRotate = false
    Recovered.aimAttachment = Instance.new("Attachment")
    Recovered.aimAttachment.Parent = root
    Recovered.aimAlignOrientation = Instance.new("AlignOrientation")
    Recovered.aimAlignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
    Recovered.aimAlignOrientation.Attachment0 = Recovered.aimAttachment
    Recovered.aimAlignOrientation.MaxTorque = math.huge
    Recovered.aimAlignOrientation.Responsiveness = 200
    Recovered.aimAlignOrientation.RigidityEnabled = false
    Recovered.aimAlignOrientation.Enabled = false
    Recovered.aimAlignOrientation.Parent = root
end

function Recovered.destroyAimController()
    local humanoid = getHumanoid()
    if humanoid then pcall(function() humanoid.AutoRotate = true end) end
    if Recovered.aimAlignOrientation then pcall(function() Recovered.aimAlignOrientation:Destroy() end) end
    if Recovered.aimAttachment then pcall(function() Recovered.aimAttachment:Destroy() end) end
    Recovered.aimAlignOrientation, Recovered.aimAttachment, Recovered.faceTarget = nil, nil, nil
end

Recovered.hitboxTargetParts = {"Head", "Fake Head", "Toilet"}
function Recovered.expandHitboxes()
    local living = Workspace:FindFirstChild("Living")
    local me = getCharacter()
    if not living then return end
    for _, model in ipairs(living:GetChildren()) do
        if model ~= me and model:IsA("Model") then
            local hum = model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                for _, partName in ipairs(Recovered.hitboxTargetParts) do
                    local part = model:FindFirstChild(partName)
                    if part and part:IsA("BasePart") then
                        if not Recovered.hitboxOriginals[part] then
                            Recovered.hitboxOriginals[part] = {
                                Size = part.Size,
                                Transparency = part.Transparency,
                                CanCollide = part.CanCollide,
                                Massless = part.Massless,
                            }
                        end
                        part.Size = Vector3.new(Recovered.hitboxSize, Recovered.hitboxSize, Recovered.hitboxSize)
                        part.Transparency = 0.6
                        part.CanCollide = false
                        part.Massless = true
                    end
                end
            end
        end
    end
end

function Recovered.restoreHitboxes()
    for part, original in pairs(Recovered.hitboxOriginals) do
        pcall(function()
            if part and part.Parent then
                part.Size = original.Size
                part.Transparency = original.Transparency
                part.CanCollide = original.CanCollide
                part.Massless = original.Massless
            end
        end)
        Recovered.hitboxOriginals[part] = nil
    end
end

function Recovered.getESPAdornee(model)
    if not model or not model:IsA("Model") then return nil end
    return model:FindFirstChild("Head") or model:FindFirstChild("Fake Head") or model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

function Recovered.removeESP(model)
    local selection = Recovered.espSelection[model]
    if selection then pcall(function() selection:Destroy() end); Recovered.espSelection[model] = nil end
    local billboard = Recovered.espBillboards[model]
    if billboard then pcall(function() billboard:Destroy() end); Recovered.espBillboards[model] = nil end
end

function Recovered.ensureESP(model, humanoid, adornee)
    if not model or not humanoid or not adornee then return end
    if Recovered.espEnabled then
        local selection = Recovered.espSelection[model]
        if not selection or not selection.Parent then
            selection = Instance.new("SelectionBox")
            selection.Adornee = adornee
            selection.Color3 = Recovered.espColor
            selection.SurfaceTransparency = 0.04
            selection.LineThickness = 0.82
            selection.SurfaceColor3 = Recovered.espColor
            local parented = pcall(function() selection.Parent = CoreGui end)
            if not parented or not selection.Parent then selection.Parent = Workspace end
            Recovered.espSelection[model] = selection
        else
            selection.Adornee = adornee
            selection.Color3 = Recovered.espColor
            selection.SurfaceColor3 = Recovered.espColor
        end

        local billboard = Recovered.espBillboards[model]
        if not billboard or not billboard.Parent then
            billboard = Instance.new("BillboardGui")
            billboard.AlwaysOnTop = true
            billboard.Adornee = adornee
            billboard.Size = UDim2.new(0, 130, 0, 44)
            billboard.StudsOffset = Vector3.new(0, 3.5, 0)
            local nameLabel = Instance.new("TextLabel")
            nameLabel.Name = "NameLabel"
            nameLabel.Size = UDim2.new(1, 0, 0.5, 0)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = model.Name
            nameLabel.TextColor3 = Recovered.espColor
            nameLabel.TextSize = 12
            nameLabel.Font = Enum.Font.Code
            nameLabel.TextStrokeTransparency = 0
            nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
            nameLabel.Parent = billboard
            local hpLabel = Instance.new("TextLabel")
            hpLabel.Name = "HPLabel"
            hpLabel.Size = UDim2.new(1, 0, 0.5, 0)
            hpLabel.Position = UDim2.new(0, 0, 0.5, 0)
            hpLabel.BackgroundTransparency = 1
            hpLabel.TextSize = 11
            hpLabel.Font = Enum.Font.Code
            hpLabel.TextStrokeTransparency = 0
            hpLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
            hpLabel.Parent = billboard
            local parented = pcall(function() billboard.Parent = CoreGui end)
            if not parented or not billboard.Parent then
                pcall(function() billboard.Parent = LP:WaitForChild("PlayerGui") end)
            end
            Recovered.espBillboards[model] = billboard
        else
            billboard.Adornee = adornee
        end
        local nameLabel = billboard:FindFirstChild("NameLabel")
        if nameLabel then nameLabel.Text = model.Name; nameLabel.TextColor3 = Recovered.espColor end
        local hpLabel = billboard:FindFirstChild("HPLabel")
        if hpLabel then
            local percent = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
            hpLabel.Text = "HP: " .. math.floor(humanoid.Health) .. " (" .. math.floor(percent * 100) .. "%)"
            if percent > 0.6 then hpLabel.TextColor3 = Color3.fromRGB(0, 255, 100)
            elseif percent > 0.3 then hpLabel.TextColor3 = Color3.fromRGB(255, 200, 0)
            else hpLabel.TextColor3 = Color3.fromRGB(255, 50, 50) end
        end
    else
        Recovered.removeESP(model)
    end
end

function Recovered.updateESP()
    local living = Workspace:FindFirstChild("Living")
    local seen = {}
    if living then
        for _, model in ipairs(living:GetChildren()) do
            if model:IsA("Model") and model ~= getCharacter() then
                local humanoid = model:FindFirstChildOfClass("Humanoid")
                local adornee = Recovered.getESPAdornee(model)
                if humanoid and humanoid.Health > 0 and adornee then
                    seen[model] = true
                    Recovered.ensureESP(model, humanoid, adornee)
                end
            end
        end
    end
    for model in pairs(Recovered.espSelection) do if not seen[model] then Recovered.removeESP(model) end end
    for model in pairs(Recovered.espBillboards) do if not seen[model] then Recovered.removeESP(model) end end
end

function Recovered.removeTracer(model)
    local info = Recovered.espTracers[model]
    if not info then return end
    for _, obj in pairs(info) do if typeof(obj) == "Instance" then pcall(function() obj:Destroy() end) end end
    Recovered.espTracers[model] = nil
end

function Recovered.updateESPTracers()
    local character = getCharacter()
    local localRoot = character and character:FindFirstChild("HumanoidRootPart")
    local living = Workspace:FindFirstChild("Living")
    local seen = {}
    if living and localRoot then
        for _, model in ipairs(living:GetChildren()) do
            if model:IsA("Model") and model ~= character then
                local humanoid = model:FindFirstChildOfClass("Humanoid")
                local targetRoot = model:FindFirstChild("HumanoidRootPart")
                if humanoid and humanoid.Health > 0 and targetRoot then
                    seen[model] = true
                    local info = Recovered.espTracers[model]
                    if not info or not info.beam or not info.beam.Parent then
                        local attA = Instance.new("Attachment")
                        attA.Name = "ESPLine_A"
                        attA.Parent = localRoot
                        local attB = Instance.new("Attachment")
                        attB.Name = "ESPLine_B"
                        attB.Parent = targetRoot
                        local beam = Instance.new("Beam")
                        beam.Attachment0 = attA
                        beam.Attachment1 = attB
                        beam.Color = ColorSequence.new(Recovered.espLineColor)
                        beam.LightEmission = 0.08
                        beam.LightInfluence = 0.08
                        beam.FaceCamera = true
                        beam.Width0 = 1
                        beam.Width1 = 1
                        beam.Transparency = NumberSequence.new(0)
                        beam.Parent = localRoot
                        Recovered.espTracers[model] = {beam = beam, attA = attA, attB = attB}
                    else
                        info.attA.Parent = localRoot
                        info.attB.Parent = targetRoot
                        info.beam.Color = ColorSequence.new(Recovered.espLineColor)
                    end
                end
            end
        end
    end
    for model in pairs(Recovered.espTracers) do if not seen[model] then Recovered.removeTracer(model) end end
end

function Recovered.applyAntiLag(enabled)
    if enabled then
        pcall(function()
            for _, obj in ipairs(Workspace:GetDescendants()) do
                if obj:IsA("BasePart") then
                    if not Recovered.antiLagOriginals[obj] then Recovered.antiLagOriginals[obj] = {Material = obj.Material} end
                    obj.Material = Enum.Material.SmoothPlastic
                elseif obj:IsA("Decal") or obj:IsA("Texture") then
                    if not Recovered.antiLagOriginals[obj] then Recovered.antiLagOriginals[obj] = {Transparency = obj.Transparency} end
                    obj.Transparency = 1
                end
            end
        end)
    else
        for obj, original in pairs(Recovered.antiLagOriginals) do
            pcall(function()
                if obj and obj.Parent then
                    if original.Material ~= nil then obj.Material = original.Material end
                    if original.Transparency ~= nil then obj.Transparency = original.Transparency end
                end
            end)
            Recovered.antiLagOriginals[obj] = nil
        end
    end
end

function Recovered.setFullbright(enabled)
    if enabled then
        if not Recovered.fullbrightOriginal then
            Recovered.fullbrightOriginal = {
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                FogEnd = Lighting.FogEnd,
                GlobalShadows = Lighting.GlobalShadows,
            }
        end
        pcall(function()
            Lighting.Ambient = Color3.new(1, 1, 1)
            Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
            Lighting.Brightness = 2
            Lighting.ClockTime = 14
            Lighting.FogEnd = 100000
            Lighting.GlobalShadows = false
        end)
    else
        if Recovered.fullbrightOriginal then
            local o = Recovered.fullbrightOriginal
            pcall(function() Lighting.Ambient = o.Ambient end)
            pcall(function() Lighting.OutdoorAmbient = o.OutdoorAmbient end)
            pcall(function() Lighting.Brightness = o.Brightness end)
            pcall(function() Lighting.ClockTime = o.ClockTime end)
            pcall(function() Lighting.FogEnd = o.FogEnd end)
            pcall(function() Lighting.GlobalShadows = o.GlobalShadows end)
            Recovered.fullbrightOriginal = nil
        end
    end
end

-- 已恢复的维护循环：不会碰未选择的 ST 独有功能。
task.spawn(function()
    while task.wait(0.15) do
        if Recovered.hitboxEnabled then Recovered.expandHitboxes() else Recovered.restoreHitboxes() end
        if Recovered.espEnabled then Recovered.updateESP() else for model in pairs(Recovered.espSelection) do Recovered.removeESP(model) end; for model in pairs(Recovered.espBillboards) do Recovered.removeESP(model) end end
        if Recovered.espLinesEnabled then Recovered.updateESPTracers() else for model in pairs(Recovered.espTracers) do Recovered.removeTracer(model) end end
        if Recovered.antiLagEnabled then Recovered.applyAntiLag(true) end
        if Recovered.fullbrightEnabled then Recovered.setFullbright(true) end
        if Recovered.antiJeffreyEnabled then
            pcall(function()
                local jeffrey = Workspace:FindFirstChild("Jeffrey")
                local notHumanoid = jeffrey and jeffrey:FindFirstChild("NotHumanoid")
                if notHumanoid then notHumanoid.Sit = true end
            end)
        end
    end
end)

RunService.Heartbeat:Connect(function()
    local humanoid, root, camera = getHumanoid(), getHRP(), Workspace.CurrentCamera
    if humanoid then
        if Recovered.walkSpeedEnabled then humanoid.WalkSpeed = Recovered.walkSpeedValue end
        if Recovered.jumpPowerEnabled then humanoid.UseJumpPower = true; humanoid.JumpPower = Recovered.jumpPowerValue end
    end
    if Recovered.fovEnabled and camera then camera.FieldOfView = Recovered.fovValue end
    if Recovered.maxZoomEnabled then LP.CameraMaxZoomDistance = Recovered.maxZoomValue end
end)

LP.CharacterAdded:Connect(function()
    task.wait(1)
    Recovered.destroyAimController()
    if Recovered.faceNearestEnabled or autoAttackEnabled then Recovered.createAimController() end
    if Recovered.walkSpeedEnabled and getHumanoid() then getHumanoid().WalkSpeed = Recovered.walkSpeedValue end
    if Recovered.jumpPowerEnabled and getHumanoid() then getHumanoid().UseJumpPower = true; getHumanoid().JumpPower = Recovered.jumpPowerValue end
    if Recovered.fullbrightEnabled then Recovered.setFullbright(true) end
    if Recovered.antiLagEnabled then Recovered.applyAntiLag(true) end
end)

-- ==================== 武器 ====================
local WEAPON_MAP = {
    ["天文冲击枪"] = "Astro Blaster",
    ["鱼叉枪"] = "Harpoon Gun",
    ["射击鱼叉枪"] = "Shot Harpoon Gun",
    ["霰弹枪"] = "Shot Gun",
    ["脉冲步枪"] = "Pulse Rifle",
    ["EPD"] = "EPD",
    ["小型激光枪"] = "Small Laser Gun",
    ["电击狙击枪"] = "Tazer Sniper",
    ["电击枪"] = "Tazer Gun",
}
local WEAPON_OPTIONS = { "天文冲击枪", "鱼叉枪", "射击鱼叉枪", "霰弹枪", "脉冲步枪", "EPD", "小型激光枪", "电击狙击枪", "电击枪" }
local weaponWhitelist = {}
for _, en in pairs(WEAPON_MAP) do weaponWhitelist[en] = true end

local function isWhitelistedWeapon(tool)
    if not tool or not tool:IsA("Tool") then return false end
    if weaponWhitelist[tool.Name] then return true end
    for en in pairs(weaponWhitelist) do
        if tool.Name:find(en, 1, true) then return true end
    end
    return false
end

local function findGunTool()
    local char = getCharacter()
    if char then
        local held = char:FindFirstChildWhichIsA("Tool")
        if held and isWhitelistedWeapon(held) then return held, true end
    end
    local bp = LP:FindFirstChild("Backpack")
    if bp then
        local astro = bp:FindFirstChild("Astro Blaster")
        if astro and isWhitelistedWeapon(astro) then return astro, false end
        for _, tool in ipairs(bp:GetChildren()) do
            if tool:IsA("Tool") and isWhitelistedWeapon(tool) then return tool, false end
        end
    end
    return nil, false
end

local function hasUsableGun()
    local tool, held = findGunTool()
    if tool then return true, tool, held end
    return false, nil, false
end

local function equipTool(tool)
    if not tool or not tool.Parent then return false end
    local char = getCharacter()
    local hum = getHumanoid()
    if not char or not hum then return false end
    if tool.Parent == char then return true end
    local ok = pcall(function() hum:EquipTool(tool) end)
    return ok and tool.Parent == char
end

-- ==================== 其他状态 ====================
local cachedPlayerNamesLower = {}
local function refreshPlayerNameCache()
    cachedPlayerNamesLower = {}
    for _, p in ipairs(Players:GetPlayers()) do
        pcall(function()
            cachedPlayerNamesLower[p.Name:lower()] = true
            cachedPlayerNamesLower[p.DisplayName:lower()] = true
        end)
    end
end
pcall(function() Players.PlayerAdded:Connect(refreshPlayerNameCache) end)
pcall(function() Players.PlayerRemoving:Connect(refreshPlayerNameCache) end)
pcall(refreshPlayerNameCache)

local function nameContainsCachedPlayer(nameLower)
    for cachedName in pairs(cachedPlayerNamesLower) do
        if cachedName ~= "" then
            local s, e = nameLower:find(cachedName, 1, true)
            if s then
                local beforeOK = s == 1 or not nameLower:sub(s - 1, s - 1):match("[%w_]")
                local afterOK = e == #nameLower or not nameLower:sub(e + 1, e + 1):match("[%w_]")
                if beforeOK and afterOK then return true end
            end
        end
    end
    return false
end

-- ==================== 目标识别 ====================
local function isNPC(m)
    return m and m:IsA("Model") and m:FindFirstChildWhichIsA("Humanoid") ~= nil
end

local function readBoolValue(model, names)
    for _, name in ipairs(names) do
        local v = model:FindFirstChild(name)
        if v and v:IsA("BoolValue") then return v.Value end
    end
    return nil
end

local function isOwnedByPlayer(model)
    local creatorVal = model:FindFirstChild("Owner") or model:FindFirstChild("Creator") or model:FindFirstChild("Player") or model:FindFirstChild("Master")
    if not creatorVal then return false end
    if creatorVal:IsA("ObjectValue") and creatorVal.Value then
        if creatorVal.Value:IsA("Player") then return true end
        if Players:GetPlayerFromCharacter(creatorVal.Value) then return true end
    end
    return false
end

local blacklistEnemyNames = {
    "speaker pulse tank", "camera pulse tank", "pulse tank",
}

local function isEnemy(model)
    if not model or not model:IsA("Model") then return false end
    if model == LP.Character then return false end
    if Players:GetPlayerFromCharacter(model) then return false end
    if isOwnedByPlayer(model) then return false end

    local explicitEnemy = readBoolValue(model, { "IsEnemy", "Enemy", "Hostile" })
    if explicitEnemy == true then return true end
    if explicitEnemy == false then return false end

    local attrEnemy = model:GetAttribute("IsEnemy")
    if attrEnemy == true then return true end
    if attrEnemy == false then return false end

    local nameLower = model.Name:lower()
    for _, n in ipairs(blacklistEnemyNames) do
        if nameLower:find(n, 1, true) then return false end
    end

    if nameContainsCachedPlayer(nameLower) then return false end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end

    -- STBB 的 Living 容器本身就是最可靠的敌人范围标记。
    -- 在 Living 中即使模型名称以后换了，也不要因为关键字不匹配而漏怪。
    local living = Workspace:FindFirstChild("Living", true)
    if living then
        local okDesc = pcall(function() return model:IsDescendantOf(living) end)
        if okDesc and model:IsDescendantOf(living) then
            return true
        end
    end

    local keywords = {
        "zombie", "toilet", "titan", "camera", "speaker", "astro",
        "drill", "plunger", "infected", "scientist", "g-man", "clock",
    }
    for _, kw in ipairs(keywords) do
        if nameLower:find(kw, 1, true) then return true end
    end
    return false
end

local lastEnemySearch, ENEMY_SEARCH_INTERVAL = 0, 0.15
local function getClosestEnemyThrottled()
    if tick() - lastEnemySearch < ENEMY_SEARCH_INTERVAL and cachedEnemy and cachedEnemy.Parent then
        local h = cachedEnemy:FindFirstChildOfClass("Humanoid")
        if h and h.Health > 0 and isEnemy(cachedEnemy) then return cachedEnemy end
    end

    lastEnemySearch = tick()
    local myChar = getCharacter()
    local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myHrp then cachedEnemy = nil return nil end

    local searchFolder = Workspace:FindFirstChild("Living") or Workspace
    local closest, minDist = nil, math.huge
    local seenModels = {}

    local function consider(model)
        if not model or seenModels[model] then return end
        seenModels[model] = true
        if not isEnemy(model) then return end
        local hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head") or model.PrimaryPart
        if hrp and hrp:IsA("BasePart") then
            local dist = (myHrp.Position - hrp.Position).Magnitude
            if dist < minDist then
                minDist = dist
                closest = model
            end
        end
    end

    for _, model in ipairs(searchFolder:GetChildren()) do
        if model:IsA("Model") then consider(model) end
    end
    -- 部分新版敌人套在事件/波次 Model 里；只扫 Model，避免被零件数量拖垮。
    for _, obj in ipairs(searchFolder:GetDescendants()) do
        if obj:IsA("Model") then consider(obj) end
    end
    cachedEnemy = closest
    return closest
end

-- ==================== Tab1 主要功能 ====================
local speedVal, speedEnabled, speedConn = 0, false, nil
Tab1:CreateToggle({
    Name = "CFrame移速", CurrentValue = false, Flag = "SpeedToggle", Ext = true,
    Callback = function(v)
        speedEnabled = v
        if v then
            if not speedConn then
                speedConn = RS.Stepped:Connect(function()
                    if not speedEnabled or hardMovementBlocked() or autoAttackEnabled or autoFireGunEnabled or autoTraceMaterialEnabled then return end
                    local c = getCharacter()
                    local h = c and c:FindFirstChild("HumanoidRootPart")
                    local hum = c and c:FindFirstChildWhichIsA("Humanoid")
                    if h and hum and speedVal > 0 then
                        local d = hum.MoveDirection
                        if d.Magnitude > 0 then
                            pcall(function() h.CFrame = h.CFrame + d * speedVal end)
                        end
                    end
                end)
            end
            notify("功能提示", "已开启CFrame移速")
        else
            if speedConn then speedConn:Disconnect(); speedConn = nil end
            notify("功能提示", "已关闭CFrame移速")
        end
    end,
})
Tab1:CreateSlider({ Name = "移速数值", Range = { 0, 20 }, Increment = 1, CurrentValue = 0, Flag = "SpeedValue", Callback = function(v) speedVal = v end })

Tab1:CreateToggle({
    Name = "背包界面", CurrentValue = false, Flag = "InventoryToggle", Ext = true,
    Callback = function(v)
        local pg = LP:FindFirstChild("PlayerGui")
        local inv = findGuiByNames(pg, { "Inventory", "InventoryUI", "InventoryGui", "InventoryFrame" })
        if inv then
            setGuiOpen(inv, v)
        else
            notify("背包", "当前没找到背包界面对象", 3)
        end
    end,
})

-- 山本特效：只删除客户端可见对象/对话 UI，不再删除 ReplicatedStorage Remote，也不再销毁全部动画。
local dsRunning, dsJob, dsConn = false, nil, nil
local visualEffectNames = {
    CameraAwaken = true, CameraAwakenV2 = true, CameraAwakenHeadCap = true,
    Kaijin = true, Kakajumon = true, TekrinnDialogueRemote = true,
}

local function clearDialogueUI()
    for _, root in ipairs({ LP:FindFirstChild("PlayerGui"), CoreGui }) do
        if root then
            for _, g in ipairs(root:GetDescendants()) do
                if g:IsA("ScreenGui") then
                    local n = g.Name:lower()
                    if n:find("dialogue", 1, true) or n:find("dialog", 1, true) then
                        pcall(function() g:Destroy() end)
                    end
                end
            end
        end
    end
end

local function deleteVisualEffectsOnly()
    for _, root in ipairs({ Workspace, LP:FindFirstChild("PlayerGui"), CoreGui }) do
        if root then
            for _, obj in ipairs(root:GetDescendants()) do
                if visualEffectNames[obj.Name] and not obj:IsDescendantOf(RepStorage) then
                    pcall(function() obj:Destroy() end)
                end
            end
        end
    end
    clearDialogueUI()
end

Tab1:CreateToggle({
    Name = "删除山本特效", CurrentValue = false, Flag = "DeleteShanbenToggle", Ext = true,
    Callback = function(v)
        dsRunning = v
        if v then
            deleteVisualEffectsOnly()
            if dsConn then dsConn:Disconnect(); dsConn = nil end
            dsConn = Workspace.DescendantAdded:Connect(function(obj)
                if dsRunning and visualEffectNames[obj.Name] then
                    task.defer(function()
                        if dsRunning and obj.Parent and not obj:IsDescendantOf(RepStorage) then
                            pcall(function() obj:Destroy() end)
                        end
                    end)
                end
            end)
            if not dsJob then
                dsJob = task.spawn(function()
                    while dsRunning do
                        task.wait(1)
                        if dsRunning then deleteVisualEffectsOnly() end
                    end
                    dsJob = nil
                end)
            end
            notify("功能提示", "已开启删除山本特效（仅处理客户端可见对象）")
        else
            if dsConn then dsConn:Disconnect(); dsConn = nil end
            if dsJob then task.cancel(dsJob); dsJob = nil end
            notify("功能提示", "已关闭删除山本特效")
        end
    end,
})

-- 锁定视角
local lockCameraConnection
Tab1:CreateToggle({
    Name = "锁定视角", CurrentValue = false, Flag = "LockCameraToggle", Ext = true,
    Callback = function(v)
        lockCameraEnabled = v
        if v then
            if not lockCameraConnection then
                lockCameraConnection = RS.Heartbeat:Connect(function()
                    if not lockCameraEnabled or hardMovementBlocked() or autoAttackEnabled or autoFireGunEnabled or autoTraceMaterialEnabled then return end
                    local c = getCharacter()
                    local h = c and c:FindFirstChild("HumanoidRootPart")
                    local cam = Workspace.CurrentCamera
                    if not h or not cam then return end
                    local lv = cam.CFrame.LookVector
                    local flat = Vector3.new(lv.X, 0, lv.Z)
                    if flat.Magnitude > 0.01 then
                        pcall(function() h.CFrame = CFrame.lookAt(h.Position, h.Position + flat.Unit) end)
                    end
                end)
            end
            notify("功能提示", "已开启锁定视角")
        else
            if lockCameraConnection then lockCameraConnection:Disconnect(); lockCameraConnection = nil end
            notify("功能提示", "已关闭锁定视角")
        end
    end,
})

-- 远距离跟随
local fConn
Tab1:CreateToggle({
    Name = "zuts远距离跟随", CurrentValue = false, Flag = "MonsterFollowToggle", Ext = true,
    Callback = function(v)
        if v then
            if not fConn then
                fConn = RS.Heartbeat:Connect(function()
                    if hardMovementBlocked() or autoAttackEnabled or autoFireGunEnabled or autoTraceMaterialEnabled then return end
                    local c = getCharacter()
                    local h = c and c:FindFirstChild("HumanoidRootPart")
                    local living = Workspace:FindFirstChild("Living", true)
                    local t = living and living:FindFirstChild("Zombie Upgraded Titan Speaker V2", true)
                    local th = t and t:FindFirstChild("HumanoidRootPart")
                    if h and th then
                        pcall(function() h.CFrame = CFrame.new(th.Position + Vector3.new(90, 15, -130), th.Position) end)
                    end
                end)
            end
            notify("功能提示", "已开启zuts远距离跟随")
        else
            if fConn then fConn:Disconnect(); fConn = nil end
            notify("功能提示", "已关闭zuts远距离跟随")
        end
    end,
})

-- 删除导弹效果
local missileRunning, missileJob = false, nil
Tab1:CreateToggle({
    Name = "删除导弹特效", CurrentValue = false, Flag = "DeleteMissileToggle", Ext = true,
    Callback = function(v)
        missileRunning = v
        if v then
            if not missileJob then
                missileJob = task.spawn(function()
                    while missileRunning do
                        local ef = Workspace:FindFirstChild("Effects", true)
                        if ef then
                            for _, x in ipairs(ef:GetDescendants()) do
                                if x.Name == "MissileBOOM" then pcall(function() x:Destroy() end) end
                            end
                        end
                        task.wait(0.2)
                    end
                    missileJob = nil
                end)
            end
            notify("功能提示", "已开启删除导弹特效")
        else
            if missileJob then task.cancel(missileJob); missileJob = nil end
            notify("功能提示", "已关闭删除导弹特效")
        end
    end,
})

-- 自动重生
local autoRebirthEnabled, autoRebirthJob = false, nil
local autoRebirthDiedConn
local function hookAutoRebirthCharacter(c)
    if autoRebirthDiedConn then autoRebirthDiedConn:Disconnect(); autoRebirthDiedConn = nil end
    if not autoRebirthEnabled or not c then return end
    local h = c:FindFirstChildOfClass("Humanoid") or c:WaitForChild("Humanoid", 3)
    if not h then return end
    autoRebirthDiedConn = h.Died:Connect(function()
        if not autoRebirthEnabled then return end
        task.wait(0.45)
        pcall(function() fireRemote("GetReadyRemote", "1", true) end)
    end)
end
Tab1:CreateToggle({
    Name = "自动重生", CurrentValue = false, Flag = "AutoRebirthToggle", Ext = true,
    Callback = function(v)
        autoRebirthEnabled = v
        if v then
            hookAutoRebirthCharacter(getCharacter())
            if not autoRebirthJob then
                autoRebirthJob = task.spawn(function()
                    while autoRebirthEnabled do
                        local c = getCharacter()
                        local h = c and c:FindFirstChildOfClass("Humanoid")
                        if c and h and h.Health > 0 and h.Health < 10 then
                            pcall(function() h.Health = 0 end)
                        end
                        task.wait(0.75)
                    end
                    autoRebirthJob = nil
                end)
            end
            notify("功能提示", "已开启自动重生")
        else
            if autoRebirthJob then task.cancel(autoRebirthJob); autoRebirthJob = nil end
            if autoRebirthDiedConn then autoRebirthDiedConn:Disconnect(); autoRebirthDiedConn = nil end
            notify("功能提示", "已关闭自动重生")
        end
    end,
})

-- 显示所有角色名称
local nameDisplayEnabled, nameDisplayGuis, nameDisplayConn, nameDisplayLoop = false, {}, nil, nil
local function getDisplayName(model)
    local plr = Players:GetPlayerFromCharacter(model)
    if plr then return plr.DisplayName .. " (@" .. plr.Name .. ")" end
    return model.Name
end

local function addNameTag(model)
    if not model or not model:IsA("Model") or nameDisplayGuis[model] then return end
    local head = model:FindFirstChild("Head")
    local hrp = model:FindFirstChild("HumanoidRootPart")
    local targetPart = head or hrp
    if not targetPart or targetPart:FindFirstChild("NameDisplayTag") then return end

    local bill = Instance.new("BillboardGui")
    bill.Name = "NameDisplayTag"
    bill.Adornee = targetPart
    bill.Size = UDim2.new(0, 200, 0, 25)
    bill.StudsOffset = Vector3.new(0, 2.5, 0)
    bill.AlwaysOnTop = true
    bill.MaxDistance = 10000
    bill.Parent = targetPart

    local txt = Instance.new("TextLabel")
    txt.Size = UDim2.new(1, 0, 1, 0)
    txt.BackgroundTransparency = 1
    txt.Text = getDisplayName(model)
    txt.TextColor3 = Color3.fromRGB(255, 255, 255)
    txt.TextSize = 13
    txt.Font = Enum.Font.SourceSansBold
    txt.TextStrokeTransparency = 0
    txt.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    txt.TextXAlignment = Enum.TextXAlignment.Center
    txt.Parent = bill
    nameDisplayGuis[model] = bill
end

local function clearAllNameTags()
    for _, gui in pairs(nameDisplayGuis) do pcall(function() gui:Destroy() end) end
    nameDisplayGuis = {}
end

local function scanAllCharacters()
    if not nameDisplayEnabled then return end
    local function scan(root)
        if not root then return end
        for _, obj in ipairs(root:GetDescendants()) do
            if obj:IsA("Model") and obj:FindFirstChildWhichIsA("Humanoid") then addNameTag(obj) end
        end
    end
    scan(Workspace)
    scan(Workspace:FindFirstChild("Living"))
end

Tab1:CreateToggle({
    Name = "显示所有角色名称", CurrentValue = false, Flag = "NameDisplayToggle", Ext = true,
    Callback = function(v)
        nameDisplayEnabled = v
        if v then
            scanAllCharacters()
            if nameDisplayConn then nameDisplayConn:Disconnect() end
            nameDisplayConn = Workspace.DescendantAdded:Connect(function(obj)
                if not nameDisplayEnabled then return end
                task.defer(function()
                    if obj.Parent and obj:IsA("Model") and obj:FindFirstChildWhichIsA("Humanoid") then
                        addNameTag(obj)
                    end
                end)
            end)
            if nameDisplayLoop then task.cancel(nameDisplayLoop) end
            nameDisplayLoop = task.spawn(function()
                while nameDisplayEnabled do
                    task.wait(2)
                    scanAllCharacters()
                end
                nameDisplayLoop = nil
            end)
            notify("功能提示", "已开启显示角色名称")
        else
            if nameDisplayConn then nameDisplayConn:Disconnect(); nameDisplayConn = nil end
            if nameDisplayLoop then task.cancel(nameDisplayLoop); nameDisplayLoop = nil end
            clearAllNameTags()
            notify("功能提示", "已关闭显示角色名称")
        end
    end,
})

-- 抽奖统计
local gachaStatScreenGui, gachaStatTextLabel, gachaStatConnection
local gachaStatTotal = { Common = 0, Epic = 0, Legendary = 0, Mythic = 0 }
local function setupGachaStatDisplay()
    if gachaStatConnection then return true end
    local remote = findRemote("GachaCharacter", 5)
    if not remote or not remote:IsA("RemoteEvent") then
        notify("抽奖", "找不到 GachaCharacter RemoteEvent")
        return false
    end
    gachaStatScreenGui = Instance.new("ScreenGui")
    gachaStatScreenGui.Name = "ST_GachaStatUI"
    gachaStatScreenGui.ResetOnSpawn = false
    gachaStatScreenGui.Parent = getUiParent()

    gachaStatTextLabel = Instance.new("TextLabel")
    gachaStatTextLabel.Size = UDim2.new(0.5, 0, 0.08, 0)
    gachaStatTextLabel.Position = UDim2.new(0.25, 0, 0.03, 0)
    gachaStatTextLabel.BackgroundTransparency = 1
    gachaStatTextLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    gachaStatTextLabel.TextScaled = true
    gachaStatTextLabel.Font = Enum.Font.GothamBold
    gachaStatTextLabel.Text = "普通:0 史诗:0 传说:0 神话:0"
    gachaStatTextLabel.Parent = gachaStatScreenGui

    gachaStatConnection = remote.OnClientEvent:Connect(function(data)
        if type(data) ~= "table" or #data == 0 then return end
        local counts = {}
        for _, item in ipairs(data) do
            if type(item) == "table" then
                local rarity = tostring(item[2] or "")
                counts[rarity] = (counts[rarity] or 0) + 1
            end
        end
        gachaStatTotal.Common = gachaStatTotal.Common + (counts.Common or 0)
        gachaStatTotal.Epic = gachaStatTotal.Epic + (counts.Epic or 0)
        gachaStatTotal.Legendary = gachaStatTotal.Legendary + (counts.Legendary or 0)
        gachaStatTotal.Mythic = gachaStatTotal.Mythic + (counts.Mythic or 0)
        if gachaStatTextLabel then
            gachaStatTextLabel.Text = string.format("普通:%d 史诗:%d 传说:%d 神话:%d", gachaStatTotal.Common, gachaStatTotal.Epic, gachaStatTotal.Legendary, gachaStatTotal.Mythic)
        end
    end)
    return true
end

local function cleanupGachaStatDisplay()
    if gachaStatConnection then gachaStatConnection:Disconnect(); gachaStatConnection = nil end
    if gachaStatScreenGui then gachaStatScreenGui:Destroy(); gachaStatScreenGui = nil end
    gachaStatTextLabel = nil
    gachaStatTotal = { Common = 0, Epic = 0, Legendary = 0, Mythic = 0 }
end

Tab1:CreateButton({ Name = "抽奖统计", Ext = true, Callback = function()
    if gachaStatScreenGui then
        cleanupGachaStatDisplay()
        notify("抽奖统计", "已关闭")
    else
        if setupGachaStatDisplay() then notify("抽奖统计", "已开启") end
    end
end })

-- ==================== PolyHub 恢复目标辅助 ====================
Tab1:CreateSection("PolyHub 恢复目标辅助")
Tab1:CreateToggle({ Name = "敌人 ESP", CurrentValue = false, Flag = "RecoveredESP", Ext = true, Callback = function(v) Recovered.espEnabled = v end })
Tab1:CreateToggle({ Name = "ESP Tracers", CurrentValue = false, Flag = "RecoveredESPTracers", Ext = true, Callback = function(v) Recovered.espLinesEnabled = v end })
Tab1:CreateToggle({ Name = "扩大敌人碰撞箱", CurrentValue = false, Flag = "RecoveredHitbox", Ext = true, Callback = function(v)
    Recovered.hitboxEnabled = v
    if not v then Recovered.restoreHitboxes() end
end })
Tab1:CreateSlider({ Name = "碰撞箱大小", Range = { 2, 20 }, Increment = 1, CurrentValue = 5, Flag = "RecoveredHitboxSize", Callback = function(v) Recovered.hitboxSize = v end })

-- ==================== Tab2 其它 ====================
-- PolyHub 恢复版飞行：BodyVelocity + BodyGyro；保留 ST 手机端上/下按钮，仅作为输入层。
local flyEnabled, flyConn, flySpeed = false, nil, 50
local flyGui, flyUp, flyDown = nil, false, false

local function destroyFlyControls()
    flyUp, flyDown = false, false
    if flyGui then pcall(function() flyGui:Destroy() end); flyGui = nil end
end

local function createFlyControls()
    if not UIS or not UIS.TouchEnabled or flyGui then return end
    local pg = getUiParent()
    if not pg then return end
    local gui = Instance.new("ScreenGui")
    gui.Name = "ST_FlyControls"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.Parent = pg
    flyGui = gui
    local function makeButton(text, pos)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(85, 55)
        b.Position = pos
        b.BackgroundTransparency = 0.25
        b.Text = text
        b.TextSize = 22
        b.Font = Enum.Font.GothamBold
        b.TextColor3 = Color3.new(1,1,1)
        b.Parent = gui
        return b
    end
    local up = makeButton("↑", UDim2.new(1, -190, 1, -180))
    local down = makeButton("↓", UDim2.new(1, -190, 1, -115))
    up.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then flyUp = true end
    end)
    up.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then flyUp = false end
    end)
    down.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then flyDown = true end
    end)
    down.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then flyDown = false end
    end)
end

function Recovered.enableFlight()
    local root = getHRP()
    if not root then return false end
    if Recovered.flyVelocity then pcall(function() Recovered.flyVelocity:Destroy() end) end
    if Recovered.flyGyro then pcall(function() Recovered.flyGyro:Destroy() end) end
    Recovered.flyVelocity = Instance.new("BodyVelocity")
    Recovered.flyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
    Recovered.flyVelocity.Velocity = Vector3.new(0, 0, 0)
    Recovered.flyVelocity.Parent = root
    Recovered.flyGyro = Instance.new("BodyGyro")
    Recovered.flyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
    Recovered.flyGyro.P = 100
    Recovered.flyGyro.D = 10000
    Recovered.flyGyro.CFrame = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame or root.CFrame
    Recovered.flyGyro.Parent = root
    return true
end

function Recovered.disableFlight()
    if Recovered.flyVelocity then pcall(function() Recovered.flyVelocity:Destroy() end); Recovered.flyVelocity = nil end
    if Recovered.flyGyro then pcall(function() Recovered.flyGyro:Destroy() end); Recovered.flyGyro = nil end
end

local function stopFly()
    flyEnabled = false
    if flyConn then flyConn:Disconnect(); flyConn = nil end
    Recovered.disableFlight()
    destroyFlyControls()
end

local function startFly()
    if flyConn then return end
    if not Recovered.enableFlight() then return end
    flyEnabled = true
    createFlyControls()
    flyConn = RS.Heartbeat:Connect(function()
        if not flyEnabled or hardMovementBlocked() or autoAttackEnabled or autoFireGunEnabled or autoTraceMaterialEnabled then return end
        local root = getHRP()
        local hum = getHumanoid()
        local cam = Workspace.CurrentCamera
        if not root or not hum or not cam or not Recovered.flyVelocity or not Recovered.flyGyro then return end
        local move = hum.MoveDirection
        if UIS:IsKeyDown(Enum.KeyCode.W) then move = move + cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then move = move - cam.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then move = move - cam.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then move = move + cam.CFrame.RightVector end
        local vertical = 0
        if UIS:IsKeyDown(Enum.KeyCode.Space) or flyUp then vertical = vertical + 1 end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) or flyDown then vertical = vertical - 1 end
        move = Vector3.new(move.X, vertical + move.Y, move.Z)
        if move.Magnitude > 0.05 then move = move.Unit else move = Vector3.zero end
        Recovered.flyVelocity.Velocity = move * flySpeed
        Recovered.flyGyro.CFrame = cam.CFrame
    end)
end

Tab2:CreateButton({ Name = "飞行", Ext = true, Callback = function()
    if flyEnabled then
        stopFly()
        notify("功能提示", "已关闭飞行")
    else
        if startFly() then notify("功能提示", "已开启飞行（恢复版）") else notify("功能提示", "未找到角色根部件") end
    end
end })

-- 画质：保存原值再恢复，不再硬编码恢复值。
local graphicsOriginal = nil
local function captureGraphics()
    if graphicsOriginal then return end
    graphicsOriginal = {
        GlobalShadows = Lighting.GlobalShadows,
        ShadowSoftness = Lighting.ShadowSoftness,
        Brightness = Lighting.Brightness,
        Ambient = Lighting.Ambient,
        QualityLevel = nil,
        Post = {},
        Terrain = {},
    }
    pcall(function() graphicsOriginal.QualityLevel = settings().Rendering.QualityLevel end)
    for _, name in ipairs({ "Bloom", "Blur", "SunRays", "ColorCorrection", "DepthOfField" }) do
        local fx = Lighting:FindFirstChild(name)
        if fx then graphicsOriginal.Post[name] = fx.Enabled end
    end
    local t = Workspace.Terrain
    if t then
        graphicsOriginal.Terrain = {
            WaterWaveSize = t.WaterWaveSize,
            WaterWaveSpeed = t.WaterWaveSpeed,
            WaterReflectance = t.WaterReflectance,
            WaterTransparency = t.WaterTransparency,
        }
    end
end

local function restoreGraphics()
    if not graphicsOriginal then return end
    pcall(function() Lighting.GlobalShadows = graphicsOriginal.GlobalShadows end)
    pcall(function() Lighting.ShadowSoftness = graphicsOriginal.ShadowSoftness end)
    pcall(function() Lighting.Brightness = graphicsOriginal.Brightness end)
    pcall(function() Lighting.Ambient = graphicsOriginal.Ambient end)
    for name, enabled in pairs(graphicsOriginal.Post) do
        local fx = Lighting:FindFirstChild(name)
        if fx then pcall(function() fx.Enabled = enabled end) end
    end
    if graphicsOriginal.Terrain then
        local t = Workspace.Terrain
        if t then
            for k, v in pairs(graphicsOriginal.Terrain) do pcall(function() t[k] = v end) end
        end
    end
    pcall(function()
        if graphicsOriginal.QualityLevel then settings().Rendering.QualityLevel = graphicsOriginal.QualityLevel end
    end)
end

Tab2:CreateToggle({ Name = "画质简化", CurrentValue = false, Flag = "GraphicsSimplifiedToggle", Ext = true, Callback = function(v)
    if v then
        captureGraphics()
        pcall(function()
            Lighting.GlobalShadows = false
            Lighting.ShadowSoftness = 0
            Lighting.Brightness = 2
        end)
        for _, name in ipairs({ "Bloom", "Blur", "SunRays", "ColorCorrection", "DepthOfField" }) do
            local fx = Lighting:FindFirstChild(name)
            if fx then pcall(function() fx.Enabled = false end) end
        end
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
        pcall(function()
            local t = Workspace.Terrain
            t.WaterWaveSize = 0
            t.WaterWaveSpeed = 0
            t.WaterReflectance = 0
        end)
        notify("功能提示", "已开启画质简化")
    else
        restoreGraphics()
        notify("功能提示", "已关闭画质简化")
    end
end })

-- 快速互动：记录每个 Prompt 原始 HoldDuration，关闭时恢复。
local quickInteractEnabled, quickInteractConn = false, nil
local quickInteractOriginal = setmetatable({}, { __mode = "k" })
local function setPromptInstant(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return end
    if quickInteractOriginal[prompt] == nil then quickInteractOriginal[prompt] = prompt.HoldDuration end
    pcall(function() prompt.HoldDuration = 0 end)
end
Tab2:CreateToggle({ Name = "快速互动", CurrentValue = false, Flag = "QuickInteractToggle", Ext = true, Callback = function(v)
    quickInteractEnabled = v
    if v then
        for _, p in ipairs(Workspace:GetDescendants()) do if p:IsA("ProximityPrompt") then setPromptInstant(p) end end
        if quickInteractConn then quickInteractConn:Disconnect() end
        quickInteractConn = Workspace.DescendantAdded:Connect(function(obj)
            if quickInteractEnabled and obj:IsA("ProximityPrompt") then setPromptInstant(obj) end
        end)
        notify("功能提示", "已开启快速互动")
    else
        if quickInteractConn then quickInteractConn:Disconnect(); quickInteractConn = nil end
        for prompt, duration in pairs(quickInteractOriginal) do
            if prompt and prompt.Parent then pcall(function() prompt.HoldDuration = duration end) end
            quickInteractOriginal[prompt] = nil
        end
        notify("功能提示", "已关闭快速互动并恢复原 HoldDuration")
    end
end })

-- PolyHub 恢复版 Fullbright：Ambient/OutdoorAmbient/Brightness/ClockTime/FogEnd/GlobalShadows。
Tab2:CreateToggle({ Name = "夜视（Fullbright 恢复版）", CurrentValue = false, Flag = "NightVisionToggle", Ext = true, Callback = function(v)
    Recovered.fullbrightEnabled = v
    Recovered.setFullbright(v)
    notify("功能提示", v and "已开启 Fullbright" or "已关闭 Fullbright")
end })

-- 隐藏名字：不再删除其他 BillboardGui，只修改本地 Humanoid NameDisplayDistance。

-- 隐藏名字：不再删除其他 BillboardGui，只修改本地 Humanoid NameDisplayDistance。
local hNameEnabled, hNameConn = false, nil
local function hideNameOnly()
    if not hNameEnabled then return end
    local h = getHumanoid()
    if h then pcall(function() h.NameDisplayDistance = 0 end) end
end
local function restoreName()
    local h = getHumanoid()
    if h then pcall(function() h.NameDisplayDistance = 10 end) end
end
pcall(function()
    LP.CharacterAdded:Connect(function()
        task.wait(0.5)
        if hNameEnabled then hideNameOnly() else restoreName() end
    end)
end)
Tab2:CreateToggle({ Name = "隐藏名字(客户端)", CurrentValue = false, Flag = "HideNameToggle", Ext = true, Callback = function(v)
    hNameEnabled = v
    if v then
        hideNameOnly()
        if not hNameConn then
            hNameConn = task.spawn(function()
                while hNameEnabled do
                    task.wait(1)
                    hideNameOnly()
                end
            end)
        end
        notify("功能提示", "已开启隐藏名字")
    else
        if hNameConn then task.cancel(hNameConn); hNameConn = nil end
        restoreName()
        notify("功能提示", "已关闭隐藏名字")
    end
end })

Tab2:CreateButton({ Name = "重置人物（自杀）", Ext = true, Callback = function()
    local h = getHumanoid()
    if h then pcall(function() h.Health = 0 end); notify("功能提示", "已执行重置人物") else notify("错误提示", "未找到角色") end
end })


Tab2:CreateSection("PolyHub 恢复功能")
Tab2:CreateSlider({ Name = "WalkSpeed", Range = { 1, 100 }, Increment = 1, CurrentValue = 16, Flag = "RecoveredWalkSpeed", Callback = function(v) Recovered.walkSpeedValue = v end })
Tab2:CreateToggle({ Name = "启用 WalkSpeed", CurrentValue = false, Flag = "RecoveredWalkSpeedToggle", Ext = true, Callback = function(v) Recovered.walkSpeedEnabled = v end })
Tab2:CreateSlider({ Name = "JumpPower", Range = { 1, 150 }, Increment = 1, CurrentValue = 50, Flag = "RecoveredJumpPower", Callback = function(v) Recovered.jumpPowerValue = v end })
Tab2:CreateToggle({ Name = "启用 JumpPower", CurrentValue = false, Flag = "RecoveredJumpPowerToggle", Ext = true, Callback = function(v) Recovered.jumpPowerEnabled = v end })
Tab2:CreateSlider({ Name = "FOV", Range = { 40, 120 }, Increment = 1, CurrentValue = 70, Flag = "RecoveredFOV", Callback = function(v) Recovered.fovValue = v end })
Tab2:CreateToggle({ Name = "启用 FOV", CurrentValue = false, Flag = "RecoveredFOVToggle", Ext = true, Callback = function(v) Recovered.fovEnabled = v end })
Tab2:CreateSlider({ Name = "最大镜头距离", Range = { 32, 256 }, Increment = 1, CurrentValue = 128, Flag = "RecoveredMaxZoom", Callback = function(v) Recovered.maxZoomValue = v end })
Tab2:CreateToggle({ Name = "启用最大镜头距离", CurrentValue = false, Flag = "RecoveredMaxZoomToggle", Ext = true, Callback = function(v) Recovered.maxZoomEnabled = v end })
Tab2:CreateToggle({ Name = "Anti-Lag（恢复版）", CurrentValue = false, Flag = "RecoveredAntiLagToggle", Ext = true, Callback = function(v)
    Recovered.antiLagEnabled = v
    Recovered.applyAntiLag(v)
    notify("Anti-Lag", v and "已启用" or "已恢复原材质/贴图")
end })
Tab2:CreateToggle({ Name = "Anti-Jeffrey（恢复版）", CurrentValue = false, Flag = "AntiJeffreyToggle", Ext = true, Callback = function(v)
    Recovered.antiJeffreyEnabled = v
    notify("Anti-Jeffrey", v and "已启用" or "已关闭")
end })

-- ==================== Tab3 自动化 ====================
local autoVoteMode, autoVoteEnabled, autoVoteJob = "AstroV2", false, nil
Tab3:CreateSection("基础自动化")
local VOTE_MAP = {
    ["战斗装甲第一幕"] = "BattleArmorAct1", ["天文 V2"] = "AstroV2", ["天文"] = "Astro", ["普通"] = "Normal",
    ["困难"] = "Hard", ["极难"] = "VeryHard", ["疯狂"] = "Insane", ["噩梦"] = "Nightmare", ["Boss 挑战"] = "BossRush",
    ["僵尸"] = "Zombie", ["僵尸 V2"] = "ZombieV2", ["圣诞"] = "Christmas", ["雷暴"] = "ThunderStorm",
    ["地狱"] = "Hell", ["暗黑维度"] = "DarkDimension",
}
local VOTE_OPTIONS = { "战斗装甲第一幕", "天文 V2", "天文", "普通", "困难", "极难", "疯狂", "噩梦", "Boss 挑战", "僵尸", "僵尸 V2", "圣诞", "雷暴", "地狱", "暗黑维度" }
Tab3:CreateDropdown({ Name = "投票模式", Options = VOTE_OPTIONS, CurrentOption = { "天文 V2" }, Flag = "VoteMode", Callback = function(o)
    local picked = type(o) == "table" and o[1] or tostring(o)
    autoVoteMode = VOTE_MAP[picked] or picked
    local vote = findRemote("Vote", 1)
    if vote then pcall(function() if vote:IsA("RemoteEvent") then vote:FireServer(autoVoteMode) else vote:InvokeServer(autoVoteMode) end end) end
end })
Tab3:CreateToggle({ Name = "自动投票", CurrentValue = false, Flag = "AutoVoteToggle", Ext = true, Callback = function(v)
    autoVoteEnabled = v
    if v then
        if not autoVoteJob then
            autoVoteJob = task.spawn(function()
                while autoVoteEnabled do
                    local vote = findRemote("Vote", 2)
                    if not vote then
                        notify("自动化", "找不到 Vote，自动投票暂停", 3)
                        task.wait(2)
                    else
                        pcall(function()
                            if vote:IsA("RemoteEvent") then vote:FireServer(autoVoteMode) else vote:InvokeServer(autoVoteMode) end
                        end)
                        task.wait(1)
                    end
                end
                autoVoteJob = nil
            end)
        end
        notify("自动化", "已开启自动投票")
    else
        if autoVoteJob then task.cancel(autoVoteJob); autoVoteJob = nil end
        notify("自动化", "已关闭自动投票")
    end
end })

local autoReadyEnabled, autoReadyJob = false, nil
Tab3:CreateToggle({ Name = "自动准备", CurrentValue = false, Flag = "AutoReadyToggle", Ext = true, Callback = function(v)
    autoReadyEnabled = v
    if v then
        local readyNow = findRemote("GetReadyRemote", 1)
        if readyNow then pcall(function() if readyNow:IsA("RemoteEvent") then readyNow:FireServer("1", true) else readyNow:InvokeServer("1", true) end end) end
        if not autoReadyJob then
            autoReadyJob = task.spawn(function()
                while autoReadyEnabled do
                    local ready = findRemote("GetReadyRemote", 2)
                    if ready then
                        pcall(function()
                            if ready:IsA("RemoteEvent") then ready:FireServer("1", true) else ready:InvokeServer("1", true) end
                        end)
                    else notify("自动化", "找不到 GetReadyRemote", 3) end
                    task.wait(3)
                end
                autoReadyJob = nil
            end)
        end
        notify("自动化", "已开启自动准备")
    else
        if autoReadyJob then task.cancel(autoReadyJob); autoReadyJob = nil end
        notify("自动化", "已关闭自动准备")
    end
end })

-- 直升机跳过：公开 STBB 社区脚本当前仍使用 SkipHelicopter:FireServer()。
local autoSkipHeliEnabled, autoSkipHeliJob, autoSkipHeliInterval = false, nil, 1
Tab3:CreateToggle({ Name = "自动跳过直升机", CurrentValue = false, Flag = "AutoSkipHeliToggle", Ext = true, Callback = function(v)
    autoSkipHeliEnabled = v
    if v then
        if not autoSkipHeliJob then
            autoSkipHeliJob = task.spawn(function()
                while autoSkipHeliEnabled do
                    local r = findRemote("SkipHelicopter", 2)
                    if r then
                        pcall(function()
                            if r:IsA("RemoteEvent") then r:FireServer() else r:InvokeServer() end
                        end)
                    end
                    task.wait(autoSkipHeliInterval)
                end
                autoSkipHeliJob = nil
            end)
        end
        notify("自动化", "已开启自动跳过直升机")
    else
        if autoSkipHeliJob then task.cancel(autoSkipHeliJob); autoSkipHeliJob = nil end
        notify("自动化", "已关闭自动跳过直升机")
    end
end })

-- 抽奖：替换为反混淆中已验证的 1Spin / 10Spins / 1LuckySpin。
local autoGachaEnabled, autoGachaJob, autoGachaInterval, autoGachaPool, autoGachaSpinArg = false, nil, 3, "GachaSkins", "1Spin"
Tab3:CreateSection("自动抽奖（恢复参数）")
Tab3:CreateDropdown({ Name = "抽奖池", Options = { "皮肤池 (GachaSkins)", "角色池 (GachaCharacter)" }, CurrentOption = { "皮肤池 (GachaSkins)" }, Flag = "GachaPool", Callback = function(opt)
    local s = type(opt) == "table" and opt[1] or tostring(opt)
    autoGachaPool = s:find("角色池", 1, true) and "GachaCharacter" or "GachaSkins"
end })
Tab3:CreateDropdown({ Name = "抽奖类型", Options = { "单抽 (1Spin)", "10连抽 (10Spins)", "幸运单抽 (1LuckySpin)" }, CurrentOption = { "单抽 (1Spin)" }, Flag = "GachaArg", Callback = function(opt)
    local s = type(opt) == "table" and opt[1] or tostring(opt)
    if s:find("10连", 1, true) then autoGachaSpinArg = "10Spins"
    elseif s:find("幸运", 1, true) then autoGachaSpinArg = "1LuckySpin"
    else autoGachaSpinArg = "1Spin" end
end })
Tab3:CreateSlider({ Name = "抽奖间隔 (秒)", Range = { 1, 30 }, Increment = 1, CurrentValue = 3, Flag = "GachaInterval", Callback = function(v) autoGachaInterval = v end })
local function doRecoveredGachaOnce()
    local remote = findRemote(autoGachaPool, 1.5)
    if not remote then notify("抽奖", "找不到 " .. autoGachaPool); return false end
    local ok = pcall(function()
        if remote:IsA("RemoteEvent") then remote:FireServer(autoGachaSpinArg) else remote:InvokeServer(autoGachaSpinArg) end
    end)
    notify("抽奖", ok and ("已发送 " .. autoGachaSpinArg) or "发送失败", 2)
    return ok
end
Tab3:CreateButton({ Name = "抽一次", Ext = true, Callback = doRecoveredGachaOnce })
Tab3:CreateToggle({ Name = "自动抽奖", CurrentValue = false, Flag = "AutoGachaToggle", Ext = true, Callback = function(v)
    autoGachaEnabled = v
    if v then
        if not autoGachaJob then
            autoGachaJob = task.spawn(function()
                while autoGachaEnabled do
                    doRecoveredGachaOnce()
                    task.wait(autoGachaInterval)
                end
                autoGachaJob = nil
            end)
        end
        notify("自动化", "已开启自动抽奖")
    else
        if autoGachaJob then task.cancel(autoGachaJob); autoGachaJob = nil end
        notify("自动化", "已关闭自动抽奖")
    end
end })

-- 礼物
local autoGiftEnabled

-- 礼物
local autoGiftEnabled, autoGiftJob, autoGiftInterval = false, nil, 1
Tab3:CreateSection("开礼物")
Tab3:CreateSlider({ Name = "开礼物间隔 (秒)", Range = { 0.5, 10 }, Increment = 0.5, CurrentValue = 1, Flag = "GiftInterval", Callback = function(v) autoGiftInterval = v end })
Tab3:CreateButton({ Name = "开一次礼物", Ext = true, Callback = function()
    local remote = findRemote("GachaCapsule")
    if not remote then notify("礼物", "找不到 GachaCapsule"); return end
    local ok, err = pcall(function()
        if remote:IsA("RemoteEvent") then remote:FireServer() else remote:InvokeServer() end
    end)
    notify("礼物", ok and "已发送开礼物请求" or ("失败: " .. tostring(err)), 3)
end })
Tab3:CreateToggle({ Name = "自动开礼物", CurrentValue = false, Flag = "AutoGiftToggle", Ext = true, Callback = function(v)
    autoGiftEnabled = v
    if v then
        if not autoGiftJob then
            autoGiftJob = task.spawn(function()
                while autoGiftEnabled do
                    local remote = findRemote("GachaCapsule")
                    if remote then pcall(function()
                        if remote:IsA("RemoteEvent") then remote:FireServer() else remote:InvokeServer() end
                    end) end
                    task.wait(autoGiftInterval)
                end
                autoGiftJob = nil
            end)
        end
        notify("自动化", "已开启自动开礼物")
    else
        if autoGiftJob then task.cancel(autoGiftJob); autoGiftJob = nil end
        notify("自动化", "已关闭自动开礼物")
    end
end })

-- ==================== 自动技能 ====================
-- 反混淆恢复：E/R/T/Y/U/I/O/P/F/G/H/J/K/L/Z/X/C/V/B/N/M，间隔 0.6 秒。
local autoSkillEnabled, autoSkillJob = false, nil
local autoSkillKeys = {"E", "R", "T", "Y", "U", "I", "O", "P", "F", "G", "H", "J", "K", "L", "Z", "X", "C", "V", "B", "N", "M"}
local AUTO_SKILL_OPTIONS = {"E", "R", "T", "Y", "U", "I", "O", "P", "F", "G", "H", "J", "K", "L", "Z", "X", "C", "V", "B", "N", "M"}

local function pressRecoveredGameKey(key)
    if not VirtualInputManager or type(key) ~= "string" then return false end
    local keyCode = Enum.KeyCode[key]
    if not keyCode then return false end
    local ok = pcall(function()
        VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
        task.wait(0.01)
        VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
    end)
    return ok
end

local autoSkillSyncWithFarm = false

local function startRecoveredAutoSkill()
    if autoSkillJob then return end
    autoSkillJob = task.spawn(function()
        while autoSkillEnabled or (autoSkillSyncWithFarm and autoAttackEnabled) do
            if not isAstroRunning and not isShopping and not isTeleportingToMaterial and not autoFireGunEnabled then
                for _, key in ipairs(autoSkillKeys) do
                    if not autoSkillEnabled and not (autoSkillSyncWithFarm and autoAttackEnabled) then break end
                    pressRecoveredGameKey(key)
                end
            end
            task.wait(0.6)
        end
        autoSkillJob = nil
    end)
end

Tab3:CreateSection("自动释放技能（恢复版）")
Tab3:CreateDropdown({ Name = "技能按键（可多选）", Options = AUTO_SKILL_OPTIONS, CurrentOption = AUTO_SKILL_OPTIONS, MultipleOptions = true, Flag = "AutoSkillKeys", Callback = function(selected)
    autoSkillKeys = {}
    if type(selected) == "table" then
        for _, key in ipairs(selected) do if table.find(AUTO_SKILL_OPTIONS, key) then autoSkillKeys[#autoSkillKeys + 1] = key end end
    end
    if #autoSkillKeys == 0 then autoSkillKeys = {"E"} end
end })
Tab3:CreateToggle({ Name = "自动释放技能", CurrentValue = false, Flag = "AutoSkillToggle", Ext = true, Callback = function(v)
    autoSkillEnabled = v
    if v then startRecoveredAutoSkill(); notify("自动技能", "已开启")
    elseif not autoSkillSyncWithFarm and autoSkillJob then task.cancel(autoSkillJob); autoSkillJob = nil; notify("自动技能", "已关闭")
    else notify("自动技能", "已关闭") end
end })
Tab3:CreateToggle({ Name = "自动技能跟随自动刷怪", CurrentValue = false, Flag = "AutoSkillWithFarm", Ext = true, Callback = function(v)
    autoSkillSyncWithFarm = v
    if v then
        startRecoveredAutoSkill()
    elseif not autoSkillEnabled and autoSkillJob then
        task.cancel(autoSkillJob)
        autoSkillJob = nil
    end
end })

-- ==================== 技能录制/回放 ====================

-- ==================== 技能录制/回放 ====================
local recState = {
    recording = false,
    playing = false,
    events = {},
    groups = {},
    playJob = nil,
    recordStartTime = 0,
    hookInstalled = false,
    loop = true,
    refreshQuickList = nil,
    mergeWindow = 0.1,
    ignoreRemotes = {
        MouseStream = true, MouseHit = true, SendSetting = true, UITimerControl = true,
        NotifyEvent = true, NotifyWaveComplete = true, NotifyWaveReset = true, GetBadgeStatus = true,
        Running = true, GetReadyRemote = true, HeadCaptainOfCCTVSet = true,
    },
}
recState.hasFileAPI = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
recState.cloudFile = "ST_Cloud_RemoteGroups_" .. tostring(game.PlaceId) .. ".json"

local treeRecState = {
    recording = false, playing = false, events = {}, groups = {}, playJob = nil,
    recordStartTime = 0, hookInstalled = false, refreshQuickList = nil, mergeWindow = 0.2,
}
treeRecState.hasFileAPI = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
treeRecState.cloudFile = "ST_Cloud_TreeGroups_" .. tostring(game.PlaceId) .. ".json"

local function getInstancePath(inst)
    if typeof(inst) ~= "Instance" then return nil end
    local ok, path = pcall(function() return inst:GetFullName() end)
    return ok and path or nil
end

local function recSerArg(a, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if depth > 8 then return { __t = "?" } end

    local simpleType = type(a)
    if simpleType == "number" or simpleType == "string" or simpleType == "boolean" then
        return { __t = simpleType, v = a }
    end
    if a == nil then return { __t = "nil" } end

    local t = typeof(a)
    if t == "Instance" then
        return { __t = "I", path = getInstancePath(a), class = a.ClassName, name = a.Name }
    elseif t == "Vector3" then
        return { __t = "V3", x = a.X, y = a.Y, z = a.Z }
    elseif t == "Vector2" then
        return { __t = "V2", x = a.X, y = a.Y }
    elseif t == "CFrame" then
        local ok, c = pcall(function() return { a:GetComponents() } end)
        return ok and { __t = "CF", c = c } or nil
    elseif t == "Color3" then
        return { __t = "C3", r = a.R, g = a.G, b = a.B }
    elseif t == "EnumItem" then
        local enumType = tostring(a.EnumType):gsub("^Enum%.", "")
        return { __t = "E", enum = enumType, name = a.Name }
    elseif t == "BrickColor" then
        return { __t = "BC", n = a.Number }
    elseif t == "UDim2" then
        return { __t = "UD2", xs = a.X.Scale, xo = a.X.Offset, ys = a.Y.Scale, yo = a.Y.Offset }
    elseif t == "table" then
        if seen[a] then return { __t = "cycle" } end
        seen[a] = true
        local items = {}
        for k, v in pairs(a) do
            local ks = recSerArg(k, depth + 1, seen)
            local vs = recSerArg(v, depth + 1, seen)
            if not ks or not vs then return nil end
            items[#items + 1] = { k = ks, v = vs }
        end
        seen[a] = nil
        return { __t = "T", items = items }
    end
    return nil
end

local function findByPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    local parts = {}
    for piece in path:gmatch("[^%.]+") do parts[#parts + 1] = piece end
    if #parts == 0 then return nil end
    local current = game:FindFirstChild(parts[1])
    if not current then return nil end
    for i = 2, #parts do
        current = current:FindFirstChild(parts[i])
        if not current then return nil end
    end
    return current
end

local function findRemoteFallback(name, className)
    if type(name) ~= "string" then return nil end
    local found
    local ok = pcall(function()
        for _, obj in ipairs(game:GetDescendants()) do
            if obj.Name == name and (not className or obj.ClassName == className) then
                found = obj
                break
            end
        end
    end)
    return ok and found or nil
end

local function resolveRecordedRemote(ev)
    if not ev then return nil end
    local remote = ev.path and findByPath(ev.path) or nil
    if remote and (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction")) then
        return remote
    end
    return findRemoteFallback(ev.remote, ev.class)
end

local function recDesArg(d)
    if not d or type(d) ~= "table" then return nil end
    local t = d.__t
    if t == "number" or t == "string" or t == "boolean" then return d.v end
    if t == "nil" then return nil end
    if t == "T" then
        local out = {}
        for _, kv in ipairs(d.items or {}) do
            out[recDesArg(kv.k)] = recDesArg(kv.v)
        end
        return out
    elseif t == "I" then
        return findByPath(d.path) or findRemoteFallback(d.name, d.class)
    elseif t == "V3" then
        return Vector3.new(d.x, d.y, d.z)
    elseif t == "V2" then
        return Vector2.new(d.x, d.y)
    elseif t == "CF" then
        local ok, cf = pcall(function() return CFrame.new(table.unpack(d.c or {})) end)
        return ok and cf or CFrame.new()
    elseif t == "C3" then
        return Color3.new(d.r, d.g, d.b)
    elseif t == "E" then
        local ok, result = pcall(function() return Enum[d.enum][d.name] end)
        return ok and result or nil
    elseif t == "BC" then
        local ok, result = pcall(function() return BrickColor.new(d.n) end)
        return ok and result or nil
    elseif t == "UD2" then
        return UDim2.new(d.xs, d.xo, d.ys, d.yo)
    end
    return nil
end

local function safeSerializeArgs(vargs)
    local ser = {}
    for i = 1, #vargs do
        local s = recSerArg(vargs[i])
        if s == nil then return nil end
        ser[i] = s
    end
    return ser
end

local function installAllHooks()
    if recState.hookInstalled and treeRecState.hookInstalled then return true end
    if type(getrawmetatable) ~= "function" or type(newcclosure) ~= "function" or type(getnamecallmethod) ~= "function" or type(setreadonly) ~= "function" then
        notify("录制", "当前执行器不支持完整 Hook，录制功能保持关闭", 4)
        return false
    end

    local ok, err = pcall(function()
        local mt = getrawmetatable(game)
        if not mt then error("无法取得 game metatable") end
        local oldNC = mt.__namecall
        if type(oldNC) ~= "function" then error("没有旧 __namecall") end
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            local vargs = { ... }
            if (method == "FireServer" or method == "InvokeServer") and typeof(self) == "Instance" then
                if (self:IsA("RemoteEvent") or self:IsA("RemoteFunction")) and not recState.ignoreRemotes[self.Name] then
                    local ser = safeSerializeArgs(vargs)
                    if ser then
                        local now = tick()
                        local path = getInstancePath(self)
                        if recState.recording and not recState.playing then
                            local tRel = now - recState.recordStartTime
                            local last = recState.events[#recState.events]
                            if last and last.remote == self.Name and (tRel - last.t) <= recState.mergeWindow then
                                last.args = ser
                                last.t = tRel
                                last.path = path
                                last.kind = method
                                last.class = self.ClassName
                                last.state = snapshotSkillState()
                            else
                                recState.events[#recState.events + 1] = {
                                    remote = self.Name,
                                    path = path,
                                    class = self.ClassName,
                                    kind = method,
                                    args = ser,
                                    t = tRel,
                                    state = snapshotSkillState(),
                                }
                            end
                        end
                        if treeRecState.recording and not treeRecState.playing then
                            local tRel = now - treeRecState.recordStartTime
                            local last = treeRecState.events[#treeRecState.events]
                            if last and last.remote == self.Name and (tRel - last.t) <= treeRecState.mergeWindow then
                                last.args = ser
                                last.t = tRel
                                last.path = path
                                last.kind = method
                                last.class = self.ClassName
                                last.state = snapshotSkillState()
                            else
                                treeRecState.events[#treeRecState.events + 1] = {
                                    remote = self.Name,
                                    path = path,
                                    class = self.ClassName,
                                    kind = method,
                                    args = ser,
                                    t = tRel,
                                    state = snapshotSkillState(),
                                }
                            end
                        end
                    end
                end
            end
            return oldNC(self, table.unpack(vargs))
        end)
        setreadonly(mt, true)
    end)

    if not ok then
        notify("录制", "Hook 安装失败: " .. tostring(err), 4)
        return false
    end

    recState.hookInstalled = true
    treeRecState.hookInstalled = true
    return true
end

local function recSaveCloud()
    if not recState.hasFileAPI or not HttpService then return end
    pcall(function() writefile(recState.cloudFile, HttpService:JSONEncode(recState.groups)) end)
end
local function recLoadCloud()
    if not recState.hasFileAPI or not HttpService or not isfile(recState.cloudFile) then return end
    pcall(function()
        local d = HttpService:JSONDecode(readfile(recState.cloudFile))
        if type(d) ~= "table" then return end
        for name, g in pairs(d) do
            if type(g) == "table" and type(g.events) == "table" then recState.groups[name] = g end
        end
    end)
end

local function recWaitUntil(targetTime, state)
    while state.playing do
        local remaining = targetTime - tick()
        if remaining <= 0 then return true end
        task.wait(math.min(remaining, 0.03))
    end
    return false
end

local function recPlayGroup(name)
    local g = recState.groups[name]
    if not g or not g.events or #g.events == 0 then notify("技能组", "该技能组为空"); return end
    if recState.playJob then task.cancel(recState.playJob); recState.playJob = nil end

    recState.playing = true
    isSkillPlaying = true
    isCastingSkill = true

    recState.playJob = task.spawn(function()
        repeat
            local playStart = tick()
            for _, ev in ipairs(g.events) do
                if not recState.playing then break end
                local targetT = playStart + math.max(0, tonumber(ev.t) or 0)
                if not recWaitUntil(targetT, recState) then break end

                local charBefore = LP.Character
                local hum = charBefore and charBefore:FindFirstChildWhichIsA("Humanoid")
                if not hum or hum.Health <= 0 then
                    notify("技能组", "角色已死亡，当前技能组停止", 3)
                    recState.playing = false
                    break
                end

                if ev.state then
                    local compatible, reason = skillStateCompatible(ev.state)
                    if not compatible then
                        notify("技能组", "角色状态与录制不匹配：" .. tostring(reason), 4)
                        recState.playing = false
                        break
                    end
                end

                local r = resolveRecordedRemote(ev)
                if r then
                    local args = {}
                    for _, a in ipairs(ev.args or {}) do args[#args + 1] = recDesArg(a) end
                    pcall(function()
                        if (ev.kind == "InvokeServer" or ev.kind == nil) and r:IsA("RemoteFunction") then
                            r:InvokeServer(table.unpack(args))
                        elseif (ev.kind == "FireServer" or ev.kind == nil) and r:IsA("RemoteEvent") then
                            r:FireServer(table.unpack(args))
                        end
                    end)
                end
            end
            if recState.loop and recState.playing then task.wait(0.05) end
        until not recState.loop or not recState.playing

        recState.playing = false
        isSkillPlaying = false
        isCastingSkill = false
        recState.playJob = nil
        currentTarget = nil
        cachedEnemy = nil
        lastHrpPosition = nil
    end)
end

local function recStopPlay()
    recState.playing = false
    isSkillPlaying = false
    isCastingSkill = false
    if recState.playJob then task.cancel(recState.playJob); recState.playJob = nil end
    local h = getHumanoid()
    local hrp = getHRP()
    if h then pcall(function() h.WalkSpeed = 16 end); pcall(function() h.PlatformStand = false end) end
    if hrp then pcall(function() hrp.Anchored = false end) end
end

Tab3:CreateSection("技能录制")
local recGroupName = ""
Tab3:CreateInput({ Name = "技能组名称", PlaceholderText = "输入名称（留空则自动命名）", CurrentValue = "", Flag = "RecGroupName", Callback = function(text) recGroupName = text or "" end })
Tab3:CreateButton({ Name = "▶ 开始录制", Ext = true, Callback = function()
    if recState.recording then notify("录制", "正在录制中"); return end
    if treeRecState.recording then notify("录制", "技能树正在录制，请先结束技能树录制"); return end
    if not installAllHooks() then return end
    recState.events = {}
    recState.recordStartTime = tick()
    refreshCharacterState()
    recState.recording = true
    isCastingSkill = true
    notify("录制", "开始！点游戏内技能键，录完点停止", 4)
end })
Tab3:CreateButton({ Name = "⏹ 停止并保存", Ext = true, Callback = function()
    if not recState.recording then notify("录制", "未在录制中"); return end
    recState.recording = false
    isCastingSkill = false
    if #recState.events == 0 then notify("录制", "没录到有效事件", 3); return end
    local nm = recGroupName
    if nm == "" then nm = "技能组_" .. os.date("%m%d_%H%M%S") end
    recState.groups[nm] = { events = recState.events, time = os.date("%Y-%m-%d %H:%M:%S"), map = game.PlaceId, state = recState.events[1] and recState.events[1].state or nil }
    recSaveCloud()
    notify("录制", "已保存: " .. nm .. " (" .. #recState.events .. " 条)", 3)
    if recState.refreshQuickList then recState.refreshQuickList() end
end })
Tab3:CreateButton({ Name = "保存技能组", Ext = true, Callback = function()
    if #recState.events == 0 then notify("录制", "录制为空"); return end
    local nm = recGroupName
    if nm == "" then notify("录制", "请先输入技能组名称", 3); return end
    recState.groups[nm] = { events = recState.events, time = os.date("%Y-%m-%d %H:%M:%S"), map = game.PlaceId, state = recState.events[1] and recState.events[1].state or nil }
    recSaveCloud()
    notify("录制", "已保存: " .. nm, 3)
    if recState.refreshQuickList then recState.refreshQuickList() end
end })

Tab3:CreateSection("技能组快捷使用")
local quickGroupName
local function quickListOptions()
    local o = {}
    for n in pairs(recState.groups) do o[#o + 1] = n end
    if #o == 0 then o = { "(暂无技能组)" } end
    table.sort(o)
    return o
end
local quickDropdown = Tab3:CreateDropdown({ Name = "选择技能组", Options = quickListOptions(), CurrentOption = { "(暂无技能组)" }, Flag = "QuickSkillGroup", Callback = function(opt)
    quickGroupName = type(opt) == "table" and opt[1] or opt
end })
local function refreshQuickDropdown()
    pcall(function() quickDropdown:Refresh(quickListOptions()) end)
end
recState.refreshQuickList = refreshQuickDropdown
Tab3:CreateToggle({ Name = "使用技能组（循环 + 按原时间释放）", CurrentValue = false, Flag = "QuickSkillToggle", Ext = true, Callback = function(v)
    if v then
        if not quickGroupName or quickGroupName == "(暂无技能组)" then notify("技能组", "请先选择一个技能组"); return end
        recState.loop = true
        recPlayGroup(quickGroupName)
        notify("技能组", "开始循环使用: " .. quickGroupName)
    else
        recStopPlay()
        notify("技能组", "已停止")
    end
end })
Tab3:CreateButton({ Name = "删除技能组", Ext = true, Callback = function()
    if not quickGroupName or quickGroupName == "(暂无技能组)" then notify("技能组", "请先选择一个技能组"); return end
    recState.groups[quickGroupName] = nil
    recSaveCloud()
    refreshQuickDropdown()
    notify("技能组", "已删除: " .. quickGroupName)
end })
Tab3:CreateButton({ Name = "刷新技能组列表", Ext = true, Callback = function()
    refreshQuickDropdown()
    local n = 0 for _ in pairs(recState.groups) do n = n + 1 end
    notify("技能组", "已加载 " .. n .. " 个技能组")
end })
task.spawn(function()
    task.wait(1)
    recLoadCloud()
    local n = 0 for _ in pairs(recState.groups) do n = n + 1 end
    if n > 0 then notify("本地", "已加载 " .. n .. " 个技能组", 3); refreshQuickDropdown() end
end)

-- 技能树
local function treeRecSaveCloud()
    if not treeRecState.hasFileAPI or not HttpService then return end
    pcall(function() writefile(treeRecState.cloudFile, HttpService:JSONEncode(treeRecState.groups)) end)
end
local function treeRecLoadCloud()
    if not treeRecState.hasFileAPI or not HttpService or not isfile(treeRecState.cloudFile) then return end
    pcall(function()
        local d = HttpService:JSONDecode(readfile(treeRecState.cloudFile))
        if type(d) ~= "table" then return end
        for name, g in pairs(d) do
            if type(g) == "table" and type(g.events) == "table" then treeRecState.groups[name] = g end
        end
    end)
end

local function treeRecPlayGroup(name)
    local g = treeRecState.groups[name]
    if not g or not g.events or #g.events == 0 then notify("技能树", "该技能树为空"); return end
    if treeRecState.playJob then task.cancel(treeRecState.playJob); treeRecState.playJob = nil end
    treeRecState.playing = true
    treeRecState.playJob = task.spawn(function()
        local start = tick()
        for _, ev in ipairs(g.events) do
            if not treeRecState.playing then break end
            local target = start + math.max(0, tonumber(ev.t) or 0)
            while tick() < target and treeRecState.playing do task.wait(0.01) end
            if not treeRecState.playing then break end
            if ev.state then
                local compatible = skillStateCompatible(ev.state)
                if not compatible then
                    notify("技能树", "角色状态与录制不匹配，已停止", 4)
                    break
                end
            end
            local r = resolveRecordedRemote(ev)
            if r then
                local args = {}
                for _, a in ipairs(ev.args or {}) do args[#args + 1] = recDesArg(a) end
                pcall(function()
                    if (ev.kind == "InvokeServer" or ev.kind == nil) and r:IsA("RemoteFunction") then r:InvokeServer(table.unpack(args))
                    elseif (ev.kind == "FireServer" or ev.kind == nil) and r:IsA("RemoteEvent") then r:FireServer(table.unpack(args)) end
                end)
            end
        end
        treeRecState.playing = false
        treeRecState.playJob = nil
        notify("技能树", "使用完成")
    end)
end

local function treeRecStopPlay()
    treeRecState.playing = false
    if treeRecState.playJob then task.cancel(treeRecState.playJob); treeRecState.playJob = nil end
end

Tab3:CreateSection("技能树录制")
local treeRecGroupName = ""
Tab3:CreateInput({ Name = "技能树名称", PlaceholderText = "输入技能树名称", CurrentValue = "", Flag = "TreeRecGroupName", Callback = function(text) treeRecGroupName = text or "" end })
Tab3:CreateToggle({ Name = "开始录制技能树", CurrentValue = false, Flag = "TreeRecToggle", Ext = true, Callback = function(v)
    if v then
        if recState.recording then notify("技能树", "技能组正在录制，请先结束技能组录制"); return end
        if treeRecState.recording then return end
        if not installAllHooks() then return end
        treeRecState.events = {}
        treeRecState.recordStartTime = tick()
        treeRecState.recording = true
        notify("技能树", "开始！去点技能树加点，关掉开关即保存", 4)
    else
        if not treeRecState.recording then return end
        treeRecState.recording = false
        if #treeRecState.events == 0 then notify("技能树", "没录到有效事件", 3); return end
        local nm = treeRecGroupName
        if nm == "" then nm = "技能树_" .. os.date("%m%d_%H%M%S") end
        treeRecState.groups[nm] = { events = treeRecState.events, time = os.date("%Y-%m-%d %H:%M:%S"), map = game.PlaceId, state = treeRecState.events[1] and treeRecState.events[1].state or nil }
        treeRecSaveCloud()
        notify("技能树", "已保存: " .. nm .. " (" .. #treeRecState.events .. " 条)", 3)
        if treeRecState.refreshQuickList then treeRecState.refreshQuickList() end
    end
end })

Tab3:CreateSection("技能树快捷使用")
local treeQuickGroupName
local function treeQuickListOptions()
    local o = {}
    for n in pairs(treeRecState.groups) do o[#o + 1] = n end
    if #o == 0 then o = { "(暂无技能树)" } end
    table.sort(o)
    return o
end
local treeQuickDropdown = Tab3:CreateDropdown({ Name = "选择技能树", Options = treeQuickListOptions(), CurrentOption = { "(暂无技能树)" }, Flag = "TreeQuickGroup", Callback = function(opt)
    treeQuickGroupName = type(opt) == "table" and opt[1] or opt
end })
local function refreshTreeQuickDropdown() pcall(function() treeQuickDropdown:Refresh(treeQuickListOptions()) end) end
treeRecState.refreshQuickList = refreshTreeQuickDropdown
Tab3:CreateToggle({ Name = "使用技能树", CurrentValue = false, Flag = "TreeQuickToggle", Ext = true, Callback = function(v)
    if v then
        if not treeQuickGroupName or treeQuickGroupName == "(暂无技能树)" then notify("技能树", "请先选择一个技能树"); return end
        if recState.playing then notify("技能树", "技能组正在播放，请先关闭技能组"); return end
        treeRecPlayGroup(treeQuickGroupName)
        notify("技能树", "开始使用: " .. treeQuickGroupName)
    else
        treeRecStopPlay()
        notify("技能树", "已停止")
    end
end })
Tab3:CreateButton({ Name = "删除技能树", Ext = true, Callback = function()
    if not treeQuickGroupName or treeQuickGroupName == "(暂无技能树)" then notify("技能树", "请先选择一个技能树"); return end
    treeRecState.groups[treeQuickGroupName] = nil
    treeRecSaveCloud()
    refreshTreeQuickDropdown()
    notify("技能树", "已删除: " .. treeQuickGroupName)
end })
Tab3:CreateButton({ Name = "刷新技能树列表", Ext = true, Callback = function()
    refreshTreeQuickDropdown()
    local n = 0 for _ in pairs(treeRecState.groups) do n = n + 1 end
    notify("技能树", "已加载 " .. n .. " 个技能树")
end })
task.spawn(function()
    task.wait(1)
    treeRecLoadCloud()
    local n = 0 for _ in pairs(treeRecState.groups) do n = n + 1 end
    if n > 0 then notify("本地", "已加载 " .. n .. " 个技能树", 3); refreshTreeQuickDropdown() end
end)

-- ==================== 自动战斗（替换为 PolyHub Auto Farm 恢复版） ====================
local autoAttackConnection = nil

local function getRecoveredFarmAttackCooldown()
    return 1 - (Recovered.farmSpeed / 100) * 0.95
end

local function tryRecoveredLMBAttack()
    local character = getCharacter()
    local lmb = character and character:FindFirstChild("LMB")
    if not lmb then return false end
    local now = tick()
    local cooldown = math.max(getRecoveredFarmAttackCooldown(), 0)
    if now - Recovered.lastLmbAttack < cooldown then return false end
    local ok = pcall(function() lmb:FireServer() end)
    if ok then Recovered.lastLmbAttack = tick(); return true end
    return false
end

task.spawn(function()
    while task.wait(0.5) do
        if autoAttackEnabled then
            Recovered.autoFarmTarget = Recovered.getClosestEnemy()
        else
            Recovered.autoFarmTarget = nil
        end
    end
end)

local function startAutoAttack()
    if autoAttackConnection then return end
    autoAttackConnection = RS.Heartbeat:Connect(function()
        if not autoAttackEnabled then return end
        local root = getHRP()
        local target = Recovered.autoFarmTarget
        if not root or not target or not target.Parent then return end
        local humanoid = target:FindFirstChildOfClass("Humanoid")
        local targetRoot = target:FindFirstChild("HumanoidRootPart")
        local combatPart = Recovered.getCombatPart(target) or targetRoot
        if not humanoid or humanoid.Health <= 0 or not targetRoot or not combatPart or not combatPart:IsA("BasePart") then return end

        local destination = combatPart.CFrame
        if Recovered.autoFarmMode == "Teleport" then
            root.CFrame = destination
        else
            local tweenSpeed = math.max(15, (Recovered.farmSpeed / 100) * 507.5)
            local distance = (destination.Position - root.Position).Magnitude
            local duration = distance / tweenSpeed
            if Recovered.currentFarmTween then pcall(function() Recovered.currentFarmTween:Cancel() end); Recovered.currentFarmTween = nil end
            pcall(function()
                Recovered.currentFarmTween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear), {CFrame = destination})
                Recovered.currentFarmTween:Play()
            end)
        end

        local radius = combatPart.Size.Magnitude / 2 + ((target.Name == "Ginger Toilet") and 1 or 2.5)
        local flatDelta = Vector3.new(combatPart.Position.X - root.Position.X, 0, combatPart.Position.Z - root.Position.Z)
        if flatDelta.Magnitude <= radius then tryRecoveredLMBAttack() end
    end)
end

-- 恢复版 Auto Farm 附带的紫色防坠平台（Event 84，几何结构可确认）。
RunService.Heartbeat:Connect(function()
    if not autoAttackEnabled then return end
    pcall(function()
        local root = getHRP()
        if not root then return end
        local platform = Workspace:FindFirstChild("PolyHubFarmPlatform")
        if not platform then
            platform = Instance.new("Part")
            platform.Name = "PolyHubFarmPlatform"
            platform.Size = Vector3.new(15, 2, 15)
            platform.Anchored = true
            platform.CanCollide = true
            platform.Transparency = 0.5
            platform.Color = Color3.fromRGB(95, 0, 255)
            platform.Material = Enum.Material.Neon
            platform.Parent = Workspace
        end
        platform.Position = Vector3.new(root.Position.X, root.Position.Y - 15, root.Position.Z)
    end)
end)

Tab3:CreateSection("自动战斗（恢复版 Auto Farm）")
Tab3:CreateDropdown({ Name = "刷怪移动模式", Options = { "Tween", "Teleport" }, CurrentOption = { "Tween" }, Flag = "RecoveredAutoFarmMode", Callback = function(v)
    Recovered.autoFarmMode = type(v) == "table" and (v[1] or "Tween") or tostring(v)
    if Recovered.currentFarmTween then pcall(function() Recovered.currentFarmTween:Cancel() end); Recovered.currentFarmTween = nil end
end })
Tab3:CreateSlider({ Name = "刷怪速度", Range = { 1, 100 }, Increment = 1, CurrentValue = 100, Flag = "RecoveredFarmSpeed", Callback = function(v) Recovered.farmSpeed = v end })
Tab3:CreateToggle({ Name = "开启自动刷怪", CurrentValue = false, Flag = "AutoAttackToggle", Ext = true, Callback = function(v)
    autoAttackEnabled = v
    if v then
        Recovered.createAimController()
        startAutoAttack()
        if autoSkillSyncWithFarm and not autoSkillJob then startRecoveredAutoSkill() end
        notify("自动化", "已开启恢复版 Auto Farm")
    else
        if autoAttackConnection then autoAttackConnection:Disconnect(); autoAttackConnection = nil end
        if Recovered.currentFarmTween then pcall(function() Recovered.currentFarmTween:Cancel() end); Recovered.currentFarmTween = nil end
        Recovered.autoFarmTarget = nil
        if not Recovered.faceNearestEnabled then Recovered.destroyAimController() end
        notify("自动化", "已关闭恢复版 Auto Farm")
    end
end })

Tab3:CreateToggle({ Name = "Face Nearest（恢复版）", CurrentValue = false, Flag = "RecoveredFaceNearest", Ext = true, Callback = function(v)
    Recovered.faceNearestEnabled = v
    if v then Recovered.createAimController() else if Recovered.aimAlignOrientation then Recovered.aimAlignOrientation.Enabled = false end end
end })

RunService.Heartbeat:Connect(function()
    if not Recovered.faceNearestEnabled then return end
    local root = getHRP()
    if not root or not Recovered.aimAlignOrientation then return end
    if tick() - Recovered.faceTargetStamp >= 0.1 or not Recovered.faceTarget then
        Recovered.faceTarget = Recovered.getClosestEnemy()
        Recovered.faceTargetStamp = tick()
    end
    if not Recovered.faceTarget then Recovered.aimAlignOrientation.Enabled = false; return end
    local targetRoot = Recovered.faceTarget:FindFirstChild("HumanoidRootPart")
    if not targetRoot then Recovered.aimAlignOrientation.Enabled = false; return end
    local direction = targetRoot.Position - root.Position
    if direction.Magnitude > 0.5 then
        Recovered.aimAlignOrientation.CFrame = CFrame.lookAt(Vector3.zero, direction)
        Recovered.aimAlignOrientation.Enabled = true
    else
        Recovered.aimAlignOrientation.Enabled = false
        Recovered.faceTarget = nil
    end
end)

-- ==================== 自动用枪 ====================

-- ==================== 自动用枪 ====================
local autoFireGunJob, autoFireGunInterval = nil, 0.15
Tab3:CreateSection("自动用枪")
Tab3:CreateDropdown({ Name = "武器白名单（可多选）", Options = WEAPON_OPTIONS, CurrentOption = WEAPON_OPTIONS, MultipleOptions = true, Flag = "WeaponWhitelist", Callback = function(selected)
    weaponWhitelist = {}
    if type(selected) == "table" then
        for _, cn in ipairs(selected) do
            local en = WEAPON_MAP[cn]
            if en then weaponWhitelist[en] = true end
        end
    end
end })
Tab3:CreateSlider({ Name = "自动用枪间隔 (秒)", Range = { 0.05, 2 }, Increment = 0.05, CurrentValue = 0.15, Flag = "AutoFireGunInterval", Callback = function(v) autoFireGunInterval = v end })

Tab3:CreateToggle({ Name = "自动用枪（放风筝模式）", CurrentValue = false, Flag = "AutoFireGunToggle", Ext = true, Callback = function(v)
    autoFireGunEnabled = v
    if v then
        if not autoFireGunJob then
            autoFireGunJob = task.spawn(function()
                local kiteBV
                local function cleanupKite()
                    if kiteBV then pcall(function() kiteBV:Destroy() end); kiteBV = nil end
                end

                while autoFireGunEnabled do
                    if isAstroRunning or isSkillPlaying or isShopping or isTeleportingToMaterial or autoTraceMaterialEnabled then
                        cleanupKite()
                        task.wait(0.1)
                    else
                        local char = getCharacter()
                        if not char then cleanupKite(); task.wait(0.5)
                        else
                            local held = char:FindFirstChildWhichIsA("Tool")
                            if not held or not isWhitelistedWeapon(held) then
                                cleanupKite()
                                local tool = findGunTool()
                                if tool then equipTool(tool) end
                                task.wait(0.5)
                            else
                                local target = getClosestEnemyThrottled()
                                local myHrp = char:FindFirstChild("HumanoidRootPart")
                                if target and target.Parent and myHrp then
                                    local targetHrp = target:FindFirstChild("HumanoidRootPart") or target:FindFirstChild("Head")
                                    if targetHrp then
                                        local delta = targetHrp.Position - myHrp.Position
                                        local dist = delta.Magnitude
                                        local SAFE_DISTANCE = 50
                                        if delta.Magnitude > 0.01 then
                                            pcall(function() myHrp.CFrame = CFrame.lookAt(myHrp.Position, Vector3.new(targetHrp.Position.X, myHrp.Position.Y, targetHrp.Position.Z)) end)
                                        end
                                        if dist < SAFE_DISTANCE then
                                            if not kiteBV or kiteBV.Parent ~= myHrp then
                                                cleanupKite()
                                                kiteBV = Instance.new("BodyVelocity")
                                                kiteBV.MaxForce = Vector3.new(1e5, 0, 1e5)
                                                kiteBV.P = 20000
                                                kiteBV.Name = "ST_GunKite_BV"
                                                kiteBV.Parent = myHrp
                                            end
                                            local flee = Vector3.new(myHrp.Position.X - targetHrp.Position.X, 0, myHrp.Position.Z - targetHrp.Position.Z)
                                            if flee.Magnitude > 0.01 then kiteBV.Velocity = flee.Unit * 100 else kiteBV.Velocity = Vector3.zero end
                                        elseif kiteBV then
                                            kiteBV.Velocity = Vector3.zero
                                        end
                                    end
                                else
                                    cleanupKite()
                                end

                                local activated = false
                                pcall(function()
                                    held:Activate()
                                    activated = true
                                end)
                                if not activated then
                                    local gs = findRemote("GunSystem")
                                    if gs then
                                        pcall(function()
                                            if gs:IsA("RemoteEvent") then gs:FireServer(held, nil, "Fire", nil, true, true) else gs:InvokeServer(held, nil, "Fire", nil, true, true) end
                                        end)
                                    end
                                    if LMBRemote then pcall(function() LMBRemote:FireServer() end) end
                                end
                                task.wait(autoFireGunInterval)
                            end
                        end
                    end
                end
                cleanupKite()
                autoFireGunJob = nil
            end)
        end
        notify("自动化", "已开启自动用枪（放风筝模式）")
    else
        if autoFireGunJob then task.cancel(autoFireGunJob); autoFireGunJob = nil end
        notify("自动化", "已关闭自动用枪")
    end
end })

-- ==================== 自动材料（PolyHub 恢复版） ====================
local RecoveredMapItemNames = {
    ["Clock Spider"] = true,
    ["Transmitter"] = true,
    ["Flash Drive"] = true,
    ["Astro Samples"] = true,
    ["X-18"] = true,
    ["The Present"] = true,
}

local function recoveredGetObjectPosition(obj)
    if obj:IsA("Model") then
        if obj.PrimaryPart then return obj.PrimaryPart.Position end
        local ok, pivot = pcall(function() return obj:GetPivot() end)
        return ok and pivot.Position or nil
    elseif obj:IsA("BasePart") then
        return obj.Position
    end
end

local function findNearestMapItem()
    local root = getHRP()
    local transmitterFolder = Workspace:FindFirstChild("Transmitter")
    if not root or not transmitterFolder then return nil, nil end
    local nearest, nearestPrompt, nearestDistance = nil, nil, math.huge
    for _, obj in ipairs(transmitterFolder:GetChildren()) do
        if RecoveredMapItemNames[obj.Name] and (obj:IsA("Model") or obj:IsA("BasePart")) then
            local prompt = obj:FindFirstChildOfClass("ProximityPrompt") or obj:FindFirstChild("ProximityPrompt", true)
            local position = recoveredGetObjectPosition(obj)
            if prompt and position then
                local distance = (position - root.Position).Magnitude
                if distance < nearestDistance then nearest, nearestPrompt, nearestDistance = obj, prompt, distance end
            end
        end
    end
    return nearest, nearestPrompt
end

local function collectMapItem(obj, prompt)
    if not obj or not prompt then return false end
    local root, position = getHRP(), recoveredGetObjectPosition(obj)
    if not root or not position then return false end
    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    root.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
    task.wait(0.2)
    if not prompt.Parent then return false end
    pcall(function() prompt.HoldDuration = 0 end)
    if type(fireproximityprompt) == "function" then
        local ok = pcall(function() fireproximityprompt(prompt) end)
        if ok then return true end
    end
    return false
end

local function startRecoveredMaterialJob()
    if Recovered.currentMaterialJob then return end
    Recovered.currentMaterialJob = task.spawn(function()
        while autoTraceMaterialEnabled do
            if isAstroRunning or isSkillPlaying or isShopping then
                task.wait(0.1)
            else
                local target, prompt = findNearestMapItem()
                if target and prompt then
                    isTeleportingToMaterial = true
                    currentTraceTarget = target
                    collectMapItem(target, prompt)
                    currentTraceTarget = nil
                    isTeleportingToMaterial = false
                    task.wait(0.5)
                else
                    currentTraceTarget = nil
                    isTeleportingToMaterial = false
                    task.wait(0.4)
                end
            end
        end
        Recovered.currentMaterialJob = nil
        currentTraceTarget = nil
        isTeleportingToMaterial = false
    end)
end

Tab3:CreateSection("自动交互材料（恢复版）")
Tab3:CreateDropdown({ Name = "材料白名单（已验证路径）", Options = { "Clock Spider", "Transmitter", "Flash Drive", "Astro Samples", "X-18", "The Present" }, CurrentOption = { "Clock Spider", "Transmitter", "Flash Drive", "Astro Samples", "X-18", "The Present" }, MultipleOptions = true, Flag = "RecoveredMaterialWhitelist", Callback = function(_) end })
Tab3:CreateToggle({ Name = "自动瞬移拾取材料", CurrentValue = false, Flag = "AutoTraceMaterialToggle", Ext = true, Callback = function(Value)
    autoTraceMaterialEnabled = Value
    if Value then
        startRecoveredMaterialJob()
        notify("自动化", "已开启恢复版材料拾取")
    else
        if Recovered.currentMaterialJob then task.cancel(Recovered.currentMaterialJob); Recovered.currentMaterialJob = nil end
        currentTraceTarget = nil
        isTeleportingToMaterial = false
        notify("自动化", "已关闭恢复版材料拾取")
    end
end })

-- ==================== 自动冲水（Flush Damage Aura 恢复路径） ====================
-- 反混淆明确恢复到：Living 近 50 studs -> ProximityPrompt -> parent.Name == lever ->
-- Root CFrame 到 lever、Disabled、HoldDuration=0；最终触发调用未唯一恢复，因此不补猜测。
local autoFlushEnabled, autoFlushJob = false, nil

local function startRecoveredFlush()
    if autoFlushJob then return end
    autoFlushJob = task.spawn(function()
        while autoFlushEnabled do
            pcall(function()
                local character = getCharacter()
                local root = character and character:FindFirstChild("HumanoidRootPart")
                local living = Workspace:FindFirstChild("Living")
                if not root or not living then return end
                for _, model in ipairs(living:GetChildren()) do
                    if model:IsA("Model") then
                        local targetRoot = model:FindFirstChild("HumanoidRootPart")
                        if targetRoot and (root.Position - targetRoot.Position).Magnitude <= 50 then
                            for _, descendant in ipairs(model:GetDescendants()) do
                                if descendant:IsA("ProximityPrompt") and descendant.Parent and descendant.Parent.Name == "lever" and descendant.Enabled then
                                    root.CFrame = descendant.Parent.CFrame
                                    descendant.Enabled = false
                                    descendant.HoldDuration = 0
                                end
                            end
                        end
                    end
                end
            end)
            task.wait(0.1)
        end
        autoFlushJob = nil
    end)
end

Tab3:CreateSection("自动冲水（恢复版）")
Tab3:CreateToggle({ Name = "自动冲水（Flush Aura）", CurrentValue = false, Flag = "AutoFlushToggle", Ext = true, Callback = function(v)
    autoFlushEnabled = v
    if v then startRecoveredFlush(); notify("自动冲水", "已开启恢复路径")
    else if autoFlushJob then task.cancel(autoFlushJob); autoFlushJob = nil end; notify("自动冲水", "已关闭") end
end })

-- ==================== 天文模式 ====================

-- ==================== 天文模式 ====================
local astroSpeed, aJob, aRun = 530, nil, false
local astroHealJob

local function stopA()
    aRun = false
    isAstroRunning = false
    if aJob then task.cancel(aJob); aJob = nil end
    if astroHealJob then task.cancel(astroHealJob); astroHealJob = nil end
    local r = getHRP()
    if r then
        for _, c in ipairs(r:GetChildren()) do
            if c.Name == "ST_Astro_BV" or c.Name == "ST_Astro_BG" then pcall(function() c:Destroy() end) end
        end
    end
    notify("自动化", "天文模式已停止")
end

local function doA()
    local rs = RepStorage
    local buff = findRemote("Buff", 1)
    local vote = findRemote("Vote", 3)
    local ready = findRemote("GetReadyRemote", 3)
    if not vote or not ready then
        notify("天文模式", "必要 Remote 缺失：Vote/GetReadyRemote", 4)
        aRun = false
        return
    end

    if not astroHealJob then
        astroHealJob = task.spawn(function()
            local lastB = 0
            while aRun do
                local c = getCharacter()
                local hum = c and c:FindFirstChildWhichIsA("Humanoid")
                if buff and hum and hum.Parent and hum.Health > 0 and hum.Health <= hum.MaxHealth / 2 and tick() - lastB > 6 then
                    pcall(function()
                        if buff:IsA("RemoteEvent") then buff:FireServer() else buff:InvokeServer() end
                    end)
                    lastB = tick()
                end
                task.wait(0.3)
            end
            astroHealJob = nil
        end)
    end

    local endV = tick() + 10
    while tick() < endV and aRun do
        pcall(function() vote:FireServer("AstroV2") end)
        task.wait(1.2)
    end
    if not aRun then return end

    pcall(function() ready:FireServer("1", true) end)

    -- 保留原脚本的等待逻辑意图：等待 Living 的实际数量，而不是把 pcall 成功当成条件成功。
    local waitStart = tick()
    while tick() - waitStart < 90 and aRun do
        local started = false
        local living = Workspace:FindFirstChild("Living", true)
        if living then
            local count = 0
            for _, d in ipairs(living:GetDescendants()) do
                if d:IsA("Model") and d:FindFirstChildOfClass("Humanoid") then count = count + 1; if count > 3 then break end end
            end
            if count > 3 then started = true end
        end
        if started then break end
        task.wait(1)
    end
    if not aRun then return end

    -- 按要求：保留原有 Astro 固定路线坐标，不改这一项。
    local pts = {
        Vector3.new(-666.88, 296.16, -541.21),
        Vector3.new(490.00, 295.81, -541.63),
        Vector3.new(490.42, 296.16, 487.95),
        Vector3.new(-667.22, 296.21, 488.04),
    }
    local endP, limit, d = Vector3.new(-22.88, 2.71, -1.34), 900, 5

    local function getValidHRP()
        local h = getHRP()
        return h and h.Parent and h or nil
    end

    local function go(targetPos)
        local h = getValidHRP()
        if not h then return end
        local bv = Instance.new("BodyVelocity")
        bv.Name = "ST_Astro_BV"
        bv.MaxForce = Vector3.new(1e8, 1e8, 1e8)
        bv.Velocity = Vector3.zero
        bv.P = 20000
        bv.Parent = h

        local bg = Instance.new("BodyGyro")
        bg.Name = "ST_Astro_BG"
        bg.MaxTorque = Vector3.new(1e8, 1e8, 1e8)
        bg.P = 20000
        bg.CFrame = h.CFrame
        bg.Parent = h

        local lastPos, stuckStart = h.Position, tick()
        local dis = (targetPos - h.Position).Magnitude
        while dis > d and aRun do
            local cur = getValidHRP()
            if not cur then break end
            if cur ~= h then
                pcall(function() bv.Parent = cur end)
                pcall(function() bg.Parent = cur end)
                h = cur
            end
            local delta = targetPos - cur.Position
            if delta.Magnitude > 0.01 then
                bv.Velocity = delta.Unit * astroSpeed
                local look = Vector3.new(delta.X, 0, delta.Z)
                if look.Magnitude > 0 then bg.CFrame = CFrame.lookAt(cur.Position, cur.Position + look.Unit) end
            end
            task.wait(0.03)
            if (cur.Position - lastPos).Magnitude < 0.5 then
                if tick() - stuckStart > 1.5 then break end
            else
                lastPos = cur.Position
                stuckStart = tick()
            end
            dis = (targetPos - cur.Position).Magnitude
        end
        pcall(function() bv:Destroy() end)
        pcall(function() bg:Destroy() end)
    end

    local st = tick()
    while tick() - st < limit and aRun do
        for _, pt in ipairs(pts) do
            go(pt)
            if tick() - st >= limit or not aRun then break end
            task.wait(0.05)
        end
    end

    local finalHRP = getValidHRP()
    if finalHRP then pcall(function() finalHRP.CFrame = CFrame.new(endP) end) end
end

Tab3:CreateSection("天文模式")
Tab3:CreateParagraph({ Title = "使用建议", Content = "建议使用血量高或有回血的小型单位，不支持蜘蛛单位。天文路线按原脚本保留；技能组可继续运行，但移动控制由天文模式占用。" })
Tab3:CreateToggle({ Name = "自动通关天文模式", CurrentValue = false, Flag = "AutoLoopToggle", Ext = true, Callback = function(v)
    if v then
        if aRun then return end
        aRun = true
        isAstroRunning = true
        aJob = task.spawn(function()
            while aRun do
                local ok, err = pcall(doA)
                if not ok then notify("天文模式", "执行异常: " .. tostring(err), 4) end
                if not aRun then break end
                task.wait(5)
            end
            isAstroRunning = false
            aJob = nil
            if astroHealJob then task.cancel(astroHealJob); astroHealJob = nil end
        end)
        notify("自动化", "天文模式开跑")
    else
        stopA()
    end
end })
Tab3:CreateSlider({ Name = "天文模式移动速度", Range = { 100, 1000 }, Increment = 10, CurrentValue = 530, Flag = "AstroSpeedSlider", Callback = function(Value) astroSpeed = Value end })

-- ==================== 功能/Remote 检测 ====================
Tab3:CreateSection("STBB 当前接口检测")
Tab3:CreateButton({ Name = "检测游戏接口", Ext = true, Callback = function()
    local names = {
        "LMB", "MouseStream", "Vote", "GetReadyRemote", "SkipHelicopter",
        "GachaCapsule", "GachaCharacter", "GachaSkins", "Buff",
        "ForChangeCharacter", "ShopSystem", "BuyItemFromShopHourly", "GunSystem",
        "NukeTitanSet", "HeadCaptainOfCCTVSet",
    }
    local okList, missList = {}, {}
    for _, nm in ipairs(names) do
        local r = findRemote(nm, 0.25)
        if r then okList[#okList + 1] = nm .. "[" .. r.ClassName .. "]" else missList[#missList + 1] = nm end
    end
    notify("STBB接口", "找到 " .. tostring(#okList) .. "/" .. tostring(#names) .. " 个", 4)
    print("[STBB接口] FOUND: " .. table.concat(okList, ", "))
    print("[STBB接口] MISSING: " .. (#missList > 0 and table.concat(missList, ", ") or "无"))
end })

-- ==================== 紧急重置 ====================
local function resetAllLocks()
    isSkillPlaying = false
    isCastingSkill = false
    isTeleportingToMaterial = false
    isShopping = false
    combatCooldownUntil = 0
    lastHrpPosition = nil
    _materialTpCounter = _materialTpCounter + (1)
    pcall(recStopPlay)
    pcall(treeRecStopPlay)
    if Recovered.currentFarmTween then pcall(function() Recovered.currentFarmTween:Cancel() end); Recovered.currentFarmTween = nil end
    if autoAttackEnabled and not autoAttackConnection then startAutoAttack() end

    local c = getCharacter()
    local h = c and c:FindFirstChildWhichIsA("Humanoid")
    local hrp = c and c:FindFirstChild("HumanoidRootPart")
    if h then
        pcall(function() h.WalkSpeed = 16 end)
        pcall(function() h.PlatformStand = false end)
        pcall(function() h.JumpPower = 50 end)
        pcall(function() h.UseJumpPower = true end)
    end
    if hrp then
        pcall(function() hrp.Anchored = false end)
        for _, obj in ipairs(hrp:GetChildren()) do
            if obj.Name == "ST_AutoAttack_BV" or obj.Name == "ST_AutoAttack_BG" or obj.Name == "ST_GunKite_BV" or obj.Name == "ST_Astro_BV" or obj.Name == "ST_Astro_BG" then
                pcall(function() obj:Destroy() end)
            end
        end
    end
    notify("重置", "所有脚本状态已重置，可以重新开启功能")
end

Tab3:CreateSection("紧急重置")
Tab3:CreateButton({ Name = "🔧 紧急重置所有状态锁", Ext = true, Callback = resetAllLocks })
Tab3:CreateButton({ Name = "🔧 重置自动战斗连接", Ext = true, Callback = function()
    if autoAttackConnection then autoAttackConnection:Disconnect(); autoAttackConnection = nil end
    if Recovered.currentFarmTween then pcall(function() Recovered.currentFarmTween:Cancel() end); Recovered.currentFarmTween = nil end
    if autoAttackEnabled and not autoAttackConnection then startAutoAttack(); notify("自动战斗", "连接已重建") else notify("自动战斗", "连接已清理，请重新开启自动战斗") end
end })

-- ==================== Tab4 特殊泰坦 ====================
Tab4:CreateSection("特殊泰坦")
local titanRequests = {
    { "升级版泰坦电视", "Upgraded Titan TV", 0 },
    { "升级版泰坦音响", "Upgraded Titan Speaker", 0 },
    { "升级版泰坦摄像", "Upgraded Titan Cameraman", 0 },
    { "时钟泰坦", "Clock Titan", 0 },
    { "G厕所Z", "G-Toilet Z", 0 },
    { "警报泰坦", "Siren Titan", 0 },
    { "大型时钟人", "Large Clock Man", 0 },
    { "天文大电视", "Astro Large TV man", 1 },
}
for _, item in ipairs(titanRequests) do
    local label, name, arg = item[1], item[2], item[3]
    Tab4:CreateButton({ Name = label, Ext = true, Callback = function()
        local r = findRemote("ForChangeCharacter")
        if not r then notify("角色切换", "找不到 ForChangeCharacter"); return end
        local ok, err = pcall(function()
            if r:IsA("RemoteEvent") then r:FireServer(name, arg) else r:InvokeServer(name, arg) end
        end)
        task.delay(0.5, refreshCharacterState)
        notify("角色切换", ok and ("已发送: " .. label) or ("失败: " .. tostring(err)), 3)
    end })
end

Tab4:CreateSection("自动请求")
local autoSpecialRequestEnabled, autoSpecialRequestJob, autoSpecialRequestInterval = false, nil, 3
local function findSpecialTitanRequest()
    local char = getCharacter()
    if char then
        local held = char:FindFirstChild("SpecialTitan-Request", true)
        if held and held:IsA("Tool") then return held, true end
    end
    local bp = LP:FindFirstChild("Backpack")
    if bp then
        local req = bp:FindFirstChild("SpecialTitan-Request", true)
        if req and req:IsA("Tool") then return req, false end
    end
    return nil, false
end
local function equipSpecialRequest(tool)
    if not tool then return false end
    local hum = getHumanoid()
    if not hum then return false end
    if tool.Parent == getCharacter() then return true end
    local ok = pcall(function() hum:EquipTool(tool) end)
    return ok and tool.Parent == getCharacter()
end
Tab4:CreateSlider({ Name = "请求间隔 (秒)", Range = { 1, 30 }, Increment = 1, CurrentValue = 3, Flag = "SpecialReqInterval", Callback = function(v) autoSpecialRequestInterval = v end })
Tab4:CreateToggle({ Name = "自动使用特殊泰坦请求", CurrentValue = false, Flag = "AutoSpecialRequestToggle", Ext = true, Callback = function(v)
    autoSpecialRequestEnabled = v
    if v then
        if not autoSpecialRequestJob then
            autoSpecialRequestJob = task.spawn(function()
                while autoSpecialRequestEnabled do
                    local tool, isHeld = findSpecialTitanRequest()
                    if tool then
                        if not isHeld then equipSpecialRequest(tool) end
                        task.wait(0.1)
                        pcall(function() tool:Activate() end)
                    end
                    task.wait(autoSpecialRequestInterval)
                end
                autoSpecialRequestJob = nil
            end)
        end
        notify("自动化", "已开启自动特殊泰坦请求")
    else
        if autoSpecialRequestJob then task.cancel(autoSpecialRequestJob); autoSpecialRequestJob = nil end
        notify("自动化", "已关闭自动特殊泰坦请求")
    end
end })

-- ==================== Tab5 商店 ====================
local function getPlayerGui() return LP:FindFirstChild("PlayerGui") end
Tab5:CreateToggle({ Name = "直升机商店", CurrentValue = false, Flag = "HeliShopToggle", Ext = true, Callback = function(Value)
    local pg = getPlayerGui(); local target = pg and pg:FindFirstChild("003-A")
    if target then pcall(function() target.Enabled = Value end) end
end })
Tab5:CreateToggle({ Name = "泰坦电视2.0装备商店", CurrentValue = false, Flag = "TVShopToggle", Ext = true, Callback = function(Value)
    local pg = getPlayerGui(); local target = pg and pg:FindFirstChild("UpgradeTVShop")
    if target then pcall(function() target.Enabled = Value end) end
end })
Tab5:CreateToggle({ Name = "泰坦音响2.0装备商店", CurrentValue = false, Flag = "UTSMShopToggle", Ext = true, Callback = function(Value)
    local pg = getPlayerGui(); local target = pg and pg:FindFirstChild("ConfirmUTSM")
    if target then pcall(function() target.Enabled = Value end) end
end })
Tab5:CreateToggle({ Name = "泰坦监控2.0装备商店", CurrentValue = false, Flag = "CameraShopToggle", Ext = true, Callback = function(Value)
    local pg = getPlayerGui(); local target = pg and pg:FindFirstChild("UpgradeCameraShop")
    if target then pcall(function() target.Enabled = Value end) end
end })
Tab5:CreateButton({ Name = "导弹人装备升级", Ext = true, Callback = function()
    local nukeTitanSet = findRemote("NukeTitanSet")
    if nukeTitanSet then
        pcall(function()
            if nukeTitanSet:IsA("RemoteEvent") then nukeTitanSet:FireServer("BuyC4s") else nukeTitanSet:InvokeServer("BuyC4s") end
        end)
    end
end })

local SHOP_MAP = {
    ["耳机"] = "HeadPhone", ["泰坦请求"] = "Titan-Request", ["特殊泰坦请求"] = "SpecialTitan-Request", ["音响请求"] = "Speaker Request",
    ["喷气背包"] = "Jetpack", ["镜头"] = "Lens", ["手雷"] = "Grenade", ["鱼叉枪"] = "Harpoon Gun", ["霰弹枪"] = "Shot Gun", ["脉冲步枪"] = "Pulse Rifle",
    ["射击鱼叉枪"] = "Shot Harpoon Gun", ["EPD"] = "EPD", ["小型激光枪"] = "Small Laser Gun", ["电击狙击枪"] = "Tazer Sniper",
    ["电击枪"] = "Tazer Gun", ["天文冲击枪"] = "Astro Blaster",
}
local SHOP_OPTIONS = { "耳机", "泰坦请求", "特殊泰坦请求", "音响请求", "喷气背包", "镜头", "手雷", "鱼叉枪", "霰弹枪", "脉冲步枪", "射击鱼叉枪", "EPD", "小型激光枪", "电击狙击枪", "电击枪", "天文冲击枪" }
local shopSelected, shopAutoEnabled, shopAutoJob, shopAutoInterval, shopSavedPos = {}, false, nil, 1.5, nil

Tab5:CreateSection("商店物品购买")
Tab5:CreateDropdown({ Name = "要购买的物品（可多选）", Options = SHOP_OPTIONS, CurrentOption = {}, MultipleOptions = true, Flag = "ShopBuyList", Callback = function(selected)
    shopSelected = {}
    if type(selected) == "table" then for _, cn in ipairs(selected) do local en = SHOP_MAP[cn]; if en then shopSelected[en] = true end end end
end })
Tab5:CreateSlider({ Name = "购买间隔 (秒)", Range = { 0.5, 10 }, Increment = 0.5, CurrentValue = 1.5, Flag = "ShopBuyInterval", Callback = function(v) shopAutoInterval = v end })

local SHOP_PRICE_MAP = {
    HeadPhone = 500,
    ["Titan-Request"] = 1000,
}

local SHOP_CN = {}
for cn, en in pairs(SHOP_MAP) do SHOP_CN[en] = cn end

local function trySelectShopItem(itemName)
    local pg = LP:FindFirstChild("PlayerGui")
    local shopGui = pg and pg:FindFirstChild("003-A")
    if not shopGui then return false end
    local localized = SHOP_CN[itemName] or itemName
    for _, obj in ipairs(shopGui:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            local textValue = ""
            if obj:IsA("TextButton") then textValue = tostring(obj.Text or "") end
            local attr = tostring(obj:GetAttribute("ToolName") or "")
            local hay = (textValue .. " " .. attr .. " " .. obj.Name):lower()
            local looksLikeBuyButton = hay:find("buy", 1, true) or hay:find("purchase", 1, true) or hay:find("购买", 1, true)
            if not looksLikeBuyButton and (hay:find(localized:lower(), 1, true) or hay:find(itemName:lower(), 1, true)) then
                local ok = pcall(function() obj:Activate() end)
                if ok then task.wait(0.2); return true end
            end
        end
    end
    return false
end

local function findHelicopterShopPart()
    local roots = {
        Workspace:FindFirstChild("HelicopterShop", true),
        Workspace:FindFirstChild("Helicopter", true),
        Workspace:FindFirstChild("Shop", true),
    }
    for _, hs in ipairs(roots) do
        if hs then
            local sp = hs:FindFirstChild("ShopPart", true)
            if sp and sp:IsA("BasePart") then return sp end
            local xdd = hs:FindFirstChild("ShopXDD", true)
            if xdd then
                for _, d in ipairs(xdd:GetDescendants()) do if d:IsA("BasePart") then return d end end
            end
            for _, d in ipairs(hs:GetDescendants()) do
                if d:IsA("BasePart") and (d.Name:lower():find("shop", 1, true) or d.Name:lower():find("spawn", 1, true)) then return d end
            end
        end
    end
    return nil
end

local function getItemPrice(itemName)
    local pg = getPlayerGui()
    local shopGui = pg and pg:FindFirstChild("003-A")
    if not shopGui then return SHOP_PRICE_MAP[itemName] end

    pcall(function() trySelectShopItem(itemName) end)
    local directNames = { "ItemPrice", "Price", "Cost", "ItemCost", "CenCost" }
    for _, nm in ipairs(directNames) do
        local label = shopGui:FindFirstChild(nm, true)
        if label and typeof(label.Text) == "string" then
            local n = parseNumberText(label.Text)
            if n > 0 then return n end
        end
    end

    local localized = SHOP_CN[itemName] or itemName
    local found = nil
    pcall(function()
        for _, obj in ipairs(shopGui:GetDescendants()) do
            if obj:IsA("TextLabel") or obj:IsA("TextButton") then
                local nm = tostring(obj.Name or ""):lower()
                local text = tostring(obj.Text or "")
                local hay = (nm .. " " .. text):lower()
                if (hay:find("price", 1, true) or hay:find("cost", 1, true) or hay:find("cen", 1, true) or hay:find("coin", 1, true) or hay:find("购买", 1, true)) then
                    local n = parseNumberText(text)
                    if n > 0 then found = n; break end
                end
            end
        end
    end)
    return found or SHOP_PRICE_MAP[itemName]
end

local function teleportToShopAndOpen()
    local hrp = getHRP()
    local shopPart = findHelicopterShopPart()
    if not hrp or not shopPart then return false end
    if not shopSavedPos then shopSavedPos = hrp.CFrame end
    local targetPos = Vector3.new(shopPart.Position.X, hrp.Position.Y, shopPart.Position.Z)
    for _ = 1, 3 do pcall(function() hrp.CFrame = CFrame.new(targetPos) end); task.wait(0.1) end
    task.wait(0.6)
    local pg = LP:FindFirstChild("PlayerGui")
    local shopGui = pg and pg:FindFirstChild("003-A")
    if shopGui then setGuiOpen(shopGui, true) end
    task.wait(0.3)
    return true
end

local function returnToSavedPos()
    if not shopSavedPos then return end
    local hrp = getHRP()
    if hrp then
        pcall(function() hrp.CFrame = shopSavedPos end)
        task.wait(0.2)
        pcall(function() hrp.CFrame = shopSavedPos end)
    end
    shopSavedPos = nil
end

local shopAutoToggle
local suppressShopUiCallback = false
local function stopShopAuto(reason, returnPos)
    shopAutoEnabled = false
    isShopping = false
    if returnPos ~= false then returnToSavedPos() end
    suppressShopUiCallback = true
    pcall(function() if shopAutoToggle then shopAutoToggle:Set(false) end end)
    suppressShopUiCallback = false
    shopAutoJob = nil
    if reason then notify("商店", reason, 3) end
end

shopAutoToggle = Tab5:CreateToggle({
    Name = "自动购买（钱够且降落才去）", CurrentValue = false, Flag = "ShopAutoBuyToggle", Ext = true,
    Callback = function(v)
        if suppressShopUiCallback then return end
        shopAutoEnabled = v
        if not v then
            if shopAutoJob then task.cancel(shopAutoJob); shopAutoJob = nil end
            isShopping = false
            returnToSavedPos()
            notify("商店", "已关闭自动购买")
            return
        end

        if shopAutoJob then return end
        shopAutoJob = task.spawn(function()
            if isAstroRunning then stopShopAuto("天文模式运行中"); return end

            local remaining = {}
            for en in pairs(shopSelected) do remaining[#remaining + 1] = en end
            if #remaining == 0 then stopShopAuto("未勾选物品"); return end
            table.sort(remaining)

            isShopping = true
            local failedAttempts = 0
            while shopAutoEnabled and #remaining > 0 do
                local en = remaining[1]
                local shouldSkip = false

                local price = getItemPrice(en)
                local money = getMapMoney()
                -- 能读到价格和金钱时执行“钱够才买”；新版界面无法读价格时，
                -- 不再直接停掉整个自动购买，而是交给服务端做余额校验。
                if price and money >= 0 and money < price then
                    task.wait(1)
                    shouldSkip = true
                end

                if not shouldSkip then
                    while shopAutoEnabled do
                        local shopPart = findHelicopterShopPart()
                        if shopPart and shopPart.Parent and shopPart.AssemblyLinearVelocity.Magnitude < 5 then break end
                        task.wait(1)
                    end
                    if not shopAutoEnabled then break end

                    local opened = teleportToShopAndOpen()
                    if not opened then
                        failedAttempts = failedAttempts + (1)
                        if failedAttempts >= 3 then
                            stopShopAuto("连续 3 次找不到直升机商店")
                            return
                        end
                        task.wait(1)
                        shouldSkip = true
                    end
                end

                if not shouldSkip then
                    local before = getMapMoney()
                    local ok = false
                    if en == "Speaker Request" then
                        local cinema = findRemote("ChangeToCinema", 1.5)
                        if cinema then ok = pcall(function()
                            if cinema:IsA("RemoteEvent") then cinema:FireServer() else cinema:InvokeServer() end
                        end) end
                    else
                        local shop = findRemote("ShopSystem", 1.5)
                        if shop then ok = pcall(function()
                            if shop:IsA("RemoteEvent") then shop:FireServer("Buy", en) else shop:InvokeServer("Buy", en) end
                        end) end
                    end
                    task.wait(0.8)
                    local after = getMapMoney()
                    if ok then
                        table.remove(remaining, 1)
                        failedAttempts = 0
                        if before >= 0 and after >= 0 and after < before then
                            notify("商店", "已购买: " .. en, 2)
                        else
                            notify("商店", "已发送购买请求: " .. en, 2)
                        end
                    else
                        failedAttempts = failedAttempts + (1)
                        if failedAttempts >= 3 then
                            stopShopAuto("购买失败 3 次: " .. en)
                            return
                        end
                        notify("商店", "购买未确认，重试中: " .. en, 2)
                    end

                    task.wait(shopAutoInterval)
                end
            end

            if shopAutoEnabled then stopShopAuto("全部购买完成") end
        end)
        notify("商店", "已开启自动购买，实时监测中...")
    end,
})

-- ==================== Tab6 付费功能 ====================
-- 按要求：保留原来的 Kaijin 付费功能，不在本次修改中改变其逻辑。
Tab6:CreateButton({ Name = "一刀修罗", Ext = true, Callback = function()
    if not checkIsWhitelisted() then notify("付费功能", "您无权使用此功能，仅限白名单用户", 3); return end
    if not integrityCheck() then notify("安全警告", "检测到脚本代码被篡改，功能已锁定！", 5); return end
    local pg = LP:FindFirstChild("PlayerGui")
    local existingUI = pg and pg:FindFirstChild("SkillSwitchUI")
    if existingUI then
        existingUI:Destroy()
        notify("付费功能", "已关闭一刀修罗界面")
        return
    end
    if not pg then notify("付费功能", "找不到 PlayerGui"); return end

    local ScreenUI = Instance.new("ScreenGui")
    ScreenUI.Name = "SkillSwitchUI"
    ScreenUI.ResetOnSpawn = false
    ScreenUI.IgnoreGuiInset = true
    ScreenUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenUI.Parent = pg

    local SkillBtn = Instance.new("TextButton")
    SkillBtn.Size = UDim2.new(0, 160, 0, 50)
    SkillBtn.Position = UDim2.new(0.02, 0, 0.4, 0)
    SkillBtn.BackgroundColor3 = Color3.fromRGB(20, 120, 220)
    SkillBtn.TextColor3 = Color3.new(1, 1, 1)
    SkillBtn.Font = Enum.Font.SourceSansBold
    SkillBtn.TextSize = 18
    SkillBtn.Text = "开启一刀修罗"
    SkillBtn.Active = true
    pcall(function() SkillBtn.Draggable = true end)
    SkillBtn.Parent = ScreenUI

    local isDragging, dragStart, startPos = false, nil, nil
    if UIS then
        SkillBtn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch then
                isDragging = true
                dragStart = input.Position
                startPos = SkillBtn.AbsolutePosition
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if isDragging and input.UserInputType == Enum.UserInputType.TouchMovement then
                local delta = input.Position - dragStart
                SkillBtn.Position = UDim2.new(0, startPos.X + delta.X, 0, startPos.Y + delta.Y)
            end
        end)
        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch then isDragging = false end
        end)
    end

    local SkillSwitch = false
    local skillJob
    local function StopSkill()
        SkillSwitch = false
        if skillJob then task.cancel(skillJob); skillJob = nil end
    end
    local function RunSkill()
        if skillJob then task.cancel(skillJob) end
        skillJob = task.spawn(function()
            while SkillSwitch do
                local r = findRemote("HeadCaptainOfCCTVSet")
                if r and r:IsA("RemoteEvent") then
                    local args = { { Skill = "Kaijin" } }
                    pcall(function() r:FireServer(table.unpack(args)) end)
                end
                task.wait(0.3)
            end
            skillJob = nil
        end)
    end

    SkillBtn.MouseButton1Click:Connect(function()
        SkillSwitch = not SkillSwitch
        if SkillSwitch then
            SkillBtn.BackgroundColor3 = Color3.fromRGB(30, 180, 60)
            SkillBtn.Text = "关闭一刀修罗"
            RunSkill()
            notify("功能提示", "已开启一刀修罗")
        else
            StopSkill()
            SkillBtn.BackgroundColor3 = Color3.fromRGB(20, 120, 220)
            SkillBtn.Text = "开启一刀修罗"
            notify("功能提示", "已关闭一刀修罗")
        end
    end)

    ScreenUI.Destroying:Connect(StopSkill)
    notify("付费功能", "已开启一刀修罗界面")
end })

-- ==================== 角色变化清理 ====================
pcall(function()
    LP.CharacterAdded:Connect(function(newCharacter)
        task.defer(function()
            refreshCharacterState()
            hookAutoRebirthCharacter(newCharacter)
            currentTarget = nil
            cachedEnemy = nil
            lastHrpPosition = nil
            combatCooldownUntil = tick() + 1
            if Recovered.currentFarmTween then pcall(function() Recovered.currentFarmTween:Cancel() end); Recovered.currentFarmTween = nil end
            if hNameEnabled then hideNameOnly() end
        end)
    end)
end)

-- ==================== 启动提示 ====================
task.spawn(function()
    notify("已加载封锁战线脚本", "修正版 v4", 3)
    task.wait(3)
    notify("修复", "技能回放/自动战斗/材料/商店等已重构", 3)
    task.wait(3)
    notify("提示", "Astro 固定坐标按要求保留未改", 3)
end)

print("[ST脚本] 所有标签页创建完成（修正版 v4）！")
