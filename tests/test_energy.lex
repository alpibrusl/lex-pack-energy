# tests/test_energy.lex — pure-logic coverage for src/energy.lex.
#
# a2a_inbox is the one pure, non-trivial function here (agent id -> its A2A
# inbox URL); the rest of this file is HTTP-tool wiring and LLM system-prompt
# text, verified live against a running deployment rather than unit-tested,
# matching how the rest of this pack's files were verified before extraction.
#
# The #236 extraction that moved this pack out of lex-ev-fleet left tests/
# untracked (no test file survived the placeholder's removal) — this restores
# a real one so `lex fmt --check src/ tests/` has a tests/ directory to check.

import "../src/energy" as energy

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn test_a2a_inbox_shape() -> Result[Unit, Str] {
  assert_true(energy.a2a_inbox("grid-coordinator") == "http://localhost:8100/agents/grid-coordinator/", "a2a_inbox must build the agent's local inbox URL from its id")
}

fn test_a2a_inbox_different_ids() -> Result[Unit, Str] {
  assert_true(energy.a2a_inbox("v2g-depot-north") == "http://localhost:8100/agents/v2g-depot-north/", "a2a_inbox must use the given id, not a fixed one")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_a2a_inbox_shape(), test_a2a_inbox_different_ids()]
}

