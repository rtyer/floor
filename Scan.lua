-- Floor: the scan.
--
-- Step 1, browse: ask the auction house for every item it has (an empty
-- browse query, paged with RequestMoreBrowseResults). Each result carries the
-- item's lowest unit price and total quantity. Two kinds of candidate come out
-- of it:
--   floor: the lowest price is under what a vendor pays for the item;
--   dips:  the lowest price is well under the item's normal price (the median
--          of recent daily lows, see History.lua), so it could be resold.
-- Every result also feeds the price memory.
--
-- Step 2, detail: for the best candidates, search the item itself to see the
-- actual listings, so we know how many units sit below the reference price
-- (vendor price, or normal price after the 5% cut) and what buying them earns.
--
-- Auction house requests are throttled by the server, so every request goes
-- through a small queue that waits for AUCTION_HOUSE_THROTTLED_SYSTEM_READY.

local F = Floor
local S = {}
F.Scan = S

S.state = "idle"        -- idle | browse | detail | bids | done
S.lists = { floor = {}, dips = {}, bids = {}, crafts = {} }
S.results = { floor = {}, dips = {}, bids = {}, crafts = {} }   -- mode -> key -> candidate, to avoid duplicates
S.candidates = S.lists.floor            -- the floor list, kept under its old name
S.market = {}                           -- itemID -> { minPrice, total, raw } from the last scan
S.browseCount = 0
S.auctionCount = 0      -- auctions seen by the last bid scan
S.scanID = 0            -- increments per scan; late callbacks check it
S.CUT = 0.95            -- the auction house keeps 5% of a sale
S.REPLICATE_WAIT = 15 * 60  -- the full dump is allowed about every 15 minutes

S.TIME_LEFT = { [1] = "< 30 min", [2] = "30 min - 2 h", [3] = "2 - 12 h", [4] = "> 12 h" }
S.TIME_LEFT_KEYS = { short = 1, medium = 2, long = 3, all = 4 }

-- Item classes (Enum.ItemClass values, with the numbers as a fallback).
local function ItemClass(name, fallback)
  return (Enum and Enum.ItemClass and Enum.ItemClass[name]) or fallback
end
local CLASS_RECIPE = ItemClass("Recipe", 9)
local CLASS_QUEST = ItemClass("Questitem", 12)
-- Classes whose items never stack, so they are never commodities.
local CLASS_WEAPON = ItemClass("Weapon", 2)
local CLASS_ARMOR = ItemClass("Armor", 4)
local CLASS_CONTAINER = ItemClass("Container", 1)
local CLASS_QUIVER = ItemClass("Quiver", 11)

local function ClassFilter(ids)
  local filters = {}
  for _, id in ipairs(ids) do
    table.insert(filters, { classID = id })
  end
  return filters
end

-- The browse scan runs in passes. The server paces every request, so the
-- scan cannot be made faster, but it can show the right things first:
-- weapons and armor carry the big vendor prices and the big mispricings, so
-- they are browsed and verified before the rest of the market.
S.PHASES = {
  { name = "weapons and armor", filters = ClassFilter({ ItemClass("Weapon", 2), ItemClass("Armor", 4) }) },
  { name = "the rest of the market", filters = ClassFilter({
      ItemClass("Consumable", 0), ItemClass("Container", 1), ItemClass("Gem", 3), ItemClass("Reagent", 5),
      ItemClass("Projectile", 6), ItemClass("Tradegoods", 7), ItemClass("ItemEnhancement", 8), ItemClass("Recipe", 9),
      ItemClass("Quiver", 11), ItemClass("Questitem", 12), ItemClass("Key", 13), ItemClass("Miscellaneous", 15) }) },
}

------------------------------------------------------------------------------
-- Throttle-aware request queue
------------------------------------------------------------------------------

local Q = { queue = {}, ready = true, lastSent = nil, sentAt = nil, pausedUntil = nil }
local STALL_SECONDS = 3       -- fallback when the client cannot be asked whether it is ready
local LONG_STALL_SECONDS = 10 -- fallback even when it can
local MIN_GAP = 0.1           -- never trust "ready" within this long of a send

-- Where the last scan's seconds went, for /floor timing.
S.timing = {}
function S.ResetTiming()
  S.timing = {
    requests = 0, readyWait = 0, readyMax = 0, stalls = 0, dropped = 0,
    checks = 0, resultWait = 0, resultMax = 0, retries = 0, unanswered = 0, keyWaits = 0, maxInFlight = 0,
    browseSeconds = 0, detailSeconds = 0, pages = 0, startedAt = GetTime(),
  }
end
S.ResetTiming()

-- The client knows whether the server will take another request right now.
-- When it can tell us, that is the answer and the ready event only prompts a
-- re-check. Without it (older clients, the test harness) the ready event
-- rules, with a stall guard in case one is missed.
local function ClientReady()
  if C_AuctionHouse.IsThrottledMessageSystemReady then
    return C_AuctionHouse.IsThrottledMessageSystemReady()
  end
  return nil
end

local function NoteReady()
  if Q.sentAt then
    local waited = GetTime() - Q.sentAt
    S.timing.readyWait = S.timing.readyWait + waited
    if waited > S.timing.readyMax then
      S.timing.readyMax = waited
    end
  end
  Q.ready = true
end

local function RunNext()
  local now = GetTime()
  if Q.pausedUntil then
    if now < Q.pausedUntil then
      return
    end
    Q.pausedUntil = nil
  end
  if not Q.ready and Q.sentAt and now - Q.sentAt >= MIN_GAP then
    local client = ClientReady()
    if client == true then
      NoteReady()
    elseif now - Q.sentAt > ((client == nil) and STALL_SECONDS or LONG_STALL_SECONDS) then
      S.timing.stalls = S.timing.stalls + 1
      NoteReady() -- the ready signal never came; assume it was missed
    end
  end
  if not Q.ready then
    return
  end
  local fn = table.remove(Q.queue, 1)
  if fn then
    Q.ready = false
    Q.lastSent = fn
    Q.sentAt = now
    S.timing.requests = S.timing.requests + 1
    fn()
  end
end

local throttle = CreateFrame("Frame")
throttle:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
throttle:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
throttle:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED")
throttle:RegisterEvent("AUCTION_HOUSE_SHOW")
throttle:RegisterEvent("AUCTION_HOUSE_CLOSED")
throttle:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    if not Q.ready then
      NoteReady()
    end
    RunNext()
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED" then
    RunNext() -- the client may already take the next one
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    F.Debug("request dropped by the throttle; it will be sent again")
    S.timing.dropped = S.timing.dropped + 1
    if Q.lastSent then
      table.insert(Q.queue, 1, Q.lastSent)
      Q.lastSent = nil
    end
    Q.ready = false
    Q.sentAt = GetTime()
  else
    Q.queue = {}
    Q.ready = true
    Q.lastSent = nil
    Q.sentAt = nil
    Q.pausedUntil = nil
  end
end)
throttle:SetScript("OnUpdate", function()
  if #Q.queue > 0 then
    RunNext()
  end
  if S.state == "detail" then
    S.DetailTick()
  end
end)

function S.Send(fn)
  table.insert(Q.queue, fn)
  RunNext()
end

function S.ClearQueue()
  Q.queue = {}
end

-- Hold Floor's own requests for a moment, so a click in the auction house
-- (which sends a search of its own) is not dropped by the throttle.
function S.Pause(seconds)
  Q.pausedUntil = GetTime() + (seconds or 1.5)
