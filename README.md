# Floor

Finds auctions on WoW Forever that are listed below the price a vendor pays
for them (buy, vendor, keep the difference), auctions listed well below their
normal price (buy, relist at the normal price), and auctions whose next bid is
below the resale price (bid, wait, relist).

The addon only reads the auction house. It never buys or posts anything: you
open an item from the results and buy it with your own clicks in Blizzard's
window, which is what Blizzard's addon rules require.

## Installing

Download the latest `Floor-<version>.zip` from the repository's releases and
unzip it into the game's AddOns folder, so that `Floor.toc` ends up at
`.../Interface/AddOns/Floor/Floor.toc`. On WoW Forever that folder is
`World of Warcraft/_forever_/Interface/AddOns`. Then `/reload` or restart
the game. Auctionator is optional; see **Good to know**.

From a clone, `just install` copies the addon into the game (the `WOW_ADDONS`
variable points it at another AddOns folder). See **Developing** at the end.

## Using it

1. Open the auction house. A **Floor** button sits above the top-right corner
   of the auction house window; `/floor` also toggles the results window.
2. Click **Scan**. The scan runs in passes: weapons and armor first (the big
   vendor prices and the big mispricings), whose candidates get their listings
   checked right away, then the rest of the market, then the bid dump when
   its 15-minute window allows. **One scan fills every view**: switch
   between Sure things, Vendor floor, Price dips, Bids and Crafts while it
   runs and it keeps going. While it runs the Scan button reads **Stop**;
   click it (or `/floor stop`) to end the scan and keep what it found so
   far. A megaserver takes a minute or two in total; the server paces every
   request, so the order is what makes it fast where it matters. **Quick**
   runs only the weapons-and-armor pass. Don't search in the auction house
   while a scan runs. `/floor loop 60` rescans every minute while the auction house is
   open; `/floor bidsonscan off` leaves the bid dump to the `/floor bids`
   command. `/floor timing` says where the last scan's seconds went.
   Results appear as the scan runs: each page of browse results adds its
   rows, and the listing checks fill in the Buy / below, Profit and Cost
   columns as their answers arrive.
3. Click a row to open that item in Blizzard's buy view and buy there. For a
   stackable item Floor pre-fills the quantity worth buying within your max
   spend; the Buyout click and its confirmation are yours.
   Shift-click a row to re-check its listings. **Hide** drops an item for good
   (`/floor unignore <id>` brings it back). Hover a row for the price tiers
   and Auctionator's market price.

Columns: **Lowest** is the cheapest unit on the auction house, **Vendor** is
what a vendor pays per unit, **Per unit** is the difference, **Ratio** is that
difference as a share of the price you pay (buy at 1s, vendor at 2s = 100%),
**Buy / below** is units you can afford / units below vendor price, **Profit**
is what buying them earns, **Cost** is what they cost. Auctionator's market
price is in the tooltip when Auctionator is installed.

Each view remembers its own order. The vendor floor and bid snipes start on
**ratio x total profit**, so an item has to do well on both to reach the top:
a big profit at a modest ratio still beats a tiny profit at a huge ratio.
Price dips start on **volume seen** (units on the market, a liquidity signal)
and then resale per unit. The **Order** button at the bottom right cycles
through the orders for the current view, a column header sorts by that
column, and `/floor sort both|volume|ratio|profit|unit|lowest|vendor|below|cost`
does it from chat. Until an item's listings have been checked, its profit
counts as one unit at the lowest price.

## Sure things

The **Sure things** view puts everything with a certain profit in one list:
vendor-floor buyouts (tagged *vendor*), auctions ending soon whose next bid is
under the resale price (*bid*) and conversions that pay (*craft*). Price dips
stay in their own view on purpose: a dip is a judgement about where a price
will go back to, not a sure thing. Each row keeps its own kind's columns and
tooltip, the list is ordered by ratio x profit across kinds (the Order button
and column headers work as usual), and each kind is filtered by the min profit
and max spend set in its own view, so the boxes are hidden here. Click a row
to open it; you buy or bid in the auction house.

## Commands

