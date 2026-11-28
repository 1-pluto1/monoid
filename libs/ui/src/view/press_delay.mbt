// Delayed visual press indication inside scrollable containers (iOS `delaysContentTouches` / Android Compose
// scrollable press delay): `View::pressed()` stays immediate for input logic (repeat, tooltip dismiss, drag reset),
// while `View::press_shown()` delays lighting until a fresh press inside a `View::scrolls` container (`Tree::in_scroller`)
// has stayed for `delay_ms` (e.g. `tap_indication_ms`). If the finger lifts quickly, the scroller claims the touch, or
// the node is disposed before then, the timer is cancelled and no press highlight flashes. Handed-off holds (`through` /
// `hold_in`) pass `immediate=true` and light at once.
//
// State lives in a per-`Tree` side table (mirroring `RestBook`) so `Tree`'s C struct layout in `decls.h` stays
// unchanged across `MBC_STORE` cached build units.

///|
priv struct PressDelayState {
  mut delay_ms : () -> Double
  mut cancel : () -> Unit
  mut pending : NodeId?
  mut shown : NodeId?
  cells : Map[Int, (Int, @signals.Signal[Bool])]
}

///|
// kept across runs: per-Tree side table + 1-slot MRU cache, cleared on `Tree::dispose`
let tree_press_delays : Ref[Array[(Tree, PressDelayState)]] = Ref([])

///|
// kept across runs: 1-slot MRU cache for `Tree::press_delay_opt` / `press_delay_state`, cleared on `Tree::dispose`
let last_press_delay : Ref[(Tree, PressDelayState)?] = Ref(None)

///|
fn Tree::press_delay_opt(self : Tree) -> PressDelayState? {
  match last_press_delay.val {
    Some((t, st)) if physical_equal(t, self) => return Some(st)
    _ => ()
  }
  for entry in tree_press_delays.val {
    if physical_equal(entry.0, self) {
      last_press_delay.val = Some(entry)
      return Some(entry.1)
    }
  }
  None
}

///|
fn Tree::press_delay_state(self : Tree) -> PressDelayState {
  match self.press_delay_opt() {
    Some(st) => st
    None => {
      let st : PressDelayState = {
        delay_ms: fn() { 0.0 },
        cancel: fn() {  },
        pending: None,
        shown: None,
        cells: {},
      }
      let pair = (self, st)
      tree_press_delays.val.push(pair)
      last_press_delay.val = Some(pair)
      st
    }
  }
}

///|
/// How long (ms) a fresh press on a node inside a scrollable container (`Tree::in_scroller`) waits before lighting
/// `View::press_shown()` (`0.0` for immediate highlight, e.g. mouse input). Configured by the window host before
/// building nodes; trees that never configure it delegate `View::press_shown()` straight to `View::pressed()` without
/// allocating a side-table entry.
pub fn Tree::press_delay_in_scroll(self : Tree, f : () -> Double) -> Unit {
  let st = self.press_delay_state()
  st.delay_ms = f
  if st.shown is None && st.pending is None && self.pressing is Some(p) {
    st.shown = Some(p)
  }
}

///|
/// Clear any pending delayed press timer and remove `self` from the side table on `Tree::dispose`, releasing the array
/// slot without retaining disposed `Tree` references.
fn Tree::press_delay_clear(self : Tree) -> Unit {
  match last_press_delay.val {
    Some((t, _)) if physical_equal(t, self) => last_press_delay.val = None
    _ => ()
  }
  let arr = tree_press_delays.val
  let mut found = false
  for entry in arr {
    if physical_equal(entry.0, self) {
      found = true
      let st = entry.1
      let c = st.cancel
      st.cancel = fn() {  }
      st.pending = None
      st.shown = None
      st.cells.clear()
      c()
      break
    }
  }
  if found {
    tree_press_delays.val = arr.filter(fn(e) { !physical_equal(e.0, self) })
  }
}

///|
/// Cancel any pending delayed press highlight for this tree.
fn Tree::cancel_press_delay(self : Tree) -> Unit {
  guard self.press_delay_opt() is Some(st) else { return }
  if st.pending is Some(_) {
    let c = st.cancel
    st.cancel = fn() {  }
    st.pending = None
    c()
  }
}

