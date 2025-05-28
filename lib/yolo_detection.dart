import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter_vision/flutter_vision.dart';

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

  @override
  void initState() {
    super.initState();
    init();
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

  @override
  void dispose() async {
    detectionTimer?.cancel();
    announcementTimer?.cancel();
    super.dispose();
    await controller.dispose();
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
          // Camera Preview
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
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withOpacity(0.8),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Detection Status
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isDetecting
                          ? Colors.green.withOpacity(0.9)
                          : Colors.grey.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isDetecting ? 'Detection Active' : 'Detection Stopped',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      semanticsLabel: isDetecting
                          ? 'Object detection is currently running'
                          : 'Object detection is stopped',
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Main Control Button
                  Semantics(
                    label: isDetecting
                        ? 'Stop object detection'
                        : 'Start object detection',
                    hint: isDetecting
                        ? 'Double tap to stop detecting objects in camera view'
                        : 'Double tap to start detecting objects in camera view',
                    child: GestureDetector(
                      onTap: () async {
                        HapticFeedback.heavyImpact();
                        if (isDetecting) {
                          await stopDetection();
                        } else {
                          await startDetection();
                        }
                      },
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDetecting
                              ? Colors.red.shade600
                              : Colors.green.shade600,
                          boxShadow: [
                            BoxShadow(
                              color: (isDetecting ? Colors.red : Colors.green)
                                  .withOpacity(0.4),
                              blurRadius: 15,
                              spreadRadius: 2,
                            ),
                          ],
                          border: Border.all(
                            width: 4,
                            color: Colors.white,
                          ),
                        ),
                        child: Icon(
                          isDetecting ? Icons.stop : Icons.play_arrow,
                          color: Colors.white,
                          size: 40,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Status Panel at Top
          Positioned(
            top: 20,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Semantics(
                        label:
                            'Number of objects detected: ${yoloResults.length}',
                        child: Text(
                          'Objects: ${yoloResults.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isProcessing ? Colors.orange : Colors.green,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          isProcessing ? 'Processing...' : 'Ready',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (objectCounts.isNotEmpty) ...[                    
                    const SizedBox(height: 8),
                    const Divider(color: Colors.white54),
                    const SizedBox(height: 8),
                    Semantics(
                      label:
                          'Detected objects summary: ${_getObjectCountsAnnouncement()}',
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: objectCounts.entries.map((entry) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.7),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              '${entry.key}: ${entry.value}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ],
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

    // Process frames at 5 FPS for better performance and battery life
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
    if (yoloResults.isEmpty) return [];

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