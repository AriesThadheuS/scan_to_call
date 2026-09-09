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

import 'firebase_options.dart';

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
  int _selectedCameraIndex = 0;
  bool _isCameraInitialized = false;

  bool _isProcessingFrame = false;
  bool _isLocked = false; // Lock flag to prevent duplicate scans
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

  /// Initialize Camera Controller and start live stream
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

  /// Starts processing live frames from camera stream
  void _startCameraStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (_cameraController!.value.isStreamingImages) return;

    _cameraController!.startImageStream((CameraImage image) {
      if (_isProcessingFrame || _isLocked) return;
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

  /// Process each camera frame instantaneously using ML Kit Text Recognition
  Future<void> _processCameraFrame(CameraImage image) async {
    if (_cameraController == null) return;
    _isProcessingFrame = true;

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

      if (foundPhoneNumber != null && foundPhoneNumber.isNotEmpty && !_isLocked) {
        _isLocked = true;
        await _stopCameraStream();

        HapticFeedback.mediumImpact();

        setState(() {
          _detectedPhoneNumber = foundPhoneNumber;
        });

        debugPrint("DETECTION SUCCESS: Found number '$foundPhoneNumber'");

        // Save to Firestore and launch dialer
        await _handleDetectedNumber(foundPhoneNumber, 'live_camera');
      }
    } catch (e) {
      debugPrint("Error processing camera frame: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  /// Robust Phone Number Parser:
  /// Prevents truncation (e.g., +91 9876543210 -> +919876543210 intact, not 543210).
  /// Preserves country codes (+91, +1), leading 0s, and complete 10-digit Indian numbers [6-9]XXXXX.
  String? _extractPhoneNumber(String text) {
    if (text.isEmpty) return null;

    final List<String> lines = text.split(RegExp(r'[\r\n]+'));

    // Pattern 1: International format with + country code e.g. +91 9876543210 or +91-98765-43210
    final RegExp intlRegex = RegExp(r'\+(?:[0-9][\s.-]?){8,15}\d');

    // Pattern 2: Indian 10-digit mobile number starting with [6-9] e.g. 98765 43210, 9876543210
    final RegExp indianRegex = RegExp(r'(?<!\d)[6-9]\d{4}[\s.-]?\d{5}(?!\d)');

    // Pattern 3: Zero-leading numbers e.g. 09876543210
    final RegExp zeroLeadingRegex = RegExp(r'(?<!\d)0[6-9]\d{4}[\s.-]?\d{5}(?!\d)');

    // Pattern 4: Fallback contiguous digit sequence (10 to 15 digits)
    final RegExp fallbackDigits = RegExp(r'(?<!\d)\+?\d{10,15}(?!\d)');

    for (final line in lines) {
      // 1. Check International Format (+91 9876543210)
      final Iterable<RegExpMatch> intlMatches = intlRegex.allMatches(line);
      for (final m in intlMatches) {
        final raw = m.group(0);
        if (raw != null) {
          final clean = raw.replaceAll(RegExp(r'[^\d+]'), '');
          final digitsOnly = clean.replaceAll(RegExp(r'[^\d]'), '');
          if (digitsOnly.length >= 10 && digitsOnly.length <= 15) {
            return clean;
          }
        }
      }

      // 2. Check Indian 10-Digit Mobile (9876543210)
      final Iterable<RegExpMatch> indianMatches = indianRegex.allMatches(line);
      for (final m in indianMatches) {
        final raw = m.group(0);
        if (raw != null) {
          final clean = raw.replaceAll(RegExp(r'[^\d+]'), '');
          final digitsOnly = clean.replaceAll(RegExp(r'[^\d]'), '');
          if (digitsOnly.length == 10) {
            return clean;
          }
        }
      }

      // 3. Check Zero Leading Mobile (09876543210)
      final Iterable<RegExpMatch> zeroMatches = zeroLeadingRegex.allMatches(line);
      for (final m in zeroMatches) {
        final raw = m.group(0);
        if (raw != null) {
          final clean = raw.replaceAll(RegExp(r'[^\d+]'), '');
          final digitsOnly = clean.replaceAll(RegExp(r'[^\d]'), '');
          if (digitsOnly.length == 11) {
            return clean;
          }
        }
      }

      // 4. Fallback 10-15 Digit Sequence
      final Iterable<RegExpMatch> fallbackMatches = fallbackDigits.allMatches(line);
      for (final m in fallbackMatches) {
        final raw = m.group(0);
        if (raw != null) {
          final clean = raw.replaceAll(RegExp(r'[^\d+]'), '');
          final digitsOnly = clean.replaceAll(RegExp(r'[^\d]'), '');
          if (digitsOnly.length >= 10 && digitsOnly.length <= 15) {
            return clean;
          }
        }
      }
    }

    // 5. Global sanitization fallback across un-split text blocks
    final String wholeClean = text.replaceAll(RegExp(r'[^\d+]'), '');
    final String wholeDigits = wholeClean.replaceAll(RegExp(r'[^\d]'), '');

    if (wholeDigits.length >= 10 && wholeDigits.length <= 15) {
      if (wholeClean.startsWith('+')) {
        return wholeClean;
      }
      final match10 = RegExp(r'[6-9]\d{9}').firstMatch(wholeDigits);
      if (match10 != null) {
        return match10.group(0);
      }
      return wholeDigits;
    }

    return null;
  }

  /// Save to Cloud Firestore with explicit debug logging & open native dialer
  Future<void> _handleDetectedNumber(String phoneNumber, String source) async {
    debugPrint("--------------------------------------------------");
    debugPrint("--> FIRESTORE WRITE INITIATED");
    debugPrint("    Target Collection: 'scanned_numbers'");
    debugPrint("    Document Field 'phoneNumber': $phoneNumber");
    debugPrint("    Document Field 'source': $source");
    debugPrint("--------------------------------------------------");

    try {
      final DocumentReference docRef =
          await FirebaseFirestore.instance.collection('scanned_numbers').add({
        'phoneNumber': phoneNumber,
        'createdAt': FieldValue.serverTimestamp(),
        'source': source,
      });

      debugPrint("--> FIRESTORE SUCCESS: Written Document ID '${docRef.id}'");
    } catch (e, stackTrace) {
      debugPrint("--> FIRESTORE ERROR: Failed to write document to Firestore: $e");
      debugPrint("    StackTrace: $stackTrace");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Firestore error: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }

    // Launch dialer with cleaned number
    _openDialer(phoneNumber);
  }

  /// Launch native dialer via url_launcher with LaunchMode.externalApplication
  Future<void> _openDialer(String phoneNumber) async {
    final String cleanDigits = phoneNumber.replaceAll(RegExp(r'[^\d]'), '');

    if (cleanDigits.length < 10 || cleanDigits.length > 15) {
      debugPrint("Dialer launch skipped: Invalid digit count (${cleanDigits.length}) for number '$phoneNumber'");
      return;
    }

    final Uri telUri = Uri(scheme: 'tel', path: phoneNumber);
    debugPrint("--> LAUNCHING DIALER: $telUri (mode: LaunchMode.externalApplication)");

    try {
      final bool launched = await launchUrl(
        telUri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        debugPrint("launchUrl returned false for $telUri");
      }
    } catch (e) {
      debugPrint("Error launching dialer for $phoneNumber: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not launch dialer for $phoneNumber'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
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

      setState(() {
        _isLocked = true;
      });
      await _stopCameraStream();

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
        setState(() {
          _isLocked = false;
        });
        _startCameraStream();

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

  /// Reset scanner lock to allow continuous scanning again
  void _resetScanner() {
    setState(() {
      _isLocked = false;
      _detectedPhoneNumber = null;
    });
    _startCameraStream();
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Live Camera Preview
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

          // 2. Google Lens Style Bounding Box Overlay
          Center(
            child: Container(
              width: size.width * 0.85,
              height: 160,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _detectedPhoneNumber != null
                      ? Colors.greenAccent
                      : const Color(0xFF6366F1),
                  width: 3.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (_detectedPhoneNumber != null
                            ? Colors.greenAccent
                            : const Color(0xFF6366F1))
                        .withOpacity(0.3),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Positioned(
                    top: 12,
                    left: 16,
                    child: Text(
                      _detectedPhoneNumber != null
                          ? 'NUMBER DETECTED'
                          : 'ALIGN PHONE NUMBER HERE',
                      style: TextStyle(
                        color: _detectedPhoneNumber != null
                            ? Colors.greenAccent
                            : Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  if (_detectedPhoneNumber != null)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.85),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _detectedPhoneNumber!,
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
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
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.camera_alt_rounded,
                          color: Color(0xFF6366F1),
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Google Lens AI Scanner',
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
                      backgroundColor: Colors.black.withOpacity(0.6),
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

          // 4. Bottom Control Bar (Gallery Fallback & Rescan Button)
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isLocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: ElevatedButton.icon(
                      onPressed: _resetScanner,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Scan Another Number'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),

                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickFromGallery,
                        icon: const Icon(Icons.photo_library_rounded),
                        label: const Text('Upload from Gallery'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.black.withOpacity(0.6),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
