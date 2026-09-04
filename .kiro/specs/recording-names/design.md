# Recording Names — Design

## Where this fits

```
stopRecording()                                   (AppState)
   │
   ├─ RecordingSession.stopAndFinalize()          ← unchanged, safety-critical
   │      writes recording_<ts>.m4a, manifest .complete
   │
   ├─ pipeline.finish()                           ← unchanged, flushes transcript
   │
   └─ Task.detached: RecordingNamer.name(...)                            NEW
          │
          ├─ transcript text?
          │     ├─ from insightsModel.utterances        (Live Insights was on)
          │     └─ else NamingTranscriber.transcribe(audioURL, maxDuration:)
          │            ├─ LocalSpeechTranscriber   (Core, Apple Speech, no network)
          │            └─ AWSFileTranscriber       (Insights, Transcribe streaming)
          │
          ├─ title: LLMClient call (Bedrock) → RecordingTitler.parse
          │         else RecordingTitler.heuristicTitle
          │
          └─ SessionRenamer.rename(..., allowSuffix: true)               NEW
                 moves .m4a + transcript exports, rewrites manifest.name
                 ▲
                 └── also called by the inline rename UI
```

The audio path is untouched. Everything new hangs off the tail of
`stopRecording()` in a detached, cancellable task.

## Design decisions

**The session directory keeps its timestamp name.** Renaming it would change
`HistoryItem.id` (currently `directory.path`), invalidate the `liveDirectory` a
still-open `TranscriptLog` holds, and re-introduce the collisions the timestamp
exists to prevent. Nothing needs it: the display name already flows through
`manifest.name`, which is what `HistoryScanner` and the History row read. After
an auto-name the shape is
`~/AudioRecorderBackups/recording_2026-09-03_19-45-58/Pricing Call.m4a`, while
the user's chosen folder — the one they actually browse — holds a flat
`Pricing Call.m4a`.

**Naming runs after finalize, never before.** The name depends on a complete
transcript, and when Live Insights is off it depends on the finished `.m4a`
existing at all. Consequence: the banner reads `Saved recording_…m4a`, shows a
"Naming…" indicator, then updates to `Saved Pricing Call.m4a`. That is visible on
purpose — it shows the rename happened rather than hiding it.

**Two transcription backends, on-device first.** Requirement 4 says naming must
work with Live Insights off, which means transcribing after the fact. Both
backends are worth having and they answer different objections:

| | On-device (Apple Speech) | Amazon Transcribe (streaming replay) |
|---|---|---|
| Audio leaves the machine | no | yes, the first N minutes |
| Credentials needed | none | the ones Live Insights already uses |
| Cost | none | billed per second of audio streamed |
| Time for a 3-min window | seconds | ~45 s at 4× pacing |
| Accuracy | good | better, and matches the live transcript |
| Availability | `macOS 26+` via `SpeechAnalyzer`; `macOS 15+` via `SFSpeechRecognizer` on-device models | any supported region |

On-device is the default because it costs nothing, needs no setup, and — for a
user who deliberately turned Live Insights off — uploading their audio to name a
file would be a surprising thing for the app to decide on its own (Req 4.5).
Amazon Transcribe is one explicit opt-in away, and is the better choice for
anyone already streaming to AWS.

**Streaming replay, not a batch job.** Amazon Transcribe's batch API would need
an S3 bucket, an upload of the whole recording, `s3:PutObject` +
`transcribe:StartTranscriptionJob` + polling + cleanup. Replaying the file
through the streaming WebSocket path the app already speaks needs none of that:
no S3, no new IAM action, no new code path for credentials, and the same
`TranscribeStreamer` that live insights uses. The docs explicitly support
streaming pre-recorded media, and ask that the stream stay close to real time
with uniform 50–200 ms chunks — so replay is paced, not fire-hosed.

**Only the head of the recording is transcribed.** A 60-minute meeting does not
need 60 minutes of transcription to be named "Pricing Call". Default window: the
first 3 minutes. This is what makes the AWS path affordable and the wait
tolerable; it is also why the whole step has a hard 120-second budget (Req 1.11).

**Title generation reuses the existing `LLMClient` seam — no new pipeline
method.** `AppState` already has the finished transcript (`insightsModel.utterances`)
and closing summary (`insightsModel.summary`), so nothing needs to be asked of
`InsightsPipeline`. `AudioRecorderCore` owns the prompt, the parser, the
shortener, and the heuristic fallback (all pure, all testable); the Bedrock calls
are made through an injected `LLMClient` factory, the same seam pattern as
`insightsFactory`. When no credentials are configured, the heuristic name is used
and no network call happens at all.

