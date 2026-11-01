local Event = require("ui/event")
local Generic = require("device/generic/device")
local bb10 = require("ffi/bb10")
local cover = require("device/bb10/cover")
local ffi = require("ffi")
local logger = require("logger")

local function yes() return true end
local function no() return false end

local Device = Generic:extend{
    model = "BlackBerry Q10",
    isBB10 = yes,
    home_dir = "/accounts/1000/shared",
    display_dpi = 330,
    hasKeyboard = yes,
    hasKeys = yes,
    hasDPad = no,
    isTouchDevice = yes,
    hasColorScreen = yes,
    hasEinkScreen = no,
    -- RGBX8888 is BGRX in memory (little endian).
    hasBGRFrameBuffer = yes,
    hasFrontlight = no,
    hasWifiToggle = no,
    hasSeamlessWifiToggle = no,
    canSuspend = no,
    canStandby = no,
    canReboot = no,
    canPowerOff = no,
    canRestart = no,
    needsScreenRefreshAfterResume = no,
    canOpenLink = yes,
    openLink = function(self, link)
        return bb10.openLink(link)
    end,
}

function Device:init()
    self.screen = require("ffi/framebuffer_bb10"):new{device = self, debug = logger.dbg}
    self.powerd = require("device/bb10/powerd"):new{device = self}
    local bb10_input = require("ffi/input_bb10")
    self.input = require("device/input"):new{
        device = self,
        event_map = require("device/bb10/event_map"),
        handleMiscEv = function(this, ev)
            local UIManager = require("ui/uimanager")
            if ev.code == bb10_input.MSC_EXIT then
                logger.info("BB10: navigator exit")
                UIManager:broadcastEvent(Event:new("FlushSettings"))
                UIManager:quit()
            elseif ev.code == bb10_input.MSC_WINDOW_STATE then
                local state = ffi.C.NAVIGATOR_WINDOW_FULLSCREEN
                if ev.value == state then
                    bb10.setKeepAwake(true)
                    bb10.grabSideKeys(true)
                    this.device.screen:_updateWindow()
                else
                    -- Minimized to an active frame (or hidden): we may be killed without notice.
                    bb10.setKeepAwake(false)
                    -- Give the volume keys back to the system.
                    bb10.grabSideKeys(false)
                    this.device.input:resetState()
                    UIManager:broadcastEvent(Event:new("FlushSettings"))
                    -- Normally ready already: only re-rendered if something changed.
                    cover:start()
                end
            elseif ev.code == bb10_input.MSC_WINDOW_COVER then
                -- Comes once the event loop runs (the UI is up), with the active frame's size.
                cover:start()
            elseif ev.code == bb10_input.MSC_LOW_MEMORY then
                UIManager:broadcastEvent(Event:new("FlushSettings"))
            end
        end,
    }
    Generic.init(self)
    -- After Generic.init, which applies night mode while the "device" module is still loading.
    self.screen.onNightModeChanged = function()
        local UIManager = require("ui/uimanager")
        UIManager:unschedule(cover.update)
        UIManager:scheduleIn(0.5, cover.update, cover)
    end
    -- Volume keys turn pages instead of changing the volume (while we're in the foreground).
    bb10.grabSideKeys(true)
end

-- The active frame shows the open book.
function Device:notifyBookState(title, document)
    cover:setBook(title, document)
end

function Device:exit()
    Generic.exit(self)
    if self.screen then
        self.screen:close()
    end
end

return Device
