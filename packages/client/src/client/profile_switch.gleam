//// The seam through which a session's hub switches its own model role profile
//// (protocol-change/082).
////
//// A profile is a name the daemon stores with a session's registration and
//// resolves again every time the session opens. The hub is part of one opened
//// session and holds neither the configuration file nor the catalogue of
//// registrations, so everything a switch needs from outside it arrives as the
//// four closures of a `Desk`, supplied by the daemon when it builds the
//// session. A session with no daemon behind it (`loomd --session`) has no
//// desk, and its hub refuses `profile_get` and `profile_set` in words.
////
//// ## The four closures, in the order a switch calls them
////
//// 1. `names` reads the configuration as it stands now and returns the profile
////    names it defines. `profile_get` calls it, so the list is never older than
////    the request.
//// 2. `load` reads the configuration once more with a profile applied and
////    returns the resulting catalogue, or the daemon's refusal naming the
////    profiles that exist. The hub compares it with its own catalogue
////    (`catalog.retargets`) to decide which strands move.
//// 3. `save` writes the choice to the session's registration. It runs before
////    any strand moves, so a refusal leaves the session exactly as it was.
//// 4. `restart` begins stopping and reopening the session, which is how the new
////    profile's gateway, advisor and subagent routes are built. It returns at
////    once: the work runs in a process the session does not own, because the
////    stop ends the session.
////
//// ## Why a restart
////
//// Everything that reads a role is built once when a session opens: the
//// provider gateway's chains, the subagent route a child strand is seeded
//// from, the summarizer and block-summary routes, and whether an advisor
//// exists at all. A profile can add an advisor that the default roles lack, so
//// swapping the gateway under a live session could not give the new profile its
//// advisor. Opening the session again builds every one of them from the stored
//// profile, by the one path that already resolves a profile.

import client/catalog
import gleam/option.{type Option}

/// What a hub needs from the daemon to read and switch its session's profile.
///
/// Constructor invariants: every closure may block for the duration of a file
/// read or a registry call, and none is called from anywhere but the hub's own
/// process. `current` is the profile the session was opened under, and the hub
/// replaces it after a switch so a second `profile_get` before the restart
/// completes reports the saved profile.
pub type Desk {
  Desk(
    /// The profile the session routes its roles by, or `None` for the
    /// configuration's default roles.
    current: Option(String),
    /// The profile names the configuration defines now, sorted, or why the
    /// configuration cannot be read.
    names: fn() -> Result(List(String), String),
    /// The catalogue that choosing this profile (`None` for the default roles)
    /// would route by, or the worded refusal: an unknown name lists the ones
    /// that exist, and an unreadable configuration says so.
    load: fn(Option(String)) -> Result(catalog.Catalog, String),
    /// Stores the choice with the session's registration, so the next open
    /// resolves it.
    save: fn(Option(String)) -> Result(Nil, String),
    /// Starts stopping and reopening the session, and returns at once.
    restart: fn() -> Nil,
  )
}
