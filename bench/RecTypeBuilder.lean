import Lean
/-!
T2c piece 1: Lean-side recursor-TYPE construction for single-constructor,
non-recursive, no-index inductives (structures), including Prop elimination
computation. Developed standalone: for each test structure we build the type
and BEq-compare against the kernel's actual `T.rec` type.
-/
open Lean Meta

/-- Compute the recursor type for a single-ctor no-index non-recursive
inductive from its `InductiveVal`/`ConstructorVal`, mirroring the kernel.
Returns (recType, recLevelParams). -/
def buildRecType (indVal : InductiveVal) (ctorVal : ConstructorVal) :
    MetaM (Expr × List Name) := do
  let us := indVal.levelParams.map Level.param
  forallTelescopeReducing indVal.type fun params sort => do
    unless params.size == indVal.numParams do throwError "index detected"
    let .sort resultLevel := sort | throwError "unexpected sort"
    -- large elimination? Type-valued: yes. Prop-valued: only if all ctor
    -- fields are proofs.
    let ctorType ← instantiateForall ctorVal.type params
    let largeElim ←
      if resultLevel.isZero then
        forallTelescopeReducing ctorType fun fields _ =>
          fields.allM fun f => do isProp (← inferType f)
      else
        pure true
    -- fresh elim level param name
    let elimName := Id.run do
      unless largeElim do return none
      for i in [0:100] do
        let n := if i == 0 then `u else Name.mkSimple s!"u_{i}"
        unless indVal.levelParams.contains n do return some n
      return some `uFresh
    let motiveSort := match elimName with
      | some u => mkSort (.param u)
      | none   => mkSort .zero
    let indApp := mkAppN (mkConst indVal.name us) params
    -- motive : T params → Sort elim
    withLocalDecl `motive .implicit (← mkArrow indApp motiveSort) fun motive => do
      -- minor : ∀ fields, motive (mk params fields)
      let minorType ← forallTelescopeReducing ctorType fun fields _ => do
        let ctorApp := mkAppN (mkConst ctorVal.name us) (params ++ fields)
        mkForallFVars fields (mkApp motive ctorApp)
      withLocalDecl `t .default indApp fun t => do
        let body := mkApp motive t
        let recType ← mkForallFVars #[t] body
        let recType ← mkForallFVars #[motive] (← mkArrow minorType recType)
        let recType ← mkForallFVars params recType
        let recLevels := match elimName with
          | some u => u :: indVal.levelParams
          | none   => indVal.levelParams
        return (recType, recLevels)

def checkOne (n : Name) : MetaM Unit := do
  let .inductInfo indVal ← getConstInfo n | throwError "not inductive"
  let [ctorName] := indVal.ctors | throwError "not single-ctor"
  let .ctorInfo ctorVal ← getConstInfo ctorName | throwError "?"
  let (myType, myLevels) ← buildRecType indVal ctorVal
  let .recInfo recVal ← getConstInfo (n ++ `rec) | throwError "no rec"
  -- compare up to level-param renaming: instantiate both with the same levels
  let mine := myType.instantiateLevelParams myLevels (recVal.levelParams.map Level.param)
  if (← withNewMCtxDepth <| isDefEq mine recVal.type) then
    if mine == recVal.type then
      logInfo m!"{n}: EXACT MATCH"
    else
      logInfo m!"{n}: defeq but not syntactic\n  mine: {mine}\n  real: {recVal.type}"
  else
    logError m!"{n}: MISMATCH\n  mine: {mine}\n  real: {recVal.type}"

structure PropWithData (le : Nat → Nat → Bool) : Prop where
  intro ::
  rank_le : le 1 2 = true
structure PropPure (p q : Prop) : Prop where
  intro ::
  hp : p
  hq : q

#eval Elab.Command.liftTermElabM do
  for n in [``Prod, ``Subtype, ``PProd, ``And, ``PropPure, ``PropWithData, ``Sigma] do
    checkOne n
