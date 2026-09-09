import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Firebase initialization info: $e");
  }
  runApp(const PhoneExtractorApp());
}

class PhoneExtractorApp extends StatelessWidget {
  const PhoneExtractorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phone Scanner AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
      ),
      home: const PhoneScannerScreen(),
    );
  }
}

class PhoneScannerScreen extends StatefulWidget {
  const PhoneScannerScreen({super.key});

  @override
  State<PhoneScannerScreen> createState() => _PhoneScannerScreenState();
}

class _PhoneScannerScreenState extends State<PhoneScannerScreen> {
  File? _selectedImage;
  bool _isProcessing = false;
  String? _detectedPhoneNumber;

  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  @override
  void dispose() {
    _textRecognizer.close();
    super.dispose();
  }

  /// Smart Regex to extract phone numbers while completely ignoring surrounding alphabetic text.
  /// Strictly returns ONLY the FIRST valid phone number match (7 to 15 digits).
  String? _extractPhoneNumber(String text) {
    final RegExp phoneRegex = RegExp(
      r'(?<![a-zA-Z0-9])(?:(?:\+|00)\d{1,4}[\s.-]?)?(?:\(?\d{2,5}\)?[\s.-]?)?\d{3,4}[\s.-]?\d{3,4}(?![a-zA-Z0-9])',
    );

    final Iterable<RegExpMatch> matches = phoneRegex.allMatches(text);

    for (final match in matches) {
      final rawMatch = match.group(0);
      if (rawMatch != null) {
        // Strip non-digit and non-plus characters
        final cleanNumber = rawMatch.replaceAll(RegExp(r'[^\d+]'), '');
        final digitCount = cleanNumber.replaceAll(RegExp(r'[^\d]'), '').length;

        // Valid phone number length according to ITU E.164 (7 to 15 digits)
        if (digitCount >= 7 && digitCount <= 15) {
          // Strictly select ONLY the first valid match
          return cleanNumber;
        }
      }
    }
    return null;
  }

  /// Save detected phone number details into Cloud Firestore 'scanned_numbers' collection
  Future<void> _saveToFirestore({
    required String phoneNumber,
    required String source,
  }) async {
    await FirebaseFirestore.instance.collection('scanned_numbers').add({
      'phoneNumber': phoneNumber,
      'createdAt': FieldValue.serverTimestamp(),
      'source': source,
    });
  }

  /// Pick image, perform OCR, save to Firestore, and open dialer
  Future<void> _pickAndProcessImage(ImageSource source) async {
    final String sourceName = source == ImageSource.camera ? 'camera' : 'gallery';

    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );

      if (pickedFile == null) return;

      setState(() {
        _selectedImage = File(pickedFile.path);
        _isProcessing = true;
        _detectedPhoneNumber = null;
      });

      // Step 1: Perform OCR using Google ML Kit
      final inputImage = InputImage.fromFilePath(pickedFile.path);
      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      // Step 2: Extract strictly the FIRST valid phone number
      final String? foundPhoneNumber = _extractPhoneNumber(recognizedText.text);

      if (foundPhoneNumber == null || foundPhoneNumber.isEmpty) {
        setState(() {
          _isProcessing = false;
        });

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
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      // Step 3: Save to Cloud Firestore
      try {
        await _saveToFirestore(
          phoneNumber: foundPhoneNumber,
          source: sourceName,
        );
      } catch (firestoreError) {
        debugPrint("Firestore write error: $firestoreError");
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save to Firestore: $firestoreError'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      setState(() {
        _isProcessing = false;
        _detectedPhoneNumber = foundPhoneNumber;
      });

      if (!mounted) return;

      // Step 4: Launch native phone dialer automatically
      _openDialer(foundPhoneNumber);
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error processing image: $e'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Launch native phone dialer pre-filled with the extracted number
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Phone Scanner AI',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Image Preview Area
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: colorScheme.outline.withOpacity(0.2),
                      width: 1.5,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_selectedImage != null)
                        Image.file(
                          _selectedImage!,
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                        )
                      else
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.center_focus_weak_rounded,
                              size: 72,
                              color: colorScheme.primary.withOpacity(0.5),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Select an image to scan for phone numbers',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),

                      // Loading Overlay during ML Kit OCR & Firestore Upload
                      if (_isProcessing)
                        Container(
                          color: Colors.black.withOpacity(0.6),
                          child: Center(
                            child: Card(
                              elevation: 8,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24.0,
                                  vertical: 20.0,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(
                                      color: colorScheme.primary,
                                    ),
                                    const SizedBox(height: 16),
                                    const Text(
                                      'Processing image and saving to database...',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Detected Number Banner
              if (_detectedPhoneNumber != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.phone_in_talk_rounded,
                        color: colorScheme.onPrimaryContainer,
                        size: 28,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Scanned & Saved Number',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colorScheme.onPrimaryContainer
                                    .withOpacity(0.8),
                              ),
                            ),
                            Text(
                              _detectedPhoneNumber!,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: () => _openDialer(_detectedPhoneNumber!),
                        icon: const Icon(Icons.call),
                        tooltip: 'Open Dialer',
                      ),
                    ],
                  ),
                ),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isProcessing
                          ? null
                          : () => _pickAndProcessImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_rounded),
                      label: const Text('Scan via Camera'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isProcessing
                          ? null
                          : () => _pickAndProcessImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_rounded),
                      label: const Text('Upload Gallery'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        foregroundColor: colorScheme.primary,
                        side: BorderSide(color: colorScheme.primary, width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
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
      ),
    );
  }
}
