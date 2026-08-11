# Tira token-efficiency enhancements: CA01 to CA20

## The whole purpose of all twenty

**Every one of these exists to stop an agent paying for bytes it did not ask for.**

Tira is read far more often than it is written, and it is read by LLM agents whose cost is
proportional to the size of what comes back. Today almost every read is all-or-nothing: to learn
one ticket's column you receive its description, its comments, its gate log, its evidence and its
attachments — often tens of kilobytes to answer a question whose answer is one word. A watcher that
polls every five minutes pays that price 288 times a day to discover that nothing changed.

The twenty proposals fall into four groups, and they compound rather than overlap:

1. **Ask for less** (CA01, CA02, CA03, CA07, CA08, CA09, CA10, CA11, CA12, CA17, CA20) — field
   selection, presets and truncation, so a caller receives what it needs and no more.
2. **Do not send what has not changed** (CA04, CA05, CA06, CA13, CA18) — timestamps, hashes and
   caching, so an unchanged board costs almost nothing to check.
3. **Send it more densely** (CA14, CA15) — a compact default format and no empty fields, which is
   pure saving with no loss of information.
4. **Ask once instead of many times** (CA16, CA19) — server-side filtering and batch reads, so N
   questions become one call.

**The measured motivation.** On 2026-08-06 a single session ran `tira.export` roughly forty times.
Each call returns all 138 records in full — every description, every comment body, every gate entry.
The great majority of those calls needed `ref`, `column` and `sdlc_gate` alone. CA01 and CA03
together would have reduced that traffic by something close to two orders of magnitude, and the
watcher in CA04 would have removed most of the calls entirely.

**A principle that runs through all twenty.** None of them removes information — every one is
opt-in, and the full payload remains available by asking for it. The change is only that *asking for
everything becomes a choice rather than the default*. A tool whose cheapest call is its largest one
trains its callers to be wasteful, and an LLM agent cannot compensate by being careful: it pays for
what arrives, not for what it reads.

---

## CA01 - Field selection on every read

**Description.** Every `show` command returns the complete record: 36 keys, including description,
comments, gate log, evidence and attachments. There is no way to ask for a subset. To answer "what
column is this in?" a caller receives everything the ticket has ever accumulated.

**Expectation.** `--fields` takes a comma-separated list, repeatable, and the response contains only
those keys. Unknown field names are an error rather than silently ignored, so a typo cannot quietly
return an empty object.

**Definition of done.** `d2 tira.ticket.show --ref ZSD-1 --fields column` returns a payload
containing exactly one key besides `ref`. Byte size is at least an order of magnitude smaller than
the unscoped call on a ticket with comments. A misspelled field name exits non-zero and names the
offending field.

**Use cases.**

1. `d2 tira.ticket.show --ref ZSD-136 --fields column -o json` → `{"ref":"ZSD-136","column":"final-check"}`. Format: JSON object. Purpose: the commonest question on the board, currently the most expensive.
2. `d2 tira.ticket.show --ref ZSD-136 --fields column,sdlc_gate,assignee -o json` → three keys. Purpose: the alignment check the board watcher performs on every ticket, every run.
3. `d2 tira.ticket.show --ref ZSD-136 --fields title -o human` → one line. Purpose: rendering a reference in a report without pulling the body.
4. `d2 tira.epic.show --ref ZEPG-1 --fields column -o json` → one key. Purpose: an epic's column is its children's permission to work, so this is read before every child action.
5. `d2 tira.ticket.show --ref ZSD-136 --fields acceptance_criteria -o json` → the AC array alone. Purpose: a final check reads the criteria without the 12,000-character description.
6. `d2 tira.ticket.show --ref ZSD-136 --fields parent -o json` → one key. Purpose: deciding whose final check it is, which is a parent lookup.
7. `d2 tira.ticket.show --ref ZSD-136 --fields attachments -o json` → attachment list only. Purpose: confirming evidence exists without reading the record.
8. `d2 tira.ticket.show --ref ZSD-136 --fields nosuchfield` → exit 2, `unknown field: nosuchfield`. Purpose: a typo must fail loudly, never return an empty result that reads as absence.
9. `d2 tira.ticket.show --ref ZSD-136 --fields column --fields gate -o json` → repeated flags accumulate. Purpose: consistency with `search` and `replace`, which already accumulate.
10. `d2 tira.sow.show --ref SOW-1 --fields column -o json` → same behaviour on every record type. Purpose: one contract across SOW, epic and ticket, so a caller needs no special cases.

