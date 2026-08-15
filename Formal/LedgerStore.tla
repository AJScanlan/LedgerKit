-------------------------------- MODULE LedgerStore --------------------------------
(***************************************************************************)
(* ConversationStore's delete-versus-start race (M7 audit finding A3).     *)
(*                                                                          *)
(* WHY THIS MODEL EXISTS, AND HOW TO TRUST IT                               *)
(*                                                                          *)
(* This is a calibration artifact before it is a verification one. Two      *)
(* consecutive milestone boundary audits found an interleaving bug in the   *)
(* same verb: the M5 audit found `deleteConversation` waiting only on a     *)
(* `.running` slot and not on a `.reserved` one; the M6 audit found A3,     *)
(* where a *new* starter interleaves at delete's awaits and appends into a  *)
(* conversation the DELETE is about to erase. A human audit finds one such  *)
(* bug per boundary. The claim under test is that a model checker finds     *)
(* them all at once, or reports there are none.                             *)
(*                                                                          *)
(* That claim is worthless unless the model is faithful, and a model is     *)
(* not made faithful by being read carefully. So the model is calibrated    *)
(* against a bug already known to be real:                                  *)
(*                                                                          *)
(*   Fix = "none" models the store as shipped, and TLC MUST FAIL on it.     *)
(*                                                                          *)
(* A model that cannot reproduce A3 is wrong about the code, and the fix is *)
(* to the model, not to the store. Only once it fails on demand does a pass *)
(* on any other variant mean anything. It does fail: `NoOrphanRows` is      *)
(* violated in a ten-state trace, found in under a second — against a bug   *)
(* that took a milestone boundary audit to notice.                          *)
(*                                                                          *)
(* HOW SWIFT ACTOR REENTRANCY IS ENCODED                                    *)
(*                                                                          *)
(* One rule, applied mechanically: **a PlusCal label is an `await`.**       *)
(* A Swift actor runs one task at a time but yields at every suspension     *)
(* point, so the code between two awaits is an atomic region and the awaits *)
(* are where another task may interleave. PlusCal gives exactly that:       *)
(* statements inside one label execute atomically, and other processes may  *)
(* run at label boundaries. Placing labels at Swift's suspension points is  *)
(* therefore a transcription rather than an interpretation — which is the   *)
(* reason this particular subject is worth model-checking at all.           *)
(*                                                                          *)
(* Two reads matter and they differ in freshness, which IS the bug:         *)
(*                                                                          *)
(*   - `existingFold` reads "does this conversation exist" BEFORE a         *)
(*     suspension, and `reserve` acts on it AFTER, with no re-check. The    *)
(*     model copies it into the process-local `sawConv` to preserve that    *)
(*     staleness. Erase the local and the bug disappears from the model     *)
(*     while remaining in the code.                                         *)
(*   - The tombstone is read fresh, synchronously, inside `reserve`. That   *)
(*     freshness is the entire reason the fix works.                        *)
(*                                                                          *)
(* WHAT IS DELIBERATELY ABSTRACTED (the model's honest scope)               *)
(*                                                                          *)
(*   - One conversation. A3 is intra-conversation; cross-conversation work  *)
(*     is unrestricted by design (SPEC 6.5) and would only add symmetry.    *)
(*   - The events table is a sequence of row tags. Sequence numbers are not *)
(*     modelled as integers; "MAX(sequence)+1 restarts at 1 after a DELETE" *)
(*     appears as appending to an emptied sequence, which is what makes the *)
(*     resulting rows genesis-less.                                         *)
(*   - The fold cache, snapshots, the driver and the delta-flush cadence    *)
(*     are all absent. None participates in A3, and each would enlarge the  *)
(*     state space without enlarging the question.                          *)
(*   - `evict` (the cache drop after the DELETE commits) is folded into the *)
(*     DELETE step. It touches no invariant here.                           *)
(*   - Persistence never fails. Rollback paths are a separate question and  *)
(*     a separate model; mixing them in would make a counterexample harder  *)
(*     to read without making A3 easier to find.                            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Senders,   \* Concurrent generation starters (send / respond / regenerate).
    Fix        \* Which remedy is modelled. See the table below.

(***************************************************************************)
(* THE FOUR VARIANTS, AND WHAT TLC SAYS ABOUT EACH                          *)
(*                                                                          *)
(*   "none"      The store as shipped.            FAILS - this is A3.       *)
(*   "tombstone" M7 Phase 0's proposed fix:       FAILS - see below.        *)
(*               `deleting` set at delete entry,                            *)
(*               cleared on completion.                                     *)
(*   "sticky"    As above but never cleared.      (run it and see)          *)
(*   "guard"     No tombstone. `append` refuses   (run it and see)          *)
(*               a batch that would be the first                            *)
(*               row of a conversation without                              *)
(*               being its genesis.                                         *)
(*                                                                          *)
(* WHY "tombstone" IS NOT ENOUGH — the model's first original result.       *)
(*                                                                          *)
(* The tombstone covers the interval [delete entry, delete completion]. The *)
(* interval that actually needs covering is [starter's existence read,      *)
(* starter's append]. A starter that read `convExists` *before* the delete  *)
(* began, and reaches `reserve` *after* the delete finished and cleared the *)
(* flag, is guarded by nothing: its read says the conversation exists, the  *)
(* tombstone says no deletion is in progress, and both are true statements  *)
(* about moments that never overlapped. The append then lands on an empty   *)
(* table and numbers itself from 1.                                         *)
(*                                                                          *)
(* Reachability, stated honestly. The trace needs the starter's             *)
(* `existingFold` to suspend, which happens on a cold fold cache, and needs *)
(* its continuation to be scheduled after the deleter has run to            *)
(* completion. Swift actors give no FIFO guarantee across continuations     *)
(* resumed from different sources (a GRDB callback versus an actor hop), so *)
(* this is permitted rather than forced. That is precisely the complaint:   *)
(* with the tombstone, the invariant holds only when the scheduler          *)
(* cooperates, and nothing in the code says it must.                        *)
(*                                                                          *)
(* Note also what carries the damage past every in-memory guard: `events`   *)
(* has no foreign key to `conversations` (verified in the schema), and      *)
(* `append` validates only that each record's own conversationID matches    *)
(* its target. Nothing at the write boundary knows the conversation is      *)
(* gone — which is why "guard" is modelled at all.                          *)
(***************************************************************************)

(*--algorithm LedgerStore {

variables
    \* The conversation is loadable: `existingFold` succeeds rather than
    \* throwing `unknownConversation`.
    convExists = TRUE,

    \* The events table for this conversation. Starts at genesis, because a
    \* conversation only exists once `createConversation` has written one.
    rows = <<"genesis">>,

    \* The single-flight slot (`live[conversation]`, D24's reservation).
    \* "reserved" is claimed-but-not-yet-appended; "running" is confirmed.
    live = "none",

    \* `deleting: Set<ConversationID>` on the store actor, consulted
    \* synchronously by `reserve`. Inert unless Fix names a tombstone variant.
    deleting = FALSE;

define {
    \* A3's artifact, stated two ways because the audit describes it two ways.

    \* Rows surviving for a conversation that has been deleted.
    NoOrphanRows == (~convExists) => (rows = <<>>)

    \* The same damage seen from the reducer's side: rows whose first entry is
    \* not `conversationCreated`. Everything in such a log quarantines under
    \* SPEC 6.6 row 5 (beforeGenesis) forever.
    GenesisFirst == (rows # <<>>) => (Head(rows) = "genesis")

    \* SPEC 6.5: one generation per conversation. Not an A3 property — included
    \* because the reservation machinery is already modelled, so asking costs
    \* nothing, and because a fix that bought A3 by breaking single-flight
    \* would otherwise look like a success.
    SingleFlight ==
        Cardinality({ s \in Senders : pc[s] \in {"SCommit", "SRunning"} }) <= 1

    \* VACUITY CHECK, and it is meant to fail.
    \*
    \* A variant can pass by being inert: guard the append hard enough and no
    \* rows are ever written, which satisfies every safety property above while
    \* modelling a store that does nothing. Checking this as an invariant is how
    \* a passing run proves it still had something to get wrong — TLC must
    \* report it violated for *every* variant, including the two that otherwise
    \* pass. Never leave it in a config as a property you expect to hold.
    SanityAppendsHappen == Len(rows) <= 1
}

\* --------------------------------------------------------------------------
\* send / respond / regenerate: the generation starters.
\*
\* Real shape (ConversationStore.send -> generate -> run):
\*     let state = try await existingFold(of: conversation)   <- suspends
\*     try reserve(conversation)                              -- synchronous
\*     ... mint records ...                                   -- synchronous
\*     let tail = try await commit(records, to: conversation) <- suspends
\*     ... confirm(conversation, running: task) ...           -- synchronous
\* --------------------------------------------------------------------------
fair process (Sender \in Senders)
    \* The stale read. `existingFold` resolved this before the suspension;
    \* `reserve` acts on it after, and nothing re-checks in between.
    variables sawConv = FALSE;
{
  SLoad:
    sawConv := convExists;

  SReserve:
    \* ONE atomic region, and it must stay one: the staleness check, the
    \* tombstone check and the claim cannot be split by another task, because in
    \* Swift they are straight-line synchronous code inside `reserve`. Written as
    \* a single guarded claim rather than three early exits for a mechanical
    \* reason worth knowing: PlusCal demands a label after any statement
    \* following an `if` that contains a `goto`, and inserting those labels here
    \* would model three separately-interleavable steps — inventing a race the
    \* code does not have. When PlusCal asks for a label inside what should be
    \* one atomic region, restructure; never comply.
    if (/\ sawConv                                       \* stale: read pre-suspension
        /\ ~(Fix \in {"tombstone", "sticky"} /\ deleting) \* fresh: read here
        /\ live = "none")                                \* generationInFlight
    {
        live := "reserved";
    } else {
        goto SDone;
    };

  SCommit:
    \* The append transaction. After a DELETE this restarts numbering at 1,
    \* which is what makes the surviving rows genesis-less.
    \*
    \* "guard" models the defence at the write boundary instead of in memory:
    \* inside the same transaction that computes MAX(sequence)+1, refuse a batch
    \* that would be a conversation's first row without being its genesis. The
    \* attraction is that it does not depend on any interleaving — the write
    \* transaction is the one place where "does this conversation have rows" and
    \* "am I adding rows" are answered together, under SQLite's write lock.
    if (Fix = "guard" /\ rows = <<>>) {
        live := "none";      \* the throw; D24's rollback releases the slot
        goto SDone;
    } else {
        rows := rows \o <<"user", "start">>;
        live := "running";
    };

  SRunning:
    \* The generation runs and terminates; the slot is released.
    live := "none";

  SDone:
    skip;
}

\* --------------------------------------------------------------------------
\* deleteConversation.
\*
\* Real shape:
\*     _ = try await existingFold(of: conversation)           <- suspends
\*     cancelGeneration(in: conversation)                     -- synchronous
\*     await waitForStartToResolve(in: conversation)          <- suspends if reserved
\*     if case .running(_, let task) = live[conversation] {   -- ONE-SHOT check
\*         _ = try? await task.value                          <- suspends
\*     }
\*     try await persistence.deleteConversation(conversation) <- suspends
\* --------------------------------------------------------------------------
fair process (Deleter = "deleter")
{
  DMark:
    \* The tombstone is set synchronously at entry, before the first await.
    \* Placing it any later would leave the window it exists to close — though
    \* as the header records, placing it here does not close that window either.
    if (Fix \in {"tombstone", "sticky"}) { deleting := TRUE };

  DLoad:
    if (~convExists) { goto DDone };

  DCancel:
    skip;   \* cancelGeneration: synchronous, and a no-op when nothing is live.

  DWaitStart:
    \* Wait out a merely-*reserved* slot (the M5 audit's fix). Resolves when the
    \* start append confirms or rolls back, so it is bounded and needs no timeout.
    await live # "reserved";

  DWaitRunning:
    \* Deliberately ONE-SHOT, exactly as the code is: the running task's handle
    \* is captured at this instant. A generation that starts *after* this test
    \* is never waited on. That is A3.
    if (live = "running") { goto DWaitTask } else { goto DDelete };

  DWaitTask:
    await live # "running";

  DDelete:
    rows := <<>>;
    convExists := FALSE;

  DDone:
    \* "tombstone" clears on completion, as M7 Phase 0 specifies. "sticky" does
    \* not — the ID stays poisoned for the process's lifetime, which costs an
    \* unbounded set and buys the window that clearing re-opens.
    if (Fix = "tombstone") { deleting := FALSE };
}

} *)
\* BEGIN TRANSLATION (chksum(pcal) = "9b62146f" /\ chksum(tla) = "87c5b7a0")
VARIABLES convExists, rows, live, deleting, pc

(* define statement *)
NoOrphanRows == (~convExists) => (rows = <<>>)




GenesisFirst == (rows # <<>>) => (Head(rows) = "genesis")





SingleFlight ==
    Cardinality({ s \in Senders : pc[s] \in {"SCommit", "SRunning"} }) <= 1









SanityAppendsHappen == Len(rows) <= 1

VARIABLE sawConv

vars == << convExists, rows, live, deleting, pc, sawConv >>

ProcSet == (Senders) \cup {"deleter"}

Init == (* Global variables *)
        /\ convExists = TRUE
        /\ rows = <<"genesis">>
        /\ live = "none"
        /\ deleting = FALSE
        (* Process Sender *)
        /\ sawConv = [self \in Senders |-> FALSE]
        /\ pc = [self \in ProcSet |-> CASE self \in Senders -> "SLoad"
                                        [] self = "deleter" -> "DMark"]

SLoad(self) == /\ pc[self] = "SLoad"
               /\ sawConv' = [sawConv EXCEPT ![self] = convExists]
               /\ pc' = [pc EXCEPT ![self] = "SReserve"]
               /\ UNCHANGED << convExists, rows, live, deleting >>

SReserve(self) == /\ pc[self] = "SReserve"
                  /\ IF /\ sawConv[self]
                        /\ ~(Fix \in {"tombstone", "sticky"} /\ deleting)
                        /\ live = "none"
                        THEN /\ live' = "reserved"
                             /\ pc' = [pc EXCEPT ![self] = "SCommit"]
                        ELSE /\ pc' = [pc EXCEPT ![self] = "SDone"]
                             /\ live' = live
                  /\ UNCHANGED << convExists, rows, deleting, sawConv >>

SCommit(self) == /\ pc[self] = "SCommit"
                 /\ IF Fix = "guard" /\ rows = <<>>
                       THEN /\ live' = "none"
                            /\ pc' = [pc EXCEPT ![self] = "SDone"]
                            /\ rows' = rows
                       ELSE /\ rows' = rows \o <<"user", "start">>
                            /\ live' = "running"
                            /\ pc' = [pc EXCEPT ![self] = "SRunning"]
                 /\ UNCHANGED << convExists, deleting, sawConv >>

SRunning(self) == /\ pc[self] = "SRunning"
                  /\ live' = "none"
                  /\ pc' = [pc EXCEPT ![self] = "SDone"]
                  /\ UNCHANGED << convExists, rows, deleting, sawConv >>

SDone(self) == /\ pc[self] = "SDone"
               /\ TRUE
               /\ pc' = [pc EXCEPT ![self] = "Done"]
               /\ UNCHANGED << convExists, rows, live, deleting, sawConv >>

Sender(self) == SLoad(self) \/ SReserve(self) \/ SCommit(self)
                   \/ SRunning(self) \/ SDone(self)

DMark == /\ pc["deleter"] = "DMark"
         /\ IF Fix \in {"tombstone", "sticky"}
               THEN /\ deleting' = TRUE
               ELSE /\ TRUE
                    /\ UNCHANGED deleting
         /\ pc' = [pc EXCEPT !["deleter"] = "DLoad"]
         /\ UNCHANGED << convExists, rows, live, sawConv >>

DLoad == /\ pc["deleter"] = "DLoad"
         /\ IF ~convExists
               THEN /\ pc' = [pc EXCEPT !["deleter"] = "DDone"]
               ELSE /\ pc' = [pc EXCEPT !["deleter"] = "DCancel"]
         /\ UNCHANGED << convExists, rows, live, deleting, sawConv >>

DCancel == /\ pc["deleter"] = "DCancel"
           /\ TRUE
           /\ pc' = [pc EXCEPT !["deleter"] = "DWaitStart"]
           /\ UNCHANGED << convExists, rows, live, deleting, sawConv >>

DWaitStart == /\ pc["deleter"] = "DWaitStart"
              /\ live # "reserved"
              /\ pc' = [pc EXCEPT !["deleter"] = "DWaitRunning"]
              /\ UNCHANGED << convExists, rows, live, deleting, sawConv >>

DWaitRunning == /\ pc["deleter"] = "DWaitRunning"
                /\ IF live = "running"
                      THEN /\ pc' = [pc EXCEPT !["deleter"] = "DWaitTask"]
                      ELSE /\ pc' = [pc EXCEPT !["deleter"] = "DDelete"]
                /\ UNCHANGED << convExists, rows, live, deleting, sawConv >>

DWaitTask == /\ pc["deleter"] = "DWaitTask"
             /\ live # "running"
             /\ pc' = [pc EXCEPT !["deleter"] = "DDelete"]
             /\ UNCHANGED << convExists, rows, live, deleting, sawConv >>

DDelete == /\ pc["deleter"] = "DDelete"
           /\ rows' = <<>>
           /\ convExists' = FALSE
           /\ pc' = [pc EXCEPT !["deleter"] = "DDone"]
           /\ UNCHANGED << live, deleting, sawConv >>

DDone == /\ pc["deleter"] = "DDone"
         /\ IF Fix = "tombstone"
               THEN /\ deleting' = FALSE
               ELSE /\ TRUE
                    /\ UNCHANGED deleting
         /\ pc' = [pc EXCEPT !["deleter"] = "Done"]
         /\ UNCHANGED << convExists, rows, live, sawConv >>

Deleter == DMark \/ DLoad \/ DCancel \/ DWaitStart \/ DWaitRunning
              \/ DWaitTask \/ DDelete \/ DDone

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Deleter
           \/ (\E self \in Senders: Sender(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Senders : WF_vars(Sender(self))
        /\ WF_vars(Deleter)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION 
=============================================================================
