--[[
    AutoScript - AutoTrade + AutoFarm + AutoEgg
    Ailment fixing via native FurnitureNavigationAction. Self-healing cooldowns.
    Anti-AFK included. Baby feed disabled (pets use bowls).
--]]

local Players     = game:GetService("Players")
local CS          = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local RS          = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local LocalPlayer = Players.LocalPlayer

-- Anti-AFK: reset the idle timer so Roblox won't disconnect after ~20 min
LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

local Fsys = require(RS:WaitForChild("Fsys")).load
local RouterClient       = Fsys("RouterClient")
local ClientData         = Fsys("ClientData")
local AilmentsClient     = Fsys("new:AilmentsClient")
local EquippedPets       = Fsys("EquippedPets")
local CharWrapperClient  = Fsys("CharWrapperClient")

local FNA = require(RS.new.modules.Ailments.ClientActions.FurnitureNavigationAction)
local AFH = require(RS.new.modules.Ailments.Helpers.AilmentsFurnitureHelper)

-- ============================================================
-- CONFIG
-- ============================================================
local SERVER_URL     = "http://152.53.144.174:5000"
local INSTANCE_ID    = LocalPlayer.Name
local WEBHOOK_SECRET = "7f3a9c2e5b8d1064a2e7c9f04b6d8135"

local FARM_LOOP_INTERVAL = 0.5
local MONEYTREE_EVERY    = 600
local FIX_TIMEOUT        = 30   -- give a fix up to 30s
local COOLDOWN           = 60   -- if it fails/stalls, skip that need for 60s

local AILMENT_FURNITURE = { sleepy = true, dirty = true, toilet = true, sick = true }
local AILMENT_FEED = { hungry = true, thirsty = true }  -- pets use bowl; baby feed disabled

local startFarm, stopFarm, startEgg, stopEgg
local usernameBox, totalEggsBox, startTradeBtn

-- ============================================================
-- STATE / DEBUG
-- ============================================================
local farming, trading, eggBuying = false, false, false
local currentMode   = "idle"
local currentStatus = "idle"
local debugEnabled  = false
local lastError     = ""
local dbgFurniture  = -1
local dbgInHouse    = false
local eggBoughtCount = 0
local ailmentCooldown = {}

local function logErr(where, err) lastError = tostring(where) .. ": " .. tostring(err):sub(1, 160) end

local function countFurniture()
    local okF, FMT = pcall(Fsys, "FurnitureModelTracker")
    if okF and FMT then
        local models = FMT.get_furniture_models_list()
        if models then local n = 0; for _ in pairs(models) do n = n + 1 end; return n end
    end
    return 0
end

local function isInHouse()
    local ok, IM = pcall(Fsys, "InteriorsM")
    if not ok or not IM then return false end
    local loc = IM.get_current_location and IM.get_current_location()
    return loc ~= nil and loc.destination_id == "housing"
end

-- ============================================================
-- AUTO JOIN
-- ============================================================
task.spawn(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    local t = 0
    while not LocalPlayer.Character and t < 40 do task.wait(0.5); t = t + 0.5 end
    task.wait(2)
    for _ = 1, 6 do
        pcall(function() RouterClient.get("MainMenuAPI/ViewedNews"):FireServer() end)
        task.wait(0.3)
        pcall(function() RouterClient.get("TeamAPI/ChooseTeam"):InvokeServer("Babies", { dont_send_back_home = false, source_for_logging = "autoscript" }) end)
        task.wait(0.3)
        pcall(function() RouterClient.get("TeamAPI/Spawn"):InvokeServer("home", { source_for_logging = "autoscript" }) end)
        if LocalPlayer.Character then break end
        task.wait(1)
    end
end)

-- ============================================================
-- TRADE CONFIG
-- ============================================================
local WAIT_AFTER_ACCEPT, WAIT_AFTER_ADD = 1, 0.1
local WAIT_FOR_LOCK, WAIT_FOR_CONF_LOCK = 6, 0.1
local WAIT_STATE_CLEAR, MAX_WAIT_STATE = 5, 15
local MAX_PER_TRADE = 18
local EGG_OPTIONS = { { label = "Crystal Egg", kind = "pet_recycler_2025_crystal_egg" } }
local selectedEggIndex = 1
local EGG_BUY_OPTIONS = {
    { label = "Cracked Egg (350)", kind = "cracked_egg", category = "pets" },
    { label = "Pet Egg (600)",     kind = "pet_egg",     category = "pets" },
    { label = "Royal Egg (1450)",  kind = "royal_egg",   category = "pets" },
}
local selectedEggBuyIndex = 1

