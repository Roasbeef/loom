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
(* It asks them of three starting points, chosen by the constant Scenario: *)
(* "kept", a guest that ran on the old build and whose root holds the      *)
(* workspaces; "first", a guest that has never been up, whose first `up`   *)
(* clones the export and then copies the workspace in; and "fresh", a      *)
(* guest on the current build whose developer runs `up --fresh` and, after *)
(* a stop, may run `up` with or without the flag. The second found a fault *)
(* in the code as it was: the first clone was made in place, so a stop     *)
(* during it, or between it and the workspace copy, left a root that every *)
(* later `up` refused to upgrade for want of an srv/workspaces. The third  *)
(* found another: `--fresh` deleted the old root in place, so a stop       *)
(* during the delete left part of a root under a record that still matched,*)
(* and a plain `up` kept and booted it.                                    *)
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
(* Nine constants switch a rule off so that its mutation can be checked. A *)
(* clean run sets all nine to TRUE. Each Mutant*.cfg sets one to FALSE and *)
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
    CarryNothing,   \* A root with no workspace copy is cloned again, not refused.
    SetAside,       \* An old root is renamed away before it is deleted.
    CopyAside,      \* A workspace copy is made beside the root, then renamed in.
    Dev,            \* The manifest is a development tree's.
    Scenario,       \* "kept", "first" or "fresh".
    ExportShipsWs,  \* The exported guest root carries an srv/workspaces.
    MaxCrashes      \* Bound on stops of `up` in one behaviour.

VARIABLES
    root,      \* `root`: "none", "old", "wreck" (partly deleted) or "new".
    building,  \* `root.building`: "none", "part" (clone unfinished), "whole".
    bslot,     \* `root.building/srv/workspaces`: "none", "junk" or "real".
    next,      \* `root.next`: "none", "part" or "whole".
    nslot,     \* `root.next/srv/workspaces`: "none", "junk" or "real".
    ws,        \* Where the real workspaces are: "root", "building", "next",
               \* "gone", "unmade" before the first copy into the root, or
               \* "half" for a copy in the root that was stopped partway.
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
    /\ ws \in {"root", "building", "next", "gone", "unmade", "half"}
    /\ record \in {"old", "new"}
    /\ pc \in {"idle", "decide", "freshly", "clone", "clonerm", "clone1",
               "clone2", "clone3", "check",
               "rmnext", "rmbuild", "cp", "cp2", "clear", "name", "move",
               "rm", "rm2", "swap", "record", "copy", "copy2", "boot", "refused",
               "booted"}
    /\ crashes \in 0..MaxCrashes