end

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function KeyOf(itemKey)
  return string.format("%d:%d:%d", itemKey.itemID or 0, itemKey.itemLevel or 0, itemKey.itemSuffix or 0)
end

local function SetStatus(text)
  S.status = text
  if F.UI then
    F.UI.SetStatus(text)
  end
end

local function Refresh()
  if F.UI then
    F.UI.Refresh()
  end
end

local function CancelTimer(name)
  if S[name] then
    S[name]:Cancel()
    S[name] = nil
  end
end

------------------------------------------------------------------------------
-- Row order
------------------------------------------------------------------------------

-- "ratio" is profit per unit as a share of what you pay. "both" multiplies
-- ratio by total profit: an item has to score well on both to reach the top,
-- and a big profit at a modest ratio still beats a tiny profit at a huge one.
S.SORTS = { both = true, ratio = true, profit = true, unit = true, lowest = true, vendor = true, below = true, cost = true, volume = true }
S.SORT_ORDER = { "both", "volume", "ratio", "profit", "unit", "lowest", "vendor", "below", "cost" }

-- Each view keeps its own order. Dips default to volume seen (how many units
-- are on the market, a liquidity signal) and then profit per unit.
S.SORT_DEFAULTS = { all = "both", floor = "both", dips = "volume", bids = "both", crafts = "both" }

-- The lowest listed unit price of an item in the last scan, or nil.
function S.Price(itemID)
  local m = S.market and S.market[itemID]
  return m and m.minPrice or nil
end

-- Remember an item's lowest price and total listed quantity across its
-- browse results (one per suffix variant), for the Crafts view and friends.
function S.RecordMarket(result)
  local itemID = result.itemKey.itemID
  local m = S.market[itemID]
  if not m then
    S.market[itemID] = { minPrice = result.minPrice, total = result.totalQuantity or 0, raw = result }
  else
    m.total = m.total + (result.totalQuantity or 0)
    if result.minPrice < m.minPrice then
      m.minPrice = result.minPrice
      m.raw = result
    end
  end
end

function S.SortKey(mode)
  mode = mode or (F.db and F.db.mode) or "floor"
  local sorts = F.db and F.db.sorts
  return (sorts and sorts[mode]) or S.SORT_DEFAULTS[mode] or "both"
end

function S.SetSortKey(mode, key)
  F.db.sorts = F.db.sorts or {}
  F.db.sorts[mode] = key
end

function S.Ratio(c)
  if not c.minPrice or c.minPrice <= 0 then
    return 0
  end
  return c.unitProfit / c.minPrice
end

-- Min profit per unit and max spend are kept per view.
function S.MinUnit(mode)
  mode = mode or (F.db and F.db.mode) or "floor"
  local mins = F.db and F.db.mins
  local v = mins and mins[mode]
  if v and v >= 1 then
    return v
  end
  return 1
end

-- The spending limit of a view in copper, or nil for no limit.
function S.Budget(mode)
  mode = mode or (F.db and F.db.mode) or "floor"
  local maxes = F.db and F.db.maxes
  local b = maxes and maxes[mode] or 0
  if b and b > 0 then
    return b
  end
  return nil
end

-- What buying this item within the budget looks like: units bought (cheapest
-- first), what they cost, the profit on them, and whether the budget cut the
-- purchase short. Before the listings are checked, the one unit we know about
-- at the lowest price stands in.
function S.Affordable(c)
  local budget = S.Budget(c.mode)
  if c.mode == "bids" then
    -- a bid takes the whole lot or nothing
    local total = c.bid and c.bid.nextBid or (c.minPrice * c.total)
    if budget and total > budget then
      return 0, 0, 0, true
    end
    return c.total, total, c.belowProfit or 0, false
  end
  if not c.detailed then
    if budget and c.minPrice > budget then
      return 0, 0, 0, true
    end
    return 1, c.minPrice, c.unitProfit, false
  end
  local units, cost, profit, truncated = 0, 0, 0, false
  for _, tier in ipairs(c.tiersAll or {}) do
    local n = tier.quantity
    if budget then
      local canAfford = math.floor((budget - cost) / tier.price)
      if canAfford < n then
        n = math.max(0, canAfford)
        truncated = true
      end
    end
    if n > 0 then
      units = units + n
      cost = cost + n * tier.price
      profit = profit + n * (c.ref - tier.price)
    end
    if truncated then
      break
    end
  end
  return units, cost, profit, truncated
end

-- Profit used for ordering: what you can afford to make.
function S.Profit(c)
  local _, _, profit = S.Affordable(c)
  return profit
end

function S.Both(c)
  return S.Ratio(c) * S.Profit(c)
end

