import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageByteFormat;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class FaceRegistrationPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const FaceRegistrationPage({super.key, required this.cameras});

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

class _FaceRegistrationPageState extends State<FaceRegistrationPage> with WidgetsBindingObserver {
  late CameraController _cameraController;
  bool _isCameraInitialized = false;
  bool _isFrontCameraSelected = true;
  bool _isCapturing = false;
  bool _isProcessing = false;
  bool _isCompleted = false;
  String _feedbackMessage = '';
  Timer? _captureTimer;
  int _countdownSeconds = 3;
  bool _isAutoCaptureActive = false;
  bool _processingImage = false;
  
  // Face detector instance - only for mobile platforms
  FaceDetector? _faceDetector;
  
  // Web simulation variables
  Timer? _webSimulationTimer;
  int _webCurrentDirection = 0;
  final List<String> _webDirections = ['front', 'left', 'right', 'up', 'down'];
  
  // Track angles that have already been captured
  Map<String, bool> _capturedAngles = {
    'front': false,
    'left': false,
    'right': false,
    'up': false,
    'down': false,
  };

  // Current detected face pose
  String _currentDetectedPose = 'unknown';
  double _currentAngleX = 0.0;
  double _currentAngleY = 0.0;
  double _currentAngleZ = 0.0;
  
  // Form controllers
  final TextEditingController _employeeIdController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Face captures from different angles
  Map<String, XFile> _faceCaptures = {
    'front': XFile(''),
    'left': XFile(''),
    'right': XFile(''),
    'down': XFile(''),
    'up': XFile(''),
  };

  // Current capture direction
  String _currentCaptureDirection = 'front';
  
  // Server endpoint
  final String _apiEndpoint = 'http://localhost:3000/api/employees';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Only initialize face detector on mobile platforms
    if (!kIsWeb) {
      _faceDetector = GoogleMlKit.vision.faceDetector(
        FaceDetectorOptions(
          enableClassification: true,
          enableTracking: true,
          minFaceSize: 0.1,
          performanceMode: FaceDetectorMode.accurate
        )
      );
    }
    
