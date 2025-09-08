local obj              = {}
obj.__index            = obj

obj.name               = "CursorScope"
obj.version            = "0.0.1"
obj.author             = "Selim Acerbas"
obj.homepage           = "https://www.github.com/selimacerbas/CursorScope.spoon/"
obj.license            = "MIT"

-- Defaults (override via :configure{ global=..., cursor=..., scope=... })
obj._cfg               = {
    global = {
        fps = 30, -- render rate for follow/scope
    },
    cursor = {
        shape      = "ring", -- "ring" | "crosshair" | "dot"
        idleColor  = { red = 0, green = 0.6, blue = 1, alpha = 0.9 },
        clickColor = { red = 1, green = 0, blue = 0, alpha = 0.95 },
        radius     = 28,
        lineWidth  = 4, -- thickness for crosshair arms
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
        position     = { corner = "bottomRight", x = 20, y = 80 },
    },
}

-- State
obj._running           = false
obj._log               = hs.logger.new("CursorScope", "info")
obj._menubar           = nil
obj._highlightCircle   = nil -- ring
obj._dot               = nil -- dot
obj._crosshairCanvas   = nil -- canvas with 2 rects: ids "h" and "v"
obj._scopeCanvas       = nil
obj._scopeShapeApplied = nil
obj._mouseTap          = nil
obj._timer             = nil
obj._timerFPS          = nil
obj._lastPos           = hs.mouse.absolutePosition()
obj._lastScreen        = nil
obj._currentColor      = obj._cfg.cursor.idleColor

obj.defaultHotkeys     = {
    start = { { "ctrl", "alt", "cmd" }, "Z" },
    stop  = { { "ctrl", "alt", "cmd" }, "U" },
}

-- Utils
local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end
local function deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then deepMerge(dst[k], v) else dst[k] = v end
    end
end

-- Config
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

-- Fixed menubar icon (no user configuration)

-- Fixed menubar icon (no user configuration)
local function _fixedIconImage()
    -- Always use the built-in macOS template icon; widely available.
    return hs.image.imageFromName("NSSearchTemplate")
end

function obj:_updateMenubarIcon()
    if not self._menubar then return end
    local img = _fixedIconImage()
    if img then
        self._menubar:setIcon(img, true) -- template=true for auto light/dark tint
        self._menubar:setTitle(nil)
    else
        -- Hard fallback to a short text badge (no emoji), so it never disappears.
        self._menubar:setIcon(nil)
        self._menubar:setTitle("CS")
    end
end

function obj:_ensureMenubar(on)
    if on and not self._menubar then
        self._menubar = hs.menubar.new()
        if self._menubar then
            self:_updateMenubarIcon()
            self._menubar:setTooltip("CursorScope")
            self._menubar:setMenu(function()
                return {
                    { title = "Exit CursorScope", fn = function() self:stop() end },
                }
            end)
        end
    elseif not on and self._menubar then
        self._menubar:delete(); self._menubar = nil
    end
end

-- Cursor highlight
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
        d:setBehaviorByLabels({ "canJoinAllSpaces" }):setLevel(hs.drawing.windowLevels.overlay):show()
        self._highlightCircle = d
    elseif c.shape == "crosshair" then
        local frame = hs.geometry.rect(cx - r, cy - r, 2 * r, 2 * r)
        local cv = hs.canvas.new(frame)
        cv:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
        cv:level(hs.canvas.windowLevels.overlay)
        -- Horizontal arm
        cv[#cv + 1] = {
            id = "h",
            type = "rectangle",
            action = "fill",
            fillColor = c.idleColor,
            frame = { x = 0, y = r - math.floor(lw / 2), w = 2 * r, h = lw }
        }
        -- Vertical arm
        cv[#cv + 1] = {
            id = "v",
            type = "rectangle",
            action = "fill",
            fillColor = c.idleColor,
            frame = { x = r - math.floor(lw / 2), y = 0, w = lw, h = 2 * r }
        }
        cv:show()
        self._crosshairCanvas = cv
    else -- dot
        local d = hs.drawing.circle(hs.geometry.rect(cx - r / 2, cy - r / 2, r, r))
        d:setFill(true):setStroke(false):setFillColor(c.idleColor)
        d:setBehaviorByLabels({ "canJoinAllSpaces" }):setLevel(hs.drawing.windowLevels.overlay):show()
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

-- Scope (canvas)
local function _calcScopeFrame(self, screen)
    local s      = self._cfg.scope
    local sz     = s.size
    local sf     = screen:fullFrame()
    local p      = s.position or { corner = "bottomRight", x = 20, y = 80 }
    local corner = p.corner or "bottomRight"
    local ox, oy = p.x or 20, p.y or 80
    local x, y
    if corner == "bottomRight" then
        x = sf.x + sf.w - sz - ox; y = sf.y + sf.h - sz - oy
    elseif corner == "topRight" then
        x = sf.x + sf.w - sz - ox; y = sf.y + oy
    elseif corner == "bottomLeft" then
        x = sf.x + ox; y = sf.y + sf.h - sz - oy
    else
        x = sf.x + ox; y = sf.y + oy
    end
    return hs.geometry.rect(x, y, sz, sz)
