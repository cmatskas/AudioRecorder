# Recording Names — Tasks

Order matters: pure Core first, then the filesystem operation, then transcription
backends, then the UI. Each task ends with `swift test` green.

- [x] 1. **`SessionManifest`: add `originalName`, version 3**
  - `originalName: String?` set from `name` in `init`, `decodeIfPresent`
    defaulting to `name`, always encoded; `currentVersion = 3`.
  - Extend `SessionManifestTests`: v2 fixture → `originalName == name`; v3
    round-trip with a divergent `originalName`.
  - _Requirements: 3.2, 3.4_

- [x] 2. **`RecordingTitler`: sanitize + parse**
  - New `Sources/AudioRecorderCore/Insights/RecordingTitler.swift` with
    `maxLength = 14`, `sanitize(_:maxLength:)`, `parse(_:)`.
  - New `Tests/AudioRecorderCoreTests/RecordingTitlerTests.swift` for the
    sanitize and parse cases in the design.
  - _Requirements: 1.2, 1.3, 1.4_

- [x] 3. **`RecordingTitler`: prompts + heuristic fallback**
  - `system`, `user(summary:transcript:)`, `heuristicTitle(from:)` —
    deterministic, stop-word filtered, budget-bounded.
  - Tests: fixed transcript → stable name; stop-words-only → nil.
  - _Requirements: 1.4, 1.8_

- [x] 4. **`SessionRenamer`**
  - New `Sources/AudioRecorderCore/Recording/SessionRenamer.swift`: `Request`,
    `Outcome`, `RenameError`, `validate`, `rename(_:allowSuffix:)`.
  - Move order backup `.m4a` → manifest → user-folder copies, with rollback of
    the audio move if the manifest write fails; sidecar failures are warnings;
    missing sidecars are silent.
  - New `Tests/AudioRecorderCoreTests/SessionRenameTests.swift` covering every
    case in the design, including the `HistoryScanner` follow-up.
  - _Requirements: 1.5, 2.3, 2.5, 2.6, 2.7, 3.1, 3.3, 3.5_

- [x] 5. **`AudioFileChunker`**
  - New `Sources/AudioRecorderCore/Insights/AudioFileChunker.swift`: `AVAudioFile`
    → 16 kHz mono Int16 → uniform 100 ms `AsyncStream<Data>` chunks, capped by
    `maxDuration`, with `pacing` (`.unpaced`, `.realTime`, `.multiple(Double)`).
  - Also expose a head-trim helper writing the bounded head to a temporary file,
    for the on-device backend.
  - New `Tests/AudioRecorderCoreTests/AudioFileChunkerTests.swift` per the design
    (synthesized tone, chunk size, duration cap, mono + stereo sources, pacing).
  - _Requirements: 4.2, 4.8_

- [x] 6. **`NamingTranscriber` protocol + `LocalSpeechTranscriber`**
  - Protocol in Core; implementation using `SpeechAnalyzer`/`SpeechTranscriber`
    under `if #available(macOS 26, *)`, else `SFSpeechRecognizer` with
    `requiresOnDeviceRecognition = true`.
  - Authorization request on first use; distinct `notAuthorized` and
    `unavailable` errors; temporary head file deleted in `defer`.
  - Add `NSSpeechRecognitionUsageDescription` to the `Info.plist` in
    `scripts/build-app.sh`.
  - _Requirements: 4.1, 4.3, 4.4, 4.7_

- [x] 7. **`AWSFileTranscriber`**
  - New `Sources/AudioRecorderInsights/AWSFileTranscriber.swift`: chunks at 4×
    pacing into the existing `TranscribeStreamer`, joined final results, one
    real-time retry on service exception, empty result on silence.
  - No S3, no new IAM action; make `LazyBedrockClient` public for reuse.
  - Unit-test pacing/retry with a stub streamer in `AudioRecorderInsightsTests`;
    extend `LiveAWSIntegrationTests` with a gated end-to-end case.
  - _Requirements: 4.1, 4.3, 4.8, 4.9_

