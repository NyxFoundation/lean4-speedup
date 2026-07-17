set_option Elab.asyncInductive true
structure FMWF (le : Nat → Nat → Bool) (res : Nat) : Prop where
  rank : Nat
  h : le rank res = true
section
variable {α : Type} (le : α → α → Bool)
structure FMWF2 (res : Nat) : Prop where
  rank : Nat
  h : le = le
end
