module
set_option Elab.asyncInductive true
public structure MP (α : Type) where
  x : α
  y : Nat
public example : (MP.mk 1 2).x = 1 := rfl
public def mpf (p : MP Nat) : Nat := p.x + p.y
public theorem mpt : mpf ⟨3, 4⟩ = 7 := rfl
