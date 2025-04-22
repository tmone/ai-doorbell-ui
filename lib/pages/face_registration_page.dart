import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

class FaceRegistrationPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const FaceRegistrationPage({super.key, required this.cameras});

  @override
  State<FaceRegistrationPage> createState() => _FaceRegistrationPageState();
}

class _FaceRegistrationPageState extends State<FaceRegistrationPage> {
  late CameraController _cameraController;
  bool _isCameraInitialized = false;
  bool _isFrontCameraSelected = true;
  bool _isCapturing = false;
  bool _isProcessing = false;
  bool _isCompleted = false;
  String _feedbackMessage = '';
  
  // Form controllers
  final TextEditingController _employeeIdController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Face captures from different angles
  Map<String, XFile> _faceCaptures = {
    'front': XFile(''),
    'left': XFile(''),
    'right': XFile(''),
    'up': XFile(''),
  };

  // Current capture direction
  String _currentCaptureDirection = 'front';
  
  // Server endpoint
  final String _apiEndpoint = 'http://localhost:3000/api/employees';

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      _initializeCamera(widget.cameras.first);
    } else {
      setState(() {
        _feedbackMessage = 'Camera permission is required for face registration.';
      });
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _cameraController.initialize();
      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      setState(() {
        _feedbackMessage = 'Error initializing camera: $e';
      });
    }
  }

  void _switchCamera() {
    if (widget.cameras.length < 2) return;

    setState(() {
      _isCameraInitialized = false;
      _isFrontCameraSelected = !_isFrontCameraSelected;
    });

    final newCameraIndex = _isFrontCameraSelected ? 1 : 0;
    if (newCameraIndex < widget.cameras.length) {
      _initializeCamera(widget.cameras[newCameraIndex]);
    }
  }

  Future<void> _captureImage() async {
    if (!_cameraController.value.isInitialized) {
      return;
    }
    
    setState(() {
      _isCapturing = true;
      _feedbackMessage = 'Capturing image...';
    });

    try {
      final XFile file = await _cameraController.takePicture();
      setState(() {
        _faceCaptures[_currentCaptureDirection] = file;
        _feedbackMessage = 'Image captured successfully!';
        
        // Move to next angle
        _moveToNextCaptureDirection();
      });
    } catch (e) {
      setState(() {
        _feedbackMessage = 'Error capturing image: $e';
      });
    } finally {
      setState(() {
        _isCapturing = false;
      });
    }
  }
  
  void _moveToNextCaptureDirection() {
    final directions = ['front', 'left', 'right', 'up'];
    final currentIndex = directions.indexOf(_currentCaptureDirection);
    
    if (currentIndex < directions.length - 1) {
      setState(() {
        _currentCaptureDirection = directions[currentIndex + 1];
      });
    } else {
      // All images captured
      setState(() {
        _isCompleted = true;
      });
    }
  }

  Future<void> _submitRegistration() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isProcessing = true;
        _feedbackMessage = 'Uploading data to server...';
      });

      try {
        // Create a multipart request
        var request = http.MultipartRequest('POST', Uri.parse(_apiEndpoint));
        
        // Add employee data
        request.fields['employeeId'] = _employeeIdController.text;
        request.fields['name'] = _nameController.text;
        
        // Add face images
        for (var direction in _faceCaptures.keys) {
          final file = _faceCaptures[direction]!;
          if (file.path.isNotEmpty) {
            request.files.add(
              await http.MultipartFile.fromPath(
                'faceImages', 
                file.path,
                filename: 'face_$direction.jpg',
              ),
            );
          }
        }
        
        // Send the request
        final response = await request.send();
        
        if (response.statusCode == 201) {
          setState(() {
            _feedbackMessage = 'Registration completed successfully!';
            _isProcessing = false;
          });
          
          // Show success dialog
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
    setState(() {
      _employeeIdController.clear();
      _nameController.clear();
      _faceCaptures = {
        'front': XFile(''),
        'left': XFile(''),
        'right': XFile(''),
        'up': XFile(''),
      };
      _currentCaptureDirection = 'front';
      _isCompleted = false;
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
                Navigator.of(context).pop(); // Return to language selection
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
        instruction = 'Look straight at the camera';
        icon = Icons.face;
        break;
      case 'left':
        instruction = 'Turn your face slightly to the left';
        icon = Icons.arrow_back;
        break;
      case 'right':
        instruction = 'Turn your face slightly to the right';
        icon = Icons.arrow_forward;
        break;
      case 'up':
        instruction = 'Tilt your face slightly upward';
        icon = Icons.arrow_upward;
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
      ],
    );
  }
  
  String _getCaptureProgress() {
    int completed = _faceCaptures.values.where((file) => file.path.isNotEmpty).length;
    return '$completed/${_faceCaptures.length}';
  }

  @override
  void dispose() {
    _cameraController.dispose();
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
          // Employee information form
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
                        return 'Please enter your employee ID';
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
                        return 'Please enter your full name';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          
          // Camera preview and capture section
          Expanded(
            child: Container(
              color: Colors.black,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_isCameraInitialized)
                    CameraPreview(_cameraController),
                  
                  // Face outline guide
                  Center(
                    child: Container(
                      width: 250,
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 2.0),
                        borderRadius: BorderRadius.circular(125),
                      ),
                    ),
                  ),
                  
                  // Capture instructions
                  Positioned(
                    top: 20,
                    child: _buildCaptureFeedbackWidget(),
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
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isCapturing ? null : _captureImage,
                      icon: const Icon(Icons.camera),
                      label: Text(_isCapturing ? 'Capturing...' : 'Capture Face'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
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