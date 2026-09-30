//// The rules of `<loom-attach>`, the operator composer's image attachments,
//// as functions of the element's state (protocol-change/051, the addendum on
//// images).
////
//// The element lets the operator attach images to a prompt from a file
//// picker or a paste, shows each as a chip they can remove, and hands the
//// form their bytes. What an image may be is decided twice, and the two are
//// not the same check. The daemon is the authority: it decodes each image,
//// reads its magic number and refuses anything that is not PNG, JPEG, GIF or
//// WebP, or that is too many or too large (`web_view/image.admit`). The
//// element checks what it can before the bytes are read, so the operator
//// learns at once and a large file that would be refused is never read into
//// memory: the file's declared type, its size and how many are already held.
//// A declared type is the browser's guess from a file name, so a file that
//// passes here can still be refused there.
////
//// The limits are the daemon's own, sent in the element's `limits`
//// attribute as JSON. They are numbers and media types the daemon wrote and
//// no session text, and an attribute that does not decode leaves the element
//// attaching nothing rather than everything.
////
//// This module imports neither Lustre nor the DOM, so its decisions run
//// under Node in `attach_test`. `web_client/attach` is the element: the
//// state and messages over these, and the browser calls.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// What the daemon lets one prompt carry, as it told the element.
pub type Limits {
  Limits(
    /// The most images one prompt carries.
    count: Int,
    /// The most bytes all the images of one prompt total, before encoding.
    bytes: Int,
    /// The media types that may be attached.
    types: List(String),
  )
}

/// One image the element holds: the number it was given when it was chosen,
/// the file's name and size, and its bytes as base64 text.
pub type Held {
  Held(id: Int, name: String, size: Int, data: String)
}

/// One image being read. It counts against the limits from the moment it is
/// accepted, so two files chosen together cannot both take the last place.
pub type Reading {
  Reading(id: Int, name: String, size: Int)
}

/// A file the operator chose or pasted, before it is accepted. `file` is
/// whatever the caller reads it with, which these rules never look at.
pub type Candidate(file) {
  Candidate(name: String, mime_type: String, size: Int, file: file)
}

/// What the element knows.
pub type State {
  State(
    limits: Limits,
    /// The images already read, in the order they were chosen.
    held: List(Held),
    /// The images being read.
    reading: List(Reading),
    /// The number the next accepted file is given.
    next: Int,
    /// What the element last has to say about a file it refused or could not
    /// read, or empty.
    notice: String,
  )
}

/// The most characters of a file's name the element draws.
pub const name_width = 32

/// The limits of an element that was told none: nothing may be attached.
pub const nothing = Limits(count: 0, bytes: 0, types: [])

/// An element that holds nothing and has been told no limits.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.start().held == []
/// ```
pub fn start() -> State {
  State(limits: nothing, held: [], reading: [], next: 1, notice: "")
}

/// The limits the `limits` attribute carries:
/// `{"count":4,"bytes":8388608,"types":["image/png"]}`. Anything else, a
/// missing field included, is the limits that allow nothing.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.limits("{\"count\":1,\"bytes\":9,\"types\":[\"image/png\"]}")
///   == attach_rule.Limits(1, 9, ["image/png"])
/// ```
pub fn limits(text: String) -> Limits {
  let decoder = {
    use count <- decode.field("count", decode.int)
    use bytes <- decode.field("bytes", decode.int)
    use types <- decode.field("types", decode.list(decode.string))
    decode.success(Limits(count:, bytes:, types:))
  }
  json.parse(text, decoder) |> result.unwrap(nothing)
}

/// The element told its limits.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.configured(attach_rule.start(), limits).limits == limits
/// ```
pub fn configured(state: State, limits: Limits) -> State {
  State(..state, limits:)
}

/// Whether nothing more can be attached: the images held and being read fill
/// every place the limits give.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.full(attach_rule.start())
/// ```
pub fn full(state: State) -> Bool {
  list.length(state.held) + list.length(state.reading) >= state.limits.count
}

/// Vets each file of a choice or a paste, in order, against the limits and
/// against the files accepted before it, and returns the state with those
/// files reading and the files to read, each with the number it was given. A
/// refused file leaves a notice saying why, and the first refusal's is kept.
///
/// A file is refused when its type is not one the limits list, when it is
/// empty, when every place is taken, or when it would take the images past the
/// byte limit.
///
/// ## Examples
///
/// ```gleam
/// let file = attach_rule.Candidate("a.png", "image/png", 10, Nil)
/// let #(state, reads) = attach_rule.choose(state, [file])
/// ```
pub fn choose(
  state: State,
  candidates: List(Candidate(file)),
) -> #(State, List(#(Int, file))) {
  let #(state, reversed) =
    list.fold(candidates, #(State(..state, notice: ""), []), fn(acc, candidate) {
      let #(state, reads) = acc
      case vet(state, candidate) {
        Ok(Nil) -> {
          let id = state.next
          let reading = Reading(id:, name: candidate.name, size: candidate.size)
          #(
            State(
              ..state,
              reading: list.append(state.reading, [reading]),
              next: id + 1,
            ),
            [#(id, candidate.file), ..reads],
          )
        }
        Error(reason) -> #(refused(state, reason), reads)
      }
    })
  #(state, list.reverse(reversed))
}

// The first refusal of a choice is the one the element says.
fn refused(state: State, reason: String) -> State {
  case state.notice {
    "" -> State(..state, notice: reason)
    _ -> state
  }
}

