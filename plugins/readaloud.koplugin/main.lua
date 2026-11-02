--[[--
Read aloud: speaks the book sentence by sentence with the device's text-to-speech engine,
and turns the pages along.

The engine is BlackBerry 10's (libs/libkotts.so, see platform/bb10/kotts.c): it speaks a queue
of utterances on its own thread, and we poll it for their start & end. Two sentences are kept
queued, so that there's no gap between them.

@module koplugin.readaloud
]]

local Device = require("device")

if not (Device.isBB10 and Device:isBB10()) then
    return { disabled = true }
end

local Dispatcher = require("dispatcher")
local bb10 = require("ffi/bb10")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

ffi.cdef[[
typedef struct { int id; int what; } kotts_event_t;
int kotts_init(const char *, const char *, int, int, int);
void kotts_set_params(int, int, int);
void kotts_set_voice(const char *);
int kotts_speak(int, const char *);
void kotts_stop(void);
int kotts_poll(kotts_event_t *, int);
void kotts_shutdown(void);
]]

local KOTTS_STARTED, KOTTS_DONE, KOTTS_FAILED, KOTTS_CANCELED = 1, 2, 3, 4
local VOICES_DIR = "/usr/tts/nuance/ve/data"
local POLL_INTERVAL = 0.25
local IN_FLIGHT = 2        -- utterances handed to the engine at once
local MAX_SENTENCE = 300   -- bytes: longer sentences are split at commas or spaces

-- The engine is shared by all the reader instances (one per opened book).
local engine = {
    lib = nil,
    ready = false,
    error = nil,
    events = ffi.new("kotts_event_t[64]"),
}

-- Nuance language codes for a language (ISO 639-1, and region if any), most fitting first.
local NUANCE_LANGUAGES = {
    it = { "ITI" },
    en = { "ENU", "ENG", GB = { "ENG", "ENU" }, UK = { "ENG", "ENU" } },
    fr = { "FRF", "FRC", CA = { "FRC", "FRF" } },
    de = { "GED" },
    es = { "SPE", "SPM", MX = { "SPM", "SPE" } },
    pt = { "PTP", "PTB", BR = { "PTB", "PTP" } },
    ru = { "RUR" },
    pl = { "PLP" },
    nl = { "DUN" },
    nb = { "NON" }, no = { "NON" }, nn = { "NON" },
    ja = { "JPJ" },
    ko = { "KOK" },
    zh = { "MNC", "MNT", "CAH", TW = { "MNT", "MNC" }, HK = { "CAH", "MNT" } },
}
-- ISO 639-2 codes (some books use them).
local ISO639_2 = { ita = "it", eng = "en", fre = "fr", fra = "fr", ger = "de", deu = "de", spa = "es",
    por = "pt", rus = "ru", pol = "pl", dut = "nl", nld = "nl", nor = "nb", nob = "nb", jpn = "ja",
    kor = "ko", chi = "zh", zho = "zh" }

--- The voices whose data is mounted: { {voice = "alice", lang = "ITI"}, ... }. The system mounts
-- only the one chosen in its settings; more can be mounted as root (see the port's README).
local function availableVoices()
    local voices = {}
    local lfs = require("libs/libkoreader-lfs")
    local ok, iter, dir_obj = pcall(lfs.dir, VOICES_DIR)
    if not ok then return voices end
    for lang in iter, dir_obj do
        if lang:match("^%u%u%u$") then
            local ok2, iter2, dir_obj2 = pcall(lfs.dir, VOICES_DIR .. "/" .. lang)
            if ok2 then
                for voice in iter2, dir_obj2 do
                    if voice ~= "." and voice ~= ".." then
                        table.insert(voices, { voice = voice, lang = lang })
                    end
                end
            end
        end
    end
    table.sort(voices, function(a, b) return a.lang < b.lang end)
    return voices
end

--- Language & region of a language tag ("it", "en-GB", "pt_BR", "eng"…).
local function parseLanguage(tag)
    if type(tag) ~= "string" then return end
    local lang, region = tag:lower():match("^(%a+)[-_]?(%a*)")
    if not lang then return end
    lang = ISO639_2[lang] or lang
    return lang, region ~= "" and region:upper() or nil
end

--- The device's language (from LANG, or the region set in the system's settings).
local function deviceLanguage()
    local tag = os.getenv("LANG")
    if not tag or tag == "" or tag == "C" then
        local f = io.open("/pps/services/locale/settings")
        if f then
            tag = f:read("*a"):match("region::(%S+)")
            f:close()
        end
    end
    return tag
end

--- The best mounted voice for a language tag, or nil.
local function voiceForLanguage(tag, voices)
    local lang, region = parseLanguage(tag)
    local codes = lang and NUANCE_LANGUAGES[lang]
    if not codes then return end
    for _, code in ipairs(region and codes[region] or codes) do
        for _, v in ipairs(voices) do
            if v.lang == code then return v end
        end
    end
