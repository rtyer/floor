# Floor: research notes and backlog

Written in the early hours of Nov 22, 2026, after a pass over gold-making guides,
TSM's documentation and the Forever forums. Ideas are ordered by how much they
could pay against how much work they are.

## Already built from the research

- **Snipe mode** (done, v0.6). TradeSkillMaster's "Sniper" never scans the
  whole market; it re-reads the newest listings every few seconds. Floor's
  Snipe does the same with one browse page sorted by time left, so a vendor
  buyout is caught seconds after it is posted. Source: TSM sniper docs
  (https://support.tradeskillmaster.com/tsm-addon-documentation/tsm-addon-sniper-operations).
  Common TSM starting point for a dip threshold: 60-70% of market, which
  matches Floor's default 60%.

## Worth building next

1. **Posting helper (sell side).** Scan the bags: for each stack, show vendor
   price, the auction house's lowest, Floor's normal, and the better move
   (vendor it, or post at X). Deposit math per duration (5% / 20% / 60% of
   vendor price for 2h / 8h / 24h) and the 5% cut, so the net is honest. The
   browse data already holds every price; bags need `C_Container`. This closes
   the loop: Floor buys, then tells you how to sell.
2. **Thesis watchlist.** Items with a reason and a date ("raids Dec 9":
   consumables, enchanting mats, resistance gear by wing; "Legacy profession
   points": mid-tier mats like Mageweave, Thick Leather, Mithril). Track your
   average cost against the current price and say when to post. Alert when
   the scan sees a watched item at or under a buy price.
3. **Waylaid Crates to Merchant's Favor.** Crates sell on the auction house;
   turning them in at Durotar Supply and Logistics pays Favor (about 5-30 per
   crate by tier), which buys recipes, mounts and titles. A view listing the
   cheapest copper-per-Favor crates on the auction house would make the
   reputation grind a purchase. Needs the crate item ids and Favor per crate
   (method.gg and outof.games have lists). Sources:
   https://www.method.gg/wow-forever/how-to-get-waylaid-crates-and-merchants-favor-in-wow-forever,
   https://outof.games/realms/forever/auctions/waylaid-crates/
4. **Limited-supply vendor recipes.** Classic staple: vendors sell some
   recipes in limited stock at fixed prices; they resell on the auction house
   for more. Floor already knows merchant prices through Auctionator's cache;
   a view comparing merchant price against the auction house's lowest, for
   recipes only, would show the gap (and the reverse: recipes dumped below
   their vendor buy price).
5. **Disenchant shuffle** once an Enchanting alt exists: compare gear buyouts
   against the expected disenchant value (dust, essence, shard prices from the
   scan times drop rates). Needs a disenchant table for classic item levels.
6. **Cross-faction arbitrage** via the neutral auction houses (15% cut). On
   the PvE ruleset both factions can be played. A level-1 Alliance alt parked
   at an auction house would show whether the Alliance side is cheaper; Floor's
   memory is per character's faction, so it could hold both.

## Scan speed: what the server allows

Blizzard has never published a rate. What is known, from the 8.3 auction house
revamp and the June 2020 throttling episode: the throttle is per player, not
per realm; it applies to the addon API and not to the default UI's own
searches; in June 2020 individual addon queries went from about 0.3 s to 2-6 s
each and Blizzard later relaxed everything except cancels after the outcry.
Sources: https://www.wowhead.com/news=316512/blizzard-significantly-reduces-auction-house-throttling,
https://us.forums.blizzard.com/en/wow/t/ah-extremely-slow-throttles-need-adjustment/1326415,
https://us.forums.blizzard.com/en/wow/t/auction-house-much-slower-today-june-16/556722/13,
https://blizzardwatch.com/2020/06/18/wow-auction-house-addons-broken/.
Forever's numbers are unknown; `/floor timing` measures them. The client API
has no documented rate either: `C_AuctionHouse.IsThrottledMessageSystemReady()`
says whether the next request may go, and that is the whole contract.

What was Floor's own fault before v0.7 (all fixed): waiting for each answer
before sending the next search (the server paces requests, not answers);
sending searches for items whose key info was not cached, which the server
ignores (Auctionator's `SearchScan.lua` documents this), so each cost a
four-second timeout; and relying on the ready event alone, with a three-second
guess when it was missed. That is what made "the last 25" slow.

v0.7.1 (Nov 22): the dips focus (stackables, recipes and quest items only)
leaked gear in game. It asked the client whether an item stacks, and on a
freshly started client neither the key-info cache nor the item cache knows
most items during the browse, so every "unknown" item was let through and
never re-checked; the harness always knew every item, so it never saw this.
Now the item's class decides (the client knows every item's class without
loading it: weapons, armor, bags and quivers never stack), a dip whose listing
answer says "not a commodity" leaves the view, and the dips view carries a
Stackables only / Everything button. Also from Nov 22: the Scan button reads
Stop while a scan runs (`/floor stop`), and the status says the scan fills
every view, since switching views mid-scan looked like it needed a scan each.

## Things to know about the market (from the forums, Nov 2026)

- Fees: 5% cut on your faction's auction house, 15% neutral. Deposits since
  Nov 17: 5% / 20% / 60% of vendor price for 2h / 8h / 24h, minimum 1 copper.
- Megaserver: thousands of auctions per item; bait listings (one unit at half
  price) are common; undercut-cancel scanning is common; snipers buy within
  seconds. Blizzard polices exploits (gold removal, suspensions) but normal
  trading is fine.
- Blizzard promised more spell power gear for levels 15-40 in a future patch,
  which will deflate caster BoE greens in that range: trade them, do not hold.
- Raids open Dec 9. Expect consumables and enchanting mats to firm up the week
  before.

## Open questions only the game can answer

- Does `C_AuctionHouse.ReplicateItems` (the bid dump) work on Forever? Floor
  says so within 30 seconds if it does not.
- Does the browse sort by time remaining put the newest listings first on
  Forever, as it does on retail? If Snipe never finds anything, this is the
  first thing to check (`/floor debug`).
- How long does Forever's server take to allow the next request, and how long
  do listing answers take? `/floor timing` after a scan answers both; if the
  "ready" average is well over a second, the server is the limit and nothing
  in Floor can change it.
- Does `AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay:SetQuantity` exist
  on Forever's client? If not, the quantity pre-fill silently does nothing.
