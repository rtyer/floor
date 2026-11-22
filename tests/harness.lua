-- Headless test harness for the Floor addon: stubs the WoW API, loads the
-- addon files, runs a scan against fake auction data and checks the results.
-- Usage: luajit harness.lua <addon dir>
local addonDir = arg[1]
assert(addonDir, "pass the addon directory")

local failures = 0
local function check(cond, msg)
  if cond then print("  ok    " .. msg) else failures = failures + 1; print("  FAIL  " .. msg) end
end

------------------------------------------------------------------------------
-- Virtual clock, timers and events
------------------------------------------------------------------------------
local clock = 1000
function GetTime() return clock end
time = os.time
date = os.date

local timers = {}
C_Timer = {
  After = function(delay, fn) table.insert(timers, { at = clock + delay, fn = fn }) end,
  NewTimer = function(delay, fn)
    local t = { at = clock + delay, fn = fn }
    t.Cancel = function() t.cancelled = true end
    table.insert(timers, t)
    return t
  end,
}

local frames = {}
local throttleReady = true
local function FireEvent(name, ...)
  if name == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then throttleReady = true end
  for _, f in ipairs(frames) do
    if f.events[name] and f.scripts.OnEvent then f.scripts.OnEvent(f, name, ...) end
  end
end

local pendingEvents = {}
local function Later(name, ...)
  table.insert(pendingEvents, { name = name, args = { ... } })
end

local function Pump(seconds)
  seconds = seconds or 0.05
  local target = clock + seconds
  for _ = 1, 400 do
    -- deliver queued server events
    while #pendingEvents > 0 do
      local e = table.remove(pendingEvents, 1)
      FireEvent(e.name, unpack(e.args))
    end
    -- run OnUpdate handlers
    for _, f in ipairs(frames) do
      if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.016) end
    end
    -- run due timers
    local due = {}
    for i = #timers, 1, -1 do
      if timers[i].at <= clock then table.insert(due, 1, table.remove(timers, i)) end
    end
    for _, t in ipairs(due) do if not t.cancelled then t.fn() end end
    if #pendingEvents == 0 and #due == 0 and clock >= target then break end
    clock = clock + 0.016
  end
end

------------------------------------------------------------------------------
-- Frame stubs
------------------------------------------------------------------------------
local function Widget()
  local w = { scripts = {}, events = {}, shown = false, text = "" }
  return setmetatable(w, { __index = function(t, k)
    local methods = {
      RegisterEvent = function(self, e) self.events[e] = true end,
      UnregisterEvent = function(self, e) self.events[e] = nil end,
      SetScript = function(self, k2, fn) self.scripts[k2] = fn end,
      Show = function(self) self.shown = true end,
      Hide = function(self) self.shown = false end,
      IsShown = function(self) return self.shown end,
      SetShown = function(self, s) self.shown = s and true or false end,
      SetText = function(self, s) self.text = s end,
      GetText = function(self) return self.text end,
      HasFocus = function() return false end,
      GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
      CreateTexture = function() return Widget() end,
      CreateFontString = function() return Widget() end,
    }
    if methods[k] then return methods[k] end
    return function(self) return self end
  end })
end
function CreateFrame(kind, name, parent, template)
  local f = Widget()
  table.insert(frames, f)
  if name then _G[name] = f end
  return f
end
UIParent = Widget()
GameTooltip = Widget()
UISpecialFrames = {}
ITEM_QUALITY_COLORS = { [0] = { hex = "|cff9d9d9d" }, [1] = { hex = "|cffffffff" }, [2] = { hex = "|cff1eff00" } }
Enum = { AuctionHouseSortOrder = { Price = 0, TimeRemaining = 5 } }
SOUNDKIT = { RAID_WARNING = 8959 }
local soundsPlayed = 0
function PlaySound() soundsPlayed = soundsPlayed + 1 end
SlashCmdList = {}
function IsShiftKeyDown() return false end
GetMoneyString = nil

------------------------------------------------------------------------------
-- Fake items and auction house
------------------------------------------------------------------------------
-- id -> { name, quality, sell, cached, commodity, listings = { {price, qty}, ... }, pages }
local items = {
  [1001] = { name = "Light Leather", quality = 1, sell = 100, cached = true, commodity = true,
             listings = { { 80, 20 }, { 90, 10 }, { 120, 30 } } },
  [1002] = { name = "Rusty Axe", quality = 1, sell = 5000, cached = true, commodity = false,
             listings = { { 4000, 1 }, { 6000, 1 } } },
  [1003] = { name = "Linen Cloth", quality = 1, sell = 50, cached = true, commodity = true,
             listings = { { 60, 500 } } },
  [1004] = { name = "Slow Loader", quality = 2, sell = 300, cached = false, commodity = true,
             listings = { { 100, 5 }, { 299, 1 }, { 301, 2 } } },
  [1005] = { name = "No Vendor", quality = 1, sell = 0, cached = true, commodity = true,
             listings = { { 10, 10 } } },
  -- Vendor-sold reagent: a merchant charges 30s, vendors pay 7s 50c. Listed at 25s it is NOT a hit.
  [1006] = { name = "Elemental Flux", quality = 1, sell = 750, cached = false, commodity = true,
             listings = { { 2500, 10 } } },
  -- Same item type listed at 5s: a real hit against the 7s 50c vendor price.
  [1007] = { name = "Cheap Flux", quality = 1, sell = 750, cached = false, commodity = true,
             listings = { { 500, 4 } } },
  -- Price-dip cases (vendor price tiny, so none is a floor hit):
  -- normally 10s for a week in Auctionator's memory, 5s today -> a dip.
  [1008] = { name = "Dip Target", quality = 2, sell = 10, cached = true, commodity = true,
             listings = { { 500, 3 }, { 980, 10 } } },
  -- only two days of memory -> not enough to call a dip.
  [1009] = { name = "Young Item", quality = 2, sell = 10, cached = true, commodity = true,
             listings = { { 500, 3 } } },
  -- own memory: 20s for four days then 10s for three -> the trend says ~8s 20c today, falling.
  -- Today two units sit at 3s and thirty at 9s: an outlier in a market that is still falling.
  [1010] = { name = "Falling Item", quality = 2, sell = 10, cached = true, commodity = true,
             listings = { { 300, 2 }, { 900, 30 } } },
  -- memory says 10s flat, but today 55 units sit at 4s-4s 50c: the market has moved,
  -- the normal is re-anchored to 4s 50c and 4s is no longer a dip against it.
  [1017] = { name = "Flooded Herb", quality = 1, sell = 10, cached = true, commodity = true,
             listings = { { 400, 5 }, { 450, 50 } } },
  -- memory with a 40-day-old entry that should be pruned.
  [1011] = { name = "Pruned Item", quality = 1, sell = 10, cached = true, commodity = true,
             listings = { { 100, 1 } } },
  -- a recipe (not stackable) at half its normal price: dips include recipes.
  [1013] = { name = "Old Recipe", quality = 2, sell = 10, cached = true, commodity = false, class = 9,
             listings = { { 500, 2 } } },
  -- gear at half its normal price: dips skip gear unless /floor dipall is on.
  [1014] = { name = "Dipping Boots", quality = 2, sell = 10, cached = true, commodity = false, class = 4,
             listings = { { 500, 1 } } },
  -- a sword whose only cheap listing is a BID (no buyout): the browse price says 10s,
  -- vendor pays 50s, but there is nothing to buy out, so the floor must not keep it.
  [1015] = { name = "Bid Only Sword", quality = 2, sell = 5000, cached = true, commodity = false, class = 2,
             listings = { { 1000, 1, "bid" } } },
  -- a recipe at half its normal price, but seven copies sit at or near that price:
  -- the market has adjusted, so it is not a dip.
  [1016] = { name = "Common Recipe", quality = 2, sell = 10, cached = true, commodity = false, class = 9,
             listings = { { 500, 1 }, { 500, 1 }, { 510, 1 }, { 510, 1 }, { 520, 1 }, { 520, 1 }, { 520, 1 } } },
}
items[1002].class = 2 -- Rusty Axe is a weapon