| Command | What it does |
|---|---|
| `/floor` | toggle the window |
| `/floor scan` | scan (the auction house must be open): gear first, then the rest, then bids if allowed |
| `/floor quick` | fast pass: weapons and armor only |
| `/floor stop` | stop the running scan and keep what it found (the Scan button reads Stop meanwhile) |
| `/floor snipe on` | watch the newest listings every few seconds; `off`, `<seconds>`, `sound` |
| `/floor loop 60` | rescan every 60 seconds while the auction house is open; `/floor loop off` |
| `/floor bidsonscan off` | stop the scan from also running the bid dump |
| `/floor market` | how fast prices are moving across the whole market |
| `/floor timing` | where the last scan's seconds went: the server's pace against Floor's own |
| `/floor min 5s` | only count items at least this far below vendor price per unit |
| `/floor total 1g` | only show checked items with at least this much total profit |
| `/floor limit 25` | how many candidates get their listings checked after a scan |
| `/floor auto on` | scan whenever the auction house opens |
| `/floor sort both` | order rows by both (ratio x profit), ratio, profit, unit, lowest, vendor or below |
| `/floor mode dips` | show price dips; also `all` (sure things), `floor`, `bids` and `crafts` |
| `/floor recipes` | recipes read from your professions; `/floor recipes clear` forgets them |
| `/floor bids` | read every auction for next bids below resale (allowed every 15 min) |
| `/floor bidtime short` | bids: only auctions ending within short (<30 min), medium, long or all |
| `/floor max 5g` | the most to spend on one item; 0 for no limit |
| `/floor dipall on` | dips consider everything, not just stackables, recipes and quest items; also the button in the dips view |
| `/floor recipemax 5` | a recipe with more copies than this at or near the dip price counts as adjusted |
| `/floor dip 60`, `dipdays 3`, `dipwindow 7`, `dipmin 1s` | price dip settings (see above) |
| `/floor history <item>` | print an item's price memory |
| `/floor ignore <link or id>` | hide an item; `/floor unignore`, `/floor ignored` |
| `/floor list` | print the last scan's top hits (works away from the auction house) |
| `/floor debug` | toggle debug messages |
| `/floor reset` | forget settings and the last scan (price memory is kept); `/floor reset history` clears the memory |

The **Min profit per unit** boxes (gold, silver, copper) set how far below the
reference price a unit must be before the item counts; press Enter or click
away to apply. Both this and **Max spend per item** are kept **per view**: the
vendor floor, price dips, bid snipes and crafts each remember their own, and
the boxes (and `/floor min`, `/floor max`) act on the view that is showing.
The Sure things view has none of its own; it takes each kind's settings from
that kind's view.

## Price dips

The **Price dips** button beside the title switches the window to items whose
lowest listing is at or under 60% of their **normal price**. Floor records a
daily low (and, for checked items, a volume-weighted median) for every item on
every scan; until it has three days of its own, it reads Auctionator's price
history for the item instead, so the mode works from the first scan if
Auctionator has been running for a while.

**The normal price is trend-aware.** A flat median of recent lows goes stale in
a market that is still settling: more players farm, the same items pile up,
prices slide. So Floor fits a trend through the last 7 days' price levels (on
a log scale) and reads it at today. The tooltip shows the trend in % per day,
the flat median for comparison, and how listed volume changed over the window.
"Falling" (red normal) now means the trend is steeper than -3% a day. Guards
keep the model honest: in a falling market the normal never exceeds the flat
median, in a rising one it never exceeds it by more than half, and it never
drops below 70% of the last three days' level, so a one-off step down is not
extrapolated into a cliff.

**Re-anchoring.** After an item's listings are checked, Floor compares today's
volume-weighted median with the normal. If most of today's volume sits more
than 10% below the normal, the market has moved further than the memory knew:
the normal is re-anchored to today's median (orange in the Normal column, with
the old value in the tooltip) and the dip is re-tested against it. If the
lowest listing is no longer 60% under the re-anchored normal, the row is hidden
as "market adjusted". That is the answer to "normal says 2s but there are tons
of auctions below it": either it is a dip against today's price, or it is not
a dip.

