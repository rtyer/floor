-- Floor: the results window and the button on the auction house.
--
-- The window has two modes, picked with the buttons beside the title:
--   Vendor floor: auctions listed below what a vendor pays.
--   Price dips:   auctions listed well below the item's normal price.

local F = Floor
local UI = {}
F.UI = UI

local ROWS = 14
local ROW_HEIGHT = 22
local HEADER_Y = -82
local FIRST_ROW_Y = -100
local WIDTH, HEIGHT = 920, 142 + ROWS * ROW_HEIGHT

-- Column left edges and widths.
local COLS = {
  icon   = { x = 10,  w = 20 },
  name   = { x = 34,  w = 190 },
  lowest = { x = 228, w = 84 },
  vendor = { x = 316, w = 84 },
  unit   = { x = 404, w = 74 },
  ratio  = { x = 482, w = 60 },
  below  = { x = 546, w = 74 },
  profit = { x = 624, w = 88 },
  cost   = { x = 716, w = 84 },
  open   = { x = 804, w = 48 },
  ignore = { x = 856, w = 48 },
}

local frame
local rows = {}
local headers = {}
local offset = 0
local refreshQueued = false

------------------------------------------------------------------------------
-- Building the window
------------------------------------------------------------------------------

local function Label(parent, text, x, y, width, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  fs:SetWidth(width)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  fs:SetText(text)
  return fs
end

local function SavePosition()
  local point, _, relPoint, x, y = frame:GetPoint(1)
  F.db.pos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestorePosition()
  frame:ClearAllPoints()
  local pos = F.db.pos
  if pos and pos.point then
    frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
  elseif AuctionHouseFrame then
    frame:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 6, 0)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

local function DaysAgo(day)
  local n = F.History.Today() - day
  if n <= 0 then
    return "today"
  elseif n == 1 then
    return "yesterday"
  end
  return n .. " days ago"
end

