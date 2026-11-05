-- kids_maze: a treasure hedge maze for kids.
-- Entrance in the south, treasure under the golden tower in the middle, colored
-- towers in dead ends as landmarks, signs with tips. Stopwatch from the gate, best time.
-- Local coordinates: x east, z north, y=-1 gravel path, hedge at y 0..2.

local M = "kids_maze:"
local storage = core.get_mod_storage()
local VERSION = 7            -- 3 = Fackeln; 2 = groesseres, schwereres Labyrinth (15 x 15 Zellen, 3 Raetseltore)
local N = 11                 -- cells per side (odd); 11 instead of 15: kids found it too hard
local S = N * 3 + 1          -- Knoten pro Seite (Gang 2 breit, Hecke 1)
local C = math.floor((N - 1) / 2)   -- mittlere Zelle
local P1, P2 = 3 * (C - 1) + 1, 3 * (C + 1) + 2   -- Platz in der Mitte (Zellen C-1..C+1)
local ENTRY = C              -- Eingangszelle (x) an der Suedseite
local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

---------------------------------------------------------------- Bloecke
core.register_node(M .. "hecke", {
	description = "Maze Hedge",
	tiles = {"kids_maze_hecke.png"},
	groups = {unbreakable = 1},
	diggable = false,   -- nicht durchschlagbar, sonst ist das Labyrinth Pfusch
	is_ground_content = false,
	sounds = default.node_sound_leaves_defaults(),
})

local confetti   -- unten definiert
local taken = {}      -- Spieler, die in diesem Durchlauf den Schatz schon haben
local restart_maze    -- unten definiert
local to_start, overview, rebuild_maze, show_compass_menu   -- unten definiert

-- grosse Meldung mitten auf dem Bildschirm (verschwindet nach 5 s)
local function big_msg(player, text, color)
	if not (player and player:is_player()) then return end
	local id = player:hud_add({
		type = "text", position = {x = 0.5, y = 0.3}, alignment = {x = 0, y = 0},
		text = text, number = color or 0xFFD028, size = {x = 3, y = 3}, z_index = 100,
	})
	core.after(5, function()
		if player:is_player() then player:hud_remove(id) end
	end)
end

-- Grosses Dialogfenster mit lesbarer Schrift (der Chat links oben ist viel zu klein)
local function say(player, who, text)
	if not (player and player:is_player()) then return end
	core.show_formspec(player:get_player_name(), M .. "say",
		"formspec_version[4]size[11,6]"
		.. "style_type[label;font_size=*2;font=bold]"
		.. "label[0.6,0.8;" .. core.formspec_escape(who) .. "]"
		.. "style_type[textarea;font_size=*1.7]"
		.. "textarea[0.6,1.4;9.8,3.3;;;" .. core.formspec_escape(text) .. "]"
		.. "style_type[button_exit;font_size=*1.5]"
		.. "button_exit[3.5,4.9;4,0.9;ok;OK]")
end

core.register_craftitem(M .. "enderperle", {
	description = "Ender Pearl (teleports you to where you look)",
	inventory_image = "default_mese_crystal.png^[colorize:#3a2aff:170",
	stack_max = 16,
	on_use = function(itemstack, user)
		if not (user and user:is_player()) then return end
		local eye = vector.add(user:get_pos(), {x = 0, y = 1.5, z = 0})
		local target = vector.add(eye, vector.multiply(user:get_look_dir(), 30))
		local dest = target
		for pt in core.raycast(eye, target, false, false) do
			if pt.type == "node" then dest = pt.above break end
		end
		dest = vector.round(dest)
		-- Platz fuer den Spieler (2 Bloecke hoch) suchen
		for _ = 1, 4 do
			local a = core.registered_nodes[core.get_node(dest).name]
			local b = core.registered_nodes[core.get_node(vector.add(dest, {x = 0, y = 1, z = 0})).name]
			if a and not a.walkable and b and not b.walkable then break end
			dest = vector.add(dest, {x = 0, y = 1, z = 0})
		end
		confetti(user:get_pos())
		user:set_pos(dest)
		confetti(dest)
		core.sound_play("kids_maze_glocke", {pos = dest, gain = 0.8})
		if not core.is_creative_enabled(user:get_player_name()) then itemstack:take_item(1) end
		return itemstack
	end,
})

-- Goldener Kompass: alle Funktionen per Knopf statt Chat-Befehl (Kinder sollen nichts tippen)
core.register_craftitem(M .. "kompass", {
	description = "Golden Compass",
	inventory_image = "default_mese_crystal.png^[colorize:#ffc800:200",
	stack_max = 1,
	on_use = function(_, user)
		show_compass_menu(user)
		return ItemStack(M .. "kompass")
	end,
	on_secondary_use = function(_, user)
		show_compass_menu(user)
		return ItemStack(M .. "kompass")
	end,
})

local GOLD = "^[colorize:#ffc800:80"
core.register_node(M .. "schatzkiste", {
	description = "Golden Treasure Chest",
	paramtype2 = "facedir",
	tiles = {"default_chest_top.png" .. GOLD, "default_chest_top.png" .. GOLD,
		"default_chest_side.png" .. GOLD, "default_chest_side.png" .. GOLD,
		"default_chest_side.png" .. GOLD, "default_chest_front.png" .. GOLD},
	groups = {unbreakable = 1, not_in_creative_inventory = 1},
	diggable = false,   -- nicht zerstoerbar: Rechtsklick ODER Draufhauen oeffnet sie
	light_source = 8,
	is_ground_content = false,
	sounds = default.node_sound_wood_defaults(),
	on_rightclick = function(pos, _, clicker)
		if not clicker or not clicker:is_player() then return end
		local name = clicker:get_player_name()
		local inv = clicker:get_inventory()
		if not taken[name] then
			taken[name] = true
			for _, item in ipairs({"default:sword_diamond 1", "kids_maze:enderperle 5", "default:diamond 3",
					"default:gold_ingot 5", "default:apple 3", "default:mese_crystal 2"}) do
				local left = inv:add_item("main", item)
				if not left:is_empty() then core.add_item(pos, left) end
			end
			core.sound_play("kids_maze_fanfare", {pos = pos, gain = 1.0})
			confetti(pos)
			big_msg(clicker, "TREASURE FOUND!")
			core.chat_send_player(name, "In the chest: a diamond sword, 5 ender pearls, 3 diamonds, 5 gold bars, 3 apples and 2 mese crystals!")
		end
		core.show_formspec(name, M .. "ende",
			"formspec_version[4]size[11,6]"
			.. "style_type[label;font_size=*2;font=bold]label[0.6,0.8;YOU DID IT! You found the treasure!]"
			.. "style_type[textarea;font_size=*1.6]textarea[0.6,1.4;9.8,2;;;"
			.. core.formspec_escape("In your inventory: a diamond sword and ender pearls. An ender pearl teleports you to where you look: just hold it and press right-click!\n\nDo you want to play again?") .. "]"
			.. "style_type[button_exit;font_size=*1.4]"
			.. "button_exit[0.6,4.5;5,0.9;new;New maze!]"
			.. "button_exit[5.9,4.5;4.5,0.9;stay;Stay here]")
	end,
})

