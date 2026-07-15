--[[
    AutoScript - AutoFarm + AutoTrade + AutoEgg
    Ailments: furniture (FNA), pet_me, mystery, walk/ride, travel tasks.
    Baby hungry/thirsty/sick: grab FREE food from the Hospital (ShopAPI/BuyItem "food",
    cost 0) -> equip -> eat (UseItemHelper.use_item, ConsumeFoodObject fallback).
      water -> thirsty, healing_apple -> sick, sandwich/any food -> hungry.
    Pet grow: equip youngest pet/egg (no kind filter), swap at age 6, buy cracked egg
      when nothing to grow (only if bucks >= MIN_BUCKS_FOR_EGG).
    Pen: reads idle_progression_manager (correct key).
    Retry-until-done: handlers re-attempt the action each cycle instead of one-shot.
    Anti-AFK. Crash-guarded loop. Robust home recovery.
--]]

local Players     = game:GetService("Players")
local CS          = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local RS          = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local LocalPlayer = Players.LocalPlayer

LocalPlayer.Idled:Connect(function()
    pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
end)

local Fsys = require(RS:WaitForChild("Fsys")).load
local RouterClient      = Fsys("RouterClient")
local ClientData        = Fsys("ClientData")
local AilmentsClient    = Fsys("new:AilmentsClient")
local EquippedPets      = Fsys("EquippedPets")
local CharWrapperClient = Fsys("CharWrapperClient")
local ClientToolManager = Fsys("ClientToolManager")
local UIManager         = Fsys("UIManager")
local PetEntityHelper   = Fsys("PetEntityHelper")
local InteriorsM        = Fsys("InteriorsM")
local _okPPN, PetPerformanceName = pcall(Fsys, "PetPerformanceName")

local FNA = require(RS.new.modules.Ailments.ClientActions.FurnitureNavigationAction)
local AFH = require(RS.new.modules.Ailments.Helpers.AilmentsFurnitureHelper)
local PetEntityManager = require(RS.ClientModules.Game.PetEntities.PetEntityManager)
local _okUIH, UseItemHelper = pcall(function() return require(RS.new.modules.Ailments.Helpers.UseItemHelper) end)

-- ============================================================
-- CONFIG
-- ============================================================
local SERVER_URL     = "http://152.53.144.174:5000"
local INSTANCE_ID    = LocalPlayer.Name
local WEBHOOK_SECRET  = "7f3a9c2e5b8d1064a2e7c9f04b6d8135"

local FARM_LOOP_INTERVAL = 0.5
local MONEYTREE_EVERY    = 600
local FIX_TIMEOUT        = 40
local MOVE_TIME          = 34
local TRAVEL_TIME        = 56
local COOLDOWN           = 20   -- shorter so failed fixes retry sooner (retry-until-done)
local PET_MAX_AGE        = 6
local MIN_BUCKS_FOR_EGG  = 1000 -- only auto-buy a cracked egg (350) if you have at least this much

local AILMENT_FURNITURE = { sleepy = true, dirty = true, toilet = true }
local AILMENT_FEED = { hungry = true, thirsty = true, sick = true }  -- baby: eat free food; pet: bowl (hungry/thirsty)
local AILMENT_MOVE = { walk = true, play = true }

-- baby feed: free grab kind + which inventory kinds satisfy each ailment
local FEED_GRAB = { hungry = "schospital_refresh_2023_cafeteria_sandwich", thirsty = "water", sick = "healing_apple" }
local FEED_MATCH = {
    thirsty = function(k) return k == "water" end,
    sick    = function(k) return k == "healing_apple" end,
    hungry  = function(k) return k ~= "water" and k ~= "healing_apple"
        and not k:find("potion") and not k:find("bait") and not k:find("rod") and not k:find("temporary") end,
}

