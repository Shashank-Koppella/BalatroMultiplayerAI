-- BotArena speed / window control. Done here (instead of through Handy) because Multiplayer deliberately
-- disables Handy's speed multiplier while a lobby is open. Arena instances only ever talk to the local
-- arena server, so speeding up the client does not touch any public lobby.
return function(A)
	local U, O, C = A.util, A.obs, A.cfg
	local S = {}

	-- Called every frame BEFORE Game:update (so SPEEDFACTOR is computed from our value).
	function S.pre()
		if G and G.SETTINGS and C.speed and C.speed > 0 then G.SETTINGS.GAMESPEED = C.speed end
		if G and C.fps_cap and C.fps_cap > 0 then G.FPS_CAP = C.fps_cap end
	end

	-- Called every frame AFTER Game:update. Re-runs the event queue a few extra times so chains of
	-- dependent events (scoring, shop transitions) finish in one frame; same trick Handy's "queue
	-- overclock" uses, minus the UI.
	function S.post()
		if not (G and G.E_MANAGER and G.STAGE == G.STAGES.RUN) then return end
		local n = C.boost or 0
		if n <= 0 then return end
		local vib, jig = G.VIBRATION, G.ROOM and G.ROOM.jiggle
		for _ = 1, n do
			local count = 0
			for _, q in pairs(G.E_MANAGER.queues or {}) do count = count + #q end
			if count <= 1 then break end
			G.E_MANAGER:update(0, true)
		end
		G.VIBRATION = vib
		if G.ROOM and jig then G.ROOM.jiggle = jig end
	end

	local function apply_window()
		local w = C.window
		if not w or not love.window then return end
		local ok, err = pcall(function()
			love.window.updateMode(w.w, w.h, {
				fullscreen = false,
				borderless = false,
				resizable = true,
				x = w.x,
				y = w.y,
				vsync = C.vsync_off and 0 or nil,
			})
			if love.window.setPosition then love.window.setPosition(w.x, w.y) end
		end)
		if not ok then U.warn("window layout failed: " .. tostring(err)) end
	end

	local function apply_audio()
		if not C.mute or not (G and G.SETTINGS and G.SETTINGS.SOUND) then return end
		G.SETTINGS.SOUND.volume = 0
		G.SETTINGS.SOUND.music_volume = 0
		G.SETTINGS.SOUND.game_sounds_volume = 0
	end

	function S.on_menu()
		apply_window()
		apply_audio()
		if C.vsync_off and love.window and love.window.setVSync then pcall(love.window.setVSync, 0) end
	end

	-- Optional frame skipping for rendering. Experimental: skipped frames may flicker on some drivers.
	function S.install_draw_skip()
		if C.draw_every <= 1 or not love or not love.draw then return end
		local orig = love.draw
		local frame = 0
		love.draw = function(...)
			frame = frame + 1
			if frame % C.draw_every ~= 0 then return end
			return orig(...)
		end
	end

	return S
end
