//// The vetting lint — code mode's single load-bearing security control.
////
//// # What this decides, and why it must be adversarially correct
////
//// `vet` decides whether a model-written Gleam program is safe to compile and
//// run. The whole of code-mode isolation rests on one principle (design §6.2):
////
//// > A Gleam program's maximal capability set is the transitive closure of
//// > its imports plus its own `@external` declarations.
////
//// Pure Gleam cannot do I/O, has no reflection, no `eval`, no dynamic module
//// lookup, no macros. So a program's reachable effects are exactly what its
//// imports expose plus whatever `@external` it declares. This lint enforces
//// the three rules that turn that principle into a bound (design §6.2):
////
//// 1. **No `@external`** (and, fail-closed, no attribute at all) in submitted
////    source. `@external` is the one construct that binds Gleam to arbitrary
////    foreign code, sidestepping the capability prelude entirely.
//// 2. **Imports confined to the allowlist** — the pinned capability prelude
////    plus a pure-stdlib subset. Bound the imports and you bound the closure.
//// 3. **No dependency outside the pinned prelude** — a submitted program
////    declares no dependencies of its own; the only modules it may name are
////    allowlisted. At the source level this is the same import check as rule 2
////    (dependency *pinning* proper is the compile service's job).
////
//// This is *layer one* of defense in depth (design §6.3). The satellite node
//// is layer two. Layer one must not lean on layer two catching its misses: a
//// hostile `.beam` that slips vetting only sits in the satellite jail because
//// vetting was supposed to have caught it. Treat every rule as if it were the
//// only thing standing between hostile source and the harness.
////
//// # Totality
////
//// `vet` is total *given `glance` returns*: a program that fails to parse is a
//// `Rejected`, never a crash, and malformed, incomplete, or hostile input all
//// settle as `Rejection` values the model can read and fix in-band. The one
//// residual is inside the parser itself — `glance` carries a hard `panic`
//// (`glance.gleam:944`, "parser bug, expression not full reduced") on a path
//// no fuzzing has reached. If some input ever reaches it the panic propagates
//// out of `glance.module` and crashes `vet`; this is availability (a crash
//// never yields a spurious `Passed`), not a capability bypass, and a
//// fail-closed parser boundary is deferred hardening (see the M4 triage, V-F4).
////
//// # The `Vetted` token and downstream bypass prevention
////
//// A pass yields an opaque `Vetted` carrying the exact source that passed and
//// its parsed AST. `Vetted` has no public constructor, so the *only* way to
//// obtain one is to call `vet`. The compile service is written to take a
//// `Vetted`, not a `String`; the type system then makes it impossible to
//// compile source that was not vetted, and the carried AST spares a re-parse.

import codemode/vet/policy.{type VetPolicy} as allowlist
import glance.{type Attribute, type Module}
import gleam/list
import gleam/string
import glexer
import glexer/token

/// The outcome of vetting a source string.
pub type VetResult {
  /// The source passed all three rules. The token proves it and carries the
  /// vetted source and its AST.
  Passed(Vetted)
  /// The source failed. Every violation found in one pass is listed, so the
  /// model can fix them all at once rather than one round-trip per rule.
  Rejected(List(Rejection))
}

/// Proof that a specific source string passed vetting.
///
/// Opaque by design: the absence of a public constructor is the security
/// property. Downstream stages (the compile service) accept a `Vetted` rather
/// than a raw `String`, so un-vetted source cannot reach compilation — there is
/// no way to fabricate this token except through `vet`. It carries the source
/// verbatim and its parsed module so nothing downstream must re-vet or re-parse.
pub opaque type Vetted {
  Vetted(source: String, module: Module)
}

/// The rule a rejection is charged against. Naming the rule lets the caller
/// group and explain failures; the human-readable specifics are in `detail`.
pub type Rule {
  /// Rule 1. `@external` — or any attribute, since attributes are the only
  /// construct that can reach foreign code and we fail closed on the whole
  /// class — appeared in the submitted source.
  NoForeignInterface
  /// Rules 2 and 3. An import named a module that is not a byte-identical
  /// reference to an allowlisted one (a disallowed module, or a malformed /
  /// non-ASCII / lookalike name).
  ImportNotAllowed
  /// The source could not be parsed. A malformed program is a rejection, not a
  /// crash.
  Unparseable
}

