// lib/image_item_model.dart
// 人脸检测图片数据模型

import 'dart:typed_data';
import 'package:hive/hive.dart';

part 'image_item_model.g.dart';

@HiveType(typeId: 0)
class ImageItem extends HiveObject {
  @HiveField(0)
  final Uint8List imageData;

  @HiveField(1)
  final DateTime timestamp;

  @HiveField(2)
  final int result; // 0: 无人脸, 1: 识别成功, 2: 未知人脸

  @HiveField(3)
  final String name; // 识别到的人名

  @HiveField(4)
  final double score; // 置信度

  ImageItem({
    required this.imageData,
    required this.timestamp,
    this.result = 0,
    this.name = '',
    this.score = 0.0,
  });

  /// 获取结果描述
  String get resultText {
    switch (result) {
      case 1:
        return '✅ 识别成功: $name';
      case 2:
        return '⚠️ 未知人脸';
      default:
        return '检测中';
    }
  }

  /// 是否已识别
  bool get isRecognized => result == 1;
}