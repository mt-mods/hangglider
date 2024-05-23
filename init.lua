
hangglider = {
	translator = minetest.get_translator('hangglider'),
}
local S = hangglider.translator

local has_player_monoids = minetest.get_modpath("player_monoids")
local has_areas = minetest.get_modpath("areas")
local has_priv_protector = minetest.get_modpath("priv_protector")
	and minetest.global_exists("priv_protector")
	and priv_protector.get_area_priv
-- older versions of priv_protector and xp_redo don't have
-- the global and/or the functions yet
local has_xp_redo = minetest.get_modpath("xp_redo")
	and minetest.global_exists("xp_redo")
	and xp_redo.get_area_xp_limits and xp_redo.get_xp

local enable_hud_overlay = minetest.settings:get_bool("hangglider.enable_hud_overlay", true)
local enable_flak = has_areas and minetest.settings:get_bool("hangglider.enable_flak", true)
local flak_warning_time = tonumber(minetest.settings:get("hangglider.flak_warning_time")) or 2
local hangglider_uses = tonumber(minetest.settings:get("hangglider.uses")) or 250

local flak_warning = S("You have entered restricted airspace!@n"
	.. "You will be shot down in @1 seconds by anti-aircraft guns!",
	flak_warning_time)

local hanggliding_players = {}
local hud_overlay_ids = {}

if enable_flak then
	minetest.register_chatcommand("area_flak", {
		params = S("<ID>"),
		description = S("Toggle airspace restrictions for area <ID>."),
		func = function(name, param)
			local id = tonumber(param)
			if not id then
				return false, S("Invalid usage, see /help area_flak.")
			end
			if not areas:isAreaOwner(id, name) then
				return false, S("Area @1 does not exist or is not owned by you.", id)
			end
			local open = not areas.areas[id].flak
			-- Save false as nil to avoid inflating the DB.
			areas.areas[id].flak = open or nil
			areas:save()
			return true, S("Area @1 airspace is @2.", id,
				open and S("closed") or S("opened"))
		end
	})
end

local function set_hud_overlay(player, name, image)
	if not enable_hud_overlay then
		return
	end
	if not hud_overlay_ids[name] then
		hud_overlay_ids[name] = player:hud_add({
			hud_elem_type = "image",
			text = image,
			position = {x = 0, y = 0},
			scale = {x = -100, y = -100},
			alignment = {x = 1, y = 1},
			offset = {x = 0, y = 0},
			z_index = -150
		})
	else
		player:hud_change(hud_overlay_ids[name], "text", image)
	end
end

local function set_physics_overrides(player, overrides)
	if has_player_monoids then
		for name, value in pairs(overrides) do
			player_monoids[name]:add_change(player, value, "hangglider:glider")
		end
	else
		player:set_physics_override(overrides)
	end
end

local function remove_physics_overrides(player)
	if has_player_monoids then
		for _, name in pairs({"jump", "speed", "gravity"}) do
			player_monoids[name]:del_change(player, "hangglider:glider")
		end
	else
		player:set_physics_override({jump = 1, speed = 1, gravity = 1})
	end
end

local function can_fly(pos, name, player_xp, player_privs)
	if not enable_flak then
		return true
	end

	local flak, open = false, false
	local priv_excemption, xp_limit = false, false
	local xp_area, priv_area
	local owners = {}
	for id, area in pairs(areas:getAreasAtPos(pos)) do
		-- open areas are friendly airspace(?)
		if area.open then
			open = true
		end
		if player_privs then
			priv_area = priv_protector.get_area_priv(id)
			if player_privs[priv_area] then
				priv_excemption = true
			end
		end
		if player_xp then
			xp_area = xp_redo.get_area_xp_limits(id)
			if xp_area then
				if (xp_area.min and player_xp < xp_area.min)
					or (xp_area.max and player_xp > xp_area.max)
				then
					xp_limit = true
				end
			end
		end
		if area.flak then
			flak = true
		end
		owners[area.owner] = true
	end
	-- none of the areas has FLAK set -> friendly
	-- any of the overlapping areas is open -> friendly
	-- owners of overlapping areas -> safe
	if not flak or open or owners[name] then
		return true
	end

	-- privilaged players -> safe
	if player_privs and priv_excemption then
		return true
	end

	-- xp limits -> unfriendly
	if player_xp and not xp_limit then
		return true
	end

	return false
end

local function safe_node_below(pos)
	local node = minetest.get_node_or_nil(vector.new(pos.x, pos.y - 0.5, pos.z))
	if not node then
		return false
	end
	local def = minetest.registered_nodes[node.name]
	if def and (def.walkable or (def.liquidtype ~= "none" and def.damage_per_second <= 0)) then
		return true
	end
	return false