fn vet(state: State, candidate: Candidate(file)) -> Result(Nil, String) {
  let name = label(candidate.name)
  let taken =
    list.fold(state.held, 0, fn(total, held) { total + held.size })
    + list.fold(state.reading, 0, fn(total, reading) { total + reading.size })
  case
    list.contains(state.limits.types, string.lowercase(candidate.mime_type)),
    candidate.size <= 0,
    full(state),
    taken + candidate.size > state.limits.bytes
  {
    False, _, _, _ -> Error(name <> " is not a PNG, JPEG, GIF or WebP image.")
    True, True, _, _ -> Error(name <> " is empty.")
    True, False, True, _ ->
      Error(
        "At most "
        <> int.to_string(state.limits.count)
        <> " images can be attached.",
      )
    True, False, False, True ->
      Error(
        "Attached images may total at most "
        <> size_text(state.limits.bytes)
        <> ".",
      )
    True, False, False, False -> Ok(Nil)
  }
}

/// Whether a media type claims to be an image of any kind, allowed or not.
/// A paste that holds such a file is the operator attaching it, so the
/// element takes it and says why if it is refused.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.is_image("image/svg+xml")
/// assert !attach_rule.is_image("text/plain")
/// ```
pub fn is_image(mime_type: String) -> Bool {
  string.starts_with(string.lowercase(mime_type), "image/")
}

/// A file's read finished with `read`: the `data:` URL the browser made, or
/// nothing when the read failed. The image is held, in the place it was
/// chosen at, when the URL is a base64 one, and otherwise the element says it
/// could not read the file.
///
/// ## Examples
///
/// ```gleam
/// let state = attach_rule.loaded(state, 1, Ok("data:image/png;base64,iVBOR"))
/// ```
pub fn loaded(state: State, id: Int, read: Result(String, Nil)) -> State {
  case list.find(state.reading, fn(reading) { reading.id == id }) {
    // A read that finished after its image was removed or its element was
    // replaced has nothing to add.
    Error(Nil) -> state
    Ok(Reading(name:, size:, ..)) -> {
      let state =
        State(
          ..state,
          reading: list.filter(state.reading, fn(reading) { reading.id != id }),
        )
      case result.try(read, data_of) {
        Ok(data) ->
          State(
            ..state,
            held: list.append(state.held, [Held(id:, name:, size:, data:)]),
          )
        Error(Nil) ->
          State(..state, notice: "Could not read " <> label(name) <> ".")
      }
    }
  }
}

/// The base64 text of a `data:` URL, or `Error` for anything that is not a
/// base64 one: the URL's header must end in `;base64`, and what follows the
/// comma must be non-empty.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.data_of("data:image/png;base64,iVBOR") == Ok("iVBOR")
/// assert attach_rule.data_of("data:text/plain,hi") == Error(Nil)
/// ```
pub fn data_of(url: String) -> Result(String, Nil) {
  use #(header, data) <- result.try(string.split_once(url, ","))
  case
    string.starts_with(header, "data:") && string.ends_with(header, ";base64"),
    data
  {
    True, "" -> Error(Nil)
    True, _ -> Ok(data)
    False, _ -> Error(Nil)
  }
}

/// The image numbered `id` removed, whether it is held or still being read.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.removed(attach_rule.start(), 1) == attach_rule.start()
/// ```
pub fn removed(state: State, id: Int) -> State {
  State(
    ..state,
    held: list.filter(state.held, fn(held) { held.id != id }),
    reading: list.filter(state.reading, fn(reading) { reading.id != id }),
    notice: "",
  )
}

/// The notice cleared.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.dismissed(state).notice == ""
/// ```
pub fn dismissed(state: State) -> State {
  State(..state, notice: "")
}

/// What the form submits under the element's name: a JSON array of the held
/// images' base64 text, oldest first, or `Error` when it holds none, which
/// the element takes as no value at all.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.value(attach_rule.start()) == Error(Nil)
/// ```
pub fn value(state: State) -> Result(String, Nil) {
  case state.held {
    [] -> Error(Nil)
    held ->
      Ok(
        json.array(held, fn(image) { json.string(image.data) })
        |> json.to_string,
      )
  }
}

/// A file name cut to `name_width` characters with an ellipsis, so a long one
/// cannot widen the chip.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.label("a.png") == "a.png"
/// ```
pub fn label(name: String) -> String {
  case string.drop_start(name, name_width) {
    "" -> name
    _ -> string.slice(name, 0, name_width - 1) <> "…"
  }
}

/// A size in bytes as the chip says it: bytes below a kilobyte, then
/// kilobytes and megabytes to one decimal.
///
/// ## Examples
///
/// ```gleam
/// assert attach_rule.size_text(1_572_864) == "1.5 MB"
/// ```
pub fn size_text(bytes: Int) -> String {
  case bytes < 1024, bytes < 1_048_576 {
    True, _ -> int.to_string(bytes) <> " B"
    False, True -> tenths(bytes, 1024) <> " KB"
    False, False -> tenths(bytes, 1_048_576) <> " MB"
  }
}

// `bytes` over `unit` with one decimal, rounded down, in integers.
fn tenths(bytes: Int, unit: Int) -> String {
  let scaled = bytes * 10 / unit
  int.to_string(scaled / 10) <> "." <> int.to_string(scaled % 10)
}
