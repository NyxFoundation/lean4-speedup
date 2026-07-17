import Lean
class Weird (α : Type) where val : Nat
open Lean Meta Elab Command
def probeA {α : Type} [DecidableEq α] : Option Nat := none
#eval liftTermElabM do
  withLocalDeclD `α (mkSort levelOne) fun a => do
  let e ← mkAppM ``Weird #[a]
  let r ← synthInstance? e
  logInfo m!"before: {r.isSome}"
instance : Weird α := ⟨0⟩
#eval liftTermElabM do
  withLocalDeclD `α (mkSort levelOne) fun a => do
  let e ← mkAppM ``Weird #[a]
  let r ← synthInstance? e
  logInfo m!"after: {r.isSome}"
