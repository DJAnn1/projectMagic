--!strict
--[[
	Components: the small set of building blocks every screen uses, so the look stays consistent.

		C.text(text, role, props?)                 TextLabel (wrapping, auto height, theme font)
		C.button(text, onActivate, opts?, props?)  TextButton: hover/press feedback, sound, gamepad-selectable
		C.panel(props?)                            Frame styled as a card
		C.badge(domainId, size, dim?)              domain badge: colour + monogram + rarity shape
		C.bar(scope?, fraction, color, height)     progress bar; fraction may be a Kit Value
		C.scroll(props?)                           ScrollingFrame whose canvas grows with its content
		C.list / C.grid / C.padding / C.corner / C.stroke / C.sizeLimit   layout helpers
		C.tween(instance, kind, props)             TweenService with reduced-motion support
		C.sound(key)                               UI sound from Theme.sounds ("" = silent)

	Props tables follow Kit.create (Values bind, functions connect events).
	Sizes are in pixels at UIScale 1; InterfaceController's UIScale handles the screen size.
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

type Scope = Kit.Scope

local C = {}

local function merge(base: { [string]: any }, extra: { [string]: any }?): { [string]: any }
	if extra then
		for key, value in extra do
			base[key] = value
		end
	end
	return base
end

-- ─── Layout helpers ─────────────────────────────────────────────────────────

function C.corner(radius: number?): UICorner
	return Kit.create(nil, "UICorner", { CornerRadius = UDim.new(0, radius or Theme.radius.m) })
end

function C.stroke(color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Kit.create(nil, "UIStroke", {
		Color = color or Theme.color.line,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function C.padding(all: number, horizontal: number?): UIPadding
	local h = UDim.new(0, horizontal or all)
	local v = UDim.new(0, all)
	return Kit.create(nil, "UIPadding", { PaddingLeft = h, PaddingRight = h, PaddingTop = v, PaddingBottom = v })
end

function C.list(direction: string?, gap: number?, props: { [string]: any }?): UIListLayout
	return Kit.create(nil, "UIListLayout", merge({
		FillDirection = if direction == "x" then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or Theme.space.s),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, props))
end

function C.grid(cellWidth: number, cellHeight: number, gap: number?): UIGridLayout
	local g = gap or Theme.space.s
	return Kit.create(nil, "UIGridLayout", {
		CellSize = UDim2.fromOffset(cellWidth, cellHeight),
		CellPadding = UDim2.fromOffset(g, g),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

function C.sizeLimit(maxWidth: number, maxHeight: number): UISizeConstraint
	return Kit.create(nil, "UISizeConstraint", { MaxSize = Vector2.new(maxWidth, maxHeight) })
end

-- ─── Motion and sound ───────────────────────────────────────────────────────

function C.tween(instance: Instance, kind: string, props: { [string]: any })
	local seconds = Theme.duration(kind)
	if seconds <= 0 then
		for key, value in props do
			(instance :: any)[key] = value
		end
		return
	end
	TweenService:Create(instance, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

function C.sound(key: string)
	local id = Theme.sounds[key]
	if not id or id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = 0.5
	SoundService:PlayLocalSound(sound)
	sound:Destroy()
end

-- ─── Text ───────────────────────────────────────────────────────────────────

function C.text(text: string, role: string?, props: { [string]: any }?): TextLabel
	local r = role or "body"
	return Kit.create(nil, "TextLabel", merge({
		BackgroundTransparency = 1,
		Text = text,
		FontFace = if r == "title" or r == "display" then Theme.font.title elseif r == "heading" or r == "label" then Theme.font.bold else Theme.font.body,
		TextSize = Theme.text(r),
		TextColor3 = if r == "caption" then Theme.color.inkDim else Theme.color.ink,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		RichText = false,
	}, props))
end

-- ─── Containers ─────────────────────────────────────────────────────────────

function C.panel(props: { [string]: any }?): Frame
	local frame: Frame = Kit.create(nil, "Frame", merge({
		BackgroundColor3 = Theme.color.panel,
		BorderSizePixel = 0,
	}, props))
	C.corner().Parent = frame
	C.stroke().Parent = frame
	return frame
end

function C.scroll(props: { [string]: any }?): ScrollingFrame
	return Kit.create(nil, "ScrollingFrame", merge({
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.color.line,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
		Selectable = false,
	}, props))
end

-- ─── Buttons ────────────────────────────────────────────────────────────────

export type ButtonOptions = {
	kind: string?, -- "primary" | "secondary" (default) | "ghost" | "danger"
	disabled: boolean?,
	selected: boolean?,
	sound: string?, -- Theme.sounds key played on activate (default "select")
	height: number?,
}

local function buttonColors(kind: string, selected: boolean): (Color3, Color3)
	if kind == "primary" then
		return Theme.color.accent, Theme.color.bg
	elseif kind == "danger" then
		return Theme.color.danger, Theme.color.ink
	elseif kind == "ghost" then
		return if selected then Theme.color.panelRaised else Theme.color.panel, Theme.color.ink
	end
	return if selected then Theme.color.panelRaised else Theme.color.bg, Theme.color.ink
end

function C.button(text: string, onActivate: (() -> ())?, opts: ButtonOptions?, props: { [string]: any }?): TextButton
	local o: ButtonOptions = opts or {}
	local kind = o.kind or "secondary"
	local disabled = o.disabled == true
	local bg, fg = buttonColors(kind, o.selected == true)
	-- Disabled: an opaque flat fill with readable text. (A half-transparent gold button turned
	-- its label into brown-on-brown.) The missing border highlight and the deny sound mark it.
	if disabled then
		bg, fg = Theme.color.disabled, Theme.color.inkFaint
	end

	local button: TextButton = Kit.create(nil, "TextButton", merge({
		AutoButtonColor = false,
		BackgroundColor3 = bg,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = fg,
		FontFace = Theme.font.medium,
		TextSize = Theme.text("label"),
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, math.max(o.height or Theme.minTouch, Theme.minTouch)),
		Selectable = true, -- disabled buttons stay selectable so gamepad players can read why
	}, props))
	C.corner().Parent = button
	local stroke = C.stroke(if o.selected then Theme.color.accent else Theme.color.line, if o.selected then 2 else 1)
	stroke.Parent = button

	if not disabled then
		button.MouseEnter:Connect(function()
			stroke.Color = Theme.color.accent
		end)
		button.MouseLeave:Connect(function()
			stroke.Color = if o.selected then Theme.color.accent else Theme.color.line
		end)
		button.Activated:Connect(function()
			C.sound(o.sound or "select")
			if onActivate then
				onActivate()
			end
		end)
	else
		button.Activated:Connect(function()
			C.sound("deny")
		end)
	end
	return button
end

-- ─── Domain badge ───────────────────────────────────────────────────────────

-- Colour + two-letter monogram + rarity shape. `dim` draws an unawakened/unknown silhouette.
function C.badge(domainId: string, size: number, dim: boolean?): Frame
	local style = Theme.domainStyle(domainId)
	local color = if dim then Theme.color.inkFaint else Theme.domainColor(domainId)
	local shape = Theme.domainShape(domainId)

	local holder: Frame = Kit.create(nil, "Frame", {
		Name = "Badge_" .. domainId,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
	})
	local plate: Frame = Kit.create(nil, "Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if shape == "diamond" then UDim2.fromScale(0.72, 0.72) else UDim2.fromScale(1, 1),
		Rotation = if shape == "diamond" then 45 else 0,
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Parent = holder,
	})
	C.corner(if shape == "circle" or shape == "ring" then size else Theme.radius.s).Parent = plate
	C.stroke(color, if shape == "ring" then 3 else 2).Parent = plate
	if shape == "ring" then
		-- Mythic: a second inner ring.
		local inner: Frame = Kit.create(nil, "Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -8, 1, -8),
			BackgroundTransparency = 1,
			Parent = plate,
		})
		C.corner(size).Parent = inner
		C.stroke(color, 1).Parent = inner
	end

	if style and style.icon ~= "" and not dim then
		Kit.create(nil, "ImageLabel", {
			BackgroundTransparency = 1,
			Image = style.icon,
			ImageColor3 = color,
			Size = UDim2.fromScale(0.62, 0.62),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Parent = holder,
		})
	else
		Kit.create(nil, "TextLabel", {
			BackgroundTransparency = 1,
			Text = if dim then "?" else (if style then style.monogram else "??"),
			FontFace = Theme.font.bold,
			TextScaled = true,
			TextColor3 = color,
			Size = UDim2.fromScale(0.56, 0.56),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Parent = holder,
		})
	end
	return holder
end

-- ─── Bars ───────────────────────────────────────────────────────────────────

-- A horizontal progress bar. `fraction` is 0..1, or a Value of it (then `scope` is required).
function C.bar(scope: Scope?, fraction: number | Kit.Value<number>, color: Color3, height: number?): Frame
	local track: Frame = Kit.create(nil, "Frame", {
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height or 8),
		ClipsDescendants = true,
	})
	C.corner(Theme.radius.s).Parent = track
	C.stroke(Theme.color.line).Parent = track
	local fill: Frame = Kit.create(nil, "Frame", {
		Name = "Fill",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	})
	C.corner(Theme.radius.s).Parent = fill

	local function setFraction(f: number)
		fill.Size = UDim2.fromScale(math.clamp(f, 0, 1), 1)
	end
	if Kit.isValue(fraction) then
		local value = fraction :: Kit.Value<number>
		assert(scope, "C.bar: a bound fraction needs a scope")
		setFraction(value:get())
		scope:add(value:observe(setFraction))
	else
		setFraction(fraction :: number)
	end
	return track
end

-- ─── Small pieces ───────────────────────────────────────────────────────────

-- "✓ text" / "✗ text": status by glyph AND colour.
function C.check(met: boolean, text: string): TextLabel
	return C.text((if met then "✓  " else "✗  ") .. text, "body", {
		TextColor3 = if met then Theme.color.good else Theme.color.inkDim,
	})
end

-- A key hint chip like [G]. Returns nil when there's nothing to show (touch).
function C.keyHint(hint: string): TextLabel?
	if hint == "" then
		return nil
	end
	local label = C.text(hint, "caption", {
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 0,
		BackgroundColor3 = Theme.color.bg,
		TextColor3 = Theme.color.inkDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
	})
	C.corner(Theme.radius.s).Parent = label
	C.padding(2, 6).Parent = label
	return label
end

return C
