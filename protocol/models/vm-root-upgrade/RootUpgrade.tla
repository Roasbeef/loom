---------------------------- MODULE RootUpgrade ----------------------------
(***************************************************************************)
(* The upgrade in place of a microVM guest's kept root, as `loom vm up`    *)
(* performs it when the root was cloned from other artifacts than the      *)
(* manifest names (docs/architecture/microvm.md, "A kept root after a loom *)
(* upgrade"). The code is `vm_spec.root_step`, and `prepare_root`,         *)
(* `build_next_root`, `upgrade_steps`, `swap_roots` and `stage` in         *)
(* packages/client/src/client/vm_cli.gleam.                                *)
(*                                                                         *)
(* The model asks three questions. Can a stop of `up` at any step, followed*)
(* by another `up`, lose the workspaces the agent edited? Can a guest boot *)
(* on a root that is not the manifest's, or that lacks the workspaces? And *)
(* does `up` always finish once it stops being interrupted?                *)
(*                                                                         *)
(* It asks them of two starting points, chosen by the constant Scenario:   *)
(* "kept", a guest that ran on the old build and whose root holds the      *)
(* workspaces, and "first", a guest that has never been up, whose first    *)
(* `up` clones the export and then copies the workspace in. The second     *)
(* found a fault in the code as it was: the first clone was made in place, *)
(* so a stop during it, or between it and the workspace copy, left a root  *)
(* that every later `up` refused to upgrade for want of an srv/workspaces. *)
(*                                                                         *)
(* The disk is five facts: what `root` holds, what `root.building` and     *)
(* `root.next` hold, whether each of those two has an `srv/workspaces`     *)
(* directory and whose it is, where the real workspaces are, and what the  *)
(* host's `root-revision` record says. `up` is one process whose program   *)
(* counter is lost by a stop; the disk is all the next `up` sees.          *)
(*                                                                         *)
(* It does not model `--fresh`, which discards the root on purpose, the    *)
(* provisioning script, whose retry is decided from the host's own copy,   *)
(* or a guest that plants a link in its root, which `plain_chain` refuses  *)
(* before any step here runs.                                              *)
(*                                                                         *)
(* Seven constants switch a rule off so that its mutation can be checked. A*)
(* clean run sets all seven to TRUE. Each Mutant*.cfg sets one to FALSE and*)
(* names the property the checker must then violate. Dev makes the manifest*)
(* a development tree's, under which `up` keeps any root it finds.         *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    BuildAside,     \* The export is cloned as root.building, not root.next.
    ClearSlot,      \* The clone's own srv/workspaces is removed before use.
    NameBeforeMove, \* The clone is named root.next before the workspaces move.
    MovedFirst,     \* root_step reads root.next's workspaces before `root`.
    RecordLast,     \* root-revision is written after the root is in place.
    CloneAside,     \* A first clone is made as root.building, then renamed.
    CarryNothing,   \* A root with no workspace copy is upgraded without a move.
    Dev,            \* The manifest is a development tree's.
    Scenario,       \* "kept" or "first".
    ExportShipsWs,  \* The exported guest root carries an srv/workspaces.
    MaxCrashes      \* Bound on stops of `up` in one behaviour.

VARIABLES
    root,      \* `root`: "none", "old", "wreck" (partly deleted) or "new".
    building,  \* `root.building`: "none", "part" (clone unfinished), "whole".
    bslot,     \* `root.building/srv/workspaces`: "none", "junk" or "real".
    next,      \* `root.next`: "none", "part" or "whole".
    nslot,     \* `root.next/srv/workspaces`: "none", "junk" or "real".
    ws,        \* Where the real workspaces are: "root", "building", "next",
               \* "gone", or "unmade" before the first copy into the root.
    record,    \* The root-revision record: "old" or "new".
    pc,        \* Where `up` is, or "idle", "refused" or "booted".
    crashes    \* Stops of `up` so far.

vars == <<root, building, bslot, next, nslot, ws, record, pc, crashes>>

Running == pc \notin {"idle", "refused", "booted"}

TypeOK ==
    /\ root \in {"none", "old", "wreck", "new"}
    /\ building \in {"none", "part", "whole"}
    /\ bslot \in {"none", "junk", "real"}
    /\ next \in {"none", "part", "whole"}
    /\ nslot \in {"none", "junk", "real"}
    /\ ws \in {"root", "building", "next", "gone", "unmade"}
    /\ record \in {"old", "new"}
    /\ pc \in {"idle", "decide", "clone", "clone2", "clone3", "check",
               "rmnext", "rmbuild", "cp", "cp2", "clear", "name", "move",
               "rm", "rm2", "swap", "record", "copy", "boot", "refused",
               "booted"}
    /\ crashes \in 0..MaxCrashes

(***************************************************************************)
(* "kept": a guest that ran on the old build. Its root holds the           *)
(* workspaces and the record names the old revision; the manifest names    *)
(* the new one. "first": no root, no record (which reads as old), and the  *)
(* developer's workspace not yet copied in.                                *)
(***************************************************************************)
Init ==
    /\ root = IF Scenario = "kept" THEN "old" ELSE "none"
    /\ building = "none" /\ bslot = "none"
    /\ next = "none" /\ nslot = "none"
    /\ ws = IF Scenario = "kept" THEN "root" ELSE "unmade"
    /\ record = "old"
    /\ pc = "idle"
    /\ crashes = 0

(***************************************************************************)
(* The developer runs `up`, the first time or again after a stop or a      *)
(* refusal.                                                                *)
(***************************************************************************)
Start ==
    /\ pc \in {"idle", "refused"}
    /\ pc' = "decide"
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, record, crashes>>

(***************************************************************************)
(* `vm_spec.root_step`. `moved` is the presence of root.next/srv/workspaces*)
(* as lstat sees it, whoever put it there. With RecordLast off the record  *)
(* is written here, before the root it describes exists.                   *)
(***************************************************************************)
Moved == next # "none" /\ nslot # "none"

Stale == ~Dev /\ record = "old"

StepOf ==
    IF MovedFirst
    THEN IF Moved THEN "finish"
         ELSE IF root = "none" THEN "clone"
         ELSE IF Stale THEN "upgrade" ELSE "keep"
    ELSE IF root = "none" THEN "clone"
         ELSE IF Moved THEN "finish"
         ELSE IF Stale THEN "upgrade" ELSE "keep"

Decide ==
    /\ pc = "decide"
    /\ pc' = CASE StepOf = "finish" -> "rm"
               [] StepOf = "clone" -> "clone"
               [] StepOf = "upgrade" -> "check"
               [] StepOf = "keep" -> "copy"
    /\ record' = IF ~RecordLast /\ StepOf # "keep" THEN "new" ELSE record
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, crashes>>

(***************************************************************************)
(* What a clone of the export has at srv/workspaces: the export's own      *)
(* directory when it ships one, and possibly not yet during the copy.      *)
(***************************************************************************)
ShippedSoFar == IF ExportShipsWs THEN {"none", "junk"} ELSE {"none"}
Shipped == IF ExportShipsWs THEN "junk" ELSE "none"

(***************************************************************************)
(* CloneRoot, `replace_root`: `root` is missing, so the leftovers are      *)
(* removed and the export is cloned. The clone is not atomic. With         *)
(* CloneAside it is made as root.building and renamed, so a `root` that    *)
(* exists is whole; without it the copy is made in place and a stop leaves *)
(* part of a root. It brings no workspaces of the developer's.             *)
(***************************************************************************)
CloneBegin ==
    /\ pc = "clone"
    /\ next' = "none" /\ nslot' = "none"
    /\ IF CloneAside
       THEN /\ building' = "part" /\ bslot' \in ShippedSoFar
            /\ UNCHANGED root
       ELSE /\ building' = "none" /\ bslot' = "none"
            /\ root' = "wreck"
    /\ ws' = IF ws \in {"next", "building"} THEN "gone" ELSE ws
    /\ pc' = "clone2"
    /\ UNCHANGED <<record, crashes>>

CloneEnd ==
    /\ pc = "clone2"
    /\ IF CloneAside
       THEN /\ building' = "whole" /\ bslot' = Shipped
            /\ UNCHANGED root
            /\ pc' = "clone3"
       ELSE /\ root' = "new"
            /\ UNCHANGED <<building, bslot>>
            /\ pc' = "record"
    /\ UNCHANGED <<next, nslot, ws, record, crashes>>

CloneName ==
    /\ pc = "clone3"
    /\ root' = "new"
    /\ building' = "none" /\ bslot' = "none"
    /\ pc' = "record"
    /\ UNCHANGED <<next, nslot, ws, record, crashes>>

(***************************************************************************)
(* `build_next_root`. It first decides what the old root carries over     *)
(* (`vm_spec.carry_over`): workspaces in a real root/srv/workspaces move;  *)
(* a root the host never copied a workspace into carries nothing, when     *)
(* CarryNothing is on; anything else is refused. It then removes the       *)
(* leftovers of an earlier attempt, clones the export, and runs            *)
(* `upgrade_steps`. The clone is not atomic: a stop leaves part of it,     *)
(* which may or may not include the export's own srv/workspaces.           *)
(***************************************************************************)
Carries == ws = "root" /\ root \in {"old", "new"}

Check ==
    /\ pc = "check"
    /\ pc' = IF Carries \/ (CarryNothing /\ ws = "unmade") THEN "rmnext"
             ELSE "refused"
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, record, crashes>>

RemoveNext ==
    /\ pc = "rmnext"
    /\ next' = "none" /\ nslot' = "none"
    /\ ws' = IF ws = "next" THEN "gone" ELSE ws
    /\ pc' = "rmbuild"
    /\ UNCHANGED <<root, building, bslot, record, crashes>>

RemoveBuilding ==
    /\ pc = "rmbuild"
    /\ building' = "none" /\ bslot' = "none"
    /\ ws' = IF ws = "building" THEN "gone" ELSE ws
    /\ pc' = "cp"
    /\ UNCHANGED <<root, next, nslot, record, crashes>>

CopyBegin ==
    /\ pc = "cp"
    /\ IF BuildAside
       THEN /\ building' = "part" /\ bslot' \in ShippedSoFar
            /\ UNCHANGED <<next, nslot>>
       ELSE /\ next' = "part" /\ nslot' \in ShippedSoFar
            /\ UNCHANGED <<building, bslot>>
    /\ pc' = "cp2"
    /\ UNCHANGED <<root, ws, record, crashes>>

CopyEnd ==
    /\ pc = "cp2"
    /\ IF BuildAside
       THEN /\ building' = "whole" /\ bslot' = Shipped
            /\ UNCHANGED <<next, nslot>>
       ELSE /\ next' = "whole" /\ nslot' = Shipped
            /\ UNCHANGED <<building, bslot>>
    /\ pc' = "clear"
    /\ UNCHANGED <<root, ws, record, crashes>>

(***************************************************************************)
(* `clear_workspaces_slot`: the clone's own srv/workspaces is removed, so  *)
(* that directory in root.next can only mean the real ones moved.          *)
(***************************************************************************)
Clear ==
    /\ pc = "clear"
    /\ IF BuildAside
       THEN /\ bslot' = IF ClearSlot THEN "none" ELSE bslot
            /\ UNCHANGED nslot
       ELSE /\ nslot' = IF ClearSlot THEN "none" ELSE nslot
            /\ UNCHANGED bslot
    /\ pc' = IF BuildAside /\ (NameBeforeMove \/ ws # "root") THEN "name"
             ELSE IF ws = "root" THEN "move" ELSE "rm"
    /\ UNCHANGED <<root, building, next, ws, record, crashes>>

(***************************************************************************)
(* rename(root.building, root.next).                                       *)
(***************************************************************************)
Name ==
    /\ pc = "name"
    /\ next' = building /\ nslot' = bslot
    /\ building' = "none" /\ bslot' = "none"
    /\ ws' = IF ws = "building" THEN "next" ELSE ws
    /\ pc' = IF NameBeforeMove /\ ws = "root" THEN "move" ELSE "rm"
    /\ UNCHANGED <<root, record, crashes>>

(***************************************************************************)
(* rename(root/srv/workspaces, <new root>/srv/workspaces): the one step    *)
(* that moves the workspaces. With NameBeforeMove off the new root is      *)
(* still root.building when they move into it.                             *)
(***************************************************************************)
Move ==
    /\ pc = "move"
    /\ IF BuildAside /\ ~NameBeforeMove
       THEN /\ bslot' = "real" /\ ws' = "building"
            /\ UNCHANGED nslot
            /\ pc' = "name"
       ELSE /\ nslot' = "real" /\ ws' = "next"
            /\ UNCHANGED bslot
            /\ pc' = "rm"
    /\ UNCHANGED <<root, building, next, record, crashes>>

(***************************************************************************)
(* `swap_roots`: delete the old root, which is not atomic, then            *)
(* rename(root.next, root). Deleting a root that still holds the           *)
(* workspaces destroys them.                                               *)
(***************************************************************************)
RemoveRootBegin ==
    /\ pc = "rm"
    /\ root' = IF root = "none" THEN "none" ELSE "wreck"
    /\ ws' = IF ws = "root" THEN "gone" ELSE ws
    /\ pc' = "rm2"
    /\ UNCHANGED <<building, bslot, next, nslot, record, crashes>>

RemoveRootEnd ==
    /\ pc = "rm2"
    /\ root' = "none"
    /\ pc' = "swap"
    /\ UNCHANGED <<building, bslot, next, nslot, ws, record, crashes>>

Swap ==
    /\ pc = "swap"
    /\ root' = IF next = "whole" THEN "new" ELSE "wreck"
    /\ ws' = IF ws = "next" THEN "root" ELSE ws
    /\ next' = "none" /\ nslot' = "none"
    /\ pc' = "record"
    /\ UNCHANGED <<building, bslot, record, crashes>>

(***************************************************************************)
(* `stage` records the revision after the root is in place, copies the     *)
(* developer's workspace into the root unless a copy is there, and then    *)
(* the guest boots on `root`.                                              *)
(***************************************************************************)
Record ==
    /\ pc = "record"
    /\ record' = "new"
    /\ pc' = "copy"
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, crashes>>

CopyWorkspace ==
    /\ pc = "copy"
    /\ ws' = IF ws = "unmade" /\ root # "none" THEN "root" ELSE ws
    /\ pc' = "boot"
    /\ UNCHANGED <<root, building, bslot, next, nslot, record, crashes>>

Boot ==
    /\ pc = "boot"
    /\ pc' = "booted"
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, record, crashes>>

(***************************************************************************)
(* `up` is stopped: the process and its place are lost, the disk stays.    *)
(***************************************************************************)
Crash ==
    /\ Running
    /\ crashes < MaxCrashes
    /\ crashes' = crashes + 1
    /\ pc' = "idle"
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, record>>

Up ==
    \/ Start \/ Decide \/ CloneBegin \/ CloneEnd \/ CloneName \/ Check
    \/ RemoveNext \/ RemoveBuilding \/ CopyBegin \/ CopyEnd \/ Clear \/ Name
    \/ Move \/ RemoveRootBegin \/ RemoveRootEnd \/ Swap \/ Record
    \/ CopyWorkspace \/ Boot

Next == Up \/ Crash

Spec == Init /\ [][Next]_vars /\ WF_vars(Up)

(***************************************************************************)
(* The workspaces exist somewhere on disk in every state.                  *)
(***************************************************************************)
WorkspacesKept == ws # "gone"

(***************************************************************************)
(* A guest boots only on a whole root that holds the workspaces, and that  *)
(* root is cloned from the manifest's artifacts unless the manifest is a   *)
(* development tree's, which keeps a whole old root on purpose.            *)
(***************************************************************************)
BootedRight ==
    pc = "booted" =>
        /\ ws = "root"
        /\ root = "new" \/ (Dev /\ root = "old")

(***************************************************************************)
(* An srv/workspaces in root.next is always the real one, which is what    *)
(* lets root_step read its presence as a finished move.                    *)
(***************************************************************************)
MovedIsReal == Moved => nslot = "real"

(***************************************************************************)
(* Once `up` stops being interrupted, it boots the guest.                  *)
(***************************************************************************)
Converges == <>(pc = "booted")

=============================================================================
