-- SimpleUI: leaving a "Group by Book Series" view really leaves it.
--
-- Inside a series group (a virtual folder SimpleUI shows in place of the real
-- one), the Library tab and the title-bar back arrow both go to the real
-- folder with changeToPath(). SimpleUI keeps a "series open" marker so it can
-- re-enter the group after a book is closed, and clears it in its
-- FileChooser.updateItems hook. In KOReader's cover views CoverBrowser
-- replaces FileChooser.updateItems with its own every time the Library opens,
-- so that hook never runs, the marker stays set, and the refresh that follows
-- changeToPath() re-opens the series at once — the page looks stuck.
--
-- This patch sends a changeToPath() to the series' own folder (or "..")
-- through SimpleUI's SeriesGrouping.exitSeriesView(), which clears the marker
-- first. Any other path is passed through untouched.
--
-- Hooks by folder name "simpleui". Written 2026-10-25 for SimpleUI 3.0 on
-- KOReader v2026.07.2.

local userpatch = require("userpatch")

local function norm(p)
    return p and (p:gsub("/+$", "")) or p
end

userpatch.registerPatchPluginFunc("simpleui", function()
    local logger = require("logger")
    local okS, SG = pcall(require, "features/library/sui_series_grouping")
    if not (okS and SG.isInSeriesView and SG.exitSeriesView) then
        logger.warn("simpleui-series-view-exit: SeriesGrouping not found, patch skipped")
        return
    end
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._series_view_exit_patched then return end
    FileChooser._series_view_exit_patched = true

    local orig_changeToPath = FileChooser.changeToPath
    FileChooser.changeToPath = function(fc, path, ...)
        if SG.isInSeriesView(fc) then
            local parent = norm(fc.item_table._sg_parent_path)
            local target = norm(path)
            if parent and target and (target == parent or target:match("/%.%.$") or target == "..") then
                SG.exitSeriesView(fc)
                return
            end
        end
        return orig_changeToPath(fc, path, ...)
    end
end)
