// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'image_item_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ImageItemAdapter extends TypeAdapter<ImageItem> {
  @override
  final int typeId = 0;

  @override
  ImageItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ImageItem(
      imageData: fields[0] as Uint8List,
      timestamp: fields[1] as DateTime,
      result: fields[2] as int? ?? 0,
      name: fields[3] as String? ?? '',
      score: fields[4] as double? ?? 0.0,
    );
  }

  @override
  void write(BinaryWriter writer, ImageItem obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.imageData)
      ..writeByte(1)
      ..write(obj.timestamp)
      ..writeByte(2)
      ..write(obj.result)
      ..writeByte(3)
      ..write(obj.name)
      ..writeByte(4)
      ..write(obj.score);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
          other is ImageItemAdapter &&
              runtimeType == other.runtimeType &&
              typeId == other.typeId;
}