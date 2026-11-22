-- Floor: finds auctions listed below their vendor price on WoW Forever.
--
-- The scan only reads the auction house. Nothing is bought or posted by the
-- addon: you open an item from the results and buy it with your own clicks in
-- Blizzard's window, which is what Blizzard's addon rules require.
--
-- Files: Core.lua (settings, item data, slash commands), Scan.lua (the scan),
-- UI.lua (the results window and the button on the auction house).

local ADDON_NAME = ...

Floor = Floor or {}
local F = Floor
F.version = "0.7.1"
F.debug = false
F.ahOpen = false

local DEFAULTS = {
  mins = {},             -- per view: copper per unit below the reference price before an item counts (default 1)
  maxes = {},            -- per view: copper you are willing to spend on one item (default 0 = no limit)
  minTotalProfit = 0,    -- copper of total profit before a checked item is shown (0 = show all)
  detailLimit = 25,      -- how many candidates get their listings checked after a scan
  autoScan = false,      -- start a scan when the auction house opens
  loop = 0,              -- rescan every this many seconds while the auction house is open (0 = off, min 30)
  snipeEvery = 3,        -- seconds between looks at the newest listings while sniping
  snipeSound = true,     -- play a sound when a snipe hit appears
  bidsOnScan = true,     -- a scan also runs the bid dump when the 15-minute window allows
  sorts = {},            -- row order per view, see Scan.SORT_DEFAULTS (both | volume | ratio | profit | unit | lowest | vendor | below | cost)
  mode = "floor",        -- which list the window shows: floor | dips | bids
  dipRecipeMax = 5,      -- dips: a recipe with more copies than this at or near the dip price is "adjusted", not a dip
  dipsEnabled = true,    -- look for items below their normal price
  dipAll = false,        -- dips: false = stackables, recipes and quest items only; true = everything
  lastReplicate = 0,     -- when the full auction dump (bid scan) last ran
  bidMaxTimeLeft = 1,    -- bids: only auctions with this much time left or less (1 <30m, 2 <2h, 3 <12h, 4 any)
  dipPercent = 60,       -- a dip is a lowest price at or under this % of the normal price
  dipDays = 3,           -- days of price memory needed before an item can be a dip
  dipWindow = 7,         -- the normal price is the median of the daily lows over this many days
  dipMinNormal = 100,    -- ignore items whose normal price is under this many copper
  dipLimit = 25,         -- how many dip candidates get their listings checked after a scan
  history = {},          -- itemID -> "day:min:qty;..." (see History.lua)
  recipes = {},          -- recipeID -> { name, prof, out, qty, reagents } read from profession windows (see Crafts.lua)
  ignore = {},           -- itemID -> true
  pos = nil,             -- saved window position
  last = nil,            -- the last scan's results, for /floor list
}

------------------------------------------------------------------------------
-- Messages and money
------------------------------------------------------------------------------

-- What the dips view considers: everything, or stackables, recipes and quest
-- items only (the default). Narrowing applies at once; widening needs a scan,
-- since gear was never recorded as a dip.
function F.SetDipAll(on)
  F.db.dipAll = on and true or false
  if F.db.dipAll then
    F.Print("Dips consider every item, gear included. Run a scan to find gear dips.")
  else
    F.Print("Dips consider stackables, recipes and quest items only. Gear dips are hidden now.")
  end
  if F.UI then
    F.UI.Refresh()
  end
end

function F.Print(msg, ...)
  if select("#", ...) > 0 then
    msg = string.format(msg, ...)
  end
  print("|cff33ccff[Floor]|r " .. tostring(msg))
end

function F.Debug(msg, ...)
  if F.debug then
    F.Print("debug: " .. msg, ...)
  end
end

