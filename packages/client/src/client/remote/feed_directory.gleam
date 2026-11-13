//// The live session feeds a daemon holds, found by their tokens
//// (protocol-change/108, "The box's feed host").
////
//// A feed is one process (`client/remote/feed_host`), and the laptop names it
//// with the 128-bit token the box minted when it attached. This directory is the
//// one place that maps a token to its feed, so every poll, send and detach is
//// judged against the feeds of the spawner the sender's node resolved to, before
//// anything else. A token of another spawner's feed is not found here, and a
//// token whose feed is gone is not found either, which is why a request for a
//// feed that has ended learns that it has ended and touches nothing.
////
//// It also holds the cap. A spawner holds at most `remote_feed.max_feeds` feeds
//// that have not ended, and the ninth attach is refused. The count and the
//// reservation of a place are one turn of this process, so two attaches racing
//// for the last place cannot both have it.
////
//// ## A place is reserved before the feed starts
////
//// Starting a feed attaches to a gateway and takes a connection permit, which
//// can take seconds, so the directory does not start it. The caller reserves a
//// place, starts the feed, and registers it. The reservation names the caller's
//// process and the directory monitors it, so a caller that dies between the two
//// steps gives the place back. A running feed is monitored in the same way, so
//// a feed that exits is forgotten without anyone having to say so.
////
//// ## Flow
////
//// `start` → `reserve` → `register` → `find` → `ended`
////
//// 1. `start` begins the directory.
//// 2. `reserve` takes a place for a spawner and mints the token, or refuses at
////    the cap.
//// 3. `register` binds the token to its running feed, or `release` gives the
////    place back when the feed did not start.
//// 4. `find` looks a token up among one spawner's feeds.
//// 5. `ended` stops a feed counting toward the cap while it is kept for a late
////    poll.

import broker/token
import client/remote/feed_host.{type Feed}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/result
import gleam/string
import weft/actor

/// Whether a feed counts toward its spawner's cap.
type Standing {
  /// The feed has not ended.
  Counted

  /// The feed ended and is kept so that a late poll learns why.
  Kept
}

/// What a token names.
type Entry {
  /// A place was reserved and the feed is starting.
  Reserved(spawner: String, owner: Pid, watch: process.Monitor)

  /// The feed is running.
  Running(
    spawner: String,
    feed: Feed,
    standing: Standing,
    watch: process.Monitor,
  )
}

/// A running directory.
pub opaque type Directory {
  Directory(subject: Subject(Message))
}

type Message {
  Reserve(
    spawner: String,
    owner: Pid,
    cap: Int,
    reply: Subject(Result(String, Nil)),
  )
  Register(token: String, feed: Feed)
  Release(token: String)
  Find(spawner: String, token: String, reply: Subject(Result(Feed, Nil)))
  Ended(token: String)
  Down(down: process.Down)
}

/// Starts an empty directory.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(directory) = feed_directory.start()
/// ```
pub fn start() -> Result(Directory, String) {
  let started =
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(Down)
      actor.initialised(dict.new())
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.unlinked
    |> actor.start

  // A directory that did not start leaves the daemon serving no feed.
  case started {
    Ok(started) -> Ok(Directory(started.data))
    Error(_) -> Error("the feed directory did not start")
  }
}

/// Takes a place for one of `spawner`'s feeds and mints its token, or answers
/// `Error(Nil)` when the spawner already holds `cap` feeds that have not ended.
/// `owner` is the process that will start the feed, whose death gives the place
/// back.
///
/// ## Examples
///
/// ```gleam
/// // feed_directory.reserve(directory, "laptop", process.self(), 8)
/// ```
pub fn reserve(
  directory: Directory,
  spawner: String,
  owner: Pid,
  cap: Int,
) -> Result(String, Nil) {
  process.call(directory.subject, waiting: 1000, sending: Reserve(
    spawner,
    owner,
    cap,
    _,
  ))
}

/// Binds a reserved token to its running feed.
///
/// ## Examples
///
/// ```gleam
/// // feed_directory.register(directory, token, feed)
/// ```
pub fn register(directory: Directory, token: String, feed: Feed) -> Nil {
  process.send(directory.subject, Register(token, feed))
}

/// Gives a reserved place back because the feed did not start.
///
/// ## Examples
///
/// ```gleam
/// // feed_directory.release(directory, token)
/// ```
pub fn release(directory: Directory, token: String) -> Nil {
  process.send(directory.subject, Release(token))
}