-- INTERIOR travel tasks: enter_smooth(dest, door) -> wait in the interior -> return home.
-- (being inside the interior satisfies these; sick handled by feed, not here)
local TRAVEL_DEST = {
    pizza_party   = { dest = "PizzaShop", door = "MainDoor" },
    school        = { dest = "School",    door = "MainDoor" },
    salon         = { dest = "Salon",     door = "MainDoor" },
}
-- MAINMAP SPOT tasks: enter MainMap -> teleport to a specific StaticMap part -> STAY there
-- (RateArea server component only ticks while your char is at the spot, ~50s). {area, targetPart, radius}
-- {area, targetPart, radius}. Teleport to the part the ailment's is_in_area check measures FROM
-- (the AilmentTarget/Origin), not the nav target - beach_party's nav target sits outside its perimeter.
local MAP_SPOT = {
    beach_party   = { "Beach",        "BeachPartyAilmentTarget", 550 },
    camping       = { "Campsite",     "CampsiteOrigin",          100 },
    balloon_fight = { "BalloonFight",  "FortDagi",               100 },
    bored         = { "Park",         "BoredAilmentTarget",      100 },
}

local startFarm, stopFarm, startEgg, stopEgg
local usernameBox, totalEggsBox, startTradeBtn

-- ============================================================
-- STATE / DEBUG
-- ============================================================
local farming, trading, eggBuying = false, false, false
local currentMode   = "idle"
local currentStatus = "idle"
local debugEnabled  = true   -- always on (no toggle)
local lastError     = ""
local lastFixed     = ""
local dbgFurniture  = -1
local dbgInHouse    = false
local eggBoughtCount = 0
local ailmentCooldown = {}
local ailmentAttempts = {}   -- per-ailment fail count -> give up after 2 (only if NO progress)

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
    local loc = InteriorsM.get_current_location and InteriorsM.get_current_location()
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
local function waitForTradeStateClear() local e = 0; while e < MAX_WAIT_STATE do if ClientData.get("trade") == nil then return true end task.wait(0.25); e = e + 0.25 end; return false end
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
-- PETS
-- ============================================================
local function petAge(item) return (item and item.properties and item.properties.age) or 99 end
local function isEgg(kind) return kind ~= nil and kind:match("egg$") ~= nil end   -- actual unhatched egg (ends in "egg")
local function getPenUniques()
    local set = {}
    local pen = ClientData.get("idle_progression_manager") or {}   -- correct key
    for u in pairs(pen.active_pets or {}) do set[u] = true end
    return set
