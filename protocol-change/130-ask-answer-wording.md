# protocol-change/130: an ask's answer is delivered as readable text

**Status**: ACCEPTED 2026-11-23. The owner asked for it after using a release
on 2026-11-23, and accepted the fix in the same session.
**Affects**: the text of the prompt that carries an answer to the asking strand
(`core/attention_answer.prompt_text`, whose first parameter is now the ask
rather than its id); one sentence of the `ask` tool's description
(`tools/attention`). No stored record, control command, wire frame, event or
`loom.toml` key changes. The submitted answer (`attention.answer`'s `answer`
object, and the page's form) is unchanged, and so is the stored `Answer`.
**Amends**: [119](119-attention-records.md), "The answer", the paragraph that
specifies the prompt's text and its fenced object.

## Problem

Protocol-change/119 delivered an answer as the sentence "Answer to ask-…:"
followed by one fenced JSON object, `{"ask", "answers", "other"}`. The prompt
is an ordinary user message, so every client draws it in the transcript as the
person's message. After answering an ask on the release, the owner read this in
their session's transcript:

~~~text
Answer to ask-b0244f75fb:

```json
{"ask":"ask-b0244f75fb","answers":{"q1":null},"other":{"q1":"already answered"}}
```
~~~

The transcript is where the person reads what they told the agent. It showed a
wire record with a `null` where their words belonged, and it did not show the
question they had answered.

## What was considered

- **Keep the JSON and teach each client to draw it.** The web view, the
  terminal and the desktop app would each recognise the message, find the ask
  by its id and draw the question with the answer. That is three renderers of
  one format, each needing the ask's record, including after the ask is
  answered and pruned. Any client that does not do it, such as a transcript
  export, still shows the wire record.
- **Send JSON to the model and readable text to the transcript.** The
  transcript records what the model was sent; two texts would make the
  transcript no longer the authoritative copy that 119 says it is.
- **Word the prompt for both readers.** Chosen. The model does not need a JSON
  object to read which option was picked when the label is quoted exactly as
  the ask offered it.

## Decision

The prompt is a line naming the ask, then each question in order, numbered,
with its answer under it, indented three spaces:

```text
Answer to your ask ask-3f9c01a2b4.

1. Retry?
   Yes

2. Which branch?
   "topic"

3. Which files?
   "a.gleam", "b.gleam"

4. Anything else?
   Other (not one of the options): Do it in a branch instead.
```

The answer under a question is:

| The question's answer | Words |
| --- | --- |
| `confirm` | `Yes` or `No` |
| `choice` | the label, in double quotes |
| `multiple`, `checklist` | the labels in double quotes, separated by `, `; `None of the options` for an empty checklist |
| `fill` | the text as typed |
| Other, for any kind | `Other (not one of the options): ` and the text |

A question or a person's text that spans lines keeps its lines, and each later
line is indented three spaces, so a line of the person's text cannot read as
the next numbered question. The ask's id stays on the first line, so a strand
with more than one open ask can tell which one this answers.

Validation is unchanged: `core/attention_answer.check` still measures the whole
prompt against `max_prompt_bytes`, now with the questions' text in it.

The `ask` tool's description says how the answer arrives: a message from the
person that names the ask's id and lists each question, numbered, with the
answer under it.

## What it costs

- The prompt is longer by the questions' text. An ask holds at most four
  questions, and the bound is checked on the whole text as before.
- The answer is no longer machine-parseable from the transcript. Nothing read
  it back: the stored record holds the typed `Answer` (119), and that is what
  the feed and every client read.
- A session that was asked before this change and answered after it reads the
  new wording. The tool description it was given said a fenced object; the
  new text names the ask and the answers plainly, so it is still readable.

## As built

- `core/attention_answer.prompt_text(ask, values)` builds the text;
  `client/daemon/attention_door` passes the ask.
- Tests: `core/test/core/attention_answer_test` pins the whole text for one
  answer of each kind, an Other with two lines, an empty checklist and a `No`;
  `client/test/client/daemon_attention_test` checks the delivered prompt's
  first line; `tools/test/tools/attention_test` checks the description.
