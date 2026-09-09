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
  } catch (e) {
    debugPrint("Firebase initialization info: $e");
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
        // Lock stream immediately upon valid detection to prevent duplicate triggers
        _isLocked = true;
        await _stopCameraStream();

        // Haptic feedback for Google Lens effect
        HapticFeedback.mediumImpact();

        setState(() {
          _detectedPhoneNumber = foundPhoneNumber;
        });

        // Save to Firestore and launch dialer
        await _handleDetectedNumber(foundPhoneNumber, 'live_camera');
      }
    } catch (e) {
      debugPrint("Error processing camera frame: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  /// Smart Regex to prioritize phone numbers (7 to 15 digits), ignoring surrounding letters
  String? _extractPhoneNumber(String text) {
    final RegExp phoneRegex = RegExp(
      r'(?<![a-zA-Z0-9])(?:(?:\+|00)\d{1,4}[\s.-]?)?(?:\(?\d{2,5}\)?[\s.-]?)?\d{3,4}[\s.-]?\d{3,4}(?![a-zA-Z0-9])',
    );

    final Iterable<RegExpMatch> matches = phoneRegex.allMatches(text);

    for (final match in matches) {
      final rawMatch = match.group(0);
      if (rawMatch != null) {
        final cleanNumber = rawMatch.replaceAll(RegExp(r'[^\d+]'), '');
        final digitCount = cleanNumber.replaceAll(RegExp(r'[^\d]'), '').length;

        if (digitCount >= 7 && digitCount <= 15) {
          return cleanNumber;
        }
      }
    }
    return null;
  }

  /// Save to Firestore & automatically trigger phone dialer
  Future<void> _handleDetectedNumber(String phoneNumber, String source) async {
    try {
      await FirebaseFirestore.instance.collection('scanned_numbers').add({
        'phoneNumber': phoneNumber,
        'createdAt': FieldValue.serverTimestamp(),
        'source': source,
      });
    } catch (e) {
      debugPrint("Firestore upload error: $e");
    }

    _openDialer(phoneNumber);
  }

  /// Open native dialer using url_launcher with tel: scheme
  Future<void> _openDialer(String phoneNumber) async {
    final Uri telUri = Uri(scheme: 'tel', path: phoneNumber);

    try {
      if (await canLaunchUrl(telUri)) {
        await launchUrl(telUri);
      } else {
        await launchUrl(telUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not launch dialer for $phoneNumber'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  /// Static photo selection fallback from Gallery using ImagePicker
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
                  // Corner accent indicators
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
                    // Fallback Upload from Gallery
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
