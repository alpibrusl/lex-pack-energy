# info.lex — the energy agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of a REST pack's pos.PackManifest: how a console
# should PRESENT this pack's personas — labels, taglines, and the starter
# prompts each persona actually handles (they exercise the persona's own
# tools, which is why they live here and not in a frontend table). Served by
# the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "energy", title: "Energy", tagline: "Site EMS and V2G: parked-fleet batteries bid into flexibility markets.", personas: [{ kind: "grid", title: "Grid coordinator", tagline: "Aggregates parked-fleet capacity and answers balancing-market calls.", suggested_prompts: ["How much V2G capacity is available right now?", "Bid available capacity into the balancing market.", "What is the current grid frequency situation?"] }, { kind: "v2g", title: "V2G asset", tagline: "A bidirectional battery asset: state of charge, dispatch readiness.", suggested_prompts: ["What is your state of charge?", "Are you available for discharge dispatch?"] }, { kind: "ems", title: "Site EMS", tagline: "A site energy manager: EVSE load, power limits, rebalancing.", suggested_prompts: ["What is the current site load?", "Rebalance power across the active EVSEs."] }] }
}

