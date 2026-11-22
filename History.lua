-- Floor: price memory.
--
-- Every scan records, per item, the day's lowest unit price and the quantity
-- listed. From those daily lows we take an item's "normal" price: the median
-- over the last few days, today excluded. A median ignores a single bait
-- listing on one day. Auctionator keeps the same kind of daily low, so when
-- Floor's own memory is short we read Auctionator's to fill the gap.
--
-- Storage: FloorDB.history[itemID] = "day:min:qty[:vwm];..." oldest first,
-- where day is the UTC day number and vwm, when present, is the
-- volume-weighted median of the listings seen that day (only items whose
-- listings were checked have it). Kept for 30 days.

local F = Floor
local H = {}
F.History = H

local DAY = 86400
H.KEEP_DAYS = 30

function H.Today()
  return math.floor(time() / DAY)
end

local function Parse(str)
  local out = {}
  if type(str) ~= "string" then
    return out
  end
  for part in str:gmatch("[^;]+") do
    local day, min, qty, vwm = part:match("^(%d+):(%d+):(%d+):?(%d*)$")
    if day then
      table.insert(out, { day = tonumber(day), min = tonumber(min), qty = tonumber(qty), vwm = tonumber(vwm) })
    end
  end
  return out
end

local function Serialize(entries)
  local parts = {}
  for _, e in ipairs(entries) do
    if e.vwm then
      table.insert(parts, string.format("%d:%d:%d:%d", e.day, e.min, e.qty, e.vwm))
    else
      table.insert(parts, string.format("%d:%d:%d", e.day, e.min, e.qty))
    end
  end
  return table.concat(parts, ";")
end

-- Record today's lowest price and listed quantity for an item. Several scans
-- on one day keep the lowest price seen and the latest quantity.
function H.Record(itemID, minPrice, qty)
  if not F.db or not F.db.history or not minPrice or minPrice <= 0 then
    return
  end
  local today = H.Today()
  local cutoff = today - H.KEEP_DAYS
  local kept, found = {}, false
  for _, e in ipairs(Parse(F.db.history[itemID])) do
    if e.day >= cutoff then
      if e.day == today then
        found = true
        if minPrice < e.min then
          e.min = minPrice
        end
        e.qty = qty or e.qty
      end
      table.insert(kept, e)
    end
  end
  if not found then
    table.insert(kept, { day = today, min = math.floor(minPrice), qty = math.floor(qty or 0) })
  end
  F.db.history[itemID] = Serialize(kept)
end

-- Remember today's volume-weighted median for an item whose listings were
-- checked. Several checks on one day keep the latest.
function H.RecordMedian(itemID, vwm)
  if not F.db or not F.db.history or not vwm or vwm <= 0 then
    return
  end
  local today = H.Today()
  local entries = Parse(F.db.history[itemID])
  local found = false
  for _, e in ipairs(entries) do
    if e.day == today then
      e.vwm = math.floor(vwm)
      found = true
    end
  end
  if not found then
    table.insert(entries, { day = today, min = math.floor(vwm), qty = 0, vwm = math.floor(vwm) })
  end
  F.db.history[itemID] = Serialize(entries)
end

-- Floor's own entries for an item, oldest first.
function H.Entries(itemID)
  if not F.db or not F.db.history then
    return {}
  end
  return Parse(F.db.history[itemID])
end

-- Auctionator's daily lows for an item, converted to our day numbers.
function H.AuctionatorEntries(itemID)
  if not (Auctionator and Auctionator.Database and Auctionator.Database.GetPriceHistory) then
    return {}
  end
  local ok, rows = pcall(Auctionator.Database.GetPriceHistory, Auctionator.Database, tostring(itemID))
  if not ok or type(rows) ~= "table" then
    return {}
  end
  local day0 = Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
  if not day0 then
    return {}
  end
  local out = {}
  for _, r in ipairs(rows) do
    local raw = tonumber(r.rawDay)
    if raw and r.minSeen and r.minSeen > 0 then
      table.insert(out, {
        day = math.floor((raw * DAY + day0) / DAY),
        min = r.minSeen,
        qty = r.available or 0,
        source = "auctionator",
      })
    end
  end
  table.sort(out, function(a, b) return a.day < b.day end)
  return out
end

-- Own entries, filled in with Auctionator's on days we have nothing. Oldest first.
function H.Merged(itemID, useAuctionator)
  local byDay = {}
  if useAuctionator then
    for _, e in ipairs(H.AuctionatorEntries(itemID)) do
      byDay[e.day] = e
    end
  end
  for _, e in ipairs(H.Entries(itemID)) do
    byDay[e.day] = e
  end
  local out = {}
  for _, e in pairs(byDay) do
    table.insert(out, e)
  end
  table.sort(out, function(a, b) return a.day < b.day end)
  return out
end

local function Median(values)
  if #values == 0 then
    return nil
  end
  table.sort(values)
  local n = #values
  if n % 2 == 1 then
    return values[(n + 1) / 2]
  end
  return (values[n / 2] + values[n / 2 + 1]) / 2
