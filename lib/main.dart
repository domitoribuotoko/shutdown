// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:wake_on_lan/wake_on_lan.dart';

// =============================================================================
// НАСТРОЙКИ (вшиты константами)
// =============================================================================

/// IP-адрес вашего ПК в локальной сети (например, 192.168.1.100)
const String kPcIp = '192.168.31.94';

/// Широковещательный адрес для WoL (обычно тот же IP, но последний октет 255)
const String kBroadcastIp = '192.168.31.255';

/// MAC-адрес сетевой карты ПК (в формате "AA:BB:CC:DD:EE:FF")
const String kPcMac = '70:85:C2:DA:3D:A3';

/// UDP-порт, на котором слушает сервер на ПК (Python-скрипт принимает команду "SHUTDOWN").
/// По этому порту только отправляется команда выключения, проверка «включён ли ПК» — по kTcpCheckPort.
const int kUdpPort = 9999;

/// TCP-порт для проверки «включён ли ПК» (доступность хоста). Например 445 (SMB) или 80 (HTTP).
const int kTcpCheckPort = 445;

/// Команда, которую ожидает UDP-сервер (можно дополнить паролем)
const String kShutdownCommand = 'SHUTDOWN';

/// Таймаут для проверки TCP-соединения (в секундах)
const int kConnectTimeout = 3;

// =============================================================================
// ТОП-УРОВНЕВЫЕ ФУНКЦИИ ДЛЯ ВИДЖЕТА (работают без UI, в т.ч. когда приложение закрыто)
// =============================================================================

/// Отправка WoL (без UI). Используется виджетом и экраном.
Future<void> sendWol() async {
  final ipValidation = IPAddress.validate(kBroadcastIp);
  if (!ipValidation.state) {
    print('❌ Ошибка валидации IP: ${ipValidation.error}');
    return;
  }
  final macValidation = MACAddress.validate(kPcMac);
  if (!macValidation.state) {
    print('❌ Ошибка валидации MAC: ${macValidation.error}');
    return;
  }
  final ipAddress = IPAddress(kBroadcastIp);
  final macAddress = MACAddress(kPcMac);
  final wakeOnLan = WakeOnLAN(ipAddress, macAddress);
  try {
    await wakeOnLan.wake();
    print('✅ WoL-пакет успешно отправлен');
  } catch (e) {
    print('❌ Ошибка отправки WoL: $e');
  }
}

/// Отправка UDP-команды выключения (без UI).
Future<void> sendUdpShutdown() async {
  RawDatagramSocket? udpSocket;
  try {
    udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    udpSocket.broadcastEnabled = true;
    final List<int> data = utf8.encode(kShutdownCommand);
    udpSocket.send(data, InternetAddress(kPcIp), kUdpPort);
    print('✅ UDP-команда отправлена');
    await Future.delayed(const Duration(milliseconds: 100));
  } catch (e) {
    print('❌ Ошибка отправки UDP: $e');
  } finally {
    udpSocket?.close();
  }
}

/// Вызывается при нажатии на виджет, даже когда приложение выключено.
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  // Логи для проверки в logcat (фильтр: PC_WIDGET), когда приложение не запущено
  print('[PC_WIDGET] Background callback started, uri=$uri');
  try {
    final status = await HomeWidget.getWidgetData<String>('pc_status', defaultValue: 'off');
    print('[PC_WIDGET] pc_status=$status -> ${status == 'on' ? "отправка UDP shutdown" : "отправка WoL"}');
    if (status == 'on') {
      await sendUdpShutdown();
    } else {
      await sendWol();
    }
    await Future.delayed(const Duration(seconds: 1));
    await HomeWidget.updateWidget(name: 'HomeWidgetProvider');
    print('[PC_WIDGET] Callback finished, widget updated');
  } catch (e, st) {
    print('[PC_WIDGET] ERROR in callback: $e');
    print('[PC_WIDGET] $st');
  }
}

// =============================================================================
// ГЛАВНОЕ ПРИЛОЖЕНИЕ
// =============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HomeWidget.registerBackgroundCallback(widgetBackgroundCallback);
  print('[PC_WIDGET] Background callback registered (tap widget when app closed -> this callback runs)');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PC Remote',
      theme: ThemeData.dark(),
      home: const PcControlScreen(),
    );
  }
}

class PcControlScreen extends StatefulWidget {
  const PcControlScreen({super.key});

  @override
  State<PcControlScreen> createState() => _PcControlScreenState();
}

/// Статус ПК: совпадает с виджетом и нативным кодом.
const String _statusOn = 'on';
const String _statusOff = 'off';
const String _statusPendingWol = 'pending_wol';
const String _statusPendingShutdown = 'pending_shutdown';

