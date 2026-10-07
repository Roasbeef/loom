//// Operator configuration has a dedicated, exact-action approval boundary.
////
//// The host fixes the only editable path. Reading exposes configuration text,
//// never resolved credentials. A small anchored edit validates before asking;
//// the existing durable escalation binds consent to its path, base digest and
//// replacement. No sandbox grant is requested or retained. After consent the
//// host rechecks the base, writes atomically and refreshes its live publication.

import broker/escalation
import core/clock
import core/json
import gleam/bool
import gleam/list
import gleam/option.{Some}
import gleam/string
import tools/tool

/// One trusted file observation, with its complete base identity.
pub type Document {
  Document(
    /// The operator-selected real path; callers cannot select another file.
    path: String,
    /// Content identity used to reject edits based on an older observation.
    digest: String,
    /// Configuration bytes; resolved secret values are never included.
    text: String,
  )
}

/// One replacement bound to the file the operator will review.
pub type Edit {
  Edit(
    /// Exact trusted path reported by the host.
    path: String,
    /// Exact observation this replacement is based on.
    digest: String,
    /// Unique literal text to replace, or empty for an append.
    old: String,
    /// Replacement text, shown completely in the approval diff.
    new: String,
  )
}

/// Host authority over the selected file, independent of filesystem grants.
pub type Door {
  Door(
    /// Reads a bounded observation of the explicitly selected file.
    read: fn() -> Result(Document, String),
    /// Validates the complete resulting document without writing it.
    validate: fn(Edit) -> Result(Nil, String),
    /// Rechecks the base, commits once and refreshes the live configuration.
    apply: fn(Edit) -> Result(String, String),
  )
}

/// Builds the read and proposal tool for the host's selected configuration.
///
/// ## Examples
///
/// ```gleam
/// // configuration.tool(door)
/// ```
pub fn tool(door: Door) -> tool.Tool {
  tool.Tool(
    name: "loom_config",
    description: "Inspect the explicitly selected loom.toml with action=read. To propose a small edit, use action=edit and copy path and digest from the read; old must match once, or be empty to append. The complete edit asks for operator approval before writing. Invalid, stale, oversized or unapproved proposals write nothing. Model settings reload for subsequent operations; tools, secrets and daemon services require restart. No general filesystem permission is granted. Split larger edits into separately reviewed proposals.",
    prompt_snippet: Some(
      "Use loom_config to help the operator iterate on their selected loom.toml; every edit requires approval of its exact diff.",
    ),
    schema: tool.object_schema(
      [
        #("action", tool.string_property("read or edit")),
        #(
          "path",
          tool.string_property("exact path returned by read; required for edit"),
        ),
        #(
          "digest",
          tool.string_property(
            "base digest returned by read; required for edit",
          ),
        ),
        #(
          "old",
          tool.string_property(
            "unique literal text to replace; empty to append",
          ),
        ),
        #(
          "new",
          tool.string_property("replacement text shown in the approval diff"),
        ),
      ],
      ["action"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: tool.read_requirements,
    run: fn(ctx, args) { run(door, ctx, args) },
  )
}

fn run(door: Door, ctx: tool.Ctx, args: json.JsonValue) -> tool.ToolOutcome {
  use action <- tool.with_arg(tool.required_string(args, "action"))
  case action {
    "read" -> {
      use document <- tool.with_arg(door.read())
      tool.success(
        "File: "
        <> json.to_string(json.String(document.path))
        <> "\nDigest: "
        <> document.digest
        <> "\n\nConfiguration:\n"
        <> document.text,
      )
      |> tool.with_details(
        json.Object([
          #("path", json.String(document.path)),
          #("digest", json.String(document.digest)),
        ]),
      )
    }
    "edit" -> edit(door, ctx, args)
    _ -> tool.failure("action must be read or edit")
  }
}

fn edit(door: Door, ctx: tool.Ctx, args: json.JsonValue) -> tool.ToolOutcome {
  use Nil <- tool.with_arg(case args {
    json.Object(fields) -> {
      use <- bool.guard(
        string.byte_size(json.to_string(json.canonical(args))) > 2048,
        Error(
          "the complete edit must fit the 2 KiB approval preview; propose a smaller edit",
        ),
      )
      case string.join(list_keys(fields), ",") {
        "action,digest,new,old,path" -> Ok(Nil)
        _ -> Error("edit requires exactly action, path, digest, old and new")
      }
    }
    _ -> Error("arguments must be an object")
  })
  use path <- tool.with_arg(tool.required_string(args, "path"))
  use digest <- tool.with_arg(tool.required_string(args, "digest"))
  use old <- tool.with_arg(tool.required_string(args, "old"))
  use new <- tool.with_arg(tool.required_string(args, "new"))
  let proposal = Edit(path:, digest:, old:, new:)
  use Nil <- tool.with_arg(door.validate(proposal))
  let #(now, _) = clock.read(ctx.clock)
  let denial =
    escalation.Denial(
      reason: "Editing operator configuration requires approval of this exact diff.",
      source: escalation.PolicyDenial,
      wanted: [],
    )
  case ctx.raise_refusal(tool.RaisedRefusal(denial, now + 600_000)) {
    tool.Settle ->
      tool.failure("Configuration edit was not approved; no file was changed.")
    tool.Resume([]) -> {
      use outcome <- tool.with_arg(door.apply(proposal))
      tool.success(outcome)
    }
    tool.Resume([_, ..]) ->
      tool.failure(
        "Configuration edits consume exact-action consent without sandbox grants.",
      )
  }
}

fn list_keys(fields: List(#(String, json.JsonValue))) -> List(String) {
  fields
  |> list.map(fn(pair) { pair.0 })
  |> list.sort(string.compare)
}
