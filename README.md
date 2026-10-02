# 📱 Scan to Call

> **A real-time offline phone number scanner for Android**  
> Point your camera at any phone number — and call it instantly.

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🔍 **Live Camera OCR** | High-speed 1080p continuous stream parsing using Google ML Kit |
| 🎯 **Spatial ROI Box Filtering** | Filters text elements strictly within the green Viewfinder box (≥80% overlap) |
| 🗳️ **Rolling Consensus Engine** | 3-frame buffer requiring 2/3 majority vote before committing numbers |
| 🔤 **OCR Confusion Matrix** | Context-aware sanitizer fixing OCR character confusions (`O`→`0`, `l`→`1`, `S`→`5`, `B`→`8`) |
| 🌐 **Universal Global Parsing** | Native E.164 (`+1`, `+44`, `+91`, `+971`), trunk zero prefixes, and international formats |
| 🛡️ **Noise & False-Positive Rejection** | Filters out dates, timestamps, IP addresses, prices, and sequential/repeated numbers |
| 📞 **Instant Dialer** | One-tap dialing with zero delay permissions check and native dialer launch |
| 🧠 **Multi-Number Picker** | Displays a dark glassmorphic modal sheet when multiple numbers are in view |
| 🖼️ **Gallery Upload** | Fallback image picker for extracting phone numbers from gallery screenshots |
| 💾 **Offline SQLite Log** | Non-blocking offline call logging — zero internet connection required |
| 🔦 **Flashlight & Haptics** | Built-in torch toggle and tactile haptic vibration (`HapticFeedback.mediumImpact()`) on match |

---

## 📸 How It Works

```
                     Live 1080p Camera Stream (250ms FPS Throttle)
                                       │
                                       ▼
                       Spatial ROI Bounding Box Filtering
                  (Extract lines inside green viewfinder box ≥80%)
                                       │
                                       ▼
                    Global OCR Character Confusion Matrix
             (Fix O->0, l->1, S->5, B->8, Q->0 digit confusions)
                                       │
                                       ▼
                     Universal Global Phone Parser & Rejection
            (E.164, Trunk Zero, Length 10-15, Reject Dates/IPs/Prices)
                                       │
                                       ▼
                     Rolling Consensus Voting Engine
               (Requires candidate match in ≥2 of 3 frames)
                                       │
                ┌──────────────────────┴──────────────────────┐
            count=1                                       count>1
                │                                             │
      Green Viewfinder Lock                        Modal Bottom Sheet
      Tactile Haptic Vibration                     Interactive Number Picker
      "Call +1 555-019-2834"                                  │
                │                                             │
                └──────────────────────┬──────────────────────┘
                                       ▼
                         Non-blocking SQLite Call Log
                                       │
                                       ▼
                            Native Device Dialer Launch
```

---

## 📥 APK Downloads & Device Support

> **Don't know which APK to download?**  
> Most modern Android phones (released after 2019) use **arm64-v8a**.

### 🔽 Direct Download

