import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:sound_generator/sound_generator.dart';
import 'package:sound_generator/waveTypes.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'locator.dart';
import 'mesh_service.dart';
import 'native_mesh_service.dart';

class UltrasonicService {
  static final UltrasonicService _instance = UltrasonicService._internal();
  factory UltrasonicService() => _instance;
  UltrasonicService._internal() {
    _setupNativeReceiver();
  }

  static const MethodChannel _channel = MethodChannel('ultrasonic');

  final StreamController<String> _sonarController = StreamController<String>.broadcast();
  Stream<String> get sonarMessages => _sonarController.stream;

  double _freq0 = 17800.0;
  double _freq1 = 18300.0;
  bool _isTransmitting = false;
  bool _isCalibrating = false;
  bool get isTransmitting => _isTransmitting;

  static const _bitDurationMs = 120;
  static const _interFrameGapMs = 300;
  static const _preamble = [0xAA, 0xAA, 0xAC];
  double _currentNoiseFloor = 0.0;

  Future<void> _init() async {
    SoundGenerator.init(44100);
    SoundGenerator.setWaveType(waveTypes.SINUSOIDAL);
    SoundGenerator.setVolume(0.6);
  }

  Future<void> autoCalibrateIfNeeded({bool force = false}) async {
    if (_isCalibrating) return;
    _isCalibrating = true;
    final prefs = await SharedPreferences.getInstance();

    if (!force) {
      final savedF0 = prefs.getDouble('ultra_freq0');
      final savedF1 = prefs.getDouble('ultra_freq1');
      if (savedF0 != null && savedF1 != null) {
        _freq0 = savedF0;
        _freq1 = savedF1;
        _isCalibrating = false;
        return;
      }
    }

    try {
      final dynamic raw = await _channel.invokeMethod('runFrequencySweep');
      final Map<double,double> spectrum = {};
      if (raw is Map) {
        raw.forEach((k,v){
          final key = double.tryParse(k.toString());
          final value = double.tryParse(v.toString());
          if(key != null && value != null) spectrum[key]=value;
        });
      }
      if(spectrum.isEmpty) throw Exception("Empty spectrum");

      // Выбираем частоты: самая тихая + минимальный шум с разносом >400
      final sorted = spectrum.entries.toList()..sort((a,b)=>a.value.compareTo(b.value));
      _freq0 = sorted.first.key;
      _freq1 = sorted.firstWhere((e)=> (e.key - _freq0).abs()>=400, orElse: ()=>sorted.last).key;

      await prefs.setDouble('ultra_freq0', _freq0);
      await prefs.setDouble('ultra_freq1', _freq1);
    } catch (e) {
      _freq0 = 17800.0;
      _freq1 = 18300.0;
    } finally {
      _isCalibrating = false;
    }
  }

  Future<void> transmitFrame(String payload) async {
    if (_isTransmitting) return;
    _isTransmitting = true;
    await _init();

    final data = utf8.encode(payload);
    final frame = [..._preamble, data.length, ...data, _crc8(data)];
    final bits = frame.expand((b)=>List.generate(8,(i)=>(b>>(7-i))&1)).toList();

    final mesh = locator<MeshService>();
    SoundGenerator.play();
    final sw = Stopwatch()..start();
    int lastBitTime=0;
    for(final bit in bits){
      SoundGenerator.setFrequency(bit==1?_freq1:_freq0);
      final wait = lastBitTime+_bitDurationMs-sw.elapsedMilliseconds;
      if(wait>0) await Future.delayed(Duration(milliseconds: wait));
      lastBitTime = sw.elapsedMilliseconds;
    }
    await Future.delayed(Duration(milliseconds: _bitDurationMs));
    SoundGenerator.stop();
    await Future.delayed(Duration(milliseconds: _interFrameGapMs));
    mesh.addLog("✅ Acoustic frame delivered.");
    _isTransmitting=false;
  }

  int _crc8(List<int> data){
    var crc = 0x00;
    for(final b in data){
      crc^=b;
      for(int i=0;i<8;i++){
        crc = (crc & 0x80)!=0?((crc<<1)^0x07):(crc<<1);
        crc &=0xFF;
      }
    }
    return crc;
  }

  Future<void> transmitBeacon() async {
    if(_isTransmitting) return;
    _isTransmitting=true;
    await _init();
    SoundGenerator.setFrequency(_freq1);
    SoundGenerator.play();
    await Future.delayed(Duration(milliseconds: 1000));
    SoundGenerator.stop();
    _isTransmitting=false;
  }

  void handleInboundSignal(String signal){
    if(signal.trim().isEmpty) return;
    _sonarController.add(signal);
  }
  void _setupNativeReceiver() {
    _channel.setMethodCallHandler((call) async {
      if(call.method == 'onSignalDetected') {
        final msg = call.arguments as String;
        handleInboundSignal(msg); // пушим в Stream
      }
    });
  }


  Future<void> startListening() async {
    await autoCalibrateIfNeeded(force:false);
    await NativeMeshService.startSonarListening();
  }

  Future<void> stopListening() async {
    await NativeMeshService.stopSonarListening();
  }

  void stop(){
    SoundGenerator.stop();
    _isTransmitting=false;
  }
}
