import assert from "node:assert/strict";
import test from "node:test";
import { MeshRelayEvents, watchRequest } from "../src/mesh-relay-events.ts";
import type { MeshRelay } from "../src/mesh-relay-registry.ts";
const node = "ab".repeat(32);
const relay = (revision: number): MeshRelay => ({node,name:"relay",generation:1,revision,address:{id:node,addrs:[]}});

test("global watch rejects stale proofs and bounds slow readers and per-node subscriptions", async t => {
  t.mock.timers.enable({apis:["setInterval"]});
  const now = 1_000_000;
  assert.ok(watchRequest(JSON.stringify({node,generation:1,at:now}),now));
  for (const value of [{node,generation:0,at:now},{node,generation:1,at:now-60_001},{node,generation:1,at:now+60_001}]) {
    assert.equal(watchRequest(JSON.stringify(value),now),null);
  }
  const events = new MeshRelayEvents();
  const first = events.open(node,1,now,now,[relay(1)])!;
  const second = events.open(node,1,now+1,now,[relay(1)])!;
  assert.equal(events.open(node,1,now,now,[relay(1)]),null);
  assert.equal(events.open(node,1,now+2,now,[relay(1)]),null);
  for (let revision=2;revision<=100;revision++) events.changed([relay(revision)]);
  const reader = first.getReader();
  const next = async () => JSON.parse(new TextDecoder().decode((await reader.read()).value));
  assert.equal((await next()).relays[0].revision,1);
  assert.equal((await next()).relays[0].revision,100,"slow consumers retain the newest snapshot, not the intervening updates");
  events.changed([]);
  assert.deepEqual((await next()).relays,[]);
  assert.equal((await reader.read()).done,true);
  await second.cancel();
  const replacement = events.open(node,1,now+2,now,[relay(1)])!;
  assert.ok(replacement); await replacement.cancel();
  assert.doesNotThrow(() => events.changed([relay(101)]));
});

test("global watch does not schedule a heartbeat interval when the initial snapshot closes the stream", async () => {
  const realSetInterval = globalThis.setInterval;
  let scheduled = 0;
  globalThis.setInterval = ((...args: Parameters<typeof setInterval>) => {
    scheduled++;
    return realSetInterval(...args);
  }) as typeof setInterval;
  try {
    const events = new MeshRelayEvents();
    const stream = events.open(node, 2, 1_000_000, 1_000_000, [relay(1)])!;
    assert.ok(stream);
    assert.equal(scheduled, 0, "closing on initial snapshot must not leak a heartbeat timer");
    const reader = stream.getReader();
    const first = await reader.read();
    assert.equal(first.done, false);
    assert.equal(JSON.parse(new TextDecoder().decode(first.value)).relays[0].generation, 1);
    assert.equal((await reader.read()).done, true);
  } finally {
    globalThis.setInterval = realSetInterval;
  }
});
