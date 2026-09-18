import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const GboardEnhancerApp());

class GboardEnhancerApp extends StatelessWidget {
  const GboardEnhancerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Gboard Enhancer',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF6C63FF),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF8D86FF),
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _channel = MethodChannel('dev.gboard.enhancer/config');

  bool _loading = true;
  bool _writingTools = true;
  bool _regionBypass = true;
  bool _modelUnlock = true;
  bool _experimental = false;
  String _country = 'US';
  String _backend = 'GBOARD_SERVER';

  Map<String, dynamic> _nativeDiag = {};
  Map<String, String> _netDiag = {};
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = Map<String, dynamic>.from(
        await _channel.invokeMethod<Map>('loadConfig') ?? const {},
      );
      final diag = Map<String, dynamic>.from(
        await _channel.invokeMethod<Map>('nativeDiagnostics') ?? const {},
      );
      if (!mounted) return;
      setState(() {
        _writingTools = config['writingTools'] ?? true;
        _regionBypass = config['regionBypass'] ?? true;
        _modelUnlock = config['modelUnlock'] ?? true;
        _experimental = config['experimental'] ?? false;
        _country = config['forcedCountry'] ?? 'US';
        _backend = config['backend'] ?? 'GBOARD_SERVER';
        _nativeDiag = diag;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    await _channel.invokeMethod('saveConfig', {
      'writingTools': _writingTools,
      'regionBypass': _regionBypass,
      'modelUnlock': _modelUnlock,
      'experimental': _experimental,
      'forcedCountry': _country,
      'backend': _backend,
    });
  }

  Future<String> _probe(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      req.headers.set(HttpHeaders.userAgentHeader, 'GboardEnhancer/0.2');
      final response = await req.close().timeout(const Duration(seconds: 5));
      await response.drain<void>();
      return 'HTTP ' + response.statusCode.toString();
    } on TimeoutException {
      return 'TIMEOUT';
    } on SocketException catch (e) {
      return 'SOCKET ' + (e.osError?.errorCode.toString() ?? '-');
    } catch (e) {
      return e.runtimeType.toString();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _runDiagnostics() async {
    setState(() => _testing = true);
    final native = Map<String, dynamic>.from(
      await _channel.invokeMethod<Map>('nativeDiagnostics') ?? const {},
    );

    final results = <String, String>{};
    results['Google'] =
        await _probe('https://www.google.com/generate_204');
    results['Google APIs'] =
        await _probe('https://www.googleapis.com/discovery/v1/apis');
    results['Gboard model CDN'] = await _probe(
      'https://dl.google.com/handwriting/models/handwriting_release.superpack_manifest.20260206.json',
    );

    if (!mounted) return;
    setState(() {
      _nativeDiag = native;
      _netDiag = results;
      _testing = false;
    });
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _switchTile(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile.adaptive(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (v) {
        onChanged(v);
        _save();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gboard Enhancer'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.keyboard_alt_outlined),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '0.2-dev · Flutter + Kotlin',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Gboard 热路径已改为纯内存缓存；配置只在启动或变更时刷新。',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _section('AI & Writing', [
            _switchTile(
              'AI Writing Tools',
              'Proofread、My Style、Smart Reply、Streaming UI 等',
              _writingTools,
              (v) => setState(() => _writingTools = v),
            ),
            ListTile(
              title: const Text('Writing backend'),
              subtitle: const Text(
                'Server 不可用时可分别测试 AICore / Astrea',
              ),
              trailing: DropdownButton<String>(
                value: _backend,
                items: const [
                  DropdownMenuItem(
                    value: 'GBOARD_SERVER',
                    child: Text('Server'),
                  ),
                  DropdownMenuItem(
                    value: 'AICORE',
                    child: Text('AICore'),
                  ),
                  DropdownMenuItem(
                    value: 'ASTREA',
                    child: Text('Astrea'),
                  ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _backend = v);
                  _save();
                },
              ),
            ),
          ]),
          _section('Region & Models', [
            _switchTile(
              'Region / language bypass',
              '解除客户端语言 allowlist 与部分地区判断',
              _regionBypass,
              (v) => setState(() => _regionBypass = v),
            ),
            ListTile(
              title: const Text('Forced country'),
              subtitle: const Text(
                '仅覆盖客户端 device_country_for_testing',
              ),
              trailing: SizedBox(
                width: 84,
                child: TextFormField(
                  initialValue: _country,
                  maxLength: 2,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    counterText: '',
                    isDense: true,
                  ),
                  onChanged: (v) => _country = v.toUpperCase(),
                  onFieldSubmitted: (_) => _save(),
                ),
              ),
            ),
            _switchTile(
              'Offline model unlock',
              '允许 Gboard 原生 Superpacks / MDD 下载与自动更新',
              _modelUnlock,
              (v) => setState(() => _modelUnlock = v),
            ),
            _switchTile(
              'Experimental',
              'Emojify、Agentic Dictation 等未完全验证开关',
              _experimental,
              (v) => setState(() => _experimental = v),
            ),
          ]),
          _section('Diagnostics', [
            ListTile(
              title: const Text('Gboard'),
              subtitle: Text(
                (_nativeDiag['gboardVersion'] ?? 'not visible').toString(),
              ),
            ),
            ListTile(
              title: const Text('Google Play services'),
              subtitle: Text(
                (_nativeDiag['gmsVersion'] ?? 'not installed / not visible')
                    .toString(),
              ),
              trailing: Icon(
                _nativeDiag['gmsInstalled'] == true
                    ? Icons.check_circle
                    : Icons.error_outline,
              ),
            ),
            ListTile(
              title: const Text('Android AICore'),
              subtitle: Text(
                (_nativeDiag['aicoreVersion'] ??
                        'not installed / not visible')
                    .toString(),
              ),
              trailing: Icon(
                _nativeDiag['aicoreInstalled'] == true
                    ? Icons.check_circle
                    : Icons.info_outline,
              ),
            ),
            const ListTile(
              title: Text('Hot-path config'),
              subtitle: Text(
                'In-memory snapshot; no periodic ContentProvider IPC',
              ),
              trailing: Icon(Icons.speed_rounded),
            ),
            ..._netDiag.entries.map(
              (e) => ListTile(
                title: Text(e.key),
                subtitle: Text(e.value),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: FilledButton.icon(
                onPressed: _testing ? null : _runDiagnostics,
                icon: _testing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_rounded),
                label: Text(
                  _testing
                      ? 'Testing…'
                      : 'Run connectivity diagnostics',
                ),
              ),
            ),
          ]),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            child: Text(
              '配置变更时只向 Gboard 发送一次刷新广播。若某些功能状态未更新，强制停止 Gboard 后重新调用键盘。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
