--[[
    Wraith v2.0  |  Universal Lock-On • Silent Aim • ESP
    Snowfall UI  |  every toggle is wired to real code
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local Lighting           = game:GetService("Lighting")
local Camera             = workspace.CurrentCamera
local LocalPlayer        = Players.LocalPlayer

-- ══════════════════════════════════════════════════════════════════════════
--  CONFIG
-- ══════════════════════════════════════════════════════════════════════════
local cfg = {
    -- aimbot
    aimEnabled      = false,
    fovRadius       = 120,
    fovVisible      = true,
    aimSpeed        = 6,        -- 0 = instant, 20 = very slow
    aimPart         = "Head",
    skipTeammates   = false,
    onlyVisible     = true,
    holdToAim       = false,    -- hold RMB instead of toggle

    -- advanced
    recoilControl   = false,
    smartSmooth     = false,    -- eases in/out with distance to target
    naturalMove     = false,    -- adds organic sine drift
    prediction      = false,
    predictAmount   = 12,       -- /100 seconds of velocity lead
    randomOffset    = false,
    offsetStrength  = 2,

    -- silent aim
    silentAim       = false,
    silentFovOnly   = true,     -- only redirect if target inside FOV

    -- esp
    espEnabled      = true,
    espBoxes        = true,
    espNames        = true,
    espHealth       = true,
    espDistance     = true,
    espTracers      = false,
    espTeamCheck    = false,
    espMaxDist      = 1000,
    chams           = false,
    fullbright      = false,

    -- ui
    snow            = true,
    snowCount       = 45,
    rainbowAccent   = false,

    -- keys
    lockKey         = Enum.KeyCode.Q,
    guiKey          = Enum.KeyCode.RightShift,

    -- colors
    cFov      = Color3.fromRGB(150, 110, 255),
    cEnemy    = Color3.fromRGB(255, 75, 75),
    cFriend   = Color3.fromRGB(75, 255, 130),
    cLocked   = Color3.fromRGB(255, 215, 60),
    cTracer   = Color3.fromRGB(180, 150, 255),
}

-- ══════════════════════════════════════════════════════════════════════════
--  STATE
-- ══════════════════════════════════════════════════════════════════════════
local lockedTarget = nil
local espObjects   = {}
local chamObjects  = {}
local lightBackup  = nil
local aimHeld      = false

-- Drawing fallback so the script never hard-errors on weak executors
local hasDrawing = pcall(function() local d = Drawing.new("Circle") d:Remove() end)
local function newDraw(kind, props)
    if not hasDrawing then
        return setmetatable({}, {__index = function() return nil end, __newindex = function() end,
            __call = function() end})
    end
    local d = Drawing.new(kind)
    for k, v in pairs(props or {}) do d[k] = v end
    return d
end

local fovCircle = newDraw("Circle", {
    Radius = cfg.fovRadius, Color = cfg.cFov, Filled = false,
    Thickness = 1.5, Visible = false, NumSides = 72, Transparency = 0.85,
})

-- ══════════════════════════════════════════════════════════════════════════
--  HELPERS
-- ══════════════════════════════════════════════════════════════════════════
local function getChar(p) return p and p.Character end
local function getHum(p)
    local c = getChar(p)
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot(p)
    local c = getChar(p)
    return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart)
end
local function isAlive(p)
    local h = getHum(p)
    return h ~= nil and h.Health > 0
end
local function isFriendly(p)
    return p.Team ~= nil and LocalPlayer.Team ~= nil and p.Team == LocalPlayer.Team
end

local function worldToVP(pos)
    local ok, sp = pcall(Camera.WorldToViewportPoint, Camera, pos)
    if ok then return Vector2.new(sp.X, sp.Y), sp.Z > 0 end
    return Vector2.zero, false
end

local function screenCenter()
    return Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y * 0.5)
end

-- resolve the configured aim part, with sensible fallbacks for R6/R15
local R6_MAP = {
    UpperTorso = "Torso", LowerTorso = "Torso",
    LeftUpperArm = "Left Arm", RightUpperArm = "Right Arm",
    LeftUpperLeg = "Left Leg", RightUpperLeg = "Right Leg",
}
local function getAimPart(p)
    local c = getChar(p)
    if not c then return nil end
    return c:FindFirstChild(cfg.aimPart)
        or (R6_MAP[cfg.aimPart] and c:FindFirstChild(R6_MAP[cfg.aimPart]))
        or c:FindFirstChild("HumanoidRootPart")
        or c:FindFirstChild("Head")
end

-- line of sight test
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
local function hasLOS(p, part)
    if not part then return false end
    local myChar = getChar(LocalPlayer)
    losParams.FilterDescendantsInstances = {myChar, Camera}
    local origin = Camera.CFrame.Position
    local dir = part.Position - origin
    local res = workspace:Raycast(origin, dir, losParams)
    if not res then return true end
    return res.Instance:IsDescendantOf(getChar(p))
end

-- final aim position: base + prediction + noise + random offset
local noiseSeed = math.random() * 1000
local function aimPosition(p)
    local part = getAimPart(p)
    if not part then return nil end
    local pos = part.Position

    if cfg.prediction then
        local vel = part.AssemblyLinearVelocity
        if vel and vel.Magnitude > 0.1 then
            pos = pos + vel * (cfg.predictAmount / 100)
        end
    end

    if cfg.naturalMove then
        local t = os.clock()
        pos = pos + Vector3.new(
            math.sin(t * 1.7 + noiseSeed) * 0.35,
            math.sin(t * 2.3 + noiseSeed) * 0.22,
            math.cos(t * 1.1 + noiseSeed) * 0.35
        )
    end

    if cfg.randomOffset then
        local s = cfg.offsetStrength * 0.15
        pos = pos + Vector3.new(
            (math.random() - 0.5) * s,
            (math.random() - 0.5) * s,
            (math.random() - 0.5) * s
        )
    end

    return pos
end

local function isValidTarget(p)
    if p == LocalPlayer or not isAlive(p) then return false end
    if cfg.skipTeammates and isFriendly(p) then return false end
    local part = getAimPart(p)
    if not part then return false end
    if cfg.onlyVisible and not hasLOS(p, part) then return false end
    return true
end

local function getClosestInFOV()
    local center, best, bestDist = screenCenter(), nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if isValidTarget(p) then
            local part = getAimPart(p)
            local sp, vis = worldToVP(part.Position)
            if vis then
                local d = (sp - center).Magnitude
                if d <= cfg.fovRadius and d < bestDist then
                    best, bestDist = p, d
                end
            end
        end
    end
    return best
end

-- target used by silent aim (independent of the camera lock)
local function silentTarget()
    if lockedTarget and isAlive(lockedTarget) then return lockedTarget end
    if not cfg.silentFovOnly then
        local center, best, bestDist = screenCenter(), nil, math.huge
        for _, p in ipairs(Players:GetPlayers()) do
            if isValidTarget(p) then
                local sp, vis = worldToVP(getAimPart(p).Position)
                if vis then
                    local d = (sp - center).Magnitude
                    if d < bestDist then best, bestDist = p, d end
                end
            end
        end
        return best
    end
    return getClosestInFOV()
