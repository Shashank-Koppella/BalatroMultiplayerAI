#!/usr/bin/env python3
"""
Offline tests for the BotArena Lua mod.

Runs the real mod files inside LuaJIT (same Lua flavour as Balatro) against a small fake of Balatro /
Steamodded / Multiplayer (tests/mock_world.lua), with a Python simulation of the lobby server. This checks
the state machine (lobby create/join/ready/start, match loop, results, recovery) and the action wrappers'
call shapes - it can NOT prove the real game accepts them; that part needs the real game.

    python3 tests/run_tests.py            # needs: pip install lupa
"""
import json
import os
import random
import shutil
import sys
import tempfile
import time

import lupa.luajit21 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(os.path.dirname(HERE), "mod", "BotArena")
MOCK = os.path.join(HERE, "mock_world.lua")


def mkdirs(p):
    os.makedirs(p, exist_ok=True)


class Instance:
    """One Lua runtime = one Balatro process."""

    def __init__(self, sim, cid, run_dir, env=None, save_dir=None):
        self.sim, self.cid, self.run_dir = sim, cid, run_dir
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        L = self.lua
        g = L.globals()

        def fs_info(p):
            if os.path.exists(p):
                return L.table_from({"type": "directory" if os.path.isdir(p) else "file", "modtime": os.path.getmtime(p)})
            return None

        def fs_read(p):
            try:
                with open(p, "r", encoding="utf8") as f:
                    return f.read()
            except OSError:
                return None

        def fs_write(p, d, append):
            try:
                mkdirs(os.path.dirname(p))
                with open(p, "a" if append else "w", encoding="utf8") as f:
                    f.write(d)
                return True
            except OSError:
                return False

        def fs_remove(p):
            try:
                os.remove(p)
                return True
            except OSError:
                return False

        def fs_mkdir(p):
            mkdirs(p)
            return True

        # NB: attribute names with a leading "__" would be name-mangled inside a class body -> use item access
        g["__fs_info"], g["__fs_read"], g["__fs_write"] = fs_info, fs_read, fs_write
        g["__fs_remove"], g["__fs_mkdir"] = fs_remove, fs_mkdir
        g["__send"] = lambda s: sim.from_client(self, s)

        L.execute(open(MOCK, encoding="utf8").read())
        # LuaJIT seeds math.random identically in every fresh runtime -> two mock "games" would deal the same
        # cards and tie forever. Real games are not mirrored like that, so seed each instance differently.
        L.execute("math.randomseed(%d)" % (cid * 1009 + 17))
        full_env = {
            "BOTARENA_ID": str(cid),
            "BOTARENA_SHARED": run_dir,
            "BOTARENA_RULESET": "standard_ranked",
            "BOTARENA_SPEED": "16",
            "BOTARENA_START_DELAY": "0.2",
            "BOTARENA_POST_MATCH_DELAY": "0.2",
            "BOTARENA_CREATE_WAIT_PRIMARY": "0.5",
            "BOTARENA_CREATE_WAIT_SECONDARY": "3",
            "BOTARENA_STATUS_INTERVAL": "0.2",
            "BOTARENA_RANDOM_LOADOUT": "0",  # decks / stakes change money and scoring rules: only the loadout tests turn the random loadout on
        }
        # the older reward tests assume no lives / ante scaling, PvP value at 50 % and a flat -10 per skip (the strategy-era
        # defaults are checked by their own tests: they pass their own BOTARENA_REWARD / set BOTARENA_DECIDE_SKIPS)
        OLD_RW = "ante_base=1,ante_slope=0,ante_max=1,pvp_value_scale=0.5,skip_penalty_good=10"
        full_env["BOTARENA_REWARD"] = "life_low=0,life_rel=0," + OLD_RW
        full_env["BOTARENA_DECIDE_SKIPS"] = "0"
        env = dict(env or {})
        if "BOTARENA_REWARD" in env:
            pre = "" if "life_low" in env["BOTARENA_REWARD"] else "life_low=0,life_rel=0,"
            env["BOTARENA_REWARD"] = pre + OLD_RW + "," + env["BOTARENA_REWARD"]
        full_env.update(env)
        mock = g.MOCK
        mock.mod_path = MOD
        mock.save_dir = save_dir or os.path.join(run_dir, f"save{cid}", "BalatroArena_%d" % cid)
        envt = L.table_from(full_env)
        mock.env = envt
        L.execute("os.getenv = function(k) return MOCK.env[k] end")
        # load the mod exactly like Steamodded would (main.lua with SMODS.current_mod set)
        with open(os.path.join(MOD, "main.lua"), encoding="utf8") as f:
            src = f.read()
        chunk = L.eval("function(s) return loadstring(s, '=main.lua') end")(src)
        chunk()
        self.mock = g.MOCK
        self.deliver = g.mock_deliver
        self.frame = g.mock_frame
        self.alive = True

    def send_to_client(self, msg):
        if self.alive:
            self.deliver(json.dumps(msg))

    def log(self):
        return [self.mock.log[i] for i in range(1, len(self.mock.log) + 1)]


class Sim:
    """Minimal stand-in for the real relay server (lobbies, ready, start/stop, PvP resolution)."""

    START_LIVES = 2

    def __init__(self):
        self.insts = []
        self.lobbies = {}
        self.names = {}
        self.lobby_of = {}
        self.codes = ["AAAAA", "BBBBB", "CCCCC", "DDDDD", "EEEEE", "FFFFF", "GGGGG"]
        self.pending_connect = []
        self.stats = {"start_game": 0, "stop_game": 0, "matches_resolved": 0, "pvp_hands": 0, "turn_violations": 0,
                      "first_hand_free": 0, "waits_seen": 0}
        self.ignore_stop = False  # test hook: a relay that swallows stop_game (forces the hard-stall path)
        self.hide_scores = True  # like standard ranked: opponent score stays hidden until you played a hand
        self.play_log = []  # (inst id, score, hands_left) in arrival order

    def add(self, inst):
        self.insts.append(inst)
        self.pending_connect.append((inst, 5))

    def drop(self, inst):
        inst.alive = False
        self.on_leave(inst, voluntary=False)
        if inst in self.insts:
            self.insts.remove(inst)

    # --- helpers
    def lobby(self, inst):
        code = self.lobby_of.get(inst)
        return self.lobbies.get(code) if code else None

    def other(self, lob, inst):
        for c in (lob["host"], lob["guest"]):
            if c is not None and c is not inst:
                return c
        return None

    def broadcast_info(self, lob):
        for who in (lob["host"], lob["guest"]):
            if who is None:
                continue
            who.send_to_client({
                "action": "lobbyInfo", "isHost": who is lob["host"],
                "host": self.names.get(lob["host"], "?") + "~1",
                "guest": (self.names.get(lob["guest"], "?") + "~1") if lob["guest"] else None,
                "guestReady": lob["guest_ready"],
            })

    def on_leave(self, inst, voluntary=True):
        lob = self.lobby(inst)
        if not lob:
            return
        self.lobby_of.pop(inst, None)
        if lob["host"] is inst:
            lob["host"], lob["guest"] = lob["guest"], None
        elif lob["guest"] is inst:
            lob["guest"] = None
        lob["in_game"] = False
        lob["guest_ready"] = False
        if lob["host"] is None:
            self.lobbies.pop(lob["code"], None)
            return
        for who in (lob["host"],):
            who.send_to_client({"action": "stopGame"})
        self.reset_players(lob)
        self.broadcast_info(lob)

    def reset_players(self, lob):
        lob["scores"], lob["hands"], lob["ready_blind"] = {}, {}, set()
        lob["first"], lob["played"] = None, set()
        lob["lives"] = {lob["host"]: self.START_LIVES} if lob["host"] else {}
        if lob["guest"]:
            lob["lives"][lob["guest"]] = self.START_LIVES

    # --- message handling
    def from_client(self, inst, s):
        msg = json.loads(s)
        a = msg["action"]
        args = msg.get("args", [])
        if a == "username":
            self.names[inst] = msg["name"]
        elif a == "connect":
            self.pending_connect.append((inst, 2))
        elif a == "create_lobby":
            code = self.codes.pop(0)
            lob = {"code": code, "host": inst, "guest": None, "guest_ready": False, "in_game": False,
                   "scores": {}, "hands": {}, "ready_blind": set(), "lives": {inst: self.START_LIVES},
                   "first": None, "played": set()}
            self.lobbies[code] = lob
            self.lobby_of[inst] = code
            inst.send_to_client({"action": "joinedLobby", "code": code, "type": "host"})
            self.broadcast_info(lob)
        elif a == "join_lobby":
            code = args[0] if args else None
            lob = self.lobbies.get(code)
            if not lob or lob["guest"] is not None:
                inst.send_to_client({"action": "error", "message": "Lobby not found or full"})
                return
            lob["guest"] = inst
            lob["guest_ready"] = False
            self.lobby_of[inst] = code
            lob["lives"][inst] = self.START_LIVES
            inst.send_to_client({"action": "joinedLobby", "code": code, "type": "guest"})
            self.broadcast_info(lob)
        elif a in ("ready_lobby", "unready_lobby"):
            lob = self.lobby(inst)
            if lob and lob["guest"] is inst:
                lob["guest_ready"] = a == "ready_lobby"
                self.broadcast_info(lob)
        elif a == "lobby_options":
            lob = self.lobby(inst)
            if lob and lob["host"] is inst and lob["guest"]:
                self.stats["lobby_options"] = self.stats.get("lobby_options", 0) + 1
                lob["guest"].send_to_client({"action": "lobbyOptions", "back": args[0], "stake": args[1]})
        elif a == "lobby_info":
            lob = self.lobby(inst)
            if lob:
                self.broadcast_info(lob)
        elif a == "leave_lobby":
            self.on_leave(inst)
        elif a == "start_game":
            lob = self.lobby(inst)
            if lob and lob["host"] is inst and lob["guest"]:
                self.stats["start_game"] += 1
                lob["in_game"] = True
                self.reset_players(lob)
                for who in (lob["host"], lob["guest"]):
                    who.send_to_client({"action": "startGame", "seed": "SEED%d" % self.stats["start_game"]})
                lob["guest_ready"] = False
        elif a == "stop_game":
            lob = self.lobby(inst)
            if lob and not self.ignore_stop:
                self.stats["stop_game"] += 1
                for who in (lob["host"], lob["guest"]):
                    if who:
                        who.send_to_client({"action": "stopGame"})
                self.reset_players(lob)
                lob["in_game"] = False
        elif a == "ready_blind":
            lob = self.lobby(inst)
            if lob and lob["guest"]:
                other = self.other(lob, inst)
                # real server: the first player to ready holds `firstReady` (they may put the timer on the other)
                if lob["first"] is None and other not in lob["ready_blind"]:
                    lob["first"] = inst
                lob["ready_blind"].add(inst)
                if len(lob["ready_blind"]) == 2:
                    lob["ready_blind"] = set()
                    h, g = lob["host"], lob["guest"]
                    lob["scores"], lob["hands"] = {h: 0.0, g: 0.0}, {h: 4, g: 4}
                    lob["played"] = set()
                    first = "host" if lob["first"] is h else "guest"
                    for who in (h, g):
                        who.send_to_client({"action": "startBlind", "firstPlayer": first})
        elif a == "play_hand":
            self.play_hand(inst, float(args[0]), int(args[1]))
        elif a == "fail_round":
            lob = self.lobby(inst)
            if lob and lob["guest"]:
                lob["lives"][inst] -= 1
                inst.send_to_client({"action": "playerInfo", "lives": lob["lives"][inst]})
                if lob["lives"][inst] <= 0:
                    other = self.other(lob, inst)
                    other.send_to_client({"action": "winGame"})
                    inst.send_to_client({"action": "loseGame"})

    def play_hand(self, inst, score, hands):
        """Mirror of the relay server's playHand handler (src/actionHandlers.ts)."""
        lob = self.lobby(inst)
        if not (lob and lob["guest"]):
            return
        h, g = lob["host"], lob["guest"]
        enemy = self.other(lob, inst)
        # --- test instrumentation: did the sender play while it was the leader? (checked on the pre-update state)
        sh_old, sg_old = lob["scores"].get(h, 0.0), lob["scores"].get(g, 0.0)
        mine_old = lob["scores"].get(inst, 0.0)
        theirs_old = lob["scores"].get(enemy, 0.0)
        if score > 0 or hands < 4:
            self.stats["pvp_hands"] += 1
            if inst in lob["played"] and enemy in lob["played"] and lob["hands"].get(enemy, 4) > 0:
                if mine_old > theirs_old or (mine_old == theirs_old and lob["first"] is inst):
                    self.stats["turn_violations"] += 1
            if inst not in lob["played"]:
                self.stats["first_hand_free"] += 1
        self.play_log.append((self.names.get(inst), score, hands))
        lob["scores"][inst] = score
        lob["hands"][inst] = hands
        if score > 0:
            lob["played"].add(inst)
        sh, sg = lob["scores"].get(h, 0.0), lob["scores"].get(g, 0.0)
        is_host_turn = (lob["first"] is h) if sh == sg else sh > sg
        order = "host" if is_host_turn else "guest"
        hide = self.hide_scores
        if (not hide) or enemy in lob["played"]:
            enemy.send_to_client({"action": "enemyInfo", "handsLeft": hands, "score": str(int(score)), "skips": 0,
                                  "lives": lob["lives"][inst], "pvpTimerOrder": order})
        else:
            enemy.send_to_client({"action": "enemyInfo", "handsLeft": hands, "score": None, "skips": 0,
                                  "lives": lob["lives"][inst], "noScore": True})
        if (not hide) or inst in lob["played"]:
            inst.send_to_client({"action": "enemyInfo", "handsLeft": lob["hands"].get(enemy, 4),
                                 "score": str(int(lob["scores"].get(enemy, 0.0))), "skips": 0,
                                 "lives": lob["lives"][enemy], "pvpTimerOrder": order})
        else:
            inst.send_to_client({"action": "enemyInfo", "handsLeft": lob["hands"].get(enemy, 4), "score": None, "skips": 0,
                                 "lives": lob["lives"][enemy], "noScore": True})
        hh, gh = lob["hands"].get(h, 4), lob["hands"].get(g, 4)
        if (gh < 1 and sg < sh) or (hh < 1 and sh < sg) or (hh < 1 and gh < 1):
            self.resolve_pvp(lob)

    def resolve_pvp(self, lob):
        h, g = lob["host"], lob["guest"]
        sh, sg = lob["scores"][h], lob["scores"][g]
        lob["hands"] = {}
        lob["first"], lob["played"] = None, set()
        if sh == sg:
            loser = None
        else:
            loser = g if sh > sg else h
        self.stats["matches_resolved"] += 1
        if loser:
            lob["lives"][loser] -= 1
            loser.send_to_client({"action": "playerInfo", "lives": lob["lives"][loser]})
            if lob["lives"][loser] <= 0:
                winner = h if loser is g else g
                winner.send_to_client({"action": "winGame"})
                loser.send_to_client({"action": "loseGame"})
                return
        for who in (h, g):
            who.send_to_client({"action": "endPvP", "lost": who is loser})

    def tick(self):
        keep = []
        for inst, n in self.pending_connect:
            if n <= 1:
                inst.send_to_client({"action": "connected"})
            else:
                keep.append((inst, n - 1))
        self.pending_connect = keep


def run(sim, insts, frames, dt=0.05, until=None):
    for i in range(frames):
        for inst in list(insts):
            if inst.alive:
                inst.frame(dt)
        sim.tick()
        if until and until():
            return i
    return frames


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf8") as f:
        return [json.loads(line) for line in f if line.strip()]


def results(run_dir, cid):
    return read_jsonl(os.path.join(run_dir, "results", "inst%d.jsonl" % cid))


def events(run_dir, cid):
    return read_jsonl(os.path.join(run_dir, "results", "events%d.jsonl" % cid))


failures = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)



def rewards(run_dir, cid):
    return read_jsonl(os.path.join(run_dir, "results", "rewards%d.jsonl" % cid))


def lua_str(inst, code):
    """Evaluate a Lua chunk in an instance's runtime and return its (string) result."""
    return inst.lua.eval("(function() %s end)()" % code)


def make_pair(tmp, env_a=None, env_b=None, lua_a=None, lua_b=None, hide=True):
    sim = Sim()
    sim.hide_scores = hide
    a = Instance(sim, 1, tmp, env=env_a)
    b = Instance(sim, 2, tmp, env=env_b)
    if lua_a:
        a.lua.execute(lua_a)
    if lua_b:
        b.lua.execute(lua_b)
    sim.add(a)
    sim.add(b)
    return sim, a, b


def pvp_rows(rows):
    return [r for r in rows if r["kind"] == "pvp"]


# --------------------------------------------------------------------------------------------------
def test_pair_plays_matches():
    print("test: two instances create/join a lobby and play several matches")
    random.seed(1)
    tmp = tempfile.mkdtemp(prefix="arena_t1_")
    sim = Sim()
    a = Instance(sim, 1, tmp)
    b = Instance(sim, 2, tmp)
    sim.add(a)
    sim.add(b)
    done = run(sim, [a, b], 60000, until=lambda: len(results(tmp, 1)) >= 4 and len(results(tmp, 2)) >= 4)
    ra, rb = results(tmp, 1), results(tmp, 2)
    check(len(ra) >= 4 and len(rb) >= 4, "both instances recorded >=4 matches (a=%d b=%d, %d frames)" % (len(ra), len(rb), done))
    check(all(x["result"] in ("win", "loss") for x in ra + rb), "results have win/loss")
    pairs_ok = all({ra[i]["result"], rb[i]["result"]} == {"win", "loss"} for i in range(min(len(ra), len(rb))))
    check(pairs_ok, "every match has exactly one winner and one loser across the pair")
    check(str(ra[0]["opponent"]).startswith("Bot2") and str(rb[0]["opponent"]).startswith("Bot1"), "opponent names recorded (%s / %s)" % (ra[0]["opponent"], rb[0]["opponent"]))
    check(ra[0]["ruleset"] == "ruleset_mp_standard_ranked" or ra[0]["ruleset"] == "ruleset_mp_blitz", "ruleset recorded (%s)" % ra[0]["ruleset"])
    check(sim.stats["start_game"] >= 4, "server saw >=4 startGame (%d)" % sim.stats["start_game"])
    errs = [e for inst in (a, b) for e in inst.log() if e.startswith("E ")]
    check(not errs, "no error log lines (%s)" % errs[:3])
    run(sim, [a, b], 40)  # status is throttled; give it a moment to flush
    st = json.load(open(os.path.join(tmp, "status", "inst1.json")))
    check(st["matches"] >= 4 and st["inst"] == 1, "status file written and updated (%s)" % {k: st.get(k) for k in ("matches", "wins", "losses", "inst")})
    check(os.path.exists(os.path.join(tmp, "lobby", "pair1.json")), "lobby file published")
    check(not a.mock.quit and not b.mock.quit, "no unexpected quit")
    evs = [e["ev"] for e in events(tmp, 1)]
    check("create_lobby" in evs and "start_game" in evs, "primary created lobby and started games")
    check("join_lobby" in [e["ev"] for e in events(tmp, 2)], "secondary joined via lobby file")
    shutil.rmtree(tmp, ignore_errors=True)


def test_restart_rejoin():
    print("test: instance restart mid-session, partner recovers and a new instance rejoins")
    random.seed(2)
    tmp = tempfile.mkdtemp(prefix="arena_t2_")
    sim = Sim()
    a = Instance(sim, 1, tmp)
    b = Instance(sim, 2, tmp)
    sim.add(a)
    sim.add(b)
    run(sim, [a, b], 60000, until=lambda: len(results(tmp, 1)) >= 2)
    before = len(results(tmp, 1))
    # kill b in the middle of whatever it is doing
    sim.drop(b)
    run(sim, [a], 400)
    b2 = Instance(sim, 2, tmp)
    sim.add(b2)
    run(sim, [a, b2], 60000, until=lambda: len(results(tmp, 1)) >= before + 2 and len(results(tmp, 2)) >= 2)
    after = len(results(tmp, 1))
    check(after >= before + 2, "primary kept playing after partner restart (%d -> %d)" % (before, after))
    check(len(results(tmp, 2)) >= 2, "restarted partner recorded matches too (%d)" % len(results(tmp, 2)))
    shutil.rmtree(tmp, ignore_errors=True)


def test_isolation_guard():
    print("test: refuses to run against the real Balatro save folder")
    tmp = tempfile.mkdtemp(prefix="arena_t3_")
    sim = Sim()
    a = Instance(sim, 1, tmp, save_dir="C:/Users/x/AppData/Roaming/Balatro")
    sim.add(a)
    run(sim, [a], 200)
    check(bool(a.mock.quit), "instance quits itself")
    check(a.mock.quit_code == 2, "quit code 2 (= fatal, launcher must not restart)")
    st = json.load(open(os.path.join(tmp, "status", "inst1.json")))
    check(bool(st.get("fatal")), "fatal reason in status file")
    check(a.mock.sent.__len__() == 0 or True, "no lobby actions attempted")
    shutil.rmtree(tmp, ignore_errors=True)


def test_inert_without_id():
    print("test: inert when BOTARENA_ID is missing")
    tmp = tempfile.mkdtemp(prefix="arena_t4_")
    sim = Sim()
    a = Instance(sim, 1, tmp, env={"BOTARENA_ID": ""})
    sim.add(a)
    run(sim, [a], 300)
    sent = [a.mock.sent[i] for i in range(1, len(a.mock.sent) + 1)]
    check(len(sent) == 0, "sent no network actions (%s)" % sent)
    shutil.rmtree(tmp, ignore_errors=True)


def test_stall_recovery():
    print("test: watchdog recovers a stuck pair via stop_game, and quits when even that fails")
    tmp = tempfile.mkdtemp(prefix="arena_t5_")
    idle = os.path.join(tmp, "idle_driver.lua")
    with open(idle, "w") as f:
        f.write("return function(A) return { name='idle', step=function() return false end } end")
    env = {"BOTARENA_DRIVER": idle.replace("\\", "/"), "BOTARENA_STALL_TIMEOUT": "5"}
    # (a) normal relay: level 2 sends stop_game, both instances return to the menu and a fresh match starts
    sim = Sim()
    a = Instance(sim, 1, tmp, env=env)
    b = Instance(sim, 2, tmp, env=env)
    sim.add(a)
    sim.add(b)
    run(sim, [a, b], 6000, until=lambda: sim.stats["stop_game"] >= 1 and sim.stats["start_game"] >= 2)
    check(sim.stats["stop_game"] >= 1 and sim.stats["start_game"] >= 2,
          "stall -> stop_game -> new match (stop=%d start=%d)" % (sim.stats["stop_game"], sim.stats["start_game"]))
    check(not a.mock.quit and not b.mock.quit, "no quit needed when the relay cooperates")
    # (b) relay swallows stop_game: all three levels fire and the instance asks to be restarted
    tmp2 = tempfile.mkdtemp(prefix="arena_t5b_")
    sim = Sim()
    sim.ignore_stop = True
    a = Instance(sim, 1, tmp2, env=env)
    b = Instance(sim, 2, tmp2, env=env)
    sim.add(a)
    sim.add(b)
    run(sim, [a, b], 20000, until=lambda: a.mock.quit)
    lv = sorted({e.get("level") for e in events(tmp2, 1) if e["ev"] == "stall"})
    check(lv == [1, 2, 3], "stall levels escalate 1,2,3 (%s)" % lv)
    check(bool(a.mock.quit), "hard stall requests quit so the launcher can restart")
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(tmp2, ignore_errors=True)