end

local function startEngine(rate, pitch)
    if engine.ready then
        return true
    end
    if not engine.lib then
        local ok, lib = pcall(ffi.load, "libs/libkotts.so")
        if not ok then
            engine.error = tostring(lib)
            return false
        end
        engine.lib = lib
    end
    local voices = availableVoices()
    local v = voiceForLanguage(deviceLanguage(), voices) or voices[1] or { voice = "alice", lang = "ITI" }
    engine.voice = v.voice
    local ret = engine.lib.kotts_init(nil, engine.voice, rate, pitch, 100)
    if ret ~= 0 then
        engine.error = T("kotts_init: %1", ret)
        logger.warn("ReadAloud: engine init failed:", ret)
        return false
    end
    engine.ready = true
    return true
end

-- Words ending with a period that don't end a sentence (lowercase).
local ABBREVIATIONS = {}
for w in ("sig sigg sig.ra sig.na dott dott.ssa prof prof.ssa avv ing arch geom rag on sen mons "
        .. "dr mr mrs ms st jr sr vs etc ecc cfr pag pagg vol cap fig ca"):gmatch("%S+") do
    ABBREVIATIONS[w] = true
end

--- Text cleanup, then sentences (with no sentence longer than MAX_SENTENCE).
local function splitSentences(text)
    text = text:gsub("\u{00AD}", "")       -- soft hyphens
               :gsub("…", "...")
               :gsub("%s+", " ")
    -- Closing quotes & brackets before the final punctuation, so that it's followed by a space.
    for _ = 1, 2 do
        for _, q in ipairs({ "\"", "'", "”", "’", "»", ")", "]" }) do
            text = text:gsub("([%.!?]+)" .. q:gsub("%p", "%%%0"), q .. "%1")
        end
    end
    local sentences = {}
    local function add(s)
        s = util.trim(s)
        if s == "" then return end
        while #s > MAX_SENTENCE do
            local cut = s:sub(1, MAX_SENTENCE):match("^.*[,;:]() ") or s:sub(1, MAX_SENTENCE):match("^.* ()")
            if not cut or cut < 40 then break end
            table.insert(sentences, util.trim(s:sub(1, cut - 1)))
            s = util.trim(s:sub(cut))
        end
        table.insert(sentences, s)
    end
    local start = 1
    local pos = 1
    while true do
        -- End of sentence: . ! ? followed by a space and not by a lowercase letter (abbreviations).
        local a, b = text:find("[%.!?]+ ", pos)
        if not a then break end
        local next_char = text:sub(b + 1, b + 1)
        local word = text:sub(start, a):match("([%w%.]+)%.$")
        local abbreviation = word and text:sub(a, b) == ". "
            and (ABBREVIATIONS[word:lower()] or word:match("^%a$"))
        if not next_char:match("%l") and not abbreviation then
            add(text:sub(start, b))
            start = b + 1
        end
        pos = b + 1
    end
    local rest = text:sub(start)
    -- Whether the text ends a sentence (else, its last piece goes on in the next page).
    local complete = rest:match("^%s*$") ~= nil or rest:match("[%.!?]%s*$") ~= nil
    add(rest)
    return sentences, complete
end

local ReadAloud = WidgetContainer:extend{
    name = "readaloud",
    is_doc_only = true,
}

function ReadAloud:init()
    self.rate = G_reader_settings:readSetting("readaloud_rate", 100)
    self.pitch = G_reader_settings:readSetting("readaloud_pitch", 100)
    self.state = "stopped" -- or "reading", "paused"
    self.next_id = 0
    self.poll_task = function() self:poll() end
    Dispatcher:registerAction("readaloud_toggle", {
        category = "none", event = "ReadAloudToggle", title = _("Read aloud: start/pause"), reader = true,
    })
    Dispatcher:registerAction("readaloud_stop", {
        category = "none", event = "ReadAloudStop", title = _("Read aloud: stop"), reader = true,
    })
    self.ui.menu:registerToMainMenu(self)
end

