// A change to one message must not make the background reader hash the rest of the page again.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Data } from "../src/data.ts";
import { MdAhead } from "../src/md-ahead.ts";
import { Effect } from "effect";
import { MD_READING, mdKey, parse } from "../src/markdown.ts";
import { Runner } from "../src/runtime.ts";

test("a_message_change_keeps_unchanged_readings_ready_without_hashing_their_words_again", () => {
  const stable = "An already cached long reply: " + "same words. ".repeat(100);
  const changed = "An edited reply with different words.";
  const stableKey = mdKey(stable);
  const changedKey = mdKey(changed);
  const entries = new Map<number, unknown>([
    [1, { n: 1, kind: "message", thread: 7, authorKind: "agent", text: stable }],
    [2, { n: 2, kind: "message", thread: 7, authorKind: "person", text: "first" }],
  ]);
  const checks: string[] = [];
  const data = {
    logSpan: () => ({ min: 1, max: Math.max(...entries.keys()), count: entries.size }),
    logRange: () => entries,
    // (where a chat opens when not at its end, and what a step read written: none here)
    thread: () => undefined,
    record: () => undefined,
    flushMd: () => {},
    mdStore: () => ({ has: (key: string) => { checks.push(key); return true; } }),
  } as unknown as Data;
  const ahead = new MdAhead(data, {} as Runner, () => 0);
  const readChar = String.prototype.charCodeAt;
  let stableChars = 0;
  String.prototype.charCodeAt = function (at: number) {
    if (String(this) === stable) stableChars++;
    return readChar.call(this, at);
  };
  try {
    ahead.thread("w/s", 7);
    assert.ok(stableChars > 0, "the first time, the old reply is identified for the cache");
    stableChars = 0;
    checks.length = 0;
    entries.set(2, { n: 2, kind: "message", thread: 7, authorKind: "person", text: "second" });
    ahead.thread("w/s", 7);
    assert.deepEqual(checks, [stableKey], "still check the cache, since it can have evicted a reading");
    assert.equal(stableChars, 0, "an unchanged reply's words need no second hash");
    entries.set(3, { n: 3, kind: "edit", target: 1, text: stable, attachments: ["a new attachment"] });
    checks.length = 0;
    ahead.thread("w/s", 7);
    assert.deepEqual(checks, [stableKey]);
    assert.equal(stableChars, 0, "an edit of the attachments leaves the reply's words alone");
    entries.set(3, { n: 3, kind: "edit", target: 1, text: changed });
    checks.length = 0;
    ahead.thread("w/s", 7);
    assert.deepEqual(checks, [changedKey], "an edit is checked by its new words");
    entries.delete(3);
    checks.length = 0;
    ahead.thread("w/s", 7);
    assert.deepEqual(checks, [stableKey], "removing the edit restores the original reply's key");
    assert.equal(stableChars, 0);
  } finally {
    String.prototype.charCodeAt = readChar;
  }
});

test("a_reply_is_prepared_again_when_its_cached_reading_has_been_evicted", async () => {
  const text = `**A saved reply.** ${Math.random()}`;
  const key = mdKey(text);
  const entries = new Map([[1, Object.freeze({ n: 1, kind: "message", thread: 7, authorKind: "agent", text })]]);
  const cached = new Map([[key, "old cached tree"]]);
  let ready!: () => void;
  const prepared = new Promise<void>((resolve) => { ready = resolve; });
  const store = {
    has: (k: string) => cached.has(k),
    get: (k: string) => cached.get(k) ?? null,
    put: (k: string, value: string) => { cached.set(k, value); ready(); },
  };
  const data = {
    logSpan: () => ({ min: 1, max: 1, count: 1 }),
    logRange: () => entries,
    // (where a chat opens when not at its end, and what a step read written: none here)
    thread: () => undefined,
    record: () => undefined,
    flushMd: () => {},
    mdStore: () => store,
  } as unknown as Data;
  const runner = new Runner();
  const ahead = new MdAhead(data, runner, () => 0);
  try {
    ahead.thread("w/s", 7);
    cached.delete(key);
    ahead.thread("w/s", 7);
    await prepared;
    assert.deepEqual(JSON.parse(cached.get(key)!), parse(text));
  } finally {
    runner.shutdown();
  }
});

