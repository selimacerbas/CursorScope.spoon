-- CursorScope.spoon (draggable scope, per-screen positions, rich menubar)
-- Author: Selim Acerbas
-- License: MIT

local obj              = {}
obj.__index            = obj

obj.name               = "CursorScope"
obj.version            = "0.0.3" -- fix self-at-top errors, add Zoom/Size menus, dynamic canvas sizing
obj.author             = "Selim Acerbas"
obj.homepage           = "https://www.github.com/selimacerbas/CursorScope.spoon/"
obj.license            = "MIT"

-- =====================
-- Defaults
-- =====================
obj._cfg               = {
    global = {
        fps = 30, -- render rate for follow/scope
    },
    cursor = {
        shape      = "ring", -- "ring" | "crosshair" | "dot"
        idleColor  = { red = 0, green = 0.6, blue = 1, alpha = 0.9 },
        clickColor = { red = 1, green = 0, blue = 0, alpha = 0.95 },
        radius     = 28,
        lineWidth  = 4, -- thickness for crosshair arms and ring stroke
    },
    scope = {
        enabled      = true,        -- show/hide scope entirely
        size         = 220,         -- px (square)
        zoom         = 2.0,         -- 1.5–4.0 recommended
        shape        = "rectangle", -- "rectangle" | "circle"
        cornerRadius = 12,          -- for rectangle
        borderWidth  = 2,
        borderColor  = { red = 1, green = 1, blue = 1, alpha = 0.9 },
        background   = { red = 0, green = 0, blue = 0, alpha = 0.25 },
        topLeft      = nil, -- absolute top-left on current screen
    },
}

-- =====================
-- State
-- =====================
obj._running           = false
obj._log               = hs.logger.new("CursorScope", "info")
obj._menubar           = nil
obj._highlightCircle   = nil -- ring
obj._dot               = nil -- dot
obj._crosshairCanvas   = nil -- canvas with 2 rects: ids "h" and "v"
obj._scopeCanvas       = nil
obj._scopeShapeApplied = nil
obj._scopeSizeApplied  = nil
obj._mouseTap          = nil
obj._dragTap           = nil
obj._timer             = nil
obj._timerFPS          = nil
obj._lastPos           = hs.mouse.absolutePosition()
obj._lastScreen        = nil
obj._currentColor      = obj._cfg.cursor.idleColor
obj._posByScreen       = {} -- per-screen saved positions { [screenId] = {x=..,y=..} }

-- Drag state for scope
obj._dragging          = false
obj._dragOffset        = nil -- offset inside the canvas where the drag began

obj.defaultHotkeys     = {
    start = { { "ctrl", "alt", "cmd" }, "Z" },
    stop  = { { "ctrl", "alt", "cmd" }, "U" },
}

-- =====================
-- Utils
-- =====================
local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end
local function deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then deepMerge(dst[k], v) else dst[k] = v end
    end
end
local function rectsIntersect(a, b)
    return not (a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y)
end
local function _screenFrame(screen)
    return (screen or hs.screen.mainScreen()):fullFrame()
end
local function _clampTopLeftToScreen(self, screen, tl)
    local sf = _screenFrame(screen)
    local sz = self._cfg.scope.size
    local x  = clamp((tl and tl.x) or (sf.x + 20), sf.x, sf.x + sf.w - sz)
    local y  = clamp((tl and tl.y) or (sf.y + 80), sf.y, sf.y + sf.h - sz)
    return { x = x, y = y }
end
local function _resolveTopLeftForScreen(self, screen)
    local sid = screen:id()
    local saved = self._posByScreen and self._posByScreen[sid]
    if saved then return _clampTopLeftToScreen(self, screen, saved) end

    local s = self._cfg.scope
    local sz = s.size
    local sf = _screenFrame(screen)

    if self._lastScreen and s.topLeft then
        local prevSF = _screenFrame(self._lastScreen)
        local rx = (s.topLeft.x - prevSF.x) / math.max(1, (prevSF.w - sz))
        local ry = (s.topLeft.y - prevSF.y) / math.max(1, (prevSF.h - sz))
        rx = clamp(rx, 0, 1); ry = clamp(ry, 0, 1)
        local tl = { x = sf.x + math.floor(rx * (sf.w - sz)), y = sf.y + math.floor(ry * (sf.h - sz)) }
        return _clampTopLeftToScreen(self, screen, tl)
    end

    local tl = { x = sf.x + sf.w - sz - 20, y = sf.y + sf.h - sz - 80 }
    return _clampTopLeftToScreen(self, screen, tl)
