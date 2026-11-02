--[[--
BlackBerry 10 active frame (the navigator's "window cover", shown while KOReader is minimized):
the open book's cover, title & authors, or the KOReader logo when no book is open.
White, or black in night mode.

It's rendered to a PNG in the cache dir, only when something changes (book, night mode, size).
Fed by the device: `setBook` (Device:notifyBookState), `start` (once the UI is up), `update`.

@module device.bb10.cover
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local bb10 = require("ffi/bb10")
local logger = require("logger")

local Cover = {
    book = nil,        -- { title = , authors = , image = (BB, ours) } while a book is open
    book_serial = 0,   -- bumped on each setBook (also cancels a pending cover image load)
    shown_key = nil,   -- what the navigator currently shows
    file = nil,        -- the PNG the navigator shows: a new name each time (it caches them by path)
    file_serial = 0,
    started = false,   -- fonts & widgets are usable
}

-- Faces at exact pixel sizes (Font:getFace scales its size by Screen:scaleBySize).
local function getFace(name, px)
    local Font = require("ui/font")
    local Screen = require("device").screen
    return Font:getFace(name, px * 1000 / Screen:scaleBySize(1000))
end

local function textBox(text, px, bold, width, max_lines, fgcolor, bgcolor, alignment)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local face = getFace("cfont", px)
    local box = TextBoxWidget:new{
        text = text,
        face = face,
        bold = bold,
        width = width,
        alignment = alignment or "left",
        fgcolor = fgcolor,
        bgcolor = bgcolor,
    }
    if box:getSize().h > box:getLineHeight() * max_lines + 1 then
        box:free()
        box = TextBoxWidget:new{
            text = text,
            face = face,
            bold = bold,
            width = width,
            height = math.ceil(box:getLineHeight() * max_lines),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = alignment or "left",
            fgcolor = fgcolor,
            bgcolor = bgcolor,
        }
    end
    return box
end

function Cover:_render(w, h, night)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local bg = night and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = night and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local fg2 = night and Blitbuffer.COLOR_GRAY_B or Blitbuffer.COLOR_DARK_GRAY
    local pad = math.floor(h * 0.07)
    local widget

    if self.book then
        local text_w = w - 2 * pad
        local group = HorizontalGroup:new{ align = "center" }
        local image = self.book.image
        if image then
            local iw, ih = image:getWidth(), image:getHeight()
            local scale = math.min((h - 2 * pad) / ih, (w * 0.42) / iw)
            local cw, ch = math.max(1, math.floor(iw * scale + 0.5)), math.max(1, math.floor(ih * scale + 0.5))
            table.insert(group, ImageWidget:new{
                image = image,
                image_disposable = false,
                width = cw,
                height = ch,
                original_in_nightmode = false, -- we paint to our own (never inverted) buffer
            })
            table.insert(group, HorizontalSpan:new{ width = pad })
            text_w = text_w - cw - pad
        end
        local texts = VerticalGroup:new{
            align = "left",
            textBox(self.book.title, 21, true, text_w, self.book.authors and 4 or 6, fg, bg),
        }
        if self.book.authors then
            table.insert(texts, VerticalSpan:new{ width = math.floor(pad / 2) })
            table.insert(texts, textBox(self.book.authors, 16, false, text_w, 2, fg2, bg))
        end
        table.insert(group, texts)
        widget = group
    else
        local logo_h = math.floor(h * 0.62)
        widget = VerticalGroup:new{
            align = "center",
            ImageWidget:new{
                file = "resources/koreader.png",
                file_do_cache = false,
                width = logo_h,
                height = logo_h,
                scale_factor = 0,
                alpha = true,
                original_in_nightmode = false,
            },
            VerticalSpan:new{ width = math.floor(pad / 2) },
            textBox("KOReader", 22, true, w - 2 * pad, 1, night and Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_GRAY_2,
                    bg, "center"),
        }
    end

    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    bb:fill(bg)
    local size = widget:getSize()
    widget:paintTo(bb, math.floor((w - size.w) / 2), math.floor((h - size.h) / 2))
    widget:free()
    return bb
end

--- Render & show the active frame, if anything changed since the last time.
function Cover:update()
    if not self.started then
        return
    end
    local night = G_reader_settings:isTrue("night_mode")
    local w, h = bb10.cover_width, bb10.cover_height
    local key = table.concat({ self.book_serial, self.book and self.book.image and "i" or "-",
                               tostring(night), w, h }, ":")
    if key == self.shown_key then
        return
    end
    local ok, err = pcall(function()
        local bb = self:_render(w, h, night)
        -- Own subdirectory: DocCache treats every plain file in cache/ as one of its items,
        -- and a PNG we delete behind its back made DocCache:serialize() crash on close.
        local lfs = require("libs/libkoreader-lfs")
        local cache = DataStorage:getDataDir() .. "/cache"
        local dir = cache .. "/bb10-cover"
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
            -- Leftovers of older builds, which wrote them straight into cache/.
            for name in lfs.dir(cache) do
                if name:match("^bb10%-cover%-.*%.png$") then
                    os.remove(cache .. "/" .. name)
                end
            end
        end
        self.file_serial = self.file_serial + 1
        local file = string.format("%s/bb10-cover-%d-%d.png", dir, os.time(), self.file_serial)
        -- Our color buffers are BGR (Device:hasBGRFrameBuffer).
        bb:writePNG(file, true)
        bb:free()
        local set, set_err = bb10.setCover(file)
        if not set then
            os.remove(file)
            error("navigator_window_cover_update: " .. tostring(set_err))
        end
        -- Drop the older ones (also those left by previous runs).
        for name in lfs.dir(dir) do
            if name:match("^bb10%-cover%-.*%.png$") and dir .. "/" .. name ~= file then
                os.remove(dir .. "/" .. name)
            end
        end
        self.file = file
    end)
    if ok then
        self.shown_key = key
        logger.dbg("BB10: active frame updated", key)
    else
        logger.warn("BB10: active frame update failed:", err)
    end
end

function Cover:start()
    self.started = true
    self:update()
end

--- A book was opened (title & document) or closed (nil).
function Cover:setBook(title, document)
    if self.book and self.book.image then
        self.book.image:free()
    end
    self.book = nil
    self.book_serial = self.book_serial + 1
    if document then
        local authors
        local ok, ReaderUI = pcall(require, "apps/reader/readerui")
        local props = ok and ReaderUI.instance and ReaderUI.instance.doc_props
        if props and props.authors and props.authors ~= "" then
            authors = props.authors:gsub("\n", ", ")
        end
        self.book = {
            title = title or (document.file or ""):match("([^/]+)$") or "",
            authors = authors,
        }
        -- The cover image can take a while (PDF page rendering): later, not to delay the book's opening.
        local serial = self.book_serial
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(1, function()
            if serial ~= self.book_serial or not document.is_open then
                return
            end
            local cover_ok, image = pcall(function()
                return require("apps/filemanager/filemanagerbookinfo"):getCoverImage(document)
            end)
            if cover_ok and image then
                -- Keep a small copy only.
                local max_h = 2 * bb10.cover_height
                if image:getHeight() > max_h then
                    image = require("ui/renderimage"):scaleBlitBuffer(image,
                        math.floor(image:getWidth() * max_h / image:getHeight()), max_h, true)
                end
                self.book.image = image
            elseif not cover_ok then
                logger.warn("BB10: no cover image:", image)
            end
            self:update()
        end)
    end
    self:update()
end

return Cover
