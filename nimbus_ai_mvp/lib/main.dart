import 'dart:async';
import 'dart:io';


import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(NimbusApp(cameras: cameras));
}

class NimbusApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const NimbusApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nimbus AI MVP',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: HomePage(cameras: cameras),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const HomePage({super.key, required this.cameras});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late CameraController _cameraController;
  bool _cameraReady = false;


  late final stt.SpeechToText _stt;
  bool _sttAvailable = false;
  bool _listening = false;


  final FlutterTts _tts = FlutterTts();
  String _lastHeard = '';

  // ML Kit object detector (base model, on-device)
  late final ObjectDetector _detector;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await _initTTS();
    await _initSpeech();
    await _initCamera();
    await _initDetector();
    if (mounted) setState(() {});
  }

  Future<void> _initTTS() async {
    await _tts.setSpeechRate(0.5); // slower, clearer
    await _tts.setPitch(1.0);
  }

  Future<void> _initSpeech() async {
    _stt = stt.SpeechToText();
    _sttAvailable = await _stt.initialize(
      onStatus: (s) => debugPrint('STT status: $s'),
      onError: (e) => debugPrint('STT error: $e'),
    );
  }

  Future<void> _initCamera() async {
    final back = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
    _cameraController = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg, // use still photos for simplicity
    );
    await _cameraController.initialize();
    _cameraReady = true;
  }

  Future<void> _initDetector() async {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true, // request labels when available
      multipleObjects: true,
    );
  _detector = ObjectDetector(options: options);
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _detector.close();
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  Future<void> _startListening() async {
    if (!_sttAvailable) {
      await _speak('Speech not available');
      return;
    }
    setState(() => _listening = true);
    await _stt.listen(
      onResult: (r) {
        _lastHeard = r.recognizedWords.toLowerCase();
        if (r.finalResult) {
          _handleCommand(_lastHeard);
        }
        setState(() {});
      },
      listenFor: const Duration(seconds: 5),
      pauseFor: const Duration(seconds: 2),
      partialResults: true,
      localeId: null, // system default
    );
  }

  Future<void> _stopListening() async {
    await _stt.stop();
    setState(() => _listening = false);
  }


Future<void> _handleCommand(String text) async {
  await _stopListening();
  if (text.contains("what's in front") ||
      text.contains('what is in front') ||
      text.contains('whats in front') ||
      text.contains('what is ahead') ||
      text.contains('what\'s ahead')) {
    await _scanSceneAndSpeak();
  } else {
    await _speak('Say: what\'s in front of me');
  }
}

Future<void> _scanSceneAndSpeak() async {
  if (!_cameraReady) {
    await _speak('Camera not ready');
    return;
} 

try {
  // Take a still photo to a temp file for ML Kit
  final tmpDir = await getTemporaryDirectory();
  final path = '${tmpDir.path}/scene.jpg';
  final file = await _cameraController.takePicture();
  await file.saveTo(path);


  final inputImage = InputImage.fromFilePath(path);
  final objects = await _detector.processImage(inputImage);


  if (objects.isEmpty) {
    await _speak('I do not see anything clearly in front.');
    return;
  }

  // Build a simple, short sentence from detected labels
  final List<String> labels = [];
  for (final obj in objects) {
    // Prefer the most confident label if available
    if (obj.labels.isNotEmpty) {
      labels.add(obj.labels.first.text.toLowerCase());
    } else {
      labels.add('object');
    }
  }

  // Count occurrences
  final Map<String, int> counts = {};
  for (final l in labels) {
    counts[l] = (counts[l] ?? 0) + 1;
  }

  final parts = counts.entries
      .map((e) => e.value == 1 ? 'a ${e.key}' : '${e.value} ${e.key}s')
      .toList();


  final sentence = _joinForSpeech(parts);
  await _speak('$sentence are in front.');
} catch (e) {
  debugPrint('Detect error: $e');
  await _speak('Sorry, I had trouble seeing the scene.');
}
}

String _joinForSpeech(List<String> parts) {
  if (parts.isEmpty) return 'Nothing';
  if (parts.length == 1) return parts.first;
  if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
  return parts.sublist(0, parts.length - 1).join(', ') + ', and ' + parts.last;
}


Future<void> _speak(String text) async {
  await _tts.stop();
  await _tts.speak(text);
}

@override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(title: const Text('Nimbus AI MVP')),
    body: Column(
      children: [
        if (_cameraReady)
          AspectRatio(
            aspectRatio: _cameraController.value.aspectRatio,
            child: CameraPreview(_cameraController),
          )
        else
          const Padding(
            padding: EdgeInsets.all(24.0),
            child: Text('Initializing camera...'),
          ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Text(
            _listening
              ? 'Listening... say: "What\'s in front of me?"'
              : (_lastHeard.isEmpty
                ? 'Tap the mic and ask: What\'s in front of me?'
                : 'You said: $_lastHeard'),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: _scanSceneAndSpeak,
              icon: const Icon(Icons.camera_alt),
              label: const Text("What's in front?"),
            ),
            const SizedBox(width: 16),
            ElevatedButton.icon(
              onPressed: _listening ? _stopListening : _startListening,
              icon: Icon(_listening ? Icons.stop : Icons.mic),
              label: Text(_listening ? 'Stop' : 'Speak'),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    ),
  );
} 
}