-- BotArena utilities: logging, env access, tiny file IO helpers, JSON helpers, tree search.
return function(A)
	local U = {}

	local json_ok, json = pcall(require, "json")
	U.json = json_ok and json or nil

	-- ---------------------------------------------------------------------------------------------
	-- time / env
	-- ---------------------------------------------------------------------------------------------
	function U.now()
		-- Monotonic seconds (real time, not scaled by game speed).
		if love and love.timer and love.timer.getTime then return love.timer.getTime() end
		return os.clock()
	end

	function U.wall()
		return os.time()
	end

	function U.env(name, default)
		local v = os.getenv(name)
		if v == nil or v == "" then return default end
		return v
	end

	function U.env_num(name, default)
		local v = tonumber(os.getenv(name))
		if v == nil then return default end
		return v
	end

	function U.env_bool(name, default)
		local v = os.getenv(name)
		if v == nil or v == "" then return default end
		v = string.lower(v)
		return not (v == "0" or v == "false" or v == "no" or v == "off")
	end

	-- ---------------------------------------------------------------------------------------------
	-- logging (Lovely log + optional BotArena log file)
	-- ---------------------------------------------------------------------------------------------
	local log_path = nil
	function U.set_log_path(p) log_path = p end

	local function emit(level, msg)
		msg = tostring(msg)
		local fn = (level == "error" and sendErrorMessage)
			or (level == "warn" and sendWarnMessage)
			or (level == "debug" and sendDebugMessage)
			or sendInfoMessage
		if fn then pcall(fn, msg, "BotArena") end
		if log_path and NFS then
			local line = string.format("%s [%s] %s\n", os.date("%H:%M:%S"), level, msg)
			pcall(function() NFS.append(log_path, line) end)
		end
	end
	function U.info(msg) emit("info", msg) end
	function U.warn(msg) emit("warn", msg) end
	function U.err(msg) emit("error", msg) end
	function U.debug(msg) emit("debug", msg) end

	-- ---------------------------------------------------------------------------------------------
	-- files (absolute paths via nativefs)
	-- ---------------------------------------------------------------------------------------------
	function U.norm(path)
		if not path then return path end
		return (tostring(path):gsub("\\", "/"))
	end

	function U.join(a, b)
		a = U.norm(a):gsub("/+$", "")
		return a .. "/" .. U.norm(b):gsub("^/+", "")
	end

	function U.mkdirs(path)
		path = U.norm(path)
		if not NFS then return false end
		if NFS.getInfo(path) then return true end
		local acc = ""
		for part in path:gmatch("[^/]+") do
			if acc == "" then
				-- keep drive letters ("C:") and leading slashes intact
				acc = path:sub(1, 1) == "/" and ("/" .. part) or part
			else
				acc = acc .. "/" .. part
			end
			if not (acc:match("^%a:$")) and not NFS.getInfo(acc) then pcall(NFS.createDirectory, acc) end
		end
		return NFS.getInfo(path) ~= nil
	end

	function U.read(path)
		if not NFS then return nil end
		local info = NFS.getInfo(U.norm(path))
		if not info then return nil end
		local ok, data = pcall(NFS.read, U.norm(path))
		if ok then return data end
		return nil
	end

	function U.write(path, data)
		if not NFS then return false end
		local ok = pcall(NFS.write, U.norm(path), data)
		return ok
	end

	function U.append(path, data)
		if not NFS then return false end
		local ok = pcall(NFS.append, U.norm(path), data)
		return ok
	end

	function U.remove(path)
		if not NFS then return false end
		return pcall(NFS.remove, U.norm(path))
	end

	function U.mtime(path)
		if not NFS then return nil end
		local info = NFS.getInfo(U.norm(path))
		return info and info.modtime or nil
	end

	-- ---------------------------------------------------------------------------------------------
	-- JSON
	-- ---------------------------------------------------------------------------------------------
	function U.encode(v)
		if not U.json then return nil end
		local ok, s = pcall(U.json.encode, v)
		if ok then return s end
		return nil
	end

	function U.decode(s)
		if not U.json or not s or s == "" then return nil end
		local ok, v = pcall(U.json.decode, s)
		if ok then return v end
		return nil
	end

	function U.write_json(path, v)
		local s = U.encode(v)
		if not s then return false end
		return U.write(path, s)
	end

	function U.read_json(path)
		return U.decode(U.read(path))
	end

	function U.append_jsonl(path, v)
		local s = U.encode(v)
		if not s then return false end
		return U.append(path, s .. "\n")
	end

	-- ---------------------------------------------------------------------------------------------
	-- misc
	-- ---------------------------------------------------------------------------------------------
	-- Depth-first search through a UIBox / UIElement tree for the first node satisfying `pred`.
	function U.find_uie(root, pred, max_nodes)
		if not root then return nil end
		local seen, budget = {}, max_nodes or 4000
		local function visit(node)
			if type(node) ~= "table" or seen[node] then return nil end
			seen[node] = true
			budget = budget - 1
			if budget <= 0 then return nil end
			local ok, hit = pcall(pred, node)
			if ok and hit then return node end
			if node.UIRoot then
				local r = visit(node.UIRoot)
				if r then return r end
			end
			if type(node.children) == "table" then
				for _, child in pairs(node.children) do
					local r = visit(child)
					if r then return r end
				end
			end
			return nil
		end
		return visit(root)
	end

	function U.find_button(root, button_name)
		return U.find_uie(root, function(n)
			return n.config and n.config.button == button_name
		end)
	end

	function U.shallow_copy(t)
		local r = {}
		for k, v in pairs(t or {}) do r[k] = v end
		return r
	end

	function U.parse_kv_list(s)
		-- "a=1,b=true,c=text" -> { a = 1, b = true, c = "text" }
		local out = {}
		if not s or s == "" then return out end
		for pair in tostring(s):gmatch("[^,;]+") do
			local k, v = pair:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
			if k then
				if v == "true" then
					v = true
				elseif v == "false" then
					v = false
				elseif tonumber(v) ~= nil then
					v = tonumber(v)
				end
				out[k] = v
			end
		end
		return out
	end

	function U.fmt_score(s)
		-- MP scores are InsaneInt-like tables; tostring them safely for logs.
		if s == nil then return nil end
		if type(s) == "table" then
			local ok, MPII = pcall(function() return MP.INSANE_INT.to_string(s) end)
			if ok and MPII then return MPII end
			return "?"
		end
		return tostring(s)
	end

	-- Best-effort conversion of a score to a plain Lua number: a number, a numeric string, an MP
	-- "InsaneInt" ({ coeffiocient, exponent, e_count } - sic) or a Talisman-style big number.
	-- Values beyond double range saturate to math.huge. Returns nil when it cannot be read.
	function U.num(x)
		local t = type(x)
		if t == "number" then
			if x ~= x then return nil end
			return x
		end
		if t == "string" then return tonumber(x) end
		if t == "table" then
			if x.coeffiocient ~= nil then
				if (tonumber(x.e_count) or 0) > 0 then return math.huge end
				local c, ex = tonumber(x.coeffiocient) or 0, tonumber(x.exponent) or 0
				if c == 0 then return 0 end
				if ex > 308 then return math.huge end
				return c * 10 ^ ex
			end
			if type(x.to_number) == "function" then
				local ok, v = pcall(x.to_number, x)
				if ok and type(v) == "number" then return v end
			end
			if x.m ~= nil and x.e ~= nil then -- Talisman Big {m, e}
				local m, e = tonumber(x.m), tonumber(x.e)
				if m and e then
					if e > 308 then return math.huge end
					return m * 10 ^ e
				end
			end
		end
		return nil
	end

	-- log10(1 + score) with sane handling of nil / negative / infinite values (used by reward shaping).
	function U.log1p10(x)
		local n = U.num(x)
		if not n or n <= 0 then return 0 end
		if n == math.huge then return 308 end
		return math.log10(n + 1)
	end

	-- log2(1 + score): "doublings", the unit of the PvP score margin (see reward.lua). Same edge cases as log1p10.
	function U.log1p2(x)
		local n = U.num(x)
		if not n or n <= 0 then return 0 end
		if n == math.huge then return 1024 end
		return math.log(n + 1) / math.log(2)
	end

	-- ---------------------------------------------------------------------------------------------
	-- safe CardArea access. The game's CardArea:remove() sets `.cards = nil` (and REMOVED = true) while
	-- other code may still hold G.pack_cards / G.shop_* etc. Reading `#area.cards` on such a leftover
	-- area throws - which used to kill the bot's tick every frame (see README, "cash-out").
	-- ---------------------------------------------------------------------------------------------
	function U.cards(area)
		if type(area) ~= "table" or area.REMOVED then return {} end
		local c = area.cards
		if type(c) ~= "table" then return {} end
		return c
	end

	function U.count(area)
		return #U.cards(area)
	end

	-- A booster pack is open only when its card area is alive and holds cards or the pack UI exists.
	function U.pack_open()
		if not G then return false end
		local p = G.pack_cards
		if type(p) == "table" and not p.REMOVED and type(p.cards) == "table" then return true end
		return G.booster_pack ~= nil and not (type(G.booster_pack) == "table" and G.booster_pack.REMOVED)
	end

	return U
end