---

## CA02 - Exclude fields

**Description.** The inverse of CA01, and often the more useful one. A caller frequently wants
*everything except* the three or four fields that carry almost all the bytes. Naming twenty fields
to omit four is worse than naming the four.

**Expectation.** `--exclude-fields` is repeatable and composes with `--fields` (exclusion applied
after selection). Excluding a field that does not exist is an error, for the same reason as CA01.

**Definition of done.** `--exclude-fields description,comments,gate_passing_log,evidence` returns a
record with every other key intact and is dramatically smaller on a mature ticket. Combining
`--fields` and `--exclude-fields` behaves as documented rather than as an accident.

**Use cases.**

1. `d2 tira.ticket.show --ref ZSD-136 --exclude-fields description,comments -o json` → full record minus the two largest fields. Purpose: the standard "read the ticket" call for an agent picking work up.
2. `d2 tira.ticket.show --ref ZSD-136 --exclude-fields gate_passing_log,evidence -o json` → structure without the append-only logs. Purpose: the logs grow without limit and are rarely what a reader wants.
3. `d2 tira.ticket.show --ref ZSD-136 --exclude-fields comments -o json` → everything but 87 comment bodies. Purpose: reading the specification without the running log.
4. `d2 tira.export --exclude-fields description,comments -o json` → whole board, structure only. Purpose: the single highest-value call in this document.
5. `d2 tira.ticket.list --full --exclude-fields description -o json` → full records, no prose. Purpose: bulk analysis where the prose is never read.
6. `d2 tira.ticket.show --ref ZSD-136 --fields description --exclude-fields description -o json` → empty result, documented. Purpose: the interaction is defined rather than surprising.
7. `d2 tira.ticket.show --ref ZSD-136 --exclude-fields attachments -o json` → record without attachment metadata. Purpose: attachment lists are long on evidence-heavy tickets.
8. `d2 tira.epic.show --ref ZEPG-1 --exclude-fields comments -o json` → an epic's 104 comments omitted. Purpose: epics accumulate comments faster than tickets, since children report into them.
9. `d2 tira.ticket.show --ref ZSD-136 --exclude-fields nosuchfield` → exit 2. Purpose: symmetry with CA01's failure behaviour.
10. `d2 tira.ticket.show --ref ZSD-136 --exclude-fields description --exclude-fields comments -o json` → repeated flags accumulate. Purpose: consistency across the tool.

---

## CA03 - Field selection on export

**Description.** `tira.export` is the single most expensive call in the tool: every record, every
field, in one payload. It is also the most useful, because it answers board-wide questions in one
round trip. Today those two facts are in tension and callers choose the expensive option because it
is the only one.

**Expectation.** `--fields` and `--exclude-fields` behave on `export` exactly as on `show`.

**Definition of done.** `d2 tira.export --fields ref,column -o json` returns 138 two-key objects and
is small enough to read on every sweep without hesitation. The full export is unchanged when no
flags are given.

**Use cases.**

1. `d2 tira.export --fields ref,column -o json` → the whole board's shape. Purpose: FT99's core question, currently answered by downloading everything.
2. `d2 tira.export --fields ref,column,sdlc_gate -o json` → gate alignment across the board in one call. Purpose: the board watcher's entire job.
3. `d2 tira.export --fields ref,parent -o json` → the hierarchy. Purpose: computing which epic owns which ticket, needed by the final-check owner check.
4. `d2 tira.export --fields ref,assignee,column -o json` → who owes what. Purpose: the assignee mismatch check.
5. `d2 tira.export --exclude-fields description,comments,gate_passing_log,evidence -o json` → structure only. Purpose: bulk reconciliation without prose.
6. `d2 tira.export --fields ref,start_date,due_date -o json` → the date audit. Purpose: checking the start/end date rule across every ticket.
7. `d2 tira.export --fields ref,labels -o json` → label coverage. Purpose: confirming the Zenandi-Developer label rule.
8. `d2 tira.export --fields ref,checklist -o json` → every checklist. Purpose: "what is left?" across the board.
9. `d2 tira.export --fields ref,attachments -o json` → evidence coverage. Purpose: finding tickets that claim gates with nothing attached.
10. `d2 tira.export --fields ref -o json` → refs alone. Purpose: the cheapest possible existence check for a set of tickets.