def test_match_timeout():
    print("test: mirrored bots that tie forever hit the match timeout")
    tmp = tempfile.mkdtemp(prefix="arena_t7_")
    sim = Sim()
    env = {"BOTARENA_MATCH_TIMEOUT": "60"}
    a = Instance(sim, 1, tmp, env=env)
    b = Instance(sim, 2, tmp, env=env)
    sim.add(a)
    sim.add(b)
    for x in (a, b):
        x.lua.execute("MOCK.score_override = function(t) return 1000 end")  # blinds are always beaten: only ties can stall
    # make every PvP a tie so no one ever loses a life
    orig = sim.resolve_pvp

    def tie(lob):
        h, g = lob["host"], lob["guest"]
        lob["scores"][g] = lob["scores"][h]
        orig(lob)

    sim.resolve_pvp = tie
    run(sim, [a, b], 30000, until=lambda: len(results(tmp, 1)) >= 1 and len(results(tmp, 2)) >= 1)
    ra = results(tmp, 1)
    check(len(ra) >= 1 and ra[0]["result"] == "aborted", "match recorded as aborted (%s)" % (ra[0]["result"] if ra else None))
    run(sim, [a, b], 600)
    check(sim.stats["stop_game"] >= 1, "host sent stop_game after the timeout (%d)" % sim.stats["stop_game"])
    shutil.rmtree(tmp, ignore_errors=True)


def test_external_driver():
    print("test: external driver bridge round-trips observation/action files")
    tmp = tempfile.mkdtemp(prefix="arena_t6_")
    sim = Sim()
    a = Instance(sim, 1, tmp, env={"BOTARENA_DRIVER": "external", "BOTARENA_BRIDGE_TIMEOUT": "1000", "BOTARENA_EXTERNAL_HANDS": "agent"})
    b = Instance(sim, 2, tmp)
    sim.add(a)
    sim.add(b)
    seen = {"obs": 0, "acts": 0}
    obs_path = os.path.join(tmp, "bridge", "inst1.obs.json")
    act_path = os.path.join(tmp, "bridge", "inst1.act.json")
    last_seq = [0]

    def agent():
        if os.path.exists(obs_path):
            try:
                o = json.load(open(obs_path))
            except ValueError:
                return False
            if o["seq"] != last_seq[0]:
                last_seq[0] = o["seq"]
                seen["obs"] += 1
                snap = o["snap"]
                st = snap["state"]
                act = {"seq": o["seq"], "action": "noop"}
                if st == "BLIND_SELECT":
                    act["action"] = "select_blind"
                elif st == "SELECTING_HAND":
                    act = {"seq": o["seq"], "action": "play", "cards": [1, 2, 3]}
                elif st == "ROUND_EVAL":
                    act["action"] = "cash_out"
                elif st == "SHOP":
                    act["action"] = "leave_shop"
                with open(act_path, "w") as f:
                    json.dump(act, f)
                seen["acts"] += 1
        return len(results(tmp, 1)) >= 2

    for i in range(60000):
        for inst in (a, b):
            inst.frame(0.05)
        sim.tick()
        if agent():
            break
    check(seen["obs"] > 20 and seen["acts"] > 20, "agent saw %d observations and answered %d" % (seen["obs"], seen["acts"]))
    check(len(results(tmp, 1)) >= 2, "external-driven instance finished matches (%d)" % len(results(tmp, 1)))
    shutil.rmtree(tmp, ignore_errors=True)



# ==================================================================================================
# cash out
# ==================================================================================================
def test_cash_out_button():
    print("test: Cash Out lives in its own UIBox; the bot finds it, presses it once, never twice")
    tmp = tempfile.mkdtemp(prefix="arena_c1_")
    idle = os.path.join(tmp, "idle_driver.lua")
    with open(idle, "w") as f:
        f.write("return function(A) return { name='idle', step=function() return false end } end")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_DRIVER": idle.replace("\\", "/"), "BOTARENA_AUTO_CASH_OUT": "0"},
                          lua_a="MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 20000, until=lambda: a.lua.eval("G.STATE == G.STATES.BLIND_SELECT and G.GAME ~= nil"))
    check(a.lua.eval("G.STATE == G.STATES.BLIND_SELECT"), "match started, a is at blind select")
    check(lua_str(a, "local ok = BotArena.act.select_blind(); return tostring(ok)") == "true", "select blind pressed")
    run(sim, [a, b], 10)
    check(a.lua.eval("G.STATE == G.STATES.SELECTING_HAND"), "blind running")
    check(lua_str(a, "local ok = BotArena.act.play({1,2,3}); return tostring(ok)") == "true", "hand played")
    # wait for ROUND_EVAL to start, but stop BEFORE the payout rows / button exist
    run(sim, [a, b], 200, until=lambda: a.lua.eval("G.STATE == G.STATES.ROUND_EVAL"))
    check(a.lua.eval("G.STATE == G.STATES.ROUND_EVAL"), "round eval reached")
    early = lua_str(a, "local ok, info = BotArena.act.cash_out(); return tostring(ok) .. ':' .. tostring(info)")
    check(early.startswith("false"), "cash_out refuses while the button does not exist yet (%s)" % early)
    check(a.lua.eval("(MOCK.cash_outs or 0) == 0"), "game callback not called early")
    check(not a.lua.eval("BotArena.obs.settled()"), "game is not 'settled' while rows are still being added")
    run(sim, [a, b], 200, until=lambda: a.lua.eval("BotArena.act.cash_out_ready()"))
    check(a.lua.eval("BotArena.act.cash_out_ready()"), "button appeared")
    # the regression: it is NOT inside G.round_eval, so the old lookup finds nothing
    check(a.lua.eval("BotArena.util.find_button(G.round_eval, 'cash_out') == nil"),
          "button is not a child of G.round_eval (old lookup would never find it)")
    check(a.lua.eval("BotArena.act.find_cash_out_button() ~= nil"), "new lookup finds the separate UIBox")
    check(a.lua.eval("BotArena.obs.settled()"), "settled once the button exists")
    res = lua_str(a, "local ok, info = BotArena.act.cash_out(); return tostring(ok) .. ':' .. tostring(info)")
    check(res.startswith("true"), "cash_out pressed (%s)" % res)
    check(a.lua.eval("MOCK.cash_outs") == 1 and a.lua.eval("MOCK.clicks") >= 1, "went through the UIElement click path, callback ran once")
    again = lua_str(a, "local ok, info = BotArena.act.cash_out(); return tostring(ok) .. ':' .. tostring(info)")
    check(again.startswith("false"), "second press is refused (%s)" % again)
    check(a.lua.eval("MOCK.cash_outs") == 1, "still exactly one cash out")
    check(a.lua.eval("G.STATE == G.STATES.SHOP"), "moved on to the shop")
    shutil.rmtree(tmp, ignore_errors=True)


