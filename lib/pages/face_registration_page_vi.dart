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

class FaceRegistrationPageVI extends StatefulWidget {
  final List<CameraDescription> cameras;

  const FaceRegistrationPageVI({super.key, required this.cameras});

  @override
  State<FaceRegistrationPageVI> createState() => _FaceRegistrationPageVIState();
}

class _FaceRegistrationPageVIState extends State<FaceRegistrationPageVI> with WidgetsBindingObserver {
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
  
  // Face detection instance - only for mobile platforms
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
        _feedbackMessage = 'Quyền truy cập camera là cần thiết cho đăng ký khuôn mặt.';
      });
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_isCameraInitialized) {
      await _cameraController.dispose();
    }
    
    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium, // Thay đổi từ high sang medium để tăng hiệu suất
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
        _feedbackMessage = 'Lỗi khởi tạo camera: $e';
        _isCameraInitialized = false;
      });
      print('Lỗi khởi tạo camera: $e');
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

      // Đảm bảo đang sử dụng đúng camera
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

      // Xử lý khuôn mặt đầu tiên được phát hiện
      final Face face = faces.first;
      
      // Lấy góc xoay của khuôn mặt
      final double? headEulerAngleX = face.headEulerAngleX;
      final double? headEulerAngleY = face.headEulerAngleY;
      final double? headEulerAngleZ = face.headEulerAngleZ;
      
      // Các giá trị này chỉ khác null khi sử dụng ML Kit face detector
      if (headEulerAngleX != null && headEulerAngleY != null && headEulerAngleZ != null) {
        if (mounted) {
          setState(() {
            _currentAngleX = headEulerAngleX;
            _currentAngleY = headEulerAngleY;
            _currentAngleZ = headEulerAngleZ;
          });
          
          // Xác định hướng khuôn mặt dựa trên góc
          _determineFacePose(headEulerAngleX, headEulerAngleY, headEulerAngleZ);

          // Chụp khuôn mặt nếu ở đúng vị trí và góc này chưa được chụp
          _autoCaptureFaceIfReady();
        }
      }
    } catch (e) {
      // Xử lý lỗi không gây crash
      print('Lỗi khi xử lý khuôn mặt: $e');
    } finally {
      _processingImage = false;
    }
  }
  
  void _determineFacePose(double angleX, double angleY, double angleZ) {
    // Xác định ngưỡng cho các hướng khác nhau
    const double frontThreshold = 15.0;
    const double sideThreshold = 25.0;
    const double verticalThreshold = 15.0;

    // Xác định hướng
    String pose = 'unknown';
    
    // Kiểm tra mặt thẳng trước tiên
    if (angleX.abs() < frontThreshold && 
        angleY.abs() < frontThreshold && 
        angleZ.abs() < frontThreshold) {
      pose = 'front';
    }
    // Kiểm tra mặt trái/phải
    else if (angleY.abs() > sideThreshold) {
      pose = angleY > 0 ? 'right' : 'left';
    }
    // Kiểm tra mặt ngửa/cúi
    else if (angleX.abs() > verticalThreshold) {
      pose = angleX > 0 ? 'down' : 'up';  // Trục X bị đảo ngược với góc mặt
    }
    
    if (mounted) {
      setState(() {
        _currentDetectedPose = pose;
        _updateCurrentCaptureDirectionBasedOnPose(pose);
      });
    }
  }

  void _autoCaptureFaceIfReady() {
    // Chỉ tiến hành nếu chế độ tự động đang bật và không trong quá trình chụp
    if (!_isAutoCaptureActive || _isCapturing || _isCompleted || !mounted) {
      return;
    }

    // Kiểm tra nếu hướng hiện tại trùng với hướng cần và chưa được chụp
    if (_currentDetectedPose != 'unknown' && 
        _currentDetectedPose != 'no_face' &&
        !_capturedAngles[_currentDetectedPose]!) {
      
      // Bắt đầu quá trình chụp
      _captureImage();
    }
  }
  
  void _updateCurrentCaptureDirectionBasedOnPose(String detectedPose) {
    // Cập nhật hướng cần chụp dựa trên hướng khuôn mặt phát hiện được
    // và các góc còn thiếu
    if (detectedPose != 'unknown' && detectedPose != 'no_face' && !_capturedAngles[detectedPose]!) {
      _currentCaptureDirection = detectedPose;
    } else {
      // Nếu góc đã được chụp hoặc không xác định,
      // tìm góc tiếp theo chưa được chụp
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
      _feedbackMessage = 'Vui lòng đặt khuôn mặt của bạn ở vị trí ${_getDirectionInVietnamese(_webDirections[_webCurrentDirection]).toLowerCase()}';
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

  // Bắt đầu quá trình chụp tự động
  void _startAutoCapture() {
    if (!_isCameraInitialized || _isCompleted) {
      return;
    }
    
    setState(() {
      _isAutoCaptureActive = true;
      _feedbackMessage = 'Chụp tự động đang hoạt động. Hãy đặt khuôn mặt của bạn theo hướng dẫn.';
    });
    
    // For web platform, use simulation instead of ML Kit
    if (kIsWeb) {
      _startWebSimulation();
    }
  }

  // Dừng quá trình chụp tự động
  void _stopAutoCapture() {
    _webSimulationTimer?.cancel();
    
    setState(() {
      _isAutoCaptureActive = false;
      _feedbackMessage = 'Đã tạm dừng chụp tự động.';
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
      _feedbackMessage = 'Đang chụp ảnh...';
    });

    try {
      // Tạm dừng dòng hình ảnh để chụp ảnh chất lượng cao (chỉ trên mobile)
      if (!kIsWeb) {
        await _cameraController.stopImageStream();
      }
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final XFile file = await _cameraController.takePicture();
      
      if (!mounted) return;
      
      // Bắt đầu lại dòng hình ảnh (chỉ trên mobile)
      if (!kIsWeb) {
        await _cameraController.startImageStream(_processCameraImage);
      }
      
      setState(() {
        _faceCaptures[_currentCaptureDirection] = file;
        _capturedAngles[_currentCaptureDirection] = true;
        _feedbackMessage = 'Chụp ảnh thành công!';
        
        // Kiểm tra xem đã chụp đủ các góc chưa
        if (_getMissingAngles().isEmpty) {
          _isCompleted = true;
          _isAutoCaptureActive = false;
          _webSimulationTimer?.cancel();
        } else {
          _feedbackMessage = 'Vui lòng đặt khuôn mặt của bạn cho góc tiếp theo.';
        }
      });
    } catch (e) {
      print('Lỗi khi chụp ảnh: $e');
      
      try {
        // Khởi động lại stream khi lỗi (chỉ trên mobile)
        if (!kIsWeb && !_cameraController.value.isStreamingImages && mounted) {
          await _cameraController.startImageStream(_processCameraImage);
        }
      } catch (streamError) {
        print('Lỗi khởi động lại stream: $streamError');
      }
      
      if (mounted) {
        setState(() {
          _feedbackMessage = 'Lỗi khi chụp ảnh: $e';
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
        _feedbackMessage = 'Đang tải dữ liệu lên máy chủ...';
      });

      try {
        // Tạo yêu cầu multipart
        var request = http.MultipartRequest('POST', Uri.parse(_apiEndpoint));
        
        // Thêm dữ liệu nhân viên
        request.fields['employeeId'] = _employeeIdController.text;
        request.fields['name'] = _nameController.text;
        
        // Thêm hình ảnh khuôn mặt - xử lý khác nhau cho web và mobile
        for (var direction in _faceCaptures.keys) {
          final file = _faceCaptures[direction]!;
          if (file.path.isNotEmpty) {
            // Đối với web, cần đọc trực tiếp bytes vì file path không hoạt động
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
              // Đối với mobile, có thể sử dụng file path
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
        
        // Gửi yêu cầu
        final response = await request.send();
        
        if (response.statusCode == 201) {
          setState(() {
            _feedbackMessage = 'Đăng ký hoàn tất thành công!';
            _isProcessing = false;
          });
          
          // Hiển thị hộp thoại hoàn thành
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
    _captureTimer?.cancel();
    _webSimulationTimer?.cancel();
    _stopAutoCapture();
    _webCurrentDirection = 0;
    
    // Khởi động lại stream nếu đã dừng (chỉ trên mobile)
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
                Navigator.of(context).pop(); // Trở lại trang chọn ngôn ngữ
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
        instruction = 'Xoay mặt của bạn từ từ sang trái';
        icon = Icons.arrow_back;
        break;
      case 'right':
        instruction = 'Xoay mặt của bạn từ từ sang phải';
        icon = Icons.arrow_forward;
        break;
      case 'up':
        instruction = 'Ngước mặt của bạn từ từ lên trên';
        icon = Icons.arrow_upward;
        break;
      case 'down':
        instruction = 'Cúi mặt của bạn từ từ xuống dưới';
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
          'Góc: ${_getDirectionInVietnamese(_currentCaptureDirection)} (${_getCaptureProgress()})',
          style: const TextStyle(color: Colors.white),
        ),
        if (_isAutoCaptureActive && _currentDetectedPose == _currentCaptureDirection)
          const Text(
            'Tuyệt vời! Giữ nguyên tư thế...',
            style: TextStyle(
              color: Colors.green,
              fontSize: 16.0,
              fontWeight: FontWeight.bold,
            ),
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
      case 'down': return 'DƯỚI';
      default: return direction.toUpperCase();
    }
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
          // Biểu mẫu thông tin nhân viên
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
          
          // Phần xem trước camera và chụp ảnh
          Expanded(
            child: Container(
              color: Colors.black,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_isCameraInitialized)
                    CameraPreview(_cameraController),
                  
                  // Hướng dẫn khung khuôn mặt
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
                  
                  // Hướng dẫn chụp
                  Positioned(
                    top: 20,
                    child: _buildCaptureFeedbackWidget(),
                  ),
                  
                  // Thông tin debug về góc khuôn mặt (chỉ hiển thị trên thiết bị di động)
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
                              'Nhận diện: ${_getDetectedPoseInVietnamese(_currentDetectedPose)}',
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
                  
                  // Thêm thông báo cho web
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
                              'CHẾ ĐỘ WEB',
                              style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Vui lòng di chuyển khuôn mặt khi nhận hướng dẫn',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  
                  // Thông báo phản hồi
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
                    
                  // Danh sách các góc đã chụp và cần chụp
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
                            'Trạng thái chụp:',
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
                                  _getDirectionInVietnamese(entry.key),
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
          
          // Các nút hành động
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
                          label: const Text('Dừng Chụp Tự Động'),
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
                          label: const Text('Bắt Đầu Chụp Tự Động'),
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
  
  String _getDetectedPoseInVietnamese(String pose) {
    switch (pose) {
      case 'front': return 'Thẳng';
      case 'left': return 'Trái';
      case 'right': return 'Phải';
      case 'up': return 'Trên';
      case 'down': return 'Dưới';
      case 'no_face': return 'Không có mặt';
      case 'unknown': return 'Không xác định';
      default: return pose;
    }
  }
}