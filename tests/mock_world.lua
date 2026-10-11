-- A tiny fake of the pieces of Balatro + Steamodded + the Multiplayer mod that BotArena touches.
-- Each BotArena instance under test gets its own Lua runtime that loads this file, so globals do not leak.
-- Network traffic goes through __send(json) (Python server simulation) and comes back via mock_deliver(json).

-- ---------------------------------------------------------------------------------------------
-- tiny JSON (tests only; the real game provides its own `json` module)
-- ---------------------------------------------------------------------------------------------
local json = {}
local function esc(s)
	return (s:gsub('[%c"\\]', function(c)
		local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
		return m[c] or string.format("\\u%04x", c:byte())
	end))
end
local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		n = n + 1
	end
	return n == #t
end
function json.encode(v)
	local tv = type(v)
	if tv == "nil" then return "null"
	elseif tv == "boolean" then return tostring(v)
	elseif tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%.0f", v) end
		return tostring(v)
	elseif tv == "string" then return '"' .. esc(v) .. '"'
	elseif tv == "table" then
		local out = {}
		if is_array(v) and next(v) ~= nil then
			for i = 1, #v do out[#out + 1] = json.encode(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local val = v[k]
			if val == nil then val = v[tonumber(k)] end
			out[#out + 1] = '"' .. esc(k) .. '":' .. json.encode(val)
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	error("cannot encode " .. tv)
end
function json.decode(s)
	local pos = 1
	local function ws() pos = s:find("%S", pos) or #s + 1 end
	local value
	local function str()
		local out = {}
		pos = pos + 1
		while true do
			local c = s:sub(pos, pos)
			if c == "" then error("unterminated string") end
			if c == '"' then pos = pos + 1; break end
			if c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				local m = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if n == "u" then
					out[#out + 1] = string.char(tonumber(s:sub(pos + 2, pos + 5), 16) % 256)
					pos = pos + 6
				else
					out[#out + 1] = m[n] or n
					pos = pos + 2
				end
			else
				out[#out + 1] = c
				pos = pos + 1
			end
		end
		return table.concat(out)
	end
	function value()
		ws()
		local c = s:sub(pos, pos)
		if c == "{" then
			local t = {}
			pos = pos + 1
			ws()
			if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
			while true do
				ws()
				local k = str()
				ws()
				assert(s:sub(pos, pos) == ":", "expected :")
				pos = pos + 1
				t[k] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "}" then break end
				assert(d == ",", "expected , in object")
			end
			return t
		elseif c == "[" then
			local t = {}
			pos = pos + 1
			ws()
			if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
			while true do
				t[#t + 1] = value()
				ws()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "]" then break end
				assert(d == ",", "expected , in array")
			end
			return t
		elseif c == '"' then return str()
		elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
		elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
		elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
			assert(num and #num > 0, "bad json at " .. pos)
			pos = pos + #num
			return tonumber(num)
		end
	end
	local v = value()
	return v
end
package.loaded["json"] = json
_G.json = json

-- ---------------------------------------------------------------------------------------------
-- engine fakes
-- ---------------------------------------------------------------------------------------------
MOCK = { clock = 0, quit = false, log = {}, sent = {}, actions = {} }

function sendInfoMessage(m, c) MOCK.log[#MOCK.log + 1] = "I " .. tostring(m) end
function sendWarnMessage(m, c) MOCK.log[#MOCK.log + 1] = "W " .. tostring(m) end
function sendErrorMessage(m, c) MOCK.log[#MOCK.log + 1] = "E " .. tostring(m) end
function sendDebugMessage(m, c) end

love = {
	timer = { getTime = function() return MOCK.clock end, getFPS = function() return 60 end },
	filesystem = { getSaveDirectory = function() return MOCK.save_dir or "/tmp/BalatroArena_test/save" end },
	window = {
		updateMode = function(w, h, s) MOCK.window = { w = w, h = h, s = s } end,
		setPosition = function() end,
		setVSync = function() end,
	},
	event = { quit = function(code) MOCK.quit = true; MOCK.quit_code = code or 0 end },
	draw = function() end,
}

NFS = {
	getInfo = function(p) return __fs_info(p) end,
	read = function(p) return __fs_read(p) end,
	write = function(p, d) return __fs_write(p, d, false) end,
	append = function(p, d) return __fs_write(p, d, true) end,
	remove = function(p) return __fs_remove(p) end,
	createDirectory = function(p) return __fs_mkdir(p) end,
}

SMODS = {
	Mods = { Multiplayer = { config = { username = "Guest" } }, BotArena = {} },
	current_mod = { id = "BotArena", version = "0.1.0", path = "" },
}
function SMODS.load_file(rel, id)
	local path = MOCK.mod_path .. "/" .. rel
	local data = __fs_read(path)
	if not data then return nil, "missing " .. path end
	return loadstring(data, "=" .. rel)
end

-- ---------------------------------------------------------------------------------------------
-- game state fakes
-- ---------------------------------------------------------------------------------------------
-- decks and stakes (rules mirrored from vanilla + the Multiplayer mod's Spectral+ stake; only what lib/rules.lua / the bots read)
local P_CENTERS_BACKS = {
	b_red = { key = "b_red", name = "Red Deck", set = "Back" },
	b_blue = { key = "b_blue", name = "Blue Deck", set = "Back" },
	b_yellow = { key = "b_yellow", name = "Yellow Deck", set = "Back" },
	b_green = { key = "b_green", name = "Green Deck", set = "Back" },
	b_black = { key = "b_black", name = "Black Deck", set = "Back" },
	b_magic = { key = "b_magic", name = "Magic Deck", set = "Back" },
	b_nebula = { key = "b_nebula", name = "Nebula Deck", set = "Back" },
	b_ghost = { key = "b_ghost", name = "Ghost Deck", set = "Back" },
	b_abandoned = { key = "b_abandoned", name = "Abandoned Deck", set = "Back" },
	b_checkered = { key = "b_checkered", name = "Checkered Deck", set = "Back" },
	b_zodiac = { key = "b_zodiac", name = "Zodiac Deck", set = "Back" },
	b_painted = { key = "b_painted", name = "Painted Deck", set = "Back" },
	b_anaglyph = { key = "b_anaglyph", name = "Anaglyph Deck", set = "Back" },
	b_plasma = { key = "b_plasma", name = "Plasma Deck", set = "Back" },
	b_erratic = { key = "b_erratic", name = "Erratic Deck", set = "Back" },
	b_mp_cocktail = { key = "b_mp_cocktail", name = "Cocktail Deck", set = "Back" },
}
local STAKE_KEYS = { "stake_white", "stake_red", "stake_green", "stake_black", "stake_blue", "stake_purple", "stake_orange", "stake_gold",
	"stake_mp_planet", "stake_mp_spectral", "stake_mp_spectralplus" }
local P_STAKES, STAKE_POOL = {}, {}
for i, k in ipairs(STAKE_KEYS) do
	P_STAKES[k] = { key = k, order = i }
	STAKE_POOL[i] = P_STAKES[k]
end
-- G.GAME.modifiers for a stake index (the same chain SMODS.setup_stake applies)
function MOCK.stake_modifiers(i)
	local m = {}
	if i >= 11 then
		m.no_blind_reward = { Small = true }
		m.scaling = 5
		m.enable_eternals_in_shop, m.enable_perishables_in_shop, m.enable_rentals_in_shop = true, true, true
		return m
	end
	if i >= 2 then m.no_blind_reward = { Small = true } end
	if i >= 3 then m.scaling = 2 end
	if i >= 4 then m.enable_eternals_in_shop = true end
	if i >= 6 then m.scaling = 3 end
	if i >= 7 then m.enable_perishables_in_shop = true end
	if i >= 8 then m.enable_rentals_in_shop = true end
	return m
end
function MOCK.apply_loadout()
	local cfg = MP.LOBBY.config
	local center
	for _, c in pairs(P_CENTERS_BACKS) do if c.name == cfg.back then center = c end end
	center = center or P_CENTERS_BACKS.b_red
	local stake = tonumber(cfg.stake) or 1
	G.GAME.stake = stake
	G.GAME.modifiers = MOCK.stake_modifiers(stake)
	G.GAME.rental_rate, G.GAME.perishable_rounds = 3, 5
	G.GAME.selected_back = { name = center.name, effect = { center = center } }
	if center.name == "Green Deck" then
		G.GAME.modifiers.no_interest, G.GAME.modifiers.money_per_hand, G.GAME.modifiers.money_per_discard = true, 2, 1
	end
end

G = {
	STAGES = { MAIN_MENU = 1, RUN = 2, SANDBOX = 3 },
	STATES = {
		SMODS_BOOSTER_OPENED = 999, SELECTING_HAND = 1, HAND_PLAYED = 2, DRAW_TO_HAND = 3, GAME_OVER = 4,
		SHOP = 5, PLAY_TAROT = 6, BLIND_SELECT = 7, ROUND_EVAL = 8, TAROT_PACK = 9, PLANET_PACK = 10,
		MENU = 11, TUTORIAL = 12, SPLASH = 13, SANDBOX = 14, SPECTRAL_PACK = 15, DEMO_CTA = 16,
		STANDARD_PACK = 17, BUFFOON_PACK = 18, NEW_ROUND = 19,
	},
	SETTINGS = { paused = false, SOUND = { volume = 50 }, GAMESPEED = 1 },
	FUNCS = {},
	E_MANAGER = { queues = { base = {} }, update = function(self, dt, forced) MOCK.eq_updates = (MOCK.eq_updates or 0) + 1 end },
	CONTROLLER = { locked = false, locks = {} },
	I = { UIBOX = {} },
	STATE_COMPLETE = true,
	TIMERS = { REAL = 0, TOTAL = 0 },
	VIBRATION = 0,
	ROOM = { jiggle = 0 },
}
G.P_CENTERS, G.P_STAKES, G.P_CENTER_POOLS = P_CENTERS_BACKS, P_STAKES, { Stake = STAKE_POOL }
G.STAGE = G.STAGES.MAIN_MENU
G.STATE = G.STATES.SPLASH

Game = {}
function Game:update(dt)
	MOCK.frames = (MOCK.frames or 0) + 1
	if G.STATE == G.STATES.SPLASH and MOCK.frames > 20 then
		G.STATE = G.STATES.MENU
		G.MAIN_MENU_UI = MOCK.make_ui({ lobby_menu_start = { button = "lobby_ready_up" } })
	end
	if MOCK.game_update then MOCK.game_update() end
end

-- UI node fake. Mirrors the parts of UIBox / UIElement the mod relies on:
--   box:get_UIE_by_ID(id)   recursive search through box.UIRoot.children (what the real UIBox does)
--   node:click()            what a mouse click calls: honours one_press (disable_button) and runs G.FUNCS[button](node)
local function ui_click(self)
	if self.config.button and (not self.last_clicked or self.last_clicked + 0.1 < MOCK.clock) and self.states.visible
		and not self.disable_button then
		if self.config.one_press then self.disable_button = true end
		self.last_clicked = MOCK.clock
		MOCK.clicks = (MOCK.clicks or 0) + 1
		G.FUNCS[self.config.button](self)
		self.button_clicked = true
	end
end

function MOCK.make_ui(ids, opts)
	opts = opts or {}
	local ui = { children = {}, config = {} }
	ui.UIRoot = { config = {}, children = {}, UIBox = ui }
	function ui:get_UIE_by_ID(id, node)
		node = node or self.UIRoot
		if node.config and node.config.id == id then return node end
		for _, child in pairs(node.children) do
			local r = self:get_UIE_by_ID(id, child)
			if r then return r end
		end
		return nil
	end
	ui.by_id = {}
	for id, cfg in pairs(ids or {}) do
		local node = { config = { id = id, button = cfg.button, one_press = cfg.one_press }, children = {}, UIBox = ui,
			states = { visible = true }, click = ui_click }
		ui.by_id[id] = node
		ui.children[#ui.children + 1] = node
		ui.UIRoot.children[#ui.UIRoot.children + 1] = node
	end
	if opts.register then G.I.UIBOX[#G.I.UIBOX + 1] = ui end
	return ui
end

function MOCK.remove_ui(ui)
	for i, b in ipairs(G.I.UIBOX) do
		if b == ui then table.remove(G.I.UIBOX, i) break end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Multiplayer mod fake
-- ---------------------------------------------------------------------------------------------
local function insane(n)
	n = tonumber(n) or 0
	if n == 0 then return { coeffiocient = 0, exponent = 0, e_count = 0 } end
	local ex = 0
	while n >= 1e6 do n = n / 10; ex = ex + 1 end -- keep coefficients modest like the real thing
	return { coeffiocient = n, exponent = ex, e_count = 0 }
end

local function new_enemy()
	return { lives = 4, hands = 4, score = insane(0), real_score = insane(0), highest_score = insane(0),
		info_received = false, skips = 0 }
end

MP = {
	LOBBY = {
		connected = false, code = nil, is_host = false, ready_to_start = false, username = "Guest",
		config = { ruleset = "ruleset_mp_blitz", gamemode = "gamemode_mp_attrition" },
		guest = {}, host = {},
	},
	GAME = { ready_blind = false, lives = 4, enemy = new_enemy(), highest_score = insane(0), pvp_reached_first = false },
	Rulesets = { ruleset_mp_standard_ranked = {}, ruleset_mp_blitz = {} },
	EXPERIMENTAL = {},
	STATS = { record_match = function(won) MOCK.recorded = (MOCK.recorded or 0) + 1 end },
	INSANE_INT = {
		from_string = function(str)
			local n = tonumber(str) or 0
			return insane(n)
		end,
		to_string = function(t)
			local v = (t.coeffiocient or 0) * 10 ^ (t.exponent or 0)
			return string.format("%.0f", v)
		end,
	},
	ACTIONS = {},
}
function MP.apply_default_modifiers() end
function MP.LoadReworks() end
function MP.is_pvp_boss()
	return G.GAME and G.GAME.blind and G.GAME.blind.pvp or false
end

local function send(msg)
	local s = json.encode(msg)
	MOCK.sent[#MOCK.sent + 1] = msg.action
	__send(s)
end
for _, name in ipairs({ "create_lobby", "join_lobby", "ready_lobby", "unready_lobby", "lobby_info", "leave_lobby",
	"start_game", "stop_game", "connect", "lobby_options", "unready_blind", "play_hand", "fail_round" }) do
	MP.ACTIONS[name] = function(...) send({ action = name, args = { ... } }) end
end
-- the real one sends the whole lobby config; the mock only carries the deck and stake
MP.ACTIONS.lobby_options = function() send({ action = "lobby_options", args = { MP.LOBBY.config.back, MP.LOBBY.config.stake } }) end
-- the real play_hand also records MP.GAME.score; keep that so reward/pvp code sees the same state
local play_hand_send = MP.ACTIONS.play_hand
function MP.ACTIONS.play_hand(score, hands_left)
	MP.GAME.score = insane(score)
	MOCK.hands_sent = (MOCK.hands_sent or 0) + 1
	MOCK.last_play = { score = score, hands_left = hands_left, clock = MOCK.clock }
	MOCK.plays = MOCK.plays or {}
	MOCK.plays[#MOCK.plays + 1] = { score = score, hands_left = hands_left, clock = MOCK.clock }
	play_hand_send(score, hands_left)
end
function MP.ACTIONS.set_username(n) MP.LOBBY.username = n; send({ action = "username", name = n }) end
function MP.ACTIONS.ready_blind(e)
	MP.GAME.next_blind_context = e
	send({ action = "ready_blind" })
end

function G.FUNCS.exit_overlay_menu()
	G.OVERLAY_MENU = nil
	G.SETTINGS.paused = false
end

function G.FUNCS.start_lobby(e)
	G.SETTINGS.paused = false
	MP.ACTIONS.create_lobby("attrition")
	G.FUNCS.exit_overlay_menu()
end

function G.FUNCS.lobby_ready_up(e)
	MP.LOBBY.ready_to_start = not MP.LOBBY.ready_to_start
	if MP.LOBBY.ready_to_start then MP.ACTIONS.ready_lobby() else MP.ACTIONS.unready_lobby() end
end

function G.FUNCS.go_to_menu()
	G.STAGE = G.STAGES.MAIN_MENU
	G.STATE = G.STATES.MENU
	G.GAME = nil
	G.hand = nil
	G.jokers = nil
	G.consumeables = nil
	G.round_eval = nil
	G.shop = nil
	G.pack_cards = nil
	G.blind_select_opts = nil
	G.I.UIBOX = {}
	MOCK.pending = nil
	MOCK.timers = {}
	G.E_MANAGER.queues.base = {}
	G.MAIN_MENU_UI = MOCK.make_ui({ lobby_menu_start = { button = "lobby_ready_up" } })
end

-- ---- cards / areas ---------------------------------------------------------------------------
CardArea = {}
CardArea.__index = CardArea
function CardArea:emplace(card)
	self.cards[#self.cards + 1] = card
	card.area = self
end
Card = {}
Card.__index = Card
function Card:sell_card()
	-- like the real one: the money arrives later, from an event, through ease_dollars
	local cost = self.sell_cost or 1
	local area = self.area
	if area then
		for i, c in ipairs(area.cards) do if c == self then table.remove(area.cards, i) break end end
	end
	MOCK.after(2, function() ease_dollars(cost) end)
end

function ease_dollars(mod, instant)
	G.GAME.dollars = G.GAME.dollars + (tonumber(mod) or 0)
end

local function new_card(rank, suit)
	return { base = { value = tostring(rank), id = rank, suit = suit, nominal = math.min(rank, 10) },
		ability = { set = "Default", bonus = 0 }, config = { center = { key = "c_base" } },
		get_chip_bonus = function(self) return self.base.nominal end, sort_id = math.random(1, 1e9), cost = 0 }
end

function MOCK.new_consumable(set)
	return setmetatable({ ability = { set = set, consumeable = true, extra_slots_used = 0 }, cost = 3, sell_cost = 1,
		config = { center = { key = "c_" .. string.lower(set) } }, sort_id = math.random(1, 1e9) }, Card)
end

-- run `fn` after `frames` mock frames (a non-blocking "event")
MOCK.timers = {}
function MOCK.after(frames, fn)
	MOCK.timers[#MOCK.timers + 1] = { frames = frames, fn = fn }
end

local function deal()
	G.hand.cards = {}
	for i = 1, 8 do G.hand.cards[i] = new_card(math.random(2, 14), ({ "Hearts", "Spades", "Clubs", "Diamonds" })[math.random(1, 4)]) end
	G.hand.highlighted = {}
	if MOCK.with_deck then
		-- a draw pile for the planner tests (opt-in so the older tests keep their exact behaviour)
		G.deck = { cards = {}, config = {} }
		for i = 1, 24 do G.deck.cards[i] = new_card(math.random(2, 14), ({ "Hearts", "Spades", "Clubs", "Diamonds" })[math.random(1, 4)]) end
	end
end

local function make_hand_area()
	local a = { cards = {}, highlighted = {}, config = { card_limit = 5, highlighted_limit = 5 } }
	function a:unhighlight_all() self.highlighted = {} end
	function a:add_to_highlighted(c) if #self.highlighted < 5 then self.highlighted[#self.highlighted + 1] = c end end
	return a
end

local function make_area(limit)
	return setmetatable({ cards = {}, config = { card_limit = limit } }, CardArea)
end

function G.FUNCS.get_poker_hand_info(cards)
	if #cards == 0 then return "NULL", "NULL", {}, {} end
	local ranks, text = {}, "High Card"
	for _, c in ipairs(cards) do ranks[c.base.id] = (ranks[c.base.id] or 0) + 1 end
	for _, n in pairs(ranks) do if n >= 2 then text = "Pair" end end
	return text, text, {}, { cards[1] }
end

local function blind_ui(deck)
	local ui = MOCK.make_ui({ select_blind_button = { button = "select_blind", one_press = true } })
	if deck ~= "Boss" then
		local skip = { config = { button = "skip_blind" }, children = {}, UIBox = ui, states = { visible = true }, click = nil }
		ui.children[#ui.children + 1] = skip
		ui.UIRoot.children[#ui.UIRoot.children + 1] = skip
	end
	return ui
end

local function enter_blind_select()
	G.STATE = G.STATES.BLIND_SELECT
	G.STATE_COMPLETE = true
	local g = G.GAME
	local order = { "Small", "Big", "Boss" }
	g.blind_on_deck = order[((g.round or 0) % 3) + 1]
	g.round_resets.blind_choices = { Small = "bl_small", Big = "bl_big", Boss = (g.round_resets.ante >= 2) and "bl_mp_nemesis" or "bl_hook" }
	g.round_resets.pvp_blind_choices = {}
	g.round_resets.blind_tags = { Small = "tag_investment", Big = "tag_double" } -- what a skip would give (real: round_resets.blind_tags)
	G.blind_select_opts = {}
	for _, d in ipairs(order) do G.blind_select_opts[d:lower()] = blind_ui(d) end
end

function G.FUNCS.lobby_start_run(e, args)
	G.STAGE = G.STAGES.RUN
	G.GAME = {
		round = 0, dollars = 4, chips = 0, bankrupt_at = 0, skips = 0,
		round_resets = { ante = 1, blind_choices = {}, pvp_blind_choices = {}, hands = 4 },
		current_round = { hands_left = 4, discards_left = 3, reroll_cost = 5, hands_played = 0, dollars = 0 },
		starting_params = { play_limit = 5, discard_limit = 5 },
		hands = { ["High Card"] = { chips = 5, mult = 1 }, Pair = { chips = 10, mult = 2 } },
		blind = { chips = 50, dollars = 3, config = { blind = { key = "bl_small" } } },
	}
	MOCK.apply_loadout()
	G.hand = make_hand_area()
	G.jokers = make_area(5)
	G.consumeables = make_area(2)
	G.I.UIBOX = {}
	if MOCK.rich_shop or MOCK.with_deck then
		-- full deck + hand levels, as the planner / decision layer read them
		G.playing_cards = {}
		for _, suit in ipairs({ "Hearts", "Spades", "Clubs", "Diamonds" }) do
			for rank = 2, 14 do G.playing_cards[#G.playing_cards + 1] = new_card(rank, suit) end
		end
		for name, h in pairs(G.GAME.hands) do h.level, h.l_chips, h.l_mult, h.played = 1, 15, 1, 0 end
	end
	MP.GAME = { ready_blind = false, lives = 4, enemy = new_enemy(), highest_score = insane(0), pvp_reached_first = false }
	MOCK.timers = {}
	enter_blind_select()
end

function G.FUNCS.mp_toggle_ready(e)
	MP.GAME.ready_blind = not MP.GAME.ready_blind
	if MP.GAME.ready_blind then MP.ACTIONS.ready_blind(e) else MP.ACTIONS.unready_blind() end
end

local function start_round(btn_blind_key, pvp)
	local g = G.GAME
	g.round = g.round + 1
	g.chips = 0
	g.current_round.hands_left = 4
	g.current_round.discards_left = 3
	g.current_round.hands_played = 0
	g.current_round.dollars = 0
	g.blind = { chips = pvp and 0 or (40 + 30 * g.round), dollars = pvp and 5 or 3, pvp = pvp, config = { blind = { key = btn_blind_key } } }
	G.blind_select_opts = nil
	G.STATE = G.STATES.SELECTING_HAND
	G.STATE_COMPLETE = true
	deal()
	if pvp then
		-- real MP: select_blind announces the starting hand count and a new round to the server
		MP.ACTIONS.play_hand(0, g.round_resets.hands)
	end
	-- optional scripted "joker" effects that fire when a blind is selected (Cartomancer-like)
	if MOCK.on_select then MOCK.on_select() end
end

function G.FUNCS.select_blind(e)
	local deck = G.GAME.blind_on_deck
	local key = G.GAME.round_resets.blind_choices[deck]
	start_round(key, key == "bl_mp_nemesis")
end

function G.FUNCS.skip_blind(e)
	G.GAME.skips = G.GAME.skips + 1
	G.GAME.round = G.GAME.round + 1
	enter_blind_select()
end

function G.FUNCS.can_play(e)
	if #G.hand.highlighted > 0 and G.GAME.current_round.hands_left > 0 then e.config.button = "play_cards_from_highlighted" else e.config.button = nil end
end
function G.FUNCS.can_discard(e)
	if #G.hand.highlighted > 0 and G.GAME.current_round.discards_left > 0 then e.config.button = "discard_cards_from_highlighted" else e.config.button = nil end
end

local function remove_highlighted()
	local keep = {}
	local set = {}
	for _, c in ipairs(G.hand.highlighted) do set[c] = true end
	for _, c in ipairs(G.hand.cards) do if not set[c] then keep[#keep + 1] = c end end
	G.hand.cards = keep
end

function G.FUNCS.discard_cards_from_highlighted(e)
	G.GAME.current_round.discards_left = G.GAME.current_round.discards_left - 1
	remove_highlighted()
	while #G.hand.cards < 8 do G.hand.cards[#G.hand.cards + 1] = new_card(math.random(2, 14), "Hearts") end
	G.hand.highlighted = {}
end

-- ---- round evaluation, as in the real game -------------------------------------------------------
-- evaluate_round adds payout rows through the GLOBAL add_round_eval_row; the "bottom" row creates the
-- Cash Out button as its OWN UIBox (not a child of G.round_eval) and records the total.
function add_round_eval_row(config)
	MOCK.rows = MOCK.rows or {}
	MOCK.rows[#MOCK.rows + 1] = { name = config.name, dollars = config.dollars }
	if config.name == "bottom" then
		G.GAME.current_round.dollars = config.dollars
		if MOCK.no_button then return end
		local btn = MOCK.make_ui({ cash_out_button = { button = "cash_out", one_press = true } }, { register = true })
		G.cash_out_ui = btn
	end
end

local function evaluate_round()
	local g = G.GAME
	MOCK.rows = {}
	local total = 0
	local function row(name, dollars)
		add_round_eval_row({ name = name, dollars = dollars, bonus = name ~= "blind1" })
		total = total + dollars
	end
	row("blind1", g.blind.dollars or 0)
	if g.current_round.hands_left > 0 and not MP.is_pvp_boss() then row("hands", g.current_round.hands_left) end
	if MOCK.eor_money and MOCK.eor_money > 0 then row("joker1", MOCK.eor_money) end
	if g.dollars >= 5 then row("interest", math.min(math.floor(g.dollars / 5), 5)) end
	if MOCK.comeback then row("comeback", MOCK.comeback) end
	add_round_eval_row({ name = "bottom", dollars = total })
end

local function enter_round_eval()
	G.STATE = G.STATES.ROUND_EVAL
	G.STATE_COMPLETE = false
	G.round_eval = MOCK.make_ui({})
	-- rows + button appear a few frames later; until then a blocking event is queued (so the bot must not act)
	G.E_MANAGER.queues.base = { { blocking = true } }
	MOCK.after(4, function()
		if not G.GAME or not G.round_eval then return end -- run torn down meanwhile
		evaluate_round()
		if MOCK.eval_stuck then
			-- regression: a blocking event that stays in the queue long after the cash-out button exists
			G.E_MANAGER.queues.base = { { blocking = true, trigger = "after", delay = 99 } }
			MOCK.eval_button_frame = MOCK.frame or 0
			MOCK.after(MOCK.eval_stuck, function() G.E_MANAGER.queues.base = {} end)
		else
			G.E_MANAGER.queues.base = {}
		end
		G.STATE_COMPLETE = true
	end)
end
MOCK.enter_round_eval = enter_round_eval

function G.FUNCS.play_cards_from_highlighted(e)
	local total = 0
	for _, c in ipairs(G.hand.highlighted) do total = total + c.base.nominal * 3 end
	if MOCK.score_override then total = MOCK.score_override(total) end
	G.GAME.chips = G.GAME.chips + total
	G.GAME.current_round.hands_left = G.GAME.current_round.hands_left - 1
	G.GAME.current_round.hands_played = G.GAME.current_round.hands_played + 1
	remove_highlighted()
	G.hand.highlighted = {}
	MOCK.hands_played_total = (MOCK.hands_played_total or 0) + 1
	-- scripted per-hand "joker" effects
	if MOCK.hand_money and MOCK.hand_money > 0 then ease_dollars(MOCK.hand_money) end
	if MOCK.hand_tarot then G.consumeables:emplace(MOCK.new_consumable("Tarot")) end
	if MOCK.hand_spectral then G.consumeables:emplace(MOCK.new_consumable("Spectral")) end
	local end_seq = MOCK.pvp_end_seq or 0
	if G.GAME.blind.pvp then MP.ACTIONS.play_hand(G.GAME.chips, G.GAME.current_round.hands_left) end
	if (MOCK.pvp_end_seq or 0) == end_seq then
		G.STATE = G.STATES.HAND_PLAYED
		G.STATE_COMPLETE = true
	end
	-- "animation": a blocking event that resolves after a few frames
	MOCK.pending = { frames = 3, fn = function()
		if not G.GAME or not G.GAME.blind then return end -- the run was torn down meanwhile (stopGame)
		local pvp = G.GAME.blind.pvp
		if pvp and (MOCK.pvp_end_seq or 0) ~= end_seq then return end -- the server already ended this PvP
		if pvp then
			if G.GAME.current_round.hands_left <= 0 then
				-- wait for the server's endPvP / game result; the mock server drives the next step
				G.STATE = G.STATES.SELECTING_HAND
				G.GAME.waiting_pvp = true
				G.hand.cards = {}
			else
				G.STATE = G.STATES.SELECTING_HAND
				if #G.hand.cards < 8 then deal() end
			end
			return
		end
		local beaten = G.GAME.chips >= G.GAME.blind.chips
		if beaten or G.GAME.current_round.hands_left <= 0 then
			if not beaten then
				-- Multiplayer: a failed blind is turned into a "win" for the game (chips target -1) and the server
				-- is told through fail_round, which costs a life
				G.GAME.blind.chips = -1
				MP.ACTIONS.fail_round(G.GAME.current_round.hands_played)
			end
			enter_round_eval()
		else
			G.STATE = G.STATES.SELECTING_HAND
			if #G.hand.cards < 8 then deal() end
		end
	end }
end

function G.FUNCS.cash_out(e)
	MOCK.cash_outs = (MOCK.cash_outs or 0) + 1
	if not G.round_eval then return end
	e.config.button = nil
	local payout = G.GAME.current_round.dollars or 0
	G.round_eval = nil
	-- The REAL game never removes the old Cash Out UIBox (it only slides off with G.round_eval): the used box, whose
	-- button is nil, stays in G.I.UIBOX forever and sits BEFORE every newer one. (MOCK.tidy_cash_boxes = true restores the old, unrealistic mock.)
	if G.cash_out_ui and MOCK.tidy_cash_boxes then MOCK.remove_ui(G.cash_out_ui) end
	G.cash_out_ui = nil
	ease_dollars(payout)
	G.GAME.chips = 0
	G.STATE = G.STATES.SHOP
	G.STATE_COMPLETE = true
	G.shop = MOCK.make_ui({ next_round_button = { button = "toggle_shop", one_press = true } })
	G.shop.by_id.next_round_button.config.button = "toggle_shop"
	local j = { ability = { set = "Joker", extra_slots_used = 0, card_limit = 0 }, config = { center = { key = "j_joker", rarity = 1 } },
		cost = 2, sort_id = 777 + G.GAME.round, edition = nil }
	G.shop_jokers = { cards = { j } }
	G.shop_booster = { cards = {} }
	G.shop_vouchers = { cards = {} }
	if MOCK.rich_shop then MOCK.fill_rich_shop() end
end


-- ---- rich shop (opt-in: MOCK.rich_shop = true) ---------------------------------------------------
-- several jokers, a planet, a voucher, a booster pack, rerolls, selling, packs with picks - what lib/decide.lua enumerates
local JOKER_DEFS = {
	{ name = "Joker", key = "j_joker", cost = 2, rarity = 1, ab = { mult = 4 } },
	{ name = "Greedy Joker", key = "j_greedy_joker", cost = 5, rarity = 1, ab = { mult = 3 } },
	{ name = "Banner", key = "j_banner", cost = 5, rarity = 1, ab = { chips = 30 } },
	{ name = "Egg", key = "j_egg", cost = 4, rarity = 1, ab = {} },
	{ name = "Cavendish", key = "j_cavendish", cost = 4, rarity = 1, ab = { x_mult = 3 } },
	{ name = "Golden Joker", key = "j_golden", cost = 6, rarity = 1, ab = {} },
}
function MOCK.new_joker(def)
	def = def or JOKER_DEFS[math.random(1, #JOKER_DEFS)]
	local ab = { set = "Joker", name = def.name, extra_slots_used = 0, card_limit = 0 }
	for k, v in pairs(def.ab or {}) do ab[k] = v end
	local c = setmetatable({ ability = ab, config = { center = { key = def.key, rarity = def.rarity, name = def.name } },
		cost = def.cost, sell_cost = math.max(1, math.floor(def.cost / 2)), sort_id = math.random(1, 1e9) }, Card)
	return c
end
function MOCK.new_planet(hand)
	local c = MOCK.new_consumable("Planet")
	c.ability.hand_type = hand or "Pair"
	c.config.center.key = "c_" .. string.lower((hand or "Pair"):gsub(" ", "_"))
	return c
end
function Card:can_sell_card() return not (self.ability and self.ability.eternal) end
function Card:can_use_consumeable()
	if self.needs_targets then return false end
	return true
end

local function mock_level_up(hand)
	local h = G.GAME.hands[hand]
	if not h then return end
	h.level = (h.level or 1) + 1
	h.chips = h.chips + (h.l_chips or 15)
	h.mult = h.mult + (h.l_mult or 1)
end

function MOCK.fill_rich_shop()
	G.shop_jokers.cards = {}
	for i = 1, 3 do G.shop_jokers.cards[i] = MOCK.new_joker() end
	G.shop_jokers.cards[4] = MOCK.new_planet(math.random() < 0.5 and "Pair" or "High Card")
	G.shop_vouchers.cards = { setmetatable({ ability = { set = "Voucher" }, config = { center = { key = "v_overstock_norm" } }, cost = 10, sell_cost = 5, sort_id = 1 }, Card) }
	G.shop_booster.cards = { setmetatable({ ability = { set = "Booster" }, config = { center = { key = "p_celestial_normal_1" } }, cost = 4, sell_cost = 2, sort_id = 2 }, Card) }
	G.shop_vouchers.cards[1].area, G.shop_booster.cards[1].area = G.shop_vouchers, G.shop_booster
	for _, c in ipairs(G.shop_jokers.cards) do c.area = G.shop_jokers end
end

local function close_pack()
	G.pack_cards = { REMOVED = true }
	G.GAME.pack_choices = 0
	G.STATE = G.STATES.SHOP
	G.STATE_COMPLETE = true
end

local function open_pack(card)
	MOCK.packs_opened = (MOCK.packs_opened or 0) + 1
	G.GAME.dollars = G.GAME.dollars - card.cost
	for i, x in ipairs(G.shop_booster.cards) do if x == card then table.remove(G.shop_booster.cards, i) break end end
	G.STATE = G.STATES.PLANET_PACK
	G.pack_cards = make_area(3)
	G.pack_cards:emplace(MOCK.new_planet("Pair"))
	G.pack_cards:emplace(MOCK.new_planet("High Card"))
	if MOCK.pack_joker then G.pack_cards:emplace(MOCK.new_joker()) end
	if MOCK.pack_tarot_target then
		local t = MOCK.new_consumable("Tarot"); t.needs_targets = true; G.pack_cards:emplace(t)
	end
	G.GAME.pack_choices = MOCK.pack_choices or 1
	G.STATE_COMPLETE = true
end

function G.FUNCS.can_select_card(e)
	local c = e.config.ref_table
	if MOCK.fail_pick then e.config.button = nil; return end
	if c.ability.set ~= "Joker" or #G.jokers.cards < G.jokers.config.card_limit then e.config.button = "use_card" else e.config.button = nil end
end

function G.FUNCS.skip_booster(e)
	MOCK.packs_skipped = (MOCK.packs_skipped or 0) + 1
	close_pack()
end

function G.FUNCS.sell_card(e)
	MOCK.sold = (MOCK.sold or 0) + 1
	e.config.ref_table:sell_card()
end

function G.FUNCS.reroll_shop(e)
	MOCK.rerolls = (MOCK.rerolls or 0) + 1
	local cost = G.GAME.current_round.reroll_cost
	G.GAME.dollars = G.GAME.dollars - cost
	G.GAME.current_round.reroll_cost = cost + 1
	local keep = {}
	for _, c in ipairs(G.shop_jokers.cards) do if c.ability.set ~= "Joker" then keep[#keep + 1] = c end end
	G.shop_jokers.cards = keep
	for i = 1, 2 do local j = MOCK.new_joker(); j.area = G.shop_jokers; table.insert(G.shop_jokers.cards, 1, j) end
end

function G.FUNCS.use_card(e)
	local c = e.config.ref_table
	MOCK.use_calls = (MOCK.use_calls or 0) + 1
	if c.area == G.shop_booster then return open_pack(c) end
	if c.area == G.shop_vouchers then
		G.GAME.dollars = G.GAME.dollars - c.cost
		for i, x in ipairs(G.shop_vouchers.cards) do if x == c then table.remove(G.shop_vouchers.cards, i) break end end
		MOCK.vouchers = (MOCK.vouchers or 0) + 1
		return
	end
	if G.pack_cards and not G.pack_cards.REMOVED and c.area == G.pack_cards then
		for i, x in ipairs(G.pack_cards.cards) do if x == c then table.remove(G.pack_cards.cards, i) break end end
		if c.ability.set == "Planet" then mock_level_up(c.ability.hand_type)
		elseif c.ability.set == "Joker" then G.jokers.cards[#G.jokers.cards + 1] = c; c.area = G.jokers end
		MOCK.picks = (MOCK.picks or 0) + 1
		G.GAME.pack_choices = G.GAME.pack_choices - 1
		if G.GAME.pack_choices <= 0 then close_pack() end
		return
	end
	if c.area == G.consumeables then
		for i, x in ipairs(G.consumeables.cards) do if x == c then table.remove(G.consumeables.cards, i) break end end
		if c.ability.set == "Planet" then mock_level_up(c.ability.hand_type) end
		MOCK.cons_used = (MOCK.cons_used or 0) + 1
	end
end

function G.FUNCS.toggle_shop(e)
	G.shop = nil
	G.shop_jokers, G.shop_booster, G.shop_vouchers = nil, nil, nil
	-- regression: a leftover (removed) booster-pack area, as seen in a real run: .cards is nil, REMOVED is set
	if MOCK.stale_pack then G.pack_cards = { REMOVED = true } end
	-- advance: after every third blind the ante goes up
	if G.GAME.round % 3 == 0 then G.GAME.round_resets.ante = G.GAME.round_resets.ante + 1 end
	enter_blind_select()
end

function G.FUNCS.can_buy(e) end
function G.FUNCS.can_reroll(e)
	if MOCK.rich_shop and G.GAME.dollars >= G.GAME.current_round.reroll_cost then e.config.button = "reroll_shop" else e.config.button = nil end
end
function G.FUNCS.buy_from_shop(e)
	local c = e.config.ref_table
	G.GAME.dollars = G.GAME.dollars - c.cost
	MOCK.bought = (MOCK.bought or 0) + 1
	if c.ability.set == "Planet" or c.ability.consumeable then
		G.consumeables.cards[#G.consumeables.cards + 1] = c; c.area = G.consumeables
	else
		G.jokers.cards[#G.jokers.cards + 1] = c; c.area = G.jokers
	end
	for i, x in ipairs(G.shop_jokers.cards) do if x == c then table.remove(G.shop_jokers.cards, i) break end end
end

-- the real MP hook: pvp ready/start arrives from the server as a message
function MOCK.begin_pvp_blind()
	local e = MP.GAME.next_blind_context
	MP.GAME.ready_blind = false
	G.FUNCS.select_blind(e)
end

-- Frame driver used by the Python tests --------------------------------------------------------
function mock_frame(dt)
	MOCK.clock = MOCK.clock + dt
	if MOCK.pending then
		MOCK.pending.frames = MOCK.pending.frames - 1
		G.STATE_COMPLETE = false
		if MOCK.pending.frames <= 0 then
			local fn = MOCK.pending.fn
			MOCK.pending = nil
			G.STATE_COMPLETE = true -- fn may flip it again (e.g. entering ROUND_EVAL)
			fn()
		end
	end
	if #MOCK.timers > 0 then
		local keep, due = {}, {}
		for _, t in ipairs(MOCK.timers) do
			t.frames = t.frames - 1
			if t.frames <= 0 then due[#due + 1] = t else keep[#keep + 1] = t end
		end
		MOCK.timers = keep
		for _, t in ipairs(due) do t.fn() end
	end
	Game:update(dt)
end

-- Messages from the server simulation ----------------------------------------------------------
function mock_deliver(s)
	local p = json.decode(s)
	local a = p.action
	if a == "connected" then
		MP.LOBBY.connected = true
	elseif a == "joinedLobby" then
		MP.LOBBY.code = p.code
		MP.LOBBY.ready_to_start = false
	elseif a == "lobbyInfo" then
		MP.LOBBY.is_host = p.isHost
		MP.LOBBY.host = { username = p.host }
		MP.LOBBY.guest = p.guest and { username = p.guest } or {}
		MP.LOBBY.ready_to_start = p.guest ~= nil and p.guestReady == true
	elseif a == "lobbyOptions" then
		if p.back ~= nil then MP.LOBBY.config.back = p.back end
		if p.stake ~= nil then MP.LOBBY.config.stake = p.stake end
	elseif a == "startGame" then
		MP.LOBBY.ready_to_start = false
		G.FUNCS.lobby_start_run(nil, { seed = p.seed })
	elseif a == "stopGame" then
		G.FUNCS.go_to_menu()
	elseif a == "winGame" then
		MP.GAME.enemy.lives = 0 -- the real server reports the loser's last life before it sends winGame (198 of 198 real wins show enemy_lives 0)
		MP.STATS.record_match(true)
		G.STATE = G.STATES.GAME_OVER
	elseif a == "loseGame" then
		MP.STATS.record_match(false)
		G.STATE = G.STATES.GAME_OVER
	elseif a == "startBlind" then
		-- same bookkeeping as the real action_start_blind
		local e = MP.GAME.enemy
		e.score, e.real_score, e.info_received, e.hands = insane(0), insane(0), false, 4
		MP.GAME.pvp_reached_first = (MP.LOBBY.is_host and "host" or "guest") == p.firstPlayer
		MOCK.begin_pvp_blind()
	elseif a == "enemyInfo" then
		local e = MP.GAME.enemy
		e.hands = tonumber(p.handsLeft) or 0
		e.skips = tonumber(p.skips) or 0
		e.lives = tonumber(p.lives) or e.lives
		if not p.noScore and p.score ~= nil then
			e.real_score = MP.INSANE_INT.from_string(p.score)
			e.score = e.real_score
			e.info_received = true
		end
		MOCK.enemy_infos = (MOCK.enemy_infos or 0) + 1
	elseif a == "playerInfo" then
		MP.GAME.lives = p.lives
	elseif a == "endPvP" then
		MOCK.pvp_end_seq = (MOCK.pvp_end_seq or 0) + 1 -- the hand animation that is still running must not undo this
		G.GAME.waiting_pvp = nil
		MP.GAME.pvp_reached_first = false
		MP.GAME.score = nil
		MOCK.enter_round_eval()
	elseif a == "error" then
		G.OVERLAY_MENU = { error = p.message }
	elseif a == "disconnected" then
		MP.LOBBY.connected = false
		MP.LOBBY.code = nil
	end
end