-- Copper -> "1g 2s 3c" (with coin icons when the client offers them).
function F.Money(copper)
  if copper == nil then
    return "-"
  end
  copper = math.floor(copper + 0.5)
  if GetMoneyString then
    return GetMoneyString(copper, true)
  end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then
    return string.format("%dg %ds %dc", g, s, c)
  elseif s > 0 then
    return string.format("%ds %dc", s, c)
  end
  return string.format("%dc", c)
end

-- "1g 2s 3c", "5s", "50c" or a bare number of copper -> copper, or nil.
function F.ParseMoney(text)
  if type(text) ~= "string" then
    return nil
  end
  text = text:lower():gsub("%s+", "")
  if text == "" then
    return nil
  end
  if text:match("^%d+$") then
    return tonumber(text)
  end
  local total, matched = 0, false
  for amount, unit in text:gmatch("(%d+)([gsc])") do
    matched = true
    amount = tonumber(amount)
    if unit == "g" then
      total = total + amount * 10000
    elseif unit == "s" then
      total = total + amount * 100
    else
      total = total + amount
    end
  end
  if matched then
    return total
  end
  return nil
end

------------------------------------------------------------------------------
-- Item data
------------------------------------------------------------------------------

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Item data arrives from the server on demand. Callers queue a callback and we
-- ask the client to load the item; ITEM_DATA_LOAD_RESULT fires when it is in.
local pendingLoads = {}
local loader = CreateFrame("Frame")
loader:SetScript("OnEvent", function(_, _, itemID, success)
  local callbacks = pendingLoads[itemID]
  if callbacks then
    pendingLoads[itemID] = nil
    for _, callback in ipairs(callbacks) do
      callback(success)
    end
  end
  if next(pendingLoads) == nil then
    loader:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
  end
end)

function F.LoadItem(itemID, callback)
  if not pendingLoads[itemID] then
    pendingLoads[itemID] = {}
  end
  table.insert(pendingLoads[itemID], callback)
  loader:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  C_Item.RequestLoadItemDataByID(itemID)
end

-- The price a vendor pays for one unit, or nil if the item is not cached yet
-- (the scan then loads the item and asks again). Only the client's own item
-- data is trusted here: Auctionator's "vendor price" cache holds what merchants
-- charge for items they sell, which is a different number.
function F.VendorPrice(itemID)
  local sellPrice = select(11, GetItemInfo(itemID))
  if sellPrice ~= nil then
    return sellPrice
  end
  return nil
end

-- What a merchant charges per unit for an item it sells in unlimited stock,
-- from Auctionator's cache of merchants you have visited. Nil if unknown.
function F.MerchantPrice(itemID)
  if Auctionator and Auctionator.API and Auctionator.API.v1
     and Auctionator.API.v1.GetVendorPriceByItemID then
    local ok, price = pcall(Auctionator.API.v1.GetVendorPriceByItemID, "Floor", itemID)
    if ok and type(price) == "number" and price > 0 then
      return price
    end
  end
  return nil
end

-- Auctionator's market price per unit (its lowest price from the last scan),
-- or nil when Auctionator is missing or has never seen the item.
function F.MarketPrice(itemID)
  if Auctionator and Auctionator.API and Auctionator.API.v1
     and Auctionator.API.v1.GetAuctionPriceByItemID then
    local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "Floor", itemID)
    if ok and type(price) == "number" then
      return price
    end
  end
  return nil
end

-- Name, quality and icon for a browse result's item key. Any of them may be
-- nil until the client has the item; the UI refreshes when the data arrives.
function F.ItemDisplay(itemKey)
  local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
  if info and info.itemName then
    return info.itemName, info.quality, info.iconFileID
  end
  local name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemKey.itemID)
  return name, quality, icon
end

function F.ItemLink(itemID)
  local link = select(2, GetItemInfo(itemID))
  return link or ("item:" .. tostring(itemID))
end

function F.Colorize(name, quality)
  local colors = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
  if colors and colors.hex then
    return colors.hex .. name .. "|r"
  end
  return name
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

