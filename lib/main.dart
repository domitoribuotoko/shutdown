// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

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

/// Собирает WoL magic-пакет (6×0xFF + 16×MAC) и возвращает null при неверном MAC.
Uint8List? _buildWolPacket(String mac) {
  final parts = mac.replaceAll('-', ':').split(':');
  if (parts.length != 6) return null;
  final macBytes = <int>[];
  for (final p in parts) {
    final b = int.tryParse(p, radix: 16);
    if (b == null || b < 0 || b > 255) return null;
    macBytes.add(b);
  }
  final packet = Uint8List(6 + 16 * 6);
  for (var i = 0; i < 6; i++) packet[i] = 0xFF;
  for (var i = 0; i < 16; i++) {
    for (var j = 0; j < 6; j++) packet[6 + i * 6 + j] = macBytes[j];
  }
  return packet;
}

/// Одна попытка отправки WoL через RawDatagramSocket. Возвращает true только при успешной отправке
/// (при ENETUNREACH / недоступной сети бросает/ловим и возвращаем false, как в нативном коде).
Future<bool> sendWol() async {
  final packet = _buildWolPacket(kPcMac);
  if (packet == null) {
    print('❌ Неверный MAC: $kPcMac');
    return false;
  }
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final target = InternetAddress(kBroadcastIp);
    socket.send(packet, target, 9); // WoL port 9
    print('✅ WoL-пакет успешно отправлен');
    return true;
  } on SocketException catch (e) {
    print('❌ Ошибка отправки WoL: $e');
    return false;
  } on OSError catch (e) {
    print('❌ Ошибка отправки WoL: $e');
    return false;
  } catch (e) {
    print('❌ Ошибка отправки WoL: $e');
    return false;
  } finally {
    socket?.close();
  }
}

/// До [maxAttempts] попыток WoL. Возвращает true, если хотя бы одна успешна.
Future<bool> sendWolWithRetries(int maxAttempts) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (await sendWol()) return true;
    if (attempt < maxAttempts - 1) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
  return false;
}

/// Проверяет, что устройство в той же подсети, что и ПК (как в нативном виджете).
/// WoL broadcast доходит только в своей подсети; при другой подсети не переходим в ожидание.
/// Если не удаётся определить — возвращает true, чтобы не ломать сценарии.
Future<bool> isOnSameSubnetAsPc() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    String? deviceIp;
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final a = addr.address;
        if (a.split('.').length == 4) {
          deviceIp = a;
          break;
        }
      }
      if (deviceIp != null) break;
    }
    if (deviceIp == null) return true;
    final devicePrefix = deviceIp.split('.').take(3).join('.');
    final pcParts = kPcIp.split('.');
    if (pcParts.length != 4) return true;
    final pcPrefix = pcParts.take(3).join('.');
    if (devicePrefix != pcPrefix) {
      print('❌ Другая подсеть: устройство $deviceIp, ПК $kPcIp');
      return false;
    }
    return true;
  } catch (e) {
    print('❌ Не удалось получить подсеть: $e');
  }
  return true;
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
    final ok = await sendWol();
    _showSnackBar(ok ? 'WoL-пакет отправлен' : 'Не удалось отправить WoL');
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

      case _statusOff: {
        if (!await isOnSameSubnetAsPc()) {
          _showSnackBar('Сеть недоступна, WoL не отправлен');
          return;
        }
        final ok = await sendWolWithRetries(3);
        if (!ok) {
          _showSnackBar('Сеть недоступна, WoL не отправлен');
          return;
        }
        setState(() => _pendingWolFirstCheck = true);
        await _applyStatus(_statusPendingWol);
        _showSnackBar('WoL отправлен, ожидание включения…');
        _scheduleNextCheck();
        break;
      }

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