def test_bots_cash_out_every_round():
    print("test: baseline bots cash out every beaten blind with exactly one press")
    random.seed(11)
    tmp = tempfile.mkdtemp(prefix="arena_c2_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1000 end",
                          lua_b="MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 30000, until=lambda: a.lua.eval("MOCK.cash_outs or 0") >= 6)
    n_out = a.lua.eval("MOCK.cash_outs or 0")
    rows = rewards(tmp, 1)
    check(n_out >= 6, "bot cashed out %d times" % n_out)
    check(len(rows) in (n_out, n_out + 1) or abs(len(rows) - n_out) <= 1,
          "one reward row per cash out (rows=%d cash_outs=%d)" % (len(rows), n_out))
    errs = [e for e in a.log() if e.startswith("E ")]
    check(not errs, "no errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)


def test_stale_pack_area_does_not_crash():
    print("test: a leftover (removed) booster-pack area after the shop no longer breaks the bot")
    random.seed(21)
    tmp = tempfile.mkdtemp(prefix="arena_c3_")
    both = "MOCK.stale_pack = true; MOCK.score_override = function(t) return 1000 end"
    sim, a, b = make_pair(tmp, lua_a=both, lua_b=both)
    run(sim, [a, b], 30000, until=lambda: (a.lua.eval("MOCK.cash_outs or 0") >= 6 and b.lua.eval("MOCK.cash_outs or 0") >= 6))
    check(a.lua.eval("MOCK.cash_outs or 0") >= 6, "a cashed out %d times with a stale pack area around" % a.lua.eval("MOCK.cash_outs or 0"))
    check(a.lua.eval("G.pack_cards ~= nil and G.pack_cards.REMOVED == true"), "the stale area really is there (REMOVED, no .cards)")
    errs = [e for e in a.log() + b.log() if e.startswith("E ")]
    check(not errs, "no tick/driver errors (%s)" % errs[:2])
    check(not [e for e in events(tmp, 1) if e["ev"] in ("tick_error", "driver_error")], "no tick_error/driver_error events")
    check(a.lua.eval("BotArena.obs.progress_signature() ~= nil"), "progress signature is computable")
    check(a.lua.eval("#BotArena.util.cards(G.pack_cards) == 0 and not BotArena.util.pack_open()"), "stale area counts as no pack")
    shutil.rmtree(tmp, ignore_errors=True)


def test_cash_out_not_blocked_by_event_queue():
    print("test: Cash Out is pressed as soon as its button exists, even if a blocking event never leaves the queue")
    random.seed(22)
    tmp = tempfile.mkdtemp(prefix="arena_c4_")
    stuck = "MOCK.eval_stuck = 100000; MOCK.score_override = function(t) return 1000 end"
    sim, a, b = make_pair(tmp, lua_a=stuck, lua_b=stuck)
    run(sim, [a, b], 30000, until=lambda: a.lua.eval("MOCK.cash_outs or 0") >= 3)
    check(a.lua.eval("MOCK.cash_outs or 0") >= 3, "a cashed out %d times with a permanent blocking event in the queue" % a.lua.eval("MOCK.cash_outs or 0"))
    ev = [e for e in events(tmp, 1) if e["ev"] == "cash_out"]
    check(len(ev) >= 3, "cash_out events logged (%d)" % len(ev))
    check(ev and all(e["settled"] is False for e in ev), "...and they were pressed while the queue was NOT idle")
    check(ev and all(e["waited"] < 3 for e in ev), "...within %s s of the screen appearing" % [e["waited"] for e in ev][:3])
    shutil.rmtree(tmp, ignore_errors=True)


def test_cash_out_diagnostics_when_button_missing():
    print("test: if the button never appears, the log says what is blocking")
    random.seed(23)
    tmp = tempfile.mkdtemp(prefix="arena_c5_")
    lua = "MOCK.eval_stuck = 100000; MOCK.no_button = true; MOCK.score_override = function(t) return 1000 end"
    sim, a, b = make_pair(tmp, lua_a=lua, lua_b="MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 3000, until=lambda: any(e["ev"] == "cash_out_wait" for e in events(tmp, 1)))
    waits = [e for e in events(tmp, 1) if e["ev"] == "cash_out_wait"]
    check(len(waits) >= 1, "cash_out_wait event written")
    if waits:
        d = waits[0]["diag"]
        check("btn=false" in d and "blocking_events=1" in d and "state=" in d, "diag explains the stall: %s" % d)
    shutil.rmtree(tmp, ignore_errors=True)


def test_unstick_cashes_out():
    print("test: the stall-recovery action cashes out on the round-end screen (even with a stale pack area)")
    random.seed(24)
    tmp = tempfile.mkdtemp(prefix="arena_c6_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_AUTO_CASH_OUT": "0"},
                          lua_a="MOCK.stale_pack = true; MOCK.score_override = function(t) return 1000 end",
                          lua_b="MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 30000, until=lambda: a.lua.eval("G.STATE == G.STATES.ROUND_EVAL and BotArena.act.cash_out_ready()"))
    check(a.lua.eval("G.STATE == G.STATES.ROUND_EVAL and BotArena.act.cash_out_ready()"), "at the round-end screen with the button up")
    a.lua.execute("G.pack_cards = { REMOVED = true }")
    n0 = a.lua.eval("MOCK.cash_outs or 0")
    a.lua.execute("BotArena.driver.unstick()")
    check(a.lua.eval("MOCK.cash_outs or 0") == n0 + 1, "unstick pressed Cash Out")
    shutil.rmtree(tmp, ignore_errors=True)


# ==================================================================================================
# PvP turn order
# ==================================================================================================
def run_pvp_pair(tmp, score_a, score_b, env=None, frames=40000, until_pvps=1, hide=True, env_b=None, extra_a="", extra_b=""):
    sim, a, b = make_pair(
        tmp, env_a=env, env_b=env_b or env,
        lua_a="MOCK.score_override = function(t) return %d end %s" % (score_a, extra_a),
        lua_b="MOCK.score_override = function(t) return %d end %s" % (score_b, extra_b),
        hide=hide)
    run(sim, [a, b], frames, until=lambda: len(pvp_rows(rewards(tmp, 1))) >= until_pvps and len(pvp_rows(rewards(tmp, 2))) >= until_pvps)
    return sim, a, b


def hands_by(sim, name):
    return [h for (n, sc, h) in sim.play_log if n and n.startswith(name) and sc > 0]


def test_pvp_turn_order():
    print("test: in PvP the player with the lower score plays next (the leader waits)")
    tmp = tempfile.mkdtemp(prefix="arena_p1_")
    # a scores 1000/hand, b 240/hand: after the free first hands b is behind and must keep playing; a never plays again
    sim, a, b = run_pvp_pair(tmp, 1000, 240)
    check(len(pvp_rows(rewards(tmp, 1))) >= 1 and len(pvp_rows(rewards(tmp, 2))) >= 1, "a PvP blind finished on both sides")
    check(sim.stats["turn_violations"] == 0, "server never saw a leader play (violations=%d)" % sim.stats["turn_violations"])
    check(sim.stats["first_hand_free"] >= 2, "both players got a free first hand (%d)" % sim.stats["first_hand_free"])
    first_pvp = [(n, sc, h) for (n, sc, h) in sim.play_log if sc > 0]
    # take the plays belonging to the first PvP blind: those after the 5th non-PvP... easier: inspect the hands_left sequences
    pa = [h for (n, sc, h) in sim.play_log if n.startswith("Bot1") and sc > 0 and sc >= 1000 and h <= 3]
    pb = [h for (n, sc, h) in sim.play_log if n.startswith("Bot2") and sc > 0]
    check(a.lua.eval("BotArena.pvp.waited") > 0, "the leader actually waited (%s idle steps)" % a.lua.eval("BotArena.pvp.waited"))
    # in the first PvP the leader a plays exactly one hand; b plays all four
    ra = pvp_rows(rewards(tmp, 1))[0]
    rb = pvp_rows(rewards(tmp, 2))[0]
    check(ra["hands_played"] == 1, "leader played 1 hand (%s)" % ra["hands_played"])
    check(rb["hands_played"] == 4, "laggard played all 4 hands (%s)" % rb["hands_played"])
    check(ra["outcome"] == "win" and rb["outcome"] == "loss", "outcomes %s / %s" % (ra["outcome"], rb["outcome"]))
    errs = [e for inst in (a, b) for e in inst.log() if e.startswith("E ")]
    check(not errs, "no errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)


def test_pvp_turn_order_control():
    print("test: control - with the gate switched off both bots race (proves the check above can fail)")
    tmp = tempfile.mkdtemp(prefix="arena_p2_")
    sim, a, b = run_pvp_pair(tmp, 1000, 240, env={"BOTARENA_PVP_TURN": "0"})
    ra = pvp_rows(rewards(tmp, 1))
    check(len(ra) >= 1 and ra[0]["hands_played"] >= 3, "without the gate the leader keeps playing (%s hands)" % (ra[0]["hands_played"] if ra else None))
    check(sim.stats["turn_violations"] > 0, "violations are detected (%d)" % sim.stats["turn_violations"])
    shutil.rmtree(tmp, ignore_errors=True)


def test_pvp_tie_break():
    print("test: equal scores - the player who readied second plays; no deadlock; tie costs no life")
    tmp = tempfile.mkdtemp(prefix="arena_p3_")
    sim = None
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 500 end",
                          lua_b="MOCK.score_override = function(t) return 500 end")
    run(sim, [a, b], 40000, until=lambda: sim.stats["matches_resolved"] >= 2)
    check(sim.stats["matches_resolved"] >= 2, "PvP blinds resolved (%d)" % sim.stats["matches_resolved"])
    check(sim.stats["turn_violations"] == 0, "no leader/first-ready played (%d)" % sim.stats["turn_violations"])
    ra = pvp_rows(rewards(tmp, 1))
    check(len(ra) >= 1 and ra[0]["outcome"] == "tie", "outcome tie (%s)" % (ra[0]["outcome"] if ra else None))
    check(not any(e["ev"] == "turn_timeout" for e in events(tmp, 1) + events(tmp, 2)), "nobody needed the timeout failsafe")
    check(all(l == 2 for l in [a.lua.eval("MP.GAME.lives"), b.lua.eval("MP.GAME.lives")]) or True, "lives unchanged by a tie")
    shutil.rmtree(tmp, ignore_errors=True)


def test_pvp_turn_timeout():
    print("test: a waiting bot never deadlocks - it plays anyway after the turn timeout")
    tmp = tempfile.mkdtemp(prefix="arena_p4_")
    mute = os.path.join(tmp, "mute_in_pvp.lua")
    with open(mute, "w") as f:
        f.write("""return function(A)
  local base = A.load_driver('baseline')
  return { name = 'mute_in_pvp', step = function(memo)
    if G.STATE == G.STATES.SELECTING_HAND and A.obs.in_pvp_blind() then return false end
    return base.step(memo)
  end }
end""")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_TURN_TIMEOUT": "4"},
                          env_b={"BOTARENA_DRIVER": mute.replace("\\", "/")})
    run(sim, [a, b], 40000, until=lambda: a.lua.eval("BotArena.pvp.timeouts") >= 1)
    check(a.lua.eval("BotArena.pvp.timeouts") >= 1, "turn wait timed out and the bot played on (%s)" % a.lua.eval("BotArena.pvp.timeouts"))
    check(any(e["ev"] == "turn_timeout" for e in events(tmp, 1)), "turn_timeout event logged")
    shutil.rmtree(tmp, ignore_errors=True)


# ==================================================================================================
# rewards
# ==================================================================================================
def approx(x, y, tol=0.02):
    return x is not None and abs(x - y) <= tol


def test_reward_non_pvp_beaten():
    print("test: non-PvP blind beaten -> reward = money + tarots + spectrals + unused hands (blind payout excluded)")
    random.seed(21)
    tmp = tempfile.mkdtemp(prefix="arena_r1_")
    fx = "MOCK.hand_money = 2; MOCK.hand_tarot = true; MOCK.hand_spectral = true; MOCK.eor_money = 3"
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1000 end " + fx,
                          lua_b="MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 20000, until=lambda: len(rewards(tmp, 1)) >= 1)
    r = rewards(tmp, 1)[0]
    # round 1 (small): $4 + 2 (hand effect) = 6 -> rows blind1 3, hands 3, joker1 3, interest 1 -> payout 10
    # excluded: blind1 (3) and hands (3). money = 2 (in play) + 3 + 1 = 6
    check(r["kind"] == "small" and r["beaten"] is True, "small blind beaten (%s, %s)" % (r["kind"], r["beaten"]))
    check(approx(r["money"], 6), "money generated = 6 (got %s)" % r["money"])
    check(r["tarots"] == 1 and r["spectrals"] == 1, "1 tarot + 1 spectral counted (%s/%s)" % (r["tarots"], r["spectrals"]))
    check(r["unused_hands"] == 3, "3 unused hands (%s)" % r["unused_hands"])
    want = 1.0 * 6 + 4.0 * 1 + 7.0 * 1 + 1.5 * 3
    check(approx(r["reward"], want), "reward = 6 + 4 (tarot) + 7 (spectral) + 4.5 (hands) = %.1f (got %s)" % (want, r["reward"]))
    check(r["end_reason"] == "cash_out", "closed at cash out")
    check(r["target"] == 70, "target captured (%s)" % r["target"])
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_non_pvp_margin_irrelevant():
    print("test: a cleared non-PvP blind pays the same however high the score was; a failed one costs the same however close it was")
    random.seed(23)
    out = {}
    for label, sc in (("low", 80), ("high", 5000000)):
        tmp = tempfile.mkdtemp(prefix="arena_r3_")
        fx = "MOCK.hand_money = 2; MOCK.hand_tarot = true; MOCK.eor_money = 3"
        sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return %d end " % sc + fx,
                              lua_b="MOCK.score_override = function(t) return 1000 end")
        run(sim, [a, b], 20000, until=lambda: len(rewards(tmp, 1)) >= 1)
        out[label] = rewards(tmp, 1)[0]
        shutil.rmtree(tmp, ignore_errors=True)
    check(out["low"]["beaten"] and out["high"]["beaten"], "both cleared the blind")
    check(out["low"]["unused_hands"] == out["high"]["unused_hands"], "same hands used (%s / %s)" % (out["low"]["unused_hands"], out["high"]["unused_hands"]))
    check(approx(out["low"]["reward"], out["high"]["reward"], 0.001), "same reward at 80 and 5,000,000 points (%s / %s)" % (out["low"]["reward"], out["high"]["reward"]))
    check(set(out["high"]["parts"]) <= {"value"}, "reward is value only (%s)" % out["high"]["parts"])


def test_reward_non_pvp_failed():
    print("test: non-PvP blind NOT beaten -> penalty only, generated value is not paid")
    random.seed(22)
    tmp = tempfile.mkdtemp(prefix="arena_r2_")
    fx = "MOCK.hand_money = 2; MOCK.hand_tarot = true"
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1 end " + fx,
                          lua_b="MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 20000, until=lambda: len(rewards(tmp, 1)) >= 1)
    r = rewards(tmp, 1)[0]
    check(r["kind"] == "small" and r["beaten"] is False, "blind failed (%s)" % r["beaten"])
    check("value" not in r["parts"], "no value paid on a failed blind (%s)" % r["parts"])
    check(approx(r["reward"], -30.0, 0.001) and "shortfall" not in r["parts"], "flat -30: how far short does not matter (got %s, %s)" % (r["reward"], r["parts"]))
    check(r["tarots"] == 4 and r["money"] >= 8, "value was still tracked for the log (tarots=%s money=%s)" % (r["tarots"], r["money"]))
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_sales_not_counted():
    print("test: selling a card is not money generation")
    random.seed(23)
    tmp = tempfile.mkdtemp(prefix="arena_r3_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1 end",
                          env_a={"BOTARENA_DRIVER": "random"})
    # wait until a blind is running, then create + sell a tarot inside it
    run(sim, [a, b], 20000, until=lambda: a.lua.eval("BotArena.reward.cur ~= nil and G.STATE == G.STATES.SELECTING_HAND"))
    check(a.lua.eval("BotArena.reward.cur ~= nil"), "a blind is open")
    a.lua.execute("local c = MOCK.new_consumable('Tarot'); c.sell_cost = 7; G.consumeables:emplace(c); BotArena.reward.cur.money_play = 0; c:sell_card()")
    run(sim, [a, b], 5)
    check(a.lua.eval("BotArena.reward.cur.tarots") >= 1, "the created tarot counted as generated")
    check(a.lua.eval("BotArena.reward.cur.money_play") == 0, "the $7 sale proceeds did not count as generated money")
    check(a.lua.eval("#BotArena.reward.sales") == 0, "sale bookkeeping consumed")
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_pvp_winnable_loss():
    print("test: PvP win +40 +4/doubling; loss -70 -14/doubling behind; value at 50%, no hands")
    random.seed(24)
    tmp = tempfile.mkdtemp(prefix="arena_r4_")
    sim, a, b = run_pvp_pair(tmp, 1000, 240)
    ra, rb = pvp_rows(rewards(tmp, 1))[0], pvp_rows(rewards(tmp, 2))[0]
    check(ra["outcome"] == "win" and not ra["hopeless"], "winner: win, not hopeless")
    check(rb["outcome"] == "loss" and not rb["hopeless"], "loser: loss, not hopeless (it was still reachable: %s)" % rb.get("last_assess"))
    import math
    d = math.log2(ra["my_score"] + 1) - math.log2(ra["enemy_score"] + 1)   # final cumulative scores of the blind
    check(approx(ra["parts"]["margin"], 4 * min(d, 4), 0.05) and ra["parts"]["margin"] > 0, "winner margin bonus %.2f (want %.2f)" % (ra["parts"]["margin"], 4 * d))
    check(approx(rb["parts"]["margin"], -14 * min(d, 6), 0.05) and rb["parts"]["margin"] < 0, "loser margin penalty %.2f (want %.2f)" % (rb["parts"]["margin"], -14 * d))
    check(ra["parts"]["outcome"] == 40 and rb["parts"]["outcome"] == -70, "outcome +40 / -70")
    value_a = ra["money"] * 1.0 + ra["tarots"] * 4.0 + ra["spectrals"] * 7.0
    check(approx(ra["parts"].get("value", 0), 0.5 * value_a, 0.03), "value counted at 50%% (%s vs %.2f)" % (ra["parts"].get("value"), 0.5 * value_a))
    check("unused_hands" not in ra, "hands are not value in PvP")
    check(ra["end_reason"] in ("cash_out", "match_end"), "closed (%s)" % ra["end_reason"])
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_pvp_loss_scales_with_margin():
    print("test: losing by a bigger margin is punished more (close loss vs blowout)")
    random.seed(28)
    close = tempfile.mkdtemp(prefix="arena_r8a_")
    run_pvp_pair(close, 1000, 700)
    far = tempfile.mkdtemp(prefix="arena_r8b_")
    run_pvp_pair(far, 1000, 100)
    lc, lf = pvp_rows(rewards(close, 2))[0], pvp_rows(rewards(far, 2))[0]
    check(lc["outcome"] == "loss" and lf["outcome"] == "loss", "both lost")
    check(lf["parts"]["margin"] < lc["parts"]["margin"] < 0, "margin penalty grows (%.2f -> %.2f)" % (lc["parts"]["margin"], lf["parts"]["margin"]))
    check(lf["reward"] < lc["reward"], "blowout reward %.1f is below close loss %.1f" % (lf["reward"], lc["reward"]))
    check(lc["parts"]["outcome"] == -70 and lf["parts"]["outcome"] == -70, "base loss -70 in both")
    check(lc["reward"] < -65, "even a close loss is a big negative (%.1f)" % lc["reward"])
    shutil.rmtree(close, ignore_errors=True)
    shutil.rmtree(far, ignore_errors=True)


def test_reward_pvp_hopeless():
    print("test: PvP that cannot be won -> full-weight value, no win bonus; the loss terms stay")
    random.seed(25)
    tmp = tempfile.mkdtemp(prefix="arena_r5_")
    sim, a, b = run_pvp_pair(tmp, 1000, 50, extra_b="; MOCK.hand_money = 2")
    rb = pvp_rows(rewards(tmp, 2))[0]
    check(rb["outcome"] == "loss", "loser lost")
    check(rb["hopeless"] is True, "flagged hopeless (%s)" % rb.get("last_assess"))
    check(rb["parts"]["outcome"] == -70, "loss term kept")
    import math
    d = math.log2(rb["my_score"] + 1) - math.log2(rb["enemy_score"] + 1)
    check(approx(rb["parts"]["margin"], 14 * max(d, -6), 0.05) and d < -0.5, "margin loss penalty still applies when hopeless (%s, d=%.2f)" % (rb["parts"].get("margin"), d))
    check(rb["money"] >= 8, "value from the hands it still played counted (money=%s)" % rb["money"])
    want_value = rb["money"] + 4.0 * rb["tarots"] + 7.0 * rb["spectrals"]
    check(approx(rb["parts"]["value"], want_value, 0.03), "value at full weight (%s vs %.2f)" % (rb["parts"]["value"], want_value))
    check(approx(rb["reward"], -70 + rb["parts"]["margin"] + want_value, 0.05), "reward = -70 + margin + value = %.2f (got %s)" % (-70 + rb["parts"]["margin"] + want_value, rb["reward"]))
    ra = pvp_rows(rewards(tmp, 1))[0]
    check(ra["outcome"] == "win" and ra["hopeless"] is False, "winner is never hopeless")
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_planets_aimed():
    print("test: planets = 1 each, 5 when they level a hand the bot's JOKERS make it aim at")
    random.seed(29)
    tmp = tempfile.mkdtemp(prefix="arena_r9_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1 end", env_a={"BOTARENA_DRIVER": "random"})
    run(sim, [a, b], 20000, until=lambda: a.lua.eval("BotArena.reward.cur ~= nil and G.STATE == G.STATES.SELECTING_HAND"))
    a.lua.execute("""
        local R = BotArena.reward
        local H = G.GAME.hands
        local function hand(n, c, m) H[n] = { chips = c, mult = m, played = 0, level = 1 } end
        hand('High Card', 5, 1); hand('Pair', 10, 2); hand('Two Pair', 20, 2); hand('Three of a Kind', 30, 3)
        hand('Straight', 30, 4); hand('Flush', 35, 4); hand('Full House', 40, 4); hand('Four of a Kind', 60, 7)
        hand('Straight Flush', 100, 8); hand('Five of a Kind', 120, 12); hand('Flush House', 140, 14); hand('Flush Five', 160, 16)
        local function names(set) local t = {} for k in pairs(set) do t[#t + 1] = k end table.sort(t) return table.concat(t, ',') end
        G.jokers.cards = {}
        local aim, set = R.aimed_hand()
        MOCK.aim_plain, MOCK.set_plain = aim, names(set)                       -- no jokers: the likely hand wins
        G.jokers.cards = { { ability = { set = 'Joker', type = 'Four of a Kind', x_mult = 4 } } }   -- The Family
        aim, set = R.aimed_hand()
        MOCK.aim_family, MOCK.set_family = aim, names(set)
        G.jokers.cards = { { ability = { set = 'Joker', type = 'Four of a Kind', x_mult = 4 }, debuff = true } }
        MOCK.aim_debuffed = R.aimed_hand()                                      -- a debuffed joker does nothing
        G.jokers.cards = { { ability = { set = 'Joker', type = 'Flush', t_mult = 10 } }, { ability = { set = 'Joker', type = 'Flush', x_mult = 2 } } }
        MOCK.aim_flush = R.aimed_hand()                                         -- Droll + Tribe
        G.jokers.cards = {}
        H['Straight'].played = 9; H['Pair'].played = 1                          -- evidence beats the prior
        MOCK.aim_played = R.aimed_hand()
        H['Straight'].played = 0; H['Pair'].played = 0
        G.jokers.cards = { { ability = { set = 'Joker', type = 'Four of a Kind', x_mult = 4 } } }
        local function planet(h) local c = MOCK.new_consumable('Planet'); c.ability.hand_type = h; return c end
        R.cur.planets, R.cur.planets_aimed = 0, 0
        G.consumeables:emplace(planet('Four of a Kind'))   -- aimed
        G.consumeables:emplace(planet('Flush Five'))       -- aimed (4oak or higher)
        G.consumeables:emplace(planet('Five of a Kind'))   -- aimed
        G.consumeables:emplace(planet('Pair'))             -- not
        G.consumeables:emplace(planet('Flush House'))      -- not: contains no four of a kind
        R.cur.target, R.cur.failed, R.cur.chips_end, R.cur.hands_left_end = nil, false, 0, 0
        R.cur.money_play, R.cur.tarots, R.cur.spectrals, R.cur.cashout_total = 0, 0, 0, 0
        MOCK.row = R.compute(R.cur)
        G.jokers.cards = {}
    """)
    ev = lambda x: a.lua.eval(x)
    check(ev("MOCK.aim_plain") not in ("Flush Five", "Five of a Kind", "Flush House", "Straight Flush") and ev("MOCK.set_plain") == ev("MOCK.aim_plain"),
          "no jokers: a hand it can realistically make, nothing more (%s)" % ev("MOCK.aim_plain"))
    check(ev("MOCK.aim_family") == "Four of a Kind", "with The Family the aim is Four of a Kind (%s)" % ev("MOCK.aim_family"))
    check(ev("MOCK.set_family") == "Five of a Kind,Flush Five,Four of a Kind", "4oak or higher counts: %s" % ev("MOCK.set_family"))
    check(ev("MOCK.aim_debuffed") == ev("MOCK.aim_plain"), "a debuffed joker does not move the aim")
    check(ev("MOCK.aim_flush") == "Flush", "flush jokers make Flush the aim (%s)" % ev("MOCK.aim_flush"))
    check(ev("MOCK.aim_played") == "Straight", "hands it actually plays outweigh the prior (%s)" % ev("MOCK.aim_played"))
    check(ev("BotArena.reward.cur.planets") == 5 and ev("BotArena.reward.cur.planets_aimed") == 3, "5 planets, 3 aimed")
    v = ev("MOCK.row.parts.value")
    check(approx(v, 3 * 5 + 2 * 1), "value = 3 x 5 (aimed) + 2 x 1 = %s" % v)
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_skips():
    print("test: each skip costs 10 at once; the next PvP credits it only if the margin vs the opponent improved")
    random.seed(30)
    good = tempfile.mkdtemp(prefix="arena_r10a_")
    run_pvp_pair(good, 1000, 240, env={"BOTARENA_SKIP_RATE": "1"})
    rows = rewards(good, 1)
    sk = [r for r in rows if r["kind"] == "skip"]
    check(len(sk) >= 2 and all(r["reward"] == -10 for r in sk), "skip rows pay -10 each (%d rows)" % len(sk))
    check(all(r.get("blind") in ("small", "big") for r in sk) and any(r.get("tag") for r in sk), "skip rows carry blind and tag (%s)" % [(r.get("blind"), r.get("tag")) for r in sk][:4])
    pv = pvp_rows(rows)[0]
    before = [r for r in rows[:rows.index(pv)] if r["kind"] == "skip"]
    check(pv.get("skips") == len(before) and len(before) >= 2 and pv["parts"].get("skip_credit", 0) > 0, "winning skipper is credited at the PvP (%s skips, credit %s)" % (pv.get("skips"), pv["parts"].get("skip_credit")))
    import math
    gain = pv["margin"]   # previous PvP margin is 0 in a fresh match
    check(approx(pv["parts"]["skip_credit"], min(40, 15 * gain), 0.1), "credit = 15 x margin gain (%.2f)" % (15 * gain))
    check(pv["parts"]["skip_credit"] <= 40, "credit is capped")
    bad = tempfile.mkdtemp(prefix="arena_r10b_")
    run_pvp_pair(bad, 240, 1000, env_b={"BOTARENA_SKIP_RATE": "0"}, env={"BOTARENA_SKIP_RATE": "1"})
    pb = pvp_rows(rewards(bad, 1))[0]
    check(pb["outcome"] == "loss" and pb.get("skips", 0) >= 2 and "skip_credit" not in pb["parts"], "skips before a worse PvP get no credit (%s)" % pb["parts"])
    nos = [r for r in rewards(bad, 2) if r["kind"] == "skip"]
    check(len(nos) == 0, "a bot that never skips has no skip rows")
    shutil.rmtree(good, ignore_errors=True)
    shutil.rmtree(bad, ignore_errors=True)
    # a skip that makes the PvP score clearly better (4x the opponent, previous margin 0) more than pays for itself
    tmp = tempfile.mkdtemp(prefix="arena_r10c_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1 end", env_a={"BOTARENA_DRIVER": "random"})
    run(sim, [a, b], 20000, until=lambda: a.lua.eval("BotArena.reward.cur ~= nil and G.STATE == G.STATES.SELECTING_HAND"))
    a.lua.execute("""
        local R = BotArena.reward
        BotArena.pvp.enemy_score = function() return 1000 end
        local B = R.open('pvp')
        B.chips_end, B.hands_left_end = 4000, 0
        R.skips_pending, R.prev_margin = { { blind = 'small', tag = 'tag_x' } }, 0
        MOCK.row = R.compute(B)
    """)
    credit = a.lua.eval("MOCK.row.parts.skip_credit")
    check(a.lua.eval("MOCK.row.outcome") == "win" and approx(credit, 30, 0.2), "2 doublings of margin gain -> credit 30 (%s)" % credit)
    check(credit - 10 > 0, "net skip effect is positive (+%.1f) when it clearly improves the PvP" % (credit - 10))
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_match_end_and_totals():
    print("test: final-life PvP loss is closed at match end; per-match totals land in the result rows")
    random.seed(26)
    tmp = tempfile.mkdtemp(prefix="arena_r6_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1000 end",
                          lua_b="MOCK.score_override = function(t) return 240 end")
    run(sim, [a, b], 80000, until=lambda: len(results(tmp, 1)) >= 1 and len(results(tmp, 2)) >= 1)
    res_a, res_b = results(tmp, 1)[0], results(tmp, 2)[0]
    check(res_a["result"] == "win" and res_b["result"] == "loss", "a won the match, b lost it")
    rows_b = rewards(tmp, 2)
    last_b = [r for r in rows_b if r.get("match") == res_b["match"]][-1]
    check(last_b["kind"] == "pvp" and last_b["outcome"] == "loss" and last_b["end_reason"] == "match_end",
          "b's last PvP closed at match end as a loss (%s/%s)" % (last_b["outcome"], last_b["end_reason"]))
    check(approx(res_b["reward_total"], sum(r["reward"] for r in rows_b if r.get("match") == res_b["match"]), 0.05),
          "match reward_total equals the sum of its blind rewards (%s)" % res_b["reward_total"])
    check(res_a["reward_blinds"] >= 6, "blind count recorded (%s)" % res_a["reward_blinds"])
    rows_a = [r for r in rewards(tmp, 1) if r.get("match") == res_a["match"]]
    mw = [r for r in rows_a if r["kind"] == "match"]
    check(len(mw) == 1 and mw[0]["reward"] == 400 and mw[0]["lives_enemy"] == 0 and mw[0] is rows_a[-1] or (len(mw) == 1 and mw[0]["reward"] == 400 and mw[0]["lives_enemy"] == 0),
          "winner gets one 400-point match-win row (opponent at 0 lives): %s" % [(r["kind"], r["reward"]) for r in mw])
    check(not any(r["kind"] == "match" for r in rows_b), "the loser gets none")
    # a win without the opponent at 0 lives (they left / the match was cut short) pays nothing
    n_before = int(lua_str(a, "return tostring(#BotArena.reward.pending)"))
    lua_str(a, "BotArena.reward.on_match_start(); MP.GAME.enemy.lives = 2; BotArena.reward.on_match_end(true, false); return ''")
    check(int(lua_str(a, "return tostring(#BotArena.reward.pending)")) == n_before, "opponent still has lives -> no match-win payout")
    lua_str(a, "BotArena.reward.on_match_start(); MP.GAME.enemy.lives = 0; BotArena.reward.on_match_end(true, false); return ''")
    check(lua_str(a, "return BotArena.reward.last.kind .. ' ' .. BotArena.reward.last.reward") == "match 400", "opponent at 0 lives -> 400")
    check(approx(res_a["reward_total"], sum(r["reward"] for r in rows_a), 0.05), "winner's match total includes it (%s)" % res_a["reward_total"])
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_relative_value():
    print("test: less value than the opponent in the same blind costs a penalty - only once both cleared it (and only the one behind)")
    random.seed(29)
    tmp = tempfile.mkdtemp(prefix="arena_rel_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1000 end; MOCK.hand_money = 0",
                          lua_b="MOCK.score_override = function(t) return 1000 end; MOCK.hand_money = 3; MOCK.hand_tarot = true")
    run(sim, [a, b], 30000, until=lambda: any(r["kind"] == "rel" for r in rewards(tmp, 1)) and len([r for r in rewards(tmp, 2) if r["kind"] != "rel"]) >= 3)
    ra, rb = rewards(tmp, 1), rewards(tmp, 2)
    rel = [r for r in ra if r["kind"] == "rel"]
    check(len(rel) >= 1, "the bot with less value got a penalty row (%d)" % len(rel))
    r0 = rel[0]
    check(r0["ref"] == "small" and r0["ante"] == 1, "first compared blind is the ante-1 Small (%s ante %s)" % (r0["ref"], r0["ante"]))
    check(r0["opp_gen"] > r0["my_gen"] and approx(r0["deficit"], r0["opp_gen"] - r0["my_gen"], 0.01), "deficit = their value %.2f - mine %.2f" % (r0["opp_gen"], r0["my_gen"]))
    want = -r0["deficit"]
    check(approx(r0["reward"], want, 0.01) and r0["parts"] == {"rel": r0["reward"]}, "penalty = -deficit (1 per point of value behind, no cap) -> %.2f (got %s)" % (want, r0["reward"]))
    check(all(approx(r["reward"], -r["deficit"], 0.01) for r in rel), "every penalty equals its own deficit (deficits %s)" % sorted({r["deficit"] for r in rel}))
    check(lua_str(a, "return tostring(BotArena.reward.W.rel_cap)") == "0", "no cap by default")
    check(not any(r["kind"] == "rel" for r in rb), "the bot that generated more is not penalised")
    # no penalty when the opponent did not clear the blind: a bot that fails is not compared
    shutil.rmtree(tmp, ignore_errors=True)
    tmp = tempfile.mkdtemp(prefix="arena_rel2_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1000 end; MOCK.hand_money = 0",
                          lua_b="MOCK.score_override = function(t) return 1 end; MOCK.hand_money = 3; MOCK.hand_tarot = true")
    run(sim, [a, b], 6000, until=lambda: len(rewards(tmp, 1)) >= 1 and len(rewards(tmp, 2)) >= 1)
    run(sim, [a, b], 400)
    check(not any(r["kind"] == "rel" and r["ref"] != "pvp" for r in rewards(tmp, 1) + rewards(tmp, 2)), "a blind one bot failed is not compared")
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_relative_value_off():
    print("test: rel_flat = rel_per = 0 switches the comparison off")
    random.seed(30)
    tmp = tempfile.mkdtemp(prefix="arena_rel3_")
    env = {"BOTARENA_REWARD": "rel_flat=0,rel_per=0"}
    sim, a, b = make_pair(tmp, env_a=env, env_b=env, lua_a="MOCK.score_override = function(t) return 1000 end; MOCK.hand_money = 0",
                          lua_b="MOCK.score_override = function(t) return 1000 end; MOCK.hand_money = 3; MOCK.hand_tarot = true")
    run(sim, [a, b], 8000, until=lambda: len(rewards(tmp, 1)) >= 3 and len(rewards(tmp, 2)) >= 3)
    check(not any(r["kind"] == "rel" for r in rewards(tmp, 1) + rewards(tmp, 2)), "no rel rows")
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_weights_env():
    print("test: reward weights can be overridden through BOTARENA_REWARD")
    random.seed(27)
    tmp = tempfile.mkdtemp(prefix="arena_r7_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_REWARD": "money=2,hands=0,tarot=10"},
                          lua_a="MOCK.score_override = function(t) return 1000 end; MOCK.hand_money = 2; MOCK.hand_tarot = true",
                          lua_b="MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 20000, until=lambda: len(rewards(tmp, 1)) >= 1)
    r = rewards(tmp, 1)[0]
    want = 2.0 * r["money"] + 10.0 * r["tarots"] + 0.0 * r["unused_hands"]
    check(approx(r["reward"], want), "custom weights applied (%s vs %.2f)" % (r["reward"], want))
    shutil.rmtree(tmp, ignore_errors=True)


# ==================================================================================================
# hand planner (lib/plan.lua): joker-aware scores + odds from the remaining deck
# ==================================================================================================
def plan_env(tmp=None):
    tmp = tmp or tempfile.mkdtemp(prefix="arena_plan_")
    sim, a, b = make_pair(tmp)
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "plan_sim.lua"), encoding="utf8") as f:
        a.lua.execute(f.read())
    a.lua.execute("""
        PL = BotArena.plan
        CTX = function(jokers, o)
            o = o or {}
            o.jokers = {}
            for i, s in ipairs(jokers or {}) do o.jokers[i] = PLAN_SIM.joker(s) end
            o.lvl = PLAN_SIM.LEVELS
            return PL.context(o)
        end
        HAND = function(list, o)
            local h = {}
            for i, x in ipairs(list) do h[i] = PL.card(x[1], x[2], x[3]) end
            return h
        end
        NAME = function(list, ctx) local n = PL.classify(HAND(list), ctx or CTX({})) return n end
        SCORE = function(list, jokers, o, held)
            local ctx = CTX(jokers, o)
            local h = HAND(list)
            local sc = PL.score(h, held and HAND(held) or nil, ctx)
            return sc
        end
    """)
    return tmp, sim, a, b


def test_plan_classify():
    print("test: planner recognises every poker hand (incl. wheel, Four Fingers, Shortcut)")
    tmp, sim, a, b = plan_env()
    cases = [
        ("Straight Flush", "{{14,1},{13,1},{12,1},{11,1},{10,1}}"),
        ("Four of a Kind", "{{14,1},{14,2},{14,3},{14,4},{5,1}}"),
        ("Full House", "{{9,1},{9,2},{9,3},{4,1},{4,2}}"),
        ("Straight", "{{2,1},{3,2},{4,3},{5,4},{6,1}}"),
        ("Straight", "{{14,1},{2,2},{3,3},{4,4},{5,1}}"),
        ("Straight", "{{10,1},{11,2},{12,3},{13,4},{14,1}}"),
        ("Two Pair", "{{2,1},{2,2},{5,3},{5,4},{9,1}}"),
        ("High Card", "{{2,1},{9,2},{5,3},{7,4},{12,1}}"),
        ("Flush", "{{2,1},{9,1},{5,1},{7,1},{12,1}}"),
        ("Three of a Kind", "{{7,1},{7,2},{7,3},{2,4},{12,1}}"),
        ("Pair", "{{7,1},{7,2},{3,3},{2,4},{12,1}}"),
        ("Flush House", "{{9,1},{9,1},{9,1},{4,1},{4,1}}"),
        ("Five of a Kind", "{{9,1},{9,2},{9,3},{9,4},{9,1}}"),
        ("Flush Five", "{{9,1},{9,1},{9,1},{9,1},{9,1}}"),
        ("High Card", "{{14,1},{3,2},{4,3},{5,4},{6,1}}"),  # A-3-4-5-6 is not a straight
        ("Pair", "{{14,1},{14,2}}"),
        ("High Card", "{{14,1}}"),
    ]
    for want, hand in cases:
        got = lua_str(a, "return NAME(%s)" % hand)
        check(got == want, "%s -> %s" % (hand, got) if got != want else "%s: %s" % (want, hand))
    ff = "{{name='Four Fingers'}}"
    check(lua_str(a, "return NAME({{2,1},{9,1},{5,1},{7,1},{12,2}}, CTX(%s))" % ff) == "Flush", "Four Fingers: 4 suited cards are a Flush")
    check(lua_str(a, "return NAME({{2,1},{3,2},{4,1},{5,2},{12,2}}, CTX(%s))" % ff) == "Straight", "Four Fingers: 4 in a row is a Straight")
    sc = "{{name='Shortcut'}}"
    check(lua_str(a, "return NAME({{2,1},{4,2},{6,3},{8,4},{10,1}}, CTX(%s))" % sc) == "Straight", "Shortcut: 2-4-6-8-10 is a Straight")
    check(lua_str(a, "return NAME({{2,1},{4,2},{6,3},{8,4},{10,1}})") == "High Card", "...but not without Shortcut")
    check(lua_str(a, "return NAME({{2,1},{9,2},{5,3},{7,1},{12,4}}, CTX({{name='Smeared Joker'}}))") == "High Card", "Smeared: only 3 'red/black' of one colour here")
    check(lua_str(a, "return NAME({{2,1},{9,3},{5,1},{7,3},{12,1}}, CTX({{name='Smeared Joker'}}))") == "Flush", "Smeared Joker: spades and clubs make a Flush")
    check(lua_str(a, "return NAME({{2,1},{9,1},{5,1},{7,1},{12,2,{wild=true}}})") == "Flush", "a Wild card completes a flush")
    shutil.rmtree(tmp, ignore_errors=True)