- [x] 8. **`RecordingNamer`**
  - New `Sources/AudioRecorderCore/Insights/RecordingNamer.swift` with `Inputs`,
    injected `transcriber`/`llm`, `maxTranscriptionDuration = 180`,
    `budget = .seconds(120)`, `proposeName` that never throws and honours
    cancellation.
  - New `Tests/AudioRecorderCoreTests/RecordingNamerTests.swift` per the design.
  - _Requirements: 1.1, 1.8, 1.11, 4.1, 4.2, 4.10, 4.11_

- [x] 9. **`AppState`: settings, injections, naming on stop**
  - `lastSavedName`, `lastSavedSessionDirectory`, `autoNameRecordings`,
    `namingBackend`, `isNaming`, `isRenaming`; `llmClientFactory` and
    `cloudNamingTranscriberFactory` seams; UserDefaults keys including
    `namingCloudConsentGranted`.
  - Decompose the "Saved …" banner so the name is published separately from
    `statusMessage`.
  - Detached, cancellable naming task after `pipeline.finish()`, cancelled by
    `startRecording()`; all naming errors swallowed.
  - Wire the two factories in `AudioRecorderApp`.
  - _Requirements: 1.1, 1.6, 1.7, 1.9, 1.10, 4.4, 4.5, 4.11_

- [x] 10. **`AppState`: manual rename API**
  - `renameLastRecording(to:)` and `rename(_ item: HistoryItem, to:) -> Bool`
    through `SessionRenamer` with `allowSuffix: false` and a 50-character limit;
    `RenameError` → `errorMessage`, warnings → `statusMessage`; refused while
    recording or saving; cancels any in-flight naming task.
  - _Requirements: 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.10_

- [x] 11. **`ContentView`: clickable, editable name row**
  - `savedNameRow` with idle button + pencil + Show in Finder + "Naming…"
    indicator; edit mode with focused, pre-selected `TextField`, Save/Cancel,
    `.onSubmit`, `.onExitCommand`, inline validation reason; accessibility labels
    and hints.
  - _Requirements: 1.10, 2.1, 2.2, 2.4, 2.5, 2.8_

- [x] 12. **Naming settings row + cloud consent**
  - Toggle for `autoNameRecordings` and a `namingBackend` picker beside the Live
    Insights row, captions stating what leaves the machine, on-device option
    disabled with a reason when unauthorized/unavailable, Amazon Transcribe
    option gated behind a confirmation that names the service and the 3-minute
    window; disabled while recording.
  - _Requirements: 1.9, 4.4, 4.5, 4.6, 4.7_

- [x] 13. **`HistoryView`: rename a past recording**
  - Rename button in the detail pane reusing the edit affordance, then
    `model.refresh(root:)`.
  - _Requirements: 2.9_

- [x] 14. **Docs**
  - README: automatic content-based naming, the two transcription backends and
    exactly what each sends where, the 3-minute window, in-app rename, and the
    fact that the session directory keeps its timestamp name.
  - _Requirements: 1.1, 4.3, 4.5, 4.6, 2.1, 3.1_

- [x] 15. **Verify end to end**
  - Done: `swift test` → 162 tests, 4 skipped (the gated live-AWS cases), 0
    failures. `./scripts/build-app.sh` builds and signs `dist/AudioRecorder.app`
    with `NSSpeechRecognitionUsageDescription` present.
  - Still to do by hand (needs a real recording and AWS account):
    (a) Live Insights on → name changes from timestamp to topic label within
    seconds; (b) Live Insights off, on-device backend → permission prompt on
    first use, then a name with no network activity; (c) Amazon Transcribe
    backend → consent prompt once, then a name within ~1 minute for a 3-minute
    window; (d) denied speech permission → timestamp name kept, no error banner,
    caption explains; (e) click the name, rename, confirm Finder, banner and
    History agree; (f) rename to an existing name → refused with an explanation;
    (g) start a new recording while naming runs → naming cancelled, capture
    unaffected.
  - _Requirements: all_
