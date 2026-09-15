#!/usr/bin/env python3
"""Render the capability prelude's public surface, per module, as Gleam.

Input is `gleam export package-interface` over `packages/cap` — the
compiler's own view of what it will accept, which is the only source that
cannot drift from what a submitted program is compiled against. Output is
the body of `packages/tools/src/tools/prelude.gleam`: one rendered block
per module, keyed by module name, for `tools/codemode` to filter through
a seam's allowlist and show to a model.

Two renderings of the same modules, in the same order, because the two
readers want different amounts of it. `surfaces` is the whole public
surface and is what `fs_read` of `cap://<module>` reads out on demand.
`type_surfaces` is the same block cut after the `pub type` declarations —
the heading, the module's purpose line, and the types with their docs —
and is what the `code_mode` description carries. Each `type_surfaces`
entry is a character-for-character prefix of its `surfaces` counterpart,
so the block a model reads on demand extends the block it was shown
instead of restating it in different words.

The cut is where it is because of what the two cost. A description is the
byte prefix of the provider's cached region, paid on every request of
every strand for the life of the session, and function signatures are the
bulk of a module. A signature a program needs can be read when it is
needed, and the read lands in the conversation tail rather than the
prefix. A type is different: `proc.run` returns a `proc.Output`, and a
program that cannot name the `stdout` field cannot read the output it
just paid for — a model that skips the read and guesses a field name pays
a compile either way, so the declarations stay where they cannot be
missed.

Nothing here decides *which* modules a seam admits. This renders every
module the interface reports, `cap/runtime` included; the allowlist filter
lives in `tools/codemode`, where the seam offers are. Rendering the filter
here would put the security-relevant decision in a build script and leave
the tool description asserting a claim nothing checks.

## What is rendered, and what was left out

The block for a module is Gleam-shaped source: `pub type` declarations
with their constructors, `pub const`, and `pub fn` signatures, each under
its `///` documentation. Gleam-shaped rather than a compact notation
because the reader's whole job is to write Gleam: a form it can pattern
match against the language it is emitting needs no legend beyond the two
sentences `tools/codemode` states, and a bespoke notation would need
teaching in the same bytes it saved.

Three deliberate omissions, each measured over the nine workspace modules
(characters, and tokens at the usual four-characters-per-token estimate):

  * **Parameter names.** The interface carries a parameter's *label* and
    not its name, because the label is all a caller may write. A labelled
    parameter renders `label: Type` and an unlabelled one renders as its
    bare type. Inventing names for the unlabelled ones would read as
    labels and teach a call the compiler rejects, which is the one
    failure this rendering exists to prevent.
  * **`## Examples` sections** (1,014 chars, ~250 tok). These are the
    prelude's doctests. They are assertions about return values that the
    signature above them already states, they exist to be run rather than
    read, and they are the one part of a doc comment written for a
    maintainer instead of a caller. Everything before the first `#`
    heading is kept in full — including the `Capability: \\`fs.read\\`.`
    line, which names the exact capability a refusal will cite.
  * **All but the first sentence of a module's own doc** (7,900 of 8,850
    chars, ~1,970 tok). A module doc runs to the design rationale — Rule
    Zero, the two-channel doctrine, what a satellite's death means — which
    is written for someone changing the prelude, not for someone calling
    it. The first sentence is the house convention's purpose line
    (`\\`cap/fs\\` — workspace filesystem access, as typed calls over the
    broker.`) and carries the whole of what a caller needs to choose
    between modules. The reader loses the "why"; it gains nine modules of
    "what" for the price of one module's preamble.

The omissions above apply to both renderings, since the second is a cut of
the first. What the cut itself costs and saves is measured where it is
spent, in `tools/codemode`'s `signatures_text`: the `code_mode` tool went
from 52,162 bytes on the wire to 25,690 on a workspace-only host, 17,753
to 10,698 on an orchestration-only one, and 64,842 to 33,472 on a host
serving both.
"""

import json
import re
import sys
import textwrap

# The rendered lines wrap here. Narrow enough to read as source, wide
# enough that wrapping does not itself become a line of tokens per line.
WIDTH = 74

VARS = "abcdefghijklmnopqrstuvwxyz"