**Market drift.** At the end of each scan Floor computes the median per-item
trend across every item with three days of memory and reports it in chat and
in the dips footer, for example "-2.1%/day across 1,234 items (deflating)".
That is the pace of the whole economy's deflation; a dip in a market deflating
at that rate has to beat it to be worth holding.

In this mode the **Normal** column replaces Vendor and **Resale/unit** is the
normal price after the 5% auction house cut, minus the lowest listing. Profit
assumes you relist at the normal price; deposits are not counted. A normal
price shown in red means the last three days were all below it: the item may
simply be getting cheaper, and the "dip" may be the new price.

Dips only consider stackable items (trade goods, consumables and the like),
recipes and quest items: things that trade in volume and resell cleanly. Gear
is skipped, because one cheap piece of armor is rarely a market signal;
`/floor dipall on`, or the **Stackables only / Everything** button in the
dips view, includes everything; widening needs a new scan, narrowing again
hides gear at once. The decision rests on the item's class, which the client
knows for every item without loading it, so gear stays out even on a freshly
started client whose item cache is empty; an item whose stack size is still
unknown is shown until its listing check settles it. In this view the Ratio column shows
**Volume**, the units listed, and rows are ordered by it.

Recipes get one more test: if more than 5 copies sit at or near the dip
price (within 10% of the lowest), the market has adjusted and the row is
hidden as "market adjusted" rather than shown as a dip. `/floor recipemax 5`
changes the count.

**Volume by price.** Hover a checked item to see its price ladder: how many
units sit at each price on the first page of results, with the share of all
units at or below each price, and the volume-weighted median. For a dip,
Floor compares that median with the normal price: if most units are still
near normal, the cheap ones are outliers and the lowest price shows green
("market intact"); if most units are near the dip price, the market has moved
and it shows orange. The median is also remembered per day, so
`/floor history <item>` shows lows and medians side by side.

Settings: `/floor dip 60` (the percentage), `/floor dipdays 3` (days of memory
needed), `/floor dipwindow 7` (days in the median), `/floor dipmin 1s` (ignore
items whose normal price is lower). `/floor history <item>` prints what Floor
remembers about an item.

## Bid snipes

The **Bid snipes** button shows auctions whose *next bid* (the current bid
plus the increment, or the minimum bid when nobody has bid) is below the
resale price: the normal price after the 5% cut when Floor has enough memory
for the item, otherwise the vendor price (marked `v`). Commodities have no
bids, so this view is about gear, recipes and other single items.

Only auctions ending soon are shown: within 30 minutes by default, since a
bid on something with hours left just invites a counter-bid. `/floor bidtime
medium` (under 2 hours), `long` (under 12) or `all` widens the window.

**Scan bids** reads the auction house's full list of auctions, which the game
allows about every 15 minutes. Columns: **Bid/unit**, **Ref/unit**,
**Profit/unit**, **Ratio**, **Time left** (red when under 30 minutes),
**Profit** if the bid wins, **Next bid** (what you pay). Click a row to open
the item and place the bid yourself in the auction house. Remember that bids
can be outbid, the buyout may go first, and bid gold is tied up until the
auction ends.

## Snipe

A full scan takes minutes because the server paces every page, which is why
someone else gets the vendor buyouts first. **Snipe** (the button, or
`/floor snipe on`) does what the sniper tools do instead: every few seconds it
asks for one page only, sorted so the most recently posted auctions come
first, and runs those through the vendor-floor and price-dip tests. A new
listing below vendor price, or well below normal, is called out in chat with a
sound within seconds of being posted and appears at the top of its view tagged
"new". Gear is verified first (bid or buyout?) and only called out when a real
buyout is under vendor price. Buying is still your click: open the row and
buy in the auction house.

`/floor snipe 5` looks every 5 seconds (minimum 2), `/floor snipe sound`
toggles the sound, `/floor snipe off` stops. Sniping pauses while a scan runs
and stops when the auction house closes. Run a full scan first so the price
memory and the Crafts view are current, then leave Snipe on while you stand at
the auction house.