**Getting a *short* title is the hard part, and it needs all three defences.**
Measured against the configured models with a real summary (a talk about
childhood labels and a boy called "the boy with the broken brain"):

| | first answer | after retry | final name |
|---|---|---|---|
| `nova-lite`, original prompt | `Impact of Childhood Labels` (26) | — | `Impact of` ← the bug |
| `nova-lite`, current prompt | `Jim's Label` (11) | — | `Broken Brain` |
| `claude-sonnet-4.5`, current prompt | `Broken Brain` (12) | — | `Broken Brain` |

So: the prompt carries examples *at* the budget rather than just stating it; a
first answer over budget earns one retry that quotes the rejected answer back
(models count characters badly but shorten concrete things well —
"Checkout Outage" → "Checkout Down"); and whatever still arrives is shortened by
dropping whole words. Naive truncation is what produced "Impact of", so
`compress` drops a leading article, then function words, then filler nouns
("Discussion", "Overview"), then keeps the strongest adjacent pair
("Broken Brain" out of "Jim's Broken Brain"), and only cuts inside a word when a
single word is longer than the whole budget.

**The title uses the deep model, not the fast one.** The fast lane's cheap model
runs every few seconds during a recording, where cost dominates; naming runs once
per recording, where quality dominates and one short call is negligible. The table
above is the evidence: same prompt, materially better names.

**Failure is silent for naming, loud for manual rename.** Auto-naming that fails
leaves the timestamp name and says nothing (Req 1.6) — the user did not ask for
it in that moment. A manual rename that fails must report exactly which artifact
failed (Req 2.7), because the user is waiting on it.

**Manifest is written between the moves.** Order: move the backup `.m4a` (the
canonical copy History reads), then rewrite the manifest, then move the
user-folder copies. If the backup move fails, nothing else happens. If the
manifest write fails, the audio move is rolled back. A crash at any point leaves
a manifest pointing at a file that exists (Req 3.5).

## Components

### 1. `RecordingTitler` — Core, pure

`Sources/AudioRecorderCore/Insights/RecordingTitler.swift`

```swift
public enum RecordingTitler {
    public static let maxLength = 14
    public static let system: String
    public static func user(summary: String, transcript: String) -> String
    public static func retryUser(summary: String, transcript: String, previous: String) -> String
    /// The model's answer, cleaned but not shortened — what gets quoted back.
    public static func candidate(in response: String) -> String?
    public static func fits(_ name: String, maxLength: Int = maxLength) -> Bool
    public static func parse(_ response: String) -> String?
    public static func clean(_ raw: String) -> String
    public static func compress(_ raw: String, maxLength: Int = maxLength) -> String?
    public static func heuristicTitle(from transcript: String) -> String?
    public static func sanitize(_ raw: String, maxLength: Int = maxLength) -> String?
}
```

`clean` handles filesystem safety at any length: `/` and `:` and other separators
become spaces, disallowed characters are dropped, possessives lose the whole
suffix (`Jim's` → `Jim`, because `Jims` reads like a typo), whitespace collapses.

`compress` reduces length by removing whole words, in order of how little they
carry: a leading article, then function words, then filler nouns, then all but the
strongest adjacent pair, then all but the longest single word. Only a word longer
than the entire budget is cut mid-word.

`heuristicTitle` tokenizes on non-letters, lowercases, drops a built-in stop-word
list and tokens under 4 characters, ranks by frequency (ties by first
occurrence), title-cases the top terms and joins them while they fit the budget.
Deterministic, therefore directly testable.

Prompt:

```
You name audio recording files. Given a description of a recorded conversation,
reply with a file name for it.

Hard limit: 14 characters including spaces. A longer answer is unusable and will
be thrown away.

Rules:
- One or two short words. Never three.
- Name the most concrete, memorable thing in the conversation, not the abstract theme.
- Letters, digits, spaces and hyphens only.
- Never start with "The", "A" or "An". Never end with a preposition such as "of", "for" or "on".
- No dates, times, speaker names, quotes, or trailing punctuation.

Examples of the required length and style:
- a discussion of next quarter's pricing strategy -> Pricing Plan
- a story about a boy told he had a broken brain after a head injury -> Broken Brain
- a vendor walking through their onboarding product -> Vendor Demo
- a retro on why the data migration slipped three weeks -> Migration Slip
- a debate about how childhood nicknames shape adult confidence -> Child Labels

Reply with the file name only.
```

