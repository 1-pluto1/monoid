// Delayed `View::press_shown()` indication inside scrollable containers (`Tree::press_delay_in_scroll`):
// - `View::pressed()` stays immediate for input logic regardless of scroll containers.
// - Inside a vertical or horizontal `View::scrolls`, `View::press_shown()` waits `delay_ms` before lighting.
// - Releasing or losing the hold before `delay_ms` cancels the timer so `View::press_shown()` never flashes.
// - Holding past `delay_ms` and then losing the hold immediately clears `View::press_shown()`.
// - Outside any scroller (or when `delay_ms == 0`), `View::press_shown()` lights immediately.
// - Disposing a node while its press delay is pending cancels the timer without firing reactions.

///|
let press_delay_test_ms : Double = 100.0

///|
let press_delay_half_ms : Double = 50.0

///|
let press_delay_past_ms : Double = 150.0

///|
test "press_delay_in_scroll: pressed() stays immediate; press_shown() delays in vertical/horizontal scroll and cancels on release or dispose" {
  let delay_ms = Ref(press_delay_test_ms)
  let outside_v : Ref[@view.View?] = Ref(None)
  let vert_v : Ref[@view.View?] = Ref(None)
  let horiz_v : Ref[@view.View?] = Ref(None)
  let show_vert : @signals.Signal[Bool] = @signals.signal(true)
  let vert_shown_flips = Ref(0)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(out) {
      out.width(Is(Some(100.0))).height(Is(Some(40.0))).presses(Is(true)) |> ignore
      outside_v.val = Some(out)
    })
    |> ignore
    root.box(fn(sc) {
      sc
      .width(Is(Some(200.0)))
      .height(Is(Some(120.0)))
      .scrolls(@view.Scroll::new(), fn(held) {
        held.show(at_once=true, fn() { show_vert.get() }, fn(v) {
          v.width(Is(Some(200.0))).height(Is(Some(40.0))).presses(Is(true)) |> ignore
          v.reacts(fn() { v.press_shown() }, at_start=false, fn(on) { if on { vert_shown_flips.val += 1 } })
          vert_v.val = Some(v)
        })
        |> ignore
        held.box(fn(pad) { pad.height(Is(Some(300.0))) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(sc) {
      sc
      .width(Is(Some(200.0)))
      .height(Is(Some(50.0)))
      .scrolls(@view.Scroll::across(), fn(held) {
        held.row(Is(true)) |> ignore
        held.box(fn(h) {
          h.width(Is(Some(80.0))).height(Is(Some(40.0))).presses(Is(true)) |> ignore
          horiz_v.val = Some(h)
        })
        |> ignore
        held.box(fn(pad) { pad.width(Is(Some(300.0))).height(Is(Some(40.0))) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.press_delay_in_scroll(fn() { delay_ms.val })
  tree.frame(300.0, 400.0, now=0.0) |> ignore
  let out = outside_v.val.unwrap()
  let vert = vert_v.val.unwrap()
  let horiz = horiz_v.val.unwrap()
  let is_pressed = fn(v : @view.View) { @signals.untracked(fn() { v.pressed() }) }
  let is_shown = fn(v : @view.View) { @signals.untracked(fn() { v.press_shown() }) }
  // 1. Outside scroller: both pressed() and press_shown() light immediately at t0
  let t1 = 10.0
  tree.event(t1, fn() { tree.hold_press(out.id()) })
  let out_at_0 = (is_pressed(out), is_shown(out))
  tree.event(t1 + 10.0, fn() { tree.press_held(out.id()) |> ignore })
  assert_eq(out_at_0, (true, true))
  assert_eq((is_pressed(out), is_shown(out)), (false, false))
  // 2. Inside vertical scroller, held past delay: pressed() immediate, press_shown() dark before and lit at delay
  let t2 = 100.0
  tree.event(t2, fn() { tree.hold_press(vert.id()) })
  let vert_at_0 = (is_pressed(vert), is_shown(vert))
  tree.advance(t2 + press_delay_half_ms)
  let vert_at_50 = (is_pressed(vert), is_shown(vert))
  tree.advance(t2 + press_delay_test_ms)
  let vert_at_100 = (is_pressed(vert), is_shown(vert))
  tree.event(t2 + press_delay_test_ms + 20.0, fn() { tree.press_held(vert.id()) |> ignore })
  assert_eq(vert_at_0, (true, false))
  assert_eq(vert_at_50, (true, false))
  assert_eq(vert_at_100, (true, true))
  assert_eq((is_pressed(vert), is_shown(vert)), (false, false))
  // 3. Inside vertical scroller, released early at half delay: press_shown() never lights even past full delay
  let flips_before_early = vert_shown_flips.val
  let t3 = 300.0
  tree.event(t3, fn() { tree.hold_press(vert.id()) })
  tree.advance(t3 + press_delay_half_ms)
  tree.event(t3 + press_delay_half_ms, fn() { tree.press_held(vert.id()) |> ignore })
  tree.advance(t3 + press_delay_past_ms)
  assert_eq((is_shown(vert), vert_shown_flips.val), (false, flips_before_early))
  // 4. Inside horizontal scroller (Scroll::across): press_shown() also delayed until press_delay_test_ms
  let t4 = 500.0
  tree.event(t4, fn() { tree.hold_press(horiz.id()) })
  let horiz_at_0 = (is_pressed(horiz), is_shown(horiz))
  tree.advance(t4 + press_delay_test_ms)
  let horiz_at_100 = (is_pressed(horiz), is_shown(horiz))
  tree.event(t4 + press_delay_test_ms + 20.0, fn() { tree.press_held(horiz.id()) |> ignore })
  assert_eq(horiz_at_0, (true, false))
  assert_eq(horiz_at_100, (true, true))
  assert_eq((is_pressed(horiz), is_shown(horiz)), (false, false))
  // 5. With 0ms delay (e.g. Mouse): press_shown() lights immediately even inside scroller
  delay_ms.val = 0.0
  let t5 = 700.0
  tree.event(t5, fn() { tree.hold_press(vert.id()) })
  let vert_mouse = is_shown(vert)
  tree.event(t5 + 10.0, fn() { tree.press_held(vert.id()) |> ignore })
  assert_true(vert_mouse)
  // 6. Disposing node while delay is pending cancels timer and releases holder cleanly
  delay_ms.val = press_delay_test_ms
  let flips_before_dispose = vert_shown_flips.val
  let t6 = 800.0
  tree.event(t6, fn() { tree.hold_press(vert.id()) })
  show_vert.set(false)
  tree.frame(300.0, 400.0, now=t6 + 20.0) |> ignore
  let holder_after_dispose = tree.holder()
  tree.advance(t6 + press_delay_past_ms)
  assert_eq((holder_after_dispose, vert_shown_flips.val), (None, flips_before_dispose))
  tree.dispose()
}