---

## CA04 - Changed-since filtering

**Description.** A watcher polls the whole board every five minutes to discover what changed. On a
quiet board that is 288 full downloads a day to learn that nothing happened. The information needed
is a delta and the tool can only supply a snapshot.

**Expectation.** `--since TIMESTAMP` returns only records whose `last_updated` is at or after that
time. The response includes the server's current time, so the caller can pass it back next call
without clock-skew arithmetic.

**Definition of done.** `--since` on a quiet board returns an empty record set and a timestamp.
Making a change and re-running returns exactly the changed record. A `--since` in the future returns
empty rather than erroring.

**Use cases.**

1. `d2 tira.export --since 2026-08-06T21:00:00+01:00 -o json` → `{"records":[...],"count":N,"now":"..."}`. Purpose: the watcher's whole job in one cheap call.
2. `d2 tira.export --since <now> -o json` → `{"records":[],"count":0,"now":"..."}`. Purpose: proving a quiet board costs almost nothing.
3. `d2 tira.ticket.list --since 2026-08-06T20:00 --column final-check -o json` → recent arrivals in one column. Purpose: noticing a ticket landing in a column that owes somebody action.
4. `d2 tira.export --since <t> --fields ref,column -o json` → composes with CA03. Purpose: the two savings multiply.
5. `d2 tira.export --since 2030-01-01T00:00 -o json` → empty, exit 0. Purpose: a future timestamp is not an error.
6. `d2 tira.export --since garbage` → exit 2 naming the parse failure. Purpose: a malformed timestamp must not be silently treated as zero, which would return everything.
7. `d2 tira.epic.list --since <t> -o json` → changed epics only. Purpose: the epic-board half of the hourly sweep.
8. `d2 tira.export --since <t> -o toon` → same filtering, compact format. Purpose: composes with CA14.
9. `d2 tira.ticket.show --ref ZSD-1 --since <t> -o json` → the record, or empty if unchanged. Purpose: cheap re-read of one ticket.
10. `d2 tira.export --since <t>` repeated with the returned `now` → no gaps and no double-reporting across consecutive calls. Purpose: the property that makes a watcher correct rather than approximately correct.

---

## CA05 - Per-record content hash

**Description.** A caller that has seen a record cannot tell whether it has changed without
downloading it again. Timestamps help (CA04) but a hash is stronger: it distinguishes a real change
from a touched-but-identical record, and it works when clocks are unreliable.

**Expectation.** Every record carries a stable `content_hash` covering its meaningful fields. Reading
the same unchanged record twice yields the same hash; changing any field changes it.

**Definition of done.** `d2 tira.export --fields ref,content_hash` is small and sufficient to decide
which records need a full read. A no-op write does not change the hash.

**Use cases.**

1. `d2 tira.export --fields ref,content_hash -o json` → 138 tiny pairs. Purpose: a complete change check for a fraction of a full export.
2. `d2 tira.ticket.show --ref ZSD-1 --fields content_hash -o json` → one value. Purpose: cheapest possible "has this changed?".
3. Compare stored hashes against a fresh list, then `show` only the differing refs. Purpose: the canonical cheap-sync pattern.
4. `d2 tira.ticket.update --ref ZSD-1 --priority 4` on a ticket already at 4 → hash unchanged. Purpose: a no-op write must not look like a change.
5. `d2 tira.comment.add ...` → hash changes. Purpose: comments are content and must be covered.
6. `d2 tira.attachment.add ...` → hash changes. Purpose: attachments are content.
7. `d2 tira.export --fields ref,content_hash,column -o json` → hash plus the field most often wanted with it. Purpose: one call decides both "changed?" and "where?".
8. Two consecutive exports with no writes → identical hashes throughout. Purpose: stability is the property that makes the hash usable.
9. `d2 tira.epic.show --ref ZEPG-1 --fields content_hash` → same contract on epics. Purpose: uniformity.
10. Hash documented as opaque and not to be parsed. Purpose: prevents callers depending on its internals.

---

## CA06 - Conditional read

**Description.** Even with CA05, a caller must make a request and receive a body to learn that
nothing changed. HTTP solved this decades ago with conditional requests; a local tool can do the
same with less ceremony.

**Expectation.** `--if-changed HASH` returns the record if its hash differs and a short
"unchanged" response otherwise. Exit status distinguishes the two so a shell caller need not parse.

