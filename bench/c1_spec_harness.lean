import Lean
/- C1 v1 speculation harness (zero rebuild): for each command N, fork a REAL
speculative elaboration of command N+1 against the pre-N command state on a
worker task, elaborate N on the main thread, then join and validate:
  - parse validity: speculative parse (pre-N env) == real parse (post-N env)
  - read/write disjointness: N's written constants ∩ N+1's statement reads = ∅
Logs per-command: speculation validity, main/spec wall, overlap saved.
Run from the corpus dir:  lake env lean --run ../bench/c1_spec_harness.lean <file> -/
open Lean Elab Frontend

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

/-- Replace proof/value bodies with `sorry` so speculation elaborates
STATEMENTS ONLY — the production v1 semantics (bodies stay async/sequential).
Applies to declValSimple / declValEqns / whereStructInst / byTactic nodes. -/
partial def sorryBodies (stx : Syntax) : Syntax :=
  let sorryTerm := Syntax.node .none `Lean.Parser.Term.sorry #[Syntax.atom .none "sorry"]
  let nullNode := Syntax.node .none nullKind #[]
  let termSuffix := Syntax.node .none `Lean.Parser.Termination.suffix #[nullNode, nullNode]
  let sorryVal  := Syntax.node .none `Lean.Parser.Command.declValSimple
    #[Syntax.atom .none ":=", sorryTerm, termSuffix, nullNode]
  let rec go (s : Syntax) : Syntax :=
    match s with
    | .node info kind args =>
      if kind == `Lean.Parser.Command.declValSimple || kind == `Lean.Parser.Command.declValEqns
          || kind == `Lean.Parser.Command.whereStructInst then
        sorryVal
      else if kind == `Lean.Parser.Term.byTactic then
        sorryTerm
      else
        .node info kind (args.map go)
    | s => s
  go stx

/-- Elaborate one parsed command on a given command state (worker-safe: pure
state value in, state value out). Returns elapsed nanos and the final state. -/
def elabOn (inputCtx : Parser.InputContext) (cmdPos : String.Pos.Raw) (stx : Syntax)
    (st : Command.State) : BaseIO (Nat × Command.State) := do
  let t0 ← IO.monoNanosNow
  let cmdCtx : Command.Context := {
    cmdPos, fileName := inputCtx.fileName, fileMap := inputCtx.fileMap
    snap? := none, cancelTk? := none
  }
  let st := { st with infoState := { enabled := true }, messages := {}, snapshotTasks := #[] }
  match (← EIO.toBaseIO <| (Command.elabCommandTopLevel stx |>.run cmdCtx |>.run st)) with
  | .ok (_, stNew) => return ((← IO.monoNanosNow) - t0, stNew)
  | .error _ => return ((← IO.monoNanosNow) - t0, st)

structure Rec' where
  i : Nat
  kind : Name
  mainNs : Nat
  specNs : Nat := 0
  parseOk : Bool := false
  disjoint : Bool := false
  specClean : Bool := false
  specKind : Name := .anonymous
  eqChecked : Nat := 0
  eqMatched : Nat := 0

structure PrevSpec where
  specEnv : Environment
  preConsts : NameSet

partial def specLoop (recs : Array Rec') (prev? : Option PrevSpec) (i : Nat) : FrontendM (Array Rec') := do
  updateCmdPos
  let ictx ← getInputContext
  let stPre ← getCommandState
  let pstate ← getParserState
  let scope := stPre.scopes.head!
  let pmctx := { env := stPre.env, options := scope.opts, currNamespace := scope.currNamespace, openDecls := scope.openDecls }
  let (cmdN, psN, msgs) := Parser.parseCommand ictx pmctx pstate stPre.messages
  modify fun s => { s with commands := s.commands.push cmdN }
  setParserState psN
  setMessages msgs
  -- speculate N+1: parse with PRE-N env from psN, elaborate on pre-N state copy
  let specTask ← BaseIO.asTask do
    let (cmdSpec, _, _) := Parser.parseCommand ictx pmctx psN stPre.messages
    if Parser.isTerminalCommand cmdSpec then
      return none
    let cmdSpecStmt := if cmdSpec.getKind == `Lean.Parser.Command.declaration
      then sorryBodies cmdSpec else cmdSpec
    let (ns, stSpec) ← elabOn ictx psN.pos cmdSpecStmt stPre
    return some (cmdSpec, ns, stSpec)
  -- elaborate N on main
  let t0 ← IO.monoNanosNow
  elabCommandAtFrontend cmdN
  let mainNs := (← IO.monoNanosNow) - t0
  let stPost ← getCommandState
  let mut r : Rec' := { i, kind := cmdN.getKind, mainNs }
  -- result-equivalence: compare THIS command's real statement types vs the
  -- speculation of it launched during the previous command
  if let some prev := prev?.filter (fun _ => cmdN.getKind == `Lean.Parser.Command.declaration) then
    let specConsts := moduleConsts prev.specEnv
    let realNow := moduleConsts stPost.env
    let mut checked := 0
    let mut matched := 0
    for n in realNow.toList do
      unless prev.preConsts.contains n do
        if specConsts.contains n then
          checked := checked + 1
          match stPost.env.find? n, prev.specEnv.find? n with
          | some ciReal, some ciSpec =>
            if ciReal.type == ciSpec.type && ciReal.levelParams == ciSpec.levelParams then
              matched := matched + 1
            else
              IO.println s!"EQ-MISMATCH {n}: lvls {ciReal.levelParams} vs {ciSpec.levelParams}; typeEq={ciReal.type == ciSpec.type}"
          | _, _ => pure ()
    r := { r with eqChecked := checked, eqMatched := matched }
  -- join speculation and validate
  if let some (cmdSpec, specNs, stSpec) := specTask.get then
    r := { r with specNs, specKind := cmdSpec.getKind }
    -- parse validity: re-parse N+1 with POST-N env and compare structure
    let scopePost := stPost.scopes.head!
    let pmctxPost := { env := stPost.env, options := scopePost.opts,
                       currNamespace := scopePost.currNamespace, openDecls := scopePost.openDecls }
    let (cmdReal, _, _) := Parser.parseCommand ictx pmctxPost psN stPost.messages
    r := { r with parseOk := toString cmdSpec == toString cmdReal }
    -- writes of N
    let preConsts := moduleConsts stPre.env
    let postConsts := moduleConsts stPost.env
    let mut writesN : Array Name := #[]
    for n in postConsts.toList do
      unless preConsts.contains n do
        writesN := writesN.push n
    -- statement reads of speculated N+1 (info trees of the speculative state)
    let bodies := bodyRanges cmdSpec
    let infoSt := stSpec.infoState.substituteLazy.get
    let mut reads : NameSet := {}
    for t in infoSt.trees do
      reads := collectStmtConsts t bodies none reads
    let disjoint := writesN.all fun w => !reads.contains w
    let specClean := !(stSpec.messages.toList.any (·.severity matches .error))
    unless specClean do
      if r.i < 6 then
        for m in stSpec.messages.toList do
          if m.severity matches .error then
            IO.println s!"spec err cmd{r.i}: {(← m.data.toString).take 120}"
    r := { r with disjoint, specClean }
  let recs := recs.push r
  let nextPrev : Option PrevSpec :=
    if let some (_, _, stSpec) := specTask.get then
      if r.parseOk && r.disjoint && r.specClean then
        some { specEnv := stSpec.env, preConsts := moduleConsts stPre.env }
      else none
    else none
  if Parser.isTerminalCommand cmdN then
    return recs
  specLoop recs nextPrev (i + 1)

unsafe def main (args : List String) : IO Unit := do
  let path :: _ := args | throw <| IO.userError "usage: c1_spec_harness <file.lean>"
  Lean.enableInitializersExecution
  let sp := match (← IO.getEnv "LEAN_PATH") with
    | some p => System.SearchPath.parse p
    | none => []
  initSearchPath (← findSysroot) sp
  let input ← IO.FS.readFile path
  let inputCtx := Parser.mkInputContext input path
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let opts : Options := (({} : Options).setBool `Elab.async false)
  let (env, messages) ← processHeader header opts messages inputCtx
  if messages.hasErrors then
    for m in messages.toList do
      IO.println s!"HEADER ERROR: {(← m.data.toString).take 200}"
  let cmdState := Command.mkState env messages opts
  let cmdState := { cmdState with infoState.enabled := true }
  let fs : Frontend.State := { commandState := cmdState, parserState, cmdPos := parserState.pos }
  let (recs, _) ← (specLoop #[] none 0).run { inputCtx } |>.run fs
  let total := recs.size
  let withSpec := recs.filter (·.specNs > 0)
  let valid := withSpec.filter fun r => r.parseOk && r.disjoint && r.specClean
  let mainTotal := (recs.map (·.mainNs)).foldl (·+·) 0
  let savedNs := (valid.map fun r => min r.specNs r.mainNs).foldl (·+·) 0
  IO.println s!"commands: {total}; speculated: {withSpec.size}; VALID (parse+disjoint): {valid.size} = {100 * valid.size / (max withSpec.size 1)}%"
  IO.println s!"parse-invalid: {(withSpec.filter (!·.parseOk)).size}; read-write conflicts: {(withSpec.filter fun r => r.parseOk && !r.disjoint).size}; spec-errored: {(withSpec.filter fun r => !r.specClean).size}"
  IO.println s!"main-thread total: {mainTotal / 1000000} ms; overlap saved by valid depth-1 speculation: {savedNs / 1000000} ms ({100 * savedNs / (max mainTotal 1)}%)"
  let eqC := (recs.map (·.eqChecked)).foldl (·+·) 0
  let eqM := (recs.map (·.eqMatched)).foldl (·+·) 0
  IO.println s!"RESULT EQUIVALENCE: {eqM}/{eqC} speculated statement types structurally identical to sequential"
  IO.FS.withFile "c1_spec_out.jsonl" IO.FS.Mode.write fun out => do
    for r in recs do
      out.putStrLn ("{\"i\": " ++ toString r.i ++ ", \"kind\": \"" ++ toString r.kind ++
        "\", \"mainNs\": " ++ toString r.mainNs ++ ", \"specNs\": " ++ toString r.specNs ++
        ", \"parseOk\": " ++ toString r.parseOk ++ ", \"disjoint\": " ++ toString r.disjoint ++
        ", \"specClean\": " ++ toString r.specClean ++ "}")
