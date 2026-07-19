# Invention theory — how to generate invention as a thinking pattern

Research synthesis (2026-07-19), commissioned after the honest verdict on
iterations 50–73: the loop produced world-class *diagnostics* and one real
*bug fix* (T6), but no *invention*. This document asks why, against the
literature on how inventions actually arise, and rewrites the operating
protocol accordingly. Companion to [invention-playbook.md](invention-playbook.md)
(which remains the *selection* half of the method).

## 1. The structural diagnosis: our loop suppressed invention by design

[Fleming (2001)](https://funginstitute.berkeley.edu/wp-content/uploads/2012/10/Recombinant-Uncertainty-in-Technological-Search.pdf),
from 17,264 patents: searching with unfamiliar component combinations
**lowers the mean usefulness but raises the variance** — and breakthroughs
live only in the variance tail. Our loop demanded a verified, pushable
increment from *every* iteration, i.e. it applied the selection discipline
at the **generation** stage. That optimizes the mean and kills the
variance: it mass-produces bug fixes (mean improvements) and structurally
excludes inventions (tail events). T7/T8 were *correctly killed* by the
gates — but no high-variance attempt was ever generated in the first
place.

## 2. What the literature says invention is

| Theory | Claim | Implication for us |
|---|---|---|
| [Arthur, *The Nature of Technology*](https://sites.santafe.edu/~wbarthur/thenatureoftechnology.htm) | Invention = **harnessing a phenomenon** (radar ← EM reflection, MRI ← NMR) + combining existing components. Radical novelty is not accumulated small change. | psi-fold harnessed a phenomenon (ψ-symmetry of twiddle factors). T6 harnessed nothing — waste removal, hence "not an invention". |
| [C-K theory (Hatchuel & Weil)](https://www.ck-theory.org/c-k-theory/?lang=en) | Design = joint expansion of Concept space (propositions undecidable under current knowledge) and Knowledge space, via four operators (C→K, K→C, C→C, K→K). | Our loop ran K→K only (measure → explain). The playbook rule "analogy = explanation compressor after measurement" is a K-space operator; the **C-expansion operators were missing**. |
| [BVSR (Campbell / Simonton)](https://www.tandfonline.com/doi/full/10.1080/10400419.2022.2059919) | Creativity = **blind variation + selective retention**. Expertise alone reapplies known solutions; *new* expertise requires variation not fully sighted by current knowledge. | Our search was maximally sighted (measurement-driven) → converges to local optima = bugs. Controlled blindness is a required ingredient, not a failure of rigor. |
| [Uzzi et al., *Science* 2013](https://www.science.org/doi/10.1126/science.1240474) (17.9 M papers) | Highest-impact work = **exceptionally conventional core + a tail of atypical combination** (hit rate ≈ 2× background). Maximal novelty underperforms. | One atypical ingredient at a time, embedded in fully conventional engineering. psi-fold's shape exactly. |
| [TRIZ (Altshuller)](https://www.qualitymag.com/articles/98566-triz-the-backbone-of-innovation-and-problem-solving) (patent corpus) | Inventions **resolve contradictions without compromise** (improving A degrades B), via recurring principles — notably *separation* in time/space/condition. | Our measured contradiction — "commands must see sequential env state" vs "we need parallel command elaboration" — is textbook TRIZ input. Separation-in-time = speculative execution. |

## 3. Case studies: what the delta of great inventions actually was

### Einstein 1905 (special relativity)

How he thought (primary sources):
- **Pre-verbal combinatory play**: his reply to
  [Hadamard's survey of mathematicians](https://www.themarginalian.org/2013/08/14/how-einstein-thought-combinatorial-creativity/) —
  "combinatory play seems to be the essential feature in productive
  thought — *before* any connection with words or signs"; his thought
  elements were "visual and some of muscular type", voluntarily
  reproducible and combinable.
- **Gedankenexperiment as the main instrument**
  ([overview](https://en.wikipedia.org/wiki/Einstein%27s_thought_experiments)):
  riding a light beam at 16; the 1905 paper *opens* with the
  magnet-and-conductor experiment — an offense at the theory giving **two
  explanations for one phenomenon**. Asymmetry-sensitivity was his anomaly
  detector.
- **Principle-theory strategy**: when constructive (mechanistic)
  explanations kept failing, promote empirically solid regularities to
  postulates and derive.
- **Operationalization of "obvious" concepts**: simultaneity redefined as
  a clock-synchronization procedure.

The delta ([historians' consensus](https://arxiv.org/html/2510.17838v2),
[also](https://arxiv.org/html/2509.09361v1)): **zero new mathematics**.
Lorentz transformations, group property, velocity addition, even the
phrase "principle of relativity" pre-existed (Poincaré). The delta was:
(1) *subtraction* — the ether abolished; (2) *status change* — an ad-hoc
auxiliary hypothesis elevated to a universal postulate; (3)
*reinterpretation* — the same formulas read as kinematics, not dynamics
corrections. Poincaré extended Lorentz's dynamics; Einstein re-founded
kinematics.

### von Neumann (EDVAC, QM foundations, Monte Carlo)

How he thought:
- [Ulam's recollection](https://mathshistory.st-andrews.ac.uk/Extras/Ulam_Rota/):
  aural/symbolic rather than visual; slept on problems and woke with
  answers.
- Core operator: **opportunistic axiomatization**
  ([methodology study](https://www.researchgate.net/publication/281136116_Opportunistic_Axiomatics_-_Von_Neumann_on_the_Methodology_of_Mathematical_Physics)) —
  take someone else's half-formed practice and give it the abstraction
  that makes its generality visible: set theory, Hilbert-space unification
  of Heisenberg vs Schrödinger, game theory, EDVAC.
- His own warning: when formalism "shows signs of becoming baroque…the
  only remedy is the rejuvenating return to the source: the reinjection of
  more or less directly empirical ideas."

The delta of the
[EDVAC report](https://en.wikipedia.org/wiki/First_Draft_of_a_Report_on_the_EDVAC):
all components pre-existed — delay-line storage and stored-program
discussions at the Moore School (Eckert/Mauchly, months before his
involvement), universality (Turing 1936). The delta was **the
representation**: describing the machine as hardware-independent
[*logical organs* in McCulloch-Pitts neuron vocabulary](http://ds-wordpress.haverford.edu/bitbybit/bit-by-bit-contents/chapter-five/5-2-john-von-neumann-and-the-report-on-the-edvac/),
which made the design portable and copyable — that is why it became "the
von Neumann architecture". The representation *was* the invention.
(Monte Carlo, with Ulam, is an Arthur-style phenomenon capture:
randomness harnessed as a computational resource.)

## 4. The five delta operators (compressed from the cases)

Great-invention deltas recur as a small set of operators, applied to a
~99 %-conventional base:

1. **Subtraction** — remove the component everyone assumes (the ether).
   *For Lean: "is elaboration necessary for checking?" — a verify-only
   fast path.*
2. **Status change** — promote a measured regularity to a design axiom.
   *For Lean: "most commands don't read the previous command's writes"
   (measured) → axiomatize it → speculative command elaboration with
   violation repair.*
3. **Re-representation** — change the abstraction level of a working
   mess. *For Lean: the env as a stream of monotone commits; elaboration
   as an explicit dataflow graph.*
4. **Unification** — two explanations for one phenomenon offend; make
   them one.
5. **Decomposition of the obvious** — operationalize a concept nobody
   questions. *For Lean: "command order", "the environment".*

Common trigger for all five: **sensitivity to asymmetries and
redundancies that others tolerate.**

## 5. Protocol v2 — generating invention as a thinking pattern

The verified-gates machinery (playbook rules 1–8) is the *retention* half
of BVSR and stays intact. The missing *generation* half:

1. **Name the contradiction** in one sentence (TRIZ input; diagnostics
   feed this — ours: sequential env semantics vs parallel command
   elaboration).
2. **Inventory phenomena** (Arthur, K→C): exploitable structures in the
   domain and neighbors — symmetries, monotonicity, idempotence,
   locality, *statistical regularities of the workload* (measured
   command-independence is a harnessable phenomenon).
3. **Force C-expansions** (C-K): write ≥10 concept propositions currently
   undecidable — including ones current knowledge forbids — using the five
   delta operators and TRIZ separation principles as generators.
4. **Budget blind variance** (Fleming/BVSR): a fixed fraction of loop time
   (e.g. 1/3) where the verified-increment rule is **suspended at
   generation time** — cheap prototypes of high-uncertainty combinations,
   expecting a low mean, harvesting the tail.
5. **Conventional core, one atypical ingredient** (Uzzi): never two exotic
   moves at once.
6. **Selection stays brutal** (playbook rules — unchanged).
7. **Keep a perceptual channel open**: psi-fold came from *looking at* a
   visually-3d render. Visualization is the perception apparatus for
   step 2; iterations 50–73 never used it — a protocol violation in
   hindsight.

## 6. Sources

TRIZ: [Quality Magazine overview](https://www.qualitymag.com/articles/98566-triz-the-backbone-of-innovation-and-problem-solving) ·
C-K: [ck-theory.org](https://www.ck-theory.org/c-k-theory/?lang=en),
[C-K and creative thinking](https://www.researchgate.net/publication/321926190_C-K_Theory_Modelling_Creative_Thinking_and_Its_Impact_on_Research) ·
Arthur: [The Nature of Technology](https://sites.santafe.edu/~wbarthur/thenatureoftechnology.htm) ·
BVSR: [Simonton 2022 status review](https://www.tandfonline.com/doi/full/10.1080/10400419.2022.2059919) ·
Impact structure: [Uzzi et al., Science 2013](https://www.science.org/doi/10.1126/science.1240474) ·
Variance: [Fleming 2001](https://funginstitute.berkeley.edu/wp-content/uploads/2012/10/Recombinant-Uncertainty-in-Technological-Search.pdf) ·
Einstein: [Hadamard-survey reply](https://www.themarginalian.org/2013/08/14/how-einstein-thought-combinatorial-creativity/),
[thought experiments](https://en.wikipedia.org/wiki/Einstein%27s_thought_experiments),
[genesis of SR (2025 history)](https://arxiv.org/html/2510.17838v2),
[Einstein vs Poincaré](https://arxiv.org/html/2509.09361v1) ·
von Neumann: [Ulam & Rota](https://mathshistory.st-andrews.ac.uk/Extras/Ulam_Rota/),
[Opportunistic Axiomatics](https://www.researchgate.net/publication/281136116_Opportunistic_Axiomatics_-_Von_Neumann_on_the_Methodology_of_Mathematical_Physics),
[EDVAC report](https://en.wikipedia.org/wiki/First_Draft_of_a_Report_on_the_EDVAC),
[Bit by Bit ch. 5.2](http://ds-wordpress.haverford.edu/bitbybit/bit-by-bit-contents/chapter-five/5-2-john-von-neumann-and-the-report-on-the-edvac/)
