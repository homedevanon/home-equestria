Cloud rider lifetime regression
==============================

From the source checkout, with a Godot 4.5-compatible Linux executable:

  python3 tools/cloudominium/test_rider_cleanup.py --engine /path/to/godot

Expected: CLOUD_RIDER_DONE checks=10 failures=0 and exit 0. The runner creates
an empty temporary project, copies only the executable, loads the production
cloud script, and isolates user data. No game assets, native extensions, speech
services, VR hardware or player saves are needed. All temporary files are removed
when the runner exits.

To reproduce against the unchanged 0.3.1.2 script, using the same fixture:

  python3 tools/cloudominium/test_rider_cleanup.py --engine /path/to/godot --source-ref 0.3.1.2-maredev

The original reproduces SIGSEGV on the tested Linux release engines (4.5 and
4.5.2). Exact timing depends on allocation patterns; a failure or typed-array
validation error can precede the crash. The corrected script passes all checks
on both engines. A typed Array[Node] must not validate a freed object merely to
discard it: inspect the entry as Variant, test validity, and remove its slot by
index. Immediate/queued disposal, boarding, support transfer, surviving riders
and 32 disposal cycles with WAV-playback allocations are covered.

This regression establishes the cleanup defect. A live crash had the same first
nine native frames as this reproducer, but its stripped trace did not identify
the exact script call site. It does not prove every observed crash shares this
cause or replace an interactive playtest.
