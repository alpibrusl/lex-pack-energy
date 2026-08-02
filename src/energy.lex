# agents/energy.lex — the ENERGY (V2G grid-balancing) domain pack.
#
# The second real domain pack (#25), proving "logistics is just the first use
# case": it mounts on the UNCHANGED platform core via `pack.mount_pack`, shares
# the EV fleet's depots and vehicles (V2G), and transacts with the logistics
# domain across the directory. Two personas:
#   grid-coordinator — brokers grid flexibility: how much V2G power/energy the
#                      fleet can provide over a window (capability
#                      energy.balancing.frequency).
#   v2g-asset        — a depot battery/vehicle that discharges to the grid when
#                      it has SoC headroom (capability energy.v2g.dispatch).
# Both are ordinary LLM agents (runner.make_handler) with live tools — the same
# shape as the logistics personas, just a different domain.

import "std.str" as str

import "std.list" as list

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/registry" as reg

import "lex-soft/src/runner" as runner

import "./intents" as intents

fn tenant_hdr(req :: { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] }, tenant :: Str) -> { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] } {
  if str.is_empty(tenant) {
    req
  } else {
    http.with_header(req, "X-Tenant-Id", tenant)
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  match http.send(tenant_hdr(base, tenant)) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capabilities ──────────────────────────────────────────────────────────────
fn grid_capability() -> cap.Capability {
  cap.inbound("handle", "Accept grid flexibility requests: how much V2G power (kW) / energy (kWh) the fleet can provide over a window, and at what price.", { title: "GridFlexRequest", description: "Inbound message for the grid coordinator.", fields: [sch.required_str("text", [])] })
}

fn v2g_capability() -> cap.Capability {
  cap.inbound("handle", "Accept a V2G dispatch: discharge N kWh to the grid if the asset has state-of-charge headroom; otherwise decline with a reason.", { title: "V2gDispatch", description: "Inbound message for a V2G battery asset.", fields: [sch.required_str("text", [])] })
}

# ── Tools (live backends — V2G reuses the fleet's telemetry + charge) ─────────
fn make_grid_tools(telemetry_url :: Str, charge_url :: Str, tenant :: Str) -> List[t.Tool] {
  [t.define("get_depot_chargers", "List depot chargers + live status — bays available to host V2G discharge.", { title: "GetDepotChargers", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(charge_url, "/v1/chargers"), tenant))
  }), t.define("get_vehicle_soc", "Live state of charge for a vehicle by VIN — the V2G energy it could shed.", { title: "GetVehicleSoc", description: "Vehicle SoC.", fields: [sch.required_str("vin", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([telemetry_url, "/vehicles/", jstr(args, "vin"), "/telemetry/latest"], ""), tenant))
  })]
}

fn make_v2g_tools(telemetry_url :: Str, tenant :: Str) -> List[t.Tool] {
  [t.define("get_soc", "Live state of charge for this asset's vehicle by VIN, to check discharge headroom.", { title: "GetSoc", description: "Asset SoC.", fields: [sch.required_str("vin", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([telemetry_url, "/vehicles/", jstr(args, "vin"), "/telemetry/latest"], ""), tenant))
  })]
}

# ── System prompts ────────────────────────────────────────────────────────────
fn grid_system_prompt(id :: Str) -> Str {
  str.join(["You are grid coordinator ", id, ". You broker flexibility on both sides of the meter.", " SELL side (V2G): when the grid requests flexibility, call get_depot_chargers and get_vehicle_soc to find how much energy the fleet can shed,", " then reply with a concrete offer: available kW, duration in minutes, and a price. Never overcommit beyond the measured SoC and free bays.", " BUY side (site flexibility): to relieve a constraint, run a TENDER — find_peers with intent \"flexibility\" for site energy managers, then send_message each one (always topic \"handle\" — peers accept no other skill) a tender naming the kW to shed, the window and your EUR/kWh price, and take the best COMMITTED reply.", " The seller delivers by actuating its site limit and settles on the platform; you verify the cost later in your usage statement (chargebacks).", " Be concise and decisive; always state kW, window and price as concrete numbers."], "")
}

fn v2g_system_prompt(id :: Str) -> Str {
  str.join(["You are V2G battery asset ", id, ". You discharge stored energy to the grid on dispatch — but only with SoC headroom.", " On a dispatch, call get_soc; accept only if discharging the requested kWh keeps SoC above a safe floor (e.g. 30%),", " otherwise decline with the available headroom. State the topic ('v2g_accept' or 'v2g_decline'), kWh, and resulting SoC."], "")
}

# ── Agent factories (the persona builders the pack mounts) ────────────────────
fn make_grid_def(db :: Db, id :: Str, base_url :: Str, telemetry_url :: Str, charge_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := grid_capability()
  let cfg := { id: id, kind: "grid", system_prompt: grid_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "charge_url", url: charge_url }, { key: "telemetry_url", url: telemetry_url }], intent_roles: intents.fleet(), tools: make_grid_tools(telemetry_url, charge_url, "") }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("V2G grid coordinator ", id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

fn make_v2g_def(db :: Db, id :: Str, base_url :: Str, telemetry_url :: Str, charge_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := v2g_capability()
  let cfg := { id: id, kind: "v2g", system_prompt: v2g_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "charge_url", url: charge_url }, { key: "telemetry_url", url: telemetry_url }], intent_roles: intents.fleet(), tools: make_v2g_tools(telemetry_url, "") }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("V2G battery asset ", id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

# ── Registry seed (the pack's discoverable agents + namespaced capabilities) ──
# Registering the energy agents with their namespaced capabilities is what makes
# them discoverable across the seam — a logistics agent can look up who serves
# energy.balancing.frequency / energy.v2g.dispatch and transact with them.
fn a2a_inbox(agent_id :: Str) -> Str {
  str.join(["http://localhost:8100/agents/", agent_id, "/"], "")
}

fn seed(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  let v2g_assets := ["v2g-depot-north", "v2g-depot-south"]
  match reg.register_in(db, "voltgrid-energy", "grid-coordinator", "grid", "V2G Grid Coordinator", a2a_inbox("grid-coordinator"), ["energy.balancing.frequency"]) {
    Err(e) => Err(e),
    Ok(_) => list.fold(v2g_assets, Ok(()), fn (acc :: Result[Unit, Str], id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      match acc {
        Err(e) => Err(e),
        Ok(_) => reg.register_in(db, "voltgrid-energy", id, "v2g", str.concat("V2G Battery Asset ", id), a2a_inbox(id), ["energy.v2g.dispatch"]),
      }
    }),
  }
}