--- Text of a page: for reflowable documents (crengine) between this page's & the next one's
-- xpointers, else the page's text boxes (PDF, DjVu).
function ReadAloud:getPageText(page)
    local doc = self.ui.document
    if self.ui.rolling then
        local xp0 = doc:getPageXPointer(page)
        if not xp0 then return "" end
        local xp1 = page < doc:getPageCount() and doc:getPageXPointer(page + 1)
        if not xp1 then
            -- Last page: up to the last word.
            xp1 = xp0
            for _ = 1, 20000 do
                local xp = doc:getNextVisibleWordEnd(xp1)
                if not xp or xp == xp1 then break end
                xp1 = xp
            end
        end
        return doc:getTextFromXPointers(xp0, xp1) or ""
    end
    local ok, boxes = pcall(doc.getPageTextBoxes, doc, page)
    if not ok or type(boxes) ~= "table" then return "" end
    local words = {}
    for _, line in ipairs(boxes) do
        for _, word in ipairs(line) do
            if word.word then table.insert(words, word.word) end
        end
    end
    -- Words hyphenated at the end of a line.
    return (table.concat(words, " "):gsub("(%a)%- (%l)", "%1%2"))
end

--- Load the sentences of `page` (following a sentence begun on the previous page, `carry`).
function ReadAloud:loadPage(page, carry, first)
    local text = self:getPageText(page)
    local sentences, complete = splitSentences((carry or "") .. " " .. text)
    self.page = page
    self.sentences = {}
    for i, s in ipairs(sentences) do
        -- The page is turned when its first sentence starts (or the one after the sentence
        -- begun on the previous page).
        local turn = (i == 1 and not carry) or (i == 2 and carry ~= nil)
        table.insert(self.sentences, { text = s, page = page, turn = turn, index = i })
    end
    self.carry = nil
    if not complete and page < self.ui.document:getPageCount() and #self.sentences > 0 then
        self.carry = table.remove(self.sentences).text
    end
    self.index = first or 1
end

function ReadAloud:nextSentence()
    while self.index > #self.sentences do
        if self.page >= self.ui.document:getPageCount() then
            return nil
        end
        self:loadPage(self.page + 1, self.carry)
    end
    local s = self.sentences[self.index]
    self.index = self.index + 1
    return s
end

function ReadAloud:feed()
    while self.in_flight_count < IN_FLIGHT do
        local s = self:nextSentence()
        if not s then break end
        self.next_id = self.next_id + 1
        if engine.lib.kotts_speak(self.next_id, s.text) ~= 0 then
            logger.warn("ReadAloud: kotts_speak failed")
            break
        end
        self.in_flight[self.next_id] = s
        self.in_flight_count = self.in_flight_count + 1
    end
end

function ReadAloud:poll()
    if self.state ~= "reading" then return end
    local n = engine.lib.kotts_poll(engine.events, 64)
    for i = 0, n - 1 do
        local id, what = engine.events[i].id, engine.events[i].what
        local s = self.in_flight[id]
        if s then
            if what == KOTTS_STARTED then
                self.current = s
                if s.turn and s.page ~= self.ui:getCurrentPage() then
                    self.turning = true
                    self.ui:handleEvent(Event:new("GotoPage", s.page))
                    self.turning = false
                end
            else
                self.in_flight[id] = nil
                self.in_flight_count = self.in_flight_count - 1
                if what == KOTTS_FAILED then
                    logger.warn("ReadAloud: failed to speak:", s.text)
                end
            end
        end
    end
    if self.state ~= "reading" then return end
    self:feed()
    if self.in_flight_count == 0 then
        -- The end of the book.
        self:stop()
        return
    end
    UIManager:scheduleIn(POLL_INTERVAL, self.poll_task)
end

function ReadAloud:_cancel()
    UIManager:unschedule(self.poll_task)
    if engine.ready then
        engine.lib.kotts_stop()
        engine.lib.kotts_poll(engine.events, 64) -- drop the events of what we canceled
    end
    self.in_flight = {}
    self.in_flight_count = 0
end

--- Start reading at `page` (default: the current one), from its `first` sentence.
function ReadAloud:start(page, first)
    if not startEngine(self.rate, self.pitch) then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = T(_("Text-to-speech isn't available:\n%1"), engine.error or "?"),
        })
        return
    end
    self:_cancel()
    self:selectVoice()
    self:loadPage(page or self.ui:getCurrentPage(), nil, first)
    self.current = nil
    self:setState("reading")
    self:feed()
    UIManager:scheduleIn(POLL_INTERVAL, self.poll_task)
end

function ReadAloud:pause()
    if self.state ~= "reading" then return end
    -- Resume with the sentence being spoken.
    local s = self.current
    self.resume_at = s and { page = s.page, index = s.index } or { page = self.page, index = 1 }
    self:_cancel()
    self:setState("paused")
end

function ReadAloud:resume()
    local at = self.resume_at
    self.resume_at = nil
    if at and at.page == self.ui:getCurrentPage() then
        self:start(at.page, at.index)
    else
        self:start()
    end
end

function ReadAloud:stop()
    self:_cancel()
    self:setState("stopped")
    self.resume_at = nil
    self.current = nil
end

