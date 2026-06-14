// lib/main.dart - K230智能门禁App (V3修复版)
// 修复: 连接兼容性、防止卡死

import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:hive_flutter/hive_flutter.dart';
import 'upload_face_page.dart';
import 'monitor_page.dart';
import 'image_item_model.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(ImageItemAdapter());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'K230智能门禁',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // K230 IP地址 - 根据实际情况修改
  final String baseUrl = "http://10.196.53.231:8080";
  String doorStatus = "未知";
  String faceRecogStatus = "等待中";
  int faceCount = 0;
  bool isConnected = false;
  Timer? _timer;
  bool _isFetching = false;
  int _errorCount = 0;

  // 环境状态
  double envChipTemp = 0;
  int envLight = 0;
  int envLedDuty = 0;
  String envLedMode = 'auto';
  int envFanDuty = 0;
  String envFanMode = 'auto';
  Timer? _envTimer;
  bool _isEnvFetching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _envTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _timer?.cancel();
      _timer = null;
      _envTimer?.cancel();
      _envTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      _startPolling();
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _envTimer?.cancel();
    _fetchStatus();
    _fetchEnvStatus();
    _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!_isFetching) {
        _fetchStatus();
      }
    });
    _envTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!_isEnvFetching) {
        _fetchEnvStatus();
      }
    });
  }

  Future<void> _fetchStatus() async {
    if (_isFetching) return;
    _isFetching = true;

    try {
      // 获取门状态
      final statusResp = await http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(const Duration(seconds: 3));

      if (statusResp.statusCode == 200) {
        final data = json.decode(statusResp.body);
        if (mounted) {
          setState(() {
            // 兼容 "close" 和 "closed" 两种格式
            String status = data['status'] ?? '';
            doorStatus = (status == 'open') ? '已开启' : '已关闭';
            isConnected = true;
            _errorCount = 0;
          });
        }
      }

      // 获取人脸识别状态
      final recogResp = await http
          .get(Uri.parse('$baseUrl/face_recog'))
          .timeout(const Duration(seconds: 3));

      if (recogResp.statusCode == 200) {
        final data = json.decode(recogResp.body);
        if (mounted) {
          setState(() {
            faceCount = data['face_count'] ?? 0;
            int result = data['result'] ?? 0;
            String name = data['name'] ?? '';
            double score = (data['score'] ?? 0.0).toDouble();

            if (result == 1) {
              faceRecogStatus = '识别成功: $name (${(score * 100).toInt()}%)';
            } else if (result == 2) {
              faceRecogStatus = '检测到未知人脸';
            } else {
              faceRecogStatus = '等待中';
            }
          });
        }
      }
    } catch (e) {
      _errorCount++;
      if (mounted && _errorCount >= 2) {
        setState(() {
          isConnected = false;
          doorStatus = "连接失败";
          faceRecogStatus = "连接失败";
        });
      }
    } finally {
      _isFetching = false;
    }
  }

  Future<void> _controlDoor(String action) async {
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/$action'))
          .timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        if (mounted) {
          String status = data['status'] ?? '';
          setState(() => doorStatus = (status == 'open') ? '已开启' : '已关闭');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('门已${(status == 'open') ? '开启' : '关闭'}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请检查网络连接')),
        );
      }
    }
  }

  Future<void> _clearFaces() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有已注册的人脸吗？'),
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

    if (confirm != true) return;

    try {
      await http
          .get(Uri.parse('$baseUrl/clear_faces'))
          .timeout(const Duration(seconds: 5));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空人脸库')),
        );
      }
      _fetchStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败')),
        );
      }
    }
  }

  // ==================== 环境控制方法 ====================
  Future<void> _fetchEnvStatus() async {
    if (_isEnvFetching) return;
    _isEnvFetching = true;
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/env_status'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200 && mounted) {
        final data = json.decode(resp.body);
        setState(() {
          envChipTemp = (data['chip_temp'] ?? 0).toDouble();
          envLight = data['light'] ?? 0;
          envLedDuty = data['led_duty'] ?? 0;
          envLedMode = data['led_mode'] ?? 'auto';
          envFanDuty = data['fan_duty'] ?? 0;
          envFanMode = data['fan_mode'] ?? 'auto';
        });
      }
    } catch (_) {}
    _isEnvFetching = false;
  }

  Future<void> _ledAction(String action) async {
    try {
      await http.get(Uri.parse('$baseUrl/led/$action')).timeout(const Duration(seconds: 3));
    } catch (_) {}
    _fetchEnvStatus();
  }

  Future<void> _ledSet(int value) async {
    try {
      await http.get(Uri.parse('$baseUrl/led/set?value=$value')).timeout(const Duration(seconds: 3));
    } catch (_) {}
    _fetchEnvStatus();
  }

  Future<void> _fanAction(String action) async {
    try {
      await http.get(Uri.parse('$baseUrl/fan/$action')).timeout(const Duration(seconds: 3));
    } catch (_) {}
    _fetchEnvStatus();
  }

  Future<void> _fanSet(int value) async {
    try {
      await http.get(Uri.parse('$baseUrl/fan/set?value=$value')).timeout(const Duration(seconds: 3));
    } catch (_) {}
    _fetchEnvStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('K230智能门禁'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchStatus,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchStatus,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 连接状态卡片
              Card(
                color: isConnected ? Colors.green[50] : Colors.red[50],
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        isConnected ? Icons.wifi : Icons.wifi_off,
                        color: isConnected ? Colors.green : Colors.red,
                        size: 32,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isConnected ? '已连接' : '未连接',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isConnected ? Colors.green : Colors.red,
                              ),
                            ),
                            Text(
                              baseUrl,
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 状态信息卡片
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // 门状态
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            doorStatus == '已开启' ? Icons.lock_open : Icons.lock,
                            size: 48,
                            color: doorStatus == '已开启' ? Colors.green : Colors.red,
                          ),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('门状态', style: TextStyle(color: Colors.grey)),
                              Text(
                                doorStatus,
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: doorStatus == '已开启' ? Colors.green :
                                  doorStatus == '已关闭' ? Colors.red : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 20),

                      // 识别状态
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.face, size: 40, color: Colors.blue),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('识别状态', style: TextStyle(color: Colors.grey)),
                                Text(
                                  faceRecogStatus,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // 人脸数量
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blue[50],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.people, color: Colors.blue),
                            const SizedBox(width: 8),
                            Text(
                              '已注册人脸: $faceCount / 10',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: Colors.blue,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // 环境监控卡片
              _buildEnvCard(),

              const SizedBox(height: 16),

              // 门控制按钮
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _controlDoor('open'),
                      icon: const Icon(Icons.lock_open),
                      label: const Text('开门'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _controlDoor('close'),
                      icon: const Icon(Icons.lock),
                      label: const Text('关门'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // 功能网格
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.5,
                children: [
                  _buildFeatureCard(
                    icon: Icons.photo_library,
                    title: '检测记录',
                    color: Colors.blue,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => MonitorPage(baseUrl: baseUrl)),
                    ),
                  ),
                  _buildFeatureCard(
                    icon: Icons.person_add,
                    title: '注册人脸',
                    color: Colors.purple,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => UploadFacePage(baseUrl: baseUrl)),
                    ),
                  ),
                  _buildFeatureCard(
                    icon: Icons.people,
                    title: '人脸管理',
                    color: Colors.orange,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => FaceListPage(baseUrl: baseUrl)),
                    ),
                  ),
                  _buildFeatureCard(
                    icon: Icons.delete_sweep,
                    title: '清空人脸',
                    color: Colors.grey,
                    onTap: _clearFaces,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEnvCard() {
    final isLightDark = envLight == 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.thermostat, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                const Text('环境监控', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _fetchEnvStatus,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 温湿度行
            Row(
              children: [
                _envDataChip(Icons.memory, '芯片', '${envChipTemp.toStringAsFixed(1)}°C',
                    envChipTemp > 60 ? Colors.red : Colors.purple),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _envDataChip(Icons.light_mode, '光照', isLightDark ? '暗' : '亮',
                    isLightDark ? Colors.grey : Colors.amber),
              ],
            ),
            const Divider(height: 24),
            // LED 控制
            Row(
              children: [
                Icon(Icons.lightbulb, color: envLedDuty > 0 ? Colors.yellow : Colors.grey, size: 20),
                const SizedBox(width: 8),
                Text('补光LED', style: TextStyle(fontSize: 14, color: Colors.grey[800])),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: envLedMode == 'auto' ? Colors.green[100] : Colors.blue[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(envLedMode == 'auto' ? 'AUTO' : '手动',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                          color: envLedMode == 'auto' ? Colors.green[700] : Colors.blue[700])),
                ),
                const Spacer(),
                Text('${envLedDuty}%', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _envBtn('开', () => _ledAction('on'), Colors.green, envLedMode != 'auto'),
                const SizedBox(width: 6),
                _envBtn('关', () => _ledAction('off'), Colors.red, envLedMode != 'auto'),
                const SizedBox(width: 6),
                _envBtn('自动', () => _ledAction('auto'), Colors.grey, envLedMode != 'auto'),
                const Spacer(),
                if (envLedMode != 'auto')
                  SizedBox(
                    width: 80,
                    child: Slider(
                      value: envLedDuty.toDouble(),
                      min: 0, max: 100, divisions: 10,
                      label: '${envLedDuty}%',
                      onChangeEnd: (v) => _ledSet(v.toInt()),
                      onChanged: (v) => setState(() => envLedDuty = v.toInt()),
                    ),
                  ),
              ],
            ),
            const Divider(height: 20),
            // 风扇控制
            Row(
              children: [
                Icon(Icons.fan, color: envFanDuty > 0 ? Colors.cyan : Colors.grey, size: 20),
                const SizedBox(width: 8),
                Text('散热风扇', style: TextStyle(fontSize: 14, color: Colors.grey[800])),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: envFanMode == 'auto' ? Colors.green[100] : Colors.blue[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(envFanMode == 'auto' ? 'AUTO' : '手动',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                          color: envFanMode == 'auto' ? Colors.green[700] : Colors.blue[700])),
                ),
                const Spacer(),
                Text('${envFanDuty}%', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _envBtn('开', () => _fanAction('on'), Colors.green, envFanMode != 'auto'),
                const SizedBox(width: 6),
                _envBtn('关', () => _fanAction('off'), Colors.red, envFanMode != 'auto'),
                const SizedBox(width: 6),
                _envBtn('自动', () => _fanAction('auto'), Colors.grey, envFanMode != 'auto'),
                const Spacer(),
                if (envFanMode != 'auto')
                  SizedBox(
                    width: 80,
                    child: Slider(
                      value: envFanDuty.toDouble(),
                      min: 0, max: 100, divisions: 10,
                      label: '${envFanDuty}%',
                      onChangeEnd: (v) => _fanSet(v.toInt()),
                      onChanged: (v) => setState(() => envFanDuty = v.toInt()),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _envDataChip(IconData icon, String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
        child: Column(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
            Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }

  Widget _envBtn(String label, VoidCallback onPressed, Color color, bool enabled) {
    return TextButton(
      onPressed: enabled ? onPressed : null,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        backgroundColor: enabled ? color.withOpacity(0.1) : Colors.grey[200],
        foregroundColor: enabled ? color : Colors.grey,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildFeatureCard({
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 36, color: color),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey[800],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 人脸列表管理页面
class FaceListPage extends StatefulWidget {
  final String baseUrl;
  const FaceListPage({super.key, required this.baseUrl});

  @override
  State<FaceListPage> createState() => _FaceListPageState();
}

class _FaceListPageState extends State<FaceListPage> {
  List<String> _faces = [];
  int _faceCount = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFaces();
  }

  Future<void> _loadFaces() async {
    setState(() => _isLoading = true);
    try {
      final response = await http
          .get(Uri.parse('${widget.baseUrl}/face_list'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _faces = List<String>.from(data['faces'] ?? []);
            _faceCount = data['face_count'] ?? 0;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _deleteFace(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除 "$name" 吗？'),
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

    if (confirm != true) return;

    try {
      await http.get(Uri.parse('${widget.baseUrl}/delete_face/$name'))
          .timeout(const Duration(seconds: 5));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除: $name')),
        );
      }
      _loadFaces();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('人脸管理'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadFaces),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _loadFaces,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.blue[50],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.people, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(
                    '已注册人脸: $_faceCount / 10',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _faces.isEmpty
                  ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.face_outlined, size: 80, color: Colors.grey[300]),
                    const SizedBox(height: 16),
                    Text(
                      '暂无注册人脸',
                      style: TextStyle(fontSize: 18, color: Colors.grey[500]),
                    ),
                  ],
                ),
              )
                  : ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _faces.length,
                itemBuilder: (context, index) {
                  final name = _faces[index];
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.blue[100],
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
                        ),
                      ),
                      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
                      subtitle: Text('ID: ${index + 1}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteFace(name),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}