end

local function shoot_flak_sound(pos)
	minetest.sound_play("hangglider_flak_shot", {
		pos = pos,
		max_hear_distance = 30,
		gain = 10.0,
	}, true)
end

local function hangglider_step(self, dtime)
	local gliding = false
	local player = self.object:get_attach("parent")
	if player then
		local pos = player:get_pos()
		local name = player:get_player_name()
		if hanggliding_players[name] then
			if not safe_node_below(pos) then
				gliding = true
				local vel = player:get_velocity().y
				if vel < 0 and vel > -3 then
					set_physics_overrides(player, {
						speed = math.abs(vel / 2.0) + 1.0,
						gravity = (vel + 3) / 20,
					})
				elseif vel <= -3 then
					set_physics_overrides(player, {
						speed = 2.5,
						gravity = -0.1,
					})
					if vel < -5 then
						-- Extra airbrake when falling too fast
						player:add_velocity(vector.new(0, math.min(5, math.abs(vel / 10.0)), 0))
					end
				else  -- vel > 0
					set_physics_overrides(player, {
						speed = 1.0,
						gravity = 0.25,
					})
				end
			end
			if not can_fly(pos, name, self.xp, self.privs) then
				if not self.flak_timer then
					self.flak_timer = 0
					shoot_flak_sound(pos)
					minetest.chat_send_player(name, flak_warning)
				else
					self.flak_timer = self.flak_timer + dtime
				end
				if self.flak_timer > flak_warning_time then
					player:set_hp(1, {type = "set_hp", cause = "hangglider:flak"})
					player:get_inventory():remove_item("main", ItemStack("hangglider:hangglider"))
					shoot_flak_sound(pos)
					gliding = false
				end
			end
			if not gliding then
				remove_physics_overrides(player)
				hanggliding_players[name] = nil
				set_hud_overlay(player, name, "blank.png")
			end
		end
	end
	if not gliding then
		self.object:set_detach()
		self.object:remove()
	end
end

local function hangglider_use(stack, player)
	if type(player) ~= "userdata" then
		return  -- Real players only
	end
	local pos = player:get_pos()
	local name = player:get_player_name()
	if not hanggliding_players[name] then
		minetest.sound_play("hanggliger_equip", {pos = pos, max_hear_distance = 8, gain = 1.0}, true)
		local entity = minetest.add_entity(pos, "hangglider:glider")
		if entity then
			entity:set_attach(player, "", vector.new(0, 10, 0), vector.new(0, 0, 0))
			local color = stack:get_meta():get("hangglider_color")
			if color then
				entity:set_properties({
					textures = {"wool_white.png^[multiply:#"..color, "default_wood.png"}
				})
			end
			set_hud_overlay(player, name, "hangglider_overlay.png")
			set_physics_overrides(player, {jump = 0, gravity = 0.25})
			local luaentity = entity:get_luaentity()
			if has_xp_redo then
				luaentity.xp = xp_redo.get_xp(name)
			end
			if has_priv_protector then
				luaentity.privs = minetest.get_player_privs(name)
			end
			hanggliding_players[name] = true
			if hangglider_uses > 0 then
				stack:add_wear(65535 / hangglider_uses)
			end
			return stack
		end
	else
		set_hud_overlay(player, name, "blank.png")
		remove_physics_overrides(player)
		hanggliding_players[name] = nil
	end
end

minetest.register_on_dieplayer(function(player)
	local name = player:get_player_name()
	hanggliding_players[name] = nil
	remove_physics_overrides(player)
end)

minetest.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	hanggliding_players[name] = nil
	hud_overlay_ids[name] = nil
	remove_physics_overrides(player)
end)

minetest.register_on_player_hpchange(function(player, hp_change, reason)
	local name = player:get_player_name()
	if hanggliding_players[name] and reason.type == "fall" then
		-- Stop all fall damage when hanggliding
		return 0, true
	end
	return hp_change
end, true)

minetest.register_entity("hangglider:glider", {
	visual = "mesh",
	visual_size = {x = 12, y = 12},
	collisionbox = {0,0,0,0,0,0},
	mesh = "hangglider.obj",
	immortal = true,
	static_save = false,
	textures = {"wool_white.png", "default_wood.png"},
	on_step = hangglider_step,
})

minetest.register_tool("hangglider:hangglider", {
	description = S("Glider"),
	inventory_image = "hangglider_item.png",
	sound = {breaks = "default_tool_breaks"},
	on_use = hangglider_use,
})

dofile(minetest.get_modpath("hangglider").."/crafts.lua")