end

function obj:_buildScopeCanvas(frame)
    if self._scopeCanvas then
        self._scopeCanvas:delete(); self._scopeCanvas = nil
    end
    local s = self._cfg.scope
    local cv = hs.canvas.new(frame)
    cv:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    cv:level(hs.canvas.windowLevels.overlay)

    local shape = s.shape or "rectangle"
    if shape == "circle" then
        cv[#cv + 1] = { id = "clip", type = "oval", action = "clip", frame = { x = 0, y = 0, w = 100, h = 100 } }
        cv[#cv + 1] = { id = "bg", type = "rectangle", action = "fill", fillColor = s.background, frame = { x = 0, y = 0, w = 100, h = 100 } }
        cv[#cv + 1] = { id = "img", type = "image", image = nil, imageScaling = "scaleToFit", frame = { x = 0, y = 0, w = 100, h = 100 } }
        cv[#cv + 1] = { id = "reset", type = "resetClip" }
        cv[#cv + 1] = {
            id = "border",
            type = "oval",
            action = "stroke",
            strokeColor = s.borderColor,
            strokeWidth = s
                .borderWidth,
            frame = { x = 0, y = 0, w = 100, h = 100 }
        }
    else
        cv[#cv + 1] = { id = "bg", type = "rectangle", action = "fill", fillColor = s.background, frame = { x = 0, y = 0, w = 100, h = 100 }, roundedRectRadii = { xRadius = s.cornerRadius, yRadius = s.cornerRadius } }
        cv[#cv + 1] = { id = "img", type = "image", image = nil, imageScaling = "scaleToFit", frame = { x = 0, y = 0, w = 100, h = 100 } }
        cv[#cv + 1] = {
            id = "border",
            type = "rectangle",
            action = "stroke",
            strokeColor = s.borderColor,
            strokeWidth =
                s.borderWidth,
            frame = { x = 0, y = 0, w = 100, h = 100 },
            roundedRectRadii = { xRadius = s.cornerRadius, yRadius = s.cornerRadius }
        }
    end

    self._scopeCanvas = cv
    self._scopeShapeApplied = shape
    cv:show()
end

function obj:_ensureScopeOnScreen(screen)
    if not self._cfg.scope.enabled then
        if self._scopeCanvas then
            self._scopeCanvas:delete(); self._scopeCanvas = nil
        end
        return
    end
    local frame = _calcScopeFrame(self, screen)
    if not self._scopeCanvas or self._scopeShapeApplied ~= (self._cfg.scope.shape or "rectangle") then
        self:_buildScopeCanvas(frame)
    else
        self._scopeCanvas:frame(frame)
    end
end

function obj:_updateScopeImage(pos, screen)
    local s = self._cfg.scope
    if not s.enabled or not self._scopeCanvas then return end
    local sz, zoom     = s.size, s.zoom
    local capW         = math.floor(sz / zoom)
    local capH         = math.floor(sz / zoom)
    local halfW        = math.floor(capW / 2)
    local halfH        = math.floor(capH / 2)

    local sf           = screen:fullFrame()
    local absX         = clamp(pos.x - halfW, sf.x, sf.x + sf.w - capW)
    local absY         = clamp(pos.y - halfH, sf.y, sf.y + sf.h - capH)
    local capRectLocal = screen:absoluteToLocal(hs.geometry.rect(absX, absY, capW, capH))
    local img          = screen:snapshot(capRectLocal)
    if img then self._scopeCanvas["img"].image = img end
end

-- Event taps & render timer
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

function obj:_stopEventTap()
    if self._mouseTap then
        self._mouseTap:stop(); self._mouseTap = nil
    end
end

function obj:_stopRenderTimer()
    if self._timer then
        self._timer:stop(); self._timer = nil; self._timerFPS = nil
    end
end

-- Public API
function obj:start()
    if self._running then return self end
    self._running = true
    self:_buildHighlight()
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    self:_ensureScopeOnScreen(scr)
    self._lastScreen = scr
    self:_startEventTap()
    self:_startRenderTimer()
    self:_ensureMenubar(true)
    return self
end

function obj:stop()
    if not self._running then return self end
    self._running = false
    self:_stopEventTap()
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

function obj:bindHotkeys(map)
    map = map or self.defaultHotkeys
    if map.start then hs.hotkey.bind(map.start[1], map.start[2], function() self:start() end) end
    if map.stop then hs.hotkey.bind(map.stop[1], map.stop[2], function() self:stop() end) end
    if map.toggle then hs.hotkey.bind(map.toggle[1], map.toggle[2], function() self:toggle() end) end
    return self
end

return obj
