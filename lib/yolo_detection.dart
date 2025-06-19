import 'dart:ui';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:http_parser/http_parser.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

late List<CameraDescription> cameras;

class YoloVideo extends StatefulWidget {
  final FlutterVision vision;
  const YoloVideo({Key? key, required this.vision}) : super(key: key);

  @override
  State<YoloVideo> createState() => _YoloVideoState();
}

class _YoloVideoState extends State<YoloVideo> {
  late CameraController controller;
  late List<Map<String, dynamic>> yoloResults;
  CameraImage? cameraImage;
  bool isLoaded = false;
  bool isDetecting = false;
  bool isProcessing = false;
  Timer? detectionTimer;
  Timer? announcementTimer;
  String lastAnnouncement = '';
  Map<String, int> objectCounts = {};

  // VQA related variables
  File? _capturedImage;
  bool _isListening = false;
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  final String apiUrl = 'http://192.168.1.10:5000/predict';
  bool _isProcessingVQA = false;
  bool _showFrozenFrame = false;
  Timer? _questionTimer;
  OverlayEntry? _answerOverlay;

  @override
  void initState() {
    super.initState();
    init();
    _initSpeech();
    _initTts();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);
  }

  Future<void> _speakAnswer(String text) async {
    await _flutterTts.stop();
    await Future.delayed(const Duration(milliseconds: 150));
    return _flutterTts.speak(text);
  }

  Future<void> _initSpeech() async {
    await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' && _isListening) {
          setState(() => _isListening = false);
        }
      },
      onError: (error) async {
        print('Speech recognition error: $error');
        // Handle error_no_match gracefully
        if (error.errorMsg == 'error_no_match') {
          setState(() {
            _isListening = false;
            _showFrozenFrame = false;
          });
          _resetVQAState();
          await _speakAnswer("I didn't catch that. Please try again.");
          HapticFeedback.heavyImpact();
        }
      },
    );
  }

  void _resetVQAState() {
    _flutterTts.stop(); // Stop any ongoing speech
    setState(() {
      _showFrozenFrame = false;
      _isListening = false;
      _isProcessingVQA = false;
      _capturedImage = null;
    });
    _questionTimer?.cancel();
  }

  Future<void> _startListeningAndProcess() async {
    if (!_isListening && !_isProcessingVQA) {
      try {
        // Capture the image first
        if (controller.value.isStreamingImages) {
          await stopDetection();
        }

        // Remove bounding boxes before freezing
        setState(() {
          yoloResults.clear();
          objectCounts.clear();
        });

        // Take picture
        final XFile image = await controller.takePicture();
        _capturedImage = File(image.path);

        // Show frozen frame and play sound
        setState(() {
          _showFrozenFrame = true;
        });

        HapticFeedback.heavyImpact();
        // Wait for the ready prompt to complete before starting listening
        await _speakAnswer("Ready for your question");

        // Start listening only after TTS is complete
        setState(() => _isListening = true);

        // Set a timeout for the question
        _questionTimer?.cancel();
        _questionTimer = Timer(const Duration(seconds: 10), () async {
          if (_isListening) {
            await _speech.stop();
            setState(() {
              _showFrozenFrame = false;
            });
            _resetVQAState();
            await _speakAnswer("No question detected. Please try again.");
            HapticFeedback.heavyImpact();
          }
        });

        await _speech.listen(
          onResult: (result) async {
            if (result.finalResult) {
              _questionTimer?.cancel();
              setState(() {
                _isListening = false;
                // _showFrozenFrame = false; // Do NOT unfreeze here
              });
              String question = result.recognizedWords;

              if (question.trim().isEmpty) {
                _resetVQAState();
                await _speakAnswer(
                    "I didn't hear a question. Please try again.");
                return;
              }

              // Wait for confirmation message to complete before processing
              await _speakAnswer("I heard: $question. Processing...");

              // Process the question while keeping the image frozen
              await _processVQA(question);
            }
          },
          cancelOnError: true,
          listenMode: stt.ListenMode.confirmation,
        );
      } catch (e) {
        print('Error in VQA process: $e');
        _resetVQAState();
        await _speakAnswer("Sorry, there was an error. Please try again.");
      }
    }
  }

  void _showAnswerOverlay(String answer) {
    _answerOverlay?.remove();
    _answerOverlay = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 24,
        left: 18,
        right: 18,
        child: _ModernAnswerCard(answer: answer),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_answerOverlay!);
    Future.delayed(const Duration(seconds: 5), () {
      _answerOverlay?.remove();
      _answerOverlay = null;
      setState(() {
        _showFrozenFrame = false;
      });
    });
  }

  Future<void> _processVQA(String question) async {
    setState(() => _isProcessingVQA = true);

    try {
      var request = http.MultipartRequest('POST', Uri.parse(apiUrl));
      request.fields['question'] = question;
      request.files.add(await http.MultipartFile.fromPath(
        'image',
        _capturedImage!.path,
        contentType: MediaType('image', 'jpeg'),
      ));

      var response = await request.send();
      var responseData = await http.Response.fromStream(response);

      if (response.statusCode == 200) {
        var jsonResponse = jsonDecode(responseData.body);
        String answer = jsonResponse['answer'];

        // Show the answer as a modern overlay at the top
        if (mounted) {
          _showAnswerOverlay(answer);
        }
        // Wait for the answer to be completely spoken
        await _speakAnswer(answer);
      } else {
        await _speakAnswer(
            "Sorry, I couldn't process the image. Please try again.");
      }
    } catch (e) {
      await _speakAnswer("Sorry, there was an error. Please try again.");
    } finally {
      setState(() {
        _isProcessingVQA = false;
      });
      _capturedImage = null;
    }
  }

  @override
  void dispose() {
    detectionTimer?.cancel();
    announcementTimer?.cancel();
    _questionTimer?.cancel();
    _speech.stop();
    _flutterTts.stop();
    super.dispose();
    controller.dispose();
  }

  init() async {
    cameras = await availableCameras();
    controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );

    await controller.initialize();
    await loadYoloModel();

    setState(() {
      isLoaded = true;
      isDetecting = false;
      yoloResults = [];
    });
  }

  Future<void> loadYoloModel() async {
    await widget.vision.loadYoloModel(
      labels: 'assets/labels.txt',
      modelPath: 'assets/yolov8n.tflite',
      modelVersion: "yolov8",
      numThreads: 4,
      useGpu: true,
    );
    setState(() {
      isLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;

    if (!isLoaded) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                strokeWidth: 4,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
              SizedBox(height: 20),
              Text(
                "Loading AI model...",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                semanticsLabel:
                    "Loading artificial intelligence model, please wait",
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera Preview or Frozen Frame
          if (_showFrozenFrame && _capturedImage != null)
            Positioned.fill(
              child: Image.file(
                _capturedImage!,
                fit: BoxFit.cover,
              ),
            )
          else
            Semantics(
              label: 'Camera view for object detection',
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: CameraPreview(controller),
              ),
            ),

          // Detection boxes
          ...displayBoxesAroundRecognizedObjects(size),

          // Control Panel at Bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
              child: AnimatedOpacity(
                opacity: 1.0,
                duration: const Duration(milliseconds: 400),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(36),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withOpacity(0.18),
                            Colors.white.withOpacity(0.08),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(36),
                        border: Border.all(
                          width: 2.5,
                          style: BorderStyle.solid,
                          color: Colors.blueAccent.withOpacity(0.18),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.18),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        switchInCurve: Curves.easeInOutCubic,
                        switchOutCurve: Curves.easeInOutCubic,
                        child: _isListening
                            ? _ListeningMicPanel(timer: _questionTimer)
                            : _isProcessingVQA
                                ? const _ProcessingPanel()
                                : Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      // Detection Status
                                      Flexible(
                                        fit: FlexFit.tight,
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 300),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 12),
                                          decoration: BoxDecoration(
                                            color: isDetecting
                                                ? Colors.green.withOpacity(0.92)
                                                : Colors.grey.withOpacity(0.92),
                                            borderRadius:
                                                BorderRadius.circular(32),
                                            boxShadow: [
                                              if (isDetecting)
                                                BoxShadow(
                                                  color: Colors.green
                                                      .withOpacity(0.25),
                                                  blurRadius: 16,
                                                  spreadRadius: 2,
                                                ),
                                            ],
                                          ),
                                          child: AnimatedDefaultTextStyle(
                                            duration: const Duration(
                                                milliseconds: 300),
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 0.2,
                                              shadows: isDetecting
                                                  ? [
                                                      const Shadow(
                                                        color: Colors.black45,
                                                        blurRadius: 4,
                                                      ),
                                                    ]
                                                  : [],
                                            ),
                                            child: Text(
                                              isDetecting
                                                  ? 'Detection Active'
                                                  : 'Detection Stopped',
                                              semanticsLabel: isDetecting
                                                  ? 'Object detection is currently running'
                                                  : 'Object detection is stopped',
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      // Detection Control Button (hide during VQA)
                                      if (!_isListening && !_isProcessingVQA)
                                        _AnimatedActionButton(
                                          icon: isDetecting
                                              ? Icons.stop
                                              : Icons.play_arrow,
                                          color: isDetecting
                                              ? Colors.red
                                              : Colors.green,
                                          onTap: () async {
                                            HapticFeedback.heavyImpact();
                                            if (isDetecting) {
                                              await stopDetection();
                                            } else {
                                              await startDetection();
                                            }
                                          },
                                          semanticLabel: isDetecting
                                              ? 'Stop object detection'
                                              : 'Start object detection',
                                          semanticHint: isDetecting
                                              ? 'Double tap to stop detecting objects in camera view'
                                              : 'Double tap to start detecting objects in camera view',
                                          isActive: isDetecting,
                                        ),
                                      if (!_isListening && !_isProcessingVQA)
                                        const SizedBox(width: 12),
                                      // VQA Button (always visible in normal state)
                                      if (!_isListening && !_isProcessingVQA)
                                        _AnimatedActionButton(
                                          icon: Icons.question_answer,
                                          color: Colors.blue,
                                          onTap: () async {
                                            if (!_isListening &&
                                                !_isProcessingVQA) {
                                              await _startListeningAndProcess();
                                            }
                                          },
                                          semanticLabel:
                                              'Ask a question about what you see',
                                          semanticHint:
                                              'Double tap to take a picture and ask a question by voice',
                                          isActive: false,
                                        ),
                                    ],
                                  ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getObjectCountsAnnouncement() {
    if (objectCounts.isEmpty) return 'No objects detected';

    List<String> announcements = [];
    objectCounts.forEach((object, count) {
      announcements.add('$count ${object}${count > 1 ? 's' : ''}');
    });

    return announcements.join(', ');
  }

  Future<void> yoloOnFrame(CameraImage cameraImage) async {
    if (isProcessing) return;

    setState(() {
      isProcessing = true;
    });

    try {
      final result = await widget.vision.yoloOnFrame(
        bytesList: cameraImage.planes.map((plane) => plane.bytes).toList(),
        imageHeight: cameraImage.height,
        imageWidth: cameraImage.width,
        iouThreshold: 0.3,
        confThreshold: 0.4, // Higher confidence for better accuracy
        classThreshold: 0.4,
      );

      if (mounted) {
        setState(() {
          yoloResults = result;
          isProcessing = false;
          _updateObjectCounts();
        });
      }
    } catch (e) {
      print('YOLO processing error: $e');
      if (mounted) {
        setState(() {
          isProcessing = false;
        });
      }
    }
  }

  void _updateObjectCounts() {
    Map<String, int> newCounts = {};

    for (var result in yoloResults) {
      if (result["box"][4] >= 0.4) {
        // Only count high-confidence detections
        String objectName = result['tag'];
        newCounts[objectName] = (newCounts[objectName] ?? 0) + 1;
      }
    }

    objectCounts = newCounts;

    // Announce changes periodically for accessibility
    _announceDetections();
  }

  void _announceDetections() {
    if (objectCounts.isEmpty) return;

    String announcement = _getObjectCountsAnnouncement();

    // Only announce if there's a significant change
    if (announcement != lastAnnouncement) {
      lastAnnouncement = announcement;

      // Cancel previous timer
      announcementTimer?.cancel();

      // Set a new timer to announce after 2 seconds of stability
      announcementTimer = Timer(const Duration(seconds: 2), () {
        // This would integrate with screen reader
        // For now, we'll use semantics labels on the UI elements
        if (mounted) {
          HapticFeedback.selectionClick();
        }
      });
    }
  }

  Future<void> startDetection() async {
    setState(() {
      isDetecting = true;
    });

    if (controller.value.isStreamingImages) {
      return;
    }

    // Process frames at 5 FPS
    detectionTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (!isDetecting) {
        timer.cancel();
        return;
      }

      if (cameraImage != null && !isProcessing) {
        yoloOnFrame(cameraImage!);
      }
    });

    await controller.startImageStream((image) async {
      if (isDetecting && !isProcessing) {
        cameraImage = image;
      }
    });
  }

  Future<void> stopDetection() async {
    setState(() {
      isDetecting = false;
      isProcessing = false;
      yoloResults.clear();
      objectCounts.clear();
    });

    detectionTimer?.cancel();
    announcementTimer?.cancel();

    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  List<Widget> displayBoxesAroundRecognizedObjects(Size screen) {
    if (!isDetecting || yoloResults.isEmpty) return [];

    double factorX = screen.width / (cameraImage?.height ?? 1);
    double factorY = screen.height / (cameraImage?.width ?? 1);

    final filteredResults =
        yoloResults.where((result) => result["box"][4] >= 0.4).toList();

    return filteredResults.map((result) {
      final colorIndex = result['tag'].hashCode % colors.length;
      final borderColor = colors[colorIndex];
      final bgColor = borderColor.withOpacity(0.9);
      final confidence = (result['box'][4] * 100).toStringAsFixed(1);

      return Positioned(
        left: result["box"][0] * factorX,
        top: result["box"][1] * factorY,
        width: (result["box"][2] - result["box"][0]) * factorX,
        height: (result["box"][3] - result["box"][1]) * factorY,
        child: Semantics(
          label:
              '${result['tag']} detected with $confidence percent confidence',
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(8.0)),
              border: Border.all(color: borderColor, width: 3.0),
              boxShadow: [
                BoxShadow(
                  color: borderColor.withOpacity(0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                "${result['tag']} $confidence%",
                style: TextStyle(
                  backgroundColor: bgColor,
                  color: Colors.white,
                  fontSize: 14.0,
                  fontWeight: FontWeight.bold,
                  shadows: const [
                    Shadow(
                      offset: Offset(1, 1),
                      blurRadius: 2,
                      color: Colors.black54,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  static const List<Color> colors = [
    Colors.red,
    Colors.green,
    Colors.blue,
    Colors.orange,
    Colors.purple,
    Colors.pink,
    Colors.cyan,
    Colors.lime,
    Colors.indigo,
    Colors.amber,
    Colors.teal,
    Colors.brown,
  ];
}

class _AnimatedActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String semanticLabel;
  final String semanticHint;
  final bool isActive;
  const _AnimatedActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.semanticLabel,
    required this.semanticHint,
    this.isActive = false,
    Key? key,
  }) : super(key: key);

  @override
  State<_AnimatedActionButton> createState() => _AnimatedActionButtonState();
}

class _AnimatedActionButtonState extends State<_AnimatedActionButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      hint: widget.semanticHint,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          width: _pressed ? 62 : 70,
          height: _pressed ? 62 : 70,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                widget.color.withOpacity(0.85),
                widget.color.withOpacity(0.65),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withOpacity(widget.isActive ? 0.5 : 0.25),
                blurRadius: widget.isActive ? 18 : 8,
                spreadRadius: widget.isActive ? 2 : 0,
                offset: const Offset(0, 6),
              ),
            ],
            border: Border.all(
              color: Colors.white.withOpacity(0.7),
              width: widget.isActive ? 3 : 1.5,
            ),
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Icon(
                widget.icon,
                key: ValueKey(widget.icon),
                color: Colors.white,
                size: 36,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ListeningMicPanel extends StatefulWidget {
  final Timer? timer;
  const _ListeningMicPanel({Key? key, required this.timer}) : super(key: key);

  @override
  State<_ListeningMicPanel> createState() => _ListeningMicPanelState();
}

class _ListeningMicPanelState extends State<_ListeningMicPanel> {
  double _progress = 1.0;
  late Timer _localTimer;

  @override
  void initState() {
    super.initState();
    _progress = 1.0;
    _localTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      setState(() {
        _progress -= 0.01;
        if (_progress <= 0) {
          _progress = 0;
          timer.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _localTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
      width: double.infinity,
      height: 80,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 70,
              height: 70,
              child: CircularProgressIndicator(
                value: _progress,
                strokeWidth: 6,
                backgroundColor: Colors.white.withOpacity(0.15),
                valueColor: AlwaysStoppedAnimation<Color>(Colors.redAccent),
              ),
            ),
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Colors.redAccent, Colors.red.shade700],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.redAccent.withOpacity(0.3),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(Icons.mic, color: Colors.white, size: 36),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessingPanel extends StatelessWidget {
  const _ProcessingPanel({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
      width: double.infinity,
      height: 80,
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 6,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                backgroundColor: Colors.white24,
              ),
            ),
            const SizedBox(width: 18),
            Text(
              'Processing...',
              style: TextStyle(
                color: Colors.orange.shade700,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModernAnswerCard extends StatefulWidget {
  final String answer;
  const _ModernAnswerCard({required this.answer});

  @override
  State<_ModernAnswerCard> createState() => _ModernAnswerCardState();
}

class _ModernAnswerCardState extends State<_ModernAnswerCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _scaleAnim = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.blue.shade700.withOpacity(0.85),
                    Colors.purple.shade400.withOpacity(0.75),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: Colors.white.withOpacity(0.25),
                  width: 2.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blueAccent.withOpacity(0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ShaderMask(
                    shaderCallback: (rect) => LinearGradient(
                      colors: [Colors.amber, Colors.yellow, Colors.orange],
                    ).createShader(rect),
                    child: const Icon(
                      Icons.emoji_objects_rounded,
                      size: 38,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Text(
                      widget.answer,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                        shadows: [
                          Shadow(
                            color: Colors.black38,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
