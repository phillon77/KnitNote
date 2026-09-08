# Publication evidence output verification — 2026-09-08

## Scope and review
Candidate f91b3e08c2f85b39be04baaf12c98968aced59f7, baseline5d7f39dea0eca9af2e7200f58d5ba14eee0efe4c. Independent review approved spec/quality, no Critical or Important findings. Data-only save output program, ordinary semantic compatibility and target inclusion accepted. No executor, runtime bootstrap activation, physical ownership or release readiness claimed.

Minor deferred: SyncPublicationEvidenceOutputProgramTests wrong-id fixture changes version but retains original record; consistency fails before expectedID isolation. Production expectedID guard exists. Improve with a valid other-ID envelope when next touching tests or in pre-release test review; this is not a demonstrated production defect.

## Verified frozen candidate
| Check | Result | Log | SHA256 |
| --- | --- | --- | --- |
| Core affected | 234 tests / 8 suites, exit0 | /tmp/publication-output-green.log | 8b3ee578b5dc97d9bd1c20e2b184c3fd36798cf1cf0f2bbef610adcd376a5dd3 |
| App | 241 tests / 12 suites, exit0 | /tmp/publication-output-app-01.log | 15741421d1abcec29285eeb082108f8605a8764bc5fd4e59cb359649825060c8 |
| App root | 73 tests / 7 suites, exit0 | /tmp/publication-output-root-01.log | 6d7a5386d453fb78cd1a95ada3e49f6652621cdd4cf21e6276553c7ca03ec91c |
| macOS unsigned build-for-testing | exit0,104.521s | /tmp/publication-output-macos-01.log | 6c8fab7c3cb96ca2f940b14ef350be3745503596c01b887df095675de058184e |
| iOS unsigned build | exit0,48.583s | /tmp/publication-output-ios-01.log | 00d4d277dbfd54286d58008cf58a8c343d8fe4a540ab3bddeef7aceb5326283f |

Controller serial session69037 ended exit0. Source frozen throughout. Each Xcode log has three AppIntents metadata-extraction warnings and no errors. No physical-device test inferred from build success. Full Core suite not repeated; focused coverage listed above.

Frozen Git trees: Sources6210e4791c58dc44bcaa38a791f0976fe27525f2, Tests325d4a9578f3811bdee707cea13725ab85fdacc6, KnitNote78721554b1f8c32862824939dc7ec2e986fded90, PBX3b40f39a2219f73cbdade43d3320f43516b35ccd. Version1.7.0(13) unchanged.

## Rulings and limitations
Head boundary uses actual shared count guard with exact/+1/negative tests and real small encoded parity; not a full-size64MiB semantic fixture. This limits test memory, at the cost of that explicit coverage limitation. Pure candidate errors map to corrupt while ordinary typed errors remain unchanged; runtime RED and comparison tests cover this boundary.

The owner must still verify complete actual prefix equals expected tree, compose helpers once, establish durable preparing, execute retained outputs and parent synchronization, enforce full history/Base64/recovery budgets, implement abort/sourceSpent/reissue and remaining transport/App/device acceptance. No signing, merge, push, upload or submission occurred.

Immediate user-authorized step complete; automatic delegation remains PAUSED. No next task dispatched. User scratch preserved.

