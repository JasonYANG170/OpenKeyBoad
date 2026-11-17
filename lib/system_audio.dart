import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'audio_analysis.dart';
import 'models.dart';

/// A leased system-output capture worker, shared by native and bridge clients.
/// It keeps no recording and shuts down if the client closes or stops polling.
class SystemAudio {
  Process? _process;
  Future<void>? _starting;
  Timer? _lease;
  int _generation = 0;
  final _analyzer = AudioAnalysis();
  List<int> _tail = [];
  final _clock = Stopwatch()..start();
  Duration _received = Duration.zero;
  DateTime? _failed;
  String _status = '正在启动系统声音采集…';
  bool _captureReady = false;

  Future<Json> read(bool enabled) async {
    if (!enabled) {
      _stop();
      return {'supported': true, 'ready': false};
    }
    if (!Platform.isWindows && !Platform.isLinux) {
      return {
        'supported': false,
        'status': '系统声音律动目前支持 Windows 和 Linux；其他客户端可通过桌面端连接链接使用。',
      };
    }
    _lease?.cancel();
    _lease = Timer(const Duration(seconds: 4), _stop);
    if (_process == null &&
        _starting == null &&
        (_failed == null ||
            DateTime.now().difference(_failed!).inSeconds >= 3)) {
      _starting = _start(_generation).whenComplete(() => _starting = null);
    }
    if (_process == null ||
        _received == Duration.zero ||
        _clock.elapsed - _received > const Duration(milliseconds: 350)) {
      return {
        'supported': true,
        'ready': _process != null && _captureReady,
        'level': 0,
        'bands': List.filled(8, 0),
        'status': _status,
      };
    }
    return _analyzer.frame(Platform.isWindows ? _rate : 44100);
  }

  int _rate = 48000;
  Future<void> _start(int epoch) async {
    try {
      final script = _windowsCapture.replaceAll('__PARENT__', '$pid');
      final bytes = <int>[
        for (final c in script.codeUnits) ...[c & 255, c >> 8],
      ];
      final process = Platform.isWindows
          ? await Process.start('powershell.exe', [
              '-NoProfile',
              '-NonInteractive',
              '-EncodedCommand',
              base64Encode(bytes),
            ])
          : await Process.start('parec', [
              '--device=@DEFAULT_MONITOR@',
              '--format=float32le',
              '--rate=44100',
              '--channels=1',
            ]);
      if (epoch != _generation) {
        process.kill();
        return;
      }
      _process = process;
      _captureReady = false;
      _tail = [];
      _received = Duration.zero;
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('RATE:')) {
              _rate = int.tryParse(line.substring(5)) ?? 48000;
            }
            if (line == 'READY') _captureReady = true;
          });
      process.stdout.listen((chunk) {
        if (_process != process) return;
        final bytes = Uint8List.fromList([..._tail, ...chunk]);
        final length = bytes.length - bytes.length % 4;
        final view = ByteData.sublistView(bytes);
        for (var i = 0; i < length; i += 4) {
          _analyzer.add(view.getFloat32(i, Endian.little));
        }
        _tail = bytes.sublist(length);
        _received = _clock.elapsed;
      });
      unawaited(
        process.exitCode.then((code) {
          if (_process != process) return;
          _process = null;
          _failed = DateTime.now();
          _status = Platform.isLinux
              ? '无法采集系统声音，请确认已安装 PulseAudio/PipeWire 的 parec。'
              : '声音设备已变化或采集失败，正在自动重试。';
        }),
      );
    } catch (_) {
      _failed = DateTime.now();
      _status = '系统声音采集不可用；Linux 需安装 parec。';
    }
  }

  void _stop() {
    ++_generation;
    _lease?.cancel();
    _lease = null;
    final process = _process;
    _process = null;
    process?.kill();
    _received = Duration.zero;
    _captureReady = false;
    _tail = [];
  }
}