**Definition of done.** An unchanged conditional read produces a response of a few dozen bytes and
exit 0 with a documented marker. A changed one produces the full record.

**Use cases.**

1. `d2 tira.ticket.show --ref ZSD-1 --if-changed abc123 -o json` → `{"unchanged":true}`. Purpose: the cheapest possible poll of one ticket.
2. Same call after an edit → the full record. Purpose: the positive path.
3. `d2 tira.export --if-changed <board-hash> -o json` → `{"unchanged":true}` for the whole board. Purpose: one call replaces a whole sweep on a quiet board.
4. `--if-changed` with a malformed hash → exit 2. Purpose: a bad hash must not be treated as "changed", which would return everything and hide the error.
5. `--if-changed` composed with `--fields` → returns only the selected fields when changed. Purpose: the savings multiply.
6. Exit code 0 with `unchanged` marker, distinct from a genuine empty result. Purpose: silence and emptiness must be distinguishable.
7. `d2 tira.epic.show --ref ZEPG-1 --if-changed <h>` → same contract. Purpose: uniformity.
8. A board-level hash exposed by `export` for use in case 3. Purpose: makes the whole-board conditional read possible.
9. Documented interaction with `--since`: both may be given, and the stricter wins. Purpose: no surprising precedence.
10. `--if-changed` never writes anything. Purpose: a read path must be provably read-only.

---

## CA07 - Count-only mode

**Description.** Many questions are questions about a number: how many are parked, how many lack a
gate, how many are in final check. Answering them today means downloading every matching record and
counting locally.

**Expectation.** `--count` suppresses the records and returns the count alone.

**Definition of done.** `d2 tira.ticket.list --column backlog --count` returns a single integer in a
response of a few bytes, and that integer equals the length of the unsuppressed result.

**Use cases.**

1. `d2 tira.ticket.list --column backlog --count -o json` → `{"count":47}`. Purpose: the FT99 headline.
2. `d2 tira.ticket.list --column final-check --count -o json` → `{"count":1}`. Purpose: "does anything owe me a final check?" for a few bytes.
3. `d2 tira.search --text "no audio" --count -o json` → `{"count":3}`. Purpose: gauging a search before paying for it.
4. `d2 tira.export --count -o json` → total records. Purpose: cheap sanity check that the board is intact.
5. `--count` with `--since` → number changed since a time. Purpose: deciding whether a full sync is worth making.
6. `--count` and `--fields` together → documented as `--count` winning. Purpose: no ambiguity.
7. `d2 tira.epic.list --count` → epic total. Purpose: uniformity.
8. `d2 tira.ticket.list --assignee michael --count` → what is waiting on a person. Purpose: the assignee audit's headline.
9. `--count` returns 0 rather than erroring on no matches. Purpose: zero is an answer, not a failure.
10. `-o human` with `--count` prints a bare number. Purpose: usable directly in a shell without a parser.

---

## CA08 - A `--brief` preset

**Description.** Roughly four reads in five want the same five fields: ref, title, column, gate,
assignee. Requiring each caller to name them repeatedly invites divergence, and a caller that
cannot be bothered falls back to the full record.

**Expectation.** `--brief` is exactly that set, with the title truncated to a documented width.

**Definition of done.** `--brief` output is small, uniform across record types, and identical to the
equivalent `--fields` list, so the preset is a shorthand rather than a special case.

**Use cases.**

1. `d2 tira.ticket.show --ref ZSD-136 --brief -o human` → one line. Purpose: the default way to look at a ticket.
2. `d2 tira.export --brief -o json` → the whole board in five fields. Purpose: the standard sweep payload.
3. `d2 tira.ticket.list --column in-progress --brief -o human` → a readable table. Purpose: "what is being worked?" answered directly.
4. `d2 tira.dashboard --brief` → the board without prose. Purpose: the routine glance.
5. `--brief` documented as equal to a named `--fields` list. Purpose: no hidden behaviour.
6. `--brief` with `--fields` → error, since they contradict. Purpose: fail rather than guess.
7. Title truncation width documented and stable. Purpose: output that can be parsed.
8. `d2 tira.epic.list --brief` → same shape for epics. Purpose: uniformity.
9. `--brief` composed with `--since` → recent changes, briefly. Purpose: the watcher's ideal call.
10. `--brief` on a record with a null assignee prints an explicit marker, not an empty column. Purpose: absence must be visible.

