// Shared with the standalone Dart package, which has no Flutter dependencies.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../lib/hid.dart';
import '../lib/models.dart';
import '../lib/via.dart';

Future<void> main(List<String> args) async {
  try {
    await _run(args);
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

Future<void> _run(List<String> args) async {
  final here = File(Platform.resolvedExecutable).parent.path;
  final webIndex = File('$here/web/index.html');
  final web = webIndex.existsSync()
      ? '$here/web'
      : Directory('build/web').existsSync()
      ? 'build/web'
      : '../build/web';
  final assetRoot = Directory('$web/assets/assets').existsSync()
      ? '$web/assets/assets'
      : Directory('assets').existsSync()
      ? 'assets'
      : '../assets';
  final boards = [
    for (final id in ['rs2', 'ak650'])
      Board.fromJson(
        jsonDecode(await File('$assetRoot/$id.json').readAsString()) as Json,
      ),
  ];
  final service = DesktopService(boards);
  if (args.contains('--probe')) {
    for (final device in await service.scan()) {
      final profile = await service.read(device);
      stdout.writeln(
        '${device.label}  ${profile.keys.length} 层 · ${profile.keys.first.length} 键位 · RGB 灯效 ${profile.light.effect}',
      );
    }
    return;
  }
  if (!File('$web/index.html').existsSync()) {
    throw StateError('找不到 Flutter 网页资源，请先运行 flutter build web。');
  }
  final lan = args.contains('--lan');
  final random = Random.secure();
  final token = base64Url
      .encode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
  final server = await HttpServer.bind(
    lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
    0,
  );
  final links = ['http://127.0.0.1:${server.port}/#$token'];
  if (lan) {
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final address in interface.addresses.where(_privateIp)) {
        links.add('http://${address.address}:${server.port}/#$token');
      }
    }
  }
  stdout.writeln('键盘控制台\n${links.join('\n')}\n关闭此窗口可断开手机连接。');
  if (!args.contains('--no-browser')) {
    final command = Platform.isWindows
        ? 'rundll32.exe'
        : Platform.isMacOS
        ? 'open'
        : 'xdg-open';
    final arguments = [
      if (Platform.isWindows) 'url.dll,FileProtocolHandler',
      links.first,
    ];
    try {
      await Process.start(command, arguments, mode: ProcessStartMode.detached);
    } on ProcessException {
      /* The printed link is still available. */
    }
  }

  var busy = false;
  await for (final request in server) {
    // Dispatch promptly so a long USB operation never stalls static files.
    Future<void>(() async {
      final response = request.response;
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      try {
        if (!_privateIp(request.connectionInfo!.remoteAddress)) {
          return _json(response, 403, {'error': '仅开放本机与局域网访问。'});
        }
        final path = request.uri.pathSegments;
        if (path.isNotEmpty && path.first == 'api') {
          response.headers.set('Cache-Control', 'no-store');
          if (request.headers.value('Authorization') != 'Bearer $token') {
            return _json(response, 401, {'error': '需要有效的连接链接。'});
          }
          // Network/media requests must not hold the keyboard's USB transaction lock.
          if (request.method == 'GET' && request.uri.path == '/api/weather') {
            final city = request.uri.queryParameters['city']?.trim() ?? '';
            if (city.isEmpty || city.length > 100) {
              throw const FormatException('请输入有效城市名。');
            }
            return _json(response, 200, await service.weather(city));
          }
          if (request.method == 'GET' &&
              request.uri.path == '/api/now-playing') {
            return _json(response, 200, await service.nowPlaying());
          }
          if (request.method == 'POST' && request.uri.path == '/api/lyrics') {
            return _json(
              response,
              200,
              await service.lyrics(await _readBody(request)),
            );
          }
          if (busy) return _json(response, 409, {'error': '键盘正在处理另一项操作。'});
          busy = true;
          try {
            if (request.method == 'GET' && request.uri.path == '/api/devices') {
              _json(response, 200, {
                'devices': (await service.scan())
                    .map((item) => item.toJson())
                    .toList(),
              });
            } else if (request.method == 'GET' &&
                request.uri.path == '/api/metrics') {
              _json(response, 200, {'values': await service.metrics()});
            } else if (path.length == 4 &&
                path[1] == 'companion' &&
                request.method == 'POST') {
              final board = boards.firstWhere((board) => board.id == path[2]);
              final device = DeviceRef(path[3], board.id, board.name);
              final body = await _readBody(request);
              final packets = (body['packets'] as List)
                  .map((p) => (p as List).cast<int>())
                  .toList();
              validatePackets(packets);
              _json(response, 200, {
                'packets': await service.companion(device, packets),
              });
            } else if (path.length == 4 &&
                path[1] == 'profile' &&
                (request.method == 'GET' || request.method == 'POST')) {
              final board = boards.firstWhere((board) => board.id == path[2]);
              final device = DeviceRef(path[3], board.id, board.name);
              if (request.method == 'GET') {
                _json(response, 200, (await service.read(device)).toJson());
              } else {
                final body = <int>[];
                await for (final chunk in request.timeout(
                  const Duration(seconds: 5),
                )) {
                  if (body.length + chunk.length > 65536) {
                    throw const FormatException('配置文件过大。');
                  }
                  body.addAll(chunk);
                }
                final profile = jsonDecode(utf8.decode(body)) as Json;
                final before = Profile.fromJson(
                  board,
                  profile['before'] as Json,
                );
                final after = Profile.fromJson(board, profile['after'] as Json);
                _json(
                  response,
                  200,
                  (await service.apply(device, before, after)).toJson(),
                );
              }
            } else {
              _json(response, 404, {'error': '未知接口。'});
            }
          } finally {
            busy = false;
          }
        } else if (request.method == 'GET') {
          await _static(web, path, response);
        } else {
          _json(response, 405, {'error': '请求方式不受支持。'});
        }
      } catch (error) {
        try {
          _json(response, 400, {'error': error.toString()});
        } on StateError {
          // The client disconnected after headers were sent.
        }
      } finally {
        try {
          await response.close();
        } on IOException {
          // An interrupted client must not stop the bridge.
        }
      }
    });
  }
}

