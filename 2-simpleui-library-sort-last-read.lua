-- SimpleUI: a "Last read" sort and a "Hide Currently Reading book" toggle
-- for the Flat Library home screen module.
--
-- The module (modules/module_library) sorts by title, author, date added,
-- size or random; its mode list and labels are file locals, so this patch
-- reaches them through the module's own functions:
-- - SORT_ORDER / SORT_LABELS (upvalues of the Sort menu builder) get
--   "last_read", so the Sort menu offers it and the saved mode is accepted;
-- - the module's spec (upvalue of build) gets a getFileList that, in that
--   mode, puts books you have started first, most recently read first
--   (KOReader's history). "Started" is SimpleUI's own rule for its progress
--   badge: above 0%, or marked finished or abandoned — a history entry for a
--   book with no progress (reset or never turned a page) does not count.
--   Unread books follow newest added first (file date, as the module's own
--   "Date added" sort), then by title.
--
-- Read times come from KOReader's own history (ReadHistory), the same list
-- as History in the file manager.
--
-- Hide books ▸ "Current book" (shown only while Currently Reading
-- is on the screen) mirrors Recent Books' "Hide Currently Reading book", but
-- under the module's own key
-- (pfx .. "flat_library_exclude_currently", default off = stock behaviour);
-- it wraps the spec's filterItem.
--
-- "Hide books" (submenu): leaves books of a reading status out of this row —
-- Finished (100% or marked finished), On hold (KOReader's "abandoned"), In
-- progress (started, not finished) and Unread (no progress). Each off by
-- default, keys pfx .. "flat_library_hide_<status>". Only this row: SimpleUI's
-- own Finished Books setting (show/fade/hide) still applies library-wide.
--
-- Hooks by folder name "simpleui" (pluginloader ignores _meta.lua names) and
-- wraps the module once. Written 2026-10-24 for SimpleUI 3.0 on KOReader
-- v2026.07.2.

local userpatch = require("userpatch")

local MODE        = "last_read"
local EXCLUDE_KEY = "flat_library_exclude_currently"
local HIDE_PREFIX = "flat_library_hide_"
local HIDE_STATUSES = {
    { id = "finished",    label = "Finished books" },
    { id = "on_hold",     label = "On-hold books" },
    { id = "in_progress", label = "In-progress books" },
    { id = "unread",      label = "Unread books" },
}

local function upvalue(fn, name)
    for i = 1, 255 do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then return nil end
        if n == name then return v end
    end
end

local function patch(Lib)
    local spec = upvalue(Lib.build, "spec")
    local menu = spec and spec.extra_menu_items_before
    local order  = menu and upvalue(menu, "SORT_ORDER")
    local labels = menu and upvalue(menu, "SORT_LABELS")
    if not (spec and order and labels and spec.getFileList) then
        return false
    end

    -- Menu entry, after "Author (A–Z)".
    local at = #order + 1
    for i, m in ipairs(order) do if m == "author_asc" then at = i + 1 end end
    table.insert(order, at, MODE)
    labels[MODE] = require("infra/sui_i18n").translate("Last read")

    local Config      = require("infra/sui_config")
    local orig_list   = spec.getFileList
    spec.getFileList = function(ctx)
        local fps = orig_list(ctx)
        local pfx = (ctx and ctx.pfx) or ""
        if Config.readChoice(pfx .. "flat_library_sort_mode", order, "title_asc") ~= MODE then
            return fps
        end
        -- History and the library scan can name a file by different paths
        -- (symlinked storage), so both are compared by real path too.
        local realpath = require("ffi/util").realpath
        local read_at = {}
        for _, item in ipairs(require("readhistory").hist or {}) do
            if item.file and item.time then
                read_at[item.file] = item.time
                local real = realpath(item.file)
                if real then read_at[real] = item.time end
            end
        end
        local okS, SH = pcall(require, "modules/module_books_shared")
        local function started(fp)
            if not (okS and SH.getBookData) then return true end
            local okD, bd = pcall(SH.getBookData, fp)
            if not okD or type(bd) ~= "table" then return true end
            return (bd.percent or 0) > 0 or bd.status == "complete" or bd.status == "abandoned"
        end
        local rank = {}
        local function readTime(fp)
            if rank[fp] ~= nil then return rank[fp] end
            local t = read_at[fp]
            if t == nil then
                local real = realpath(fp)
                t = real and read_at[real]
            end
            t = (t and started(fp)) and t or 0
            rank[fp] = t
            return t
        end
        -- Unread books: newest added first, ties in the module's title order.
        local added = {}
        local okL, LibraryScan = pcall(require, "engines/sui_library_scan")
        local home = okL and LibraryScan.resolveHomeDir and LibraryScan.resolveHomeDir()
        if home then
            for _, r in ipairs(LibraryScan.getRaw(home) or {}) do added[r.fp] = r.mtime or 0 end
        end
        local pos = {}
        for i, fp in ipairs(fps) do pos[fp] = i end
        table.sort(fps, function(a, b)
            local ta, tb = readTime(a), readTime(b)
            if ta ~= tb then return ta > tb end
            local ma, mb = added[a] or 0, added[b] or 0
            if ma ~= mb then return ma > mb end
            return pos[a] < pos[b]
        end)
        return fps
    end

    local SUISettings = require("infra/sui_store")
    local okSH, SH = pcall(require, "modules/module_books_shared")

    -- Reading status of a book, from SimpleUI's cached book data.
    local function statusOf(fp, ctx)
        if not (okSH and SH.getBookData) then return nil end
        local okD, bd = pcall(SH.getBookData, fp, ctx and ctx.prefetched and ctx.prefetched[fp])
        if not okD or type(bd) ~= "table" then return nil end
        local pct = bd.percent or 0
        if pct >= 1 or bd.status == "complete" then return "finished" end
        if bd.status == "abandoned" then return "on_hold" end
        if pct > 0 then return "in_progress" end
        return "unread"
    end

    local orig_filter = spec.filterItem
    spec.filterItem = function(fp, ctx, ...)
        local pfx = (ctx and ctx.pfx) or ""
        if ctx and ctx.current_fp == fp and SUISettings:isTrue(pfx .. EXCLUDE_KEY) then
            return false
        end
        local any = false
        for _, s in ipairs(HIDE_STATUSES) do
            if SUISettings:isTrue(pfx .. HIDE_PREFIX .. s.id) then any = true; break end
        end
        if any then
            local st = statusOf(fp, ctx)
            if st and SUISettings:isTrue(pfx .. HIDE_PREFIX .. st) then return false end
        end
        if orig_filter then return orig_filter(fp, ctx, ...) end
        return true
    end

    -- Menu row, before "Finished Books" (the builder's last row).
    spec.extra_menu_items_before = function(ctx_menu)
        local items = menu(ctx_menu)
        local pfx   = ctx_menu.pfx or ""
        local _lc   = ctx_menu._ or function(s) return s end
        local okr, shown = pcall(function()
            local Registry  = require("modules/moduleregistry")
            local currently = Registry.get("currently")
            return currently and Registry.isEnabled(currently, pfx)
        end)
        local hide_rows = {}
        if okr and shown then
            hide_rows[#hide_rows + 1] = {
                text           = _lc("Current book"),
                checked_func   = function() return SUISettings:isTrue(pfx .. EXCLUDE_KEY) end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    SUISettings:saveSetting(pfx .. EXCLUDE_KEY, not SUISettings:isTrue(pfx .. EXCLUDE_KEY))
                    ctx_menu.refresh()
                end,
            }
        end
        for _, s in ipairs(HIDE_STATUSES) do
            local key = pfx .. HIDE_PREFIX .. s.id
            hide_rows[#hide_rows + 1] = {
                text           = _lc(s.label),
                checked_func   = function() return SUISettings:isTrue(key) end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(key, not SUISettings:isTrue(key))
                    ctx_menu.refresh()
                end,
            }
        end
        table.insert(items, math.max(1, #items), { text = _lc("Hide books"), sub_item_table = hide_rows })
        return items
    end
    return true
end

userpatch.registerPatchPluginFunc("simpleui", function()
    local logger = require("logger")
    local ok, Lib = pcall(require, "modules/module_library")
    if not ok or type(Lib) ~= "table" or type(Lib.build) ~= "function" then
        logger.warn("simpleui-library-sort-last-read: modules/module_library not found, patch skipped")
        return
    end
    if Lib._last_read_patched then return end
    local okp, done = pcall(patch, Lib)
    if okp and done then
        Lib._last_read_patched = true
    else
        logger.warn("simpleui-library-sort-last-read: module layout changed, patch skipped", done)
    end
end)
