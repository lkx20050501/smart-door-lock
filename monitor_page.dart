// lib/monitor_page.dart - 人脸检测记录页面 (V4修复版)
// 修复: 使用手机本地时间，不依赖K230发送的时间戳

import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'image_item_model.dart';

class MonitorPage extends StatefulWidget {
  final String baseUrl;
  const MonitorPage({super.key, required this.baseUrl});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> with WidgetsBindingObserver {
  String doorStatus = "未知";
  String faceRecogStatus = "等待中";
  double threshold = 0.65;
  Timer? _statusTimer;
  Timer? _imageTimer;

  List<ImageItem> _images = [];
  Box<ImageItem>? _imageBox;
  String _debugInfo = "";

  // 用于去重：记录上一张图片的哈希值
  int? _lastImageHash;

  // 防止请求堆积
  bool _isStatusFetching = false;
  bool _isImageFetching = false;

  // 连接状态
  bool _isConnected = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initHive();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _stopPolling();
    } else if (state == AppLifecycleState.resumed) {
      _startPolling();
    }
  }

  void _stopPolling() {
    _statusTimer?.cancel();
    _imageTimer?.cancel();
    _statusTimer = null;
    _imageTimer = null;
  }

  Future<void> _initHive() async {
    try {
      _imageBox = await Hive.openBox<ImageItem>('face_images');
      _loadImages();
      _startPolling();
    } catch (e) {
      debugPrint('Hive初始化错误: $e');
    }
  }

  void _loadImages() {
    if (_imageBox != null) {
      setState(() {
        _images = _imageBox!.values.toList();
        _images.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      });
    }
  }

  void _startPolling() {
    _stopPolling();

    // 立即执行一次
    _fetchStatus();

    // 状态轮询 - 每2秒
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!_isStatusFetching && mounted) {
        _fetchStatus();
      }
    });

    // 图片轮询 - 每2秒，延迟1秒开始
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        _fetchFaceImage();
        _imageTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
          if (!_isImageFetching && mounted) {
            _fetchFaceImage();
          }
        });
      }
    });
  }

  Future<void> _fetchStatus() async {
    if (_isStatusFetching) return;
    _isStatusFetching = true;

    try {
      final recogResp = await http
          .get(Uri.parse('${widget.baseUrl}/face_recog'))
          .timeout(const Duration(seconds: 3));

      if (recogResp.statusCode == 200 && mounted) {
        final data = json.decode(recogResp.body);
        setState(() {
          int result = data['result'] ?? 0;
          String name = data['name'] ?? '';
          double score = (data['score'] ?? 0.0).toDouble();
          threshold = (data['threshold'] ?? 0.65).toDouble();
          _isConnected = true;

          if (result == 1) {
            faceRecogStatus = '✅ 识别成功: $name (${(score * 100).toStringAsFixed(0)}%)';
          } else if (result == 2) {
            faceRecogStatus = '⚠️ 未知人脸 (${(score * 100).toStringAsFixed(0)}%)';
          } else {
            faceRecogStatus = '⏳ 等待识别...';
          }
        });
      }

      final statusResp = await http
          .get(Uri.parse('${widget.baseUrl}/status'))
          .timeout(const Duration(seconds: 3));

      if (statusResp.statusCode == 200 && mounted) {
        final data = json.decode(statusResp.body);
        setState(() {
          String status = data['status'] ?? '';
          doorStatus = (status == 'open') ? '🟢 已开启' : '🔴 已关闭';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnected = false;
        });
      }
    } finally {
      _isStatusFetching = false;
    }
  }

  Future<void> _fetchFaceImage() async {
    if (_isImageFetching) return;
    _isImageFetching = true;

    try {
      final response = await http
          .get(Uri.parse('${widget.baseUrl}/face_image'))
          .timeout(const Duration(seconds: 5));

      if (!mounted) return;

      final contentType = response.headers['content-type'] ?? '';

      if (response.statusCode == 200 && contentType.contains('image')) {
        // 获取自定义头信息（只需要识别结果，不需要时间戳）
        String resultStr = response.headers['x-face-result'] ?? '0';
        String name = response.headers['x-face-name'] ?? '';
        String scoreStr = response.headers['x-face-score'] ?? '0';

        int result = int.tryParse(resultStr) ?? 0;
        double score = double.tryParse(scoreStr) ?? 0.0;

        // 使用手机本地时间
        DateTime imageTime = DateTime.now();

        // 获取图片数据
        final Uint8List imageData = response.bodyBytes;

        // 验证JPEG数据
        bool isValidJpeg = imageData.length > 500 &&
            imageData[0] == 0xFF &&
            imageData[1] == 0xD8;

        // 计算图片哈希用于去重（简单使用长度+前几个字节）
        int currentHash = imageData.length;
        if (imageData.length > 100) {
          for (int i = 0; i < 100; i += 10) {
            currentHash = currentHash * 31 + imageData[i];
          }
        }

        // 检查是否为新图片（通过哈希值判断）
        bool isNewImage = _lastImageHash == null || currentHash != _lastImageHash;

        if (mounted) {
          setState(() {
            _debugInfo = "大小: ${imageData.length}B, 有效: $isValidJpeg, 新图: $isNewImage";
          });
        }

        // 只保存有效的新图片
        if (isNewImage && result > 0 && isValidJpeg) {
          _lastImageHash = currentHash;

          final imageItem = ImageItem(
            imageData: imageData,
            timestamp: imageTime,  // 使用手机本地时间
            result: result,
            name: name,
            score: score,
          );

          await _imageBox?.add(imageItem);
          _loadImages();

          debugPrint('[图片] 保存成功: ${imageData.length}B, result=$result, name=$name, time=$imageTime');
        }
      } else if (response.statusCode == 200) {
        // JSON响应（no_face等）
        try {
          final data = json.decode(response.body);
          if (mounted) {
            setState(() {
              _debugInfo = "状态: ${data['status'] ?? 'unknown'}";
            });
          }
        } catch (e) {
          // 忽略解析错误
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _debugInfo = "获取图片失败";
        });
      }
    } finally {
      _isImageFetching = false;
    }
  }

  Future<void> _clearAllImages() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有检测记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );

    if (confirm == true && _imageBox != null) {
      await _imageBox!.clear();
      _lastImageHash = null;
      _loadImages();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空所有记录')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('检测记录'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clearAllImages,
            tooltip: '清空记录',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _fetchStatus();
              _fetchFaceImage();
            },
            tooltip: '刷新',
          ),
        ],
      ),
      body: Column(
        children: [
          // 状态面板
          Container(
            padding: const EdgeInsets.all(12),
            color: _isConnected ? Colors.blue[50] : Colors.red[50],
            child: Column(
              children: [
                // 连接状态
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isConnected ? Icons.wifi : Icons.wifi_off,
                      color: _isConnected ? Colors.green : Colors.red,
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isConnected ? '已连接' : '连接断开',
                      style: TextStyle(
                        fontSize: 12,
                        color: _isConnected ? Colors.green : Colors.red,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 门状态和识别状态
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            const Text('门状态', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text(
                              doorStatus,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            const Text('识别状态', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text(
                              faceRecogStatus,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // 调试信息
                if (_debugInfo.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _debugInfo,
                      style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                    ),
                  ),
              ],
            ),
          ),

          // 图片网格标题
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '检测记录 (${_images.length})',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  '阈值: ${(threshold * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),

          // 图片网格
          Expanded(
            child: _images.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.photo_library_outlined, size: 80, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  Text(
                    '暂无检测记录',
                    style: TextStyle(fontSize: 18, color: Colors.grey[500]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '当检测到人脸时会自动保存',
                    style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                  ),
                ],
              ),
            )
                : RefreshIndicator(
              onRefresh: () async {
                _fetchStatus();
                _fetchFaceImage();
              },
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.75,
                ),
                itemCount: _images.length,
                itemBuilder: (context, index) {
                  final item = _images[index];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ImageDetailPage(
                            item: item,
                            onDelete: _loadImages,
                          ),
                        ),
                      );
                    },
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.memory(
                                  item.imageData,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      color: Colors.grey[200],
                                      child: const Icon(Icons.broken_image, size: 40, color: Colors.grey),
                                    );
                                  },
                                ),
                                Positioned(
                                  top: 8,
                                  left: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: item.isRecognized
                                          ? Colors.green.withOpacity(0.9)
                                          : Colors.orange.withOpacity(0.9),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      item.isRecognized ? '已识别' : '未知',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.all(8),
                            color: item.isRecognized ? Colors.green[50] : Colors.orange[50],
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.isRecognized ? item.name : '未知人脸',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: item.isRecognized ? Colors.green[800] : Colors.orange[800],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${(item.score * 100).toStringAsFixed(1)}%',
                                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${item.timestamp.month}/${item.timestamp.day} '
                                      '${item.timestamp.hour.toString().padLeft(2, '0')}:'
                                      '${item.timestamp.minute.toString().padLeft(2, '0')}',
                                  style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 图片详情页
class ImageDetailPage extends StatelessWidget {
  final ImageItem item;
  final VoidCallback? onDelete;

  const ImageDetailPage({super.key, required this.item, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('图片详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => _deleteImage(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: Image.memory(
                  item.imageData,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.broken_image, size: 80, color: Colors.grey),
                        const SizedBox(height: 16),
                        Text(
                          '图片加载失败',
                          style: TextStyle(color: Colors.grey[400], fontSize: 18),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '数据大小: ${item.imageData.length} bytes',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: item.isRecognized ? Colors.green : Colors.orange,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item.resultText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('置信度', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                      Text(
                        '${(item.score * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: item.score,
                      backgroundColor: Colors.grey[700],
                      valueColor: AlwaysStoppedAnimation(item.isRecognized ? Colors.green : Colors.orange),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('检测时间', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                      Text(
                        '${item.timestamp.year}/${item.timestamp.month}/${item.timestamp.day} '
                            '${item.timestamp.hour.toString().padLeft(2, '0')}:'
                            '${item.timestamp.minute.toString().padLeft(2, '0')}:'
                            '${item.timestamp.second.toString().padLeft(2, '0')}',
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('图片大小', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                      Text(
                        '${(item.imageData.length / 1024).toStringAsFixed(1)} KB',
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteImage(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这张图片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await item.delete();
      onDelete?.call();
      if (context.mounted) {
        Navigator.pop(context);
      }
    }
  }
}