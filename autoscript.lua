--[[
    AutoScript - Combined AutoTrade + AutoFarm + AutoEgg GUI
    Local server only.
--]]

local Players    = game:GetService("Players")
local CS         = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Fsys = require(game.ReplicatedStorage:WaitForChild("Fsys")).load
local RouterClient       = Fsys("RouterClient")
local ClientData         = Fsys("ClientData")
local AilmentsClient     = Fsys("new:AilmentsClient")
local EquippedPets       = Fsys("EquippedPets")
local CharWrapperClient  = Fsys("CharWrapperClient")
local StateManagerClient = Fsys("StateManagerClient")

-- ============================================================
-- CONFIG: flip DISABLE_RENDER to false if the farm can't find
-- furniture (keeps rendering on so the world loads normally).
-- ============================================================
local DISABLE_RENDER = true

-- Forward declarations so sendStatus (defined below) can reach these;
-- they get assigned further down once the GUI / farm / egg logic is built.
local startFarm, stopFarm, startEgg, stopEgg
local usernameBox, totalEggsBox, startTradeBtn

-- ============================================================
-- AUTO JOIN: wait for load -> choose team -> spawn home ->
-- hide menu GUI -> then kill rendering (deferred until in-game)
-- ============================================================
task.spawn(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    local t = 0
    while not LocalPlayer.Character and t < 20 do task.wait(0.5); t = t + 0.5 end
    task.wait(2)

    -- dismiss news, choose Babies team, spawn at home (retry a few times)
    for _ = 1, 5 do
        pcall(function() RouterClient.get("MainMenuAPI/ViewedNews"):FireServer() end)
        task.wait(0.3)
        pcall(function()
            RouterClient.get("TeamAPI/ChooseTeam"):InvokeServer("Babies", {
                dont_send_back_home = false, source_for_logging = "autoscript"
            })
        end)
        task.wait(0.3)
        pcall(function()
            RouterClient.get("TeamAPI/Spawn"):InvokeServer("home", { source_for_logging = "autoscript" })
        end)
        task.wait(1)
    end

    -- best-effort: hide leftover main-menu / play / news GUIs (skips our own)
    pcall(function()
        for _, g in ipairs(LocalPlayer.PlayerGui:GetChildren()) do
            if g:IsA("ScreenGui") and g.Name ~= "AutoScriptGui" then
                local n = g.Name:lower()
                if n:find("menu") or n:find("play") or n:find("title") or n:find("news") then
                    g.Enabled = false
                end
            end
        end
    end)

    -- now that we're in-game, kill rendering to save CPU (GPU-less host)
    if DISABLE_RENDER then
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
        pcall(function()
            UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualityLevel.QualityLevel1
        end)
        pcall(function()
            local Lighting = game:GetService("Lighting")
            Lighting.GlobalShadows = false
            Lighting.FogEnd = 9e9
            for _, e in ipairs(Lighting:GetChildren()) do
                if e:IsA("PostEffect") then e.Enabled = false end
            end
        end)
        for _ = 1, 5 do
            task.wait(2)
            pcall(function() RunService:Set3dRenderingEnabled(false) end)
        end
    end
end)

-- ============================================================
-- TRADE CONFIG
-- ============================================================
local WAIT_AFTER_ACCEPT  = 1
local WAIT_AFTER_ADD     = 0.1
local WAIT_FOR_LOCK      = 6
local WAIT_FOR_CONF_LOCK = 0.1
local WAIT_STATE_CLEAR   = 5
local MAX_WAIT_STATE     = 15
local MAX_PER_TRADE      = 18

local EGG_OPTIONS = {
    { label = "Crystal Egg", kind = "pet_recycler_2025_crystal_egg" },
}
local selectedEggIndex = 1

-- ============================================================
-- FARM CONFIG
-- ============================================================
local FARM_LOOP_INTERVAL = 0.5
local FARM_TP_OFFSET     = Vector3.new(0, 4, 0)
local FARM_USE_WAIT      = 0.3

local AILMENT_USE_ID = {
    ["dirty"]   = "dirty",
    ["hungry"]  = "hungry",
    ["thirsty"] = "thirsty",
    ["toilet"]  = "toilet",
    ["sleepy"]  = "sleepy",
    ["sick"]    = "sick",
}

local AILMENT_USE_ID_FALLBACK = {
    ["toilet"]  = "ailments_refresh_2024_litter_box",
    ["hungry"]  = "ailments_refresh_2024_cheap_food_bowl",
    ["thirsty"] = "ailments_refresh_2024_cheap_water_bowl",
    ["dirty"]   = "generic_bathtub",
    ["sleepy"]  = "generic_crib",
    ["sick"]    = "hospital_refresh_2023_healing_bed",
}

local AILMENT_LOCATION = {}

local AILMENT_MOVEMENT = {
    ["walk"]   = true,
    ["play"]   = true,
    ["pet_me"] = true,
}

-- Ailments we skip entirely (game handles them automatically)
local AILMENT_SKIP = {
    ["journey_2026_truck_repair"] = true,
    ["at_work"]     = true,
    ["salon"]       = true,
    ["school"]      = true,
    ["beach_party"] = true,
    ["camping"]     = true,
    ["party_zone"]  = true,
    ["pizza_party"] = true,
    ["ride"]        = true,
    ["bored"]       = true,
    ["mystery"]     = true,
    -- weather ailments (handled by game world)
    ["diving_board"] = true,
    ["leaf_pile"]    = true,
    ["rain_puddle"]  = true,
    ["snowman"]      = true,
}