---

## CA09 - Truncate long text by default

**Description.** Descriptions reach twelve thousand characters; gate logs and evidence grow without
bound. A caller wanting the first line pays for all of it, and usually wanted only enough to
recognise the ticket.

**Expectation.** Long text fields are truncated to a documented length with an explicit marker and a
character count. `--full` restores the complete value.

**Definition of done.** A truncated field is visibly truncated — never silently — and the original
length is reported so a caller knows what it is missing.

**Use cases.**

1. `d2 tira.ticket.show --ref ZSD-136 -o json` → `"description":"PROBLEM STATEMENT...","description_truncated":true,"description_length":12023`. Purpose: recognisable without the payload.
2. `--full` → the complete description. Purpose: the opt-in for when it is genuinely needed.
3. `--truncate 500` → a caller-chosen limit. Purpose: different tasks need different amounts.
4. `--truncate 0` → field omitted entirely but still marked present. Purpose: maximum saving without pretending the field is empty.
5. Truncation applies to `gate_passing_log` and `evidence`. Purpose: those are the fields that grow without limit.
6. A short field is returned whole with no marker. Purpose: no noise on small records.
7. Truncation happens on a character boundary, never mid-escape. Purpose: output must stay valid JSON.
8. `--full` documented as the previous behaviour. Purpose: nothing is lost, only defaulted differently.
9. Truncation never applies to `ref`, `column`, `sdlc_gate` or other short structural fields. Purpose: structure is never lossy.
10. `-o human` shows an ellipsis and the count. Purpose: a person sees immediately that there is more.

---

## CA10 - Read the last N comments

**Description.** An epic accumulates a hundred comments; reading the newest requires all of them.
The commonest question about comments — "what is the latest?" — is the most expensive to ask.

**Expectation.** `--last N` on a comment read returns the newest N in order.

**Definition of done.** `--last 1` returns exactly one comment and is small regardless of how many
the record holds.

**Use cases.**

1. `d2 tira.comment.list --ref ZEPG-1 --last 1 -o json` → the newest comment. Purpose: an epic's inbox is its comments, and only the newest is usually new.
2. `--last 5` → the recent thread. Purpose: enough context to resume without the history.
3. `--last 0` → none, with the count. Purpose: existence check with no bodies.
4. `--last N` where N exceeds the total → all of them, no error. Purpose: callers need not know the count first.
5. `--first N` for the original context. Purpose: the earliest comments carry the framing.
6. `--last` composed with `--since` → recent and new. Purpose: precise polling.
7. Ordering documented as newest-last so appending is natural. Purpose: no surprising order.
8. `--last` available wherever comments are returned, including `show`. Purpose: uniformity.
9. `d2 tira.comment.list --ref X --last 1 --fields author` → author of the newest only. Purpose: composes with CA01.
10. Comment ids remain stable and are always returned. Purpose: a caller can always fetch a specific one.

---

## CA11 - Comment metadata without bodies

**Description.** A watcher needs to know that a comment appeared and who wrote it. It does not need
the text until it decides to act. Today the two are inseparable.

**Expectation.** `--meta-only` returns id, author, timestamp and body length, and omits the body.

**Definition of done.** A record with a hundred comments returns a metadata list that is a small
fraction of the full payload and is sufficient to detect a new comment and attribute it.

**Use cases.**

1. `d2 tira.comment.list --ref ZEPG-1 --meta-only -o json` → ids, authors, times, lengths. Purpose: exactly what a change watcher needs.
2. `--meta-only` on `export` → comment metadata board-wide. Purpose: whole-board comment detection cheaply.
3. Detect a new id, then fetch that one body. Purpose: the canonical two-step, cheap then precise.
4. `--meta-only --last 5` → composes with CA10. Purpose: recent metadata only.
5. Body length included so a caller can budget before fetching. Purpose: no surprises on a huge comment.
6. Author returned exactly as stored, with the caveat documented that a UI may attribute to a configured author rather than the typist. Purpose: a real observed hazard that silently muted a person's comments.
7. `--meta-only` never truncates metadata. Purpose: metadata is small; truncating it would be false economy.
8. Attachment count per comment included. Purpose: a comment with evidence is worth reading first.
9. `-o human` prints one line per comment. Purpose: readable directly.
10. `--meta-only` with `--fields body` → error, since they contradict. Purpose: fail rather than guess.

