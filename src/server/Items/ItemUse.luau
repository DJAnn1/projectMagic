--!strict
--[[
	ItemUse: what using an item does, one handler per effect kind (docs/Items.md §3.5).
	Item definitions list effects (ItemDef.use.effects); InventoryService runs them through here.

	Each handler has
		check(ctx, effect) -> reason?   nil when the effect would do something now
		apply(ctx, effect) -> (ok, reason?)
	A use goes ahead only if at least one effect passes its check (no drinking a healing draught at
	full health), and the item is consumed only if at least one effect applied.

	KINDS
		heal       { amount, over? }   health now, or spread over `over` seconds (food)
		reservoir  { amount? | share? } reservoir now (flat, or a share of max)
		buff       { id, name, duration, stats?, resist? }   a timed stat layer (StatCache)
		study      { branch, lore? }   ProgressionService:awardStudy(…, "book", itemId) (once per book)
		spell      { recipe }          cast through CastService, beyond your own knowledge; you still
		                               pay the reservoir (CastService:castFromItem)
		repair     { amount }          the most worn equipped item regains durability
		cleanse    { statuses }        removes those statuses (StatusEffects.cleanse)
		borrow     { relic }           a minute of mythic magic (Services/BorrowedPowerService)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Damage = require(Server.Magic.Cast.Damage)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local ItemInstance = require(game:GetService("ReplicatedStorage").Shared.Items.ItemInstance)
local StatCache = require(script.Parent.StatCache)
local BorrowedPowerService = require(Server.Services.BorrowedPowerService)

export type Context = {
	player: Player,
	humanoid: Humanoid,
	itemId: string,
	inv: any, -- Inventory.Inv
	now: number,
	aim: Vector3?,
	reservoirs: any, -- ReservoirService
	progression: any, -- ProgressionService
	cast: any, -- CastService
}

type Handler = {
	check: (Context, any) -> string?,
	apply: (Context, any) -> (boolean, string?),
}

local HEAL_TICK = 0.5

local handlers: { [string]: Handler } = {}

handlers.heal = {
	check = function(ctx, _effect)
		return if ctx.humanoid.Health >= ctx.humanoid.MaxHealth then "FULL_HEALTH" else nil
	end,
	apply = function(ctx, effect)
		local humanoid = ctx.humanoid
		local over = effect.over or 0
		if over <= 0 then
			Damage.heal(humanoid, effect.amount, ctx.player.UserId, nil)
			return true, nil
		end
		-- Over time: stops if the character dies or is replaced.
		local ticks = math.max(1, math.floor(over / HEAL_TICK))
		local perTick = effect.amount / ticks
		task.spawn(function()
			for _ = 1, ticks do
				task.wait(HEAL_TICK)
				if humanoid.Health <= 0 or not humanoid.Parent then
					return
				end
				Damage.heal(humanoid, perTick, ctx.player.UserId, nil)
			end
		end)
		return true, nil
	end,
}

handlers.reservoir = {
	check = function(ctx, _effect)
		local state = ctx.reservoirs:get(ctx.player)
		if not state then
			return "NOT_LOADED"
		end
		return if state.current >= state.max then "RESERVOIR_FULL" else nil
	end,
	apply = function(ctx, effect)
		local state = ctx.reservoirs:get(ctx.player)
		if not state then
			return false, "NOT_LOADED"
		end
		local amount = effect.amount or (effect.share or 0) * state.max
		state.current = math.min(state.max, state.current + amount)
		ctx.reservoirs:push(ctx.player)
		return true, nil
	end,
}

handlers.buff = {
	check = function()
		return nil
	end,
	apply = function(ctx, effect)
		StatCache.addBuff(ctx.player, {
			id = effect.id,
			name = effect.name or effect.id,
			expires = ctx.now + effect.duration,
			stats = effect.stats,
			resist = effect.resist,
		})
		return true, nil
	end,
}

handlers.study = {
	check = function()
		return nil
	end,
	apply = function(ctx, effect)
		local result, reason = ctx.progression:awardStudy(ctx.player, effect.branch, "book", ctx.itemId, { lore = effect.lore })
		if not result then
			return false, reason or "NOTHING_LEARNED"
		end
		return true, nil
	end,
}

handlers.spell = {
	check = function(ctx, _effect)
		return if ctx.aim == nil then "NEEDS_AIM" else nil
	end,
	apply = function(ctx, effect)
		local refusal = ctx.cast:castFromItem(ctx.player, effect.recipe, ctx.aim :: Vector3)
		return refusal == nil, refusal
	end,
}

handlers.borrow = {
	check = function(ctx, _effect)
		return if BorrowedPowerService:isActive(ctx.player) then "ALREADY_BORROWING" else nil
	end,
	apply = function(ctx, effect)
		local reason = BorrowedPowerService:begin(ctx.player, effect.relic)
		return reason == nil, reason
	end,
}

-- The most worn equipped item: lowest durability share, ignoring items that never wear.
local function mostWorn(inv: any): any?
	local worst, worstShare = nil, 1
	for _, rec in inv.equip do
		local max = ItemInstance.maxDurability(rec)
		if max then
			local share = (ItemInstance.durability(rec) :: number) / max
			if share < worstShare then
				worst, worstShare = rec, share
			end
		end
	end
	return worst
end

handlers.repair = {
	check = function(ctx, _effect)
		return if mostWorn(ctx.inv) == nil then "NOTHING_TO_REPAIR" else nil
	end,
	apply = function(ctx, effect)
		local rec = mostWorn(ctx.inv)
		if not rec then
			return false, "NOTHING_TO_REPAIR"
		end
		local max = ItemInstance.maxDurability(rec) :: number
		local after = math.min(max, (ItemInstance.durability(rec) :: number) + effect.amount)
		rec.d = if after >= max then nil else after
		return true, nil
	end,
}

handlers.cleanse = {
	check = function(ctx, effect)
		for _, id in effect.statuses do
			if StatusEffects.has(ctx.humanoid, id) then
				return nil
			end
		end
		return "NOTHING_TO_CLEANSE"
	end,
	apply = function(ctx, effect)
		return StatusEffects.cleanse(ctx.humanoid, effect.statuses) > 0, "NOTHING_TO_CLEANSE"
	end,
}

local ItemUse = {}

ItemUse.kinds = handlers

-- First reason none of the effects would do anything, or nil when the use should go ahead.
function ItemUse.check(ctx: Context, effects: { any }): string?
	local first: string? = nil
	for _, effect in effects do
		local handler = handlers[effect.kind]
		local reason = if handler then handler.check(ctx, effect) else "UNKNOWN_EFFECT"
		if reason == nil then
			return nil
		end
		first = first or reason
	end
	return first or "NOTHING_TO_DO"
end

-- Applies every effect that passes its check. Returns (anyApplied, firstFailure).
function ItemUse.apply(ctx: Context, effects: { any }): (boolean, string?)
	local any, failure = false, nil
	for _, effect in effects do
		local handler = handlers[effect.kind]
		if handler and handler.check(ctx, effect) == nil then
			local ok, reason = handler.apply(ctx, effect)
			any = any or ok
			if not ok then
				failure = failure or reason
			end
		end
	end
	return any, failure
end

return ItemUse
