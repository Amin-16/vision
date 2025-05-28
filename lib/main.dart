import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'vqa.dart';
import 'yolo_detection.dart';

enum Options { frame }
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  runApp(
    MaterialApp(
      title: 'Accessible Vision App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Roboto',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 18),
          bodyMedium: TextStyle(fontSize: 16),
          titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
      home: const HomeScreen(),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  late FlutterVision vision;

  @override
  void initState() {
    super.initState();
    vision = FlutterVision();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      YoloVideo(vision: vision),
      const VQAPage(),
    ];
    return Scaffold(
      body: pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_alt),
            label: 'Object Detection',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.question_answer),
            label: 'VQA',
          ),
        ],
      ),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late FlutterVision vision;
  Options option = Options.frame;

  @override
  void initState() {
    super.initState();
    vision = FlutterVision();
  }

  @override
  void dispose() async {
    super.dispose();
    await vision.closeTesseractModel();
    await vision.closeYoloModel();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Object Detection Camera',
          semanticsLabel: 'Object Detection Camera App',
        ),
        backgroundColor: Colors.blue.shade800,
        foregroundColor: Colors.white,
        elevation: 4,
        centerTitle: true,
      ),
      body: task(option),
      floatingActionButton: Semantics(
        label: 'Menu options',
        hint: 'Double tap to open detection options',
        child: SpeedDial(
          icon: Icons.menu,
          activeIcon: Icons.close,
          backgroundColor: Colors.blue.shade700,
          foregroundColor: Colors.white,
          activeBackgroundColor: Colors.blue.shade900,
          activeForegroundColor: Colors.white,
          visible: true,
          closeManually: false,
          curve: Curves.easeInOut,
          overlayColor: Colors.black,
          overlayOpacity: 0.7,
          buttonSize: const Size(64.0, 64.0),
          elevation: 8,
          children: [
            SpeedDialChild(
              child: const Icon(Icons.video_call, size: 28),
              backgroundColor: Colors.green.shade600,
              foregroundColor: Colors.white,
              label: 'Start Object Detection',
              labelStyle: const TextStyle(
                fontSize: 16.0,
                fontWeight: FontWeight.w600,
              ),
              onTap: () {
                HapticFeedback.mediumImpact();
                setState(() {
                  option = Options.frame;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget task(Options option) {
    return YoloVideo(vision: vision);
  }
}