-- ============================================================
-- TRADE HELPERS
-- ============================================================
local function calcBatches(totalEggs)
    local batches, remaining = {}, totalEggs
    while remaining > 0 do local b = math.min(remaining, MAX_PER_TRADE); table.insert(batches, b); remaining = remaining - b end
    return batches
end
local function getEggUniques(eggKind, count)
    local inventory = ClientData.get("inventory") or {}
    local found = {}
    for _, items in pairs(inventory) do
        for unique, item in pairs(items) do
            if item.kind == eggKind then table.insert(found, unique); if #found >= count then return found end end
        end
    end
    return found
end
local function waitForTradeStateClear()
    local e = 0; while e < MAX_WAIT_STATE do if ClientData.get("trade") == nil then return true end task.wait(0.25); e = e + 0.25 end; return false
end
local function waitForNewNegotiationStage(lastId)
    local e = 0
    while e < MAX_WAIT_STATE do
        local s = ClientData.get("trade")
        if s and s.current_stage == "negotiation" and s.trade_id ~= lastId then return true, s.trade_id end
        task.wait(0.25); e = e + 0.25
    end
    return false, nil
end
local function waitForConfirmationStage(tradeId)
    local e = 0
    while e < 30 do
        local s = ClientData.get("trade")
        if s and s.current_stage == "confirmation" and s.trade_id == tradeId then return true end
        task.wait(0.25); e = e + 0.25
    end
    return false
end

-- ============================================================
-- WRAPPERS / AILMENTS
-- ============================================================
local function getBabyWrapper()
    local char = LocalPlayer.Character
    if not char then return nil end
    local ok, w = pcall(function() return CharWrapperClient.get(char) end)
    if ok then return w end
    return nil
end
local function getCharWrappers()
    local wrappers = {}
    local baby = getBabyWrapper()
    if baby then table.insert(wrappers, { w = baby, tag = "baby" }) end
    local ok1, w1 = pcall(function() return EquippedPets.get_my_equipped_char_wrappers() end)
    if ok1 and w1 then for _, w in ipairs(w1) do table.insert(wrappers, { w = w, tag = "pet" }) end end
    if #wrappers <= 1 then
        local pw = ClientData.get("pet_char_wrappers")
        if pw then for _, c in pairs(pw) do local w = CharWrapperClient.get and CharWrapperClient.get(c); if w then table.insert(wrappers, { w = w, tag = "pet" }) end end end
    end
    return wrappers
end
-- returns list of { kind, progress, wrapper, tag, obj }
local function getActiveAilments()
    local results = {}
    for _, entry in ipairs(getCharWrappers()) do
        local ok, ailments = pcall(function() return AilmentsClient.get_ailments_for_pet(entry.w) end)
        if ok and ailments then
            for _, a in pairs(ailments) do
                if a and a.kind then
                    local progress = a.get_progress and a:get_progress() or (a.progress or 0)
                    if progress < 1 then
                        table.insert(results, { kind = a.kind, progress = progress, wrapper = entry.w, tag = entry.tag, obj = a })
                    end
                end
            end
        end
    end
    table.sort(results, function(a, b) return a.progress < b.progress end)
    return results
end
local function ailmentStillActive(kind, wrapper)
    local ok, ailments = pcall(function() return AilmentsClient.get_ailments_for_pet(wrapper) end)
    if ok and ailments then
        for _, a in pairs(ailments) do
            if a.kind == kind then
                local p = a.get_progress and a:get_progress() or (a.progress or 0)
                if p < 1 then return true end
            end
        end
    end
    return false
end

-- ============================================================
-- FURNITURE AILMENT FIX (native FurnitureNavigationAction)
-- ============================================================
local function fixFurnitureAilment(kind, wrapper)
    local pos
    pcall(function() pos = AFH.find_furniture_position(kind) end)
    if not pos then return false, "no furniture for " .. kind end
    local target
    if typeof(pos) == "Vector3" then target = pos
    elseif typeof(pos) == "CFrame" then target = pos.Position
    elseif type(pos) == "table" and pos.Position then target = pos.Position end
    if not target then return false, "bad furniture pos" end

    local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local ailingChar = wrapper and wrapper.char
    local isPet = ailingChar and ailingChar ~= LocalPlayer.Character
    local function park()
        if myRoot then myRoot.CFrame = CFrame.new(target + Vector3.new(0, 3, 0)) end
        if isPet then
            local pr = ailingChar:FindFirstChild("HumanoidRootPart")
            if pr then pr.CFrame = CFrame.new(target + Vector3.new(2.5, 3, 0)) end
        end
    end
    park(); task.wait(1)

    local action = FNA.new({ ailment_to_boost = kind })
    if not action:get_valid_interaction() then return false, "no interaction in range" end
    pcall(function() action:automatically_use_nearby_furniture(wrapper) end)

    local waited = 0
    while farming and waited < FIX_TIMEOUT do
        task.wait(2); waited = waited + 2
        park()
        if not ailmentStillActive(kind, wrapper) then
            pcall(function() action:stop() end)
            return true, "fixed in " .. waited .. "s"
        end
    end
    pcall(function() action:stop() end)
    return false, "timeout after " .. waited .. "s"