The examples are load-bearing. With the limit stated but not demonstrated,
`nova-lite` answered `Impact of Childhood Labels`; with them, it answers
`Jim's Label`.

### 2. `NamingTranscriber` — Core protocol, two implementations

```swift
/// Transcribes the head of a finished recording for naming purposes only.
public protocol NamingTranscriber: Sendable {
    /// Plain text (no speaker attribution — a title does not need it).
    /// Throws on failure; the caller treats any failure as "no name".
    func transcribe(audioURL: URL, maxDuration: TimeInterval) async throws -> String
}
```

**`AudioFileChunker`** (Core, `Sources/AudioRecorderCore/Insights/AudioFileChunker.swift`)
Shared front end for both backends: opens the `.m4a` with `AVAudioFile`, converts
to 16 kHz mono `Int16` via `AVAudioConverter` (same target format as
`AnalysisFeed.outputSampleRate`), and yields uniform 100 ms chunks (3,200 bytes)
as an `AsyncStream<Data>`, stopping at `maxDuration`. Optional `pacing` parameter
sleeps between chunks so output can be real-time or a fixed multiple of it.
Downmixing mic and system audio to mono is fine here: naming needs words, not
speakers.

**`LocalSpeechTranscriber`** (Core, `Sources/AudioRecorderCore/Insights/LocalSpeechTranscriber.swift`)
- `macOS 26+`: `SpeechAnalyzer` + `SpeechTranscriber`, fed the file directly,
  concatenating final results. Requires the language model asset; if it is
  unavailable and cannot be installed, throws `unavailable`.
- `macOS 15+` fallback: `SFSpeechRecognizer` with `SFSpeechURLRecognitionRequest`
  and `requiresOnDeviceRecognition = true`, taking the final result's best
  transcription. `requiresOnDeviceRecognition` is not optional here: without it
  Apple's recognizer may send audio to Apple's servers, which would violate
  Req 4.5 as quietly as the AWS path would.
- Authorization via `SFSpeechRecognizer.requestAuthorization`; needs
  `NSSpeechRecognitionUsageDescription` in `Info.plist` (added to
  `scripts/build-app.sh`). Denied or restricted → throws `notAuthorized`, which
  the setting caption surfaces and the banner does not.
- The bounded window is honoured by trimming: the head of the file is written to
  a temporary `.m4a`/`.caf` via `AudioFileChunker`'s reader, and the temporary
  file is deleted in a `defer`.

**`AWSFileTranscriber`** (Insights, `Sources/AudioRecorderInsights/AWSFileTranscriber.swift`)
- Builds chunks with `AudioFileChunker(pacing: .multiple(4))` and hands the
  stream to the existing `TranscribeStreamer.run(chunks:onUtterance:)`, joining
  final results in arrival order.
- Reuses `AWSCredentials`, `TranscribePresigner`, `EventStreamCodec` untouched.
  No S3, no new IAM action (Req 4.9).
- On a service exception at 4× pacing, retries once at `.realTime` (Req 4.8).
- Empty result (a silent opening window) is returned as an empty string, which
  the namer treats as "no name" rather than an error.

### 3. `RecordingNamer` — Core orchestrator

`Sources/AudioRecorderCore/Insights/RecordingNamer.swift`

```swift
public struct RecordingNamer: Sendable {
    public struct Inputs: Sendable {
        public var audioURL: URL              // finished .m4a in the session dir
        public var liveTranscript: String     // "" when Live Insights was off
        public var summary: String            // closing deep-pass summary, if any
    }

    public var transcriber: (any NamingTranscriber)?
    public var llm: (any LLMClient)?
    public var titleModelID: String?
    public var maxTranscriptionDuration: TimeInterval = 180
    public var budget: Duration = .seconds(120)

    /// Nil whenever a name cannot be produced. Never throws.
    public func proposeName(_ inputs: Inputs) async -> String?
}
```

Steps: use `liveTranscript` if non-empty, else `transcriber?.transcribe`; bail out
on empty text; ask the LLM once for a title and `parse` it; on failure or absence
use `heuristicTitle`; `sanitize` to 14; return nil if nothing survives. The whole
body runs inside a `withTimeout(budget)` helper and is cancellation-aware, so
starting a new recording kills it (Req 4.11).

