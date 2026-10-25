-- KOReader: a one-finger swipe down anywhere on the page opens the top menu.
--
-- KOReader opens its top menu with a tap or a swipe down in the top part of
-- the screen. On devices where a swipe from the very top edge belongs to the
-- system (Android's notification panel, for one), that swipe often opens the
-- system panel instead. With this patch the swipe can start anywhere on the
-- page.
--
-- In page view a one-finger vertical swipe does nothing (page turns are
-- left/right; only a mouse wheel moves pages vertically), so this takes
-- nothing away. Scroll view keeps its vertical swipes for scrolling, and edge
-- gestures (frontlight on the left/right edges, KOReader's own top-zone menu
-- swipe) are matched first and behave as before. Reflowable books (EPUB,
-- FB2, …) only; PDFs and comics are unchanged.
--
-- Written 2026-10-25 for KOReader v2026.07.2.

local ReaderRolling = require("apps/reader/modules/readerrolling")
local Event = require("ui/event")

local orig_onSwipe = ReaderRolling.onSwipe
ReaderRolling.onSwipe = function(self, arg, ges)
    if orig_onSwipe(self, arg, ges) then return true end
    if ges and ges.direction == "south" and not ges.mousewheel_direction
            and self.view.view_mode == "page" then
        self.ui:handleEvent(Event:new("ShowMenu"))
        return true
    end
end