/// Where in the submitted source a violation sits.
///
/// `glance` attaches a byte span only to function definitions and a byte
/// offset to parse errors; imports and attributes on non-function definitions
/// carry no span, so those rejections are `Unlocated` and name the offending
/// construct in the rejection's `detail` instead. On the Erlang target these
/// offsets are true byte offsets.
pub type Location {
  /// A byte span `[start, end)` in the source.
  SourceSpan(start: Int, end: Int)
  /// A single byte offset (a parse error reports a point, not a span).
  SourcePoint(byte_offset: Int)
  /// No span is available for this construct; see the rejection's `detail`.
  Unlocated
}

/// One violation. `rule` categorizes it, `detail` is a message phrased so the
/// model can fix the program in-band, and `location` points at the source
/// where possible.
pub type Rejection {
  Rejection(rule: Rule, detail: String, location: Location)
}

/// Vet a submitted Gleam program against a policy.
///
/// Parses the source with `glance`; a parse failure is a single `Unparseable`
/// rejection. On a successful parse it collects *all* rule-1 and rule-2/3
/// violations (it does not stop at the first) and returns `Passed` only if
/// there are none. Total: every input maps to a `VetResult`.
///
/// ## Examples
///
/// ```gleam
/// let source = "import cap/fs\npub fn main() { fs.read(\"x\") }"
/// let assert vet.Passed(_) = vet.vet(source, policy.default())
/// ```
///
/// ```gleam
/// let source = "@external(erlang, \"os\", \"cmd\")\npub fn run(c: String) -> String"
/// let assert vet.Rejected([r]) = vet.vet(source, policy.default())
/// assert r.rule == vet.NoForeignInterface
/// ```
///
pub fn vet(source: String, policy: VetPolicy) -> VetResult {
  case glance.module(source) {
    Error(error) -> Rejected([parse_rejection(error)])
    Ok(module) -> {
      let rejections =
        list.flatten([
          attribute_rejections(module),
          dangling_attribute_backstop(source, module),
          import_rejections(module, policy),
          unseen_import_backstop(source, module),
        ])
      case rejections {
        [] -> Passed(Vetted(source:, module:))
        _ -> Rejected(rejections)
      }
    }
  }
}

/// The exact source that passed vetting. The compile service compiles this
/// string, guaranteeing it compiles what was vetted and nothing else.
pub fn vetted_source(vetted: Vetted) -> String {
  vetted.source
}

/// The parsed module of a vetted source, so downstream stages need not
/// re-parse.
pub fn vetted_module(vetted: Vetted) -> Module {
  vetted.module
}

// --- Rule 1: no foreign interface ------------------------------------------
//
// `@external` binds a Gleam function to foreign Erlang/JavaScript code and is
// the sole in-source route to unmediated effects. We fail closed on the entire
// attribute class: a submitted one-shot program has no legitimate need for any
// attribute, and refusing all of them removes any chance that an obscure or
// future attribute spelling reaches foreign code. `glance` attaches attributes
// to the definition that follows them, so we sweep the attribute lists of every
// kind of definition — functions, custom types, type aliases, constants, and
// imports alike.

/// Collect a rejection for every attribute on every definition in the module.
fn attribute_rejections(module: Module) -> List(Rejection) {
  list.flatten([
    // Functions carry a source span, so their attribute rejections can point
    // at the offending definition.
    list.flat_map(module.functions, fn(definition) {
      attributes_to_rejections(
        definition.attributes,
        function_location(definition.definition),
      )
    }),
    list.flat_map(module.custom_types, fn(definition) {
      attributes_to_rejections(definition.attributes, Unlocated)
    }),
    list.flat_map(module.type_aliases, fn(definition) {
      attributes_to_rejections(definition.attributes, Unlocated)
    }),
    list.flat_map(module.constants, fn(definition) {
      attributes_to_rejections(definition.attributes, Unlocated)
    }),
    list.flat_map(module.imports, fn(definition) {
      attributes_to_rejections(definition.attributes, Unlocated)
    }),
  ])
}

