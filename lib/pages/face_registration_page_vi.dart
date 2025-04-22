import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

class FaceRegistrationPageVI extends StatefulWidget {
  final List<CameraDescription> cameras;

  const FaceRegistrationPageVI({super.key, required this.cameras});

  @override
  State<FaceRegistrationPageVI> createState() => _FaceRegistrationPageVIState();
}

class _FaceRegistrationPageVIState extends State<FaceRegistrationPageVI> {
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
        _feedbackMessage = 'Quyền truy cập camera là cần thiết cho đăng ký khuôn mặt.';
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
        _feedbackMessage = 'Lỗi khởi tạo camera: $e';
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
      _feedbackMessage = 'Đang chụp ảnh...';
    });

    try {
      final XFile file = await _cameraController.takePicture();
      setState(() {
        _faceCaptures[_currentCaptureDirection] = file;
        _feedbackMessage = 'Chụp ảnh thành công!';
        
        // Move to next angle
        _moveToNextCaptureDirection();
      });
    } catch (e) {
      setState(() {
        _feedbackMessage = 'Lỗi khi chụp ảnh: $e';
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
        _feedbackMessage = 'Đang tải dữ liệu lên máy chủ...';
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
            _feedbackMessage = 'Đăng ký hoàn tất thành công!';
            _isProcessing = false;
          });
          
          // Show success dialog
          _showCompletionDialog();
        } else {
          final responseBody = await response.stream.bytesToString();
          setState(() {
            _feedbackMessage = 'Lỗi: ${response.statusCode} - $responseBody';
            _isProcessing = false;
          });
        }
      } catch (e) {
        setState(() {
          _feedbackMessage = 'Lỗi khi gửi dữ liệu: $e';
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
          title: const Text('Đăng Ký Hoàn Tất'),
          content: const Text('Cảm ơn bạn! Dữ liệu khuôn mặt của bạn đã được đăng ký thành công.'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _resetRegistration();
              },
              child: const Text('Đăng Ký Nhân Viên Khác'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop(); // Return to language selection
              },
              child: const Text('Trở Về Trang Chủ'),
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
        instruction = 'Nhìn thẳng vào camera';
        icon = Icons.face;
        break;
      case 'left':
        instruction = 'Xoay mặt của bạn nhẹ qua bên trái';
        icon = Icons.arrow_back;
        break;
      case 'right':
        instruction = 'Xoay mặt của bạn nhẹ qua bên phải';
        icon = Icons.arrow_forward;
        break;
      case 'up':
        instruction = 'Ngước mặt của bạn lên trên một chút';
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
          'Góc: ${_getDirectionInVietnamese(_currentCaptureDirection)} (${_getCaptureProgress()})',
          style: const TextStyle(color: Colors.white),
        ),
      ],
    );
  }
  
  String _getDirectionInVietnamese(String direction) {
    switch (direction) {
      case 'front': return 'THẲNG';
      case 'left': return 'TRÁI';
      case 'right': return 'PHẢI';
      case 'up': return 'TRÊN';
      default: return direction.toUpperCase();
    }
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
        title: const Text('Đăng Ký Khuôn Mặt Nhân Viên'),
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
                      labelText: 'Mã Nhân Viên',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Vui lòng nhập mã nhân viên';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Họ và Tên',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Vui lòng nhập họ và tên';
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
                      label: Text(_isCapturing ? 'Đang chụp...' : 'Chụp Khuôn Mặt'),
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
                      label: Text(_isProcessing ? 'Đang xử lý...' : 'Gửi Đăng Ký'),
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
                    label: const Text('Làm Lại'),
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