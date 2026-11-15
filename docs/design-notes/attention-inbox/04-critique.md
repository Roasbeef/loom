# The critique round

**Status: how the four concepts are judged.** Two critics read all four
concepts side by side, each through one lens, without seeing the other's
review. Each designer then receives both reviews of their own concept and
revises once. A final judge ranks the revised concepts and names the top of
the bracket for the owner.

A critic reviews against the brief (`03-brief.md`) and its rulings, not
against personal taste. A finding is worth writing only if it names the
place (a section of the note, a region of a screenshot), says what goes
wrong for whom, and says what would fix it.

## Lens 1: the owner at 14:20

The critic plays the owner: a person running six to twenty sessions, back
after three hours, who rejected busy designs before and finds reading
transcripts a drag. Judge from the screenshots first and the note second,
because that is the order the owner meets them.

1. **Ten-second read.** From `desktop-light.png` alone, can you say what
   needs you, how many, and which first? Write down what you actually read
   in ten seconds.
2. **Answer without context.** Can each of the four "needs you" items be
   decided from what the item shows, without opening a transcript? Where
   not, what is missing?
3. **Calm.** Does it show too much at once? Count the distinct regions and
   the distinct colours carrying meaning in the default view.
4. **Presses and screens** to clear the scenario. Check the note's count
   against the mockup.
5. **Scale.** Imagine twenty sessions and three coordinators. What breaks
   first?
6. **Phone.** Could you clear the approval and the two asks on the phone?
7. **Trust.** Does the design make it clear what a press will send, to
   whom, and that it arrived?

## Lens 2: does it fit Loom

The critic is a senior engineer on Loom. Judge from the note, checking the
fact sheet's citations where a claim is load-bearing.

1. **Phase 0 honesty.** Does phase 0 really use only existing signals?
   Name any phase-0 claim that needs a substrate piece or a wire change.
2. **Logic placement.** Does any rule about what a session's state means
   live in `web_view` instead of `session_view`?
3. **Roles and consent.** Is every deciding control owner/operator-only and
   two-press? Does any approval decision bind to something other than the
   record's digest and drawn sequence? Can session text reach markup or a
   list key?
4. **Substrate discipline.** Does the concept need more than the three
   shared additions? Is that need argued, or incidental?
5. **Protocol cost.** List the protocol changes the concept needs and what
   each decides. Is any of them large, contested or security-sensitive?
6. **Server-component realism.** Lustre server components re-render on the
   server and patch the browser; region tree paths are load-bearing. Does
   the design depend on rich client interaction (drag, text selection
   annotation, local optimistic state) that a server component makes
   expensive?
7. **Build cost.** A rough size for phase 0 and phase 1, in pull requests
   of the size this repo lands.

## Output of each critic

One file per lens, `critique-owner.md` and `critique-loom.md`, with:

1. A table: concept × each numbered question, a score from 1 to 5 and a
   one-line reason.
2. Per concept, the three most important findings, most severe first,
   each with place, harm and fix.
3. A **steal list**: the single best idea in each concept that a winner
   should take.
4. The critic's ranking with a paragraph of reasons.

## Revision and the final judge

Each designer receives both critiques of their concept and the steal list,
revises the note and the mockup once, and appends a short *Revision*
section saying what changed and what was rejected and why. The judge then
reads the four revised notes, the screenshots and both critiques, and
writes `ranking.md`: the ranking, the top of the bracket (two or three
concepts) for the owner, a hybrid if one is clearly better than any
single concept, and the questions the owner must answer to choose.