/// Finds a feed among one spawner's feeds. A token that was never minted, that
/// belongs to another spawner, or whose feed has exited is not found.
///
/// ## Examples
///
/// ```gleam
/// // feed_directory.find(directory, "laptop", token)
/// ```
pub fn find(
  directory: Directory,
  spawner: String,
  token: String,
) -> Result(Feed, Nil) {
  process.call(directory.subject, waiting: 1000, sending: Find(
    spawner,
    token,
    _,
  ))
}

/// Says that a feed ended, so that it stops counting toward the cap while it is
/// kept for a late poll.
///
/// ## Examples
///
/// ```gleam
/// // feed_directory.ended(directory, token)
/// ```
pub fn ended(directory: Directory, token: String) -> Nil {
  process.send(directory.subject, Ended(token))
}

/// The transition function: one arm per message.
fn handle(
  entries: Dict(String, Entry),
  message: Message,
) -> actor.Next(Dict(String, Entry), Message) {
  case message {
    Reserve(spawner:, owner:, cap:, reply:) ->
      case counted(entries, spawner) >= cap {
        True -> {
          process.send(reply, Error(Nil))
          actor.continue(entries)
        }
        False -> {
          let minted = mint()
          process.send(reply, Ok(minted))
          let watch = process.monitor(owner)
          actor.continue(dict.insert(
            entries,
            minted,
            Reserved(spawner:, owner:, watch:),
          ))
        }
      }

    // A reservation is replaced by its feed. The caller's monitor is dropped
    // and the feed's takes over, so the feed's exit is what frees the place.
    Register(token:, feed:) ->
      case dict.get(entries, token) {
        Ok(Reserved(spawner:, watch:, ..)) -> {
          process.demonitor_process(watch)
          let watch = process.monitor(feed_host.pid(feed))
          actor.continue(dict.insert(
            entries,
            token,
            Running(spawner:, feed:, standing: Counted, watch:),
          ))
        }

        // A token with no reservation was released or its owner died, so the
        // feed has no place. It is left to end on its own lease.
        Ok(Running(..)) | Error(Nil) -> actor.continue(entries)
      }

    Release(token:) ->
      case dict.get(entries, token) {
        Ok(Reserved(watch:, ..)) -> {
          process.demonitor_process(watch)
          actor.continue(dict.delete(entries, token))
        }
        Ok(Running(..)) | Error(Nil) -> actor.continue(entries)
      }

    Find(spawner:, token:, reply:) -> {
      process.send(reply, found(entries, spawner, token))
      actor.continue(entries)
    }

    Ended(token:) ->
      case dict.get(entries, token) {
        Ok(Running(spawner:, feed:, watch:, ..)) ->
          actor.continue(dict.insert(
            entries,
            token,
            Running(spawner:, feed:, standing: Kept, watch:),
          ))
        Ok(Reserved(..)) | Error(Nil) -> actor.continue(entries)
      }

    // Every entry holds one monitor, on the reserving process or on the feed,
    // so a process that went down names exactly the entries to forget.
    Down(down:) -> actor.continue(forgotten(entries, down))
  }
}

/// How many of a spawner's feeds count toward its cap.
fn counted(entries: Dict(String, Entry), spawner: String) -> Int {
  dict.values(entries)
  |> list.count(fn(entry) {
    case entry {
      Reserved(spawner: held, ..) -> held == spawner
      Running(spawner: held, standing: Counted, ..) -> held == spawner
      Running(standing: Kept, ..) -> False
    }
  })
}

/// The feed a token names, if it is a running feed of this spawner.
fn found(
  entries: Dict(String, Entry),
  spawner: String,
  token: String,
) -> Result(Feed, Nil) {
  use entry <- result.try(dict.get(entries, token))

  // Only a running feed of this spawner is a feed the sender may name.
  case entry {
    Running(spawner: held, feed:, ..) if held == spawner -> Ok(feed)
    Running(..) | Reserved(..) -> Error(Nil)
  }
}

/// Drops the entries whose watched process went down.
fn forgotten(
  entries: Dict(String, Entry),
  down: process.Down,
) -> Dict(String, Entry) {
  case down {
    process.ProcessDown(pid: gone, ..) ->
      dict.filter(entries, fn(_token, entry) {
        case entry {
          Reserved(owner:, ..) -> owner != gone
          Running(feed:, ..) -> feed_host.pid(feed) != gone
        }
      })
    process.PortDown(..) -> entries
  }
}

/// Mints a token: 128 bits, as 32 lowercase hexadecimal characters.
fn mint() -> String {
  token.production_entropy()(16)
  |> bit_array.base16_encode
  |> string.lowercase
}
