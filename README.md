# BalatroArena

**An autonomous AI agent and self-play training arena for Balatro Multiplayer.**

BalatroArena runs several isolated copies of Balatro on one PC and lets bots play full **Balatro Multiplayer** matches
against each other, continuously and without human input. A Lua mod (`BotArena`) plays the game through the same UI
callbacks a human triggers, a Node.js launcher builds and supervises the game instances and a **local** copy of the
official relay server, and a NumPy trainer learns shop, pack, skip and hand-play decisions from the matches the bots
generate. Everything runs on the local machine; nothing connects to public or ranked lobbies.

```
 ┌── Balatro copy 1 ──┐        ┌── Balatro copy 2 ──┐         pair 1 = match 1 (1 vs 1)
 │ Steamodded +       │        │ Steamodded +       │
 │ Multiplayer +      │        │ Multiplayer +      │
 │ BotArena (bot)     │        │ BotArena (bot)     │
 └────────┬───────────┘        └─────────┬──────────┘
          │                              │
 ┌── Balatro copy 3 ──┐        ┌── Balatro copy 4 ──┐         pair 2 = match 2 (1 vs 1)
 │ ...                │        │ ...                │         `--pairs N` for more matches
 └────────┬───────────┘        └─────────┬──────────┘
          └────────── 127.0.0.1:18788 ───┘
               local relay server (server/arena-server.mjs)
                          │
        run/ results · rewards · decision logs ──► trainer/ (NumPy: behaviour cloning + PPO)
```

## Contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Quick start](#quick-start)
4. [Commands](#commands)
5. [How the arena works](#how-the-arena-works)
6. [Configuration](#configuration)
7. [How the bot plays](#how-the-bot-plays)
8. [Rewards](#rewards)
9. [Machine learning](#machine-learning)
10. [Writing your own bot](#writing-your-own-bot)
11. [Data formats](#data-formats)
12. [Project layout](#project-layout)
13. [Tests](#tests)
14. [Notes and limitations](#notes-and-limitations)
15. [Licensing](#licensing)

## Features

* **Fully automatic matches**: connect, create or join a lobby, ready up, play every shop, pack, blind and PvP round,
  record the result, return to the lobby and start the next match, indefinitely.
* **Parallel self-play**: 2 windows per pair, any number of pairs (default 2 pairs = 4 windows = 2 simultaneous matches),
  each in a private game copy with its own save folder and Mods folder. The normal Balatro install and profile are never touched.
* **Hand planner**: a re-implementation of Balatro's scoring order (hand levels, enhancements, editions, seals,
  retriggers, held-in-hand effects and 60+ jokers) with Monte Carlo rollouts over the cards left in the draw pile to
  estimate the probability of clearing a blind, and a live calibration of its predictions against the real scores.
* **Strategic decision layer**: every blind-select, shop and booster-pack decision is enumerated as a list of legal
  options with numeric features, valued by a rule-based model (the "teacher") and logged for learning.
* **Learned policies**: a NumPy MLP policy for shop/pack/skip decisions and a second one for choosing hand plays and
  discards, trained by behaviour cloning of the teacher and then by PPO self-play on a shaped reward.
* **Reward module** inside the mod: one reward per blind with an auditable breakdown (value generated, clears, PvP
  outcome and margin, skips, value relative to the opponent, match win).
* **Random deck and stake per lobby**: all 15 base-game decks and the White, Green, Black, Purple, Gold and Spectral+
  stakes; the bots read the active rules from the game and adapt (Plasma scoring, no-interest economy, sticker
  jokers, Ghost's Hex, Anaglyph's Double Tag, ...).
* **PvP turn order** (the lower score plays next) enforced for every driver, joker auto-ordering, seal and
  retrigger-aware play, consumable-slot management for Purple Seals.
* **Tooling**: a supervising launcher with crash/freeze recovery, results and Elo tables, a per-blind reward audit,
  a file bridge for external agents, and a test suite that runs the real mod Lua against a mocked game.

## Requirements

* Windows 10/11 with **Balatro** (Steam) and these installed in it:
  * [Lovely](https://github.com/ethangreen-dev/lovely-injector) in the game folder (`version.dll`)
  * a Mods folder (`%APPDATA%\Balatro\Mods`) containing **Steamodded** and **Balatro Multiplayer 0.5.5**
* **Node.js 18+** (launcher and local server)
* **Python 3.10+ with NumPy** for the trainer (`pip install numpy`)
* For the test suite: `pip install lupa`
* About 1 CPU core and one game-folder copy on disk per instance

The mod is written against Multiplayer 0.5.5 and its internals (`MP.LOBBY`, `MP.GAME`, ruleset keys); other
versions may need small adjustments.

## Quick start

Put the repository somewhere that is **not** inside the Steam folder (for example `Documents\BalatroArena`), open a
terminal in it and run:

```
node arena.js setup        # writes arena.config.json with auto-detected paths, then checks the installation
node arena.js selftest     # exercises the bundled local server with two scripted clients (no game needed)
node arena.js up           # builds the game copies, starts the server and four games, keeps them playing
```

Four small windows appear (two matches side by side), create lobbies, ready up and play. `Ctrl+C` in the terminal
stops everything, or run `node arena.js down` from a second terminal.

```
node arena.js results      # wins/losses, matches per hour, Elo table
node arena.js rewards      # what every blind paid and why
node arena.js status       # what every instance is doing right now
```

Useful variations of `up`: `--pairs 1` (one match, two windows), `--pairs 3` (six windows), `--speed 32`
(faster), `--ruleset blitz`, `--for 60` (stop after 60 minutes), `--matches 50` (stop each instance after 50 matches).

## Commands

| command | purpose |
|---|---|
| `node arena.js doctor` | check the game folder, Lovely, Steamodded, Multiplayer, ports and disk space |
| `node arena.js setup` | write `arena.config.json` with auto-detected paths, then run `doctor` |
| `node arena.js selftest` | 16 protocol checks of the local server with scripted clients (lobby, start, PvP resolution, lives, ties, `stopGame`, leave/rejoin, host promotion, burst traffic) |
| `node arena.js up [options]` | build instances, start the server and every game, supervise them |
| `node arena.js down` | ask a running arena to shut down cleanly |
| `node arena.js status` | live phase, record, ante, lives, fps and reward total per instance |
| `node arena.js results [--json] [--since MIN]` | win/loss table, matches per hour, Elo between instances, breakdown by deck and stake |
| `node arena.js rewards [--json] [--last N] [--since MIN]` | per-blind reward audit |
| `node arena.js train <bc\|live\|agent\|eval\|inspect>` | trainer (see [Machine learning](#machine-learning)) |
| `node arena.js logs [server\|inst1 [arena\|proc\|lovely]]` | tail logs |
| `node arena.js build [--rebuild]` | (re)build the instance folders only |
| `node arena.js clean --yes` | delete the instance copies and the `run/` folder |

Options of `up`:

| option | meaning |
|---|---|
| `--pairs N` | pairs of instances (default 2) |
| `--speed X` | game speed multiplier (default 16) |
| `--driver D` | `baseline`, `random`, `external` or a path to a `.lua` driver |
| `--matches N` | stop each instance after N matches |
| `--for MIN` | stop the whole arena after MIN minutes |
| `--ruleset R` | `standard_ranked` (default), `blitz`, `vanilla`, ... |
| `--reward k=v,...` | override reward weights, e.g. `--reward money=2,tarot=5,fail=40` |
| `--no-pvp-turn` | let both bots play whenever they like in PvP |
| `--fresh` | **delete** previous results, logs and decision data before starting |
| `--rebuild` / `--no-build` | recreate / skip refreshing the game copies |
| `--no-server` / `--port N` | use an already-running server / choose the relay port |
| `--visible` | show Lovely's console windows |

## How the arena works

`arena.js up`:

1. **Builds instances** (`instances/inst1/game`, ...): a copy of the Balatro folder with the executable renamed
   `BalatroArena_1.exe`, so the copy's save folder becomes `%APPDATA%\BalatroArena_1`. Copies are reused on later runs.
2. **Prepares each Mods folder** (`%APPDATA%\BalatroArena_1\Mods`): copies only Steamodded, Multiplayer and BotArena
   from the normal Mods folder and writes a `.env` that points that Multiplayer copy at `127.0.0.1:<port>`. The real
   profile (`settings.jkr`, `meta.jkr`, `profile.jkr`) is copied once so unlocks match; after that every instance owns its profile.
3. **Starts the local server**, then the instances (staggered). Odd instances are *primary* (create the lobby), even
   instances are *secondary* (join it). Instances 1+2 are pair 1, 3+4 are pair 2, and so on; the lobby code is
   exchanged through `run/lobby/pair<N>.json`, so pairs never meet each other.
4. **Supervises**: restarts instances that crash or freeze, never restarts one that refused to run (exit code 2) or
   that was closed by hand, and prints a status board every 15 s.
5. **In each game**: connect → create/join lobby → (host rolls the deck and stake) → ready → host starts → the bot
   plays the whole match → the result is recorded → host sends `stopGame` → back to the lobby → repeat.

Files written under `run/`:

| path | content |
|---|---|
| `run/results/inst<N>.jsonl` | one row per finished match (result, opponent, seed, deck, stake, ante, lives, duration, reward total, ...) |
| `run/results/rewards<N>.jsonl` | one row per finished blind: components and total |
| `run/results/events<N>.jsonl` | lobby, match and stall events (debugging) |
| `run/decisions/inst<N>.jsonl` | strategic decisions (shop, packs, blinds) with option features |
| `run/decisions/inst<N>.hand.jsonl` | hand decisions (candidate plays and discards) |
| `run/status/inst<N>.json` | live heartbeat: phase, record, ante, lives, fps, running reward total |
| `run/pairval/inst<N>.json` | per-blind value ledger used for the opponent comparison |
| `run/logs/` | `inst<N>.arena.log` (bot log), `inst<N>.proc.log` (process output), `server.log` |
| `run/bridge/` | file bridge for external agents |

### Safety and isolation

* The arena talks **only** to the local server (`server.host` defaults to `127.0.0.1`, and each Multiplayer copy's
  `.env` overrides its server address). Sped-up, automated clients must not join public or ranked lobbies.
* An instance refuses to run (exit code 2, status `fatal`) if its save folder is the real `Balatro` folder, and
  `arena.js` refuses to build instances inside the Steam folder or the real save folder.
* The bundled relay has its anti-abuse limiter relaxed (bots send bursts of messages) and is bound to loopback.

## Configuration

`arena.config.json` (created by `setup`) is merged over built-in defaults and under command-line flags. Paths may use
`%APPDATA%`, `$VARS` and `~`.

| key | default | meaning |
|---|---|---|
| `gameDir` | auto (Steam) | Balatro folder containing the exe and `version.dll` (Lovely) |
| `sourceModsDir` | `%APPDATA%\Balatro\Mods` | where Steamodded and Multiplayer are copied from |
| `instancesDir` | `<arena>\instances` | where the game copies go (about the size of the install each) |
| `pairs` | 2 | pairs of instances; 2 = 4 windows = 2 simultaneous matches |
| `ruleset` / `gamemode` | `standard_ranked` / `attrition` | any Multiplayer ruleset (`blitz`, `legacy_ranked`, `vanilla`, ...) |
| `lobbyOptions` | `""` | extra lobby options, e.g. `"starting_lives=3,pvp_start_round=2"` |
| `randomLoadout` | true | every lobby plays a random vanilla deck on a random stake; `false` = the lobby's own deck and stake |
| `loadoutDecks` / `loadoutStakes` | `""` | limit the random pool by short name, e.g. `"plasma,ghost"` / `"gold,spectralplus"` |
| `driver` | `baseline` | `baseline`, `random`, `external`, or a path to your own `.lua` driver |
| `pvpTurn` | true | PvP blinds: the player with the lower score plays next |
| `turnTimeout` | 45 | real seconds a waiting bot idles before it plays anyway (deadlock failsafe) |
| `plan` / `planMs` | true / 60 | use the hand planner / its thinking budget per decision in ms |
| `decideHeuristic` / `decideEps` | true / 0 | rule-based shop/pack/blind valuation / chance of a random non-destructive choice (training diversity) |
| `decideSkips` | true | blinds are skipped only by the strategy rules; `false` = never skip |
| `jokerOrder` | true | automatically re-order the joker row |
| `externalHands` | `learned` | who plays hands for the external driver: `learned` (hand model), `planner`, or `agent` (raw card indices) |
| `handPlanFeat` / `handDecisions` / `handEps` / `handMaxOpts` | true / true / 0 / 44 | planner verdict as model features / log hand decisions / random-candidate chance / candidates per decision |
| `reward` | `{}` | reward weight overrides, e.g. `{ "money": 1, "tarot": 3, "fail": 30 }` |
| `speed` / `boost` | 16 / 4 | game speed multiplier / extra event-queue passes per frame |
| `matches` | 0 | matches per instance before it exits (0 = endless) |
| `matchTimeout` | 3600 | seconds before a match is aborted (e.g. two bots tying every PvP forever) |
| `window` | 640×360 grid | window size and the screen size used to tile windows |
| `perInstance` | `{}` | per-instance overrides, e.g. `{ "2": { "driver": "random", "speed": 8, "name": "Rival", "env": {...} } }` |
| `drawEvery` | 1 | 2–4 skips rendering frames to save GPU |

Every setting is also available to the mod as a `BOTARENA_*` environment variable (`lib/config.js` →
`mod/BotArena/lib/config.lua`), so `perInstance.env` can set any of them, for example `BOTARENA_SKIP_RATE=0.3` makes
the baseline skip Small/Big blinds 30 % of the time. Per-instance overrides use the same keys:
`"perInstance": { "3": { "pvpTurn": false, "reward": { "tarot": 5 } } }`.

## How the bot plays

The built-in `baseline` driver combines a hand planner, a rule-based strategic model and a set of explicit rules. The
learned policies start as clones of this bot and are trained from its logs (see [Machine learning](#machine-learning)).

### Hand planner (`lib/plan.lua`)

1. **Joker-aware scoring.** A fast re-implementation of Balatro's scoring order: hand-level chips and mult, every
   scoring card (rank chips, Bonus / Mult / Glass / Stone / Lucky cards, foil / holographic / polychrome, Red Seal),
   jokers left to right (suit, rank, hand-type and face-card jokers, Duo / Trio / Family / Order / Tribe, Fibonacci,
   Scholar, Photograph, Triboulet, scaling jokers, Half Joker, Banner, Cavendish, Acrobat, Card Sharp, Flower Pot, ...),
   retriggers (Hack, Sock and Buskin, Hanging Chad, Dusk, Seltzer), held-in-hand effects (Steel, Baron, Shoot the
   Moon, Raised Fist, Blackboard, Mime), Blueprint / Brainstorm copying, Four Fingers, Shortcut, Smeared Joker,
   Splash, Pareidolia and the Plasma Deck balancing. Anything unknown falls back to the game's generic ability
   fields (`x_mult`, `t_mult`, `t_chips`).
2. **Calibration.** After each hand the planner compares its predicted score with the score the game awarded and
   learns a per-hand-type correction factor (reset every match).
3. **Odds from the draw pile.** It reads the cards left in the deck as an unordered pile (never the shuffle order)
   and runs Monte Carlo rollouts: for every candidate action (play a hand, or discard these cards and draw) it plays
   out the rest of the blind many times with the remaining hands and discards and counts how often the blind is
   cleared. A four-of-a-kind that needs two specific cards out of 44 is worth its tiny probability, not its score.
4. **Objective.** `P(clear) × 1.5 per unused hand − (1 − P(clear)) × 30` plus a small penalty for how far a failed
   blind falls short. A certain three-hand clear beats a 5 % shot at clearing in one hand, and a play that clears the
   blind right now always wins. On a PvP blind it maximises the expected score while the opponent still has hands and
   switches to "beat their final score" when the opponent is out of hands. On The Hook it plays to leave the blind with
   as few hands as possible.
5. **PvP details.** A lone card that is clearly weaker than the best play is never opened with (it wastes a hand);
   when jokers pay extra on the last hand (Dusk, Acrobat, ...) the best hand is saved for the last hand.

Every decision is logged, e.g. `plan: discard 1,2,5,7 [discard (flush draw)] score~288 need=260 p_clear=0.62
hands=2 discards=1 deck=44 opts=9`. If the planner throws, the rule-based fallback plays the hand (five errors in a
match disable it for the rest of that match).

### Seals, retriggers and consumable slots

* **Purple Seal**: discarding a Purple Seal card creates a Tarot, which the planner values at the Tarot reward weight.
  When a play already clears the blind, the clearing play stays in hand and Purple Seal cards outside it are
  discarded first (discards cost no hand); otherwise discards containing Purple cards get the bonus and plays containing
  them a matching penalty. A Purple discard needs a free consumable slot, so when every slot is taken the bot first
  **uses** a Planet or an untargeted Tarot, or **sells** the weakest held consumable if it is worth clearly less than a
  random Tarot, and only then discards.
* **Gold Seal and Lucky cards**: among plays that clear the blind the planner prefers the one that earns the most money:
  $3 per trigger for a Gold Seal card and the $20 / 1-in-15 chance of a Lucky card, **including retriggers** (Hanging
  Chad's first card, Hack, Sock and Buskin, Dusk on the last hand, Seltzer, Red Seals).
* **Retrigger jokers in the shop**: Hack, Dusk, Sock and Buskin, Seltzer and Hanging Chad (including the
  Multiplayer rework) add little to today's score, so their value is computed from how much they have to repeat:
  jokers that fire per scoring card (Photograph, Scary Face, Triboulet, Fibonacci, Even Steven, Odd Todd, Walkie
  Talkie, Hiker, Lucky Cat, 8 Ball, ...) plus the share of Gold Seal, Red Seal, Lucky and Glass cards in the deck. A
  second retrigger joker multiplies the first; the bonus fades after ante 7. The same support numbers are logged as
  features so the learned policy can adjust them.

### Strategic decisions (`lib/decide.lua`)

On the blind-select, shop and booster-pack screens every legal option (select, skip, buy, sell, use, reroll, open,
pick, leave) is listed with numeric features: cost, interest lost, what the item adds to the best hands according to
the planner (non-PvP and PvP), lives of both players, ante, distance to the next PvP, joker families, deck composition,
sticker state, active deck and stake, and more. The rule-based value model picks from that list. Its rules:

* **Skips**: only the ante-1 Investment and Rare tags (not Investment with a strong economy joker, or when a strong
  voucher could not be bought without that blind); in later antes only when a joker condition is lined up (Idol hit,
  Ancient Joker suit, Juggle tag for a held-card build). A waiting Double Tag (Anaglyph Deck) makes strong tags worth a skip.
* **Early game is economy**: economy jokers first, scoring jokers only as far as the next blind needs
  (comfort = planner potential against the blind target).
* **Interest**: spend so that the next blind's income refills the balance to the $25 cap; reroll sparingly and never
  down to a balance that could not buy a Blueprint; the shop before a PvP blind spends a bit more.
* **Packs**: Spectral packs always (opened last, with the leftover dollars), Arcana first above $15, Buffoon next,
  Standard when there is money to spare. Pick targeting: Lucky / Steel and deck fixing (Hanged Man, Death), seals
  other than Blue, Wraith / Talisman / Immolate / Cryptid / Deja Vu / Medium; Tarots that need hand cards are aimed
  (Magician on the best cards, Chariot on junk, Death copies the best card over a bad one, ...).
* **Selling**: with full slots the joker that adds least is swapped out for a clearly better one; early that is the
  weakest scorer, late (strong scorers) the economy jokers go first.
* **Vouchers**: all taken when affordable except Telescope, Observatory, Planet Merchant / Tycoon, Tarot Tycoon,
  Magic Trick and Illusion. Hermit is held until $15 or more.
* **Planets**: before ante 4 only when the next blind needs levels or the interest cap is still full afterwards.
* **Multiplayer jokers**: Pacifist (×10 outside PvP) is valued mainly by its PvP potential; Skip-Off, Lets Go
  Gambling and Penny Pincher are rated highest.
* **Joker order** (`lib/order.lua`): +chips and +mult jokers left of x-mult jokers, Brainstorm behind the strongest
  joker, Blueprint next to the one worth copying, Ceremonial Dagger rightmost, pinned jokers stay. Found by searching
  with the planner and applied only when at least 1 % better (`jokerOrder: false` disables it).

### Deck and stake rules (`lib/rules.lua`)

Every lobby the host rolls a random vanilla deck (Red, Blue, Yellow, Green, Black, Magic, Nebula, Ghost, Abandoned,
Checkered, Zodiac, Painted, Anaglyph, Plasma, Erratic) and a random stake (White, Green, Black, Purple, Gold,
Spectral+); both players use it. Rules are read **live** from the game (`G.GAME.modifiers`, the selected deck, the
stickers on cards), never from a hard-coded table:

| rule | how the bots handle it |
|---|---|
| Green / Purple / Spectral+ scaling (2 / 3 / 5) | blind targets come from the game; comfort and potential features see it |
| Small Blind pays $0 (Green and above) | income estimates and skip value account for it |
| Eternal jokers (Black and above) | cannot be sold or swapped: valued lower, much lower when weak or when slots are scarce |
| Perishable jokers (Gold and above) | worth only the rounds they still work; sold once perished |
| Rental jokers (Gold and above) | $3 per round is charged against their value and the income estimate; sold when not worth it |
| Plasma Deck | scoring balances chips and mult (`floor((chips + mult) / 2)` each); reflected in the planner |
| Green Deck | no interest (interest-cap vouchers and To the Moon are worthless), $2 per unused hand and $1 per unused discard |
| Ghost Deck | starts with Hex, which destroys every other joker: used only as the lone joker |
| Anaglyph Deck | a Double Tag after every boss: skip values change |
| Abandoned Deck | no face cards: face-triggered economy jokers are dead, Ride the Bus never resets |
| Checkered / Erratic / Painted / Nebula / Zodiac / Magic / Blue / Red / Yellow / Black | deck composition and starting resources are read from the game |

`BOTARENA_DECKS` / `BOTARENA_STAKES` (config keys `loadoutDecks` / `loadoutStakes`) restrict the pool.

### PvP turn order (`lib/pvp.lua`)

On a PvP blind, once both players have played a hand the player with the **lower** score plays next and the leader
waits. Each player's first hand is free (the opponent's score is hidden until you have played). On an exact tie the
player who readied first holds the timer role, so the other one plays. A player with no hands left, or whose opponent
has none left, is never held back. The gate is applied before every driver step, so every driver obeys it; the status
board shows `(waits: ahead)` while a bot holds back. A waiting bot plays anyway after `turnTimeout` seconds without a
change in the opponent's score or hands. `--no-pvp-turn` disables the gate; `snap["pvp"]` tells an external agent whose
turn it is and why.

### Robustness

* Cash Out is pressed exactly once, the moment its UI box exists, independent of the game's event queue; if the
  round-end screen ever stalls, the bot logs why (state, button presence, blocking events and the source line that
  queued them) as `cash_out_wait` events.
* A stall watchdog escalates from a soft recovery to `stopGame` to a restart; card areas are always read through
  guarded helpers because the game leaves removed areas behind after booster packs.
* An external agent that stops answering never stalls a match: after 60 s the baseline plays instead.

## Rewards

Rewards are computed inside the mod (`mod/BotArena/lib/reward.lua`) by watching the game, so they work with every
driver. One reward is paid per **blind**, at Cash Out (or at match end if the match stops first), and each is written to
`run/results/rewards<N>.jsonl` with all of its components (`node arena.js rewards --last 20`). External trainers
receive them as `snap["reward"]["events"]` / `["delta"]` (each finished blind exactly once).

**Value generated** (from selecting the blind until Cash Out):

| term | counts | default weight |
|---|---|---|
| money | $ gained during the blind (jokers, gold cards, interest, end-of-round money, per-discard money) plus the Cash Out payout minus the parts independent of the bot (base blind payout, comeback bonus, per-hand money); rental fees count negatively; selling does not count | 1 per $ |
| tarots | Tarot cards that appear in the consumable slots (created by jokers, tags, Purple Seals, other consumables); purchases and pack picks happen outside the blind and do not count | 4 each |
| spectrals | the same for Spectral cards | 7 each |
| planets | the same for Planet cards; a planet for a hand type the bot is **aiming at** is worth more | 1 each, 5 if aimed |
| unused hands | hands left when a non-PvP blind is beaten (scaled by the stake's money per hand); PvP pays nothing for them | 1.5 each |

The **aimed hand** is joker-aware: for every hand type the bot projects `(level chips + chip jokers) × (level mult +
mult jokers) × x-mult jokers × feasibility`, using the jokers it owns whose condition matches that hand, and the same
"contains" rule the game uses. Feasibility is a prior (Pair .95 … Flush Five .0008) or the share of hands actually
played of that type, whichever is higher.

**Small / Big / ante-1 Boss (non-PvP blinds)**

* beaten: reward = value generated;
* not beaten: reward = **−30**, flat; the value generated on a failed blind is not paid. A failed blind also costs a life;
* the score never matters: clearing with exactly the target or with 100× the target pays the same.

**PvP blinds** (outcome from the server's life change). Margins are measured in doublings,
`log2((mine+1)/(theirs+1))`, because PvP scores end up close together.

* **win**: `+40 + 4 × doublings ahead` (capped at 4 doublings) `+ 1.0 × value`;
* **loss**: `−(70 + 14 × doublings behind)` (capped at 6) `× life factor × ante factor + 1.0 × value`. The life factor
  rises as the bot's lives fall or the enemy's rise; the ante factor runs from 0.8 at ante 2 to 1.28 at ante 8;
* **tie**: 0 + value;
* **hopeless** (the last hand was played and even an optimistic estimate could not reach the opponent's score): value is
  paid at full weight, there is no win bonus and the loss terms stay, so throwing a PvP early is never attractive.

**Skips** (Small / Big only): each skip costs **−10** immediately (−2 for the ante-1 Investment / Rare tag). At the next
PvP, if the score margin against the opponent improved compared with the previous PvP, the skips in between are
credited `15 × doublings of improvement` (capped at 40).

**Value relative to the opponent** (every blind): each bot keeps a ledger of its finished blinds (`run/pairval/`) and
reads its partner's. When both have finished the same blind (and, for Small / Big / boss, both cleared it) the values
are compared; the bot with the strictly lower value books an extra `rel` row of `−1.0 × value behind` (uncapped). Equal
value costs nothing.

**Winning the match** books a `match` row of **+400** when the opponent reaches 0 lives (an opponent that merely left
or a match that was cut short pays nothing).

Selling is deliberately neutral: sale proceeds are not value generation, but what they enable is, and a joker worth more
than its price shows up as lower scores and failed blinds.

All weights live in `R.W` at the top of `reward.lua`, in the config (`"reward": {...}`) or on the command line
(`--reward money=2,tarot=5,spectral=8,planet_aimed=6,hands=1,fail=40,pvp_loss=80,skip_penalty=12`). Keys: `money tarot
spectral planet planet_aimed hands fail fail_shortfall match_win rel_flat rel_per rel_cap rel_pvp pvp_win pvp_loss
pvp_margin pvp_margin_cap pvp_loss_margin pvp_loss_margin_cap pvp_value_scale pvp_hopeless_value_scale
pvp_hopeless_keeps_loss hopeless_slack skip_penalty skip_credit skip_credit_cap skip_penalty_good ante_base ante_slope
ante_max life_low life_rel count_base_reward`. `reward_total` is stored on each match row as well.

Known approximations: "tarots generated" counts cards that land in the consumable slots (a chain such as
Emperor → Tarot is counted for the new card but not the consumed one); the hopeless test uses observed scores and base
hand values; a blind that ends because the opponent lost their last life is not scored; the aimed hand is a heuristic
and the skip credit is noisy because the opponent's strength moves too.

## Machine learning

The `trainer/` package (NumPy only, no deep-learning framework) learns two policies from the logs the bots write:

* a **strategy model** for blind-select, shop and pack decisions, and
* a **hand model** that chooses among candidate plays and discards.

### Models

* **Features** (`trainer/features.py`): every decision row becomes a state vector `s` and one feature row `x` per
  option, using fixed transforms (linear / log / signed) and hashed bins for option keys and owned jokers. New
  features are appended at the end of the vectors; checkpoints from earlier layouts are zero-padded on load, so a
  schema change never invalidates a trained model.
* **Policy**: `logit_i = MLP([s ; x_i])` with a softmax over the options of one decision, plus a value head `V(s)`.
  Backpropagation and Adam are hand-written and checked against finite differences.
* **Behaviour cloning**: cross-entropy towards the teacher's choice plus value regression.
* **PPO**: clipped surrogate using the logged behaviour probability, advantage = return − V, entropy bonus and a
  behaviour-cloning regulariser. The return of a decision is the discounted sum of the rewards of the following blinds
  in the same match (`γ = 0.9` for strategy, `0.6` for hands), divided by a reward scale of 30. Only finished matches
  contribute.

### Hand decisions

On every hand `lib/handdec.lua` lists up to 44 candidate moves (plays and discards: all sensible card subsets plus a
few random ones) with features such as the play's score with the current jokers, what stays in hand, what a discard
keeps, how many outs remain in the deck, a small Monte Carlo estimate of the redraw, seal counts and free consumable
slots. The planner's own choice is always among them (teacher and safety net), but the model may pick any candidate.
`handPlanFeat: false` removes the planner's verdict from the features for pure learning from game mechanics.
A Purple Seal discard chosen by the planner is a fixed rule: it is played directly and logged as a teacher decision.

### Workflow

Run from the repository folder (`pip install numpy` once).

1. **Collect data** with the baseline bots, optionally with exploration (`decideEps` ≈ 0.15 in the config):
   `node arena.js up` and let a few hundred matches finish.
2. **Clone the teacher**: stop the arena, then `node arena.js train bc` (`--only hand` / `--only strategy` for one
   model). It prints how often the model agrees with the baseline's choice and writes `trainer_ckpt/model.npz` and
   `trainer_ckpt/model_hand.npz`.
3. **Learn online**: set the instances that should learn to the external driver, for example
   ```json
   "perInstance": { "3": { "driver": "external" }, "4": { "driver": "external" } }
   ```
   then `node arena.js up --pairs 2` and, in a second terminal, `node arena.js train live --insts 3,4`. Instances 1 and 2
   keep playing with the baseline and act as the control group and teacher-data source. `--learn strategy` freezes the
   hand model, `--hands planner` switches learned hand play off.
4. **Judge it**: `node arena.js train eval` (win rate and reward per driver, `--last N` for recent matches) and
   `node arena.js train inspect [--kind hand]` (where the model disagrees with the logged choice, marked `!!`). The
   best test is one learner against one baseline in the same pair over 100+ matches.
5. `node arena.js train agent` answers the bridge with the saved model without learning (`--greedy` takes the arg-max).

Tuning options of `train`: `--lr`, `--hand-lr`, `--hidden`, `--hand-hidden`, `--gamma`, `--gamma-hand`,
`--reward-scale`, `--match-bonus` (extra win/loss reward at match end, default 0), `--clip`, `--entropy`,
`--bc-coef`, `--min-rows`, `--hand-min-rows`, `--ppo-epochs`.

## Writing your own bot

A driver is a Lua file returning `function(A) return { step = function(memo) ... end } end`
(`mod/BotArena/drivers/template.lua`). `step` is called only when the game is idle and should perform at most one
action through `A.act` (`select_blind`, `skip_blind`, `play`, `discard`, `buy`, `sell`, `use_consumable`,
`pick_pack_card`, `skip_pack`, `reroll`, `cash_out`, `leave_shop`, ...). These press the real UI callbacks, so
Multiplayer's own hooks run exactly as for a human player. Set `"driver": "C:/path/my_driver.lua"` to use it;
`drivers/baseline.lua` is a complete example.

To drive from Python use `"driver": "external"`. The game writes `run/bridge/inst<N>.obs.json` (a full observation with
a sequence number `seq`) and waits for `run/bridge/inst<N>.act.json` with the same `seq`; the result is reported in
`inst<N>.res.json`. A decision observation (`snap.dec`) carries the option list; the agent answers
`{"seq": ..., "action": "choose", "i": <0-based option>, "p": <probability>, "v": <value estimate>}`. Raw actions
(play, discard, buy, ...) work too. `examples/external_agent.py` is a minimal agent and `python -m trainer live` a full one.
File latency is a few milliseconds; use several pairs for throughput.

## Data formats

* **Match row** (`run/results/inst<N>.jsonl`): `{inst, sess, match, result: win|loss|aborted, opponent, seed, deck, stake,
  ante, lives, secs, reward_total, ...}`
* **Reward row** (`run/results/rewards<N>.jsonl`): `{inst, sess, match, ridx, kind, ante, deck, stake, outcome, beaten,
  money, tarots, spectrals, unused_hands, hopeless, parts{}, reward, ...}` plus skip, `rel` and `match` rows.
* **Decision row** (`run/decisions/inst<N>.jsonl`): `{seq, kind, bidx, sx{state features}, jokers[], cons[],
  options[{id, act, kind, key, pos, fx{option features}}], chosen, src, p, v}`; `bidx` is the index of the next reward
  row when the decision was made. Hand decisions have the same shape with `kind: "hand"`.
* **Config chain**: `arena.config.json` → `lib/config.js` → `BOTARENA_*` environment → `mod/BotArena/lib/config.lua`.

## Project layout

```
arena.js, arena.cmd        launcher entry point
lib/                       launcher: config, instance builder, server wrapper, supervisor, doctor, selftest, results
mod/BotArena/              the Lua mod
  main.lua                 module loader and game hooks
  lib/arena.lua            lobby / match state machine, watchdog, results
  lib/act.lua, obs.lua     UI actions and observations
  lib/plan.lua             hand planner (scoring, Monte Carlo rollouts, seals, calibration)
  lib/handdec.lua          hand candidates, features and logging
  lib/decide.lua           strategic decision layer (options, features, rule-based value model)
  lib/rules.lua            deck and stake rules, random loadout
  lib/order.lua            joker auto-ordering
  lib/pvp.lua              PvP turn order
  lib/reward.lua           reward accounting
  lib/speed.lua, hands.lua, util.lua, config.lua
  drivers/                 baseline, random, external (file bridge), template
server/                    local relay server (build of the official server) and its sources
trainer/                   NumPy trainer: features, model, algo, data, agent, evaluate, cli
trainer_ckpt/              trained checkpoints (strategy and hand model)
examples/external_agent.py minimal external agent
tests/                     mock game, planner simulator, test suites
```

## Tests

* `node arena.js selftest` – 16 protocol checks against the bundled server.
* `python tests/run_tests.py` (needs `pip install lupa`) – runs the real mod Lua in LuaJIT against a mocked
  Balatro / Steamodded / Multiplayer and a simulated relay: lobby flow, many matches, restart recovery, isolation guard,
  stall watchdog, match timeout, external bridge, Cash Out layout, PvP turn order, reward accounting, hand planner
  (hand recognition, joker-aware scores, odds from the deck, planner versus greedy play over simulated blinds), decision
  layer, joker ordering, deck and stake rules, seals, retrigger valuation and consumable-slot management.
  It also runs the trainer tests.
* `python tests/test_trainer.py` (needs NumPy) – gradient checks, behaviour cloning, PPO step, data joins, live bridge,
  checkpoint compatibility across feature-layout changes.
* `node tests/launcher_test.js` – end-to-end test of `arena.js` with a fake game executable: instance building, server
  start, the default 4-window layout, config migration, flag-to-environment plumbing, status board, supervision
  (crash / freeze / fatal / closed) and shutdown.

## Notes and limitations

* **Windows first.** Paths and window tiling target Windows; each instance needs roughly one CPU core. If the fps
  column in `status` drops, lower `--speed` or use fewer pairs. `speed 16` with `boost 4` is a starting point.
* **Save-folder guard.** Each copy must use `%APPDATA%\BalatroArena_<N>`. If a window reports
  `fatal: ... real Balatro save folder` in `run/status/inst<N>.json`, the game derived the folder differently; nothing is
  modified in that case.
* **Running outside Steam.** The copies start without Steam. If a copy refuses to start, set `"steamAppId": true` in
  the config to write `steam_appid.txt`.
* **Learning signal.** The models learn from blind-level rewards, so improvement is gradual and noisy; while a model
  samples from its own policy it will sometimes play worse than the planner (`--greedy` measures the arg-max policy).
  The reward weights are a starting point and are meant to be tuned from `node arena.js rewards --last 50`.
* **Not modelled yet**: the Ectoplasm trick, Tarots that need targets while held (outside packs), most bosses other
  than The Hook, discard-triggered jokers (Trading Card, Faceless Joker, Mail-In Rebate, Burnt Joker, Hit the Road),
  Blue Seal "hold until round end" play, and credit assignment for hands finer than the blind.
* **Multiplayer 0.5.5** is the supported version. The default ruleset is `standard_ranked` with the `attrition`
  gamemode: from ante 2 the boss blind is a PvP blind and each player has 4 lives.

## Licensing

`server/arena-server.mjs` is a build of the official Balatro Multiplayer relay server
(<https://github.com/Balatro-Multiplayer/balatromultiplayerapi-server>, GPL-3.0; license text in
`server/LICENSE-SERVER.md`) with the SQLite-backed stores replaced by in-memory stubs and the listener bound to
loopback. The modified source and build script are in `server/source/`; see `server/SOURCE.md`.

Balatro is the property of its developer and publisher, and Balatro Multiplayer, Steamodded and Lovely belong to their
respective authors. This repository contains none of their files: the arena copies the locally installed game at runtime.
