-- SimpleUI: styles for highlights in the Quote home screen module.
--
-- Adds two rows to the Quote module's settings:
-- - Appearance ▸ Highlight style: Classic (SimpleUI's own look), Epigraph,
--   Marginalia, Highlighter;
-- - Content ▸ Attribution: which parts go on the line under the quote —
--   book title, author, chapter, date highlighted, page (default: book,
--   author). Order is fixed; parts a highlight doesn't have are skipped.
--
-- The styles (only for highlights; built-in and custom quotes keep the
-- Classic look):
-- - Epigraph: a large quotation mark in the accent colour. Left: “ beside
--   the first line; Right: ” on the right; Centre: “ above the quote.
-- - Marginalia: a thin accent bar beside the quote (left or right side);
--   centred, a short horizontal divider between quote and attribution.
-- - Highlighter: each line on its own accent-tint block, square ends, a
--   thin gap of paper between lines, balanced line breaks.
-- All three: attribution in letter-spaced capitals, cleaned-up text (no
-- outer quotation marks, trailing comma -> full stop, soft hyphens and
-- line breaks removed).
--
-- SimpleUI's own Quote settings keep working: Alignment, Text ▸ Quote (font,
-- style, size) and Text ▸ Author (font, style, size, colour of the
-- attribution). Colour: SimpleUI's accent (Settings ▸ Style), grey while
-- none is set.
--
-- With the module's Fixed height on (3 quote lines, the shorter quotes
-- centred), the reserved height also counts what a style adds — the
-- divider and its gaps, the large mark, the tinted line padding — so a
-- three-line highlight fits in every style and the screen below never moves.
--
-- Also drops the module's fixed 14 px padding above the quote (SimpleUI's
-- PAD, in build and getHeight alike): the module's Top Margin setting already
-- sets the space above it. The 8 px below (PAD2) stays.
--
-- How: the module's local buildFromHighlight is replaced through
-- debug.setupvalue (the same local is used by the Mixed sources), with the
-- module's own pickHighlight, so the shuffled order, the 250-character
-- limit and tap-to-open (filepath, pos0, page) are unchanged. Settings rows
-- are added by wrapping getMenuItems. Chapter, date and page come from the
-- book's KOReader annotations, matched by pos0.
--
-- Keys (per home screen, saved in presets): pfx .. "quote_hl_style",
-- pfx .. "quote_hl_parts".
--
-- Hooks by folder name "simpleui" (pluginloader ignores _meta.lua names).
-- Written 2026-10-24 for SimpleUI 3.0 on KOReader v2026.07.2.

local userpatch = require("userpatch")

local STYLE_KEY = "quote_hl_style"
local PARTS_KEY = "quote_hl_parts"
local STYLES = {
    { value = "classic",     label = "Classic" },
    { value = "epigraph",    label = "Epigraph" },
    { value = "marginalia",  label = "Marginalia" },
    { value = "highlighter", label = "Highlighter" },
}
local PARTS = {
    { key = "book",    label = "Book title" },
    { key = "author",  label = "Author" },
    { key = "chapter", label = "Chapter" },
    { key = "date",    label = "Date highlighted" },
    { key = "page",    label = "Page" },
}
local DEFAULT_PARTS = { book = true, author = true }

local MARK_SCALE  = 4.0   -- quotation mark size, relative to the quote text
local ATTR_SCALE  = 0.82  -- capitals of the attribution, relative to Text ▸ Author
local DIVIDER_FRAC = 0.1  -- centred Marginalia divider, share of the card width
local GREY_INK    = 0.45  -- mark/bar without an accent (Blitbuffer.gray level)
local GREY_TINT   = 0.12  -- highlighter tint without an accent
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local SOFT_HYPHEN = "\u{00AD}"
local NBSP        = "\u{00A0}"
local WJ          = "\u{2060}"
local HAIR        = "\u{200A}"
local OPEN_MARKS  = { "“", "‘", "„", "‚", "«", "‹", "\"", "'", "—", "–" }
local CLOSE_MARKS = { "”", "’", "»", "›", "\"", "'" }

local function upvalue(fn, name)
    if type(fn) ~= "function" then return nil end
    for i = 1, 255 do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then return nil end
        if n == name then return v, i end
    end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local SUISettings -- infra/sui_store, set in the hook