end

-- =====================
-- Config
-- =====================
function obj:configure(cfg)
    if type(cfg) ~= "table" then return self end
    if cfg.global then deepMerge(self._cfg.global, cfg.global) end
    if cfg.cursor then deepMerge(self._cfg.cursor, cfg.cursor) end
    if cfg.scope then deepMerge(self._cfg.scope, cfg.scope) end

    if self._running then
        self:_restartRenderTimerIfNeeded()
        if self._cfg.scope.enabled then
            self:_ensureScopeOnScreen(hs.mouse.getCurrentScreen() or hs.screen.mainScreen())
        else
            if self._scopeCanvas then
                self._scopeCanvas:delete(); self._scopeCanvas = nil
            end
        end
        self:_updateMenubarIcon()
        self:_buildHighlight()
    end
    return self
end

-- =====================
-- Menubar
-- =====================
local function _fixedIconImage()
    return hs.image.imageFromName("NSSearchTemplate")
end
function obj:_updateMenubarIcon()
    if not self._menubar then return end
    local img = _fixedIconImage()
    if img then
        self._menubar:setIcon(img, true)
        self._menubar:setTitle(nil)
    else
        self._menubar:setIcon(nil)
        self._menubar:setTitle("CS")
    end
end

function obj:_menuItems()
    local items = {}

    -- Scope enable/disable
    table.insert(items, {
        title   = self._cfg.scope.enabled and "Scope: Enabled" or "Scope: Disabled",
        checked = self._cfg.scope.enabled,
        fn      = function() self:setScopeEnabled(not self._cfg.scope.enabled) end
    })

    -- Scope shape submenu
    table.insert(items, {
        title = "Scope Shape",
        menu = {
            {
                title = "Rectangle",
                checked = (self._cfg.scope.shape == "rectangle"),
                fn = function()
                    if self._cfg.scope.shape ~= "rectangle" then
                        self._cfg.scope.shape = "rectangle"
                        if self._running then
                            local scr = hs.mouse.getCurrentScreen() or self._lastScreen or hs.screen.mainScreen()
                            self:_ensureScopeOnScreen(scr)
                        end
                    end
                end
            },
            {
                title = "Circle",
                checked = (self._cfg.scope.shape == "circle"),
                fn = function()
                    if self._cfg.scope.shape ~= "circle" then
                        self._cfg.scope.shape = "circle"
                        if self._running then
                            local scr = hs.mouse.getCurrentScreen() or self._lastScreen or hs.screen.mainScreen()
                            self:_ensureScopeOnScreen(scr)
                        end
                    end
                end
            },
        }
    })

    -- Cursor shape submenu
    table.insert(items, {
        title = "Cursor Shape",
        menu = {
            {
                title = "Ring",
                checked = (self._cfg.cursor.shape == "ring"),
                fn = function()
                    if self._cfg.cursor.shape ~= "ring" then
                        self._cfg.cursor.shape = "ring"; if self._running then self:_buildHighlight() end
                    end
                end
            },
            {
                title = "Crosshair",
                checked = (self._cfg.cursor.shape == "crosshair"),
                fn = function()
                    if self._cfg.cursor.shape ~= "crosshair" then
                        self._cfg.cursor.shape = "crosshair"; if self._running then self:_buildHighlight() end
                    end
                end
            },
            {
                title = "Dot",
                checked = (self._cfg.cursor.shape == "dot"),
                fn = function()
                    if self._cfg.cursor.shape ~= "dot" then
                        self._cfg.cursor.shape = "dot"; if self._running then self:_buildHighlight() end
                    end
                end
            },
        }
    })

    -- FPS submenu (common presets + Custom…)
    local currentFPS = math.max(1, tonumber(self._cfg.global.fps) or 30)
    local fpsChoices = { 15, 24, 30, 45, 60 }
    local fpsSub = {}
    for _, f in ipairs(fpsChoices) do
        table.insert(fpsSub, {
            title = tostring(f) .. " fps",
            checked = (currentFPS == f),
            fn = function()
                if self._cfg.global.fps ~= f then
                    self._cfg.global.fps = f
                    if self._running then self:_restartRenderTimerIfNeeded() end
                end
            end
        })
    end
    table.insert(fpsSub, {
        title = "Custom…",
        fn = function()
            if hs.dialog and hs.dialog.textPrompt then
                local btn, text = hs.dialog.textPrompt("Set FPS", "Enter a number (1–144)", tostring(currentFPS), "OK",
                    "Cancel")
                if btn == "OK" then
                    local val = tonumber(text)
                    if val then
                        val = math.max(1, math.min(144, math.floor(val)))
                        if self._cfg.global.fps ~= val then
                            self._cfg.global.fps = val
                            if self._running then self:_restartRenderTimerIfNeeded() end
                        end
                    end
                end
            else
                hs.alert.show("hs.dialog not available; use presets.")
            end
        end
    })
    table.insert(items, { title = "FPS", menu = fpsSub })

    -- Zoom submenu
    local currentZoom = tonumber(self._cfg.scope.zoom) or 2.0
    local zoomChoices = { 1.5, 2.0, 3.0, 4.0 }
    local zoomSub = {}
    for _, z in ipairs(zoomChoices) do
        table.insert(zoomSub, {
            title = tostring(z) .. "×",
            checked = (math.abs(currentZoom - z) < 0.001),
            fn = function()
                if self._cfg.scope.zoom ~= z then
                    self._cfg.scope.zoom = z
                end
            end
        })
    end
    table.insert(zoomSub, {
        title = "Custom…",
        fn = function()
            if hs.dialog and hs.dialog.textPrompt then
                local btn, text = hs.dialog.textPrompt("Set Zoom", "Enter a number (1.0–8.0)", tostring(currentZoom),
                    "OK", "Cancel")
                if btn == "OK" then
                    local val = tonumber(text)
                    if val then
                        val = math.max(1.0, math.min(8.0, val))
                        self._cfg.scope.zoom = val
                    end
                end
            else
                hs.alert.show("hs.dialog not available; use presets.")
            end
        end
    })
    table.insert(items, { title = "Zoom", menu = zoomSub })

    -- Size submenu
    local currentSize = tonumber(self._cfg.scope.size) or 220
    local sizeOptions = {
        { label = "Small",  v = 160 },
        { label = "Medium", v = 220 },
        { label = "Large",  v = 320 },
    }
    local sizeSub = {}
    for _, opt in ipairs(sizeOptions) do
        table.insert(sizeSub, {
            title = opt.label .. " (" .. tostring(opt.v) .. ")",
            checked = (currentSize == opt.v),
            fn = function()
                if self._cfg.scope.size ~= opt.v then
                    self._cfg.scope.size = opt.v
                    if self._running then
                        local scr = hs.mouse.getCurrentScreen() or self._lastScreen or hs.screen.mainScreen()
                        self:_ensureScopeOnScreen(scr)
                    end
                end
            end
        })
    end
    table.insert(sizeSub, {
        title = "Custom…",
        fn = function()
            if hs.dialog and hs.dialog.textPrompt then
                local btn, text = hs.dialog.textPrompt("Set Size", "Enter pixels (min 120, max 600)",
                    tostring(currentSize), "OK", "Cancel")
                if btn == "OK" then
                    local val = tonumber(text)
                    if val then
                        val = math.max(120, math.min(600, math.floor(val)))
                        if self._cfg.scope.size ~= val then
                            self._cfg.scope.size = val
                            if self._running then
                                local scr = hs.mouse.getCurrentScreen() or self._lastScreen or hs.screen.mainScreen()
                                self:_ensureScopeOnScreen(scr)
                            end
                        end
                    end
                end
            else
                hs.alert.show("hs.dialog not available; use presets.")
            end
        end
    })
    table.insert(items, { title = "Size", menu = sizeSub })

    table.insert(items, { title = "-" }) -- separator
    table.insert(items, { title = self._running and "Stop" or "Start", fn = function() self:toggle() end })
    table.insert(items, { title = "Exit CursorScope", fn = function() self:stop() end })

    return items