Future<Json> _readBody(HttpRequest request) async {
  final bytes = <int>[];
  await for (final chunk in request.timeout(const Duration(seconds: 8))) {
    if (bytes.length + chunk.length > 65536) {
      throw const FormatException('请求数据过大。');
    }
    bytes.addAll(chunk);
  }
  return jsonDecode(utf8.decode(bytes)) as Json;
}

bool _privateIp(InternetAddress address) {
  final ip = address.rawAddress;
  return address.isLoopback ||
      (ip.length == 4 &&
          (ip[0] == 10 ||
              (ip[0] == 192 && ip[1] == 168) ||
              (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31)));
}

void _json(HttpResponse response, int code, Json body) {
  response.statusCode = code;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
}

Future<void> _static(
  String web,
  List<String> segments,
  HttpResponse response,
) async {
  final parts = segments.where((value) => value.isNotEmpty).toList();
  if (parts.any(
    (part) =>
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part) ||
        part == '.' ||
        part == '..',
  )) {
    return _json(response, 404, {'error': '文件不存在。'});
  }
  final path = parts.isEmpty ? 'index.html' : parts.join('/');
  final file = File('$web/$path');
  if (!await file.exists()) return _json(response, 404, {'error': '文件不存在。'});
  final type = switch (path.split('.').last) {
    'html' => 'text/html',
    'js' || 'mjs' => 'text/javascript',
    'json' => 'application/json',
    'wasm' => 'application/wasm',
    'css' => 'text/css',
    'png' => 'image/png',
    'woff2' => 'font/woff2',
    'ttf' => 'font/ttf',
    _ => 'application/octet-stream',
  };
  response.headers.set('Content-Type', type);
  response.headers.set('Cache-Control', 'no-cache');
  await response.addStream(file.openRead());
}
