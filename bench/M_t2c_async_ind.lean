set_option Elab.asyncInductive true
structure P (α : Type) where mk :: (x : α) (y : Nat)
example : (P.mk 1 2).x = 1 := rfl        -- iota reduction through rec
def f (p : P Nat) : Nat := p.x + p.y
theorem t : f ⟨3, 4⟩ = 7 := rfl
structure QProp : Prop where mk :: (h : True)
example : QProp := ⟨trivial⟩
structure RPropData (le : Nat → Nat → Bool) : Prop where mk :: (rank : Nat) (h : le 1 2 = le 1 2)
example (le : Nat → Nat → Bool) : RPropData le := ⟨5, rfl⟩
#print P.rec
