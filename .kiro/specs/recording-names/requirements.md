# Recording Names — Requirements

## Overview

Recordings are currently named `recording_2026-09-03_19-45-58`. That name is
unique and sortable but says nothing about the recording, and the only way to
change it is Finder — which also breaks the app's own bookkeeping, because
`HistoryScanner` finds a session's audio as `<manifest.name>.m4a`.

This feature gives a recording a short, human-readable name:

1. **Automatically**, derived from what the conversation was actually about —
   including when Live Insights is off, by transcribing the finished recording
   after it is saved.
2. **Manually**, by clicking the file name in the app and editing it in place.

Both paths write through one rename operation that keeps every artifact of a
session (audio, manifest, transcript exports) consistent.

## Terminology

- **Session directory** — `~/AudioRecorderBackups/recording_<timestamp>/`. This
  is the session's archival identity and is *not* renamed (see design).
- **Display name** — `SessionManifest.name`. Drives the `.m4a` file name, the
  transcript export names, the History row, and the "Saved …" banner.
- **Title budget** — fewer than 15 characters, i.e. **1–14 characters**, for the
  base name excluding the `.m4a` extension.
- **Naming transcript** — text used only to pick a name. Either the Live
  Insights transcript (already on disk) or a transcript produced after
  recording from the finished `.m4a`.

---

## Requirement 1 — Automatic content-based naming

**User story:** As someone who records meetings back to back, I want each file
named after what the meeting was about, so I can find last week's pricing call
without opening files.

### Acceptance criteria

1.1 WHEN a recording finishes AND a naming transcript can be obtained, THE
SYSTEM SHALL derive a display name from the conversation content and rename the
recording's artifacts to it.

1.2 THE generated name SHALL be 1–14 characters long, excluding the extension.

1.3 THE generated name SHALL contain only letters, digits, spaces, and hyphens,
SHALL NOT begin with `.` or `-`, and SHALL NOT contain `/` or `:`.

1.4 THE generated name SHALL be human-readable as a topic label (e.g.
`Pricing Call`, `Q3 Budget`, `Vendor Demo`), not a sentence, timestamp, or
speaker list.

1.5 IF the derived name collides with an existing file or a name already used in
either destination, THE SYSTEM SHALL disambiguate with a numeric suffix
(`Pricing Call 2`) while still respecting the 14-character budget.

1.6 IF no naming transcript can be obtained, or naming fails for any reason, THE
SYSTEM SHALL keep the existing `recording_<timestamp>` name and SHALL NOT
surface an error banner. Auto-naming is a convenience and never a failure mode
of recording.

1.7 THE naming step SHALL run after audio finalization completes. It SHALL NOT
delay, block, or be able to fail the audio finalize path, and the app SHALL
remain fully usable — including starting the next recording — while naming runs.

1.8 THE naming step SHALL make at most two title-model calls per recording: one
to name the recording, and one more only when the first answer exceeds the length
budget. IF both overshoot, THE SYSTEM SHALL shorten the answer by removing whole
words. IF the model is unreachable or no credentials are configured, THE SYSTEM
SHALL fall back to a local, network-free heuristic name.

1.12 THE SYSTEM SHALL NOT emit a name that ends in a preposition, article, or
other grammatical fragment. Shortening SHALL remove whole words; cutting inside a
word is permitted only when a single word exceeds the entire budget.

1.13 THE title SHALL be requested from the configured *deep* model, not the fast
suggestion-lane model.

1.9 THE user SHALL be able to disable auto-naming, with the setting persisted
across launches. Default: enabled.

1.10 WHEN auto-naming has renamed a recording, THE UI SHALL show the new name
without the user reopening or refreshing anything, and SHALL indicate while
naming is in progress.

1.11 THE whole naming step SHALL be bounded in time (default 120 seconds) and
SHALL abandon quietly when the budget is exceeded.

---

## Requirement 2 — Rename in the app

**User story:** As a user looking at the recording I just made, I want to click
its name, type a better one, and press Save — without going to Finder.

### Acceptance criteria

2.1 WHERE the finished recording's file name is displayed at the bottom of the
Record tab, THE name SHALL be a click target that reveals an editable text
field, pre-filled with the current name and fully selected.

2.2 WHILE editing, THE SYSTEM SHALL offer **Save** and **Cancel**; Return SHALL
save and Escape SHALL cancel.

2.3 WHEN the user saves a new name, THE SYSTEM SHALL rename, in every
destination that has them:
   - `<old>.m4a` in the backup session directory,
   - `<old>.m4a` in the user's chosen folder,
   - `<old>.transcript.txt` and `<old>.transcript.json` in the user's chosen
     folder,
   - and update `SessionManifest.name` in the session directory.