local function RowTooltip(row)
  local c = row.candidate
  if not c then
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(c.itemID)
  GameTooltip:AddLine(" ")
  if c.mode == "crafts" and c.craft then
    local k = c.craft
    GameTooltip:AddLine(string.format("%s  (%s, %s)", k.name or "craft", k.prof or "?", k.source or ""), 1, 0.82, 0)
    for _, part in ipairs(k.parts or {}) do
      local name = select(1, F.ItemDisplay({ itemID = part.id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })) or ("item " .. part.id)
      GameTooltip:AddDoubleLine(string.format("%d x %s  (%d listed)", part.n, name, part.listed or 0), F.Money(part.price * part.n), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Cost per craft", F.Money(c.minPrice), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine(string.format("Makes %d, lowest listed at", k.qty or 1), F.Money(k.productPrice), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Sold on the auction house (after 5%)", F.Money(math.floor(k.productPrice * (k.qty or 1) * 0.95)) .. "  (" .. F.Money(k.auctionProfit or 0) .. " profit)", 1, 0.82, 0, 1, 1, 1)
    if k.vendor and k.vendor > 0 then
      GameTooltip:AddDoubleLine("Sold to a vendor", F.Money(k.vendor * (k.qty or 1)) .. "  (" .. F.Money(k.vendorProfit or 0) .. " profit)", 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Better route", k.route == "vendor" and "vendor the product" or "auction the product", 1, 0.82, 0, 0.5, 1, 0.5)
    GameTooltip:AddDoubleLine("Crafts today's listings could feed", tostring(c.belowUnits or 0), 1, 0.82, 0, 1, 1, 1)
    local budget = F.Scan.Budget(c.mode)
    if budget then
      local units, cost, profit = F.Scan.Affordable(c)
      GameTooltip:AddDoubleLine("Within your max spend of " .. F.Money(budget), string.format("%d crafts for %s, profit %s", units, F.Money(cost), F.Money(profit)), 0.5, 0.8, 1, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Costs use each reagent's lowest listing; buying many climbs the price ladder, so treat the total as a ceiling. Open a profession window once so Floor learns its recipes.", 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to open the product in the auction house.", 0.5, 0.8, 1)
    GameTooltip:Show()
    return
  end
  if c.mode == "bids" and c.bid then
    local b = c.bid
    GameTooltip:AddDoubleLine("Current bid", b.bidAmount > 0 and F.Money(b.bidAmount) or "no bids yet (min " .. F.Money(b.minBid) .. ")", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Next bid", F.Money(b.nextBid) .. (c.total > 1 and string.format(" for %d", c.total) or ""), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Buyout", b.buyout > 0 and F.Money(b.buyout) or "none", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Time left", F.Scan.TIME_LEFT[b.timeLeft or 0] or "?", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Seller", tostring(b.owner or "?"), 1, 0.82, 0, 1, 1, 1)
    if c.refKind == "normal" then
      GameTooltip:AddDoubleLine(string.format("Normal price (median of %d days)", c.days or 0), F.Money(c.normal), 1, 0.82, 0, 1, 1, 1)
      GameTooltip:AddDoubleLine("Resale after the 5% cut", F.Money(c.ref), 1, 0.82, 0, 1, 1, 1)
    else
      GameTooltip:AddDoubleLine("Vendor pays (no price memory yet)", F.Money(c.ref), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Profit if the bid wins", F.Money(c.belowProfit or 0), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Someone can outbid you, and the buyout may vanish first. Bids tie up gold until the auction ends.", 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to open the item. Find this auction by its bid and place yours there.", 0.5, 0.8, 1, true)
    GameTooltip:Show()
    return
  end
  GameTooltip:AddDoubleLine("Lowest listing", F.Money(c.minPrice), 1, 0.82, 0, 1, 1, 1)
  if c.mode == "dips" then
    if c.reanchored then
      GameTooltip:AddDoubleLine("Normal price (today's market median)", F.Money(c.normal), 1, 0.6, 0.3, 1, 1, 1)
      GameTooltip:AddDoubleLine("  memory said", F.Money(c.normalBefore), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    else
      GameTooltip:AddDoubleLine(string.format("Normal price (trend over %d days)", c.days or 0), F.Money(c.normal), 1, 0.82, 0, 1, 1, 1)
    end
    if c.flatMedian and math.floor(c.flatMedian + 0.5) ~= c.normal then
      GameTooltip:AddDoubleLine("  flat median of those days", F.Money(c.flatMedian), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    end
    if c.slope and c.slope ~= 0 then
      local r, g, b = 1, 1, 1
      if c.slope < -0.03 then
        r, g, b = 1, 0.5, 0.5
      end
      GameTooltip:AddDoubleLine("Price trend", string.format("%+.1f%% a day", c.slope * 100), 1, 0.82, 0, r, g, b)
    end
    if c.supplyChange then
      GameTooltip:AddDoubleLine("Listed volume over the window", string.format("x%.1f", c.supplyChange), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Resale after the 5% cut", F.Money(c.ref), 1, 0.82, 0, 1, 1, 1)
  else
    GameTooltip:AddDoubleLine("Vendor pays", F.Money(c.vendor), 1, 0.82, 0, 1, 1, 1)
  end
  GameTooltip:AddDoubleLine("Listed in total", tostring(c.total), 1, 0.82, 0, 1, 1, 1)

  if c.mode == "dips" and c.recent and #c.recent > 0 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Recent daily lows:", 1, 0.82, 0)
    for i = math.max(1, #c.recent - 6), #c.recent do
      local e = c.recent[i]
      local note = e.source == "auctionator" and "  (Auctionator)" or ""
      local text = "low " .. F.Money(e.min)
      if e.vwm then
        text = text .. ", median " .. F.Money(e.vwm)
      end
      GameTooltip:AddDoubleLine(DaysAgo(e.day), text .. note, 1, 1, 1, 1, 1, 1)
    end
    if c.falling then
      GameTooltip:AddLine("Falling: the last three days were all below normal. This may be the new price, not a dip.", 1, 0.4, 0.4, true)
    end
  end

  local refName = c.mode == "dips" and "the resale price" or "vendor price"
  if c.detailed then
    GameTooltip:AddLine(" ")
    -- Volume by price: every tier on the page, cheap ones first, with the
    -- share of all units at or below that price. Tiers under the reference
    -- price are white, the rest grey.
    if c.ladder and #c.ladder > 0 then
      GameTooltip:AddLine(string.format("Volume by price (%d units on this page):", c.ladderUnits or 0), 1, 0.82, 0)
      local shown = 0
      for _, tier in ipairs(c.ladder) do
        shown = shown + 1
        if shown > 8 then
          GameTooltip:AddLine(string.format("...and %d more price tiers", #c.ladder - 8), 0.7, 0.7, 0.7)
          break
        end
        local share = c.ladderUnits and c.ladderUnits > 0 and math.floor(tier.cumulative * 100 / c.ladderUnits + 0.5) or 0
        local r, g, b = 1, 1, 1
        if tier.price >= c.ref then
          r, g, b = 0.6, 0.6, 0.6
        end
        GameTooltip:AddDoubleLine(string.format("%d x  (%d%% at or below)", tier.quantity, share), F.Money(tier.price), r, g, b, r, g, b)
      end
      if c.more then
        GameTooltip:AddLine("...and more (not all results were returned)", 0.7, 0.7, 0.7)
      end
      if c.vwMedian then
        GameTooltip:AddDoubleLine("Volume-weighted median", F.Money(c.vwMedian), 1, 0.82, 0, 1, 1, 1)
      end
      if c.mode == "dips" and c.adjusted and c.reanchored then
        GameTooltip:AddLine("Market adjusted: most of today's volume is below the remembered normal, and against today's median this is no longer a dip.", 1, 0.6, 0.3, true)
      elseif c.mode == "dips" and c.adjusted then
        GameTooltip:AddLine(string.format("Market adjusted: %d copies of this recipe are listed at or near this price (more than %d). This is the new price.", c.nearUnits or 0, F.db.dipRecipeMax or 5), 1, 0.6, 0.3, true)
      elseif c.mode == "dips" and c.reanchored then
        GameTooltip:AddLine("Market moved: the normal was re-anchored to today's median, and the cheap units are still a dip against that.", 1, 0.8, 0.4, true)
      elseif c.mode == "dips" and c.marketIntact ~= nil then
        if c.marketIntact then
          GameTooltip:AddLine("Market intact: most units are still near the normal price, so the cheap ones are outliers.", 0.4, 1, 0.4, true)
        else
          GameTooltip:AddLine("Market moved: most units are near the dip price. This looks like the new price, not an outlier.", 1, 0.6, 0.3, true)
        end
      end
      GameTooltip:AddDoubleLine("Below " .. refName, string.format("%d units, profit %s", c.belowUnits or 0, F.Money(c.belowProfit or 0)), 1, 0.82, 0, 1, 1, 1)
    else
      GameTooltip:AddLine("No listings came back for it.", 0.7, 0.7, 0.7)
    end
  else
    GameTooltip:AddLine(" ")
    if c.mode == "floor" and F.Scan.IsCommodity(c.itemKey) ~= true then
      GameTooltip:AddLine("Unverified: for a non-stackable item the browse price can be a bid, not a buyout. Shift-click to check its listings; only buyouts count.", 1, 0.8, 0.4, true)
    else
      GameTooltip:AddLine("Shift-click to check its listings now.", 0.7, 0.7, 0.7)
    end
  end

  local budget = F.Scan.Budget(c.mode)
  local units, cost, profit, truncated = F.Scan.Affordable(c)
  if budget then
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Within your max spend of " .. F.Money(budget),
      string.format("buy %d for %s, profit %s", units, F.Money(cost), F.Money(profit)), 0.5, 0.8, 1, 1, 1, 1)
    if truncated and c.detailed then
      GameTooltip:AddLine("The budget stops the purchase short of the cheap listings.", 0.7, 0.7, 0.7, true)
    end
  end

  local market = F.MarketPrice(c.itemID)
  if market then
    GameTooltip:AddDoubleLine("Auctionator market price", F.Money(market), 1, 0.82, 0, 1, 1, 1)
  end
  local merchant = F.MerchantPrice(c.itemID)
  if merchant then
    GameTooltip:AddDoubleLine("A vendor sells this for", F.Money(merchant), 1, 0.5, 0.2, 1, 1, 1)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click to open it in the auction house. You buy it there.", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function CreateRow(index)
  local row = CreateFrame("Button", nil, frame)
  row:SetSize(WIDTH - 20, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, FIRST_ROW_Y - (index - 1) * ROW_HEIGHT)

  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0.0)

  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(18, 18)
  row.icon:SetPoint("LEFT", row, "LEFT", COLS.icon.x, 0)

  local function Cell(col, justify)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", row, "LEFT", COLS[col].x, 0)
    fs:SetWidth(COLS[col].w)
    fs:SetJustifyH(justify or "RIGHT")
    fs:SetWordWrap(false)
    return fs
  end
  row.name = Cell("name", "LEFT")
  row.lowest = Cell("lowest")
  row.vendor = Cell("vendor")
  row.unit = Cell("unit")
  row.ratio = Cell("ratio")
  row.below = Cell("below")
  row.profit = Cell("profit")
  row.cost = Cell("cost")

  row.open = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.open:SetSize(COLS.open.w, 18)
  row.open:SetPoint("LEFT", row, "LEFT", COLS.open.x, 0)
  row.open:SetText("Open")
  row.open:SetScript("OnClick", function()
    if row.candidate then
      F.Scan.Open(row.candidate)
    end
  end)

  row.ignore = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.ignore:SetSize(COLS.ignore.w, 18)
  row.ignore:SetPoint("LEFT", row, "LEFT", COLS.ignore.x, 0)
  row.ignore:SetText("Hide")
  row.ignore:SetScript("OnClick", function()
    if row.candidate then
      F.db.ignore[row.candidate.itemID] = true
      F.Print("Ignoring %s. Use /floor unignore %d to bring it back.", F.ItemLink(row.candidate.itemID), row.candidate.itemID)
      UI.Refresh()
    end
  end)

  row:SetScript("OnClick", function()
    if row.candidate then
      if IsShiftKeyDown() then
        F.Scan.DetailOne(row.candidate)
      else
        F.Scan.Open(row.candidate)
      end
    end
  end)
  row:SetScript("OnEnter", RowTooltip)
  row:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  return row
end

-- A gold / silver / copper input group. `onChange` receives the total copper.
local function MoneyGroup(labelText, anchor, anchorPoint, x, y, onChange)
  local group = {}
  group.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  group.label:SetPoint("LEFT", anchor, anchorPoint, x, y)
  group.label:SetText(labelText)

  local function Box(width, maxLetters, anchorTo, gap, unitLabel)
    local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetPoint("LEFT", anchorTo, "RIGHT", gap, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(maxLetters)
    box:SetJustifyH("RIGHT")
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", function() group:Read() end)
    local unit = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    unit:SetPoint("LEFT", box, "RIGHT", 2, 0)
    unit:SetText(unitLabel)
    box.unit = unit
    return box
  end
  group.g = Box(44, 5, group.label, 10, "g")
  group.s = Box(28, 2, group.g.unit, 6, "s")
  group.c = Box(28, 2, group.s.unit, 6, "c")

  function group:HasFocus()
    return self.g:HasFocus() or self.s:HasFocus() or self.c:HasFocus()
  end
  function group:SetShown(shown)
    for _, w in ipairs({ self.label, self.g, self.g.unit, self.s, self.s.unit, self.c, self.c.unit }) do
      w:SetShown(shown)
    end
  end
  function group:Fill(copper)
    if self:HasFocus() then
      return
    end
    copper = math.max(0, math.floor((copper or 0) + 0.5))
    self.g:SetText(tostring(math.floor(copper / 10000)))
    self.s:SetText(tostring(math.floor((copper % 10000) / 100)))
    self.c:SetText(tostring(copper % 100))
  end
  function group:Read()
    local g = tonumber(self.g:GetText()) or 0
    local s = tonumber(self.s:GetText()) or 0
    local c = tonumber(self.c:GetText()) or 0
    onChange(g * 10000 + s * 100 + c)
  end
  return group
end

local function Build()
  if frame then
    return
  end
  frame = CreateFrame("Frame", "FloorFrame", UIParent, "BackdropTemplate")
  UI.frame = frame
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
  })
  frame:Hide()
  table.insert(UISpecialFrames, "FloorFrame") -- Escape closes it

  -- Row 1: title, mode buttons, close.
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
  title:SetText("Floor")

  local function ModeButton(mode, text, x)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(112, 20)
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -10)
    button.label = text
    button:SetText(text)
    button:SetScript("OnClick", function()
      F.db.mode = mode
      offset = 0
      UI.Refresh()
    end)
    return button
  end
  frame.modeAll = ModeButton("all", "Sure things", 80)
  frame.modeFloor = ModeButton("floor", "Vendor floor", 196)
  frame.modeDips = ModeButton("dips", "Price dips", 312)
  frame.modeBids = ModeButton("bids", "Bid snipes", 428)
  frame.modeCrafts = ModeButton("crafts", "Crafts", 544)

  local drag = CreateFrame("Frame", nil, frame)
  drag:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  drag:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  drag:SetHeight(30)
  drag:EnableMouse(true)
  drag:RegisterForDrag("LeftButton")
  drag:SetScript("OnDragStart", function() frame:StartMoving() end)
  drag:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); SavePosition() end)
  drag:SetFrameLevel(frame:GetFrameLevel()) -- under the buttons

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

  -- Row 2: status, Check more, Scan.
  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.status:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -38)
  frame.status:SetWidth(520)
  frame.status:SetJustifyH("LEFT")
  frame.status:SetWordWrap(false)
  frame.status:SetText("Click Scan with the auction house open.")

  frame.scan = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.scan:SetSize(70, 22)
  frame.scan:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -34)
  frame.scan:SetText("Scan")
  frame.scan:SetScript("OnClick", function()
    if F.Scan.Busy() then
      F.Scan.Abort("you stopped it; what it found so far stays")
    elseif F.db.mode == "bids" and (time() - (F.db.lastReplicate or 0)) >= F.Scan.REPLICATE_WAIT then
      F.Scan.StartBids()
    else
      F.Scan.Start()
    end
  end)
  frame.scan:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if F.Scan.Busy() then
      GameTooltip:SetText("Stop")
      GameTooltip:AddLine("Stops the scan. Everything found so far stays in every view.", 1, 1, 1, true)
    else
      GameTooltip:SetText("Scan")
      GameTooltip:AddLine("One scan fills every view: vendor floor, price dips, crafts, and bid snipes when the 15-minute window allows. Switch views while it runs; it keeps going.", 1, 1, 1, true)
      GameTooltip:AddLine("Weapons and armor first (verified right away), then the rest of the market.", 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
  end)
  frame.scan:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.quick = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.quick:SetSize(60, 22)
  frame.quick:SetPoint("RIGHT", frame.scan, "LEFT", -6, 0)
  frame.quick:SetText("Quick")
  frame.quick:SetScript("OnClick", function() F.Scan.Start({ quick = true }) end)
  frame.quick:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Quick scan")
    GameTooltip:AddLine("Weapons and armor only: the fast way to catch big vendor-floor items before someone else does.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.quick:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.snipe = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.snipe:SetSize(64, 22)
  frame.snipe:SetPoint("RIGHT", frame.quick, "LEFT", -6, 0)
  frame.snipe:SetText("Snipe")
  frame.snipe:SetScript("OnClick", function()
    if F.Scan.snipe.on then
      F.Scan.SnipeStop()
    else
      F.Scan.SnipeStart()
    end
    UI.Refresh()
  end)
  frame.snipe:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Snipe")
    GameTooltip:AddLine("Watch the newest listings every few seconds and call out anything below vendor price or well below normal, the moment it is posted. Buying is still your click.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.snipe:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.check = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.check:SetSize(90, 22)
  frame.check:SetPoint("RIGHT", frame.snipe, "LEFT", -6, 0)
  frame.check:SetText("Check more")
  frame.check:SetScript("OnClick", function()
    local queued = 0
    for _, c in ipairs(F.Scan.Visible()) do
      if not c.detailed and c.mode ~= "bids" then
        F.Scan.DetailOne(c)
        queued = queued + 1
        if queued >= (F.db.detailLimit or 25) then
          break
        end
      end
    end
    if queued == 0 then
      F.Print("Every shown item has been checked.")
    end
  end)

  -- Row 3: the two money settings.
  local rowAnchor = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  rowAnchor:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -60)
  rowAnchor:SetText("")
  -- Both settings belong to the view that is showing.
  frame.minGroup = MoneyGroup("Min profit per unit", rowAnchor, "LEFT", 0, 0, function(copper)
    local mode = F.db.mode or "floor"
    if copper < 1 then
      copper = 1
    end
    if copper ~= F.Scan.MinUnit(mode) then
      F.db.mins[mode] = copper
      F.Print("In the %s view, items now count when they are at least %s below the reference price per unit.", mode, F.Money(copper))
    end
    UI.Refresh()
  end)
  frame.maxGroup = MoneyGroup("Max spend per item (0 = any)", frame.minGroup.c.unit, "RIGHT", 28, 0, function(copper)
    local mode = F.db.mode or "floor"
    if copper ~= (F.db.maxes[mode] or 0) then
      F.db.maxes[mode] = copper
      if copper > 0 then
        F.Print("In the %s view, max spend per item is %s. Items you can't afford are hidden and profit counts only the units that fit.", mode, F.Money(copper))
      else
        F.Print("No spending limit in the %s view.", mode)
      end
    end
    UI.Refresh()
  end)
  -- The unified view has no settings of its own.
  frame.allNote = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.allNote:SetPoint("LEFT", rowAnchor, "LEFT", 0, 0)
  frame.allNote:SetText("Each kind keeps the min profit and max spend set in its own view (vendor floor, bid snipes, crafts).")
  frame.allNote:Hide()

  -- Dips view: what the dips consider. Stackables, recipes and quest items by
  -- default; everything (gear too) when /floor dipall is on.
  frame.dipScope = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.dipScope:SetSize(110, 22)
  frame.dipScope:SetPoint("RIGHT", frame, "RIGHT", -30, 0)
  frame.dipScope:SetPoint("TOP", rowAnchor, "TOP", 0, 4)
  frame.dipScope:SetScript("OnClick", function()
    F.SetDipAll(not F.db.dipAll)
  end)
  frame.dipScope:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(F.db.dipAll and "Dips: everything" or "Dips: stackables only")
    GameTooltip:AddLine("Stackables only: trade goods, consumables and other stackable items, plus recipes and quest items. One piece of gear at a low price is rarely a market signal.", 1, 1, 1, true)
    GameTooltip:AddLine(F.db.dipAll and "Click to go back to stackables only; gear dips are hidden at once." or "Click to consider everything, gear included; that needs a new scan.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  frame.dipScope:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.dipScope:Hide()

  -- Column headers. The sortable ones are buttons; the active one is yellow.
  local function HeaderButton(key, text, col)
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(COLS[col].w, 16)
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", COLS[col].x, HEADER_Y + 2)
    local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints()
    fs:SetJustifyH("RIGHT")
    fs:SetWordWrap(false)
    fs:SetText(text)
    button.text = fs
    button:SetScript("OnClick", function(self)
      F.Scan.SetSortKey(F.db.mode or "floor", self.sortKey or key)
      UI.Refresh()
    end)
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText("Sort by " .. (self.text:GetText() or text):lower())
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    headers[key] = button
    return button
  end

  Label(frame, "Item", COLS.name.x, HEADER_Y, COLS.name.w)
  HeaderButton("lowest", "Lowest", "lowest")
  HeaderButton("vendor", "Vendor", "vendor")
  HeaderButton("unit", "Per unit", "unit")
  HeaderButton("ratio", "Ratio", "ratio")
  HeaderButton("below", "Buy / below", "below")
  HeaderButton("profit", "Profit", "profit")
  HeaderButton("cost", "Cost", "cost")

  for i = 1, ROWS do
    rows[i] = CreateRow(i)
  end

  -- Order button: cycles through the row orders. Column headers set one directly.
  frame.sortButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.sortButton:SetSize(150, 20)
  frame.sortButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 10)
  frame.sortButton:SetScript("OnClick", function()
    local mode = F.db.mode or "floor"
    local current = F.Scan.SortKey(mode)
    local order = F.Scan.SORT_ORDER
    local nextKey = order[1]
    for i, key in ipairs(order) do
      if key == current then
        nextKey = order[i + 1] or order[1]
        break
      end
    end
    F.Scan.SetSortKey(mode, nextKey)
    UI.Refresh()
  end)
  frame.sortButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Row order")
    GameTooltip:AddLine("Both: ratio x affordable profit, so an item needs a good score on both.", 1, 1, 1, true)
    GameTooltip:AddLine("Click to cycle; click a column header to sort by that column.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  frame.sortButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 12)
  frame.footer:SetWidth(WIDTH - 200)
  frame.footer:SetJustifyH("LEFT")

  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    local total = #F.Scan.Visible()
    local maxOffset = math.max(0, total - ROWS)
    offset = math.max(0, math.min(maxOffset, offset - delta))
    UI.Refresh()
  end)

  RestorePosition()
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

-- Tags for the unified view, where rows of three kinds share one list.
local KIND_TAGS = { floor = "|cff9ab8ffvendor|r ", bids = "|cffffcc66bid|r ", crafts = "|cff7fdcb0craft|r " }

local SORT_LABELS = {
  both = "Order: ratio x profit", volume = "Order: volume seen", ratio = "Order: ratio", profit = "Order: profit",
  unit = "Order: per unit", lowest = "Order: lowest price", vendor = "Order: reference price",
  below = "Order: units below", cost = "Order: cheapest buy",
}

local function Draw()
  refreshQueued = false
  if not frame or not frame:IsShown() then
    return
  end
  local mode = F.db.mode or "floor"
  local dips = (mode == "dips")
  local bids = (mode == "bids")
  local crafts = (mode == "crafts")
  local all = (mode == "all")
  local visible = F.Scan.Visible(mode)
  local maxOffset = math.max(0, #visible - ROWS)
  if offset > maxOffset then
    offset = maxOffset
  end
  UI.FillBoxes()

  frame.modeAll:SetText((all and "> " or "") .. frame.modeAll.label)
  frame.modeFloor:SetText((mode == "floor" and "> " or "") .. frame.modeFloor.label)
  frame.modeDips:SetText((dips and "> " or "") .. frame.modeDips.label)
  frame.modeBids:SetText((bids and "> " or "") .. frame.modeBids.label)
  frame.modeCrafts:SetText((crafts and "> " or "") .. frame.modeCrafts.label)
  frame.check:SetShown(not bids and not crafts)
  frame.scan:SetText(F.Scan.Busy() and "|cffff6666Stop|r" or "Scan")
  frame.dipScope:SetShown(dips)
  frame.dipScope:SetText(F.db.dipAll and "Everything" or "Stackables only")
  frame.snipe:SetText(F.Scan.snipe.on and "|cff66ff66Sniping|r" or "Snipe")
  if bids then
    headers.lowest.text:SetText("Bid/unit")
    headers.vendor.text:SetText("Ref/unit")
    headers.unit.text:SetText("Profit/unit")
    headers.below.text:SetText("Time left")
    headers.cost.text:SetText("Next bid")
  elseif crafts then
    headers.lowest.text:SetText("Cost/craft")
    headers.vendor.text:SetText("Sells for")
    headers.unit.text:SetText("Profit/craft")
    headers.below.text:SetText("Crafts")
    headers.cost.text:SetText("Total cost")
  elseif all then
    headers.lowest.text:SetText("Buy at")
    headers.vendor.text:SetText("Sells for")
    headers.unit.text:SetText("Profit/unit")
    headers.below.text:SetText("Units / time")
    headers.cost.text:SetText("Cost")
  else
    headers.lowest.text:SetText("Lowest")
    headers.vendor.text:SetText(dips and "Normal" or "Vendor")
    headers.unit.text:SetText(dips and "Resale/unit" or "Per unit")
    headers.below.text:SetText("Buy / below")
    headers.cost.text:SetText("Cost")
  end
  -- In the dips view the Ratio column becomes Volume (units on the market);
  -- in the crafts view it reads Margin.
  headers.ratio.text:SetText(dips and "Volume" or (crafts and "Margin" or "Ratio"))
  headers.ratio.sortKey = dips and "volume" or "ratio"

  local activeSort = F.Scan.SortKey(mode)
  frame.sortButton:SetText(SORT_LABELS[activeSort] or ("Order: " .. activeSort))
  for key, header in pairs(headers) do
    if (header.sortKey or key) == activeSort then
      header.text:SetTextColor(1, 0.82, 0)
    else
      header.text:SetTextColor(0.75, 0.75, 0.75)
    end
  end

  for i = 1, ROWS do
    local row = rows[i]
    local c = visible[offset + i]
    row.candidate = c
    if c then
      local name, quality, icon = F.ItemDisplay(c.itemKey)
      row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      local shown = F.Colorize(name or ("item " .. c.itemID), quality)
      if c.mode == "bids" and (c.total or 1) > 1 then
        shown = shown .. " |cffaaaaaax" .. c.total .. "|r"
      end
      if all then
        shown = (KIND_TAGS[c.mode] or "") .. shown
      end
      if c.new and c.seenAt and GetTime() - c.seenAt < 120 then
        shown = "|cff66ff66new|r " .. shown
      end
      row.name:SetText(shown)
      local lowest = F.Money(c.minPrice)
      if c.mode == "dips" and c.marketIntact == true then
        lowest = "|cff66ff66" .. lowest .. "|r"   -- outlier in an intact market
      elseif c.mode == "dips" and c.marketIntact == false then
        lowest = "|cffffa040" .. lowest .. "|r"   -- the market has moved to the dip
      end
      row.lowest:SetText(lowest)
      if c.mode == "dips" then
        local normal = F.Money(c.normal)
        if c.reanchored then
          normal = "|cffffa040" .. normal .. "|r"   -- re-anchored to today's market
        elseif c.falling then
          normal = "|cffff6060" .. normal .. "|r"   -- trend falling more than 3% a day
        end
        row.vendor:SetText(normal)
      elseif c.mode == "bids" then
        row.vendor:SetText((c.refKind == "vendor" and "|cffaaaaaav|r " or "") .. F.Money(c.ref))
      elseif c.mode == "crafts" and c.craft then
        local sells = F.Money(c.craft.productPrice * c.craft.qty)
        if c.craft.route == "vendor" then
          sells = "|cffaaaaaav|r " .. F.Money(c.ref)
        end
        row.vendor:SetText(sells)
      else
        row.vendor:SetText(F.Money(c.vendor))
      end
      row.unit:SetText(F.Money(c.unitProfit))
      if c.mode == "dips" then
        row.ratio:SetText(tostring(c.total or 0))
      else
        local percent = math.floor(F.Scan.Ratio(c) * 100 + 0.5)
        if percent > 9999 then
          row.ratio:SetText("9999%+")
        else
          row.ratio:SetText(string.format("%d%%", percent))
        end
      end
      local units, cost, profit, truncated = F.Scan.Affordable(c)
      if c.mode == "bids" then
        local left = F.Scan.TIME_LEFT[c.bid and c.bid.timeLeft or 0] or "?"
        if c.bid and c.bid.timeLeft == 1 then
          left = "|cffff6060" .. left .. "|r"
        end
        row.below:SetText(left)
        row.profit:SetText(F.Money(profit))
        row.cost:SetText(F.Money(c.bid and c.bid.nextBid or cost))
      elseif c.detailed then
        local below = tostring(c.belowUnits or 0) .. (c.more and "+" or "")
        row.below:SetText(tostring(units) .. " / " .. below)
        row.profit:SetText(F.Money(profit))
        row.cost:SetText((truncated and "|cffffd060" or "") .. F.Money(cost) .. (truncated and "|r" or ""))
      elseif c.mode == "floor" and F.Scan.IsCommodity(c.itemKey) ~= true then
        -- a non-stackable item's browse price may be a bid; only a listing check tells
        row.below:SetText("|cff888888bid or buyout?|r")
        row.profit:SetText(c.detailFailed and "|cff888888no answer|r" or "|cff888888unverified|r")
        row.cost:SetText("|cff888888" .. F.Money(c.minPrice) .. " ea|r")
      else
        row.below:SetText("? / ?")
        row.profit:SetText("|cff888888not checked|r")
        row.cost:SetText("|cff888888" .. F.Money(c.minPrice) .. " ea|r")
      end
      row:Show()
    else
      row:Hide()
    end
  end

  local footer
  if #visible > ROWS then
    footer = string.format("Showing %d-%d of %d. Scroll for more. Click a row to open it; you buy in the auction house.",
      offset + 1, math.min(offset + ROWS, #visible), #visible)
  elseif all then
    footer = "Sure things: vendor-floor buyouts (vendor), auctions ending soon with a next bid under resale (bid) and conversions that pay (craft), in one list. Price dips stay in their own view. Click a row to open it; you buy or bid in the auction house."
  elseif crafts then
    footer = "Crafts: conversions where the reagents cost less than the product sells for (after the 5% cut, or v = vendored). Prices from the last scan's lowest listings. Recipes come from built-ins plus any profession window you open."
  elseif bids then
    footer = "Bids: auctions ending within " .. (F.Scan.TIME_LEFT[F.db.bidMaxTimeLeft or 1] or "?") .. " whose next bid is under the resale price (normal after the 5% cut, or v = vendor price). /floor bidtime widens it. Click a row, then bid in the auction house."
  elseif dips then
    footer = "Dips (" .. (F.db.dipAll and "everything, gear included" or "stackables, recipes and quest items") .. "): lowest at or under " .. tostring(F.db.dipPercent or 60) .. "% of the trend-adjusted normal, ordered by volume then resale per unit. Green lowest = outlier in an intact market; orange normal = re-anchored to today's median; red normal = falling." .. F.Scan.DriftText(" Market: ")
  else
    footer = "Click a row to open it in the auction house and buy with your own clicks. Shift-click checks its listings (buyouts only; bids never count). Buy / below = units within your max spend / units under vendor price."
  end
  frame.footer:SetText(footer)
end

-- Show the saved settings in the money boxes (unless one is being typed in).
function UI.FillBoxes()
  if not frame then
    return
  end
  local mode = F.db.mode or "floor"
  local all = (mode == "all")
  frame.minGroup:SetShown(not all)
  frame.maxGroup:SetShown(not all)
  frame.allNote:SetShown(all)
  if all then
    return
  end
  frame.minGroup.label:SetText("Min profit per unit (" .. mode .. ")")
  frame.maxGroup.label:SetText("Max spend per item (" .. mode .. ", 0 = any)")
  frame.minGroup:Fill(F.Scan.MinUnit(mode))
  frame.maxGroup:Fill((F.db.maxes and F.db.maxes[mode]) or 0)
end

-- Kept for callers that know the old names.
function UI.FillMinBoxes()
  UI.FillBoxes()
end
function UI.ReadMinBoxes()
  if frame then
    frame.minGroup:Read()
  end
end

function UI.Refresh()
  if refreshQueued then
    return
  end
  refreshQueued = true
  C_Timer.After(0, Draw)
end

function UI.SetStatus(text)
  if frame then
    frame.status:SetText(text or "")
  end
end

function UI.Show()
  Build()
  frame:Show()
  if F.Scan.status then
    frame.status:SetText(F.Scan.status)
  end
  UI.Refresh()
end

function UI.Toggle()
  Build()
  if frame:IsShown() then
    frame:Hide()
  else
    UI.Show()
  end
end

------------------------------------------------------------------------------
-- Hooking into the auction house window
------------------------------------------------------------------------------

local ahButton

function UI.OnAuctionHouseShow()
  if AuctionHouseFrame and not ahButton then
    ahButton = CreateFrame("Button", "FloorAHButton", AuctionHouseFrame, "UIPanelButtonTemplate")
    ahButton:SetSize(64, 22)
    ahButton:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT", -26, 2)
    ahButton:SetText("Floor")
    ahButton:SetScript("OnClick", function() UI.Toggle() end)
  end
  if frame and frame:IsShown() then
    UI.Refresh()
  end
end

function UI.OnAuctionHouseClosed()
  if frame and frame:IsShown() then
    frame:Hide()
  end
end

-- Names and icons arrive after the scan; redraw when they do.
local refresher = CreateFrame("Frame")
refresher:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
refresher:RegisterEvent("ITEM_DATA_LOAD_RESULT")
refresher:SetScript("OnEvent", function()
  if frame and frame:IsShown() then
    UI.Refresh()
  end
end)