### 4. `SessionRenamer` — Core, filesystem

`Sources/AudioRecorderCore/Recording/SessionRenamer.swift`

```swift
public enum SessionRenamer {
    public struct Request: Sendable {
        public var sessionDirectory: URL      // backup session dir: manifest + canonical .m4a
        public var userDestinationRoot: URL?  // flat folder: copy + transcript exports
        public var newName: String
    }
    public struct Outcome: Sendable {
        public var name: String               // may carry a " 2" suffix
        public var backupAudioURL: URL?
        public var userAudioURL: URL?
        public var warnings: [String]         // non-fatal: sidecars not moved
    }
    public enum RenameError: LocalizedError {
        case invalidName(String), nameTaken(String)
        case audioMoveFailed(String), manifestWriteFailed(String)
    }
    public static func rename(_ request: Request, allowSuffix: Bool) throws -> Outcome
    public static func validate(_ name: String, limit: Int) -> Result<String, RenameError>
}
```

1. Validate the requested name against the given limit (14 auto / 50 manual).
   Validation is deliberately more permissive than `RecordingTitler.sanitize`: a
   person who types "Sync w/ Dana" is told about the slash rather than silently
   handed something else. Generated names arrive already sanitized.
2. Load the manifest for the current name; absent → `invalidName`.
3. Collisions: append ` 2`, ` 3`, … re-truncating the base to stay inside the
   budget (auto), or throw `nameTaken` (manual).
4. Move `<old>.m4a` in the session directory. Failure → `audioMoveFailed`,
   nothing else touched.
5. Write the manifest with the new `name`, `originalName` preserved. Failure →
   move the audio back, throw `manifestWriteFailed`.
6. Move the user-folder `.m4a` and the two transcript exports; each failure is a
   warning. A missing source (no transcript exports when Insights was off) is
   skipped silently.

### 5. `SessionManifest` — one new field

`originalName: String?`, `currentVersion = 3`. `init` sets it from `name`;
`init(from:)` uses `decodeIfPresent` defaulting to `name` so v1 and v2 manifests
load unchanged (Req 3.4). `name` remains the display name, so `HistoryScanner`,
`RecoveryManager`, and `SessionEncoder` are unaffected.

### 6. `AppState` — orchestration and settings

```swift
public enum NamingBackend: String, Codable, Sendable { case off, onDevice, amazonTranscribe }

@Published public private(set) var lastSavedName: String?
@Published public private(set) var lastSavedSessionDirectory: URL?
@Published public var autoNameRecordings: Bool          // default true
@Published public var namingBackend: NamingBackend      // default .onDevice
@Published public private(set) var isNaming = false
@Published public private(set) var isRenaming = false

/// Injected by the app target, like `insightsFactory`.
public var llmClientFactory: ((InsightsConfiguration) -> any LLMClient)?
public var cloudNamingTranscriberFactory: ((InsightsConfiguration) -> any NamingTranscriber)?

public func renameLastRecording(to newName: String)
public func rename(_ item: HistoryItem, to newName: String) -> Bool
```

Persisted in `UserDefaults`: `autoNameRecordings`, `namingBackend`,
`namingCloudConsentGranted`. `namingBackend = .amazonTranscribe` can only be set
through a confirmation that states a portion of the recording will be uploaded to
Amazon Transcribe (Req 4.5); the consent flag records that it was granted.

The banner message is decomposed so the name is no longer embedded in a string:
`statusMessage` keeps warnings, and the file name renders from `lastSavedName`.
That is what makes the name a distinct, clickable view rather than text inside a
sentence.

`stopRecording()` tail, after `pipeline.finish()`:

```
guard autoNameRecordings, namingBackend != .off else { return }
isNaming = true
namingTask = Task.detached(priority: .utility) { … RecordingNamer … SessionRenamer … }
```

`namingTask` is stored and cancelled by `startRecording()` (Req 4.11) and by a
manual rename (Req 2.10).

`AudioRecorderApp` gains two injections beside `insightsFactory`:

```swift
state.llmClientFactory = { LazyBedrockClient(configuration: $0) }        // made public
state.cloudNamingTranscriberFactory = { AWSFileTranscriber(configuration: $0) }
```

### 7. UI

`ContentView` gains `savedNameRow` below the banner, shown when
`lastSavedName != nil`:
- Idle: `Button(name)` in `.plain` style with a pencil glyph and "Click to
  rename" help, beside the existing Show in Finder button; disabled while
  `isRecording || isSaving || isRenaming`; a small "Naming…" `ProgressView` while
  `isNaming`.
