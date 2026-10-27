-- Kindle Scribe: start in the rotation KOReader closed with.
--
-- KOReader saves the rotation on exit (closed_rotation_mode) and restores it
-- on start. On the Kindle Scribe the device init then asks the Kindle's
-- window manager for the accelerometer orientation and rotates to that
-- instead. The window manager is paused (SIGSTOP) while KOReader runs, so it
-- answers with what the stock UI last saw ("U", upright), not how the Kindle
-- is held: KOReader comes up upside down for a reader who holds it the other
-- way, until the device is turned around and back.
--
-- This patch puts the saved rotation back before the first screen is shown.
-- Auto-rotation by the accelerometer while KOReader runs is unchanged.
--
-- Install as koreader/patches/2-kindle-scribe-keep-rotation.lua. On any other
-- device it does nothing.
-- Written 2026-10-27 for KOReader v2026.07.2 on a Kindle Scribe (2022).

local Device = require("device")
if not (Device:isKindle() and Device.model and Device.model:find("^KindleScribe")) then return end

local mode = G_reader_settings:readSetting("closed_rotation_mode")
if mode and mode ~= Device.screen:getRotationMode() then
    Device.screen:setRotationMode(mode)
end