end

function obj:_ensureMenubar(on)
    if on and not self._menubar then
        self._menubar = hs.menubar.new()
        if self._menubar then
            self:_updateMenubarIcon()
            self._menubar:setTooltip("CursorScope")
            self._menubar:setMenu(function() return self:_menuItems() end)
        end
    elseif not on and self._menubar then
        self._menubar:delete(); self._menubar = nil
    end
end

-- =====================
-- Cursor highlight
-- =====================
function obj:_destroyHighlight()
    local function kill(x) if x then x:delete() end end
    kill(self._highlightCircle); self._highlightCircle = nil
    kill(self._dot); self._dot = nil
    if self._crosshairCanvas then
        self._crosshairCanvas:delete(); self._crosshairCanvas = nil
    end
end

function obj:_buildHighlight()
    self:_destroyHighlight()
    local c = self._cfg.cursor
    self._currentColor = c.idleColor
    local pos = hs.mouse.absolutePosition()
    local r, lw = c.radius, math.max(1, math.floor(c.lineWidth or 2))
    local cx, cy = pos.x, pos.y

    if c.shape == "ring" then
        local frame = hs.geometry.rect(cx - r, cy - r, 2 * r, 2 * r)
        local d = hs.drawing.circle(frame)
        d:setStroke(true):setFill(false):setStrokeColor(c.idleColor):setStrokeWidth(c.lineWidth)
        d:setBehaviorByLabels({ "canJoinAllSpaces" }):setLevel(hs.drawing.windowLevels.overlay)
        if d.setClickThrough then d:setClickThrough(true) end
        d:show()
        self._highlightCircle = d
    elseif c.shape == "crosshair" then
        local frame = hs.geometry.rect(cx - r, cy - r, 2 * r, 2 * r)
        local cv = hs.canvas.new(frame)
        cv:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
        cv:level(hs.canvas.windowLevels.overlay)
        if cv.clickThrough then cv:clickThrough(true) end
        cv[#cv + 1] = { id = "h", type = "rectangle", action = "fill", fillColor = c.idleColor, frame = { x = 0, y = r - math.floor(lw / 2), w = 2 * r, h = lw } }
        cv[#cv + 1] = { id = "v", type = "rectangle", action = "fill", fillColor = c.idleColor, frame = { x = r - math.floor(lw / 2), y = 0, w = lw, h = 2 * r } }
        cv:show()
        self._crosshairCanvas = cv
    else -- dot
        local d = hs.drawing.circle(hs.geometry.rect(cx - r / 2, cy - r / 2, r, r))
        d:setFill(true):setStroke(false):setFillColor(c.idleColor)
        d:setBehaviorByLabels({ "canJoinAllSpaces" }):setLevel(hs.drawing.windowLevels.overlay)
        if d.setClickThrough then d:setClickThrough(true) end
        d:show()
        self._dot = d
    end
end

function obj:_recolorHighlight(col)
    self._currentColor = col
    if self._highlightCircle then self._highlightCircle:setStrokeColor(col) end
    if self._crosshairCanvas then
        self._crosshairCanvas["h"].fillColor = col
        self._crosshairCanvas["v"].fillColor = col
    end
    if self._dot then self._dot:setFillColor(col) end
end

function obj:_moveHighlight(pos)
    local r = self._cfg.cursor.radius
    if self._highlightCircle then
        self._highlightCircle:setFrame(hs.geometry.rect(pos.x - r, pos.y - r, 2 * r, 2 * r))
    end
    if self._crosshairCanvas then
        self._crosshairCanvas:frame(hs.geometry.rect(pos.x - r, pos.y - r, 2 * r, 2 * r))
    end
    if self._dot then
        self._dot:setFrame(hs.geometry.rect(pos.x - r / 2, pos.y - r / 2, r, r))
    end
end

-- =====================
-- Scope (canvas)
-- =====================
local function _frameFromTopLeft(self, screen, tl)
    local sz = self._cfg.scope.size
    local clamped = _clampTopLeftToScreen(self, screen, tl)
    return hs.geometry.rect(clamped.x, clamped.y, sz, sz), clamped
end
function obj:_buildScopeCanvas(frame)
    if self._scopeCanvas then
        self._scopeCanvas:delete(); self._scopeCanvas = nil
    end
    local s  = self._cfg.scope
    local sz = s.size
    local cv = hs.canvas.new(frame)
    cv:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    cv:level(hs.canvas.windowLevels.overlay)

    local shape = s.shape or "rectangle"
    if shape == "circle" then
        cv[#cv + 1] = { id = "clip", type = "oval", action = "clip", frame = { x = 0, y = 0, w = sz, h = sz } }
        cv[#cv + 1] = { id = "bg", type = "rectangle", action = "fill", fillColor = s.background, frame = { x = 0, y = 0, w = sz, h = sz } }
        cv[#cv + 1] = { id = "img", type = "image", image = nil, imageScaling = "scaleToFit", frame = { x = 0, y = 0, w = sz, h = sz } }
        cv[#cv + 1] = { id = "reset", type = "resetClip" }
        cv[#cv + 1] = {
            id = "border",
            type = "oval",
            action = "stroke",
            strokeColor = s.borderColor,
            strokeWidth = s
                .borderWidth,
            frame = { x = 0, y = 0, w = sz, h = sz }
        }
    else
        cv[#cv + 1] = { id = "bg", type = "rectangle", action = "fill", fillColor = s.background, frame = { x = 0, y = 0, w = sz, h = sz }, roundedRectRadii = { xRadius = s.cornerRadius, yRadius = s.cornerRadius } }
        cv[#cv + 1] = { id = "img", type = "image", image = nil, imageScaling = "scaleToFit", frame = { x = 0, y = 0, w = sz, h = sz } }
        cv[#cv + 1] = {
            id = "border",
            type = "rectangle",
            action = "stroke",
            strokeColor = s.borderColor,
            strokeWidth =
                s.borderWidth,
            frame = { x = 0, y = 0, w = sz, h = sz },
            roundedRectRadii = { xRadius = s.cornerRadius, yRadius = s.cornerRadius }
        }
    end

    -- In-canvas dragging with Cmd+Alt (some systems deliver events here more reliably)
    if cv.clickActivating then cv:clickActivating(false) end
    cv:mouseCallback(function(canvas, event, id, x, y)
        local mods = hs.eventtap.checkKeyboardModifiers() or {}
        local cmdAlt = (mods.cmd == true) and (mods.alt == true)
        if event == "mouseDown" then
            if cmdAlt then
                self._dragging   = true
                self._dragOffset = { x = x, y = y }
            end
        elseif event == "mouseUp" then
            self._dragging   = false
            self._dragOffset = nil
        elseif event == "mouseMove" and self._dragging then
            if not cmdAlt then return end
            local frameNow = canvas:frame()
            local newX     = frameNow.x + (x - self._dragOffset.x)
            local newY     = frameNow.y + (y - self._dragOffset.y)
            local scr      = hs.mouse.getCurrentScreen() or self._lastScreen or hs.screen.mainScreen()
            local sf       = (scr or hs.screen.mainScreen()):fullFrame()
            newX           = clamp(newX, sf.x, sf.x + sf.w - frameNow.w)
            newY           = clamp(newY, sf.y, sf.y + sf.h - frameNow.h)
            canvas:frame({ x = newX, y = newY, w = frameNow.w, h = frameNow.h })
            self._cfg.scope.topLeft = { x = newX, y = newY }
            if scr and scr.id then self._posByScreen[scr:id()] = { x = newX, y = newY } end
        end
    end)

    self._scopeCanvas       = cv
    self._scopeShapeApplied = shape
    self._scopeSizeApplied  = sz
    cv:show()
end

function obj:_ensureScopeOnScreen(screen)
    if not self._cfg.scope.enabled then
        if self._scopeCanvas then
            self._scopeCanvas:delete(); self._scopeCanvas = nil
        end
        return
    end

    local tl = _resolveTopLeftForScreen(self, screen)
    local sid = screen:id()
    self._posByScreen[sid] = tl -- remember for this screen
    self._cfg.scope.topLeft = tl

    local frame = hs.geometry.rect(tl.x, tl.y, self._cfg.scope.size, self._cfg.scope.size)

    if not self._scopeCanvas or self._scopeShapeApplied ~= (self._cfg.scope.shape or "rectangle") or self._scopeSizeApplied ~= self._cfg.scope.size then
        self:_buildScopeCanvas(frame)
    else
        self._scopeCanvas:frame(frame)
    end
end

function obj:_updateScopeImage(pos, screen)
    local s = self._cfg.scope
    if not s.enabled or not self._scopeCanvas then return end

    local sz, zoom   = s.size, s.zoom
    local capW       = math.floor(sz / zoom)
    local capH       = math.floor(sz / zoom)
    local halfW      = math.floor(capW / 2)
    local halfH      = math.floor(capH / 2)

    local sf         = screen:fullFrame()
    local absX       = clamp(pos.x - halfW, sf.x, sf.x + sf.w - capW)
    local absY       = clamp(pos.y - halfH, sf.y, sf.y + sf.h - capH)
    local capRectAbs = hs.geometry.rect(absX, absY, capW, capH)

    local scopeFrame = self._scopeCanvas and self._scopeCanvas:frame()

    -- Freeze updates if the capture rect would include the scope to avoid recursion.
    if scopeFrame and rectsIntersect(scopeFrame, capRectAbs) then
        return
    end

    local capRectLocal = screen:absoluteToLocal(capRectAbs)
    local img          = screen:snapshot(capRectLocal)
    if img then self._scopeCanvas["img"].image = img end
end

-- =====================
-- Event taps & render timer
-- =====================
function obj:_startEventTap()
    local ev = hs.eventtap.event.types
    self._mouseTap = hs.eventtap.new(
        { ev.mouseMoved, ev.leftMouseDown, ev.rightMouseDown, ev.otherMouseDown },
        function(e)
            if e:getType() == ev.mouseMoved then
                self._lastPos = hs.mouse.absolutePosition()
            else
                self:_recolorHighlight(self._cfg.cursor.clickColor)
                hs.timer.doAfter(0.15, function()
                    if self._running then self:_recolorHighlight(self._cfg.cursor.idleColor) end
                end)
            end
            return false
        end
    ):start()
end

function obj:_startDragEventTap()
    local ev = hs.eventtap.event.types
    self._dragTap = hs.eventtap.new(
        { ev.leftMouseDown, ev.leftMouseDragged, ev.leftMouseUp },
        function(e)
            if not self._scopeCanvas then return false end
            local t      = e:getType()
            local mods   = hs.eventtap.checkKeyboardModifiers() or {}
            local mouse  = e:location()
            local frame  = self._scopeCanvas:frame()

            local inside = mouse.x >= frame.x and mouse.x <= frame.x + frame.w and mouse.y >= frame.y and
                mouse.y <= frame.y + frame.h

            if t == ev.leftMouseDown then
                if mods.cmd and mods.alt and inside then
                    self._dragging   = true
                    self._dragOffset = { x = mouse.x - frame.x, y = mouse.y - frame.y }
                    if self._scopeCanvas and self._scopeCanvas["border"] then
                        self._scopeCanvas["border"].strokeColor = { red = 1, green = 1, blue = 0, alpha = 1 }
                    end
                    return true
                end
            elseif t == ev.leftMouseDragged then
                if self._dragging then
                    if not (mods.cmd and mods.alt) then
                        self._dragging = false; self._dragOffset = nil
                        if self._scopeCanvas and self._scopeCanvas["border"] then
                            self._scopeCanvas["border"].strokeColor = self._cfg.scope.borderColor
                        end
                        return true
                    end
                    local scr = hs.screen.mainScreen()
                    for _, s in ipairs(hs.screen.allScreens()) do
                        local f = s:fullFrame()
                        if frame.x >= f.x and frame.x < f.x + f.w and frame.y >= f.y and frame.y < f.y + f.h then
                            scr = s; break
                        end
                    end
                    local sf   = scr:fullFrame()
                    local newX = clamp(mouse.x - self._dragOffset.x, sf.x, sf.x + sf.w - frame.w)
                    local newY = clamp(mouse.y - self._dragOffset.y, sf.y, sf.y + sf.h - frame.h)
                    self._scopeCanvas:frame({ x = newX, y = newY, w = frame.w, h = frame.h })
                    self._cfg.scope.topLeft = { x = newX, y = newY }
                    if scr and scr.id then self._posByScreen[scr:id()] = { x = newX, y = newY } end
                    return true
                end
            elseif t == ev.leftMouseUp then
                if self._dragging then
                    self._dragging = false; self._dragOffset = nil
                    if self._scopeCanvas and self._scopeCanvas["border"] then
                        self._scopeCanvas["border"].strokeColor = self._cfg.scope.borderColor
                    end
                    return true
                end
            end
            return false
        end
    ):start()
end

function obj:_stopEventTap()
    if self._mouseTap then
        self._mouseTap:stop(); self._mouseTap = nil
    end
end

function obj:_stopDragEventTap()
    if self._dragTap then
        self._dragTap:stop(); self._dragTap = nil
    end
end

function obj:_startRenderTimer()
    local fps = math.max(1, tonumber(self._cfg.global.fps) or 30)
    self._timer = hs.timer.doEvery(1 / fps, function()
        local pos = self._lastPos
        local scr = hs.mouse.getCurrentScreen() or self._lastScreen or hs.screen.mainScreen()
        if not scr then return end
        if self._lastScreen ~= scr then
            self:_ensureScopeOnScreen(scr)
            self._lastScreen = scr
        end
        self:_moveHighlight(pos)
        self:_updateScopeImage(pos, scr)
    end)
    self._timerFPS = fps
end

function obj:_restartRenderTimerIfNeeded()
    if not self._timer then return end
    local fps = math.max(1, tonumber(self._cfg.global.fps) or 30)
    if self._timerFPS ~= fps then
        self._timer:stop(); self._timer = nil; self._timerFPS = nil
        self:_startRenderTimer()
    end
end

function obj:_stopRenderTimer()
    if self._timer then
        self._timer:stop(); self._timer = nil; self._timerFPS = nil
    end
end

-- =====================
-- Public API
-- =====================
function obj:start()
    if self._running then return self end
    self._running = true
    self:_buildHighlight()
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    self:_ensureScopeOnScreen(scr)
    self._lastScreen = scr
    self:_startEventTap()
    self:_startDragEventTap()
    self:_startRenderTimer()
    self:_ensureMenubar(true)
    return self
end

function obj:stop()
    if not self._running then return self end
    self._running = false
    self:_stopEventTap()
    self:_stopDragEventTap()
    self:_stopRenderTimer()
    self:_destroyHighlight()
    if self._scopeCanvas then
        self._scopeCanvas:delete(); self._scopeCanvas = nil
    end
    self:_ensureMenubar(false)
    return self
end

function obj:toggle() if self._running then return self:stop() else return self:start() end end

function obj:setScopeEnabled(enabled)
    self._cfg.scope.enabled = not not enabled
    if not self._running then return self end
    if enabled then
        self:_ensureScopeOnScreen(hs.mouse.getCurrentScreen() or hs.screen.mainScreen())
    else
        if self._scopeCanvas then
            self._scopeCanvas:delete(); self._scopeCanvas = nil
        end
    end
    return self
end

function obj:setScopeTopLeft(x, y)
    if type(x) == "table" then
        y = x.y; x = x.x
    end
    if type(x) ~= "number" or type(y) ~= "number" then return self end
    local scr = hs.mouse.getCurrentScreen() or self._lastScreen or hs.screen.mainScreen()
    self._cfg.scope.topLeft = { x = x, y = y }
    if self._running then
        local frame = hs.geometry.rect(x, y, self._cfg.scope.size, self._cfg.scope.size)
        if self._scopeCanvas then self._scopeCanvas:frame(frame) end
    end
    if scr and scr.id then self._posByScreen[scr:id()] = { x = x, y = y } end
    return self
end

function obj:bindHotkeys(map)
    map = map or self.defaultHotkeys
    if map.start then hs.hotkey.bind(map.start[1], map.start[2], function() self:start() end) end
    if map.stop then hs.hotkey.bind(map.stop[1], map.stop[2], function() self:stop() end) end
    if map.toggle then hs.hotkey.bind(map.toggle[1], map.toggle[2], function() self:toggle() end) end
    return self
end

return obj