class _PcControlScreenState extends State<PcControlScreen> {
  String _pcStatus = _statusOff;
  bool _isLoading = true;
  Timer? _statusTimer;
  /// Для pending_wol: первый опрос через 10 сек, дальше каждые 2 сек
  bool _pendingWolFirstCheck = true;

  static const _widgetSyncChannel = MethodChannel('com.example.shutdowner2/widget_sync');

  @override
  void initState() {
    super.initState();
    _saveWidgetConfig();
    _loadStateFromWidget().then((_) {
      if (mounted) _checkStatusPeriodically();
    });
    HomeWidget.widgetClicked.listen((Uri? uri) {
      _onButtonPressed();
    });
    _widgetSyncChannel.setMethodCallHandler(_onWidgetSyncCall);
  }

  Future<dynamic> _onWidgetSyncCall(MethodCall call) async {
    if (call.method != 'widgetDidTap') return null;
    final status = await HomeWidget.getWidgetData<String>('pc_status', defaultValue: _statusOff);
    if (mounted && status != null) {
      setState(() {
        _pcStatus = status;
        if (status == _statusPendingWol) _pendingWolFirstCheck = true;
      });
      _scheduleNextCheck();
    }
    return null;
  }

  /// Синхронизация с виджетом при старте (читаем то, что мог записать нативный код).
  Future<void> _loadStateFromWidget() async {
    try {
      final status = await HomeWidget.getWidgetData<String>('pc_status', defaultValue: _statusOff);
      if (status != null && mounted) {
        setState(() {
          _pcStatus = status;
          if (status == _statusPendingWol) _pendingWolFirstCheck = true;
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Сохраняет конфиг в виджет (нативный код читает при нажатии и при периодической проверке).
  Future<void> _saveWidgetConfig() async {
    try {
      await HomeWidget.saveWidgetData<String>('pc_ip', kPcIp);
      await HomeWidget.saveWidgetData<String>('broadcast_ip', kBroadcastIp);
      await HomeWidget.saveWidgetData<String>('pc_mac', kPcMac);
      await HomeWidget.saveWidgetData<String>('udp_port', kUdpPort.toString());
      await HomeWidget.saveWidgetData<String>('shutdown_cmd', kShutdownCommand);
      await HomeWidget.saveWidgetData<String>('tcp_check_port', kTcpCheckPort.toString());
      await HomeWidget.saveWidgetData<String>('connect_timeout_sec', kConnectTimeout.toString());
    } catch (e) {
      print('❌ Ошибка сохранения конфига виджета: $e');
    }
  }

  /// Запускает проверку и планирует следующую: WoL — 10 сек первый раз, потом 2 сек; shutdown — без задержки; on/off — 5 сек.
  void _checkStatusPeriodically() {
    _scheduleNextCheck(initial: true);
  }

  void _scheduleNextCheck({bool initial = false}) {
    if (!mounted) return;
    _statusTimer?.cancel();
    Duration delay;
    switch (_pcStatus) {
      case _statusPendingWol:
        delay = _pendingWolFirstCheck ? const Duration(seconds: 10) : const Duration(seconds: 2);
        if (_pendingWolFirstCheck) _pendingWolFirstCheck = false;
        break;
      case _statusPendingShutdown:
        delay = Duration.zero;
        break;
      default:
        delay = const Duration(seconds: 5);
        break;
    }
    void run() async {
      await _checkStatus();
      if (mounted) _scheduleNextCheck();
    }
    if (initial && _pcStatus == _statusPendingWol && _pendingWolFirstCheck) {
      // Первый запрос при ожидании WoL — через 10 сек, не сразу
      _statusTimer = Timer(delay, run);
    } else if (initial) {
      run();
    } else {
      _statusTimer = Timer(delay, run);
    }
  }

  /// Обновляет состояние и виджет (единый источник правды с нативным кодом).
  Future<void> _applyStatus(String status, {int? shutdownFailCount}) async {
    if (!mounted) return;
    setState(() => _pcStatus = status);
    try {
      await HomeWidget.saveWidgetData<String>('pc_status', status);
      if (shutdownFailCount != null) {
        await HomeWidget.saveWidgetData<String>('shutdown_fail_count', shutdownFailCount.toString());
      }
      await HomeWidget.updateWidget(name: 'HomeWidgetProvider');
    } catch (e) {
      print('❌ Ошибка сохранения статуса: $e');
    }
  }

  /// Проверяет доступность ПК по TCP; для pending-режимов обновляет счётчики/результат.
  Future<void> _checkStatus() async {
    bool isOnline;
    try {
      final socket = await Socket.connect(kPcIp, kTcpCheckPort,
          timeout: Duration(seconds: kConnectTimeout));
      socket.destroy();
      isOnline = true;
    } catch (_) {
      isOnline = false;
    }

    switch (_pcStatus) {
      case _statusPendingWol:
        if (isOnline) {
          await _applyStatus(_statusOn);
        }
        break;
      case _statusPendingShutdown:
        final countStr = await HomeWidget.getWidgetData<String>('shutdown_fail_count', defaultValue: '0');
        var failCount = int.tryParse(countStr ?? '0') ?? 0;
        if (isOnline) {
          failCount = 0;
          await _applyStatus(_statusPendingShutdown, shutdownFailCount: 0);
        } else {
          failCount++;
          if (failCount >= 3) {
            await _applyStatus(_statusOff);
          } else {
            await HomeWidget.saveWidgetData<String>('shutdown_fail_count', failCount.toString());
            await HomeWidget.updateWidget(name: 'HomeWidgetProvider');
          }
        }
        break;
      default:
        final newStatus = isOnline ? _statusOn : _statusOff;
        if (_pcStatus != newStatus) await _applyStatus(newStatus);
    }
  }

  /// Отправка Wake-on-LAN (использует общую функцию + показывает SnackBar)
  Future<void> _sendWol() async {
    await sendWol();
    _showSnackBar('WoL-пакет отправлен');
  }

  /// Отправка UDP-команды выключения (использует общую функцию + показывает SnackBar)
  Future<void> _sendUdpShutdown() async {
    await sendUdpShutdown();
    _showSnackBar('Команда выключения отправлена');
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Обработчик нажатия на большую кнопку (логика как у виджета).
  void _onButtonPressed() async {
    if (_isLoading) return;

    switch (_pcStatus) {
      case _statusOn:
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Подтверждение'),
            content: const Text('Вы действительно хотите выключить ПК?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Нет'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Да, выключить'),
              ),
            ],
          ),
        );
        if (confirm != true) return;
        await _sendUdpShutdown();
        await _applyStatus(_statusPendingShutdown, shutdownFailCount: 0);
        _showSnackBar('Команда выключения отправлена, ожидание…');
        _scheduleNextCheck();
        break;

      case _statusOff:
        await _sendWol();
        setState(() => _pendingWolFirstCheck = true);
        await _applyStatus(_statusPendingWol);
        _showSnackBar('WoL отправлен, ожидание включения…');
        _scheduleNextCheck();
        break;

      case _statusPendingWol:
        await _applyStatus(_statusOff);
        _showSnackBar('Ожидание отменено');
        break;

      case _statusPendingShutdown:
        await _applyStatus(_statusOn);
        _showSnackBar('Ожидание отменено');
        break;
    }
  }

  Future<void> _manualCheck() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    await _checkStatus();
    if (mounted) setState(() => _isLoading = false);
    _showSnackBar('Статус обновлён');
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  String _statusTitle() {
    switch (_pcStatus) {
      case _statusOn:
        return 'ПК ВКЛЮЧЁН';
      case _statusOff:
        return 'ПК ВЫКЛЮЧЕН';
      case _statusPendingWol:
        return 'Ожидание включения…';
      case _statusPendingShutdown:
        return 'Ожидание выключения…';
      default:
        return 'ПК ВЫКЛЮЧЕН';
    }
  }

  Color _statusColor() {
    switch (_pcStatus) {
      case _statusOn:
        return Colors.green;
      case _statusOff:
        return Colors.red;
      case _statusPendingWol:
      case _statusPendingShutdown:
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  String _buttonLabel() {
    switch (_pcStatus) {
      case _statusOn:
        return 'ВЫКЛЮЧИТЬ';
      case _statusOff:
        return 'ВКЛЮЧИТЬ';
      case _statusPendingWol:
      case _statusPendingShutdown:
        return 'Ожидание...';
      default:
        return 'ВКЛЮЧИТЬ';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Управление ПК'),
        centerTitle: true,
      ),
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator()
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _statusTitle(),
                    style: TextStyle(fontSize: 24, color: _statusColor()),
                  ),
                  const SizedBox(height: 40),
                  ElevatedButton(
                    onPressed: _onButtonPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _statusColor(),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(200, 200),
                      shape: const CircleBorder(),
                    ),
                    child: Text(
                      _buttonLabel(),
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextButton.icon(
                    onPressed: _isLoading ? null : _manualCheck,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Проверить статус'),
                  ),
                ],
              ),
      ),
    );
  }
}