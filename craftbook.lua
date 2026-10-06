--[[
    craftbook - Ashita v4 addon

    Scans your inventory and every mog house / carried bag, then shows which
    synthesis recipes you can make, which ingredients you have, where each one
    is stored and what is still missing.

    Commands:
        /craftbook  or  /cb        toggle the window
        /cb rescan                 force a rescan of your bags

    Recipe data comes from the LandSandBoat server database (recipes.lua).
]]--

addon.name    = 'craftbook';
addon.author  = 'Happys';
addon.version = '2.1';
addon.desc    = 'Shows what you can craft from your inventory and mog house, and where every ingredient is.';
addon.link    = 'https://github.com/Happyfists/Craftbook';

require('common');
local imgui    = require('imgui');
local settings = require('settings');

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

-- Storage containers, in the order they are displayed. 'carried' bags are with you outside the mog house.
local BAGS = {
    { id = 0,  name = 'Inventory',   carried = true  },
    { id = 5,  name = 'Mog Satchel', carried = true  },
    { id = 6,  name = 'Mog Sack',    carried = true  },
    { id = 7,  name = 'Mog Case',    carried = true  },
    { id = 1,  name = 'Mog Safe',    carried = false },
    { id = 9,  name = 'Mog Safe 2',  carried = false },
    { id = 2,  name = 'Storage',     carried = false },
    { id = 4,  name = 'Mog Locker',  carried = false },
    { id = 8,  name = 'Wardrobe',    carried = true  },
    { id = 10, name = 'Wardrobe 2',  carried = true  },
    { id = 11, name = 'Wardrobe 3',  carried = true  },
    { id = 12, name = 'Wardrobe 4',  carried = true  },
    { id = 13, name = 'Wardrobe 5',  carried = true  },
    { id = 14, name = 'Wardrobe 6',  carried = true  },
    { id = 15, name = 'Wardrobe 7',  carried = true  },
    { id = 16, name = 'Wardrobe 8',  carried = true  },
};

local CRAFTS = { 'Woodworking', 'Smithing', 'Goldsmithing', 'Clothcraft', 'Leathercraft', 'Bonecraft', 'Alchemy', 'Cooking' };
local CRAFT_SHORT = { 'Wood', 'Smith', 'Gold', 'Cloth', 'Leather', 'Bone', 'Alch', 'Cook' };

local ERAS = {
    { key = 'BASE',    name = 'Original game' },
    { key = 'ROTZ',    name = 'Rise of the Zilart' },
    { key = 'COP',     name = 'Chains of Promathia' },
    { key = 'TOAU',    name = 'Treasures of Aht Urhgan' },
    { key = 'WOTG',    name = 'Wings of the Goddess' },
    { key = 'ABYSSEA', name = 'Abyssea' },
    { key = 'SOA',     name = 'Seekers of Adoulin' },
    { key = 'ROV',     name = 'Rhapsodies of Vana\'diel' },
    { key = 'TVR',     name = 'The Voracious Resurgence' },
};

local SHOW_MODES = {
    'Ready now',
    'Have everything',
    'Missing 1',
    'Missing up to 2',
    'All recipes',
};

-- Level bands for the level filter: 0-10, 11-20, ... 111-120.
local LEVELS = {};
for i = 1, 12 do
    LEVELS[i] = string.format('Lv %d-%d', (i == 1) and 0 or ((i - 1) * 10 + 1), i * 10);
end

local COLOR = {
    ready   = { 0.45, 1.00, 0.45, 1.0 },
    fetch   = { 1.00, 0.85, 0.30, 1.0 },
    missing = { 1.00, 0.45, 0.45, 1.0 },
    dim     = { 0.65, 0.65, 0.65, 1.0 },
    head    = { 0.60, 0.80, 1.00, 1.0 },
};

local default_settings = T{
    visible      = true,
    show_mode    = 2,
    craft        = 0,
    level        = 0,
    desynth      = false,
    hide_no_ki   = true,
    skill_limit  = false,
    skill_margin = 10,
    mats_only    = true,
    theme        = 1,
    opacity      = 94,
    bags = T{
        b0 = true, b1 = true, b2 = true, b4 = true, b5 = true, b6 = true, b7 = true, b8 = true, b9 = true,
        b10 = true, b11 = true, b12 = true, b13 = true, b14 = true, b15 = true, b16 = true,
    },
    eras = T{
        BASE = true, ROTZ = true, COP = true, TOAU = true, WOTG = true,
        ABYSSEA = false, SOA = false, ROV = false, TVR = false,
    },
};

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local cfg = default_settings;

local recipes   = {};   -- all recipes
local uses      = {};   -- item id -> list of recipes that use it as an ingredient
local makes     = {};   -- item id -> list of recipes that produce it
local have      = {};   -- item id -> { total = n, bags = { [bagId] = n } }
local owned     = {};   -- sorted list of owned item ids
local skills    = {};   -- craft index -> your skill level (nil if unknown)
local names     = {};   -- item name cache

local state = {
    open          = { true },
    search        = { '' },
    item_search   = { '' },
    filtered      = {},
    items         = {},
    tab           = 1,     -- 1 recipes, 2 items, 3 settings
    extra_h       = {},    -- measured height of the expanded row per list
    sel_idx       = nil,
    item_idx      = nil,
    selected      = nil,   -- selected recipe (Recipes tab)
    selected_item = nil,   -- selected item id (Items tab)
    item_recipe   = nil,   -- recipe picked inside the Items tab
    dirty         = true,
    items_dirty   = true,
    last_scan     = -100,
    last_filter   = nil,
    last_ifilter  = nil,
    search_ready  = false,
    logged_in     = false,
};

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function flag(name)
    local v = _G[name];
    if type(v) == 'number' then return v; end
    return 0;
