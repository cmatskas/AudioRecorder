# Audio Recorder

A native macOS app that records your microphone and your Mac's system audio at
the same time — no virtual audio driver, no Python, no ffmpeg.

Built for recordings you cannot afford to lose: audio is written to disk
continuously while recording, to two independent destinations, in a format that
survives a crash mid-write.

## Why no BlackHole?

Capturing system audio on macOS traditionally meant installing a virtual audio
driver (BlackHole, Soundflower, Loopback), routing your output through a
Multi-Output Device, and recording that device as an input. macOS 14.4 added
**Core Audio process taps**, which let an app capture the system output mix
directly with nothing installed. This app uses them, so setup is one permission
prompt instead of a driver install and an audio-routing detour.

## Features

- **Simultaneous mic + system audio**, each with its own live stereo level meter
- **Continuous crash-safe writing** — a kernel panic, force quit, or power loss
  costs at most a few seconds
- **Dual destinations** — an always-on backup folder plus a folder you choose,
  written independently so a failing disk cannot take both down
- **Automatic crash recovery** — interrupted recordings are detected on launch
  and can be finished with one click
- **Native sample rates preserved** — sources are recorded separately and merged
  afterwards, so a 24 kHz Bluetooth mic never drags 48 kHz system audio down
- **AAC `.m4a` output**, with the lossless PCM masters kept in the backup folder

## Requirements

- macOS 15 or later
- Apple silicon or Intel

## Install

Download the latest `AudioRecorder.zip` from
[Releases](../../releases/latest), unzip, and drag `AudioRecorder.app` to
`/Applications`.

On first recording macOS will ask for two permissions:

| Permission | Why |
|---|---|
| **Microphone** | To record the mic you select |
| **System Audio Recording** | To capture what your Mac plays |

Both are requested only when you start recording, and can be revoked in System
Settings → Privacy & Security.

## Build from source

```bash
git clone https://github.com/cmatskas/AudioRecorder.git
cd AudioRecorder
swift test                     # run the test suite
./scripts/build-app.sh         # build dist/AudioRecorder.app
./scripts/build-app.sh --install   # build and copy to /Applications
```

The build script signs with a Developer ID Application identity if one is in
your keychain, and falls back to ad-hoc signing otherwise. Do not run it with
`sudo` — it will refuse, because root-owned build artifacts break later builds.

To regenerate the app icon:

```bash
swift scripts/generate-icon.swift
```

## How it works

```
mic device IOProc ─────► CaptureTrack ─┬─► ring ─► TrackWriter ─► mic_001.caf     (backup)
                                       └─► ring ─► TrackWriter ─► mic_001.caf     (your folder)
process tap ───────────► CaptureTrack ─┬─► ring ─► TrackWriter ─► system_001.caf  (backup)
(in its own aggregate)                 └─► ring ─► TrackWriter ─► system_001.caf  (your folder)

                         on stop / on recovery
                                  ▼
                     SessionEncoder: align by host-time
                     anchors, resample, sum ─► .m4a
```

Three design decisions carry most of the weight:

**The mic and the tap never share an aggregate device.** A process tap emits no
buffers until some process renders audio, and a tap inside an aggregate device
gates that aggregate's entire IO cycle — putting the mic in the same aggregate
starves it until system audio happens to play. Each source gets its own IO path.

**Nothing is merged on the audio thread.** Each source is written as its own PCM
master at its native rate, tagged with a host-time anchor, and the streams are
merged offline at finalize. That keeps sources decoupled (a Bluetooth dropout on
one cannot disturb the other), allows mastering-quality resampling, and lets
alignment be computed from timestamps rather than guessed at live.

**Segments are CAF with a "valid to end of file" data chunk.** WAV stores its
length in the header, written on close, so a WAV interrupted by a crash is
malformed. CAF allows the data chunk size to mean "continues to end of file", so
a segment killed mid-write is readable up to the last flushed byte with no
repair. `F_FULLFSYNC` every 5 seconds bounds worst-case loss, and segments roll
every 10 minutes so all but the live one are complete files.

A `session.json` manifest records each track's sample rate, channel count, and
timing anchor, and is updated the moment a segment is created — so recovery
always knows exactly what exists on disk.

## Tests

```bash
swift test
```

The suite covers the ring buffer, CAF crash-safety (a file abandoned without
finalizing must still be fully readable), rate-mismatched merging, timeline
alignment from anchors, dropout gap filling, uneven track lengths, manifest
migration, and crash recovery from unfinalized streams.

## License

MIT — see [LICENSE](LICENSE).
