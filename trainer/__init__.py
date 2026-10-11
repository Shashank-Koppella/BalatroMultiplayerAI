"""BotArena trainer: a numpy-only policy/value model for the strategic decisions (shop, packs, blind select).

    python -m trainer bc    --run-dir run          # behaviour-clone the baseline's logged decisions
    python -m trainer live  --run-dir run --inst 1,2   # play through the file bridge AND learn online (PPO-style)
    python -m trainer eval  --run-dir run          # win rate / reward per driver

See docs/HANDOFF.md ("Trainer") for the data flow and README.md for the commands.
"""
__version__ = "0.1.0"
