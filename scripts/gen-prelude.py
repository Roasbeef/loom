#!/usr/bin/env python3
"""Render the capability prelude's public surface, per module, as Gleam.

Input is `gleam export package-interface` over `packages/cap` — the
compiler's own view of what it will accept, which is the only source that
cannot drift from what a submitted program is compiled against. Output is
the body of `packages/tools/src/tools/prelude.gleam`: one rendered block
per module, keyed by module name, for `tools/codemode` to filter through
a seam's allowlist and paste into the `code_mode` description.

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

Type declarations *are* included, at about 1,640 tok per seam, and that is
the largest single line item here. They were not in the estimate this work
was scoped against (issue #36 measured function signatures and their docs
alone). They are not optional: `proc.run` returns a `proc.Output`, and a
program that cannot name the `stdout` field cannot read the output it just
paid for. A signature without the record it returns is a contract half
stated.
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
    lines = ["### " + module]
    summary = paragraphs(body.get("documentation"))
    if summary:
        lines.extend(textwrap.wrap(first_sentence(summary[0]), WIDTH))
    lines.append("")

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

    return "\n".join(lines).rstrip() + "\n"


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

    entries = []
    for module in sorted(modules):
        rendered = render_module(module, modules[module], aliases, set(modules))
        entries.append(
            "  #(" + gleam_string(module) + ", " + gleam_string(rendered) + "),"
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
        "pub const surfaces: List(#(String, String)) = [\n"
    )
    out.write("\n".join(entries))
    out.write("\n]\n")


if __name__ == "__main__":
    main()
