# lex-pack-energy

Energy domain pack — site-EMS and V2G (grid coordinator + battery asset) LLM-driven agent personas, built on `lex-soft`/`lex-agent`.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #236](https://github.com/alpibrusl/lex-ev-fleet/issues/236)). Matches `main.lex`'s own `pack.DomainPack` boundary named `"energy"` — note eMSP is **not** part of this pack despite the commercial-EV association; it lives in `lex-pack-logistics`, matching the actual persona grouping in `main.lex`.

## Contents

- `src/ems.lex` — site energy manager agent: manages power envelopes, sheds load for a paid flexibility window, settles delivered flex as an L1 chargeback
- `src/energy.lex` — V2G (grid-balancing) personas: `grid-coordinator` (brokers flexibility both ways) and `v2g-asset` (a depot battery/vehicle that discharges to the grid); also owns this pack's own registry `seed()`
- `src/intents.lex` — this pack's `find_peers` intent → relationship-role map

## Usage

Each agent file exports a `make_*_def(db, id, base_url, ...) -> srv.AgentDef` the host composes into a `pack.DomainPack` and mounts via `lex-soft/src/pack`'s `mount_pack`. `energy.lex`'s `seed()` populates this pack's own registry rows independently of any other pack. See `lex-ev-fleet/main.lex` for the reference composition.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine) -> this pack (persona builders + `pack.DomainPack` personas) -> the deployment (e.g. `lex-ev-fleet`, eventually [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node)) that composes the `DomainPack` and mounts it.

## License

Matches the rest of the lex ecosystem.
