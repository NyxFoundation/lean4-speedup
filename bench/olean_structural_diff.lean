import Lean
open Lean
/- Structurally compare two olean files: constants (name, type, value), then report. -/
unsafe def main (args : List String) : IO Unit := do
  let f1 :: f2 :: _ := args | throw <| IO.userError "need two olean paths"
  Lean.initSearchPath (← Lean.findSysroot)
  let (d1, r1) ← readModuleData f1
  let (d2, r2) ← readModuleData f2
  IO.println s!"consts: {d1.constants.size} vs {d2.constants.size}"
  let m2 : Std.HashMap Name ConstantInfo := d2.constants.foldl (fun m c => m.insert c.name c) {}
  let mut diffs := 0
  for c1 in d1.constants do
    match m2[c1.name]? with
    | none => IO.println s!"only in 1: {c1.name}"; diffs := diffs + 1
    | some c2 =>
      unless c1.type == c2.type do
        IO.println s!"TYPE differs: {c1.name}"; diffs := diffs + 1
      unless c1.value? == c2.value? do
        IO.println s!"VALUE differs: {c1.name}"; diffs := diffs + 1
      unless c1.levelParams == c2.levelParams do
        IO.println s!"LEVELS differ: {c1.name}: {c1.levelParams} vs {c2.levelParams}"; diffs := diffs + 1
    if diffs > 10 then IO.println "..."; break
  IO.println s!"structural diffs: {diffs}"
  IO.println s!"entries sizes: {d1.entries.map (·.1)} "
  r1.free; r2.free