test("the_chats_read_ahead_as_the_core_starts_are_looked_up_a_chat_a_turn", async () => {
  // (all at once it held the core a second and more as a phone's first chat was opened: md-ahead.ts seed)
  const said: string[] = [];
  const db = { stations: () => ["w/a", "w/b"], meta: () => String(MD_READING) };
  const entries = new Map([[1, Object.freeze({ n: 1, kind: "message", thread: 1, authorKind: "agent", text: "kept" })]]);
  const data = {
    dbs: () => [db],
    recentThreads: (station: string) => (station === "w/a" ? [1, 2] : [3]),
    logSpan: (_t: string, station: string, id: string) => { said.push(`read ${station} ${id}`); return { min: 1, max: 1, count: 1 }; },
    logRange: () => entries,
    // (where a chat opens when not at its end, and what a step read written: none here)
    thread: () => undefined,
    record: () => undefined,
    flushMd: () => {},
    mdStore: () => ({ has: () => true }),
  } as unknown as Data;
  const runner = new Runner();
  const ahead = new MdAhead(data, runner, () => 0, () => {}, () => Effect.sync(() => said.push("turn")).pipe(Effect.andThen(Effect.yieldNow)));
  try {
    ahead.seed();
    assert.deepEqual(said.filter((s) => s.startsWith("read")), [], "no chat is read as it is asked");
    while (said.filter((s) => s.startsWith("read")).length < 3) await new Promise((r) => setImmediate(r));
    assert.deepEqual(said.filter((s) => s.startsWith("read")), ["read w/a 1", "read w/a 2", "read w/b 3"]);
    for (let i = 0; i < said.length; i++) if (said[i]!.startsWith("read")) assert.equal(said[i - 1], "turn", "each chat after a turn of its own");
  } finally {
    runner.shutdown();
  }
});

test("refresh_notifies_each_waiting_owner_once_only_after_its_final_queued_block_finishes", async () => {
  const stores = new Map<string, Map<string, string>>();
  const storeOf = (station: string) => {
    let map = stores.get(station);
    if (!map) {
      map = new Map<string, string>();
      stores.set(station, map);
    }
    return {
      has: (k: string) => map.has(k),
      get: (k: string) => map.get(k) ?? null,
      put: (k: string, value: string) => void map.set(k, value),
    };
  };
  const data = {
    dbs: () => [],
    logSpan: () => null,
    logRange: () => new Map(),
    thread: () => undefined,
    record: () => undefined,
    flushMd: () => {},
    mdStore: (station: string) => storeOf(station),
  } as unknown as Data;

  const events: [string, string, boolean][] = [];
  let resolveDone!: () => void;
  const done = new Promise<void>((resolve) => { resolveDone = resolve; });
  const textOne = "**one** block";
  const textTwo = "**two** block";
  const runner = new Runner();
  const ahead = new MdAhead(data, runner, () => 0, (station, of) => {
    const map = stores.get(station)!;
    const ready = of === "t:1" && station === "w/a"
      ? map.has(mdKey(textOne)) && map.has(mdKey(textTwo))
      : of === "t:2"
        ? map.has(mdKey(textTwo))
        : map.has(mdKey(textOne));
    events.push([station, of, ready]);
    if (events.length === 3) resolveDone();
  });
  try {
    ahead.refresh("w/a", "t:1", textOne);
    ahead.refresh("w/a", "t:1", textOne);
    ahead.refresh("w/a", "t:1", textTwo);
    ahead.refresh("w/a", "t:2", textTwo);
    ahead.refresh("w/b", "t:1", textOne);
    await done;
    assert.deepEqual(events.map(([st, of]) => `${st}:${of}`).sort(), ["w/a:t:1", "w/a:t:2", "w/b:t:1"]);
    for (const [, , ready] of events) assert.equal(ready, true);

    const batchSize = 200;
    let resolveBatch!: () => void;
    const batchDone = new Promise<void>((resolve) => { resolveBatch = resolve; });
    const batchEvents: string[] = [];
    const batchStore = new Map<string, string>();
    const batchAhead = new MdAhead(
      { ...data, mdStore: () => ({ has: (k: string) => batchStore.has(k), get: (k: string) => batchStore.get(k) ?? null, put: (k: string, v: string) => void batchStore.set(k, v) }) } as unknown as Data,
      runner,
      () => 0,
      (station, of) => {
        batchEvents.push(`${station}:${of}:${batchStore.size}`);
        resolveBatch();
      },
    );
    for (let i = 0; i < batchSize; i++) batchAhead.refresh("w/a", "t:9", `item ${i}`);
    await batchDone;
    assert.deepEqual(batchEvents, [`w/a:t:9:${batchSize}`]);
  } finally {
    runner.shutdown();
  }
});
