# SnoreDetector (iOS)

Free, on-device snoring detection. Records all night, detects snoring in real time with
Apple's built-in SoundAnalysis classifier (`snoring` class), and saves **only** the audio
segments where snoring occurred — with timestamps. Non-snoring audio is never written to disk.

No servers, no subscriptions, no network access at all.

## Requirements

- Xcode 15 or newer
- iPhone running iOS 17+ (SwiftData requirement)
- Free Apple ID is enough (personal team signing)

## How to run

1. Open `SnoreDetector.xcodeproj` in Xcode.
2. Select the **SnoreDetector** target → *Signing & Capabilities* → set **Team** to your
   personal team (Xcode > Settings > Accounts to add your Apple ID). Change the bundle ID
   if Xcode complains it's taken.
3. Plug in your iPhone, select it as the run destination, press **Run**.
4. First launch on device: Settings > General > VPN & Device Management → trust your developer certificate.

## How to test detection (before a real night)

1. Launch the app, tap **Start**, allow microphone access.
2. Enable the **Debug log** toggle and watch the live *Snoring confidence* meter.
3. Play snoring audio at the phone from another device — e.g. clips from the free Kaggle
   dataset the reference paper used: https://www.kaggle.com/datasets/tareqkhanemu/snoring
   or any YouTube snoring compilation. Real snoring works even better.
4. After ~3 s of snoring you should see confidence spike above the 60% threshold and an
   event begin; stop the sound and the event finalizes ~10 s later.
5. Tap **Stop**, open **History** → the session shows a night timeline strip and the event
   list; tap play to hear each saved clip (each clip includes ~10 s of pre-roll).

## Overnight use

- Tap **Start**, plug the phone in, place it on the nightstand, lock the screen.
  Recording continues in the background (`UIBackgroundModes: audio`).
- Tap **Stop** when you wake up.
- Battery: on charge, negligible. Unplugged, expect roughly 5–15%/hour — charging overnight
  is recommended (same as SnoreLab).

## Architecture (core function)

| Piece | File | What it does |
|---|---|---|
| Capture | `SnoreDetectionEngine.swift` | `AVAudioEngine` mic tap; `.record` session; survives lock + interruptions |
| Detection | `SnoreDetectionEngine.swift` | `SNAudioStreamAnalyzer` + built-in classifier, 1.5 s windows, 50% overlap |
| Segmentation | `SnoreDetectionEngine.swift` | Event starts after 2 consecutive hits ≥ 0.6 confidence; ends after 10 s quiet |
| Clip saving | `SnoreDetectionEngine.swift` | 10 s in-memory pre-roll ring buffer → AAC `.m4a`, written only during events |
| Persistence | `Models.swift` | SwiftData: `SleepSession` → `SnoreEvent` (times, peak confidence, clip file) |
| Live UI | `SessionView.swift` | Start/Stop, elapsed time, confidence meter, tonight's events, debug log |
| Review UI | `HistoryView.swift` | Session list, stats, night timeline strip, per-event playback |

### Tuning knobs (top of `SnoreDetectionEngine.swift`)

- `confidenceThreshold` (default 0.6) — raise if false positives, lower if missed snores
- `endHangover` (10 s) — how much silence ends an episode
- `consecutiveToStart` (2 windows) — debounce before an episode starts
- `preRollDuration` (10 s) — audio kept before detection trigger

### Upgrade path (M5, optional)

If the built-in classifier underperforms on real nights: train a Create ML *Sound
Classification* model on the Kaggle dataset above (drag folders, press Train, export
`.mlmodel`) and replace one line in `SnoreDetectionEngine.start`:

```swift
// let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
let request = try SNClassifySoundRequest(mlModel: SnoreClassifier(configuration: .init()).model)
```

## Privacy

Everything runs and stays on the device. The only audio ever persisted is the detected
snoring clips, stored in the app's Documents/Sessions folder. Deleting a session in
History deletes its clips.