---

## CA12 - Attachment metadata without records

**Description.** Attachment entries carry more than a caller usually needs. Checking that evidence
exists should not require reading every attachment's full record.

**Expectation.** `--meta-only` on attachments returns filename, size, content type and creation time.

**Definition of done.** An evidence-heavy ticket returns an attachment summary that is a small
fraction of the full listing.

**Use cases.**

1. `d2 tira.attachment.list --ref ZSD-136 --meta-only -o json` → 18 compact entries. Purpose: confirming evidence exists.
2. `--fields filename` → names alone. Purpose: checking a specific artifact is present.
3. `--count` → how many. Purpose: cheapest possible evidence check.
4. `d2 tira.export --fields ref,attachment_count` → coverage board-wide. Purpose: finding gates claimed with no evidence.
5. Total size returned. Purpose: budgeting before a download.
6. SHA returned so a caller can detect a re-upload of identical bytes. Purpose: the content-addressed model made visible.
7. `--since` on attachments → recent evidence. Purpose: noticing new evidence without re-reading all of it.
8. `-o human` prints name and size per line. Purpose: readable.
9. Deduplication status included. Purpose: a stored name may differ from a supplied one, which has already caused confusion.
10. Ordering by creation time, documented. Purpose: newest evidence is usually what matters.

---

## CA13 - A first-class diff command

**Description.** Every watcher written against Tira implements the same thing: snapshot, compare,
report. Each does it slightly differently and each gets some of it wrong. It is the tool's job.

**Expectation.** `tira.diff` takes two states, or a stored snapshot and the present, and reports
per-record what changed.

**Definition of done.** `tira.diff --since T` reports column moves, gate changes, new comments and
new records, in a form small enough to act on without a further read.

**Use cases.**

1. `d2 tira.diff --since 2026-08-06T21:00 -o json` → structured changes. Purpose: replaces a hand-written watcher entirely.
2. `d2 tira.diff --since T --fields column` → column moves only. Purpose: the single most-watched change.
3. `d2 tira.diff --since T --type comment` → new comments only. Purpose: a person's comment is an instruction and outranks other changes.
4. `d2 tira.diff --snapshot /path/state.json` → against a stored state. Purpose: watchers that keep their own file.
5. Output distinguishes added, changed and removed. Purpose: a deletion must never look like an absence of change.
6. `--count` on diff → how many changed. Purpose: deciding whether to look.
7. Empty diff returns an explicit empty result, not silence. Purpose: nothing-changed and could-not-check must be distinguishable.
8. Diff includes the previous and new value for scalar fields. Purpose: acting without a second read.
9. `-o human` reads as a change log. Purpose: pasteable into a report.
10. Diff never writes state; storing a snapshot is a separate explicit call. Purpose: a read must not have side effects.

---

## CA14 - A compact output format by default

**Description.** Pretty-printed JSON spends a meaningful fraction of its bytes on whitespace and
repeated key names. For a human that is worth paying; for an agent it is pure cost.

**Expectation.** The default machine format is compact. Pretty output remains available explicitly.

**Definition of done.** The default `-o json` payload is measurably smaller than today's on the same
data, with identical information.

**Use cases.**

1. `d2 tira.export -o json` → compact. Purpose: the default becomes the cheap option.
2. `d2 tira.export -o json-pretty` → today's format. Purpose: nothing lost for human reading.
3. `d2 tira.export -o toon` → the densest available. Purpose: maximum saving where a parser exists.
4. Documented byte comparison across formats. Purpose: a caller can choose knowingly.
5. Compact output remains valid JSON. Purpose: no custom parser required.
6. `-o human` unchanged. Purpose: people are unaffected.
7. Unicode not escaped unnecessarily. Purpose: escaping inflates non-ASCII text considerably.
8. Key order stable across calls. Purpose: makes diffing and hashing possible.
9. The format flag documented as affecting only presentation. Purpose: no information difference between formats.
10. A stderr warning does not corrupt stdout in any format. Purpose: an observed hazard that breaks JSON parsing today.

---

## CA15 - Omit empty fields

**Description.** A record with thirty-six keys, twenty of them empty strings or empty arrays, spends
most of its size saying nothing. Absence is already representable by omission.

**Expectation.** Null and empty values are omitted by default; `--include-empty` restores them.

**Definition of done.** A sparse record is substantially smaller, and a caller can still distinguish
"absent" from "present but empty" through a documented rule.