-- ============================================================
-- EGG BUY OPTIONS
-- ============================================================
local EGG_BUY_OPTIONS = {
    { label = "Cracked Egg (350)",    kind = "cracked_egg",                     category = "pets" },
    { label = "Pet Egg (600)",        kind = "pet_egg",                          category = "pets" },
    { label = "Endangered Egg (750)", kind = "endangered_2026_endangered_egg",   category = "pets" },
    { label = "Moon Egg (750)",       kind = "moon_2025_egg",                    category = "pets" },
    { label = "Aztec Egg (750)",      kind = "aztec_egg_2025_aztec_egg",         category = "pets" },
    { label = "Garden Egg (750)",     kind = "garden_2024_egg",                  category = "pets" },
    { label = "Desert Egg (750)",     kind = "desert_2024_egg",                  category = "pets" },
    { label = "Royal Egg (1450)",     kind = "royal_egg",                        category = "pets" },
}
local selectedEggBuyIndex = 1

-- ============================================================
-- TRADE HELPERS
-- ============================================================
local function calcBatches(totalEggs)
    local batches, remaining = {}, totalEggs
    while remaining > 0 do
        local b = math.min(remaining, MAX_PER_TRADE)
        table.insert(batches, b)
        remaining = remaining - b
    end
    return batches
end

local function getEggUniques(eggKind, count)
    local inventory = ClientData.get("inventory") or {}
    local found = {}
    for _, items in pairs(inventory) do
        for unique, item in pairs(items) do
            if item.kind == eggKind then
                table.insert(found, unique)
                if #found >= count then return found end
            end
        end
    end
    return found
end

local function waitForTradeStateClear()
    local elapsed = 0
    while elapsed < MAX_WAIT_STATE do
        if ClientData.get("trade") == nil then return true end
        task.wait(0.25); elapsed = elapsed + 0.25
    end
    return false
end

local function waitForNewNegotiationStage(lastId)
    local elapsed = 0
    while elapsed < MAX_WAIT_STATE do
        local s = ClientData.get("trade")
        if s and s.current_stage == "negotiation" and s.trade_id ~= lastId then
            return true, s.trade_id
        end
        task.wait(0.25); elapsed = elapsed + 0.25
    end
    return false, nil
end

local function waitForConfirmationStage(tradeId)
    local elapsed = 0
    while elapsed < 30 do
        local s = ClientData.get("trade")
        if s and s.current_stage == "confirmation" and s.trade_id == tradeId then return true end
        task.wait(0.25); elapsed = elapsed + 0.25
    end
    return false
end

-- ============================================================
-- FARM HELPERS
-- ============================================================
local function getCharWrappers()
    local wrappers = {}

    -- Own character first (baby ailments)
    local char = LocalPlayer.Character
    if char then
        local ok, w = pcall(function() return CharWrapperClient.get(char) end)
        if ok and w then table.insert(wrappers, w) end
    end

    -- Equipped pets
    local ok1, w1 = pcall(function() return EquippedPets.get_my_equipped_char_wrappers() end)
    if ok1 and w1 then
        for _, w in ipairs(w1) do table.insert(wrappers, w) end
    end

    if #wrappers <= 1 then
        local petWrappers = ClientData.get("pet_char_wrappers")
        if petWrappers then
            for _, c in pairs(petWrappers) do
                local w = CharWrapperClient.get and CharWrapperClient.get(c)
                if w then table.insert(wrappers, w) end
            end
        end
    end

    if #wrappers <= 1 then
        local sm = ClientData.get("state_manager")
        if sm then
            local connected = StateManagerClient.get_chars_connected_to_me
                and StateManagerClient.get_chars_connected_to_me(sm)
            if connected then
                for _, c in pairs(connected) do
                    local w = CharWrapperClient.get and CharWrapperClient.get(c)
                    if w then table.insert(wrappers, w) end
                end
            end
        end
    end

    return wrappers
end

local function getActiveAilments(statusLabel)
    local results = {}
    local wrappers = getCharWrappers()
    if statusLabel then
        statusLabel.Text = "Wrappers: " .. #wrappers
    end
    for _, w in ipairs(wrappers) do
        local ok, ailments = pcall(function()
            return AilmentsClient.get_ailments_for_pet(w)
        end)
        if ok and ailments then
            for _, a in pairs(ailments) do
                if a and a.kind then
                    local progress = a.get_progress and a:get_progress() or (a.progress or 0)
                    if progress < 1 then
                        table.insert(results, { kind = a.kind, progress = progress })
                    end
                end
            end
        end
    end
    table.sort(results, function(a, b) return a.progress < b.progress end)
    return results
end

local function getPetChar()
    local wrappers = getCharWrappers()
    -- skip index 1 (own char), return first pet
    for i = 2, #wrappers do
        if wrappers[i].char then return wrappers[i].char end
    end
    return nil
end

