import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_settings.dart';
import 'models.dart';

int compareVersions(String a, String b) {
  List<int> parts(String s) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$').firstMatch(s);
    if (match == null) throw FormatException('无法识别版本：$s');
    return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  final left = parts(a), right = parts(b);
  for (var i = 0; i < 3; i++) {
    final order = left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return 0;
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url);
  final String name;
  final Uri url;
}

class GitHubRelease {
  GitHubRelease(this.repo, this.tag, this.page, this.published, this.assets);
  final String repo, tag;
  final Uri page;
  final DateTime? published;
  final List<ReleaseAsset> assets;
  ReleaseAsset? asset(String name) =>
      assets.where((a) => a.name == name).firstOrNull;
}

class FirmwareUpdate {
  const FirmwareUpdate({
    required this.model,
    required this.version,
    required this.release,
    required this.download,
    this.layout,
    this.sha256,
  });
  final String model, version;
  final GitHubRelease release;
  final ReleaseAsset download;
  final ReleaseAsset? layout;
  final String? sha256;
}

class UpdateCenter extends ChangeNotifier {
  UpdateCenter({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  GitHubRelease? appRelease;
  String? appVersion;
  final firmware = <String, FirmwareUpdate>{};
  final errors = <String, String>{};
  bool checking = false;
  DateTime? checkedAt;
  bool _disposed = false;
  static const owner = 'JasonYANG170';
  static const appRepo = 'OpenKeyBoad';
  static const firmwareRepos = {
    'rs2': 'JamesDonkey-RS2-QMK',
    'ak650': 'AJAZZ-AK650-QMK',
  };

  Future<String?> _text(Uri uri, {bool optional = false}) async {
    final response = await _client
        .get(uri, headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (optional && response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw StateError('GitHub 请求额度暂时不足，请稍后再试。');
      }
      throw StateError('更新服务器返回 ${response.statusCode}。');
    }
    if (response.bodyBytes.length > 2 * 1024 * 1024) {
      throw StateError('更新信息过大。');
    }
    return utf8.decode(response.bodyBytes);
  }

  Uri _raw(GitHubRelease r, String path) => Uri.https(
    'raw.githubusercontent.com',
    '/$owner/${r.repo}/${r.tag}/$path',
  );
  Future<GitHubRelease> _release(String repo) async {
    final raw = await _text(
      Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest'),
    );
    final json = jsonDecode(raw!) as Json;
    if (json['draft'] == true || json['prerelease'] == true) {
      throw StateError('没有稳定版发布。');
    }
    final tag = json['tag_name'];
    if (tag is! String ||
        tag.isEmpty ||
        tag.contains('/') ||
        tag.contains('..')) {
      throw StateError('发布标签不受支持。');
    }
    final assets = <ReleaseAsset>[];
    for (final value in (json['assets'] as List? ?? [])) {
      final name = value['name'], link = value['browser_download_url'];
      if (name is! String || link is! String) continue;
      final uri = Uri.tryParse(link);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          uri.pathSegments.length != 6 ||
          uri.pathSegments[0] != owner ||
          uri.pathSegments[1] != repo ||
          uri.pathSegments[2] != 'releases' ||
          uri.pathSegments[3] != 'download' ||
          uri.pathSegments[4] != tag ||
          uri.pathSegments[5] != name) {
        continue;
      }
      assets.add(ReleaseAsset(name, uri));
    }
    return GitHubRelease(
      repo,
      tag,
      Uri.https('github.com', '/$owner/$repo/releases/tag/$tag'),
      DateTime.tryParse(json['published_at'] as String? ?? ''),
      assets,
    );
  }

  Future<void> _application() async {
    final release = await _release(appRepo);
    final pubspec = await _text(_raw(release, 'pubspec.yaml'));
    final version = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$',
      multiLine: true,
    ).firstMatch(pubspec!)?.group(1);
    if (version == null) throw StateError('发布未提供有效的上位机版本。');
    compareVersions(version, version);
    appRelease = release;
    appVersion = version;
    // The tag pins both metadata and checksums to the released source snapshot.
    final sums = await _text(
      _raw(release, 'firmware/SHA256SUMS'),
      optional: true,
    );
    if (sums != null) _firmwareFromSums(release, sums, bundle: true);
  }

