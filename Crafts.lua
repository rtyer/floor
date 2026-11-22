-- Floor: crafts.
--
-- Simple conversions where the auction house sells the input cheaper than the
-- output: ore into bars, cloth into bolts, scraps into leather, and whatever
-- your own professions can make. Prices come from the last scan's lowest
-- listings; supply is how many crafts today's listings could feed.
--
-- Two routes are costed for every craft: sell the product on the auction
-- house (after the 5% cut) or sell it to a vendor. The better one is shown.

local F = Floor
local C = {}
F.Crafts = C

-- Conversions any character with the profession can do, with classic item
-- ids. Recipes read from your own profession windows are added to these.
C.BUILTIN = {
  { name = "Copper Bar",          prof = "Mining",         out = 2840,  qty = 1, reagents = { { 2770, 1 } } },
  { name = "Tin Bar",             prof = "Mining",         out = 3576,  qty = 1, reagents = { { 2771, 1 } } },
  { name = "Bronze Bar",          prof = "Mining",         out = 2841,  qty = 2, reagents = { { 2840, 1 }, { 3576, 1 } } },
  { name = "Silver Bar",          prof = "Mining",         out = 2842,  qty = 1, reagents = { { 2775, 1 } } },
  { name = "Iron Bar",            prof = "Mining",         out = 3575,  qty = 1, reagents = { { 2772, 1 } } },
  { name = "Steel Bar",           prof = "Mining",         out = 3859,  qty = 1, reagents = { { 3575, 1 }, { 3857, 1 } } },
  { name = "Gold Bar",            prof = "Mining",         out = 3577,  qty = 1, reagents = { { 2776, 1 } } },
  { name = "Mithril Bar",         prof = "Mining",         out = 3860,  qty = 1, reagents = { { 3858, 1 } } },
  { name = "Truesilver Bar",      prof = "Mining",         out = 6037,  qty = 1, reagents = { { 7911, 1 } } },
  { name = "Thorium Bar",         prof = "Mining",         out = 12359, qty = 1, reagents = { { 10620, 1 } } },
  { name = "Light Leather",       prof = "Leatherworking", out = 2318,  qty = 1, reagents = { { 2934, 3 } } },
  { name = "Bolt of Linen Cloth", prof = "Tailoring",      out = 2996,  qty = 1, reagents = { { 2589, 2 } } },
  { name = "Bolt of Woolen Cloth",prof = "Tailoring",      out = 2997,  qty = 1, reagents = { { 2592, 3 } } },
  { name = "Bolt of Silk Cloth",  prof = "Tailoring",      out = 4305,  qty = 1, reagents = { { 4306, 4 } } },
  { name = "Bolt of Mageweave",   prof = "Tailoring",      out = 4339,  qty = 1, reagents = { { 4338, 5 } } },
  { name = "Bolt of Runecloth",   prof = "Tailoring",      out = 14048, qty = 1, reagents = { { 14047, 5 } } },
}

-- One craft = one signature, so a recipe read from a profession window
-- replaces the built-in copy of the same conversion.
local function Signature(craft)
  local parts = {}
  for _, r in ipairs(craft.reagents) do
    table.insert(parts, r[1] .. "x" .. r[2])
  end
  table.sort(parts)
  return craft.out .. ":" .. craft.qty .. "|" .. table.concat(parts, ",")
end

-- Every craft we know: built-ins plus saved recipes, saved ones winning.
function C.All()
  local bySig, order = {}, {}
  for _, craft in ipairs(C.BUILTIN) do
    local sig = Signature(craft)
    if not bySig[sig] then
      table.insert(order, sig)
    end
    bySig[sig] = { name = craft.name, prof = craft.prof, out = craft.out, qty = craft.qty, reagents = craft.reagents, source = "built in", signature = sig }
  end
  for _, saved in pairs((F.db and F.db.recipes) or {}) do
    if saved.out and saved.reagents then
      local sig = Signature(saved)
      if not bySig[sig] then
        table.insert(order, sig)
      end
      bySig[sig] = { name = saved.name, prof = saved.prof, out = saved.out, qty = saved.qty or 1, reagents = saved.reagents, source = "your profession", signature = sig }
    end
  end
  local out = {}
  for _, sig in ipairs(order) do
    table.insert(out, bySig[sig])
  end
  return out
end

------------------------------------------------------------------------------
-- Reading recipes from an open profession window
------------------------------------------------------------------------------

