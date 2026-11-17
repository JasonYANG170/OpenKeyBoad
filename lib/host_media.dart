import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Read-only integration with the host's media session. No keyboard I/O here.
class HostMedia {
  Future<Json>? _pending;
  Json _last = {};
  DateTime _sampled = DateTime.fromMillisecondsSinceEpoch(0);

  Future<Json> current() async {
    if (DateTime.now().difference(_sampled).inMilliseconds < 1200) return _last;
    if (_pending != null) return _pending!;
    _pending = _read();
    try {
      _last = await _pending!;
      _sampled = DateTime.now();
      return _last;
    } finally {
      _pending = null;
    }
  }

  Future<Json> _read() async {
    if (Platform.isWindows) {
      final bytes = <int>[];
      for (final c in _windows.codeUnits) {
        bytes.add(c & 255);
        bytes.add(c >> 8);
      }
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          base64Encode(bytes),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 12));
      if (result.exitCode != 0) throw StateError('无法读取 Windows 系统媒体会话。');
      final value = jsonDecode((result.stdout as String).trim()) as Json;
      if (value['playing'] == true && value['updated'] is num) {
        final extra =
            (DateTime.now().millisecondsSinceEpoch -
                    (value['updated'] as num).toInt())
                .clamp(0, 86400000);
        final position = (value['position'] as num).toInt() + extra;
        final duration = (value['duration'] as num).toInt();
        value['position'] = duration > 0
            ? position.clamp(0, duration)
            : position;
      }
      return value;
    }
    if (Platform.isLinux) {
      try {
        // playerctl selects the active MPRIS player and exposes microsecond positions.
        final values = await Future.wait([
          Process.run('playerctl', [
            'metadata',
            '--format',
            '{{title}}\u001f{{artist}}\u001f{{album}}\u001f{{mpris:length}}',
          ]),
          Process.run('playerctl', ['position']),
          Process.run('playerctl', ['status']),
        ]).timeout(const Duration(seconds: 5));
        if (values.any((r) => r.exitCode != 0)) return {};
        final fields = (values[0].stdout as String).trim().split('\u001f');
        if (fields.length != 4) return {};
        return {
          'title': fields[0],
          'artist': fields[1],
          'album': fields[2],
          'duration': ((double.tryParse(fields[3]) ?? 0) / 1000).round(),
          'position':
              ((double.tryParse((values[1].stdout as String).trim()) ?? 0) *
                      1000)
                  .round(),
          'playing': (values[2].stdout as String).trim() == 'Playing',
        };
      } on ProcessException {
        throw StateError('Linux 系统歌词需要安装 playerctl，并使用支持 MPRIS 的播放器。');
      }
    }
    if (Platform.isMacOS) {
      final result = await Process.run('osascript', [
        '-l',
        'JavaScript',
        '-e',
        _mac,
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) {
        throw StateError('请允许控制台读取 Music / Spotify 的播放信息。');
      }
      return jsonDecode((result.stdout as String).trim()) as Json;
    }
    throw StateError('请通过桌面端连接链接跟随电脑的系统音乐。');
  }
}

const _mac = r'''
function run(){
  var ids=['com.spotify.client','com.apple.Music'];var paused={};
  for(var i=0;i<ids.length;i++){
    var app=Application(ids[i]);if(!app.running())continue;
    try{var track=app.currentTrack();var playing=app.playerState()==='playing';
      var data={title:track.name(),artist:track.artist(),album:track.album(),
        position:Math.round(app.playerPosition()*1000),duration:Math.round(track.duration()*(i===0?1:1000)),playing:playing};
      if(playing)return JSON.stringify(data);paused=data;
    }catch(e){}
  }return JSON.stringify(paused);
}
''';
const _windows = r'''
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null=[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$null=[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties,Windows.Media.Control,ContentType=WindowsRuntime]
function Wait-WinRt($operation,$type) {
  $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $task=$method.MakeGenericMethod($type).Invoke($null,@($operation))
  if(!$task.Wait(4000)){ throw 'Media session timeout' };return $task.Result
}
$manager=Wait-WinRt ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$session=$manager.GetCurrentSession()
if(!$session){ Write-Output '{}';exit }
$media=Wait-WinRt ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
$timeline=$session.GetTimelineProperties();$play=$session.GetPlaybackInfo()
@{title=$media.Title;artist=$media.Artist;album=$media.AlbumTitle;position=[long]($timeline.Position-$timeline.StartTime).TotalMilliseconds;duration=[long]($timeline.EndTime-$timeline.StartTime).TotalMilliseconds;playing=($play.PlaybackStatus.ToString() -eq 'Playing');updated=$timeline.LastUpdatedTime.ToUnixTimeMilliseconds();source=$session.SourceAppUserModelId} | ConvertTo-Json -Compress
''';
