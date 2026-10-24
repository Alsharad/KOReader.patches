-- SimpleUI: an OPDS button in the Library title bar, right after Search.
--
-- SimpleUI's title bar has a fixed button set (Menu, Back, Search, Browse,
-- Title) with no slot for a custom action, so this patch wraps its builder:
-- after screens/sui_titlebar's apply() has injected the Search button, it
-- adds one more IconButton to the same OverlapGroup.
--
-- - Position: follows the Search button at paint time (Search moves between a
--   normal and a compact slot when the Back button hides at the root, and is
--   parked off-screen when hidden), always one icon + gap to its right.
-- - Icon: "opds.svg" from SimpleUI's custom icon folder
--   (settings/simpleui/sui_icons/, e.g. from an icon pack) when present,
--   else KOReader's built-in "book.opened" icon.
-- - Action: the OPDS Plus catalog (opdsplus_show_catalog) when the OPDS Plus
--   plugin is installed, else KOReader's own OPDS catalog
--   (opds_show_catalog), chosen when the button is tapped.
-- - restore() (SimpleUI rebuilds the bar on settings changes) removes it.
--
-- Hooks by folder name "simpleui" (pluginloader ignores _meta.lua names) and
-- runs once per plugin instance, so the module is wrapped only once.
-- Written 2026-10-23 for SimpleUI 2.7.5 on KOReader v2026.07.2; sizing copied from
-- Search since 2026-10-24 so it also matches 3.0's tabbed title bar.

local userpatch = require("userpatch")

local ICON_REL      = "/simpleui/sui_icons/opds.svg"
local FALLBACK_ICON = "book.opened"
local ICON_ID       = "opds_titlebar_button"
local BTN_KEY  = "_opds_tb_btn"

local function addButton(TB, fm_self)
    local tb     = fm_self and fm_self.title_bar
    local search = fm_self and fm_self._titlebar_search_btn
    if not (tb and search) or fm_self[BTN_KEY] then return end

    local lfs  = require("libs/libkoreader-lfs")
    local path = require("datastorage"):getSettingsDir() .. ICON_REL
    if lfs.attributes(path, "mode") ~= "file" then path = nil end

    local Screen     = require("device").screen
    local IconButton = require("ui/widget/iconbutton")
    -- Copy Search's geometry as built: its slot (width), its icon scale and
    -- edge (3.0's tabbed bar draws icons 1.37x the slot, centred on it) and
    -- its tap paddings (zero in the 2.7 classic bar, tap padding in 3.0).
    local iw  = search.width or Screen:scaleBySize(36)

    local btn = IconButton:new{
        icon        = FALLBACK_ICON,
        width       = iw,
        height      = iw,
        padding     = tb.button_padding or Screen:scaleBySize(11),
        show_parent = tb.show_parent or fm_self,
        callback    = function()
            -- Chosen at tap time: plugins register after the title bar is built.
            -- Plugins are registered under their folder name (opds_plus.koplugin).
            local fm = require("apps/filemanager/filemanager").instance or fm_self
            local plus = fm and (fm.opds_plus or fm.opdsplus)
            local action = plus and "opdsplus_show_catalog" or "opds_show_catalog"
            require("dispatcher"):execute({ [action] = true })
        end,
    }
    btn.sui_icon_scale = search.sui_icon_scale
    btn.sui_icon_edge  = search.sui_icon_edge
    btn.padding_left   = search.padding_left   or 0
    btn.padding_right  = search.padding_right  or 0
    btn.padding_top    = search.padding_top    or 0
    btn.padding_bottom = search.padding_bottom or 0
    btn:update()

    -- Draw the icon with SimpleUI's own routine, as Search's is drawn: it sizes
    -- the icon by sui_icon_scale and centres it on the slot. The routine looks
    -- icons up by id, so the lookup is pointed at this file for the call.
    local icon_path = path or ("resources/icons/mdlight/" .. FALLBACK_ICON .. ".svg")
    local okS, S = pcall(require, "features/sui_style")
    if okS and S and S.applyIconToBtn and S.resolveIcon then
        local orig_resolve = S.resolveIcon
        S.resolveIcon = function(id)
            if id == ICON_ID then return icon_path end
            return orig_resolve(id)
        end
        pcall(S.applyIconToBtn, ICON_ID, btn)
        S.resolveIcon = orig_resolve
    end

    -- One Search-width step to the right; the classic bar has no tap padding,
    -- so it needs SimpleUI's 18 px button gap on top.
    local step = search:getSize().w
    if (search.padding_right or 0) == 0 then step = step + Screen:scaleBySize(18) end

    -- Read Search's offset at paint time so this button follows it.
    btn.overlap_align  = nil
    btn.overlap_offset = setmetatable({}, { __index = function(_, k)
        local so = search.overlap_offset or { 0, 0 }
        if k == 1 then return (so[1] or 0) + step end
        if k == 2 then return so[2] or 0 end
    end })

    table.insert(tb, btn)
    fm_self[BTN_KEY] = btn
end

local function removeButton(fm_self)
    local btn = fm_self and fm_self[BTN_KEY]
    if not btn then return end
    local tb = fm_self.title_bar
    if tb then
        for i = #tb, 1, -1 do
            if tb[i] == btn then table.remove(tb, i); break end
        end
    end
    if btn.image then pcall(btn.image.free, btn.image) end
    fm_self[BTN_KEY] = nil
end

userpatch.registerPatchPluginFunc("simpleui", function()
    local logger = require("logger")
    local ok, TB = pcall(require, "screens/sui_titlebar")
    if not ok or type(TB) ~= "table" or type(TB.apply) ~= "function" then
        logger.warn("simpleui-opds-titlebar: screens/sui_titlebar not found, patch skipped")
        return
    end
    if not TB._opds_tb_wrapped then
        TB._opds_tb_wrapped = true
        local orig_apply, orig_restore = TB.apply, TB.restore
        TB.apply = function(fm_self, ...)
            local r = orig_apply(fm_self, ...)
            local okb, err = pcall(addButton, TB, fm_self)
            if not okb then logger.warn("simpleui-opds-titlebar:", err) end
            return r
        end
        TB.restore = function(fm_self, ...)
            pcall(removeButton, fm_self)
            return orig_restore(fm_self, ...)
        end
    end
    -- The bar may already have been built before this plugin instance existed.
    require("ui/uimanager"):nextTick(function()
        local FM = require("apps/filemanager/filemanager")
        local fm = FM and FM.instance
        if fm and fm._titlebar_patched and not fm[BTN_KEY] then
            pcall(addButton, TB, fm)
            require("ui/uimanager"):setDirty(fm, "ui")
        end
    end)
end)
