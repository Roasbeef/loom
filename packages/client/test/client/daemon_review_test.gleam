//// The daemon's review read over a real registry, a real catalogue and real
//// resident sessions (protocol-change/123): `sessions.review` on the control
//// socket, and the door a home page reads through.
////
//// The observation itself is a stand-in here: a resident's own closure that
//// answers a board as the worktree capture encodes it, so what these tests pin
//// is the daemon's part. Who may read, from which authority, when the session
//// is saved or its observation fails, and that a failure's words never reach the
//// caller.

import client/daemon/attention_door.{Refusal}
import client/daemon/limits
import client/daemon/manager
import client/daemon/review_door.{Reach}
import client/daemon_server_test.{connect, frame, send}
import client/deployment
import client/session_directory
import client/session_movers
import core/agency_limits
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import storage/access
import storage/catalogue
import support/internal/ffi_ws
import web_view/review_feed
import weft/poll

const now = 1_790_000_000_000

const patch =
  "diff --git a/src/a.gleam b/src/a.gleam
--- a/src/a.gleam
+++ b/src/a.gleam
@@ -1,2 +1,2 @@
 keep
-old
+new
"

/// What a failing observation says. It is a repository's own words, and no
/// caller may learn it.
const secret = "fatal: /home/someone/secret-repo is not here"

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "an object"
  let assert Ok(found) = list.key_find(fields, key) as "the field is present"
  found
}

fn body(reply: JsonValue, key: String) -> JsonValue {
  field(field(reply, "body"), key)
}

fn code(reply: JsonValue) -> JsonValue {
  body(reply, "code")
}

fn digest_of(token: String) -> access.Digest {
  let assert Ok(digest) =
    token
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
    |> access.credential_digest
    as "the digest is valid"
  digest
}

/// A file entry as the capture encodes it.
fn entry(
  path: String,
  status: String,
  kind: String,
  body: String,
) -> JsonValue {
  json.Object([
    #("path", json.String(path)),
    #("index_status", json.String(" ")),
    #("worktree_status", json.String(status)),
    #("patch", json.String(body)),
    #("kind", json.String(kind)),
    #("extent", json.String("complete")),
  ])
}

/// A board as `worktree_diff.to_json` encodes one: a source file, its test, a
/// document and a binary file.
fn board() -> JsonValue {
  json.Object([
    #("source", json.String("git")),
    #(
      "committed",
      json.Object([
        #("message", json.String("")),
        #("patch", json.String("")),
        #("extent", json.String("complete")),
      ]),
    ),
    #("observed_at_ms", json.Int(now)),
    #("repository", json.String("head")),
    #(
      "entries",
      json.Array([
        entry("docs/next.md", "M", "text", patch),
        entry("src/a_test.gleam", "M", "text", patch),
        entry("assets/logo.png", "?", "binary", "Binary files differ"),
        entry("src/a.gleam", "M", "text", patch),
      ]),
    ),
    #("total", json.Int(4)),
    #("omitted", json.Int(0)),
    #("extent", json.String("complete")),
  ])
}

type Rig {
  Rig(
    good: String,
    broken: String,
    unknown: String,
    state_root: String,
    reach: fn(access.Digest, fn() -> Result(Nil, Nil)) ->
      review_door.Reach(String),
  )
}

/// Runs `check` against a daemon with two resident sessions, one whose
/// observation answers a board and one whose observation fails, and an
/// identity that names no session.
fn with_rig(
  check: fn(manager.Manager(String), Int, String, String, Rig) -> Nil,
) -> Nil {
  let #(a, _) = ids.mint_session(ids.generator(clock.fixed(0), 911))
  let #(b, _) = ids.mint_session(ids.generator(clock.fixed(0), 912))
  let #(d, _) = ids.mint_session(ids.generator(clock.fixed(0), 914))
  let good = ids.session_id_to_string(a)
  let broken = ids.session_id_to_string(b)
  let unknown = ids.session_id_to_string(d)
  let worktree = fn(instance: String) {
    case instance == good, instance == broken {
      True, _ -> Some(fn() { Ok(board()) })
      _, True -> Some(fn() { Error(secret) })
      False, False -> None
    }
  }
  daemon_server_test.fixture_observing(
    limits.defaults,
    fn(_) { None },
    worktree,
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    deployment.alone("nonode@nohost"),
    None,
    None,
    fn(_, ready, port, credential) {
      list.each([#(good, 911), #(broken, 912)], fn(pair) {
        let assert Ok(_) =
          manager.create(
            ready.registry,
            manager.Creation(
              pair.0,
              ready.state_root,
              pair.0,
              "",
              None,
              None,
              "",
              "",
              agency_limits.empty,
            ),
            directory: ready.sessions_directory,
            generator: ids.generator(clock.fixed(0), pair.1),
          )
          as "the session is created"
        let assert poll.Answered(_) =
          poll.until(within: 2000, every: 1, attempt: fn() {
            case manager.resolve(ready.registry, pair.0) {
              Ok(instance) -> poll.Done(instance)
              Error(_) -> poll.Retry
            }
          })
          as "the session becomes resident"
        Nil
      })
      check(
        ready.registry,
        port,
        credential,
        ready.epoch,
        Rig(
          good:,
          broken:,
          unknown:,
          state_root: ready.state_root,
          reach: fn(digest, reserve) {
            Reach(
              registry: ready.registry,
              digest:,
              observe: worktree,
              reserve:,
            )
          },
        ),
      )
    },
  )
}

