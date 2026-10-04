import Std

/- This finite model concerns one retained row, not the journal or native host.
   Result bytes are represented by two distinct digest classes. -/
namespace Admission
inductive Phase where
  | a
  | i0
  | i1
  | fap
  | fad
  | fbp
  | fbd
  | ta0p
  | ta0d
  | ta1p
  | ta1d
  | tb0p
  | tb0d
  | tb1p
  | tb1d
  | ra
  | rb
  | xa
  | xb
  deriving DecidableEq, Repr
inductive Gate where
  | open | closed
  deriving DecidableEq, Repr
inductive Digest where
  | a | b
  deriving DecidableEq, Repr
inductive Request where
  | equal | conflict
  deriving DecidableEq, Repr
inductive Event where
  | launch | refuseA | refuseB | terminalA | terminalB | retirement
  | receiptA | receiptB | compact
  deriving DecidableEq, Repr
inductive Effect where
  | noLaunch | launch
  deriving DecidableEq, Repr
inductive Error where
  | requestConflict | epochClosed | notLaunched | launchAlreadyAuthorized
  | resultConflict | missingTerminal | notForgettable
  deriving DecidableEq, Repr
inductive Outcome where
  | ok (phase : Phase) (effect : Effect)
  | error (reason : Error)
  deriving DecidableEq, Repr
open Phase

def resultDigest : Phase → Option Digest
  | .fap => some .a
  | .fad => some .a
  | .fbp => some .b
  | .fbd => some .b
  | .ta0p => some .a
  | .ta0d => some .a
  | .ta1p => some .a
  | .ta1d => some .a
  | .tb0p => some .b
  | .tb0d => some .b
  | .tb1p => some .b
  | .tb1d => some .b
  | .ra => some .a
  | .rb => some .b
  | .xa => some .a
  | .xb => some .b
  | .a | .i0 | .i1 => none

def refused : Phase → Bool
  | .fap | .fad | .fbp | .fbd | .xa | .xb => true
  | .a | .i0 | .i1 | .ta0p | .ta0d | .ta1p | .ta1d
  | .tb0p | .tb0d | .tb1p | .tb1d | .ra | .rb => false

def sealed (p : Phase) : Bool := p != .a

def success (p : Phase) : Outcome := .ok p .noLaunch

def matchResult (p : Phase) (d : Digest) : Outcome :=
  if resultDigest p == some d then success p else .error .resultConflict

def refuse (p : Phase) (d : Digest) : Outcome :=
  match p with
  | .a => success (if d == .a then .fap else .fbp)
  | .fap | .fad | .fbp | .fbd | .xa | .xb => matchResult p d
  | .i0 | .i1 | .ta0p | .ta0d | .ta1p | .ta1d
  | .tb0p | .tb0d | .tb1p | .tb1d | .ra | .rb => .error .launchAlreadyAuthorized

def terminal (p : Phase) (d : Digest) : Outcome :=
  match p with
  | .a | .fap | .fad | .fbp | .fbd | .xa | .xb => .error .notLaunched
  | .i0 => success (if d == .a then .ta0p else .tb0p)
  | .i1 => success (if d == .a then .ta1p else .tb1p)
  | .ta0p | .ta0d | .ta1p | .ta1d | .tb0p | .tb0d | .tb1p | .tb1d
  | .ra | .rb => matchResult p d

def retire (p : Phase) : Outcome :=
  match p with
  | .a => .error .notLaunched
  | .i0 | .i1 => success .i1
  | .ta0p | .ta1p => success .ta1p
  | .ta0d | .ta1d => success .ta1d
  | .tb0p | .tb1p => success .tb1p
  | .tb0d | .tb1d => success .tb1d
  | .fap | .fad | .fbp | .fbd | .ra | .rb | .xa | .xb => success p

def received : Phase → Phase
  | .fap => .fad
  | .fad => .fad
  | .fbp => .fbd
  | .fbd => .fbd
  | .ta0p => .ta0d
  | .ta0d => .ta0d
  | .ta1p => .ta1d
  | .ta1d => .ta1d
  | .tb0p => .tb0d
  | .tb0d => .tb0d
  | .tb1p => .tb1d
  | .tb1d => .tb1d
  | p => p

def receipt (p : Phase) (d : Digest) : Outcome :=
  match p with
  | .a | .i0 | .i1 => .error .missingTerminal
  | .fap | .fad | .fbp | .fbd | .ta0p | .ta0d | .ta1p | .ta1d
  | .tb0p | .tb0d | .tb1p | .tb1d | .ra | .rb | .xa | .xb =>
    if resultDigest p == some d then success (received p) else .error .resultConflict