## Crafts

The **Crafts** button shows simple conversions where the reagents cost less
on the auction house than the product sells for: ore into bars, cloth into
bolts, scraps into leather, and anything your own professions can make.
Floor ships the classic smelting, tailoring and leatherworking conversions;
open a profession window once and it reads that profession's learned recipes
too (`/floor recipes` lists what it knows).

Costs use each reagent's lowest listing from the last scan, so treat them as
a ceiling: buying many units climbs the price ladder. Two routes are costed,
selling the product on the auction house after the 5% cut or selling it to a
vendor, and the better one is shown (`v` marks the vendor route). **Crafts**
is how many crafts today's listings could feed, limited by the scarcest
reagent; Max spend applies per craft.

## Max spend

The **Max spend per item** boxes set the most you are willing to pay for one
item. Items you cannot afford a single unit of are hidden, and for the rest
Floor counts only the cheapest units that fit the budget: **Buy / below** shows
units you can afford / units under the reference price, **Profit** is the
profit on the affordable units and **Cost** what they cost (yellow when the
budget cut the purchase short). Bids are all or nothing. 0 means no limit;
`/floor max 5g` does the same from chat.

## Good to know

- The vendor floor counts **buyouts only**. The auction house's browse price
  for a non-stackable item can be a bid rather than a buyout, so such items
  show as "unverified" until their listings are checked (they are checked
  first after a scan). An item whose check finds no buyout under vendor price
  is hidden.
- Vendor prices come from the game client's own item data, never from
  Auctionator. Auctionator's "vendor price" cache records what merchants
  charge for items they sell, which is a different number; when it knows
  one, the tooltip shows it as "A vendor sells this for", a warning that the
  item is vendor-sourced.
- Deposits and the 5% cut are the seller's problem. As the buyer you pay the
  buyout and nothing else, so the vendor price minus the buyout is your profit.
- The listing check only looks at the first page of results. If every result
  on that page is below vendor price, the row shows a `+` and the tooltip says
  more may exist.
- Scans are at least 30 seconds apart, and auction house requests are queued
  behind the server's throttle, so a scan is never faster than Blizzard allows.
  Blizzard publishes no numbers; the client itself says when the server will
  take the next request, and Floor asks it every frame and sends the moment it
  says yes. Listing checks keep up to three searches out at once, because the
  server paces the asking, not the answering. A search for an item whose key
  info the client has not cached yet is silently ignored by the server, so
  Floor loads the key info first; an empty answer is asked again once, and a
  search the server never answers is dropped after two tries. `/floor timing`
  prints all of this for the last scan, so a slow scan can be blamed on the
  right party.
- Clicking a row pauses Floor's own requests for a moment so the click's
  search is not dropped by the throttle.
- Forever bug, not Floor's: auction house searches can stop working after you
  post an auction. Logging out and back in fixes it.
- Settings, the last scan and the price memory live in
  `WTF/Account/<account>/SavedVariables/Floor.lua`. Memory is one short
  string per item and is kept for 30 days.
- `tests/harness.lua` runs the addon against fake auction data without the
  game: `just test`, or `luajit tests/harness.lua .` from the repository root.

## Developing

The repository root is the addon: `Floor.toc` and the Lua files load straight
into the game, and `tests/`, `justfile` and `dist/` are left out when it is
installed or packaged. The recipes need `just` and `luajit`
(`brew install just luajit`); `just` alone lists them.

| Recipe | What it does |
|---|---|
| `just test` | runs the harness, about two hundred checks in under a second |
| `just install` | runs the harness, then copies the addon into the game's AddOns folder; `/reload` in game picks it up. `WOW_ADDONS=/path/to/AddOns just install` for another install |
| `just package` | builds `dist/Floor-<version>.zip`, which unzips to a `Floor/` folder |
| `just release` | tags `v<version>` (the version in `Floor.toc`), pushes the tag and publishes a GitHub release with the zip |
| `just version` | prints the version from `Floor.toc` |

Bump `## Version:` in `Floor.toc` and `F.version` in `Core.lua` together before
a release.