-- Futterkiste am Tor: gibt Futter fuer die Tiere im Labyrinth
local GRUEN = "^[colorize:#40c040:90"
core.register_node(M .. "futterkiste", {
	description = "Feed Box",
	paramtype2 = "facedir",
	tiles = {"default_chest_top.png" .. GRUEN, "default_chest_top.png" .. GRUEN,
		"default_chest_side.png" .. GRUEN, "default_chest_side.png" .. GRUEN,
		"default_chest_side.png" .. GRUEN, "default_chest_front.png" .. GRUEN},
	groups = {choppy = 2, not_in_creative_inventory = 1},
	diggable = false,
	is_ground_content = false,
	sounds = default.node_sound_wood_defaults(),
	on_rightclick = function(pos, _, clicker)
		if not clicker or not clicker:is_player() then return end
		local inv = clicker:get_inventory()
		for _, item in ipairs({"farming:seed_wheat 10", "farming:carrot 8",
				"farming:wheat 10", "animalia:poultry_raw 4"}) do
			if core.registered_items[item:match("^%S+")] then
				local left = inv:add_item("main", item)
				if not left:is_empty() then core.add_item(pos, left) end
			end
		end
		core.sound_play("default_chest_open", {pos = pos, gain = 0.8})
		confetti(pos)
		big_msg(clicker, "FEED COLLECTED!", 0x80FF80)
		say(clicker, "Feed Box", "You got animal feed!\n\n"
			.. "Seeds for the chickens, carrots for the pigs, wheat for the sheep and cows, raw chicken for the cats.\n\n"
			.. "How to feed: pick the feed in your hotbar (number key or mouse wheel) "
			.. "and right-click an animal.")
	end,
})

-- Wundertruhe in Sackgassen: einmal oeffnen, dann gibt es eine Ueberraschung
local LILA = "^[colorize:#b040ff:90"
local ANIMALS = {
	{"animalia:chicken", "CHICKEN", "seeds", 2},
	{"animalia:pig", "PIG", "carrots", 1},
	{"animalia:sheep", "SHEEP", "wheat", 1},
	{"animalia:cat", "CAT", "raw chicken", 1},
	{"animalia:cow", "COW", "wheat", 1},
}

-- Alle Tiere im Labyrinth-Mod sind unverwundbar: Draufhauen tut nichts.
core.register_on_mods_loaded(function()
	for _, a in ipairs(ANIMALS) do
		local def = core.registered_entities[a[1]]
		if def then
			def.on_punch = function(self, puncher)
				if puncher and puncher:is_player() then
					say(puncher, a[2]:sub(1, 1) .. a[2]:sub(2):lower(), "Ow, don't hit me! Feed me instead.")
				end
				return true
			end
		end
	end
end)

local function spawn_animal(name, pos)
	if not core.registered_entities[name] then return end
	local obj = core.add_entity(pos, name)
	local ent = obj and obj:get_luaentity()
	if ent and rawget(_G, "animalia") then
		pcall(function()
			animalia.initialize_api(ent)
			animalia.protect_from_despawn(ent)
		end)
	end
	return obj
end

confetti = function(pos)
	core.add_particlespawner({
		amount = 80, time = 0.4,
		minpos = vector.add(pos, {x = -0.5, y = 0.5, z = -0.5}),
		maxpos = vector.add(pos, {x = 0.5, y = 1, z = 0.5}),
		minvel = {x = -3, y = 3, z = -3}, maxvel = {x = 3, y = 7, z = 3},
		minacc = {x = 0, y = -8, z = 0}, maxacc = {x = 0, y = -8, z = 0},
		minexptime = 1, maxexptime = 2.5, minsize = 2, maxsize = 4,
		texture = "kids_maze_funke.png", glow = 14,
	})
	core.sound_play("kids_maze_glocke", {pos = pos, gain = 1.0})
end

-- Dorfbewohner Willy am Tor (gibt Tipps und Brot) und Grummel, das liebe Monster (streunt herum)
local function person_props(texture, scale)
	return {
		visual = "mesh", mesh = "character.b3d", textures = {texture},
		visual_size = {x = scale, y = scale},
		collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7 * scale, 0.3},
		physical = true, makes_footstep_sound = true,
	}
end