  void _firmwareFromSums(
    GitHubRelease release,
    String text, {
    required bool bundle,
    String? modelFilter,
  }) {
    final entries = <String, String>{};
    for (final line in text.split('\n')) {
      final match = RegExp(r'^([a-fA-F0-9]{64})\s+\*?([^/\\\s]+)\s*$')
          .firstMatch(line);
      if (match != null) {
        entries[match.group(2)!] = match.group(1)!.toLowerCase();
      }
    }
    for (final model in ['rs2', 'ak650']) {
      if (modelFilter != null && model != modelFilter) continue;
      final prefix = model == 'rs2' ? 'RS2' : 'AK650';
      for (final name in entries.keys) {
        final match = RegExp('^$prefix-VIA-(\\d+\\.\\d+\\.\\d+)\\.bin\$')
            .firstMatch(name);
        if (match == null) continue;
        final version = match.group(1)!;
        final download =
            release.asset(name) ??
            (bundle ? release.asset('OpenKeyBoad-Firmware.zip') : null);
        if (download == null) continue;
        final current = firmware[model];
        if (current != null &&
            (compareVersions(current.version, version) > 0 ||
                (compareVersions(current.version, version) == 0 &&
                    (current.release.repo == appRepo ||
                        release.repo != appRepo)))) {
          continue;
        }
        firmware[model] = FirmwareUpdate(
          model: model,
          version: version,
          release: release,
          download: download,
          layout: release.asset(name.replaceFirst('.bin', '.json')),
          sha256: entries[name],
        );
      }
    }
  }

  Future<void> _keyboard(String model, String repo) async {
    final release = await _release(repo);
    final sums = await _text(_raw(release, 'firmware/SHA256SUMS'));
    _firmwareFromSums(release, sums!, bundle: false, modelFilter: model);
  }

  Future<void> check({AppSettings? settings}) async {
    if (checking) return;
    checking = true;
    errors.clear();
    notifyListeners();
    final tasks = <String, Future<void> Function()>{
      '上位机': _application,
      for (final entry in firmwareRepos.entries)
        entry.value: () => _keyboard(entry.key, entry.value),
    };
    await Future.wait(
      tasks.entries.map((entry) async {
        try {
          await entry.value();
        } catch (error) {
          errors[entry.key] = error.toString().replaceFirst('Bad state: ', '');
        }
      }),
    );
    checkedAt = DateTime.now();
    checking = false;
    if (settings != null && errors.isEmpty) {
      settings.lastUpdateCheck = checkedAt;
      await settings.save();
    }
    if (!_disposed) notifyListeners();
  }

  List<ReleaseAsset> get clientDownloads =>
      appRelease?.assets
          .where(
            (a) =>
                !a.name.contains('Firmware') &&
                RegExp(r'\.(zip|tar\.gz|apk|ipa)$').hasMatch(a.name),
          )
          .toList() ??
      [];
  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}

String packageLabel(String name) => switch (name) {
  'OpenKeyBoad-Windows-native-x64.zip' => 'Windows x64 原生桌面版',
  'OpenKeyBoad-Windows-x64.zip' => 'Windows x64 网页控制台',
  'OpenKeyBoad-linux-x86_64.tar.gz' => 'Linux x64',
  'OpenKeyBoad-macos-x86_64.tar.gz' => 'macOS Intel',
  'OpenKeyBoad-Android.apk' => 'Android APK',
  'OpenKeyBoad-iOS-unsigned.ipa' => 'iOS IPA（需自行签名）',
  'OpenKeyBoad-Web.zip' => 'Web 控制台',
  _ => name,
};
