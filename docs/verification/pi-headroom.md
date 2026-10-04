# Verification: Pi Headroom tool-result ordering

Audience: maintainer verification.

This record proves that the installed Pi extension runner applies Headroom's `tool_result` patch before the next downstream delivery stage.
It also records the portable proofs for disabled and failed pass-through behavior, original retrieval, semantic preservation, instrumentation, and the tool-class folding scope decided by review: only log-shaped producers fold, and only identical runs of at least 16 characters repeated at least 3 times.

## Verified version

| date | Pi version | platform |
| --- | --- | --- |
| 2026-10-04 | 1.0.0 | macOS 26.7 |

## Command

```sh
bin/fm-test-run.sh tests/fm-pi-headroom-extension.test.sh
```

## Result

```text
ok - Headroom is inert by default
ok - Headroom retrieval ids are scoped to one session generation
ok - Headroom rejects unrecognized modes loudly and ends pending latency with the run
ok - Headroom transforms safely, retrieves originals, and records paired measurements
ok - Headroom baseline and failure paths preserve Pi's exact original result
ok - Headroom folds only fold-eligible tool classes and records the decision by class
ok - installed Pi applies Headroom's tool_result patch before downstream delivery
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```

The installed-version case loads the tracked extension and a downstream observer through Pi's real extension loader and runner.
The observer receives the transformed content, and Pi's runner returns that same patch for delivery.
The portable cases verify that a disabled arm registers no model-visible tool and writes no state, that a measurement initialization failure returns no patch, that retrieval returns the original content exactly, and that `read`, `grep`, `find`, `ls`, `edit`, `write`, the retrieval tool, and an unrecognized extension tool all keep their result byte-for-byte while the identical payload still folds for `bash`.
They also verify that a retrieval id issued before a session reload resolves to nothing rather than to another result's content, that an unrecognized `--headroom` value warns instead of starting a silently uninstrumented session, and that a result still pending when the agent run ends keeps a `null` model latency instead of taking the next run's.

Refresh this record after a Pi upgrade by rerunning the command above and the strict extension typecheck:

```sh
bin/fm-test-run.sh tests/fm-pi-primary-types.test.sh
```
