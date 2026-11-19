import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keyboard_control/models.dart';
import 'package:keyboard_control/updates.dart';

Json release(String repo, List<String> files, {bool poison = false}) => {
  'tag_name': 'build-fixture',
  'draft': false,
  'prerelease': false,
  'published_at': '2026-11-19T00:00:00Z',
  'assets': [
    for (final name in files)
      {
        'name': name,
        'browser_download_url':
            'https://${poison ? "evil.example" : "github.com"}/JasonYANG170/$repo/releases/download/build-fixture/$name',
      },
  ],
};
http.Client fixture({
  bool akFails = false,
  bool poison = false,
  void Function()? hit,
}) => MockClient((request) async {
  hit?.call();
  final p = request.url.pathSegments;
  if (request.url.host == 'api.github.com') {
    final repo = p[2];
    if (akFails && repo == 'AJAZZ-AK650-QMK') return http.Response('', 403);
    return http.Response(
      jsonEncode(
        release(repo, switch (repo) {
          'OpenKeyBoad' => [
            'OpenKeyBoad-Windows-native-x64.zip',
            'OpenKeyBoad-Firmware.zip',
          ],
          'AJAZZ-AK650-QMK' => [
            'AK650-VIA-0.3.5.bin',
            'AK650-VIA-0.3.5.json',
            'RS2-VIA-9.0.0.bin',
          ],
          _ => ['RS2-VIA-0.3.0.bin', 'RS2-VIA-0.3.0.json'],
        }, poison: poison),
      ),
      200,
    );
  }
  expect(request.url.host, 'raw.githubusercontent.com');
  expect(p[2], 'build-fixture');
  if (p.last == 'pubspec.yaml') {
    return http.Response('name: keyboard_control\nversion: 0.5.0+8\n', 200);
  }
  final entries = switch (p[1]) {
    'OpenKeyBoad' => [
      'RS2-VIA-0.3.4.bin',
      'RS2-VIA-0.3.4.json',
      'AK650-VIA-0.3.9.bin',
    ],
    'AJAZZ-AK650-QMK' => ['AK650-VIA-0.3.5.bin', 'RS2-VIA-9.0.0.bin'],
    _ => ['RS2-VIA-0.3.0.bin'],
  };
  return http.Response(
    [for (final file in entries) '${'a' * 64}  $file'].join('\n'),
    200,
  );
});

void main() {
  test('semantic versions and USB versions avoid lexical and BCD mistakes', () {
    expect(compareVersions('0.3.10', '0.3.9'), greaterThan(0));
    expect(compareVersions('v1.2.3', '1.2.3+99'), 0);
    expect(() => compareVersions('build-123', '0.6.0'), throwsFormatException);
    expect(firmwareVersionFromBcd(0x0034), '0.3.4');
    expect(firmwareVersionFromBcd(0x013a), '1.3.10');
    expect(firmwareVersionFromBcd(0), isNull);
    expect(firmwareVersionFromUsbVersion('0.34'), '0.3.4');
    expect(firmwareVersionFromUsbVersion('1.00'), '1.0.0');
    final ref = DeviceRef('fixture', 'rs2', 'RS2', firmwareVersion: '0.3.4');
    expect(DeviceRef.fromJson(ref.toJson()).firmwareVersion, '0.3.4');
  });
  test(
    'newest matching firmware wins across bundled and separate releases',
    () async {
      final center = UpdateCenter(client: fixture());
      addTearDown(center.dispose);
      await center.check();
      expect(center.errors, isEmpty);
      expect(center.appVersion, '0.5.0');
      expect(center.firmware['rs2']!.version, '0.3.4');
      expect(center.firmware['ak650']!.version, '0.3.9');
      expect(center.firmware['rs2']!.download.name, 'OpenKeyBoad-Firmware.zip');
      expect(center.firmware['rs2']!.sha256, 'a' * 64);
      expect(
        center.clientDownloads.single.name,
        'OpenKeyBoad-Windows-native-x64.zip',
      );
    },
  );
  test('a failed repository leaves successful update checks usable', () async {
    final center = UpdateCenter(client: fixture(akFails: true));
    addTearDown(center.dispose);
    await center.check();
    expect(center.errors.keys, ['AJAZZ-AK650-QMK']);
    expect(center.firmware['ak650']!.version, '0.3.9');
    expect(center.appVersion, '0.5.0');
    expect(center.checking, false);
  });
  test('untrusted asset links are not exposed as update downloads', () async {
    final center = UpdateCenter(client: fixture(poison: true));
    addTearDown(center.dispose);
    await center.check();
    expect(center.clientDownloads, isEmpty);
    expect(center.firmware, isEmpty);
  });
  test(
    'concurrent update clicks do not duplicate all repository requests',
    () async {
      var hits = 0;
      final center = UpdateCenter(client: fixture(hit: () => hits++));
      addTearDown(center.dispose);
      await Future.wait([center.check(), center.check()]);
      expect(
        hits,
        7,
      ); // Three releases, three checksum files, one pinned pubspec.
    },
  );
}