local function getStyle(pfx)
    local v = SUISettings:readSetting((pfx or "") .. STYLE_KEY)
    for _, s in ipairs(STYLES) do if s.value == v then return v end end
    return "classic"
end

local function getParts(pfx)
    local v = SUISettings:readSetting((pfx or "") .. PARTS_KEY)
    return type(v) == "table" and v or DEFAULT_PARTS
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------
local function startsWith(s, p) return s:sub(1, #p) == p end
local function endsWith(s, p) return #p <= #s and s:sub(-#p) == p end

local function cleanText(text)
    text = text:gsub(SOFT_HYPHEN, ""):gsub("[\r\n\t]+", " "):gsub("  +", " ")
    local changed = true
    while changed do
        changed = false
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        for _, m in ipairs(OPEN_MARKS) do
            if startsWith(text, m) then text = text:sub(#m + 1); changed = true end
        end
        for _, m in ipairs(CLOSE_MARKS) do
            if endsWith(text, m) then text = text:sub(1, -#m - 1); changed = true end
        end
    end
    text = text:gsub("[,;:]$", ".")
    return text
end

-- Capitals with hair spaces between letters (KOReader text has no letter
-- spacing); word joiners keep a word from breaking at its hair spaces.
local function tracked(text)
    local up = require("ffi/utf8proc").uppercase_dumb(text)
    local util = require("util")
    local out = {}
    for _, ch in ipairs(util.splitToChars(up)) do
        if #out > 0 and ch ~= " " and out[#out] ~= " " then
            out[#out + 1] = WJ .. HAIR .. WJ
        end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Chapter, date and page of a highlight, from the book's annotations
-- ---------------------------------------------------------------------------
local _meta_cache = {} -- filepath -> { mtime = n, by_pos0 = { [pos0] = annotation } }

local function annotationFor(h)
    if not (h and h.filepath and h.pos0) then return nil end
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then return nil end
    local sidecar = DocSettings:findSidecarFile(h.filepath)
    if not sidecar then return nil end
    local mtime = require("libs/libkoreader-lfs").attributes(sidecar, "modification")
    local entry = _meta_cache[h.filepath]
    if not entry or entry.mtime ~= mtime then
        entry = { mtime = mtime, by_pos0 = {} }
        local okd, ds = pcall(DocSettings.open, DocSettings, h.filepath)
        local anns = okd and ds and ds:readSetting("annotations")
        if type(anns) == "table" then
            for _, a in ipairs(anns) do
                if type(a.pos0) == "string" then entry.by_pos0[a.pos0] = a end
            end
        end
        _meta_cache[h.filepath] = entry
    end
    return type(h.pos0) == "string" and entry.by_pos0[h.pos0] or nil
end

local function formatDate(datetime)
    local y, m, d = tostring(datetime or ""):match("^(%d+)%-(%d+)%-(%d+)")
    if not y then return nil end
    local s = tonumber(d) .. " " .. (MONTHS[tonumber(m)] or m)
    if tonumber(y) ~= tonumber(os.date("%Y")) then s = s .. " " .. y end
    return s
end

local function attributionText(h, pfx)
    local parts = getParts(pfx)
    local ann = (parts.chapter or parts.date or parts.page) and annotationFor(h) or nil
    local bits = {}
    local function add(s)
        if s and s ~= "" then bits[#bits + 1] = s end
    end
    if parts.book then add(h.title) end
    if parts.author then add(h.authors) end
    if parts.chapter and ann and ann.chapter then
        local ch = cleanText(ann.chapter)
        if ch ~= h.title then add(ch) end
    end
    if parts.date and ann then add(formatDate(ann.datetime)) end
    if parts.page then
        local p = ann and ann.pageno or (type(h.page) == "number" and h.page or nil)
        if p then add("p. " .. p) end
    end
    if #bits == 0 then return nil end
    for i, b in ipairs(bits) do bits[i] = tracked(b) end
    return table.concat(bits, "  ·  ")
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------
local Blitbuffer, Font, Geom, RenderText, Screen, TextWidget, Widget, WidgetContainer
local HorizontalGroup, HorizontalSpan, VerticalGroup, VerticalSpan, CenterContainer

local function loadUI()
    Blitbuffer      = require("ffi/blitbuffer")
    Font            = require("ui/font")
    Geom            = require("ui/geometry")
    RenderText      = require("ui/rendertext")
    Screen          = require("device").screen
    TextWidget      = require("ui/widget/textwidget")
    Widget          = require("ui/widget/widget")
    WidgetContainer = require("ui/widget/container/widgetcontainer")
    HorizontalGroup = require("ui/widget/horizontalgroup")
    HorizontalSpan  = require("ui/widget/horizontalspan")
    VerticalGroup   = require("ui/widget/verticalgroup")
    VerticalSpan    = require("ui/widget/verticalspan")
    CenterContainer = require("ui/widget/container/centercontainer")
end

local function fill(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if bb.paintRectRGB32 and color.getColorRGB32 then
        bb:paintRectRGB32(x, y, w, h, color:getColorRGB32())
    else
        bb:paintRect(x, y, w, h, color.getColor8 and color:getColor8() or color)
    end
end

local function accentInk()
    local ok, Accent = pcall(require, "infra/sui_accent")
    return ok and Accent.color() or Blitbuffer.gray(GREY_INK)
end

local function accentTint()
    local ok, Accent = pcall(require, "infra/sui_accent")
    return ok and Accent.secondaryColor() or Blitbuffer.gray(GREY_TINT)
end

-- A solid rectangle.
local function bar(w, h, color)
    local b = Widget:new{ dimen = Geom:new{ w = w, h = h } }
    function b:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        fill(bb, x, y, w, h, color)
    end
    return b
end

-- A glyph cropped to its ink, so a large quotation mark takes no empty line
-- height above and below it.
local function codepoint(ch)
    local b1, b2, b3 = ch:byte(1, 3)
    if b1 < 0x80 then return b1 end
    if b1 < 0xE0 then return (b1 - 0xC0) * 64 + (b2 - 0x80) end
    return ((b1 - 0xE0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)
end

local function inkGlyph(text, face, color)
    local tw = TextWidget:new{ text = text, face = face, fgcolor = color, padding = 0 }
    -- The glyph's own bitmap: t = its top above the baseline, height = its ink.
    -- (sizeUtf8Text clamps the part below the baseline at 0, which for a
    -- quotation mark — all above the baseline — keeps the empty space down
    -- to the baseline.)
    local glyph = RenderText:getGlyph(face, codepoint(text), false)
    local top_cut = tw:getBaseline() - glyph.t
    local g = WidgetContainer:new{ dimen = Geom:new{ w = tw:getSize().w, h = glyph.bb:getHeight() }, tw }
    function g:getSize() return self.dimen end
    function g:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        self[1]:paintTo(bb, x, y - top_cut)
    end
    return g
end

-- Height from a text box's top to the cap height of its first line.
local function firstCapTop(tbw, face, bold)
    local baseline = tbw.line_glyph_baseline
    if not baseline then
        local _, ascender = face.ftsize:getHeightAndAscender()
        baseline = math.floor(ascender)
    end
    local cap = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, "H", true, bold).y_top
    return math.max(0, baseline - cap)
end

-- Greedy wrap of `words` into lines no wider than `max_w`.
local function wrap(words, widths, space_w, max_w)
    local lines, cur, cur_w = {}, {}, 0
    for i, word in ipairs(words) do
        local w = widths[i]
        if #cur > 0 and cur_w + space_w + w > max_w then
            lines[#lines + 1] = table.concat(cur, " ")
            cur, cur_w = {}, 0
        end
        cur_w = (#cur > 0) and (cur_w + space_w + w) or w
        cur[#cur + 1] = word
    end
    if #cur > 0 then lines[#lines + 1] = table.concat(cur, " ") end
    return lines
end

-- Lines of `text` balanced to equal-ish widths: the narrowest width that
-- keeps the line count of a plain wrap at `max_w`.
local function balancedLines(text, face, bold, max_w)
    local words, widths = {}, {}
    for word in text:gmatch("%S+") do
        words[#words + 1] = word
        widths[#widths + 1] = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, word, true, bold).x
    end
    if #words == 0 then return {} end
    local space_w = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, " ", true, bold).x
    local n = #wrap(words, widths, space_w, max_w)
    if n <= 1 then return wrap(words, widths, space_w, max_w) end
    local lo, hi = math.floor(max_w / n), max_w
    while hi - lo > 2 do
        local mid = math.floor((lo + hi) / 2)
        if #wrap(words, widths, space_w, mid) <= n then hi = mid else lo = mid end
    end
    return wrap(words, widths, space_w, hi)
end

-- One line of text on its tint block.
local function tintLine(text, face, bold, fgcolor, tint, pad_h, pad_v, max_w)
    local tw = TextWidget:new{ text = text, face = face, bold = bold, fgcolor = fgcolor,
                               padding = 0, max_width = max_w }
    local size = tw:getSize()
    local w, h = size.w + 2 * pad_h, size.h + 2 * pad_v
    local line = WidgetContainer:new{ dimen = Geom:new{ w = w, h = h }, tw }
    function line:getSize() return self.dimen end
    function line:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        fill(bb, x, y, w, h, tint)
        self[1]:paintTo(bb, x + pad_h, y + pad_v)
    end
    return line
end

-- ---------------------------------------------------------------------------
-- Styles
-- ---------------------------------------------------------------------------
local function buildStyled(style, h, pfx, inner_w, fonts, vspan_gap, text_alpha, clr_quote, clr_attr, alignment, UI, breaks)
    alignment = alignment or "center"
    local text = cleanText(h.text or "")
    local qface, qbold = fonts.quote_face, fonts.quote_bold
    local fs = qface.size
    local ink, tint = accentInk(), accentTint()

    local attr
    local attr_text = attributionText(h, pfx)
    local function attrBox(width, align)
        if not attr_text then return nil end
        local af = fonts.attr_face
        local small = Font:getFace(af.orig_font, math.max(6, math.floor(af.orig_size * ATTR_SCALE)))
        return UI.makeTextBox({ text = attr_text, face = small, bold = fonts.attr_bold,
            width = width, alignment = align, fgcolor = clr_attr }, text_alpha)
    end
    local attr_gap = VerticalSpan:new{ width = vspan_gap.width + Screen:scaleBySize(4) }

    local function quoteBox(width, align)
        local t = breaks and breaks(text, qface, width) or text
        return UI.makeTextBox({ text = t, face = qface, bold = qbold, width = width,
            alignment = align, fgcolor = clr_quote }, text_alpha)
    end

    local function column(align, ...)
        local vg = VerticalGroup:new{ align = align }
        for _, w in ipairs({ ... }) do if w then vg[#vg + 1] = w end end
        return vg
    end

    if style == "epigraph" then
        local mface = Font:getFace(qface.orig_font, math.floor(qface.orig_size * MARK_SCALE))
        if alignment == "center" then
            local mark = inkGlyph("“", mface, ink)
            attr = attrBox(inner_w, "center")
            return column("center", mark, VerticalSpan:new{ width = math.floor(fs * 0.35) },
                quoteBox(inner_w, "center"), attr and attr_gap, attr)
        end
        local right = alignment == "right"
        local mark = inkGlyph(right and "”" or "“", mface, ink)
        local gap = math.floor(fs * 0.35)
        local body_w = inner_w - mark:getSize().w - gap
        local quote = quoteBox(body_w, alignment)
        attr = attrBox(body_w, alignment)
        local body = column(right and "right" or "left", quote, attr and attr_gap, attr)
        local mark_col = column("left", VerticalSpan:new{ width = firstCapTop(quote, qface, qbold) }, mark)
        if right then
            return HorizontalGroup:new{ align = "top", body, HorizontalSpan:new{ width = gap }, mark_col }
        end
        return HorizontalGroup:new{ align = "top", mark_col, HorizontalSpan:new{ width = gap }, body }

    elseif style == "marginalia" then
        if alignment == "center" then
            attr = attrBox(inner_w, "center")
            local rule = bar(math.floor(inner_w * DIVIDER_FRAC), math.max(2, Screen:scaleBySize(1.5)), ink)
            local around = VerticalSpan:new{ width = math.floor(fs * 0.55) }
            return column("center", quoteBox(inner_w, "center"), around, rule, attr and around, attr)
        end
        local right = alignment == "right"
        local bar_w, gap = math.max(2, Screen:scaleBySize(2)), math.floor(fs * 0.6)
        local body_w = inner_w - bar_w - gap
        local quote = quoteBox(body_w, alignment)
        local b = bar(bar_w, quote:getSize().h, ink)
        local qrow = right
            and HorizontalGroup:new{ align = "top", quote, HorizontalSpan:new{ width = gap }, b }
            or  HorizontalGroup:new{ align = "top", b, HorizontalSpan:new{ width = gap }, quote }
        attr = attrBox(body_w, alignment)
        local arow = attr and (right
            and HorizontalGroup:new{ attr, HorizontalSpan:new{ width = bar_w + gap } }
            or  HorizontalGroup:new{ HorizontalSpan:new{ width = bar_w + gap }, attr })
        return column(right and "right" or "left", qrow, arow and attr_gap, arow)

    else -- highlighter
        local pad_h, pad_v = math.floor(fs * 0.3), math.floor(fs * 0.06)
        local line_gap = math.max(2, math.floor(fs * 0.2))
        local lines = balancedLines(text, qface, qbold, inner_w - 2 * pad_h)
        local vg = VerticalGroup:new{ align = alignment }
        for i, line in ipairs(lines) do
            if i > 1 then vg[#vg + 1] = VerticalSpan:new{ width = line_gap } end
            vg[#vg + 1] = tintLine(line, qface, qbold, clr_quote, tint, pad_h, pad_v, inner_w - 2 * pad_h)
        end
        attr = attrBox(inner_w, alignment)
        if attr then
            vg[#vg + 1] = attr_gap
            vg[#vg + 1] = attr
        end
        return vg
    end
end

-- ---------------------------------------------------------------------------
-- Settings rows
-- ---------------------------------------------------------------------------
local function addRows(spec, ctx_menu)
    local Config  = require("infra/sui_config")
    local pfx     = ctx_menu.pfx or ""
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._ or function(s) return s end

    local options = {}
    for _, s in ipairs(STYLES) do options[#options + 1] = { value = s.value, label = _lc(s.label) } end
    local style_row = Config.makeRadioSubmenuItem{
        text    = _lc("Highlight style"),
        options = options,
        get     = function() return getStyle(pfx) end,
        set     = function(v) SUISettings:saveSetting(pfx .. STYLE_KEY, v) end,
        refresh = refresh,
    }

    local part_rows = {}
    for _, p in ipairs(PARTS) do
        part_rows[#part_rows + 1] = {
            text           = _lc(p.label),
            keep_menu_open = true,
            checked_func   = function() return getParts(pfx)[p.key] == true end,
            callback       = function()
                local cur = {}
                for k, v in pairs(getParts(pfx)) do cur[k] = v end
                cur[p.key] = not cur[p.key] or nil
                SUISettings:saveSetting(pfx .. PARTS_KEY, cur)
                if refresh then refresh() end
            end,
        }
    end
    local attr_row = { text = _lc("Attribution"), sub_item_table = part_rows }

    spec.content = spec.content or {}
    table.insert(spec.content, attr_row)
    spec.appearance = spec.appearance or {}
    spec.appearance.extra = spec.appearance.extra or {}
    table.insert(spec.appearance.extra, 1, style_row)
end

-- ---------------------------------------------------------------------------
-- Hook
-- ---------------------------------------------------------------------------
userpatch.registerPatchPluginFunc("simpleui", function()
    local logger = require("logger")
    local ok, Quote = pcall(require, "modules/module_quote")
    if not ok or type(Quote) ~= "table" or type(Quote.build) ~= "function" then
        logger.warn("simpleui-quote-styles: modules/module_quote not found, patch skipped")
        return
    end
    if Quote._hl_styles_patched then return end

    local orig_from_hl, idx = upvalue(Quote.build, "buildFromHighlight")
    local pick       = upvalue(orig_from_hl, "pickHighlight")
    local buildWidget = upvalue(orig_from_hl, "buildWidget")
    local breaks     = upvalue(buildWidget, "controlLineBreaks")
    if not (orig_from_hl and idx and pick) then
        logger.warn("simpleui-quote-styles: module layout changed, patch skipped")
        return
    end
    SUISettings = require("infra/sui_store")
    loadUI()
    local UI = require("infra/sui_core")

    -- No fixed padding above the quote: Top Margin sets that space. PAD is a
    -- module local shared by build() and getHeight(), so both follow.
    local _, pad_idx = upvalue(Quote.build, "PAD")
    if pad_idx then debug.setupvalue(Quote.build, pad_idx, 0) end

    local current_pfx = ""
    local orig_build = Quote.build
    Quote.build = function(w, ctx, ...)
        current_pfx = (ctx and ctx.pfx) or ""
        return orig_build(w, ctx, ...)
    end

    local function fromHighlight(inner_w, fonts, vspan_gap, text_alpha, clr_quote, clr_attr, alignment)
        local style = getStyle(current_pfx)
        if style == "classic" then
            return orig_from_hl(inner_w, fonts, vspan_gap, text_alpha, clr_quote, clr_attr, alignment)
        end
        local h = pick()
        if not h then
            return orig_from_hl(inner_w, fonts, vspan_gap, text_alpha, clr_quote, clr_attr, alignment)
        end
        local okb, content = pcall(buildStyled, style, h, current_pfx, inner_w, fonts, vspan_gap,
            text_alpha, clr_quote, clr_attr, alignment, UI, breaks)
        if not okb then
            logger.warn("simpleui-quote-styles: build failed, showing Classic:", content)
            return orig_from_hl(inner_w, fonts, vspan_gap, text_alpha, clr_quote, clr_attr, alignment)
        end
        return content, h.filepath, h.title, h.pos0, h.page
    end
    debug.setupvalue(orig_build, idx, fromHighlight)

    local orig_menu = Quote.getMenuItems
    if type(orig_menu) == "function" then
        Quote.getMenuItems = function(ctx_menu)
            local Config = require("infra/sui_config")
            local orig_bm = Config.buildModuleMenu
            Config.buildModuleMenu = function(spec, ctx)
                Config.buildModuleMenu = orig_bm
                local okr, err = pcall(addRows, spec, ctx_menu)
                if not okr then logger.warn("simpleui-quote-styles: menu rows skipped:", err) end
                return orig_bm(spec, ctx)
            end
            local okm, res = pcall(orig_menu, ctx_menu)
            Config.buildModuleMenu = orig_bm
            if not okm then error(res) end
            return res
        end
    end
    -- Fixed height: SimpleUI reserves 3 quote lines + its gap + the
    -- attribution. A style replaces that gap with its own spacing (and the
    -- Highlighter pads every line), so the reserve grows by the difference.
    local orig_height = Quote.getHeight
    local fontSizes = type(orig_height) == "function" and upvalue(orig_height, "fontSizes")
    if fontSizes then
        local Config = require("infra/sui_config")
        local FIXED_LINES = 3
        Quote.getHeight = function(ctx, ...)
            local base = orig_height(ctx, ...)
            local pfx = (ctx and ctx.pfx) or ""
            local style = getStyle(pfx)
            if style == "classic" or not SUISettings:nilOrTrue(pfx .. "simpleui_quote_fixed_height") then
                return base
            end
            local okx, extra = pcall(function()
                local lf = (ctx and ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
                local scale = Config.getModuleScale("quote", pfx) * lf
                local styles = Config.resolveTextStyles(ctx, Quote.id, Quote.text_elems)
                local SUIStyle = require("features/sui_style")
                -- The quote's own face, as the build resolves it: spacing follows its
                -- pixel size, the mark its font at MARK_SCALE × its point size.
                local qface = SUIStyle.getTextFace(styles.quote, (fontSizes(scale, styles)))
                local fs = qface.size
                local gap = math.max(1, math.floor(Screen:scaleBySize(4) * scale))  -- SimpleUI's quote gap
                local attr_gap = gap + Screen:scaleBySize(4)
                local align = SUISettings:readSetting(pfx .. "simpleui_quote_align") or "center"
                if style == "marginalia" then
                    if align == "center" then
                        return 2 * math.floor(fs * 0.55) + math.max(2, Screen:scaleBySize(1.5)) - gap
                    end
                    return attr_gap - gap
                elseif style == "epigraph" then
                    if align == "center" then
                        local mface = Font:getFace(qface.orig_font, math.floor(qface.orig_size * MARK_SCALE))
                        local mark = inkGlyph("“", mface, nil)
                        return mark:getSize().h + math.floor(fs * 0.35) + attr_gap - gap
                    end
                    return attr_gap - gap
                end
                -- Highlighter: every line padded, a gap between lines.
                local pad_v, line_gap = math.floor(fs * 0.06), math.max(2, math.floor(fs * 0.2))
                return FIXED_LINES * 2 * pad_v + (FIXED_LINES - 1) * line_gap + attr_gap - gap
            end)
            if okx and type(extra) == "number" then return base + math.max(0, extra) end
            logger.warn("simpleui-quote-styles: fixed-height reserve skipped:", extra)
            return base
        end
    end

    Quote._hl_styles_patched = true
end)
