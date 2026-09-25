-- AUTO LAUNCH v3 | ON/OFF | RightShift
-- Experimental: no guarantee of a perfect result on every launch.

-- v3: rising-edge velocity prediction with bounded timing calibration.
-- Values displayed as integers are estimates, not authoritative game state.
local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end
local function median(values)
    local copy = {}
    for i, value in ipairs(values) do copy[i] = value end
    table.sort(copy)
    local n = #copy
    if n % 2 == 1 then return copy[math.ceil(n / 2)] end
    return (copy[n / 2] + copy[n / 2 + 1]) / 2
end
local function newMotion()
    return {samples = {}, last = nil, changed = nil, rising = false}
end
local function observeMotion(m, value, now)
    if m.last == value then return end
    if m.last ~= nil and value < m.last then
        m.samples = {}
        m.rising = false
    elseif m.last ~= nil and value > m.last then
        m.rising = true
    end
    m.last = value
    m.changed = now
    table.insert(m.samples, {t = now, p = value})
    while #m.samples > 2 and now - m.samples[1].t > 0.16 do
        table.remove(m.samples, 1)
    end
    while #m.samples > 32 do table.remove(m.samples, 1) end
end
local function estimateMotion(m, now)
    local samples = m.samples
    if not m.rising or #samples < 4 or not m.changed
        or now - m.changed > 0.08 then return nil end
    local first = samples[1]
    local last = samples[#samples]
    if last.t - first.t < 0.035 then return nil end
    local sx, sy, sxx, sxy = 0, 0, 0, 0
    for _, point in ipairs(samples) do
        local x = point.t - first.t
        sx = sx + x
        sy = sy + point.p
        sxx = sxx + x * x
        sxy = sxy + x * point.p
    end
    local n = #samples
    local denominator = n * sxx - sx * sx
    if denominator <= 0 then return nil end
    local speed = (n * sxy - sx * sy) / denominator
    if speed < 2 or speed > 1000 then return nil end
    local intercept = (sy - speed * sx) / n
    local errorSum = 0
    for _, point in ipairs(samples) do
        local err = point.p - (intercept + speed * (point.t - first.t))
        errorSum = errorSum + err * err
    end
    if math.sqrt(errorSum / n) > 0.9 then return nil end
    return speed, intercept + speed * (now - first.t)
end
local function shouldFire(m, now, dt, lead)
    if dt <= 0 or dt > 0.06 or not m.last or m.last < 85 then return false end
    local speed, predicted = estimateMotion(m, now)
    if not speed or predicted > 100.5 then return false end
    -- Select the nearest available frame to the compensated target time.
    return predicted + speed * (lead + dt * 0.5) >= 99.5, speed
end
local function newCalibration()
    return {lead = 0.020, bestLead = 0.020, bestScore = nil,
        direction = 1, scores = {}, tried = {}, total = 0}
end
local function recordResult(c, score)
    c.total = c.total + 1
    table.insert(c.scores, score)
    if #c.scores < 5 then return end
    local scoreMedian = median(c.scores)
    c.scores = {}
    local key = math.floor(c.lead * 10000 + 0.5)
    c.tried[key] = true
    if c.bestScore == nil or scoreMedian > c.bestScore + 0.25 then
        c.bestScore = scoreMedian
        c.bestLead = c.lead
        c.tried = {[key] = true}
    elseif math.abs(c.lead - c.bestLead) > 0.0001 then
        c.direction = -c.direction
    else
        c.bestScore = scoreMedian
    end
    if scoreMedian >= 99 then
        c.bestScore = scoreMedian
        c.bestLead = c.lead
        return
    end
    local candidate = c.bestLead + c.direction * 0.008
    local function available(value)
        return value >= 0 and value <= 0.12
            and not c.tried[math.floor(value * 10000 + 0.5)]
    end
    if not available(candidate) then
        c.direction = -c.direction
        candidate = c.bestLead + c.direction * 0.008
    end
    if available(candidate) then
        c.lead = candidate
    else
        c.lead = c.bestLead
        c.tried = {[math.floor(c.bestLead * 10000 + 0.5)] = true}
    end
end
local function observeResult(shot, value, now, dt)
    if dt > 0.2 or now - shot.started > 2 then return "reject" end
    if value == nil or value < 80 then return "reject" end
    if value ~= shot.value then
        shot.value = value
        shot.changed = now
    end
    if now - shot.changed >= 0.45 and now - shot.started >= 0.5 then
        return "accept", value
    end
end

local calibration = newCalibration()
local COOLDOWN = 0.5
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end

local player = Players.LocalPlayer
while not player do
    task.wait()
    player = Players.LocalPlayer
end

local pg = player:WaitForChild("PlayerGui")
local env = (getgenv and getgenv()) or _G
local click = mouse1click

for _, name in ipairs({"StopAutoLaunch", "StopAutoLaunchUI"}) do
    if type(env[name]) == "function" then
        pcall(env[name])
        env[name] = nil
    end
end

local alive = true
local enabled = false
local target
local motion = newMotion()
local lastClick = -math.huge
local connections = {}
local shot
local waitingForNewRound = false
local lastUI = 0
local busy = false

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

local function make(class, properties, parent)
    local object = Instance.new(class)
    for key, value in pairs(properties) do object[key] = value end
    object.Parent = parent
    return object
end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoLaunch"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2147483647
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

if type(gethui) == "function" then
    pcall(function()
        local container = gethui()
        if container then gui.Parent = container end
    end)
end
if not gui.Parent then
    pcall(function() gui.Parent = game:GetService("CoreGui") end)
end
if not gui.Parent then gui.Parent = pg end

local panel = make("Frame", {
    Size = UDim2.fromOffset(310, 200),
    Position = UDim2.fromOffset(25, 100),
    BackgroundColor3 = Color3.fromRGB(23, 26, 39),
    BorderSizePixel = 0,
}, gui)
make("UICorner", {CornerRadius = UDim.new(0, 14)}, panel)
make("UIStroke", {
    Color = Color3.fromRGB(86, 104, 165),
    Thickness = 1,
}, panel)
make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 38),
    Position = UDim2.fromOffset(12, 4),
    BackgroundTransparency = 1,
    Text = "AUTO LAUNCH v3",
    TextColor3 = Color3.fromRGB(230, 237, 255),
    Font = Enum.Font.GothamBold,
    TextSize = 17,
}, panel)
local toggle = make("TextButton", {
    Size = UDim2.new(1, -24, 0, 42),
    Position = UDim2.fromOffset(12, 48),
    BackgroundColor3 = Color3.fromRGB(64, 70, 95),
    Text = "OFF",
    TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold,
    TextSize = 17,
    BorderSizePixel = 0,
}, panel)
make("UICorner", {CornerRadius = UDim.new(0, 10)}, toggle)
local status = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 40),
    Position = UDim2.fromOffset(12, 96),
    BackgroundTransparency = 1,
    Text = "Buscando barra...",
    TextColor3 = Color3.fromRGB(180, 192, 220),
    Font = Enum.Font.Gotham,
    TextSize = 12,
    TextWrapped = true,
}, panel)
make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 22),
    Position = UDim2.fromOffset(12, 170),
    BackgroundTransparency = 1,
    Text = "RightShift - Mostrar / ocultar",
    TextColor3 = Color3.fromRGB(130, 145, 185),
    Font = Enum.Font.Gotham,
    TextSize = 11,
}, panel)

