# agents/ems.lex — Site EMS persona (energy-flex pack, #122 / #79).
#
# The site energy manager as an agent: it knows its site's power envelope
# (lex-ems), can SHED load by lowering the site limit for a window — the
# flexibility product — and settles delivered flex as an L1 chargeback on
# the trail (auditable, shows in /usage), via the node's /flex endpoint.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-soft/src/runner" as runner

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "./intents" as intents

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    req0
  } else {
    http.with_header(req0, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_send_json(method :: Str, url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: method, url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn ems_capability() -> cap.Capability {
  cap.inbound("handle", "Accept site-EMS requests: flexibility tenders (shed X kW in window W at price P), delivery, settlement and power-envelope queries.", { title: "EmsMessage", description: "Inbound message for a site energy manager agent.", fields: [sch.required_str("text", [])] })
}

fn jstr(args :: jv.Json, k :: Str) -> Str {
  match jv.get_field(args, k) {
    Some(JStr(v)) => v,
    _ => "",
  }
}

fn jnum(args :: jv.Json, k :: Str, dflt :: Float) -> Float {
  match jv.get_field(args, k) {
    Some(JFloat(v)) => v,
    Some(JInt(n)) => int.to_float(n),
    Some(JStr(s)) => match jv.parse(s) {
      Ok(JFloat(v)) => v,
      Ok(JInt(n)) => int.to_float(n),
      _ => dflt,
    },
    _ => dflt,
  }
}

fn make_tools(ems_url :: Str, tenant :: Str, self_url :: Str, agent_id :: Str) -> List[t.Tool] {
  [t.define("get_sites", "The sites this EMS manages: power envelope (max/reserved kW), balancing strategy, CSMS link.", { title: "GetSites", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(ems_url, "/api/v1/sites"), tenant))
  }), t.define("get_site_evses", "The EVSEs behind a site and their allocations.", { title: "GetSiteEvses", description: "Per-site EVSE registry.", fields: [sch.required_str("site_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(ems_url, str.concat("/api/v1/sites/", str.concat(jstr(args, "site_id"), "/evses"))), tenant))
  }), t.define("shed_load", "DELIVER FLEXIBILITY: lower the site's power limit to shed load for the agreed window. This actuates the real EMS (charging allocations rebalance under the new cap) and is logged in the site's event history — the delivery evidence. Restore the original limit after the window with this same tool.", { title: "ShedLoad", description: "Set the site power limit (kW).", fields: [sch.required_str("site_id", []), sch.required_str("max_power_kw", []), sch.optional(sch.required_str("reserved_kw", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let body := jv.stringify(JObj([("max_power_kw", JFloat(jnum(args, "max_power_kw", -1.0))), ("reserved_kw", JFloat(jnum(args, "reserved_kw", 0.0)))]))
    Ok(http_send_json("PATCH", str.concat(ems_url, str.concat("/api/v1/sites/", str.concat(jstr(args, "site_id"), "/limit"))), body, tenant))
  }), t.define("get_site_events", "The site's EMS event history — limit changes and rebalances. Use as delivery evidence for a flex window.", { title: "GetSiteEvents", description: "Site audit log.", fields: [sch.required_str("site_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(ems_url, str.concat("/api/v1/sites/", str.concat(jstr(args, "site_id"), "/events"))), tenant))
  }), t.define("settle_flex", "Settle a DELIVERED flex window: records the buyer->site payment as an L1 chargeback on the settlement trail (auditable; aggregates in /usage) plus a flex.delivered event. The platform re-checks the site's EMS event log for the actuation before accepting — settle only AFTER shed_load ran. ref must be unique per window (site + window start).", { title: "SettleFlex", description: "Trail-settled flexibility payment.", fields: [sch.required_str("buyer_agent", []), sch.required_str("site_id", []), sch.required_str("kwh", []), sch.required_str("eur", []), sch.required_str("ref", []), sch.optional(sch.required_str("window", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let body := jv.stringify(JObj([("from_agent", JStr(jstr(args, "buyer_agent"))), ("to_agent", JStr(agent_id)), ("site_id", JStr(jstr(args, "site_id"))), ("kwh", JFloat(jnum(args, "kwh", 0.0))), ("eur", JStr(jstr(args, "eur"))), ("ref", JStr(jstr(args, "ref"))), ("window", JStr(jstr(args, "window")))]))
    Ok(http_send_json("POST", str.concat(self_url, "/flex/settlements"), body, tenant))
  })]
}

fn system_prompt(ems_id :: Str) -> Str {
  str.join(["You are site energy manager agent ", ems_id, ". You manage charging sites' power envelopes and sell FLEXIBILITY: temporarily shedding site load for a paid window.", " - For a flex request (shed X kW from your sites in window W at price P): call get_sites, check the requested shed fits (current max_power_kw minus a safe floor for committed charging). If it fits, reply COMMITTED with site, kW and window; if not, reply DECLINED with the kW you CAN offer.", " - To DELIVER a committed window: shed_load to the reduced limit at window start; shed_load back to the original limit at window end. The site's event history is your delivery evidence (get_site_events).", " - After delivery: settle_flex once with the buyer agent id, the site id, the kWh shed, the agreed price and a unique ref (site + window start). Settlement is evidence-checked against the site's EMS event log; it will be refused if you never actuated.", " - Never shed below the reserved_kw floor; if a request would strand committed charging sessions, decline and explain.", " Be precise with numbers. Use get_sites for your ACTUAL sites — never invent assets."], "")
}

fn make_agent_def(db :: Db, ems_id :: Str, base_url :: Str, ems_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str, self_url :: Str) -> srv.AgentDef {
  let capability := ems_capability()
  let cfg := { id: ems_id, kind: "ems", system_prompt: system_prompt(ems_id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "ems_url", url: ems_url }], intent_roles: intents.fleet(), tools: make_tools(ems_url, "", self_url, ems_id) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(ems_id, str.concat("Site energy manager agent ", ems_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

