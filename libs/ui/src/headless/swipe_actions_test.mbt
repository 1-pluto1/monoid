// Tests for headless SwipeActions: horizontal drag open/close, axis locking against vertical & diagonal scroll inside
// a real `View::scrolls` list, slop subtraction (no jump, FPS-invariant), rubber-band over-drag damping, velocity flick,
// programmatic open/close, and disabled guard. All windows use `window`.

///|
test "SwipeActions: horizontal drag opens Left/Right past threshold, short drag snaps back, vertical drag ignored" {
  let events : Array[@headless.SwipeSide?] = []
  let sa = @headless.SwipeActions::new(
    left_width=80.0,
    right_width=100.0,
    threshold=0.4,
    velocity_threshold=400.0,
    slop=6.0,
    on_open=fn(side) { events.push(side) },
  )
  let t = window(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(300.0)))
      .height(Is(Some(60.0)))
      .ground(Is(c_rest))
      .says(Is(Some(@view.said(Group, label="列表行"))))
      |> ignore
      sa.bind(v)
    })
    |> ignore
  })
  // Vertical drag (dy=40 > dx=5) does not lock horizontal axis
  t.drag(150.0, 10.0, 155.0, 50.0, steps=10)
  let after_vert = (sa.offset(), sa.open_side(), sa.dragging())
  // Slow short horizontal drag right (+20 -> effective 14 < 80 * 0.4 = 32) snaps back to 0
  t.drag(150.0, 30.0, 170.0, 30.0, steps=20)
  let after_short = (sa.offset(), sa.open_side())
  // Slow horizontal drag right (+50 -> effective 44 >= 32) snaps open Left (80.0)
  t.drag(150.0, 30.0, 200.0, 30.0, steps=20)
  let after_left = (sa.offset(), sa.open_side())
  // Drag back left to close
  t.drag(200.0, 30.0, 120.0, 30.0, steps=20)
  let after_close = (sa.offset(), sa.open_side())
  // Slow horizontal drag left (-60 -> effective -54 <= -40) snaps open Right (-100.0)
  t.drag(200.0, 30.0, 140.0, 30.0, steps=20)
  let after_right = (sa.offset(), sa.open_side())
  assert_eq(after_vert, (0.0, None, false))
  assert_eq(after_short, (0.0, None))
  assert_eq(after_left, (80.0, Some(Left)))
  assert_eq(after_close, (0.0, None))
  assert_eq(after_right, (-100.0, Some(Right)))
  assert_eq(events, [Some(Left), None, Some(Right)])
}

///|
test "SwipeActions: rubber-band damping past width, fast velocity flick, and programmatic open/close" {
  let sa = @headless.SwipeActions::new(left_width=80.0, right_width=80.0, threshold=0.5, velocity_threshold=400.0)
  let t = window(fn(root) {
    root.box(fn(v) {
      v
      .width(Is(Some(300.0)))
      .height(Is(Some(60.0)))
      .ground(Is(c_rest))
      .says(Is(Some(@view.said(Group, label="可滑行"))))
      |> ignore
      sa.bind(v)
    })
    |> ignore
  })
  // Hold-drag right 160px past left_width=80 -> rubber-band damped (80 < offset < 160)
  t.press_at(50.0, 30.0)
  t.move_to(210.0, 30.0)
  let mid_offset = sa.offset()
  let mid_drag = sa.dragging()
  t.release(210.0, 30.0)
  assert_true(mid_drag)
  assert_true(mid_offset > 80.0 && mid_offset < 160.0)
  assert_eq((sa.offset(), sa.open_side(), sa.dragging()), (80.0, Some(Left), false))
  // Programmatic close
  sa.close()
  assert_eq((sa.offset(), sa.open_side()), (0.0, None))
  // Fast short flick left (25px over 2 steps ≈ 750 pt/s > 400) snaps open Right even though 25 - 6 < 40
  t.drag(150.0, 30.0, 125.0, 30.0, steps=2)
  assert_eq((sa.offset(), sa.open_side()), (-80.0, Some(Right)))
  // Programmatic open(Left) switches side
  sa.open(Left)
  assert_eq((sa.offset(), sa.open_side()), (80.0, Some(Left)))
}

