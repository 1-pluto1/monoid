// Source forms that make the MoonBit to Pion conversion fail.

///|
/// The first and last tokens of an argument, without outer parentheses.
fn ungrouped_arg(f : MbtFile, arg : Array[Int]) -> (Int, Int) {
  let toks = f.toks
  let mut start = arg[0]
  let mut last = arg[arg.length() - 1]
  while start < last && toks[start].kind == "op" && toks[start].text == "(" && toks[start].end == last {
    start += 1
    last -= 1
  }
  (start, last)
}

///|
/// The body of an inline callback passed as the whole argument.
fn callback_body(f : MbtFile, arg : Array[Int]) -> (Int, Int)? {
  guard arg.length() >= 3 else { return None }
  let toks = f.toks
  let (start, last) = ungrouped_arg(f, arg)
  guard start < last else { return None }
  if toks[start].kind == "ident" && toks[start].text == "fn" {
    guard f.lambda_at(start) is Some((_, open)) && toks[open].end == last else { return None }
    return Some((open + 1, last))
  }
  let arrow = if toks[start].kind == "op" && toks[start].text == "(" {
    toks[start].end + 1
  } else if toks[start].kind == "ident" {
    start + 1
  } else {
    return None
  }
  guard arrow > start && arrow < last && toks[arrow].kind == "op" && toks[arrow].text == "=>" else {
    return None
  }
  let body = arrow + 1
  if toks[body].kind == "op" && toks[body].text == "{" && toks[body].end == last {
    Some((body + 1, last))
  } else {
    Some((body, last + 1))
  }
}

///|
/// A group that occupies the whole expression, after any redundant parentheses.
fn literal_start(f : MbtFile, lo : Int, hi : Int, bracket : String) -> Int? {
  let toks = f.toks
  let mut start = lo
  let mut end = hi
  while start < end && toks[start].kind == "op" && toks[start].end == end - 1 {
    let args = f.args_of(start)
    if toks[start].text == bracket && (bracket != "(" || args.length() >= 2) {
      return Some(start)
    }
    if toks[start].text != "(" || args.length() != 1 {
      break
    }
    start += 1
    end -= 1
  }
  None
}

///|
/// The last statement's literal, after any preceding statements in the callback block.
fn callback_literal(f : MbtFile, lo : Int, hi : Int, bracket : String) -> Int? {
  let toks = f.toks
  guard lo < hi && is_close(toks[hi - 1]) else { return None }
  let start = f.open_of(hi - 1)
  guard start >= lo else { return None }
  let stmt = if start > lo && toks[start - 1].kind == "ident" && toks[start - 1].text == "return" {
    start - 1
  } else {
    start
  }
  if stmt > lo {
    let prev = toks[stmt - 1]
    // An arrow expression in argument position has no statement separators.
    guard toks[lo - 1].text == "{" &&
      (prev.text == ";" ||
       (prev.line < toks[stmt].line &&
        (is_close(prev) || ["ident", "num", "str"].contains(prev.kind)))) else {
      return None
    }
  }
  literal_start(f, start, hi, bracket)
}

///|
/// Direct type aliases declared in this file.
fn compat_aliases(f : MbtFile) -> Map[String, String] {
  let aliases = Map([])
  let toks = f.toks
  for it in f.items {
    if it.kind != "type" && it.kind != "typealias" {
      continue
    }
    let mut head = it.start
    while head < it.end && toks[head].text != it.kind {
      head += 1
    }
    let eq = head + 2
    if eq < it.end && toks[eq].text == "=" && f.type_at(eq + 1) is Some(target) {
      aliases[it.name] = target
    }
  }
  aliases
}

///|
fn is_view_type(name : String, aliases : Map[String, String]) -> Bool {
  let mut ty = name
  for _ in 0..<aliases.length() {
    guard aliases.get(ty) is Some(target) else { break }
    ty = target
  }
  ty == "View"
}

///|
/// The key for each or keyed_by, or the keys supplied to a virtual list.
/// Like the View rules in lint.mbt, this check uses the call shape. It does not infer receiver types.
fn lint_each_tuple_key(
  f : MbtFile,
  c : Call,
  aliases : Map[String, String],
  out : Array[Finding],
) -> Unit {
  let (pos, arity, array_keys) = match c.name {
    "each" => (1, 3, false)
    "keyed_by" => (1, 2, false)
    "list_reused" => (0, 2, true)
    "scrolls_reused" | "scrolls_window" => (1, 3, true)
    _ => return
  }
  let offset = match c.kind {
    "method" => 0
    "type" if is_view_type(c.qual, aliases) => 1
    _ => return
  }
  let args = positional(f, c.args)
  guard args.length() == arity + offset else { return }
  let toks = f.toks
  // The first argument is a supplier or a Scroll. A literal here belongs to another method.
  let (first, last) = ungrouped_arg(f, args[offset])
  let t = toks[first]
  if (first == last &&
      (t.kind == "num" || t.kind == "str" ||
       (t.kind == "ident" && ["true", "false", "None"].contains(t.text)))) ||
    (t.kind == "op" && t.text == "[" && t.end == last) ||
    (first + 1 == last && t.kind == "op" && t.text == "-" && toks[last].kind == "num") {
    return
  }
  guard callback_body(f, args[pos + offset]) is Some((lo, hi)) else { return }
  if !array_keys {
    if callback_literal(f, lo, hi, "(") is Some(k) {
      out.push(finding("each-tuple-key", f.rel, toks[k].line, f.line_text(k)))
    }
  } else if callback_literal(f, lo, hi, "[") is Some(array) {
    for (_, element) in f.args_of(array) {
      if element.length() > 0 &&
        literal_start(f, element[0], element[element.length() - 1] + 1, "(") is Some(k) {
        out.push(finding("each-tuple-key", f.rel, toks[k].line, f.line_text(k)))
      }
    }
  }
}