end

-- dispatcher: returns ok, info
local function tryFixAilment(a)
    if a.kind == "pet_me" then
        local petChar
        for _, e in ipairs(getCharWrappers()) do if e.tag == "pet" and e.w.char then petChar = e.w.char; break end end
        if petChar then
            pcall(function() RouterClient.get("PetAPI/PetPetted"):FireServer(petChar) end)
            pcall(function() RouterClient.get("AilmentsAPI/ProgressPetMeAilment"):FireServer() end)
        end
        task.wait(1)
        return not ailmentStillActive(a.kind, a.wrapper), "petted"
    elseif AILMENT_FURNITURE[a.kind] then
        return fixFurnitureAilment(a.kind, a.wrapper)
    elseif AILMENT_FEED[a.kind] then
        if a.tag == "pet" then return fixFurnitureAilment(a.kind, a.wrapper) end  -- pet: bowl
        return false, "baby feed disabled"
    end
    return false, "no handler"
end

local function isHandled(a)
    if a.kind == "pet_me" then return true end
    if AILMENT_FURNITURE[a.kind] then return true end
    if AILMENT_FEED[a.kind] then return a.tag == "pet" end  -- pet bowls only; baby feed off
    return false
end

-- ============================================================
-- MONEY TREE / INCOME
-- ============================================================
local function activateFurniture(entry)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root or not entry.model then return false end
    local useBlocks = entry.model:FindFirstChild("UseBlocks")
    local useBlock = (useBlocks and useBlocks:FindFirstChildWhichIsA("BasePart")) or entry.model.PrimaryPart or entry.model:FindFirstChildWhichIsA("BasePart")
    if not useBlock then return false end
    root.CFrame = CFrame.new(useBlock.Position + Vector3.new(0, 4, 0)); task.wait(0.3)
    local unique = entry.unique or entry.model:GetAttribute("furniture_unique")
    if not unique then return false end
    local useName = useBlock.Name
    local cfg = useBlock:FindFirstChild("Configuration")
    local useIdVal = cfg and cfg:FindFirstChild("use_id")
    if useIdVal and useIdVal.Value and useIdVal.Value ~= "" then useName = useIdVal.Value end
    local payload = { cframe = useBlock.CFrame * CFrame.new(0, useBlock.Size.Y / 2, 0) }
    task.spawn(function() pcall(function() RouterClient.get("HousingAPI/ActivateFurniture"):InvokeServer(LocalPlayer, unique, useName, payload, char) end) end)
    return true
end
local function becomeBaby()
    if ClientData.get("team") ~= "Babies" then
        task.spawn(function() RouterClient.get("TeamAPI/ChooseTeam"):InvokeServer("Babies", { dont_send_back_home = true, source_for_logging = "autofarm" }) end)
        task.wait(0.5)
    end
end
local function claimPetPen() RouterClient.get("IdleProgressionAPI/CommitAllProgression"):FireServer() end
local function tryRemote(name)
    if not pcall(function() RouterClient.get(name):InvokeServer() end) then pcall(function() RouterClient.get(name):FireServer() end) end
end
local function claimExtras()
    tryRemote("DailyLoginAPI/ClaimDailyReward"); tryRemote("DailyLoginAPI/ClaimStarReward")
    tryRemote("HousingAPI/ClaimAllDeliveries"); tryRemote("LootBoxAPI/ClaimLoginHandouts")
end
local function fillPetPen()
    local penData = ClientData.get("idle_progression") or {}
    local activePets = penData.active_pets or {}
    local count = 0; for _ in pairs(activePets) do count = count + 1 end
    if count >= 4 then return end
    local inventory = ClientData.get("inventory") or {}
    local pets = inventory.pets or {}
    local added = 0
    for unique, _ in pairs(pets) do
        if count + added >= 4 then break end
        if not activePets[unique] then RouterClient.get("IdleProgressionAPI/AddPet"):FireServer(unique); added = added + 1; task.wait(0.1) end
    end
end
local function claimMoneyTree()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local found = CS:GetTagged("furniture:moneytree")
    if #found == 0 then
        local result = RouterClient.get("HousingAPI/BuyFurnitures"):InvokeServer({ { ["kind"] = "moneytree", ["properties"] = { ["cframe"] = root.CFrame * CFrame.new(3, 0, 0) } } })
        if result and result.success then task.wait(1) end
        return
    end
    for _, model in found do pcall(activateFurniture, { unique = model:GetAttribute("furniture_unique"), model = model }); task.wait(0.2) end