function S.CompareWith(key, a, b)
  local x, y
  if key == "volume" then
    x, y = a.total or 0, b.total or 0
  elseif key == "both" then
    x, y = S.Both(a), S.Both(b)
  elseif key == "profit" then
    x, y = a.belowProfit or -1, b.belowProfit or -1
  elseif key == "unit" then
    x, y = a.unitProfit, b.unitProfit
  elseif key == "lowest" then
    x, y = -a.minPrice, -b.minPrice
  elseif key == "vendor" then
    x, y = a.ref, b.ref
  elseif key == "below" then
    x, y = a.belowUnits or -1, b.belowUnits or -1
  elseif key == "cost" then
    local _, ca = S.Affordable(a)
    local _, cb = S.Affordable(b)
    x, y = -ca, -cb
  else
    x, y = S.Ratio(a), S.Ratio(b)
  end
  if x ~= y then
    return x > y
  end
  -- Ties: volume falls back to profit per unit (the dips order is "volume
  -- seen, then resale per unit"); everything else falls back to ratio.
  if key == "volume" and a.unitProfit ~= b.unitProfit then
    return a.unitProfit > b.unitProfit
  end
  local ra, rb = S.Ratio(a), S.Ratio(b)
  if ra ~= rb then
    return ra > rb
  end
  if a.unitProfit ~= b.unitProfit then
    return a.unitProfit > b.unitProfit
  end
  return a.itemID < b.itemID
end

-- A comparator for one view's current order.
function S.Comparator(mode)
  local key = S.SortKey(mode)
  return function(a, b)
    return S.CompareWith(key, a, b)
  end
end

-- Compares two candidates of the same view by that view's order.
function S.Compare(a, b)
  return S.CompareWith(S.SortKey(a.mode), a, b)
end

-- Candidates of one mode ("floor" or "dips", default the window's mode) that
-- pass the current filters, in display order.
function S.Visible(mode)
  mode = mode or (F.db and F.db.mode) or "floor"
  if mode == "all" then
    return S.VisibleAll()
  end
  local list = S.lists[mode] or S.lists.floor
  local out = {}
  local minTotal = F.db.minTotalProfit or 0
  local budget = S.Budget(mode)
  local minUnit = S.MinUnit(mode)
  for _, c in ipairs(list) do
    local keep = not F.db.ignore[c.itemID]
    if keep and c.unitProfit < minUnit then
      keep = false
    end
    if keep and budget then
      local units = S.Affordable(c)
      if units == 0 then
        keep = false -- can't afford a single unit
      end
    end
    if keep and c.detailed and minTotal > 0 and S.Profit(c) < minTotal then
      keep = false
    end
    -- A checked item with nothing left under the reference price is not
    -- actionable: the cheap units were bought, or the browse price was a bid
    -- (the listing check only counts buyouts).
    if keep and c.detailed and c.mode ~= "bids" and (c.belowUnits or 0) == 0 then
      keep = false
    end
    -- A recipe with many copies at the dip price: the market has adjusted.
    if keep and c.adjusted then
      keep = false
    end
    -- Gear that got in while its stack size was unknown leaves once it is known.
    if keep and c.mode == "dips" and not S.DipInScope(c) then
      keep = false
    end
    if keep then
      table.insert(out, c)
    end
  end
  table.sort(out, S.Comparator(mode))
  return out
end

-- The unified view: everything with a sure profit (vendor floor, bid snipes,
-- crafts), each kind filtered by its own view's settings, in one order.
-- Price dips stay in their own view: a dip is a judgement, not a sure thing.
S.ALL_MODES = { "floor", "bids", "crafts" }
function S.VisibleAll()
  local out = {}
  for _, m in ipairs(S.ALL_MODES) do
    for _, c in ipairs(S.Visible(m)) do
      table.insert(out, c)
    end
  end
  table.sort(out, S.Comparator("all"))
  return out
end

------------------------------------------------------------------------------
-- Step 1: browse
------------------------------------------------------------------------------

-- opts.quick: only the weapons-and-armor pass, for a fast look at the big
-- vendor-floor items.
function S.Start(opts)
  if not F.ahOpen then
    F.Print("Open the auction house first.")
    return
  end
  if S.Busy() then
    F.Print("A scan is already running.")
    return
  end
  if S.lastStart and GetTime() - S.lastStart < 30 then
    F.Print("Wait %d seconds before scanning again.", math.ceil(30 - (GetTime() - S.lastStart)))
    return
  end
  S.lastStart = GetTime()
  S.scanID = S.scanID + 1
  S.quick = opts and opts.quick or false
  S.phases = S.quick and { S.PHASES[1] } or S.PHASES
  S.phaseIndex = 0
  S.manualDetail = false
  S.lists.floor, S.lists.dips = {}, {}
  S.results.floor, S.results.dips = {}, {}
  S.candidates = S.lists.floor
  S.market = {}
  S.browseCount = 0
  S.detailQueue = {}
  S.detailCurrent = nil
  CancelTimer("vendorTimer")
  CancelTimer("detailTimer")
  CancelTimer("loopTimer")
  S.ResetTiming()
  S.NextPhase()
end

-- Browse the next pass. Each pass is a browse query limited to a set of item
-- classes; its candidates get their listings checked before the next pass.
function S.NextPhase()
  S.phaseIndex = S.phaseIndex + 1
  local phase = S.phases[S.phaseIndex]
  if not phase then
    S.Finish()
    return
  end
  S.state = "browse"
  S.awaitingBrowse = true
  S.browseDone = false
  S.pendingVendor = 0
  S.timing.phaseStart = GetTime()
  S.timing.pages = (S.timing.pages or 0) + 1
  SetStatus(string.format("Scanning %s (pass %d of %d) for every view... don't search while this runs", phase.name, S.phaseIndex, #S.phases))
  Refresh()
  S.Send(function()
    C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = phase.filters })
  end)
end

function S.Abort(reason)
  CancelTimer("loopTimer")
  if S.snipe.on then
    S.SnipeStop(true)
  end
  if S.state ~= "browse" and S.state ~= "detail" and S.state ~= "bids" then
    return
  end
  S.state = "idle"
  S.awaitingBrowse = false
  S.detailCurrent = nil
  S.detailQueue = {}
  S.detailInFlight = {}
  S.ClearQueue()
  CancelTimer("vendorTimer")
  CancelTimer("detailTimer")
  CancelTimer("bidsTimer")
  S.stoppedAt = GetTime()
  SetStatus(string.format("Scan stopped: %s. %d below vendor, %d below normal so far.", tostring(reason), #S.lists.floor, #S.lists.dips))
  Refresh()
end

function S.Busy()
  return S.state == "browse" or S.state == "detail" or S.state == "bids"
end

-- Add a candidate. `ref` is the price per unit the profit is measured
-- against: the vendor price, or the normal price after the 5% cut.
local function AddCandidate(mode, result, ref, extra)
  local unitProfit = ref - result.minPrice
  if unitProfit < 1 then
    return nil
  end
  local key = KeyOf(result.itemKey)
  if S.results[mode][key] then
    return nil
  end
  local c = {
    mode = mode,
    key = key,
    itemKey = result.itemKey,
    itemID = result.itemKey.itemID,
    raw = result,               -- the browse result, handed back to Blizzard's UI to open it
    minPrice = result.minPrice,
    total = result.totalQuantity,
    ref = ref,
    unitProfit = unitProfit,
    detailed = false,
    belowUnits = nil,
    belowProfit = nil,
    tiers = nil,
    more = false,
    isCommodity = nil,
  }
  if extra then
    for k, v in pairs(extra) do
      c[k] = v
    end
  end
  S.results[mode][key] = c
  table.insert(S.lists[mode], c)
  return c
end

function S.EvaluateFloor(result, vendor)
  AddCandidate("floor", result, vendor, { vendor = vendor })
end

-- Is this item stackable, i.e. sold as a commodity? nil when unknown yet.
function S.IsCommodity(itemKey)
  local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
  if info and info.isCommodity ~= nil then
    return info.isCommodity
  end
  local stack = select(8, C_Item.GetItemInfo(itemKey.itemID))
  if stack then
    return stack > 1
  end
  return nil
end

-- Dips focus on things that trade in volume and resell cleanly: stackables
-- (trade goods, consumables...), recipes and quest items. Gear is skipped
-- unless /floor dipall is on, because one piece of armor at a low price is
-- rarely a market signal.
--
-- Returns true, false, or nil when it cannot tell yet. The item's class is
-- known for every item without the item cache, so gear, bags and quivers are
-- refused even on a cold client; only an unclassified stack size is unknown.
function S.DipEligible(itemKey)
  if F.db.dipAll then
    return true
  end
  local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(itemKey.itemID)
  if classID == CLASS_RECIPE or classID == CLASS_QUEST then
    return true
  end
  if classID == CLASS_WEAPON or classID == CLASS_ARMOR or classID == CLASS_CONTAINER or classID == CLASS_QUIVER then
    return false
  end
  if equipLoc and equipLoc ~= "" then
    return false -- anything worn is a single item
  end
  return S.IsCommodity(itemKey)
end

-- Does a dip candidate fit the dips focus, given what is known so far? The
-- listing answer settles whether it is a commodity; before that the class
-- and the item cache decide. Unknown items stay until they are known.
function S.DipInScope(c)
  if F.db.dipAll then
    return true
  end
  if c.dipScope == nil then
    local verdict
    if c.isCommodity == false then
      local classID = select(6, C_Item.GetItemInfoInstant(c.itemID))
      verdict = (classID == CLASS_RECIPE or classID == CLASS_QUEST)
    else
      verdict = S.DipEligible(c.itemKey)
    end
    if verdict == nil then
      return true
    end
    c.dipScope = verdict
  end
  return c.dipScope
end

function S.EvaluateDip(result)
  if F.db.dipsEnabled == false then
    return
  end
  if S.DipEligible(result.itemKey) == false then
    return
  end
  local itemID = result.itemKey.itemID
  local normal, days, falling, used, slope, flat, supplyChange = F.History.Normal(itemID, F.db.dipWindow or 7, F.db.dipDays or 3)
  if not normal or days < (F.db.dipDays or 3) then
    return
  end
  if normal < (F.db.dipMinNormal or 100) then
    return
  end
  if result.minPrice > normal * (F.db.dipPercent or 60) / 100 then
    return
  end
  AddCandidate("dips", result, math.floor(normal * S.CUT), {
    normal = normal,
    flatMedian = flat,
    slope = slope,
    supplyChange = supplyChange,
    days = days,
    falling = falling,
    recent = used,
  })
end

-- Today's market check for a dip. When most of today's volume sits well below
-- the trend-adjusted normal, the market has moved further than the memory
-- knew: re-anchor the normal to today's volume-weighted median and re-test.
function S.Reanchor(c)
  if c.mode ~= "dips" or not c.vwMedian or not c.normal then
    return
  end
  if c.vwMedian >= c.normal * 0.9 then
    return
  end
  -- A handful of cheap units is an outlier, not a market move. Only re-anchor
  -- when more units than the recipe threshold sit well below the normal.
  local cheapUnits = 0
  for _, tier in ipairs(c.ladder or {}) do
    if tier.price < c.normal * 0.9 then
      cheapUnits = cheapUnits + tier.quantity
    end
  end
  if cheapUnits <= (F.db.dipRecipeMax or 5) then
    return
  end
  c.reanchored = true
  c.normalBefore = c.normal
  c.normal = c.vwMedian
  c.ref = math.floor(c.vwMedian * S.CUT)
  c.unitProfit = c.ref - c.minPrice
  local below, profit, tiers = 0, 0, {}
  for _, tier in ipairs(c.ladder or {}) do
    if tier.price < c.ref then
      below = below + tier.quantity
      profit = profit + (c.ref - tier.price) * tier.quantity
      table.insert(tiers, { price = tier.price, quantity = tier.quantity })
    end
  end
  c.belowUnits = below
  c.belowProfit = profit
  c.tiersAll = tiers
  c.tiers = {}
  for i = 1, math.min(5, #tiers) do
    c.tiers[i] = tiers[i]
  end
  -- Still a dip against today's market?
  if c.unitProfit < 1 or c.minPrice > c.normal * (F.db.dipPercent or 60) / 100 then
    c.adjusted = true
  end
end

function S.Consider(result, fromSnipe)
  if not result or not result.itemKey then
    return
  end
  if (result.totalQuantity or 0) == 0 or (result.minPrice or 0) <= 0 then
    return
  end
  if not fromSnipe then
    S.browseCount = S.browseCount + 1
  end
  local itemKey = result.itemKey
  if (itemKey.battlePetSpeciesID or 0) ~= 0 then
    return
  end
  local itemID = itemKey.itemID

  S.RecordMarket(result)
  F.History.Record(itemID, result.minPrice, result.totalQuantity)
  S.EvaluateDip(result)

  local vendor = F.VendorPrice(itemID)
  if vendor == nil then
    if not C_Item.DoesItemExistByID(itemID) then
      return
    end
    local scanID = S.scanID
    S.pendingVendor = S.pendingVendor + 1
    F.LoadItem(itemID, function()
      if scanID ~= S.scanID then
        return
      end
      S.pendingVendor = math.max(0, S.pendingVendor - 1)
      local loaded = F.VendorPrice(itemID)
      if loaded then
        S.EvaluateFloor(result, loaded)
      end
      S.CheckBrowseDone()
    end)
    return
  end
  S.EvaluateFloor(result, vendor)
end

-- Work through a page of browse results a few hundred at a time so a big
-- market doesn't freeze the game.
function S.ProcessBatch(results, done)
  local scanID = S.scanID
  local i, n = 1, #results
  local function step()
    if scanID ~= S.scanID or S.state ~= "browse" then
      return
    end
    local stop = math.min(i + 399, n)
    for j = i, stop do
      S.Consider(results[j])
    end
    i = stop + 1
    if i > n then
      done()
    else
      C_Timer.After(0, step)
    end
  end
  step()
end

function S.NextPage()
  if S.state ~= "browse" then
    return
  end
  if not C_AuctionHouse.HasFullBrowseResults() then
    SetStatus(string.format("Scanning %s (pass %d of %d) for every view... %d items seen, %d below vendor, %d below normal so far",
      S.phases[S.phaseIndex].name, S.phaseIndex, #S.phases, S.browseCount, #S.lists.floor, #S.lists.dips))
    Refresh()
    S.timing.pages = (S.timing.pages or 0) + 1
    S.Send(function()
      C_AuctionHouse.RequestMoreBrowseResults()
    end)
  else
    S.browseDone = true
    S.CheckBrowseDone()
  end
end

function S.CheckBrowseDone()
  if S.state ~= "browse" or not S.browseDone then
    return
  end
  if S.pendingVendor > 0 then
    if not S.vendorTimer then
      SetStatus(string.format("Waiting for item data on %d items...", S.pendingVendor))
      S.vendorTimer = C_Timer.NewTimer(5, function()
        S.vendorTimer = nil
        S.pendingVendor = 0
        S.CheckBrowseDone()
      end)
    end
    return
  end
  CancelTimer("vendorTimer")
  S.StartDetail()
end

------------------------------------------------------------------------------
-- Step 2: detail
------------------------------------------------------------------------------

S.DETAIL_IN_FLIGHT = 3   -- listing searches awaiting an answer at once
S.DETAIL_TIMEOUT = 6     -- seconds before an unanswered search is asked again, then given up
S.KEY_WAIT = 2           -- seconds to wait for an item's key info before searching anyway

S.detailQueue = {}       -- candidates waiting to be searched
S.detailInFlight = {}    -- { c, sentAt, tries } for searches awaiting an answer

-- The server ignores a search for an item whose key info the client has not
-- cached yet (Auctionator works around the same thing). Asking for the info
-- starts the load; the search waits until it is there.
local function KeyReady(c)
  if not C_AuctionHouse.GetItemKeyInfo then
    return true
  end
  return C_AuctionHouse.GetItemKeyInfo(c.itemKey) ~= nil
end

function S.StartDetail()
  S.state = "detail"
  S.timing.browseSeconds = (S.timing.browseSeconds or 0) + (GetTime() - (S.timing.phaseStart or GetTime()))
  S.timing.detailStart = GetTime()
  table.sort(S.lists.floor, S.Comparator("floor"))
  table.sort(S.lists.dips, S.Comparator("dips"))
  S.detailQueue = {}
  S.detailInFlight = {}
  local function wanted(c)
    return not c.detailed and not c.queued and not F.db.ignore[c.itemID] and c.unitProfit >= S.MinUnit(c.mode)
      and (c.mode ~= "dips" or S.DipInScope(c))
  end
  local function queueFrom(list, limit, firstPass)
    local n = 0
    if firstPass then
      for _, c in ipairs(list) do
        if n >= limit then
          break
        end
        if wanted(c) and firstPass(c) then
          table.insert(S.detailQueue, c)
          c.queued = true
          n = n + 1
        end
      end
    end
    for _, c in ipairs(list) do
      if n >= limit then
        break
      end
      if wanted(c) and not c.queued then
        table.insert(S.detailQueue, c)
        c.queued = true
        n = n + 1
      end
    end
  end
  -- Floor: the browse price of a non-stackable item can be a bid rather than
  -- a buyout, so those get checked first; the listing check counts buyouts only.
  queueFrom(S.lists.floor, F.db.detailLimit or 25, function(c)
    return S.IsCommodity(c.itemKey) ~= true
  end)
  queueFrom(S.lists.dips, F.db.dipLimit or 25)
  -- Start every key-info load now, so each is cached by the time its search goes out.
  for _, c in ipairs(S.detailQueue) do
    KeyReady(c)
  end
  Refresh()
  S.PumpDetail()
end

-- Check one candidate's listings on demand (shift-click, or Check more).
function S.DetailOne(c)
  if not F.ahOpen then
    F.Print("Open the auction house first.")
    return
  end
  if S.state == "browse" then
    F.Print("Wait for the scan to finish.")
    return
  end
  table.insert(S.detailQueue, 1, c)
  KeyReady(c)
  if S.state ~= "detail" then
    S.manualDetail = true
    S.state = "detail"
  end
  S.PumpDetail()
end

-- The detail queue is empty: carry on with the next pass, finish, or (after a
-- manual check) go back to showing results.
function S.AfterDetail()
  if S.manualDetail then
    S.manualDetail = false
    S.state = "done"
    SetStatus(S.doneStatus or "Done")
    Refresh()
    return
  end
  S.timing.detailSeconds = (S.timing.detailSeconds or 0) + (GetTime() - (S.timing.detailStart or GetTime()))
  if (S.phaseIndex or 0) < #(S.phases or {}) then
    S.NextPhase()
  else
    S.Finish()
  end
end

local function DetailStatus()
  local waiting = #S.detailInFlight
  local left = #S.detailQueue + waiting
  if left == 0 then
    return
  end
  if waiting > 0 then
    SetStatus(string.format("Checking listings... %d left (%d asked, waiting on the server)", left, waiting))
  else
    SetStatus(string.format("Checking listings... %d left", left))
  end
end

-- Send one candidate's listing search. `tries` counts earlier attempts.
function S.SendDetail(c, tries)
  local entry = { c = c, tries = (tries or 0) + 1 }
  table.insert(S.detailInFlight, entry)
  if #S.detailInFlight > (S.timing.maxInFlight or 0) then
    S.timing.maxInFlight = #S.detailInFlight
  end
  S.detailCurrent = c
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  S.Send(function()
    entry.sentAt = GetTime()
    C_AuctionHouse.SendSearchQuery(c.itemKey, sorts, false)
  end)
end

-- Keep up to DETAIL_IN_FLIGHT searches out at once. The server paces the
-- requests, not the answers, so the next search goes out the moment the
-- server will take it instead of after the last answer has been read.
function S.PumpDetail()
  if S.state ~= "detail" then
    return
  end
  while S.detailQueue[1] and #S.detailInFlight < S.DETAIL_IN_FLIGHT do
    local c = S.detailQueue[1]
    if KeyReady(c) then
      table.remove(S.detailQueue, 1)
      c.keyWaitSince = nil
      S.SendDetail(c)
    else
      c.keyWaitSince = c.keyWaitSince or GetTime()
      if GetTime() - c.keyWaitSince < S.KEY_WAIT then
        break -- its key info is on the way; DetailTick comes back here
      end
      table.remove(S.detailQueue, 1)
      c.keyWaitSince = nil
      S.timing.keyWaits = (S.timing.keyWaits or 0) + 1
      S.SendDetail(c)
    end
  end
  if #S.detailQueue == 0 and #S.detailInFlight == 0 then
    S.AfterDetail()
    return
  end
  DetailStatus()
end

-- Every frame while checking: ask again for searches the server has not
-- answered (then give up), and send what was waiting on key info once it is
-- there.
function S.DetailTick()
  if S.state ~= "detail" then
    return
  end
  local now = GetTime()
  local changed = false
  for i = #S.detailInFlight, 1, -1 do
    local e = S.detailInFlight[i]
    if e.sentAt and now - e.sentAt > S.DETAIL_TIMEOUT then
      table.remove(S.detailInFlight, i)
      changed = true
      if e.tries < 2 then
        S.timing.retries = (S.timing.retries or 0) + 1
        F.Debug("no listings came back for item %d; asking again", e.c.itemID)
        S.SendDetail(e.c, e.tries)
      else
        S.timing.unanswered = (S.timing.unanswered or 0) + 1
        F.Debug("no listings came back for item %d", e.c.itemID)
        e.c.detailFailed = true
      end
    end
  end
  local head = S.detailQueue[1]
  if not changed and head and #S.detailInFlight < S.DETAIL_IN_FLIGHT then
    changed = KeyReady(head) or (now - (head.keyWaitSince or now)) >= S.KEY_WAIT
  end
  if changed then
    S.PumpDetail()
  end
end

-- Turn a list of {price, quantity} (any order) into the price ladder: tiers
-- sorted by price with the same price merged, plus the total units and the
-- volume-weighted median (the price at which half the units are at or below).
function S.Ladder(listings)
  local byPrice = {}
  for _, l in ipairs(listings) do
    local p = math.floor(l.price + 0.5)
    byPrice[p] = (byPrice[p] or 0) + l.quantity
  end
  local ladder = {}
  for price, quantity in pairs(byPrice) do
    table.insert(ladder, { price = price, quantity = quantity })
  end
  table.sort(ladder, function(a, b) return a.price < b.price end)
  local total = 0
  for _, t in ipairs(ladder) do
    total = total + t.quantity
  end
  local median, cumulative = nil, 0
  for _, t in ipairs(ladder) do
    cumulative = cumulative + t.quantity
    t.cumulative = cumulative
    if not median and cumulative * 2 >= total then
      median = t.price
    end
  end
  return ladder, total, median
end

-- Both readers return: units below the reference price, the profit on all of
-- them, every tier below the reference (cheapest first), whether more cheap
-- listings may exist beyond the first page of results, and every listing on
-- the page (for the price ladder).
local function ReadCommodityListings(c)
  local below, profit, tiers, lastBelow, all = 0, 0, {}, false, {}
  local n = C_AuctionHouse.GetCommoditySearchResultsQuantity(c.itemID)
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(c.itemID, i)
    if r and r.unitPrice and r.quantity then
      table.insert(all, { price = r.unitPrice, quantity = r.quantity })
      if r.unitPrice < c.ref then
        below = below + r.quantity
        profit = profit + (c.ref - r.unitPrice) * r.quantity
        lastBelow = true
        table.insert(tiers, { price = r.unitPrice, quantity = r.quantity })
      else
        lastBelow = false
      end
    end
  end
  local more = lastBelow and not C_AuctionHouse.HasFullCommoditySearchResults(c.itemID)
  return below, profit, tiers, more, all
end

local function ReadItemListings(c)
  local below, profit, tiers, lastBelow, all = 0, 0, {}, false, {}
  local n = C_AuctionHouse.GetItemSearchResultsQuantity(c.itemKey)
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(c.itemKey, i)
    if r and r.buyoutAmount and r.buyoutAmount > 0 then
      local quantity = r.quantity or 1
      local unit = r.buyoutAmount / quantity
      table.insert(all, { price = unit, quantity = quantity })
      if unit < c.ref then
        below = below + quantity
        profit = profit + (c.ref - unit) * quantity
        lastBelow = true
        table.insert(tiers, { price = unit, quantity = quantity })
      else
        lastBelow = false
      end
    end
  end
  table.sort(tiers, function(a, b) return a.price < b.price end)
  local more = lastBelow and not C_AuctionHouse.HasFullItemSearchResults(c.itemKey)
  return below, profit, tiers, more, all
end

-- The in-flight entry an answer belongs to, or nil (the answer may be to a
-- search the player made themselves).
local function TakeInFlight(isCommodity, idOrKey)
  local itemID = isCommodity and idOrKey or (type(idOrKey) == "table" and idOrKey.itemID)
  if not itemID then
    return nil
  end
  for i, e in ipairs(S.detailInFlight) do
    if e.c.itemID == itemID then
      table.remove(S.detailInFlight, i)
      return e
    end
  end
  return nil
end

-- A search sometimes comes back empty for an item that has listings: the
-- client holds no rows for it and says more are still to come.
local function BogusAnswer(isCommodity, c)
  local key = c.itemKey
  if isCommodity and C_AuctionHouse.MakeItemKey then
    key = C_AuctionHouse.MakeItemKey(c.itemID)
  end
  if C_AuctionHouse.HasSearchResults and not C_AuctionHouse.HasSearchResults(key) then
    return true
  end
  local full, n
  if isCommodity then
    full = C_AuctionHouse.HasFullCommoditySearchResults(c.itemID)
    n = C_AuctionHouse.GetCommoditySearchResultsQuantity(c.itemID)
  else
    full = C_AuctionHouse.HasFullItemSearchResults(c.itemKey)
    n = C_AuctionHouse.GetItemSearchResultsQuantity(c.itemKey)
  end
  return (not full) and (n or 0) == 0
end

function S.OnSearchResults(isCommodity, idOrKey)
  if S.state ~= "detail" then
    return
  end
  local e = TakeInFlight(isCommodity, idOrKey)
  if not e then
    return
  end
  local c = e.c
  if e.sentAt then
    local waited = GetTime() - e.sentAt
    S.timing.resultWait = (S.timing.resultWait or 0) + waited
    if waited > (S.timing.resultMax or 0) then
      S.timing.resultMax = waited
    end
  end
  if BogusAnswer(isCommodity, c) then
    if e.tries < 2 then
      S.timing.retries = (S.timing.retries or 0) + 1
      F.Debug("empty answer for item %d; asking again", c.itemID)
      S.SendDetail(c, e.tries)
    else
      S.timing.unanswered = (S.timing.unanswered or 0) + 1
      c.detailFailed = true
    end
    S.PumpDetail()
    return
  end
  S.timing.checks = (S.timing.checks or 0) + 1

  local below, profit, tiers, more, all
  if isCommodity then
    below, profit, tiers, more, all = ReadCommodityListings(c)
  else
    below, profit, tiers, more, all = ReadItemListings(c)
  end
  c.isCommodity = isCommodity
  c.belowUnits = below
  c.belowProfit = profit
  c.tiersAll = tiers
  c.tiers = {}
  for i = 1, math.min(5, #tiers) do
    c.tiers[i] = tiers[i]
  end
  c.more = more
  -- A sniped piece of gear whose check finds a real buyout under vendor price.
  if c.new and c.mode == "floor" and below > 0 and not c.alerted then
    c.alerted = true
    S.Alert(c)
  end
  -- The price ladder: where the volume sits on this page of results.
  c.ladder, c.ladderUnits, c.vwMedian = S.Ladder(all)
  if c.vwMedian then
    F.History.RecordMedian(c.itemID, c.vwMedian)
    if c.mode == "dips" and c.normal then
      -- Most volume still at or near normal: the cheap units are outliers,
      -- the flip is sound. Most volume at the dip price: the market moved,
      -- so the normal is re-anchored to today's median and the dip re-tested.
      if (c.ladderUnits or 0) > (F.db.dipRecipeMax or 5) then
        c.marketIntact = c.vwMedian >= c.normal * 0.9
      else
        c.marketIntact = nil -- too few units on the page to judge the market
      end
      S.Reanchor(c)
    end
  end
  -- Recipes: when more than a few copies sit at or near the dip price, the
  -- market has adjusted and this is the new price, not a dip.
  if c.mode == "dips" then
    local classID = select(6, C_Item.GetItemInfoInstant(c.itemID))
    if classID == CLASS_RECIPE then
      local near = 0
      for _, tier in ipairs(c.ladder or {}) do
        if tier.price <= c.minPrice * 1.1 then
          near = near + tier.quantity
        end
      end
      c.nearUnits = near
      if near > (F.db.dipRecipeMax or 5) then
        c.adjusted = true
        c.marketIntact = false
      end
    end
  end
  c.detailed = true
  c.detailFailed = nil
  Refresh()
  S.PumpDetail()
end

------------------------------------------------------------------------------
-- Snipe: watch the newest listings
------------------------------------------------------------------------------

-- A full scan takes minutes because the server paces every page. Sniping
-- asks for one page only, sorted so the most recently posted auctions come
-- first, every few seconds. New listings below vendor price or well below
-- normal show up within seconds of being posted and are called out in chat.
-- Buying is still your click.
S.snipe = { on = false, awaiting = false, cycles = 0, hits = 0, alerted = {} }

function S.SnipeStart()
  if not F.ahOpen then
    F.Print("Open the auction house first.")
    return
  end
  if S.snipe.on then
    return
  end
  S.snipe.on = true
  S.snipe.cycles = 0
  S.snipe.hits = 0
  S.snipe.alerted = {}
  F.Print("Sniping: watching the newest listings every %d seconds. /floor snipe off stops it.", F.db.snipeEvery or 3)
  S.SnipeCycle()
end

function S.SnipeStop(quiet)
  if not S.snipe.on then
    return
  end
  S.snipe.on = false
  S.snipe.awaiting = false
  CancelTimer("snipeTimer")
  if not quiet then
    F.Print("Sniping stopped after %d cycles, %d hits.", S.snipe.cycles, S.snipe.hits)
    SetStatus(S.doneStatus or "Sniping stopped.")
  end
  Refresh()
end

function S.SnipeCycle()
  if not S.snipe.on or not F.ahOpen then
    return
  end
  if S.Busy() then
    -- a scan is running; let it finish, then resume
    S.snipeTimer = C_Timer.NewTimer(5, function() S.snipeTimer = nil; S.SnipeCycle() end)
    return
  end
  S.snipe.awaiting = true
  S.snipe.cycles = S.snipe.cycles + 1
  SetStatus(string.format("Sniping the newest listings... cycle %d, %d hits so far", S.snipe.cycles, S.snipe.hits))
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.TimeRemaining, reverseSort = true } }
  S.Send(function()
    C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = sorts, filters = {}, itemClassFilters = {} })
  end)
  -- if no answer comes, try again on the next cycle
  CancelTimer("snipeTimer")
  S.snipeTimer = C_Timer.NewTimer(math.max(2, F.db.snipeEvery or 3) + 5, function()
    S.snipeTimer = nil
    S.snipe.awaiting = false
    S.SnipeCycle()
  end)
end

function S.Alert(c)
  local kind = c.mode == "dips" and "below normal" or "below vendor"
  local _, _, profit = S.Affordable(c)
  F.Print("|cff66ff66New listing %s:|r %s at %s (%s, %s profit on what you can afford)",
    kind, F.ItemLink(c.itemID), F.Money(c.minPrice), c.mode == "dips" and ("normal " .. F.Money(c.normal)) or ("vendor " .. F.Money(c.vendor)), F.Money(profit))
  if F.db.snipeSound ~= false then
    pcall(function()
      if SOUNDKIT and SOUNDKIT.RAID_WARNING then
        PlaySound(SOUNDKIT.RAID_WARNING)
      elseif PlaySound then
        PlaySound(8959)
      end
    end)
  end
end

function S.OnSnipeResults()
  S.snipe.awaiting = false
  CancelTimer("snipeTimer")
  local results = C_AuctionHouse.GetBrowseResults() or {}
  local beforeFloor, beforeDips = #S.lists.floor, #S.lists.dips
  for _, result in ipairs(results) do
    S.Consider(result, true)
  end
  -- Anything new is a snipe hit: verify gear (bid or buyout?) and call it out.
  local function announce(list, from)
    for i = from + 1, #list do
      local c = list[i]
      c.new = true
      c.seenAt = GetTime()
      S.snipe.hits = S.snipe.hits + 1
      if not S.snipe.alerted[c.key] and not F.db.ignore[c.itemID] and c.unitProfit >= S.MinUnit(c.mode) then
        S.snipe.alerted[c.key] = true
        if c.mode == "floor" and S.IsCommodity(c.itemKey) ~= true then
          S.DetailOne(c) -- the alert fires once the check finds a real buyout
        else
          c.alerted = true
          S.Alert(c)
        end
      end
    end
  end
  announce(S.lists.floor, beforeFloor)
  announce(S.lists.dips, beforeDips)
  Refresh()
  if S.snipe.on then
    S.snipeTimer = C_Timer.NewTimer(math.max(2, F.db.snipeEvery or 3), function()
      S.snipeTimer = nil
      S.SnipeCycle()
    end)
  end
end

------------------------------------------------------------------------------
-- Bid snipes: the full dump of every auction, read for bids below resale
------------------------------------------------------------------------------

-- The dump (ReplicateItems) lists each auction with its minimum bid, current
-- bid, increment and buyout, which the browse results never show. It is only
-- allowed about every 15 minutes, so it gets its own button.
function S.StartBids(auto)
  if not F.ahOpen then
    if not auto then
      F.Print("Open the auction house first.")
    end
    return
  end
  if S.Busy() then
    if not auto then
      F.Print("A scan is already running.")
    end
    return
  end
  local last = F.db.lastReplicate or 0
  local wait = S.REPLICATE_WAIT - (time() - last)
  if wait > 0 then
    if not auto then
      F.Print("The full auction dump is allowed about every 15 minutes. Try again in %d min %d s.", math.floor(wait / 60), wait % 60)
    end
    return
  end
  S.scanID = S.scanID + 1
  S.state = "bids"
  S.lists.bids = {}
  S.results.bids = {}
  S.auctionCount = 0
  F.db.lastReplicate = time()
  SetStatus("Asking for the full auction list... (this can take a while)")
  Refresh()
  C_AuctionHouse.ReplicateItems()
  CancelTimer("bidsTimer")
  S.bidsTimer = C_Timer.NewTimer(30, function()
    S.bidsTimer = nil
    if S.state == "bids" then
      S.state = "idle"
      F.db.lastReplicate = 0 -- let them try again
      SetStatus("No auction list came back. Try again, or the full dump may not be available here.")
      F.Print("The auction house didn't answer the full-list request within 30 seconds.")
      Refresh()
    end
  end)
end

-- The price per unit a bid is measured against: the normal price after the
-- cut when we have enough memory, otherwise the vendor price.
local function BidReference(itemID)
  local normal, days = F.History.Normal(itemID, F.db.dipWindow or 7, F.db.dipDays or 3)
  if normal and days >= (F.db.dipDays or 3) and normal >= (F.db.dipMinNormal or 100) then
    return math.floor(normal * S.CUT), "normal", normal, days
  end
  local vendor = F.VendorPrice(itemID)
  if vendor and vendor > 0 then
    return vendor, "vendor", vendor, 0
  end
  return nil
end

function S.ConsiderAuction(index)
  local info = { C_AuctionHouse.GetReplicateItemInfo(index) }
  local count, minBid, minIncrement, buyout, bidAmount, highBidder, owner, itemID =
    info[3], info[8], info[9], info[10], info[11], info[12], info[14], info[17]
  if not itemID or not count or count < 1 or not minBid or minBid <= 0 then
    return
  end
  S.auctionCount = S.auctionCount + 1
  if highBidder == true then
    return -- our own bid
  end
  if not C_Item.DoesItemExistByID(itemID) then
    return
  end
  local timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft(index)
  if timeLeft and timeLeft > (F.db.bidMaxTimeLeft or 1) then
    return -- not ending soon enough to snipe
  end
  local itemKey = C_AuctionHouse.MakeItemKey(itemID)
  if S.IsCommodity(itemKey) == true then
    return -- commodities have no bids
  end
  local nextBid = (bidAmount and bidAmount > 0) and (bidAmount + (minIncrement or 0)) or minBid
  if buyout and buyout > 0 and nextBid > buyout then
    nextBid = buyout
  end
  local ref, refKind, refBase, days = BidReference(itemID)
  if not ref then
    return
  end
  local perUnit = nextBid / count
  if perUnit >= ref then
    return
  end
  local key = string.format("%d:%d", itemID, index)
  if S.results.bids[key] then
    return
  end
  local c = {
    mode = "bids",
    key = key,
    itemKey = itemKey,
    itemID = itemID,
    raw = { itemKey = itemKey, totalQuantity = count, minPrice = (buyout and buyout > 0) and math.floor(buyout / count) or math.floor(perUnit), containsOwnerItem = false },
    minPrice = perUnit,
    total = count,
    ref = ref,
    refKind = refKind,
    normal = refKind == "normal" and refBase or nil,
    vendor = refKind == "vendor" and refBase or nil,
    days = days,
    unitProfit = ref - perUnit,
    bid = { minBid = minBid, bidAmount = bidAmount or 0, nextBid = nextBid, increment = minIncrement or 0,
            buyout = buyout or 0, timeLeft = timeLeft, owner = owner, link = C_AuctionHouse.GetReplicateItemLink(index) },
    -- a bid auction is one lot: already "checked"
    detailed = true,
    belowUnits = count,
    belowProfit = ref * count - nextBid,
    tiersAll = { { price = perUnit, quantity = count } },
    tiers = { { price = perUnit, quantity = count } },
    more = false,
    isCommodity = false,
  }
  S.results.bids[key] = c
  table.insert(S.lists.bids, c)
end

function S.ProcessReplicate()
  local scanID = S.scanID
  local n = C_AuctionHouse.GetNumReplicateItems()
  local i = 0
  local function step()
    if scanID ~= S.scanID or S.state ~= "bids" then
      return
    end
    local stop = math.min(i + 299, n - 1)
    for j = i, stop do
      S.ConsiderAuction(j)
    end
    i = stop + 1
    if i < n then
      SetStatus(string.format("Reading auctions... %d of %d, %d bids below resale so far", i, n, #S.lists.bids))
      C_Timer.After(0, step)
    else
      S.FinishBids(n)
    end
  end
  step()
end

function S.FinishBids(n)
  CancelTimer("bidsTimer")
  S.state = "done"
  table.sort(S.lists.bids, S.Comparator("bids"))
  local window = S.TIME_LEFT[F.db.bidMaxTimeLeft or 1] or "?"
  S.doneStatus = string.format("Bids: %d auctions read, %d ending within %s with a next bid below resale", n or S.auctionCount, #S.lists.bids, window)
  SetStatus(S.doneStatus)
  F.Print("Bid scan done: %d auctions read, %d ending within %s have a next bid below the resale price.", n or S.auctionCount, #S.lists.bids, window)
  Refresh()
  S.ScheduleLoop()
end

------------------------------------------------------------------------------
-- Finish
------------------------------------------------------------------------------

-- Where the last scan's seconds went: the server's pace against Floor's own.
function S.TimingText()
  local t = S.timing
  if not t or (t.requests or 0) == 0 then
    return "No scan timed yet. Run a scan, then /floor timing."
  end
  local total = t.totalSeconds or (GetTime() - (t.startedAt or GetTime()))
  local readyAvg = t.requests > 0 and (t.readyWait / t.requests) or 0
  local parts = {}
  table.insert(parts, string.format("Last scan: %.0fs in all, %d requests. Browse %.0fs over %d pages; the server took %.1fs on average to allow the next request (slowest %.1fs).",
    total, t.requests, t.browseSeconds or 0, t.pages or 0, readyAvg, t.readyMax or 0))
  if (t.checks or 0) > 0 or (t.unanswered or 0) > 0 then
    local resultAvg = (t.checks or 0) > 0 and (t.resultWait / t.checks) or 0
    table.insert(parts, string.format("Listing checks %.0fs for %d items, up to %d out at once; answers took %.1fs on average (slowest %.1fs); %d asked again, %d never answered, %d sent before their item data arrived.",
      t.detailSeconds or 0, t.checks or 0, t.maxInFlight or 0, resultAvg, t.resultMax or 0, t.retries or 0, t.unanswered or 0, t.keyWaits or 0))
  end
  if (t.stalls or 0) > 0 or (t.dropped or 0) > 0 then
    table.insert(parts, string.format("%d requests waited out a missing ready signal; %d were dropped by the throttle and sent again.", t.stalls or 0, t.dropped or 0))
  end
  table.insert(parts, "The server's pace sets the browse time: Floor sends each request the moment the server will take it.")
  return table.concat(parts, " ")
end

-- "-2.1%/day across 1,234 items (deflating)" with a prefix, or "" when unknown.
function S.DriftText(prefix)
  local drift, n = S.drift, S.driftItems
  if drift == nil and F.db.last then
    drift, n = F.db.last.drift, F.db.last.driftItems
  end
  if drift == nil or not n or n == 0 then
    return ""
  end
  local word = "steady"
  if drift < -0.01 then
    word = "deflating"
  elseif drift > 0.01 then
    word = "inflating"
  end
  return string.format("%s%+.1f%%/day across %d items (%s)", prefix or "", drift * 100, n, word)
end

local function Compact(list)
  local saved = {}
  for i, c in ipairs(list) do
    if i > 100 then
      break
    end
    table.insert(saved, {
      itemID = c.itemID,
      minPrice = c.minPrice,
      ref = c.ref,
      vendor = c.vendor,
      normal = c.normal,
      days = c.days,
      total = c.total,
      belowUnits = c.belowUnits,
      belowProfit = c.belowProfit,
    })
  end
  return saved
end

function S.Finish()
  S.state = "done"
  CancelTimer("detailTimer")
  table.sort(S.lists.floor, S.Comparator("floor"))
  table.sort(S.lists.dips, S.Comparator("dips"))

  if F.Crafts and not S.quick then
    F.Crafts.Evaluate()
  end
  local drift, driftItems = F.History.MarketDrift(F.db.dipWindow or 7)
  F.db.last = {
    time = time(),
    items = S.browseCount,
    hits = Compact(S.lists.floor),
    dips = Compact(S.lists.dips),
    drift = drift,
    driftItems = driftItems,
  }
  S.drift, S.driftItems = drift, driftItems
  S.timing.totalSeconds = GetTime() - (S.timing.startedAt or GetTime())
  F.Debug("%s", S.TimingText())

  S.doneStatus = string.format("Done%s: %d items seen, %d below vendor price, %d below normal price, %d paying crafts%s",
    S.quick and " (quick, gear only)" or "", S.browseCount, #S.lists.floor, #S.lists.dips, #S.lists.crafts, S.DriftText(" · market "))
  SetStatus(S.doneStatus)
  F.Print("Scan done%s: %d items seen, %d below vendor price, %d below their normal price, %d crafts that pay. Memory covers %d items.%s",
    S.quick and " (quick, gear only)" or "", S.browseCount, #S.lists.floor, #S.lists.dips, #S.lists.crafts, F.History.Count(), S.DriftText(" Market drift: "))
  Refresh()
  S.AfterScan()
end

-- One scan fills every view: when the full auction dump is allowed again,
-- the bid snipes run too; then the rescan loop is scheduled if it is on.
function S.AfterScan()
  if F.db.bidsOnScan ~= false and F.ahOpen and (time() - (F.db.lastReplicate or 0)) >= S.REPLICATE_WAIT then
    S.StartBids(true)
    return
  end
  S.ScheduleLoop()
end

-- Rescan every F.db.loop seconds while the auction house stays open.
function S.ScheduleLoop()
  CancelTimer("loopTimer")
  local every = F.db.loop or 0
  if every > 0 and F.ahOpen then
    every = math.max(30, every)
    S.loopTimer = C_Timer.NewTimer(every, function()
      S.loopTimer = nil
      if F.ahOpen and not S.Busy() then
        S.Start({ quick = S.quick })
      end
    end)
    if S.doneStatus then
      SetStatus(S.doneStatus .. string.format(" · rescan in %ds", every))
    end
  end
end

------------------------------------------------------------------------------
-- Open an item in Blizzard's buy view. Buying is your click from there.
------------------------------------------------------------------------------

function S.Open(c)
  if not F.ahOpen or not AuctionHouseFrame then
    F.Print("Open the auction house first.")
    return
  end
  S.Pause(1.5) -- the click sends its own search; keep ours out of its way
  local ok, err = pcall(function()
    AuctionHouseFrame:SelectBrowseResult(c.raw)
  end)
  if ok and c.isCommodity then
    -- Save a step: pre-fill the quantity with what is worth buying within the
    -- budget. The Buyout click and its confirmation stay yours.
    local units = S.Affordable(c)
    if units and units > 0 then
      C_Timer.After(0.3, function()
        pcall(function()
          local display = AuctionHouseFrame.CommoditiesBuyFrame and AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay
          if display and display.SetQuantity then
            display:SetQuantity(units)
          end
        end)
      end)
    end
  end
  if not ok then
    F.Print("Couldn't open %s here (%s). Search for it in the auction house.", F.ItemLink(c.itemID), tostring(err))
  elseif c.mode == "bids" then
    F.Print("Opened %s: find the auction with a %s bid (seller %s) and place your bid there.",
      F.ItemLink(c.itemID), F.Money(c.bid.bidAmount > 0 and c.bid.bidAmount or c.bid.minBid), tostring(c.bid.owner or "?"))
  end
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
events:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
events:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
events:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
events:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
events:SetScript("OnEvent", function(_, event, ...)
  if event == "REPLICATE_ITEM_LIST_UPDATE" then
    if S.state == "bids" then
      S.ProcessReplicate()
    end
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    if S.snipe.awaiting and S.state ~= "browse" then
      S.OnSnipeResults()
      return
    end
    if S.state ~= "browse" or not S.awaitingBrowse then
      return
    end
    S.awaitingBrowse = false
    S.ProcessBatch(C_AuctionHouse.GetBrowseResults(), function()
      S.NextPage()
    end)
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    if S.state ~= "browse" then
      return
    end
    local added = ...
    S.ProcessBatch(added or {}, function()
      S.NextPage()
    end)
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    local itemID = ...
    S.OnSearchResults(true, itemID)
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    local itemKey = ...
    S.OnSearchResults(false, itemKey)
  end
end)
