/- T10 varTelescopeCache correctness probes: every cache-key axis gets an
interleaved mutation; file output must be IDENTICAL with the option on/off. -/

-- 1. open-decl change between variable commands (name-resolution capture)
namespace A
class C (α : Type) where val : Nat := 0
instance : C Nat := {}
end A
namespace B
class C (α : Type) where val : Nat := 1
instance : C Int := {}
end B

section
open A
variable {α : Type} [C α]
theorem t1 [A.C Nat] : True := trivial
open B
variable {β : Type} [B.C β]   -- prefix [C α] must still mean A.C
theorem t2 : (A.C.val (α := Nat)) = 0 := rfl
#check @t2
end

-- 2. instance added between variable commands (env stamp)
section
class D (α : Type) where d : Nat := 2
variable {γ : Type} [D γ]
instance : D Nat := {}
variable [D Int]
theorem t3 [D Nat] : D.d (α := Nat) = 2 := rfl
#check @t3
end

-- 3. universe command between variables (levelNames key)
section
variable {δ : Type u}
universe v
variable {ε : Type v}
def t4 (x : δ) (y : ε) : δ × ε := (x, y)
#check @t4
end

-- 4. set_option between variables (opts key)
section
variable {ζ : Type}
set_option pp.explicit true in
#check @id ζ
variable [Inhabited ζ]
theorem t5 : (default : ζ) = default := rfl
#check @t5
end

-- 5. binder-annotation update (varDecls element replacement)
section
variable {η : Type}
variable (η)
def t6 (x : η) : η := x
#check @t6
end

-- 6. plain long chain (the hit path itself)
section
variable {R1 : Type} [Mul R1]
variable {R2 : Type} [Mul R2]
variable {R3 : Type} [Mul R3]
theorem t7 (a : R1) (b : R2) (c : R3) : a * a = a * a := rfl
#check @t7
end

-- 7. auto-bound section variable (must NOT be cached; α is auto-bound)
section
variable [BEq κα] [Hashable κα]
def t8 (x : κα) : κα := x
theorem t9 (x : κα) : t8 x = x := rfl
#check @t9
end