/// Turn a definition's attribute list into rejections at `location`.
fn attributes_to_rejections(
  attributes: List(Attribute),
  location: Location,
) -> List(Rejection) {
  list.map(attributes, attribute_rejection(_, location))
}

/// Reject one attribute. `@external` gets a message naming the FFI hazard
/// specifically; every other attribute is refused on the fail-closed rule.
fn attribute_rejection(attribute: Attribute, location: Location) -> Rejection {
  case attribute.name {
    "external" ->
      Rejection(
        NoForeignInterface,
        "`@external` binds a function to foreign Erlang/JavaScript code, "
          <> "bypassing the capability prelude; it is never permitted in a "
          <> "submitted program",
        location,
      )
    other ->
      Rejection(
        NoForeignInterface,
        "attribute `@"
          <> other
          <> "` is not permitted in a submitted program; vetting fails closed "
          <> "on every attribute, since attributes are the only construct that "
          <> "can reach foreign code",
        location,
      )
  }
}

/// The span of a function definition as a `Location`.
fn function_location(function: glance.Function) -> Location {
  let glance.Span(start, end) = function.location
  SourceSpan(start, end)
}

/// A fail-closed backstop that catches every attribute `glance` dropped,
/// keyed off the token stream rather than the raw source or the AST.
///
/// `glance` discards an attribute that precedes no definition — a dangling
/// `@external` at end of input, for instance, vanishes from the AST. It binds
/// no function so it is inert, and the real `gleam` compiler rejects an
/// unattached attribute outright, but we refuse it here on principle: the whole
/// attribute class fails closed, whatever the parser does with it.
///
/// The scan is over `glexer` tokens, not the raw source. Scanning raw bytes for
/// the substring `"@external"` (the previous approach) fired on the literal
/// appearing inside a string constant or a comment — rejecting effect-free
/// programs such as an agent grepping a codebase for FFI (M4 triage V-F1). A
/// string or comment lexes to a single `String`/comment token that never
/// decomposes into `At` followed by a `Name`, so the token scan sees only real
/// attribute syntax. It is also spacing- and comment-adjacency-independent:
/// `@ external` and `@//c\nexternal` both lex to `At, Name("external")` once
/// whitespace and comments are discarded (M4 triage V-F2), and it sees every
/// `@name`, not just `@external` (M4 triage V-F5).
///
/// To avoid double-reporting the common case — an attribute attached to a
/// definition, which the AST sweep already catches — the backstop reports only
/// the attribute names present in the token stream *beyond* those the AST
/// surfaced (a multiset difference). What remains is exactly the dropped,
/// dangling attributes.
fn dangling_attribute_backstop(
  source: String,
  module: Module,
) -> List(Rejection) {
  let dropped =
    subtract_first_occurrences(
      token_attribute_names(source),
      ast_attribute_names(module),
    )
  list.map(dropped, dangling_attribute_rejection)
}

/// The attribute names in the token stream: every `At` token immediately
/// followed by a `Name`. Whitespace and comments are discarded first, so an
/// attribute is caught however it is spaced, and a `"@external"` inside a string
/// or comment is a single non-`At` token that is never counted.
fn token_attribute_names(source: String) -> List(String) {
  glexer.new(source)
  |> glexer.discard_whitespace
  |> glexer.discard_comments
  |> glexer.lex
  |> scan_attribute_names([])
}