end
task.spawn(function()
    while true do
        task.wait(20)
        if not pcall(function() RouterClient.get("PayAPI/Collect"):InvokeServer() end) then pcall(function() RouterClient.get("PayAPI/Collect"):FireServer() end) end
    end
end)

-- ============================================================
-- STATUS / DEBUG
-- ============================================================
local function getEggCounts()
    local inventory = ClientData.get("inventory") or {}
    local counts, pets = {}, inventory.pets or {}
    for _, item in pairs(pets) do if item.kind and item.kind:find("egg") then counts[item.kind] = (counts[item.kind] or 0) + 1 end end
    return counts
end
-- baby/pet ailment breakdown for the dashboard
local function buildAilmentLists()
    local baby, pet = {}, {}
    for _, entry in ipairs(getCharWrappers()) do
        local ok, ailments = pcall(function() return AilmentsClient.get_ailments_for_pet(entry.w) end)
        if ok and ailments then
            for _, a in pairs(ailments) do
                if a and a.kind then
                    local p = a.get_progress and a:get_progress() or (a.progress or 0)
                    if p < 1 then
                        local s = a.kind .. " " .. math.floor(p*100) .. "%"
                        if entry.tag == "baby" then table.insert(baby, s) else table.insert(pet, s) end
                    end
                end
            end
        end
    end
    return table.concat(baby, ", "), table.concat(pet, ", ")
end
local function buildDebug()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local pos = root and string.format("%.0f, %.0f, %.0f", root.Position.X, root.Position.Y, root.Position.Z) or "none"
    local babyA, petA = buildAilmentLists()
    return { team = tostring(ClientData.get("team")), has_char = char ~= nil, char_pos = pos,
        in_house = dbgInHouse, furniture = dbgFurniture, task = currentStatus, egg_bought = eggBoughtCount,
        baby_ailments = babyA, pet_ailments = petA, last_error = lastError }
end
local function sendStatus()
    pcall(function()
        local body = { instance_id = INSTANCE_ID, secret = WEBHOOK_SECRET, username = LocalPlayer.Name,
            job_id = game.JobId, bucks = ClientData.get("money") or 0, eggs = getEggCounts(),
            status = currentStatus, mode = currentMode, error = lastError }
        if debugEnabled then body.debug = buildDebug() end
        local response = HttpService:RequestAsync({ Url = SERVER_URL .. "/update", Method = "POST",
            Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(body) })
        if response.Success then
            local data = HttpService:JSONDecode(response.Body)
            local cmd = data.command
            if cmd then
                if cmd == "start_farm" and not farming then startFarm()
                elseif cmd == "stop_farm" and farming then stopFarm()
                elseif cmd == "start_egg" and not eggBuying then startEgg()
                elseif cmd == "stop_egg" and eggBuying then stopEgg()
                elseif cmd == "debug_on" then debugEnabled = true
                elseif cmd == "debug_off" then debugEnabled = false
                elseif cmd:sub(1, 6) == "trade:" then
                    local parts = cmd:split(":")
                    local target, count = parts[2], tonumber(parts[3])
                    if target and count and usernameBox and totalEggsBox and startTradeBtn then
                        usernameBox.Text = target; totalEggsBox.Text = tostring(count)
                        if not trading then startTradeBtn.MouseButton1Click:Fire() end
                    end
                end
            end
        end
    end)
end
task.spawn(function() while true do task.wait(5); pcall(sendStatus) end end)

-- ============================================================
-- ENSURE IN HOUSE
-- ============================================================
local function ensureInHouse(setFarmStatus)
    if isInHouse() then return true end
    setFarmStatus("Recovering to house...")
    local ok, IM = pcall(Fsys, "InteriorsM")
    for _ = 1, 4 do
        if isInHouse() then return true end
        if ok and IM then pcall(function() IM.exit_smooth() end); task.wait(1.5) end
        pcall(function() RouterClient.get("TeamAPI/Spawn"):InvokeServer("home", { source_for_logging = "recover" }) end)
        task.wait(2.5)
        if isInHouse() then return true end
        if ok and IM then pcall(function() IM.enter_smooth("housing", "MainDoor", { house_owner = LocalPlayer }) end) end
        local t = 0
        while t < 8 do task.wait(0.5); t = t + 0.5; if isInHouse() then return true end end
    end
    return isInHouse()
end

