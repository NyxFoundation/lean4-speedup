set_option Elab.asyncByProofs true
def f (n : Nat) : { m : Nat // m > 0 } := ⟨n + 1, by omega⟩
def g (l : List Nat) : { l' : List Nat // l'.length = l.length } := ⟨l.map (· + 1), by simp⟩
theorem uses_f : (f 3).val = 4 := rfl
def dependent (n : Nat) : { m : Nat // m > n } :=
  ⟨n + 1, by omega⟩
#eval (f 5).val