fn scan_attribute_names(
  tokens: List(#(token.Token, glexer.Position)),
  names: List(String),
) -> List(String) {
  case tokens {
    [#(token.At, _), #(token.Name(name), _), ..rest] ->
      scan_attribute_names(rest, [name, ..names])
    [_, ..rest] -> scan_attribute_names(rest, names)
    [] -> list.reverse(names)
  }
}

/// The attribute names `glance` surfaced on every kind of definition.
fn ast_attribute_names(module: Module) -> List(String) {
  list.flatten([
    list.flat_map(module.functions, definition_attribute_names),
    list.flat_map(module.custom_types, definition_attribute_names),
    list.flat_map(module.type_aliases, definition_attribute_names),
    list.flat_map(module.constants, definition_attribute_names),
    list.flat_map(module.imports, definition_attribute_names),
  ])
}

fn definition_attribute_names(
  definition: glance.Definition(a),
) -> List(String) {
  list.map(definition.attributes, fn(attribute) { attribute.name })
}

/// Removes, for each element of `remove`, its first occurrence in `from` — a
/// multiset difference. The result is the token-stream attributes the AST did
/// not account for: the dangling ones.
fn subtract_first_occurrences(
  from: List(String),
  remove: List(String),
) -> List(String) {
  list.fold(remove, from, remove_first)
}

fn remove_first(names: List(String), name: String) -> List(String) {
  case names {
    [] -> []
    [first, ..rest] ->
      case first == name {
        True -> rest
        False -> [first, ..remove_first(rest, name)]
      }
  }
}

/// A fail-closed backstop against a *parser* divergence over imports.
///
/// Vetting decides what a program may reach by reading `glance`'s AST; the
/// harness then compiles the same source with `gleam`. `@external` already has
/// a parser-independent backstop (`dangling_attribute_backstop`); imports did
/// not, and an import `glance` did not surface is an import the allowlist was
/// never applied to (M4 triage V-F3). No divergence has been exhibited — this
/// exists so that if one ever appears it fails closed rather than silently
/// admitting a module.
///
/// Same shape as the attribute backstop: sweep the token stream for import
/// paths, subtract the ones the AST accounted for, and reject whatever is
/// left. Being a token sweep, it is immune to the false positive a raw-source
/// scan would produce — the text `import cap/fs` inside a string constant or a
/// comment lexes to a single token that is never an `Import` keyword.
fn unseen_import_backstop(source: String, module: Module) -> List(Rejection) {
  let unseen =
    subtract_first_occurrences(
      token_imports(source),
      list.map(module.imports, fn(definition) { definition.definition.module }),
    )
  list.map(unseen, fn(name) {
    Rejection(
      ImportNotAllowed,
      "the import `"
        <> name
        <> "` appears in the submitted source but was not surfaced by the "
        <> "parser vetting reads, so the allowlist was never applied to it; "
        <> "vetting fails closed on a parser disagreement",
      Unlocated,
    )
  })
}

/// The module paths the token stream imports, in source order.
///
/// Public so the backstop's scanner can be tested and audited directly: it is
/// the half of the parser cross-check that does not come from `glance`, and a
/// scanner that quietly saw nothing would make the whole check vacuous.
///
/// ## Examples
///
/// ```gleam
/// let source = "import cap/fs\nimport gleam/list as l\n"
/// assert vet.token_imports(source) == ["cap/fs", "gleam/list"]
/// ```
///
/// ```gleam
/// // Not an import: a single string token never lexes to the keyword.
/// assert vet.token_imports("const c = \"import cap/fs\"\n") == []
/// ```
///
pub fn token_imports(source: String) -> List(String) {
  glexer.new(source)
  |> glexer.discard_whitespace
  |> glexer.discard_comments
  |> glexer.lex
  |> scan_imports([])
}

fn scan_imports(
  tokens: List(#(token.Token, glexer.Position)),
  found: List(String),
) -> List(String) {
  case tokens {
    [#(token.Import, _), ..rest] -> {
      let #(segments, rest) = scan_path(rest, [])
      scan_imports(rest, [string.join(list.reverse(segments), "/"), ..found])
    }
    [_, ..rest] -> scan_imports(rest, found)
    [] -> list.reverse(found)
  }
}

// A module path is lowercase name segments joined by `/`; the first token that
// is neither ends it (`.` before an unqualified list, `as` before an alias, or
// the next statement).
fn scan_path(
  tokens: List(#(token.Token, glexer.Position)),
  segments: List(String),
) -> #(List(String), List(#(token.Token, glexer.Position))) {
  case tokens, segments {
    [#(token.Name(segment), _), ..rest], [] -> scan_path(rest, [segment])
    [#(token.Slash, _), #(token.Name(segment), _), ..rest], [_, ..] ->
      scan_path(rest, [segment, ..segments])
    _, _ -> #(segments, tokens)
  }
}

/// A rejection for a dangling attribute the token scan found. `@external` names
/// the FFI hazard specifically; every other attribute is refused on the same
/// fail-closed rule the AST sweep applies to attached ones.
fn dangling_attribute_rejection(name: String) -> Rejection {
  case name {
    "external" ->
      Rejection(
        NoForeignInterface,
        "the `@external` attribute appears in the submitted source; it binds "
          <> "foreign Erlang/JavaScript code and is never permitted",
        Unlocated,
      )
    other ->
      Rejection(
        NoForeignInterface,
        "attribute `@"
          <> other
          <> "` appears in the submitted source; vetting fails closed on every "
          <> "attribute, since attributes are the only construct that can reach "
          <> "foreign code",
        Unlocated,
      )
  }
}

// --- Rules 2 & 3: imports confined to the allowlist ------------------------
//
// A submitted program may name only allowlisted modules. Every import name is
// first put through the ASCII grammar gate (`policy.is_legal_module_name`),
// which rejects homoglyphs, fullwidth characters, zero-width joiners, and every
// other non-ASCII or malformed name before any comparison — see the policy
// module doc for why we defend lookalikes by grammar rather than Unicode
// normalization. A well-formed name is then checked for byte-identical
// membership in the allowlist. `glance` gives imports no source span, so these
// rejections name the module in `detail` and are `Unlocated`.

/// Collect a rejection for every import that is not an allowlisted module.
fn import_rejections(module: Module, policy: VetPolicy) -> List(Rejection) {
  list.filter_map(module.imports, fn(definition) {
    let name = definition.definition.module
    case allowlist.is_legal_module_name(name) {
      False ->
        Ok(Rejection(
          ImportNotAllowed,
          "import `"
            <> name
            <> "` is not a legal ASCII module reference; module names must be "
            <> "lowercase ASCII, so a lookalike or non-ASCII name is never "
            <> "equal to an allowlisted module",
          Unlocated,
        ))
      True ->
        // The denylist is consulted before the allowlist: these modules are
        // rejected with a specific reason, and stay rejected even if a
        // misconfigured policy allowed one (CH-F1, redundant defense).
        case allowlist.is_denied(name) {
          True ->
            Ok(Rejection(
              ImportNotAllowed,
              "import `"
                <> name
                <> "` is explicitly denied: `gleam/erlang` and `gleam/otp` (and "
                <> "their submodules) expose raw processes, atoms, OS access, "
                <> "and supervision; a submitted program's concurrency is "
                <> "`cap/task`/`cap/actor`",
              Unlocated,
            ))
          False ->
            case allowlist.contains(policy, name) {
              True -> Error(Nil)
              False ->
                Ok(Rejection(
                  ImportNotAllowed,
                  "import `"
                    <> name
                    <> "` is not in the capability allowlist; a submitted "
                    <> "program may import only the pinned prelude",
                  Unlocated,
                ))
            }
        }
    }
  })
}

// --- Parse failures --------------------------------------------------------

/// Turn a `glance` parse error into a rejection. Keeps `vet` total: a program
/// that will not parse is a rejection value, never a crash.
fn parse_rejection(error: glance.Error) -> Rejection {
  case error {
    glance.UnexpectedEndOfInput ->
      Rejection(
        Unparseable,
        "submitted source ended unexpectedly; the program is incomplete and "
          <> "cannot be vetted",
        Unlocated,
      )
    glance.UnexpectedToken(token:, position:) ->
      Rejection(
        Unparseable,
        "submitted source could not be parsed near an unexpected token: "
          <> string.inspect(token),
        // `glexer.Position` carries the offset; field access needs no import
        // of the type, and on the Erlang target this is a true byte offset.
        SourcePoint(position.byte_offset),
      )
  }
}