-- ============================================================
-- GUI HELPERS
-- ============================================================
local function corner(inst, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = inst end
local function label(parent, text, x, y, w, h, size, color, bold, wrap)
    local l = Instance.new("TextLabel")
    l.Position = UDim2.new(0, x, 0, y); l.Size = UDim2.new(0, w, 0, h)
    l.BackgroundTransparency = 1; l.Text = text; l.TextSize = size or 11
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextColor3 = color or Color3.fromRGB(180, 180, 180)
    l.TextXAlignment = Enum.TextXAlignment.Left; l.TextWrapped = wrap or false
    l.Parent = parent; return l
end
local function textbox(parent, x, y, w, h, placeholder)
    local b = Instance.new("TextBox")
    b.Position = UDim2.new(0, x, 0, y); b.Size = UDim2.new(0, w, 0, h)
    b.BackgroundColor3 = Color3.fromRGB(50, 50, 50); b.BorderSizePixel = 0
    b.Text = ""; b.PlaceholderText = placeholder or ""
    b.TextColor3 = Color3.fromRGB(255, 255, 255); b.PlaceholderColor3 = Color3.fromRGB(110, 110, 110)
    b.TextSize = 12; b.Font = Enum.Font.Gotham; b.ClearTextOnFocus = false
    b.Parent = parent; corner(b, 5); return b
end
local function button(parent, text, x, y, w, h, color)
    local b = Instance.new("TextButton")
    b.Position = UDim2.new(0, x, 0, y); b.Size = UDim2.new(0, w, 0, h)
    b.BackgroundColor3 = color or Color3.fromRGB(60, 60, 60); b.BorderSizePixel = 0
    b.Text = text; b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 12; b.Font = Enum.Font.GothamBold; b.Parent = parent; corner(b, 6); return b
end

-- ============================================================
-- MAIN GUI
-- ============================================================
local W, H = 200, 270
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoScriptGui"; screenGui.ResetOnSpawn = false; screenGui.Parent = LocalPlayer.PlayerGui
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H); main.Position = UDim2.new(0, 10, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(28, 28, 28); main.BorderSizePixel = 0
main.Active = true; main.Draggable = true; main.ClipsDescendants = true; main.Parent = screenGui; corner(main, 8)
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 28); titleBar.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
titleBar.BorderSizePixel = 0; titleBar.Parent = main; corner(titleBar, 8)
label(titleBar, "AutoScript", 8, 0, 140, 28, 12, Color3.fromRGB(255,255,255), true)
local minimized = false
local minBtn = button(titleBar, "-", W-46, 4, 20, 20, Color3.fromRGB(60,60,60)); minBtn.TextSize = 11
minBtn.MouseButton1Click:Connect(function() minimized = not minimized; main.Size = UDim2.new(0, W, 0, minimized and 28 or H); minBtn.Text = minimized and "+" or "-" end)
local closeBtn = button(titleBar, "X", W-24, 4, 20, 20, Color3.fromRGB(170,50,50)); closeBtn.TextSize = 11
closeBtn.MouseButton1Click:Connect(function() farming = false; trading = false; eggBuying = false; screenGui:Destroy() end)
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, 24); tabBar.Position = UDim2.new(0, 0, 0, 28)
tabBar.BackgroundColor3 = Color3.fromRGB(22, 22, 22); tabBar.BorderSizePixel = 0; tabBar.Parent = main
local tabW = math.floor((W - 8) / 3)
local tabTrade = button(tabBar, "Trade", 2, 2, tabW, 20, Color3.fromRGB(0, 150, 90))
local tabFarm  = button(tabBar, "Farm",  4 + tabW, 2, tabW, 20, Color3.fromRGB(50, 50, 50))
local tabEgg   = button(tabBar, "Egg",   6 + tabW*2, 2, tabW, 20, Color3.fromRGB(50, 50, 50))
tabTrade.TextSize = 10; tabFarm.TextSize = 10; tabEgg.TextSize = 10
local tradePanel = Instance.new("Frame"); tradePanel.Size = UDim2.new(1,0,1,-52); tradePanel.Position = UDim2.new(0,0,0,52); tradePanel.BackgroundTransparency = 1; tradePanel.Parent = main
local farmPanel = Instance.new("Frame"); farmPanel.Size = UDim2.new(1,0,1,-52); farmPanel.Position = UDim2.new(0,0,0,52); farmPanel.BackgroundTransparency = 1; farmPanel.Visible = false; farmPanel.Parent = main
local eggPanel = Instance.new("Frame"); eggPanel.Size = UDim2.new(1,0,1,-52); eggPanel.Position = UDim2.new(0,0,0,52); eggPanel.BackgroundTransparency = 1; eggPanel.Visible = false; eggPanel.Parent = main
local function switchTab(tab)
    tradePanel.Visible = tab == "trade"; farmPanel.Visible = tab == "farm"; eggPanel.Visible = tab == "egg"
    tabTrade.BackgroundColor3 = tab == "trade" and Color3.fromRGB(0,150,90)  or Color3.fromRGB(50,50,50)
    tabFarm.BackgroundColor3  = tab == "farm"  and Color3.fromRGB(0,120,180) or Color3.fromRGB(50,50,50)
    tabEgg.BackgroundColor3   = tab == "egg"   and Color3.fromRGB(180,120,0) or Color3.fromRGB(50,50,50)