const _windowsCapture = r'''
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMEnumerator {}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMEnumerator {
 int EnumAudioEndpoints(int flow,uint mask,out IntPtr devices);
 [PreserveSig] int GetDefaultAudioEndpoint(int flow,int role,out IMMDevice device);
 int GetDevice(string id,out IMMDevice device);
 int Register(IntPtr callback); int Unregister(IntPtr callback);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
 [PreserveSig] int Activate(ref Guid id,uint context,IntPtr parameters,[MarshalAs(UnmanagedType.IUnknown)] out object result);
 int OpenPropertyStore(uint access,out IntPtr store);
 [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
 int GetState(out uint state);
}
[ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioClient {
 [PreserveSig] int Initialize(int mode,uint flags,long duration,long periodicity,IntPtr format,IntPtr session);
 int GetBufferSize(out uint frames); int GetStreamLatency(out long latency); int GetCurrentPadding(out uint padding);
 int IsFormatSupported(int mode,IntPtr format,out IntPtr closest);
 [PreserveSig] int GetMixFormat(out IntPtr format);
 int GetDevicePeriod(out long normal,out long minimum);
 [PreserveSig] int Start(); [PreserveSig] int Stop(); int Reset(); int SetEventHandle(IntPtr handle);
 [PreserveSig] int GetService(ref Guid id,[MarshalAs(UnmanagedType.IUnknown)] out object service);
}
[ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICapture {
 [PreserveSig] int GetBuffer(out IntPtr data,out uint frames,out uint flags,out ulong device,out ulong qpc);
 [PreserveSig] int ReleaseBuffer(uint frames);
 [PreserveSig] int GetNextPacketSize(out uint frames);
}
public static class OutputCapture {
 static void Check(int code){Marshal.ThrowExceptionForHR(code);}
 public static void Run(int parentId) {
  IMMEnumerator enumerator=null; IMMDevice device=null; IAudioClient client=null; ICapture capture=null; IntPtr format=IntPtr.Zero;
  try {
   enumerator=(IMMEnumerator)new MMEnumerator(); Check(enumerator.GetDefaultAudioEndpoint(0,0,out device));
   Guid cid=new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"); object obj;
   Check(device.Activate(ref cid,23,IntPtr.Zero,out obj)); client=(IAudioClient)obj;
   Check(client.GetMixFormat(out format));
   int tag=(ushort)Marshal.ReadInt16(format,0), channels=(ushort)Marshal.ReadInt16(format,2);
   int rate=Marshal.ReadInt32(format,4), align=(ushort)Marshal.ReadInt16(format,12), bits=(ushort)Marshal.ReadInt16(format,14);
   if(tag==65534){ if((ushort)Marshal.ReadInt16(format,16)<22)throw new Exception("Invalid audio format");tag=(ushort)Marshal.ReadInt16(format,24); }
   if(channels<1||channels>32||align<channels*(bits/8)||!((tag==3&&bits==32)||(tag==1&&(bits==16||bits==24||bits==32)))) throw new Exception("Unsupported mix format");
   Console.Error.WriteLine("RATE:"+rate);
   Check(client.Initialize(0,0x20000,1000000,0,format,IntPtr.Zero));
   Guid capid=new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");Check(client.GetService(ref capid,out obj));capture=(ICapture)obj;
   Check(client.Start()); Console.Error.WriteLine("READY"); Stream output=Console.OpenStandardOutput(); var parent=Process.GetProcessById(parentId);
   var clock=Stopwatch.StartNew(); long lastDeviceCheck=0; string originalId; device.GetId(out originalId);
   while(!parent.HasExited){
    if(clock.ElapsedMilliseconds-lastDeviceCheck>2000){
     lastDeviceCheck=clock.ElapsedMilliseconds; IMMDevice current; Check(enumerator.GetDefaultAudioEndpoint(0,0,out current));
     try {string currentId;current.GetId(out currentId);if(currentId!=originalId)break;} finally{Marshal.ReleaseComObject(current);}
    }
    uint size;Check(capture.GetNextPacketSize(out size));
    while(size>0){
     IntPtr data;uint frames,flags;ulong pos,qpc;Check(capture.GetBuffer(out data,out frames,out flags,out pos,out qpc));
     try{
      if(frames>rate*2)throw new Exception("Audio buffer too large");
      byte[] source=new byte[frames*align];if((flags&2)==0)Marshal.Copy(data,source,0,source.Length);
      float[] mono=new float[frames];
      if((flags&2)==0)for(int i=0;i<frames;i++){
       double sample=0;for(int c=0;c<channels;c++){int p=i*align+c*(bits/8);
        if(tag==3)sample+=BitConverter.ToSingle(source,p);
        else if(bits==16)sample+=BitConverter.ToInt16(source,p)/32768.0;
        else if(bits==32)sample+=BitConverter.ToInt32(source,p)/2147483648.0;
        else {int v=source[p]|(source[p+1]<<8)|(source[p+2]<<16);if((v&0x800000)!=0)v|=unchecked((int)0xff000000);sample+=v/8388608.0;}
       }mono[i]=(float)(sample/channels);
      }
      byte[] packed=new byte[mono.Length*4];Buffer.BlockCopy(mono,0,packed,0,packed.Length);output.Write(packed,0,packed.Length);output.Flush();
     }finally{Check(capture.ReleaseBuffer(frames));}
     Check(capture.GetNextPacketSize(out size));
    }Thread.Sleep(10);
   }
  }finally{
   if(client!=null)client.Stop(); if(format!=IntPtr.Zero)Marshal.FreeCoTaskMem(format);
   if(capture!=null)Marshal.ReleaseComObject(capture);if(client!=null)Marshal.ReleaseComObject(client);if(device!=null)Marshal.ReleaseComObject(device);if(enumerator!=null)Marshal.ReleaseComObject(enumerator);
  }
 }
}
'@
[OutputCapture]::Run(__PARENT__)
''';