**Use cases.**

1. `d2 tira.ticket.show --ref ZSD-1 -o json` → only populated keys. Purpose: sparse records become cheap.
2. `--include-empty` → today's shape. Purpose: callers depending on fixed keys are not broken.
3. `d2 tira.export -o json` → the saving multiplied across every record. Purpose: the largest single win on a sparse board.
4. Documented rule for distinguishing absent from empty. Purpose: the one real risk of this change, addressed explicitly.
5. Empty arrays omitted as well as empty strings. Purpose: most empties are arrays.
6. `false` and `0` are never treated as empty. Purpose: a classic and costly bug.
7. `--include-empty` composes with `--fields`. Purpose: no surprising interactions.
8. `-o human` unaffected, since it already omits blanks. Purpose: people see no change.
9. Schema documentation lists every possible key. Purpose: omission must not make discovery harder.
10. A newly created record returns only what was set. Purpose: shows immediately which fields still need filling.

---

## CA16 - Server-side filtering on any field

**Description.** A caller that wants "every ticket in backlog with no gate" must download every
ticket and filter locally. The filtering is trivial; the download is not.

**Expectation.** `--where FIELD=VALUE`, repeatable and combined with AND, on any scalar field, with
support for absence and inequality.

**Definition of done.** A query returning three records costs about what three records cost, not
what the whole board costs.

**Use cases.**

1. `d2 tira.ticket.list --where column=backlog --where sdlc_gate= -o json` → parked tickets with no gate. Purpose: the alignment check, in one cheap call.
2. `--where assignee=michael` → what waits on a person. Purpose: the assignee audit.
3. `--where priority=5` → highest priority only. Purpose: triage.
4. `--where parent=ZEPG-1` → an epic's children. Purpose: currently requires a full export.
5. `--where sdlc_gate!=G13 --where column=done` → done tickets whose gate disagrees. Purpose: finding a board that is confidently wrong.
6. `--where labels~Zenandi-Developer` → containment on arrays. Purpose: label coverage.
7. `--where start_date=` → tickets with no start date. Purpose: the date rule audit.
8. Filters compose with `--fields` and `--count`. Purpose: the savings multiply.
9. An unknown field in `--where` → exit 2. Purpose: a typo must not silently match nothing and read as "none exist".
10. Filter semantics documented exactly, including how empty is expressed. Purpose: ambiguity here produces confidently wrong answers.

---

## CA17 - Refs-only output

**Description.** Sometimes the only thing wanted is which records match. The refs are a few bytes
each; the records are not.

**Expectation.** `--refs-only` returns a flat array of refs.

**Definition of done.** The response is a small array, and its contents equal the refs of the full
result.

**Use cases.**

1. `d2 tira.ticket.list --column backlog --refs-only -o json` → `["ZSD-5","ZSD-9",...]`. Purpose: knowing which, without any detail.
2. `--refs-only` with `--where` → a filtered ref list. Purpose: the input to a batch read (CA19).
3. `d2 tira.search --text "audio" --refs-only` → matching refs. Purpose: a cheap search result.
4. `--refs-only` with `--since` → recently changed refs. Purpose: a watcher's shortlist.
5. `-o human` prints one ref per line. Purpose: pipes directly into a shell loop.
6. `--refs-only` with `--count` → count wins, documented. Purpose: no ambiguity.
7. Empty result is an empty array, not null. Purpose: callers need not special-case.
8. Ordering documented and stable. Purpose: reproducible output.
9. `d2 tira.epic.list --refs-only` → same on epics. Purpose: uniformity.
10. Refs returned exactly as stored, never normalised. Purpose: refs are identity and must not be altered.

---

## CA18 - Read-through cache with a version stamp

**Description.** A single sweep may call `export` several times within a minute for different
purposes. Each is a full read of data that has not changed between them.

**Expectation.** An optional on-disk cache keyed by a board version, refreshed when the board
changes, with a documented staleness bound and an explicit bypass.

**Definition of done.** Repeated identical calls within the window are served locally and are
measurably faster; a write invalidates the cache immediately so a caller never reads its own stale
data.

**Use cases.**

