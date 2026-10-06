# Craftbook

An Ashita v4 addon for Final Fantasy XI (built for CatsEyeXI).

```

Shows which synthesis recipes you can make from what you own, and where every
ingredient is (Inventory, Mog Safe, Storage, Locker, Satchel, Sack, Case, Wardrobes).

Install
-------
1. Copy the whole "craftbook" folder into your Ashita "addons" folder, so you end up with:
       <Ashita>\addons\craftbook\craftbook.lua
       <Ashita>\addons\craftbook\recipes.lua
2. In game type:   /addon load craftbook
   To load it every time, add that line to <Ashita>\scripts\default.txt

Commands
--------
/cb  (or /craftbook)   show or hide the window
/cb rescan             rescan your bags now (it also rescans every 2 seconds while open)

Using it
--------
Find recipe   type the name of anything you want to craft. This searches every recipe,
              ignoring the dropdowns, and opens the recipe when the name matches exactly.
Dropdowns     what to show (ready / have everything / missing 1 or 2 / all), craft, level band.
Click a row   opens it: each ingredient with  have / need  and which bag it is in.
              Click it again to close it.
Drag          drag the window by any empty part of it. Drag the bottom-right corner to resize.

Colours
-------
Green   every ingredient is in your Inventory - ready to synth
Yellow  you own everything, but some of it is in another bag (the recipe shows which)
Red     something is missing ("need 2" = two ingredients short)

Tabs
----
Recipes   described above
Items     everything you own, where it is, and the recipes that use it (click one to open it)
Settings  theme and background opacity, which bags to search, which expansions to include,
          desynths, skill limit

Crystals are not counted as ingredients: a recipe shows which crystal it uses, but you are
not marked as missing anything if you have none.

Recipe data is from the LandSandBoat server database (the server CatsEyeXI is built on).
Recipes that CatsEyeXI has added or changed itself will not be reflected.
```

## Updating

Double-click `update.bat` in the addon folder to download the latest version from this repository, then type `/addon reload craftbook` in game.