- Editing: `TextField` bound to `@State draftName`, focused with text selected
  via `@FocusState`, `.onSubmit` saves, `.onExitCommand` cancels, Save disabled
  with an inline reason when `SessionRenamer.validate` fails.
- Accessibility: `accessibilityLabel("Recording name, \(name)")`,
  `accessibilityHint("Activate to rename")`; the field is labeled "Recording
  name".

A naming row near the Live Insights row exposes `autoNameRecordings` and a
`namingBackend` picker whose caption states plainly what leaves the machine:
"On-device — audio stays on this Mac" / "Amazon Transcribe — the first 3 minutes
are uploaded" (Req 4.6).

`HistoryView`'s detail pane gains a Rename button using the same affordance,
calling `state.rename(item, to:)` then `model.refresh(root:)`.

## Testing

New, under `Tests/AudioRecorderCoreTests/`:

`RecordingTitlerTests` — sanitize (strips `/` and `:`, collapses whitespace,
trims leading `-`/`.`, word-boundary truncation within 14, hard cut for one long
word, nil on empty/punctuation-only, keeps digits and internal hyphens); parse
(unwraps quotes, fences, `Title:` prefix, trailing period; a long sentence is
truncated, not rejected); heuristicTitle (stable output for a fixed transcript,
stop words excluded, nil for stop-words-only).

`SessionRenameTests` — temp-directory based, in the style of
`TranscriptPersistenceTests`: renames backup `.m4a` + manifest with
`originalName` intact; renames user-folder `.m4a` and both transcript exports;
missing exports produce no warnings; `allowSuffix: true` collision yields ` 2`
inside the budget; `allowSuffix: false` collision throws `nameTaken` and changes
nothing; invalid names (`""`, `"a/b"`, `".hidden"`, 51 chars) throw and change
nothing; a read-only user destination yields warnings with a consistent backup +
manifest; `HistoryScanner.scan` then reports the new name with non-nil
`audioURL`.

`SessionManifestTests` (extend) — v2 fixture decodes with `originalName == name`;
v3 round-trip preserves a divergent `originalName`.

`AudioFileChunkerTests` — synthesize a 5-second tone with `AVAudioFile`, then
assert: chunks are uniform 3,200 bytes (100 ms at 16 kHz mono Int16), total
duration is capped by `maxDuration`, a mono and a stereo source both work, and
`.realTime` pacing takes measurably longer than unpaced.

`RecordingNamerTests` — with a mock `NamingTranscriber` and the existing mock
`LLMClient`: live transcript short-circuits transcription; empty live transcript
triggers the transcriber; a throwing LLM falls back to the heuristic; a throwing
transcriber yields nil; a hanging transcriber is cut off by the budget; a
cancelled task returns nil promptly.

`AudioRecorderInsightsTests` — `AWSFileTranscriber` chunk pacing and retry
selection are unit-testable without the network by injecting a stub streamer;
live-service coverage belongs in the existing `LiveAWSIntegrationTests`, gated as
those already are.

`LocalSpeechTranscriber` is not unit-tested (it needs OS models and an
authorization prompt); it is covered by the manual pass in task 14.

## Risks

| Risk | Mitigation |
|---|---|
| Naming uploads audio a user expected to stay local | Explicit opt-in naming the service and the window (Req 4.5); on-device default; `requiresOnDeviceRecognition` on the Apple path too |
| Per-recording Transcribe cost surprises the user | Bounded 3-minute head window, shown in the setting caption; see the Amazon Transcribe pricing page for rates |
| On-device model unavailable for the user's locale | `SpeechTranscriber` asset check, then `supportsOnDeviceRecognition`, then quiet fallback to the timestamp name |
| Replay pacing trips a service protection | 4× cap with a single real-time retry (Req 4.8), uniform 100 ms chunks per AWS guidance |
| Naming contends with the next recording | Detached utility-priority task, cancelled by `startRecording()` (Req 4.11) |
| Model returns a name that leaks sensitive content into a file name | Manual rename always available; auto-naming can be turned off (Req 1.9) |
| Two recordings finish with the same generated name | Numeric suffix inside the budget, checked in both destinations (Req 1.5) |
| Banner name changing seconds after save looks like a glitch | "Naming…" indicator makes it a visible step rather than a silent mutation |
