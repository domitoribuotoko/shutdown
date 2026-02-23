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

/// UDP-порт, на котором слушает сервер на ПК (должен совпадать с портом в Python-сервере)
const int kUdpPort = 9999;

/// TCP-порт для проверки состояния (например, 445 – общий доступ к файлам)
const int kTcpCheckPort = 445;

/// Команда, которую ожидает UDP-сервер (можно дополнить паролем)
const String kShutdownCommand = 'SHUTDOWN';

/// Таймаут для проверки TCP-соединения (в секундах)
const int kConnectTimeout = 3;

// =============================================================================
// ГЛАВНОЕ ПРИЛОЖЕНИЕ
// =============================================================================

void main()async {
  WidgetsFlutterBinding.ensureInitialized();
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

class _PcControlScreenState extends State<PcControlScreen> {
  bool _isPcOnline = false;   // true = ПК включён (зелёный), false = выключен (красный)
  bool _isLoading = true;     // для отображения индикатора загрузки при первом запуске
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _checkStatusPeriodically();
    HomeWidget.widgetClicked.listen((Uri? uri) {
      print('🔔 Виджет нажат');
      _onButtonPressed();
    });
  }
  void _setupHomeWidgetListener() {
    HomeWidget.widgetClicked.listen((Uri? uri) {
      print('🔔 Виджет нажат');
      _onButtonPressed();
    });
  }

  /// Запускает периодическую проверку статуса (каждые 5 секунд)
  void _checkStatusPeriodically() {
    print('🔄 Запуск периодической проверки статуса');
    _checkStatus(); // первая проверка сразу
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      print('⏰ Таймер сработал, проверяем статус...');
      _checkStatus();
    });
  }

  /// Проверяет, включён ли ПК, через TCP-соединение
  Future<void> _checkStatus() async {
    print('🔍 Проверка статуса ПК: попытка подключиться к $kPcIp:$kTcpCheckPort (таймаут $kConnectTimeout сек)');
    try {
      // Пытаемся подключиться к TCP-порту
      final socket = await Socket.connect(kPcIp, kTcpCheckPort,
          timeout: Duration(seconds: kConnectTimeout));
      // Если успешно – ПК включён
      print('✅ TCP-подключение успешно установлено к $kPcIp:$kTcpCheckPort');
      socket.destroy(); // закрываем сокет, он нам больше не нужен
      _updateStatus(true);
    } catch (e) {
      // Ошибка подключения (таймаут, refused) – считаем ПК выключенным
      print('❌ Ошибка TCP-подключения: $e');
      _updateStatus(false);
    }
  }

  void _updateStatus(bool isOnline)async {
    print('📱 Обновление статуса: ${isOnline ? "ВКЛЮЧЁН" : "ВЫКЛЮЧЕН"}');
    if (_isPcOnline != isOnline || _isLoading) {
      setState(() {
        _isPcOnline = isOnline;
        _isLoading = false;  // <-- обязательно сбрасываем загрузку
      });
      print('🔄 Статус изменён на экране: ${isOnline ? "Зелёный" : "Красный"}');
      try {
        await HomeWidget.saveWidgetData<String>('pc_status', isOnline ? 'on' : 'off');
        print('✅ Данные сохранены в виджет');
        await HomeWidget.updateWidget(name: 'HomeWidgetProvider');
        print('✅ Виджет обновлён');
      } catch (e) {
        print('❌ Ошибка при работе с виджетом: $e');
      }
    } else {
      print('⏸️ Статус не изменился');
    }
  }

  /// Отправка Wake-on-LAN пакета с использованием пакета wake_on_lan
  Future<void> _sendWol() async {
    print('📤 Отправка WoL-пакета на $kBroadcastIp, MAC: $kPcMac');
    // Валидируем и создаём объекты IPAddress и MACAddress
    final ipValidation = IPAddress.validate(kBroadcastIp);
    if (!ipValidation.state) {
      print('❌ Ошибка валидации IP: ${ipValidation.error}');
      _showSnackBar('Ошибка IP: ${ipValidation.error}');
      return;
    }
    final macValidation = MACAddress.validate(kPcMac);
    if (!macValidation.state) {
      print('❌ Ошибка валидации MAC: ${macValidation.error}');
      _showSnackBar('Ошибка MAC: ${macValidation.error}');
      return;
    }

    final ipAddress = IPAddress(kBroadcastIp);
    final macAddress = MACAddress(kPcMac);
    final wakeOnLan = WakeOnLAN(ipAddress, macAddress);

    try {
      await wakeOnLan.wake();
      print('✅ WoL-пакет успешно отправлен');
      _showSnackBar('WoL-пакет отправлен');
    } catch (e) {
      print('❌ Ошибка отправки WoL: $e');
      _showSnackBar('Ошибка отправки WoL: $e');
    }
  }

  /// Отправка UDP-команды на выключение ПК
  Future<void> _sendUdpShutdown() async {
    print('📤 Отправка UDP-команды "$kShutdownCommand" на $kPcIp:$kUdpPort');
    RawDatagramSocket? udpSocket;
    try {
      udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udpSocket.broadcastEnabled = true;

      final List<int> data = utf8.encode(kShutdownCommand);
      udpSocket.send(data, InternetAddress(kPcIp), kUdpPort);

      print('✅ UDP-команда отправлена');
      _showSnackBar('Команда выключения отправлена');

      await Future.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      print('❌ Ошибка отправки UDP: $e');
      _showSnackBar('Ошибка отправки UDP: $e');
    } finally {
      udpSocket?.close();
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Обработчик нажатия на большую кнопку
  void _onButtonPressed() async {
    if (_isLoading) return;

    if (_isPcOnline) {
      // ПК включён – показываем диалог подтверждения
      final bool? confirm = await showDialog<bool>(
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

      if (confirm != true) return; // если отмена – ничего не делаем

      // Подтверждено – отправляем команду
      setState(() => _isLoading = true);
      await _sendUdpShutdown();
      // После отправки команды дадим небольшой запас времени и проверим статус
      await Future.delayed(const Duration(seconds: 1));
      _checkStatus();
    } else {
      // ПК выключен – отправляем WoL без диалога
      setState(() => _isLoading = true);
      await _sendWol();
      // После отправки WoL тоже проверяем статус
      await Future.delayed(const Duration(seconds: 1));
      _checkStatus();
    }
  }
  Future<void> _manualCheck() async {
    if (_isLoading) return; // если уже идёт проверка – игнорируем
    print('🔄 Ручная проверка статуса');
    setState(() => _isLoading = true); // показываем индикатор загрузки на основной кнопке
    await _checkStatus(); // вызываем существующую проверку
    setState(() => _isLoading = false); // скрываем индикатор после завершения
    // можно показать уведомление:
    _showSnackBar('Статус обновлён');
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
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
              _isPcOnline ? 'ПК ВКЛЮЧЁН' : 'ПК ВЫКЛЮЧЕН',
              style: TextStyle(
                fontSize: 24,
                color: _isPcOnline ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _onButtonPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isPcOnline ? Colors.green : Colors.red,
                foregroundColor: Colors.white,
                minimumSize: const Size(200, 200),
                shape: const CircleBorder(),
              ),
              child: Text(
                _isPcOnline ? 'ВЫКЛЮЧИТЬ' : 'ВКЛЮЧИТЬ',
                style: const TextStyle(fontSize: 20),
              ),
            ),
            const SizedBox(height: 20), // небольшой отступ
            TextButton.icon(
              onPressed: _isLoading ? null : _manualCheck, // запрещаем нажатие во время загрузки
              icon: const Icon(Icons.refresh),
              label: const Text('Проверить статус'),
            ),
          ],
        ),
      ),
    );
  }
}