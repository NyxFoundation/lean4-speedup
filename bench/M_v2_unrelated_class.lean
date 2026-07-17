import Lean
/- v2 probe: adding an instance of class C must NOT invalidate (tier-2 rescue)
   a cached derivation of class D, but must flip a cached failure of C. -/
class CC (α : Type) where c : Nat
structure DD where d : Nat := 3
instance : Inhabited DD := ⟨{}⟩
open Lean Meta Elab Command
#eval liftTermElabM do
  let r ← synthInstance? (← mkAppM ``Inhabited #[mkConst ``DD])
  let rc ← synthInstance? (← mkAppM ``CC #[mkConst ``DD])
  logInfo m!"D: {r.isSome}, C: {rc.isSome}"   -- true, false
instance : CC DD := ⟨0⟩  -- grows instance table (class CC only)
#eval liftTermElabM do
  let r ← synthInstance? (← mkAppM ``Inhabited #[mkConst ``DD])
  let rc ← synthInstance? (← mkAppM ``CC #[mkConst ``DD])
  logInfo m!"D: {r.isSome}, C: {rc.isSome}"   -- true (tier-2 hit), true (flipped)
