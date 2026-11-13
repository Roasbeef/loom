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
//// It also holds the cap. A spawner holds at most `remote_feed.max_feeds` feeds,
//// and the ninth attach is refused. A feed counts from its reservation until its
//// process exits, and an ended feed is a process until it is forgotten one lease
//// after it ended, holding its connection permit all that time. Counting it
//// is what keeps the permits a spawner can hold at the cap whatever its attaches
//// and endings do. The price is that a laptop which reattaches at the cap is
//// refused for up to one lease after its last feed ended. The count and the
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
//// `start` → `reserve` → `register` → `find` → `release`
////
//// 1. `start` begins the directory.
//// 2. `reserve` takes a place for a spawner and mints the token, or refuses at
////    the cap.
//// 3. `register` binds the token to its running feed, or `release` gives the
////    place back when the feed did not start.
//// 4. `find` looks a token up among one spawner's feeds.

import broker/internal/call
import broker/token
import client/remote/feed_host.{type Feed}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/result
import gleam/string
import weft/actor

/// What a token names.
type Entry {
  /// A place was reserved and the feed is starting.
  Reserved(spawner: String, owner: Pid, watch: process.Monitor)

  /// The feed is running, or ended and kept for a late poll.
  Running(spawner: String, feed: Feed, watch: process.Monitor)
}

/// A running directory.
pub opaque type Directory {
  Directory(subject: Subject(Message))
}

/// Why no place was reserved.
pub type Refused {
  /// The spawner holds as many feeds as the cap allows.
  AtCap

  /// The directory did not answer, so nothing was reserved.
  Unavailable
}

/// Why no feed was found, which a laptop must be told apart: a feed that is
/// gone has ended and starting again is right, and a directory that did not
/// answer says nothing about the feed, so the call is asked again.
pub type Missing {
  /// The token was never minted, belongs to another spawner, names a place not
  /// yet running as a feed, or its feed has exited.
  Gone

  /// The directory did not answer, so nothing is known of the token.
  Unanswered
}

type Message {
  Reserve(
    spawner: String,
    owner: Pid,
    cap: Int,
    reply: Subject(Result(String, Refused)),
  )
  Register(token: String, feed: Feed)
  Release(token: String)
  Find(spawner: String, token: String, reply: Subject(Result(Feed, Nil)))
  Stop
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

/// Takes a place for one of `spawner`'s feeds and mints its token, or says why
/// not: the spawner already holds `cap` feeds, or the directory did not answer.
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
) -> Result(String, Refused) {
  call.try_call(directory.subject, waiting: 1000, sending: Reserve(
    spawner,
    owner,
    cap,
    _,
  ))
  |> result.replace_error(Unavailable)
  |> result.flatten
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
/// belongs to another spawner, or whose feed has exited is `Gone`, and any token
/// is `Unanswered` while the directory does not answer.
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
) -> Result(Feed, Missing) {
  case
    call.try_call(directory.subject, waiting: 1000, sending: Find(
      spawner,
      token,
      _,
    ))
  {
    Ok(Ok(feed)) -> Ok(feed)
    Ok(Error(Nil)) -> Error(Gone)
    Error(_) -> Error(Unanswered)
  }
}

/// Stops the directory, which every call after answers as unavailable. A daemon
/// does this when it stops serving feeds, and a test does it to see what a
/// laptop is told when the directory is silent.
///
/// ## Examples
///
/// ```gleam
/// // feed_directory.stop(directory)
/// ```
pub fn stop(directory: Directory) -> Nil {
  process.send(directory.subject, Stop)
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
          process.send(reply, Error(AtCap))
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
            Running(spawner:, feed:, watch:),
          ))
        }

        // A token with no reservation was released or its owner died, so the
        // feed has no place. It dies with its owner, which it watches until
        // it is registered.
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

    Stop -> actor.stop()

    // Every entry holds one monitor, on the reserving process or on the feed,
    // so a process that went down names exactly the entries to forget.
    Down(down:) -> actor.continue(forgotten(entries, down))
  }
}

/// How many feeds of a spawner hold a place: every reservation and every feed
/// that has not exited, ended or not.
fn counted(entries: Dict(String, Entry), spawner: String) -> Int {
  dict.values(entries)
  |> list.count(fn(entry) { entry.spawner == spawner })
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
