import Batteries.Data.List.Lemmas
open Lean

/- Dump the intra-module decl dependency DAG of `Batteries.Data.List.Lemmas`
as JSON lines: {"n": name, "l": startLine, "d": [same-module deps]}.
Aux decls (`._proof_N`, `.match_N`, …) are folded into their user-facing parent. -/
run_meta do
  let env ← getEnv
  let target := `Batteries.Data.List.Lemmas
  let some modIdx := env.getModuleIdx? target | throwError "module not found"
  let mut inMod : NameSet := {}
  for (n, _) in env.constants.toList do
    if env.getModuleIdxFor? n == some modIdx then
      inMod := inMod.insert n
  let fold (n : Name) : Name := Id.run do
    let mut cur := n
    while cur != Name.anonymous do
      match cur with
      | .str p s =>
        if s.startsWith "_" || s.startsWith "match_" || s.startsWith "proof_"
            || s.startsWith "eq_" || s.startsWith "unsafe_" then
          cur := p
        else
          break
      | .num p _ => cur := p
      | _ => break
    return cur
  let mut deps : Std.HashMap Name NameSet := {}
  let mut lines : Std.HashMap Name Nat := {}
  for (n, ci) in env.constants.toList do
    if env.getModuleIdxFor? n == some modIdx then
      let p := fold n
      if p == Name.anonymous then continue
      let mut acc := deps.getD p {}
      for u in ci.getUsedConstantsAsSet.toList do
        if inMod.contains u then
          let up := fold u
          if up != p && up != Name.anonymous then
            acc := acc.insert up
      deps := deps.insert p acc
      match ← findDeclarationRanges? n with
      | some rs =>
        let ln := rs.range.pos.line
        let old := lines.getD p 1000000
        lines := lines.insert p (min old ln)
      | none => pure ()
  for (p, ds) in deps.toList do
    let l := lines.getD p 0
    let inner := String.intercalate "," (ds.toList.map (fun d => "\"" ++ toString d ++ "\""))
    IO.println ("{\"n\": \"" ++ toString p ++ "\", \"l\": " ++ toString l ++ ", \"d\": [" ++ inner ++ "]}")