local function findNearestFurniture(root, targetAilmentKind)
    local best, bestDist = nil, math.huge

    local ok, AilmentsFurnitureHelper = pcall(Fsys, "AilmentsFurnitureHelper")
    local ok2, FurnitureModelTracker  = pcall(Fsys, "FurnitureModelTracker")
    if ok and AilmentsFurnitureHelper and ok2 and FurnitureModelTracker then
        local models = FurnitureModelTracker.get_furniture_models_list()
        if models then
            for _, model in pairs(models) do
                local valid = pcall(function()
                    return AilmentsFurnitureHelper.is_furniture_model_valid(model, targetAilmentKind)
                end)
                if valid then
                    local p = model:FindFirstChild("PlacementBlock") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
                    if p then
                        local d = (root.Position - p.Position).Magnitude
                        if d < bestDist then
                            best = { unique = model:GetAttribute("furniture_unique"), model = model, player = nil }
                            bestDist = d
                        end
                    end
                end
            end
        end
    end

    if not best then
        for _, obj in workspace:GetDescendants() do
            if obj:IsA("Model") then
                local kind = obj:GetAttribute("furniture_kind")
                if kind then
                    local ok3, valid = pcall(function()
                        local AFH = Fsys("AilmentsFurnitureHelper")
                        return AFH.is_furniture_valid(kind, targetAilmentKind, obj)
                    end)
                    if ok3 and valid then
                        local p = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
                        if p then
                            local d = (root.Position - p.Position).Magnitude
                            if d < bestDist then
                                best = { unique = obj:GetAttribute("furniture_unique"), model = obj, player = nil }
                                bestDist = d
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

local function getHouseOwner()
    local ok, InteriorsM = pcall(Fsys, "InteriorsM")
    if ok and InteriorsM then
        local loc = InteriorsM.get_current_location and InteriorsM.get_current_location()
        if loc and loc.house_owner then return loc.house_owner end
    end
    return LocalPlayer
end

local function isInHouse()
    local ok, InteriorsM = pcall(Fsys, "InteriorsM")
    if not ok or not InteriorsM then return false end
    local loc = InteriorsM.get_current_location and InteriorsM.get_current_location()
    return loc ~= nil and loc.destination_id == "housing"
end

local function getHouseDoor()
    local houseExteriors = workspace:FindFirstChild("HouseExteriors")
    if houseExteriors then
        for _, plot in houseExteriors:GetChildren() do
            local house = plot:GetChildren()[1]
            if house then
                local door = house:FindFirstChild("Doors") and house.Doors:FindFirstChild("MainDoor")
                if door then
                    local config = door:FindFirstChild("WorkingParts") and door.WorkingParts:FindFirstChild("Configuration")
                    local ownerVal = config and config:FindFirstChild("house_owner")
                    if ownerVal and ownerVal.Value == LocalPlayer.Name then
                        return door
                    end
                end
            end
        end
    end
    return nil
end

local function activateFurniture(entry)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local model = entry.model
    local unique = model:GetAttribute("furniture_unique") or entry.unique
    if not unique then return false end
    local useBlocks = model:FindFirstChild("UseBlocks")
    local useBlock = useBlocks and useBlocks:FindFirstChildWhichIsA("BasePart")
        or model:FindFirstChild("UseBlock", true)
        or model:FindFirstChildWhichIsA("BasePart")
    if not useBlock then return false end
    root.CFrame = CFrame.new(useBlock.Position + FARM_TP_OFFSET)
    task.wait(FARM_USE_WAIT)
    local payload = { cframe = useBlock.CFrame * CFrame.new(0, useBlock.Size.Y / 2, 0) }
    local owner = entry.player or getHouseOwner()
    local petChar = getPetChar() or char
    RouterClient.get("HousingAPI/ActivateFurniture"):InvokeServer(owner, unique, useBlock.Name, payload, petChar)
    return true
end

local function becomeBaby()
    local team = ClientData.get("team")
    if team ~= "Babies" then
        task.spawn(function()
            RouterClient.get("TeamAPI/ChooseTeam"):InvokeServer("Babies", {
                dont_send_back_home = true,
                source_for_logging = "autofarm"
            })
        end)
        task.wait(0.5)
    end
end

local function claimPetPen()
    RouterClient.get("IdleProgressionAPI/CommitAllProgression"):FireServer()
end

-- Fire a remote, trying InvokeServer first then FireServer, all pcall-safe.
local function tryRemote(name)
    if not pcall(function() RouterClient.get(name):InvokeServer() end) then
        pcall(function() RouterClient.get(name):FireServer() end)
    end
end

-- Claims daily rewards + cashout/deliveries. Names verified from the RS dump.
local function claimExtras()
    tryRemote("DailyLoginAPI/ClaimDailyReward")
    tryRemote("DailyLoginAPI/ClaimStarReward")
    tryRemote("HousingAPI/ClaimAllDeliveries")
    tryRemote("LootBoxAPI/ClaimLoginHandouts")
end

local function fillPetPen()
    local penData = ClientData.get("idle_progression") or {}
    local activePets = penData.active_pets or {}
    local count = 0
    for _ in pairs(activePets) do count = count + 1 end
    if count >= 4 then return end
    local inventory = ClientData.get("inventory") or {}
    local pets = inventory.pets or {}
    local added = 0
    for unique, _ in pairs(pets) do
        if count + added >= 4 then break end
        if not activePets[unique] then
            RouterClient.get("IdleProgressionAPI/AddPet"):FireServer(unique)
            added = added + 1
            task.wait(0.1)
        end
    end
end

local function claimMoneyTree()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local found = CS:GetTagged("furniture:moneytree")
    if #found == 0 then
        local placeCFrame = root.CFrame * CFrame.new(3, 0, 0)
        local result = RouterClient.get("HousingAPI/BuyFurnitures"):InvokeServer({
            { ["kind"] = "moneytree", ["properties"] = { ["cframe"] = placeCFrame } }
        })
        if result and result.success then task.wait(1) end
        return
    end
    for _, model in found do
        local entry = { unique = model:GetAttribute("furniture_unique"), model = model, player = nil }
        pcall(activateFurniture, entry)
        task.wait(0.2)
    end