end

-- The day's price level: the volume-weighted median when the listings were
-- checked that day, else the daily low.
local function Level(e)
  return e.vwm or e.min
end

-- Least-squares line through (daysAgo, log price). Returns the slope per day
-- (as a log change) and the value the line gives for today, or nil with
-- fewer than three points.
local function LogTrend(entries, today)
  local n = #entries
  if n < 3 then
    return nil
  end
  local sx, sy = 0, 0
  for _, e in ipairs(entries) do
    sx = sx + (e.day - today)
    sy = sy + math.log(math.max(1, Level(e)))
  end
  local mx, my = sx / n, sy / n
  local sxy, sxx = 0, 0
  for _, e in ipairs(entries) do
    local dx = (e.day - today) - mx
    sxy = sxy + dx * (math.log(math.max(1, Level(e))) - my)
    sxx = sxx + dx * dx
  end
  if sxx == 0 then
    return nil
  end
  local slope = sxy / sxx
  local intercept = my - slope * mx -- the line's value at daysAgo = 0, i.e. today
  return slope, math.exp(intercept)
end

-- The normal price, trend-aware. A flat median of recent lows goes stale in a
-- market that is still settling (prices fall as more players farm and the
-- same items pile up), so we fit a trend through the recent daily levels and
-- read it at today. Guards: the result never exceeds the flat median in a
-- falling market, never rises more than 50% above it, and never drops below
-- 70% of the last three days' level (a step down should not be extrapolated
-- into a cliff).
-- Returns normal, daysUsed, falling, entriesUsed, slopePerDay (fraction, e.g.
-- -0.05 = -5% a day), flatMedian, supplyChange (last quantity / first).
function H.Normal(itemID, window, minDays)
  window = window or 7
  minDays = minDays or 3
  local today = H.Today()
  local function collect(entries)
    local used = {}
    for _, e in ipairs(entries) do
      if e.day < today and e.day >= today - window and e.min > 0 then
        table.insert(used, e)
      end
    end
    return used
  end
  -- Own memory first; only read Auctionator's when ours is too short.
  local used = collect(H.Entries(itemID))
  if #used < minDays then
    used = collect(H.Merged(itemID, true))
  end
  if #used == 0 then
    return nil, 0, false, used, 0, nil, nil
  end

  local levels = {}
  for _, e in ipairs(used) do
    table.insert(levels, Level(e))
  end
  local flat = Median(levels)

  local normal, slope = flat, 0
  local logSlope, today0 = LogTrend(used, today)
  if logSlope then
    slope = math.exp(logSlope) - 1
    local recent = {}
    for i = math.max(1, #used - 2), #used do
      table.insert(recent, Level(used[i]))
    end
    local recentLevel = Median(recent) or flat
    local lower = recentLevel * 0.7
    local upper = (logSlope < 0) and flat or (flat * 1.5)
    normal = math.max(lower, math.min(upper, today0))
  end
  normal = math.floor(normal + 0.5)

  local falling = slope < -0.03
  local supplyChange
  local firstQty, lastQty = used[1].qty or 0, used[#used].qty or 0
  if firstQty > 0 then
    supplyChange = lastQty / firstQty
  end
  return normal, #used, falling, used, slope, flat, supplyChange
end

-- How fast the whole market is moving: the median per-item daily slope over
-- the window, across items with at least three days of memory. Returns the
-- drift as a fraction per day (e.g. -0.02 = prices fall 2% a day) and the
-- number of items it rests on.
function H.MarketDrift(window)
  window = window or 7
  if not F.db or not F.db.history then
    return nil, 0
  end
  local today = H.Today()
  local slopes = {}
  for _, str in pairs(F.db.history) do
    local used = {}
    for _, e in ipairs(Parse(str)) do
      if e.day < today and e.day >= today - window and e.min > 0 then
        table.insert(used, e)
      end
    end
    local logSlope = LogTrend(used, today)
    if logSlope then
      table.insert(slopes, logSlope)
    end
  end
  local m = Median(slopes)
  if not m then
    return nil, 0
  end
  return math.exp(m) - 1, #slopes
end

-- Drop entries older than the keep window from every item (run occasionally).
function H.Prune()
  if not F.db or not F.db.history then
    return 0
  end
  local cutoff = H.Today() - H.KEEP_DAYS
  local removed = 0
  for itemID, str in pairs(F.db.history) do
    local kept = {}
    for _, e in ipairs(Parse(str)) do
      if e.day >= cutoff then
        table.insert(kept, e)
      end
    end
    if #kept == 0 then
      F.db.history[itemID] = nil
      removed = removed + 1
    else
      F.db.history[itemID] = Serialize(kept)
    end
  end
  return removed
end

function H.Count()
  local n = 0
  if F.db and F.db.history then
    for _ in pairs(F.db.history) do
      n = n + 1
    end
  end
  return n
end
