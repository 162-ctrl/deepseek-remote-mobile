import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../services/history_api.dart';
import '../services/pairing_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// M4.1：本地已安装插件画廊（对齐电脑端「设置 → 插件 → 已安装」）。
///
/// 电脑端的插件页把 Host 已装插件分成三组：内置插件配置（子智能体、网页搜索、
/// Agent 循环、终端…）、实验性插件（带「实验性」标签和开关）、其他插件。手机端
/// 以前只按「插件包（bundle）」展示，颗粒太粗也看不出是内置还是实验性；这里改成
/// 和电脑端一样的画廊分组，每个插件一行带开关，开关走同一条 `plugins/enabled`。
class PluginGalleryScreen extends StatefulWidget {
  const PluginGalleryScreen({super.key, required this.liveStore});

  final LiveStore liveStore;

  @override
  State<PluginGalleryScreen> createState() => _PluginGalleryScreenState();
}

class _PluginGalleryScreenState extends State<PluginGalleryScreen> {
  PluginGallery? _gallery;
  bool _loading = true;
  String? _error;
  String _keyword = '';
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _gallery == null;
      _error = null;
    });
    try {
      final gallery = await widget.liveStore.pluginGallery();
      if (!mounted) return;
      setState(() {
        _gallery = gallery;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messageOf(error);
      });
    }
  }

  Future<void> _toggle(PluginGalleryItem item, bool enabled) async {
    if (_busy.contains(item.id)) return;
    setState(() => _busy.add(item.id));
    try {
      await widget.liveStore.setPluginEnabled(item.id, enabled);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      _toast(enabled ? '已启用 ${item.name}' : '已停用 ${item.name}');
    } catch (error) {
      if (!mounted) return;
      _toast(_messageOf(error), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(item.id));
    }
  }

  void _toast(String? message, {bool error = false}) {
    if (message == null || message.isEmpty) return;
    final palette = context.appPalette;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        backgroundColor: error ? palette.danger : palette.text,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      backgroundColor: palette.bg,
      appBar: AppBar(
        backgroundColor: palette.bg,
        title: const Text('已安装插件'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final palette = context.appPalette;
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    final error = _error;
    if (error != null && (_gallery == null || _gallery!.groups.isEmpty)) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          EmptyHint(icon: Icons.extension_off_rounded, text: error),
          Center(child: TextButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    final gallery = _gallery ?? const PluginGallery();
    final keyword = _keyword.trim().toLowerCase();
    final groups = <PluginGalleryGroup>[
      for (final group in gallery.groups)
        PluginGalleryGroup(
          key: group.key,
          title: group.title,
          plugins: <PluginGalleryItem>[
            for (final plugin in group.plugins)
              if (keyword.isEmpty ||
                  plugin.name.toLowerCase().contains(keyword) ||
                  plugin.description.toLowerCase().contains(keyword) ||
                  plugin.id.toLowerCase().contains(keyword))
                plugin,
          ],
        ),
    ].where((group) => group.plugins.isNotEmpty).toList(growable: false);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 28),
        children: [
          TextField(
            onChanged: (value) => setState(() => _keyword = value),
            decoration: const InputDecoration(
              hintText: '搜索已安装插件',
              prefixIcon: Icon(Icons.search_rounded, size: 19),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${gallery.total} 个插件 · 开关与电脑端「设置 → 插件」同源，重启 DSH 后完全生效',
            style: TextStyle(color: palette.text3, fontSize: 12, height: 1.5),
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            _warning(error),
          ],
          for (final group in groups) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 8),
              child: Text(
                '${group.title} · ${group.plugins.length}',
                style: TextStyle(
                  color: palette.text2,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final plugin in group.plugins) ...[
              _PluginRow(
                item: plugin,
                busy: _busy.contains(plugin.id),
                onToggle: (value) => _toggle(plugin, value),
              ),
              const SizedBox(height: 8),
            ],
          ],
          if (groups.isEmpty) ...[
            const SizedBox(height: 40),
            EmptyHint(
              icon: Icons.search_off_rounded,
              text: keyword.isEmpty ? '电脑端没有已安装插件' : '没有匹配「$_keyword」的插件',
            ),
          ],
        ],
      ),
    );
  }

  Widget _warning(String text) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.warnSoft,
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: palette.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: palette.text2, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  static String? _messageOf(Object error) {
    if (error is PairingApiException) {
      if (error.statusCode == 404) {
        return '电脑端插件版本过低，还不能读取本地插件；升级插件（0.2.9+）后重试。';
      }
      return error.message;
    }
    return '$error';
  }
}

class _PluginRow extends StatelessWidget {
  const _PluginRow({
    required this.item,
    required this.busy,
    required this.onToggle,
  });

  final PluginGalleryItem item;
  final bool busy;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: item.experimental ? palette.warnSoft : palette.accentSoft,
              borderRadius: BorderRadius.circular(AppRadius.code),
            ),
            child: Icon(
              item.experimental
                  ? Icons.science_outlined
                  : Icons.extension_outlined,
              size: 19,
              color: item.experimental ? palette.warn : palette.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (item.experimental) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: palette.warnSoft,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          '实验性',
                          style: TextStyle(color: palette.warn, fontSize: 10),
                        ),
                      ),
                    ],
                  ],
                ),
                if (item.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text3,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Switch.adaptive(
              value: item.enabled,
              activeThumbColor: palette.accent,
              onChanged: onToggle,
            ),
        ],
      ),
    );
  }
}