(***************************************************************************)
(* "kept": a guest that ran on the old build. Its root holds the           *)
(* workspaces and the record names the old revision; the manifest names    *)
(* the new one. "first": no root, the developer's workspace not yet copied *)
(* in, and either record, since a root can be missing under a record that  *)
(* matches. "fresh": a whole root of the current build under a matching    *)
(* record; the workspace copy `--fresh` discards on purpose is not counted,*)
(* so the workspace starts as not yet copied in.                           *)
(***************************************************************************)
Init ==
    /\ root = CASE Scenario = "kept" -> "old"
                [] Scenario = "first" -> "none"
                [] Scenario = "fresh" -> "new"
    /\ building = "none" /\ bslot = "none"
    /\ next = "none" /\ nslot = "none"
    /\ ws = IF Scenario = "kept" THEN "root" ELSE "unmade"
    /\ record \in CASE Scenario = "kept" -> {"old"}
                    [] Scenario = "first" -> {"old", "new"}
                    [] Scenario = "fresh" -> {"new"}
    /\ pc = "idle"
    /\ crashes = 0

(***************************************************************************)
(* The developer runs `up`, the first time or again after a stop or a      *)
(* refusal. In the "fresh" scenario the first run carries `--fresh`, and a *)
(* later one may or may not.                                               *)
(***************************************************************************)
Start ==
    /\ pc \in {"idle", "refused"}
    /\ pc' \in CASE Scenario # "fresh" -> {"decide"}
                 [] Scenario = "fresh" /\ crashes = 0 -> {"freshly"}
                 [] Scenario = "fresh" /\ crashes > 0 -> {"decide", "freshly"}
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, record, crashes>>

(***************************************************************************)
(* `--fresh`: root_step answers CloneRoot whatever the disk holds.         *)
(***************************************************************************)
DecideFresh ==
    /\ pc = "freshly"
    /\ pc' = "clone"
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
(* CloneRoot, `replace_root`. The leftovers are removed, an old root is    *)
(* removed, and the export is cloned. Neither the delete nor the clone is  *)
(* atomic. With SetAside the old root is renamed away first, so the name   *)
(* `root` is gone in one step; without it a stop leaves part of a root.    *)
(* With CloneAside the clone is made as root.building and renamed, so a    *)
(* `root` that exists is whole; without it the copy is made in place. The  *)
(* clone brings no workspaces of the developer's. A copy in the root that  *)
(* `--fresh` replaces is discarded on purpose and is copied in again; any  *)
(* other root that still holds the workspaces must never reach this step.  *)
(***************************************************************************)
CloneBegin ==
    /\ pc = "clone"
    /\ next' = "none" /\ nslot' = "none"
    /\ building' = "none" /\ bslot' = "none"
    /\ root' = IF root = "none" \/ SetAside THEN "none" ELSE "wreck"
    /\ ws' = CASE ws \in {"next", "building"} -> "gone"
               [] ws \in {"root", "half"} /\ Scenario = "fresh" -> "unmade"
               [] ws \in {"root", "half"} /\ Scenario # "fresh" -> "gone"
               [] OTHER -> ws
    /\ pc' = IF root = "none" \/ SetAside THEN "clone1" ELSE "clonerm"
    /\ UNCHANGED <<record, crashes>>

CloneRemoveEnd ==
    /\ pc = "clonerm"
    /\ root' = "none"
    /\ pc' = "clone1"
    /\ UNCHANGED <<building, bslot, next, nslot, ws, record, crashes>>

CloneCopyBegin ==
    /\ pc = "clone1"
    /\ IF CloneAside
       THEN /\ building' = "part" /\ bslot' \in ShippedSoFar
            /\ UNCHANGED root
       ELSE /\ root' = "wreck"
            /\ UNCHANGED <<building, bslot>>
    /\ pc' = "clone2"
    /\ UNCHANGED <<next, nslot, ws, record, crashes>>

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
(* a root the host never copied a workspace into carries nothing and is    *)
(* cloned again as a first root is, when CarryNothing is on; anything else *)
(* is refused. For workspaces that move it then removes the leftovers of   *)
(* an earlier attempt, clones the export, and runs `upgrade_steps`. The    *)
(* clone is not atomic: a stop leaves part of it, which may or may not     *)
(* include the export's own srv/workspaces.                                *)
(***************************************************************************)
Carries == ws = "root" /\ root \in {"old", "new"}

Check ==
    /\ pc = "check"
    /\ pc' = IF Carries THEN "rmnext"
             ELSE IF CarryNothing /\ ws = "unmade" THEN "clone"
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
    /\ pc' = IF BuildAside /\ NameBeforeMove THEN "name" ELSE "move"
    /\ UNCHANGED <<root, building, next, ws, record, crashes>>

(***************************************************************************)
(* rename(root.building, root.next).                                       *)
(***************************************************************************)
Name ==
    /\ pc = "name"
    /\ next' = building /\ nslot' = bslot
    /\ building' = "none" /\ bslot' = "none"
    /\ ws' = IF ws = "building" THEN "next" ELSE ws
    /\ pc' = IF NameBeforeMove THEN "move" ELSE "rm"
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
(* the guest boots on `root`. With CopyAside the copy is made beside the   *)
(* root and renamed in, so a copy that is there is whole; without it the   *)
(* copy is made at its final name, and a stop leaves half of one that the  *)
(* next `up` keeps because a copy is there.                                *)
(***************************************************************************)
Record ==
    /\ pc = "record"
    /\ record' = "new"
    /\ pc' = "copy"
    /\ UNCHANGED <<root, building, bslot, next, nslot, ws, crashes>>

CopyWorkspace ==
    /\ pc = "copy"
    /\ IF ws = "unmade" /\ root # "none"
       THEN IF CopyAside
            THEN ws' = "root" /\ pc' = "boot"
            ELSE ws' = "half" /\ pc' = "copy2"
       ELSE ws' = ws /\ pc' = "boot"
    /\ UNCHANGED <<root, building, bslot, next, nslot, record, crashes>>

CopyWorkspaceEnd ==
    /\ pc = "copy2"
    /\ ws' = "root"
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
    \/ Start \/ Decide \/ DecideFresh \/ CloneBegin \/ CloneRemoveEnd
    \/ CloneCopyBegin \/ CloneEnd \/ CloneName \/ Check
    \/ RemoveNext \/ RemoveBuilding \/ CopyBegin \/ CopyEnd \/ Clear \/ Name
    \/ Move \/ RemoveRootBegin \/ RemoveRootEnd \/ Swap \/ Record
    \/ CopyWorkspace \/ CopyWorkspaceEnd \/ Boot

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
