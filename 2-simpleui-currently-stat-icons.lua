-- SimpleUI: an icon before each statistic of the Currently Reading module.
--
-- With Statistics style "one per line" (default), SimpleUI draws the book's
-- statistics as plain text lines; its only icon, a clock, is drawn before the
-- single compact line. This patch puts an icon before each line instead:
--   time left        -> clock (SimpleUI's own clock glyph)
--   days reading     -> calendar
--   time read        -> open book
-- The glyphs come from KOReader's symbols font, the same font and size as
-- SimpleUI's clock, centred on the text line, in the line's colour. The
-- module's "Statistics icon" switch turns them off as it does the clock.
--
-- How: while the module builds, BookStats.line (called once per row) tells
-- which statistic a row shows, and the row's text widget, made right after by
-- UI.makeColoredText, gets the icon painted to its left. The text keeps
-- SimpleUI's own widget, so in-place refreshes of the numbers still work.
--
-- Hooks by folder name "simpleui" (pluginloader ignores _meta.lua names).
-- Written 2026-10-24 for SimpleUI 3.0 on KOReader v2026.07.2.

local userpatch = require("userpatch")

local ICONS = {
    book_remaining = "\u{E84F}", -- clock
    book_days      = "\u{E7EC}", -- calendar
    book_time      = "\u{E7BD}", -- book-open-variant
}
local ICON_SCALE = 1.1  -- glyph size relative to the text, as SimpleUI's clock
local GAP_SCALE  = 0.5  -- icon-to-text gap relative to the text size

userpatch.registerPatchPluginFunc("simpleui", function()
    local logger = require("logger")
    local okC, Cur       = pcall(require, "modules/module_currently")
    local okB, BookStats = pcall(require, "infra/sui_book_stats")
    local okU, UI        = pcall(require, "infra/sui_core")
    local okS, SUIStyle  = pcall(require, "features/sui_style")
    if not (okC and okB and okU and okS and type(Cur) == "table" and type(Cur.build) == "function"
            and type(BookStats.line) == "function" and type(UI.makeColoredText) == "function"
            and SUIStyle.pxFace and SUIStyle.FACE_ICONS) then
        logger.warn("simpleui-currently-stat-icons: SimpleUI layout changed, patch skipped")
        return
    end
    if Cur._stat_icons_patched then return end
    Cur._stat_icons_patched = true

    local SUISettings = require("infra/sui_store")
    local Geom        = require("ui/geometry")

    local building, pending = false, nil

    local orig_line = BookStats.line
    BookStats.line = function(order, ...)
        if building and type(order) == "table" and #order == 1 then pending = order[1] end
        return orig_line(order, ...)
    end

    -- The row's text widget with `glyph` painted before it.
    local function withIcon(orig_text, args, glyph, ...)
        local face      = args.face
        local icon_face = SUIStyle.pxFace(SUIStyle.FACE_ICONS, face.size * ICON_SCALE)
        local icon      = orig_text({ text = glyph, face = icon_face, fgcolor = args.fgcolor, padding = 0 })
        local icon_w    = icon:getSize().w
        local gap       = math.floor(face.size * GAP_SCALE)
        local nudge     = SUIStyle.inkCentreShift and SUIStyle.inkCentreShift(icon_face, glyph, false) or 0

        local opts = {}
        for k, v in pairs(args) do opts[k] = v end
        if opts.max_width then opts.max_width = math.max(1, opts.max_width - icon_w - gap) end
        local tw = orig_text(opts, ...)

        local text_size, text_paint = tw.getSize, tw.paintTo
        tw.getSize = function(self)
            local s = text_size(self)
            return Geom:new{ w = s.w + icon_w + gap, h = s.h }
        end
        tw.paintTo = function(self, bb, x, y)
            local h  = text_size(self).h
            local ih = icon:getSize().h
            icon:paintTo(bb, x, y + math.floor((h - ih) / 2) + nudge)
            text_paint(self, bb, x + icon_w + gap, y)
        end
        return tw
    end

    local orig_text = UI.makeColoredText
    UI.makeColoredText = function(args, ...)
        local id = pending
        if not (building and id and type(args) == "table" and args.truncate_with_ellipsis and args.face) then
            return orig_text(args, ...)
        end
        pending = nil
        local glyph = ICONS[id]
        if not glyph then return orig_text(args, ...) end
        local ok, w = pcall(withIcon, orig_text, args, glyph, ...)
        if ok then return w end
        logger.warn("simpleui-currently-stat-icons: icon skipped:", w)
        return orig_text(args, ...)
    end

    local function finish(ok, ...)
        building, pending = false, nil
        if not ok then error((...), 0) end
        return ...
    end
    local orig_build = Cur.build
    Cur.build = function(w, ctx, ...)
        local pfx = (ctx and ctx.pfx) or ""
        building, pending = SUISettings:nilOrTrue(pfx .. "currently_stats_icon"), nil
        return finish(pcall(orig_build, w, ctx, ...))
    end
end)
