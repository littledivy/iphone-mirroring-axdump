# 01 — dtrace sniffer (the original idea)

The first approach: passively sniff iPhone Mirroring's accessibility queries with
dtrace and rebuild the iOS tree from what it observes.

`sniff.d` hooks `AXPMacPlatformElement` methods inside the Mirror process and
prints tab-separated records; `consumer.go` folds them into an in-memory tree.

## Run

1. Start iPhone Mirroring.
2. Start VoiceOver (needed — the sniffer is passive; with no assistive client
   querying the tree, nothing is emitted).
3. `sudo dtrace -p $PID -s ./sniff.d > /tmp/axstream.txt 2>/dev/null`

## Why it was abandoned

- **Passive** — only captures attributes some *other* client (VoiceOver)
  requests. No VoiceOver ⇒ no data.
- Needs `sudo` and hand-decodes tagged/heap pointers (fragile).
- Not runnable as-is: a Go package (`axsniff`) with no `go.mod`/`main`.

Kept for history. See `../02-mirroring-swift` (active client) and
`../03-direct-device` (talk to the phone directly — the good one).
