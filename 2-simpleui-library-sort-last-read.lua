-- SimpleUI: a "Last read" sort and a "Hide Currently Reading book" toggle
-- for the Flat Library home screen module.
--
-- The module (modules/module_library) sorts by title, author, date added,
-- size or random; its mode list and labels are file locals, so this patch
-- reaches them through the module's own functions:
-- - SORT_ORDER / SORT_LABELS (upvalues of the Sort menu builder) get
--   "last_read", so the Sort menu offers it and the saved mode is accepted;
-- - the module's spec (upvalue of build) gets a getFileList that, in that
--   mode, puts books from KOReader's history first, newest read first.
--   Books never opened follow in title order (the module's fallback for an
--   unknown mode).
--
-- Read times come from KOReader's own history (ReadHistory), the same list
-- as History in the file manager.
--
-- The toggle mirrors Recent Books' row of the same name (shown only while
-- Currently Reading is on the screen), but under the module's own key
-- (pfx .. "flat_library_exclude_currently", default off = stock behaviour);
-- it wraps the spec's filterItem.
--
-- Hooks by folder name "simpleui" (pluginloader ignores _meta.lua names) and
-- wraps the module once. Written 2026-10-24 for SimpleUI 3.0 on KOReader
-- v2026.07.2.

local userpatch = require("userpatch")

local MODE        = "last_read"
local EXCLUDE_KEY = "flat_library_exclude_currently"

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
        local function readTime(fp)
            local t = read_at[fp]
            if t == nil then
                local real = realpath(fp)
                t = real and read_at[real]
                read_at[fp] = t or 0
            end
            return t or 0
        end
        -- Stable: unread books keep the module's title order.
        local pos = {}
        for i, fp in ipairs(fps) do pos[fp] = i end
        table.sort(fps, function(a, b)
            local ta, tb = readTime(a), readTime(b)
            if ta ~= tb then return ta > tb end
            return pos[a] < pos[b]
        end)
        return fps
    end

    local SUISettings = require("infra/sui_store")
    local orig_filter = spec.filterItem
    spec.filterItem = function(fp, ctx, ...)
        if ctx and ctx.current_fp == fp
                and SUISettings:isTrue(((ctx.pfx) or "") .. EXCLUDE_KEY) then
            return false
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
        if okr and shown then
            table.insert(items, math.max(1, #items), {
                text           = _lc("Hide Currently Reading book"),
                checked_func   = function() return SUISettings:isTrue(pfx .. EXCLUDE_KEY) end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(pfx .. EXCLUDE_KEY, not SUISettings:isTrue(pfx .. EXCLUDE_KEY))
                    ctx_menu.refresh()
                end,
            })
        end
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