end

local farming   = false
local trading   = false
local eggBuying = false

-- ============================================================
-- WEBHOOK CONFIG
-- ============================================================
local SERVER_URL     = "http://152.53.144.174:5000"
local INSTANCE_ID    = LocalPlayer.Name  -- unique per instance (the account name)
local WEBHOOK_SECRET  = "7f3a9c2e5b8d1064a2e7c9f04b6d8135" -- must match WEBHOOK_SECRET on the server

local HttpService = game:GetService("HttpService")

local currentMode   = "idle"
local currentStatus = "idle"

local function getEggCounts()
    local inventory = ClientData.get("inventory") or {}
    local counts = {}
    local pets = inventory.pets or {}
    for _, item in pairs(pets) do
        if item.kind and item.kind:find("egg") then
            counts[item.kind] = (counts[item.kind] or 0) + 1
        end
    end
    return counts
end

local function sendStatus()
    local bucks = ClientData.get("money") or 0
    local eggs  = getEggCounts()
    pcall(function()
        local response = HttpService:RequestAsync({
            Url = SERVER_URL .. "/update",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({
                instance_id = INSTANCE_ID,
                secret      = WEBHOOK_SECRET,
                username    = LocalPlayer.Name,
                job_id      = game.JobId,
                bucks       = bucks,
                eggs        = eggs,
                status      = currentStatus,
                mode        = currentMode,
            })
        })
        if response.Success then
            local data = HttpService:JSONDecode(response.Body)
            local cmd  = data.command
            if cmd then
                if cmd == "start_farm" and not farming then
                    startFarm()
                elseif cmd == "stop_farm" and farming then
                    stopFarm()
                elseif cmd == "start_egg" and not eggBuying then
                    startEgg()
                elseif cmd == "stop_egg" and eggBuying then
                    stopEgg()
                elseif cmd:sub(1, 6) == "trade:" then
                    local parts = cmd:split(":")
                    local target = parts[2]
                    local count  = tonumber(parts[3])
                    if target and count then
                        usernameBox.Text  = target
                        totalEggsBox.Text = tostring(count)
                        if not trading then
                            startTradeBtn.MouseButton1Click:Fire()
                        end
                    end
                end
            end
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(5)
        pcall(sendStatus)
    end
end)

local function ensureInHouse(setFarmStatus)
    if isInHouse() then return end
    setFarmStatus("Going to house...")

    local ok, InteriorsM = pcall(Fsys, "InteriorsM")
    if ok and InteriorsM then
        local loc = InteriorsM.get_current_location and InteriorsM.get_current_location()
        if loc and loc.destination_id ~= "housing" then
            pcall(function() InteriorsM.exit_smooth() end)
            task.wait(2)
        end
        pcall(function()
            InteriorsM.enter_smooth("housing", "MainDoor", { house_owner = LocalPlayer })
        end)
        local timeout = 0
        while timeout < 8 do
            task.wait(0.2); timeout = timeout + 0.2
            if isInHouse() then setFarmStatus("In house!"); return end
        end
    end

    local char     = LocalPlayer.Character
    local root     = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChild("Humanoid")
    if not root or not humanoid then return end
    local door = getHouseDoor()
    if door then
        local touchToEnter = door:FindFirstChild("WorkingParts") and door.WorkingParts:FindFirstChild("TouchToEnter")
        if touchToEnter then
            local doorCFrame = touchToEnter.CFrame
            local behind = doorCFrame * CFrame.new(0, 0, 3)
            root.CFrame = CFrame.new(behind.Position + Vector3.new(0, 3, 0))
            task.wait(0.1)
            humanoid:MoveTo(touchToEnter.Position)
            task.wait(0.3)
            root.CFrame = CFrame.new(touchToEnter.Position + Vector3.new(0, 2, 0))
        end
    end
    local timeout = 0
    while timeout < 5 do
        task.wait(0.1); timeout = timeout + 0.1
        if isInHouse() then setFarmStatus("In house!"); return end
    end
end

-- ============================================================
-- GUI HELPERS
-- ============================================================
local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = inst
end

local function label(parent, text, x, y, w, h, size, color, bold, wrap)
    local l = Instance.new("TextLabel")
    l.Position = UDim2.new(0, x, 0, y)
    l.Size = UDim2.new(0, w, 0, h)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextSize = size or 11
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextColor3 = color or Color3.fromRGB(180, 180, 180)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextWrapped = wrap or false
    l.Parent = parent
    return l
end

local function textbox(parent, x, y, w, h, placeholder)
    local b = Instance.new("TextBox")
    b.Position = UDim2.new(0, x, 0, y)
    b.Size = UDim2.new(0, w, 0, h)
    b.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    b.BorderSizePixel = 0
    b.Text = ""
    b.PlaceholderText = placeholder or ""
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.PlaceholderColor3 = Color3.fromRGB(110, 110, 110)
    b.TextSize = 12
    b.Font = Enum.Font.Gotham
    b.ClearTextOnFocus = false
    b.Parent = parent
    corner(b, 5)
    return b
end

local function button(parent, text, x, y, w, h, color)
    local b = Instance.new("TextButton")
    b.Position = UDim2.new(0, x, 0, y)
    b.Size = UDim2.new(0, w, 0, h)
    b.BackgroundColor3 = color or Color3.fromRGB(60, 60, 60)
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 12
    b.Font = Enum.Font.GothamBold
    b.Parent = parent
    corner(b, 6)
    return b
