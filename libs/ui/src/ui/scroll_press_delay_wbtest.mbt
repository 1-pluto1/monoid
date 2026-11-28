// Tree-mode finger press delay inside scrollable containers (`Tree::press_delay_in_scroll` wired in `view_host.mbt`):
// - `View::pressed()` stays immediate for logic on all inputs.
// - Under `Finger`, `View::press_shown()` on a node inside `View::scrolls` delays by `tap_indication_ms` so scrolling
//   past buttons/rows never flashes pressed highlights, clears immediately if scrolled after lighting, and quick taps
//   still fire `on_press` immediately on release.
// - Under `Mouse`, or for a finger outside any scroller, `View::press_shown()` lights immediately.

///|
test "tree scroll press delay: Finger delays press_shown() in scroll while pressed() stays immediate; clears on late scroll; Mouse & outside immediate" {
  let shown_in_scroll = Ref(false)
  let raw_in_scroll = Ref(false)
  let shown_outside = Ref(false)
  let clicks = Ref(0)
  let make = fn(pointing : Pointing) {
    shown_in_scroll.val = false
    raw_in_scroll.val = false
    shown_outside.val = false
    clicks.val = 0
    let t = Tester::tree(
      fn(root) {
        root.box(fn(top) {
          top
          .width(Is(Some(300.0)))
          .height(Is(Some(44.0)))
          .presses(Is(true))
          .on_press(fn() {  })
          .says(Is(Some(@view.said(Button, label="外部按钮"))))
          .ground(
            By(fn() {
              shown_outside.val = top.press_shown()
              if top.press_shown() { 0x3366CCFFL } else { 0xEEEEEEFFL }
            }),
          )
          |> ignore
        })
        |> ignore
        root.box(fn(sc) {
          sc
          .width(Is(Some(300.0)))
          .height(Is(Some(200.0)))
          .scrolls(@view.Scroll::new(), slop=touch_slop(), fn(held) {
            held.box(fn(btn) {
              btn
              .width(Is(Some(300.0)))
              .height(Is(Some(50.0)))
              .presses(Is(true))
              .says(Is(Some(@view.said(Button, label="列表按钮"))))
              .on_press(fn() { clicks.val += 1 })
              .ground(
                By(fn() {
                  raw_in_scroll.val = btn.pressed()
                  shown_in_scroll.val = btn.press_shown()
                  if btn.press_shown() { 0x3366CCFFL } else { 0xFFFFFFFFL }
                }),
              )
              |> ignore
            })
            |> ignore
            held.box(fn(tall) { tall.height(Is(Some(600.0))) |> ignore }) |> ignore
          })
          |> ignore
        })
        |> ignore
      },
      w=300.0,
      h=300.0,
      pointing~,
    )
    t.draw()
    t
  }
  // 1. Finger outside scroller: lights immediately at t=0
  let t = make(Finger)
  t.touch(0, 100.0, 22.0)
  t.draw()
  let outside_at_0 = shown_outside.val
  t.touch(2, 100.0, 22.0)
  t.draw()
  assert_true(outside_at_0)
  assert_false(shown_outside.val)
  // 2. Finger inside scroller, held past tap_indication_ms: pressed() immediate, press_shown() lit at tap_indication_ms
  let t = make(Finger)
  t.touch(0, 100.0, 70.0)
  t.draw()
  let at_0 = (raw_in_scroll.val, shown_in_scroll.val)
  t.run_for(tap_indication_ms / 2.0)
  let at_half = (raw_in_scroll.val, shown_in_scroll.val)
  t.run_for(tap_indication_ms / 2.0)
  let at_full = (raw_in_scroll.val, shown_in_scroll.val)
  t.touch(2, 100.0, 70.0)
  t.draw()
  assert_eq(at_0, (true, false))
  assert_eq(at_half, (true, false))
  assert_eq(at_full, (true, true))
  assert_eq((raw_in_scroll.val, shown_in_scroll.val, clicks.val), (false, false, 1))
  // 3. Finger inside scroller, scrolling immediately: press_shown() stays false on every frame, no click
  let t = make(Finger)
  t.touch(0, 100.0, 70.0)
  t.draw()
  let mut flashed = shown_in_scroll.val
  for i in 1..=8 {
    t.advance(input_step_ms)
    t.touch(1, 100.0, 70.0 - i.to_double() * 8.0)
    t.draw()
    if shown_in_scroll.val {
      flashed = true
    }
  }
  t.touch(2, 100.0, 6.0)
  t.draw()
  assert_eq((flashed, shown_in_scroll.val, clicks.val), (false, false, 0))
  // 4. Finger held past tap_indication_ms (lit), then dragged to scroll: press_shown() clears once scroll claims
  let t = make(Finger)
  t.touch(0, 100.0, 70.0)
  t.draw()
  t.run_for(tap_indication_ms)
  let lit_before_scroll = shown_in_scroll.val
  for i in 1..=6 {
    t.advance(input_step_ms)
    t.touch(1, 100.0, 70.0 - i.to_double() * 8.0)
    t.draw()
  }
  let lit_during_scroll = shown_in_scroll.val
  t.touch(2, 100.0, 22.0)
  t.draw()
  assert_eq((lit_before_scroll, lit_during_scroll, shown_in_scroll.val, clicks.val), (true, false, false, 0))
  // 5. Finger inside scroller, quick tap (< tap_indication_ms): never flashes, still clicks on release
  let t = make(Finger)
  t.touch(0, 100.0, 70.0)
  t.draw()
  t.run_for(tap_indication_ms / 2.0)
  let quick_before = shown_in_scroll.val
  t.touch(2, 100.0, 70.0)
  t.draw()
  assert_eq((quick_before, shown_in_scroll.val, clicks.val), (false, false, 1))
  // 6. Mouse inside scroller: press_shown() lights immediately at t=0
  let t = make(Mouse)
  t.press_at(100.0, 70.0)
  t.draw()
  let mouse_at_0 = shown_in_scroll.val
  t.release(100.0, 70.0)
  t.draw()
  assert_eq((mouse_at_0, shown_in_scroll.val, clicks.val), (true, false, 1))
}