def var_name(index):
    """A type variable's name. The interface numbers them; Gleam names them."""
    return VARS[index % 26] + ("" if index < 26 else str(index // 26))


def build_alias_map(modules):
    """Foreign `(module, Name)` -> the `(module, Alias)` that can name it.

    `cap/report` aliases `core/msgpack.MsgPackValue` as `Value` precisely
    so a program can name the type without importing a module the
    allowlist refuses. The interface expands aliases in signatures, so a
    literal rendering would print `MsgPackValue` — a name that resolves
    nowhere a program can reach. Reversing the aliases the prelude
    declares puts the nameable name back, and derives it from the prelude
    rather than hardcoding the one case that exists today.
    """
    reverse = {}
    for module, body in modules.items():
        for alias_name, alias in body.get("type-aliases", {}).items():
            target = alias.get("alias") or {}
            if target.get("kind") == "named" and not target.get("parameters"):
                key = (target.get("module"), target.get("name"))
                reverse.setdefault(key, (module, alias_name))
    return reverse


def qualify(module, name, here, aliases):
    """How a program that imported `here` writes this type's name."""
    if module in (here, "gleam"):
        return name
    if (module, name) in aliases:
        alias_module, alias_name = aliases[(module, name)]
        if alias_module == here:
            return alias_name
        return alias_module.split("/")[-1] + "." + alias_name
    return module.split("/")[-1] + "." + name


def render_type(node, here, aliases):
    kind = node.get("kind")
    if kind == "named":
        base = qualify(node["module"], node["name"], here, aliases)
        parameters = node.get("parameters") or []
        if not parameters:
            return base
        inner = ", ".join(render_type(p, here, aliases) for p in parameters)
        return base + "(" + inner + ")"
    if kind == "variable":
        return var_name(node["id"])
    if kind == "fn":
        parameters = node.get("parameters") or []
        inner = ", ".join(render_type(p, here, aliases) for p in parameters)
        return "fn(" + inner + ") -> " + render_type(node["return"], here, aliases)
    if kind == "tuple":
        elements = node.get("elements") or []
        return "#(" + ", ".join(render_type(e, here, aliases) for e in elements) + ")"
    raise SystemExit("gen-prelude: unknown type kind " + repr(kind))


def paragraphs(doc):
    """A doc comment as whitespace-normalized paragraphs."""
    if not doc:
        return []
    lines = doc if isinstance(doc, list) else doc.split("\n")
    out, current = [], []
    for line in lines:
        stripped = line.strip()
        if stripped:
            current.append(stripped)
        elif current:
            out.append(" ".join(current))
            current = []
    if current:
        out.append(" ".join(current))
    return out


def prose(doc):
    """Every paragraph before the first markdown heading.

    The heading is where a prelude doc comment stops addressing its caller
    and starts addressing its maintainer: `## Examples` and the doctest
    beneath it, in every case in the prelude today.
    """
    out = []
    for paragraph in paragraphs(doc):
        if paragraph.startswith("#"):
            break
        out.append(paragraph)
    return out


def doc_block(doc, indent):
    lines = []
    for index, paragraph in enumerate(prose(doc)):
        if index:
            lines.append(indent + "///")
        width = WIDTH - len(indent) - 4
        for line in textwrap.wrap(paragraph, width):
            lines.append(indent + "/// " + line)
    return lines


def first_sentence(text):
    """The purpose line: everything up to the first sentence-ending period.

    The prelude's module docs all open `\\`cap/x\\` — purpose.`, so this cut
    is the house convention read back rather than a guess at where prose
    stops being useful.
    """
    match = re.search(r"\.(\s|$)", text)
    return text if not match else text[: match.start() + 1]


def type_parameters(count):
    if not count:
        return ""
    return "(" + ", ".join(var_name(i) for i in range(count)) + ")"


def parameter_list(parameters, here, aliases):
    rendered = []
    for parameter in parameters:
        label = parameter.get("label")
        prefix = label + ": " if label else ""
        rendered.append(prefix + render_type(parameter["type"], here, aliases))
    return ", ".join(rendered)


def render_module(module, body, aliases, all_modules):
    """One module, rendered twice: the whole surface and its types alone.

    The two renderings are the same lines cut at one point, not two
    passes: `header` is the heading and the purpose line, `types` the
    `pub type` declarations, and `rest` the constants and functions. The
    description pastes header + types and the `cap://` scheme reads out
    all three, so the block a model reads on demand is a superset of the
    block it was shown, character for character, rather than a second
    rendering that can disagree with the first.
    """
    header = ["### " + module]
    summary = paragraphs(body.get("documentation"))
    if summary:
        header.extend(textwrap.wrap(first_sentence(summary[0]), WIDTH))
    header.append("")

    lines = []
    for name in sorted(body.get("type-aliases", {})):
        alias = body["type-aliases"][name]
        lines.extend(doc_block(alias.get("documentation"), ""))
        head = "pub type " + name + type_parameters(alias.get("parameters", 0))
        target = alias["alias"]
        # A re-export of a type from outside the prelude has no right-hand
        # side worth printing: `cap/report.Value` aliases
        # `core/msgpack.MsgPackValue`, and a program cannot import
        # `core/msgpack`, so `= MsgPackValue` names something that resolves
        # nowhere it can reach — while the reverse-alias map has already put
        # `Value` into every signature that mentions the type. The alias
        # therefore renders as a bare name, which is the caller's actual
        # situation: reached only through the module's own functions.
        reachable = (
            target.get("kind") != "named"
            or target.get("module") == "gleam"
            or target.get("module") in all_modules
        )
        if reachable:
            lines.append(head + " = " + render_type(target, module, aliases))
        else:
            lines.append(head)

    for name in sorted(body.get("types", {})):
        declaration = body["types"][name]
        lines.extend(doc_block(declaration.get("documentation"), ""))
        head = "pub type " + name + type_parameters(declaration.get("parameters", 0))
        constructors = declaration.get("constructors") or []
        # No constructors means opaque (or external): the caller sees the
        # name and reaches it only through the module's own functions,
        # which is exactly what an empty body says.
        if not constructors:
            lines.append(head)
            continue
        lines.append(head + " {")
        for constructor in constructors:
            lines.extend(doc_block(constructor.get("documentation"), "  "))
            parameters = constructor.get("parameters") or []
            arguments = parameter_list(parameters, module, aliases)
            suffix = "(" + arguments + ")" if parameters else ""
            lines.append("  " + constructor["name"] + suffix)
        lines.append("}")

    types = lines
    lines = []
    for name in sorted(body.get("constants", {})):
        constant = body["constants"][name]
        lines.extend(doc_block(constant.get("documentation"), ""))
        lines.append(
            "pub const " + name + ": " + render_type(constant["type"], module, aliases)
        )

    for name in sorted(body.get("functions", {})):
        function = body["functions"][name]
        lines.extend(doc_block(function.get("documentation"), ""))
        arguments = parameter_list(function.get("parameters") or [], module, aliases)
        lines.append(
            "pub fn "
            + name
            + "("
            + arguments
            + ") -> "
            + render_type(function["return"], module, aliases)
        )

    rest = lines
    whole = "\n".join(header + types + rest).rstrip() + "\n"
    typed = "\n".join(header + types).rstrip() + "\n"
    return whole, typed


def gleam_string(text):
    """`text` as a Gleam string literal, newlines and all.

    Gleam string literals carry literal newlines, so the artifact stays
    readable as the text it is rather than as one escaped line. Only the
    backslash and the double quote need escaping.
    """
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: gen-prelude.py <package-interface.json>")
    with open(sys.argv[1]) as handle:
        interface = json.load(handle)
    modules = interface["modules"]
    aliases = build_alias_map(modules)

    whole_entries, typed_entries = [], []
    for module in sorted(modules):
        whole, typed = render_module(module, modules[module], aliases, set(modules))
        whole_entries.append(
            "  #(" + gleam_string(module) + ", " + gleam_string(whole) + "),"
        )
        typed_entries.append(
            "  #(" + gleam_string(module) + ", " + gleam_string(typed) + "),"
        )

    out = sys.stdout
    out.write(
        "/// Every module of the capability prelude, in the order the\n"
        "/// compiler reports them, paired with its public surface rendered\n"
        "/// for a model to read.\n"
        "///\n"
        "/// Unfiltered on purpose: `tools/codemode` selects from this list\n"
        "/// through the seam's own `allowed_imports`, so the one place that\n"
        "/// decides what a model is shown is the one place that already\n"
        "/// knows what vetting will accept. `cap/runtime` is in here and is\n"
        "/// on neither seam's allowlist; it must never reach a description.\n"
        "///\n"
        "/// This is the whole surface, which is what `cap://<module>` reads\n"
        "/// out on demand. What the tool description carries is the shorter\n"
        "/// `type_surfaces` below.\n"
        "pub const surfaces: List(#(String, String)) = [\n"
    )
    out.write("\n".join(whole_entries))
    out.write("\n]\n\n")
    out.write(
        "/// The same modules in the same order, cut after their `pub type`\n"
        "/// declarations: the heading, the module's purpose line, and the\n"
        "/// types with their docs, and nothing else.\n"
        "///\n"
        "/// This is what the `code_mode` description renders. A description\n"
        "/// is the byte prefix of the provider's cached region, paid on\n"
        "/// every request of every strand, and the functions are the bulk of\n"
        "/// a module's surface while the types are what a program cannot\n"
        "/// work around: a signature can be read from `cap://<module>` when\n"
        "/// it is wanted, but a field name guessed wrong is a compile the\n"
        "/// model pays for either way.\n"
        "///\n"
        "/// Each entry is a prefix of its `surfaces` counterpart, so the\n"
        "/// block a model reads on demand extends the block it was shown\n"
        "/// rather than restating it differently.\n"
        "pub const type_surfaces: List(#(String, String)) = [\n"
    )
    out.write("\n".join(typed_entries))
    out.write("\n]\n")


if __name__ == "__main__":
    main()