local resultLabel = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 28),
    Position = UDim2.fromOffset(12, 136),
    BackgroundTransparency = 1,
    Text = "Calibrando: esperando resultados",
    TextColor3 = Color3.fromRGB(113, 220, 172),
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextWrapped = true,
}, panel)

local function reset()
    motion = newMotion()
end
local function paintToggle()
    toggle.Text = enabled and "ON" or "OFF"
    toggle.BackgroundColor3 = enabled
        and Color3.fromRGB(33, 151, 108)
        or Color3.fromRGB(64, 70, 95)
end
local function cursorOverMenu()
    if not panel.Visible then return false end
    local point = UIS:GetMouseLocation()
    local position = panel.AbsolutePosition
    local size = panel.AbsoluteSize
    return point.X >= position.X
        and point.X <= position.X + size.X
        and point.Y >= position.Y
        and point.Y <= position.Y + size.Y
end
local function read(object)
    if not object or not object:IsDescendantOf(pg) then return nil end
    local node = object
    while node and node ~= pg do
        if node:IsA("GuiObject") and not node.Visible then return nil end
        if node:IsA("ScreenGui") and not node.Enabled then return nil end
        node = node.Parent
    end
    local text = object.Text:gsub("<[^>]+>", ""):gsub(",", ".")
    local value = tonumber(text:match("^%s*(%d+%.?%d*)%s*%%%s*$"))
    if value and value >= 0 and value <= 100 then return value end
