import 'dart:convert';

typedef Json = Map<String, dynamic>;
const consoleVersion = '0.4.0';

int bounded(dynamic value, int max, String field) {
  if (value is! int || value < 0 || value > max) {
    throw FormatException('无效的字段：$field');
  }
  return value;
}

class KeyPosition {
  const KeyPosition(
    this.row,
    this.column,
    this.x,
    this.y,
    this.width,
    this.height,
    this.label,
    this.encoder,
  );

  factory KeyPosition.fromJson(Json value) {
    final matrix = value['matrix'] as List;
    return KeyPosition(
      matrix[0] as int,
      matrix[1] as int,
      (value['x'] as num).toDouble(),
      (value['y'] as num).toDouble(),
      (value['w'] as num?)?.toDouble() ?? 1,
      (value['h'] as num?)?.toDouble() ?? 1,
      value['label'] as String?,
      value['encoder'] != null,
    );
  }

  final int row, column;
  final double x, y, width, height;
  final String? label;
  final bool encoder;
}

class Board {
  Board.fromJson(Json data)
    : id = data['id'] as String,
      name = data['name'] as String,
      vid = data['vid'] as int,
      pid = data['pid'] as int,
      rows = data['rows'] as int,
      cols = data['cols'] as int,
      keys = (data['keys'] as List)
          .cast<Json>()
          .map(KeyPosition.fromJson)
          .toList(),
      defaults = (data['default_layers'] as List)
          .map((v) => (v as List).cast<int>())
          .toList(),
      custom = (data['custom'] as Json).map(
        (k, v) => MapEntry(int.parse(k), v as String),
      ),
      effects = (data['effects'] as List).cast<String>();

  final String id, name;
  final int vid, pid, rows, cols;
  final List<KeyPosition> keys;
  final List<List<int>> defaults;
  final Map<int, String> custom;
  final List<String> effects;

  int get layers => defaults.length;
  String get usbId => '${hex(vid)}:${hex(pid)}';
  Profile preview() => Profile(
    id,
    defaults.map(List<int>.of).toList(),
    List.generate(layers, (_) => [0x00aa, 0x00a9]),
    const Lighting(130, 1, 115, 150, 210),
  );
}

String hex(int value) => value.toRadixString(16).padLeft(4, '0').toUpperCase();

class Lighting {
  const Lighting(
    this.brightness,
    this.effect,
    this.speed,
    this.hue,
    this.saturation,
  );
  factory Lighting.fromJson(Json value) => Lighting(
    bounded(value['brightness'], 255, 'brightness'),
    bounded(value['effect'], 255, 'effect'),
    bounded(value['speed'], 255, 'speed'),
    bounded(value['hue'], 255, 'hue'),
    bounded(value['saturation'], 255, 'saturation'),
  );

  final int brightness, effect, speed, hue, saturation;
  Json toJson() => {
    'brightness': brightness,
    'effect': effect,
    'speed': speed,
    'hue': hue,
    'saturation': saturation,
  };
  Lighting copyWith({
    int? brightness,
    int? effect,
    int? speed,
    int? hue,
    int? saturation,
  }) => Lighting(
    brightness ?? this.brightness,
    effect ?? this.effect,
    speed ?? this.speed,
    hue ?? this.hue,
    saturation ?? this.saturation,
  );
}

class Profile {
  Profile(
    this.model,
    List<List<int>> keys,
    List<List<int>> encoders,
    this.light, {
    List<int>? macros,
    this.macroCount = 0,
  }) : keys = List.unmodifiable(keys.map(List<int>.unmodifiable)),
       encoders = List.unmodifiable(encoders.map(List<int>.unmodifiable)),
       macros = macros == null ? null : List.unmodifiable(macros);

  factory Profile.fromJson(Board board, Json json) {
    if (json['format'] != 1 || json['model'] != board.id) {
      throw const FormatException('配置格式或键盘型号不匹配。');
    }
    List<List<int>> readMatrix(String field, int columns) {
      final rows = json[field];
      if (rows is! List || rows.length != board.layers) {
        throw FormatException('配置的 $field 层数不匹配。');
      }
      return rows.map((row) {
        if (row is! List || row.length != columns) {
          throw FormatException('配置的 $field 键位数量不匹配。');
        }
        return row.map((entry) => bounded(entry, 0xffff, field)).toList();
      }).toList();
    }

    final light = json['lighting'];
    if (light is! Json) throw const FormatException('缺少灯光配置。');
    return Profile(
      board.id,
      readMatrix('keys', board.keys.length),
      readMatrix('encoders', 2),
      Lighting.fromJson(light),
      macros: json['macros'] == null
          ? null
          : (json['macros'] as List)
                .map((v) => bounded(v, 255, 'macros'))
                .toList(),
      macroCount: json['macroCount'] == null
          ? 0
          : bounded(json['macroCount'], 32, 'macroCount'),
    );
  }

  final String model;
  final List<List<int>> keys, encoders;
  final Lighting light;
  final List<int>? macros;
  final int macroCount;
  Json toJson() => {
    'format': 1,
    'model': model,
    'keys': keys,
    'encoders': encoders,
    'lighting': light.toJson(),
    if (macros != null) 'macros': macros,
    if (macros != null) 'macroCount': macroCount,
  };
  String get serialized => jsonEncode(toJson());
  Profile withKey(int layer, int index, int value, {bool encoder = false}) {
    final matrix = (encoder ? encoders : keys).map(List<int>.of).toList();
    matrix[layer][index] = value;
    return Profile(
      model,
      encoder ? keys : matrix,
      encoder ? matrix : encoders,
      light,
      macros: macros,
      macroCount: macroCount,
    );
  }

  Profile withLight(Lighting value) => Profile(
    model,
    keys,
    encoders,
    value,
    macros: macros,
    macroCount: macroCount,
  );
  Profile withMacros(List<int>? bytes, int count) =>
      Profile(model, keys, encoders, light, macros: bytes, macroCount: count);
}

class DeviceRef {
  const DeviceRef(this.id, this.model, this.label);
  factory DeviceRef.fromJson(Json json) => DeviceRef(
    json['id'] as String,
    json['model'] as String,
    json['label'] as String,
  );
  final String id, model, label;
  Json toJson() => {'id': id, 'model': model, 'label': label};
}

abstract interface class KeyboardService {
  Future<List<DeviceRef>> scan();
  Future<Profile> read(DeviceRef device);
  Future<Profile> apply(DeviceRef device, Profile before, Profile after);
  Future<List<List<int>>> companion(DeviceRef device, List<List<int>> packets);
  Future<List<int>> metrics();
  Future<Json> nowPlaying();
  Future<Json> lyrics(Json track);
  Future<Json> weather(String city);
}

abstract interface class OnlineHostService {
  Future<Json> network();
  Future<Json> audio(bool enabled);
}

extension OnlineHost on KeyboardService {
  Future<Json> hostNetwork() => this is OnlineHostService
      ? (this as OnlineHostService).network()
      : Future.value({'supported': false});
  Future<Json> systemAudio(bool enabled) => this is OnlineHostService
      ? (this as OnlineHostService).audio(enabled)
      : Future.value({
          'supported': false,
          'status': '请通过 Windows / Linux 桌面端连接链接使用系统声音律动。',
        });
}