end

-- ============================================================
-- MAIN GUI
-- ============================================================
local W, H = 200, 270

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoScriptGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = LocalPlayer.PlayerGui

local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0, 10, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.ClipsDescendants = true
main.Parent = screenGui
corner(main, 8)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 28)
titleBar.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
corner(titleBar, 8)

label(titleBar, "AutoScript", 8, 0, 140, 28, 12, Color3.fromRGB(255,255,255), true)

local minimized = false
local minBtn = button(titleBar, "-", W-46, 4, 20, 20, Color3.fromRGB(60,60,60))
minBtn.TextSize = 11
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    main.Size = UDim2.new(0, W, 0, minimized and 28 or H)
    minBtn.Text = minimized and "+" or "-"
end)

local closeBtn = button(titleBar, "X", W-24, 4, 20, 20, Color3.fromRGB(170,50,50))
closeBtn.TextSize = 11
closeBtn.MouseButton1Click:Connect(function()
    farming = false; trading = false; eggBuying = false
    screenGui:Destroy()
end)

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, 24)
tabBar.Position = UDim2.new(0, 0, 0, 28)
tabBar.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
tabBar.BorderSizePixel = 0
tabBar.Parent = main

local activeTab = "trade"
local tabW = math.floor((W - 8) / 3)
local tabTrade = button(tabBar, "Trade", 2, 2, tabW, 20, Color3.fromRGB(0, 150, 90))
local tabFarm  = button(tabBar, "Farm",  4 + tabW, 2, tabW, 20, Color3.fromRGB(50, 50, 50))
local tabEgg   = button(tabBar, "Egg",   6 + tabW*2, 2, tabW, 20, Color3.fromRGB(50, 50, 50))
tabTrade.TextSize = 10; tabFarm.TextSize = 10; tabEgg.TextSize = 10

local tradePanel = Instance.new("Frame")
tradePanel.Size = UDim2.new(1, 0, 1, -52)
tradePanel.Position = UDim2.new(0, 0, 0, 52)
tradePanel.BackgroundTransparency = 1
tradePanel.Parent = main

local farmPanel = Instance.new("Frame")
farmPanel.Size = UDim2.new(1, 0, 1, -52)
farmPanel.Position = UDim2.new(0, 0, 0, 52)
farmPanel.BackgroundTransparency = 1
farmPanel.Visible = false
farmPanel.Parent = main

local eggPanel = Instance.new("Frame")
eggPanel.Size = UDim2.new(1, 0, 1, -52)
eggPanel.Position = UDim2.new(0, 0, 0, 52)
eggPanel.BackgroundTransparency = 1
eggPanel.Visible = false
eggPanel.Parent = main

local function switchTab(tab)
    activeTab = tab
    tradePanel.Visible = tab == "trade"
    farmPanel.Visible  = tab == "farm"
    eggPanel.Visible   = tab == "egg"
    tabTrade.BackgroundColor3 = tab == "trade" and Color3.fromRGB(0,150,90)  or Color3.fromRGB(50,50,50)
    tabFarm.BackgroundColor3  = tab == "farm"  and Color3.fromRGB(0,120,180) or Color3.fromRGB(50,50,50)
    tabEgg.BackgroundColor3   = tab == "egg"   and Color3.fromRGB(180,120,0) or Color3.fromRGB(50,50,50)
end

tabTrade.MouseButton1Click:Connect(function() switchTab("trade") end)
tabFarm.MouseButton1Click:Connect(function()  switchTab("farm")  end)
tabEgg.MouseButton1Click:Connect(function()   switchTab("egg")   end)

local PW = W - 12

-- ============================================================
-- TRADE PANEL
-- ============================================================
local y = 4
label(tradePanel, "Username", 6, y, PW, 12, 10)
usernameBox = textbox(tradePanel, 6, y+13, PW, 22, "e.g. AltAccount123")
y = y + 38

label(tradePanel, "Egg Type", 6, y, PW, 12, 10)
local eggDropdown = button(tradePanel, EGG_OPTIONS[1].label, 6, y+13, PW, 22, Color3.fromRGB(50,50,50))
eggDropdown.TextSize = 10; eggDropdown.Font = Enum.Font.Gotham
local arrowLbl = label(eggDropdown, "v", PW-16, 0, 16, 22, 10, Color3.fromRGB(180,180,180))

local dropMenu = Instance.new("Frame")
dropMenu.Size = UDim2.new(0, PW, 0, #EGG_OPTIONS * 22)
dropMenu.Position = UDim2.new(0, 6, 0, y+37)
dropMenu.BackgroundColor3 = Color3.fromRGB(45,45,45)
dropMenu.BorderSizePixel = 0
dropMenu.Visible = false
dropMenu.ZIndex = 10
dropMenu.Parent = tradePanel
corner(dropMenu, 4)

for i, opt in ipairs(EGG_OPTIONS) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 22)
    b.Position = UDim2.new(0, 0, 0, (i-1)*22)
    b.BackgroundTransparency = 1
    b.Text = opt.label
    b.TextColor3 = Color3.fromRGB(255,255,255)
    b.TextSize = 10; b.Font = Enum.Font.Gotham
    b.ZIndex = 11; b.Parent = dropMenu
    b.MouseButton1Click:Connect(function()
        selectedEggIndex = i
        eggDropdown.Text = opt.label
        dropMenu.Visible = false
        arrowLbl.Text = "v"
    end)
end