-- Crafting inputs and outputs (real classic ids): ore at 10c, bars at 25c; bronze needs a copper and a tin bar.
items[2770] = { name = "Copper Ore", quality = 1, sell = 1, cached = true, commodity = true, listings = { { 10, 100 } } }
items[2840] = { name = "Copper Bar", quality = 1, sell = 2, cached = true, commodity = true, listings = { { 25, 60 } } }
items[3576] = { name = "Tin Bar", quality = 1, sell = 3, cached = true, commodity = true, listings = { { 30, 40 } } }
items[2841] = { name = "Bronze Bar", quality = 1, sell = 5, cached = true, commodity = true, listings = { { 40, 80 } } }

-- A profession window: one learned recipe, Bronze Bar, which also exists as a built-in.
Enum.CraftingReagentType = { Basic = 1 }
C_TradeSkillUI = {
  GetAllRecipeIDs = function() return { 101 } end,
  GetRecipeInfo = function(id) return { recipeID = id, name = "Bronze Bar", learned = true } end,
  GetRecipeSchematic = function(id)
    return { outputItemID = 2841, quantityMin = 2, quantityMax = 2, reagentSlotSchematics = {
      { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 2840 } } },
      { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 3576 } } },
    } }
  end,
  GetTradeSkillLine = function() return 186, "Mining" end,
}

local TODAY = math.floor(os.time() / 86400)

-- Auctionator stub: its "vendor price" API returns what merchants CHARGE (30s for everything here),
-- and its database holds a week of daily lows for Dip Target and two days for Young Item.
Auctionator = {
  API = { v1 = {
    GetVendorPriceByItemID = function(_, id) return 3000 end,
    GetAuctionPriceByItemID = function(_, id) return nil end,
  } },
  Constants = { SCAN_DAY_0 = 0 },
  Database = {},
}
function Auctionator.Database:GetPriceHistory(key)
  local rows = {}
  if key == "1008" or key == "1013" or key == "1014" or key == "1016" or key == "1017" or key == "1020" or key == "1021" then
    for d = 1, 7 do table.insert(rows, { rawDay = tostring(TODAY - d), minSeen = 1000, maxSeen = 1200, available = 50 }) end
  elseif key == "1009" then
    for d = 1, 2 do table.insert(rows, { rawDay = tostring(TODAY - d), minSeen = 1000, maxSeen = 1200, available = 50 }) end
  end
  return rows
end
local function minPrice(it) local m; for _, l in ipairs(it.listings) do if not m or l[1] < m then m = l[1] end end return m end
local function totalQty(it) local t = 0; for _, l in ipairs(it.listings) do t = t + l[2] end return t end

C_Item = {
  GetItemInfo = function(id)
    local it = items[id]
    if not it or not it.cached then return nil end
    local stack = it.commodity and 20 or 1
    return it.name, "|Hitem:" .. id .. "|h[" .. it.name .. "]|h", it.quality, 1, 1, "Trade Goods", "Leather", stack, "", "icon" .. id, it.sell
  end,
  GetItemInfoInstant = function(id)
    local it = items[id]
    return id, "Type", "Subtype", "", "icon" .. id, it and it.class or 7, 0
  end,
  DoesItemExistByID = function(id) return items[id] ~= nil end,
  RequestLoadItemDataByID = function(id)
    local it = items[id]
    if it and not it.cached then
      C_Timer.After(0.1, function() it.cached = true; FireEvent("ITEM_DATA_LOAD_RESULT", id, true) end)
    end
  end,
}

