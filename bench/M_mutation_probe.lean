import Lean
structure MyT where x : Nat := 7
open Lean Meta Elab Command
#eval liftTermElabM do
  let e ← mkAppM ``Inhabited #[mkConst ``MyT]
  let r ← synthInstance? e
  logInfo m!"before: {r.isSome}"
instance : Inhabited MyT := ⟨{}⟩
#eval liftTermElabM do
  let e ← mkAppM ``Inhabited #[mkConst ``MyT]
  let r ← synthInstance? e
  logInfo m!"after: {r.isSome}"