2.4 WHEN a rename succeeds, THE SYSTEM SHALL update the banner text, the Show in
Finder target, and the History list to the new name.

2.5 THE SYSTEM SHALL reject and explain, without renaming anything: an empty or
whitespace-only name, a name containing `/` or `:`, a name beginning with `.`,
and a name longer than 50 characters. Manual names may exceed the 14-character
auto-naming budget — that budget exists to keep *generated* names terse.

2.6 IF the target name already exists in either destination, THE SYSTEM SHALL
report the conflict and leave the current name unchanged.

2.7 IF any individual rename fails (permissions, removed volume), THE SYSTEM
SHALL report which artifact failed, SHALL leave the recording playable and
discoverable, and SHALL NOT leave the manifest pointing at a file that does not
exist.

2.8 THE rename control SHALL be disabled while a recording is in progress, while
saving, or while a rename is in flight.

2.9 A past recording selected in the History tab SHALL be renamable the same
way, through the same operation.

2.10 A manual rename SHALL take precedence over auto-naming: IF the user renames
a recording while its automatic naming is still running, THE automatic name
SHALL be discarded.

---

## Requirement 3 — Consistency and recoverability

3.1 THE session directory name SHALL remain `recording_<timestamp>` regardless
of renames, so a session's identity on disk is stable and immune to name
collisions.

3.2 THE manifest SHALL retain the original timestamp-based name, so the
chronological identity of a renamed recording is never lost.

3.3 WHEN the manifest records a display name, `HistoryScanner` and
`RecoveryManager` SHALL locate the session's audio by that name.

3.4 Manifests written before this feature SHALL load unchanged, with their
display name taken from the existing `name` field.

3.5 A rename SHALL be safe to interrupt: the manifest is written after the file
moves succeed, so a crash mid-rename leaves the manifest pointing at a name that
exists.

---

## Requirement 4 — Transcription for naming when Live Insights is off

**User story:** As a user who does not want live transcription running during
calls, I still want my recordings named by content — so after the recording is
saved, transcribe enough of it to figure out what it was about.

### Acceptance criteria

4.1 WHEN a recording finishes AND no Live Insights transcript exists, THE SYSTEM
SHALL transcribe the finished `.m4a` for the sole purpose of naming it.

4.2 THE SYSTEM SHALL transcribe only the beginning of the recording, up to a
bounded window (default 3 minutes), because a topic is established early and the
window bounds both cost and waiting time. The window SHALL be configurable.

4.3 THE SYSTEM SHALL support two transcription backends:
   - **On-device** (Apple Speech): no network, no credentials, no cost.
   - **Amazon Transcribe** (streaming): the existing streaming path replayed
     from the file, requiring the AWS credentials and region already configured
     for Live Insights.

4.4 THE default backend SHALL be on-device when the OS and language model
support it; otherwise naming SHALL fall back to Amazon Transcribe only if the
user has explicitly opted in.

4.5 THE SYSTEM SHALL NOT send recorded audio off the machine without an explicit
opt-in that names the service and states that a portion of the recording will be
uploaded. Live Insights being *off* SHALL NOT be silently overridden by naming.

4.6 THE selected backend SHALL be visible and changeable in the app, together
with a plain statement of what leaves the machine in each case.

4.7 WHEN the on-device backend requires user authorization, THE SYSTEM SHALL
request it at first use, and WHEN authorization is denied THE SYSTEM SHALL fall
back to the timestamp name and reflect the denial in the setting's caption — not
in an error banner.

4.8 Amazon Transcribe streaming SHALL be driven at near-real-time pacing with
uniform 50–200 ms chunks of 16 kHz mono signed 16-bit PCM, per the service's
documented guidance, and SHALL cap replay speed so a naming run cannot be
mistaken for abuse. IF the service rejects the pace, THE SYSTEM SHALL retry once
at real-time pacing.

4.9 THE naming transcription SHALL NOT use Amazon S3 and SHALL NOT require IAM
permissions beyond those Live Insights already needs.

4.10 THE naming transcript SHALL be treated as a transient input: it SHALL NOT
overwrite or fabricate a session's `transcript.json`, `transcript.jsonl`, or
`insights.json`.

4.11 THE naming transcription SHALL run entirely off the main thread and SHALL
be cancelled if the user starts another recording, so it can never contend with
capture.

---

## Out of scope

- Renaming the PCM masters (`mic_001.caf`, `system_001.caf`) or the session
  directory itself.
- Retroactively naming or bulk-transcribing existing recordings.
- Persisting the naming transcript as a full session transcript (a plausible
  follow-up, deliberately not bundled here).
- Amazon Transcribe **batch** jobs, which would require an S3 bucket, an upload
  of the entire recording, and new IAM permissions (see design).
