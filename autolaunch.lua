-- AUTO LAUNCH
-- ON/OFF: activar o desactivar.
-- RightShift: mostrar / ocultar menu.
-- Deja el cursor sobre la zona de lanzamiento.
-- v2: calibracion experimental con resultados estables tras el clic.
-- El resultado puede variar con los fotogramas y la latencia del executor.

-- Learn from batches of three stable results; never infer early/late
-- from a single low score. Compare neighboring thresholds instead.
local function newCalibration()
    return {threshold = 97, bestThreshold = 97, bestScore = nil,
        direction = 1, scores = {}, tried = {}}
end

local function recordResult(c, score)
    table.insert(c.scores, score)
    if #c.scores < 3 then return end
    local average = 0
    for _, value in ipairs(c.scores) do average = average + value end
    average = average / #c.scores
    c.scores = {}
    c.tried[c.threshold] = true

    if c.bestScore == nil or average > c.bestScore + 0.2 then
        c.bestScore = average
        c.bestThreshold = c.threshold
        c.tried = {[c.threshold] = true}
    elseif c.threshold ~= c.bestThreshold then
        c.direction = -c.direction
    else
        -- Refresh the reference as timing conditions change.
        c.bestScore = average
    end

    if average >= 99 then
        c.bestScore = average
        c.bestThreshold = c.threshold
        return
    end

    local candidate = c.bestThreshold + c.direction
    if candidate < 94 or candidate > 99 or c.tried[candidate] then
        c.direction = -c.direction
        candidate = c.bestThreshold + c.direction
    end
    if candidate >= 94 and candidate <= 99 and not c.tried[candidate] then
        c.threshold = candidate
    else
        c.threshold = c.bestThreshold
        c.tried = {[c.bestThreshold] = true}
    end
end

-- A stable value after a recent moving bar is only a result candidate.
-- Reject timeouts, resets, vanished UI and long frame stalls.
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
local previous
local armed = false
local lastClick = -math.huge
local connections = {}
local shot
local waitingForNewRound = false
local lastMovement = -math.huge

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
    Text = "AUTO LAUNCH v2",
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
    previous = nil
    armed = false
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
connect(RunService.Heartbeat, function(dt)
    if not alive or not target then return end
    local percent = read(target)
    local now = os.clock()

    if shot then
        local outcome, score = observeResult(shot, percent, now, dt)
        if outcome == "accept" then
            recordResult(calibration, score)
            resultLabel.Text = "Resultado detectado: " .. score
                .. "% | Muestras: " .. #calibration.scores .. "/3"
            shot = nil
        elseif outcome == "reject" then
            resultLabel.Text = "Resultado no confirmado; sin ajuste"
            shot = nil
        end
        if shot then
            status.Text = "Leyendo resultado..."
            return
        end
    end

    if percent == nil then
        target = nil
        reset()
        status.Text = "Esperando la barra..."
        return
    end
    if not enabled then
        reset()
        status.Text = "OFF - Barra: " .. percent .. "%"
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
    local old = previous
    local recentMovement = now - lastMovement < 0.2
    previous = percent
    if old ~= nil and old ~= percent then lastMovement = now end
    if percent < calibration.threshold then
        armed = true
        status.Text = "ON - Barra: " .. percent .. "%"
        return
    end
    local crossed = armed and old ~= nil
        and old < calibration.threshold
        and percent >= calibration.threshold and percent > old
    if not crossed then return end
    armed = false
    if dt > 0.1 or now - lastClick < COOLDOWN then return end
    local confirmed = read(target)
    if not confirmed or confirmed < calibration.threshold
        or confirmed < percent then return end

    lastClick = now
    waitingForNewRound = true
    local ok, err = pcall(click)
    if ok then
        if recentMovement then
            shot = {started = now, changed = now, value = confirmed}
        else
            resultLabel.Text = "Movimiento insuficiente; sin ajuste"
        end
        status.Text = "Clic enviado"
    else
        enabled = false
        reset()
        paintToggle()
        status.Text = "Error al enviar el clic"
        warn("Auto Launch: " .. tostring(err))
    end
end)

env.StopAutoLaunch = function()
    if not alive then return end
    alive = false
    enabled = false
    for _, connection in ipairs(connections) do connection:Disconnect() end
    gui:Destroy()
end