end
local function findBar()
    local match
    for _, object in ipairs(pg:GetDescendants()) do
        if not object:IsDescendantOf(gui)
            and (object:IsA("TextLabel") or object:IsA("TextButton"))
            and read(object) ~= nil then
            if match then return nil, "Varios porcentajes visibles" end
            match = object
        end
    end
    return match, "Esperando la barra..."
end

connect(toggle.Activated, function()
    if type(click) ~= "function" then
        status.Text = "El executor no incluye mouse1click"
        return
    end
    enabled = not enabled
    shot = nil
    reset()
    paintToggle()
    status.Text = enabled
        and "Activo - Coloca el cursor sobre el lanzamiento"
        or "Desactivado"
end)
connect(UIS.InputBegan, function(input)
    if input.KeyCode == Enum.KeyCode.RightShift
        and not UIS:GetFocusedTextBox() then
        panel.Visible = not panel.Visible
    end
end)
task.spawn(function()
    while alive do
        if not target then
            local found, message = findBar()
            if not alive then return end
            target = found
            reset()
            status.Text = found and "Barra encontrada" or message
        end
        task.wait(1)
    end
end)
local function update(now, dt)
    if not alive or not target or busy then return end
    local percent = read(target)
    if shot then
        local outcome, score = observeResult(shot, percent, now, dt)
        if outcome == "accept" then
            recordResult(calibration, score)
            resultLabel.Text = "Resultado: " .. score .. "% | "
                .. #calibration.scores .. "/5 para calibrar"
            shot = nil
            reset()
        elseif outcome == "reject" then
            resultLabel.Text = "Resultado no confirmado; sin ajuste"
            shot = nil
            reset()
        end
        if shot then return end
    end
    if percent == nil then
        target = nil
        reset()
        status.Text = "Esperando la barra..."
        return
    end
    if not enabled then
        reset()
        if now - lastUI > 0.1 then
            lastUI = now
            status.Text = "OFF - Barra: " .. percent .. "%"
        end
        return
    end
    if waitingForNewRound then
        if percent < 80 then
            waitingForNewRound = false
            reset()
        else
            status.Text = "Esperando nueva carga"
            return
        end
    end
    if cursorOverMenu() or UIS:GetFocusedTextBox() then
        reset()
        status.Text = "Aparta el cursor del menu y cierra el chat"
        return
    end
    if dt > 0.06 then
        reset()
        status.Text = "Pausa de imagen: esperando una subida estable"
        return
    end
    observeMotion(motion, percent, now)
    if now - lastUI > 0.1 then
        lastUI = now
        status.Text = "ON - " .. percent .. "% - "
            .. (motion.rising and "Midiendo subida" or "Esperando subida")
    end
    local fire = shouldFire(motion, now, dt, calibration.lead)
    if not fire or now - lastClick < COOLDOWN then return end
    local confirmed = read(target)
    if not confirmed or confirmed < percent or confirmed < 85 then return end

    lastClick = now
    waitingForNewRound = true
    busy = true
    -- No sleeps or loops between the final reading and the input call.
    local ok, err = pcall(click)
    busy = false
    if not alive then return end
    if ok then
        if enabled then
            shot = {started = now, changed = now, value = confirmed}
        end
        status.Text = "Clic enviado - Leyendo resultado"
    else
        enabled = false
        reset()
        paintToggle()
        status.Text = "Error al enviar el clic"
        warn("Auto Launch: " .. tostring(err))
    end
end

connect(RunService.Heartbeat, function(dt)
    update(os.clock(), dt)
end)

env.StopAutoLaunch = function()
    if not alive then return end
    alive = false
    enabled = false
    for _, connection in ipairs(connections) do connection:Disconnect() end
    gui:Destroy()
end