///|
let iter_callback_methods : Array[String] = ["any", "all", "find_first", "filter", "map", "each"]

///|
let iter_adapters : Array[String] = [
  "filter", "map", "filter_map", "flat_map", "flatten", "mapi", "take", "take_while",
  "map_while", "drop", "drop_while", "concat", "zip",
]

///|
fn iter_callback_call(f : MbtFile, c : Call) -> Bool {
  guard c.kind == "method" else { return false }
  if c.name == "search_by" || c.name == "filter_map" {
    return true
  }
  guard iter_callback_methods.contains(c.name) else { return false }
  let toks = f.toks
  let mut start = 0
  let mut close = c.at - 2
  while close > start && toks[close].kind == "op" && toks[close].text == ")" {
    let open = f.open_of(close)
    guard open >= start && toks[open].text == "(" else { return false }
    if open >= start + 3 &&
      toks[open - 1].kind == "ident" &&
      toks[open - 2].kind == "op" && toks[open - 2].text == "." &&
      toks[open - 3].kind != "at" {
      let name = toks[open - 1].text
      if name == "iter" {
        return open + 1 == close
      }
      guard iter_adapters.contains(name) else { return false }
      close = open - 3
      continue
    }
    // Unwrap a grouped receiver. Stop at a call such as wrap(xs.iter()).
    if open > start {
      let prev = toks[open - 1]
      if prev.line == toks[open].line &&
        ((prev.kind == "ident" &&
          !["return", "if", "while", "guard", "match", "in"].contains(prev.text)) ||
         (prev.kind == "op" && (prev.text == ")" || prev.text == "]"))) {
        return false
      }
    }
    start = open + 1
    close -= 1
  }
  false
}

///|
fn lint_iter_signal_read(
  f : MbtFile,
  lo : Int,
  hi : Int,
  callbacks : Map[Int, (Int, Int)],
  out : Array[Finding],
) -> Unit {
  let toks = f.toks
  let mut k = lo
  while k < hi {
    // A callback written inside this one can run later. Check it separately if it belongs to its own iterator.
    if callbacks.get(k) is Some((_, end)) && end <= hi {
      k = end
      continue
    }
    let t = toks[k]
    if t.kind == "ident" && t.text == "fn" && f.lambda_at(k) is Some((_, open)) && toks[open].end < hi {
      k = toks[open].end + 1
      continue
    }
    if k >= lo + 2 &&
      k + 2 < hi &&
      t.kind == "ident" &&
      toks[k - 1].kind == "op" && toks[k - 1].text == "." &&
      toks[k + 1].kind == "op" && toks[k + 1].text == "(" && toks[k + 1].end == k + 2 &&
      ((t.text == "get" && toks[k - 2].kind != "at") ||
       (t.text == "window_zoom" && toks[k - 2].kind == "at" && toks[k - 2].text == "@ui")) {
      out.push(finding("iter-signal-read", f.rel, t.line, f.line_text(k)))
    }
    k += 1
  }
}

///|
fn lint_untyped_let_fn(f : MbtFile, out : Array[Finding]) -> Unit {
  let toks = f.toks
  for k, t in toks {
    if t.kind != "ident" || t.text != "let" || k + 1 >= toks.length() {
      continue
    }
    let name = if toks[k + 1].text == "mut" { k + 2 } else { k + 1 }
    let open = name + 3
    if open >= toks.length() ||
      toks[name].kind != "ident" ||
      toks[name + 1].kind != "op" || toks[name + 1].text != "=" ||
      toks[name + 2].kind != "ident" || toks[name + 2].text != "fn" ||
      toks[open].kind != "op" || toks[open].text != "(" || toks[open].end < 0 ||
      f.in_test(k) || f.block_start(k) == 0 {
      continue
    }
    for (_, param) in f.args_of(open) {
      if param.length() == 1 && toks[param[0]].kind == "ident" && toks[param[0]].text != "_" {
        out.push(finding("untyped-let-fn", f.rel, t.line, f.line_text(k)))
        break
      }
    }
  }
}

///|
fn lint_compat(f : MbtFile, out : Array[Finding]) -> Unit {
  if f.test_file {
    return
  }
  let aliases = compat_aliases(f)
  let callbacks : Map[Int, (Int, Int)] = Map([])
  let iter_bodies = []
  for c in f.calls {
    if c.is_def || f.in_test(c.at) {
      continue
    }
    lint_each_tuple_key(f, c, aliases, out)
    let iterates = iter_callback_call(f, c)
    for (_, arg) in c.args {
      if callback_body(f, arg) is Some(body) {
        callbacks[arg[0]] = body
        if iterates {
          iter_bodies.push(body)
        }
      }
    }
  }
  for (lo, hi) in iter_bodies {
    lint_iter_signal_read(f, lo, hi, callbacks, out)
  }
  lint_untyped_let_fn(f, out)
}
