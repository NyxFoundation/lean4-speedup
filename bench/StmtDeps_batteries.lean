import Batteries.Data.List.Lemmas
open Lean

/- Statement-dependency census for the command-independence phenomenon
(protocol v2 step 2). For each user-facing decl in the target module:
{"n": name, "l": startLine, "sd": [same-module deps of the TYPE],
 "bd": [same-module deps of the VALUE only]}.
Statements are what the sequential main thread elaborates; `sd` distances
in command order measure the speculation window for command-level
parallelism. Private aux decls are mapped to their user name first, then
aux suffixes (`._proof_N`, `.match_N`, numeric `eq_N`, …) fold into the
user-facing parent. -/
run_meta do
  let env ← getEnv
  let target := `Batteries.Data.List.Lemmas
  let some modIdx := env.getModuleIdx? target | throwError "module not found"
  let mut inMod : NameSet := {}
  for (n, _) in env.constants.toList do
    if env.getModuleIdxFor? n == some modIdx then
      inMod := inMod.insert n
  let isAuxComp (s : String) : Bool :=
    s.startsWith "_" || s.startsWith "match_" || s.startsWith "unsafe_"
    || ((s.startsWith "proof_" || s.startsWith "eq_") &&
        (s.drop (if s.startsWith "proof_" then 6 else 3) |>.all fun c => c.isDigit || c == '_'))
    || s == "eq_def"
  let fold (n : Name) : Name := Id.run do
    let mut cur := (privateToUserName? n).getD n
    while cur != Name.anonymous do
      match cur with
      | .str p s => if isAuxComp s then cur := p else break
      | .num p _ => cur := p
      | _ => break
    return cur
  let mut sdeps : Std.HashMap Name NameSet := {}
  let mut bdeps : Std.HashMap Name NameSet := {}
  let mut lines : Std.HashMap Name Nat := {}
  for (n, ci) in env.constants.toList do
    if env.getModuleIdxFor? n == some modIdx then
      let p := fold n
      if p == Name.anonymous then continue
      let collect (e : Expr) (acc : NameSet) : NameSet := Id.run do
        let mut acc := acc
        for u in e.getUsedConstantsAsSet.toList do
          if inMod.contains u then
            let up := fold u
            if up != p && up != Name.anonymous then
              acc := acc.insert up
        return acc
      -- aux decls (proofs, matchers) count as BODY mass of the parent;
      -- only the parent's own type is the statement.
      if fold n == n then
        sdeps := sdeps.insert p (collect ci.type (sdeps.getD p {}))
      else
        bdeps := bdeps.insert p (collect ci.type (bdeps.getD p {}))
      match ci.value? with
      | some v => bdeps := bdeps.insert p (collect v (bdeps.getD p {}))
      | none => pure ()
      match ← findDeclarationRanges? n with
      | some rs =>
        let ln := rs.range.pos.line
        let old := lines.getD p 1000000
        lines := lines.insert p (min old ln)
      | none => pure ()
  let names := (sdeps.toList.map (·.1) ++ bdeps.toList.map (·.1)).eraseDups
  for p in names do
    let l := lines.getD p 0
    let sd := (sdeps.getD p {}).toList
    let bdAll := (bdeps.getD p {}).toList
    let bd := bdAll.filter (fun d => !(sdeps.getD p {}).contains d)
    let enc (ds : List Name) := String.intercalate "," (ds.map (fun d => "\"" ++ toString d ++ "\""))
    IO.println ("{\"n\": \"" ++ toString p ++ "\", \"l\": " ++ toString l ++
      ", \"sd\": [" ++ enc sd ++ "], \"bd\": [" ++ enc bd ++ "]}")