///|
/// Delay (ms) before lighting `View::press_shown()` for `id`; `0.0` outside scrollable containers or when disabled.
fn Tree::press_delay_for(self : Tree, id : NodeId) -> Double {
  guard self.press_delay_opt() is Some(st) else { return 0.0 }
  if !self.in_scroller(id) {
    return 0.0
  }
  let ms = @signals.untracked(st.delay_ms)
  if ms > 0.0 {
    ms
  } else {
    0.0
  }
}

///|
fn Tree::press_shown_tell(self : Tree, st : PressDelayState, id : NodeId?, on : Bool) -> Unit {
  guard id is Some(i) && self.alive_id(i) else { return }
  match st.cells.get(i.at) {
    Some((gen, s)) if gen == i.gen => s.set(on || self.lit_every)
    _ => ()
  }
}

///|
fn Tree::press_shown_to(self : Tree, st : PressDelayState, id : NodeId?) -> Unit {
  let prev = st.shown
  if prev != id {
    st.shown = id
    self.press_shown_tell(st, prev, false)
    self.press_shown_tell(st, id, true)
  }
}

///|
/// Update visual press indication when `Tree::held_to` changes to `h`. Handed-off holds pass `immediate=true` and
/// light at once; fresh presses inside a scroller wait `press_delay_for(id)` before lighting `View::press_shown()`.
fn Tree::press_shown_update(self : Tree, h : NodeId?, immediate : Bool) -> Unit {
  guard self.press_delay_opt() is Some(st) else { return }
  self.cancel_press_delay()
  match h {
    Some(id) => {
      let delay = if immediate { 0.0 } else { self.press_delay_for(id) }
      if delay > 0.0 {
        self.press_shown_to(st, None)
        guard self.view_of(id) is Some(v) else { return }
        st.pending = Some(id)
        let due = self.cause_now() + delay
        st.cancel = v.at_moment(due, fn() {
          if st.pending == Some(id) {
            st.pending = None
            st.cancel = fn() {  }
            if self.held == Some(id) && self.alive_id(id) {
              self.press_shown_to(st, Some(id))
            }
          }
        })
      } else {
        self.press_shown_to(st, Some(id))
      }
    }
    None => self.press_shown_to(st, None)
  }
}

///|
/// Remove a disposed node's `press_shown` cell so pooled slots never retain stale signals.
fn Tree::press_shown_drop(self : Tree, at : Int, gen : Int) -> Unit {
  guard self.press_delay_opt() is Some(st) else { return }
  match st.cells.get(at) {
    Some((g, _)) if g == gen => st.cells.remove(at)
    _ => ()
  }
}

///|
/// Update all live `press_shown` cells when `Tree::lit_all` toggles for Tester look measurements.
fn Tree::press_shown_lit_all(self : Tree, on : Bool) -> Unit {
  guard self.press_delay_opt() is Some(st) else { return }
  for at, entry in st.cells {
    let (gen, s) = entry
    let id : NodeId = { at, gen }
    if self.alive_id(id) {
      s.set(on || st.shown == Some(id))
    }
  }
}

///|
fn Tree::press_shown_watched(self : Tree, id : NodeId) -> Bool {
  match self.press_delay_opt() {
    Some(st) =>
      match st.cells.get(id.at) {
        Some((gen, _)) => gen == id.gen
        None => false
      }
    None => false
  }
}

///|
fn Tree::press_shown_id(self : Tree) -> NodeId? {
  match self.press_delay_opt() {
    Some(st) => st.shown
    None => self.pressing
  }
}

///|
/// Whether visual press feedback should be shown on this node now: like `View::pressed()`, except a fresh press inside
/// a scrollable container (`Tree::in_scroller`) waits `Tree::press_delay_in_scroll` so scrolling never flashes pressed
/// highlights. Use `View::pressed()` for input logic and `View::press_shown()` for visual press states.
pub fn View::press_shown(self : View) -> Bool {
  guard self.live() is Some(_) else { return false }
  match self.tree.press_delay_opt() {
    None => self.pressed()
    Some(st) => {
      self.tree.ground_reads(ground_read_hand)
      let id = self.id()
      let s = match st.cells.get(self.at) {
        Some((gen, s)) if gen == self.gen => s
        _ => {
          let s = @signals.signal(self.tree.lit_every || st.shown == Some(id), same=fn(a, b) { a == b })
          st.cells[self.at] = (self.gen, s)
          s
        }
      }
      s.get()
    }
  }
}
