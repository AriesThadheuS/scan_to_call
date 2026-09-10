# 📱 Scan to Call

> **A real-time offline phone number scanner for Android**  
> Point your camera at any phone number — and call it instantly.

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🔍 Live Camera OCR | Continuously scans camera frames using Google ML Kit |
| 📞 Instant Dialer | Taps detected number → opens native phone dialer |
| 🧠 Multi-Number Picker | Multiple numbers in view → modal bottom sheet to select |
| 🖼️ Gallery Scan | Upload any image to extract and call a phone number |
| 💾 Offline SQLite Log | Every dialed number logged locally — no internet needed |
| 🔦 Flashlight Toggle | Built-in torch control for low-light scanning |
| 🛡️ Frame Stabilization | 700ms debounce prevents flicker from hand shake |

---

## 📸 How It Works

```
Open App
   │
   ▼
Camera starts live scanning (every 300ms)
   │
   ├── 0 numbers found   → Waiting state: "Align phone number here"
   ├── 1 number found    → Green bounding box + "Call XXXXXXXXXX" button
   └── 2+ numbers found  → Bottom sheet: pick which number to call
         │
         └── Tap number → SQLite log → Native dialer launched
```

---

## 🗂️ Project Structure

```
scan_to_call/
├── lib/
│   └── main.dart                  # All app logic (camera, OCR, UI, DB)
├── android/
│   ├── app/
│   │   ├── build.gradle.kts       # Build config: minify, ProGuard, APK naming
│   │   ├── proguard-rules.pro     # Keep rules: MLKit, SQLite, Flutter
│   │   └── src/main/
│   │       ├── AndroidManifest.xml # App name, permissions
│   │       └── res/mipmap-*/      # Launcher icons (all density buckets)
│   └── gradle.properties          # JVM memory settings
├── assets/
│   └── logo.png                   # App logo
└── pubspec.yaml                   # Flutter dependencies
```

---

## 📦 Dependencies

```yaml
dependencies:
  camera: ^0.11.0+2                      # Live camera stream
  image_picker: ^1.1.2                   # Gallery image selection
  google_mlkit_text_recognition: ^0.14.0 # On-device OCR engine
  url_launcher: ^6.3.0                   # Native dialer launch
  permission_handler: ^11.3.1            # Runtime permissions
  sqflite: ^2.3.3                        # Local SQLite database
  path: ^1.9.0                           # DB path helper
```

---

## 🚀 Getting Started

### Prerequisites
- Flutter SDK ≥ 3.0.0
- Android Studio / JDK 17+
- Android device with camera

### Run in Development
```bash
git clone https://github.com/AriesThadheuS/phone-number-scanner.git
cd phone-number-scanner
flutter pub get
flutter run
```

### Build Release APK (Recommended: Split per ABI)
```bash
# Slim per-architecture APKs (~25–31 MB each)
flutter build apk --release --split-per-abi --no-tree-shake-icons

# Fat universal APK (~74 MB, all architectures)
flutter build apk --release --no-tree-shake-icons
```

### Output APKs
```
build/app/outputs/flutter-apk/
├── app-arm64-v8a-release.apk   → Modern phones (2019+)
├── app-armeabi-v7a-release.apk → Older/budget phones
└── app-x86_64-release.apk      → Emulators
```

---

## 🔐 Permissions Required

| Permission | Reason |
|------------|--------|
| `CAMERA` | Live viewfinder scanning |
| `READ_MEDIA_IMAGES` | Gallery image upload |
| `CALL_PHONE` | Direct call launch |
| `READ_PHONE_STATE` | Phone permission check |

---

## 📐 Architecture

```
_processCameraFrame (every 300ms)
        │
        ▼
_extractAllPhoneNumbers (ML Kit text → List<String>)
        │
   ┌────┴────┐
 count=1   count>1
   │           │
 Green Box  Bottom Sheet
 Call Btn   Number Picker
   │           │
   └────┬──────┘
        ▼
_handleDetectedNumber
   ├── SQLite: DatabaseHelper.logCall()
   └── _openDialer → tel: URL intent
```

---

## 🧠 Key Logic Explained

### Frame Stabilization (Anti-Shake)
```dart
// Holds last detected number visible for 700ms even if frames miss it
// Prevents flicker during hand movement
static const int _stabilizationHoldMs = 700;
```

### Multi-Number Bottom Sheet
```dart
// Triggered when >1 valid phone numbers appear simultaneously in view
// Pauses camera scanning while picker is open
// 1.5s cooldown after dismissal (anti-flicker)
Future<void> _showMultipleNumbersBottomSheet(List<String> numbers)
```

### Number Parsing (4-tier regex engine)
1. International format: `+91 9876543210`
2. Zero-lead Indian: `09876543210`
3. Standard 10-digit Indian: `[6-9]XXXXXXXXX`
4. Generic 10–15 digit fallback

---

## 🌿 Git Branches

| Branch | Purpose |
|--------|---------|
| `UAT` | Testing / staging builds |
| `Main` | Production-ready release |

---

## 📝 Changelog

### v1.0.0 — 10 September 2026
- ✅ App renamed to **Scan to Call**
- ✅ Custom green scanner launcher icon (all density buckets)
- ✅ Code minification + resource shrinking (ProGuard/R8)
- ✅ Split-per-ABI APKs: 74 MB → ~25–31 MB
- ✅ Frame stabilization (700ms debounce)
- ✅ Gallery button position fixed (above gesture bar)
- ✅ Multi-number extraction engine (`Set<String>` deduplication)
- ✅ Modal bottom sheet number picker (dark glassmorphic UI)
- ✅ Anti-flicker 1.5s cooldown after modal dismiss
- ✅ SQLite source tagging: `'camera'`, `'gallery'`, `'camera_multi'`

---

## 👨‍💻 Author

**AriesThadheuS**  
GitHub: [@AriesThadheuS](https://github.com/AriesThadheuS)

---

*Built with Flutter 💙 | Powered by Google ML Kit*