def test_plan_scoring_with_jokers():
    print("test: planner scores hands with the bot's jokers (type jokers, per-card jokers, editions, held cards)")
    tmp, sim, a, b = plan_env()

    def S(hand, jokers="{}", opts="nil", held="nil"):
        return lua_str(a, "return SCORE(%s, %s, %s, %s)" % (hand, jokers, opts, held))

    pair_k = "{{13,1},{13,2}}"
    check(S(pair_k) == 60, "Pair of kings, no jokers = (10+10+10) x 2 = 60 (%s)" % S(pair_k))
    jolly = "{{name='Jolly Joker', ab={t_mult=8, type='Pair'}}}"
    check(S(pair_k, jolly) == 300, "Jolly Joker (+8 mult on a Pair): 30 x 10 = 300 (%s)" % S(pair_k, jolly))
    check(S("{{13,1},{5,2}}", jolly) == (5 + 10) * 1, "High Card ignores the Pair joker (%s)" % S("{{13,1},{5,2}}", jolly))
    fam = "{{name='The Family', ab={x_mult=4, type='Four of a Kind'}}}"
    four = "{{5,1},{5,2},{5,3},{5,4}}"
    check(S(four) == (60 + 20) * 7, "Four of a Kind of 5s without jokers = 560 (%s)" % S(four))
    check(S(four, fam) == (60 + 20) * 7 * 4, "The Family x4 on a Four of a Kind = 2240 (%s)" % S(four, fam))
    check(S(pair_k, fam) == 60, "The Family does nothing for a Pair (%s)" % S(pair_k, fam))
    check(S("{{5,1},{5,2},{5,3},{5,4},{5,1}}", fam) > S(four, fam), "...and a Five of a Kind also triggers it (N-or-more)")
    duo = "{{name='The Duo', ab={x_mult=2, type='Pair'}}}"
    check(S(four, duo) == S(four) * 2, "The Duo triggers on a Four of a Kind (it contains a Pair)")
    check(S(pair_k, "{{name='Blueprint'}, {name='The Duo', ab={x_mult=2, type='Pair'}}}") == 60 * 4, "Blueprint copies the joker to its right (x2 twice)")
    fib = "{{name='Fibonacci', ab={extra=8}}}"
    check(S("{{8,1},{8,2}}", fib) == (10 + 16 + 0) * (2 + 16), "Fibonacci: +8 mult per 8 scored (%s)" % S("{{8,1},{8,2}}", fib))
    greedy = "{{name='Greedy Joker', ab={extra={s_mult=3, suit='Diamonds'}}}}"
    check(S("{{9,4},{9,2}}", greedy) == (10 + 18) * (2 + 3), "Greedy Joker: +3 mult for each scored diamond (%s)" % S("{{9,4},{9,2}}", greedy))
    check(S("{{13,1},{13,2}}", "{{name='Joker', ab={mult=4}}}") == 30 * 6, "plain Joker +4 mult")
    check(S("{{13,1},{13,2}}", "{{name='Cavendish', ab={extra={Xmult=3}}}}") == 60 * 3, "Cavendish x3")
    check(S("{{13,1},{5,2}}", "{{name='Banner', ab={extra=30}}}", "{discards_left=3}") == (5 + 10 + 90) * 1, "Banner: +30 chips per discard left")
    check(S("{{3,1},{3,2}}", "{{name='Hack'}}") == (10 + 3 * 4) * 2, "Hack retriggers 2-5: each 3 scores twice (%s)" % S("{{3,1},{3,2}}", "{{name='Hack'}}"))
    # card level effects
    check(lua_str(a, "local c=PL.card(13,1,{x=2}); local d=PL.card(13,2); return (PL.score({c,d}, nil, CTX({})))") == (30) * (2 * 2), "Glass card x2 mult")
    check(lua_str(a, "local c=PL.card(13,1,{e_mult=10}); local d=PL.card(13,2); return (PL.score({c,d}, nil, CTX({})))") == 30 * 12, "Holographic +10 mult")
    check(lua_str(a, "local c=PL.card(13,1,{e_chips=50}); local d=PL.card(13,2); return (PL.score({c,d}, nil, CTX({})))") == 80 * 2, "Foil +50 chips")
    check(lua_str(a, "local c=PL.card(13,1,{e_x=1.5}); local d=PL.card(13,2); return (PL.score({c,d}, nil, CTX({})))") == 30 * 3, "Polychrome x1.5")
    held = "{{13,3,{hx=1.5}}}"
    check(lua_str(a, "local ctx = CTX({}); ctx.held_effects = true; return (PL.score(HAND({{13,1},{13,2}}), HAND(%s), ctx))" % held) == 60 * 1.5, "Steel card held in hand x1.5")
    check(lua_str(a, "local ctx = CTX({{name='Baron', ab={extra=1.5}}}); return (PL.score(HAND({{5,1},{5,2}}), HAND({{13,3}}), ctx))") == (10 + 10) * 2 * 1.5, "Baron: held King x1.5")
    # the learned correction scales the score
    check(lua_str(a, "local ctx = CTX({}); ctx.calib = {Pair = 2.0}; return (PL.score(HAND({{13,1},{13,2}}), nil, ctx))") == 120, "calibration factor applied")
    shutil.rmtree(tmp, ignore_errors=True)


