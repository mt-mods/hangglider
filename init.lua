-- Hangglider mod for Minetest
-- Original code by Piezo_ (orderofthefourthwall@gmail.com)
-- 2018-11-14

-- Modifications by David G (kestral246@gmail.com)
-- 2018-11-24
-- For Minetest 5.x, glider's set_attach needs to be offset by 1 node
--     Switch to alternate commented line below with correct offset.
-- Additional tuning of parameters.
-- Commented out debug hud display code, prefixed with "--debug:".

-- 2018-11-22
-- Give visual indication that hangglider is equiped.
--     Display simple overlay with blurred struts when equiped.
--     Issue: don't know how to disable overlay in third person view.
-- Also Unequip hangglider when landing on water.
-- Attempt to linearize parabolic flight path.
--     Start gravity stronger, but gradually reduce it as descent velocity increases.
--     Don't use airstopper when equipped from the ground (descent velocity is low).
--     Slightly increase flight speed to 1.25.
-- Unequip/equip cycling mid-flight should not fly farther than continuous flight.
--     When equipping mid-air (descent velocity higher), use airstopper but increase descent slope afterwards.
--     Create airbreak flag so all equips mid-flight use faster descent.
--     Reset airbreak flag only when land (canExist goes false).
--     Issue: it wouldn't reset if land in water, use fly, and launch from air, before I added test for water,
--            not sure if there are other such cases.
-- Temporarily add hud debug display to show descent velocity, gravity override, and airbreak flag.
--     Still in process of tuning all the parameters.


-- Modifications by Piezo_
-- 2018-11-25
-- hud overlay and debug can be enabled/disabled
-- Added blender-rendered overlay for struts using the actual model.
-- Reduced airbreak penalty severity
-- gave glider limited durability.
-- Improved gravity adjustment function.
-- Changed airbreaking process
-- Removed airbreak penalty, as any 'advantage' seems minimal after new adjustments
-- Removed airbreak until minetest devs are smart enough to implement better serverside players.
-- Simplified liquid check.

-- Modifications by gpcf
-- 2018-12-09
-- get shot down while flying over protected areas marked as no-fly-zones (flak, from German Flugabwehrkanone)
--  set these areas with the /area_flak command

-- Modifications by SpaghettiToastBook
-- 2018-12-29
-- Physics overrides use player_monoids mod if available

-- Modifications by SwissalpS
-- 2022-05-16
-- Add Z-index to theoretically be behind hotbar and practically behind other HUDs

local HUD_Overlay = true -- show glider struts as overlay on HUD
local debug = false -- show debug info in top-center of hud
local warning_time = tonumber(minetest.settings:get("hangglider.flak_warning_time")) or 2
hangglider = {} -- Make this global, so other mods can tell if hangglider exists.
hangglider.use = {}

if HUD_Overlay then
	hangglider.id = {}  -- hud id for displaying overlay with struts
end

if debug then -- hud id for debug data
	hangglider.debug = {}
end

if minetest.get_modpath("areas") then
	hangglider.flak = true
	-- chat command definition essentially copied from areas mod.
	minetest.register_chatcommand("area_flak",{
		params = "<ID>",
		description = "Toggle airspace restrictions for area <ID>",
		func = function(name, param)
			local id = tonumber(param)
			if not id then
				return false, "Invalid usage, see /help area_flak."
			end

			if not areas:isAreaOwner(id, name) then
				return false, "Area "..id.." does not exist or is not owned by you."
			end
			local open = not areas.areas[id].flak
			-- Save false as nil to avoid inflating the DB.
			areas.areas[id].flak = open or nil
			areas:save()
			return true, ("Area's airspace %s."):format(open and "closed" or "opened")
		end
	})
end

hangglider.can_fly = function (pname, pos)
	-- Checks if the player will get shot down at the position
	if areas and hangglider.flak then
		local flak = false
		local owners = {}
		for _, area in pairs(areas:getAreasAtPos(pos)) do
			if area.flak then
				flak = true
			end
			owners[area.owner] = true
		end
		if flak and not owners[pname] then
			return false
		end
	end
	return true
end

hangglider.shot_sound = function (pos)
	minetest.sound_play("hangglider_flak_shot", {
		pos = pos,
		max_hear_distance = 30,
		gain = 10.0,
	}, true)
end

local has_player_monoids = minetest.get_modpath("player_monoids")

local physics_attrs = {"jump", "speed", "gravity"}

local function apply_physics_override(player, overrides)
	if has_player_monoids then
		for _, attr in pairs(physics_attrs) do
			if overrides[attr] then
				player_monoids[attr]:add_change(player, overrides[attr], "hangglider:glider")
			end
		end
	else
		player:set_physics_override(overrides)
	end
end

local function remove_physics_override(player, overrides)
	for _, attr in pairs(physics_attrs) do
		if overrides[attr] then
			if has_player_monoids then
				player_monoids[attr]:del_change(player, "hangglider:glider")
			else
				player:set_physics_override({[attr] = 1})
			end
		end
	end
end

