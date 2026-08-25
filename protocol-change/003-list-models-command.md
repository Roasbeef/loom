# protocol-change/003 — add `models` to the client command set

**Status**: ACCEPTED 2026-08-25 · **Affects**: Part 1.6 client protocol ·
**Raised by**: the client-plane documentation pass ·
**Implemented**: `client/protocol` (already shipped) + spec text

## Problem

Part 1.6 freezes the client command set as thirteen names:

```
"prompt"|"steer"|"follow_up"|"abort"|"approve"|"deny"|"fork"|"navigate"
|"compact"|"create_strand"|"set_config"|"subscribe"|"catch_up"
```

The implementation speaks fourteen. `models` was added with the model
catalogue so a client can list what an operator configured — it is what
the terminal client's `:models` picker calls before offering a choice —
and the spec text was never amended. Nothing about the addition was
wrong; the omission of a proposal was. The root ground rules say
interfaces in spec Part 1 are frozen and that changing one requires a
proposal, *never silent drift*, and this is exactly the drift that rule
exists to catch. It was found by writing the client plane up as built and
comparing the result against the frozen list, not by anything failing.

## Proposal

Ratify the fourteenth command as shipped:

```
c→s: {v:1, id, cmd: ... |"models", body: {}}
```

`models` takes an empty body and is answered with a reply carrying the
catalogue's entries and the role table, so a client can render a picker
without reading the operator's configuration file itself. It is a
read-only query: it commits nothing, starts no operation, and touches no
strand, which is why it needs no scoping fields.

## Impact

None on the durable format and none on any other plane. The command is
already implemented and covered by the golden protocol fixtures; this
proposal aligns the normative text with what ships. A client written to
the old thirteen keeps working, since it simply never sends the
fourteenth.

## Decision

**Accepted**, and worth stating why rather than merely recording it. The
alternative — folding a catalogue listing into `set_config` or a
general-purpose query command — was considered and dismissed. Overloading
`set_config`, whose every other use commits durable strand
configuration, would give one command two natures: a query and a write.
A generic query command would need a discriminator that reinvents the
command name it was meant to avoid. A read-only command with an empty
body is the smaller thing.

The process lapse is the more useful lesson. The catalogue work reached
the wire through the gateway, the protocol codec, the golden fixtures,
and the terminal client without anyone checking the frozen list, because
every one of those layers was consistent with the others. Consistency
across an implementation is not ratification. A doc pass caught it here;
a fixture regenerated from the codec would not have.