end

-- ══════════════════════════════════════════════════════════════════════════
--  SILENT AIM  (namecall hook — redirects raycasts to the target)
-- ══════════════════════════════════════════════════════════════════════════
do
    local function g(name)
        local ok, v = pcall(function() return getfenv()[name] end)
        return (ok and type(v) == "function") and v or nil
    end
    local hookmm = g("hookmetamethod")
    local getnc  = g("getnamecallmethod")
    local ckcall = g("checkcaller")

    if hookmm and getnc then
        local ok, err = pcall(function()
            local old
            old = hookmm(game, "__namecall", function(self, ...)
                local m = getnc()
                local safe = (not ckcall) or (not ckcall())

                if cfg.silentAim and safe then
                    local tgt = silentTarget()
                    local pos = tgt and aimPosition(tgt)
                    if pos then
                        if m == "FindPartOnRayWithIgnoreList"
                        or m == "FindPartOnRayWithWhitelist"
                        or m == "FindPartOnRay" then
                            local a = {...}
                            local ray = a[1]
                            if typeof(ray) == "Ray" then
                                a[1] = Ray.new(ray.Origin,
                                    (pos - ray.Origin).Unit * ray.Direction.Magnitude)
                                return old(self, unpack(a))
                            end
                        elseif m == "Raycast" then
                            local a = {...}
                            if typeof(a[1]) == "Vector3" and typeof(a[2]) == "Vector3" then
                                a[2] = (pos - a[1]).Unit * a[2].Magnitude
                                return old(self, unpack(a))
                            end
                        end
                    end
                end
                return old(self, ...)
            end)
        end)
        if not ok then warn("[Wraith] silent aim hook failed: " .. tostring(err)) end
    else
        warn("[Wraith] executor lacks hookmetamethod — silent aim disabled")
    end
end

-- ══════════════════════════════════════════════════════════════════════════
--  ESP
-- ══════════════════════════════════════════════════════════════════════════
local function createESP(p)
    if espObjects[p] or p == LocalPlayer then return end
    espObjects[p] = {
        outline = newDraw("Square", {Visible=false, Thickness=3,   Filled=false, Color=Color3.new(0,0,0), Transparency=0.6}),
        box     = newDraw("Square", {Visible=false, Thickness=1,   Filled=false}),
        name    = newDraw("Text",   {Visible=false, Size=13, Center=true, Outline=true, Font=2, Color=Color3.new(1,1,1)}),
        healthB = newDraw("Square", {Visible=false, Thickness=1,   Filled=true, Color=Color3.fromRGB(15,15,20)}),
        health  = newDraw("Square", {Visible=false, Thickness=1,   Filled=true}),
        dist    = newDraw("Text",   {Visible=false, Size=11, Center=true, Outline=true, Font=2, Color=Color3.fromRGB(190,190,210)}),
        tracer  = newDraw("Line",   {Visible=false, Thickness=1,   Transparency=0.7}),
    }
end

local function hideESP(obj)
    for _, d in pairs(obj) do pcall(function() d.Visible = false end) end
end

local function removeESP(p)
    local obj = espObjects[p]
    if obj then
        for _, d in pairs(obj) do pcall(function() d:Remove() end) end
        espObjects[p] = nil
    end
    if chamObjects[p] then chamObjects[p]:Destroy() chamObjects[p] = nil end
end

-- chams via Highlight
local function updateChams()
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LocalPlayer then continue end
        local want = cfg.chams and cfg.espEnabled and isAlive(p)
            and not (cfg.espTeamCheck and isFriendly(p))
        local c = getChar(p)

        if want and c then
            local h = chamObjects[p]
            if not h or h.Parent ~= c then
                if h then h:Destroy() end
                h = Instance.new("Highlight")
                h.FillTransparency = 0.55
                h.OutlineTransparency = 0
                h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                h.Parent = c
                chamObjects[p] = h
            end
            local col = (p == lockedTarget) and cfg.cLocked
                or (isFriendly(p) and cfg.cFriend or cfg.cEnemy)
            h.FillColor = col
            h.OutlineColor = col
        elseif chamObjects[p] then
            chamObjects[p]:Destroy()
            chamObjects[p] = nil
        end
    end
end

local function updateESP()
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LocalPlayer then continue end
        if not espObjects[p] then createESP(p) end
        local obj = espObjects[p]

        if not (cfg.espEnabled and isAlive(p)) then hideESP(obj) continue end
        if cfg.espTeamCheck and isFriendly(p) then hideESP(obj) continue end

        local c, root = getChar(p), getRoot(p)
        if not (c and root) then hideESP(obj) continue end

        local dist3D = (root.Position - Camera.CFrame.Position).Magnitude
        if dist3D > cfg.espMaxDist then hideESP(obj) continue end

        -- project character bounds
        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        local anyVis = false
        for _, part in ipairs(c:GetChildren()) do
            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                local sz = part.Size * 0.5
                for _, o in ipairs({
                    Vector3.new( sz.X,  sz.Y,  sz.Z), Vector3.new(-sz.X,  sz.Y,  sz.Z),
                    Vector3.new( sz.X, -sz.Y,  sz.Z), Vector3.new(-sz.X, -sz.Y,  sz.Z),
                    Vector3.new( sz.X,  sz.Y, -sz.Z), Vector3.new(-sz.X,  sz.Y, -sz.Z),
                    Vector3.new( sz.X, -sz.Y, -sz.Z), Vector3.new(-sz.X, -sz.Y, -sz.Z),
                }) do
                    local sp, vis = worldToVP(part.CFrame:PointToWorldSpace(o))
                    if vis then
                        anyVis = true
                        minX = math.min(minX, sp.X) maxX = math.max(maxX, sp.X)
                        minY = math.min(minY, sp.Y) maxY = math.max(maxY, sp.Y)
                    end
                end
            end
        end
        if not anyVis then hideESP(obj) continue end

        local col = (p == lockedTarget) and cfg.cLocked
            or (isFriendly(p) and cfg.cFriend or cfg.cEnemy)
        local pad = 3
        local pos  = Vector2.new(minX - pad, minY - pad)
        local size = Vector2.new((maxX - minX) + pad*2, (maxY - minY) + pad*2)

        obj.outline.Visible  = cfg.espBoxes
        obj.outline.Position = pos - Vector2.new(1, 1)
        obj.outline.Size     = size + Vector2.new(2, 2)

        obj.box.Visible  = cfg.espBoxes
        obj.box.Color    = col
        obj.box.Position = pos
        obj.box.Size     = size

        obj.name.Visible  = cfg.espNames
        obj.name.Text     = p.DisplayName
        obj.name.Color    = col
        obj.name.Position = Vector2.new((minX + maxX) * 0.5, pos.Y - 16)

        local hum = getHum(p)
        local hp  = hum and math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1) or 0
        obj.healthB.Visible  = cfg.espHealth
        obj.healthB.Position = Vector2.new(pos.X - 6, pos.Y)
        obj.healthB.Size     = Vector2.new(3, size.Y)
        obj.health.Visible   = cfg.espHealth
        obj.health.Color     = Color3.fromRGB(math.floor((1 - hp) * 255), math.floor(hp * 220) + 35, 60)
        obj.health.Position  = Vector2.new(pos.X - 6, pos.Y + size.Y * (1 - hp))
        obj.health.Size      = Vector2.new(3, size.Y * hp)

        obj.dist.Visible  = cfg.espDistance
        obj.dist.Text     = string.format("%dm", dist3D)
        obj.dist.Position = Vector2.new((minX + maxX) * 0.5, pos.Y + size.Y + 3)

        obj.tracer.Visible = cfg.espTracers
        if cfg.espTracers then
            local sp, vis = worldToVP(root.Position)
            obj.tracer.From  = Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y)
            obj.tracer.To    = vis and sp or obj.tracer.From
            obj.tracer.Color = col
        end
    end
