// lib/upload_face_page.dart - 人脸注册页面 (V4简化版)
// 只保留K230摄像头注册方式

import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class UploadFacePage extends StatefulWidget {
  final String baseUrl;

  const UploadFacePage({super.key, required this.baseUrl});

  @override
  State<UploadFacePage> createState() => _UploadFacePageState();
}

class _UploadFacePageState extends State<UploadFacePage> {
  bool _isLoading = false;
  String? _statusMessage;
  bool _isSuccess = false;
  int _faceCount = 0;

  @override
  void initState() {
    super.initState();
    _fetchFaceCount();
  }

  // 获取当前人脸数量
  Future<void> _fetchFaceCount() async {
    try {
      final response = await http
          .get(Uri.parse('${widget.baseUrl}/face_list'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() {
          _faceCount = data['face_count'] ?? 0;
        });
      }
    } catch (e) {
      // 忽略错误
    }
  }

  // 从K230摄像头注册
  Future<void> _registerFromK230Camera() async {
    setState(() {
      _isLoading = true;
      _statusMessage = '正在从K230摄像头注册...\n请站在摄像头前，确保只有一人';
      _isSuccess = false;
    });

    try {
      final response = await http.get(
        Uri.parse('${widget.baseUrl}/register'),
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _isLoading = false;
          if (data['status'] == 'ok') {
            _statusMessage = '✅ ${data['message']}';
            _isSuccess = true;
            _faceCount = data['face_count'] ?? _faceCount;
          } else {
            _statusMessage = '❌ ${data['message']}';
            _isSuccess = false;
          }
        });
      } else {
        throw Exception('服务器错误: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = '注册失败: $e';
          _isSuccess = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('注册人脸'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchFaceCount,
            tooltip: '刷新',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 当前人脸数量
            Card(
              color: Colors.blue[50],
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.people, color: Colors.blue, size: 28),
                    const SizedBox(width: 12),
                    Text(
                      '已注册人脸: $_faceCount / 10',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // K230摄像头注册
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // 图标
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: Colors.blue[100],
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.videocam,
                        color: Colors.blue,
                        size: 40,
                      ),
                    ),

                    const SizedBox(height: 16),

                    const Text(
                      'K230摄像头注册',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      '请站在K230摄像头前\n确保画面中只有一人，面部清晰可见',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),

                    const SizedBox(height: 24),

                    // 注册按钮
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _registerFromK230Camera,
                        icon: _isLoading
                            ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                            : const Icon(Icons.face, size: 24),
                        label: Text(
                          _isLoading ? '注册中...' : '开始注册',
                          style: const TextStyle(fontSize: 18),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // 状态消息
            if (_statusMessage != null)
              Card(
                color: _isSuccess ? Colors.green[50] : Colors.orange[50],
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        _isSuccess ? Icons.check_circle : Icons.info,
                        color: _isSuccess ? Colors.green : Colors.orange,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _statusMessage!,
                          style: TextStyle(
                            color: _isSuccess ? Colors.green[800] : Colors.orange[800],
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 24),

            // 提示卡片
            Card(
              color: Colors.grey[100],
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.lightbulb, color: Colors.amber, size: 20),
                        SizedBox(width: 8),
                        Text(
                          '注册提示',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildTip(Icons.person, '确保画面中只有一张人脸'),
                    _buildTip(Icons.wb_sunny, '光线充足，避免逆光'),
                    _buildTip(Icons.face, '面部正对摄像头'),
                    _buildTip(Icons.visibility_off, '不要遮挡面部（眼镜、口罩等）'),
                    _buildTip(Icons.storage, '最多可注册10张人脸'),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 说明文字
            Text(
              '人脸注册后，系统将自动识别并开门',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTip(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[700],
              ),
            ),
          ),
        ],
      ),
    );
  }
}