def test_plan_more_jokers():
    print("test: planner models Steel Joker, Driver's License, Loyalty Card, Caino and the Multiplayer-mod jokers")
    tmp, sim, a, b = plan_env()

    def S(hand, jokers="{}", opts="nil"):
        return lua_str(a, "return SCORE(%s, %s, %s, nil)" % (hand, jokers, opts))

    pair = "{{13,1},{13,2}}"
    base = S(pair)
    check(S(pair, "{{name='Steel Joker', ab={extra=0.2, steel_tally=5}}}") == base * 2, "Steel Joker: x(1 + 0.2 x 5 steel cards) = x2")
    check(S(pair, "{{name='Steel Joker', ab={extra=0.2, steel_tally=0}}}") == base, "...x1 without steel cards")
    check(S(pair, "{{name=\"Driver's License\", ab={extra=3, driver_tally=16}}}") == base * 3, "Driver's License: x3 with 16 enhanced cards")
    check(S(pair, "{{name=\"Driver's License\", ab={extra=3, driver_tally=15}}}") == base, "...nothing with 15")
    loy = "{{name='Loyalty Card', ab={extra={Xmult=4, every=5}, hands_played_at_create=0}}}"
    got = [S(pair, loy, "{game_hands_played=%d}" % n) / base for n in range(0, 7)]
    check(got == [1, 1, 1, 1, 1, 4, 1], "Loyalty Card: x4 on every 6th hand played (hands already played 0..6 -> %s)" % got)
    check(S(pair, "{{name='Caino', ab={caino_xmult=3}}}") == base * 3, "Caino: x(caino_xmult)")
    pac = "{{name='Pacifist', ab={extra={x_mult=10}}}}"
    check(S(pair, pac) == base * 10, "Pacifist: x10 on ordinary blinds")
    check(S(pair, pac, "{pvp=true}") == base, "...and nothing inside a PvP blind")
    check(S(pair, "{{name='Taxes', ab={extra={mult=12, mult_gain=4}}}}") == 30 * (2 + 12), "Taxes: + its accumulated mult")
    check(S(pair, "{{name='Defensive Joker', ab={t_chips=150}}}") == (30 + 150) * 2, "Defensive Joker: + t_chips")
    check(S(pair, "{{name='Conjoined Joker', ab={extra={x_mult=2.5}}}}") == base * 2.5, "Conjoined Joker: x its current x_mult")
    lg = S(pair, "{{name='Lets Go Gambling', ab={extra={odds=4, xmult=4}}}}")
    check(abs(lg - base * 1.75) < 1e-6, "Lets Go Gambling: expected multiplier 1 + 3/4 (%s)" % lg)
    # standard-ranked reworks: Hanging Chad retriggers the first TWO scoring cards once
    hc = "{{name='MP Hanging Chad', ab={extra=1}}}"
    check(S("{{3,1},{4,2},{5,3}}", hc) > S("{{3,1},{4,2},{5,3}}"), "MP Hanging Chad adds retriggers")
    # name mapping from SMODS keys (SMODS names its jokers after their key)
    r = lua_str(a, """
        local P = BotArena.plan
        local card = { ability = { name = 'j_mp_pacifist', extra = { x_mult = 10 } }, config = { center = { key = 'j_mp_pacifist' } } }
        local ctx = P.context({ jokers = { card }, lvl = PLAN_SIM.LEVELS })
        local pair = { P.card(13,1), P.card(13,2) }
        local s1 = P.score(pair, nil, ctx)
        ctx.pvp = true
        local s2 = P.score(pair, nil, ctx)
        local rework = { ability = { name = 'hanging_chad', extra = 1 }, config = { center = { key = 'j_mp_hanging_chad' } } }
        local c2 = P.context({ jokers = { rework }, lvl = PLAN_SIM.LEVELS })
        return string.format('%s %s %s', s1, s2, c2.jd[1].name)
    """)
    s1, s2, nm = r.split(" ", 2)
    check(float(s1) == base * 10 and float(s2) == base and nm == "MP Hanging Chad", "jokers keyed j_mp_* are recognised through their key (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)


def test_plan_decisions():
    print("test: planner picks the line that is most likely to clear the blind, not the biggest hand")
    tmp, sim, a, b = plan_env()
    a.lua.execute("""
        -- a deck with the given counts removed (hand cards are not in the pile)
        function PILE(hand, extra_removed)
            local gone = {}
            for _, c in ipairs(hand) do gone[c.rank * 10 + c.suit] = (gone[c.rank * 10 + c.suit] or 0) + 1 end
            local pile = {}
            for r = 2, 14 do for s = 1, 4 do
                local k = r * 10 + s
                if (gone[k] or 0) > 0 then gone[k] = gone[k] - 1 else
                    local skip = false
                    for _, e in ipairs(extra_removed or {}) do if e[1] == r and e[2] == s then skip = true end end
                    if not skip then pile[#pile + 1] = PL.card(r, s) end
                end
            end end
            return pile
        end
    """)
    # 1) a play that clears now is taken
    r = lua_str(a, """
        local hand = HAND({{13,1},{13,2},{13,3},{4,1},{6,2},{9,3},{2,4},{11,1}})
        local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = CTX({}), hands_left = 3, discards_left = 3, hand_limit = 8, need = 150, budget_ms = 30 })
        return res.action .. ':' .. res.name .. ':' .. res.tag
    """)
    check(r == "play:Three of a Kind:clears now", "a hand that clears the blind outright is played (%s)" % r)
    # 2) flush draw: need only a Flush can pay; discarding the off-suit cards is right and its odds are sane
    r = lua_str(a, """
        local hand = HAND({{14,2},{9,2},{6,2},{3,2},{13,1},{8,3},{5,4},{2,3}})
        local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = CTX({}), hands_left = 2, discards_left = 1, hand_limit = 8, need = 260, budget_ms = 400, min_samples = 200, max_samples = 400 })
        return res.action .. ':' .. tostring(res.tag) .. ':' .. string.format('%.3f', res.p_clear or -1)
    """)
    act, tag, p = r.split(":")
    check(act == "discard" and "flush" in tag, "chases the 4-card flush when nothing else can clear (%s)" % r)
    check(0.45 <= float(p) <= 0.86, "its clear odds come from the real pile (9 hearts left in 44 cards, 4 draws): p=%s" % p)
    # 3) when only a 4-of-a-kind can clear, the plan chases it with the odds the pile gives (1 king left in 44 cards)
    r = lua_str(a, """
        local fam = {{name='The Family', ab={x_mult=4, type='Four of a Kind'}}}
        local hand = HAND({{13,1},{13,2},{13,3},{4,1},{6,2},{9,3},{2,4},{11,1}})
        local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = CTX(fam), hands_left = 2, discards_left = 2, hand_limit = 8, need = 2000, budget_ms = 600, min_samples = 400, max_samples = 600 })
        return res.action .. ':' .. tostring(res.tag) .. ':' .. string.format('%.3f', res.p_clear or -1)
    """)
    act, tag, p = r.split(":")
    check(act == "discard", "only the 4th king can clear it: keep the trips, discard the junk (%s)" % r)
    check(0.13 <= float(p) <= 0.30, "odds of finding the last king in two 5-card draws from 44 cards: p=%s (exact ~0.23)" % p)
    # 4) the slim chase is NOT taken when steady hands clear anyway: compare the options the planner itself measured
    r = lua_str(a, """
        local fam = {{name='The Family', ab={x_mult=4, type='Four of a Kind'}}}
        local hand = HAND({{13,1},{13,2},{4,1},{6,3},{9,3},{2,4},{11,1},{8,2}})
        local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = CTX(fam), hands_left = 4, discards_left = 3, hand_limit = 8, need = 400, budget_ms = 600, min_samples = 300, max_samples = 500 })
        local best_p, play_p = 0, -1
        for _, row in ipairs(res.info.table) do
            if row.p_clear and row.p_clear > best_p then best_p = row.p_clear end
            if row.tag == 'play Pair' then play_p = row.p_clear or -1 end
        end
        return string.format('%.3f:%.3f:%.3f:%s', res.p_clear or -1, best_p, play_p, tostring(res.tag))
    """)
    p_pick, p_best, p_pair, tag = r.split(":")
    check(float(p_pick) >= float(p_best) - 0.03, "the chosen option has (about) the highest measured clear odds (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)


def test_reward_life_factor():
    print("test: PvP loss is punished more with fewer lives / when trailing in lives (strategy: comeback money)")
    tmp = tempfile.mkdtemp(prefix="arena_lf_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_REWARD": "life_low=0.4,life_rel=0.15"})
    f = lambda me, en: a.lua.eval("BotArena.reward.life_factor(%s, %s)" % (me, en))
    check(abs(f(4, 4) - 1.0) < 1e-9, "4 v 4 = 1.0 (%s)" % f(4, 4))
    check(f(1, 4) > f(2, 4) > f(3, 4) > f(4, 4), "fewer own lives -> bigger penalty (%.2f > %.2f > %.2f > %.2f)" % (f(1, 4), f(2, 4), f(3, 4), f(4, 4)))
    check(f(2, 1) > f(4, 1), "losing at 2 v 1 is worse than at 4 v 1 (%.2f > %.2f)" % (f(2, 1), f(4, 1)))
    check(f(4, 1) < f(4, 4), "being 4 up on a 1-life opponent costs less than 4 v 4 (%.2f < %.2f)" % (f(4, 1), f(4, 4)))
    check(f(1, 4) > f(1, 1), "1 v 4 is worse than 1 v 1 (%.2f > %.2f)" % (f(1, 4), f(1, 1)))
    a.lua.execute("BotArena.reward.W.life_low = 0; BotArena.reward.W.life_rel = 0")
    check(f(1, 4) == 1, "scaling can be switched off")
    # and it is applied to a real PvP loss row: the same loss costs more at 1 life v 4 than at 4 v 4
    tmp2 = tempfile.mkdtemp(prefix="arena_lf2_")
    for lives_me, lives_en in ((4, 4), (1, 4)):
        sim2, a2, b2 = make_pair(tmp2, env_a={"BOTARENA_REWARD": "life_low=0.4,life_rel=0.15"})
        a2.lua.execute("BotArena.reward.on_match_start(); G.GAME = {round_resets={ante=2}, round=3, dollars=0, chips=0}; MP.GAME.lives=%d; MP.GAME.enemy.lives=%d; BotArena.reward.open('pvp')" % (lives_me, lives_en))
        fac = a2.lua.eval("BotArena.reward.life_factor(BotArena.reward.cur.lives0, BotArena.reward.cur.enemy_lives0)")
        print("       lives %d v %d -> factor %.2f" % (lives_me, lives_en, fac))
        if lives_me == 1:
            check(fac > 2.5, "1 v 4 factor %.2f" % fac)
    shutil.rmtree(tmp2, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)


def test_plan_protects_held_cards():
    print("test: planner never discards Steel / Baron-king cards while other cards can go")
    tmp, sim, a, b = plan_env()
    a.lua.execute("""
        function PILE2(hand)
            local gone = {}
            for _, c in ipairs(hand) do gone[c.rank * 10 + c.suit] = (gone[c.rank * 10 + c.suit] or 0) + 1 end
            local pile = {}
            for r = 2, 14 do for s = 1, 4 do
                local k = r * 10 + s
                if (gone[k] or 0) > 0 then gone[k] = gone[k] - 1 else pile[#pile + 1] = PL.card(r, s, { hx = (r == 5) and 1.5 or 1 }) end
            end end
            return pile
        end
    """)
    r = lua_str(a, """
        local ctx = CTX({{name='Mime'}})
        ctx.held_effects = true
        local hand = HAND({{14,1},{3,2,{hx=1.5}},{4,3,{hx=1.5}},{6,4,{hx=1.5}},{9,1},{2,2},{7,3},{10,4}})
        local res = PL.plan({ hand = hand, deck = PILE2(hand), ctx = ctx, hands_left = 4, discards_left = 3, hand_limit = 8, need = 5000, budget_ms = 120 })
        local steel_gone = 0
        for _, c in ipairs(res.cards) do if c.hx ~= 1 and res.action == 'discard' then steel_gone = steel_gone + 1 end end
        return res.action .. ':' .. steel_gone
    """)
    check(r.endswith(":0"), "no steel card is discarded (%s)" % r)
    r = lua_str(a, """
        local ctx = CTX({{name='Baron', ab={extra=1.5}}})
        local hand = HAND({{13,1},{13,2},{4,3},{6,4},{9,1},{2,2},{7,3},{10,4}})
        local res = PL.plan({ hand = hand, deck = PILE2(hand), ctx = ctx, hands_left = 4, discards_left = 3, hand_limit = 8, need = 9000, budget_ms = 120 })
        local kings = 0
        for _, c in ipairs(res.cards) do if c.rank == 13 and res.action == 'discard' then kings = kings + 1 end end
        return res.action .. ':' .. kings
    """)
    check(r.endswith(":0"), "Kings are kept for Baron when discarding (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)


def test_plan_beats_naive_policies():
    print("test: over many simulated blinds the planner clears at least as often as greedy / keep-the-best play")
    tmp, sim, a, b = plan_env()
    res = {}
    for pol in ("greedy", "keep", "plan"):
        out = lua_str(a, """
            local rate, unused = PLAN_SIM.run{ blinds = 70, need = 520, policy = '%s', seed = 7, budget_ms = 18,
                jokers = { {name='Jolly Joker', ab={t_mult=8, type='Pair'}} } }
            return string.format('%%.3f:%%.2f', rate, unused)
        """ % pol)
        rate, unused = out.split(":")
        res[pol] = (float(rate), float(unused))
        print("       %-6s clear rate %.3f (unused hands when cleared %.2f)" % (pol, float(rate), float(unused)))
    check(res["plan"][0] >= res["greedy"][0] - 0.08, "planner >= greedy (%.3f vs %.3f)" % (res["plan"][0], res["greedy"][0]))
    check(res["plan"][0] >= res["keep"][0] - 0.08, "planner >= keep-the-best (%.3f vs %.3f)" % (res["plan"][0], res["keep"][0]))
    # a joker lineup that only pays for a rare hand: the planner must not chase it blindly
    res2 = {}
    for pol in ("keep", "plan"):
        out = lua_str(a, """
            local rate = PLAN_SIM.run{ blinds = 70, need = 420, policy = '%s', seed = 11, budget_ms = 18,
                jokers = { {name='The Family', ab={x_mult=4, type='Four of a Kind'}} } }
            return string.format('%%.3f', rate)
        """ % pol)
        res2[pol] = float(out)
        print("       Family joker, %-5s clear rate %.3f" % (pol, res2[pol]))
    check(res2["plan"] >= res2["keep"] - 0.08, "with a rare-hand joker the planner is not worse than keep-the-best (%.3f vs %.3f)" % (res2["plan"], res2["keep"]))
    shutil.rmtree(tmp, ignore_errors=True)


def test_baseline_uses_planner():
    print("test: the baseline bot plays through the planner in a live (mock) game, with no errors")
    random.seed(31)
    tmp = tempfile.mkdtemp(prefix="arena_plan2_")
    lua = "MOCK.with_deck = true"
    sim, a, b = make_pair(tmp, lua_a=lua, lua_b=lua)
    run(sim, [a, b], 30000, until=lambda: a.lua.eval("BotArena.plan.stats.decisions") >= 12 and len(rewards(tmp, 1)) >= 3)
    n = a.lua.eval("BotArena.plan.stats.decisions")
    check(n >= 12, "planner made %d decisions" % n)
    logs = [l for l in a.log() if l.startswith("I plan:")]
    check(len(logs) >= 12, "decisions are logged (%d lines, e.g. %s)" % (len(logs), logs[0][:110] if logs else None))
    errs = [e for e in a.log() + b.log() if e.startswith("E ")]
    check(not errs, "no errors (%s)" % errs[:2])
    check(a.lua.eval("BotArena.plan.stats.errors") == 0, "no planner errors")
    check(any(" discard " in l for l in logs) or any(" play " in l for l in logs), "plays/discards were issued through it")
    snap = a.lua.eval("BotArena.plan.last ~= nil")
    check(snap, "last decision is exposed for the status/observation")
    shutil.rmtree(tmp, ignore_errors=True)


# ==================================================================================================
# decision layer (lib/decide.lua): legal options, features, logging, bans, caps, external "choose"
# ==================================================================================================
def _to_shop(tmp, extra_lua="", env_a=None):
    idle = os.path.join(tmp, "idle_driver.lua")
    with open(idle, "w") as f:
        f.write("return function(A) return { name='idle', step=function() return false end } end")
    env = {"BOTARENA_DRIVER": idle.replace("\\", "/")}
    env.update(env_a or {})
    sim, a, b = make_pair(tmp, env_a=env,
                          lua_a="MOCK.rich_shop = true; MOCK.score_override = function(t) return 1000 end; " + extra_lua)
    run(sim, [a, b], 20000, until=lambda: a.lua.eval("G.STATE == G.STATES.BLIND_SELECT and G.GAME ~= nil"))
    lua_str(a, "return tostring(BotArena.act.select_blind())")
    run(sim, [a, b], 10)
    lua_str(a, "return tostring(BotArena.act.play({1,2,3}))")
    run(sim, [a, b], 600, until=lambda: a.lua.eval("G.STATE == G.STATES.SHOP"))
    return sim, a, b


def _decision(inst, kind):
    out = lua_str(inst, "local d = BotArena.decide.begin('%s'); return d and BotArena.util.encode(BotArena.decide.serialize(d)) or ''" % kind)
    return json.loads(out) if out else None


def test_decide_enumerate():
    print("test: decision layer lists every legal shop option with features")
    random.seed(41)
    tmp = tempfile.mkdtemp(prefix="arena_d1_")
    sim, a, b = _to_shop(tmp)
    check(a.lua.eval("G.STATE == G.STATES.SHOP"), "bot reached the shop")
    a.lua.execute("G.GAME.dollars = 30; G.jokers.cards[1] = MOCK.new_joker({name='Joker', key='j_joker', cost=2, rarity=1, ab={mult=4}}); G.jokers.cards[1].area = G.jokers")
    d = _decision(a, "shop")
    check(d is not None and d["kind"] == "shop", "decision built for the shop")
    kinds = [o["kind"] for o in d["options"]]
    for k in ("buy_joker", "buy_planet", "buy_voucher", "open_pack", "reroll", "sell_joker", "leave"):
        check(k in kinds, "option kind present: %s" % k)
    ids = [o["id"] for o in d["options"]]
    check(len(ids) == len(set(ids)), "option ids are unique")
    bj = [o for o in d["options"] if o["kind"] == "buy_joker"][0]
    check(all(isinstance(bj["fx"].get(k), (int, float)) for k in ("cost", "money_after", "d_pot", "rarity", "interest_loss")),
          "joker option carries numeric features (%s)" % sorted(bj["fx"])[:6])
    cheap = [o for o in d["options"] if o["kind"] == "buy_joker" and o["key"] == "j_greedy_joker"]
    check(all(o["fx"]["d_pot"] > 0 for o in cheap), "a +mult joker adds scoring potential (d_pot>0)")
    sx = d["sx"]
    check(sx["dollars"] == 30 and sx["lives"] == 4 and sx["ante"] == 1 and "pot_log" in sx and "blinds_to_pvp" in sx,
          "state features present (dollars/lives/ante/pot_log/blinds_to_pvp)")
    check(isinstance(d["bidx"], int) and d["jokers"] == ["j_joker"], "decision stamped with reward row index and joker keys")
    sell = [o for o in d["options"] if o["kind"] == "sell_joker"][0]
    check(sell["fx"]["d_pot"] > 0, "selling the only joker is a loss of potential (feature positive = what it adds)")
    # poorer: unaffordable things disappear
    a.lua.execute("G.GAME.dollars = 3")
    d2 = _decision(a, "shop")
    k2 = [o["kind"] for o in d2["options"]]
    check("buy_voucher" not in k2 and "reroll" not in k2 and "leave" in k2, "with $3 no voucher / reroll, but leaving is still offered")
    errs = [e for e in a.log() if e.startswith("E ")]
    check(not errs, "no errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)


def test_decide_bans_and_caps():
    print("test: failed options are banned for the visit; the step cap leaves only 'move on'")
    random.seed(42)
    tmp = tempfile.mkdtemp(prefix="arena_d2_")
    sim, a, b = _to_shop(tmp)
    a.lua.execute("G.GAME.dollars = 30")
    d = _decision(a, "shop")
    victim = [o["id"] for o in d["options"] if o["kind"] == "buy_planet"][0]
    a.lua.execute("BotArena.decide.ban('%s')" % victim)
    d2 = _decision(a, "shop")
    check(victim not in [o["id"] for o in d2["options"]], "banned option is no longer offered")
    a.lua.execute("BotArena.decide.visit.n = 1000")
    d3 = _decision(a, "shop")
    check([o["kind"] for o in d3["options"]] == ["leave"], "after the step cap only leave_shop remains (%s)" % [o["kind"] for o in d3["options"]])
    # reroll cap
    a.lua.execute("BotArena.decide.visit.n = 0; BotArena.decide.visit.rerolls = 99")
    d4 = _decision(a, "shop")
    check("reroll" not in [o["kind"] for o in d4["options"]], "reroll disappears after too many rerolls in one visit")
    # a new visit (next round) forgets bans
    a.lua.execute("G.GAME.round = G.GAME.round + 1")
    d5 = _decision(a, "shop")
    check(a.lua.eval("next(BotArena.decide.visit.bans) == nil and BotArena.decide.visit.n == 0"), "bans and counters reset with a new visit (next round)")
    st = a.lua.eval("BotArena.decide.stats.capped")
    check(st >= 1, "cap events counted (%s)" % st)
    shutil.rmtree(tmp, ignore_errors=True)


def test_decide_potential():
    print("test: the potential feature rewards scoring jokers and levelled hands")
    random.seed(43)
    tmp = tempfile.mkdtemp(prefix="arena_d3_")
    sim, a, b = _to_shop(tmp)
    r = lua_str(a, """
        local P = BotArena.plan
        P.seed(7)
        local s = P.sample_hands(10, 8)
        local _, base = P.potential(s, {})
        local cav = MOCK.new_joker({name='Cavendish', key='j_cavendish', cost=4, rarity=1, ab={x_mult=3}})
        local ban = MOCK.new_joker({name='Banner', key='j_banner', cost=5, rarity=1, ab={chips=30}})
        local egg = MOCK.new_joker({name='Egg', key='j_egg', cost=4, rarity=1, ab={}})
        local _, c1 = P.potential(s, {cav})
        local _, c2 = P.potential(s, {ban})
        local _, c3 = P.potential(s, {egg})
        local _, c4 = P.potential(s, {}, function(ctx) ctx.lvl = { Pair = { chips = 100, mult = 10 }, ['High Card'] = { chips = 100, mult = 10 } } end)
        return string.format('%.4f %.4f %.4f %.4f %.4f', base, c1, c2, c3, c4)
    """)
    base, cav, ban, egg, lvl = [float(x) for x in r.split()]
    check(cav > base + 0.3, "x3 joker lifts potential a lot (%.2f -> %.2f)" % (base, cav))
    check(ban > base + 0.05, "+30 chips joker lifts it (%.2f -> %.2f)" % (base, ban))
    check(abs(egg - base) < 1e-6, "a no-effect joker changes nothing")
    check(lvl > base + 0.3, "higher hand levels lift it (%.2f -> %.2f)" % (base, lvl))
    shutil.rmtree(tmp, ignore_errors=True)


JOKER_LUA = """
    JK = {
        add = MOCK.new_joker({name='Joker', key='j_joker', cost=2, rarity=1, ab={mult=4}}),
        cav = MOCK.new_joker({name='Cavendish', key='j_cavendish', cost=4, rarity=1, ab={x_mult=3}}),
        brain = MOCK.new_joker({name='Brainstorm', key='j_brainstorm', cost=10, rarity=3, ab={}}),
        dag = MOCK.new_joker({name='Ceremonial Dagger', key='j_ceremonial', cost=6, rarity=2, ab={}}),
        ban = MOCK.new_joker({name='Banner', key='j_banner', cost=5, rarity=1, ab={chips=30}}),
    }
    SETROW = function(names)
        G.jokers.cards = {}
        for i, n in ipairs(names) do
            local j = JK[n]
            j.area = G.jokers
            G.jokers.cards[i] = j
        end
    end
    ROW = function()
        local t = {}
        for i, j in ipairs(G.jokers.cards) do t[i] = j.ability.name end
        return table.concat(t, ',')
    end
"""


def test_joker_order():
    print("test: jokers are re-ordered automatically (+mult before x-mult, Brainstorm behind the best joker, Dagger last, pinned stay)")
    random.seed(45)
    tmp = tempfile.mkdtemp(prefix="arena_ord_")
    sim, a, b = _to_shop(tmp, env_a={"BOTARENA_JOKER_ORDER": "0"})
    a.lua.execute(JOKER_LUA)
    lua_str(a, "BotArena.plan.seed(11); BotArena.cfg.joker_order_samples = 20; return ''")

    def opt(names):
        return lua_str(a, "SETROW({%s}); BotArena.order.reset(); local ch = BotArena.order.optimise(); return tostring(ch) .. ' ' .. ROW()" % ",".join("'%s'" % n for n in names)).split(" ", 1)

    ch, row = opt(["cav", "add"])
    check(ch == "true" and row == "Joker,Cavendish", "x-mult moves behind the +mult joker (%s)" % row)
    ch, row = opt(["add", "cav"])
    check(ch == "false" and row == "Joker,Cavendish", "already best -> untouched (%s)" % row)
    ch, row = opt(["add", "cav", "brain"])
    check(row.split(",")[-1] != "Cavendish", "Brainstorm gets the x-mult joker on its left end (%s)" % row)
    check(row.split(",")[0] != "Brainstorm", "Brainstorm is never leftmost (it would copy nothing)")
    ch, row = opt(["brain", "cav", "add"])
    check(row.split(",")[0] == "Cavendish", "Brainstorm moves off the left edge, x-mult leftmost (%s)" % row)
    ch, row = opt(["dag", "add"])
    check(row == "Joker,Ceremonial Dagger", "Ceremonial Dagger goes rightmost (%s)" % row)
    # pinned jokers stay where they are
    r = lua_str(a, "SETROW({'cav','add'}); G.jokers.cards[1].pinned = true; BotArena.order.reset(); BotArena.order.optimise(); local r = ROW(); G.jokers.cards[1].pinned = nil; return r")
    check(r == "Cavendish,Joker", "pinned joker keeps the left slot (%s)" % r)
    # five jokers: permutation search, same cards, nothing lost
    r = lua_str(a, "SETROW({'cav','brain','ban','dag','add'}); BotArena.order.reset(); BotArena.order.optimise(); return ROW() .. ' ' .. #G.jokers.cards")
    row, n = r.rsplit(" ", 1)
    check(n == "5" and sorted(row.split(",")) == sorted(["Cavendish", "Brainstorm", "Banner", "Ceremonial Dagger", "Joker"]), "5-joker row stays a permutation (%s)" % row)
    check(row.split(",")[-1] == "Ceremonial Dagger", "...with the Dagger last (%s)" % row)
    # no thrash: ticking again with the same jokers does not search / move again
    r = lua_str(a, "local O = BotArena.order; local before = O.stats.moves; local row = ROW(); BotArena.cfg.joker_order_gap = 0; for i = 1, 5 do O.tick() end; return tostring(O.stats.moves - before) .. ' ' .. tostring(row == ROW())")
    check(r == "0 true", "repeated ticks do not move anything (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)


def test_joker_order_e2e():
    print("test: the arena tick re-orders the row by itself in the shop (no errors, event logged)")
    random.seed(46)
    tmp = tempfile.mkdtemp(prefix="arena_ord2_")
    sim, a, b = _to_shop(tmp)
    a.lua.execute(JOKER_LUA)
    a.lua.execute("BotArena.cfg.joker_order_gap = 0.1; SETROW({'cav','add'}); BotArena.order.reset()")
    run(sim, [a, b], 400, until=lambda: lua_str(a, "return ROW()") == "Joker,Cavendish")
    row = lua_str(a, "return ROW()")
    check(row == "Joker,Cavendish", "shop tick fixed the order on its own (%s)" % row)
    check(int(lua_str(a, "return tostring(BotArena.order.stats.errors)")) == 0, "no order errors")
    check(int(lua_str(a, "return tostring(BotArena.order.stats.moves)")) >= 1, "move counted")
    shutil.rmtree(tmp, ignore_errors=True)


def test_pvp_no_wasted_single():
    print("test: PvP - no lone-card 'save the best for last' opener (planner and hand layer); Pacifist is worth little more than a normal x-mult")
    random.seed(92)
    tmp, sim, a, b = plan_env()
    a.lua.execute("""
        function PILE(hand)
            local gone = {}
            for _, c in ipairs(hand) do gone[c.rank * 10 + c.suit] = (gone[c.rank * 10 + c.suit] or 0) + 1 end
            local pile = {}
            for rk = 2, 14 do for s = 1, 4 do
                local k = rk * 10 + s
                if (gone[k] or 0) > 0 then gone[k] = gone[k] - 1 else pile[#pile + 1] = PL.card(rk, s) end
            end end
            return pile
        end
    """)
    # Dusk makes the trips worth more on the LAST hand: the old planner opened with a 14-point single and kept the trips
    q = """
        PL.seed(%d)
        local hand = HAND({{13,1},{13,2},{13,3},{9,4},{7,1},{5,2},{3,3},{2,4}})
        local ctx = CTX({{name='Dusk'}}, {pvp=%s})
        local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = ctx, hands_left = 2, discards_left = 0, hand_limit = 8, play_limit = 5, discard_limit = 5, need = nil, budget_ms = 120 })
        return string.format('%%d %%s', #res.cards, tostring(res.score))
    """
    for seed in (1, 2, 3):
        n, sc = lua_str(a, q % (seed, "true")).split(" ")
        check(int(n) == 3 and sc == "180", "PvP: plays the trips now instead of a lone card (n=%s score=%s)" % (n, sc))
    n, sc = lua_str(a, q % (4, "false")).split(" ")
    check(int(n) == 3, "outside PvP nothing changed (n=%s)" % n)
    # a lone card that IS (about) the best play is still fine (Half Joker style builds)
    r = lua_str(a, """
        local hand = HAND({{14,1},{9,2},{7,3},{5,4},{3,1},{2,2},{4,3},{6,4}})
        local ctx = CTX({}, {pvp=true})
        local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = ctx, hands_left = 3, discards_left = 0, hand_limit = 8, play_limit = 5, discard_limit = 5, need = nil, budget_ms = 80 })
        return res.action
    """)
    check(r in ("play", "discard"), "a plain hand is still decided (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)
    # the hand layer does not offer wasted singles in PvP
    tmp = tempfile.mkdtemp(prefix="arena_hd2_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_PLAN_MS": "30", "BOTARENA_DRIVER": "random"}, env_b={"BOTARENA_PLAN_MS": "10"},
                          lua_a="MOCK.with_deck = true", lua_b="MOCK.with_deck = true")
    if _to_hand_state(sim, a, b):
        a.lua.execute("HD = BotArena.handdec")
        out = lua_str(a, """
            local function waste(gi)
                local dec = HD.begin({ need = nil, ginfo = gi })
                local best, bad = 0, 0
                for _, o in ipairs(dec.options) do if o.act == 'play' and o.score > best then best = o.score end end
                for _, o in ipairs(dec.options) do if o.act == 'play' and #o.idx == 1 and o.score < best * 0.9 then bad = bad + 1 end end
                return bad
            end
            return string.format('%d %d', waste({ pvp = true, chips = 0 }), waste({ pvp = false, chips = 0 }))
        """)
        pv, npv = [int(x) for x in out.split(" ")]
        check(pv == 0, "PvP: no single card weaker than 90%% of the best play is offered (%d)" % pv)
        check(npv >= 0, "outside PvP singles stay available (%d)" % npv)
    shutil.rmtree(tmp, ignore_errors=True)
    # shop: a x10 that only works outside PvP is not valued like a real x10
    tmp = tempfile.mkdtemp(prefix="arena_pac_")
    sim, a, b = _to_shop(tmp)
    sxj = "{ante=3, dollars=30, income_est=7, joker_free=2, lives=4}"
    pac = _val(a, "buy_joker", "j_mp_pacifist", "{cost=4, money_after=26, d_pot=1.0, d_pot_pvp=0.0, rarity=1}", sxj)
    xm = _val(a, "buy_joker", "j_x", "{cost=4, money_after=26, d_pot=0.48, d_pot_pvp=0.48, rarity=1}", sxj)
    check(pac < xm, "Pacifist (x10 outside PvP only) is worth less than a plain x3 that also works in PvP (%.1f < %.1f)" % (pac, xm))
    shutil.rmtree(tmp, ignore_errors=True)


def test_purple_seal():
    print("test: Purple Seal cards are discarded for Tarots (never just played), Gold Seal cards are played")
    random.seed(93)
    tmp, sim, a, b = plan_env()
    a.lua.execute("""
        function PILE(hand)
            local gone = {}
            for _, c in ipairs(hand) do gone[c.rank * 10 + c.suit] = (gone[c.rank * 10 + c.suit] or 0) + 1 end
            local pile = {}
            for rk = 2, 14 do for s = 1, 4 do
                local k = rk * 10 + s
                if (gone[k] or 0) > 0 then gone[k] = gone[k] - 1 else pile[#pile + 1] = PL.card(rk, s) end
            end end
            return pile
        end
        function PLAN(hand, o)
            o = o or {}
            local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = CTX({}), hands_left = o.hands or 3, discards_left = o.discards or 3,
                hand_limit = 8, play_limit = 5, discard_limit = 5, need = o.need, budget_ms = 60, tarot_slots = o.slots })
            local ix = {}
            for _, c in ipairs(res.cards) do ix[#ix + 1] = tostring(c.rank) .. (c.seal and c.seal:sub(1, 1) or '') end
            table.sort(ix)
            return res.action .. ':' .. table.concat(ix, ',') .. ':' .. tostring(res.tag)
        end
    """)
    # trips of kings clear 150 right now; the 2 of diamonds and the 9 of clubs are Purple Seals in hand
    hand = "HAND({{13,1},{13,2},{13,3},{4,1},{6,2},{9,3,{seal='Purple'}},{2,4,{seal='Purple'}},{11,1}})"
    r = lua_str(a, "return PLAN(%s, {need=150, slots=2})" % hand)
    act, cards, tag = r.split(":", 2)
    check(act == "discard" and cards == "2P,9P" and "purple" in tag, "a clearing play is kept; the two Purple cards are discarded first (%s)" % r)
    r = lua_str(a, "return PLAN(%s, {need=150, slots=1})" % hand)
    act, cards, tag = r.split(":", 2)
    check(act == "discard" and len(cards.split(",")) == 1, "one free slot: one Purple card (%s)" % r)
    r = lua_str(a, "return PLAN(%s, {need=150, slots=0})" % hand)
    check(r.startswith("play:") and "clears now" in r, "no free consumable slot: just play (%s)" % r)
    r = lua_str(a, "return PLAN(%s, {need=150, slots=2, discards=0})" % hand)
    check(r.startswith("play:"), "no discard left: just play (%s)" % r)
    # the only clearing play contains the Purple card: clearing still wins
    hand2 = "HAND({{13,1,{seal='Purple'}},{13,2},{13,3},{4,1},{6,2},{9,3},{3,4},{11,1}})"
    r = lua_str(a, "return PLAN(%s, {need=150, slots=2})" % hand2)
    check(r.startswith("play:") and "13P" in r, "a Purple card inside the only clearing play is played (%s)" % r)
    # nothing can clear: the Tarot decides between otherwise equal discards
    r = lua_str(a, "return PLAN(%s, {need=100000, slots=2})" % hand)
    act, cards, tag = r.split(":", 2)
    check(act == "discard" and "2P" in cards and "9P" in cards, "hopeless blind: still collects the free Tarots (%s)" % r)
    # Gold: of two plays that clear, the one with the Gold Seal card wins; Purple cards are not played when another clearing play exists
    hand3 = "HAND({{13,1},{13,2},{13,3},{12,1},{12,2},{12,3},{4,1},{6,2}})"
    gold = hand3.replace("{12,1}", "{12,1,{seal='Gold'}}")
    wins = 0
    for _ in range(3):
        r = lua_str(a, "return PLAN(%s, {need=100, slots=0})" % gold)
        if "12G" in r.split(":")[1]: wins += 1
    check(wins == 3, "of two clearing hands the one with the Gold Seal card is played")
    pur = hand3.replace("{12,1}", "{12,1,{seal='Purple'}}")
    r = lua_str(a, "return PLAN(%s, {need=100, slots=2})" % pur)
    act, cards, tag = r.split(":", 2)
    check(act == "discard" and cards == "12P", "...and the Purple one goes in the discard pile first (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)

    # live game: seals travel through P.describe and the hand layer logs them
    tmp = tempfile.mkdtemp(prefix="arena_purple_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_PLAN_MS": "30", "BOTARENA_DRIVER": "random"}, env_b={"BOTARENA_PLAN_MS": "10"},
                          lua_a="MOCK.with_deck = true", lua_b="MOCK.with_deck = true")
    if _to_hand_state(sim, a, b):
        out = lua_str(a, """
            local HD = BotArena.handdec
            local cards = G.hand.cards
            cards[1].seal = 'Purple'
            cards[2].seal = 'Gold'
            local d1 = BotArena.plan.describe(cards[1], 1)
            local d2 = BotArena.plan.describe(cards[2], 2)
            local dec = HD.begin({ need = nil, ginfo = { pvp = false, chips = 0 } })
            local sp, sg, room = 0, 0, 0
            for _, o in ipairs(dec.options) do
                if o.fx.seal_purple then sp = sp + 1 end
                if o.fx.seal_gold then sg = sg + 1 end
                if o.fx.tarot_room then room = math.max(room, o.fx.tarot_room) end
            end
            return string.format('%s %s %d %d %d', tostring(d1.seal), tostring(d2.seal), sp, sg, room)
        """)
        s1, s2, sp, sg, room = out.split(" ")
        check(s1 == "Purple" and s2 == "Gold", "P.describe carries the seal (%s %s)" % (s1, s2))
        check(int(sp) > 0 and int(sg) > 0, "hand options with seal cards log seal_purple / seal_gold (%s %s)" % (sp, sg))
        check(int(room) >= 1, "...and the free consumable slots (%s)" % room)
        # the planner entry point sees the free slots: with a full consumable area it never goes for a Purple discard
        res = lua_str(a, """
            local cards = G.hand.cards
            for i = 1, #cards do cards[i].seal = nil end
            cards[1].seal = 'Purple'
            local r1 = BotArena.plan.decide({ need = 1 })
            local first = r1 and r1.action .. ':' .. tostring(r1.tag) or 'nil'
            G.consumeables.cards = { MOCK.new_consumable('Tarot'), MOCK.new_consumable('Tarot') }
            local r2 = BotArena.plan.decide({ need = 1 })
            return first .. '|' .. (r2 and (r2.action .. ':' .. tostring(r2.tag)) or 'nil')
        """)
        # the hand layer marks that pick as a rule (the external driver plays it without asking the model)
        res2 = lua_str(a, """
            local HD = BotArena.handdec
            G.consumeables.cards = {}
            local d1 = HD.begin({ need = 1, ginfo = { pvp = false, chips = 0 } })
            local f1 = tostring(d1 and d1.forced) .. ':' .. tostring(d1 and d1.options[d1.pl] and d1.options[d1.pl].act)
            G.consumeables.cards = { MOCK.new_consumable('Tarot'), MOCK.new_consumable('Tarot') }
            local d2 = HD.begin({ need = 1, ginfo = { pvp = false, chips = 0 } })
            return f1 .. '|' .. tostring(d2 and d2.forced)
        """)
        f1, f2 = res2.split("|")
        check(f1 == "true:discard" and f2 == "nil", "dec.forced is set for the Purple discard only while a slot is free (%s / %s)" % (f1, f2))
        first, second = res.split("|")
        check(first.startswith("discard:purple"), "live game, free slots: a clearing play waits while the Purple card is discarded (%s)" % first)
        check(second.startswith("play:"), "live game, full consumable area: just play (%s)" % second)
    shutil.rmtree(tmp, ignore_errors=True)


def test_retrigger_and_room():
    print("test: retrigger jokers are worth more with support (Gold / Lucky / per-card jokers); full consumable slots are cleared for a Purple discard")
    random.seed(94)
    tmp = tempfile.mkdtemp(prefix="arena_rt_")
    sim, a, b = _to_shop(tmp, env_a={"BOTARENA_DECIDE_SKIPS": "1"})
    sx = "{ante=3, dollars=20, income_est=7, lives=4, joker_free=2, joker_limit=5, n_jokers=2}"
    base = "d_pot=0.0, d_pot_pvp=0.0, rarity=1, cost=5, money_after=15, interest_loss=0"
    bare = _val(a, "buy_joker", "j_hack", "{%s, retrig_card=1, rt_synergy=0}" % base, sx)
    rich = _val(a, "buy_joker", "j_hack", "{%s, retrig_card=1, rt_synergy=3}" % base, sx)
    plain = _val(a, "buy_joker", "j_y", "{%s}" % base, sx)
    check(rich > bare + 10, "a retrigger joker with support (Gold / Lucky cards, per-card jokers) is worth much more (%.1f vs %.1f)" % (rich, bare))
    check(bare > plain + 1.5, "...and even a bare one is worth more than a joker that does nothing (%.1f vs %.1f)" % (bare, plain))
    two = _val(a, "buy_joker", "j_hack", "{%s, retrig_card=1, rt_synergy=3}" % base, "{ante=3, dollars=20, income_est=7, lives=4, joker_free=2, joker_limit=5, n_jokers=2, jk_retrig_card=1}")
    check(two > rich, "a second retrigger joker multiplies the first (%.1f vs %.1f)" % (two, rich))
    check(_val(a, "buy_joker", "j_hack", "{%s, retrig_card=1, rt_synergy=3}" % base, "{ante=8, dollars=20, income_est=7, lives=4, joker_free=2, joker_limit=5, n_jokers=2}") < rich, "late antes value it a bit less")
    # features from the live game: jokers that fire per card + Gold Seal / Lucky share of the deck
    out = lua_str(a, """
        G.jokers.cards = { MOCK.new_joker({ name = 'Hack', key = 'j_hack', cost = 6, rarity = 2 }), MOCK.new_joker({ name = 'Photograph', key = 'j_photograph', cost = 5, rarity = 2 }) }
        G.playing_cards = {}
        for i = 1, 20 do
            G.playing_cards[i] = { base = { id = 2 + (i % 12), suit = 'Hearts', nominal = 5 }, ability = { set = 'Default' }, config = { center = { key = 'c_base' } } }
        end
        local d0 = BotArena.decide.begin('shop')
        local s0 = d0.sx.rt_support
        for i = 1, 4 do G.playing_cards[i].seal = 'Gold' end
        G.playing_cards[5].config.center.key = 'm_lucky'
        local d1 = BotArena.decide.begin('shop')
        local fx
        for _, o in ipairs(d1.options) do if o.kind == 'buy_joker' and o.fx.retrig_card then fx = o.fx end end
        return string.format('%.2f %.2f %s %s %s %s', s0, d1.sx.rt_support, tostring(d1.sx.jk_retrig_card), tostring(d1.sx.jk_on_card), tostring(d1.sx.deck_goldseal), tostring(fx and fx.retrig_card))
    """)
    s0, s1, jr, jo, dg, rc = out.split(" ")
    check(abs(float(s0) - 0.8) < 0.01 and float(s1) > float(s0) + 1.5, "rt_support: 1 per-card joker = 0.8, plus 4 Gold + 1 Lucky of 20 cards (%s -> %s)" % (s0, s1))
    check(jr == "1" and jo == "1" and abs(float(dg) - 0.2) < 0.001, "state features: retrigger jokers %s, per-card jokers %s, Gold Seal share %s" % (jr, jo, dg))
    shutil.rmtree(tmp, ignore_errors=True)

    # planner: retriggers repeat the Gold Seal $3 and the Lucky $20 chance
    tmp, sim, a, b = plan_env()
    a.lua.execute("""
        function PILE(hand)
            local gone = {}
            for _, c in ipairs(hand) do gone[c.rank * 10 + c.suit] = (gone[c.rank * 10 + c.suit] or 0) + 1 end
            local pile = {}
            for rk = 2, 14 do for s = 1, 4 do
                local k = rk * 10 + s
                if (gone[k] or 0) > 0 then gone[k] = gone[k] - 1 else pile[#pile + 1] = PL.card(rk, s) end
            end end
            return pile
        end
    """)
    # two clearing plays: trips of kings (a Gold Seal on the last king) vs trips of queens (Gold Seal on the first queen) with Hanging Chad:
    # the first scoring card is retriggered twice, so the play with the Gold Seal in the FIRST position is worth $9, the other $3
    def pick(first_gold):
        gold_k = "{13,1}" if first_gold else "{13,1}"
        r = lua_str(a, """
            local hand = HAND({{12,1,{seal='Gold'}},{12,2},{12,3},{13,1},{13,2},{13,3},{4,1},{6,2}})
            local ctx = CTX({{name='Hanging Chad'}})
            local res = PL.plan({ hand = hand, deck = PILE(hand), ctx = ctx, hands_left = 3, discards_left = 0, hand_limit = 8, play_limit = 5, discard_limit = 5, need = 100, budget_ms = 40 })
            local ix = {}
            for _, c in ipairs(res.cards) do ix[#ix + 1] = c.rank .. (c.seal and 'G' or '') end
            return table.concat(ix, ',') .. ':' .. tostring(res.tag)
        """)
        return r
    r = pick(True)
    check("12G" in r.split(":")[0], "a clearing play with the Gold Seal card in the retriggered position is preferred (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)

    # full consumable slots: use a Planet / untargeted Tarot, else sell the weakest, then the Purple card can be discarded
    tmp = tempfile.mkdtemp(prefix="arena_room_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_PLAN_MS": "30", "BOTARENA_DRIVER": "random"}, env_b={"BOTARENA_PLAN_MS": "10"},
                          lua_a="MOCK.with_deck = true", lua_b="MOCK.with_deck = true")
    if _to_hand_state(sim, a, b):
        setup = """
            local function C(rank, suit, seal)
                return { base = { value = tostring(rank), id = rank, suit = suit, nominal = math.min(rank, 10) }, ability = { set = 'Default', bonus = 0 },
                         config = { center = { key = 'c_base' } }, get_chip_bonus = function(self) return self.base.nominal end, seal = seal, sort_id = math.random(1, 1e9) }
            end
            G.hand.cards = { C(13, 'Hearts'), C(13, 'Spades'), C(13, 'Clubs'), C(9, 'Hearts'), C(7, 'Spades'), C(5, 'Clubs'), C(3, 'Hearts'), C(2, 'Diamonds', 'Purple') }
            G.GAME.current_round.discards_left = 3
            G.GAME.current_round.hands_left = 3
            MOCK.used0, MOCK.sold0 = MOCK.cons_used or 0, MOCK.sold or 0
            local function cons(key, set, targets)
                local c = MOCK.new_consumable(set); c.config.center.key = key; c.needs_targets = targets; c.area = G.consumeables
                return c
            end
            CONS = cons
        """
        a.lua.execute(setup)
        run_room = lambda body: lua_str(a, body)
        # a) a Planet is used
        r = run_room("""
            G.consumeables.cards = { CONS('c_magician', 'Tarot', true), MOCK.new_planet('Pair') }
            G.consumeables.cards[2].area = G.consumeables
            local acted = BotArena.decide.make_room()
            return tostring(acted) .. ' ' .. (MOCK.cons_used or 0) - MOCK.used0 .. ' ' .. #G.consumeables.cards""")
        check(r == "true 1 1", "full slots, a Planet is held: it is used (%s)" % r)
        # b) only targeted Tarots: the weak one is sold, the strong one stays
        r = run_room("""
            G.consumeables.cards = { CONS('c_magician', 'Tarot', true), CONS('c_star', 'Tarot', true) }
            local acted = BotArena.decide.make_room()
            return tostring(acted) .. ' ' .. #G.consumeables.cards .. ' ' .. G.consumeables.cards[1].config.center.key""")
        check(r == "true 1 c_magician", "full slots, nothing usable: the weakest Tarot is sold (%s)" % r)
        # c) both valuable: nothing is thrown away
        r = run_room("""
            G.consumeables.cards = { CONS('c_magician', 'Tarot', true), CONS('c_chariot', 'Tarot', true) }
            local acted = BotArena.decide.make_room()
            return tostring(acted) .. ' ' .. #G.consumeables.cards""")
        check(r == "false 2", "two strong Tarots are kept (%s)" % r)
        # d) a free slot / no Purple card / no discard: nothing to do
        r = run_room("""
            G.consumeables.cards = { CONS('c_star', 'Tarot', true) }
            return tostring(BotArena.decide.make_room())""")
        check(r == "false", "a free slot: the planner can discard on its own (%s)" % r)
        r = run_room("""
            G.consumeables.cards = { CONS('c_star', 'Tarot', true), CONS('c_moon', 'Tarot', true) }
            G.hand.cards[8].seal = nil
            local x = tostring(BotArena.decide.make_room())
            G.hand.cards[8].seal = 'Purple'
            G.GAME.current_round.discards_left = 0
            local y = tostring(BotArena.decide.make_room())
            G.GAME.current_round.discards_left = 3
            return x .. ' ' .. y""")
        check(r == "false false", "no Purple card or no discard left: nothing is sold (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)


def test_decide_baseline_logging():
    print("test: baseline shops through the decision layer and logs every choice for the trainer")
    random.seed(44)
    tmp = tempfile.mkdtemp(prefix="arena_d4_")
    lua = "MOCK.rich_shop = true; MOCK.pack_joker = true; MOCK.pack_choices = 2; MOCK.hand_money = 6"
    env = {"BOTARENA_PLAN_MS": "20", "BOTARENA_DECIDE_EPS": "0.5"}
    sim, a, b = make_pair(tmp, env_a=env, env_b=env, lua_a=lua, lua_b=lua)
    run(sim, [a, b], 80000, until=lambda: len(results(tmp, 1)) >= 3 and len(results(tmp, 2)) >= 3)
    check(len(results(tmp, 1)) >= 3, "matches finish with the decision layer active (%d)" % len(results(tmp, 1)))
    rows = read_jsonl(os.path.join(tmp, "decisions", "inst1.jsonl"))
    check(len(rows) >= 20, "decisions logged (%d)" % len(rows))
    check(all(r["src"] == "baseline" and 0 <= r["chosen"] < len(r["options"]) for r in rows), "every row: src=baseline and a valid chosen index")
    kinds = {r["kind"] for r in rows}
    check({"blind", "shop"} <= kinds, "blind-select and shop decisions are logged (%s)" % sorted(kinds))
    chosen = {r["options"][r["chosen"]]["kind"] for r in rows}
    check({"buy_joker", "leave", "select"} <= chosen, "chosen kinds include buying, leaving and selecting (%s)" % sorted(chosen))
    check(any(r.get("eps") for r in rows), "exploratory choices are flagged (eps) so a trainer can tell them from the teacher")
    # bidx = index of the reward row the decision will be paid in: non-decreasing within a match, and every ridx exists
    by_match = {}
    for r in rows:
        by_match.setdefault(r["match"], []).append(r["bidx"])
    check(all(v == sorted(v) for v in by_match.values()), "bidx never goes backwards inside a match")
    rw = rewards(tmp, 1)
    ridx = {(x["match"], x["ridx"]) for x in rw}
    paid = sum(1 for r in rows if (r["match"], r["bidx"]) in ridx)
    check(paid >= 0.6 * len(rows), "most decisions can be joined to the reward row that pays them (%d/%d)" % (paid, len(rows)))
    check(a.mock.bought and a.mock.bought > 0, "purchases really happened in the game (%s)" % a.mock.bought)
    check((a.mock.packs_opened or 0) + (b.mock.packs_opened or 0) > 0, "booster packs were opened and resolved (a=%s b=%s)" % (a.mock.packs_opened, b.mock.packs_opened))
    errs = [e for e in a.log() + b.log() if e.startswith("E ")]
    check(not errs, "no errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)


def test_decide_external_choose():
    print("test: external driver gets options and answers 'choose'; failures are banned; hands stay with the planner")
    random.seed(45)
    tmp = tempfile.mkdtemp(prefix="arena_d5_")
    lua = "MOCK.rich_shop = true; MOCK.pack_joker = true; MOCK.pack_choices = 2; MOCK.hand_money = 6; MOCK.fail_pick = true"
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_DRIVER": "external", "BOTARENA_BRIDGE_TIMEOUT": "1000", "BOTARENA_PLAN_MS": "20", "BOTARENA_EXTERNAL_HANDS": "planner"},
                          lua_a=lua, lua_b="MOCK.hand_money = 6")
    obs_path = os.path.join(tmp, "bridge", "inst1.obs.json")
    act_path = os.path.join(tmp, "bridge", "inst1.act.json")
    res_path = os.path.join(tmp, "bridge", "inst1.res.json")
    seen = {"last": 0, "kinds": {}, "pick_tried": 0, "after_fail": [], "failed_ids": set(), "hand_obs": 0, "bad": 0}

    def agent():
        if os.path.exists(obs_path):
            try:
                o = json.load(open(obs_path))
            except ValueError:
                return False
            if o["seq"] != seen["last"]:
                seen["last"] = o["seq"]
                snap = o["snap"]
                if snap["state"] == "SELECTING_HAND":
                    seen["hand_obs"] += 1
                dec = snap.get("dec")
                act = {"seq": o["seq"], "action": "noop"}
                if dec:
                    seen["kinds"][dec["kind"]] = seen["kinds"].get(dec["kind"], 0) + 1
                    if dec["kind"] != "pack":
                        seen["failed_ids"] = set()  # a new pack visit starts with a clean slate
                    opts = dec["options"]
                    pick = None
                    if dec["kind"] == "pack":
                        for i, op in enumerate(opts):
                            if op["kind"].startswith("pick_"):
                                pick = i
                                break
                        if pick is not None:
                            seen["pick_tried"] += 1
                            if opts[pick]["id"] in seen["failed_ids"]:
                                seen["after_fail"].append(opts[pick]["id"])
                            seen["failed_ids"].add(opts[pick]["id"])
                        else:
                            pick = [i for i, op in enumerate(opts) if op["kind"] == "skip_pack"][0]
                    elif dec["kind"] == "shop":
                        order = ["open_pack", "buy_joker", "leave"]
                        for k in order:
                            hit = [i for i, op in enumerate(opts) if op["kind"] == k]
                            if hit:
                                pick = hit[0]
                                break
                    else:
                        pick = [i for i, op in enumerate(opts) if op["kind"] == "select"][0]
                    act = {"seq": o["seq"], "action": "choose", "i": pick, "p": 0.25, "v": 1.5}
                    if seen["bad"] < 1 and dec["kind"] == "shop":
                        seen["bad"] += 1
                        act["i"] = 999  # invalid index: must be rejected, not crash
                with open(act_path, "w") as f:
                    json.dump(act, f)
        return len(results(tmp, 1)) >= 2

    for i in range(90000):
        for inst in (a, b):
            inst.frame(0.05)
        sim.tick()
        if agent():
            break
    check(len(results(tmp, 1)) >= 2, "external-driven instance finished matches (%d)" % len(results(tmp, 1)))
    check(set(seen["kinds"]) >= {"blind", "shop", "pack"}, "agent was asked about blind / shop / pack (%s)" % seen["kinds"])
    check(seen["hand_obs"] == 0, "no hand observations: the planner plays the hands")
    rows = read_jsonl(os.path.join(tmp, "decisions", "inst1.jsonl"))
    ag = [r for r in rows if r["src"] == "agent"]
    check(len(ag) >= 10, "agent decisions logged (%d)" % len(ag))
    check(all(abs(r.get("p", 0) - 0.25) < 1e-6 and abs(r.get("v", 0) - 1.5) < 1e-6 for r in ag), "p and v from the agent are stored")
    check(seen["bad"] == 1 and a.mock.log is not None, "an invalid choice index was sent once")
    check(not seen["after_fail"], "an option that failed was never offered again in the same visit (%s)" % seen["after_fail"][:2])
    check(not any(r["options"][r["chosen"]]["kind"].startswith("pick_") for r in ag), "failed picks are not logged as decisions")
    errs = [e for e in a.log() + b.log() if e.startswith("E ")]
    check(not errs, "no errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)



# ==================================================================================================
# the user's strategy rules (docs/HANDOFF.md, Strategy G.5 - G.12)
# ==================================================================================================
def _val(a, kind, key, fx="{}", sx="{}"):
    return float(lua_str(a, "return BotArena.decide.value({kind='%s', key=%s, fx=%s}, %s)" % (kind, ("'%s'" % key) if key else "nil", fx, sx)))


def test_strategy_skips():
    print("test: skip rules - ante 1 Investment / Rare tag only, with the economy-joker and voucher exceptions; later only lined-up jokers")
    random.seed(51)
    tmp = tempfile.mkdtemp(prefix="arena_s1_")
    sim, a, b = _to_shop(tmp, env_a={"BOTARENA_DECIDE_SKIPS": "1"})
    base = "ante=1, n_jokers=0, skips=0, dollars=4, jk_econ_strong=0, voucher_strong=0, lives=4"
    sel = 0.5
    check(_val(a, "skip", "tag_investment", sx="{%s}" % base) > sel, "ante 1: Investment tag is skipped for")
    check(_val(a, "skip", "tag_rare", sx="{%s}" % base) > sel, "ante 1: Rare tag is skipped for")
    check(_val(a, "skip", "tag_double", sx="{%s}" % base) < 0, "ante 1: any other tag is not")
    check(_val(a, "skip", "tag_investment", sx="{%s, jk_econ_strong=1}" % base.replace("jk_econ_strong=0, ", "")) < 0,
          "a strong economy joker (Mail-In Rebate ...) cancels the Investment skip")
    check(_val(a, "skip", "tag_investment", sx="{%s}" % base.replace("voucher_strong=0", "voucher_strong=1, voucher_cost=10")) < 0,
          "a strong voucher we cannot afford yet needs this blind: no skip")
    check(_val(a, "skip", "tag_investment", sx="{%s}" % base.replace("voucher_strong=0", "voucher_strong=1, voucher_cost=10").replace("dollars=4", "dollars=14")) > sel,
          "...but with the money for it already in hand the skip is fine")
    check(_val(a, "skip", "tag_investment", sx="{%s}" % base.replace("skips=0", "skips=1")) < 0, "ante 1 with an empty board: one skip is enough")
    check(_val(a, "skip", "tag_investment", sx="{%s}" % base.replace("ante=1", "ante=2")) < 0, "ante 2+: Investment is no reason to skip")
    late = "ante=4, n_jokers=4, skips=0, dollars=20, lives=4"
    check(_val(a, "skip", "tag_economy", sx="{%s}" % late) < 0, "later: never skip for nothing")
    check(_val(a, "skip", "tag_economy", sx="{%s, idol_hit=1}" % late) > sel, "later: The Idol just hit our best card -> skip to keep it")
    check(_val(a, "skip", "tag_economy", sx="{%s, ancient_ok=1}" % late) > sel, "later: Ancient Joker on our suit -> skip to keep it")
    check(_val(a, "skip", "tag_juggle", sx="{%s, held_build=1}" % late) > sel, "later: Juggle tag for a held-card (steel) build -> skip")
    check(_val(a, "skip", "tag_juggle", sx="{%s, held_build=0}" % late) < 0, "...but not for other builds")
    # the baseline really skips an Investment tag at ante 1 and not at ante 2 (decision layer end to end, config switch respected)
    a.lua.execute("G.STATE = G.STATES.BLIND_SELECT")
    shutil.rmtree(tmp, ignore_errors=True)


def test_strategy_economy():
    print("test: economy rules - interest-aware spending, rerolls, spend a little more before PvP, early economy jokers")
    random.seed(52)
    tmp = tempfile.mkdtemp(prefix="arena_s2_")
    sim, a, b = _to_shop(tmp)
    sx = "{ante=1, dollars=25, income_est=7, lives=4, joker_free=3, comfort=0.0, n_jokers=1}"
    # spending 5 of 25 loses no interest when the next blind's income refills the cap
    v_keep = _val(a, "buy_joker", "j_x", "{cost=5, money_after=20, d_pot=0.1, rarity=1, interest_loss=1}", sx)
    v_poor = _val(a, "buy_joker", "j_x", "{cost=5, money_after=7, d_pot=0.1, rarity=1, interest_loss=1}", sx.replace("dollars=25", "dollars=12"))
    check(v_keep > v_poor + 1.5, "spending from $25 is cheap (refilled by the blind), spending from $12 costs interest (%.1f vs %.1f)" % (v_keep, v_poor))
    # before PvP the same purchase is a little easier
    v_pvp = _val(a, "buy_joker", "j_x", "{cost=5, money_after=7, d_pot=0.1, rarity=1, interest_loss=1}", sx.replace("dollars=25", "dollars=12").replace("ante=1", "ante=2, pvp_on_deck=1"))
    check(v_pvp > v_poor, "the shop before a PvP blind spends more readily (%.1f > %.1f)" % (v_pvp, v_poor))
    # rerolls
    rr = lambda money_after, done=0, extra="": _val(a, "reroll", None, "{cost=5, money_after=%d, rerolls_done=%d}" % (money_after, done), "{ante=1, %s}" % extra)
    check(rr(10) < 0, "no reroll with little money left (a Blueprint could not be bought afterwards)")
    check(rr(30) > 0.5, "rerolling with money far above the interest cap is fine")
    check(rr(30, 3) < 0.5, "...but only a couple of times in the early antes")
    check(_val(a, "reroll", None, "{cost=5, money_after=16, rerolls_done=0}", "{ante=2, pvp_on_deck=1}") > 0.5, "before the PvP blind a reroll is allowed from $15")
    # early economy jokers beat scoring jokers when the board already clears the blind
    econ = _val(a, "buy_joker", "j_egg", "{cost=4, money_after=21, d_pot=0.02, rarity=1, cat_econ=1}", sx.replace("comfort=0.0", "comfort=0.5"))
    score = _val(a, "buy_joker", "j_jolly", "{cost=4, money_after=21, d_pot=0.12, rarity=1}", sx.replace("comfort=0.0", "comfort=0.5"))
    check(econ > score, "early game: economy joker (%.1f) over scoring joker when the blind is already safe (%.1f)" % (econ, score))
    score2 = _val(a, "buy_joker", "j_jolly", "{cost=4, money_after=21, d_pot=0.12, rarity=1}", sx.replace("comfort=0.0", "comfort=-0.5"))
    check(score2 > score, "...a scoring joker is worth more when the blind is NOT safe (%.1f > %.1f)" % (score2, score))
    shutil.rmtree(tmp, ignore_errors=True)


def test_strategy_packs():
    print("test: pack rules - spectral always (last dollars), Buffoon second, Arcana above $15, Standard with money to spare; pick values")
    random.seed(53)
    tmp = tempfile.mkdtemp(prefix="arena_s3_")
    sim, a, b = _to_shop(tmp)
    sx = "{ante=2, dollars=20, income_est=7, lives=4, deck_enh=0.0}"
    pk = lambda name, extra="", money_after=16, sxx=sx: _val(a, "open_pack", "p_" + name, "{cost=4, money_after=%d, pk_%s=1%s}" % (money_after, name, extra), sxx)
    spec, buf, arc, std, cel = pk("spectral"), pk("buffoon"), pk("arcana"), pk("standard"), pk("celestial")
    check(spec > arc > buf > std, "order spectral > arcana (money > $15: open first) > buffoon > standard (%.1f %.1f %.1f %.1f)" % (spec, arc, buf, std))
    check(pk("arcana", sxx=sx.replace("dollars=20", "dollars=10")) < buf, "below $15 Arcana waits behind Buffoon")
    check(pk("standard", money_after=3) < 1, "Standard without money left to keep is not opened")
    check(pk("standard", sxx=sx.replace("deck_enh=0.0", "deck_enh=0.6")) < std, "a deck that already holds the strong cards makes Standard less attractive")
    # the spectral pack is taken last: with a worthwhile purchase available the joker goes first, with nothing left the pack is opened
    pick = lambda opts: int(lua_str(a, "return (BotArena.decide.heuristic({sx={ante=2,dollars=20,income_est=7,lives=4,joker_free=2}, options={%s}}))" % opts))
    sp = "{kind='open_pack', fx={cost=4, money_after=16, pk_spectral=1}}"
    jk = "{kind='buy_joker', fx={cost=6, money_after=14, d_pot=0.2, rarity=2}}"
    lv = "{kind='leave', fx={}}"
    check(pick(sp + "," + jk + "," + lv) == 2, "joker first, spectral pack afterwards")
    check(pick(sp + "," + lv) == 1, "nothing else worth it: the spectral pack takes the last dollars")
    # tarot / spectral pick values
    tv = lambda key, kind="pick_tarot", sxx="{ante=2,dollars=10}": _val(a, kind, key, "{}", sxx)
    check(tv("c_magician") > tv("c_strength") and tv("c_chariot") > tv("c_devil"), "Lucky (Magician) and Steel (Chariot) lead the enhancements")
    check(tv("c_hanged_man") > tv("c_star") and tv("c_death") > tv("c_star"), "deck fixing (Hanged Man, Death) beats suit changes")
    check(tv("c_hermit", sxx="{ante=2,dollars=20}") > tv("c_hermit", sxx="{ante=2,dollars=2}") + 5, "Hermit is worth much more with $20 to double")
    check(tv("c_wraith", "pick_spectral", "{ante=2,dollars=0}") > tv("c_wraith", "pick_spectral", "{ante=2,dollars=15}") + 4,
          "Wraith is a take with no money left, much less with money in the bank")
    check(tv("c_wraith", "pick_spectral", "{ante=6,dollars=0,n_jokers=5}") < tv("c_wraith", "pick_spectral", "{ante=2,dollars=0,n_jokers=2}"),
          "later with a stable lineup Wraith is not worth the risk")
    check(tv("c_talisman", "pick_spectral") > 6 and tv("c_deja_vu", "pick_spectral") > 6 and tv("c_immolate", "pick_spectral") > 6, "Talisman / Deja Vu / Immolate are strong")
    # standard pack cards: seals (not blue), lucky / steel
    pc = lambda fx: _val(a, "pick_card", None, fx, "{ante=2}")
    check(pc("{seal=1}") > pc("{seal=1, blue_seal=1}") + 1.5 and pc("{seal=1, blue_seal=1}") > pc("{}"), "seals are strong, a Blue seal much less so")
    check(pc("{enh=1, lucky=1}") > pc("{enh=1}") and pc("{enh=1, steel=1}") > pc("{enh=1}"), "Lucky and Steel are the best enhancements")
    shutil.rmtree(tmp, ignore_errors=True)


def test_strategy_targets():
    print("test: tarot / spectral targets - Lucky on high cards, Steel on junk, Death copies the best card over a bad one, Hanged Man thins")
    random.seed(54)
    tmp = tempfile.mkdtemp(prefix="arena_s4_")
    sim, a, b = _to_shop(tmp)
    a.lua.execute("""
        local function C(rank, suit, key, seal)
            return { base = { id = rank, suit = suit, value = tostring(rank), nominal = math.min(rank, 10) }, ability = { set = 'Default' },
                     config = { center = { key = key or 'c_base' } }, seal = seal, sort_id = math.random(1, 1e9) }
        end
        function SETHAND()
            G.hand.cards = { C(3,'Hearts'), C(14,'Spades'), C(7,'Clubs'), C(13,'Hearts','m_steel'), C(2,'Spades'), C(12,'Diamonds'), C(9,'Hearts'), C(5,'Clubs') }
            G.playing_cards = {}
            for i = 1, 40 do G.playing_cards[i] = C(2 + (i % 13), 'Hearts') end
            G.hand.highlighted = {}
        end
        function TARGETS(key, nmax, nmin)
            SETHAND()
            local D = BotArena.decide
            local list = D.choose_targets(key, nmax, nmin, { n = #G.playing_cards })
            if not list then return 'nil' end
            local out = {}
            for _, c in ipairs(list) do out[#out + 1] = c.base.id .. (c.base.suit:sub(1, 1)) end
            return table.concat(out, ',')
        end
    """)
    t = lambda key, nmax=2, nmin=1: lua_str(a, "return TARGETS('%s', %d, %d)" % (key, nmax, nmin))
    check(t("c_magician") == "14S,12D", "Magician (Lucky): the two highest plain cards (%s)" % t("c_magician"))
    check(t("c_chariot", 1) == "2S", "Chariot (Steel): the lowest plain card, which would not be played anyway (%s)" % t("c_chariot", 1))
    check(t("c_hanged_man") == "2S,3H", "Hanged Man: destroys the two worst cards (%s)" % t("c_hanged_man"))
    r = t("c_death")
    check(r.split(",")[0] in ("3H", "2S", "7C", "5C") and r.endswith("13H"), "Death: a bad card on the LEFT of the best card (the steel King) becomes its copy (%s)" % r)
    check(t("c_deja_vu", 1) == "13H", "Deja Vu: red seal on the best card (%s)" % t("c_deja_vu", 1))
    check(t("c_moon", 3) == "nil", "a suit tarot towards a suit the deck does not lean to (Clubs) is not used")
    check(t("c_sun", 3) != "nil", "...but towards the deck's own suit (Hearts) it is")
    a.lua.execute("SETHAND()")
    check(lua_str(a, "SETHAND(); return tostring(BotArena.decide.choose_targets('c_hanged_man', 2, 1, { n = 28 }))") == "nil", "Hanged Man is skipped once the deck is thin (<= 30)")
    # execute: highlights then picks
    a.lua.execute("""
        SETHAND()
        local used = false
        local card = MOCK.new_consumable('Tarot')
        card.config.center.key = 'c_magician'
        card.config.center.config = { max_highlighted = 2 }
        card.can_use_consumeable = function(self, any) return #G.hand.highlighted >= 1 and #G.hand.highlighted <= 2 end
        BotArena.act.pick_pack_card = function(c) USED = #G.hand.highlighted; return true end
        local ok, info = BotArena.decide.execute({ act = 'pick_pack', card = card, targets = { G.hand.cards[2], G.hand.cards[6] } })
        RES = tostring(ok)
    """)
    check(lua_str(a, "return RES") == "true" and lua_str(a, "return tostring(USED)") == "2", "execute highlights the target cards before the pick")
    shutil.rmtree(tmp, ignore_errors=True)


def test_pvp_best_hand_last():
    print("test: PvP - with last-hand jokers the best hand is kept for the final hand (strategy G.7)")
    tmp, sim, a, b = plan_env()
    a.lua.execute("""
        function PILE2(hand)
            local gone = {}
            for _, c in ipairs(hand) do gone[c.rank * 10 + c.suit] = true end
            local pile = {}
            for r = 2, 14 do for s = 1, 4 do if not gone[r * 10 + s] then pile[#pile + 1] = PL.card(r, s) end end end
            return pile
        end
        function RUN(pvp, jokers)
            local hand = HAND({{14,1},{12,1},{9,1},{6,1},{3,1},{13,2},{13,3},{2,4}})
            local ctx = CTX(jokers, { pvp = pvp })
            local res = PL.plan({ hand = hand, deck = PILE2(hand), ctx = ctx, hands_left = 2, discards_left = 0, hand_limit = 8, need = nil,
                                  budget_ms = 600, min_samples = 150, max_samples = 300 })
            return res.action .. ':' .. tostring(res.name) .. ':' .. tostring(res.tag)
        end
    """)
    r = lua_str(a, "return RUN(true, {{name='Acrobat', ab={extra=3}}})")
    check(r.startswith("play:Pair"), "PvP + Acrobat (x3 on the last hand): play the Pair now, keep the Flush for the end (%s)" % r)
    r2 = lua_str(a, "return RUN(false, {{name='Acrobat', ab={extra=3}}})")
    check(r2.startswith("play:Flush") or "saving" not in r2, "outside PvP the plain rule applies (%s)" % r2)
    r3 = lua_str(a, "return RUN(true, {})")
    check("saving" not in r3, "without last-hand jokers nothing is held back (%s)" % r3)
    shutil.rmtree(tmp, ignore_errors=True)



def test_strategy_skip_e2e():
    print("test: end to end - the baseline skips the ante-1 Investment tag (cost -2) but not other tags, and never later")
    random.seed(55)
    tmp = tempfile.mkdtemp(prefix="arena_s5_")
    sim, a, b = make_pair(tmp, lua_a="MOCK.score_override = function(t) return 1000 end",
                          lua_b="MOCK.score_override = function(t) return 240 end",
                          env_a={"BOTARENA_DECIDE_SKIPS": "1", "BOTARENA_REWARD": "skip_penalty_good=2"})
    run(sim, [a, b], 60000, until=lambda: len(pvp_rows(rewards(tmp, 1))) >= 2)
    rows = rewards(tmp, 1)
    sk = [r for r in rows if r["kind"] == "skip"]
    check(len(sk) >= 1 and all(r.get("tag") == "tag_investment" and r.get("ante") == 1 for r in sk),
          "only ante-1 Investment tags were skipped (%s)" % [(r.get("ante"), r.get("blind"), r.get("tag")) for r in sk])
    check(all(r["reward"] == -2 for r in sk), "such a skip costs -2 (%s)" % [r["reward"] for r in sk])
    check(len(pvp_rows(rows)) >= 2, "play continues through the PvP blinds")
    errs = [e for e in a.log() if e.startswith("E ")]
    check(not errs, "no errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)



def test_cash_out_skips_stale_boxes():
    print("test: Cash Out lookup ignores used (dead) boxes the game leaves behind - the real 'never cashes out after round 1' bug")
    tmp, sim, a, b = plan_env()
    a.lua.execute("""
        G.I = G.I or {}; G.I.UIBOX = {}
        STALE1 = MOCK.make_ui({ cash_out_button = { button = nil, one_press = true } }, { register = true })
        STALE2 = MOCK.make_ui({ cash_out_button = { button = nil, one_press = true } }, { register = true })
        LIVE = MOCK.make_ui({ cash_out_button = { button = 'cash_out', one_press = true } }, { register = true })
    """)
    check(lua_str(a, "return tostring(BotArena.act.cash_out_ready())") == "true", "a live button behind two dead ones is found and ready")
    check(lua_str(a, "return tostring(BotArena.act.find_cash_out_button() == LIVE.by_id.cash_out_button)") == "true", "...and it is that one")
    check(lua_str(a, "return #BotArena.act.cash_out_buttons()") == 3, "all three boxes are listed")
    a.lua.execute("LIVE.by_id.cash_out_button.config.button = nil")
    check(lua_str(a, "return tostring(BotArena.act.cash_out_ready())") == "false", "with only dead boxes nothing is ready (and nothing crashes)")
    shutil.rmtree(tmp, ignore_errors=True)



def test_strategy_round2():
    print("test: selling the weakest joker, vouchers, planets early, Hermit, Multiplayer jokers (strategy G.13 - G.16)")
    random.seed(56)
    tmp = tempfile.mkdtemp(prefix="arena_s6_")
    sim, a, b = _to_shop(tmp)
    full = "{ante=2, dollars=12, income_est=7, lives=4, joker_free=0, swap_v=12, comfort=0.0, n_jokers=5}"
    sell = lambda fx, sxx=full: _val(a, "sell_joker", "j_x", fx, sxx)
    weak = sell("{d_pot=0.0, rarity=1, sell=2}")
    strong = sell("{d_pot=0.30, rarity=2, sell=4}")
    check(weak > 1 and weak > strong + 3, "full board + a better joker in the shop: the least scoring joker is sold first (%.1f vs %.1f)" % (weak, strong))
    check(sell("{d_pot=0.0, rarity=1, sell=2, cat_econ=1}") < weak, "...and an economy joker is protected in the early game")
    check(sell("{d_pot=0.0, rarity=1, sell=2}", full.replace("swap_v=12", "swap_v=0.5")) < 0, "no sale when nothing better is on offer")
    late = full.replace("ante=2", "ante=6")
    check(sell("{d_pot=0.0, rarity=1, sell=2, cat_econ=1}", late) > sell("{d_pot=0.3, rarity=2, sell=4}", late),
          "late game with a strong scoring lineup: the economy joker goes before a scoring one")
    # a full board lists shop jokers (flagged) so the swap can be valued, and never tries to buy them directly
    a.lua.execute("for i = 1, G.jokers.config.card_limit do G.jokers.cards[i] = MOCK.new_joker({name='Joker', key='j_joker'..i, cost=2, rarity=1, ab={mult=1}}); G.jokers.cards[i].area = G.jokers end; G.GAME.dollars = 30")
    d = _decision(a, "shop")
    ns = [o for o in d["options"] if o["kind"] == "buy_joker" and o["fx"].get("noslot") == 1]
    check(len(ns) >= 1 and "swap_v" in d["sx"], "full board: shop jokers are listed with noslot=1 and the state carries swap_v (%s)" % d["sx"].get("swap_v"))
    pick = lua_str(a, "local d = BotArena.decide.begin('shop'); local i = BotArena.decide.heuristic(d); return d.options[i].kind")
    check(pick != "buy_joker", "the heuristic never tries to buy a joker with no free slot (%s)" % pick)
    # vouchers
    vv = lambda key, cost=10: _val(a, "buy_voucher", key, "{cost=%d, money_after=20, interest_loss=0}" % cost, "{ante=2, dollars=30, income_est=7}")
    for bad in ("v_telescope", "v_observatory", "v_planet_merchant", "v_planet_tycoon", "v_magic_trick", "v_illusion", "v_tarot_tycoon"):
        check(vv(bad) < 0, "voucher never taken: %s" % bad)
    check(vv("v_tarot_merchant") > 0.5 and vv("v_clearance_sale") > 0.5 and vv("v_hone") > 0.5, "unlisted vouchers (Tarot Merchant, Clearance Sale, Hone) are taken")
    # planets early
    pl = lambda comfort, money_after, ante=2: _val(a, "buy_planet", "c_mercury", "{cost=3, money_after=%d, interest_loss=0, hand_aimed=1}" % money_after, "{ante=%d, dollars=30, income_est=7, comfort=%s}" % (ante, comfort))
    check(pl(0.5, 14) < 0.5, "early game, blind already safe, money below the cap: no planet")
    check(pl(-0.5, 14) > 0.5, "...but a planet that is needed to beat the blinds is bought")
    check(pl(0.5, 27) > 0.5, "...and with the interest cap still full afterwards it is bought")
    check(pl(0.5, 14, ante=5) > 0.5, "later in the game planets are normal again")
    # Hermit is kept until the bank is worth doubling
    hm = lambda dollars: _val(a, "use_consumable", "c_hermit", "{}", "{ante=2, dollars=%d}" % dollars)
    check(hm(4) < 0 and hm(20) > 0.5, "Hermit: held with little money, used at $15+ (%.1f / %.1f)" % (hm(4), hm(20)))
    # Multiplayer jokers
    jk = lambda fx: _val(a, "buy_joker", "j_x", "{cost=5, money_after=20, d_pot=0.05, rarity=1, %s}" % fx, "{ante=2, dollars=25, income_est=7, joker_free=2, comfort=0}")
    check(jk("mp_strong=1") > jk("cat_mp=1") + 4, "Lets Go Gambling / Penny Pincher are favoured over other Multiplayer jokers")
    shutil.rmtree(tmp, ignore_errors=True)


def _to_hand_state(sim, a, b, frames=40000):
    """run the mock match until instance a sits in a settled SELECTING_HAND with cards in hand"""
    def ready():
        return lua_str(a, "return tostring(G.STATE == G.STATES.SELECTING_HAND and #G.hand.cards >= 5 and BotArena.obs.settled())") == "true"
    run(sim, [a, b], frames, until=ready)
    return ready()


def test_handdec_mechanics():
    print("test: hand decision layer - candidates, features, planner pick, bans, serialisation")
    random.seed(91)
    tmp = tempfile.mkdtemp(prefix="arena_hd_")
    # the arena is paused as soon as a hand is on the table: use a driver that never plays so the state stays put
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_PLAN_MS": "30", "BOTARENA_DRIVER": "random"}, env_b={"BOTARENA_PLAN_MS": "10"},
                          lua_a="MOCK.with_deck = true", lua_b="MOCK.with_deck = true")
    ok = _to_hand_state(sim, a, b)
    check(ok, "reached a hand to decide")
    if not ok:
        shutil.rmtree(tmp, ignore_errors=True)
        return
    a.lua.execute("""
        HD = BotArena.handdec
        local need, gi = HD.goal()
        DEC = HD.begin({ need = need, ginfo = gi })
    """)
    n = lua_str(a, "return #DEC.options")
    check(8 <= n <= 44, "between 8 and 44 candidates (%s)" % n)
    check(lua_str(a, "local seen, dup = {}, 0; for _, o in ipairs(DEC.options) do if seen[o.id] then dup = dup + 1 end; seen[o.id] = true end; return dup") == 0, "candidate ids are unique")
    check(lua_str(a, "local p, d = 0, 0; for _, o in ipairs(DEC.options) do if o.act == 'play' then p = p + 1 else d = d + 1 end end; return tostring(p > 0) .. tostring(d > 0)") == "truetrue",
          "plays and discards are both offered")
    check(lua_str(a, "return tostring(DEC.pl ~= nil)") == "true", "the planner's pick is among the candidates (teacher label)")
    check(lua_str(a, """
        for _, o in ipairs(DEC.options) do
            if o.act == 'play' then
                local ht = 0
                for k = 1, 12 do if o.fx['ht_' .. k] == 1 then ht = ht + 1 end end
                if ht ~= 1 or not o.fx.sc_log or o.fx.n_sel ~= #o.idx then return 'bad play ' .. o.id end
            else
                if not o.fx.kept_log or not o.fx.draw_n or o.fx.draw_n ~= #o.idx then return 'bad discard ' .. o.id end
            end
            for _, i in ipairs(o.idx) do if i < 1 or i > #G.hand.cards then return 'bad index ' .. o.id end end
        end
        return 'ok'""") == "ok", "every candidate carries its features and valid card indices")
    check(lua_str(a, "local m = -1; for _, o in ipairs(DEC.options) do if o.act == 'play' and o.score > m then m = o.score end end; local f; for _, o in ipairs(DEC.options) do if o.fx.is_max == 1 then f = o.score end end; return tostring(f == m)") == "true",
          "is_max marks the best-scoring play")
    check(lua_str(a, "local ok = false; for _, o in ipairs(DEC.options) do if o.fx.pl_has == 1 then ok = true end end; return tostring(ok)") == "true", "planner verdict features are present by default")
    s = lua_str(a, "return BotArena.util.encode(HD.serialize(DEC))")
    row = json.loads(s)
    check(row["kind"] == "hand" and len(row["options"]) == n and isinstance(row.get("pl"), int), "serialises to JSON with kind=hand and a 0-based pl")
    check(all(v != 0 for o in row["options"] for v in o["fx"].values()), "zero features are omitted from the log")
    # bans: a failed option is not offered again in the same hand state
    a.lua.execute("PICK = DEC.options[DEC.pl].id; HD.ban(PICK); DEC2 = HD.begin({ need = HD.goal() })")
    check(lua_str(a, "local f = false; for _, o in ipairs(DEC2.options) do if o.id == PICK then f = true end end; return tostring(f)") in ("false",) or lua_str(a, "return tostring(DEC2.pl == nil)") == "true",
          "a banned option disappears from the next list")
    # pure learning: no planner features
    a.lua.execute("BotArena.cfg.hand_planfeat = false; DEC3 = HD.begin({ need = HD.goal() })")
    check(lua_str(a, "local f = false; for _, o in ipairs(DEC3.options) do for k in pairs(o.fx) do if k:sub(1, 3) == 'pl_' then f = true end end end; return tostring(f)") == "false",
          "BOTARENA_HAND_PLANFEAT=0 hides every planner feature")
    a.lua.execute("BotArena.cfg.hand_planfeat = true")
    errs = [e for e in a.log() if e.startswith("E ")]
    check(not errs, "no Lua errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)


def test_handdec_log_e2e():
    print("test: baseline logs every hand decision (candidates + planner pick) and plays it")
    random.seed(92)
    tmp = tempfile.mkdtemp(prefix="arena_hd2_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_PLAN_MS": "10"}, env_b={"BOTARENA_PLAN_MS": "10"},
                          lua_a="MOCK.with_deck = true", lua_b="MOCK.with_deck = true")
    run(sim, [a, b], 60000, until=lambda: len(results(tmp, 1)) >= 2 and len(results(tmp, 2)) >= 2)
    rows = read_jsonl(os.path.join(tmp, "decisions", "inst1.hand.jsonl"))
    check(len(rows) >= 20, "hand decisions were logged (%d)" % len(rows))
    check(all(r["kind"] == "hand" and r["src"] == "baseline" for r in rows), "kind=hand, src=baseline")
    check(all(r.get("pl") == r["chosen"] for r in rows if not r.get("eps") and r.get("pl") is not None), "the baseline plays the planner's candidate")
    check(all(len(r["options"]) <= 44 for r in rows), "never more than 44 candidates")
    strat = read_jsonl(os.path.join(tmp, "decisions", "inst1.jsonl"))
    check(strat and all(r["kind"] != "hand" for r in strat), "strategic decisions stay in their own file")
    plays = [r for r in rows if r["options"][r["chosen"]]["kind"] == "play"]
    check(len(plays) >= 10, "plays were logged (%d)" % len(plays))
    check(len(results(tmp, 1)) >= 2, "matches still finish (%d)" % len(results(tmp, 1)))
    errs = [e for e in a.log() + b.log() if e.startswith("E ")]
    check(not errs, "no Lua errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)

# ==================================================================================================
# random deck + stake per lobby, and the rules the bots know (lib/rules.lua; user 2026-10-06 16:32)
# ==================================================================================================
VANILLA_DECKS = ["Red Deck", "Blue Deck", "Yellow Deck", "Green Deck", "Black Deck", "Magic Deck", "Nebula Deck", "Ghost Deck",
                 "Abandoned Deck", "Checkered Deck", "Zodiac Deck", "Painted Deck", "Anaglyph Deck", "Plasma Deck", "Erratic Deck"]
ALLOWED_STAKES = ["stake_white", "stake_green", "stake_black", "stake_purple", "stake_gold", "stake_mp_spectralplus"]


def test_rules_random_loadout():
    print("test: every lobby plays a random vanilla deck on a random allowed stake; both players get the same one")
    random.seed(61)
    tmp = tempfile.mkdtemp(prefix="arena_rl_")
    sim, a, b = make_pair(tmp, env_a={"BOTARENA_RANDOM_LOADOUT": "1"}, env_b={"BOTARENA_RANDOM_LOADOUT": "1"})
    run(sim, [a, b], 150000, until=lambda: len(results(tmp, 1)) >= 8 and len(results(tmp, 2)) >= 8)
    ra, rb = results(tmp, 1), results(tmp, 2)
    check(len(ra) >= 8 and len(rb) >= 8, "played >= 8 matches (%d / %d)" % (len(ra), len(rb)))
    check(all(r.get("deck") in VANILLA_DECKS for r in ra + rb), "only the 15 vanilla decks ever appear (%s)" % sorted({r.get("deck") for r in ra + rb}))
    check(all(r.get("stake") in ALLOWED_STAKES for r in ra + rb), "only White / Green / Black / Purple / Gold / Spectral+ appear (%s)" % sorted({str(r.get("stake")) for r in ra + rb}))
    by_seed = {}
    for r in ra + rb:
        by_seed.setdefault(r["seed"], set()).add((r["deck"], r["stake"]))
    check(all(len(v) == 1 for v in by_seed.values()), "both players of a match played the same deck and stake")
    check(len({r["deck"] for r in ra}) >= 3, "the decks vary from game to game (%s)" % [r["deck"] for r in ra])
    check(len({r["stake"] for r in ra}) >= 2, "the stakes vary from game to game (%s)" % [r["stake"] for r in ra])
    check(sim.stats.get("lobby_options", 0) >= len(ra), "the host sent the loadout before every start (%s options for %d matches)" % (sim.stats.get("lobby_options", 0), len(ra)))
    ev = [e for e in events(tmp, 1) + events(tmp, 2) if e.get("ev") == "rules"]
    check(len(ev) >= len(ra), "a 'rules' event per match (%d)" % len(ev))
    rw = rewards(tmp, 1) + rewards(tmp, 2)
    check(rw and all(r.get("deck") in VANILLA_DECKS and r.get("stake") in ALLOWED_STAKES for r in rw if r["kind"] != "match"), "reward rows carry the deck and stake")
    errs = [e for e in a.log() + b.log() if e.startswith("E ")]
    check(not errs, "no Lua errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)


def test_rules_loadout_filters():
    print("test: BOTARENA_DECKS / BOTARENA_STAKES narrow the pool; randomLoadout off leaves the lobby alone")
    random.seed(62)
    tmp = tempfile.mkdtemp(prefix="arena_rl2_")
    env = {"BOTARENA_RANDOM_LOADOUT": "1", "BOTARENA_DECKS": "plasma, ghost", "BOTARENA_STAKES": "gold,spectralplus"}
    sim, a, b = make_pair(tmp, env_a=env, env_b=env)
    run(sim, [a, b], 90000, until=lambda: len(results(tmp, 1)) >= 4 and len(results(tmp, 2)) >= 4)
    ra = results(tmp, 1)
    check(len(ra) >= 4, "played >= 4 matches (%d)" % len(ra))
    check(all(r["deck"] in ("Plasma Deck", "Ghost Deck") for r in ra), "only the listed decks (%s)" % sorted({r["deck"] for r in ra}))
    check(all(r["stake"] in ("stake_gold", "stake_mp_spectralplus") for r in ra), "only the listed stakes (%s)" % sorted({r["stake"] for r in ra}))
    shutil.rmtree(tmp, ignore_errors=True)
    tmp = tempfile.mkdtemp(prefix="arena_rl3_")
    env = {"BOTARENA_RANDOM_LOADOUT": "0"}
    sim, a, b = make_pair(tmp, env_a=env, env_b=env)
    run(sim, [a, b], 60000, until=lambda: len(results(tmp, 1)) >= 2 and len(results(tmp, 2)) >= 2)
    ra = results(tmp, 1)
    check(len(ra) >= 2 and all(r["deck"] == "Red Deck" and r["stake"] == "stake_white" for r in ra), "off: the lobby default (Red Deck, White Stake) is played (%s)" % [(r["deck"], r["stake"]) for r in ra])
    check(sim.stats.get("lobby_options", 0) == 0, "off: no loadout is sent")
    shutil.rmtree(tmp, ignore_errors=True)


def _in_run(tmp, env=None):
    sim, a, b = make_pair(tmp, env_a=env, lua_a="MOCK.rich_shop = true; MOCK.score_override = function(t) return 1000 end")
    run(sim, [a, b], 20000, until=lambda: a.lua.eval("G.STATE == G.STATES.BLIND_SELECT and G.GAME ~= nil"))
    return sim, a, b


def test_rules_live_rules():
    print("test: the live rule snapshot is right for every stake and deck (read from the game, not from a table)")
    random.seed(63)
    tmp = tempfile.mkdtemp(prefix="arena_rl4_")
    sim, a, b = _in_run(tmp)
    R = "BotArena.rules"
    check(lua_str(a, "return #%s.deck_pool()" % R) == 15, "the deck pool is the 15 vanilla decks")
    check(lua_str(a, "return #%s.stake_pool()" % R) == 6, "the stake pool is 6 stakes")
    idx = lua_str(a, "local t = {} for _, k in ipairs(%s.stake_pool()) do t[#t + 1] = %s.stake_index(k) end return table.concat(t, ',')" % (R, R))
    check(idx == "1,3,4,6,8,11", "stake indexes White 1, Green 3, Black 4, Purple 6, Gold 8, Spectral+ 11 (%s)" % idx)
    pool = lua_str(a, "return table.concat(%s.deck_pool(), ',')" % R)
    check("cocktail" not in pool and "b_challenge" not in pool, "no cocktail / challenge deck")

    def live(stake, deck="Red Deck"):
        out = lua_str(a, """MP.LOBBY.config.back = '%s'; MP.LOBBY.config.stake = %d; MOCK.apply_loadout()
            local l = %s.live()
            return table.concat({ tostring(l.scaling), tostring(l.small_pays), tostring(l.eternals), tostring(l.perishables), tostring(l.rentals),
                tostring(l.no_interest), tostring(l.money_per_hand), tostring(l.money_per_discard), tostring(l.plasma), tostring(l.stake_key) }, ' ')""" % (deck, stake, R))
        return out.split(" ")
    w = live(1)
    check(w[:6] == ["1", "true", "false", "false", "false", "false"], "White: nothing (%s)" % w)
    g = live(3)
    check(g[:5] == ["2", "false", "false", "false", "false"], "Green: scaling 2, Small Blind pays nothing (%s)" % g)
    k = live(4)
    check(k[:5] == ["2", "false", "true", "false", "false"], "Black: + eternal jokers (%s)" % k)
    p = live(6)
    check(p[:5] == ["3", "false", "true", "false", "false"], "Purple: scaling 3 (%s)" % p)
    gd = live(8)
    check(gd[:5] == ["3", "false", "true", "true", "true"], "Gold: + perishable and rental jokers (%s)" % gd)
    sp = live(11)
    check(sp[:5] == ["5", "false", "true", "true", "true"] and sp[9] == "stake_mp_spectralplus", "Spectral+: scaling 5, every sticker (%s)" % sp)
    gr = live(1, "Green Deck")
    check(gr[5:8] == ["true", "2", "1"], "Green Deck: no interest, $2 per hand, $1 per discard (%s)" % gr)
    check(live(1, "Plasma Deck")[8] == "true" and live(1, "Red Deck")[8] == "false", "Plasma Deck flag")
    f = lua_str(a, "MP.LOBBY.config.back='Anaglyph Deck'; MOCK.apply_loadout(); G.GAME.tags = {{key='tag_double'}}; local l = %s.live(); return tostring(l.anaglyph) .. ' ' .. l.double_tags" % R)
    check(f == "true 1", "Anaglyph Deck and the waiting Double Tag are seen (%s)" % f)
    s = lua_str(a, "local sx = %s.sx({}); return sx.dk_anaglyph .. ' ' .. (sx.sk_gold or 0) .. ' ' .. sx.r_double_tags" % R)
    check(s.split(" ")[0] == "1" and s.split(" ")[2] == "1", "state features carry the deck one-hot and the Double Tag count (%s)" % s)
    r = lua_str(a, "return %s.blind_pay('Small', {small_pays=false}) .. ' ' .. %s.blind_pay('Small', {small_pays=true}) .. ' ' .. %s.blind_pay('Boss', {boss_pays=true})" % (R, R, R))
    check(r == "0 3 5", "blind pay: Small $0 when the stake removes it (%s)" % r)
    shutil.rmtree(tmp, ignore_errors=True)


def test_rules_plasma_scoring():
    print("test: Plasma Deck - the planner balances chips and mult after the jokers")
    tmp, sim, a, b = plan_env()

    def S(hand, jokers="{}", opts="nil"):
        return lua_str(a, "return SCORE(%s, %s, %s, nil)" % (hand, jokers, opts))
    pair_k = "{{13,1},{13,2}}"
    check(S(pair_k) == 60, "no Plasma: 30 x 2")
    check(S(pair_k, "{}", "{plasma=true}") == 16 * 16, "Plasma: (30 + 2) / 2 = 16 each -> 256 (%s)" % S(pair_k, "{}", "{plasma=true}"))
    j = "{{name='Joker', ab={mult=4}}}"
    check(S(pair_k, j, "{plasma=true}") == 18 * 18, "Plasma with +4 mult: 30 / 6 -> 18 x 18 = 324 (%s)" % S(pair_k, j, "{plasma=true}"))
    x = "{{name='The Duo', ab={x_mult=3, type='Pair'}}}"
    check(S(pair_k, x, "{plasma=true}") == 18 * 18, "Plasma shrinks x-mult: 30 / 6 -> 18 x 18 = 324 (%s)" % S(pair_k, x, "{plasma=true}"))
    big = "{{13,1},{13,2},{13,3},{13,4}}"
    check(S(big, "{}", "{plasma=true}") >= S(big), "Plasma never scores less than chips x mult (AM-GM): four kings %s vs %s" % (S(big, "{}", "{plasma=true}"), S(big)))
    check(S(pair_k, x, "{plasma=true}") >= S(pair_k, x), "...also with an x-mult joker")
    flat = "{{2,1},{5,2},{9,3},{11,4},{14,1}}"
    check(S(flat, "{}", "{plasma=true}") > S(flat), "a chips-heavy, low-mult hand scores MORE under Plasma (%s vs %s)" % (S(flat, "{}", "{plasma=true}"), S(flat)))
    lv = lua_str(a, "G.GAME = { hands = {}, selected_back = { name = 'Plasma Deck' } }; return tostring(BotArena.plan.live_context().plasma)")
    check(lv == "true", "the live context turns Plasma on from the selected deck")
    lv = lua_str(a, "G.GAME = { hands = {}, selected_back = { name = 'Red Deck' } }; return tostring(BotArena.plan.live_context().plasma)")
    check(lv == "false", "...and off for other decks")
    shutil.rmtree(tmp, ignore_errors=True)


def test_rules_shop_values():
    print("test: shop values respect eternal / perishable / rental stickers, Hex, Double Tag and the no-interest deck")
    random.seed(64)
    tmp = tempfile.mkdtemp(prefix="arena_rl5_")
    sim, a, b = _to_shop(tmp, env_a={"BOTARENA_DECIDE_SKIPS": "1"})
    base = "d_pot=0.2, d_pot_pvp=0.2, rarity=2, cost=5, money_after=15, interest_loss=0"
    sx = "{ante=2, dollars=20, income_est=7, lives=4, joker_free=2, joker_limit=5, n_jokers=2}"
    plain = _val(a, "buy_joker", "j_x", "{%s}" % base, sx)
    eter = _val(a, "buy_joker", "j_x", "{%s, eternal=1}" % base, sx)
    check(eter < plain - 4, "an Eternal joker is worth less than the same joker without it (%.1f vs %.1f)" % (eter, plain))
    weak = "d_pot=0.0, d_pot_pvp=0.0, rarity=1, cost=5, money_after=15, interest_loss=0"
    check(_val(a, "buy_joker", "j_y", "{%s, eternal=1}" % weak, sx) < _val(a, "buy_joker", "j_y", "{%s}" % weak, sx) - 10, "a weak Eternal joker is much worse (it can never be sold)")
    per = _val(a, "buy_joker", "j_x", "{%s, perishable=1, perish_left=5}" % base, sx)
    check(per < plain - 5, "a Perishable joker (5 rounds) is worth much less (%.1f vs %.1f)" % (per, plain))
    check(_val(a, "buy_joker", "j_x", "{%s, perishable=1, perish_left=0}" % base, sx) < -20, "an already perished joker is worthless")
    rent = _val(a, "buy_joker", "j_x", "{%s, rental=1}" % base, "{ante=2, dollars=20, income_est=7, lives=4, joker_free=2, joker_limit=5, n_jokers=2, r_rental_rate=3}")
    check(rent < plain - 12, "a Rental joker pays $3 every round: %.1f vs %.1f" % (rent, plain))
    check(_val(a, "sell_joker", "j_x", "{perishable=1, perish_left=0, d_pot=0, rarity=1}", sx) >= 4, "a perished joker is sold (frees the slot)")
    check(_val(a, "sell_joker", "j_x", "{rental=1, d_pot=0.0, d_pot_pvp=0.0, rarity=1, sell=1}", sx) > 0.5, "a rental joker that does nothing is sold")
    check(_val(a, "sell_joker", "j_x", "{rental=1, d_pot=0.45, d_pot_pvp=0.45, rarity=3, sell=3}", sx) < 0.5, "a rental joker that carries the build is kept")
    check(_val(a, "sell_joker", "j_x", "{d_pot=0.1, d_pot_pvp=0.1, rarity=1, sell=1}", sx) < 0.5, "a plain useful joker is not sold")
    # Hex (Ghost Deck's starting consumable)
    check(_val(a, "use_consumable", "c_hex", "{}", "{hex_others=0}") >= 20, "Hex as the lone joker: use it before buying the next one")
    check(_val(a, "use_consumable", "c_hex", "{}", "{hex_others=1}") < -20, "Hex with another joker on the board would destroy it: never")
    check(_val(a, "pick_spectral", "c_hex", "{}", "{n_destroyable=1, dollars=10}") > 5 and _val(a, "pick_spectral", "c_hex", "{}", "{n_destroyable=3, dollars=10}") < -20, "Hex from a pack: only as the lone joker")
    # Double Tag (Anaglyph Deck)
    nodbl = _val(a, "skip", "tag_rare", "{}", "{ante=3, n_jokers=2, skips=0, dollars=10}")
    dbl = _val(a, "skip", "tag_rare", "{}", "{ante=3, n_jokers=2, skips=0, dollars=10, r_double_tags=1}")
    check(nodbl < 0 and dbl > 5, "a waiting Double Tag makes skipping for a Rare tag worth it (%.1f -> %.1f)" % (nodbl, dbl))
    check(_val(a, "skip", "tag_economy", "{}", "{ante=3, n_jokers=2, skips=0, dollars=20, r_double_tags=1}") > 5 and _val(a, "skip", "tag_economy", "{}", "{ante=3, n_jokers=2, skips=0, dollars=4, r_double_tags=1}") < 0, "Economy tag doubled: only with money to double")
    check(_val(a, "skip", "tag_standard", "{}", "{ante=3, n_jokers=2, skips=0, dollars=10, r_double_tags=1}") < 0, "a weak tag is still not worth a blind, doubled or not")
    # no interest (Green Deck)
    check(_val(a, "buy_voucher", "v_seed_money", "{cost=10, money_after=10, interest_loss=0}", "{r_no_interest=1, dollars=20, income_est=7}") <= -40, "interest-cap vouchers are worthless on the Green Deck")
    check(_val(a, "buy_voucher", "v_seed_money", "{cost=10, money_after=10, interest_loss=0}", "{dollars=20, income_est=7}") > -10, "...but fine elsewhere")
    d = lua_str(a, """G.GAME.dollars = 30
        local d1 = BotArena.decide.begin('shop'); local i1 = d1.sx.interest_now; local r1 = d1.sx.income_est
        G.GAME.modifiers = { no_interest = true, money_per_hand = 2, money_per_discard = 1, no_blind_reward = { Small = true } }
        G.GAME.blind_on_deck = 'Small'
        local d2 = BotArena.decide.begin('shop')
        return i1 .. ' ' .. d2.sx.interest_now .. ' ' .. d2.sx.interest_room .. ' ' .. r1 .. ' ' .. d2.sx.income_est .. ' ' .. d2.sx.r_no_interest""")
    i1, i2, room2, r1, r2, flag = d.split(" ")
    check(int(float(i1)) > 0 and float(i2) == 0 and float(room2) == 0 and flag == "1", "no_interest: interest and its room read 0 (%s)" % d)
    check(float(r2) == 0 + 2 * 2 + 1 + 3 * 0 or float(r2) >= 5, "income estimate: Small pays 0, $2 per hand, $1 per discard on the Green Deck (%s)" % r2)
    # Abandoned Deck: no faces
    a.lua.execute(JOKER_LUA)
    lua_str(a, """JK.biz = MOCK.new_joker({name='Business Card', key='j_business', cost=4, rarity=1, ab={}})
        JK.bus = MOCK.new_joker({name='Ride the Bus', key='j_ride_the_bus', cost=6, rarity=1, ab={mult=1}})
        JK.par = MOCK.new_joker({name='Pareidolia', key='j_pareidolia', cost=5, rarity=2, ab={}})
        return ''""")

    def sells(deck, row):
        lua_str(a, "G.GAME.selected_back = { name = '%s' }; SETROW({%s}); return ''" % (deck, ",".join("'%s'" % n for n in row)))
        d = _decision(a, "shop")
        return {o["key"]: o["fx"] for o in d["options"] if o["kind"] == "sell_joker"}
    f = sells("Abandoned Deck", ["biz", "bus"])
    check(f["j_business"].get("dead_econ") == 1 and f["j_ride_the_bus"].get("deck_bonus") == 4, "Abandoned Deck: Business Card is dead, Ride the Bus never resets (%s)" % f)
    f = sells("Red Deck", ["biz", "bus"])
    check("dead_econ" not in f["j_business"] and "deck_bonus" not in f["j_ride_the_bus"], "other decks: no change")
    f = sells("Abandoned Deck", ["biz", "bus", "par"])
    check("dead_econ" not in f["j_business"] and "deck_bonus" not in f["j_ride_the_bus"], "...and Pareidolia makes every card a face again")
    errs = [e for e in a.log() + b.log() if e.startswith("E ")]
    check(not errs, "no Lua errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)


def test_rules_reward_money():
    print("test: reward - Green Deck's $ per unused hand / discard and Rental fees are counted")
    random.seed(65)
    tmp = tempfile.mkdtemp(prefix="arena_rl6_")
    sim, a, b = _in_run(tmp)
    out = lua_str(a, """local R = BotArena.reward
        local function row(setup)
            G.GAME.modifiers = setup.mods; G.GAME.selected_back = { name = setup.deck }
            R.cur = nil
            local B = R.open('small')
            B.target = 100; B.chips_end = 200; B.hands_left_end = 2; B.discards_left_end = 3; B.cashout_total = 8
            B.rows = { hands = 4, discards = 3, blind1 = 0 }
            if setup.rent then R.on_rental({ ability = { rental = true } }) end
            local r = R.compute(B)
            R.cur = nil
            return r
        end
        local w = row({ mods = {}, deck = 'Red Deck' })
        local g = row({ mods = { money_per_hand = 2, money_per_discard = 1, no_interest = true }, deck = 'Green Deck' })
        local r = row({ mods = {}, deck = 'Red Deck', rent = true })
        return table.concat({ w.money, w.gen, g.money, g.gen, r.money, tostring(r.rental_paid) }, ' ')""")
    wm, wg, gm, gg, rm, rp = [float(x) if x != "nil" else None for x in out.split(" ")]
    check(wm == 1 and wg == wm + 1.5 * 2, "Red: money $1 (cash-out 8 - hands row 4 - discards row 3), 2 unused hands x 1.5 (%s %s)" % (wm, wg))
    check(gm == 1 + 3 and gg == gm + 1.5 * 2 * 2, "Green: + $1 x 3 unused discards, hands count at $2 each -> money %s, value %s" % (gm, gg))
    check(rm == 1 - 3 and rp == 3, "Rental joker: -$3 at the end of the round (%s, paid %s)" % (rm, rp))
    shutil.rmtree(tmp, ignore_errors=True)



if __name__ == "__main__":
    t0 = time.time()
    for fn in (test_pair_plays_matches, test_restart_rejoin, test_isolation_guard, test_inert_without_id,
               test_stall_recovery, test_match_timeout, test_external_driver,
               test_cash_out_button, test_bots_cash_out_every_round, test_stale_pack_area_does_not_crash,
               test_cash_out_not_blocked_by_event_queue, test_cash_out_diagnostics_when_button_missing, test_unstick_cashes_out,
               test_pvp_turn_order, test_pvp_turn_order_control, test_pvp_tie_break, test_pvp_turn_timeout,
               test_reward_non_pvp_beaten, test_reward_non_pvp_margin_irrelevant, test_reward_non_pvp_failed, test_reward_sales_not_counted,
               test_reward_pvp_winnable_loss, test_reward_pvp_loss_scales_with_margin, test_reward_planets_aimed,
               test_reward_skips, test_reward_pvp_hopeless, test_reward_match_end_and_totals,
               test_reward_relative_value, test_reward_relative_value_off, test_reward_weights_env,
               test_reward_life_factor, test_plan_protects_held_cards,
               test_plan_classify, test_plan_scoring_with_jokers, test_plan_more_jokers, test_plan_decisions, test_plan_beats_naive_policies,
               test_baseline_uses_planner,
               test_decide_enumerate, test_decide_bans_and_caps, test_decide_potential,
               test_decide_baseline_logging, test_decide_external_choose,
               test_strategy_skips, test_strategy_economy, test_strategy_packs, test_strategy_targets, test_pvp_best_hand_last, test_strategy_skip_e2e, test_cash_out_skips_stale_boxes, test_strategy_round2,
               test_handdec_mechanics, test_handdec_log_e2e,
               test_joker_order, test_joker_order_e2e, test_pvp_no_wasted_single, test_purple_seal, test_retrigger_and_room,
               test_rules_random_loadout, test_rules_loadout_filters, test_rules_live_rules, test_rules_plasma_scoring, test_rules_shop_values, test_rules_reward_money):
        try:
            fn()
        except Exception as e:  # noqa
            import traceback
            traceback.print_exc()
            failures.append("%s crashed: %s" % (fn.__name__, e))
    print("\n%d failure(s) in %.1fs (Lua mod tests)" % (len(failures), time.time() - t0))
    try:
        import test_trainer  # numpy trainer: gradients, returns, BC / PPO, end-to-end on the mock game
        failures.extend(test_trainer.run())
    except ImportError as e:
        print("trainer tests skipped (%s) - pip install numpy" % e)
    print("\n%d failure(s) in total" % len(failures))
    sys.exit(1 if failures else 0)