def compact : Phase → Outcome
  | .fad => success .xa
  | .fbd => success .xb
  | .ta1d => success .ra
  | .tb1d => success .rb
  | .ra => success .ra
  | .rb => success .rb
  | .xa => success .xa
  | .xb => success .xb
  | .a | .i0 | .i1 | .fap | .fbp | .ta0p | .ta0d | .ta1p
  | .tb0p | .tb0d | .tb1p => .error .notForgettable

/- Request validation precedes lifecycle decisions, as inspect does in Gleam. -/
def step (g : Gate) (p : Phase) (r : Request) (e : Event) : Outcome :=
  if r == .conflict then .error .requestConflict else
  match e with
  | .launch =>
    if p == .a then
      if g == .open then .ok .i0 .launch else .error .epochClosed
    else success p
  | .refuseA => refuse p .a
  | .refuseB => refuse p .b
  | .terminalA => terminal p .a
  | .terminalB => terminal p .b
  | .retirement => retire p
  | .receiptA => receipt p .a
  | .receiptB => receipt p .b
  | .compact => compact p

def next (p : Phase) : Outcome → Phase
  | .ok q _ => q
  | .error _ => p

def launches : Outcome → Nat
  | .ok _ .launch => 1
  | .ok _ .noLaunch | .error _ => 0

/- Each local lemma is checked by reduction in Lean's kernel. -/
theorem only_open_admitted_launch (g : Gate) (p : Phase) (r : Request) (e : Event) :
    launches (step g p r e) = 1 ↔
      g = .open ∧ p = .a ∧ r = .equal ∧ e = .launch := by
  cases g <;> cases p <;> cases r <;> cases e <;> decide

theorem sealed_preserved (g : Gate) (p : Phase) (r : Request) (e : Event) :
    sealed p = true → sealed (next p (step g p r e)) = true := by
  cases g <;> cases p <;> cases r <;> cases e <;> decide

theorem sealed_no_launch (g : Gate) (p : Phase) (r : Request) (e : Event) :
    sealed p = true → launches (step g p r e) = 0 := by
  cases g <;> cases p <;> cases r <;> cases e <;> decide

theorem launch_seals (g : Gate) (p : Phase) (r : Request) (e : Event) :
    launches (step g p r e) = 1 → sealed (next p (step g p r e)) = true := by
  cases g <;> cases p <;> cases r <;> cases e <;> decide

theorem refusal_origin_preserved (g : Gate) (p : Phase) (r : Request) (e : Event) :
    refused p = true → refused (next p (step g p r e)) = true := by
  cases g <;> cases p <;> cases r <;> cases e <;> decide

def launchedTerminal : Phase → Bool
  | .ta0p | .ta0d | .ta1p | .ta1d | .tb0p | .tb0d | .tb1p | .tb1d
  | .ra | .rb => true
  | .a | .i0 | .i1 | .fap | .fad | .fbp | .fbd | .xa | .xb => false

def hasReceipt : Phase → Bool
  | .fad | .fbd | .ta0d | .ta1d | .tb0d | .tb1d | .ra | .rb | .xa | .xb => true
  | .a | .i0 | .i1 | .fap | .fbp | .ta0p | .ta1p | .tb0p | .tb1p => false

def hasRetirement : Phase → Bool
  | .i1 | .fap | .fad | .fbp | .fbd | .ta1p | .ta1d | .tb1p | .tb1d
  | .ra | .rb | .xa | .xb => true
  | .a | .i0 | .ta0p | .ta0d | .tb0p | .tb0d => false

theorem compact_obligations (p : Phase) :
    (∃ q eff, compact p = .ok q eff) →
      hasReceipt p = true ∧ hasRetirement p = true := by
  cases p <;> simp [compact, success, hasReceipt, hasRetirement]

/- Retired fences already discharged obligations; only newly compacted rows
   need a receipt and, for launched work, affirmative native retirement. -/
theorem compact_requires_evidence (p : Phase) :
    launches (compact p) = 0 ∧
    ((∃ q eff, compact p = .ok q eff) ↔
      p = .fad ∨ p = .fbd ∨ p = .ta1d ∨ p = .tb1d ∨
      p = .ra ∨ p = .rb ∨ p = .xa ∨ p = .xb) := by
  cases p <;> simp [compact, success, launches]

abbrev Input := Gate × Request × Event

def run (p : Phase) : List Input → Phase
  | [] => p
  | (g, r, e) :: xs => run (next p (step g p r e)) xs

def count (p : Phase) : List Input → Nat
  | [] => 0
  | (g, r, e) :: xs => launches (step g p r e) + count (next p (step g p r e)) xs

theorem sealed_trace (xs : List Input) (p : Phase) (h : sealed p = true) :
    count p xs = 0 ∧ sealed (run p xs) = true := by
  induction xs generalizing p with
  | nil => simp [count, run, h]
  | cons x xs ih =>
    rcases x with ⟨g, r, e⟩
    have hp := sealed_preserved g p r e h
    have hn := sealed_no_launch g p r e h
    simpa [count, run, hn] using ih _ hp