local willi_obj
core.register_entity(M .. "dorfbewohner", {
	initial_properties = person_props("character.png^[colorize:#a06020:70", 1),
	on_activate = function(self, staticdata)
		local d = staticdata ~= "" and core.deserialize(staticdata) or {}
		self.start_dir = d.dir
		self.tip = 0
		-- nur ein Willy: weitere Kopien entfernen
		if willi_obj and willi_obj ~= self.object and willi_obj:get_pos() then
			self.object:remove()
			return
		end
		willi_obj = self.object
		self.object:set_acceleration({x = 0, y = -9.8, z = 0})
		self.object:set_nametag_attributes({text = "Willy", color = "#FFD028"})
		self.object:set_animation({x = 0, y = 79}, 30, 0)
		self.object:set_armor_groups({immortal = 1})
	end,
	get_staticdata = function(self)
		return core.serialize({dir = self.start_dir})
	end,
	-- Niemand kann Willy verletzen
	on_punch = function(self, puncher)
		if puncher and puncher:is_player() then
			say(puncher, "Willy", "Ow, don't hit me! Right-click me instead.")
		end
		return true
	end,
	on_step = function(self)
		self.t = (self.t or 0) + 1
		if self.t % 10 ~= 0 then return end
		local pos = self.object:get_pos()
		self.greeted = self.greeted or {}
		for _, p in ipairs(core.get_connected_players()) do
			local pp = p:get_pos()
			local pname = p:get_player_name()
			local dist = vector.distance(pos, pp)
			if dist < 6 then
				self.object:set_yaw(math.atan2(-(pp.x - pos.x), pp.z - pos.z))
				if not self.greeted[pname] then
					self.greeted[pname] = true
					say(p, "Willy", "Hi " .. pname .. "! Welcome to the Kids Maze!\n\n"
						.. "The treasure is under the golden tower in the middle. Right-click me and I'll give you tips. "
						.. "Grab feed at the green box first - the animals love it!")
				end
			elseif dist > 14 then
				self.greeted[pname] = nil
			end
		end
	end,
	on_rightclick = function(self, clicker)
		local name = clicker:get_player_name()
		local tips = {
			"Hi, I'm Willy! The treasure is under the golden tower in the middle.",
			"Climb a lookout tower and you'll see the paths from above!",
			"Three gates are locked. Only solving the task opens them. Right-click a gate!",
			"The floor has colors: red is northwest, blue northeast, yellow southeast, purple southwest. And the tall tower in front of the entrance has a ladder - you can see everything from up there!",
			"Wrong turns often end at a tower or an animal. Just turn around!",
		}
		if self.start_dir then
			tips[#tips + 1] = "My tip: from the gate, the path first leads " .. self.start_dir .. "."
		end
		self.tip = self.tip % #tips + 1
		say(clicker, "Willy", tips[self.tip])
		if self.tip == 1 then
			local inv = clicker:get_inventory()
			if core.registered_items["farming:bread"] then inv:add_item("main", "farming:bread 2") end
		end
	end,
})

core.register_entity(M .. "grummel", {
	initial_properties = person_props("character.png^[colorize:#30c030:150", 1.15),
	on_activate = function(self)
		self.object:set_acceleration({x = 0, y = -9.8, z = 0})
		self.object:set_nametag_attributes({text = "Grummel (Monster)", color = "#40E040"})
		self.object:set_armor_groups({immortal = 1})
		self.timer, self.yaw = 0, math.random() * 6.28
	end,
	on_step = function(self, dtime)
		self.timer = self.timer + dtime
		local v = self.object:get_velocity()
		if self.timer > 2 then
			self.timer = 0
			if math.random() < 0.4 then
				self.walking = false
			else
				self.walking = true
				self.yaw = math.random() * 6.28
			end
			self.object:set_animation(self.walking and {x = 168, y = 187} or {x = 0, y = 79}, 30, 0)
		end
		local speed = self.walking and 1.2 or 0
		self.object:set_yaw(self.yaw)
		local vy = v.y
		if self.walking and v.y == 0 and (math.abs(v.x) + math.abs(v.z)) < 0.2 then
			vy = 5   -- gegen die Hecke gelaufen: huepfen und Richtung aendern
			self.yaw = math.random() * 6.28
		end
		self.object:set_velocity({x = -math.sin(self.yaw) * speed, y = vy, z = math.cos(self.yaw) * speed})
	end,
	on_rightclick = function(self, clicker)
		local pos = self.object:get_pos()
		self.object:add_velocity({x = 0, y = 7, z = 0})
		confetti(pos)
		core.chat_send_player(clicker:get_player_name(),
			"Grummel: BOOOH! ... Hehe, I'm just a friendly monster. Here, an apple!")
		local left = clicker:get_inventory():add_item("main", "default:apple")
		if not left:is_empty() then core.add_item(pos, left) end
	end,
})

core.register_node(M .. "wundertruhe", {
	description = "Wonder Chest",
	paramtype2 = "facedir",
	tiles = {"default_chest_top.png" .. LILA, "default_chest_top.png" .. LILA,
		"default_chest_side.png" .. LILA, "default_chest_side.png" .. LILA,
		"default_chest_side.png" .. LILA, "default_chest_front.png" .. LILA},
	groups = {choppy = 2, not_in_creative_inventory = 1},
	diggable = false,
	light_source = 6,
	is_ground_content = false,
	sounds = default.node_sound_wood_defaults(),
	on_rightclick = function(pos, _, clicker)
		if not clicker or not clicker:is_player() then return end
		local pname = clicker:get_player_name()
		local inv = clicker:get_inventory()
		local prizes = {
			{"default:diamond 2", "2 diamonds"}, {"default:apple 6", "6 apples"},
			{"default:gold_ingot 4", "4 gold bars"}, {"farming:bread 4", "4 loaves of bread"},
			{"default:mese_crystal 2", "2 mese crystals"}, {"wool:pink 8", "8 pink wool"},
			{"default:goldblock 1", "a gold block"}, {"default:pick_diamond 1", "a diamond pickaxe"},
		}
		local choices = {}
		for _, pz in ipairs(prizes) do
			if core.registered_items[pz[1]:match("^%S+")] then choices[#choices + 1] = pz end
		end
		local roll = math.random(1, 4)
		local above = vector.add(pos, {x = 0, y = 1, z = 0})
		if roll == 1 and core.registered_entities["animalia:chicken"] then
			local a = ANIMALS[math.random(1, #ANIMALS)]
			spawn_animal(a[1], above)
			core.chat_send_player(pname, "Surprise! A " .. a[2]:lower() .. " jumped out of the chest!")
		elseif #choices > 0 then
			local pz = choices[math.random(1, #choices)]
			local left = inv:add_item("main", pz[1])
			if not left:is_empty() then core.add_item(pos, left) end
			big_msg(clicker, "You found " .. pz[2] .. "!", 0xFF80FF)
			core.chat_send_player(pname, "Surprise! You found " .. pz[2] .. "!")
		end
		confetti(pos)
		core.after(1.5, function()
			if core.get_node(pos).name == M .. "wundertruhe" then
				core.remove_node(pos)
				confetti(pos)
			end
		end)
	end,
})

-- Raetseltor: versperrt den gesamten Gang, Rechtsklick -> Frage, richtige Antwort oeffnet es
local asking = {}   -- Spielername -> {pos=, fails=}

local function norm(s)
	s = (s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	s = s:gsub("ä", "ae"):gsub("ö", "oe"):gsub("ü", "ue"):gsub("ß", "ss")
	return s
end

core.register_node(M .. "raetseltor", {
	description = "Riddle Gate",
	tiles = {"default_stone_brick.png^[colorize:#ff9a00:110"},
	groups = {unbreakable = 1},
	diggable = false,
	light_source = 8,
	is_ground_content = false,
	sounds = default.node_sound_stone_defaults(),
	on_rightclick = function(pos, _, clicker)
		if not clicker or not clicker:is_player() then return end
		local name = clicker:get_player_name()
		local meta = core.get_meta(pos)
		local q = meta:get_string("q")
		if q == "" then return end
		local keep = asking[name] and vector.equals(asking[name].pos, pos) and asking[name].fails or 0
		asking[name] = {pos = pos, fails = keep}
		core.show_formspec(name, M .. "raetsel",
			"formspec_version[4]size[11,7]"
			.. "style_type[label;font_size=*2;font=bold]label[0.6,0.8;RIDDLE GATE - solve the task!]"
			.. "style_type[textarea;font_size=*1.7]textarea[0.6,1.4;9.8,2.4;;;" .. core.formspec_escape(q) .. "]"
			.. "style_type[field;font_size=*1.7]field[0.6,4.5;9.8,1;antwort;Your answer:;]"
			.. "style_type[button_exit;font_size=*1.5]button_exit[3.5,5.7;4,0.9;ok;Give answer]")
	end,
})

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname == M .. "kompass" then
		if not (player and player:is_player()) then return end
		if fields.back then to_start(player) end
		if fields.new then restart_maze(player) end
		if fields.rebuild and core.check_player_privs(player:get_player_name(), {server = true}) then
			rebuild_maze()
		end
		if fields.map and core.check_player_privs(player:get_player_name(), {server = true}) then
			overview(player)
		end
		return
	end
	if formname == M .. "ende" and fields.new and restart_maze then
		restart_maze(player)
		return
	end
	if formname ~= M .. "raetsel" then return end
	if not (fields.ok or fields.key_enter_field) then return end
	local name = player:get_player_name()
	local st = asking[name]
	if not st then return end
	local meta = core.get_meta(st.pos)
	local given = norm(fields.antwort)
	local right = false
	for ans in meta:get_string("a"):gmatch("[^|]+") do
		if given == norm(ans) then right = true end
	end
	if right then
		asking[name] = nil
		for _, p in ipairs(core.find_nodes_in_area(vector.subtract(st.pos, {x = 2, y = 3, z = 2}),
				vector.add(st.pos, {x = 2, y = 3, z = 2}), M .. "raetseltor")) do
			core.remove_node(p)
		end
		confetti(st.pos)
		core.sound_play("kids_maze_fanfare", {to_player = name, gain = 0.8})
		big_msg(player, "CORRECT!", 0x80FF80)
		say(player, "Riddle Gate", "CORRECT! The gate is open - off you go!")
	else
		st.fails = st.fails + 1
		local msg = "Not right yet. Try again (right-click the gate)!"
		if st.fails >= 2 then msg = msg .. "\n\nHint: " .. meta:get_string("hint") end
		say(player, "Raetseltor", msg)
	end
end)

---------------------------------------------------------------- Labyrinth erzeugen
local function rng(seed)
	local s = seed % 2147483647
	if s <= 0 then s = s + 2147483646 end
	return function(n)
		s = s * 16807 % 2147483647
		return s % n + 1
	end
end

local function key(cx, cz) return cx .. "," .. cz end
local function in_plaza(cx, cz) return cx >= C - 1 and cx <= C + 1 and cz >= C - 1 and cz <= C + 1 end

local function gen_maze(seed)
	local R = rng(seed)
	local edges, visited = {}, {[key(ENTRY, 0)] = true}
	local function link(a, b, c, d)
		edges[key(a, b) .. "|" .. key(c, d)] = true
		edges[key(c, d) .. "|" .. key(a, b)] = true
	end
	local stack = {{ENTRY, 0}}
	while #stack > 0 do
		local cur = stack[#stack]
		local nb = {}
		for _, d in ipairs(DIRS) do
			local nx, nz = cur[1] + d[1], cur[2] + d[2]
			if nx >= 0 and nx < N and nz >= 0 and nz < N and not visited[key(nx, nz)] then
				nb[#nb + 1] = {nx, nz}
			end
		end
		if #nb == 0 then
			stack[#stack] = nil
		else
			local n = nb[R(#nb)]
			link(cur[1], cur[2], n[1], n[2])
			visited[key(n[1], n[2])] = true
			stack[#stack + 1] = n
		end
	end
	for cx = C - 1, C + 1 do for cz = C - 1, C + 1 do
		if cx < C + 1 then link(cx, cz, cx + 1, cz) end
		if cz < C + 1 then link(cx, cz, cx, cz + 1) end
	end end
	local maze = {edges = edges}
	function maze.open(a, b, c, d) return edges[key(a, b) .. "|" .. key(c, d)] == true end
	function maze.neighbors(cx, cz)
		local out = {}
		for _, d in ipairs(DIRS) do
			if maze.open(cx, cz, cx + d[1], cz + d[2]) then out[#out + 1] = {cx + d[1], cz + d[2]} end
		end
		return out
	end
	-- kuerzester Weg Eingang -> Platz (BFS)
	local prev, queue, goal = {[key(ENTRY, 0)] = false}, {{ENTRY, 0}}, nil
	local qi = 1
	while qi <= #queue do
		local c = queue[qi]; qi = qi + 1
		if in_plaza(c[1], c[2]) then goal = c break end
		for _, n in ipairs(maze.neighbors(c[1], c[2])) do
			if prev[key(n[1], n[2])] == nil then
				prev[key(n[1], n[2])] = c
				queue[#queue + 1] = n
			end
		end
	end
	local path = {}
	while goal do
		table.insert(path, 1, goal)
		goal = prev[key(goal[1], goal[2])] or nil
	end
	maze.path = path
	return maze, R
end

-- Ist der Knoten (X, Z) Hecke?
local function is_hedge(maze, X, Z)
	if X < 0 or Z < 0 or X > S - 1 or Z > S - 1 then return false end
	if X >= P1 and X <= P2 and Z >= P1 and Z <= P2 then return false end
	if Z == 0 and (X == ENTRY * 3 + 1 or X == ENTRY * 3 + 2) then return false end
	local xw, zw = X % 3 == 0, Z % 3 == 0
	if xw and zw then return true end
	if xw then
		local cx, cz = X / 3, math.floor(Z / 3)
		return cx == 0 or cx == N or not maze.open(cx - 1, cz, cx, cz)
	end
	if zw then
		local cx, cz = math.floor(X / 3), Z / 3
		return cz == 0 or cz == N or not maze.open(cx, cz - 1, cx, cz)
	end
	return false
end

---------------------------------------------------------------- Bauen
local function builder(o)
	local B = {}
	function B.pos(x, y, z) return {x = o.x + x, y = o.y + y, z = o.z + z} end
	function B.set(x, y, z, name, p2)
		core.set_node(B.pos(x, y, z), {name = name, param2 = p2 or 0})
	end
	function B.box(x1, y1, z1, x2, y2, z2, name)
		for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do B.set(x, y, z, name) end end end
	end
	function B.fill(x1, y1, z1, x2, y2, z2, name)
		local p1, p2 = B.pos(x1, y1, z1), B.pos(x2, y2, z2)
		local vm = core.get_voxel_manip()
		local e1, e2 = vm:read_from_map(p1, p2)
		local area = VoxelArea:new({MinEdge = e1, MaxEdge = e2})
		local data, p2d = vm:get_data(), vm:get_param2_data()
		local cid = core.get_content_id(name)
		for i in area:iterp(p1, p2) do data[i] = cid; p2d[i] = 0 end
		vm:set_data(data)
		vm:set_param2_data(p2d)
		vm:write_to_map(true)
	end
	-- Wandschild: d = Richtung von Schild zur Wand
	local WM = {["1,0"] = 2, ["-1,0"] = 3, ["0,1"] = 4, ["0,-1"] = 5}
	function B.sign(x, y, z, d, text)
		local p = B.pos(x, y, z)
		core.set_node(p, {name = "default:sign_wall_wood", param2 = WM[d[1] .. "," .. d[2]]})
		signs_lib.update_sign(p, {text = text})
	end
	function B.ladder(x, y, z, d)
		core.set_node(B.pos(x, y, z), {name = "default:ladder_wood", param2 = WM[d[1] .. "," .. d[2]]})
	end
	B.signed = {}
	return B
end

-- Schild an eine Heckenwand innerhalb der Zelle haengen
local function sign_in_cell(B, maze, cx, cz, text)
	B.signed[key(cx, cz)] = true
	for _, n in ipairs({{3 * cx + 1, 3 * cz + 1}, {3 * cx + 2, 3 * cz + 1},
			{3 * cx + 1, 3 * cz + 2}, {3 * cx + 2, 3 * cz + 2}}) do
		for _, d in ipairs(DIRS) do
			if is_hedge(maze, n[1] + d[1], n[2] + d[2]) then
				B.sign(n[1], 1, n[2], d, text)
				return true
			end
		end
	end
	return false
end

local TOWERS = {
	{"wool:red", "RED TOWER"},
	{"wool:blue", "BLUE TOWER"},
	{"wool:yellow", "YELLOW TOWER"},
	{"wool:violet", "PURPLE TOWER"},
}

-- Aussichtsturm in einer Sackgasse: Leiter hoch, Plattform ueber den Hecken mit Gelaender
local TOWER_H = 6
local function viewing_tower(B, c, nb)
	local o = {nb[1] - c[1], nb[2] - c[2]}
	local x0, z0 = 3 * c[1] + 1, 3 * c[2] + 1
	local lx = x0 + (o[1] == 1 and 1 or 0)
	local lz = z0 + (o[2] == 1 and 1 or 0)
	local d = {-o[1], -o[2]}
	B.box(x0, 0, z0, x0 + 1, TOWER_H - 1, z0 + 1, "default:stonebrick")
	B.box(x0 - 1, TOWER_H, z0 - 1, x0 + 2, TOWER_H, z0 + 2, "default:wood")
	for y = 0, TOWER_H do B.ladder(lx, y, lz, d) end
	for x = x0 - 1, x0 + 2 do for z = z0 - 1, z0 + 2 do
		if x == x0 - 1 or x == x0 + 2 or z == z0 - 1 or z == z0 + 2 then
			B.set(x, TOWER_H + 1, z, "default:fence_wood")
		end
	end end
	-- Schild oben, an einem Holzblock im Gelaender
	local fx, fz = x0 + 1 - (lx - x0), z0 + 1 - (lz - z0)
	B.set(fx + d[1], TOWER_H + 1, fz + d[2], "default:wood")
	B.sign(fx, TOWER_H + 1, fz, d, "VIEW!\nFrom up here you\nsee all the paths.\nWhere is the\ngolden top?")
	-- Schild in der Heckenluecke davor
	local gx = o[1] ~= 0 and (o[1] > 0 and x0 + 2 or x0 - 1) or (lx == x0 and x0 + 1 or x0)
	local gz = o[2] ~= 0 and (o[2] > 0 and z0 + 2 or z0 - 1) or (lz == z0 and z0 + 1 or z0)
	B.sign(gx, 1, gz, d, "LOOKOUT TOWER\nClimb the\nladder!")
end

-- Hoher Uebersichtsturm vor dem Eingang: Leiter hoch, dann sieht man alle Gaenge von oben
local OVERVIEW_H = 12
local function overview_tower(B, x0, z0)
	B.box(x0, 0, z0, x0 + 1, OVERVIEW_H - 1, z0 + 1, "default:stonebrick")
	B.box(x0 - 1, OVERVIEW_H, z0 - 1, x0 + 2, OVERVIEW_H, z0 + 2, "default:wood")
	for y = 0, OVERVIEW_H do B.ladder(x0, y, z0, {0, 1}) end
	for x = x0 - 1, x0 + 2 do for z = z0 - 1, z0 + 2 do
		if x == x0 - 1 or x == x0 + 2 or z == z0 - 1 or z == z0 + 2 then
			B.set(x, OVERVIEW_H + 1, z, "default:fence_wood")
		end
	end end
	for _, c in ipairs({{x0 - 1, z0 - 1}, {x0 + 2, z0 - 1}, {x0 - 1, z0 + 2}, {x0 + 2, z0 + 2}}) do
		B.set(c[1], OVERVIEW_H + 2, c[2], "default:meselamp")
	end
	B.sign(x0 + 1, 1, z0 - 1, {0, 1}, "OVERVIEW!\nClimb the\nladder and see\nthe whole\nmaze!")
end

local function build(o, seed)
	local B = builder(o)
	local maze, R = gen_maze(seed)
	-- alte Schild-Texte entfernen
	for _, obj in ipairs(core.get_objects_in_area(B.pos(-8, -1, -14), B.pos(S + 6, 14, S + 6))) do
		if not obj:is_player() then obj:remove() end
	end
	B.fill(-8, -12, -14, S + 6, -2, S + 6, "default:dirt")
	B.fill(-8, -1, -14, S + 6, -1, S + 6, "default:dirt_with_grass")
	B.fill(-8, 0, -14, S + 6, 14, S + 6, "air")
	-- Farbige Boeden je Viertel: so weiss man immer, wo man ist (Farben wie die bunten Tuerme)
	local mid = math.floor(S / 2)
	B.fill(1, -1, mid, mid - 1, -1, S - 2, "wool:red")        -- Nordwest
	B.fill(mid, -1, mid, S - 2, -1, S - 2, "wool:blue")       -- Nordost
	B.fill(mid, -1, 1, S - 2, -1, mid - 1, "wool:yellow")     -- Suedost
	B.fill(1, -1, 1, mid - 1, -1, mid - 1, "wool:violet")     -- Suedwest
	B.fill(ENTRY * 3, -1, -9, ENTRY * 3 + 3, -1, 0, "default:gravel")
	B.fill(P1, -1, P1, P2, -1, P2, "default:stone_block")

	for X = 0, S - 1 do for Z = 0, S - 1 do
		if is_hedge(maze, X, Z) then B.box(X, 0, Z, X, 2, Z, M .. "hecke") end
	end end

	-- Fackeln auf jedem zweiten Heckenpfosten: nachts gruselig-gemuetliches Licht
	for X = 0, S - 1, 3 do for Z = 0, S - 1, 3 do
		if (X / 3 + Z / 3) % 2 == 0 and is_hedge(maze, X, Z) and not (X >= P1 - 1 and X <= P2 + 1 and Z >= P1 - 1 and Z <= P2 + 1) then
			B.set(X, 3, Z, "default:torch", 1)
		end
	end end

	overview_tower(B, ENTRY * 3 - 9, -7)

	-- Tor mit Steinsaeulen und Schild
	local gx = ENTRY * 3
	B.box(gx, 0, 0, gx, 3, 0, "default:stonebrick")
	B.box(gx + 3, 0, 0, gx + 3, 3, 0, "default:stonebrick")
	B.box(gx + 1, 3, 0, gx + 2, 3, 0, "default:stonebrick")
	B.sign(gx + 1, 3, -1, {0, 1}, "KIDS\nMAZE")
	B.sign(gx - 1, 1, -1, {0, 1}, "Find the treasure\nunder the\nGOLDEN tower!\nThe clock starts\nat the gate.")
	B.sign(gx + 4, 1, -1, {0, 1}, "Tip: Keep one\nhand on the hedge\nand follow it\nall the way.")

	-- Futterkiste, Farb-Hinweis und Aussichtsturm-Hinweis am Tor
	B.set(gx - 3, 0, -1, M .. "futterkiste", 0)
	B.sign(gx - 3, 1, -1, {0, 1}, "FEED BOX!\nGrab feed for\nthe animals in\nthe maze!")
	B.sign(gx + 5, 1, -1, {0, 1}, "FLOOR COLORS:\nRED = Northwest\nBLUE = Northeast\nYELLOW = Southeast\nPURPLE = Southwest")
	B.sign(gx + 6, 1, -1, {0, 1}, "Animals: pick feed\nin your hotbar,\nright-click them.\nTowers with\nladders = views!")

	-- goldener Turm + Schatzkiste in der Mitte
	local tx = ENTRY * 3 + 1
	B.box(tx, 0, tx, tx + 1, 7, tx + 1, "default:goldblock")
	B.box(tx, 8, tx, tx + 1, 8, tx + 1, "default:meselamp")
	B.set(tx, 0, tx - 2, M .. "schatzkiste", 0)
	B.set(tx + 1, 0, tx - 2, "default:goldblock")
	B.sign(tx, 1, tx - 1, {0, 1}, "THE TREASURE!\nRight-click the\ngolden chest.")

	-- Sackgassen sammeln (nicht Platz, nicht Eingang)
	local on_path = {}
	for _, c in ipairs(maze.path) do on_path[key(c[1], c[2])] = true end
	local dead = {}
	for cx = 0, N - 1 do for cz = 0, N - 1 do
		if not in_plaza(cx, cz) and not (cx == ENTRY and cz == 0)
				and #maze.neighbors(cx, cz) == 1 then
			dead[#dead + 1] = {cx, cz}
		end
	end end

	-- bunte Tuerme: je Viertel die Sackgasse, die am weitesten draussen liegt
	local used = {}
	local quads = {{0, 1}, {1, 1}, {1, 0}, {0, 0}}   -- NW, NO, SO, SW
	for i, q in ipairs(quads) do
		local best, bd
		for _, c in ipairs(dead) do
			local qx, qz = c[1] > C and 1 or 0, c[2] > C and 1 or 0
			if c[1] ~= C and c[2] ~= C and qx == q[1] and qz == q[2] and not used[key(c[1], c[2])] then
				local dist = math.abs(c[1] - C) + math.abs(c[2] - C)
				if not bd or dist > bd then best, bd = c, dist end
			end
		end
		if best then
			used[key(best[1], best[2])] = true
			local t = TOWERS[i]
			local x0, z0 = 3 * best[1] + 1, 3 * best[2] + 1
			B.box(x0, 0, z0, x0 + 1, 5, z0 + 1, t[1])
			B.box(x0, 6, z0, x0 + 1, 6, z0 + 1, "default:meselamp")
			local nb = maze.neighbors(best[1], best[2])[1]
			local d = {best[1] - nb[1], best[2] - nb[2]}
			-- Schild in der Heckenluecke vor dem Turm, Blick auf den Turm
			local gx2 = d[1] ~= 0 and (d[1] > 0 and 3 * best[1] or 3 * best[1] + 3) or x0
			local gz2 = d[2] ~= 0 and (d[2] > 0 and 3 * best[2] or 3 * best[2] + 3) or z0
			B.sign(gx2, 1, gz2, d, t[2] .. "\nDead end!\nThe treasure is\nunder the GOLDEN\ntower.")
		end
	end

	-- freie Sackgassen mischen (deterministisch per Seed)
	local pool = {}
	for _, c in ipairs(dead) do
		if not used[key(c[1], c[2])] then pool[#pool + 1] = c end
	end
	for i = #pool, 2, -1 do
		local j = R(i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local function take()
		local c = table.remove(pool)
		if c then used[key(c[1], c[2])] = true end
		return c
	end

	-- 2 Aussichtstuerme
	for _ = 1, 2 do
		local c = take()
		if c then viewing_tower(B, c, maze.neighbors(c[1], c[2])[1]) end
	end

	-- Tiere zum Fuettern (Mod animalia)
	if core.registered_entities["animalia:chicken"] then
		for i = 1, #ANIMALS do
			-- die ersten zwei in Sackgassen mit Schild, der Rest streunt durchs Labyrinth
			local c = i <= 2 and take() or nil
			if not c then
				repeat c = {R(N) - 1, R(N) - 1} until not in_plaza(c[1], c[2])
			end
			local a = ANIMALS[i]
			for k = 1, a[4] do
				spawn_animal(a[1], B.pos(3 * c[1] + 1 + (k - 1) * 0.6, 0.5, 3 * c[2] + 1))
			end
			if i <= 2 then
				sign_in_cell(B, maze, c[1], c[2],
					a[2] .. "!\nI like " .. a[3] .. ".\nGrab feed at the gate\nand click me!")
			end
		end
	end

	-- Wundertruhen
	for _ = 1, 2 do
		local c = take()
		if c then
			B.set(3 * c[1] + 1, 0, 3 * c[2] + 1, M .. "wundertruhe", 0)
			sign_in_cell(B, maze, c[1], c[2], "WONDER CHEST!\nRight-click and\nbe surprised!")
		end
	end

	-- Willy am Tor (verraet die erste Richtung) und Grummel irgendwo im Labyrinth
	do
		local a, b = maze.path[1], maze.path[2]
		local dirname = b and ((b[1] > a[1] and "east") or (b[1] < a[1] and "west") or "north") or "north"
		core.add_entity(B.pos(gx + 1.5, 0.5, -4), M .. "dorfbewohner", core.serialize({dir = dirname}))
		local c
		repeat c = {R(N) - 1, R(N) - 1} until not in_plaza(c[1], c[2])
		core.add_entity(B.pos(3 * c[1] + 1.5, 0.5, 3 * c[2] + 1.5), M .. "grummel")
	end

	-- Schneemann in einer weiteren Sackgasse (Hut schaut ueber die Hecke)
	local jokes = {
		"Dead end!\nTurn around\nand keep looking.",
		"Only a worm\nlives here.\nWrong way!",
		"Oh no, a dead\nend! But you've\ngot this!",
	}
	local placed_snow, ji = false, 1
	for _, c in ipairs(dead) do
		if not used[key(c[1], c[2])] and not on_path[key(c[1], c[2])] then
			local x0, z0 = 3 * c[1] + 1, 3 * c[2] + 1
			if not placed_snow then
				B.box(x0, 0, z0, x0, 2, z0, "default:snowblock")
				B.set(x0, 3, z0, "default:coalblock")
				used[key(c[1], c[2])] = true
				sign_in_cell(B, maze, c[1], c[2], "Hi, I'm the\nsnowman! There's\nno way through\nhere.")
				placed_snow = true
			elseif ji <= #jokes and R(3) == 1 then
				used[key(c[1], c[2])] = true
				sign_in_cell(B, maze, c[1], c[2], jokes[ji])
				ji = ji + 1
			end
		end
	end

	-- Lob-Schilder auf dem richtigen Weg: an jeder zweiten Kreuzung im richtigen Abzweig
	local praise = {"Correct!\nKeep going!", "Great!\nYou're on the\nright track.",
		"Exactly this\nway!", "Well done!"}
	local junctions, pi = 0, 1
	for i = 2, #maze.path - 1 do
		local c = maze.path[i]
		if #maze.neighbors(c[1], c[2]) >= 3 then
			junctions = junctions + 1
			local nxt = maze.path[i + 1]
			if junctions % 2 == 1 and not in_plaza(nxt[1], nxt[2]) then
				sign_in_cell(B, maze, nxt[1], nxt[2], praise[(pi - 1) % #praise + 1])
				pi = pi + 1
			end
		end
	end
	if #maze.path >= 3 then
		local c = maze.path[#maze.path - 1]
		sign_in_cell(B, maze, c[1], c[2], "Almost there!\nThe golden tower\nis just ahead!")
	end

	-- Raetseltore: drei Tore mit Textaufgaben (leicht, mittel, schwer), Antwort als Zahl oder Wort
	local NUMW = {[0] = "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
		"eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"}
	local function A(n) return NUMW[n] and (n .. "|" .. NUMW[n]) or tostring(n) end
	local easy = {
		{"Grummel has 7 apples. Willy gives him 5 more. How many apples does Grummel have now?", A(12), "Add 7 and 5."},
		{"There are 9 chickens in the maze. 4 run away. How many are left?", A(5), "Take 4 from 9."},
		{"8 torches burn in the maze. 6 more are lit. How many burn now?", A(14), "Add 8 and 6."},
		{"Willy has 15 diamonds. 6 fall into the lava. How many are left?", A(9), "Take 6 from 15."},
		{"Grummel bakes 12 loaves of bread and eats 5. How many are left?", A(7), "Take 5 from 12."},
	}
	local medium = {
		{"One sheep has 4 legs. How many legs do 5 sheep have together?", A(20), "Multiply 5 by 4."},
		{"Each tower has 3 torches. There are 6 towers. How many torches is that?", A(18), "Multiply 6 by 3."},
		{"20 apples are shared fairly among 4 animals. How many does each animal get?", A(5), "Divide 20 by 4."},
		{"A spider has 8 legs. How many legs do 3 spiders have together?", "24|twenty-four", "Multiply 3 by 8."},
		{"Grummel and Willy share 18 gold bars fairly. How many does each get?", A(9), "Divide 18 by 2."},
	}
	local hard = {
		{"Grummel has 5 diamonds. Willy has twice as many. How many do they have together?", A(15), "First Willy's: 5 times 2. Then add Grummel's."},
		{"There are 6 pens with 4 animals in each. 5 animals escape. How many stay in the pens?", "19|nineteen", "First 6 times 4. Then minus 5."},
		{"Willy buys 3 ice creams at 2 gold coins each and pays with 10 coins. How much change does he get?", A(4), "First 3 times 2. Then 10 minus that."},
		{"A treasure chest has 3 drawers with 7 coins in each. 4 coins fall out. How many stay inside?", "17|seventeen", "First 3 times 7. Then minus 4."},
	}
	local words, numbers = easy, medium

	local function pick(list, avoid)
		local w
		repeat w = list[R(#list)] until w ~= avoid or #list < 2
		return w
	end
	local function gate(a, b, q, ans, hint, text)
		local dx, dz = b[1] - a[1], b[2] - a[2]
		local xs, zs
		if dx ~= 0 then
			local X = dx > 0 and 3 * a[1] + 3 or 3 * a[1]
			xs, zs = {X}, {3 * a[2] + 1, 3 * a[2] + 2}
		else
			local Z = dz > 0 and 3 * a[2] + 3 or 3 * a[2]
			xs, zs = {3 * a[1] + 1, 3 * a[1] + 2}, {Z}
		end
		for _, x in ipairs(xs) do for _, z in ipairs(zs) do for y = 0, 2 do
			B.set(x, y, z, M .. "raetseltor")
			local m = core.get_meta(B.pos(x, y, z))
			m:set_string("q", q); m:set_string("a", ans); m:set_string("hint", hint)
		end end end
		sign_in_cell(B, maze, a[1], a[2], text)
	end
	local path = maze.path
	local gates = 0
	if #path >= 10 then
		local w = pick(words)
		local m = math.floor(#path * 0.3)
		gate(path[m], path[m + 1], w[1], w[2], w[3], "RIDDLE GATE 1!\nRight-click and\nsolve the\ntask.")
		local n = pick(numbers)
		m = math.floor(#path * 0.62)
		gate(path[m], path[m + 1], n[1], n[2], n[3], "RIDDLE GATE 2!\nA slightly\nharder\ntask.")
		gates = 2
	end
	if #path >= 3 then
		local h = pick(hard)
		gate(path[#path - 1], path[#path], h[1], h[2], h[3],
			"LAST GATE!\nSolve the task,\nthen you're at\nthe treasure.")
		gates = gates + 1
	end

	-- Himmelsrichtungs-Schilder auf dem richtigen Weg
	for i = 3, #maze.path - 2, 4 do
		local c = maze.path[i]
		if not B.signed[key(c[1], c[2])] and not in_plaza(c[1], c[2]) then
			local ns = c[2] < C - 1 and "south" or (c[2] > C + 1 and "north" or "")
			local ew = c[1] < C - 1 and "west" or (c[1] > C + 1 and "east" or "")
			local where = (ns == "" and ew == "") and "the middle" or ("the " .. ns .. ew)
			if ns == "" then where = "the " .. ew end
			sign_in_cell(B, maze, c[1], c[2],
				"You are in\n" .. where .. ".\nThe treasure is\nin the MIDDLE.")
		end
	end

	storage:set_string("origin", core.serialize(o))
	storage:set_int("seed", seed)
	storage:set_int("ver", VERSION)
	core.log("action", ("[kids_maze] built at %s, seed %d, path %d cells, %d dead ends")
		:format(core.pos_to_string(o), seed, #maze.path, #dead))
	return maze
end

---------------------------------------------------------------- Spielablauf
local function origin()
	local s = storage:get_string("origin")
	return s ~= "" and core.deserialize(s) or nil
end

local function ground_y()
	if core.get_mapgen_setting("mg_name") == "flat" then
		local g = tonumber(core.get_mapgen_setting("mgflat_ground_level"))
		if g then return g end
	end
	-- never build below sea level, or the maze floods with water
	local wl = tonumber(core.get_mapgen_setting("water_level")) or 1
	local found
	for y = 40, -20, -1 do
		local def = core.registered_nodes[core.get_node({x = 0, y = y, z = 0}).name]
		if def and def.walkable then found = y break end
	end
	return math.max(found or 8, wl + 2)
end

local runs = {}   -- name -> {start=us, done=bool, hud=id}

local function fmt(sec)
	return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

core.register_entity(M .. "kamera", {
	initial_properties = {physical = false, pointable = false, visual = "sprite",
		textures = {"blank.png"}, is_visible = false, static_save = false},
})

local function detach(player)
	local parent = player:get_attach()
	if parent then
		player:set_detach()
		if not parent:is_player() then parent:remove() end
	end
end

-- Ueberblick von oben (fuer Eltern: verraet den Weg!)
overview = function(player)
	local o = origin()
	if not o then return end
	detach(player)
	local from = {x = o.x + S / 2, y = o.y + 42, z = o.z - 14}
	local cam = core.add_entity(from, M .. "kamera")
	if cam then player:set_attach(cam, "", {x = 0, y = 0, z = 0}) end
	core.after(0.3, function()
		if not player:is_player() then return end
		local dy, dz = -42, S / 2 + 14
		player:set_look_horizontal(0)
		player:set_look_vertical(-math.atan2(dy, dz))
	end)
end

to_start = function(player)
	local o = origin()
	if not o then return end
	detach(player)
	local name = player:get_player_name()
	local r = runs[name]
	if r and r.hud then player:hud_remove(r.hud) end
	runs[name] = {}
	taken[name] = nil
	player:set_pos({x = o.x + ENTRY * 3 + 1.5, y = o.y, z = o.z - 6})
	player:set_look_horizontal(0)
	player:set_look_vertical(0)
	core.set_timeofday(0.45)
end

local function emerge_and_build(seed, done)
	core.emerge_area({x = -12, y = -30, z = -18}, {x = S + 10, y = 40, z = S + 10},
		function(_, _, remaining)
			if remaining > 0 then return end
			local g = ground_y()
			build({x = 0, y = g + 1, z = 0}, seed)
			if done then done() end
		end)
end

local rebuilding = false
restart_maze = function(player)
	if rebuilding then return end
	rebuilding = true
	core.chat_send_player(player:get_player_name(), "Building a new maze ... one moment!")
	emerge_and_build(math.random(1, 2000000000), function()
		rebuilding = false
		for _, pl in ipairs(core.get_connected_players()) do to_start(pl) end
		core.chat_send_all("A new maze is ready! Good luck!")
	end)
end

-- Umbau mit gleichem Grundriss (Eltern-Funktion im Kompass-Menue)
rebuild_maze = function()
	emerge_and_build(storage:get_int("seed"), function()
		for _, pl in ipairs(core.get_connected_players()) do to_start(pl) end
		core.chat_send_all("The maze was rebuilt: towers, animals and surprises!")
	end)
end

-- Kompass-Menue: alle Funktionen als Knoepfe statt Chat-Befehle
show_compass_menu = function(player)
	if not (player and player:is_player()) then return end
	local name = player:get_player_name()
	local parent_btns, h, close_y = "", 4.5, 3.5
	if core.check_player_privs(name, {server = true}) then
		parent_btns = "button[0.6,3.5;9.8,0.9;rebuild;Rebuild (same layout)]"
			.. "button[0.6,4.4;9.8,0.9;map;Parent view (from above)]"
		h, close_y = 6.3, 5.3
	end
	core.show_formspec(name, M .. "kompass",
		"formspec_version[4]size[10," .. h .. "]"
		.. "style_type[label;font_size=*2;font=bold]label[0.6,0.7;GOLDEN COMPASS]"
		.. "style_type[button;font_size=*1.5]"
		.. "button[0.6,1.7;9.8,0.9;back;Back to the gate]"
		.. "button[0.6,2.6;9.8,0.9;new;New maze]"
		.. parent_btns
		.. "button_exit[0.6," .. close_y .. ";3.2,0.9;ok;Close]")
end

local function finish(player, r)
	local sec = math.floor((core.get_us_time() - r.start) / 1e6)
	r.done = true
	local name = player:get_player_name()
	local best = storage:get_int("best")
	local msg = "HOORAY, " .. name .. "! You found the golden tower - in " .. fmt(sec) .. "!"
	if best == 0 or sec < best then
		storage:set_int("best", sec)
		msg = msg .. " NEW BEST TIME!"
	else
		msg = msg .. " (Best time: " .. fmt(best) .. ")"
	end
	core.chat_send_all(msg)
	if r.hud then player:hud_change(r.hud, "text", "Done: " .. fmt(sec)) end
	core.sound_play("kids_maze_fanfare", {to_player = name, gain = 1.0})
	local p = player:get_pos()
	core.add_particlespawner({
		amount = 120, time = 2.5,
		minpos = vector.add(p, {x = -3, y = 1, z = -3}), maxpos = vector.add(p, {x = 3, y = 5, z = 3}),
		minvel = {x = -1, y = 1, z = -1}, maxvel = {x = 1, y = 3, z = 1},
		minacc = {x = 0, y = -2, z = 0}, maxacc = {x = 0, y = -2, z = 0},
		minexptime = 1.5, maxexptime = 3, minsize = 2, maxsize = 4,
		texture = "kids_maze_funke.png", glow = 14,
	})
end

local acc = 0
core.register_globalstep(function(dtime)
	acc = acc + dtime
	if acc < 0.5 then return end
	acc = 0
	local o = origin()
	if not o then return end
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local r = runs[name]
		if not r then r = {}; runs[name] = r end
		local p = player:get_pos()
		local lx, lz = p.x - o.x, p.z - o.z
		local inside = lx >= 0 and lx <= S and lz >= 0.6 and lz <= S
		if not r.start and not r.done and inside then
			r.start = core.get_us_time()
			r.hud = player:hud_add({
				type = "text", position = {x = 0.5, y = 0.06}, alignment = {x = 0, y = 0},
				text = "Time: 0:00", number = 0xFFD028, size = {x = 2, y = 2},
			})
			core.sound_play("kids_maze_glocke", {to_player = name, gain = 0.6})
			core.chat_send_player(name, "Here we go! The clock is running. Find the golden tower!")
		elseif r.start and not r.done then
			if lx >= P1 and lx <= P2 + 1 and lz >= P1 and lz <= P2 + 1 then
				finish(player, r)
			elseif r.hud then
				player:hud_change(r.hud, "text",
					"Time: " .. fmt(math.floor((core.get_us_time() - r.start) / 1e6)))
			end
		end
	end
end)

core.register_chatcommand("maze", {
	params = "start | new | rebuild | best | map",
	description = "Maze: back to the gate, new maze, best time (fallback - the Golden Compass does all of this)",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if param == "new" then
			local seed = math.random(1, 2000000000)
			emerge_and_build(seed, function()
				storage:set_int("best", 0)
				for _, pl in ipairs(core.get_connected_players()) do to_start(pl) end
				core.chat_send_all("A brand-new maze is ready! Good luck!")
			end)
			return true, "Building a new maze ..."
		elseif param == "rebuild" then
			if not core.check_player_privs(name, {server = true}) then
				return false, "Parents only."
			end
			emerge_and_build(storage:get_int("seed"), function()
				for _, pl in ipairs(core.get_connected_players()) do to_start(pl) end
				core.chat_send_all("The maze was rebuilt: towers, animals and surprises!")
			end)
			return true, "Rebuilding the maze with the same layout ..."
		elseif param == "map" and player then
			if not core.check_player_privs(name, {server = true}) then
				return false, "The map is for parents only."
			end
			overview(player)
			return true, "View from above. /maze takes you back to the gate."
		elseif param == "best" then
			local best = storage:get_int("best")
			return true, best > 0 and ("Best time: " .. fmt(best)) or "No best time yet."
		elseif player then
			to_start(player)
			return true, "Back to the gate. The clock starts at the gate."
		end
		return false
	end,
})

core.after(1, function()
	if not origin() then
		emerge_and_build(storage:get_int("seed") ~= 0 and storage:get_int("seed") or 2111)
	elseif storage:get_int("ver") ~= VERSION then
		-- aelteres, kleineres Labyrinth: schwereres neu bauen
		emerge_and_build(math.random(1, 2000000000), function()
			storage:set_int("best", 0)
			for _, pl in ipairs(core.get_connected_players()) do to_start(pl) end
			core.chat_send_all("The maze is new and easier, no water! Good luck!")
		end)
	end
end)

core.register_on_joinplayer(function(player)
	core.after(3, function()
		if player:is_player() and origin() then
			to_start(player)
			local inv = player:get_inventory()
			if inv and not inv:contains_item("main", M .. "kompass") then
				inv:add_item("main", M .. "kompass")
			end
			core.chat_send_player(player:get_player_name(),
				"Welcome to Kids Maze! Find the treasure under the golden tower. "
				.. "Everything is on your Golden Compass - right-click it!")
		end
	end)
end)

core.register_on_leaveplayer(function(player)
	runs[player:get_player_name()] = nil
end)

-- Draufhauen wirkt wie Rechtsklick (Kinder hauen gern drauf)
for _, n in ipairs({"schatzkiste", "wundertruhe", "futterkiste", "raetseltor"}) do
	local def = core.registered_nodes[M .. n]
	if def and def.on_rightclick then
		core.override_item(M .. n, {
			on_punch = function(pos, node, puncher)
				def.on_rightclick(pos, node, puncher)
			end,
		})
	end
end

-- Fuettern: eigene, robuste Behandlung. Futter pro Tierart, immer eine sichtbare Rueckmeldung.
local FOOD = {
	["animalia:chicken"] = {"farming:seed_wheat", "farming:seed_cotton"},
	["animalia:pig"] = {"farming:carrot", "farming:potato"},
	["animalia:sheep"] = {"farming:wheat"},
	["animalia:cow"] = {"farming:wheat"},
	["animalia:cat"] = {"animalia:poultry_raw", "animalia:poultry_cooked"},
}
local FOOD_NAME = {
	["animalia:chicken"] = "seeds", ["animalia:pig"] = "carrots", ["animalia:sheep"] = "wheat",
	["animalia:cow"] = "wheat", ["animalia:cat"] = "raw chicken",
}
local feed_flag = false

-- Fuettern: freundliche Rueckmeldung und Belohnung nach 3 Tieren
local fed = {}
local ANIMAL_NAME = {}
for _, a in ipairs(ANIMALS) do ANIMAL_NAME[a[1]] = a[2]:sub(1, 1) .. a[2]:sub(2):lower() end
if rawget(_G, "animalia") and animalia.feed then
	local orig_feed = animalia.feed
	animalia.feed = function(self, clicker, ...)
		local ok = orig_feed(self, clicker, ...)
		if ok then feed_flag = true end
		if ok and clicker and clicker:is_player() then
			local pname = clicker:get_player_name()
			local label = ANIMAL_NAME[self.name] or "Tier"
			big_msg(clicker, label .. " is munching!", 0x80FF80)
			local f = fed[pname] or {n = 0}
			fed[pname] = f
			f.n = f.n + 1
			if f.n == 3 then
				clicker:get_inventory():add_item("main", "default:diamond 2")
				confetti(self.object:get_pos())
				core.chat_send_player(pname, "ANIMAL FRIEND! You fed an animal 3 times - here are 2 diamonds!")
				big_msg(clicker, "ANIMAL FRIEND! 2 diamonds!")
			end
		end
		return ok
	end
end

-- Rechtsklick auf ein Tier: klappt das normale Fuettern nicht, uebernehmen wir es selbst
-- oder sagen dem Kind, was das Tier mag.
core.register_on_mods_loaded(function()
	for name, foods in pairs(FOOD) do
		local def = core.registered_entities[name]
		if def and def.on_rightclick then
			local orig = def.on_rightclick
			def.on_rightclick = function(self, clicker, ...)
				if not (clicker and clicker:is_player()) then return orig(self, clicker, ...) end
				feed_flag = false
				orig(self, clicker, ...)
				if feed_flag then return end
				local stack = clicker:get_wielded_item()
				local item = stack:get_name()
				local label = ANIMAL_NAME[name] or "Tier"
				local ok = false
				for _, f in ipairs(foods) do if f == item then ok = true end end
				if ok then
					if not core.is_creative_enabled(clicker:get_player_name()) then
						stack:take_item(1)
						clicker:set_wielded_item(stack)
					end
					-- wie normales Fuettern zaehlen
					local pname = clicker:get_player_name()
					big_msg(clicker, label .. " is munching!", 0x80FF80)
					local f = fed[pname] or {n = 0}
					fed[pname] = f
					f.n = f.n + 1
					confetti(self.object:get_pos())
					if f.n == 3 then
						clicker:get_inventory():add_item("main", "default:diamond 2")
						core.chat_send_player(pname, "ANIMAL FRIEND! You fed an animal 3 times - here are 2 diamonds!")
						big_msg(clicker, "ANIMAL FRIEND! 2 diamonds!")
					end
				else
					say(clicker, label, "I'm hungry! I like " .. (FOOD_NAME[name] or "food") .. ".\n\n"
						.. "Grab feed at the green feed box at the gate, pick it in your hotbar, "
						.. "then right-click me.")
				end
			end
		end
	end
end)