local browsePages = {}
local pageIndex = 0
local searchItem
local searchesWithoutKey = 0
local browseQueries = {}
C_AuctionHouse = {
  SendBrowseQuery = function(query)
    -- honour the item class filter, like the real auction house
    local allowed
    if query and query.itemClassFilters and #query.itemClassFilters > 0 then
      allowed = {}
      for _, f in ipairs(query.itemClassFilters) do allowed[f.classID] = true end
    end
    table.insert(browseQueries, allowed and "filtered" or "all")
    local all = {}
    for id, it in pairs(items) do
      if not allowed or allowed[it.class or 7] then
        table.insert(all, { itemKey = { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 },
                            minPrice = minPrice(it), totalQuantity = totalQty(it), containsOwnerItem = false })
      end
    end
    -- newest first when asked to sort by time remaining (items carry a fake "posted" stamp)
    if query and query.sorts and query.sorts[1] and query.sorts[1].sortOrder == Enum.AuctionHouseSortOrder.TimeRemaining then
      table.sort(all, function(a, b)
        local pa, pb = items[a.itemKey.itemID].posted or 0, items[b.itemKey.itemID].posted or 0
        if pa ~= pb then return pa > pb end
        return a.itemKey.itemID < b.itemKey.itemID
      end)
    else
      table.sort(all, function(a, b) return a.itemKey.itemID < b.itemKey.itemID end)
    end
    browsePages = {}
    for i = 1, #all, 2 do
      table.insert(browsePages, { all[i], all[i + 1] })
    end
    pageIndex = 1
    throttleReady = false
    Later("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    Later("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  end,
  GetBrowseResults = function() return browsePages[1] end,
  HasFullBrowseResults = function() return pageIndex >= #browsePages end,
  RequestMoreBrowseResults = function()
    pageIndex = pageIndex + 1
    throttleReady = false
    Later("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    Later("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", browsePages[pageIndex])
  end,
  SendSearchQuery = function(itemKey)
    local it = items[itemKey.itemID]
    searchItem = itemKey.itemID
    if it.keyPending then searchesWithoutKey = searchesWithoutKey + 1 end
    throttleReady = false
    Later("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")   -- the server is ready for the next request at once...
    if it.silent then return end                      -- ...but some items never get an answer
    if it.slow then                                   -- ...and some answers take a while
      C_Timer.After(it.slow, function()
        if it.commodity then
          FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", itemKey.itemID)
        else
          FireEvent("ITEM_SEARCH_RESULTS_UPDATED", itemKey)
        end
      end)
    elseif it.commodity then
      Later("COMMODITY_SEARCH_RESULTS_UPDATED", itemKey.itemID)
    else
      Later("ITEM_SEARCH_RESULTS_UPDATED", itemKey)
    end
  end,
  GetCommoditySearchResultsQuantity = function(id) return #items[id].listings end,
  GetCommoditySearchResultInfo = function(id, i) local l = items[id].listings[i]; return { unitPrice = l[1], quantity = l[2] } end,
  HasFullCommoditySearchResults = function() return true end,
  GetItemSearchResultsQuantity = function(key)
    local it = items[key.itemID]
    if it.flaky and not it.flakyServed then it.flakyServed = true; return 0 end  -- first answer: empty
    return #it.listings
  end,
  GetItemSearchResultInfo = function(key, i)
    local l = items[key.itemID].listings[i]
    if l[3] == "bid" then
      return { buyoutAmount = nil, bidAmount = l[1] * l[2], minBid = l[1] * l[2], quantity = l[2] }
    end
    return { buyoutAmount = l[1] * l[2], quantity = l[2] }
  end,
  HasFullItemSearchResults = function(key) local it = items[key.itemID]; return not (it and it.flaky and not it.flakyServed) end,
  HasSearchResults = function() return true end,
  IsThrottledMessageSystemReady = function() return throttleReady end,
  GetItemKeyInfo = function(key)
    local it = items[key.itemID]
    if not it then return nil end
    if it.keyPending then
      -- not cached yet: asking starts the load, which lands a little later
      if not it.keyRequested then
        it.keyRequested = true
        C_Timer.After(0.3, function() it.keyPending = false; FireEvent("ITEM_KEY_ITEM_INFO_RECEIVED", key.itemID) end)
      end
      return nil
    end
    return { itemName = it.name, quality = it.quality, iconFileID = 1, isCommodity = it.commodity }
  end,
  MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
}

-- The full auction dump used by the bid scan.
-- { itemID, count, minBid, increment, buyout, bidAmount, weAreHighBidder, owner, timeLeft }
local auctions = {
  { 1002, 1, 2000, 100, 6000, 0, false, "Seller", 1 },     -- Rusty Axe: next bid 20s vs vendor 50s, ending soon
  { 1013, 1, 300, 20, 0, 400, false, "Other", 1 },         -- Old Recipe: next bid 4s 20c vs resale 9s 50c, ending soon
  { 1013, 1, 300, 20, 0, 400, true, "Other", 1 },          -- our own high bid: skipped
  { 1002, 1, 5500, 100, 7000, 0, false, "Pricey", 1 },     -- next bid above vendor: skipped
  { 1001, 20, 1000, 50, 1500, 0, false, "Stacker", 1 },    -- commodity: skipped
  { 1013, 1, 300, 20, 0, 0, false, "Patient", 3 },         -- Old Recipe with 2-12 h left: skipped unless /floor bidtime long
}
local replicateCalls = 0
C_AuctionHouse.ReplicateItems = function() replicateCalls = replicateCalls + 1; Later("REPLICATE_ITEM_LIST_UPDATE") end
C_AuctionHouse.GetNumReplicateItems = function() return #auctions end
C_AuctionHouse.GetReplicateItemInfo = function(i)
  local a = auctions[i + 1]
  local it = items[a[1]]
  return it.name, "icon", a[2], it.quality, true, 1, 0, a[3], a[4], a[5], a[6], a[7], nil, a[8], a[8], 0, a[1], true
end
C_AuctionHouse.GetReplicateItemTimeLeft = function(i) return auctions[i + 1][9] end
C_AuctionHouse.GetReplicateItemLink = function(i) return "|Hitem:" .. auctions[i + 1][1] .. "|h[x]|h" end
AuctionHouseFrame = Widget()
AuctionHouseFrame.selected = nil
AuctionHouseFrame.SelectBrowseResult = function(self, r) self.selected = r end

------------------------------------------------------------------------------
-- Load the addon
------------------------------------------------------------------------------
for _, file in ipairs({ "Core.lua", "History.lua", "Scan.lua", "Crafts.lua", "UI.lua" }) do
  local chunk, err = loadfile(addonDir .. "/" .. file)
  assert(chunk, err)
  chunk("Floor", {})
end

print("== load")
FireEvent("ADDON_LOADED", "Floor")
check(type(FloorDB) == "table" and Floor.Scan.MinUnit("floor") == 1 and Floor.Scan.MinUnit("dips") == 1 and Floor.Scan.Budget("bids") == nil, "saved variables initialised, per-view min and max at their defaults")
check(type(FloorDB.history) == "table" and FloorDB.mode == "floor", "price memory table and floor mode by default")

-- Seed Floor's own memory: Falling Item 20s x4 days then 10s x3 days; Pruned Item has a 40-day-old entry.
do
  local parts = {}
  for d = 7, 4, -1 do table.insert(parts, (TODAY - d) .. ":2000:40") end
  for d = 3, 1, -1 do table.insert(parts, (TODAY - d) .. ":1000:40") end
  FloorDB.history[1010] = table.concat(parts, ";")
  FloorDB.history[1011] = (TODAY - 40) .. ":100:1;" .. (TODAY - 1) .. ":100:1"
end

print("== price memory")
do
  local normal, days, falling, _, slope, flat = Floor.History.Normal(1010, 7, 3)
  check(normal >= 800 and normal <= 850 and days == 7, "Falling Item: trend reads about 8s 20c today, below the flat 20s median (" .. tostring(normal) .. ", " .. tostring(days) .. ")")
  check(flat == 2000, "Falling Item: the flat median is still reported (" .. tostring(flat) .. ")")
  check(slope < -0.10 and falling == true, string.format("Falling Item: trend about -14%% a day -> falling (%.3f)", slope))
  normal, days, falling, _, slope = Floor.History.Normal(1008, 7, 3)
  check(normal == 1000 and days == 7, "Dip Target: Auctionator's week fills in when own memory is short (" .. tostring(normal) .. ", " .. tostring(days) .. ")")
  check(slope == 0 and falling == false, "Dip Target: a flat week has no trend")
  local drift, n = Floor.History.MarketDrift(7)
  check(n == 1 and drift < -0.1, string.format("market drift rests on the one item with its own 3-day memory and is negative (%d, %.3f)", n, drift or 0))
  normal, days = Floor.History.Normal(1009, 7, 3)
  check(days == 2, "Young Item: only two days known (" .. tostring(days) .. ")")
  normal, days = Floor.History.Normal(1001, 7, 3)
  check(normal == nil and days == 0, "no memory at all -> no normal price")
  Floor.History.Record(1011, 100, 1)
  check(#Floor.History.Entries(1011) == 2, "recording prunes the 40-day-old entry (" .. #Floor.History.Entries(1011) .. " entries)")
  Floor.History.Record(1012, 300, 5)
  Floor.History.Record(1012, 250, 7)
  local e = Floor.History.Entries(1012)
  check(#e == 1 and e[1].min == 250 and e[1].qty == 7 and e[1].day == TODAY, "two records on one day keep the lower price and the latest quantity")
  Floor.History.RecordMedian(1012, 290)
  e = Floor.History.Entries(1012)
  check(#e == 1 and e[1].vwm == 290 and e[1].min == 250, "a median is added to today's entry without losing the low")
  check(FloorDB.history[1012] == TODAY .. ":250:7:290", "stored as day:min:qty:vwm (" .. tostring(FloorDB.history[1012]) .. ")")
  check(#Floor.History.Entries(1010) == 7 and Floor.History.Entries(1010)[1].vwm == nil, "old three-field entries still parse")
end

print("== money parsing")
check(Floor.ParseMoney("5s") == 500, "5s -> 500")
check(Floor.ParseMoney("1g2s3c") == 10203, "1g2s3c -> 10203")
check(Floor.ParseMoney("50") == 50, "50 -> 50 copper")
check(Floor.ParseMoney("abc") == nil, "garbage -> nil")
check(Floor.Money(10203) == "1g 2s 3c", "10203 -> 1g 2s 3c (" .. Floor.Money(10203) .. ")")

print("== recipes from a profession window")
FireEvent("TRADE_SKILL_LIST_UPDATE")
Pump(1)
check(FloorDB.recipes["101"] ~= nil and FloorDB.recipes["101"].out == 2841 and FloorDB.recipes["101"].qty == 2 and #FloorDB.recipes["101"].reagents == 2,
  "the Bronze Bar recipe was read: makes 2 from two reagents")
check(FloorDB.recipes["101"].prof == "Mining", "the profession name was read (" .. tostring(FloorDB.recipes["101"].prof) .. ")")
do
  local all = Floor.Crafts.All()
  local bronze, seen = 0, {}
  for _, k in ipairs(all) do
    if k.out == 2841 then bronze = bronze + 1; seen = k end
  end
  check(bronze == 1 and seen.source == "your profession", "the read recipe replaces the built-in Bronze Bar instead of duplicating it")
  check(#all == #Floor.Crafts.BUILTIN, "all crafts = built-ins with one replaced (" .. #all .. ")")
end

print("== scan before the auction house opens")
SlashCmdList.FLOOR("scan")
check(Floor.Scan.state == "idle", "refuses to scan with the auction house closed")

print("== scan")
FireEvent("AUCTION_HOUSE_SHOW")
Pump()
SlashCmdList.FLOOR("")       -- open the window
SlashCmdList.FLOOR("scan")
Pump(6)
check(Floor.Scan.state == "done", "scan reaches done (state=" .. tostring(Floor.Scan.state) .. ")")
check(Floor.Scan.browseCount == 20, "saw 20 browse results across both passes (" .. tostring(Floor.Scan.browseCount) .. ")")
check(Floor.Scan.Price(2770) == 10 and Floor.Scan.market[2770].total == 100, "the price map remembers Copper Ore at 10c, 100 listed")
check(#browseQueries == 2 and Floor.Scan.phaseIndex == 2, "two browse passes: weapons and armor, then the rest (" .. #browseQueries .. ")")
check(replicateCalls == 1 and #Floor.Scan.lists.bids == 2, "the scan also ran the bid dump and filled the bids view (" .. #Floor.Scan.lists.bids .. ")")

local byID = {}
for _, c in ipairs(Floor.Scan.candidates) do byID[c.itemID] = c end
check(byID[1001] ~= nil, "Light Leather (80 < 100) is a candidate")
check(byID[1002] ~= nil, "Rusty Axe (4000 < 5000) is a candidate")
check(byID[1003] == nil, "Linen Cloth (60 > 50) is not a candidate")
check(byID[1004] ~= nil, "Slow Loader counts once its item data arrives")
check(byID[1005] == nil, "item with no vendor price is skipped")
check(byID[1015] ~= nil and byID[1015].detailed and byID[1015].belowUnits == 0, "Bid Only Sword: browse price 10s was a bid; the listing check finds no buyout under vendor")
do
  local shown = {}
  for _, c in ipairs(Floor.Scan.Visible("floor")) do shown[c.itemID] = true end
  check(shown[1015] == nil, "Bid Only Sword is hidden from the vendor floor (buyouts only)")
  check(#Floor.Scan.Visible("floor") == 4, "the vendor floor shows the 4 real buyout hits (" .. #Floor.Scan.Visible("floor") .. ")")
end
check(byID[1006] == nil, "Elemental Flux at 25s is not a hit: merchant price (30s) is not the vendor price (7s 50c)")
check(byID[1007] ~= nil and byID[1007].vendor == 750, "Cheap Flux uses the loaded vendor price 7s 50c (" .. tostring(byID[1007] and byID[1007].vendor) .. ")")
if byID[1007] then
  check(byID[1007].detailed and byID[1007].belowUnits == 4 and byID[1007].belowProfit == 1000, "Cheap Flux: 4 below, profit 10s")
end

if byID[1001] then
  local c = byID[1001]
  check(c.detailed and c.belowUnits == 30, "Light Leather: 30 units below vendor (" .. tostring(c.belowUnits) .. ")")
  check(c.belowProfit == 500, "Light Leather: profit 500c (" .. tostring(c.belowProfit) .. ")")
  check(c.isCommodity == true, "Light Leather read as a commodity")
end
if byID[1002] then
  local c = byID[1002]
  check(c.detailed and c.belowUnits == 1 and c.belowProfit == 1000, "Rusty Axe: 1 below, profit 1000c (" .. tostring(c.belowUnits) .. ", " .. tostring(c.belowProfit) .. ")")
end
if byID[1004] then
  local c = byID[1004]
  check(c.detailed and c.belowUnits == 6 and c.belowProfit == 1001, "Slow Loader: 6 below, profit 1001c (" .. tostring(c.belowUnits) .. ", " .. tostring(c.belowProfit) .. ")")
end
print("== ordering")
check(Floor.Scan.SortKey("floor") == "both" and Floor.Scan.SortKey("dips") == "volume" and Floor.Scan.SortKey("bids") == "both",
  "default orders: floor both, dips volume, bids both")
local vis = Floor.Scan.Visible()
check(vis[1] and vis[1].itemID == 1004 and vis[2] and vis[2].itemID == 1007,
  "both: Slow Loader 2.0 x 10s 1c, then Cheap Flux 0.5 x 10s (" .. tostring(vis[1] and vis[1].itemID) .. ", " .. tostring(vis[2] and vis[2].itemID) .. ")")
check(vis[3] and vis[3].itemID == 1002 and vis[4] and vis[4].itemID == 1001,
  "both: Rusty Axe 0.25 x 10s beats Light Leather 0.25 x 5s")
check(math.abs(Floor.Scan.Both(vis[1]) - 2002) < 1e-6 and math.abs(Floor.Scan.Both(vis[4]) - 125) < 1e-6,
  "both scores: 2002 and 125 (" .. tostring(Floor.Scan.Both(vis[1])) .. ", " .. tostring(Floor.Scan.Both(vis[4])) .. ")")
local unchecked = { minPrice = 100, unitProfit = 50, detailed = false }
check(Floor.Scan.Profit(unchecked) == 50 and math.abs(Floor.Scan.Both(unchecked) - 25) < 1e-9,
  "an unchecked item counts one unit at the lowest price")
SlashCmdList.FLOOR("sort ratio")
vis = Floor.Scan.Visible()
check(vis[1].itemID == 1004 and vis[2].itemID == 1007 and vis[3].itemID == 1002 and vis[4].itemID == 1001,
  "ratio: 200%, 50%, then the 25% tie broken by profit per unit")
check(math.abs(Floor.Scan.Ratio(vis[1]) - 2.0) < 1e-9, "Slow Loader's ratio is 200%")
SlashCmdList.FLOOR("sort profit")
vis = Floor.Scan.Visible()
check(vis[1].itemID == 1004 and vis[2].itemID == 1007 and vis[3].itemID == 1002 and vis[4].itemID == 1001,
  "sort profit: 10s 1c, then the two 10s ties broken by ratio, then 5s")
SlashCmdList.FLOOR("sort lowest")
vis = Floor.Scan.Visible()
check(vis[1].itemID == 1001, "sort lowest: cheapest listing first (" .. tostring(vis[1].itemID) .. ")")
SlashCmdList.FLOOR("sort bogus")
check(Floor.Scan.SortKey("floor") == "lowest", "unknown sort key is refused")
check(Floor.Scan.SortKey("dips") == "volume", "changing the floor order leaves the dips order alone")
SlashCmdList.FLOOR("sort both")
-- the Order button cycles through every order and back to both
local cycles = {}
for _ = 1, #Floor.Scan.SORT_ORDER do
  FloorFrame.sortButton.scripts.OnClick(FloorFrame.sortButton)
  table.insert(cycles, Floor.Scan.SortKey("floor"))
end
check(cycles[1] == "volume" and cycles[#cycles] == "both", "Order button cycles volume ... back to both (" .. table.concat(cycles, ",") .. ")")
check(FloorDB.last and #FloorDB.last.hits == 5, "last scan saved with 5 floor candidates, the bid-only one included (" .. tostring(FloorDB.last and #FloorDB.last.hits) .. ")")

print("== price dips")
local dips = {}
for _, c in ipairs(Floor.Scan.lists.dips) do dips[c.itemID] = c end
check(dips[1008] ~= nil, "Dip Target (5s vs normal 10s) is a dip")
if dips[1008] then
  local c = dips[1008]
  check(c.normal == 1000 and c.ref == 950 and c.unitProfit == 450, "Dip Target: normal 10s, resale 9s 50c after the cut, 4s 50c per unit (" .. tostring(c.normal) .. ", " .. tostring(c.ref) .. ", " .. tostring(c.unitProfit) .. ")")
  check(c.detailed and c.belowUnits == 3 and c.belowProfit == 1350, "Dip Target: 3 units under the resale price, profit 13s 50c (" .. tostring(c.belowUnits) .. ", " .. tostring(c.belowProfit) .. ")")
  check(c.falling == false, "Dip Target is not flagged as falling")
end
if dips[1008] then
  local c = dips[1008]
  check(c.ladder and #c.ladder == 2 and c.ladderUnits == 13, "Dip Target ladder: 2 price tiers, 13 units (" .. tostring(c.ladder and #c.ladder) .. ", " .. tostring(c.ladderUnits) .. ")")
  check(c.vwMedian == 980, "Dip Target volume-weighted median is 9s 80c (" .. tostring(c.vwMedian) .. ")")
  check(c.marketIntact == true, "Dip Target: market intact, the 3 cheap units are outliers")
  check(c.ladder[1].cumulative == 3 and c.ladder[2].cumulative == 13, "ladder carries cumulative volume")
  local e = Floor.History.Entries(1008)
  check(#e == 1 and e[1].vwm == 980 and e[1].min == 500, "today's memory for Dip Target keeps low 5s and median 9s 80c")
end
if dips[1010] then
  local c = dips[1010]
  check(c.vwMedian == 900 and c.marketIntact == true and not c.reanchored, "Falling Item: 30 of 32 units at 9s, market intact around the trend normal, no re-anchor")
  check(c.belowUnits == 2 and c.falling == true, "Falling Item: the two 3s units are the dip, flagged falling (" .. tostring(c.belowUnits) .. ")")
end
check(dips[1017] ~= nil, "Flooded Herb is a dip candidate from memory (10s normal, 4s lowest)")
if dips[1017] then
  local c = dips[1017]
  check(c.reanchored == true and c.normalBefore == 1000 and c.normal == 450 and c.ref == 427,
    "Flooded Herb: 55 units at 4s-4s 50c -> normal re-anchored from 10s to today's 4s 50c median (" .. tostring(c.normal) .. ")")
  check(c.adjusted == true, "Flooded Herb: 4s is not a dip against 4s 50c -> market adjusted")
  check(c.unitProfit == 27 and c.belowUnits == 5, "Flooded Herb: against the re-anchored resale, 5 units are 27c under it")
  local shown = {}
  for _, v in ipairs(Floor.Scan.Visible("dips")) do shown[v.itemID] = true end
  check(shown[1017] == nil, "Flooded Herb is hidden from the dips view")
end
do
  local ladder, total, median = Floor.Scan.Ladder({ { price = 100, quantity = 1 }, { price = 300, quantity = 4 }, { price = 100, quantity = 2 }, { price = 200, quantity = 3 } })
  check(#ladder == 3 and ladder[1].price == 100 and ladder[1].quantity == 3 and total == 10 and median == 200,
    "Ladder merges equal prices, sorts, totals 10 and finds the 50% price (" .. tostring(median) .. ")")
end
check(dips[1009] == nil, "Young Item (2 days of memory) is not a dip")
check(dips[1010] ~= nil and dips[1010].falling == true, "Falling Item is a dip and flagged falling")
check(dips[1011] == nil, "Pruned Item (1 day of memory, price unchanged) is not a dip")
check(dips[1001] == nil and dips[1002] == nil, "floor hits with no memory are not dips")
check(dips[1013] ~= nil and dips[1013].detailed and dips[1013].belowUnits == 2, "Old Recipe (a recipe, not stackable) is a dip with 2 units checked")
check(dips[1014] == nil, "Dipping Boots (gear) is skipped by the dips focus")
check(dips[1016] ~= nil and dips[1016].detailed and dips[1016].adjusted == true and dips[1016].nearUnits == 7,
  "Common Recipe: 7 copies at or near the dip price -> market adjusted (" .. tostring(dips[1016] and dips[1016].nearUnits) .. ")")
check(dips[1013] and dips[1013].adjusted == nil and dips[1013].nearUnits == 2, "Old Recipe: 2 copies near the price stays a dip")
do
  local shown = {}
  for _, c in ipairs(Floor.Scan.Visible("dips")) do shown[c.itemID] = true end
  check(shown[1016] == nil and shown[1013] == true, "the adjusted recipe is hidden from the dips view, the real one shown")
end
check(Floor.Scan.DipEligible({ itemID = 1014 }) == false and Floor.Scan.DipEligible({ itemID = 1013 }) == true and Floor.Scan.DipEligible({ itemID = 1001 }) == true,
  "dip focus: gear no, recipe yes, stackable yes")
SlashCmdList.FLOOR("dipall on")
check(Floor.Scan.DipEligible({ itemID = 1014 }) == true, "/floor dipall on lets gear through")
SlashCmdList.FLOOR("dipall off")
check(FloorDB.last and #FloorDB.last.dips == 5, "last scan saved 5 dip candidates, the adjusted ones included (" .. tostring(FloorDB.last and #FloorDB.last.dips) .. ")")
check(FloorDB.last.drift ~= nil and FloorDB.last.driftItems >= 1, "the scan saved the market drift")
check(Floor.Scan.DriftText("Market: "):find("^Market: ") ~= nil and Floor.Scan.DriftText(""):find("deflating") ~= nil, "drift text reads as deflating (" .. Floor.Scan.DriftText("") .. ")")
check(#Floor.History.Entries(1001) == 1 and Floor.History.Entries(1001)[1].min == 80, "the scan recorded today's low for Light Leather")
check(Floor.History.Count() >= 11, "memory covers every scanned item (" .. Floor.History.Count() .. ")")
SlashCmdList.FLOOR("mode dips")
check(FloorDB.mode == "dips" and #Floor.Scan.Visible() == 3, "mode dips shows the 3 dips (" .. #Floor.Scan.Visible() .. ")")
do
  local v = Floor.Scan.Visible()
  check(v[1].itemID == 1010 and v[2].itemID == 1008 and v[3].itemID == 1013,
    "dips ordered by volume seen (32, 13, 2) (" .. v[1].itemID .. ", " .. v[2].itemID .. ", " .. v[3].itemID .. ")")
  SlashCmdList.FLOOR("sort both")
  v = Floor.Scan.Visible()
  check(v[1].itemID == 1010 and Floor.Scan.SortKey("dips") == "both" and Floor.Scan.SortKey("floor") == "both",
    "/floor sort in the dips view changes only the dips order (" .. v[1].itemID .. ")")
  SlashCmdList.FLOOR("sort volume")
end
SlashCmdList.FLOOR("dip 40")
check(FloorDB.dipPercent == 40, "/floor dip 40 sets the threshold")
SlashCmdList.FLOOR("history 1008")
SlashCmdList.FLOOR("mode floor")
check(FloorDB.mode == "floor" and #Floor.Scan.Visible() == 4, "mode floor shows the 4 floor hits again")

print("== filters and opening")
SlashCmdList.FLOOR("min 6s")
check(#Floor.Scan.Visible() == 1, "min 6s per unit leaves only Rusty Axe (" .. #Floor.Scan.Visible() .. " shown)")
SlashCmdList.FLOOR("min 1")
SlashCmdList.FLOOR("ignore 1002")
check(#Floor.Scan.Visible() == 3, "ignoring Rusty Axe hides it (" .. #Floor.Scan.Visible() .. " shown)")
SlashCmdList.FLOOR("unignore 1002")
check(#Floor.Scan.Visible() == 4, "unignore brings it back")

print("== gold / silver / copper boxes")
local minG, minS, minC = FloorFrame.minGroup.g, FloorFrame.minGroup.s, FloorFrame.minGroup.c
minG:SetText("0"); minS:SetText("6"); minC:SetText("0")
Floor.UI.ReadMinBoxes()
check(Floor.Scan.MinUnit("floor") == 600 and Floor.Scan.MinUnit("dips") == 1, "boxes 0g 6s 0c -> 600 copper for the floor view only (" .. tostring(Floor.Scan.MinUnit("floor")) .. ")")
check(#Floor.Scan.Visible() == 1, "6s per unit from the boxes leaves only Rusty Axe")
SlashCmdList.FLOOR("min 1g2s3c")
Floor.UI.FillBoxes()
check(minG:GetText() == "1" and minS:GetText() == "2" and minC:GetText() == "3",
  "boxes show 1 / 2 / 3 for 1g 2s 3c (" .. minG:GetText() .. "/" .. minS:GetText() .. "/" .. minC:GetText() .. ")")
minG:SetText(""); minS:SetText(""); minC:SetText("")
Floor.UI.ReadMinBoxes()
check(Floor.Scan.MinUnit("floor") == 1, "empty boxes fall back to 1 copper")

print("== max spend")
check(Floor.Scan.Budget("floor") == nil, "no budget by default")
do
  local u, cost, profit, cut = Floor.Scan.Affordable(byID[1001])
  check(u == 30 and cost == 80 * 20 + 90 * 10 and profit == 500 and cut == false,
    "no budget: Light Leather buys all 30 for 25s, profit 5s (" .. u .. ", " .. cost .. ", " .. profit .. ")")
end
SlashCmdList.FLOOR("max 7s")
check(Floor.Scan.Budget("floor") == 700 and Floor.Scan.Budget("dips") == nil and Floor.Scan.Budget("bids") == nil, "/floor max 7s sets a 700 copper budget for the floor view only")
do
  local u, cost, profit, cut = Floor.Scan.Affordable(byID[1001])
  check(u == 8 and cost == 640 and profit == 160 and cut == true,
    "7s budget: Light Leather buys 8 of the 80c units for 6s 40c, profit 1s 60c, cut short (" .. u .. ", " .. cost .. ", " .. profit .. ")")
  u, cost, profit, cut = Floor.Scan.Affordable(byID[1002])
  check(u == 0 and cut == true, "7s budget: Rusty Axe at 40s can't be bought at all")
  local visibleIDs = {}
  for _, c in ipairs(Floor.Scan.Visible("floor")) do visibleIDs[c.itemID] = true end
  check(visibleIDs[1002] == nil and visibleIDs[1001] and visibleIDs[1004] and visibleIDs[1007],
    "7s budget hides Rusty Axe and keeps the three affordable items")
  check(Floor.Scan.Profit(byID[1001]) == 160, "ordering uses the affordable profit (" .. tostring(Floor.Scan.Profit(byID[1001])) .. ")")
  local unchecked = { minPrice = 900, unitProfit = 50, detailed = false }
  u = Floor.Scan.Affordable(unchecked)
  check(u == 0, "an unchecked item above the budget counts as unaffordable")
  unchecked.minPrice = 600
  u, cost, profit = Floor.Scan.Affordable(unchecked)
  check(u == 1 and cost == 600 and profit == 50, "an unchecked item inside the budget counts one unit")
end
local maxG, maxS, maxC = FloorFrame.maxGroup.g, FloorFrame.maxGroup.s, FloorFrame.maxGroup.c
Floor.UI.FillBoxes()
check(maxG:GetText() == "0" and maxS:GetText() == "7" and maxC:GetText() == "0", "max spend boxes show 0 / 7 / 0")
maxG:SetText("2"); maxS:SetText("0"); maxC:SetText("0")
FloorFrame.maxGroup:Read()
check(FloorDB.maxes.floor == 20000 and Floor.Scan.Budget("floor") == 20000, "typing 2g in the boxes sets a 2g budget for the floor view (" .. tostring(FloorDB.maxes.floor) .. ")")
check(#Floor.Scan.Visible("floor") == 4, "2g budget shows all four floor items again")
SlashCmdList.FLOOR("sort cost")
check(Floor.Scan.Visible("floor")[1].itemID == 1004 or Floor.Scan.Visible("floor")[1].itemID == 1001, "sort cost puts a cheap buy first (" .. tostring(Floor.Scan.Visible("floor")[1].itemID) .. ")")
SlashCmdList.FLOOR("sort both")
SlashCmdList.FLOOR("max 0")
check(Floor.Scan.Budget("floor") == nil, "/floor max 0 removes the budget")
Floor.Scan.Open(byID[1001])
check(AuctionHouseFrame.selected and AuctionHouseFrame.selected.itemKey.itemID == 1001, "Open hands the browse result to Blizzard's SelectBrowseResult")
SlashCmdList.FLOOR("list")

print("== crafts")
do
  local byOut = {}
  for _, c in ipairs(Floor.Scan.lists.crafts) do byOut[c.itemID] = c end
  check(#Floor.Scan.lists.crafts == 2, "two crafts pay with today's prices (" .. #Floor.Scan.lists.crafts .. ")")
  local copper = byOut[2840]
  check(copper ~= nil and copper.minPrice == 10 and copper.ref == 23 and copper.unitProfit == 13,
    "Copper Ore 10c -> Copper Bar 25c: 23c after the cut, 13c profit per craft")
  check(copper and copper.belowUnits == 100 and copper.belowProfit == 1300, "100 ore listed -> 100 crafts possible, 13s total")
  local bronze = byOut[2841]
  check(bronze ~= nil and bronze.minPrice == 55 and bronze.ref == 76 and bronze.unitProfit == 21,
    "Copper Bar 25c + Tin Bar 30c -> 2 Bronze Bars at 40c: 76c after the cut, 21c profit (" .. tostring(bronze and bronze.minPrice) .. ", " .. tostring(bronze and bronze.ref) .. ")")
  check(bronze and bronze.belowUnits == 40 and bronze.craft.source == "your profession", "tin bars limit bronze to 40 crafts; the recipe came from the profession window")
  check(copper and copper.craft.route == "auction", "copper bars sell better on the auction house than to a vendor (2c)")
  SlashCmdList.FLOOR("mode crafts")
  check(FloorDB.mode == "crafts" and #Floor.Scan.Visible() == 2, "the crafts view shows both")
  check(Floor.Scan.Visible()[1].itemID == 2840, "ordered by ratio x profit: copper (1.3 x 13s) before bronze (0.38 x 8s 40c) (" .. tostring(Floor.Scan.Visible()[1].itemID) .. ")")
  SlashCmdList.FLOOR("max 3s")
  do
    local u, cost, profit = Floor.Scan.Affordable(copper)
    check(u == 30 and cost == 300 and profit == 390, "a 3s budget in the crafts view affords 30 copper crafts (" .. tostring(u) .. ")")
  end
  SlashCmdList.FLOOR("max 0")
  SlashCmdList.FLOOR("recipes")
  SlashCmdList.FLOOR("mode floor")
end

print("== bid snipes")
SlashCmdList.FLOOR("bids")
Pump(2)
check(Floor.Scan.state == "done" and replicateCalls == 1, "a manual bid scan right after the automatic one is refused (dump once) (state=" .. tostring(Floor.Scan.state) .. ")")
check(FloorDB.lastReplicate > 0, "the dump time is remembered")
local bids = {}
for _, c in ipairs(Floor.Scan.lists.bids) do bids[c.itemID] = (bids[c.itemID] or 0) + 1 end
check(#Floor.Scan.lists.bids == 2, "2 auctions have a next bid below resale (" .. #Floor.Scan.lists.bids .. ")")
check(bids[1002] == 1 and bids[1013] == 1, "one Rusty Axe auction and one Old Recipe auction; own bid, overpriced and commodity skipped")
for _, c in ipairs(Floor.Scan.lists.bids) do
  if c.itemID == 1002 then
    check(c.refKind == "vendor" and c.ref == 5000 and c.bid.nextBid == 2000 and c.belowProfit == 3000 and c.bid.timeLeft == 1,
      "Rusty Axe bid: vendor reference 50s, next bid 20s, profit 30s, ending soon")
  elseif c.itemID == 1013 then
    check(c.refKind == "normal" and c.ref == 950 and c.bid.nextBid == 420 and c.belowProfit == 530,
      "Old Recipe bid: resale 9s 50c, next bid 4s 20c (4s + 20c increment), profit 5s 30c (" .. tostring(c.bid.nextBid) .. ", " .. tostring(c.belowProfit) .. ")")
  end
end
SlashCmdList.FLOOR("mode bids")
check(FloorDB.mode == "bids" and #Floor.Scan.Visible() == 2, "mode bids shows both auctions")
check(Floor.Scan.Visible()[1].itemID == 1002, "ordered by ratio x profit: Rusty Axe (1.5 x 30s) first (" .. tostring(Floor.Scan.Visible()[1].itemID) .. ")")
SlashCmdList.FLOOR("max 10s")
check(Floor.Scan.Budget("bids") == 1000 and Floor.Scan.Budget("floor") == nil, "/floor max in the bids view sets the bids budget only")
check(#Floor.Scan.Visible() == 1 and Floor.Scan.Visible()[1].itemID == 1013, "a 10s budget hides the 20s bid and keeps the 4s 20c one")
check(#Floor.Scan.Visible("floor") == 4, "the floor view, with no budget of its own, still shows all four hits")
SlashCmdList.FLOOR("min 6s")
check(Floor.Scan.MinUnit("bids") == 600 and Floor.Scan.MinUnit("floor") == 1, "/floor min in the bids view sets the bids minimum only")
SlashCmdList.FLOOR("min 1")
do
  local u, cost, profit = Floor.Scan.Affordable(Floor.Scan.Visible()[1])
  check(u == 1 and cost == 420 and profit == 530, "a bid is all or nothing: 1 lot for 4s 20c, profit 5s 30c")
end
SlashCmdList.FLOOR("max 0")
SlashCmdList.FLOOR("bids")
check(replicateCalls == 1, "a second bid scan within 15 minutes is refused")
check(FloorDB.bidMaxTimeLeft == 1, "bids default to auctions ending within 30 minutes")
SlashCmdList.FLOOR("bidtime long")
check(FloorDB.bidMaxTimeLeft == 3, "/floor bidtime long widens to 12 hours")
FloorDB.lastReplicate = 0 -- pretend 15 minutes passed
SlashCmdList.FLOOR("bids")
Pump(2)
check(replicateCalls == 2 and #Floor.Scan.lists.bids == 3, "with the wider window the 2-12 h Old Recipe auction joins the list (" .. #Floor.Scan.lists.bids .. ")")
SlashCmdList.FLOOR("bidtime bogus")
check(FloorDB.bidMaxTimeLeft == 3, "unknown bidtime is refused")
SlashCmdList.FLOOR("bidtime short")
SlashCmdList.FLOOR("mode floor")

print("== snipe")
do
  local floorBefore = #Floor.Scan.lists.floor
  -- Someone posts Linen Cloth at 30c; vendors pay 50c. It is the newest listing.
  items[1003].listings = { { 30, 40 }, { 60, 500 } }
  items[1003].posted = 999
  local queriesBefore = #browseQueries
  SlashCmdList.FLOOR("snipe on")
  Pump(0.5)
  check(Floor.Scan.snipe.on == true and Floor.Scan.snipe.cycles >= 1, "sniping starts and runs a cycle (" .. Floor.Scan.snipe.cycles .. ")")
  check(#browseQueries == queriesBefore + Floor.Scan.snipe.cycles, "each cycle is one browse query, no paging")
  local linen
  for _, c in ipairs(Floor.Scan.lists.floor) do if c.itemID == 1003 then linen = c end end
  check(linen ~= nil and linen.new == true and linen.minPrice == 30 and linen.vendor == 50, "the new Linen Cloth listing at 30c is caught as a floor hit")
  check(Floor.Scan.snipe.hits >= 1 and soundsPlayed >= 1, "a hit is counted and the sound played (" .. Floor.Scan.snipe.hits .. ", " .. soundsPlayed .. ")")
  check(#Floor.Scan.lists.floor == floorBefore + 1, "no duplicate candidates from repeated cycles")
  -- Now a sword appears at 15s buyout; vendors pay 50s. Gear is verified before the alert.
  local soundsBefore = soundsPlayed
  items[1018] = { name = "New Sword", quality = 2, sell = 5000, cached = true, commodity = false, class = 2, posted = 1000,
                  listings = { { 1500, 1 } } }
  Pump(8)
  local sword
  for _, c in ipairs(Floor.Scan.lists.floor) do if c.itemID == 1018 then sword = c end end
  check(sword ~= nil and sword.new == true and sword.detailed == true and sword.belowUnits == 1,
    "the new sword is caught, verified by a listing check, and has a real buyout under vendor")
  check(sword and sword.alerted == true and soundsPlayed == soundsBefore + 1, "the sword is called out once, after verification (" .. tostring(soundsPlayed - soundsBefore) .. " sounds)")
  check(Floor.Scan.snipe.cycles >= 2, "cycles keep coming while sniping is on (" .. Floor.Scan.snipe.cycles .. ")")
  items[1018] = nil
  SlashCmdList.FLOOR("snipe off")
  check(Floor.Scan.snipe.on == false and Floor.Scan.snipeTimer == nil, "/floor snipe off stops the loop")
  items[1003].listings = { { 60, 500 } }
  items[1003].posted = nil
end

print("== listing checks go out while answers are pending")
do
  -- Five vendor-floor items (two gear, three stackable) whose answers take a second each,
  -- while the server is ready for the next request at once.
  local slow = { 1001, 1002, 1004, 1007, 1015 }
  for _, id in ipairs(slow) do items[id].slow = 1.0 end
  Floor.Scan.lastStart = nil
  SlashCmdList.FLOOR("scan")
  Pump(6)
  local t = Floor.Scan.timing
  check(Floor.Scan.state == "done", "scan with slow answers reaches done (state=" .. tostring(Floor.Scan.state) .. ")")
  check(t.maxInFlight >= 2 and t.maxInFlight <= Floor.Scan.DETAIL_IN_FLIGHT, "several searches were out at once, within the cap (" .. tostring(t.maxInFlight) .. ")")
  check(t.resultWait >= 5 and t.detailSeconds < 3.5, string.format("five one-second answers took under 3.5s of checking across two passes, not five (%.1fs for %.1fs of waiting)", t.detailSeconds, t.resultWait))
  check(t.checks >= 5 and t.unanswered == 0 and t.retries == 0, "every search was answered and used (" .. tostring(t.checks) .. " checks)")
  local byID2 = {}
  for _, c in ipairs(Floor.Scan.lists.floor) do byID2[c.itemID] = c end
  check(byID2[1001] and byID2[1001].detailed and byID2[1001].belowUnits == 30, "Light Leather's slow answer was still read: 30 below")
  check(Floor.Scan.TimingText():find("Listing checks", 1, true) ~= nil, "/floor timing describes the listing checks")
  SlashCmdList.FLOOR("timing")
  for _, id in ipairs(slow) do items[id].slow = nil end
end

print("== listing checks wait for key info, re-ask empty answers, give up on silence")
do
  items[1002].keyPending = true      -- Rusty Axe's key info is not cached yet
  items[1015].flaky = true           -- Bid Only Sword answers empty the first time
  items[1019] = { name = "Silent Dagger", quality = 2, sell = 8000, cached = true, commodity = false, class = 2,
                  listings = { { 3000, 1 } }, silent = true }
  searchesWithoutKey = 0
  Floor.Scan.lastStart = nil
  SlashCmdList.FLOOR("scan")
  Pump(6); Pump(6); Pump(6)
  local t = Floor.Scan.timing
  check(Floor.Scan.state == "done", "scan with a silent item still reaches done (state=" .. tostring(Floor.Scan.state) .. ")")
  check(searchesWithoutKey == 0, "no search went out before its item's key info was cached")
  local byID3 = {}
  for _, c in ipairs(Floor.Scan.lists.floor) do byID3[c.itemID] = c end
  check(byID3[1002] and byID3[1002].detailed and byID3[1002].belowUnits == 1, "Rusty Axe was checked once its key info arrived")
  check(byID3[1015] and byID3[1015].detailed and byID3[1015].belowUnits == 0, "Bid Only Sword's empty first answer was asked again and the real answer used")
  check(byID3[1019] and not byID3[1019].detailed and byID3[1019].detailFailed == true, "the Silent Dagger is given up after a second try and marked")
  check(t.retries == 2 and t.unanswered == 1, string.format("timing counts 2 re-asks and 1 never answered (%d, %d)", t.retries, t.unanswered))
  check(t.detailSeconds >= 2 * Floor.Scan.DETAIL_TIMEOUT and t.detailSeconds < 2 * Floor.Scan.DETAIL_TIMEOUT + 3,
    string.format("the silent item cost two timeouts and nothing else waited on it (%.1fs)", t.detailSeconds))
  items[1002].keyPending = nil; items[1002].keyRequested = nil
  items[1015].flaky = nil; items[1015].flakyServed = nil
  items[1019] = nil
end

print("== dips stay on stackables when the item cache is cold")
do
  -- A helm and a pet at 40% of their normal price, neither in the item cache nor the
  -- key-info cache when the browse sees them: Floor cannot ask whether they stack.
  items[1020] = { name = "Cold Helm", quality = 2, sell = 10, cached = false, commodity = false, class = 4,
                  keyPending = true, listings = { { 400, 1 } } }
  items[1021] = { name = "Mystery Pet", quality = 2, sell = 10, cached = false, commodity = false, class = 15,
                  keyPending = true, listings = { { 400, 1 } } }
  SlashCmdList.FLOOR("dip 60")
  Floor.UI.Show()
  Floor.Scan.lastStart = nil
  SlashCmdList.FLOOR("scan")
  Pump(6); Pump(6); Pump(6)
  check(Floor.Scan.state == "done", "scan finishes (state=" .. tostring(Floor.Scan.state) .. ")")
  local function dip(id) for _, c in ipairs(Floor.Scan.lists.dips) do if c.itemID == id then return c end end end
  local function shown(id) for _, c in ipairs(Floor.Scan.Visible("dips")) do if c.itemID == id then return true end end return false end
  check(dip(1020) == nil, "the helm is refused by its class before the cache knows anything about it")
  local pet = dip(1021)
  check(pet ~= nil, "the pet got in while its stack size was unknown")
  check(pet and not shown(1021), "once its key info arrived the pet is hidden from the dips view")
  check(pet and Floor.Scan.DipInScope(pet) == false and pet.dipScope == false, "the pet's verdict is remembered on the candidate")
  -- The button in the dips view flips the scope: widening needs a scan, narrowing applies at once.
  SlashCmdList.FLOOR("mode dips")
  Pump()
  check(FloorFrame.dipScope:IsShown() and FloorFrame.dipScope:GetText() == "Stackables only",
    "the dips view shows a Stackables only button (" .. tostring(FloorFrame.dipScope:GetText()) .. ")")
  FloorFrame.dipScope.scripts.OnClick(FloorFrame.dipScope)
  Pump()
  check(FloorDB.dipAll == true and FloorFrame.dipScope:GetText() == "Everything", "clicking it switches dips to everything")
  check(shown(1021) == true, "with everything on, the pet shows at once")
  Floor.Scan.lastStart = nil
  SlashCmdList.FLOOR("scan")
  Pump(6); Pump(6); Pump(6)
  check(dip(1020) ~= nil and shown(1020), "a scan with everything on finds the helm dip")
  SlashCmdList.FLOOR("dipall off")
  Pump()
  check(FloorDB.dipAll == false and not shown(1020) and not shown(1021), "/floor dipall off hides the helm and the pet without a scan")
  SlashCmdList.FLOOR("mode floor")
  Pump()
  check(not FloorFrame.dipScope:IsShown(), "the button leaves with the dips view")
  SlashCmdList.FLOOR("dip 40")
  items[1020] = nil
  items[1021] = nil
end

print("== stopping a scan")
do
  -- Rusty Axe's listing answer takes two seconds, so the scan is still checking when we look.
  items[1002].slow = 2.0
  Floor.Scan.lastStart = nil
  SlashCmdList.FLOOR("scan")
  Pump(0.3)
  check(Floor.Scan.Busy() and FloorFrame.scan:GetText():find("Stop", 1, true) ~= nil,
    "the Scan button reads Stop while a scan runs (state=" .. tostring(Floor.Scan.state) .. ", " .. tostring(FloorFrame.scan:GetText()) .. ")")
  local foundSoFar = #Floor.Scan.lists.floor
  check(foundSoFar > 0, "the first pass already listed something (" .. foundSoFar .. ")")
  FloorFrame.scan.scripts.OnClick(FloorFrame.scan)
  Pump()
  check(not Floor.Scan.Busy() and Floor.Scan.state == "idle", "clicking Stop ends the scan (state=" .. tostring(Floor.Scan.state) .. ")")
  check(FloorFrame.scan:GetText() == "Scan", "the button reads Scan again")
  check(#Floor.Scan.lists.floor == foundSoFar and (Floor.Scan.status or ""):find("stopped", 1, true) ~= nil,
    "what was found stays and the status says so (" .. tostring(Floor.Scan.status) .. ")")
  Pump(3)
  check(Floor.Scan.state == "idle" and #Floor.Scan.lists.floor == foundSoFar, "the late answer to a stopped scan changes nothing")
  SlashCmdList.FLOOR("stop")
  items[1002].slow = nil
end

print("== sure things: the unified view")
SlashCmdList.FLOOR("mode all")
check(FloorDB.mode == "all", "/floor mode all switches to the unified view")
do
  local all = Floor.Scan.Visible("all")
  local n = #Floor.Scan.Visible("floor") + #Floor.Scan.Visible("bids") + #Floor.Scan.Visible("crafts")
  check(n > 0 and #all == n, "it holds every vendor-floor, bid and craft row (" .. #all .. " of " .. n .. ")")
  local kinds, dips = {}, false
  for _, c in ipairs(all) do kinds[c.mode] = true; if c.mode == "dips" then dips = true end end
  check(kinds.floor and kinds.bids and kinds.crafts and not dips, "all three kinds appear and price dips do not")
  local ordered = true
  for i = 2, #all do if Floor.Scan.Both(all[i - 1]) < Floor.Scan.Both(all[i]) then ordered = false end end
  check(ordered, "it is ordered by ratio x profit across kinds")
  SlashCmdList.FLOOR("min 5s")
  SlashCmdList.FLOOR("max 5g")
  check(FloorDB.mins.all == nil and FloorDB.maxes.all == nil, "min and max are not set from the unified view")
  SlashCmdList.FLOOR("mode")
  check(FloorDB.mode == "floor", "/floor mode cycles from the unified view to the vendor floor")
end

print("== quick scan and rescan loop")
Floor.Scan.lastStart = nil
local queriesBefore = #browseQueries
SlashCmdList.FLOOR("loop 60")
check(FloorDB.loop == 60, "/floor loop 60 is stored")
SlashCmdList.FLOOR("quick")
Pump(4)
check(Floor.Scan.state == "done" and Floor.Scan.quick == true, "quick scan finishes (state=" .. tostring(Floor.Scan.state) .. ")")
check(#browseQueries == queriesBefore + 1 and Floor.Scan.browseCount == 3, "quick scan browsed only weapons and armor: 3 items (" .. tostring(Floor.Scan.browseCount) .. ")")
do
  local ids = {}
  for _, c in ipairs(Floor.Scan.lists.floor) do ids[c.itemID] = true end
  check(ids[1002] and ids[1015] and not ids[1001], "quick scan found the two gear floor candidates and no commodities")
end
check(Floor.Scan.loopTimer ~= nil, "a rescan is scheduled after the scan when the loop is on")
SlashCmdList.FLOOR("loop off")
check(FloorDB.loop == 0 and Floor.Scan.loopTimer == nil, "/floor loop off cancels it")
SlashCmdList.FLOOR("loop 5")
check(FloorDB.loop == 0, "a loop under 30 seconds is refused")

print("== reset keeps memory")
SlashCmdList.FLOOR("reset")
check(Floor.History.Count() >= 11 and Floor.Scan.MinUnit("floor") == 1 and Floor.Scan.Budget("floor") == nil, "/floor reset keeps the price memory and clears the per-view settings")
SlashCmdList.FLOOR("reset history")
check(Floor.History.Count() == 0, "/floor reset history clears it")

print("== second scan too soon, then close")
SlashCmdList.FLOOR("scan")
check(Floor.Scan.state == "done", "a second scan within 30 s is refused")
FireEvent("AUCTION_HOUSE_CLOSED")
check(Floor.ahOpen == false, "auction house close noted")

print(failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
