//// An in-memory `FileSystem` fake: a tiny actor holding a path → bytes
//// dict, wrapped in the same record of functions production uses, so
//// the fs tools cannot tell it from a real disk.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import tools/tool.{type FileSystem}

/// A handle to one in-memory filesystem.
pub opaque type MemoryFs {
  MemoryFs(subject: Subject(Msg))
}

type Msg {
  Read(path: String, reply: Subject(Result(BitArray, tool.FsError)))
  Write(
    path: String,
    bytes: BitArray,
    reply: Subject(Result(Nil, tool.FsError)),
  )
  IsFile(path: String, reply: Subject(Bool))
  Rename(from: String, to: String, reply: Subject(Result(Nil, tool.FsError)))
}

/// Starts an empty in-memory filesystem.
pub fn start() -> MemoryFs {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(handle)
    |> actor.start
    as "memory fs failed to start"
  MemoryFs(subject: started.data)
}

/// The seam record over this store. Directory creation is a no-op (the
/// store is flat); everything else behaves like a disk.
pub fn filesystem(fs: MemoryFs) -> FileSystem {
  tool.FileSystem(
    read: fn(path) {
      process.call(fs.subject, waiting: 1000, sending: Read(path, _))
    },
    write: fn(path, bytes) {
      process.call(fs.subject, waiting: 1000, sending: Write(path, bytes, _))
    },
    create_directory_all: fn(_path) { Ok(Nil) },
    is_file: fn(path) {
      Ok(process.call(fs.subject, waiting: 1000, sending: IsFile(path, _)))
    },
    // The flat store holds no symlinks and no directories: a stored
    // path is a plain file, everything else is missing — under which
    // real-path resolution degrades to the lexical walk.
    read_link: fn(path) {
      case process.call(fs.subject, waiting: 1000, sending: IsFile(path, _)) {
        True -> Ok(tool.NotALink)
        False -> Ok(tool.LinkMissing)
      }
    },
    // Atomic by construction here: the actor's own message handling is
    // the serialization, so a rename is one indivisible step exactly as
    // `rename(2)` is on a real filesystem.
    rename: fn(from, to) {
      process.call(fs.subject, waiting: 1000, sending: Rename(from, to, _))
    },
  )
}

fn handle(
  state: Dict(String, BitArray),
  message: Msg,
) -> actor.Next(Dict(String, BitArray), Msg) {
  case message {
    Read(path, reply) -> {
      case dict.get(state, path) {
        Ok(bytes) -> process.send(reply, Ok(bytes))
        Error(Nil) -> process.send(reply, Error(tool.FsNotFound(path:)))
      }
      actor.continue(state)
    }
    Write(path, bytes, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(dict.insert(state, path, bytes))
    }
    IsFile(path, reply) -> {
      process.send(reply, dict.has_key(state, path))
      actor.continue(state)
    }
    Rename(from, to, reply) -> {
      case dict.get(state, from) {
        Error(Nil) -> {
          process.send(reply, Error(tool.FsNotFound(path: from)))
          actor.continue(state)
        }
        Ok(bytes) -> {
          process.send(reply, Ok(Nil))
          actor.continue(dict.insert(dict.delete(state, from), to, bytes))
        }
      }
    }
  }
}