minetest.register_entity("hangglider:glider", {
	visual = "mesh",
	visual_size = {x = 12, y = 12},
	collisionbox = {0,0,0,0,0,0},
	mesh = "glider.obj",
	immortal = true,
	static_save = false,
	textures = {"wool_white.png", "default_wood.png"},
	on_step = function(self, dtime)
		local canExist = false
		if self.object:get_attach() then
			local player = self.object:get_attach("parent")
			if player then
				local pos = player:get_pos()
				local pname = player:get_player_name()
				if hangglider.use[pname] then
					local mrn_name = minetest.registered_nodes[minetest.get_node(vector.new(pos.x, pos.y-0.5, pos.z)).name]
					if mrn_name then
						if not (mrn_name.walkable or mrn_name.liquidtype ~= "none") then
							canExist = true
							local step_v = player:get_velocity().y
							if step_v < 0 and step_v > -3 then
								apply_physics_override(player, {speed = math.abs(step_v/2) + 0.75})
							elseif step_v <= -3 then -- Cap our gliding movement speed.
								apply_physics_override(player, {speed = 2.25})
							else
								remove_physics_override(player, {speed = 1})
							end
							if debug then
								player:hud_change(hangglider.debug[pname].id, "text", step_v..', '..
									player:get_physics_override().gravity)
							end
							apply_physics_override(player, {gravity = ((step_v + 3)/20)})
						end
					end
				end
				if not hangglider.can_fly(pname,pos) then
					if not self.warned then -- warning shot
						self.warned = 0
						hangglider.shot_sound(pos)
						minetest.chat_send_player(pname, "Protected area! You will be shot down in " ..
							warning_time .. " seconds by anti-aircraft guns!")
					end
					self.warned = self.warned + dtime
					if self.warned > warning_time then -- shoot down
						player:set_hp(1)
						player:get_inventory():remove_item("main", ItemStack("hangglider:hangglider"))
						hangglider.shot_sound(pos)
						canExist = false
					end
				end
				if not canExist then
					remove_physics_override(player, {gravity = 1, jump = 1, speed = 1})
					hangglider.use[pname] = false
					if HUD_Overlay then
						player:hud_change(hangglider.id[pname], "text", "blank.png")
					end
				end
			end
		end
		if not canExist then
			self.object:set_detach()
			self.object:remove()
		end
	end
})

minetest.register_on_dieplayer(function(player)
	remove_physics_override(player, {
		gravity = 1,
		jump = 1,
	})
	hangglider.use[player:get_player_name()] = false
end)

minetest.register_on_joinplayer(function(player)
	local pname = player:get_player_name()
	remove_physics_override(player, {
		gravity = 1,
		jump = 1,
	})
	hangglider.use[pname] = false
	if HUD_Overlay then
		hangglider.id[pname] = player:hud_add({
			hud_elem_type = "image",
			text = "blank.png",
			position = {x = 0, y = 0},
			scale = {x = -100, y = -100},
			alignment = {x = 1, y = 1},
			offset = {x = 0, y = 0},
			z_index = -150
		})
	end
	if debug then
		hangglider.debug[pname] = {id = player:hud_add({hud_elem_type = "text",
			position = {x = 0.5, y= 0.1 },
			text = "-",
			number = 0xFF0000}),  -- red text
			-- ht = {50,50,50},
		}
	end
end)

minetest.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	hangglider.use[pname] = nil
	if HUD_Overlay then hangglider.id[pname] = nil end
	if debug then hangglider.debug[pname] = nil end
end)

minetest.register_tool("hangglider:hangglider", {
	description = "Glider",
	inventory_image = "glider_item.png",
	stack_max = 1,
	on_use = function(itemstack, player)
		if not player or player.is_fake_player then
			-- player does not exist or is created from an automated machine (fake_player)
			return
		end
		local pos = player:get_pos()
		local pname = player:get_player_name()
		if not hangglider.use[pname] then -- Equip
			minetest.sound_play("bedsheet", {pos = pos, max_hear_distance = 8, gain = 1.0}, true)
			if HUD_Overlay then player:hud_change(hangglider.id[pname], "text", "glider_struts.png") end
			minetest.add_entity(pos, "hangglider:glider"):set_attach(player, "", {x=0,y=10,z=0}, {x=0,y=0,z=0})
			hangglider.use[pname] = true
			apply_physics_override(player, {jump = 0})
			itemstack:set_wear(itemstack:get_wear() + 255)
			return itemstack
		elseif hangglider.use[pname] then -- Unequip
			if HUD_Overlay then player:hud_change(hangglider.id[pname], "text", "default_wood.png^[colorize:#0000:255") end
			hangglider.use[pname] = false
		end
	end,
	sound = {breaks = "default_tool_breaks"},
})

minetest.register_craft({
	type = "shapeless",
	output = "hangglider:hangglider",
	recipe = {"default:paper", "default:paper", "default:paper",
		"default:paper", "hangglider:hangglider", "default:paper",
		"default:paper", "default:paper", "default:paper"
	},
})

minetest.register_craft({
	output = "hangglider:hangglider",
	recipe = {
		{"wool:white", "wool:white", "wool:white"},
		{"default:stick", "", "default:stick"},
		{"", "default:stick", ""},
	}
})
