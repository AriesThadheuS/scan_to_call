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
// UPGRADE 3: CountryInfo & Universal Worldwide Country & Line Type Detector
// ═══════════════════════════════════════════════════════════════════════════════
class CountryInfo {
  final String isoCode;
  final String flagEmoji;
  final String countryName;
  final String lineType; // 'Mobile', 'Landline', 'International'
  final String rawNumber;
  final String dialableNumber;
  final String formattedNumber;

  CountryInfo({
    required this.isoCode,
    required this.flagEmoji,
    required this.countryName,
    required this.lineType,
    required this.rawNumber,
    required this.dialableNumber,
    required this.formattedNumber,
  });

  String get displayTag => '$countryName • $lineType';
  String get fullDisplayText => '$flagEmoji $formattedNumber ($displayTag)';
}

class CountryHelper {
  /// Converts a 2-letter ISO country code into a dynamic Unicode Flag Emoji
  static String countryCodeToEmoji(String countryCode) {
    final String code = countryCode.toUpperCase();
    if (code.length != 2) return '🌐';
    final int first = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final int second = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(first) + String.fromCharCode(second);
  }

  /// ITU Calling Code Table mapping international prefixes to ISO codes & names
  static final Map<String, Map<String, String>> _ituPrefixes = {
    '+1': {'iso': 'US', 'name': 'USA / Canada'},
    '+7': {'iso': 'RU', 'name': 'Russia'},
    '+20': {'iso': 'EG', 'name': 'Egypt'},
    '+27': {'iso': 'ZA', 'name': 'South Africa'},
    '+30': {'iso': 'GR', 'name': 'Greece'},
    '+31': {'iso': 'NL', 'name': 'Netherlands'},
    '+32': {'iso': 'BE', 'name': 'Belgium'},
    '+33': {'iso': 'FR', 'name': 'France'},
    '+34': {'iso': 'ES', 'name': 'Spain'},
    '+36': {'iso': 'HU', 'name': 'Hungary'},
    '+39': {'iso': 'IT', 'name': 'Italy'},
    '+40': {'iso': 'RO', 'name': 'Romania'},
    '+41': {'iso': 'CH', 'name': 'Switzerland'},
    '+43': {'iso': 'AT', 'name': 'Austria'},
    '+44': {'iso': 'GB', 'name': 'United Kingdom'},
    '+45': {'iso': 'DK', 'name': 'Denmark'},
    '+46': {'iso': 'SE', 'name': 'Sweden'},
    '+47': {'iso': 'NO', 'name': 'Norway'},
    '+48': {'iso': 'PL', 'name': 'Poland'},
    '+49': {'iso': 'DE', 'name': 'Germany'},
    '+51': {'iso': 'PE', 'name': 'Peru'},
    '+52': {'iso': 'MX', 'name': 'Mexico'},
    '+53': {'iso': 'CU', 'name': 'Cuba'},
    '+54': {'iso': 'AR', 'name': 'Argentina'},
    '+55': {'iso': 'BR', 'name': 'Brazil'},
    '+56': {'iso': 'CL', 'name': 'Chile'},
    '+57': {'iso': 'CO', 'name': 'Colombia'},
    '+58': {'iso': 'VE', 'name': 'Venezuela'},
    '+60': {'iso': 'MY', 'name': 'Malaysia'},
    '+61': {'iso': 'AU', 'name': 'Australia'},
    '+62': {'iso': 'ID', 'name': 'Indonesia'},
    '+63': {'iso': 'PH', 'name': 'Philippines'},
    '+64': {'iso': 'NZ', 'name': 'New Zealand'},
    '+65': {'iso': 'SG', 'name': 'Singapore'},
    '+66': {'iso': 'TH', 'name': 'Thailand'},
    '+81': {'iso': 'JP', 'name': 'Japan'},
    '+82': {'iso': 'KR', 'name': 'South Korea'},
    '+84': {'iso': 'VN', 'name': 'Vietnam'},
    '+86': {'iso': 'CN', 'name': 'China'},
    '+90': {'iso': 'TR', 'name': 'Turkey'},
    '+91': {'iso': 'IN', 'name': 'India'},
    '+92': {'iso': 'PK', 'name': 'Pakistan'},
    '+93': {'iso': 'AF', 'name': 'Afghanistan'},
    '+94': {'iso': 'LK', 'name': 'Sri Lanka'},
    '+95': {'iso': 'MM', 'name': 'Myanmar'},
    '+960': {'iso': 'MV', 'name': 'Maldives'},
    '+961': {'iso': 'LB', 'name': 'Lebanon'},
    '+962': {'iso': 'JO', 'name': 'Jordan'},
    '+963': {'iso': 'SY', 'name': 'Syria'},
    '+964': {'iso': 'IQ', 'name': 'Iraq'},
    '+965': {'iso': 'KW', 'name': 'Kuwait'},
    '+966': {'iso': 'SA', 'name': 'Saudi Arabia'},
    '+967': {'iso': 'YE', 'name': 'Yemen'},
    '+968': {'iso': 'OM', 'name': 'Oman'},
    '+971': {'iso': 'AE', 'name': 'United Arab Emirates'},
    '+972': {'iso': 'IL', 'name': 'Israel'},
    '+973': {'iso': 'BH', 'name': 'Bahrain'},
    '+974': {'iso': 'QA', 'name': 'Qatar'},
    '+975': {'iso': 'BT', 'name': 'Bhutan'},
    '+977': {'iso': 'NP', 'name': 'Nepal'},
    '+98': {'iso': 'IR', 'name': 'Iran'},
  };

