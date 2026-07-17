-- B1: core-only representative workload: inductive types, structures,
-- typeclass search, simp, decide, and a bit of metaprogramming.
inductive Tree (α : Type) where
  | leaf
  | node (l : Tree α) (v : α) (r : Tree α)

namespace Tree
def insert [Ord α] (v : α) : Tree α → Tree α
  | leaf => node leaf v leaf
  | node l x r =>
    match compare v x with
    | .lt => node (insert v l) x r
    | .eq => node l x r
    | .gt => node l x (insert v r)

def toList : Tree α → List α
  | leaf => []
  | node l v r => toList l ++ v :: toList r

def size : Tree α → Nat
  | leaf => 0
  | node l _ r => size l + 1 + size r

theorem size_toList (t : Tree α) : t.toList.length = t.size := by
  induction t with
  | leaf => rfl
  | node l v r ihl ihr => simp [toList, size, ihl, ihr]; omega
end Tree

structure Vec3 where
  x : Float
  y : Float
  z : Float
deriving Repr, BEq, Inhabited

instance : Add Vec3 := ⟨fun a b => ⟨a.x + b.x, a.y + b.y, a.z + b.z⟩⟩
instance : HMul Float Vec3 Vec3 := ⟨fun s v => ⟨s * v.x, s * v.y, s * v.z⟩⟩

def dot (a b : Vec3) : Float := a.x * b.x + a.y * b.y + a.z * b.z

def fib : Nat → Nat
  | 0 => 0 | 1 => 1 | n + 2 => fib n + fib (n + 1)

theorem fib_pos : 0 < fib 7 := by decide

example : (List.range 100).length = 100 := by simp

macro "mkdefs" n:num : command => do
  let mut cmds := #[]
  for i in [0:n.getNat] do
    let name := Lean.mkIdent (Lean.Name.mkSimple s!"gen{i}")
    cmds := cmds.push (← `(def $name : Nat := $(Lean.quote i) + 1))
  return ⟨Lean.mkNullNode cmds⟩

mkdefs 200
