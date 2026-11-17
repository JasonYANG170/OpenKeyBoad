import 'models.dart';

List<List<int>> macroEntries(Profile profile) {
  final result = <List<int>>[], bytes = profile.macros;
  if (bytes == null) throw StateError('请先从键盘读取宏存储。');
  var start = 0;
  for (var i = 0; i < bytes.length && result.length < profile.macroCount; i++) {
    if (bytes[i] == 0) {
      result.add(bytes.sublist(start, i));
      start = i + 1;
    }
  }
  if (result.length != profile.macroCount) {
    throw const FormatException('现有宏数据不完整，请先备份配置。');
  }
  return result;
}

Profile assignChord(
  Profile original,
  int layer,
  int index,
  List<int> down, {
  int? encoder,
}) {
  final values = down.toSet().toList();
  if (values.isEmpty ||
      values.length > 14 ||
      values.where((code) => code < 0xe0).length > 6 ||
      values.any((code) => code < 4 || code > 0xe7)) {
    throw const FormatException('组合键最多支持 6 个普通键和 8 个左右修饰键。');
  }
  final entries = macroEntries(original);
  final used = {
    ...original.keys.expand((v) => v),
    ...original.encoders.expand((v) => v),
  };
  var target = -1;
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].isEmpty && !used.contains(0x7700 + i)) {
      target = i;
      break;
    }
  }
  if (target < 0) throw StateError('没有空闲宏槽，请在其他 VIA 工具整理后重新读取。');
  entries[target] = [
    for (final code in values) ...[1, 2, code],
    for (final code in values.reversed) ...[1, 3, code],
  ];
  final buffer = [
    for (final entry in entries) ...[...entry, 0],
  ];
  if (buffer.length >= original.macros!.length) throw StateError('键盘的宏存储空间不足。');
  buffer.addAll(List.filled(original.macros!.length - buffer.length, 0));
  return original
      .withMacros(buffer, original.macroCount)
      .withKey(
        layer,
        encoder ?? index,
        0x7700 + target,
        encoder: encoder != null,
      );
}
