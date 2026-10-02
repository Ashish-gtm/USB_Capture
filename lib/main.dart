import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:uvccamera/uvccamera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(
    MaterialApp(
      title: 'Capture Viewer',
      theme: ThemeData.dark(useMaterial3: true),
      home: const ViewerPage(),
    ),
  );
}

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> with WidgetsBindingObserver {
  final Map<String, UvcCameraDevice> _devices = {};
  UvcCameraDevice? _active;
  UvcCameraController? _controller;
  Future<void>? _init;
  StreamSubscription<UvcCameraDeviceEvent>? _deviceSub;
  StreamSubscription<UvcCameraErrorEvent>? _errorSub;
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;
  Duration _recordingDuration = Duration.zero;
  String _status =
      'Plug in your USB capture card \n Rotate your phone to landscape for better experience';
  bool _showBar = true;
  bool _isRecording = false;
  bool _captureBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable(); // keep screen on while viewing
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _deviceSub?.cancel();
    _closeCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _closeCamera();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _connect(_active ?? (_devices.isEmpty ? null : _devices.values.first));
    }
  }

  void _say(String text) {
    if (mounted) setState(() => _status = text);
  }

  Future<void> _start() async {
    if (!await UvcCamera.isSupported()) {
      _say('This phone does not support USB video (USB host needed).');
      return;
    }
    _deviceSub = UvcCamera.deviceEventStream.listen(_onDeviceEvent);
    final found = await UvcCamera.getDevices();
    if (!mounted) return;
    _devices
      ..clear()
      ..addAll(found);
    if (_devices.isNotEmpty) _connect(_devices.values.first);
  }

  void _onDeviceEvent(UvcCameraDeviceEvent e) {
    final name = e.device.name;
    if (e.type == UvcCameraDeviceEventType.attached) {
      _devices[name] = e.device;
      if (_active == null) _connect(e.device);
    } else if (e.type == UvcCameraDeviceEventType.detached) {
      _devices.remove(name);
      if (_active?.name == name) {
        _closeCamera();
        _active = null;
        _status = 'Capture card unplugged';
      }
    } else if (e.type == UvcCameraDeviceEventType.connected) {
      if (_active?.name == name && _controller == null) _open(e.device);
    } else if (e.type == UvcCameraDeviceEventType.disconnected) {
      if (_active?.name == name) {
        _closeCamera();
        _status = 'Disconnected';
      }
    }
    if (mounted) setState(() {});
  }

  // Ask for Android CAMERA permission, then USB permission.
  // Once granted, the plugin fires a "connected" event and _open() runs.
  Future<void> _connect(UvcCameraDevice? device) async {
    if (device == null) {
      _say('No USB capture card found');
      return;
    }
    _closeCamera();
    _active = device;
    _say('Requesting permissions…');
    final cam = await Permission.camera.request();
    if (!cam.isGranted) {
      _say('Camera permission is required by Android for USB video.');
      return;
    }
    final ok = await UvcCamera.requestDevicePermission(device);
    if (!ok) {
      _say('USB permission denied. Tap refresh to try again.');
      return;
    }
    _say('Connecting…');
  }

  void _open(UvcCameraDevice device) {
    final c = UvcCameraController(
      device: device,
      resolutionPreset: UvcCameraResolutionPreset.high,
    );
    _controller = c;
    _init = c.initialize().then((_) async {
      _errorSub = c.cameraErrorEvents.listen((err) {
        if (err.error.type == UvcCameraErrorType.previewInterrupted) {
          _say('Preview interrupted – reconnecting…');
          _closeCamera();
          _connect(_active);
        }
      });
      if (mounted) setState(() {}); // refresh to show the negotiated size
    });
    setState(() {});
  }

  void _closeCamera() {
    final camera = _controller;
    _errorSub?.cancel();
    _errorSub = null;
    _controller = null;
    _init = null;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingStartedAt = null;
    _recordingDuration = Duration.zero;
    _isRecording = false;
    if (camera != null) unawaited(_disposeCamera(camera));
  }

  Future<void> _disposeCamera(UvcCameraController camera) async {
    try {
      if (camera.value.isRecordingVideo) {
        final video = await camera.stopVideoRecording();
        final saved = await _saveCapture(video.path, 'video', '.mp4');
        _showCaptureMessage('Video saved to Gallery: $saved');
      }
    } catch (error) {
      _showCaptureMessage('Could not finalize recording: $error');
    } finally {
      await camera.dispose();
    }
  }

  Future<void> _refresh() async {
    final found = await UvcCamera.getDevices();
    if (!mounted) return;
    setState(() {
      _devices
        ..clear()
        ..addAll(found);
    });
    final keep = _active == null ? null : found[_active!.name];
    _connect(keep ?? (found.isEmpty ? null : found.values.first));
  }

  Future<String> _saveCapture(
    String sourcePath,
    String prefix,
    String extension,
  ) async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt < 29 &&
          !await Permission.storage.request().isGranted) {
        throw StateError(
          'Storage permission is required to save captures to Gallery.',
        );
      }
    }

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final fileName = '$prefix-$timestamp$extension';
    final result = await SaverGallery.saveFile(
      filePath: sourcePath,
      fileName: fileName,
      albumPath: 'Capture Viewer',
      skipIfExists: false,
    );
    if (!result.isSuccess) {
      throw StateError(
        result.errorMessage ?? 'Gallery did not save the capture.',
      );
    }
    return fileName;
  }

  void _showCaptureMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _capturePhoto() async {
    final camera = _controller;
    if (camera == null ||
        !camera.value.isInitialized ||
        _captureBusy ||
        _isRecording) {
      return;
    }
    setState(() => _captureBusy = true);
    try {
      final photo = await camera.takePicture();
      final saved = await _saveCapture(photo.path, 'photo', '.jpg');
      _showCaptureMessage('Photo saved to Gallery: $saved');
    } catch (error) {
      _showCaptureMessage('Could not capture photo: $error');
    } finally {
      if (mounted) setState(() => _captureBusy = false);
    }
  }

  Future<void> _toggleRecording() async {
    final camera = _controller;
    if (camera == null || !camera.value.isInitialized || _captureBusy) return;
    setState(() => _captureBusy = true);
    try {
      if (_isRecording) {
        final video = await camera.stopVideoRecording();
        if (mounted) setState(() => _isRecording = false);
        _stopRecordingTimer();
        final saved = await _saveCapture(video.path, 'video', '.mp4');
        _showCaptureMessage('Video saved to Gallery: $saved');
      } else {
        final mode = camera.value.previewMode;
        if (mode == null) {
          throw StateError('The camera preview mode is unavailable.');
        }
        await camera.startVideoRecording(mode);
        if (mounted) {
          setState(() {
            _isRecording = true;
            _recordingDuration = Duration.zero;
          });
          _startRecordingTimer();
        }
      }
    } catch (error) {
      _showCaptureMessage('Recording failed: $error');
    } finally {
      if (mounted) setState(() => _captureBusy = false);
    }
  }

  void _startRecordingTimer() {
    _recordingStartedAt = DateTime.now();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startedAt = _recordingStartedAt;
      if (!mounted || startedAt == null || !_isRecording) return;
      setState(() {
        _recordingDuration = DateTime.now().difference(startedAt);
      });
    });
  }

  void _stopRecordingTimer() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingStartedAt = null;
    _recordingDuration = Duration.zero;
  }

  String get _recordingTimeLabel {
    final totalSeconds = _recordingDuration.inSeconds;
    final hours = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showBar = !_showBar),
        child: Stack(
          children: [
            Positioned.fill(child: Center(child: _body())),
            if (_showBar) _topBar(),
            if (_showBar) _bottomAttribution(),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final c = _controller;
    if (c == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.usb, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      );
    }
    return FutureBuilder<void>(
      future: _init,
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            'Could not start preview:\n${snap.error}',
            textAlign: TextAlign.center,
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return const CircularProgressIndicator();
        }
        return UvcCameraPreview(c);
      },
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _active?.name ?? 'USB Capture Viewer',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_devices.length > 1)
                PopupMenuButton<UvcCameraDevice>(
                  icon: const Icon(Icons.switch_video),
                  enabled: !_captureBusy,
                  onSelected: _connect,
                  itemBuilder:
                      (_) => [
                        for (final d in _devices.values)
                          PopupMenuItem(value: d, child: Text(d.name)),
                      ],
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  _resolutionLabel,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reconnect',
                onPressed: _captureBusy ? null : _refresh,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomAttribution() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: false,
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Capture photo',
                onPressed:
                    _controller?.value.isInitialized == true &&
                            !_captureBusy &&
                            !_isRecording
                        ? _capturePhoto
                        : null,
                icon:
                    _captureBusy && !_isRecording
                        ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.photo_camera),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: _isRecording ? 'Stop recording' : 'Start recording',
                onPressed:
                    _controller?.value.isInitialized == true && !_captureBusy
                        ? _toggleRecording
                        : null,
                color: _isRecording ? Colors.redAccent : null,
                icon: Icon(
                  _isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
                ),
              ),
              if (_isRecording)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    _recordingTimeLabel,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              const IgnorePointer(child: Text('Made by Ashish & Claude')),
            ],
          ),
        ),
      ),
    );
  }

  String get _resolutionLabel {
    final mode = _controller?.value.previewMode;
    if (mode != null) return '${mode.frameWidth}x${mode.frameHeight}';
    return '…';
  }
}
