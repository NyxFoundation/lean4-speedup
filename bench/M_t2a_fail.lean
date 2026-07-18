set_option Elab.asyncByProofs true
def bad (n : Nat) : { m : Nat // m > n + 1000 } := ⟨n + 1, by omega⟩
