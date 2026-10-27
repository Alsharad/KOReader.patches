-- SimpleUI: Currently Reading tweaks. Three parts, applied in this order:
-- an icon before each statistic, a "Text Spacing" setting, and "Finished" for
-- a book marked finished. One file, so the order they wrap the module in is
-- fixed.
--
-- 1. Statistic icons. With Statistics style "one per line" (default), SimpleUI
-- draws the book's statistics as plain text lines; its only icon, a clock, is
-- drawn before the single compact line. Each line gets an icon instead:
--   time left -> clock (SimpleUI's own clock glyph), days reading -> calendar,
--   time read -> open book.
-- The glyphs come from KOReader's symbols font, the same font and size as
-- SimpleUI's clock, centred on the text line, in the line's colour. The
-- module's "Statistics icon" switch turns them off as it does the clock.
-- How: while the module builds, BookStats.line (called once per row) tells
-- which statistic a row shows, and the row's text widget, made right after by
-- UI.makeColoredText, gets the icon painted to its left. The text keeps
-- SimpleUI's own widget, so in-place refreshes of the numbers still work.
--
-- 2. Text Spacing.
-- The text column beside the cover (series, title, author, progress bar,
-- statistics) uses fixed gaps, and each statistic line takes the font's full
-- line height. This patch adds Appearance ▸ Size ▸ Text Spacing:
--   Default      — SimpleUI's own spacing;
--   Compact      — the gaps cut to 40% and the statistic lines trimmed to
--                  their letters (a margin kept for descenders);
--   Fit to Cover — the spacing adjusted on every draw so the text spans the
--                  cover's height less an even margin above and below the
--                  letters (4% of the cover height each): tightened when the
--                  text is taller, widened (gaps up to 3×) when shorter. When
--                  even the tightest spacing can't fit, that is used.
-- Fit to Cover applies to the fixed cover layout; with Dynamic Cover Size
-- (the cover follows the text) it behaves as Default.
--
-- How: the gaps come from the module's _scaledLayoutDims and its height
-- estimate from SUIStyle.faceHeight, both wrapped while the module builds or
-- measures itself; a statistic line (made by UI.makeColoredText right after
-- BookStats.line) gets KOReader's forced_height. Fit to Cover builds the
-- module up to three times, measuring the text column against the cover.
-- Key: pfx .. "currently_text_spacing" ("default" | "compact" | "fit").
--
-- 3. Finished. A book marked finished (KOReader's Complete, Readest's Finished)
-- before its last page kept showing its position, e.g. 92%, on the progress
-- bar, and a time left. Such a book gets a full bar labelled "Finished" (bar
-- style "With percentage"), and "Finished" in place of the time left (and of
-- the percentage statistic, shown when the bar has no label); a book read to
-- the end without the mark shows 100% as before.
-- The module's bar builder (buildProgressBarWithPct) is private, so it is
-- swapped through build's upvalue, and a flag set around build() and
-- updateStats() says whether the book being drawn is marked finished
-- (added 2026-10-27).
--
-- Hooks by folder name "simpleui". Text Spacing written 2026-10-26, the
-- icons 2026-10-24, the Finished label 2026-10-27, for SimpleUI 3.0 on
-- KOReader v2026.07.2.

local userpatch = require("userpatch")

-- 1. Statistic icons ------------------------------------------------------

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
        logger.warn("simpleui-currently-reading-tweaks (icons): SimpleUI layout changed, icons skipped")
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
        logger.warn("simpleui-currently-reading-tweaks (icons): icon skipped:", w)
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

-- 2. Text Spacing ---------------------------------------------------------

local KEY          = "currently_text_spacing"
local COMPACT_GAP  = 0.4   -- Compact: gap multiplier
local MAX_GAP      = 3     -- Fit to Cover: largest gap multiplier
local FIT_PAD      = 0.04  -- Fit to Cover: margin above and below the text, × cover height
local CAP_HEIGHT   = 0.72  -- capital-letter height, × font size (for the visible top edge)
local DESCENDER    = 0.25  -- room kept below the baseline, × font size
local GAP_KEYS = { "title_gap", "author_gap", "series_gap", "desc_gap",
                   "bar_gap_before", "bar_gap_after", "pct_gap" }

-- Upvalue `name` of fn — or of the function fn wraps, when another patch
-- has already wrapped it (the stat-icons patch keeps it as `orig_build`).
-- Returns the function that owns it, its index and its value.
local function upvalue(fn, name, depth)
    depth = depth or 0
    local wrapped
    for i = 1, 255 do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then break end
        if n == name then return fn, i, v end
        if type(v) == "function" and n:match("^orig") then wrapped = wrapped or v end
    end
    if wrapped and depth < 4 then return upvalue(wrapped, name, depth + 1) end
end

userpatch.registerPatchPluginFunc("simpleui", function()
    local logger = require("logger")
    local okC, Cur       = pcall(require, "modules/module_currently")
    local okB, BookStats = pcall(require, "infra/sui_book_stats")
    local okU, UI        = pcall(require, "infra/sui_core")
    local okS, SUIStyle  = pcall(require, "features/sui_style")
    local okF, Config    = pcall(require, "infra/sui_config")
    if not (okC and okB and okU and okS and okF and type(Cur) == "table"
            and type(Cur.build) == "function" and type(Cur.getHeight) == "function"
            and type(Cur.getMenuItems) == "function" and type(BookStats.line) == "function"
            and type(UI.makeColoredText) == "function" and type(SUIStyle.faceHeight) == "function"
            and type(Config.buildModuleMenu) == "function" and type(Config.makeRadioSubmenuItem) == "function") then
        logger.warn("simpleui-currently-reading-tweaks (text spacing): SimpleUI layout changed, patch skipped")
        return
    end
    if Cur._text_spacing_patched then return end
    local f_dims,  i_dims,  dims  = upvalue(Cur.build, "_scaledLayoutDims")
    local f_cover, i_cover, cover = upvalue(Cur.build, "_computeCoverDims")
    local f_faces, i_faces, faces = upvalue(Cur.getHeight, "_resolveFaces")
    if not (i_dims and i_cover and i_faces) then
        logger.warn("simpleui-currently-reading-tweaks (text spacing): module internals changed, patch skipped")
        return
    end
    Cur._text_spacing_patched = true

    local SUISettings = require("infra/sui_store")
    local Size        = require("ui/size")

    -- While active: gaps × gap_k, statistic lines trimmed by trim (0 = none,
    -- 1 = down to letters + descender room).
    local active, gap_k, trim = false, 1, 0
    local cover_h, stats_face, row_pending, rows = nil, nil, false, nil

    local function mode(pfx)
        local m = SUISettings:readSetting(pfx .. KEY)
        return (m == "compact" or m == "fit") and m or "default"
    end

    debug.setupvalue(f_dims, i_dims, function(scale, styles)
        local LD = dims(scale, styles)
        if active and gap_k ~= 1 then
            for _, k in ipairs(GAP_KEYS) do
                if LD[k] then LD[k] = math.max(0, math.floor(LD[k] * gap_k + 0.5)) end
            end
        end
        return LD
    end)
    debug.setupvalue(f_cover, i_cover, function(...)
        local w, h = cover(...)
        cover_h = h
        return w, h
    end)
    debug.setupvalue(f_faces, i_faces, function(LD, styles)
        local fc, emb = faces(LD, styles)
        stats_face = fc and fc.stats
        return fc, emb
    end)

    local function trimmed(nat, face, baseline)
        local min_h = baseline + math.ceil(face.size * DESCENDER)
        if min_h >= nat then return nat end
        return math.floor(nat - trim * (nat - min_h) + 0.5)
    end

    -- Statistic lines: BookStats.line is called right before each one is made.
    local orig_line = BookStats.line
    BookStats.line = function(...)
        if active then row_pending = true end
        return orig_line(...)
    end
    local orig_text = UI.makeColoredText
    UI.makeColoredText = function(args, ...)
        if not (active and row_pending and type(args) == "table" and args.truncate_with_ellipsis and args.face) then
            return orig_text(args, ...)
        end
        row_pending = false
        -- The line is made once (other patches decorate it when it's made),
        -- so its trimmed height is worked out first, as TextWidget does.
        if trim > 0 and args.face.ftsize then
            local okH, fh, asc = pcall(function() return args.face.ftsize:getHeightAndAscender() end)
            if okH and fh and asc then
                local pad = args.padding or Size.padding.small
                local nat = math.ceil(fh) + 2 * pad
                local h = trimmed(nat, args.face, math.floor(asc + 0.5) + pad)
                if h < nat then
                    local opts = {}
                    for k, v in pairs(args) do opts[k] = v end
                    opts.forced_height = h
                    args = opts
                end
            end
        end
        local w = orig_text(args, ...)
        if rows then rows[#rows + 1] = w end
        return w
    end

    -- Height estimate: the statistic line height the build will use.
    local orig_faceH = SUIStyle.faceHeight
    SUIStyle.faceHeight = function(face, ...)
        local h = orig_faceH(face, ...)
        if active and trim > 0 and face and face == stats_face and face.ftsize then
            local ok, _, asc = pcall(function() return face.ftsize:getHeightAndAscender() end)
            if ok and asc then return trimmed(h, face, math.floor(asc + 0.5)) end
        end
        return h
    end

    -- Runs fn with the given spacing; the previous state comes back after,
    -- so a nested build or height estimate doesn't end the outer one.
    local function with(k, t, fn, ...)
        local was_a, was_k, was_t = active, gap_k, trim
        active, gap_k, trim, row_pending = true, k, t, false
        local res = { pcall(fn, ...) }
        active, gap_k, trim, row_pending = was_a, was_k, was_t, false
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2, table.maxn(res))
    end

    -- The text column: the container whose children include the last line.
    local function parentOf(node, target, depth)
        if type(node) ~= "table" or depth > 12 then return nil end
        for _, child in ipairs(node) do
            if child == target then return node end
            local p = parentOf(child, target, depth + 1)
            if p then return p end
        end
    end
    local function measure(k, t, w, ctx, ...)
        rows, cover_h = {}, nil
        local widget = with(k, t, Cur.build_unspaced, w, ctx, ...)
        local col = rows[#rows] and parentOf(widget, rows[#rows], 0)
        rows = nil
        return widget, col and col:getSize().h, cover_h, col
    end

    -- A span after the text column's last line. The module centres the
    -- column against the cover, so this lifts the text by half of it.
    local VerticalSpan = require("ui/widget/verticalspan")
    local function padBottom(col, pad)
        if not col or pad <= 0 then return end
        table.insert(col, VerticalSpan:new{ width = pad })
        if col.resetLayout then col:resetLayout() else col._size = nil end
    end

    Cur.build_unspaced = Cur.build
    Cur.build = function(w, ctx, ...)
        local pfx = (ctx and ctx.pfx) or ""
        local m = mode(pfx)
        if m == "default" then return Cur.build_unspaced(w, ctx, ...) end
        if m == "compact" then return with(COMPACT_GAP, 1, Cur.build_unspaced, w, ctx, ...) end
        if SUISettings:readSetting(pfx .. "currently_layout") == "dynamic" then
            return Cur.build_unspaced(w, ctx, ...)
        end
        -- Fit to Cover: the text column spans the cover less `pad` above and below.
        local wa, ta, c, cola = measure(1, 0, w, ctx, ...)
        if not (ta and c) then return wa end
        -- The module centres the text column against the cover. Margins are
        -- measured to the letters: the first line's box starts `lead` above
        -- its capitals, so a span of `lead` goes after the last line, and the
        -- text is sized for `pad` above and below the letters.
        local pad = math.floor(c * FIT_PAD + 0.5)
        local lead = 0
        local first = cola and cola[1]
        local inner = first and (first._inner or first)
        if inner and inner.face and inner.getBaseline then
            local okL, base = pcall(inner.getBaseline, inner)
            if okL and base then lead = math.max(0, base - math.floor(inner.face.size * CAP_HEIGHT + 0.5)) end
        end
        lead = math.min(lead, pad)
        local target = c - 2 * pad + lead
        local function done(widget, col, h)
            if h and h + lead <= c then padBottom(col, lead) end
            return widget
        end
        if ta == target then return done(wa, cola, ta) end
        if ta > target then
            local wb, tb, _, colb = measure(0, 1, w, ctx, ...)
            if not tb or tb >= target or tb >= ta then return done(wb, colb, tb) end
            local s = (ta - target) / (ta - tb)      -- 0 → as built, 1 → tightest
            local wf, tf, _, colf = measure(1 - s, s, w, ctx, ...)
            return done(wf, colf, tf)
        end
        local wb, tb = measure(2, 0, w, ctx, ...)
        if not tb or tb <= ta then return done(wa, cola, ta) end
        local k = math.min(MAX_GAP, 1 + (target - ta) / (tb - ta))
        local wf, tf, _, colf = measure(k, 0, w, ctx, ...)
        return done(wf, colf, tf)
    end

    -- Reserved height: Fit to Cover never exceeds the tightest layout, and
    -- reaches the cover's height whenever the text could be shorter.
    local orig_height = Cur.getHeight
    Cur.getHeight = function(ctx, ...)
        local pfx = (ctx and ctx.pfx) or ""
        local m = mode(pfx)
        if m == "compact" then return with(COMPACT_GAP, 1, orig_height, ctx, ...) end
        if m == "fit" and SUISettings:readSetting(pfx .. "currently_layout") ~= "dynamic" then
            return with(0, 1, orig_height, ctx, ...)
        end
        return orig_height(ctx, ...)
    end

    -- Menu: Appearance ▸ Size ▸ Text Spacing, after Cover Spacing.
    local orig_menu = Cur.getMenuItems
    Cur.getMenuItems = function(ctx_menu, ...)
        local orig_build = Config.buildModuleMenu
        Config.buildModuleMenu = function(spec, cm, ...)
            Config.buildModuleMenu = orig_build
            local pfx = (ctx_menu and ctx_menu.pfx) or ""
            local _lc = (ctx_menu and ctx_menu._) or function(s) return s end
            local size = spec and spec.appearance and spec.appearance.size
            if type(size) == "table" then
                size[#size + 1] = Config.makeRadioSubmenuItem{
                    text    = _lc("Text Spacing"),
                    options = {
                        { value = "default", label = _lc("Default") },
                        { value = "compact", label = _lc("Compact") },
                        { value = "fit",     label = _lc("Fit to Cover") },
                    },
                    get     = function() return mode(pfx) end,
                    set     = function(v) SUISettings:saveSetting(pfx .. KEY, v) end,
                    refresh = ctx_menu.refresh,
                }
            end
            return orig_build(spec, cm, ...)
        end
        local ok, res = pcall(orig_menu, ctx_menu, ...)
        Config.buildModuleMenu = orig_build
        if not ok then error(res, 0) end
        return res
    end
end)

-- 3. Finished ---------------------------------------------------------------
local LABEL = "Finished"

userpatch.registerPatchPluginFunc("simpleui", function()
    local logger = require("logger")
    local okC, Cur = pcall(require, "modules/module_currently")
    local okS, SH  = pcall(require, "modules/module_books_shared")
    if not (okC and okS and type(Cur) == "table" and type(Cur.build) == "function"
            and type(Cur.updateStats) == "function" and type(SH) == "table"
            and type(SH.getBookData) == "function") then
        logger.warn("simpleui-currently-reading-tweaks (finished label): module internals changed, patch skipped")
        return
    end
    if Cur._finished_label_patched then return end

    local holder, idx, orig_bar = upvalue(Cur.build_unspaced or Cur.build, "buildProgressBarWithPct")
    local deps = {}
    if type(orig_bar) == "function" then
        for _, n in ipairs({ "UI", "SUIStyle", "HorizontalGroup", "HorizontalSpan",
                             "_BASE_BAR_PCT_GAP", "_BASE_INLINEPCT_FS" }) do
            local _, _, v = upvalue(orig_bar, n)
            deps[n] = v
        end
    end
    if not (holder and deps.UI and deps.SUIStyle and deps.HorizontalGroup and deps.HorizontalSpan
            and deps._BASE_BAR_PCT_GAP and deps._BASE_INLINEPCT_FS) then
        logger.warn("simpleui-currently-reading-tweaks (finished label): progress bar internals changed, patch skipped")
        return
    end
    Cur._finished_label_patched = true

    local RenderText = require("ui/rendertext")
    local Screen = require("device").screen
    local finished = false

    -- Same layout as the module's own bar, with the label sized to "Finished".
    debug.setupvalue(holder, idx, function(w, pct, bar_h, scale, text_scale, face_inline, bold_inline, ink)
        if not finished then
            return orig_bar(w, pct, bar_h, scale, text_scale, face_inline, bold_inline, ink)
        end
        local face, bold = face_inline, bold_inline
        if not face then
            face, bold = deps.SUIStyle.getStyledFace(nil,
                math.max(7, math.floor(deps._BASE_INLINEPCT_FS * scale * text_scale)), "bold")
        end
        local gap = math.max(2, math.floor(deps._BASE_BAR_PCT_GAP * scale))
        local label_w = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, LABEL, true, bold).x + 1
        return deps.HorizontalGroup:new{
            align = "center",
            deps.UI.progressBar(math.max(10, w - gap - label_w), 1, bar_h, ink.bar_fg, ink.bar_bg),
            deps.HorizontalSpan:new{ width = gap },
            deps.UI.makeColoredText{ text = LABEL, face = face, bold = bold, fgcolor = ink.blk, width = label_w },
        }
    end)

    -- The statistics row asks text_of(id) for each statistic it shows.
    local BookStats = require("infra/sui_book_stats")
    local orig_line_finished = BookStats.line
    BookStats.line = function(order, is_visible, text_of, ...)
        if finished and type(text_of) == "function" then
            local text_of_book = text_of
            text_of = function(id)
                if id == "book_remaining" or id == "percent" then return LABEL end
                return text_of_book(id)
            end
        end
        return orig_line_finished(order, is_visible, text_of, ...)
    end

    local function markedFinished(fp, ctx)
        if not fp then return false end
        local bd = SH.getBookData(fp, ctx and ctx.prefetched and ctx.prefetched[fp])
        return bd ~= nil and bd.status == "complete"
    end

    local orig_build = Cur.build
    Cur.build = function(w, ctx, ...)
        finished = markedFinished(ctx and ctx.current_fp, ctx)
        local widget = orig_build(w, ctx, ...)
        finished = false
        return widget
    end

    local orig_updateStats = Cur.updateStats
    Cur.updateStats = function(widget, ctx, ...)
        finished = markedFinished(widget and widget._fp, ctx)
        local r = orig_updateStats(widget, ctx, ...)
        finished = false
        return r
    end
end)
