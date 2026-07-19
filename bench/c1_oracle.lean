import Lean
/- C1 v0 oracle (zero rebuild): run the frontend on a target file with info
trees enabled; per command, extract the TRUE same-module constant reads made
during STATEMENT-position elaboration (TermInfo nodes whose syntax lies
outside proof/value-body ranges), and the constants each command writes.
Output: c1_oracle_out.jsonl for bench/c1_oracle_analyze.py.
Run from the corpus dir:  lake env lean --run ../bench/c1_oracle.lean <file> -/
open Lean Elab Frontend

/-- Ranges of proof/value bodies inside a command (`by` blocks, `:=` values,
`where` blocks) — statement-position info is everything outside these. -/
partial def bodyRanges (stx : Syntax) : Array (String.Pos.Raw × String.Pos.Raw) :=
  go stx #[]
where
  go (s : Syntax) (acc : Array (String.Pos.Raw × String.Pos.Raw)) : Array (String.Pos.Raw × String.Pos.Raw) := Id.run do
    let kind := s.getKind
    if kind == `Lean.Parser.Term.byTactic || kind == `Lean.Parser.Command.declValSimple
        || kind == `Lean.Parser.Command.declValEqns || kind == `Lean.Parser.Command.whereStructInst then
      if let (some b, some e) := (s.getPos?, s.getTailPos?) then
        return acc.push (b, e)
    let mut acc := acc
    for c in s.getArgs do
      acc := go c acc
    return acc

partial def collectStmtConsts (tree : InfoTree) (bodies : Array (String.Pos.Raw × String.Pos.Raw))
    (ctx? : Option ContextInfo) (acc : NameSet) : NameSet :=
  match tree with
  | .context pctx t => collectStmtConsts t bodies (pctx.mergeIntoOuter? ctx?) acc
  | .node info children => Id.run do
    let mut acc := acc
    let inBody := Id.run do
      if let some pos := info.stx.getPos? then
        for (b, e) in bodies do
          if b <= pos && pos < e then
            return true
      return false
    unless inBody do
      if let .ofTermInfo ti := info then
        -- TermInfo exprs may contain mvars; instantiate via the enclosing mctx
        let e := match ctx? with
          | some ctx => (instantiateMVarsCore ctx.mctx ti.expr).1
          | none => ti.expr
        for c in e.getUsedConstantsAsSet.toList do
          acc := acc.insert c
    let ctx? := info.updateContext? ctx?
    for c in children do
      acc := collectStmtConsts c bodies ctx? acc
    return acc
  | .hole _ => acc

def moduleConsts (env : Environment) : NameSet := Id.run do
  let mut s : NameSet := {}
  for (n, _) in env.constants.map₂.toList do
    s := s.insert n
  return s

partial def oracleLoop (records : Array (Nat × Nat × Name × Array Name × NameSet))
    (prevConsts : NameSet) (i : Nat) :
    FrontendM (Array (Nat × Nat × Name × Array Name × NameSet)) := do
  -- fresh info trees per command
  modify fun s => { s with commandState := { s.commandState with infoState := { enabled := true } } }
  let done ← processCommand
  let stx := (← get).commands.back!
  let st ← getCommandState
  let newConsts := moduleConsts st.env
  let mut written : Array Name := #[]
  for n in newConsts.toList do
    unless prevConsts.contains n do
      written := written.push n
  let bodies := bodyRanges stx
  let mut reads : NameSet := {}
  for t in st.infoState.trees do
    reads := collectStmtConsts t bodies none reads
  -- declaration elaboration logs its info into snapshot tasks, not the command tree
  let rec walkSnap (t : Language.SnapshotTree) (acc : NameSet) : NameSet := Id.run do
    let mut acc := acc
    if let some it := t.element.infoTree? then
      acc := collectStmtConsts it bodies none acc
    for c in t.children do
      acc := walkSnap c.get acc
    return acc
  for task in st.snapshotTasks do
    reads := walkSnap task.get reads
  modify fun s => { s with commandState := { s.commandState with snapshotTasks := #[] } }
  if i == 11 then
    let rec cnt (t : InfoTree) (m : List (String × Nat)) : List (String × Nat) :=
      match t with
      | .context _ t => cnt t m
      | .node info children => Id.run do
        let k := match info with
          | .ofTermInfo _ => "term" | .ofTacticInfo _ => "tactic" | .ofCommandInfo _ => "command"
          | .ofMacroExpansionInfo _ => "macro" | .ofPartialTermInfo _ => "partialTerm"
          | .ofCompletionInfo _ => "completion" | _ => "other"
        let mut m := match m.lookup k with
          | some v => m.replace (k, v) (k, v+1)
          | none => (k, 1) :: m
        for c in children do
          m := cnt c m
        return m
      | .hole _ => m
    let mut m : List (String × Nat) := []
    for t in st.infoState.trees do
      m := cnt t m
    IO.println s!"cmd11 infoKinds={m} snapTasks={st.snapshotTasks.size} reads={reads.size}"
  let fileMap := (← read).inputCtx.fileMap
  let line := match stx.getPos? with
    | some p => (fileMap.toPosition p).line
    | none => 0
  let records := records.push (i, line, stx.getKind, written, reads)
  if done then return records
  oracleLoop records newConsts (i + 1)

unsafe def main (args : List String) : IO Unit := do
  let path :: _ := args | throw <| IO.userError "usage: c1_oracle <file.lean>"
  initSearchPath (← findSysroot)
  let input ← IO.FS.readFile path
  let inputCtx := Parser.mkInputContext input path
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let opts : Options := (({} : Options).setBool `Elab.async false)
  let (env, messages) ← processHeader header opts messages inputCtx
  let cmdState := Command.mkState env messages opts
  let fs : Frontend.State := { commandState := cmdState, parserState, cmdPos := parserState.pos }
  let (records, _) ← (oracleLoop #[] {} 0).run { inputCtx } |>.run fs
  IO.FS.withFile "c1_oracle_out.jsonl" IO.FS.Mode.write fun out => do
    for (i, line, kind, written, reads) in records do
      let enc (l : List Name) := String.intercalate "," (l.map (fun n => "\"" ++ toString n ++ "\""))
      out.putStrLn ("{\"i\": " ++ toString i ++ ", \"line\": " ++ toString line ++
        ", \"kind\": \"" ++ toString kind ++ "\", \"writes\": [" ++
        enc written.toList ++ "], \"reads\": [" ++ enc reads.toList ++ "]}")
  IO.println s!"commands: {records.size}"