theorem refusal_trace (xs : List Input) (p : Phase) (h : refused p = true) :
    refused (run p xs) = true := by
  induction xs generalizing p with
  | nil => exact h
  | cons x xs ih =>
    rcases x with ⟨g, r, e⟩
    exact ih _ (refusal_origin_preserved g p r e h)

theorem refusal_never_launched_terminal (xs : List Input) (p : Phase)
    (h : refused p = true) : launchedTerminal (run p xs) = false := by
  have hr := refusal_trace xs p h
  generalize run p xs = q at hr ⊢
  cases q <;> simp_all [refused, launchedTerminal]

theorem at_most_one_launch (xs : List Input) (p : Phase) : count p xs ≤ 1 := by
  induction xs generalizing p with
  | nil => simp [count]
  | cons x xs ih =>
    rcases x with ⟨g, r, e⟩
    by_cases h : launches (step g p r e) = 1
    · have hs := launch_seals g p r e h
      have hz := (sealed_trace xs _ hs).1
      simp [count, h, hz]
    · have hz : launches (step g p r e) = 0 := by
        cases ho : step g p r e with
        | error reason => simp [launches]
        | ok q eff => cases eff <;> simp_all [launches]
      simpa [count, hz] using ih (next p (step g p r e))

/- Fresh admission is a specialization, not a claim about book recreation. -/
theorem fresh_scope_at_most_one (xs : List Input) : count .a xs ≤ 1 :=
  at_most_one_launch xs .a

#print axioms only_open_admitted_launch
#print axioms sealed_preserved
#print axioms sealed_no_launch
#print axioms launch_seals
#print axioms refusal_origin_preserved
#print axioms compact_obligations
#print axioms compact_requires_evidence
#print axioms sealed_trace
#print axioms refusal_trace
#print axioms refusal_never_launched_terminal
#print axioms at_most_one_launch
#print axioms fresh_scope_at_most_one

def phases : List Phase := [.a, .i0, .i1, .fap, .fad, .fbp, .fbd, .ta0p, .ta0d, .ta1p, .ta1d, .tb0p, .tb0d, .tb1p, .tb1d, .ra, .rb, .xa, .xb]
def events : List Event := [.launch, .refuseA, .refuseB, .terminalA, .terminalB, .retirement, .receiptA, .receiptB, .compact]
def phaseText : Phase → String
  | .a => "a"
  | .i0 => "i0"
  | .i1 => "i1"
  | .fap => "fap"
  | .fad => "fad"
  | .fbp => "fbp"
  | .fbd => "fbd"
  | .ta0p => "ta0p"
  | .ta0d => "ta0d"
  | .ta1p => "ta1p"
  | .ta1d => "ta1d"
  | .tb0p => "tb0p"
  | .tb0d => "tb0d"
  | .tb1p => "tb1p"
  | .tb1d => "tb1d"
  | .ra => "ra"
  | .rb => "rb"
  | .xa => "xa"
  | .xb => "xb"
def eventText : Event → String
  | .launch => "launch"
  | .refuseA => "refuse-a"
  | .refuseB => "refuse-b"
  | .terminalA => "terminal-a"
  | .terminalB => "terminal-b"
  | .retirement => "retirement"
  | .receiptA => "receipt-a"
  | .receiptB => "receipt-b"
  | .compact => "compact"
def errorText : Error → String
  | .requestConflict => "RequestConflict"
  | .epochClosed => "EpochClosed"
  | .notLaunched => "NotLaunched"
  | .launchAlreadyAuthorized => "LaunchAlreadyAuthorized"
  | .resultConflict => "ResultConflict"
  | .missingTerminal => "MissingTerminal"
  | .notForgettable => "NotForgettable"
def outcomeText (g : Gate) : Outcome → String
  | .error e => "error:" ++ errorText e
  | .ok p eff => "ok:" ++ phaseText p ++ ":" ++ (match eff with
    | .noLaunch => "no-launch"
    | .launch => "launch") ++ ":" ++ (if g == .open then "open" else "closed")
end Admission

/- TSV is computed from the very step function whose invariants were proved. -/
def main : IO Unit := do
  let stdout ← IO.getStdout
  for g in [Admission.Gate.open, .closed] do
    for p in Admission.phases do
      for r in [Admission.Request.equal, .conflict] do
        for e in Admission.events do
          let fields := ["BRIDGE", (if g == .open then "open" else "closed"),
            Admission.phaseText p, (if r == .equal then "equal" else "conflict"),
            Admission.eventText e, Admission.outcomeText g (Admission.step g p r e)]
          stdout.putStrLn (String.intercalate "\t" fields)