end

-- ══════════════════════════════════════════════════════════════════════════
--  FULLBRIGHT
-- ══════════════════════════════════════════════════════════════════════════
local function setFullbright(on)
    if on then
        if not lightBackup then
            lightBackup = {
                Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
                FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
            }
        end
        Lighting.Brightness      = 2
        Lighting.ClockTime       = 14
        Lighting.FogEnd          = 1e6
        Lighting.GlobalShadows   = false
        Lighting.Ambient         = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient  = Color3.fromRGB(178, 178, 178)
    elseif lightBackup then
        for k, v in pairs(lightBackup) do Lighting[k] = v end
        lightBackup = nil
    end
end

-- ══════════════════════════════════════════════════════════════════════════
--  AIM LOOP
-- ══════════════════════════════════════════════════════════════════════════
local lastPitch = Camera.CFrame:ToEulerAnglesYXZ()

RunService.RenderStepped:Connect(function()
    -- FOV circle
    fovCircle.Position = screenCenter()
    fovCircle.Radius   = cfg.fovRadius
    fovCircle.Visible  = cfg.fovVisible and (cfg.aimEnabled or cfg.silentAim)
    fovCircle.Color    = cfg.rainbowAccent
        and Color3.fromHSV((os.clock() * 0.15) % 1, 0.6, 1) or cfg.cFov

    -- drop dead / invalid targets
    if lockedTarget and not isAlive(lockedTarget) then lockedTarget = nil end

    -- recoil control: cancel upward camera drift we didn't ask for
    if cfg.recoilControl then
        local pitch = select(2, Camera.CFrame:ToEulerAnglesYXZ())
        local delta = pitch - lastPitch
        if delta > 0.0015 then   -- kicked up
            local cf = Camera.CFrame
            Camera.CFrame = cf * CFrame.Angles(-delta * 0.75, 0, 0)
        end
        lastPitch = select(2, Camera.CFrame:ToEulerAnglesYXZ())
    else
        lastPitch = select(2, Camera.CFrame:ToEulerAnglesYXZ())
    end

    -- camera lock
    local engaged = cfg.aimEnabled and (not cfg.holdToAim or aimHeld)
    if engaged and lockedTarget then
        local pos = aimPosition(lockedTarget)
        if pos then
            local goal = CFrame.new(Camera.CFrame.Position, pos)
            local alpha
            if cfg.aimSpeed <= 0 then
                alpha = 1
            else
                alpha = math.clamp(1 - (cfg.aimSpeed / 21), 0.02, 1)
                if cfg.smartSmooth then
                    -- ease harder when far from the target, gentler when close
                    local sp = worldToVP(pos)
                    local off = (sp - screenCenter()).Magnitude
                    alpha = alpha * math.clamp(off / math.max(cfg.fovRadius, 1), 0.25, 1.6)
                    alpha = math.clamp(alpha, 0.02, 1)
                end
            end
            Camera.CFrame = Camera.CFrame:Lerp(goal, alpha)
        end
    end

    updateESP()
    updateChams()
end)

-- ══════════════════════════════════════════════════════════════════════════
--  GUI
-- ══════════════════════════════════════════════════════════════════════════
local searchIndex = {}   -- {frame = , text = }