local core = CreateFrame("Frame")
core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("AUCTION_HOUSE_SHOW")
core:RegisterEvent("AUCTION_HOUSE_CLOSED")
core:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON_NAME then
      return
    end
    FloorDB = FloorDB or {}
    for key, value in pairs(DEFAULTS) do
      if FloorDB[key] == nil then
        if type(value) == "table" then
          FloorDB[key] = {}
        else
          FloorDB[key] = value
        end
      end
    end
    F.db = FloorDB
    -- Older saved variables kept one order for every view.
    if type(FloorDB.sort) == "string" and FloorDB.sorts.floor == nil then
      FloorDB.sorts.floor = FloorDB.sort
    end
    FloorDB.sort = nil
    -- Min profit and max spend are kept per view; older saves had one of each.
    local oldMin, oldMax = FloorDB.minUnitProfit, FloorDB.maxSpend
    for _, mode in ipairs({ "floor", "dips", "bids", "crafts" }) do
      if FloorDB.mins[mode] == nil then
        FloorDB.mins[mode] = oldMin or 1
      end
      if FloorDB.maxes[mode] == nil then
        FloorDB.maxes[mode] = oldMax or 0
      end
    end
    FloorDB.minUnitProfit = nil
    FloorDB.maxSpend = nil
    F.Print("v%s loaded. Open the auction house and click Floor, or type /floor.", F.version)
  elseif event == "AUCTION_HOUSE_SHOW" then
    F.ahOpen = true
    if F.UI then
      F.UI.OnAuctionHouseShow()
    end
    if F.db and F.db.autoScan and F.Scan then
      C_Timer.After(1, function()
        if F.ahOpen then
          F.Scan.Start()
        end
      end)
    end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    F.ahOpen = false
    if F.Scan then
      F.Scan.Abort("the auction house closed")
    end
    if F.UI then
      F.UI.OnAuctionHouseClosed()
    end
  end
end)

------------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------------