eggDropdown.MouseButton1Click:Connect(function()
    dropMenu.Visible = not dropMenu.Visible
    arrowLbl.Text = dropMenu.Visible and "^" or "v"
end)

y = y + 38
label(tradePanel, "Total Eggs", 6, y, PW, 12, 10)
totalEggsBox = textbox(tradePanel, 6, y+13, PW, 22, "e.g. 100")
y = y + 38

local breakdownLabel = label(tradePanel, "", 6, y, PW, 20, 10, Color3.fromRGB(140,200,255), false, true)
y = y + 22

local tradeStatusLabel = label(tradePanel, "Status: Idle", 6, y, PW, 14, 10, Color3.fromRGB(100,220,100), false, true)
y = y + 16

startTradeBtn = button(tradePanel, "Start Auto Trade", 6, y, PW, 26, Color3.fromRGB(0,160,90))
startTradeBtn.TextSize = 11

totalEggsBox:GetPropertyChangedSignal("Text"):Connect(function()
    local n = tonumber(totalEggsBox.Text)
    if not n or n < 1 then breakdownLabel.Text = ""; return end
    n = math.floor(n)
    local batches = calcBatches(n)
    local rem = n % MAX_PER_TRADE
    if rem == 0 then
        breakdownLabel.Text = #batches .. " trades x " .. MAX_PER_TRADE .. " eggs"
    else
        breakdownLabel.Text = (#batches-1) .. " x " .. MAX_PER_TRADE .. "  +  1 x " .. rem .. "  =  " .. #batches .. " trades"
    end
end)

local function setTradeStatus(msg, color)
    tradeStatusLabel.Text = "Status: " .. msg
    tradeStatusLabel.TextColor3 = color or Color3.fromRGB(100,220,100)
end

local lastTradeId = nil

local function doOneTrade(targetPlayer, batchSize, eggKind)
    setTradeStatus("Waiting for state clear...")
    if not waitForTradeStateClear() then error("Trade state did not clear") end
    setTradeStatus("Sending request...")
    RouterClient.get("TradeAPI/SendTradeRequest"):FireServer(targetPlayer)
    setTradeStatus("Waiting for trade to open...")
    local opened, newId = waitForNewNegotiationStage(lastTradeId)
    if not opened then error("Trade never opened") end
    lastTradeId = newId
    task.wait(WAIT_AFTER_ACCEPT)
    local eggs = getEggUniques(eggKind, batchSize)
    if #eggs < batchSize then error("Not enough eggs: " .. #eggs .. "/" .. batchSize) end
    for i, unique in ipairs(eggs) do
        setTradeStatus("Adding egg " .. i .. "/" .. #eggs)
        RouterClient.get("TradeAPI/AddItemToOffer"):FireServer(unique)
        task.wait(WAIT_AFTER_ADD)
    end
    setTradeStatus("Waiting for lock...")
    task.wait(WAIT_FOR_LOCK)
    setTradeStatus("Accepting...")
    RouterClient.get("TradeAPI/AcceptNegotiation"):FireServer()
    setTradeStatus("Waiting for confirmation...")
    if not waitForConfirmationStage(lastTradeId) then error("Never reached confirmation") end
    task.wait(WAIT_FOR_CONF_LOCK)
    setTradeStatus("Confirming...")
    RouterClient.get("TradeAPI/ConfirmTrade"):FireServer()
    setTradeStatus("Waiting for close...")
    task.wait(WAIT_STATE_CLEAR)
end

startTradeBtn.MouseButton1Click:Connect(function()
    if trading then return end
    local username  = usernameBox.Text
    local eggKind   = EGG_OPTIONS[selectedEggIndex].kind
    local totalEggs = math.floor(tonumber(totalEggsBox.Text) or 0)
    if username == "" then setTradeStatus("Enter a username!", Color3.fromRGB(255,80,80)); return end
    if totalEggs < 1  then setTradeStatus("Enter a valid egg count!", Color3.fromRGB(255,80,80)); return end
    local target = Players:FindFirstChild(username)
    if not target then setTradeStatus("Player not found!", Color3.fromRGB(255,80,80)); return end
    if target == LocalPlayer then setTradeStatus("Can't trade yourself!", Color3.fromRGB(255,80,80)); return end
    local batches = calcBatches(totalEggs)
    trading = true
    startTradeBtn.Text = "Running..."
    startTradeBtn.BackgroundColor3 = Color3.fromRGB(100,100,100)
    task.spawn(function()
        for i, batchSize in ipairs(batches) do
            setTradeStatus("Trade " .. i .. "/" .. #batches .. " (" .. batchSize .. " eggs)")
            local ok, err = pcall(doOneTrade, target, batchSize, eggKind)
            if not ok then
                setTradeStatus("Error: " .. tostring(err):sub(1,40), Color3.fromRGB(255,80,80))
                break
            end
        end
        setTradeStatus("Done!", Color3.fromRGB(100,220,100))
        startTradeBtn.Text = "Start Auto Trade"
        startTradeBtn.BackgroundColor3 = Color3.fromRGB(0,160,90)
        trading = false
    end)
end)

-- ============================================================
-- FARM PANEL
-- ============================================================
local farmStatusLabel = label(farmPanel, "Status: Idle", 6, 6,  PW, 14, 10, Color3.fromRGB(100,220,100), false, true)
local ailmentLabel    = label(farmPanel, "",             6, 22, PW, 40, 10, Color3.fromRGB(160,160,160), false, true)
local farmBtn = button(farmPanel, "Start AutoFarm", 6, 66, PW, 26, Color3.fromRGB(0,120,180))
farmBtn.TextSize = 11

local function setFarmStatus(msg, color)
    currentStatus = msg
    farmStatusLabel.Text = "Status: " .. msg
    farmStatusLabel.TextColor3 = color or Color3.fromRGB(100,220,100)
end

local farmThread = nil

function stopFarm()
    farming = false
    currentMode = "idle"; currentStatus = "stopped"
    if farmThread then task.cancel(farmThread); farmThread = nil end
    farmBtn.Text = "Start AutoFarm"
    farmBtn.BackgroundColor3 = Color3.fromRGB(0,120,180)
    setFarmStatus("Stopped", Color3.fromRGB(200,100,100))
    ailmentLabel.Text = ""
end

function startFarm()
    farming = true; currentMode = "farm"
    farmBtn.Text = "Stop AutoFarm"
    farmBtn.BackgroundColor3 = Color3.fromRGB(170,60,60)
    setFarmStatus("Starting...")
    becomeBaby()
    fillPetPen()
    claimPetPen()
    claimMoneyTree()
    claimExtras()
    local loopCount = 0
    farmThread = task.spawn(function()
        while farming do
            loopCount = loopCount + 1
            if loopCount % 60 == 0 then pcall(claimExtras) end   -- cashout/daily ~every 30s
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                ensureInHouse(setFarmStatus)
                -- force the house furniture to stream in even with rendering off
                pcall(function() LocalPlayer:RequestStreamAroundAsync(root.Position) end)
                task.wait(0.2)
                claimPetPen()
                fillPetPen()
                claimMoneyTree()
                local ailments = getActiveAilments(farmStatusLabel)
                if #ailments == 0 then
                    setFarmStatus("All happy!")
                    ailmentLabel.Text = ""
                else
                    local lines = {}
                    for _, a in ipairs(ailments) do
                        table.insert(lines, a.kind .. " " .. math.floor(a.progress*100) .. "%")
                    end
                    ailmentLabel.Text = table.concat(lines, "  |  ")

                    local fixable = nil
                    for _, a in ipairs(ailments) do
                        if not AILMENT_SKIP[a.kind] then
                            fixable = a; break
                        end
                    end

                    if not fixable then
                        setFarmStatus("No fixable ailments")
                    elseif fixable.kind == "dirty" then
                        -- Direct remote, no furniture needed
                        setFarmStatus("Fixing: dirty (direct)")
                        pcall(function()
                            RouterClient.get("AilmentsAPI/ProgressDirtyAilment"):FireServer()
                        end)
                        task.wait(1)
                    elseif fixable.kind == "pet_me" then
                        -- Direct remote
                        setFarmStatus("Fixing: pet_me (direct)")
                        local petChar = getPetChar()
                        if petChar then
                            pcall(function()
                                RouterClient.get("PetAPI/PetPetted"):FireServer(petChar)
                            end)
                            pcall(function()
                                RouterClient.get("AilmentsAPI/ProgressPetMeAilment"):FireServer()
                            end)
                        end
                        task.wait(0.5)
                    elseif AILMENT_MOVEMENT[fixable.kind] then
                        if fixable.kind == "play" then
                            setFarmStatus("Going to park for: play")
                            local trampoline = nil
                            local park = workspace:FindFirstChild("StaticMap") and workspace.StaticMap:FindFirstChild("Park")
                            if park then
                                local trampolines = park:FindFirstChild("Trampolines")
                                if trampolines then
                                    for _, group in pairs(trampolines:GetChildren()) do
                                        for _, obj in ipairs(group:GetChildren()) do
                                            if obj.Name == "Trampoline" or obj.Name == "HighTrampoline" then
                                                trampoline = obj; break
                                            end
                                        end
                                        if trampoline then break end
                                    end
                                end
                            end
                            if trampoline then
                                local petChar = getPetChar()
                                local petRoot = petChar and petChar:FindFirstChild("HumanoidRootPart")
                                if petRoot then
                                    petRoot.CFrame = CFrame.new(trampoline.Position + Vector3.new(0, 4, 0))
                                end
                                root.CFrame = CFrame.new(trampoline.Position + Vector3.new(3, 4, 0))
                                local waited = 0
                                while farming and waited < 60 do
                                    task.wait(1); waited = waited + 1
                                    local updated = getActiveAilments(nil)
                                    local still_active = false
                                    for _, a in ipairs(updated) do
                                        if a.kind == "play" then still_active = true; break end
                                    end
                                    if not still_active then break end
                                end
                                ensureInHouse(setFarmStatus)
                            else
                                setFarmStatus("No trampoline found", Color3.fromRGB(255,200,0))
                            end
                        elseif fixable.kind == "walk" then
                            setFarmStatus("Walking...")
                            local origin = root.Position
                            for i = 1, 16 do
                                if not farming then break end
                                local angle = (i / 16) * math.pi * 2
                                local offset = Vector3.new(math.cos(angle) * 8, 0, math.sin(angle) * 8)
                                root.CFrame = CFrame.new(origin + offset)
                                task.wait(0.15)
                            end
                        end
                    else
                        setFarmStatus("Fixing: " .. fixable.kind)
                        local furniture = findNearestFurniture(root, fixable.kind)
                        if not furniture and AILMENT_USE_ID_FALLBACK[fixable.kind] then
                            furniture = findNearestFurniture(root, AILMENT_USE_ID_FALLBACK[fixable.kind])
                        end
                        if furniture then
                            local ok2, err = pcall(activateFurniture, furniture)
                            if not ok2 then
                                setFarmStatus("Error: " .. tostring(err):sub(1,40), Color3.fromRGB(255,80,80))
                            end
                        else
                            setFarmStatus("No furniture: " .. fixable.kind, Color3.fromRGB(255,200,0))
                        end
                    end
                end
            else
                setFarmStatus("No character", Color3.fromRGB(255,200,0))
            end
            task.wait(FARM_LOOP_INTERVAL)
        end
    end)
end

farmBtn.MouseButton1Click:Connect(function()
    if farming then stopFarm() else startFarm() end
end)

-- ============================================================
-- EGG PANEL
-- ============================================================
local ey = 4
label(eggPanel, "Select Egg", 6, ey, PW, 12, 10)
local eggBuyDropdown = button(eggPanel, EGG_BUY_OPTIONS[1].label, 6, ey+13, PW, 22, Color3.fromRGB(50,50,50))
eggBuyDropdown.TextSize = 10; eggBuyDropdown.Font = Enum.Font.Gotham
local eggBuyArrow = label(eggBuyDropdown, "v", PW-16, 0, 16, 22, 10, Color3.fromRGB(180,180,180))

local eggBuyDropMenu = Instance.new("Frame")
eggBuyDropMenu.Size = UDim2.new(0, PW, 0, #EGG_BUY_OPTIONS * 20)
eggBuyDropMenu.Position = UDim2.new(0, 6, 0, ey+37)
eggBuyDropMenu.BackgroundColor3 = Color3.fromRGB(45,45,45)
eggBuyDropMenu.BorderSizePixel = 0
eggBuyDropMenu.Visible = false
eggBuyDropMenu.ZIndex = 10
eggBuyDropMenu.Parent = eggPanel
corner(eggBuyDropMenu, 4)

for i, opt in ipairs(EGG_BUY_OPTIONS) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 20)
    b.Position = UDim2.new(0, 0, 0, (i-1)*20)
    b.BackgroundTransparency = 1
    b.Text = opt.label
    b.TextColor3 = Color3.fromRGB(255,255,255)
    b.TextSize = 10; b.Font = Enum.Font.Gotham
    b.ZIndex = 11; b.Parent = eggBuyDropMenu
    b.MouseButton1Click:Connect(function()
        selectedEggBuyIndex = i
        eggBuyDropdown.Text = opt.label
        eggBuyDropMenu.Visible = false
        eggBuyArrow.Text = "v"
    end)
end

eggBuyDropdown.MouseButton1Click:Connect(function()
    eggBuyDropMenu.Visible = not eggBuyDropMenu.Visible
    eggBuyArrow.Text = eggBuyDropMenu.Visible and "^" or "v"
end)

ey = ey + 38
label(eggPanel, "Interval (secs)", 6, ey, PW, 12, 10)
local eggIntervalBox = textbox(eggPanel, 6, ey+13, PW, 22, "e.g. 30")
ey = ey + 38

local eggStatusLabel = label(eggPanel, "Status: Idle", 6, ey, PW, 14, 10, Color3.fromRGB(100,220,100), false, true)
ey = ey + 16
local eggBoughtLabel = label(eggPanel, "Bought: 0", 6, ey, PW, 12, 10, Color3.fromRGB(140,200,255))
ey = ey + 16
local startEggBtn = button(eggPanel, "Start AutoEgg", 6, ey, PW, 26, Color3.fromRGB(180,120,0))
startEggBtn.TextSize = 11

local function setEggStatus(msg, color)
    eggStatusLabel.Text = "Status: " .. msg
    eggStatusLabel.TextColor3 = color or Color3.fromRGB(100,220,100)
end

local eggThread = nil
local eggBoughtCount = 0

function stopEgg()
    eggBuying = false
    currentMode = "idle"; currentStatus = "stopped"
    if eggThread then task.cancel(eggThread); eggThread = nil end
    startEggBtn.Text = "Start AutoEgg"
    startEggBtn.BackgroundColor3 = Color3.fromRGB(180,120,0)
    setEggStatus("Stopped", Color3.fromRGB(200,100,100))
end

function startEgg()
    local interval = tonumber(eggIntervalBox.Text) or 30
    if interval < 1 then interval = 1 end
    local eggKind     = EGG_BUY_OPTIONS[selectedEggBuyIndex].kind
    local eggCategory = EGG_BUY_OPTIONS[selectedEggBuyIndex].category
    eggBuying = true; currentMode = "egg"
    eggBoughtCount = 0
    startEggBtn.Text = "Stop AutoEgg"
    startEggBtn.BackgroundColor3 = Color3.fromRGB(170,60,60)
    setEggStatus("Running...")
    eggThread = task.spawn(function()
        while eggBuying do
            local bucks = ClientData.get("money") or 0
            setEggStatus("Bucks: " .. bucks)
            local ok, err = pcall(function()
                RouterClient.get("ShopAPI/BuyItem"):InvokeServer(eggCategory, eggKind, { buy_count = 1 })
            end)
            if ok then
                eggBoughtCount = eggBoughtCount + 1
                eggBoughtLabel.Text = "Bought: " .. eggBoughtCount
                setEggStatus("Bought! Total: " .. eggBoughtCount)
            else
                setEggStatus("Failed: " .. tostring(err):sub(1,30), Color3.fromRGB(255,200,0))
            end
            task.wait(interval)
        end
    end)
end

startEggBtn.MouseButton1Click:Connect(function()
    if eggBuying then stopEgg() else startEgg() end
end)

switchTab("trade")
