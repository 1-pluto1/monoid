// White-box unit, security, and seeded differential tests for O(1) wire-identity tail scanning in `Client::later_at`.

///|
fn wire_test_client() -> (Client, Array[Json]) {
  let sent : Array[Json] = []
  let c = Client::new(fn(s) { sent.push(@json.parse(s) catch { _ => Json::null() }) })
  c.keep(fn(name, _) {
    match name {
      "chats" | "chatJobs" | "station" | "prefs" => 16
      _ => 0
    }
  })
  c.show_kept(fn(name) { name == "chatJobs" || name == "station" || name == "prefs" })
  c.device_global(fn(name) { name == "prefs" })
  (c, sent)
}

///|
test "tail_wire_gen handles 16-digit production conn IDs, 2^53-1 boundary, and rejects spoofed/non-canonical forms" {
  // Standard canonical payloads from core-ts `to()`, including 16-digit production `conn` (Date.now()*1000 + jitter)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"authGen\":2}"), Some((Some(1L), Some(2), None)))
  assert_eq(
    tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1795869167405123,\"authGen\":4}"),
    Some((Some(1795869167405123L), Some(4), None)),
  )
  assert_eq(
    tail_wire_gen("{\"id\":1,\"delta\":[],\"conn\":9007199254740991,\"authGen\":7,\"vaultGen\":9}"),
    Some((Some(9007199254740991L), Some(7), Some(9))),
  )
  // 2^53 (9007199254740992) and >16 digits MUST force @json.parse fallback (`conn=None` or `None`)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":9007199254740992,\"authGen\":2}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":12345678901234567,\"authGen\":2}"), Some((None, Some(2), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":12345678901234567}"), None)
  // A >16-digit numeric payload BEFORE canonical wire-gen fields still hits the fast path cleanly
  assert_eq(
    tail_wire_gen("{\"id\":1,\"value\":12345678901234567890,\"conn\":1795869167405123,\"authGen\":2}"),
    Some((Some(1795869167405123L), Some(2), None)),
  )

  // All valid JSON value terminators before `,`
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":\"ok\",\"conn\":3,\"authGen\":0}"), Some((Some(3L), Some(0), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":true,\"conn\":4,\"authGen\":5}"), Some((Some(4L), Some(5), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":false,\"conn\":4,\"authGen\":5}"), Some((Some(4L), Some(5), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":null,\"conn\":4,\"authGen\":5}"), Some((Some(4L), Some(5), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":42,\"conn\":4,\"authGen\":5}"), Some((Some(4L), Some(5), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":9}"), Some((Some(9L), None, None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"vaultGen\":3,\"authGen\":2,\"conn\":1}"), Some((Some(1L), Some(2), Some(3))))

  // Adversarial nested spoof attempts MUST return None (force full @json.parse fallback)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{\"x\":1,\"conn\":1,\"authGen\":2}}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":\"x,\\\"conn\\\":1,\\\"authGen\\\":2\"}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":[{\"conn\":1,\"authGen\":2}]}"), None)

  // Non-canonical / malformed / duplicate / oversized numbers MUST return None (or leave conn=None to force fallback)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"authGen\":2,\"extra\":3}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"authGen\":2,\"extra\":true}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"conn\":2,\"authGen\":2}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":01,\"authGen\":2}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":-1,\"authGen\":2}"), Some((None, Some(2), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1.0,\"authGen\":2}"), Some((None, Some(2), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"authGen\":-2}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"authGen\":2.0}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"authGen\":1000000000}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{}, \"conn\":1,\"authGen\":2}"), Some((None, Some(2), None)))
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1, \"authGen\":2}"), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":{},\"conn\":1,\"authGen\":2} "), None)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":,\"conn\":1,\"authGen\":2}"), None)
  // Adversarial long digit run (must stop in O(1) at 17-char bound)
  assert_eq(tail_wire_gen("{\"id\":1,\"value\":9999999999999999999999999999999999999999}"), None)

  // Non-BMP UTF-16 surrogate pairs at every speculative probe alignment (`i - 7`, `i - 10`, `i - 11`):
  // MUST NOT abort/panic when a speculative probe lands on a trailing surrogate code unit.
  for pad = 0; pad < 16; pad = pad + 1 {
    let mut filler = ""
    for _k = 0; _k < pad; _k = _k + 1 {
      filler = filler + "a"
    }
    let unknown_num = "{\"id\":1,\"v\":\"😀" + filler + "\",\"x\":1}"
    assert_eq(tail_wire_gen(unknown_num), None)
    let valid_tail = "{\"id\":1,\"v\":\"😀" + filler + "\",\"conn\":1795869167405123,\"authGen\":4}"
    assert_eq(tail_wire_gen(valid_tail), Some((Some(1795869167405123L), Some(4), None)))
  }
}