end
-- youngest thing to grow: any pet OR egg, not in pen, under age 6 (egg vs pet - no difference)
-- youngest free pet to equip. Eggs ARE pets (they have needs/ailments and hatch as you fill them),
-- so egg or hatched = no difference. ONLY skip the practice_dog (tutorial pet that can't be equipped).
local function pickYoungestPet(exclude)
    local pen = getPenUniques()
    local pets = (ClientData.get("inventory") or {}).pets or {}
    local best, bestAge
    for u, it in pairs(pets) do
        if type(it) == "table" and it.kind and not pen[u] and u ~= exclude and not it.kind:find("practice") then
            it.unique = it.unique or u
            local age = petAge(it)
            if not best or age < bestAge then best, bestAge = it, age end
        end
    end
    return best
end
-- rate-limited shop purchase: never fire ShopAPI/BuyItem calls closer than SHOP_MIN_GAP apart.
-- (stops the getProductInfo 429 "Too Many Requests" flood that comes from spamming the shop.)
local _lastShop = 0
local SHOP_MIN_GAP = 2.5
local function shopBuy(cat, kind, opts)
    local gap = SHOP_MIN_GAP - (tick() - _lastShop)
    if gap > 0 then task.wait(gap) end
    _lastShop = tick()
    return RouterClient.get("ShopAPI/BuyItem"):InvokeServer(cat, kind, opts or { buy_count = 1 })
end
local function buyCrackedEgg()
    local money = ClientData.get("money") or 0
    if money < MIN_BUCKS_FOR_EGG then return false end
    return pcall(function() return shopBuy("pets", "cracked_egg") end)
end
-- equip a pet/egg to grow. equipped + still growing -> leave it. grown (age 6) -> swap.
-- keep A pet equipped for farming: if any real pet is already out, LEAVE it (no age-6 rotation
-- that used to leave you petless). If none, equip the youngest free pet; buy a cracked egg only
-- when there's genuinely nothing to equip.
local function ensurePetEquipped()
    local okE, eq = pcall(function() return EquippedPets.get_my_equipped() end)
    local cur = (okE and type(eq) == "table") and eq[1] or nil
    -- a real pet/egg already equipped (not the un-equippable practice_dog) -> leave it out
    if cur and cur.kind and petAge(cur) < 99 and not cur.kind:find("practice") then
        return true
    end
    -- nothing, or practice_dog stuck -> equip a real pet (exclude current so we swap it)
    local pick = pickYoungestPet(cur and cur.unique) or pickYoungestPet(nil)
    if not pick then
        if buyCrackedEgg() then task.wait(1.5); pick = pickYoungestPet(nil) end     -- nothing to equip -> buy one
    end
    if pick then pcall(function() ClientToolManager.equip(pick) end); task.wait(2); return true end
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
local function ailmentProgress(kind, wrapper)   -- current progress (0..1); 1 if gone
    local ok, ailments = pcall(function() return AilmentsClient.get_ailments_for_pet(wrapper) end)
    if ok and ailments then
        for _, a in pairs(ailments) do
            if a.kind == kind then return a.get_progress and a:get_progress() or (a.progress or 0) end
        end
    end
    return 1
end

local function returnHome()
    for _ = 1, 4 do
        if isInHouse() then return true end
        pcall(function() InteriorsM.enter_smooth("housing", "MainDoor", { house_owner = LocalPlayer }) end)
        local t = 0
        while t < 6 do task.wait(0.5); t = t + 0.5; if isInHouse() then return true end end
        pcall(function() RouterClient.get("TeamAPI/Spawn"):InvokeServer("home", { source_for_logging = "returnhome" }) end)
        task.wait(2)
    end
    return isInHouse()
end

-- ============================================================
-- FIX HANDLERS
-- ============================================================
-- furniture: re-fire the use each cycle (retry) until done or timeout
local function fixFurnitureAilment(kind, wrapper)
    local pos
    pcall(function() pos = AFH.find_furniture_position(kind) end)
    if not pos then return false, "no furniture for " .. kind end
    local target
    if typeof(pos) == "Vector3" then target = pos
    elseif typeof(pos) == "CFrame" then target = pos.Position
    elseif type(pos) == "table" and pos.Position then target = pos.Position end
    if not target then return false, "bad furniture pos" end
    local ailingChar = wrapper and wrapper.char
    local isPet = ailingChar and ailingChar ~= LocalPlayer.Character
    local function park()
        local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if myRoot then myRoot.CFrame = CFrame.new(target + Vector3.new(0, 3, 0)) end
        if isPet then local pr = ailingChar:FindFirstChild("HumanoidRootPart"); if pr then pr.CFrame = CFrame.new(target + Vector3.new(2.5, 3, 0)) end end
    end
    park(); task.wait(1)
    local action = FNA.new({ ailment_to_boost = kind })
    if not action:get_valid_interaction() then return false, "no interaction in range" end
    local waited = 0
    while farming and waited < FIX_TIMEOUT do
        if waited % 8 == 0 then pcall(function() action:automatically_use_nearby_furniture(wrapper) end) end   -- retry the action
        task.wait(2); waited = waited + 2
        local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local dDrift = (myRoot and myRoot.Parent) and (myRoot.Position - target).Magnitude or 0
        local pr = isPet and ailingChar and ailingChar:FindFirstChild("HumanoidRootPart")
        local pDrift = pr and (pr.Position - target).Magnitude or 0
        if dDrift > 12 or pDrift > 12 then park() end
        if not ailmentStillActive(kind, wrapper) then pcall(function() action:stop() end); return true, "fixed in " .. waited .. "s" end
    end
    pcall(function() action:stop() end)
    return false, "timeout after " .. waited .. "s"
end

-- ============================================================
-- BABY FEED (free hospital food): grab (if needed) -> equip -> eat, retry until clear
-- ============================================================
local function findFoodItem(kind)
    local match = FEED_MATCH[kind]
    if not match then return nil end
    local f = (ClientData.get("inventory") or {}).food or {}
    for u, it in pairs(f) do
        if type(it) == "table" and it.kind and match(it.kind) then it.unique = it.unique or u; return it end
    end
    return nil
end
local function grabFreeFood(kind)   -- must be at the Hospital shop; BuyItem is free (cost 0)
    local grabKind = FEED_GRAB[kind]
    if not grabKind then return false end
    local done, res = false, false
    task.spawn(function()
        local ok, r = pcall(function() return shopBuy("food", grabKind) end)
        res = ok and (r == "success"); done = true
    end)
    local t = 0; while not done and t < 5 do task.wait(0.25); t = t + 0.25 end
    return res
end
-- baby self-eat (CONFIRMED via ToolDBHelper decompile): the food is a GenericTool; firing
-- ToolAPI/ServerUseTool(unique,"START") then (unique,"END") runs the server's generic_server_use_end
-- which does AilmentsServer.add_progress(wrapper, ailment, 1/uses). So each START/END cycle adds ~1/uses.
-- (This is the "Feed Me" path; NOT feed_pet, which is pet-only and dead for babies.)
local function serverUseTool(unique, phase)
    local done = false
    task.spawn(function() pcall(function() RouterClient.get("ToolAPI/ServerUseTool"):InvokeServer(unique, phase) end); done = true end)
    local t = 0; while not done and t < 3 do task.wait(0.25); t = t + 0.25 end
end
local function eatOnce(item)
    serverUseTool(item.unique, "START"); task.wait(1)
    serverUseTool(item.unique, "END");   task.wait(0.6)
end
local function fixBabyFeed(a)
    local kind = a.kind
    local item = findFoodItem(kind)
    local traveled = false
    if not item then   -- none in inventory -> go to hospital and grab free
        pcall(function() InteriorsM.enter_smooth("Hospital", "MainDoor", {}) end); task.wait(3); traveled = true
        for _ = 1, 5 do if grabFreeFood(kind) then break end; task.wait(0.4) end
        item = findFoodItem(kind)
    end
    if not item then if traveled then returnHome() end; return false, "no free " .. kind .. " food" end
    pcall(function() ClientToolManager.equip(item) end); task.wait(1)
    -- fire START/END uses until the ailment is satisfied (each use adds ~1/uses progress)
    local n = 0
    while farming and n < 14 do
        n = n + 1
        item = findFoodItem(kind) or item   -- item may get consumed / unique may change
        if not item then break end
        eatOnce(item)
        if not ailmentStillActive(kind, a.wrapper) then
            pcall(function() ClientToolManager.unequip(item) end)   -- free the slot so the pet re-equips
            if traveled then returnHome() end
            return true, "fed free (" .. tostring(kind) .. ", " .. n .. " uses)"
        end
    end
    pcall(function() ClientToolManager.unequip(item) end)
    if traveled then returnHome() end
    return false, kind .. " feed timeout"
end

-- pet_me (PET ailment): the real satisfy (from AilmentsDB.pet_me create_action) is
-- FocusPetApp.petting_handler:start_petting() on the focused pet. (Not PetPetted/ProgressPetMeAilment.)
local function fixPetMe(a)
    local pchar = a.wrapper.char
    if not pchar then return false, "no pet char" end
    pcall(function() RouterClient.get("AdoptAPI/FocusPet"):FireServer(pchar) end)
    task.wait(0.5)
    local ph = UIManager.apps.FocusPetApp.petting_handler
    pcall(function() ph:show_example() end)
    pcall(function() ph:start_petting() end)
    local w = 0
    while farming and w < 12 do
        task.wait(1); w = w + 1
        if not ailmentStillActive("pet_me", a.wrapper) then break end
        if w % 4 == 0 then pcall(function() ph:start_petting() end) end   -- re-trigger if still going
    end
    pcall(function() RouterClient.get("AdoptAPI/UnfocusPet"):FireServer(pchar) end)
    return not ailmentStillActive("pet_me", a.wrapper), "petted"
end

local function fixMystery(a)
    local action = a.obj.action
    if not action or not action._get_ailment_slots then return false, "no mystery action" end
    local ok, slots = pcall(function() return action:_get_ailment_slots(a.wrapper) end)
    if not ok or type(slots) ~= "table" then return false, "no slots" end
    local FIXABLE = { sleepy=true, dirty=true, toilet=true, thirsty=true, walk=true, pet_me=true }
    local idx, kind
    for i, k in pairs(slots) do if FIXABLE[k] then idx, kind = i, k break end end
    if not idx then for i, k in pairs(slots) do idx, kind = i, k break end end
    if not idx then return false, "no slot" end
    pcall(function() RouterClient.get("AilmentsAPI/ChooseMysteryAilment"):FireServer(a.wrapper.pet_unique, action.options.ailment_key, idx, kind) end)
    task.wait(1.5)
    return not ailmentStillActive("mystery", a.wrapper), "chose " .. tostring(kind)
end

local function fixMove(a)
    local ailChar = (a.wrapper and a.wrapper.char) or LocalPlayer.Character
    local root = ailChar and ailChar:FindFirstChild("HumanoidRootPart")
    if not root then return false, "no root" end
    local origin = root.Position
    local startT, i = tick(), 0
    while farming and tick() - startT < MOVE_TIME do
        i = i + 1
        root = ailChar and ailChar:FindFirstChild("HumanoidRootPart")
        if not root or not root.Parent then break end
        local off = Vector3.new(math.cos(i * 0.4) * 5, 0, math.sin(i * 0.4) * 5)
        root.CFrame = CFrame.new(origin + off)
        local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if myRoot and myRoot.Parent and myRoot ~= root then myRoot.CFrame = CFrame.new(origin + off + Vector3.new(2.5, 0, 0)) end
        task.wait(0.2)
        if not ailmentStillActive(a.kind, a.wrapper) then return true, "moved" end
    end
    return not ailmentStillActive(a.kind, a.wrapper), "move timeout"
end

-- ride: UseItemHelper.use_item(babyWrapper, strollerItem) -> the strollers handler does
-- backpack_equip({chars_to_sit={wrapper}}) + AdoptAPI/UseStroller (sits the baby), then move.
local _okUIH2, UseItemHelperRide = pcall(function() return require(RS.new.modules.Ailments.Helpers.UseItemHelper) end)
local function fixRide(a)
    local inv = ClientData.get("inventory") or {}
    local item
    for _, cat in ipairs({ "strollers", "transport" }) do
        local items = inv[cat]
        if items then for u, it in pairs(items) do it.unique = it.unique or u; it.category = it.category or cat; item = it break end end
        if item then break end
    end
    if not item then return false, "no stroller/transport item" end
    if _okUIH2 and UseItemHelperRide then pcall(function() UseItemHelperRide.use_item(a.wrapper, item) end) end
    task.wait(2)   -- let the baby get seated in the stroller
    return fixMove(a)   -- then move it around for the ride duration
end

-- MainMap spot task: enter MainMap, stream in + find the StaticMap target part, teleport onto
-- it and hold there while the RateArea ticks (~50s), then return home.
local function fixMapSpot(a)
    local spec = MAP_SPOT[a.kind]
    if not spec then return false, "no map spot" end
    pcall(function() InteriorsM.enter_smooth("MainMap", "Neighborhood/MainDoor", {}) end)
    task.wait(4)
    local target
    for _ = 1, 10 do
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then pcall(function() LocalPlayer:RequestStreamAroundAsync(root.Position) end) end
        local sm = workspace:FindFirstChild("StaticMap")
        local area = sm and sm:FindFirstChild(spec[1])
        target = area and area:FindFirstChild(spec[2])
        if target then break end
        task.wait(1)
    end
    if not target then returnHome(); return false, "no " .. a.kind .. " target streamed" end
    local pos = target.Position
    local waited, i = 0, 0
    while farming and waited < TRAVEL_TIME do
        i = i + 1
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root and root.Parent then root.CFrame = CFrame.new(pos + Vector3.new(math.cos(i * 0.5) * 4, 4, math.sin(i * 0.5) * 4)) end
        task.wait(2); waited = waited + 2
        if not ailmentStillActive(a.kind, a.wrapper) then returnHome(); return true, a.kind .. " at spot (" .. waited .. "s)" end
    end
    returnHome()
    return false, a.kind .. " spot timeout"
end

local function fixTravel(a)
    local d = TRAVEL_DEST[a.kind]
    if not d then return false, "no dest" end
    pcall(function() InteriorsM.enter_smooth(d.dest, d.door, {}) end)
    task.wait(3)
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local origin = root and root.Position
    local startT, i = tick(), 0
    while farming and tick() - startT < TRAVEL_TIME do
        i = i + 1
        root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root and root.Parent and origin then root.CFrame = CFrame.new(origin + Vector3.new(math.cos(i * 0.4) * 4, 0, math.sin(i * 0.4) * 4)) end
        task.wait(0.3)
        if not ailmentStillActive(a.kind, a.wrapper) then break end
    end
    local done = not ailmentStillActive(a.kind, a.wrapper)
    returnHome()
    return done, done and "traveled" or "travel timeout"
end

local function tryFixAilment(a)
    if a.kind == "pet_me" then return fixPetMe(a)
    elseif a.kind == "mystery" then return fixMystery(a)
    elseif a.kind == "ride" then return fixRide(a)
    elseif MAP_SPOT[a.kind] then return fixMapSpot(a)
    elseif TRAVEL_DEST[a.kind] then return fixTravel(a)
    elseif AILMENT_MOVE[a.kind] then return fixMove(a)
    elseif AILMENT_FURNITURE[a.kind] then return fixFurnitureAilment(a.kind, a.wrapper)
    elseif AILMENT_FEED[a.kind] then
        if a.tag == "pet" then
            if a.kind == "hungry" or a.kind == "thirsty" then return fixFurnitureAilment(a.kind, a.wrapper) end
            return false, "pet " .. a.kind .. " no handler"
        end
        return fixBabyFeed(a)   -- baby: free hospital food
    end
    return false, "no handler"
end
local function isHandled(a)
    if a.kind == "pet_me" or a.kind == "mystery" or a.kind == "ride" then return true end
    if MAP_SPOT[a.kind] then return true end
    if TRAVEL_DEST[a.kind] then return true end
    if AILMENT_MOVE[a.kind] then return true end
    if AILMENT_FURNITURE[a.kind] then return true end
    if AILMENT_FEED[a.kind] then
        if a.tag == "pet" then return a.kind == "hungry" or a.kind == "thirsty" end
        return true
    end
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
    local penData = ClientData.get("idle_progression_manager") or {}   -- correct key
    local activePets = penData.active_pets or {}
    local count = 0; for _ in pairs(activePets) do count = count + 1 end
    if count >= 4 then return end
    local pets = (ClientData.get("inventory") or {}).pets or {}
    local added = 0
    for unique, it in pairs(pets) do
        if count + added >= 4 then break end
        if type(it) == "table" and it.kind and not isEgg(it.kind) and not activePets[unique] and petAge(it) >= PET_MAX_AGE then
            RouterClient.get("IdleProgressionAPI/AddPet"):FireServer(unique); added = added + 1; task.wait(0.1)
        end
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
    local eqp = "NONE"
    local okE, eq = pcall(function() return EquippedPets.get_my_equipped() end)
    if okE and eq and eq[1] then eqp = tostring(eq[1].kind) .. " a" .. tostring(eq[1].properties and eq[1].properties.age) end
    return { team = tostring(ClientData.get("team")), has_char = char ~= nil, char_pos = pos,
        in_house = dbgInHouse, furniture = dbgFurniture, task = currentStatus, egg_bought = eggBoughtCount,
        equipped_pet = eqp, baby_ailments = babyA, pet_ailments = petA, last_fixed = lastFixed, last_error = lastError }
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
    for _ = 1, 6 do
        if isInHouse() then return true end
        pcall(function() RouterClient.get("TeamAPI/Spawn"):InvokeServer("home", { source_for_logging = "recover" }) end)
        task.wait(2.5)
        if isInHouse() then return true end
        pcall(function() InteriorsM.enter_smooth("housing", "MainDoor", { house_owner = LocalPlayer }) end)
        local t = 0
        while t < 6 do task.wait(0.5); t = t + 0.5; if isInHouse() then return true end end
        pcall(function() InteriorsM.exit_smooth() end); task.wait(1.5)
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
    -- get into the house and settle FIRST, THEN become a baby + equip a pet, THEN the rest.
    -- (becoming a baby before being home seems to interfere with the pet equipping.)
    task.spawn(function()
        ensureInHouse(setFarmStatus)
        task.wait(1.5)
        becomeBaby()
        task.wait(2)
        pcall(ensurePetEquipped)
        task.wait(1)
        pcall(fillPetPen); pcall(claimPetPen); pcall(claimMoneyTree); pcall(claimExtras)
    end)
    local loopCount = 0
    farmThread = task.spawn(function()
        while farming do
            local lok, lerr = pcall(function()
                loopCount = loopCount + 1
                if loopCount % 60 == 0 then task.spawn(function() pcall(claimExtras) end) end
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if not root then
                    setFarmStatus("No character", Color3.fromRGB(255,200,0))
                elseif not ensureInHouse(setFarmStatus) then
                    dbgInHouse = false; dbgFurniture = countFurniture()
                    setFarmStatus("Stuck outside house, retrying...", Color3.fromRGB(255,200,0))
                    task.wait(2)
                else
                    -- all of these can YIELD (streaming / RemoteFunction InvokeServer). Run them
                    -- fire-and-forget so a hang can never freeze the ailment loop.
                    task.spawn(function() pcall(function() LocalPlayer:RequestStreamAroundAsync(root.Position) end) end)
                    task.wait(0.2)
                    dbgInHouse = isInHouse(); dbgFurniture = countFurniture()
                    task.spawn(function() pcall(ensurePetEquipped) end)
                    if loopCount % 60 == 0 then task.spawn(function() pcall(claimPetPen); pcall(fillPetPen) end) end
                    if loopCount % MONEYTREE_EVERY == 0 then task.spawn(function() pcall(claimMoneyTree) end) end
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
                            local key = (fixable.tag or "?") .. ":" .. fixable.kind
                            local pok, r1, r2 = pcall(tryFixAilment, fixable)
                            local ok = pok and r1 or false
                            local info = pok and r2 or ("err: " .. tostring(r1))
                            if ok then
                                lastFixed = fixable.kind .. " (" .. tostring(info) .. ")"
                                ailmentAttempts[key] = nil
                                setFarmStatus("Fixed: " .. fixable.kind)
                            else
                                logErr("fix " .. fixable.kind, info)   -- only real failures go to last_error
                                -- if the ailment actually made progress, DON'T give up - keep going
                                local afterProg = ailmentProgress(fixable.kind, fixable.wrapper)
                                if afterProg > (fixable.progress or 0) + 0.001 then
                                    ailmentAttempts[key] = nil               -- progressing -> reset the counter
                                    ailmentCooldown[key] = os.time() + 2     -- retry almost immediately
                                    setFarmStatus("Progressing " .. fixable.kind .. " (" .. math.floor(afterProg * 100) .. "%)")
                                else
                                    ailmentAttempts[key] = (ailmentAttempts[key] or 0) + 1
                                    if ailmentAttempts[key] >= 2 then
                                        ailmentCooldown[key] = os.time() + 300   -- 2 tries, no progress -> give up, move on
                                        setFarmStatus("Gave up " .. fixable.kind .. " (2 tries, no progress)", Color3.fromRGB(255,150,0))
                                    else
                                        ailmentCooldown[key] = os.time() + 5     -- quick retry for the 2nd try
                                        setFarmStatus("Retry " .. fixable.kind .. " (try " .. ailmentAttempts[key] .. ")", Color3.fromRGB(255,200,0))
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            if not lok then logErr("loop", lerr) end
            task.wait(FARM_LOOP_INTERVAL)
        end
    end)
end
farmBtn.MouseButton1Click:Connect(function() if farming then stopFarm() else startFarm() end end)

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
    if interval < 3 then interval = 3 end   -- floor to avoid hammering the shop (429s)
    local eggKind = EGG_BUY_OPTIONS[selectedEggBuyIndex].kind
    local eggCategory = EGG_BUY_OPTIONS[selectedEggBuyIndex].category
    eggBuying = true; currentMode = "egg"; eggBoughtCount = 0
    startEggBtn.Text = "Stop AutoEgg"; startEggBtn.BackgroundColor3 = Color3.fromRGB(170,60,60)
    setEggStatus("Running...")
    eggThread = task.spawn(function()
        while eggBuying do
            currentStatus = "egg (bought " .. eggBoughtCount .. ")"
            local ok, err = pcall(function() return shopBuy(eggCategory, eggKind) end)
            if ok then eggBoughtCount = eggBoughtCount + 1; eggBoughtLabel.Text = "Bought: " .. eggBoughtCount; setEggStatus("Bought! Total: " .. eggBoughtCount)
            else setEggStatus("Failed: " .. tostring(err):sub(1,30), Color3.fromRGB(255,200,0)); logErr("buyEgg", err) end
            task.wait(interval)
        end
    end)
end
startEggBtn.MouseButton1Click:Connect(function() if eggBuying then stopEgg() else startEgg() end end)

switchTab("trade")