local function buildGui()
    local prev = LocalPlayer.PlayerGui:FindFirstChild("WraithUI")
    if prev then prev:Destroy() end

    local C = {
        bg      = Color3.fromRGB(11, 11, 18),
        bar     = Color3.fromRGB(8, 8, 14),
        row     = Color3.fromRGB(20, 20, 32),
        rowHov  = Color3.fromRGB(28, 27, 45),
        border  = Color3.fromRGB(44, 38, 78),
        accent  = Color3.fromRGB(118, 80, 240),
        accentH = Color3.fromRGB(158, 122, 255),
        text    = Color3.fromRGB(214, 214, 226),
        muted   = Color3.fromRGB(96, 94, 122),
        off     = Color3.fromRGB(33, 32, 50),
        valBg   = Color3.fromRGB(30, 24, 56),
    }

    local sg = Instance.new("ScreenGui")
    sg.Name = "WraithUI"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.Parent = LocalPlayer.PlayerGui

    -- ── shell ───────────────────────────────────────────────────────────
    local main = Instance.new("Frame", sg)
    main.Size = UDim2.new(0, 600, 0, 410)
    main.Position = UDim2.new(0.5, -300, 0.5, -205)
    main.BackgroundColor3 = C.bg
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 12)

    local glow = Instance.new("UIStroke", main)
    glow.Color = C.accent
    glow.Thickness = 1.4
    glow.Transparency = 0.35

    -- soft vertical gradient over the whole panel
    local grad = Instance.new("UIGradient", main)
    grad.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 20, 42)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 10, 16)),
    }
    grad.Rotation = 90

    -- ── snow layer (behind everything) ──────────────────────────────────
    local snowLayer = Instance.new("Frame", main)
    snowLayer.Size = UDim2.new(1, 0, 1, 0)
    snowLayer.BackgroundTransparency = 1
    snowLayer.BorderSizePixel = 0
    snowLayer.ClipsDescendants = true
    snowLayer.ZIndex = 1

    local flakes = {}
    local function spawnFlakes()
        for _, f in ipairs(flakes) do f.obj:Destroy() end
        flakes = {}
        for i = 1, cfg.snowCount do
            local sz = math.random(2, 5)
            local f = Instance.new("Frame", snowLayer)
            f.Size = UDim2.new(0, sz, 0, sz)
            f.BackgroundColor3 = Color3.new(1, 1, 1)
            f.BackgroundTransparency = math.random(35, 80) / 100
            f.BorderSizePixel = 0
            f.ZIndex = 1
            Instance.new("UICorner", f).CornerRadius = UDim.new(1, 0)
            flakes[i] = {
                obj   = f,
                x     = math.random() * 600,
                y     = math.random() * 410,
                speed = 8 + math.random() * 22,
                drift = (math.random() - 0.5) * 14,
                phase = math.random() * 6.28,
                size  = sz,
            }
        end
    end
    spawnFlakes()

    local snowConn = RunService.RenderStepped:Connect(function(dt)
        if not cfg.snow then
            for _, f in ipairs(flakes) do f.obj.Visible = false end
            return
        end
        local w, h = main.AbsoluteSize.X, main.AbsoluteSize.Y
        local t = os.clock()
        for _, f in ipairs(flakes) do
            f.obj.Visible = true
            f.y = f.y + f.speed * dt
            f.x = f.x + math.sin(t * 0.8 + f.phase) * f.drift * dt
            if f.y > h then
                f.y = -f.size
                f.x = math.random() * w
            end
            if f.x < -f.size then f.x = w elseif f.x > w then f.x = -f.size end
            f.obj.Position = UDim2.new(0, math.floor(f.x), 0, math.floor(f.y))
        end
    end)
    sg.Destroying:Connect(function() snowConn:Disconnect() end)

    -- ── title bar ───────────────────────────────────────────────────────
    local tbar = Instance.new("Frame", main)
    tbar.Size = UDim2.new(1, 0, 0, 38)
    tbar.BackgroundColor3 = C.bar
    tbar.BackgroundTransparency = 0.15
    tbar.BorderSizePixel = 0
    tbar.ZIndex = 5
    Instance.new("UICorner", tbar).CornerRadius = UDim.new(0, 12)

    local tfix = Instance.new("Frame", tbar)
    tfix.Size = UDim2.new(1, 0, 0, 12)
    tfix.Position = UDim2.new(0, 0, 1, -12)
    tfix.BackgroundColor3 = C.bar
    tfix.BackgroundTransparency = 0.15
    tfix.BorderSizePixel = 0
    tfix.ZIndex = 5

    local tline = Instance.new("Frame", tbar)
    tline.Size = UDim2.new(1, 0, 0, 1)
    tline.Position = UDim2.new(0, 0, 1, -1)
    tline.BackgroundColor3 = C.border
    tline.BorderSizePixel = 0
    tline.ZIndex = 6

    local logo = Instance.new("TextLabel", tbar)
    logo.Size = UDim2.new(0, 130, 1, 0)
    logo.Position = UDim2.new(0, 16, 0, 0)
    logo.BackgroundTransparency = 1
    logo.Text = "❆  WRAITH"
    logo.TextColor3 = Color3.new(1, 1, 1)
    logo.Font = Enum.Font.GothamBold
    logo.TextSize = 13
    logo.TextXAlignment = Enum.TextXAlignment.Left
    logo.ZIndex = 6
    local lg = Instance.new("UIGradient", logo)
    lg.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 165, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 190, 255)),
    }

    -- search
    local sbox = Instance.new("Frame", tbar)
    sbox.Size = UDim2.new(0, 200, 0, 24)
    sbox.Position = UDim2.new(0.5, -100, 0.5, -12)
    sbox.BackgroundColor3 = C.off
    sbox.BackgroundTransparency = 0.2
    sbox.BorderSizePixel = 0
    sbox.ZIndex = 6
    Instance.new("UICorner", sbox).CornerRadius = UDim.new(0, 7)
    local sstroke = Instance.new("UIStroke", sbox)
    sstroke.Color = C.border sstroke.Transparency = 0.4

    local sicon = Instance.new("TextLabel", sbox)
    sicon.Size = UDim2.new(0, 20, 1, 0)
    sicon.Position = UDim2.new(0, 4, 0, 0)
    sicon.BackgroundTransparency = 1
    sicon.Text = "⌕"
    sicon.TextColor3 = C.muted
    sicon.Font = Enum.Font.GothamBold
    sicon.TextSize = 13
    sicon.ZIndex = 7

    local sinput = Instance.new("TextBox", sbox)
    sinput.Size = UDim2.new(1, -28, 1, 0)
    sinput.Position = UDim2.new(0, 24, 0, 0)
    sinput.BackgroundTransparency = 1
    sinput.PlaceholderText = "Search"
    sinput.PlaceholderColor3 = C.muted
    sinput.Text = ""
    sinput.TextColor3 = C.text
    sinput.Font = Enum.Font.Gotham
    sinput.TextSize = 11
    sinput.TextXAlignment = Enum.TextXAlignment.Left
    sinput.ClearTextOnFocus = false
    sinput.ZIndex = 7

    sinput:GetPropertyChangedSignal("Text"):Connect(function()
        local q = sinput.Text:lower()
        for _, e in ipairs(searchIndex) do
            e.frame.Visible = (q == "") or e.text:lower():find(q, 1, true) ~= nil
        end
    end)

    -- close
    local xb = Instance.new("TextButton", tbar)
    xb.Size = UDim2.new(0, 24, 0, 24)
    xb.Position = UDim2.new(1, -32, 0.5, -12)
    xb.BackgroundColor3 = Color3.fromRGB(190, 55, 65)
    xb.Text = "✕"
    xb.TextColor3 = Color3.new(1, 1, 1)
    xb.Font = Enum.Font.GothamBold
    xb.TextSize = 11
    xb.BorderSizePixel = 0
    xb.AutoButtonColor = false
    xb.ZIndex = 7
    Instance.new("UICorner", xb).CornerRadius = UDim.new(0, 6)
    xb.MouseEnter:Connect(function()
        TweenService:Create(xb, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(225, 70, 80)}):Play()
    end)
    xb.MouseLeave:Connect(function()
        TweenService:Create(xb, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(190, 55, 65)}):Play()
    end)
    xb.MouseButton1Click:Connect(function() sg:Destroy() end)

    -- drag
    do
        local drag, ds, sp
        tbar.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then
                drag, ds, sp = true, i.Position, main.Position
            end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if drag and i.UserInputType == Enum.UserInputType.MouseMovement then
                local d = i.Position - ds
                main.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
            end
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
        end)
    end

    -- ── sidebar ─────────────────────────────────────────────────────────
    local side = Instance.new("Frame", main)
    side.Size = UDim2.new(0, 118, 1, -38)
    side.Position = UDim2.new(0, 0, 0, 38)
    side.BackgroundColor3 = C.bar
    side.BackgroundTransparency = 0.25
    side.BorderSizePixel = 0
    side.ZIndex = 4

    -- parented to main, not side: a child of `side` would be swept into its
    -- UIListLayout and push every tab out of view
    local sdiv = Instance.new("Frame", main)
    sdiv.Size = UDim2.new(0, 1, 1, -38)
    sdiv.Position = UDim2.new(0, 117, 0, 38)
    sdiv.BackgroundColor3 = C.border
    sdiv.BorderSizePixel = 0
    sdiv.ZIndex = 5

    local sl = Instance.new("UIListLayout", side)
    sl.Padding = UDim.new(0, 3)
    sl.SortOrder = Enum.SortOrder.LayoutOrder
    local slp = Instance.new("UIPadding", side)
    slp.PaddingTop = UDim.new(0, 10)
    slp.PaddingLeft = UDim.new(0, 7)
    slp.PaddingRight = UDim.new(0, 8)

    -- watermark pinned to the bottom of the sidebar (outside the list flow)
    local wm = Instance.new("TextLabel", main)
    wm.Size = UDim2.new(0, 118, 0, 16)
    wm.Position = UDim2.new(0, 0, 1, -22)
    wm.BackgroundTransparency = 1
    wm.Text = "WRAITH  v2.0"
    wm.TextColor3 = C.muted
    wm.Font = Enum.Font.Gotham
    wm.TextSize = 9
    wm.ZIndex = 5

    -- ── content ─────────────────────────────────────────────────────────
    local content = Instance.new("Frame", main)
    content.Size = UDim2.new(1, -118, 1, -38)
    content.Position = UDim2.new(0, 118, 0, 38)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ZIndex = 4

    -- ── widget factory ──────────────────────────────────────────────────
    local Z = 6

    -- UIListLayout ties on equal LayoutOrder resolve by name, not creation
    -- order, so every child gets an explicit incrementing order.
    local orderN = {}
    local function nextOrder(parent)
        orderN[parent] = (orderN[parent] or 0) + 1
        return orderN[parent]
    end

    local function mkPage()
        local page = Instance.new("Frame", content)
        page.Size = UDim2.new(1, 0, 1, 0)
        page.BackgroundTransparency = 1
        page.BorderSizePixel = 0
        page.Visible = false
        page.ZIndex = Z

        local cols = {}
        for i = 0, 1 do
            local col = Instance.new("ScrollingFrame", page)
            col.Size = UDim2.new(0.5, -8, 1, -8)
            col.Position = UDim2.new(0.5 * i, i == 0 and 8 or 2, 0, 4)
            col.BackgroundTransparency = 1
            col.BorderSizePixel = 0
            col.ScrollBarThickness = 2
            col.ScrollBarImageColor3 = C.accent
            col.CanvasSize = UDim2.new(0, 0, 0, 0)
            col.AutomaticCanvasSize = Enum.AutomaticSize.Y
            col.ZIndex = Z
            local l = Instance.new("UIListLayout", col)
            l.Padding = UDim.new(0, 5)
            l.SortOrder = Enum.SortOrder.LayoutOrder
            local p = Instance.new("UIPadding", col)
            p.PaddingTop = UDim.new(0, 6)
            p.PaddingBottom = UDim.new(0, 10)
            p.PaddingRight = UDim.new(0, 6)
            cols[i + 1] = col
        end

        local mid = Instance.new("Frame", page)
        mid.Size = UDim2.new(0, 1, 1, -20)
        mid.Position = UDim2.new(0.5, -2, 0, 10)
        mid.BackgroundColor3 = C.border
        mid.BackgroundTransparency = 0.3
        mid.BorderSizePixel = 0
        mid.ZIndex = Z

        return page, cols[1], cols[2]
    end

    local function header(parent, txt)
        local h = Instance.new("TextLabel", parent)
        h.Size = UDim2.new(1, 0, 0, 20)
        h.BackgroundTransparency = 1
        h.Text = txt
        h.TextColor3 = C.accentH
        h.Font = Enum.Font.GothamBold
        h.TextSize = 10
        h.TextXAlignment = Enum.TextXAlignment.Left
        h.ZIndex = Z + 1
        h.LayoutOrder = nextOrder(parent)
        return h
    end

    local function card(parent, height)
        local f = Instance.new("Frame", parent)
        f.Size = UDim2.new(1, 0, 0, height)
        f.BackgroundColor3 = C.row
        f.BackgroundTransparency = 0.15
        f.BorderSizePixel = 0
        f.ZIndex = Z + 1
        f.LayoutOrder = nextOrder(parent)
        Instance.new("UICorner", f).CornerRadius = UDim.new(0, 7)
        local st = Instance.new("UIStroke", f)
        st.Color = C.border
        st.Transparency = 0.55
        return f, st
    end

    local function mkToggle(parent, label, get, set)
        local row, st = card(parent, 32)
        table.insert(searchIndex, {frame = row, text = label})

        local lbl = Instance.new("TextLabel", row)
        lbl.Size = UDim2.new(1, -52, 1, 0)
        lbl.Position = UDim2.new(0, 10, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = label
        lbl.TextColor3 = C.text
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 11
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.ZIndex = Z + 2

        local track = Instance.new("Frame", row)
        track.Size = UDim2.new(0, 32, 0, 17)
        track.Position = UDim2.new(1, -42, 0.5, -8)
        track.BackgroundColor3 = get() and C.accent or C.off
        track.BorderSizePixel = 0
        track.ZIndex = Z + 2
        Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

        local knob = Instance.new("Frame", track)
        knob.Size = UDim2.new(0, 13, 0, 13)
        knob.Position = UDim2.new(0, get() and 17 or 2, 0.5, -6)
        knob.BackgroundColor3 = Color3.new(1, 1, 1)
        knob.BorderSizePixel = 0
        knob.ZIndex = Z + 3
        Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

        local btn = Instance.new("TextButton", row)
        btn.Size = UDim2.new(1, 0, 1, 0)
        btn.BackgroundTransparency = 1
        btn.Text = ""
        btn.ZIndex = Z + 4
        btn.MouseEnter:Connect(function()
            TweenService:Create(st, TweenInfo.new(0.15), {Transparency = 0.1}):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(st, TweenInfo.new(0.15), {Transparency = 0.55}):Play()
        end)
        btn.MouseButton1Click:Connect(function()
            local v = not get()
            set(v)
            TweenService:Create(track, TweenInfo.new(0.14), {BackgroundColor3 = v and C.accent or C.off}):Play()
            TweenService:Create(knob, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                {Position = UDim2.new(0, v and 17 or 2, 0.5, -6)}):Play()
        end)
        return row
    end

    local function mkSlider(parent, label, minV, maxV, get, set)
        local row = card(parent, 50)
        table.insert(searchIndex, {frame = row, text = label})

        local lbl = Instance.new("TextLabel", row)
        lbl.Size = UDim2.new(1, -56, 0, 18)
        lbl.Position = UDim2.new(0, 10, 0, 5)
        lbl.BackgroundTransparency = 1
        lbl.Text = label
        lbl.TextColor3 = C.text
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 11
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.ZIndex = Z + 2

        local vbg = Instance.new("Frame", row)
        vbg.Size = UDim2.new(0, 40, 0, 16)
        vbg.Position = UDim2.new(1, -48, 0, 6)
        vbg.BackgroundColor3 = C.valBg
        vbg.BorderSizePixel = 0
        vbg.ZIndex = Z + 2
        Instance.new("UICorner", vbg).CornerRadius = UDim.new(0, 4)

        local vl = Instance.new("TextLabel", vbg)
        vl.Size = UDim2.new(1, 0, 1, 0)
        vl.BackgroundTransparency = 1
        vl.Text = tostring(get())
        vl.TextColor3 = C.accentH
        vl.Font = Enum.Font.GothamBold
        vl.TextSize = 10
        vl.ZIndex = Z + 3

        local track = Instance.new("Frame", row)
        track.Size = UDim2.new(1, -20, 0, 4)
        track.Position = UDim2.new(0, 10, 0, 34)
        track.BackgroundColor3 = C.off
        track.BorderSizePixel = 0
        track.ZIndex = Z + 2
        Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

        local t0 = (get() - minV) / (maxV - minV)
        local fill = Instance.new("Frame", track)
        fill.Size = UDim2.new(t0, 0, 1, 0)
        fill.BackgroundColor3 = C.accent
        fill.BorderSizePixel = 0
        fill.ZIndex = Z + 3
        Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)
        local fg = Instance.new("UIGradient", fill)
        fg.Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 140, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(165, 100, 255)),
        }

        local knob = Instance.new("Frame", track)
        knob.Size = UDim2.new(0, 11, 0, 11)
        knob.AnchorPoint = Vector2.new(0.5, 0.5)
        knob.Position = UDim2.new(t0, 0, 0.5, 0)
        knob.BackgroundColor3 = Color3.new(1, 1, 1)
        knob.BorderSizePixel = 0
        knob.ZIndex = Z + 4
        Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

        local hit = Instance.new("TextButton", row)
        hit.Size = UDim2.new(1, -20, 0, 20)
        hit.Position = UDim2.new(0, 10, 0, 26)
        hit.BackgroundTransparency = 1
        hit.Text = ""
        hit.ZIndex = Z + 5

        local sliding = false
        local function apply(px)
            local ap, as = track.AbsolutePosition, track.AbsoluteSize
            local t = math.clamp((px - ap.X) / as.X, 0, 1)
            local val = math.floor(minV + t * (maxV - minV) + 0.5)
            vl.Text = tostring(val)
            fill.Size = UDim2.new(t, 0, 1, 0)
            knob.Position = UDim2.new(t, 0, 0.5, 0)
            set(val)
        end
        hit.MouseButton1Down:Connect(function()
            sliding = true
            apply(UserInputService:GetMouseLocation().X)
        end)
        UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then sliding = false end
        end)
        UserInputService.InputChanged:Connect(function(i)
            if sliding and i.UserInputType == Enum.UserInputType.MouseMovement then
                apply(i.Position.X)
            end
        end)
        return row
    end

    local function mkDropdown(parent, label, opts, get, set)
        local row = card(parent, 48)
        row.ClipsDescendants = false
        table.insert(searchIndex, {frame = row, text = label})

        local lbl = Instance.new("TextLabel", row)
        lbl.Size = UDim2.new(1, -16, 0, 16)
        lbl.Position = UDim2.new(0, 10, 0, 4)
        lbl.BackgroundTransparency = 1
        lbl.Text = label
        lbl.TextColor3 = C.muted
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.ZIndex = Z + 2

        local btn = Instance.new("TextButton", row)
        btn.Size = UDim2.new(1, -20, 0, 22)
        btn.Position = UDim2.new(0, 10, 0, 21)
        btn.BackgroundColor3 = C.off
        btn.Text = "  " .. tostring(get())
        btn.TextColor3 = C.text
        btn.Font = Enum.Font.Gotham
        btn.TextSize = 11
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.ZIndex = Z + 3
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

        local arrow = Instance.new("TextLabel", btn)
        arrow.Size = UDim2.new(0, 20, 1, 0)
        arrow.Position = UDim2.new(1, -22, 0, 0)
        arrow.BackgroundTransparency = 1
        arrow.Text = "▾"
        arrow.TextColor3 = C.muted
        arrow.Font = Enum.Font.GothamBold
        arrow.TextSize = 10
        arrow.ZIndex = Z + 4

        local menu
        btn.MouseButton1Click:Connect(function()
            if menu then menu:Destroy() menu = nil arrow.Text = "▾" return end
            arrow.Text = "▴"
            menu = Instance.new("Frame", row)
            menu.Size = UDim2.new(1, -20, 0, math.min(#opts, 6) * 22 + 4)
            menu.Position = UDim2.new(0, 10, 1, 1)
            menu.BackgroundColor3 = Color3.fromRGB(24, 22, 40)
            menu.BorderSizePixel = 0
            menu.ZIndex = 60
            menu.ClipsDescendants = true
            Instance.new("UICorner", menu).CornerRadius = UDim.new(0, 6)
            local mst = Instance.new("UIStroke", menu)
            mst.Color = C.accent mst.Transparency = 0.5

            local scr = Instance.new("ScrollingFrame", menu)
            scr.Size = UDim2.new(1, -4, 1, -4)
            scr.Position = UDim2.new(0, 2, 0, 2)
            scr.BackgroundTransparency = 1
            scr.BorderSizePixel = 0
            scr.ScrollBarThickness = 2
            scr.ScrollBarImageColor3 = C.accent
            scr.CanvasSize = UDim2.new(0, 0, 0, 0)
            scr.AutomaticCanvasSize = Enum.AutomaticSize.Y
            scr.ZIndex = 61
            local ml = Instance.new("UIListLayout", scr)
            ml.Padding = UDim.new(0, 2)

            for _, opt in ipairs(opts) do
                local ob = Instance.new("TextButton", scr)
                ob.Size = UDim2.new(1, -4, 0, 20)
                ob.BackgroundColor3 = (tostring(get()) == opt) and C.accent or Color3.fromRGB(34, 32, 52)
                ob.Text = opt
                ob.TextColor3 = Color3.new(1, 1, 1)
                ob.Font = Enum.Font.Gotham
                ob.TextSize = 10
                ob.BorderSizePixel = 0
                ob.AutoButtonColor = false
                ob.ZIndex = 62
                Instance.new("UICorner", ob).CornerRadius = UDim.new(0, 4)
                ob.MouseButton1Click:Connect(function()
                    set(opt)
                    btn.Text = "  " .. opt
                    arrow.Text = "▾"
                    menu:Destroy() menu = nil
                end)
            end
        end)
        return row
    end

    -- ── tabs ────────────────────────────────────────────────────────────
    local active = nil
    local function mkTab(icon, label, page, order)
        local tab = Instance.new("TextButton", side)
        tab.Size = UDim2.new(1, 0, 0, 34)
        tab.BackgroundColor3 = C.rowHov
        tab.BackgroundTransparency = 1
        tab.BorderSizePixel = 0
        tab.Text = ""
        tab.AutoButtonColor = false
        tab.LayoutOrder = order
        tab.ZIndex = 5
        Instance.new("UICorner", tab).CornerRadius = UDim.new(0, 7)

        local ic = Instance.new("TextLabel", tab)
        ic.Size = UDim2.new(0, 20, 1, 0)
        ic.Position = UDim2.new(0, 9, 0, 0)
        ic.BackgroundTransparency = 1
        ic.Text = icon
        ic.TextColor3 = C.muted
        ic.Font = Enum.Font.GothamBold
        ic.TextSize = 12
        ic.ZIndex = 6

        local tx = Instance.new("TextLabel", tab)
        tx.Size = UDim2.new(1, -32, 1, 0)
        tx.Position = UDim2.new(0, 31, 0, 0)
        tx.BackgroundTransparency = 1
        tx.Text = label
        tx.TextColor3 = C.muted
        tx.Font = Enum.Font.Gotham
        tx.TextSize = 11
        tx.TextXAlignment = Enum.TextXAlignment.Left
        tx.ZIndex = 6

        local ind = Instance.new("Frame", tab)
        ind.Size = UDim2.new(0, 3, 0, 0)
        ind.AnchorPoint = Vector2.new(0, 0.5)
        ind.Position = UDim2.new(0, 1, 0.5, 0)
        ind.BackgroundColor3 = C.accentH
        ind.BorderSizePixel = 0
        ind.ZIndex = 7
        Instance.new("UICorner", ind).CornerRadius = UDim.new(1, 0)

        local self
        local function show()
            if active and active ~= self then
                local a = active
                TweenService:Create(a.tab, TweenInfo.new(0.15), {BackgroundTransparency = 1}):Play()
                TweenService:Create(a.ind, TweenInfo.new(0.15), {Size = UDim2.new(0, 3, 0, 0)}):Play()
                a.ic.TextColor3 = C.muted
                a.tx.TextColor3 = C.muted
                a.page.Visible = false
            end
            TweenService:Create(tab, TweenInfo.new(0.15), {BackgroundTransparency = 0.35}):Play()
            TweenService:Create(ind, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                {Size = UDim2.new(0, 3, 0, 18)}):Play()
            ic.TextColor3 = C.accentH
            tx.TextColor3 = Color3.new(1, 1, 1)
            page.Visible = true
            active = self
        end
        self = {tab = tab, ic = ic, tx = tx, ind = ind, page = page, show = show}

        tab.MouseEnter:Connect(function()
            if active ~= self then
                TweenService:Create(tab, TweenInfo.new(0.12), {BackgroundTransparency = 0.7}):Play()
            end
        end)
        tab.MouseLeave:Connect(function()
            if active ~= self then
                TweenService:Create(tab, TweenInfo.new(0.12), {BackgroundTransparency = 1}):Play()
            end
        end)
        tab.MouseButton1Click:Connect(show)
        return self
    end

    -- ── PAGE: Combat ────────────────────────────────────────────────────
    local combat, aL, aR = mkPage()
    do
        header(aL, "AIMBOT SETTINGS")
        mkToggle(aL, "Enable Aimbot", function() return cfg.aimEnabled end, function(v)
            cfg.aimEnabled = v
            if not v then lockedTarget = nil end
        end)
        mkToggle(aL, "Hold To Aim (RMB)", function() return cfg.holdToAim end, function(v) cfg.holdToAim = v end)
        mkSlider(aL, "Field of View", 20, 500, function() return cfg.fovRadius end, function(v) cfg.fovRadius = v end)
        mkSlider(aL, "Aim Speed", 0, 20, function() return cfg.aimSpeed end, function(v) cfg.aimSpeed = v end)
        mkDropdown(aL, "Aim Point", {
            "Head", "HumanoidRootPart", "UpperTorso", "LowerTorso",
            "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg",
        }, function() return cfg.aimPart end, function(v) cfg.aimPart = v end)
        mkToggle(aL, "Skip Teammates", function() return cfg.skipTeammates end, function(v) cfg.skipTeammates = v end)
        mkToggle(aL, "Only Aim at Visible", function() return cfg.onlyVisible end, function(v) cfg.onlyVisible = v end)
        mkToggle(aL, "Show FOV Circle", function() return cfg.fovVisible end, function(v) cfg.fovVisible = v end)

        header(aR, "ADVANCED AIMBOT")
        mkToggle(aR, "Recoil Control", function() return cfg.recoilControl end, function(v) cfg.recoilControl = v end)
        mkToggle(aR, "Smart Smoothing", function() return cfg.smartSmooth end, function(v) cfg.smartSmooth = v end)
        mkToggle(aR, "Natural Movement", function() return cfg.naturalMove end, function(v) cfg.naturalMove = v end)
        mkToggle(aR, "Movement Prediction", function() return cfg.prediction end, function(v) cfg.prediction = v end)
        mkSlider(aR, "Prediction Lead", 1, 40, function() return cfg.predictAmount end, function(v) cfg.predictAmount = v end)
        mkToggle(aR, "Random Offset", function() return cfg.randomOffset end, function(v) cfg.randomOffset = v end)
        mkSlider(aR, "Offset Strength", 0, 10, function() return cfg.offsetStrength end, function(v) cfg.offsetStrength = v end)
    end

    -- ── PAGE: Silent Aim ────────────────────────────────────────────────
    local silent, sL, sR = mkPage()
    do
        header(sL, "SILENT AIM")
        mkToggle(sL, "Silent Aim", function() return cfg.silentAim end, function(v) cfg.silentAim = v end)
        mkToggle(sL, "FOV Restricted", function() return cfg.silentFovOnly end, function(v) cfg.silentFovOnly = v end)
        mkSlider(sL, "Silent FOV", 20, 500, function() return cfg.fovRadius end, function(v) cfg.fovRadius = v end)
        mkDropdown(sL, "Hit Part", {
            "Head", "HumanoidRootPart", "UpperTorso", "LowerTorso",
            "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg",
        }, function() return cfg.aimPart end, function(v) cfg.aimPart = v end)

        header(sR, "RESOLVER")
        mkToggle(sR, "Predict Movement", function() return cfg.prediction end, function(v) cfg.prediction = v end)
        mkSlider(sR, "Prediction Lead", 1, 40, function() return cfg.predictAmount end, function(v) cfg.predictAmount = v end)
        mkToggle(sR, "Visibility Check", function() return cfg.onlyVisible end, function(v) cfg.onlyVisible = v end)
        mkToggle(sR, "Ignore Teammates", function() return cfg.skipTeammates end, function(v) cfg.skipTeammates = v end)

        local note = Instance.new("TextLabel", sR)
        note.Size = UDim2.new(1, 0, 0, 46)
        note.BackgroundColor3 = C.row
        note.BackgroundTransparency = 0.3
        note.BorderSizePixel = 0
        note.Text = "Hooks raycast-based weapons.\nGames using other hit\ndetection may not respond."
        note.TextColor3 = C.muted
        note.Font = Enum.Font.Gotham
        note.TextSize = 9
        note.ZIndex = Z + 2
        note.LayoutOrder = nextOrder(sR)
        Instance.new("UICorner", note).CornerRadius = UDim.new(0, 6)
    end

    -- ── PAGE: Visuals ───────────────────────────────────────────────────
    local visuals, vL, vR = mkPage()
    do
        header(vL, "PLAYER ESP")
        mkToggle(vL, "ESP Enabled", function() return cfg.espEnabled end, function(v) cfg.espEnabled = v end)
        mkToggle(vL, "Boxes", function() return cfg.espBoxes end, function(v) cfg.espBoxes = v end)
        mkToggle(vL, "Names", function() return cfg.espNames end, function(v) cfg.espNames = v end)
        mkToggle(vL, "Health Bars", function() return cfg.espHealth end, function(v) cfg.espHealth = v end)
        mkToggle(vL, "Distance", function() return cfg.espDistance end, function(v) cfg.espDistance = v end)
        mkToggle(vL, "Tracers", function() return cfg.espTracers end, function(v) cfg.espTracers = v end)
        mkSlider(vL, "Render Distance", 100, 3000, function() return cfg.espMaxDist end, function(v) cfg.espMaxDist = v end)

        header(vR, "WORLD")
        mkToggle(vR, "Chams", function() return cfg.chams end, function(v) cfg.chams = v end)
        mkToggle(vR, "Fullbright", function() return cfg.fullbright end, function(v)
            cfg.fullbright = v
            setFullbright(v)
        end)
        mkToggle(vR, "Team Check", function() return cfg.espTeamCheck end, function(v) cfg.espTeamCheck = v end)
        mkToggle(vR, "Rainbow Accent", function() return cfg.rainbowAccent end, function(v) cfg.rainbowAccent = v end)
    end

    -- ── PAGE: Settings ──────────────────────────────────────────────────
    local settings, gL, gR = mkPage()
    do
        local KEYS = {"Q","E","R","T","F","G","C","V","X","Z","LeftAlt","LeftControl","MouseButton2"}
        local UIKEYS = {"RightShift","LeftShift","Insert","End","F1","F2","F4","Delete"}

        header(gL, "KEYBINDS")
        mkDropdown(gL, "Lock Target Key", KEYS, function() return cfg.lockKey.Name end, function(v)
            if Enum.KeyCode[v] then cfg.lockKey = Enum.KeyCode[v] end
        end)
        mkDropdown(gL, "Toggle Menu Key", UIKEYS, function() return cfg.guiKey.Name end, function(v)
            if Enum.KeyCode[v] then cfg.guiKey = Enum.KeyCode[v] end
        end)

        header(gL, "INTERFACE")
        mkToggle(gL, "Snowfall", function() return cfg.snow end, function(v) cfg.snow = v end)
        mkSlider(gL, "Snow Density", 0, 150, function() return cfg.snowCount end, function(v)
            cfg.snowCount = v
            spawnFlakes()
        end)

        header(gR, "SESSION")
        local stat = Instance.new("TextLabel", gR)
        stat.Size = UDim2.new(1, 0, 0, 74)
        stat.BackgroundColor3 = C.row
        stat.BackgroundTransparency = 0.2
        stat.BorderSizePixel = 0
        stat.Text = ""
        stat.TextColor3 = C.text
        stat.Font = Enum.Font.Gotham
        stat.TextSize = 10
        stat.ZIndex = Z + 2
        stat.LayoutOrder = nextOrder(gR)
        Instance.new("UICorner", stat).CornerRadius = UDim.new(0, 7)

        task.spawn(function()
            while stat.Parent do
                local t = lockedTarget and lockedTarget.DisplayName or "none"
                stat.Text = string.format(
                    "Target: %s\nPlayers: %d\nFPS: %d\nGame: %d",
                    t, #Players:GetPlayers(),
                    math.floor(1 / math.max(RunService.RenderStepped:Wait(), 1e-6)),
                    game.PlaceId
                )
                task.wait(0.5)
            end
        end)

        local unload = Instance.new("TextButton", gR)
        unload.Size = UDim2.new(1, 0, 0, 30)
        unload.BackgroundColor3 = Color3.fromRGB(150, 45, 55)
        unload.Text = "Unload Wraith"
        unload.TextColor3 = Color3.new(1, 1, 1)
        unload.Font = Enum.Font.GothamBold
        unload.TextSize = 11
        unload.BorderSizePixel = 0
        unload.AutoButtonColor = false
        unload.ZIndex = Z + 2
        unload.LayoutOrder = nextOrder(gR)
        Instance.new("UICorner", unload).CornerRadius = UDim.new(0, 7)
        unload.MouseButton1Click:Connect(function()
            cfg.aimEnabled = false
            cfg.silentAim  = false
            cfg.espEnabled = false
            cfg.chams      = false
            setFullbright(false)
            for p in pairs(espObjects) do removeESP(p) end
            pcall(function() fovCircle:Remove() end)
            sg:Destroy()
        end)
    end

    -- register tabs
    local tCombat = mkTab("◈", "Combat",     combat,   1)
    mkTab("⊹", "Silent Aim", silent,   2)
    mkTab("◉", "Visuals",    visuals,  3)
    mkTab("⚙", "Settings",   settings, 4)
    tCombat.show()

    -- rainbow accent driver
    task.spawn(function()
        while sg.Parent do
            if cfg.rainbowAccent then
                local c = Color3.fromHSV((os.clock() * 0.12) % 1, 0.55, 1)
                glow.Color = c
                lg.Color = ColorSequence.new(c, Color3.fromRGB(120, 190, 255))
            else
                glow.Color = C.accent
            end
            task.wait(0.03)
        end
    end)

    -- open/close animation
    main.Size = UDim2.new(0, 0, 0, 0)
    TweenService:Create(main, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        {Size = UDim2.new(0, 600, 0, 410)}):Play()

    return sg, main
end

local screenGui, mainFrame = buildGui()

-- ══════════════════════════════════════════════════════════════════════════
--  INPUT
-- ══════════════════════════════════════════════════════════════════════════
UserInputService.InputBegan:Connect(function(input, gpe)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then aimHeld = true end
    if gpe then return end

    if input.KeyCode == cfg.lockKey then
        if lockedTarget then
            lockedTarget = nil
        else
            lockedTarget = getClosestInFOV()
        end
    elseif input.KeyCode == cfg.guiKey then
        if mainFrame and mainFrame.Parent then
            mainFrame.Visible = not mainFrame.Visible
        end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then aimHeld = false end
end)

-- ══════════════════════════════════════════════════════════════════════════
--  PLAYER HOOKS
-- ══════════════════════════════════════════════════════════════════════════
Players.PlayerAdded:Connect(function(p)
    createESP(p)
    p.CharacterAdded:Connect(function() task.wait(0.6) createESP(p) end)
end)
Players.PlayerRemoving:Connect(function(p)
    if lockedTarget == p then lockedTarget = nil end
    removeESP(p)
end)
for _, p in ipairs(Players:GetPlayers()) do createESP(p) end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if workspace.CurrentCamera then Camera = workspace.CurrentCamera end
end)

print("[Wraith] v2.0 loaded  |  " .. cfg.lockKey.Name .. " = lock target  |  " .. cfg.guiKey.Name .. " = toggle menu")