///|
test "SwipeActions: inside View::scrolls, vertical/diagonal drags scroll the list; crossing slop starts smoothly from 0; dead side ignored" {
  let scroll = @view.Scroll::new()
  let sa = @headless.SwipeActions::new(left_width=0.0, right_width=100.0, threshold=0.4, slop=6.0)
  let tree_ref : Ref[@view.Tree?] = Ref(None)
  let t = window(fn(root) {
    tree_ref.val = Some(root.tree)
    root.box(fn(sc) {
      sc
      .width(Is(Some(300.0)))
      .height(Is(Some(180.0)))
      .scrolls(scroll, slop=6.0, fn(held) {
        held.box(fn(v) {
          v
          .width(Is(Some(300.0)))
          .height(Is(Some(60.0)))
          .ground(Is(c_rest))
          .says(Is(Some(@view.said(Group, label="手势行"))))
          |> ignore
          sa.bind(v)
        })
        |> ignore
        held.box(fn(pad) { pad.width(Is(Some(300.0))).height(Is(Some(600.0))) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  // Vertical-leaning drag (|dy|=24 >= |dx|=8) must yield to outer View::scrolls and scroll the list
  t.touch(0, 150.0, 50.0)
  t.draw()
  for i in 1..=10 {
    t.advance(@ui.input_step_ms)
    t.touch(1, 150.0 - i.to_double() * 0.8, 50.0 - i.to_double() * 2.4)
    t.draw()
  }
  t.touch(2, 142.0, 26.0)
  t.draw()
  let after_vert = (sa.offset(), sa.open_side(), sa.dragging(), scroll.at(tree_ref.val.unwrap()) > 0.0)
  // Reset scroll back to top
  scroll.put(0.0)
  t.draw()
  // Shallow diagonal drag (|dx|=20 > |dy|=12, but |dx| <= 2*|dy|) must NOT falsely lock horizontal swipe
  t.touch(0, 150.0, 40.0)
  t.draw()
  for i in 1..=10 {
    t.advance(@ui.input_step_ms)
    t.touch(1, 150.0 - i.to_double() * 2.0, 40.0 - i.to_double() * 1.2)
    t.draw()
  }
  t.touch(2, 130.0, 28.0)
  t.draw()
  let after_diag = (sa.offset(), sa.open_side(), sa.dragging())
  // Dragging right when closed and left_width == 0.0 must not claim dragging
  t.press_at(150.0, 30.0)
  t.move_to(180.0, 30.0)
  let dead_side = (sa.offset(), sa.dragging())
  t.release(180.0, 30.0)
  // Crossing slop leftward subtracts slop so offset starts smoothly from 0 with no jump
  t.press_at(200.0, 30.0)
  t.move_to(194.0, 30.0)
  let at_slop = (sa.offset(), sa.dragging())
  t.move_to(193.5, 30.0)
  let just_past = (sa.offset(), sa.dragging())
  t.move_to(190.0, 30.0)
  let past_slop = (sa.offset(), sa.dragging())
  t.release(190.0, 30.0)
  // Single-step jump to the same final point yields the exact same offset (FPS-invariant)
  t.press_at(200.0, 30.0)
  t.move_to(190.0, 30.0)
  let single_step = (sa.offset(), sa.dragging())
  t.release(190.0, 30.0)
  assert_eq(after_vert, (0.0, None, false, true))
  assert_eq(after_diag, (0.0, None, false))
  assert_eq(dead_side, (0.0, false))
  assert_eq(at_slop, (0.0, false))
  assert_eq(just_past, (-0.5, true))
  assert_eq(past_slop, (-4.0, true))
  assert_eq(single_step, (-4.0, true))
}