1. `d2 tira.export -o json` twice in ten seconds → second served from cache. Purpose: the commonest waste.
2. `d2 tira.export --no-cache` → always fresh. Purpose: the explicit bypass when correctness matters more.
3. A write between two reads → second read is fresh. Purpose: read-your-own-writes, without which the cache is dangerous.
4. `--cache-ttl N` → caller-chosen window. Purpose: different tasks tolerate different staleness.
5. Cache reports whether a response was served from it. Purpose: never invisible, so a stale answer can always be recognised.
6. Cache stored under the workspace, not a shared temp path. Purpose: agents share `/tmp` and have already collided there.
7. Corrupt cache falls back to a live read and warns. Purpose: a cache must never be able to break the tool.
8. Cache disabled by default until proven. Purpose: correctness before saving.
9. Cache keyed by the full argument set. Purpose: two different queries must never share an entry.
10. Documented interaction with `--since` and `--if-changed`. Purpose: these features must not silently defeat each other.

---

## CA19 - Batch reads

**Description.** Reading six tickets means six invocations, six process starts and six payloads.
The refs are known in advance and the work is one query.

**Expectation.** `--ref` is repeatable, or `--refs` takes a list, and the response is keyed by ref.

**Definition of done.** One call returns all requested records; a missing ref is reported explicitly
rather than silently omitted.

**Use cases.**

1. `d2 tira.ticket.show --ref ZSD-1 --ref ZSD-2 --ref ZSD-3 -o json` → three records keyed by ref. Purpose: one call instead of three.
2. `--refs ZSD-1,ZSD-2,ZSD-3` → same, comma-separated. Purpose: convenient from a shell.
3. Batch with `--fields column` → the columns of a named set. Purpose: composes with CA01.
4. A missing ref appears with an explicit not-found marker. Purpose: silent omission would read as a record that exists but is empty.
5. Batch with `--brief` → a readable table of a named set. Purpose: reporting on a group.
6. Batch across types in one call, or a documented refusal. Purpose: no surprising partial behaviour.
7. Order of results matches the order requested. Purpose: predictable output.
8. A documented maximum batch size, with a clear error beyond it. Purpose: no silent truncation, which is the failure that made a paging bug invisible.
9. Batch composes with `--if-changed` per ref. Purpose: cheap group polling.
10. Partial failure reports which refs failed and still returns the rest. Purpose: one bad ref must not lose the whole call.

---

## CA20 - Indexed reads on gate log and evidence

**Description.** Gate log and evidence are append-only and grow without limit. They are among the
largest fields on a mature ticket, and a caller almost always wants the newest entry.

**Expectation.** `--last N`, `--first N` and read-by-id on both fields.

**Definition of done.** Reading the newest gate entry is small and constant in cost regardless of
how many entries exist.

**Use cases.**

1. `d2 tira.gate.list --ref ZSD-136 --last 1 -o json` → the newest gate entry. Purpose: "what gate did it last pass?" cheaply.
2. `--last 3` → recent history. Purpose: enough to see a trend without the whole log.
3. `d2 tira.gate.list --ref X --id GATE-002` → one entry by id. Purpose: precise retrieval.
4. `d2 tira.evidence.list --ref X --last 1` → newest evidence. Purpose: symmetry with gates.
5. `--count` on both → how many entries. Purpose: cheapest possible existence check.
6. `--meta-only` → ids, results, timestamps without the details text. Purpose: gate details are long and rarely needed in bulk.
7. `--where result=fail` → failures only. Purpose: composes with CA16, and failures are what matter.
8. Ordering documented, newest last. Purpose: appending is the natural mental model.
9. Annotations returned with their parent entry, or separately on request. Purpose: annotations are corrections and must not be lost.
10. Reading never mutates; there is no read side effect on an append-only field. Purpose: the append-only guarantee must hold for readers too.

---

## Closing note

**Highest value first, if only a few are built.** CA01 and CA03 (field selection on reads and on
export) remove the largest single waste and are the simplest to specify. CA04 and CA05
(changed-since and content hashes) remove most of the remaining waste for anything that polls.
CA15 (omit empty fields) is close to free and helps every call. Everything else builds on those four.

**One caution that applies to all twenty.** Every proposal here makes the cheap path cheaper, and
none should make the *correct* path harder to reach. Where a saving and a correctness guarantee
conflict — caching versus reading your own writes, truncation versus completeness, filtering versus
knowing what was filtered out — the correctness guarantee wins, and the saving is opt-in. A tool that
is cheap and occasionally wrong costs far more than one that is expensive and always right, because
the wrong answers are discovered late and by somebody else.
