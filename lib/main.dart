import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'firebase_options.dart';

// ---------------------------------------------------------------------------
// DatabaseHelper — Offline SQLite call log
// ---------------------------------------------------------------------------
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

List<CameraDescription> _cameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint("Firebase initialized successfully.");
  } catch (e) {
    debugPrint("Firebase initialization info/error: $e");
  }

  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint("Failed to get available cameras: $e");
  }

  runApp(const PhoneExtractorApp());
}

class PhoneExtractorApp extends StatelessWidget {
  const PhoneExtractorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Google Lens Style Live Scanner',
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

class LiveCameraScannerScreen extends StatefulWidget {
  const LiveCameraScannerScreen({super.key});

  @override
  State<LiveCameraScannerScreen> createState() =>
      _LiveCameraScannerScreenState();
}

class _LiveCameraScannerScreenState extends State<LiveCameraScannerScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final int _selectedCameraIndex = 0;
  bool _isCameraInitialized = false;

  bool _isProcessingFrame = false;
  int _lastFrameProcessedTimestamp = 0;
  String? _detectedPhoneNumber;
  bool _isFlashOn = false;

  final ImagePicker _imagePicker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

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
    final CameraController? cameraController = _cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _stopCameraStream();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(cameraController.description);
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

  /// Initialize Camera Controller and start continuous live stream
  Future<void> _initCamera(CameraDescription cameraDescription) async {
    final CameraController cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    _cameraController = cameraController;

    try {
      await cameraController.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });

      _startCameraStream();
    } catch (e) {
      debugPrint("Camera initialization error: $e");
    }
  }

  /// Starts continuous stream processing for dynamic real-time tracking
  void _startCameraStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (_cameraController!.value.isStreamingImages) return;

    _cameraController!.startImageStream((CameraImage image) {
      _processCameraFrame(image);
    });
  }

  /// Stops camera image stream safely
  Future<void> _stopCameraStream() async {
    if (_cameraController != null &&
        _cameraController!.value.isInitialized &&
        _cameraController!.value.isStreamingImages) {
      try {
        await _cameraController!.stopImageStream();
      } catch (e) {
        debugPrint("Error stopping image stream: $e");
      }
    }
  }

  /// Convert CameraImage frame to InputImage for Google ML Kit
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

  /// Dynamic Real-Time Frame Processing (Face-Detection Style) with 300ms throttling
  Future<void> _processCameraFrame(CameraImage image) async {
    if (_cameraController == null) return;

    final int now = DateTime.now().millisecondsSinceEpoch;
    // Process 1 frame every 300ms to maintain smooth 60 FPS performance without lag
    if (now - _lastFrameProcessedTimestamp < 300) {
      return;
    }

    if (_isProcessingFrame) return;
    _isProcessingFrame = true;
    _lastFrameProcessedTimestamp = now;

    try {
      final inputImage = _inputImageFromCameraImage(
        image,
        _cameraController!.description,
      );

      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      final String? foundPhoneNumber = _extractPhoneNumber(recognizedText.text);

      if (!mounted) return;

      if (foundPhoneNumber != null && foundPhoneNumber.isNotEmpty) {
        // Number detected in current frame -> Update state & highlight green
        if (_detectedPhoneNumber != foundPhoneNumber) {
          HapticFeedback.selectionClick();
          debugPrint("REALTIME TRACKING: Phone number detected '$foundPhoneNumber'");
        }

        setState(() {
          _detectedPhoneNumber = foundPhoneNumber;
        });
      } else {
        // Camera moved away / NO number in current frame -> Clear state immediately
        if (_detectedPhoneNumber != null) {
          debugPrint("REALTIME TRACKING: Number left camera view -> clearing frame");
          setState(() {
            _detectedPhoneNumber = null;
          });
        }
      }
    } catch (e) {
      debugPrint("Error processing camera frame: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  /// Robust Phone Number Parser:
  /// Prevents truncation (e.g., +91 9876543210 -> +919876543210 intact, not 543210).
  /// Preserves country codes (+91), leading 0s, and complete 10-digit Indian numbers [6-9]XXXXX.
  String? _extractPhoneNumber(String text) {
    if (text.isEmpty) return null;

    // 1. Split into lines to evaluate individual line entries
    final List<String> rawLines = text.split(RegExp(r'[\r\n]+'));

    // Regex for International format starting with '+'
    // Matches '+' followed by digits, spaces, hyphens, parentheses, or dots
    final RegExp intlPattern = RegExp(r'\+\d[\d\s\-\.\(\)]{8,20}');

    // Regex for 11-digit zero-leading numbers starting with 0 then [6-9]
    final RegExp zeroIndianPattern = RegExp(r'(?<!\d)0[\s\.-]?[6-9]\d{4}[\s\.-]?\d{5}(?!\d)');

    // Regex for 10-digit Indian numbers starting with [6-9]
    final RegExp indianPattern = RegExp(r'(?<!\d)[6-9]\d{4}[\s\.-]?\d{5}(?!\d)');

    // Regex for generic contiguous or spaced digit sequences (10-15 digits)
    final RegExp genericPattern = RegExp(r'(?<!\d)\+?\d[\d\s\-\.]{8,20}\d(?!\d)');

    for (final line in rawLines) {
      final String trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      // Check 1: International format starting with '+' e.g. +91 98765 43210 or +91-9876543210
      for (final Match m in intlPattern.allMatches(trimmedLine)) {
        final String rawMatch = m.group(0)!;
        final String clean = rawMatch.replaceAll(RegExp(r'[^\d+]'), '');
        final String digitsOnly = clean.replaceAll(RegExp(r'[^\d]'), '');
        if (digitsOnly.length >= 10 && digitsOnly.length <= 15 && clean.startsWith('+')) {
          return clean;
        }
      }

      // Check 2: Zero-leading Indian numbers e.g. 09876543210 or 0 98765 43210
      for (final Match m in zeroIndianPattern.allMatches(trimmedLine)) {
        final String rawMatch = m.group(0)!;
        final String clean = rawMatch.replaceAll(RegExp(r'[^\d]'), '');
        if (clean.length == 11 && clean.startsWith('0')) {
          return clean;
        }
      }

      // Check 3: Standard 10-digit Indian numbers starting with [6-9]
      for (final Match m in indianPattern.allMatches(trimmedLine)) {
        final String rawMatch = m.group(0)!;
        final String clean = rawMatch.replaceAll(RegExp(r'[^\d]'), '');
        if (clean.length == 10 && RegExp(r'^[6-9]').hasMatch(clean)) {
          return clean;
        }
      }

      // Check 4: Generic pattern within the line
      for (final Match m in genericPattern.allMatches(trimmedLine)) {
        final String rawMatch = m.group(0)!;
        final String clean = rawMatch.replaceAll(RegExp(r'[^\d+]'), '');
        final String digitsOnly = clean.replaceAll(RegExp(r'[^\d]'), '');
        if (digitsOnly.length >= 10 && digitsOnly.length <= 15) {
          return clean;
        }
      }
    }

    // 2. Global Fallback across whole text (handles multi-line splits from ML Kit)
    final String sanitized = text.replaceAll(RegExp(r'[^\d+\s\-]'), ' ');

    // Check for + international format globally
    for (final Match m in intlPattern.allMatches(sanitized)) {
      final String rawMatch = m.group(0)!;
      final String clean = rawMatch.replaceAll(RegExp(r'[^\d+]'), '');
      final String digitsOnly = clean.replaceAll(RegExp(r'[^\d]'), '');
      if (digitsOnly.length >= 10 && digitsOnly.length <= 15 && clean.startsWith('+')) {
        return clean;
      }
    }

    // Global digits-only extraction
    final String allDigits = text.replaceAll(RegExp(r'[^\d]'), '');

    // 11-digit starting with 0 and [6-9]
    final Match? zeroMatch = RegExp(r'0[6-9]\d{9}').firstMatch(allDigits);
    if (zeroMatch != null) {
      return zeroMatch.group(0);
    }

    // 10-digit starting with [6-9]
    final Match? indianMatch = RegExp(r'[6-9]\d{9}').firstMatch(allDigits);
    if (indianMatch != null) {
      return indianMatch.group(0);
    }

    // 10-15 digit fallback sequence
    if (allDigits.length >= 10 && allDigits.length <= 15) {
      return allDigits;
    }

    return null;
  }

  /// Full robust Call Button handler:
  /// 1. Saves to Firestore (non-blocking on failure)
  /// 2. Checks CALL_PHONE permission safely
  /// 3. Non-blocking SQLite offline log via Future.microtask
  /// 4. Launches native dialer with exhaustive debugPrint tracing
  Future<void> _handleDetectedNumber(String phoneNumber, String source) async {
    debugPrint('======================================================');
    debugPrint('[CALL FLOW] START — number: $phoneNumber | source: $source');
    debugPrint('======================================================');

    // ── STEP 1: Sanitize immediately ──────────────────────────────────────────
    final String sanitized = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    final String digitsOnly = sanitized.replaceAll('+', '');
    debugPrint('[CALL FLOW] Step 1 — Sanitized: "$sanitized" | Digits: ${digitsOnly.length}');

    if (digitsOnly.length < 10 || digitsOnly.length > 15) {
      debugPrint('[CALL FLOW] ABORT — Invalid digit count: ${digitsOnly.length}');
      return;
    }

    // ── STEP 2: Non-blocking Firestore write (never blocks dialer) ────────────
    Future.microtask(() async {
      debugPrint('[FIRESTORE] Writing to scanned_numbers...');
      try {
        final DocumentReference docRef = await FirebaseFirestore.instance
            .collection('scanned_numbers')
            .add({
          'phoneNumber': sanitized,
          'createdAt': FieldValue.serverTimestamp(),
          'source': source,
        });
        debugPrint('[FIRESTORE] SUCCESS — Doc ID: ${docRef.id}');
      } catch (e) {
        debugPrint('[FIRESTORE] ERROR (non-fatal): $e');
      }
    });

    // ── STEP 3: Non-blocking SQLite offline log (DatabaseHelper) ─────────────
    // Wrapped in Future.microtask so DB errors NEVER block or crash the dialer.
    Future.microtask(() => DatabaseHelper.logCall(sanitized, source));

    // ── STEP 4: Permission check for CALL_PHONE ───────────────────────────────
    // NOTE: Opening the dialer pad (tel:) does NOT require CALL_PHONE permission.
    // Only android.intent.action.CALL (direct call without user prompt) needs it.
    // We check it anyway; on denial we still proceed to open the dialer pad safely.
    debugPrint('[CALL FLOW] Step 4 — Checking Permission.phone...');
    PermissionStatus phonePermStatus;
    try {
      phonePermStatus = await Permission.phone.status;
      debugPrint('[PERMISSION] Current status: $phonePermStatus');

      if (phonePermStatus.isDenied) {
        phonePermStatus = await Permission.phone.request();
        debugPrint('[PERMISSION] After request: $phonePermStatus');
      }

      if (phonePermStatus.isPermanentlyDenied) {
        debugPrint('[PERMISSION] Permanently denied — opening app settings nudge');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Phone permission denied. Opening dialer pad instead.',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              backgroundColor: Colors.orange.shade800,
              action: const SnackBarAction(
                label: 'Settings',
                textColor: Colors.white,
                onPressed: openAppSettings,
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        // Fallback: still open dialer pad (tel: only shows pad, no CALL_PHONE needed)
      }
    } catch (e) {
      // permission_handler can throw on desktop/unsupported — treat as granted, proceed
      debugPrint('[PERMISSION] Exception (non-fatal, proceeding): $e');
    }

    // ── STEP 5: Launch native dialer ──────────────────────────────────────────
    await _openDialer(sanitized);

    debugPrint('[CALL FLOW] END — dialer launch attempted for $sanitized');
    debugPrint('======================================================');
  }

  /// Launch native dialer via url_launcher.
  /// Expects an already-sanitized number (digits + optional leading '+').
  /// Step-by-step debugPrint tracing at every decision point.
  Future<void> _openDialer(String sanitized) async {
    debugPrint('[DIALER] Step A — Input: "$sanitized"');

    // A. Build URI
    final Uri telUri = Uri.parse('tel:$sanitized');
    debugPrint('[DIALER] Step B — URI built: $telUri');

    // B. canLaunchUrl check
    bool canLaunch = false;
    try {
      canLaunch = await canLaunchUrl(telUri);
      debugPrint('[DIALER] Step C — canLaunchUrl: $canLaunch');
    } catch (e) {
      debugPrint('[DIALER] Step C — canLaunchUrl EXCEPTION: $e');
    }

    if (!canLaunch) {
      debugPrint('[DIALER] ABORT — No app can handle tel: scheme on this device');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No dialer app found for $sanitized'),
          backgroundColor: Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    // C. Attempt primary launch: externalNonBrowserApplication
    debugPrint('[DIALER] Step D — Attempting launchUrl (externalNonBrowserApplication)...');
    try {
      final bool launched = await launchUrl(
        telUri,
        mode: LaunchMode.externalNonBrowserApplication,
      );
      debugPrint('[DIALER] Step D — launchUrl returned: $launched');
      if (launched) {
        debugPrint('[DIALER] SUCCESS ✓ — Native dialer opened for $sanitized');
        return;
      }
    } catch (e) {
      debugPrint('[DIALER] Step D — EXCEPTION: $e — trying fallback mode...');
    }

    // D. Fallback: externalApplication mode
    debugPrint('[DIALER] Step E — Fallback: launchUrl (externalApplication)...');
    try {
      final bool launched = await launchUrl(
        telUri,
        mode: LaunchMode.externalApplication,
      );
      debugPrint('[DIALER] Step E — Fallback returned: $launched');
      if (launched) {
        debugPrint('[DIALER] SUCCESS (fallback) ✓ — Dialer opened for $sanitized');
        return;
      }
    } catch (e) {
      debugPrint('[DIALER] Step E — Fallback EXCEPTION: $e');
    }

    // E. Both modes failed — show SnackBar
    debugPrint('[DIALER] FAILED — Both launch modes returned false/threw for $sanitized');
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

  /// Fallback Upload from Gallery using ImagePicker
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

      final String? foundPhoneNumber = _extractPhoneNumber(recognizedText.text);

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
                    'No phone number detected in the image',
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
      debugPrint("Gallery processing error: $e");
    }
  }

  /// Toggle flashlight
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
      debugPrint("Error toggling flash: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bool hasDetectedNumber = _detectedPhoneNumber != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Continuous Live Camera Preview
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
                    'Initializing Live Camera...',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),

          // 2. Real-Time Dynamic Tracking Bounding Box Overlay (Face-Detection Style)
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: size.width * 0.85,
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
                  // Top Tracking Status Indicator
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
                            ? 'NUMBER TRACKED'
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

                  // Middle Detected Phone Number Display
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

                  // Interactive "Call <number>" Action Button
                  if (hasDetectedNumber)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _handleDetectedNumber(
                          _detectedPhoneNumber!,
                          'live_camera',
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

          // 3. Top Control Bar (Flashlight & Header)
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
                          'Real-Time Lens Scanner',
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

          // 4. Bottom Control Bar (Upload from Gallery)
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
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
                      backgroundColor: Colors.black.withValues(alpha: 0.6),
                      side: const BorderSide(
                        color: Colors.white38,
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
        ],
      ),
    );
  }
}