end
tabTrade.MouseButton1Click:Connect(function() switchTab("trade") end)
tabFarm.MouseButton1Click:Connect(function()  switchTab("farm")  end)
tabEgg.MouseButton1Click:Connect(function()   switchTab("egg")   end)
local PW = W - 12

-- TRADE PANEL
local y = 4
label(tradePanel, "Username", 6, y, PW, 12, 10)
usernameBox = textbox(tradePanel, 6, y+13, PW, 22, "e.g. AltAccount123")
y = y + 38
label(tradePanel, "Total Eggs", 6, y, PW, 12, 10)
totalEggsBox = textbox(tradePanel, 6, y+13, PW, 22, "e.g. 100")
y = y + 38
local breakdownLabel = label(tradePanel, "", 6, y, PW, 20, 10, Color3.fromRGB(140,200,255), false, true)
y = y + 22
local tradeStatusLabel = label(tradePanel, "Status: Idle", 6, y, PW, 14, 10, Color3.fromRGB(100,220,100), false, true)
y = y + 16
startTradeBtn = button(tradePanel, "Start Auto Trade", 6, y, PW, 26, Color3.fromRGB(0,160,90)); startTradeBtn.TextSize = 11
totalEggsBox:GetPropertyChangedSignal("Text"):Connect(function()
    local n = tonumber(totalEggsBox.Text)
    if not n or n < 1 then breakdownLabel.Text = ""; return end
    n = math.floor(n); local batches = calcBatches(n); local rem = n % MAX_PER_TRADE
    breakdownLabel.Text = rem == 0 and (#batches .. " x " .. MAX_PER_TRADE) or ((#batches-1) .. " x " .. MAX_PER_TRADE .. " + 1 x " .. rem)
end)
local function setTradeStatus(msg, color) tradeStatusLabel.Text = "Status: " .. msg; tradeStatusLabel.TextColor3 = color or Color3.fromRGB(100,220,100) end
local lastTradeId = nil
local function doOneTrade(targetPlayer, batchSize, eggKind)
    setTradeStatus("Waiting for state clear...")
    if not waitForTradeStateClear() then error("Trade state did not clear") end
    setTradeStatus("Sending request...")
    RouterClient.get("TradeAPI/SendTradeRequest"):FireServer(targetPlayer)
    local opened, newId = waitForNewNegotiationStage(lastTradeId)
    if not opened then error("Trade never opened") end
    lastTradeId = newId; task.wait(WAIT_AFTER_ACCEPT)
    local eggs = getEggUniques(eggKind, batchSize)
    if #eggs < batchSize then error("Not enough eggs: " .. #eggs .. "/" .. batchSize) end
    for i, unique in ipairs(eggs) do setTradeStatus("Adding egg " .. i .. "/" .. #eggs); RouterClient.get("TradeAPI/AddItemToOffer"):FireServer(unique); task.wait(WAIT_AFTER_ADD) end
    setTradeStatus("Waiting for lock..."); task.wait(WAIT_FOR_LOCK)
    RouterClient.get("TradeAPI/AcceptNegotiation"):FireServer()
    if not waitForConfirmationStage(lastTradeId) then error("Never reached confirmation") end
    task.wait(WAIT_FOR_CONF_LOCK)
    RouterClient.get("TradeAPI/ConfirmTrade"):FireServer()
    setTradeStatus("Waiting for close..."); task.wait(WAIT_STATE_CLEAR)
end
startTradeBtn.MouseButton1Click:Connect(function()
    if trading then return end
    local username = usernameBox.Text
    local eggKind = EGG_OPTIONS[selectedEggIndex].kind
    local totalEggs = math.floor(tonumber(totalEggsBox.Text) or 0)
    if username == "" then setTradeStatus("Enter a username!", Color3.fromRGB(255,80,80)); return end
    if totalEggs < 1 then setTradeStatus("Enter a valid egg count!", Color3.fromRGB(255,80,80)); return end
    local target = Players:FindFirstChild(username)
    if not target then setTradeStatus("Player not found!", Color3.fromRGB(255,80,80)); return end
    local batches = calcBatches(totalEggs)
    trading = true; currentMode = "trade"
    startTradeBtn.Text = "Running..."; startTradeBtn.BackgroundColor3 = Color3.fromRGB(100,100,100)
    task.spawn(function()
        for i, batchSize in ipairs(batches) do
            currentStatus = "trade " .. i .. "/" .. #batches
            local ok, err = pcall(doOneTrade, target, batchSize, eggKind)
            if not ok then setTradeStatus("Error: " .. tostring(err):sub(1,40), Color3.fromRGB(255,80,80)); logErr("trade", err); break end
        end
        setTradeStatus("Done!", Color3.fromRGB(100,220,100))
        startTradeBtn.Text = "Start Auto Trade"; startTradeBtn.BackgroundColor3 = Color3.fromRGB(0,160,90)
        trading = false; currentMode = "idle"
    end)
end)

-- FARM PANEL
local farmStatusLabel = label(farmPanel, "Status: Idle", 6, 6,  PW, 14, 10, Color3.fromRGB(100,220,100), false, true)
local ailmentLabel    = label(farmPanel, "",             6, 22, PW, 40, 10, Color3.fromRGB(160,160,160), false, true)
local farmBtn = button(farmPanel, "Start AutoFarm", 6, 66, PW, 26, Color3.fromRGB(0,120,180)); farmBtn.TextSize = 11
local function setFarmStatus(msg, color) currentStatus = msg; farmStatusLabel.Text = "Status: " .. msg; farmStatusLabel.TextColor3 = color or Color3.fromRGB(100,220,100) end
local farmThread = nil
function stopFarm()
    farming = false; currentMode = "idle"; currentStatus = "stopped"
    if farmThread then task.cancel(farmThread); farmThread = nil end
    farmBtn.Text = "Start AutoFarm"; farmBtn.BackgroundColor3 = Color3.fromRGB(0,120,180)
    setFarmStatus("Stopped", Color3.fromRGB(200,100,100)); ailmentLabel.Text = ""
end
function startFarm()
    farming = true; currentMode = "farm"
    farmBtn.Text = "Stop AutoFarm"; farmBtn.BackgroundColor3 = Color3.fromRGB(170,60,60)
    setFarmStatus("Starting..."); lastError = ""
    becomeBaby(); fillPetPen(); claimPetPen(); claimMoneyTree(); claimExtras()
    local loopCount = 0
    farmThread = task.spawn(function()
        while farming do
            loopCount = loopCount + 1
            if loopCount % 60 == 0 then pcall(claimExtras) end
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root then
                local inHouse = ensureInHouse(setFarmStatus)
                dbgInHouse = isInHouse(); dbgFurniture = countFurniture()
                if not inHouse then
                    setFarmStatus("Stuck outside house, retrying...", Color3.fromRGB(255,200,0))
                    task.wait(2)
                elseif true then
                pcall(function() LocalPlayer:RequestStreamAroundAsync(root.Position) end)
                task.wait(0.2)
                    end
                if loopCount % 60 == 0 then pcall(claimPetPen); pcall(fillPetPen) end
                if loopCount % MONEYTREE_EVERY == 0 then pcall(claimMoneyTree) end
                local ailments = getActiveAilments()
                if #ailments == 0 then
                    setFarmStatus("All happy!"); ailmentLabel.Text = ""
                else
                    local lines = {}
                    for _, a in ipairs(ailments) do table.insert(lines, a.kind .. " " .. math.floor(a.progress*100) .. "%") end
                    ailmentLabel.Text = table.concat(lines, "  |  ")
                    local now = os.time()
                    local fixable = nil
                    for _, a in ipairs(ailments) do
                        local key = (a.tag or "?") .. ":" .. a.kind
                        local cd = ailmentCooldown[key]
                        if isHandled(a) and not (cd and now < cd) then fixable = a; break end
                    end
                    if not fixable then
                        setFarmStatus("Idle (nothing to do / cooling down)")
                    else
                        setFarmStatus("Fixing: " .. (fixable.tag or "?") .. " " .. fixable.kind)
                        local ok, info = tryFixAilment(fixable)
                        logErr("fix " .. fixable.kind, info)
                        if ok then
                            setFarmStatus("Fixed: " .. fixable.kind)
                        else
                            local key = (fixable.tag or "?") .. ":" .. fixable.kind
                            ailmentCooldown[key] = os.time() + COOLDOWN
                            setFarmStatus("Skip " .. fixable.kind .. " " .. COOLDOWN .. "s (" .. tostring(info) .. ")", Color3.fromRGB(255,200,0))
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
farmBtn.MouseButton1Click:Connect(function() if farming then stopFarm() else startFarm() end end)

-- EGG PANEL
local ey = 4
label(eggPanel, "Select Egg", 6, ey, PW, 12, 10)
local eggBuyDropdown = button(eggPanel, EGG_BUY_OPTIONS[1].label, 6, ey+13, PW, 22, Color3.fromRGB(50,50,50))
eggBuyDropdown.TextSize = 10; eggBuyDropdown.Font = Enum.Font.Gotham
local eggBuyArrow = label(eggBuyDropdown, "v", PW-16, 0, 16, 22, 10, Color3.fromRGB(180,180,180))
local eggBuyDropMenu = Instance.new("Frame")
eggBuyDropMenu.Size = UDim2.new(0, PW, 0, #EGG_BUY_OPTIONS * 20); eggBuyDropMenu.Position = UDim2.new(0, 6, 0, ey+37)
eggBuyDropMenu.BackgroundColor3 = Color3.fromRGB(45,45,45); eggBuyDropMenu.BorderSizePixel = 0
eggBuyDropMenu.Visible = false; eggBuyDropMenu.ZIndex = 10; eggBuyDropMenu.Parent = eggPanel; corner(eggBuyDropMenu, 4)
for i, opt in ipairs(EGG_BUY_OPTIONS) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 20); b.Position = UDim2.new(0, 0, 0, (i-1)*20)
    b.BackgroundTransparency = 1; b.Text = opt.label; b.TextColor3 = Color3.fromRGB(255,255,255)
    b.TextSize = 10; b.Font = Enum.Font.Gotham; b.ZIndex = 11; b.Parent = eggBuyDropMenu
    b.MouseButton1Click:Connect(function() selectedEggBuyIndex = i; eggBuyDropdown.Text = opt.label; eggBuyDropMenu.Visible = false; eggBuyArrow.Text = "v" end)
end
eggBuyDropdown.MouseButton1Click:Connect(function() eggBuyDropMenu.Visible = not eggBuyDropMenu.Visible; eggBuyArrow.Text = eggBuyDropMenu.Visible and "^" or "v" end)
ey = ey + 38
label(eggPanel, "Interval (secs)", 6, ey, PW, 12, 10)
local eggIntervalBox = textbox(eggPanel, 6, ey+13, PW, 22, "e.g. 30")
ey = ey + 38
local eggStatusLabel = label(eggPanel, "Status: Idle", 6, ey, PW, 14, 10, Color3.fromRGB(100,220,100), false, true)
ey = ey + 16
local eggBoughtLabel = label(eggPanel, "Bought: 0", 6, ey, PW, 12, 10, Color3.fromRGB(140,200,255))
ey = ey + 16
local startEggBtn = button(eggPanel, "Start AutoEgg", 6, ey, PW, 26, Color3.fromRGB(180,120,0)); startEggBtn.TextSize = 11
local function setEggStatus(msg, color) eggStatusLabel.Text = "Status: " .. msg; eggStatusLabel.TextColor3 = color or Color3.fromRGB(100,220,100) end
local eggThread = nil
function stopEgg()
    eggBuying = false; currentMode = "idle"; currentStatus = "stopped"
    if eggThread then task.cancel(eggThread); eggThread = nil end
    startEggBtn.Text = "Start AutoEgg"; startEggBtn.BackgroundColor3 = Color3.fromRGB(180,120,0)
    setEggStatus("Stopped", Color3.fromRGB(200,100,100))
end
function startEgg()
    local interval = tonumber(eggIntervalBox.Text) or 30
    if interval < 1 then interval = 1 end
    local eggKind = EGG_BUY_OPTIONS[selectedEggBuyIndex].kind
    local eggCategory = EGG_BUY_OPTIONS[selectedEggBuyIndex].category
    eggBuying = true; currentMode = "egg"; eggBoughtCount = 0
    startEggBtn.Text = "Stop AutoEgg"; startEggBtn.BackgroundColor3 = Color3.fromRGB(170,60,60)
    setEggStatus("Running...")
    eggThread = task.spawn(function()
        while eggBuying do
            currentStatus = "egg (bought " .. eggBoughtCount .. ")"
            local ok, err = pcall(function() RouterClient.get("ShopAPI/BuyItem"):InvokeServer(eggCategory, eggKind, { buy_count = 1 }) end)
            if ok then eggBoughtCount = eggBoughtCount + 1; eggBoughtLabel.Text = "Bought: " .. eggBoughtCount; setEggStatus("Bought! Total: " .. eggBoughtCount)
            else setEggStatus("Failed: " .. tostring(err):sub(1,30), Color3.fromRGB(255,200,0)); logErr("buyEgg", err) end
            task.wait(interval)
        end
    end)
end
startEggBtn.MouseButton1Click:Connect(function() if eggBuying then stopEgg() else startEgg() end end)

switchTab("trade")