--- The voice to read this book with: the chosen one, or (automatic) the one for the book's
-- language, else for the device's language.
function ReadAloud:bookVoice()
    local voices = availableVoices()
    local chosen = G_reader_settings:readSetting("readaloud_voice", "auto")
    if chosen ~= "auto" then
        for _, v in ipairs(voices) do
            if v.voice == chosen then return v.voice end
        end
    end
    local props = self.ui.doc_props or {}
    local v = voiceForLanguage(props.language, voices) or voiceForLanguage(deviceLanguage(), voices)
    return v and v.voice or engine.voice
end

function ReadAloud:selectVoice()
    local voice = self:bookVoice()
    if voice and voice ~= engine.voice then
        logger.info("ReadAloud: voice", voice)
        engine.lib.kotts_set_voice(voice)
        engine.voice = voice
    end
end

-- The middle side key is play/pause while reading (or paused), even with the screen off.
function ReadAloud:setState(state)
    self.state = state
    bb10.setMediaPlayPause(state ~= "stopped")
end

function ReadAloud:onMediaPlayPause()
    if self.state ~= "stopped" then
        self:onReadAloudToggle()
        return true
    end
end

function ReadAloud:onReadAloudToggle()
    if self.state == "reading" then
        self:pause()
    elseif self.state == "paused" then
        self:resume()
    else
        self:start()
    end
    return true
end

function ReadAloud:onReadAloudStop()
    self:stop()
    return true
end

-- Pages turned by hand: go on reading from there.
function ReadAloud:onPageUpdate(page)
    if self.state == "reading" and not self.turning and page ~= (self.current and self.current.page) then
        UIManager:nextTick(function()
            if self.state == "reading" then
                self:start(self.ui:getCurrentPage())
            end
        end)
    end
end

function ReadAloud:onCloseDocument()
    self:stop()
end

function ReadAloud:onCloseWidget()
    self:stop()
end

function ReadAloud:setParam(key, value)
    self[key] = value
    G_reader_settings:saveSetting("readaloud_" .. key, value)
    if engine.ready then
        engine.lib.kotts_set_params(key == "rate" and value or 0, key == "pitch" and value or 0, 0)
    end
end

function ReadAloud:showSpin(key, title, min, max)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = self[key],
        value_min = min,
        value_max = max,
        value_step = 10,
        value_hold_step = 50,
        default_value = 100,
        unit = "%",
        callback = function(spin)
            self:setParam(key, spin.value)
        end,
    })
end

function ReadAloud:voiceMenu()
    local function choose(value)
        G_reader_settings:saveSetting("readaloud_voice", value)
        if self.state == "reading" then
            self:start(self.current and self.current.page, self.current and self.current.index)
        end
    end
    local items = {
        {
            text = _("Automatic (the book's language)"),
            checked_func = function() return G_reader_settings:readSetting("readaloud_voice", "auto") == "auto" end,
            callback = function() choose("auto") end,
            separator = true,
        },
    }
    for _, v in ipairs(availableVoices()) do
        table.insert(items, {
            text = T("%1 (%2)", v.voice:gsub("^%l", string.upper), v.lang),
            checked_func = function() return G_reader_settings:readSetting("readaloud_voice") == v.voice end,
            callback = function() choose(v.voice) end,
        })
    end
    return items
end

function ReadAloud:addToMainMenu(menu_items)
    menu_items.read_aloud = {
        sorting_hint = "tools",
        text = _("Read aloud"),
        sub_item_table = {
            {
                text_func = function()
                    if self.state == "reading" then return _("Pause") end
                    if self.state == "paused" then return _("Resume") end
                    return _("Start reading from this page")
                end,
                callback = function(touchmenu_instance)
                    touchmenu_instance:closeMenu()
                    self:onReadAloudToggle()
                end,
            },
            {
                text = _("Stop"),
                enabled_func = function() return self.state ~= "stopped" end,
                callback = function(touchmenu_instance)
                    touchmenu_instance:closeMenu()
                    self:stop()
                end,
                separator = true,
            },
            {
                text_func = function() return T(_("Speed: %1 %"), self.rate) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showSpin("rate", _("Speech speed"), 50, 300)
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text_func = function() return T(_("Pitch: %1 %"), self.pitch) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showSpin("pitch", _("Voice pitch"), 50, 200)
                    touchmenu_instance:updateItems()
                end,
                separator = true,
            },
            {
                text_func = function()
                    local chosen = G_reader_settings:readSetting("readaloud_voice", "auto")
                    local voice = self:bookVoice() or "?"
                    voice = voice:gsub("^%l", string.upper)
                    if chosen == "auto" then
                        return T(_("Voice: %1 (book language)"), voice)
                    end
                    return T(_("Voice: %1"), voice)
                end,
                sub_item_table_func = function()
                    return self:voiceMenu()
                end,
            },
        },
    }
end

return ReadAloud