///|
test "Client::later_at hits zero-parse fast path with 16-digit production conn and fails closed on corrupt queued frames" {
  let (c, sent) = wire_test_client()
  let prod_conn = "1795869167405123"
  let stale_conn = "1795869167405122"
  assert_true(
    c.receive(
      "{\"auth\":{\"conn\":" + prod_conn + ",\"global\":2,\"aggregate\":2,\"vaultGlobal\":3,\"scopes\":{\"wsA\":4},\"vaults\":{}}}",
    ),
  )

  // 1. Kept ending sub with realistic 16-digit production conn: unparseable body proves O(1) zero-parse fast path
  let s = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  c.unsubscribe(s)
  let v_before = s.version
  // Valid stale authGen=3 -> proven stale via full parse, rejected without touching s.version or s.later
  assert_true(c.later("{\"id\":1,\"value\":{\"n\":99},\"conn\":" + prod_conn + ",\"authGen\":3}"))
  assert_eq(s.version, v_before)
  assert_true(s.later is None)
  // Valid stale 16-digit conn -> proven stale via full parse, rejected without touching s.version or s.later
  assert_true(c.later("{\"id\":1,\"value\":{\"n\":99},\"conn\":" + stale_conn + ",\"authGen\":4}"))
  assert_eq(s.version, v_before)
  assert_true(s.later is None)
  // Valid stale conn WITHOUT authGen -> proven stale via full parse, rejected without touching s.version or s.later
  assert_true(c.later("{\"id\":1,\"value\":{\"n\":99},\"conn\":" + stale_conn + "}"))
  assert_eq(s.version, v_before)
  assert_true(s.later is None)
  // Fresh 16-digit conn + authGen with unparseable body -> fast-accepted in O(1) without parsing body
  assert_true(c.later("{\"id\":1,\"value\":{never read},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  assert_eq(s.version, v_before + 1)
  // Replaced by real valid whole value + delta on fast path
  assert_true(c.later("{\"id\":1,\"value\":{\"n\":10},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  assert_true(c.later("{\"id\":1,\"delta\":[{\"path\":[\"n\"],\"set\":11}],\"conn\":" + prod_conn + ",\"authGen\":4}"))
  // Spoofed nested object with no root conn/authGen -> falls back to @json.parse and is REJECTED (never clobbers n=11!)
  assert_true(c.later("{\"id\":1,\"value\":{\"n\":999,\"conn\":" + prod_conn + ",\"authGen\":4}}"))
  // Spoofed string tail -> falls back to @json.parse and is REJECTED (valid JSON, definitely stale -> keeps n=11)
  assert_true(c.later("{\"id\":1,\"value\":\"evil,\\\"conn\\\":" + prod_conn + ",\\\"authGen\\\":4\"}"))
  // True fallback path (`extra` AFTER `conn`/`authGen`): tail_wire_gen MUST return None, fallback accepts valid fresh delta
  let fb_delta = "{\"id\":1,\"delta\":[{\"path\":[\"n\"],\"set\":12}],\"conn\":" + prod_conn + ",\"authGen\":4,\"extra\":true}"
  assert_true(tail_wire_gen(fb_delta) is None, msg="extra trailing field must exercise @json.parse fallback")
  assert_true(c.later(fb_delta))
  assert_true(c.receive("{\"id\":1,\"v\":\"k:st1\",\"conn\":" + prod_conn + ",\"authGen\":4}"))
  let s2 = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_eq(s2.value.unwrap().stringify(), "{\"n\":12}")

  // 2. Fail-closed cache consistency (Codex R1 P1): if a queued whole frame fails `@json.parse` in `Later::now()`
  //    (e.g. lone UTF-16 surrogate or corrupt body with valid tail), re-subscribing MUST NOT return stale `base`
  //    and MUST NOT send `have: <token>` bound to stale data.
  assert_true(c.receive("{\"id\":2,\"value\":{\"n\":20},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  c.unsubscribe(s2)
  assert_true(c.later("{\"id\":2,\"delta\":[{\"path\":[\"n\"],\"set\":21}],\"conn\":" + prod_conn + ",\"authGen\":4}"))
  assert_true(c.later("{\"id\":2,\"value\":{corrupt_whole},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  assert_true(c.receive("{\"id\":2,\"v\":\"k:st-corrupt\",\"conn\":" + prod_conn + ",\"authGen\":4}"))
  let s3 = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(s3.value is None, msg="corrupt queued whole must fail closed instead of returning stale base")
  assert_false(sent[sent.length() - 1].stringify().contains("have"), msg="must not send have token for corrupt kept entry")

  // 2b. Fail-closed fallback parse failure (Codex R2 P1): if a frame enters the `@json.parse` fallback and fails to
  //     parse (staleness unknown), `Client::later_at` MUST invalidate the cached base so a subsequent keep receipt `v`
  //     cannot bind stale data to the new token (even for lazy non-`show_kept` topics like `chats`), until a valid
  //     whole value arrives.
  assert_true(c.receive("{\"id\":" + s3.id.to_string() + ",\"value\":{\"n\":30},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  c.unsubscribe(s3)
  let corrupt_fb = "{\"id\":" + s3.id.to_string() + ",\"delta\":[{corrupt},\"conn\":" + prod_conn + ",\"authGen\":4,\"extra\":true}"
  assert_true(tail_wire_gen(corrupt_fb) is None)
  assert_true(c.later(corrupt_fb))
  assert_true(c.receive("{\"id\":" + s3.id.to_string() + ",\"v\":\"k:st-fb-corrupt\",\"conn\":" + prod_conn + ",\"authGen\":4}"))
  let s4 = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(s4.value is None, msg="fallback parse failure must invalidate stale base")
  assert_false(sent[sent.length() - 1].stringify().contains("have"), msg="must not send have token after fallback parse failure")
  // Verify lazy kept topic (`chats`) also drops base immediately on fallback parse failure and recovers on valid whole
  let ch1 = c.subscribe("chats", params={ "scope": "wsA" })
  assert_true(c.receive("{\"id\":" + ch1.id.to_string() + ",\"value\":{\"n\":40},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  c.unsubscribe(ch1)
  assert_true(c.later("{\"id\":" + ch1.id.to_string() + ",\"value\":{corrupt_no_tail"))
  assert_true(c.receive("{\"id\":" + ch1.id.to_string() + ",\"v\":\"k:ch-corrupt\",\"conn\":" + prod_conn + ",\"authGen\":4}"))
  let ch2 = c.subscribe("chats", params={ "scope": "wsA" })
  assert_false(sent[sent.length() - 1].stringify().contains("have"), msg="lazy kept topic must not keep stale base after fallback parse failure")
  // Recovery: valid whole value after fallback parse failure heals the ending sub before `v`
  assert_true(c.receive("{\"id\":" + ch2.id.to_string() + ",\"value\":{\"n\":41},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  c.unsubscribe(ch2)
  assert_true(c.later("{\"id\":" + ch2.id.to_string() + ",\"value\":{corrupt_no_tail"))
  assert_true(c.later("{\"id\":" + ch2.id.to_string() + ",\"value\":{\"n\":42},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  assert_true(c.receive("{\"id\":" + ch2.id.to_string() + ",\"v\":\"k:ch-healed\",\"conn\":" + prod_conn + ",\"authGen\":4}"))
  let ch3 = c.subscribe("chats", params={ "scope": "wsA" })
  assert_true(sent[sent.length() - 1].stringify().contains("\"have\":\"k:ch-healed\""))
  assert_true(c.receive("{\"id\":" + ch3.id.to_string() + ",\"same\":true,\"conn\":" + prod_conn + ",\"authGen\":4}"))
  assert_eq(ch3.value.unwrap().stringify(), "{\"n\":42}")
  c.unsubscribe(ch3)

  // 2c. Truncated frame with surface-stale inner object tail (Codex R3 P1): `tail_wire_gen` sees a stale-looking
  //     `conn`/`authGen` at the inner `}`, but `text_wire_check` MUST NOT classify it as `Stale` without parsing the
  //     full root object; `@json.parse` fails -> `Corrupt` -> base is invalidated so `v` cannot bind stale data.
  assert_true(c.receive("{\"id\":" + s4.id.to_string() + ",\"value\":{\"n\":50},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  c.unsubscribe(s4)
  let trunc_stale = "{\"id\":" + s4.id.to_string() + ",\"value\":{\"inner\":1,\"conn\":" + stale_conn + ",\"authGen\":3}"
  assert_eq(tail_wire_gen(trunc_stale), Some((Some(1795869167405122L), Some(3), None)))
  assert_true(c.later(trunc_stale))
  assert_true(c.receive("{\"id\":" + s4.id.to_string() + ",\"v\":\"k:st-trunc-stale\",\"conn\":" + prod_conn + ",\"authGen\":4}"))
  let s5 = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  assert_true(s5.value is None, msg="truncated frame with surface-stale inner tail must invalidate base")
  assert_false(sent[sent.length() - 1].stringify().contains("have"), msg="must not bind stale base after truncated surface-stale frame")
  c.unsubscribe(s5)

  // 3. Discarded ending sub (!s.keeping && !has_from): drops immediately before any tail/JSON inspection
  let r1 = c.subscribe("chatRows", params={ "station": "wsA/st1", "limit": 2 })
  assert_true(c.receive("{\"id\":" + r1.id.to_string() + ",\"value\":{\"items\":[]},\"conn\":" + prod_conn + ",\"authGen\":4}"))
  let r2 = c.subscribe("chatRows", params={ "station": "wsA/st1", "limit": 4 })
  c.unsubscribe(r1)
  c.unsubscribe(r2)
  assert_true(c.later("{\"id\":" + r1.id.to_string() + ",\"value\":{never read"))
  assert_true(r1.later is None)

  // 4. Ending kept sub with no value yet (!s.holds()): delta is discarded immediately before any parse
  let k0 = c.subscribe("chatJobs", params={ "scope": "wsA" })
  c.unsubscribe(k0)
  let kv0 = k0.version
  assert_true(c.later("{\"id\":" + k0.id.to_string() + ",\"delta\":[never read"))
  assert_eq(k0.version, kv0)
  assert_true(k0.later is None)

  // 5. Device-global topic requires only `conn` (no `authGen` needed) on fast path
  let p = c.subscribe("prefs")
  assert_true(c.receive("{\"id\":" + p.id.to_string() + ",\"value\":{\"dark\":false},\"conn\":" + prod_conn + "}"))
  c.unsubscribe(p)
  let pv0 = p.version
  assert_true(c.later("{\"id\":" + p.id.to_string() + ",\"value\":{\"dark\":true},\"conn\":" + stale_conn + "}"))
  assert_eq(p.version, pv0)
  assert_true(c.later("{\"id\":" + p.id.to_string() + ",\"value\":{never read},\"conn\":" + prod_conn + "}"))
  assert_eq(p.version, pv0 + 1)
  assert_true(c.later("{\"id\":" + p.id.to_string() + ",\"value\":{\"dark\":true},\"conn\":" + prod_conn + "}"))
  assert_true(c.receive("{\"id\":" + p.id.to_string() + ",\"v\":\"k:p\",\"conn\":" + prod_conn + "}"))
  let p2 = c.subscribe("prefs")
  assert_eq(p2.value.unwrap().stringify(), "{\"dark\":true}")
}

///|
fn xorshift32(state : Ref[Int]) -> Int {
  let mut x = state.val
  x = x ^ (x << 13)
  x = x ^ ((x.reinterpret_as_uint() >> 17).reinterpret_as_int())
  x = x ^ (x << 5)
  state.val = x
  x & 0x7FFFFFFF
}

///|
test "seeded differential test: text_wire_check == msg_stale_for across valid, spoofed, masked, and 16-digit conn cases" {
  let (c, _) = wire_test_client()
  let conn_ok = "1795869167405123"
  let conn_bad = "1795869167405122"
  assert_true(
    c.receive(
      "{\"auth\":{\"conn\":" + conn_ok + ",\"global\":2,\"aggregate\":3,\"vaultGlobal\":4,\"scopes\":{\"wsA\":3,\"wsB\":3},\"vaults\":{\"wsA/v1\":5,\"wsB/v1\":5}}}",
    ),
  )
  let ws_sub = c.subscribe("station", params={ "scope": "wsA", "station": "wsA/st1" })
  let vault_sub = c.subscribe("vaultItems", params={ "workspace": "wsA", "vault": "v1" })
  let dev_sub = c.subscribe("prefs")
  // Masked subscriptions (`s.masked == true` + active scope mask `is_topic_masked == true`)
  let masked_ws = c.subscribe("station", params={ "scope": "wsB", "station": "wsB/st1" })
  let masked_vault = c.subscribe("vaultItems", params={ "workspace": "wsB", "vault": "v1" })
  let undo_ws = c.mask_scope(Workspace("wsB"))
  let undo_v = c.mask_scope(Vault("wsB", "v1"))

  let subs = [ws_sub, vault_sub, dev_sub, masked_ws, masked_vault]

  // Fixed curated cases first
  let curated = [
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":3}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":4}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":2}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_bad + ",\"authGen\":3}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":3,\"vaultGen\":5}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":4,\"vaultGen\":6}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":3,\"vaultGen\":4}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + "}",
    "{\"id\":1,\"value\":{\"conn\":" + conn_ok + ",\"authGen\":3,\"vaultGen\":5}}",
    "{\"id\":1,\"value\":\"x,\\\"conn\\\":" + conn_ok + ",\\\"authGen\\\":3,\\\"vaultGen\\\":5\"}",
    "{\"id\":1,\"authGen\":3,\"value\":{},\"conn\":" + conn_ok + "}",
    "{\"id\":1,\"vaultGen\":5,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":3}",
    "{\"id\":1,\"conn\":1,\"authGen\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":3,\"vaultGen\":5}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"conn\":" + conn_bad + ",\"authGen\":3,\"vaultGen\":5}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ",\"authGen\":3,\"vaultGen\":5,\"extra\":1}",
    "{\"id\":1,\"value\":{},\"conn\":9007199254740991,\"authGen\":3,\"vaultGen\":5}",
    "{\"id\":1,\"value\":{},\"conn\":9007199254740992,\"authGen\":3,\"vaultGen\":5}",
    "{\"id\":1,\"value\":{},\"conn\":" + conn_ok + ".0,\"authGen\":3,\"vaultGen\":5}",
    "{\"id\":1,\"value\":{},\"conn\":-1,\"authGen\":3,\"vaultGen\":5}",
    "{\"id\":1,\"value\":{}, \"conn\": " + conn_ok + ", \"authGen\": 3, \"vaultGen\": 5 }",
    "{\"id\":1,\"value\":\"😀\",\"x\":1}",
    "{\"id\":1,\"value\":\"😀a\",\"conn\":" + conn_ok + ",\"authGen\":3,\"extra\":1}",
  ]
  for sub in subs {
    for text in curated {
      let parsed = @json.parse(text) catch { _ => fail("case must be valid JSON: " + text) }
      guard parsed is Object(m) else { fail("expected object") }
      let ref_stale = c.msg_stale_for(m, sub)
      match c.text_wire_check(text, sub) {
        Stale => assert_true(ref_stale, msg="curated mismatch (Stale vs Fresh): " + text)
        Fresh => assert_false(ref_stale, msg="curated mismatch (Fresh vs Stale): " + text)
        Corrupt => fail("valid JSON must not return Corrupt: " + text)
      }
    }
  }

  // Seeded random differential fuzz (500 generated JSON payloads x 5 subs = 2,500 differential checks)
  let rng = Ref(0x13572468)
  let bodies = [
    "{}",
    "[]",
    "true",
    "false",
    "null",
    "0",
    "42",
    "\"plain\"",
    "\"中文😀\\\"escaped\\\",\\\"conn\\\":" + conn_ok + "\"",
    "{\"nested\":1,\"conn\":" + conn_ok + ",\"authGen\":3,\"vaultGen\":5}",
    "[{\"conn\":" + conn_ok + ",\"authGen\":3}]",
  ]
  let conn_vals = [conn_ok, conn_bad, "0", "9007199254740991", "9007199254740992", conn_ok + ".0", "-1"]
  let ag_vals = ["0", "2", "3", "4", "1000000000", "-1", "3.0"]
  let vg_vals = ["0", "4", "5", "6", "1000000000", "5.0"]
  let mut fast_hits = 0
  for _iter = 0; _iter < 500; _iter = _iter + 1 {
    let sb = StringBuilder()
    sb.write_string("{\"id\":1")
    // Optionally inject duplicate earlier key before value
    if xorshift32(rng) % 5 == 0 {
      sb.write_string(",\"conn\":" + conn_vals[xorshift32(rng) % conn_vals.length()])
    }
    if xorshift32(rng) % 5 == 0 {
      sb.write_string(",\"authGen\":" + ag_vals[xorshift32(rng) % ag_vals.length()])
    }
    let body = bodies[xorshift32(rng) % bodies.length()]
    sb.write_string(",\"value\":" + body)
    // Add 0..3 trailing fields in random order, optionally with whitespace or extra tail key
    let order = xorshift32(rng) % 6
    let has_conn = xorshift32(rng) % 4 != 0
    let has_ag = xorshift32(rng) % 4 != 0
    let has_vg = xorshift32(rng) % 3 == 0
    let sp = if xorshift32(rng) % 10 == 0 { " " } else { "" }
    let f_conn = if has_conn { "," + sp + "\"conn\":" + conn_vals[xorshift32(rng) % conn_vals.length()] } else { "" }
    let f_ag = if has_ag { "," + sp + "\"authGen\":" + ag_vals[xorshift32(rng) % ag_vals.length()] } else { "" }
    let f_vg = if has_vg { "," + sp + "\"vaultGen\":" + vg_vals[xorshift32(rng) % vg_vals.length()] } else { "" }
    match order {
      0 => sb.write_string(f_conn + f_ag + f_vg)
      1 => sb.write_string(f_conn + f_vg + f_ag)
      2 => sb.write_string(f_ag + f_conn + f_vg)
      3 => sb.write_string(f_ag + f_vg + f_conn)
      4 => sb.write_string(f_vg + f_conn + f_ag)
      _ => sb.write_string(f_vg + f_ag + f_conn)
    }
    if xorshift32(rng) % 7 == 0 {
      sb.write_string(",\"extra\":1")
    }
    sb.write_string("}")
    let text = sb.to_string()
    if tail_wire_gen(text) is Some(_) {
      fast_hits += 1
    }
    let parsed = @json.parse(text) catch { _ => fail("generated invalid JSON: " + text) }
    guard parsed is Object(m) else { fail("expected object") }
    for sub in subs {
      let ref_stale = c.msg_stale_for(m, sub)
      match c.text_wire_check(text, sub) {
        Stale => assert_true(ref_stale, msg="fuzz mismatch (Stale vs Fresh): " + text)
        Fresh => assert_false(ref_stale, msg="fuzz mismatch (Fresh vs Stale): " + text)
        Corrupt => fail("valid JSON must not return Corrupt: " + text)
      }
    }
  }
  assert_true(fast_hits > 100, msg="expected seeded fuzz to exercise fast path heavily")
  undo_v()
  undo_ws()
}
