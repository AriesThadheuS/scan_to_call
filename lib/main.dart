import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

// ═══════════════════════════════════════════════════════════════════════════════
// DatabaseHelper — Offline SQLite call log
// ═══════════════════════════════════════════════════════════════════════════════
class DatabaseHelper {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final String dbPath = p.join(await getDatabasesPath(), 'call_log.db');
    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE call_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            phone_number TEXT NOT NULL,
            source TEXT NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  /// Insert a call log entry. Safe to call without await — never throws to caller.
  static Future<void> logCall(String phoneNumber, String source) async {
    try {
      final db = await database;
      await db.insert('call_log', {
        'phone_number': phoneNumber,
        'source': source,
        'synced': 0,
        'created_at': DateTime.now().toIso8601String(),
      });
      debugPrint('[SQLite] Call logged: $phoneNumber ($source)');
    } catch (e) {
      debugPrint('[SQLite] ERROR logging call: $e');
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ENHANCEMENT 4: Multi-Frame Rolling Consensus Voting Engine
// ═══════════════════════════════════════════════════════════════════════════════
/// Requires a candidate phone number to appear in at least [minVotes] out of the last
/// [bufferSize] consecutive frames before being committed to UI state.
/// This completely eliminates 1-frame OCR noise, motion blur glitches, and misreads.
class ConsensusVoter {
  final int bufferSize;
  final int minVotes;

  // Ring buffer of per-frame candidate sets
  final List<Set<String>> _frameBuffer = [];

  ConsensusVoter({this.bufferSize = 3, this.minVotes = 2});

  /// Feed candidate numbers found in the current frame.
  /// Returns the Set of phone numbers that have reached consensus majority.
  Set<String> vote(Set<String> frameCandidates) {
    // Push current frame candidates; evict oldest frame if buffer capacity reached
    _frameBuffer.add(Set<String>.from(frameCandidates));
    if (_frameBuffer.length > bufferSize) {
      _frameBuffer.removeAt(0);
    }

    // Tally frequency of each candidate across buffered frames
    final Map<String, int> tally = {};
    for (final frame in _frameBuffer) {
      for (final candidate in frame) {
        tally[candidate] = (tally[candidate] ?? 0) + 1;
      }
    }

    // Return only numbers meeting or exceeding minVotes threshold
    return tally.entries
        .where((e) => e.value >= minVotes)
        .map((e) => e.key)
        .toSet();
  }

  /// Clear the rolling frame buffer (e.g. on app pause/resume or camera switch).
  void reset() => _frameBuffer.clear();
}

// ═══════════════════════════════════════════════════════════════════════════════
// App Entry Point
// ═══════════════════════════════════════════════════════════════════════════════
List<CameraDescription> _cameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('Failed to get available cameras: $e');
  }

  runApp(const PhoneExtractorApp());
}

class PhoneExtractorApp extends StatelessWidget {
  const PhoneExtractorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scan to Call',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
      ),
      home: const LiveCameraScannerScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// LiveCameraScannerScreen — Main High-Speed Scanner Widget
// ═══════════════════════════════════════════════════════════════════════════════
class LiveCameraScannerScreen extends StatefulWidget {
  const LiveCameraScannerScreen({super.key});