local function PrintLast()
  local last = F.db.last
  if not last or not last.hits then
    F.Print("No scan saved yet.")
    return
  end
  F.Print("Last scan %s: %d items seen, %d below vendor price. Top hits:",
    date("%b %d %H:%M", last.time), last.items or 0, #last.hits)
  for i, hit in ipairs(last.hits) do
    if i > 15 then
      break
    end
    local below = hit.belowUnits and tostring(hit.belowUnits) or "?"
    local profit = hit.belowProfit and F.Money(hit.belowProfit) or "?"
    F.Print("%s  lowest %s, vendor %s, %s units below, profit %s",
      F.ItemLink(hit.itemID), F.Money(hit.minPrice), F.Money(hit.vendor), below, profit)
  end
  if last.dips and #last.dips > 0 then
    F.Print("%d items below their normal price. Top dips:", #last.dips)
    for i, hit in ipairs(last.dips) do
      if i > 10 then
        break
      end
      local below = hit.belowUnits and tostring(hit.belowUnits) or "?"
      local profit = hit.belowProfit and F.Money(hit.belowProfit) or "?"
      F.Print("%s  lowest %s, normal %s (%d days), %s units below, resale profit %s",
        F.ItemLink(hit.itemID), F.Money(hit.minPrice), F.Money(hit.normal), hit.days or 0, below, profit)
    end
  end
end

local function PrintHistory(itemID)
  local normal, days, falling, _, slope, flat, supply = F.History.Normal(itemID, F.db.dipWindow or 7, F.db.dipDays or 3)
  F.Print("%s: %d days of memory; normal %s (trend-adjusted)%s", F.ItemLink(itemID), days,
    normal and F.Money(normal) or "unknown", falling and " FALLING" or "")
  if normal then
    F.Print("  flat median %s, trend %+.1f%% a day%s", F.Money(flat or normal), (slope or 0) * 100,
      supply and string.format(", listed volume x%.1f over the window", supply) or "")
  end
  local entries = F.History.Merged(itemID, true)
  local today = F.History.Today()
  for i = math.max(1, #entries - 13), #entries do
    local e = entries[i]
    local ago = today - e.day
    F.Print("  %s: low %s%s, %d listed%s", ago == 0 and "today" or (ago .. " days ago"), F.Money(e.min),
      e.vwm and (", median " .. F.Money(e.vwm)) or "", e.qty or 0,
      e.source == "auctionator" and " (Auctionator)" or "")
  end
end

local function ItemIDFromArgument(arg)
  if not arg or arg == "" then
    return nil
  end
  local fromLink = arg:match("item:(%d+)")
  if fromLink then
    return tonumber(fromLink)
  end
  return tonumber(arg)
end

local function Help()
  F.Print("Commands:")
  F.Print("/floor            toggle the results window")
  F.Print("/floor scan       scan the auction house (it must be open): weapons and armor first, then the rest, then bids if allowed")
  F.Print("/floor quick      fast pass: weapons and armor only")
  F.Print("/floor snipe on   watch the newest listings every few seconds and call out hits (/floor snipe off, /floor snipe 5 for every 5 s)")
  F.Print("/floor loop 60    rescan every 60 seconds while the auction house is open (/floor loop off)")
  F.Print("/floor bidsonscan off  stop the scan from also running the bid dump")
  F.Print("/floor market     how fast prices are moving across the whole market")
  F.Print("/floor timing     where the last scan's seconds went: the server's pace against Floor's own")
  F.Print("/floor min 5s     current view: only count items at least this far below the reference price per unit")
  F.Print("/floor total 1g   only show checked items with at least this much total profit")
  F.Print("/floor max 5g     current view: the most you'll spend on one item; profit counts only what fits (0 = no limit)")
  F.Print("/floor limit 25   how many candidates get their listings checked after a scan")
  F.Print("/floor auto on    scan whenever the auction house opens (on/off)")
  F.Print("/floor sort both  order the current view by both (ratio x profit), volume, ratio, profit, unit, lowest, vendor, below or cost")
  F.Print("/floor recipemax 5  dips: a recipe with more copies than this at or near the dip price counts as adjusted, not a dip")
  F.Print("/floor mode dips  show price dips (items below their normal price); modes: all, floor, dips, bids, crafts")
  F.Print("/floor recipes    how many recipes Floor has read from your profession windows (open one to teach it)")
  F.Print("/floor bids       read every auction (allowed every 15 min) for next bids below the resale price")
  F.Print("/floor bidtime short  bids: only auctions ending within short (<30 min), medium (<2 h), long (<12 h) or all")
  F.Print("/floor dipall on  dips consider everything, not just stackables, recipes and quest items (on/off; also the button in the dips view)")
  F.Print("/floor stop       stop the scan that is running (the Scan button reads Stop meanwhile); what it found stays")
  F.Print("/floor dip 60     a dip is a lowest price at or under this %% of the normal price")
  F.Print("/floor dipdays 3  days of price memory needed before an item can be a dip")
  F.Print("/floor dipwindow 7  the normal price is the median of the daily lows over this many days")
  F.Print("/floor dipmin 1s  ignore items whose normal price is below this")
  F.Print("/floor history <item link or ID>  show an item's price memory")
  F.Print("/floor ignore <item link or ID>, /floor unignore <ID>, /floor ignored")
  F.Print("/floor list       print the last scan's top hits and dips")
  F.Print("/floor debug      toggle debug messages")
  F.Print("/floor reset      forget settings and the last scan (price memory is kept); /floor reset history clears it")
end

SLASH_FLOOR1 = "/floor"
SlashCmdList["FLOOR"] = function(input)
  input = input or ""
  local command, rest = input:match("^(%S*)%s*(.-)$")
  command = (command or ""):lower()

  if command == "" then
    if F.UI then
      F.UI.Toggle()
    end
  elseif command == "scan" then
    F.Scan.Start()
  elseif command == "quick" then
    F.Scan.Start({ quick = true })
  elseif command == "snipe" then
    local arg = rest:lower()
    if arg == "off" then
      F.Scan.SnipeStop()
    elseif arg == "sound" then
      F.db.snipeSound = not F.db.snipeSound
      F.Print("Snipe sound %s.", F.db.snipeSound and "on" or "off")
    else
      local n = tonumber(arg)
      if n then
        F.db.snipeEvery = math.max(2, math.floor(n))
        F.Print("Sniping looks at the newest listings every %d seconds.", F.db.snipeEvery)
      end
      if arg == "on" or n or arg == "" then
        if F.Scan.snipe.on then
          F.Scan.SnipeStop()
        else
          F.Scan.SnipeStart()
        end
      else
        F.Print("Usage: /floor snipe on | off | <seconds> | sound")
      end
    end
  elseif command == "loop" then
    local arg = rest:lower()
    if arg == "off" or arg == "0" then
      F.db.loop = 0
      F.Scan.ScheduleLoop()
      F.Print("Rescan loop off.")
    else
      local n = tonumber(arg)
      if n and n >= 30 then
        F.db.loop = math.floor(n)
        F.Print("Rescanning every %d seconds while the auction house is open, starting after the next scan.", F.db.loop)
      else
        F.Print("Usage: /floor loop 60  (30 or more seconds, or off)")
      end
    end
  elseif command == "bidsonscan" then
    local on = rest:lower()
    if on == "on" then
      F.db.bidsOnScan = true
    elseif on == "off" then
      F.db.bidsOnScan = false
    else
      F.db.bidsOnScan = not F.db.bidsOnScan
    end
    F.Print("A scan %s the bid dump when the 15-minute window allows.", F.db.bidsOnScan and "also runs" or "no longer runs")
  elseif command == "stop" then
    if F.Scan.Busy() then
      F.Scan.Abort("you stopped it; what it found so far stays")
    else
      F.Print("No scan is running.")
    end
  elseif command == "timing" then
    F.Print("%s", F.Scan.TimingText())
  elseif command == "market" then
    local text = F.Scan.DriftText("")
    if text == "" then
      local drift, n = F.History.MarketDrift(F.db.dipWindow or 7)
      if drift then
        F.Print("Market drift: %+.1f%%/day across %d items.", drift * 100, n)
      else
        F.Print("Not enough price memory yet to measure the market; it needs three days of scans.")
      end
    else
      F.Print("Market drift: %s", text)
    end
  elseif command == "min" then
    local copper = F.ParseMoney(rest)
    if (F.db.mode or "floor") == "all" then
      F.Print("The Sure things view takes each kind's settings from its own view: switch to the vendor floor, bid snipes or crafts first.")
    elseif copper then
      local mode = F.db.mode or "floor"
      F.db.mins[mode] = math.max(1, copper)
      F.Print("In the %s view, items now count when they are at least %s below the reference price per unit.", mode, F.Money(F.db.mins[mode]))
      if F.UI then F.UI.Refresh() end
    else
      F.Print("Usage: /floor min 5s  (or 50c, 1g2s, or a number of copper; applies to the current view)")
    end
  elseif command == "max" then
    local copper = F.ParseMoney(rest)
    if (F.db.mode or "floor") == "all" then
      F.Print("The Sure things view takes each kind's settings from its own view: switch to the vendor floor, bid snipes or crafts first.")
    elseif copper then
      local mode = F.db.mode or "floor"
      F.db.maxes[mode] = copper
      if copper > 0 then
        F.Print("In the %s view, max spend per item is %s. Items you can't afford are hidden and profit counts only the units that fit.", mode, F.Money(copper))
      else
        F.Print("No spending limit in the %s view.", mode)
      end
      if F.UI then F.UI.Refresh() end
    else
      F.Print("Usage: /floor max 5g  (0 for no limit; applies to the current view)")
    end
  elseif command == "mode" then
    local mode = rest:lower()
    local names = { all = "sure things (vendor floor, bid snipes and crafts together)", floor = "the vendor floor", dips = "price dips", bids = "bid snipes", crafts = "crafts" }
    if mode == "all" or mode == "sure" or mode == "reliable" then
      F.db.mode = "all"
    elseif mode == "dips" or mode == "dip" then
      F.db.mode = "dips"
    elseif mode == "floor" or mode == "vendor" then
      F.db.mode = "floor"
    elseif mode == "bids" or mode == "bid" then
      F.db.mode = "bids"
    elseif mode == "crafts" or mode == "craft" then
      F.db.mode = "crafts"
    else
      local order = { "all", "floor", "dips", "bids", "crafts" }
      local nextMode = order[1]
      for i, m in ipairs(order) do
        if m == F.db.mode then
          nextMode = order[i + 1] or order[1]
        end
      end
      F.db.mode = nextMode
    end
    F.Print("Showing %s.", names[F.db.mode] or F.db.mode)
    if F.UI then F.UI.Refresh() end
  elseif command == "bids" then
    F.Scan.StartBids()
  elseif command == "recipes" then
    if rest:lower() == "clear" then
      F.db.recipes = {}
      F.Print("Forgot the recipes read from your professions. Built-in conversions stay.")
    else
      local byProf = {}
      for _, r in pairs(F.db.recipes) do
        byProf[r.prof or "?"] = (byProf[r.prof or "?"] or 0) + 1
      end
      F.Print("%d recipes remembered from your professions (plus %d built-in conversions). Open a profession window to add more; /floor recipes clear forgets them.",
        F.Crafts.Count(), #F.Crafts.BUILTIN)
      for prof, n in pairs(byProf) do
        F.Print("  %s: %d", prof, n)
      end
    end
  elseif command == "bidtime" then
    local key = rest:lower()
    local value = F.Scan.TIME_LEFT_KEYS[key] or tonumber(key)
    if value and value >= 1 and value <= 4 then
      F.db.bidMaxTimeLeft = math.floor(value)
      F.Print("Bid snipes now show auctions ending within %s. Takes effect on the next bid scan.", F.Scan.TIME_LEFT[F.db.bidMaxTimeLeft])
    else
      F.Print("Usage: /floor bidtime short | medium | long | all")
    end
  elseif command == "dipall" then
    local on = rest:lower()
    if on == "on" then
      F.SetDipAll(true)
    elseif on == "off" then
      F.SetDipAll(false)
    else
      F.SetDipAll(not F.db.dipAll)
    end
  elseif command == "dip" then
    local n = tonumber(rest)
    if n and n > 0 and n < 100 then
      F.db.dipPercent = n
      F.Print("A dip is a lowest price at or under %d%% of the normal price.", n)
    else
      F.Print("Usage: /floor dip 60  (a percentage between 1 and 99)")
    end
  elseif command == "dipdays" then
    local n = tonumber(rest)
    if n and n >= 1 then
      F.db.dipDays = math.floor(n)
      F.Print("Items need %d days of price memory before they can be dips.", F.db.dipDays)
    else
      F.Print("Usage: /floor dipdays 3")
    end
  elseif command == "dipwindow" then
    local n = tonumber(rest)
    if n and n >= 2 and n <= F.History.KEEP_DAYS then
      F.db.dipWindow = math.floor(n)
      F.Print("The normal price is the median of the daily lows over %d days.", F.db.dipWindow)
    else
      F.Print("Usage: /floor dipwindow 7  (2 to %d)", F.History.KEEP_DAYS)
    end
  elseif command == "dipmin" then
    local copper = F.ParseMoney(rest)
    if copper then
      F.db.dipMinNormal = copper
      F.Print("Dips are only shown for items whose normal price is at least %s.", F.Money(copper))
    else
      F.Print("Usage: /floor dipmin 1s")
    end
  elseif command == "history" then
    local itemID = ItemIDFromArgument(rest)
    if itemID then
      PrintHistory(itemID)
    else
      F.Print("Usage: /floor history <item link or item ID>  (memory covers %d items)", F.History.Count())
    end
  elseif command == "sort" then
    local key = rest:lower()
    if F.Scan.SORTS[key] then
      F.Scan.SetSortKey(F.db.mode or "floor", key)
      F.Print("The %s view is ordered by %s.", F.db.mode or "floor", key)
      if F.UI then F.UI.Refresh() end
    else
      F.Print("Usage: /floor sort both | volume | ratio | profit | unit | lowest | vendor | below | cost")
    end
  elseif command == "recipemax" then
    local n = tonumber(rest)
    if n and n >= 0 then
      F.db.dipRecipeMax = math.floor(n)
      F.Print("A recipe with more than %d copies at or near the dip price counts as adjusted.", F.db.dipRecipeMax)
    else
      F.Print("Usage: /floor recipemax 5")
    end
  elseif command == "total" then
    local copper = F.ParseMoney(rest)
    if copper then
      F.db.minTotalProfit = copper
      F.Print("Checked items now show when their total profit is at least %s.", F.Money(copper))
      if F.UI then F.UI.Refresh() end
    else
      F.Print("Usage: /floor total 1g  (0 shows everything)")
    end
  elseif command == "limit" then
    local n = tonumber(rest)
    if n and n >= 0 then
      F.db.detailLimit = math.floor(n)
      F.Print("Up to %d candidates get their listings checked after a scan.", F.db.detailLimit)
    else
      F.Print("Usage: /floor limit 25")
    end
  elseif command == "auto" then
    local on = rest:lower()
    if on == "on" then
      F.db.autoScan = true
    elseif on == "off" then
      F.db.autoScan = false
    else
      F.db.autoScan = not F.db.autoScan
    end
    F.Print("Scan on auction house open: %s", F.db.autoScan and "on" or "off")
  elseif command == "ignore" then
    local itemID = ItemIDFromArgument(rest)
    if itemID then
      F.db.ignore[itemID] = true
      F.Print("Ignoring %s.", F.ItemLink(itemID))
      if F.UI then F.UI.Refresh() end
    else
      F.Print("Usage: /floor ignore <item link or item ID>")
    end
  elseif command == "unignore" then
    local itemID = ItemIDFromArgument(rest)
    if itemID then
      F.db.ignore[itemID] = nil
      F.Print("No longer ignoring %s.", F.ItemLink(itemID))
      if F.UI then F.UI.Refresh() end
    else
      F.Print("Usage: /floor unignore <item link or item ID>")
    end
  elseif command == "ignored" then
    local any = false
    for itemID in pairs(F.db.ignore) do
      any = true
      F.Print("Ignored: %s (%d)", F.ItemLink(itemID), itemID)
    end
    if not any then
      F.Print("Nothing is ignored.")
    end
  elseif command == "list" then
    PrintLast()
  elseif command == "debug" then
    F.debug = not F.debug
    F.Print("Debug messages %s.", F.debug and "on" or "off")
  elseif command == "reset" then
    if rest:lower() == "history" then
      FloorDB.history = {}
      F.Print("Price memory cleared.")
    else
      local history = FloorDB.history
      for key in pairs(FloorDB) do
        FloorDB[key] = nil
      end
      for key, value in pairs(DEFAULTS) do
        if type(value) == "table" then
          FloorDB[key] = {}
        else
          FloorDB[key] = value
        end
      end
      FloorDB.history = history or {}
      F.Print("Settings and the last scan were reset. Price memory was kept (/floor reset history clears it).")
    end
    if F.UI then F.UI.Refresh() end
  else
    Help()
  end
end