| Device Type | Architecture | Size | Download |
|-------------|-------------|------|----------|
| 📱 **New Phones** (2019+) — Samsung, OnePlus, Pixel, Redmi, Realme | `arm64-v8a` (64-bit) | ~31 MB | [📥 Download APK](https://github.com/AriesThadheuS/phone-number-scanner/releases/latest/download/Scan_to_Call-arm64.apk) |
| 📱 **Old / Budget Phones** (pre-2019, entry-level) | `armeabi-v7a` (32-bit) | ~24 MB | [📥 Download APK](https://github.com/AriesThadheuS/phone-number-scanner/releases/latest/download/Scan_to_Call-arm32.apk) |
| 💻 **Android Emulator / x86 Tablet** | `x86_64` | ~33 MB | [📥 Download APK](https://github.com/AriesThadheuS/phone-number-scanner/releases/latest/download/Scan_to_Call-x86_64.apk) |

> 🔗 All releases: [github.com/AriesThadheuS/phone-number-scanner/releases](https://github.com/AriesThadheuS/phone-number-scanner/releases)

---

### 🤔 How to Find Your Phone's Architecture

**Method 1 — Settings:**
> Settings → About Phone → Processor / CPU info  
> Look for: `ARM64` / `AArch64` → download **arm64-v8a**  
> Look for: `ARM` / `ARMv7` → download **armeabi-v7a**

**Method 2 — Quick Rule:**
> Bought your phone **after 2018**? → Download **arm64-v8a** ✅  
> Using an **Android emulator** on PC/Mac? → Download **x86_64** ✅

---

### 📲 Step-by-Step Installation Guide

> ⚠️ Since this APK is not from the Play Store, allow installation from unknown sources.

**Step 1 — Allow Unknown Sources**
```
Android 8.0+ (Oreo and above):
Settings → Apps → Special App Access → Install Unknown Apps
→ Select your browser/file manager → Toggle ON "Allow from this source"

Android 7.0 and below:
Settings → Security → Unknown Sources → Toggle ON
```

**Step 2 — Download the APK**
- Tap the correct **📥 Download APK** button above for your device
- The APK file will download to your `Downloads` folder

**Step 3 — Install**
- Open your `Downloads` folder (use Files / My Files app)
- Tap `Scan_to_Call-arm64.apk` (or whichever architecture you downloaded)
- Tap **Install** → wait a few seconds

**Step 4 — Grant Permissions**
- On first launch, grant requested permissions:
  - 📷 **Camera** — required for live scanning
  - 📞 **Phone** — required to open the dialer

**Step 5 — Start Scanning!**
- Point camera at any phone number on a business card, banner, or screen
- Green target locks on number → tap **"Call XXXXXXXXXX"** → dialer opens instantly 🎉

---

### 🔒 Is It Safe?

- ✅ **100% Offline** — Zero internet connection required or used
- ✅ **Zero Telemetry** — All data stored locally in SQLite (`call_log.db`)
- ✅ **Open Source** — Full source code available on GitHub
- ✅ **No ads, no tracking, no external SDKs**

---

## 🗂️ Project Structure

```
scan_to_call/
├── lib/
│   └── main.dart                  # All app logic (camera, ROI filtering, OCR matrix, consensus engine, DB)
├── test/
│   └── widget_test.dart           # App smoke test
├── android/
│   ├── app/
│   │   ├── build.gradle.kts       # Build config: minify, ProGuard, ABI splitting
│   │   ├── proguard-rules.pro     # Keep rules for ML Kit & SQLite
│   │   └── src/main/
│   │       ├── AndroidManifest.xml # App permissions & activity configuration
│   │       └── res/mipmap-*/      # Custom launcher icons (hdpi to xxxdpi)
│   └── gradle.properties          # JVM memory options
└── pubspec.yaml                   # Flutter dependencies
```

---

## 📦 Dependencies

```yaml
dependencies:
  camera: ^0.11.4                        # High-resolution live camera stream
  image_picker: ^1.1.2                   # Gallery fallback selector
  google_mlkit_text_recognition: ^0.14.0 # On-device OCR engine
  url_launcher: ^6.3.0                   # Native dialer launcher
  permission_handler: ^11.4.0            # Dynamic runtime permissions
  sqflite: ^2.4.2+1                      # Offline SQLite call history
  path: ^1.9.0                           # DB path utilities
```

---

## 🚀 Build From Source

### Prerequisites
- Flutter SDK >= 3.0.0
- JDK 17+ & Android SDK (API 34)
- Android device or emulator

### Development Setup
```bash
git clone https://github.com/AriesThadheuS/phone-number-scanner.git
cd phone-number-scanner
flutter pub get
flutter run
```

### Production Release Build (Split per ABI)
```bash
# Generate architecture-optimized release APKs (~24MB to 33MB each)
flutter build apk --release --split-per-abi --no-tree-shake-icons
```

### Output APK Locations
```
build/app/outputs/flutter-apk/
├── app-arm64-v8a-release.apk   → Modern 64-bit phones (2019+)   ~31 MB
├── app-armeabi-v7a-release.apk → Legacy 32-bit budget phones    ~24 MB
└── app-x86_64-release.apk      → Android Emulators & PCs        ~33 MB
```

---

## 📐 Key Architecture & Engine Components

### 1. Spatial ROI Bounding Box Filter (`_extractCandidatesWithROI`)
Calculates screen-space bounding boxes for each recognized line from camera space and discards any element outside the target green viewfinder rectangle:
```dart
// Ensures only text inside active green box (≥80% overlap area) is processed
bool _isInsideRoi(Rect elementRect, Rect roi, {double threshold = 0.80})
```

### 2. Multi-Frame Rolling Consensus Voting Engine (`ConsensusVoter`)
Prevents 1-frame OCR misreads and motion blur glitches by holding candidates in a 3-frame buffer:
```dart
class ConsensusVoter {
  final List<Set<String>> _frameBuffer = [];
  Set<String> vote(Set<String> frameCandidates) {
    // Requires candidate number in at least 2 of last 3 frames to reach consensus
  }
}
```

### 3. OCR Character Confusion Matrix (`_sanitizeOcrText`)
Fixes common digit-letter optical recognition confusions prior to regex verification:
```dart
static const Map<String, String> _ocrConfusionMatrix = {
  'O': '0', 'o': '0', 'Q': '0', 'D': '0',
  'I': '1', 'l': '1', 'i': '1', '|': '1', '!': '1', ']': '1',
  'Z': '2', 'z': '2', 'E': '3', 'e': '3', 'A': '4',
  'S': '5', 's': '5', r'$': '5', 'G': '6', 'b': '6',
  'T': '7', 't': '7', 'B': '8', 'q': '9', 'g': '9',
};
```

---

## 📝 Changelog

### v1.1.0 — 2 October 2026
- **GPay/PhonePe-Level Scanning Pipeline:**
  - Integrated 1080p high-resolution camera stream (`ResolutionPreset.high`) with continuous auto-focus.
  - Added spatial ROI bounding box filtering to isolate text inside the green viewfinder box.
  - Implemented 3-frame rolling consensus voting engine (2/3 majority requirement).
  - Added OCR character confusion matrix sanitizer (`O`→`0`, `l`→`1`, `S`→`5`, `B`→`8`).
  - Implemented universal global phone number parser supporting E.164, local trunk zero, and international formats.
  - Added strict noise rejection filtering dates, timestamps, IP addresses, and currency/prices.
  - Added tactile haptic response on consensus lock (`HapticFeedback.mediumImpact()`).

---

## 👨‍💻 Author

**AriesThadheuS**  
GitHub: [@AriesThadheuS](https://github.com/AriesThadheuS)

---

*Built with Flutter 💙 | Powered by Google ML Kit*