function C.Capture()
  if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then
    return 0
  end
  local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
  if not ok or type(ids) ~= "table" then
    return 0
  end
  local prof = ""
  pcall(function()
    if C_TradeSkillUI.GetBaseProfessionInfo then
      local info = C_TradeSkillUI.GetBaseProfessionInfo()
      prof = (info and info.professionName) or ""
    end
  end)
  if prof == "" then
    pcall(function()
      local _, name = C_TradeSkillUI.GetTradeSkillLine()
      prof = name or ""
    end)
  end
  local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  local added = 0
  for _, id in ipairs(ids) do
    local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
    if okInfo and info and info.learned ~= false then
      local okSch, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, id, false)
      if okSch and sch and sch.outputItemID then
        local reagents, complete = {}, true
        for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
          local basic = (basicType == nil) or (slot.reagentType == basicType)
          if basic and (slot.quantityRequired or 0) > 0 then
            local first = slot.reagents and slot.reagents[1]
            if first and first.itemID then
              table.insert(reagents, { first.itemID, slot.quantityRequired })
            else
              complete = false
            end
          end
        end
        if complete and #reagents > 0 then
          F.db.recipes[tostring(id)] = {
            name = info.name or ("recipe " .. id),
            prof = prof,
            out = sch.outputItemID,
            qty = sch.quantityMin or 1,
            reagents = reagents,
            seen = time(),
          }
          added = added + 1
        end
      end
    end
  end
  if added > 0 then
    F.Print("Remembered %d recipes%s for the Crafts view.", added, prof ~= "" and (" from " .. prof) or "")
  end
  return added
end

function C.Count()
  local n = 0
  for _ in pairs((F.db and F.db.recipes) or {}) do
    n = n + 1
  end
  return n
end

local captureQueued = false
local events = CreateFrame("Frame")
events:RegisterEvent("TRADE_SKILL_SHOW")
events:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
events:SetScript("OnEvent", function()
  if captureQueued or not F.db then
    return
  end
  captureQueued = true
  C_Timer.After(0.5, function()
    captureQueued = false
    C.Capture()
  end)
end)

------------------------------------------------------------------------------
-- Costing against the last scan
------------------------------------------------------------------------------

function C.Evaluate()
  local S = F.Scan
  S.lists.crafts, S.results.crafts = {}, {}
  if not S.market then
    return
  end
  for _, craft in ipairs(C.All()) do
    local cost, possible, missing, parts = 0, math.huge, false, {}
    for _, r in ipairs(craft.reagents) do
      local id, n = r[1], r[2]
      local m = S.market[id]
      if not m or not m.minPrice then
        missing = true
        break
      end
      cost = cost + m.minPrice * n
      possible = math.min(possible, math.floor((m.total or 0) / n))
      table.insert(parts, { id = id, n = n, price = m.minPrice, listed = m.total or 0 })
    end
    local product = S.market[craft.out]
    if not missing and product and product.minPrice and cost > 0 and possible > 0 then
      local auctionRef = math.floor(product.minPrice * craft.qty * S.CUT)
      local auctionProfit = auctionRef - cost
      local vendor = F.VendorPrice(craft.out)
      local vendorProfit = vendor and (vendor * craft.qty - cost) or nil
      local ref, best, route = auctionRef, auctionProfit, "auction"
      if vendorProfit and vendorProfit > best then
        ref, best, route = vendor * craft.qty, vendorProfit, "vendor"
      end
      if best >= 1 then
        local c = {
          mode = "crafts",
          key = craft.signature,
          itemKey = C_AuctionHouse.MakeItemKey(craft.out),
          itemID = craft.out,
          raw = product.raw,
          minPrice = cost,
          total = product.total or 0,
          ref = ref,
          unitProfit = best,
          detailed = true,
          belowUnits = possible,
          belowProfit = best * possible,
          tiersAll = { { price = cost, quantity = possible } },
          tiers = { { price = cost, quantity = possible } },
          more = false,
          isCommodity = nil,
          craft = {
            name = craft.name, prof = craft.prof, source = craft.source, out = craft.out, qty = craft.qty,
            parts = parts, productPrice = product.minPrice, productVolume = product.total or 0,
            vendor = vendor, auctionProfit = auctionProfit, vendorProfit = vendorProfit, route = route,
          },
        }
        S.results.crafts[craft.signature] = c
        table.insert(S.lists.crafts, c)
      end
    end
  end
  table.sort(S.lists.crafts, S.Comparator("crafts"))
end