end

local function msg(text)
    print(string.format('\30\81[craftbook]\30\01 %s', text));
end

local function item_name(id)
    local n = names[id];
    if n ~= nil then return n; end
    local ok, res = pcall(function ()
        return AshitaCore:GetResourceManager():GetItemById(id);
    end);
    if ok and res ~= nil and res.Name ~= nil and res.Name[1] ~= nil and #res.Name[1] > 0 then
        n = res.Name[1];
    else
        n = string.format('Item #%d', id);
    end
    names[id] = n;
    return n;
end

local function keyitem_name(id)
    local ok, s = pcall(function ()
        return AshitaCore:GetResourceManager():GetString('keyitems.names', id);
    end);
    if ok and type(s) == 'string' and #s > 0 then return s; end
    return string.format('Key item #%d', id);
end

local function has_keyitem(id)
    local ok, r = pcall(function ()
        return AshitaCore:GetMemoryManager():GetPlayer():HasKeyItem(id);
    end);
    if ok then return r == true; end
    return nil; -- unknown
end

local function bag_enabled(id)
    return cfg.bags['b' .. id] ~= false;
end

local function split_numbers(s)
    local t = {};
    for n in s:gmatch('%d+') do t[#t + 1] = tonumber(n); end
    return t;
end

----------------------------------------------------------------------------------------------------
-- Recipe loading
----------------------------------------------------------------------------------------------------

local function load_recipes()
    local raw = require('recipes');
    for line in raw:gmatch('[^\r\n]+') do
        local id, des, ki, sk, cry, ings, res, qty, name, tag =
            line:match('^(%d+)|(%d)|(%d+)|([%d,]+)|(%d+)|([%d,]*)|([%d,]+)|([%d,]+)|(.-)|(%u*)$');
        if id ~= nil then
            local r = {
                id      = tonumber(id),
                desynth = des == '1',
                ki      = tonumber(ki),
                skills  = split_numbers(sk),
                crystal = tonumber(cry),
                results = split_numbers(res),
                qty     = split_numbers(qty),
                name    = name,
                lname   = name:lower(),
                era     = (tag == '' and 'BASE') or tag,
                need    = {},
                craft   = 1,
                level   = 0,
                status  = 3,
            };

            -- Main craft is the one with the highest requirement.
            for i = 1, 8 do
                local lv = r.skills[i] or 0;
                if lv > r.level then r.level = lv; r.craft = i; end
            end

            -- Collapse duplicate ingredients into { id, count } pairs. Crystals are not counted as ingredients.
            local counts, order = {}, {};
            local function add(item)
                if item == nil or item == 0 then return; end
                if counts[item] == nil then counts[item] = 0; order[#order + 1] = item; end
                counts[item] = counts[item] + 1;
            end
            for _, item in ipairs(split_numbers(ings)) do add(item); end
            for _, item in ipairs(order) do
                r.need[#r.need + 1] = { id = item, count = counts[item] };
                uses[item] = uses[item] or {};
                table.insert(uses[item], r);
            end

            if not r.desynth then
                local seen = {};
                for _, item in ipairs(r.results) do
                    if item ~= 0 and not seen[item] then
                        seen[item] = true;
                        makes[item] = makes[item] or {};
                        table.insert(makes[item], r);
                    end
                end
            end

            recipes[#recipes + 1] = r;
        end
    end
end

-- Builds the text each recipe is searched by (its name plus its ingredient names).
local function build_search_index()
    for _, r in ipairs(recipes) do
        local parts = { r.lname };
        for _, n in ipairs(r.need) do parts[#parts + 1] = item_name(n.id):lower(); end
        r.search = table.concat(parts, '\n');
    end
    state.search_ready = true;
end

----------------------------------------------------------------------------------------------------
-- Scanning and evaluation
----------------------------------------------------------------------------------------------------

local function scan_bags()
    local ok, inv = pcall(function () return AshitaCore:GetMemoryManager():GetInventory(); end);
    if not ok or inv == nil then return false; end

    local found, list = {}, {};
    local any = false;
    for _, bag in ipairs(BAGS) do
        if bag_enabled(bag.id) then
            for slot = 0, 80 do
                local item = inv:GetContainerItem(bag.id, slot);
                if item ~= nil and item.Id ~= nil and item.Id ~= 0 and item.Id ~= 65535 and (item.Count or 0) > 0 then
                    local h = found[item.Id];
                    if h == nil then
                        h = { total = 0, bags = {} };
                        found[item.Id] = h;
                        list[#list + 1] = item.Id;
                    end
                    h.total = h.total + item.Count;
                    h.bags[bag.id] = (h.bags[bag.id] or 0) + item.Count;
                    any = true;
                end
            end
        end
    end

    have, owned = found, list;
    state.logged_in = any;
    return true;
end

local function read_skills()
    for i = 1, 8 do
        local ok, v = pcall(function ()
            return AshitaCore:GetMemoryManager():GetPlayer():GetCraftSkill(i):GetSkill();
        end);
        if ok and type(v) == 'number' then skills[i] = v; else skills[i] = nil; end
    end
end

local function evaluate(r)
    local kinds, fetch = 0, 0;
    local times = math.huge;
    for _, n in ipairs(r.need) do
        local h = have[n.id];
        local total = (h and h.total) or 0;
        local inbag = (h and h.bags[0]) or 0;
        if total < n.count then
            kinds = kinds + 1;
        elseif inbag < n.count then
            fetch = fetch + 1;
        end
        times = math.min(times, math.floor(total / n.count));
    end
    r.missing = kinds;
    r.times   = (times == math.huge) and 0 or times;
    r.status  = (kinds > 0 and 3) or (fetch > 0 and 2) or 1;

    if r.ki ~= 0 then
        local k = has_keyitem(r.ki);
        r.ki_missing = (k == false);
    else
        r.ki_missing = false;
    end

    local gap = nil;
    for i = 1, 8 do
        local req = r.skills[i] or 0;
        if req > 0 and skills[i] ~= nil then
            local g = req - skills[i];
            if gap == nil or g > gap then gap = g; end
        end
    end
    r.gap = gap; -- nil when your skill could not be read
end

local function refresh()
    if not scan_bags() then return; end
    read_skills();
    for _, r in ipairs(recipes) do evaluate(r); end
    state.dirty = true;
    state.items_dirty = true;
end

----------------------------------------------------------------------------------------------------
-- Filtering
----------------------------------------------------------------------------------------------------

local function passes(r, text)
    if not cfg.eras[r.era] then return false; end
    if r.desynth and not cfg.desynth then return false; end

    -- Typing in the search box looks through every recipe, whatever the dropdowns say,
    -- so you can look up something you cannot make yet and see what it needs.
    if text ~= '' then
        return r.search:find(text, 1, true) ~= nil;
    end

    if cfg.craft ~= 0 and (r.skills[cfg.craft] or 0) == 0 then return false; end
    if cfg.level ~= 0 then
        -- With a craft picked, use that craft's requirement; otherwise the recipe's main level.
        local lv = (cfg.craft ~= 0 and r.skills[cfg.craft]) or r.level;
        local lo = (cfg.level == 1) and 0 or ((cfg.level - 1) * 10 + 1);
        if lv < lo or lv > cfg.level * 10 then return false; end
    end

    local mode = cfg.show_mode;
    if mode == 1 and r.status ~= 1 then return false; end
    if mode == 2 and r.status > 2 then return false; end
    if mode == 3 and r.missing > 1 then return false; end
    if mode == 4 and r.missing > 2 then return false; end
    -- In the "missing" views, skip recipes you own nothing for.
    if (mode == 3 or mode == 4) and r.missing >= #r.need then return false; end

    if cfg.hide_no_ki and mode ~= 5 and r.ki_missing then return false; end
    if cfg.skill_limit and r.gap ~= nil and r.gap > cfg.skill_margin then return false; end
    return true;
end

local function rebuild_filtered()
    local text = (state.search[1] or ''):lower();
    if text ~= '' and not state.search_ready then build_search_index(); end
    if not state.search_ready then
        -- Cheap fallback until the full index is needed.
        for _, r in ipairs(recipes) do r.search = r.search or r.lname; end
    end

    local out = {};
    for _, r in ipairs(recipes) do
        if passes(r, text) then out[#out + 1] = r; end
    end
    -- When searching, recipes whose own name matches come before ones that only use the item.
    if text ~= '' then
        for _, r in ipairs(out) do
            r.rank = (r.lname == text and 0) or (r.lname:find(text, 1, true) and 1) or 2;
        end
    else
        for _, r in ipairs(out) do r.rank = 0; end
    end
    table.sort(out, function (a, b)
        if a.rank ~= b.rank then return a.rank < b.rank; end
        if a.status ~= b.status then return a.status < b.status; end
        if a.missing ~= b.missing then return a.missing < b.missing; end
        if a.craft ~= b.craft then return a.craft < b.craft; end
        if a.level ~= b.level then return a.level < b.level; end
        if a.lname ~= b.lname then return a.lname < b.lname; end
        return a.id < b.id;
    end);
    state.filtered = out;
    state.dirty = false;
end

local function rebuild_items()
    local text = (state.item_search[1] or ''):lower();
    local out = {};
    for _, id in ipairs(owned) do
        local used = uses[id];
        if (not cfg.mats_only) or used ~= nil then
            local name = item_name(id);
            if text == '' or name:lower():find(text, 1, true) then
                out[#out + 1] = { id = id, name = name, lname = name:lower(), total = have[id].total, uses = (used and #used) or 0 };
            end
        end
    end
    table.sort(out, function (a, b)
        if a.lname ~= b.lname then return a.lname < b.lname; end
        return a.id < b.id;
    end);
    state.items = out;
    state.items_dirty = false;
end

----------------------------------------------------------------------------------------------------
-- Themes
----------------------------------------------------------------------------------------------------

-- Each theme is a small palette; the window style is built from it in push_theme().
local THEMES = {
    { name = 'Vana blue',     bg = { 0.043, 0.102, 0.227 }, panel = { 0.043, 0.102, 0.227 }, frame = { 0.090, 0.188, 0.416 }, accent = { 0.50, 0.85, 1.00 }, text = { 0.95, 0.96, 1.00 }, border = { 0.79, 0.84, 0.95 }, flat = true },
    { name = 'Midnight gold', bg = { 0.06, 0.07, 0.12 }, panel = { 0.10, 0.12, 0.19 }, frame = { 0.16, 0.19, 0.30 }, accent = { 0.86, 0.68, 0.28 }, text = { 0.93, 0.91, 0.84 } },
    { name = 'Forest',        bg = { 0.06, 0.10, 0.08 }, panel = { 0.09, 0.15, 0.12 }, frame = { 0.14, 0.24, 0.18 }, accent = { 0.55, 0.82, 0.45 }, text = { 0.90, 0.94, 0.88 } },
    { name = 'Crimson',       bg = { 0.10, 0.06, 0.07 }, panel = { 0.16, 0.09, 0.10 }, frame = { 0.27, 0.13, 0.15 }, accent = { 0.92, 0.42, 0.38 }, text = { 0.95, 0.90, 0.88 } },
    { name = 'Steel',         bg = { 0.09, 0.10, 0.11 }, panel = { 0.13, 0.15, 0.17 }, frame = { 0.21, 0.24, 0.28 }, accent = { 0.45, 0.72, 0.95 }, text = { 0.92, 0.94, 0.96 } },
    { name = 'Parchment',     bg = { 0.90, 0.85, 0.74 }, panel = { 0.95, 0.91, 0.82 }, frame = { 0.82, 0.75, 0.62 }, accent = { 0.55, 0.30, 0.12 }, text = { 0.18, 0.13, 0.08 }, light = true },
};
local THEME_NAMES = {};
for i, t in ipairs(THEMES) do THEME_NAMES[i] = t.name; end

local function rgba(c, a, mul)
    mul = mul or 1;
    return { math.min(1, c[1] * mul), math.min(1, c[2] * mul), math.min(1, c[3] * mul), a or 1 };
end

local function mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t };
end

-- Pushes the theme's colours and shape settings. Returns how many of each were pushed so they can be popped.
local function push_theme()
    local idx = cfg.theme;
    if idx == 0 then return 0, 0; end -- plain Ashita look
    local t = THEMES[idx] or THEMES[1];
    local alpha = cfg.opacity / 100;
    local colors, vars = 0, 0;

    local function col(name, value)
        local id = _G[name];
        if type(id) == 'number' then imgui.PushStyleColor(id, value); colors = colors + 1; end
    end
    local function var(name, value)
        local id = _G[name];
        if type(id) == 'number' then imgui.PushStyleVar(id, value); vars = vars + 1; end
    end

    local hover  = mix(t.frame, t.accent, 0.35);
    local active = mix(t.frame, t.accent, 0.60);

    col('ImGuiCol_Text',                 rgba(t.text));
    col('ImGuiCol_TextDisabled',         rgba(t.text, 0.55));
    col('ImGuiCol_WindowBg',             rgba(t.bg, alpha));
    col('ImGuiCol_ChildBg',              rgba(t.panel, t.flat and 0 or math.min(1, alpha + 0.05)));
    col('ImGuiCol_PopupBg',              rgba(t.panel, 0.98));
    col('ImGuiCol_Border',               t.border and rgba(t.border, 0.95) or rgba(t.accent, 0.45));
    col('ImGuiCol_TitleBg',              rgba(t.frame, 1));
    col('ImGuiCol_TitleBgActive',        rgba(active, 1));
    col('ImGuiCol_TitleBgCollapsed',     rgba(t.frame, 0.80));
    col('ImGuiCol_FrameBg',              rgba(t.frame, 0.90));
    col('ImGuiCol_FrameBgHovered',       rgba(hover, 0.95));
    col('ImGuiCol_FrameBgActive',        rgba(active, 1));
    col('ImGuiCol_Button',               rgba(t.frame, 1));
    col('ImGuiCol_ButtonHovered',        rgba(hover, 1));
    col('ImGuiCol_ButtonActive',         rgba(active, 1));
    col('ImGuiCol_Header',               rgba(active, 0.55));
    col('ImGuiCol_HeaderHovered',        rgba(hover, 0.70));
    col('ImGuiCol_HeaderActive',         rgba(active, 0.85));
    col('ImGuiCol_Tab',                  rgba(t.frame, 0.90));
    col('ImGuiCol_TabHovered',           rgba(hover, 1));
    col('ImGuiCol_TabActive',            rgba(active, 1));
    col('ImGuiCol_Separator',            t.border and rgba(mix(t.frame, t.border, 0.35), 1) or rgba(t.accent, 0.35));
    col('ImGuiCol_CheckMark',            rgba(t.accent));
    col('ImGuiCol_SliderGrab',           rgba(t.accent, 0.85));
    col('ImGuiCol_SliderGrabActive',     rgba(t.accent));
    col('ImGuiCol_ScrollbarBg',          rgba(t.bg, 0.40));
    col('ImGuiCol_ScrollbarGrab',        rgba(hover, 0.90));
    col('ImGuiCol_ScrollbarGrabHovered', rgba(active, 1));
    col('ImGuiCol_ScrollbarGrabActive',  rgba(t.accent, 1));
    col('ImGuiCol_ResizeGrip',           rgba(t.accent, 0.30));
    col('ImGuiCol_ResizeGripHovered',    rgba(t.accent, 0.60));
    col('ImGuiCol_ResizeGripActive',     rgba(t.accent, 0.90));
    col('ImGuiCol_TableHeaderBg',        rgba(t.frame, 1));
    col('ImGuiCol_TableBorderLight',     rgba(t.accent, 0.20));
    col('ImGuiCol_TableBorderStrong',    rgba(t.accent, 0.35));
    col('ImGuiCol_TableRowBg',           rgba(t.panel, 0));
    col('ImGuiCol_TableRowBgAlt',        rgba(t.frame, 0.35));

    var('ImGuiStyleVar_WindowRounding',    8);
    var('ImGuiStyleVar_ChildRounding',     8);
    var('ImGuiStyleVar_FrameRounding',     6);
    var('ImGuiStyleVar_PopupRounding',     6);
    var('ImGuiStyleVar_ScrollbarRounding', 8);
    var('ImGuiStyleVar_GrabRounding',      6);
    var('ImGuiStyleVar_TabRounding',       6);
    var('ImGuiStyleVar_WindowBorderSize',  t.border and 2 or 1);
    var('ImGuiStyleVar_ChildBorderSize',   1);
    var('ImGuiStyleVar_WindowPadding',     { 12, 10 });
    var('ImGuiStyleVar_FramePadding',      { 6, 3 });
    var('ImGuiStyleVar_ItemSpacing',       { 8, 4 });

    -- Status and heading colours that stay readable on this theme.
    if t.light then
        COLOR.ready, COLOR.fetch, COLOR.missing = { 0.10, 0.48, 0.14, 1 }, { 0.66, 0.42, 0.00, 1 }, { 0.72, 0.12, 0.10, 1 };
        COLOR.dim = { 0.40, 0.34, 0.26, 1 };
    else
        COLOR.ready, COLOR.fetch, COLOR.missing = { 0.45, 1.00, 0.45, 1 }, { 1.00, 0.85, 0.30, 1 }, { 1.00, 0.45, 0.45, 1 };
        COLOR.dim = rgba(t.text, 0.60);
    end
    COLOR.head = rgba(t.accent);
    return colors, vars;
end

local function pop_theme(colors, vars)
    if colors > 0 then imgui.PopStyleColor(colors); end
    if vars > 0 then imgui.PopStyleVar(vars); end
    if cfg.theme == 0 then
        COLOR.ready, COLOR.fetch, COLOR.missing = { 0.45, 1.00, 0.45, 1 }, { 1.00, 0.85, 0.30, 1 }, { 1.00, 0.45, 0.45, 1 };
        COLOR.dim, COLOR.head = { 0.65, 0.65, 0.65, 1 }, { 0.60, 0.80, 1.00, 1 };
    end
end

----------------------------------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------------------------------

local function status_color(r)
    if r.status == 1 then return COLOR.ready; end
    if r.status == 2 then return COLOR.fetch; end
    return COLOR.missing;
end

local function where_text(id)
    local h = have[id];
    if h == nil then return 'none'; end
    local parts = {};
    for _, bag in ipairs(BAGS) do
        local n = h.bags[bag.id];
        if n ~= nil then parts[#parts + 1] = string.format('%s x%d', bag.name, n); end
    end
    return table.concat(parts, ', ');
end

local function checkbox(label, value)
    local t = { value == true };
    imgui.Checkbox(label, t);
    return t[1] == true, (t[1] == true) ~= (value == true);
end

local function combo(label, current, options, first)
    local changed = false;
    local preview = options[current] or first or '';
    if imgui.BeginCombo(label, preview) then
        if first ~= nil then
            if imgui.Selectable(first, current == 0) then current = 0; changed = true; end
        end
        for i, name in ipairs(options) do
            if imgui.Selectable(name, current == i) then current = i; changed = true; end
        end
        imgui.EndCombo();
    end
    return current, changed;
end

-- Width of the window (or child) currently being drawn.
local function window_width(fallback)
    local ok, w = pcall(imgui.GetWindowWidth);
    if ok and type(w) == 'number' and w > 0 then return w; end
    return fallback;
end

-- Draws a long list where one row (sel) can be expanded with extra lines under it.
-- Only the rows on screen are drawn, so thousands of recipes stay cheap.
local function expanding_list(key, count, sel, draw_row, draw_extra)
    if count == 0 then return; end
    local ok, h, scroll, height, base = pcall(function ()
        return imgui.GetTextLineHeightWithSpacing(), imgui.GetScrollY(), imgui.GetWindowHeight(), imgui.GetCursorPosY();
    end);
    if not ok or type(h) ~= 'number' or type(scroll) ~= 'number' or type(height) ~= 'number' or type(base) ~= 'number' or h <= 0 then
        -- Could not measure: draw a capped list without clipping.
        for i = 1, math.min(count, 300) do
            draw_row(i);
            if i == sel then draw_extra(i); end
        end
        return;
    end

    local extra = (sel ~= nil and state.extra_h[key]) or 0;
    local first;
    if sel == nil or scroll < sel * h then
        first = math.floor(scroll / h);
    elseif scroll < sel * h + extra then
        first = sel;
    else
        first = math.floor((scroll - extra) / h);
    end
    first = math.max(1, math.min(count, first));
    local last = math.min(count, first + math.ceil(height / h) + 2);

    imgui.SetCursorPosY(base + (first - 1) * h + ((sel ~= nil and first > sel) and extra or 0));
    for i = first, last do
        draw_row(i);
        if i == sel then
            local y0 = imgui.GetCursorPosY();
            draw_extra(i);
            local y1 = imgui.GetCursorPosY();
            if type(y0) == 'number' and type(y1) == 'number' then
                extra = math.max(0, y1 - y0);
                state.extra_h[key] = extra;
            end
        end
    end
    imgui.SetCursorPosY(base + count * h + ((sel ~= nil) and extra or 0));
    imgui.Dummy({ 1, 0 });
end

local function status_tail(r)
    if r.status == 3 then return string.format('need %d', r.missing); end
    return string.format('x%d', r.times);
end

-- One compact row: status dot, name, craft and level, how many you can make.
local function draw_recipe_row(r, selected, w, id_prefix)
    local c = status_color(r);
    imgui.PushStyleColor(flag('ImGuiCol_Text'), c);
    imgui.Bullet();
    imgui.PopStyleColor(1);
    imgui.SameLine();
    local label = string.format('%s%s##%s%d', r.desynth and 'Desynth ' or '', r.name, id_prefix, r.id);
    local clicked = imgui.Selectable(label, selected);
    imgui.SameLine(w - 170);
    imgui.TextColored(COLOR.dim, string.format('%s %d', CRAFT_SHORT[r.craft], r.level));
    imgui.SameLine(w - 78);
    imgui.TextColored(c, status_tail(r));
    return clicked;
end

-- The lines shown under an expanded recipe.
local function draw_recipe_extra(r, w)
    imgui.Indent(20);

    for _, n in ipairs(r.need) do
        local h = have[n.id];
        local total = (h and h.total) or 0;
        local inbag = (h and h.bags[0]) or 0;
        local c = (total < n.count and COLOR.missing) or (inbag < n.count and COLOR.fetch) or COLOR.ready;
        imgui.TextColored(c, item_name(n.id));
        imgui.SameLine(math.max(150, w * 0.36));
        imgui.Text(string.format('%d / %d', total, n.count));
        imgui.SameLine(math.max(205, w * 0.48));
        if total > 0 then
            imgui.PushStyleColor(flag('ImGuiCol_Text'), (inbag < n.count) and c or COLOR.dim);
            imgui.TextWrapped(where_text(n.id));
            imgui.PopStyleColor(1);
        else
            -- Point out when a missing ingredient is itself something you could craft.
            local hint = 'you have none';
            local sub = makes[n.id];
            if sub ~= nil then
                local best = nil;
                for _, s in ipairs(sub) do
                    if cfg.eras[s.era] and (best == nil or s.status < best.status) then best = s; end
                end
                if best ~= nil then
                    local st = (best.status == 1 and 'ready') or (best.status == 2 and 'have mats') or string.format('need %d', best.missing);
                    hint = string.format('none - craft it: %s %d (%s)', CRAFT_SHORT[best.craft], best.level, st);
                end
            end
            imgui.PushStyleColor(flag('ImGuiCol_Text'), COLOR.dim);
            imgui.TextWrapped(hint);
            imgui.PopStyleColor(1);
        end
    end

    -- Skill requirements
    for i = 1, 8 do
        local req = r.skills[i] or 0;
        if req > 0 then
            local mine = skills[i];
            if mine == nil then
                imgui.TextColored(COLOR.dim, string.format('%s %d', CRAFTS[i], req));
            else
                local c = (mine >= req and COLOR.dim) or (mine + 10 >= req and COLOR.fetch) or COLOR.missing;
                imgui.TextColored(c, string.format('%s %d - your skill %d', CRAFTS[i], req, mine));
            end
        end
    end

    if r.ki ~= 0 then
        local k = has_keyitem(r.ki);
        local c = (k == true and COLOR.ready) or (k == false and COLOR.missing) or COLOR.dim;
        local note = (k == true and 'you have it') or (k == false and 'you do not have it') or 'could not check';
        imgui.PushStyleColor(flag('ImGuiCol_Text'), c);
        imgui.TextWrapped(string.format('Key item: %s (%s)', keyitem_name(r.ki), note));
        imgui.PopStyleColor(1);
    end

    local q = r.qty;
    local parts = {};
    if r.crystal ~= 0 then parts[#parts + 1] = item_name(r.crystal); end
    parts[#parts + 1] = string.format('makes %s x%d', item_name(r.results[1] or 0), q[1] or 1);
    for i = 2, 4 do
        local id = r.results[i] or 0;
        if id ~= 0 and (id ~= r.results[1] or (q[i] or 1) ~= (q[1] or 1)) then
            parts[#parts + 1] = string.format('HQ%d %s x%d', i - 1, item_name(id), q[i] or 1);
        end
    end
    imgui.PushStyleColor(flag('ImGuiCol_Text'), COLOR.dim);
    imgui.TextWrapped(table.concat(parts, ' - '));
    imgui.PopStyleColor(1);

    imgui.Unindent(20);
    imgui.Separator();
end

local function index_of(list, value)
    if value == nil then return nil; end
    for i, v in ipairs(list) do
        if v == value then return i; end
    end
    return nil;
end

local function draw_recipes_tab(w)
    local changed, c;

    -- Look up anything you want to craft.
    imgui.PushItemWidth(math.max(120, w - 24 - 96));
    imgui.InputText('Find recipe', state.search, 64);
    imgui.PopItemWidth();

    imgui.PushItemWidth(math.max(120, w - 24 - 112 - 96 - 16));
    cfg.show_mode, c = combo('##show', cfg.show_mode, SHOW_MODES); changed = c;
    imgui.PopItemWidth();
    imgui.SameLine();
    imgui.PushItemWidth(112);
    cfg.craft, c = combo('##craft', cfg.craft, CRAFTS, 'All crafts'); changed = changed or c;
    imgui.PopItemWidth();
    imgui.SameLine();
    imgui.PushItemWidth(96);
    cfg.level, c = combo('##level', cfg.level, LEVELS, 'All levels'); changed = changed or c;
    imgui.PopItemWidth();

    if changed then settings.save(); state.dirty = true; end
    if state.search[1] ~= state.last_filter then
        state.last_filter = state.search[1];
        state.dirty = true;
        state.autoselect = true;
    end
    if state.dirty then
        rebuild_filtered();
        -- After typing, open the recipe straight away when there is an exact or single match.
        if state.autoselect then
            state.autoselect = false;
            local first = state.filtered[1];
            if (state.search[1] or '') ~= '' and first ~= nil and (#state.filtered == 1 or first.rank == 0) then
                state.selected = first;
            end
        end
        state.sel_idx = index_of(state.filtered, state.selected);
    end

    imgui.Separator();

    imgui.BeginChild('##recipe_list', { 0, -26 }, false);
    local list = state.filtered;
    local cw = window_width(w - 24);
    if #list == 0 then
        if not state.logged_in then
            imgui.TextColored(COLOR.dim, 'No items found yet. Log in to a character.');
        else
            imgui.TextColored(COLOR.dim, (state.search[1] or '') ~= '' and 'No recipe with that name.' or 'Nothing matches. Try another filter.');
        end
    end
    expanding_list('recipes', #list, state.sel_idx, function (i)
        local r = list[i];
        if draw_recipe_row(r, state.selected == r, cw, 'r') then
            if state.selected == r then
                state.selected, state.sel_idx = nil, nil;
            else
                state.selected, state.sel_idx = r, i;
            end
        end
    end, function (i)
        draw_recipe_extra(list[i], cw);
    end);
    imgui.EndChild();

    imgui.Separator();
    imgui.TextColored(COLOR.dim, string.format((state.search[1] or '') ~= '' and '%d found' or '%d recipe(s)', #state.filtered));
    imgui.SameLine();
    imgui.TextColored(COLOR.ready, 'ready');
    imgui.SameLine();
    imgui.TextColored(COLOR.fetch, 'in another bag');
    imgui.SameLine();
    imgui.TextColored(COLOR.missing, 'missing');
end

local function draw_items_tab(w)
    local c;
    imgui.PushItemWidth(math.max(120, w - 24 - 60));
    imgui.InputText('Search', state.item_search, 64);
    imgui.PopItemWidth();
    cfg.mats_only, c = checkbox('Only crafting materials', cfg.mats_only);
    if c then settings.save(); state.items_dirty = true; end

    if state.item_search[1] ~= state.last_ifilter then
        state.last_ifilter = state.item_search[1];
        state.items_dirty = true;
    end
    if state.items_dirty then
        rebuild_items();
        state.item_idx = nil;
        for i, it in ipairs(state.items) do
            if it.id == state.selected_item then state.item_idx = i; break; end
        end
    end

    imgui.Separator();

    imgui.BeginChild('##item_list', { 0, -26 }, false);
    local list = state.items;
    local cw = window_width(w - 24);
    if #list == 0 then
        imgui.TextColored(COLOR.dim, 'No items to show.');
    end
    local jump = nil;
    expanding_list('items', #list, state.item_idx, function (i)
        local it = list[i];
        if imgui.Selectable(string.format('%s##i%d', it.name, it.id), state.selected_item == it.id) then
            if state.selected_item == it.id then
                state.selected_item, state.item_idx = nil, nil;
            else
                state.selected_item, state.item_idx = it.id, i;
            end
        end
        imgui.SameLine(cw - 170);
        imgui.TextColored(COLOR.dim, string.format('%d recipes', it.uses));
        imgui.SameLine(cw - 78);
        imgui.Text(string.format('x%d', it.total));
    end, function (i)
        local id = list[i].id;
        imgui.Indent(20);
        imgui.PushStyleColor(flag('ImGuiCol_Text'), COLOR.dim);
        imgui.TextWrapped(where_text(id));
        imgui.PopStyleColor(1);

        local used = {};
        for _, r in ipairs(uses[id] or {}) do
            if cfg.eras[r.era] and (cfg.desynth or not r.desynth) then used[#used + 1] = r; end
        end
        table.sort(used, function (a, b)
            if a.status ~= b.status then return a.status < b.status; end
            if a.missing ~= b.missing then return a.missing < b.missing; end
            if a.level ~= b.level then return a.level < b.level; end
            return a.id < b.id;
        end);
        for n, r in ipairs(used) do
            if n > 60 then
                imgui.TextColored(COLOR.dim, string.format('... and %d more', #used - 60));
                break;
            end
            if draw_recipe_row(r, false, cw, 'u') then jump = r; end
        end
        imgui.Unindent(20);
        imgui.Separator();
    end);
    imgui.EndChild();

    imgui.Separator();
    imgui.TextColored(COLOR.dim, string.format('%d item(s) - click a recipe under an item to open it', #state.items));

    -- Clicking a recipe under an item opens it on the Recipes tab.
    if jump ~= nil then
        state.tab = 1;
        state.search[1] = jump.name;
        cfg.show_mode = #SHOW_MODES;
        cfg.craft, cfg.level = 0, 0;
        state.selected = jump;
        state.dirty = true;
    end
end

local function draw_settings_tab()
    local changed, c = false, false;

    imgui.TextColored(COLOR.head, 'Look');
    imgui.PushItemWidth(180);
    cfg.theme, c = combo('Theme', cfg.theme, THEME_NAMES, 'Plain (Ashita default)'); changed = changed or c;
    if cfg.theme ~= 0 then
        local o = { cfg.opacity };
        imgui.SliderInt('Background opacity', o, 30, 100);
        if o[1] ~= cfg.opacity then cfg.opacity = o[1]; changed = true; end
    end
    imgui.PopItemWidth();

    imgui.Separator();
    imgui.TextColored(COLOR.head, 'Recipes');
    cfg.desynth, c = checkbox('Show desynthesis recipes', cfg.desynth); changed = changed or c;
    cfg.hide_no_ki, c = checkbox('Hide recipes needing a key item I lack', cfg.hide_no_ki); changed = changed or c;
    cfg.skill_limit, c = checkbox('Hide recipes too far above my skill', cfg.skill_limit); changed = changed or c;
    if cfg.skill_limit then
        local t = { cfg.skill_margin };
        imgui.PushItemWidth(120);
        imgui.SliderInt('levels above my skill allowed', t, 0, 30);
        imgui.PopItemWidth();
        if t[1] ~= cfg.skill_margin then cfg.skill_margin = t[1]; changed = true; end
    end

    imgui.Separator();
    imgui.TextColored(COLOR.head, 'Expansions to include');
    for i, era in ipairs(ERAS) do
        cfg.eras[era.key], c = checkbox(era.name, cfg.eras[era.key]); changed = changed or c;
        if i % 2 == 1 and i ~= #ERAS then imgui.SameLine(220); end
    end

    imgui.Separator();
    imgui.TextColored(COLOR.head, 'Bags to search');
    local rescan = false;
    for i, bag in ipairs(BAGS) do
        local key = 'b' .. bag.id;
        cfg.bags[key], c = checkbox(bag.name, cfg.bags[key] ~= false);
        if c then changed = true; rescan = true; end
        if i % 3 ~= 0 and i ~= #BAGS then imgui.SameLine(((i % 3) * 140) + 12); end
    end

    if changed then
        settings.save();
        state.dirty = true;
        state.items_dirty = true;
    end
    if rescan then refresh(); end
end

local TABS = { 'Recipes', 'Items', 'Settings' };
local TAB_WIDTH = { 58, 42, 62 };

local function draw_header(w)
    imgui.TextColored(COLOR.head, 'Craftbook');
    for i, name in ipairs(TABS) do
        imgui.SameLine();
        local active = (state.tab == i);
        if not active then imgui.PushStyleColor(flag('ImGuiCol_Text'), COLOR.dim); end
        if imgui.Selectable(name .. '##tab', active, 0, { TAB_WIDTH[i], 0 }) then state.tab = i; end
        if not active then imgui.PopStyleColor(1); end
    end
    imgui.SameLine(w - 32);
    if imgui.SmallButton('x##close') then
        cfg.visible = false;
        settings.save();
    end
    imgui.Separator();
end

local function draw()
    if not cfg.visible then return; end

    local now = os.clock();
    if now - state.last_scan >= 2 then
        state.last_scan = now;
        refresh();
    end

    local pushed_colors, pushed_vars = push_theme();
    imgui.SetNextWindowSize({ 460, 560 }, flag('ImGuiCond_FirstUseEver'));
    if imgui.Begin('Craftbook##craftbook_compact', nil, flag('ImGuiWindowFlags_NoTitleBar')) then
        local w = window_width(460);
        draw_header(w);
        if state.tab == 2 then
            draw_items_tab(w);
        elseif state.tab == 3 then
            draw_settings_tab();
        else
            draw_recipes_tab(w);
        end
    end
    imgui.End();
    pop_theme(pushed_colors, pushed_vars);
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------

local function apply_settings(s)
    if s ~= nil then cfg = s; end
    -- Fill in anything missing from older settings files.
    cfg.bags = cfg.bags or T{};
    cfg.eras = cfg.eras or T{};
    for k, v in pairs(default_settings.eras) do
        if cfg.eras[k] == nil then cfg.eras[k] = v; end
    end
    if type(cfg.show_mode) ~= 'number' or cfg.show_mode < 1 or cfg.show_mode > #SHOW_MODES then cfg.show_mode = 2; end
    if type(cfg.craft) ~= 'number' or cfg.craft < 0 or cfg.craft > 8 then cfg.craft = 0; end
    if type(cfg.level) ~= 'number' or cfg.level < 0 or cfg.level > #LEVELS then cfg.level = 0; end
    if type(cfg.skill_margin) ~= 'number' then cfg.skill_margin = 10; end
    if type(cfg.theme) ~= 'number' or cfg.theme < 0 or cfg.theme > #THEMES then cfg.theme = 1; end
    if type(cfg.opacity) ~= 'number' or cfg.opacity < 30 or cfg.opacity > 100 then cfg.opacity = 94; end
    state.dirty = true;
    state.items_dirty = true;
    state.last_scan = -100;
end

ashita.events.register('load', 'craftbook_load', function ()
    apply_settings(settings.load(default_settings));
    settings.register('settings', 'craftbook_settings_update', function (s)
        apply_settings(s);
    end);
    load_recipes();
    msg(string.format('Loaded %d recipes. Type /cb to show or hide the window.', #recipes));
end);

ashita.events.register('unload', 'craftbook_unload', function ()
    settings.save();
end);

ashita.events.register('command', 'craftbook_command', function (e)
    local args = e.command:args();
    if #args == 0 then return; end
    local cmd = args[1]:lower();
    if cmd ~= '/craftbook' and cmd ~= '/cb' then return; end
    e.blocked = true;

    local sub = (args[2] or ''):lower();
    if sub == 'rescan' then
        state.last_scan = os.clock();
        refresh();
        msg(string.format('Rescanned: %d different items found.', #owned));
        return;
    end
    if sub == 'help' then
        msg('/cb - show or hide the window');
        msg('/cb rescan - rescan your bags now');
        return;
    end

    cfg.visible = not cfg.visible;
    settings.save();
end);

ashita.events.register('d3d_present', 'craftbook_present', function ()
    draw();
end);