  /// Indian STD prefixes for landline detection
  static final List<String> _indianStdPrefixes = [
    '011', '022', '033', '044', '080', '040', '079', '020',
    '0422', '0484', '0471', '0452', '0431', '0416', '0427', '0451', '0821'
  ];

  /// Parses a normalized dialable number into detailed CountryInfo metadata
  static CountryInfo parse(String rawNumber) {
    final String digitsOnly = rawNumber.replaceAll(RegExp(r'[^\d]'), '');
    final bool hasPlus = rawNumber.startsWith('+');

    String isoCode = 'UN';
    String countryName = 'Global';
    String flagEmoji = '🌐';
    String lineType = 'Mobile';
    String dialableNumber = hasPlus ? '+$digitsOnly' : digitsOnly;
    String formattedNumber = dialableNumber;

    // 1. Check International Prefix Match (longest prefix first)
    if (hasPlus) {
      final String withPlus = '+$digitsOnly';
      final List<String> sortedPrefixes = _ituPrefixes.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));

      for (final prefix in sortedPrefixes) {
        if (withPlus.startsWith(prefix)) {
          final data = _ituPrefixes[prefix]!;
          isoCode = data['iso']!;
          countryName = data['name']!;
          flagEmoji = countryCodeToEmoji(isoCode);

          final String subscriber = withPlus.substring(prefix.length);

          if (prefix == '+91') {
            // India Mobile vs Landline rules
            if (subscriber.length == 10 && RegExp(r'^[6-9]').hasMatch(subscriber)) {
              lineType = 'Mobile';
              formattedNumber = '+91 ${subscriber.substring(0, 5)} ${subscriber.substring(5)}';
            } else {
              lineType = 'Landline';
              formattedNumber = '+91 $subscriber';
            }
          } else {
            lineType = subscriber.startsWith('7') && isoCode == 'GB'
                ? 'Mobile'
                : 'International';
            formattedNumber = '$prefix $subscriber';
          }
          break;
        }
      }
    } else {
      // 2. Local / Trunk Zero Numbers
      if (digitsOnly.startsWith('0')) {
        // Indian Landline / Trunk Prefix (e.g. 044-23456789, 0422-234567)
        isoCode = 'IN';
        countryName = 'India';
        flagEmoji = countryCodeToEmoji('IN');
        lineType = 'Landline';

        // Format Indian landlines nicely
        String matchedStd = '';
        for (final std in _indianStdPrefixes) {
          if (digitsOnly.startsWith(std)) {
            matchedStd = std;
            break;
          }
        }
        if (matchedStd.isNotEmpty && digitsOnly.length > matchedStd.length) {
          formattedNumber =
              '$matchedStd-${digitsOnly.substring(matchedStd.length)}';
        } else {
          formattedNumber = digitsOnly;
        }
      } else if (digitsOnly.length == 10 && RegExp(r'^[6-9]').hasMatch(digitsOnly)) {
        // Indian 10-digit Mobile without prefix (e.g. 9876543210, 98765_43210)
        isoCode = 'IN';
        countryName = 'India';
        flagEmoji = countryCodeToEmoji('IN');
        lineType = 'Mobile';
        formattedNumber =
            '+91 ${digitsOnly.substring(0, 5)} ${digitsOnly.substring(5)}';
        dialableNumber = '+91$digitsOnly';
      } else {
        formattedNumber = digitsOnly;
      }
    }

    return CountryInfo(
      isoCode: isoCode,
      flagEmoji: flagEmoji,
      countryName: countryName,
      lineType: lineType,
      rawNumber: rawNumber,
      dialableNumber: dialableNumber,
      formattedNumber: formattedNumber,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Multi-Frame Rolling Consensus Voting Engine
// ═══════════════════════════════════════════════════════════════════════════════
class ConsensusVoter {
  final int bufferSize;
  final int minVotes;
  final List<Set<String>> _frameBuffer = [];

  ConsensusVoter({this.bufferSize = 3, this.minVotes = 2});

  Set<String> vote(Set<String> frameCandidates) {
    _frameBuffer.add(Set<String>.from(frameCandidates));
    if (_frameBuffer.length > bufferSize) {
      _frameBuffer.removeAt(0);
    }

    final Map<String, int> tally = {};
    for (final frame in _frameBuffer) {
      for (final candidate in frame) {
        tally[candidate] = (tally[candidate] ?? 0) + 1;
      }
    }

    return tally.entries
        .where((e) => e.value >= minVotes)
        .map((e) => e.key)
        .toSet();
  }

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
// LiveCameraScannerScreen — Main Scanner Widget
// ═══════════════════════════════════════════════════════════════════════════════
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
  bool _isFlashOn = false;

  bool _isProcessingFrame = false;
  int _lastFrameProcessedTimestamp = 0;

  // UPGRADE 4: CountryInfo object for detailed display state
  CountryInfo? _detectedCountryInfo;
  String? _lastAutoSavedNumber;

  final ConsensusVoter _consensusVoter =
      ConsensusVoter(bufferSize: 3, minVotes: 2);

  int _lastValidDetectionTimestamp = 0;
  static const int _stabilizationHoldMs = 700;

  bool _isBottomSheetOpen = false;
  int _modalDismissCooldownUntil = 0;

  Rect _viewfinderRoi = Rect.zero;

  final ImagePicker _imagePicker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

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

  static final RegExp _confusionPattern = RegExp(
    '[${_ocrConfusionMatrix.keys.map(RegExp.escape).join()}]',
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
    final CameraController? cc = _cameraController;
    if (cc == null || !cc.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _stopCameraStream();
    } else if (state == AppLifecycleState.resumed) {
      _consensusVoter.reset();
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

      try {
        await cameraController.setFocusMode(FocusMode.auto);
      } catch (e) {
        debugPrint('[CAMERA] Focus mode set exception: $e');
      }

      setState(() => _isCameraInitialized = true);
      _startCameraStream();
    } catch (e) {
      debugPrint('[CAMERA] Initialization error: $e');
    }
  }

  void _startCameraStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_cameraController!.value.isStreamingImages) return;

    _cameraController!.startImageStream(_processCameraFrame);
  }

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
  // High-Performance Frame Processing Pipeline
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _processCameraFrame(CameraImage image) async {
    if (_cameraController == null) return;

    final int now = DateTime.now().millisecondsSinceEpoch;

    if (_isBottomSheetOpen || now < _modalDismissCooldownUntil) return;

    // Throttle OCR to 250ms
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

      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      final Set<String> frameCandidates =
          _extractCandidatesWithROI(recognizedText, image);

      if (!mounted) return;

      final Set<String> confirmedCandidates =
          _consensusVoter.vote(frameCandidates);

      if (confirmedCandidates.length > 1) {
        // Multiple candidates -> parse info for each and show bottom sheet
        final List<CountryInfo> infoList =
            confirmedCandidates.map((n) => CountryHelper.parse(n)).toList();
        debugPrint(
            '[MULTI DETECT] Consensus found ${infoList.length} numbers');
        _showMultipleNumbersBottomSheet(infoList);
      } else if (confirmedCandidates.length == 1) {
        final String foundRaw = confirmedCandidates.first;
        final CountryInfo info = CountryHelper.parse(foundRaw);
        _lastValidDetectionTimestamp = now;

        if (_detectedCountryInfo?.dialableNumber != info.dialableNumber) {
          HapticFeedback.mediumImpact();
          debugPrint('[CONSENSUS LOCKED] Phone number verified: "${info.fullDisplayText}"');
        }

        if (info.dialableNumber != _lastAutoSavedNumber) {
          _lastAutoSavedNumber = info.dialableNumber;
          debugPrint('[CAMERA DETECT] Number logged: ${info.dialableNumber}');
        }

        setState(() {
          _detectedCountryInfo = info;
        });
      } else {
        if (_detectedCountryInfo != null &&
            (now - _lastValidDetectionTimestamp < _stabilizationHoldMs)) {
          // Hold last valid detection to eliminate flicker
        } else {
          if (_detectedCountryInfo != null || _lastAutoSavedNumber != null) {
            _lastAutoSavedNumber = null;
            setState(() {
              _detectedCountryInfo = null;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('[FRAME ERROR] Exception: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  String _sanitizeOcrText(String raw) {
    if (raw.isEmpty) return raw;
    return raw.splitMapJoin(
      _confusionPattern,
      onMatch: (m) => _ocrConfusionMatrix[m.group(0)!] ?? m.group(0)!,
      onNonMatch: (s) => s,
    );
  }

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

  bool _isInsideRoi(Rect elementRect, Rect roi, {double threshold = 0.80}) {
    if (roi == Rect.zero) return true;
    final Rect intersection = elementRect.intersect(roi);
    if (intersection.isEmpty) return false;
    final double elementArea = elementRect.width * elementRect.height;
    if (elementArea <= 0) return true;
    final double overlapArea = intersection.width * intersection.height;
    return (overlapArea / elementArea) >= threshold;
  }

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
            continue;
          }
        }

        final String sanitizedLine = _sanitizeOcrText(line.text);
        final Set<String> lineNumbers =
            _extractUniversalPhoneNumbers(sanitizedLine);
        results.addAll(lineNumbers);
      }
    }

    return results;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UPGRADE 1 & 2: Delimited Normalization & Postal PIN Code Rejection
  // ─────────────────────────────────────────────────────────────────────────
  static final RegExp _datePattern = RegExp(
      r'\b(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{4})\b');
  static final RegExp _timePattern = RegExp(r'\b\d{1,2}:\d{2}(:\d{2})?\b');
  static final RegExp _ipPattern =
      RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b');
  static final RegExp _currencyPattern =
      RegExp(r'[\$₹€£¥]\s*[\d,\._]+|[\d,\._]+\.\d{2}\b');

  /// Regex pattern capturing delimited sequences containing digits, hyphens, underscores, spaces, brackets
  static final RegExp _candidateTokenRegex = RegExp(
      r'(\+?\d[\d\s\-_()\.\/]{6,20}\d)');

  bool _isPostalOrPinCode(String cleanDigits, String rawToken) {
    // REJECT standalone 5-digit or 6-digit numbers (e.g. Indian PIN codes 641001, 641-001, 600_001, US Zip 90210)
    if (cleanDigits.length == 5 || cleanDigits.length == 6) {
      if (!rawToken.trim().startsWith('+')) {
        return true;
      }
    }
    return false;
  }

  bool _isFalsePositive(String rawToken, String cleanDigits) {
    if (_datePattern.hasMatch(rawToken)) return true;
    if (_timePattern.hasMatch(rawToken)) return true;
    if (_ipPattern.hasMatch(rawToken)) return true;
    if (_currencyPattern.hasMatch(rawToken)) return true;

    // Reject standalone 4-digit years (1900-2100)
    if (cleanDigits.length == 4 &&
        int.tryParse(cleanDigits) != null &&
        int.parse(cleanDigits) >= 1900 &&
        int.parse(cleanDigits) <= 2100) {
      return true;
    }

    // UPGRADE 2: Postal PIN Code & Zip Code rejection engine
    if (_isPostalOrPinCode(cleanDigits, rawToken)) return true;

    // Rule: Total dialable digits MUST be between 8 and 15
    if (cleanDigits.length < 8 || cleanDigits.length > 15) return true;

    // Reject repeated digits (e.g. 0000000000) or sequential runs (1234567890)
    if (_isNonPhoneDigitPattern(cleanDigits)) return true;

    return false;
  }

  bool _isNonPhoneDigitPattern(String digits) {
    if (RegExp(r'^(\d)\1+$').hasMatch(digits)) return true;

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

  /// UPGRADE 1: Safely extracts and normalizes hyphen, underscore, and space delimited numbers
  Set<String> _extractUniversalPhoneNumbers(String text) {
    if (text.trim().isEmpty) return {};
    final Set<String> results = {};

    for (final Match m in _candidateTokenRegex.allMatches(text)) {
      final String rawToken = m.group(0)!;

      // Normalize underscores '_' and multiple spaces to clean delimiters
      final String normalizedToken =
          rawToken.replaceAll('_', '-').replaceAll(RegExp(r'\s+'), ' ');

      final String digitsOnly =
          normalizedToken.replaceAll(RegExp(r'[^\d]'), '');

      if (_isFalsePositive(rawToken, digitsOnly)) continue;

      final bool hasPlus = normalizedToken.trimLeft().startsWith('+');
      final String dialable = hasPlus ? '+$digitsOnly' : digitsOnly;

      results.add(dialable);
    }

    return results;
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
  // UPGRADE 5: UI ModalBottomSheet with Flag Emoji Avatar & Line Type Subtitle
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _showMultipleNumbersBottomSheet(List<CountryInfo> infoList) async {
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
                    itemCount: infoList.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final CountryInfo info = infoList[index];
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            _handleDetectedNumber(info, 'camera_multi');
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
                                // Flag Emoji Circle Avatar
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.1),
                                  child: Text(
                                    info.flagEmoji,
                                    style: const TextStyle(fontSize: 22),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        info.formattedNumber,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        info.displayTag,
                                        style: TextStyle(
                                          color: Colors.greenAccent
                                              .withValues(alpha: 0.9),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade600,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.phone_in_talk_rounded,
                                    color: Colors.white,
                                    size: 16,
                                  ),
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
  // UPGRADE 4: Dialer & Call Logging Engine
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _handleDetectedNumber(CountryInfo info, String source) async {
    final String sanitized = info.dialableNumber;

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

      final Set<String> numbers =
          _extractUniversalPhoneNumbers(_sanitizeOcrText(recognizedText.text));

      if (numbers.isNotEmpty) {
        HapticFeedback.heavyImpact();
        final CountryInfo info = CountryHelper.parse(numbers.first);
        setState(() {
          _detectedCountryInfo = info;
        });
        await _handleDetectedNumber(info, 'gallery');
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
    final bool hasDetectedNumber = _detectedCountryInfo != null;

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

          // ── 3. Viewfinder Target Overlay with Flag & Line Type Banner ─────
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: roiWidth,
              height: hasDetectedNumber ? 210 : 160,
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
                  // UPGRADE 5: Viewfinder Top Banner (Flag Emoji + Country Name + Line Type)
                  if (hasDetectedNumber)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.greenAccent.withValues(alpha: 0.6),
                          width: 1.0,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _detectedCountryInfo!.flagEmoji,
                            style: const TextStyle(fontSize: 16),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _detectedCountryInfo!.displayTag,
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF6366F1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'ALIGN PHONE NUMBER HERE',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),

                  // Middle Phone Display
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
                        _detectedCountryInfo!.formattedNumber,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 21,
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

                  // Action Call Button
                  if (hasDetectedNumber)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _handleDetectedNumber(
                          _detectedCountryInfo!,
                          'dialer',
                        ),
                        icon: const Icon(
                          Icons.phone_in_talk_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        label: Text(
                          'Call ${_detectedCountryInfo!.formattedNumber}',
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
                          padding: const EdgeInsets.symmetric(vertical: 10),
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
// ROI Mask CustomPainter
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