    _requestCameraPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App state changed before we got the chance to initialize the camera
    if (!_isCameraInitialized) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // Free up memory when camera isn't active
      _cameraController.dispose();
      _isCameraInitialized = false;
    } else if (state == AppLifecycleState.resumed) {
      // Reinitialize camera with same properties
      _initializeCamera(widget.cameras.first);
    }
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      await _initializeCamera(widget.cameras.first);
    } else {
      setState(() {
        _feedbackMessage = 'Camera permission is required for face registration.';
      });
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_isCameraInitialized) {
      await _cameraController.dispose();
    }
    
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium, // Changed from high to medium for better performance
      enableAudio: false,
      imageFormatGroup: kIsWeb ? ImageFormatGroup.jpeg : (Platform.isAndroid 
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888),
    );

    try {
      await _cameraController.initialize();
      
      if (!mounted) return;
      
      if (!kIsWeb) {
        // Start image stream for real-time face detection on mobile
        await _cameraController.startImageStream(_processCameraImage);
      }
      
      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      setState(() {
        _feedbackMessage = 'Error initializing camera: $e';
        _isCameraInitialized = false;
      });
      print('Error initializing camera: $e');
    }
  }
  
  Future<void> _processCameraImage(CameraImage cameraImage) async {
    // Skip processing on web platform
    if (kIsWeb || _processingImage || !_isAutoCaptureActive || _isCapturing || _isCompleted || !mounted) {
      return;
    }
    
    _processingImage = true;
    
    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in cameraImage.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final Size imageSize = Size(
        cameraImage.width.toDouble(),
        cameraImage.height.toDouble(),
      );

      // Make sure using the right camera
      final camera = _isFrontCameraSelected
        ? widget.cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.front,
            orElse: () => widget.cameras.first)
        : widget.cameras.firstWhere((camera) => camera.lensDirection == CameraLensDirection.back,
            orElse: () => widget.cameras.first);
            
      final imageRotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation) ?? 
        InputImageRotation.rotation0deg;

      final inputImageFormat = InputImageFormatValue.fromRawValue(cameraImage.format.raw) ?? 
        InputImageFormat.nv21;

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: imageSize,
          rotation: imageRotation, 
          format: inputImageFormat,
          bytesPerRow: cameraImage.planes[0].bytesPerRow,
        ),
      );

      final List<Face> faces = await _faceDetector!.processImage(inputImage);
      
      if (!mounted) return;
      
      if (faces.isEmpty) {
        setState(() {
          _currentDetectedPose = 'no_face';
        });
        return;
      }

      // Process the first detected face
      final Face face = faces.first;
      
      // Get face rotation angles
      final double? headEulerAngleX = face.headEulerAngleX;
      final double? headEulerAngleY = face.headEulerAngleY;
      final double? headEulerAngleZ = face.headEulerAngleZ;
      
      // These values are only non-null when using ML Kit face detector
      if (headEulerAngleX != null && headEulerAngleY != null && headEulerAngleZ != null) {
        if (mounted) {
          setState(() {
            _currentAngleX = headEulerAngleX;
            _currentAngleY = headEulerAngleY;
            _currentAngleZ = headEulerAngleZ;
          });
          
          // Determine face direction based on angles
          _determineFacePose(headEulerAngleX, headEulerAngleY, headEulerAngleZ);

          // Capture face if in correct position and angle hasn't been captured yet
          _autoCaptureFaceIfReady();
        }
      }
    } catch (e) {
      // Handle error without crashing
      print('Error processing face: $e');
    } finally {
      _processingImage = false;
    }
  }
  
  void _determineFacePose(double angleX, double angleY, double angleZ) {
    // Define thresholds for different directions
    const double frontThreshold = 15.0;
    const double sideThreshold = 25.0;
    const double verticalThreshold = 15.0;

    // Determine direction
    String pose = 'unknown';
    
    // Check front face first
    if (angleX.abs() < frontThreshold && 
        angleY.abs() < frontThreshold && 
        angleZ.abs() < frontThreshold) {
      pose = 'front';
    }
    // Check left/right face
    else if (angleY.abs() > sideThreshold) {
      pose = angleY > 0 ? 'right' : 'left';
    }
    // Check up/down face
    else if (angleX.abs() > verticalThreshold) {
      pose = angleX > 0 ? 'down' : 'up';  // X axis is inverted relative to face angle
    }
    
    if (mounted) {
      setState(() {
        _currentDetectedPose = pose;
        _updateCurrentCaptureDirectionBasedOnPose(pose);
      });
    }
  }

  void _autoCaptureFaceIfReady() {
    // Only proceed if auto mode is active and not capturing
    if (!_isAutoCaptureActive || _isCapturing || _isCompleted || !mounted) {
      return;
    }

    // Check if current pose matches what we need and hasn't been captured yet
    if (_currentDetectedPose != 'unknown' && 
        _currentDetectedPose != 'no_face' &&
        !_capturedAngles[_currentDetectedPose]!) {
      
      // Start capture process
      _captureImage();
    }
  }
  
  void _updateCurrentCaptureDirectionBasedOnPose(String detectedPose) {
    // Update capture direction based on detected face pose
    // and which angles are still missing
    if (detectedPose != 'unknown' && detectedPose != 'no_face' && !_capturedAngles[detectedPose]!) {
      _currentCaptureDirection = detectedPose;
    } else {
      // If angle has been captured or is unidentified,
      // find the next uncaptured angle
      List<String> missingAngles = _getMissingAngles();
      if (missingAngles.isNotEmpty && _currentCaptureDirection == detectedPose) {
        _currentCaptureDirection = missingAngles.first;
      }
    }
  }

  void _switchCamera() async {
    if (widget.cameras.length < 2) return;

    setState(() {
      _isCameraInitialized = false;
      _isFrontCameraSelected = !_isFrontCameraSelected;
    });

    if (!kIsWeb) {
      await _cameraController.stopImageStream();
    }
    await _cameraController.dispose();

    final newCameraIndex = _isFrontCameraSelected ? 
      widget.cameras.indexWhere((camera) => camera.lensDirection == CameraLensDirection.front) :
      widget.cameras.indexWhere((camera) => camera.lensDirection == CameraLensDirection.back);
      
    if (newCameraIndex >= 0) {
      await _initializeCamera(widget.cameras[newCameraIndex]);
    } else {
      await _initializeCamera(widget.cameras.first);
    }
  }

  // Web-specific implementation for face capture simulation
  void _startWebSimulation() {
    if (!kIsWeb || !_isAutoCaptureActive || _isCompleted) return;
    
    // Display initial instruction
    setState(() {
      _currentDetectedPose = _webDirections[_webCurrentDirection];
      _currentCaptureDirection = _webDirections[_webCurrentDirection];
      _feedbackMessage = 'Please position your face ${_webDirections[_webCurrentDirection]}';
    });
    
    // Give user 3 seconds to position their face
    _webSimulationTimer = Timer(const Duration(seconds: 3), () {
      if (_isAutoCaptureActive && !_isCapturing && !_isCompleted && mounted) {
        // Capture current angle
        _captureImage();
        
        // Move to next direction if there are any left
        _webCurrentDirection = (_webCurrentDirection + 1) % _webDirections.length;
        
        // Check if we need to continue
        if (_getMissingAngles().isEmpty) {
          setState(() {
            _isCompleted = true;
          });
        } else {
          // Schedule next capture
          _webSimulationTimer = Timer(const Duration(seconds: 4), () {
            if (_isAutoCaptureActive && !_isCapturing && !_isCompleted && mounted) {
              _startWebSimulation();
            }
          });
        }
      }
    });
  }

  // Start auto capture process
  void _startAutoCapture() {
    if (!_isCameraInitialized || _isCompleted) {
      return;
    }
    
    setState(() {
      _isAutoCaptureActive = true;
      _feedbackMessage = 'Auto-capture is active. Please follow the instructions.';
    });
    
    // For web platform, use simulation instead of ML Kit
    if (kIsWeb) {
      _startWebSimulation();
    }
  }

  // Stop auto capture process
  void _stopAutoCapture() {
    _webSimulationTimer?.cancel();
    
    setState(() {
      _isAutoCaptureActive = false;
      _feedbackMessage = 'Auto-capture paused.';
    });
  }

  List<String> _getMissingAngles() {
    return _faceCaptures.entries
        .where((entry) => entry.value.path.isEmpty)
        .map((entry) => entry.key)
        .toList();
  }

  Future<void> _captureImage() async {
    if (!_cameraController.value.isInitialized || _isCapturing || !mounted) {
      return;
    }
    
    setState(() {
      _isCapturing = true;
      _feedbackMessage = 'Capturing image...';
    });

    try {
      // Pause the image stream for high quality capture (mobile only)
      if (!kIsWeb) {
        await _cameraController.stopImageStream();
      }
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final XFile file = await _cameraController.takePicture();
      
      if (!mounted) return;
      
      // Restart image stream (mobile only)
      if (!kIsWeb) {
        await _cameraController.startImageStream(_processCameraImage);
      }
      
      setState(() {
        _faceCaptures[_currentCaptureDirection] = file;
        _capturedAngles[_currentCaptureDirection] = true;
        _feedbackMessage = 'Capture successful!';
        
        // Check if we've captured all angles
        if (_getMissingAngles().isEmpty) {
          _isCompleted = true;
          _isAutoCaptureActive = false;
          _webSimulationTimer?.cancel();
        } else {
          _feedbackMessage = 'Please position your face for the next angle.';
        }
      });
    } catch (e) {
      print('Error capturing image: $e');
      
      try {
        // Restart stream on error (mobile only)
        if (!kIsWeb && !_cameraController.value.isStreamingImages && mounted) {
          await _cameraController.startImageStream(_processCameraImage);
        }
      } catch (streamError) {
        print('Error restarting stream: $streamError');
      }
      
      if (mounted) {
        setState(() {
          _feedbackMessage = 'Error capturing image: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  Future<void> _submitRegistration() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isProcessing = true;
        _feedbackMessage = 'Uploading data to server...';
      });

      try {
        // Create multipart request
        var request = http.MultipartRequest('POST', Uri.parse(_apiEndpoint));
        
        // Add employee data
        request.fields['employeeId'] = _employeeIdController.text;
        request.fields['name'] = _nameController.text;
        
        // Add face images - handle differently for web and mobile
        for (var direction in _faceCaptures.keys) {
          final file = _faceCaptures[direction]!;
          if (file.path.isNotEmpty) {
            // For web, we need to read the bytes directly since file paths don't work
            if (kIsWeb) {
              final bytes = await file.readAsBytes();
              request.files.add(
                http.MultipartFile.fromBytes(
                  'faceImages',
                  bytes,
                  filename: 'face_$direction.jpg',
                ),
              );
            } else {
              // For mobile, we can use the file path
              request.files.add(
                await http.MultipartFile.fromPath(
                  'faceImages', 
                  file.path,
                  filename: 'face_$direction.jpg',
                ),
              );
            }
          }
        }
        
        // Send request
        final response = await request.send();
        
        if (response.statusCode == 201) {
          setState(() {
            _feedbackMessage = 'Registration completed successfully!';
            _isProcessing = false;
          });
          
          // Show completion dialog
          _showCompletionDialog();
        } else {
          final responseBody = await response.stream.bytesToString();
          setState(() {
            _feedbackMessage = 'Error: ${response.statusCode} - $responseBody';
            _isProcessing = false;
          });
        }
      } catch (e) {
        setState(() {
          _feedbackMessage = 'Error sending data: $e';
          _isProcessing = false;
        });
      }
    }
  }
  
  void _resetRegistration() {
    _captureTimer?.cancel();
    _webSimulationTimer?.cancel();
    _stopAutoCapture();
    _webCurrentDirection = 0;
    
    // Restart stream if stopped (mobile only)
    if (!kIsWeb && _isCameraInitialized && !_cameraController.value.isStreamingImages) {
      _cameraController.startImageStream(_processCameraImage);
    }
    
    setState(() {
      _employeeIdController.clear();
      _nameController.clear();
      _faceCaptures = {
        'front': XFile(''),
        'left': XFile(''),
        'right': XFile(''),
        'up': XFile(''),
        'down': XFile(''),
      };
      _capturedAngles = {
        'front': false,
        'left': false,
        'right': false,
        'up': false,
        'down': false,
      };
      _currentCaptureDirection = 'front';
      _isCompleted = false;
      _isAutoCaptureActive = false;
      _feedbackMessage = '';
    });
  }
  
  void _showCompletionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Registration Complete'),
          content: const Text('Thank you! Your face data has been registered successfully.'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _resetRegistration();
              },
              child: const Text('Register Another Employee'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop(); // Return to language selection page
              },
              child: const Text('Return to Home'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCaptureFeedbackWidget() {
    String instruction = '';
    IconData icon = Icons.face;
    
    switch (_currentCaptureDirection) {
      case 'front':
        instruction = 'Look straight into the camera';
        icon = Icons.face;
        break;
      case 'left':
        instruction = 'Slowly turn your face to the left';
        icon = Icons.arrow_back;
        break;
      case 'right':
        instruction = 'Slowly turn your face to the right';
        icon = Icons.arrow_forward;
        break;
      case 'up':
        instruction = 'Slowly tilt your face upwards';
        icon = Icons.arrow_upward;
        break;
      case 'down':
        instruction = 'Slowly tilt your face downwards';
        icon = Icons.arrow_downward;
        break;
    }
    
    return Column(
      children: [
        Icon(icon, size: 48.0, color: Colors.white),
        const SizedBox(height: 8),
        Text(
          instruction,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18.0,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Angle: ${_currentCaptureDirection.toUpperCase()} (${_getCaptureProgress()})',
          style: const TextStyle(color: Colors.white),
        ),
        if (_isAutoCaptureActive && _currentDetectedPose == _currentCaptureDirection)
          const Text(
            'Perfect! Hold this position...',
            style: TextStyle(
              color: Colors.green,
              fontSize: 16.0,
              fontWeight: FontWeight.bold,
            ),
          ),
      ],
    );
  }
  
  String _getCaptureProgress() {
    int completed = _faceCaptures.values.where((file) => file.path.isNotEmpty).length;
    return '$completed/${_faceCaptures.length}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _captureTimer?.cancel();
    _webSimulationTimer?.cancel();
    
    if (!kIsWeb && _cameraController.value.isStreamingImages) {
      _cameraController.stopImageStream();
    }
    
    _cameraController.dispose();
    
    // Only close face detector on mobile platforms
    if (!kIsWeb && _faceDetector != null) {
      _faceDetector!.close();
    }
    
    _employeeIdController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Employee Face Registration'),
        actions: [
          if (widget.cameras.length > 1)
            IconButton(
              icon: const Icon(Icons.flip_camera_ios),
              onPressed: _switchCamera,
            ),
        ],
      ),
      body: Column(
        children: [
          // Employee info form
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _employeeIdController,
                    decoration: const InputDecoration(
                      labelText: 'Employee ID',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter employee ID';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter full name';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          
          // Camera preview and capture area
          Expanded(
            child: Container(
              color: Colors.black,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_isCameraInitialized)
                    CameraPreview(_cameraController),
                  
                  // Face guide frame
                  Center(
                    child: Container(
                      width: 250,
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _currentDetectedPose == _currentCaptureDirection 
                              ? Colors.green 
                              : Colors.white, 
                          width: _currentDetectedPose == _currentCaptureDirection ? 3.0 : 2.0
                        ),
                        borderRadius: BorderRadius.circular(125),
                      ),
                    ),
                  ),
                  
                  // Capture guidance
                  Positioned(
                    top: 20,
                    child: _buildCaptureFeedbackWidget(),
                  ),
                  
                  // Debug info about face angles (mobile only)
                  if (!kIsWeb)
                    Positioned(
                      top: 120,
                      left: 20,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Detected: $_currentDetectedPose',
                              style: const TextStyle(color: Colors.white),
                            ),
                            Text(
                              'X: ${_currentAngleX.toStringAsFixed(1)}°',
                              style: const TextStyle(color: Colors.white),
                            ),
                            Text(
                              'Y: ${_currentAngleY.toStringAsFixed(1)}°',
                              style: const TextStyle(color: Colors.white),
                            ),
                            Text(
                              'Z: ${_currentAngleZ.toStringAsFixed(1)}°',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  
                  // Add web notice
                  if (kIsWeb)
                    Positioned(
                      top: 120,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Column(
                          children: [
                            Text(
                              'WEB MODE',
                              style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Please follow the prompts to move your face',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  
                  // Feedback message
                  if (_feedbackMessage.isNotEmpty)
                    Positioned(
                      bottom: 100,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                        color: Colors.black54,
                        child: Text(
                          _feedbackMessage,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ),
                    
                  // List of captured and needed angles
                  Positioned(
                    top: 120,
                    right: 20,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Capture Status:',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          ..._faceCaptures.entries.map((entry) {
                            bool isCaptured = entry.value.path.isNotEmpty;
                            return Row(
                              children: [
                                Icon(
                                  isCaptured ? Icons.check_circle : Icons.radio_button_unchecked,
                                  color: isCaptured ? Colors.green : Colors.white,
                                  size: 16,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  entry.key.toUpperCase(),
                                  style: TextStyle(
                                    color: isCaptured ? Colors.green : Colors.white,
                                    fontWeight: isCaptured ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Action buttons
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (!_isCompleted)
                  _isAutoCaptureActive
                    ? Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _stopAutoCapture,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop Auto-Capture'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            backgroundColor: Colors.orange,
                          ),
                        ),
                      )
                    : Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _startAutoCapture,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start Auto-Capture'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            backgroundColor: Colors.blue,
                          ),
                        ),
                      )
                else
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isProcessing ? null : _submitRegistration,
                      icon: const Icon(Icons.upload),
                      label: Text(_isProcessing ? 'Processing...' : 'Submit Registration'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.green,
                      ),
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _resetRegistration,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reset'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: Colors.red,
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