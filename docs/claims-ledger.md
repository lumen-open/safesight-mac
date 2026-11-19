# Claims ledger

Every public sentence about SafeSight Mac, and the evidence it rests on. A sentence may be used only while its status allows it.

| Claim | Status | Evidence needed before it may be said |
|---|---|---|
| "Free forever: no card, no trial, no account" | True now | CORE.md; no payment code in the core |
| "Open source, Apache-2.0" | True now | LICENSE |
| "Nobody can shorten your wait, including the people who made it" | Design only; may be said only with "designed so that" until the lock is built and the outside review is done | Lock built; ST-001 outside review passed |
| "Nothing leaves your Mac except update checks and the public time signal" | Design only | Release scans pass; network behaviour verified on the test Mac |
| Any accuracy number for the detector | Never until measured | The sealed cloud run's measured results, at the shipped settings, with version and date |
| "Can't be bypassed", "100%", "blocks all", "treats addiction" | Never | — |
| "The cover-only build contains no networking code" | True now, for step 1 | `tools/check-no-network.sh` on every commit; network behaviour still to be watched on the test Mac |
| "It never writes what it sees to a file, a log or a crash report" | True now, for the app (the lab harness writes synthetic frames only when asked) | Code: frames stay in memory. Whether macOS swaps the watcher's memory is recorded per macOS (ST-076) |
| "A picture can be seen for a moment before its cover" | True now (a known limit) | Its length is not measured; the target is under half a second (ST-031) |
| "On every display" (however it is attached) | Built: every display macOS lists is judged or covered whole, tested with faked displays only. AFTER TEST on hardware | ST-033 and ST-034 on a test Mac with an external display, a DisplayLink dock, an AirPlay receiver (extended and mirrored) and an iPad (Sidecar): every display judged or covered whole, through plug, unplug, sleep, wake, lid, rotation and mirroring, with the frames shown before a new display's cover counted (SL-023). Must not be said of AirPlay or Cast from a browser or the TV app straight to a TV, which the Mac never draws |
| "The cover-only build has no lock and can be paused or quit" | True now | Practice state, SD-223 |
| "A new picture is covered within about a tenth of a second" | AFTER TEST | ST-031 on a test Mac, timed with a camera or capture device, per size band. The lab bench (`results/speed-*.json`) times only the frame handed to the cover layer through to the cover layer's layers, with no capture latency and no display time |
| "Pictures stay covered while you scroll" | AFTER TEST | ST-031 with scrolling at several speeds on a test Mac, filmed. The lab bench's scroll case is a simulation with synthetic frames |
| "On busy pages, new pictures are blurred until they are checked" | AFTER TEST | ST-031 and ST-038 on a test Mac (including the 8 GB Air), with the cost published: how long harmless pictures stay blurred |
| "Pictures already checked are not checked again" (as a speed or battery claim) | AFTER TEST | ST-038 energy and latency on the Air. The cache itself is built and tested; the claim is about what the owner notices |
| "Balanced covers fewer harmless things than Either" | AFTER TEST | Lab ST-040, 18 November 2026: 8 against 194 of 932 held-out harmless screens (`results/false-covers-heldout.json`). Still to do: the same on a test Mac's real screens; "misses more" stays unmeasured until the catch rate exists |
