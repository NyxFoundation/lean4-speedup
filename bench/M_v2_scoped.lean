import Lean
/- v2 probe: activating a scoped instance via `open` must invalidate cached
   results of the affected class (candidate list changes). -/
class SC (α : Type) where s : Nat
structure STx where t : Nat := 1
namespace Hidden
scoped instance : SC STx := ⟨7⟩
end Hidden
open Lean Meta Elab Command
#eval liftTermElabM do
  let r ← synthInstance? (← mkAppM ``SC #[mkConst ``STx])
  logInfo m!"before open: {r.isSome}"   -- false
open Hidden
#eval liftTermElabM do
  let r ← synthInstance? (← mkAppM ``SC #[mkConst ``STx])
  logInfo m!"after open: {r.isSome}"    -- true (cached failure must invalidate)