fn review(socket, id: Int, session: String, epoch: String) -> JsonValue {
  send(
    socket,
    id,
    "sessions.review",
    json.Object([
      #("session", json.String(session)),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 10_000,
  )
}

fn open() -> Result(Nil, Nil) {
  Ok(Nil)
}

fn paths(reply: JsonValue) -> List(String) {
  let assert json.Array(files) = body(reply, "files") as "the files"
  list.map(files, fn(file) {
    let assert json.String(path) = field(file, "path")
    path
  })
}

// --- the control command -------------------------------------------------------

pub fn the_owner_reads_a_review_in_reading_order_test() {
  with_rig(fn(_registry, port, credential, epoch, rig) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let reply = review(socket, 1, rig.good, epoch)

    assert field(reply, "event") == json.String("sessions.review")
    assert paths(reply)
      == ["assets/logo.png", "src/a.gleam", "src/a_test.gleam", "docs/next.md"]
    assert body(reply, "repository") == json.String("head")
    assert field(body(reply, "stat"), "files") == json.Int(4)
    assert field(body(reply, "stat"), "added") == json.Int(3)
    assert body(reply, "extent") == json.String("whole")

    // The reply is a review the page's decoder reads whole.
    let assert Ok(decoded) = review_feed.decode(field(reply, "body"))
    assert decoded.omitted == 0
    let assert [logo, source, ..] = decoded.files
    assert logo.content == review_feed.Binary
    assert logo.hunks == []
    assert source.path == "src/a.gleam"
    assert list.length(source.hunks) == 1

    // An old epoch is refused before anything is read.
    let stale = review(socket, 2, rig.good, "previous-epoch")
    assert code(stale) == json.String("stale_epoch")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn an_unreadable_workspace_and_a_missing_one_are_refused_in_fixed_words_test() {
  with_rig(fn(_registry, port, credential, epoch, rig) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)

    // A resident whose observation failed says only that it could not be read.
    let failed = review(socket, 1, rig.broken, epoch)
    assert code(failed) == json.String("unavailable")
    assert !string.contains(string.inspect(failed), "secret-repo")

    // An identity the catalogue does not hold is an unknown session.
    assert code(review(socket, 3, rig.unknown, epoch))
      == json.String("not_found")
    assert code(review(socket, 4, "not-a-session", epoch))
      == json.String("bad_request")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_saved_session_is_not_read_test() {
  with_rig(fn(registry, port, credential, epoch, rig) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let _ =
      send(
        socket,
        1,
        "sessions.stop",
        json.Object([
          #("session_id", json.String(rig.good)),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    let assert poll.Answered(Nil) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(registry, rig.good) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "the session becomes saved"

    assert code(review(socket, 2, rig.good, epoch))
      == json.String("not_resident")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

// --- authority -----------------------------------------------------------------

pub fn members_read_by_their_membership_and_bystanders_see_nothing_test() {
  with_rig(fn(_registry, port, _credential, epoch, rig) {
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let member = fn(name, token, role: Option(access.Role)) {
      let assert Ok(principal) =
        access.create_member(store, name, name, digest_of(token))
        as "the member exists"
      case role {
        Some(held) -> {
          let assert Ok(Nil) = access.grant(store, principal.id, rig.good, held)
          Nil
        }
        None -> Nil
      }
    }
    let operator = string.repeat("4", 64)
    let observer = string.repeat("5", 64)
    let bystander = string.repeat("6", 64)
    member("rev-operator", operator, Some(access.Operator))
    member("rev-observer", observer, Some(access.Observer))
    member("rev-bystander", bystander, None)

    // An operator and an observer both read: the design lets an observer see a
    // thread, and a review is its body.
    list.each([operator, observer], fn(token) {
      let #(socket, _) = connect(port, token, "/v2/control")
      let _ = frame(socket, within_ms: 1000)
      let reply = review(socket, 1, rig.good, epoch)
      assert field(reply, "event") == json.String("sessions.review")
      let _ = ffi_ws.tcp_close(socket)
      Nil
    })

    // A member holding nothing is told what an unknown session is told.
    let #(socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(socket, within_ms: 1000)
    assert code(review(socket, 1, rig.good, epoch)) == json.String("not_found")
    let _ = ffi_ws.tcp_close(socket)

    // The door answers by the same authority, and nothing is read for a
    // credential that holds nothing: the allowance is not spent.
    let spent = fn() { Error(Nil) }
    assert review_door.read(rig.reach(digest_of(bystander), open), rig.good)
      == Error(Refusal("not_found", "no such session"))
    assert review_door.read(rig.reach(digest_of(bystander), spent), rig.good)
      == Error(Refusal("not_found", "no such session"))
    let assert Ok(seen) =
      review_door.read(rig.reach(digest_of(observer), open), rig.good)
    assert seen.stat.files == 4
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn a_credential_past_its_allowance_is_asked_to_wait_test() {
  with_rig(fn(_registry, _port, _credential, _epoch, rig) {
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let token = string.repeat("7", 64)
    let assert Ok(principal) =
      access.create_member(store, "rev-busy", "rev-busy", digest_of(token))
    let assert Ok(Nil) =
      access.grant(store, principal.id, rig.good, access.Observer)

    assert review_door.read(
        rig.reach(digest_of(token), fn() { Error(Nil) }),
        rig.good,
      )
      == Error(Refusal(
        "unavailable",
        "too many workspace reads; try again shortly",
      ))
    assert catalogue.close(store) == Ok(Nil)
  })
}
