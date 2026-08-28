# BNNS offline-diarizer crash reproduction on macOS 14

This branch exists for one purpose: try to reproduce, on a **macOS 14 (Sonoma)**
runner, the `EXC_BAD_ACCESS` an affected user hits inside FluidAudio's offline
diarizer, and to compare candidate fixes against it like-for-like.

Nothing here builds or ships FluidAudio. It clones the fork at run time.

## The target crash signature

All four markers must be present **on the faulting thread** — `check_signature.sh`
enforces that. An earlier version OR'd markers across every thread and produced a
false positive, because unrelated threads legitimately carry BNNS frames while
other Core ML work is in flight.

| marker | value |
|---|---|
| faulting queue | `com.apple.e5rt.concurrentExecutionQueue` |
| fault | 4-byte WRITE, `esr 0x92000047`, ~640 KB into an **unmapped** VM gap |
| frames | `_platform_memmove` ← `BNNSGraphContextExecute_v2` ← `BnnsCpuInferenceOperation::ExecuteSync` |

Anything else is a *different* crash and is reported separately, never counted.

## Why macOS 14 specifically

The user is on macOS 14.6.1 (23G93) / Mac14,9 / M2 Pro. 138 runs on a
bare-metal macOS 26.6.2 host of identical hardware produced **zero**
target-signature crashes. `macos-14` is the closest OS still offered.

Caveats that travel with every result from here:

- the image is macOS **14.8.7 (23J520)**, not the user's 14.6.1
- 3 vCPU / 7 GB VM, vs a 12-core M2 Pro
- the image's default Xcode is 15.4 (Swift 5.10), which **cannot** build
  `swift-tools-version: 6.0`; the workflow selects **Xcode 16.2 (Swift 6.0.3)**.
  The local campaign used Swift 6.3.3.
- ANE presence is probed per job via `MLModel.availableComputeDevices` and
  printed into the job summary. Do **not** use `ioreg | grep -i ane` — it finds
  nothing even on a bare-metal M2 Pro that demonstrably has a Neural Engine.
- `macos-14` is deprecated (actions/runner-images#13518): brownouts from
  2026-10-05, **fully retired 2026-11-02**.

## Variants

| name | revision | what it is |
|---|---|---|
| `unpatched` | `19600a48` (v0.15.5) | baseline |
| `serialize-only` | `d79cf8e3` | stops concurrent Core ML execution inside `process()`; costs +79 % wall |
| `lifetimeonly` | `19600a48` + `variant-B-lifetimeonly.patch` | Core ML-owned FBank array + `withExtendedLifetime`; batching preserved; free |
| `shipped` | `91958612` | serialize + lifetime + cancellation gate |

`shipped` is **not** a control. Hedy 3.10.0 ships it and the affected user still
crashed on 2026-08-26, so it is a hunt target in its own right.

### The `lifetimeonly` patch is an adaptation, not a cherry-pick
`91958612` wraps a *serial* prediction in `withExtendedLifetime`. Variant B keeps
v0.15.5's *batched* submission, so the wrap was widened to cover `audioArrays`,
`providers` and `batchProvider`. Recorded here because it is a deviation.

## Modes

- `diarizer-only` — intra-call concurrency only. This is what the patch targets.
- `asr-concurrent` — an `AsrManager` transcribing continuously in the **same
  process** for the whole diarization pass, per FluidInference/FluidAudio#661,
  whose trigger is cross-manager. **The patch is not expected to fix this mode**;
  it only serializes work inside `OfflineDiarizerManager.process()`. A crash that
  appears only here is a real result, not a misconfiguration.

Known harness limitation: the ASR loop runs until diarization finishes, so
anything that slows diarization lets ASR complete more passes and compete
harder — positive feedback. **Crash exposure is unaffected (it only goes up), but
wall time in this mode is not a quotable measurement.**

## Running one

The workflow lives only on `ci/bnns-macos14`, so there is no "Run workflow" button
(GitHub exposes `workflow_dispatch` only for workflows on the default branch —
that is deliberate here, to keep the fork's `main` clean for upstream PRs).

```bash
# edit ci/matrix.json, then:
git push origin ci/bnns-macos14     # a push IS the trigger
gh run rerun <run-id>             # re-run an identical matrix
```

## Audio

Pinned by sha256, downloaded from the `bnns-repro-assets` release. **A mismatch
fails the job** rather than proceeding with different audio — CI numbers that
are not comparable to the local ones are worse than no CI numbers.

| file | sha256 |
|---|---|
| `meeting_79min_16k_mono.wav` | `08168b91c672839f71bca31d0906af15482f5ed9f2d2c900cf871fad8d81a553` |
| `gm_8min_16k_mono.wav` | `ff5708e8416b7f949837cd5587c9ec84c9e79ece836c8fb7c11a11c322d6685f` |
| `smoke_3min.wav` | `cd19c33b445af2e3821f3be626e9cd623fb2ad508bf95aacc720d278ccd821d0` |

C-SPAN congressional hearing (public domain). The 8-minute file is a byte-exact
prefix of the 79-minute one. The WAV is never uploaded as a build artifact.

The harness source is pinned too (`bd3efbaa…`); the job **fails** if it drifts,
because one shared harness across every variant is what makes the comparison
mean anything.