  @override
  State<LiveCameraScannerScreen> createState() =>
      _LiveCameraScannerScreenState();
}

class _LiveCameraScannerScreenState extends State<LiveCameraScannerScreen>
    with WidgetsBindingObserver {
  // ── Camera Controller ─────────────────────────────────────────────────────
  CameraController? _cameraController;
  final int _selectedCameraIndex = 0;
  bool _isCameraInitialized = false;
  bool _isFlashOn = false;

  // ── Frame Processing Pipeline State ───────────────────────────────────────
  bool _isProcessingFrame = false;
  int _lastFrameProcessedTimestamp = 0;

  // ── UI & Detection State ──────────────────────────────────────────────────
  String? _detectedPhoneNumber;
  String? _lastAutoSavedNumber;

  // ENHANCEMENT 4: Multi-frame consensus voter (3-frame buffer, 2/3 majority vote)
  final ConsensusVoter _consensusVoter =
      ConsensusVoter(bufferSize: 3, minVotes: 2);

  // Stabilization: hold last confirmed number for 700ms to prevent UI flicker
  int _lastValidDetectionTimestamp = 0;
  static const int _stabilizationHoldMs = 700;

  // Modal Bottom Sheet State
  bool _isBottomSheetOpen = false;
  int _modalDismissCooldownUntil = 0;

  // ── Viewfinder ROI Bounding Box (Screen Space) ───────────────────────────
  Rect _viewfinderRoi = Rect.zero;

  // ── Recognition Tools ─────────────────────────────────────────────────────
  final ImagePicker _imagePicker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  // ── ENHANCEMENT 2: Global OCR Character Confusion Matrix ─────────────────
  /// Maps common OCR digit-letter confusion errors to proper numeric digits.
  static const Map<String, String> _ocrConfusionMatrix = {
    'O': '0', 'o': '0', 'Q': '0', 'D': '0',
    'I': '1', 'l': '1', 'i': '1', '|': '1', '!': '1', ']': '1',
    'Z': '2', 'z': '2',
    'E': '3', 'e': '3',
    'A': '4',
    'S': '5', 's': '5', r'$': '5',
    'G': '6', 'b': '6',
    'T': '7', 't': '7',
    'B': '8',
    'q': '9', 'g': '9',
  };

  // Compiled regex pattern for character replacement
  static final RegExp _confusionPattern = RegExp(
    '[${_ocrConfusionMatrix.keys.map(RegExp.escape).join()}]',
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle Handlers
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_cameras.isNotEmpty) {
      _initCamera(_cameras[_selectedCameraIndex]);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cc = _cameraController;
    if (cc == null || !cc.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _stopCameraStream();
    } else if (state == AppLifecycleState.resumed) {
      _consensusVoter.reset(); // Reset voter on app resume to flush stale frames
      _initCamera(cc.description);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCameraStream();
    _cameraController?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ENHANCEMENT 6: Camera Initialization with High-Res 1080p & AutoFocus
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initCamera(CameraDescription cameraDescription) async {
    final CameraController cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.high, // 1080p resolution for high OCR accuracy
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    _cameraController = cameraController;

    try {
      await cameraController.initialize();
      if (!mounted) return;

      // Enable continuous auto-focus mode immediately after initialization
      try {
        await cameraController.setFocusMode(FocusMode.auto);
        debugPrint('[CAMERA] AutoFocus initialized to FocusMode.auto');
      } catch (e) {
        debugPrint('[CAMERA] Focus mode set exception (non-fatal): $e');
      }

      setState(() => _isCameraInitialized = true);
      _startCameraStream();
    } catch (e) {
      debugPrint('[CAMERA] Initialization error: $e');
    }
  }

  /// Starts live camera stream processing
  void _startCameraStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_cameraController!.value.isStreamingImages) return;

    _cameraController!.startImageStream(_processCameraFrame);
  }

  /// Stops camera image stream safely
  Future<void> _stopCameraStream() async {
    if (_cameraController != null &&
        _cameraController!.value.isInitialized &&
        _cameraController!.value.isStreamingImages) {
      try {
        await _cameraController!.stopImageStream();
      } catch (e) {
        debugPrint('[CAMERA] Stop stream error: $e');
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // InputImage Construction
  // ─────────────────────────────────────────────────────────────────────────
  InputImage? _inputImageFromCameraImage(
      CameraImage image, CameraDescription camera) {
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation =
        InputImageRotationValue.fromRawValue(sensorOrientation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final inputImageFormat = format ??
        (Platform.isAndroid
            ? InputImageFormat.nv21
            : InputImageFormat.bgra8888);

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // High-Performance Frame Processing Pipeline (250ms Throttled)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _processCameraFrame(CameraImage image) async {
    if (_cameraController == null) return;

    final int now = DateTime.now().millisecondsSinceEpoch;

    // Skip processing during bottom sheet display or cooldown window
    if (_isBottomSheetOpen || now < _modalDismissCooldownUntil) return;

    // Throttle OCR to 1 frame every 250ms (~4 FPS — sweet spot for accuracy and battery)
    if (now - _lastFrameProcessedTimestamp < 250) return;

    if (_isProcessingFrame) return;
    _isProcessingFrame = true;
    _lastFrameProcessedTimestamp = now;

    try {
      final inputImage =
          _inputImageFromCameraImage(image, _cameraController!.description);

      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      // ── ML Kit Text Recognition ──────────────────────────────────────────
      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      // ── Extract candidate numbers strictly within ROI ────────────────────
      final Set<String> frameCandidates =
          _extractCandidatesWithROI(recognizedText, image);

      if (!mounted) return;

      // ── ENHANCEMENT 4: Rolling consensus vote ─────────────────────────────
      final Set<String> confirmedCandidates =
          _consensusVoter.vote(frameCandidates);

      // ── State Routing ─────────────────────────────────────────────────────
      if (confirmedCandidates.length > 1) {
        // Multiple confirmed candidates -> trigger bottom sheet selector
        debugPrint(
            '[MULTI DETECT] Consensus found ${confirmedCandidates.length} numbers: $confirmedCandidates');
        _showMultipleNumbersBottomSheet(confirmedCandidates.toList());
      } else if (confirmedCandidates.length == 1) {
        // Single confirmed candidate -> lock UI state and trigger haptics
        final String foundNumber = confirmedCandidates.first;
        _lastValidDetectionTimestamp = now;

        if (_detectedPhoneNumber != foundNumber) {
          // ENHANCEMENT 6: Tactile feedback on instant consensus verification
          HapticFeedback.mediumImpact();
          debugPrint('[CONSENSUS LOCKED] Phone number verified: "$foundNumber"');
        }

        if (foundNumber != _lastAutoSavedNumber) {
          _lastAutoSavedNumber = foundNumber;
          debugPrint('[CAMERA DETECT] Number logged: $foundNumber');
        }

        setState(() {
          _detectedPhoneNumber = foundNumber;
        });
      } else {
        // No consensus number in this frame -> apply 700ms stabilization hold
        if (_detectedPhoneNumber != null &&
            (now - _lastValidDetectionTimestamp < _stabilizationHoldMs)) {
          // Hold last valid detection to eliminate flicker during hand jitter
        } else {
          if (_detectedPhoneNumber != null || _lastAutoSavedNumber != null) {
            _lastAutoSavedNumber = null;
            setState(() {
              _detectedPhoneNumber = null;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('[FRAME ERROR] Processing exception: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ENHANCEMENT 2: OCR Character Confusion Sanitizer
  // ─────────────────────────────────────────────────────────────────────────
  /// Replaces common OCR error characters (e.g. 'O' -> '0', 'l' -> '1', 'S' -> '5')
  String _sanitizeOcrText(String raw) {
    if (raw.isEmpty) return raw;
    return raw.splitMapJoin(
      _confusionPattern,
      onMatch: (m) => _ocrConfusionMatrix[m.group(0)!] ?? m.group(0)!,
      onNonMatch: (s) => s,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ENHANCEMENT 3: Strict Spatial ROI (Region of Interest) Bounding Box Filtering
  // ─────────────────────────────────────────────────────────────────────────
  /// Maps a bounding box from camera image pixel coordinates to screen space.
  Rect _imageRectToScreenRect(
    Rect imageRect,
    Size imageSize,
    Size screenSize,
    InputImageRotation rotation,
  ) {
    final double imgW;
    final double imgH;
    if (rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg) {
      imgW = imageSize.height;
      imgH = imageSize.width;
    } else {
      imgW = imageSize.width;
      imgH = imageSize.height;
    }

    final double scaleX = screenSize.width / imgW;
    final double scaleY = screenSize.height / imgH;
    final double scale = scaleX > scaleY ? scaleX : scaleY;

    final double offsetX = (screenSize.width - imgW * scale) / 2.0;
    final double offsetY = (screenSize.height - imgH * scale) / 2.0;

    return Rect.fromLTRB(
      imageRect.left * scale + offsetX,
      imageRect.top * scale + offsetY,
      imageRect.right * scale + offsetX,
      imageRect.bottom * scale + offsetY,
    );
  }

  /// Checks if [elementRect] intersects with [roi] by at least [threshold] (80%).
  bool _isInsideRoi(Rect elementRect, Rect roi, {double threshold = 0.80}) {
    if (roi == Rect.zero) return true;
    final Rect intersection = elementRect.intersect(roi);
    if (intersection.isEmpty) return false;
    final double elementArea = elementRect.width * elementRect.height;
    if (elementArea <= 0) return true;
    final double overlapArea = intersection.width * intersection.height;
    return (overlapArea / elementArea) >= threshold;
  }

  /// Filters recognized text lines by spatial ROI box and extracts clean candidates.
  Set<String> _extractCandidatesWithROI(
      RecognizedText recognizedText, CameraImage image) {
    final Set<String> results = {};
    final Size imageSize =
        Size(image.width.toDouble(), image.height.toDouble());
    final bool roiReady = _viewfinderRoi != Rect.zero;

    InputImageRotation rotation = InputImageRotation.rotation0deg;
    if (_cameraController != null) {
      final sensorOrientation =
          _cameraController!.description.sensorOrientation;
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ??
          InputImageRotation.rotation0deg;
    }

    final Size screenSize = _getScreenSize();

    for (final TextBlock block in recognizedText.blocks) {
      for (final TextLine line in block.lines) {
        // ENHANCEMENT 3: Bounding box spatial ROI filtering
        if (roiReady) {
          final Rect lineBB = Rect.fromLTRB(
            line.boundingBox.left.toDouble(),
            line.boundingBox.top.toDouble(),
            line.boundingBox.right.toDouble(),
            line.boundingBox.bottom.toDouble(),
          );
          final Rect screenBB =
              _imageRectToScreenRect(lineBB, imageSize, screenSize, rotation);

          if (!_isInsideRoi(screenBB, _viewfinderRoi)) {
            continue; // Skip line outside active viewfinder box
          }
        }

        // ENHANCEMENT 2: Apply OCR confusion matrix sanitizer
        final String sanitizedLine = _sanitizeOcrText(line.text);

        // ENHANCEMENT 1 & 5: Universal parsing + false positive rejection
        final Set<String> lineNumbers =
            _extractUniversalPhoneNumbers(sanitizedLine);
        results.addAll(lineNumbers);
      }
    }

    return results;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ENHANCEMENT 1: Universal Global Phone Parsing (E.164 & International)
  // ENHANCEMENT 5: Strict Noise Filtering & False-Positive Rejection
  // ─────────────────────────────────────────────────────────────────────────
  static final RegExp _intlE164 = RegExp(r'\+(?:\d[\s\-\.]?){7,14}\d');
  static final RegExp _intlWithCountryCode = RegExp(
      r'\+\d{1,3}[\s\-\.]?\(?\d{1,4}\)?[\s\-\.]?\d{2,5}[\s\-\.]?\d{2,5}[\s\-\.]?\d{0,5}');
  static final RegExp _trunkPrefixedNumber = RegExp(
      r'(?<!\d)0[\s\-\.]?[1-9]\d{1,3}[\s\-\.]?\d{3,5}[\s\-\.]?\d{3,5}(?!\d)');
  static final RegExp _localNumber = RegExp(
      r'(?<!\d)[2-9]\d{3}[\s\-\.\(\)]{0,2}\d{3}[\s\-\.]{0,1}\d{3,5}(?!\d)');

  // ENHANCEMENT 5 Exclusion patterns
  static final RegExp _datePattern = RegExp(
      r'\b(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{4})\b');
  static final RegExp _timePattern = RegExp(r'\b\d{1,2}:\d{2}(:\d{2})?\b');
  static final RegExp _ipPattern =
      RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b');
  static final RegExp _currencyPattern =
      RegExp(r'[\$₹€£¥]\s*[\d,\.]+|[\d,]+\.\d{2}\b');

  bool _isFalsePositive(String rawToken, String cleanDigits) {
    if (_datePattern.hasMatch(rawToken)) return true;
    if (_timePattern.hasMatch(rawToken)) return true;
    if (_ipPattern.hasMatch(rawToken)) return true;
    if (_currencyPattern.hasMatch(rawToken)) return true;
    if (cleanDigits.length == 4 &&
        int.tryParse(cleanDigits) != null &&
        int.parse(cleanDigits) >= 1900 &&
        int.parse(cleanDigits) <= 2100) {
      return true;
    }
    return false;
  }

  Set<String> _extractUniversalPhoneNumbers(String text) {
    if (text.trim().isEmpty) return {};
    final Set<String> results = {};

    final List<RegExp> patterns = [
      _intlE164,
      _intlWithCountryCode,
      _trunkPrefixedNumber,
      _localNumber,
    ];

    for (final RegExp pattern in patterns) {
      for (final Match m in pattern.allMatches(text)) {
        final String rawToken = m.group(0)!;
        final String digitsOnly = rawToken.replaceAll(RegExp(r'[^\d]'), '');

        if (_isFalsePositive(rawToken, digitsOnly)) continue;

        final bool hasPlus = rawToken.trimLeft().startsWith('+');
        final String clean = hasPlus ? '+$digitsOnly' : digitsOnly;

        // ENHANCEMENT 5: Length strictly 10 to 15 digits
        if (digitsOnly.length < 10 || digitsOnly.length > 15) continue;
        if (_isNonPhoneDigitPattern(digitsOnly)) continue;

        results.add(clean);
      }
    }

    return results;
  }

  bool _isNonPhoneDigitPattern(String digits) {
    // Reject repeated digits (e.g. 0000000000)
    if (RegExp(r'^(\d)\1+$').hasMatch(digits)) return true;

    // Reject sequential runs
    bool ascending = true, descending = true;
    for (int i = 1; i < digits.length; i++) {
      if (int.parse(digits[i]) != int.parse(digits[i - 1]) + 1) {
        ascending = false;
      }
      if (int.parse(digits[i]) != int.parse(digits[i - 1]) - 1) {
        descending = false;
      }
      if (!ascending && !descending) break;
    }
    if (ascending || descending) return true;

    return false;
  }

  String? _extractPhoneNumber(String text) {
    final String sanitized = _sanitizeOcrText(text);
    final Set<String> nums = _extractUniversalPhoneNumbers(sanitized);
    return nums.isNotEmpty ? nums.first : null;
  }

  Size _getScreenSize() {
    final binding = WidgetsBinding.instance;
    final view = binding.platformDispatcher.views.first;
    return Size(
      view.physicalSize.width / view.devicePixelRatio,
      view.physicalSize.height / view.devicePixelRatio,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI Component: Multiple Numbers Selection Bottom Sheet
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _showMultipleNumbersBottomSheet(List<String> numbers) async {
    if (!mounted || _isBottomSheetOpen) return;
    _isBottomSheetOpen = true;

    HapticFeedback.heavyImpact();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.filter_center_focus_rounded,
                        color: Colors.greenAccent,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Multiple Numbers Detected',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Select which number to call:',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: numbers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final String numStr = numbers[index];
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            _handleDetectedNumber(numStr, 'camera_multi');
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A3C),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.greenAccent
                                    .withValues(alpha: 0.35),
                                width: 1.2,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade600,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.phone_in_talk_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    numStr,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  color: Colors.white54,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );

    _isBottomSheetOpen = false;
    _modalDismissCooldownUntil = DateTime.now().millisecondsSinceEpoch + 1500;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dialer & Call Logging Engine
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _handleDetectedNumber(String phoneNumber, String source) async {
    final String sanitized = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    final String digitsOnly = sanitized.replaceAll('+', '');

    if (digitsOnly.length < 10 || digitsOnly.length > 15) return;

    // Async non-blocking SQLite call log
    Future.microtask(() => DatabaseHelper.logCall(sanitized, source));

    try {
      final PermissionStatus phonePermStatus = await Permission.phone.status;
      if (phonePermStatus.isDenied) {
        await Permission.phone.request();
      }
    } catch (e) {
      debugPrint('[PERMISSION] Phone permission request exception: $e');
    }

    await _openDialer(sanitized);
  }

  Future<void> _openDialer(String sanitized) async {
    final Uri telUri = Uri.parse('tel:$sanitized');

    bool canLaunch = false;
    try {
      canLaunch = await canLaunchUrl(telUri);
    } catch (e) {
      debugPrint('[DIALER] canLaunchUrl check failed: $e');
    }

    if (!canLaunch) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No dialer app found for $sanitized'),
          backgroundColor: Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    try {
      if (await launchUrl(telUri,
          mode: LaunchMode.externalNonBrowserApplication)) {
        return;
      }
    } catch (e) {
      debugPrint('[DIALER] Primary launch mode failed: $e');
    }

    try {
      if (await launchUrl(telUri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (e) {
      debugPrint('[DIALER] Fallback launch mode failed: $e');
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open dialer for $sanitized'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );

      if (pickedFile == null) return;

      final inputImage = InputImage.fromFilePath(pickedFile.path);
      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      final String? foundPhoneNumber =
          _extractPhoneNumber(recognizedText.text);

      if (foundPhoneNumber != null && foundPhoneNumber.isNotEmpty) {
        HapticFeedback.heavyImpact();
        setState(() {
          _detectedPhoneNumber = foundPhoneNumber;
        });
        await _handleDetectedNumber(foundPhoneNumber, 'gallery');
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.white),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No valid phone number detected in image',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
      debugPrint('[GALLERY ERROR] Exception: $e');
    }
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    try {
      if (_isFlashOn) {
        await _cameraController!.setFlashMode(FlashMode.off);
      } else {
        await _cameraController!.setFlashMode(FlashMode.torch);
      }
      setState(() {
        _isFlashOn = !_isFlashOn;
      });
    } catch (e) {
      debugPrint('[FLASH ERROR] Exception: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bool hasDetectedNumber = _detectedPhoneNumber != null;

    // ENHANCEMENT 3: Compute viewfinder ROI in screen coordinates during build
    final double roiWidth = size.width * 0.85;
    const double roiHeight = 170.0;
    final double roiLeft = (size.width - roiWidth) / 2;
    final double roiTop = (size.height - roiHeight) / 2;
    _viewfinderRoi = Rect.fromLTWH(roiLeft, roiTop, roiWidth, roiHeight);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── 1. Live Camera Preview ────────────────────────────────────────
          if (_isCameraInitialized && _cameraController != null)
            SizedBox.expand(
              child: CameraPreview(_cameraController!),
            )
          else
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF6366F1)),
                  SizedBox(height: 16),
                  Text(
                    'Initializing High-Speed Camera...',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),

          // ── 2. Semi-Transparent Dimming Mask (Outside Viewfinder) ────────
          if (_isCameraInitialized)
            _buildRoiMask(size, roiLeft, roiTop, roiWidth, roiHeight),

          // ── 3. Green Viewfinder Target Overlay ───────────────────────────
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: roiWidth,
              height: hasDetectedNumber ? 200 : 160,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: hasDetectedNumber
                      ? Colors.greenAccent
                      : const Color(0xFF6366F1),
                  width: 3.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (hasDetectedNumber
                            ? Colors.greenAccent
                            : const Color(0xFF6366F1))
                        .withValues(alpha: 0.35),
                    blurRadius: 24,
                    spreadRadius: 3,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hasDetectedNumber
                              ? Colors.greenAccent
                              : const Color(0xFF6366F1),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        hasDetectedNumber
                            ? 'NUMBER VERIFIED ✓'
                            : 'ALIGN PHONE NUMBER HERE',
                        style: TextStyle(
                          color: hasDetectedNumber
                              ? Colors.greenAccent
                              : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                  if (hasDetectedNumber)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.greenAccent.withValues(alpha: 0.5),
                          width: 1.0,
                        ),
                      ),
                      child: Text(
                        _detectedPhoneNumber!,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                    )
                  else
                    const Text(
                      'Point camera at any phone number',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 13,
                      ),
                    ),
                  if (hasDetectedNumber)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _handleDetectedNumber(
                          _detectedPhoneNumber!,
                          'dialer',
                        ),
                        icon: const Icon(
                          Icons.phone_in_talk_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        label: Text(
                          'Call $_detectedPhoneNumber',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade600,
                          foregroundColor: Colors.white,
                          elevation: 6,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 8),
                ],
              ),
            ),
          ),

          // ── 4. Top Telemetry Header & Flash Toggle ────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.center_focus_strong_rounded,
                          color: Color(0xFF6366F1),
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Scan to Call',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.6),
                    ),
                    onPressed: _toggleFlash,
                    icon: Icon(
                      _isFlashOn ? Icons.flash_on : Icons.flash_off,
                      color: _isFlashOn ? Colors.yellowAccent : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── 5. Bottom Gallery Control ─────────────────────────────────────
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickFromGallery,
                      icon: const Icon(Icons.photo_library_rounded),
                      label: const Text('Upload from Gallery'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.black.withValues(alpha: 0.75),
                        side: const BorderSide(
                          color: Colors.white54,
                          width: 1.5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper widget for drawing dimming overlay mask
  Widget _buildRoiMask(
      Size size, double roiLeft, double roiTop, double roiWidth, double roiHeight) {
    return CustomPaint(
      size: size,
      painter: _RoiMaskPainter(
        roiRect: Rect.fromLTWH(roiLeft, roiTop, roiWidth, roiHeight),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ROI Mask CustomPainter — Darkens non-scanning area
// ═══════════════════════════════════════════════════════════════════════════════
class _RoiMaskPainter extends CustomPainter {
  final Rect roiRect;
  const _RoiMaskPainter({required this.roiRect});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = Colors.black.withValues(alpha: 0.48);

    final Path path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(
        RRect.fromRectAndRadius(roiRect, const Radius.circular(24)),
      );
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _RoiMaskPainter old) => old.roiRect != roiRect;
}
