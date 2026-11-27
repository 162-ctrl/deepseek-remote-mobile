import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../services/history_api.dart';
import '../services/pairing_api.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/empty_state.dart';
import 'plugin_gallery_screen.dart';

/// M3.6：插件页双 Tab——「已安装」按插件包分组开关，「插件市场」搜索/安装/卸载。
///
/// 兼容旧版电脑端插件：`bundles` / `market` 接口 404 时降级为旧的插件列表，
/// 并提示升级插件版本。
class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key, required this.liveStore});

  final LiveStore liveStore;

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // ---- 已安装 ----
  List<PluginBundle>? _bundles;
  List<PluginInfo> _plugins = const <PluginInfo>[];
  bool _bundlesSupported = false;
  bool _installedLoading = true;
  String? _installedError;
  final Set<String> _expandedBundles = <String>{};
  bool _showSystemPlugins = false;

  // ---- 市场 ----
  final TextEditingController _searchController = TextEditingController();
  MarketSearchResult? _marketResult;
  bool _marketLoading = false;
  bool _marketLoaded = false;
  bool _marketUnsupported = false;
  String? _marketError;
  String _indexUrl = '';

  // M4.18：电脑端插件市场目录（与电脑端「设置 → 插件市场」同一份数据）。
  // 旧的市场接口只读手动配的第三方索引，电脑上没配就是空的——所以目录才是主来源。
  PluginCatalog? _catalog;
  bool _catalogLoading = false;
  String? _catalogError;
  String _marketQuery = '';

  // ---- 操作去重 ----
  final Set<String> _busyKeys = <String>{};
  final Set<String> _installing = <String>{};
  final Set<String> _removing = <String>{};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadInstalled();
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index != 1) return;
    if (_catalog != null || _catalogLoading) return;
    _loadCatalog();
  }

  bool _isBusy(String key) => _busyKeys.contains(key);

  // ---------------------------------------------------------------------------
  // 已安装
  // ---------------------------------------------------------------------------

  Future<void> _loadInstalled() async {
    if (!mounted) return;
    setState(() {
      _installedLoading = true;
      _installedError = null;
    });
    try {
      var bundlesSupported = true;
      List<PluginBundle> bundles = const <PluginBundle>[];
      try {
        bundles = await widget.liveStore.listPluginBundles();
      } catch (_) {
        // 旧版电脑端插件没有 bundles 接口（404）或实现不完整：回退插件列表。
        bundlesSupported = false;
      }
      if (!bundlesSupported) {
        final plugins = await widget.liveStore.listPlugins();
        if (!mounted) return;
        setState(() {
          _bundlesSupported = false;
          _bundles = null;
          _plugins = plugins;
          _installedLoading = false;
        });
        return;
      }
      bundles = List<PluginBundle>.of(bundles)
        ..sort((a, b) {
          if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
          return a.name.compareTo(b.name);
        });
      if (!mounted) return;
      setState(() {
        _bundlesSupported = true;
        _bundles = bundles;
        _plugins = const <PluginInfo>[];
        _installedLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installedLoading = false;
        _installedError =
            error is PairingApiException ? error.message : '$error';
      });
    }
  }

  Future<void> _toggleBundle(PluginBundle bundle, bool enabled) async {
    final key = 'b:${bundle.name}';
    if (_isBusy(key)) return;
    setState(() => _busyKeys.add(key));
    try {
      await widget.liveStore.setBundleEnabled(bundle.name, enabled);
      if (!mounted) return;
      await _loadInstalled();
      if (!mounted) return;
      _toast(enabled ? '已启用 ${bundle.displayName}' : '已停用 ${bundle.displayName}');
    } catch (error) {
      if (!mounted) return;
      _toast(_messageOf(error, '切换插件包失败'), error: true);
    } finally {
      if (mounted) setState(() => _busyKeys.remove(key));
    }
  }

  Future<void> _togglePlugin(PluginInfo plugin, bool enabled) async {
    final key = 'p:${plugin.id}';
    if (_isBusy(key)) return;
    setState(() => _busyKeys.add(key));
    try {
      await widget.liveStore.setPluginEnabled(plugin.id, enabled);
      if (!mounted) return;
      await _loadInstalled();
      if (!mounted) return;
      _toast(enabled ? '已启用 ${plugin.name}' : '已停用 ${plugin.name}');
    } catch (error) {
      if (!mounted) return;
      _toast(_messageOf(error, '切换插件失败'), error: true);
    } finally {
      if (mounted) setState(() => _busyKeys.remove(key));
    }
  }

  // ---------------------------------------------------------------------------
  // 市场
  // ---------------------------------------------------------------------------

  /// M4.18：读电脑端插件市场目录。
  Future<void> _loadCatalog({bool force = false}) async {
    if (_catalogLoading) return;
    if (!force && _catalog != null) return;
    setState(() {
      _catalogLoading = true;
      _catalogError = null;
    });
    try {
      final catalog = await widget.liveStore.pluginCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _catalogLoading = false;
      });
      // 电脑端若另配了第三方索引，它们的条目会接在目录后面（见 `_marketEntries`）。
      await _searchMarket();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _catalogLoading = false;
        _catalogError = _messageOf(error, '读取电脑端插件市场失败');
      });
    }
  }

  Future<void> _searchMarket() async {
    if (_marketLoading) return;
    setState(() {
      _marketLoading = true;
      _marketLoaded = true;
      _marketError = null;
      _marketUnsupported = false;
    });
    try {
      final result = await widget.liveStore.marketSearch(
        url: _indexUrl.trim().isEmpty ? null : _indexUrl.trim(),
        query: _searchController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _marketResult = result;
        _marketError = result.error;
        _marketLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      final is404 = error is PairingApiException && error.statusCode == 404;
      setState(() {
        _marketLoading = false;
        _marketUnsupported = is404;
        _marketError = _messageOf(error, '搜索插件市场失败');
        _marketResult = null;
      });
    }
  }

  /// 目录条目 + 第三方索引里多出来的条目（按包名去重，目录优先）。
  List<MarketEntry> get _marketEntries {
    final out = <MarketEntry>[];
    final seen = <String>{};
    final keyword = _marketQuery.toLowerCase();
    bool hit(MarketEntry entry) {
      if (keyword.isEmpty) return true;
      return entry.name.toLowerCase().contains(keyword) ||
          (entry.title ?? '').toLowerCase().contains(keyword) ||
          (entry.description ?? '').toLowerCase().contains(keyword);
    }

    final catalog = _catalog?.entries ?? const <MarketEntry>[];
    final sorted = List<MarketEntry>.of(catalog)
      ..sort((a, b) {
        if (a.installed != b.installed) return a.installed ? -1 : 1;
        if (a.official != b.official) return a.official ? -1 : 1;
        return a.displayTitle.compareTo(b.displayTitle);
      });
    for (final entry in sorted) {
      if (!hit(entry)) continue;
      if (seen.add(entry.name)) out.add(entry);
    }
    for (final entry in _marketResult?.entries ?? const <MarketEntry>[]) {
      if (!hit(entry)) continue;
      if (seen.add(entry.name)) out.add(entry);
    }
    return out;
  }

  Future<void> _install(MarketEntry entry) async {
    if (_installing.contains(entry.name)) return;
    final confirmed = await _confirm(
      '安装 ${entry.displayTitle}',
      '会从插件市场下载并安装到这台电脑。若插件带构建脚本，还会再向你确认一次。',
      confirmLabel: '开始安装',
    );
    if (!confirmed || !mounted) return;
    // 电脑端目录给的是「包名@精确版本」，原样交回去；第三方索引条目没有 spec，用包名。
    final spec = (entry.spec ?? '').trim().isEmpty ? entry.name : entry.spec!.trim();
    setState(() => _installing.add(entry.name));
    try {
      var result = await widget.liveStore.installPlugin(spec);
      final pending = _pendingBuilds(result);
      final nextStep = (result['nextStep'] ?? '').toString().trim();
      if (pending.isNotEmpty || nextStep.isNotEmpty) {
        if (!mounted) return;
        final approved = await _confirm(
          '需要确认构建脚本',
          _buildConfirmMessage(pending, nextStep),
          confirmLabel: '允许并继续',
        );
        if (!approved || !mounted) return;
        result = await widget.liveStore.installPlugin(
          spec,
          approvedBuilds: pending,
        );
      }
      if (!mounted) return;
      _toast('已安装 ${entry.displayTitle}');
      await _loadInstalled();
      if (!mounted) return;
      await _loadCatalog(force: true);
    } catch (error) {
      if (!mounted) return;
      _toast(_messageOf(error, '安装插件失败'), error: true);
    } finally {
      if (mounted) setState(() => _installing.remove(entry.name));
    }
  }

  Future<void> _remove(MarketEntry entry) async {
    if (_removing.contains(entry.name)) return;
    final confirmed = await _confirm(
      '卸载 ${entry.displayTitle}',
      '会从这台电脑移除该插件包，相关功能会立即失效。',
      confirmLabel: '卸载',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _removing.add(entry.name));
    try {
      await widget.liveStore.removePlugin(entry.name);
      if (!mounted) return;
      _toast('已卸载 ${entry.displayTitle}');
      await _loadInstalled();
      if (!mounted) return;
      await _loadCatalog(force: true);
    } catch (error) {
      if (!mounted) return;
      _toast(_messageOf(error, '卸载插件失败'), error: true);
    } finally {
      if (mounted) setState(() => _removing.remove(entry.name));
    }
  }

  List<String> _pendingBuilds(Map<String, dynamic> result) {
    final raw = result['pendingBuilds'];
    if (raw is! List) return const <String>[];
    final names = <String>[];
    for (final item in raw) {
      if (item == null) continue;
      if (item is String) {
        if (item.trim().isNotEmpty) names.add(item.trim());
      } else if (item is Map) {
        final name = item['name'] ?? item['spec'] ?? item['id'] ?? item['path'];
        if (name != null && '$name'.trim().isNotEmpty) {
          names.add('$name'.trim());
        } else {
          names.add('$item');
        }
      } else {
        names.add('$item');
      }
    }
    return names;
  }

  String _buildConfirmMessage(List<String> pending, String nextStep) {
    final buffer = StringBuffer('以下构建脚本会在这台电脑上执行：');
    if (pending.isEmpty) {
      buffer.write('（电脑端未提供脚本名，按下一步提示确认）');
    } else {
      for (final name in pending) {
        buffer.write('\n· $name');
      }
    }
    if (nextStep.isNotEmpty) {
      buffer.write('\n\n下一步：$nextStep');
    }
    buffer.write('\n\n确认只在信任该插件时继续。');
    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // 通用
  // ---------------------------------------------------------------------------

  String _messageOf(Object error, String fallback) {
    if (error is PairingApiException) return error.message;
    return '$fallback：$error';
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? context.appPalette.danger : null,
      ),
    );
  }

  /// 与 `confirmDanger` 同一套底部弹层，但按钮文案按场景定制。
  Future<bool> _confirm(
    String title,
    String message, {
    String confirmLabel = '确认',
    bool danger = false,
  }) async {
    final palette = context.appPalette;
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: palette.card,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    danger
                        ? Icons.warning_amber_rounded
                        : Icons.extension_rounded,
                    color: danger ? palette.danger : palette.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: palette.text2,
                      fontSize: 13,
                      height: 1.55,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetContext, false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, true),
                      style: danger
                          ? FilledButton.styleFrom(
                              backgroundColor: palette.danger,
                            )
                          : null,
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(
          '插件',
          style: TextStyle(
            color: palette.text,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () {
              _loadInstalled();
              if (_tabController.index == 1) _loadCatalog(force: true);
            },
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: palette.text,
          unselectedLabelColor: palette.text3,
          labelStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
          unselectedLabelStyle:
              const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
          indicatorColor: palette.accent,
          indicatorWeight: 2.4,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: '已安装'),
            Tab(text: '插件市场'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildInstalledTab(),
          _buildMarketTab(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 「已安装」Tab
  // ---------------------------------------------------------------------------

  /// M4.1：对齐电脑端「设置 → 插件」——按插件（而不是插件包）看内置/实验性分组。
  Widget _galleryEntryBanner(int bundleCount) {
    final palette = context.appPalette;
    return Panel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: _openGallery,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    borderRadius: BorderRadius.circular(AppRadius.code),
                  ),
                  child: Icon(
                    Icons.widgets_outlined,
                    size: 19,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '浏览本地插件',
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '像电脑端「设置 → 插件」一样：内置插件配置、实验性插件，逐项开关（共 $bundleCount 个插件包）',
                        maxLines: 2,
                        style: TextStyle(
                          color: palette.text3,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: palette.text3),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openGallery() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PluginGalleryScreen(liveStore: widget.liveStore),
      ),
    );
    if (!mounted) return;
    // 画廊里可能改了开关，回来刷新插件包状态。
    await _loadInstalled();
  }

  Widget _buildInstalledTab() {
    if (_installedLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    final error = _installedError;
    if (error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          EmptyHint(icon: Icons.extension_off_rounded, text: error),
          Center(child: TextButton(onPressed: _loadInstalled, child: const Text('重试'))),
        ],
      );
    }
    if (_bundlesSupported) {
      final bundles = _bundles ?? const <PluginBundle>[];
      if (bundles.isEmpty) return _installedEmpty();
      return RefreshIndicator(
        onRefresh: _loadInstalled,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            10,
            AppSpace.page,
            28,
          ),
          children: [
            _galleryEntryBanner(bundles.length),
            const SizedBox(height: 12),
            _countLine('${bundles.length} 个插件包'),
            for (final bundle in bundles) ...[
              _BundleCard(
                bundle: bundle,
                expanded: _expandedBundles.contains(bundle.name),
                busy: _isBusy('b:${bundle.name}'),
                childBusy: (PluginInfo plugin) => _isBusy('p:${plugin.id}'),
                onToggle: (value) => _toggleBundle(bundle, value),
                onExpand: () {
                  setState(() {
                    if (!_expandedBundles.add(bundle.name)) {
                      _expandedBundles.remove(bundle.name);
                    }
                  });
                },
                onToggleChild: _togglePlugin,
              ),
              const SizedBox(height: AppSpace.cardGap),
            ],
            const SizedBox(height: 4),
            _footnote('开关会立即下发到电脑端；安装、卸载请到「插件市场」。'),
          ],
        ),
      );
    }

    // 旧版插件：过滤出第三方插件，其余收进「系统内置」。
    final visible = <PluginInfo>[
      for (final plugin in _plugins)
        if (_looksLikePlugin(plugin)) plugin,
    ]..sort((a, b) {
        if (a.isEnabled != b.isEnabled) return a.isEnabled ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    final system = <PluginInfo>[
      for (final plugin in _plugins)
        if (!_looksLikePlugin(plugin)) plugin,
    ]..sort((a, b) => a.name.compareTo(b.name));

    if (_plugins.isEmpty) return _installedEmpty();
    return RefreshIndicator(
      onRefresh: _loadInstalled,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding:
            const EdgeInsets.fromLTRB(AppSpace.page, 10, AppSpace.page, 28),
        children: [
          _legacyBanner(),
          const SizedBox(height: 12),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '旧版电脑端只返回了 Host 内部模块，没有可识别的第三方插件。',
                style: TextStyle(
                  color: context.appPalette.text3,
                  fontSize: 12.5,
                  height: 1.6,
                ),
              ),
            ),
          for (final plugin in visible) ...[
            _LegacyPluginCard(
              plugin: plugin,
              busy: _isBusy('p:${plugin.id}'),
              onChanged: (value) => _togglePlugin(plugin, value),
            ),
            const SizedBox(height: 10),
          ],
          if (system.isNotEmpty) _systemPluginsSection(system),
          const SizedBox(height: 4),
          _footnote('插件数据来自旧版电脑端，升级后会按插件包分组。'),
        ],
      ),
    );
  }

  Widget _installedEmpty() {
    return EmptyState(
      icon: Icons.extension_rounded,
      title: '电脑上还没有安装插件',
      description: '在「插件市场」安装，或在电脑的「设置 → 插件」里安装后，这里会自动同步。',
      actionLabel: '刷新',
      onAction: _loadInstalled,
    );
  }

  bool _looksLikePlugin(PluginInfo plugin) {
    final haystack = '${plugin.name} ${plugin.id}'.toLowerCase();
    return haystack.contains('dsh-plugin') ||
        haystack.contains('plugin-') ||
        haystack.contains('plugin_');
  }

  Widget _systemPluginsSection(List<PluginInfo> plugins) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: () =>
                  setState(() => _showSystemPlugins = !_showSystemPlugins),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.settings_suggest_outlined,
                        size: 18, color: palette.text3),
                    const SizedBox(width: 8),
                    Text(
                      '系统内置（${plugins.length}）',
                      style: TextStyle(
                        color: palette.text2,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _showSystemPlugins
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: palette.text3,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_showSystemPlugins)
            for (final plugin in plugins)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _LegacyPluginCard(
                  plugin: plugin,
                  busy: _isBusy('p:${plugin.id}'),
                  onChanged: (value) => _togglePlugin(plugin, value),
                ),
              ),
        ],
      ),
    );
  }

  Widget _legacyBanner() {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: palette.warnSoft,
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 17, color: palette.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前电脑插件版本较旧，升级后可按插件包分组。',
              style: TextStyle(
                color: palette.text2,
                fontSize: 12.5,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _countLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(
        text,
        style: TextStyle(
          color: context.appPalette.text3,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _footnote(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        text,
        style: TextStyle(
          color: context.appPalette.text3,
          fontSize: 12,
          height: 1.6,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 「插件市场」Tab
  // ---------------------------------------------------------------------------

  Widget _buildMarketTab() {
    final palette = context.appPalette;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            12,
            AppSpace.page,
            8,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) => setState(() {
                    _marketQuery = value.trim().toLowerCase();
                  }),
                  onSubmitted: (_) => _loadCatalog(force: true),
                  decoration: const InputDecoration(
                    hintText: '搜索插件名或关键字',
                    prefixIcon: Icon(Icons.search_rounded, size: 19),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _catalogLoading ? null : () => _loadCatalog(force: true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 46),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('刷新'),
              ),
            ],
          ),
        ),
        if (_indexOptions().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 6),
            child: Row(
              children: [
                Text(
                  '索引',
                  style: TextStyle(color: palette.text3, fontSize: 12),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _indexUrl,
                      isDense: true,
                      isExpanded: true,
                      borderRadius: BorderRadius.circular(AppRadius.code),
                      style: TextStyle(color: palette.text2, fontSize: 12.5),
                      items: [
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('全部索引'),
                        ),
                        for (final index in _indexOptions())
                          DropdownMenuItem<String>(
                            value: index.url,
                            child: Text(
                              index.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        setState(() => _indexUrl = value ?? '');
                        _searchMarket();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(child: _marketBody()),
      ],
    );
  }

  List<MarketIndex> _indexOptions() {
    final details = _marketResult?.indexDetails ?? const <MarketIndex>[];
    return details;
  }

  Widget _marketBody() {
    final catalog = _catalog;
    if (catalog == null) {
      if (_catalogLoading) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
      }
      final failure = _catalogError;
      return EmptyState(
        icon: Icons.storefront_outlined,
        title: '电脑端插件市场',
        description: failure ?? '显示电脑上「设置 → 插件市场」里的同一份插件清单，可直接安装。',
        actionLabel: '读取目录',
        onAction: () => _loadCatalog(force: true),
      );
    }
    if (!catalog.supported) {
      return EmptyState(
        icon: Icons.system_update_alt_rounded,
        title: '插件市场暂不可用',
        description: '电脑端 Harness 没有提供插件市场管理能力，先升级电脑端的 DSH 再试。',
        actionLabel: '重试',
        onAction: () => _loadCatalog(force: true),
      );
    }
    final error = _marketError ?? _catalogError;
    final entries = _marketEntries;
    if (entries.isEmpty) {
      return EmptyState(
        icon: Icons.extension_outlined,
        title: '没有找到插件',
        description: error ?? (_marketQuery.isEmpty
            ? '电脑端插件市场里还没有可安装的插件。'
            : '换个关键字再试一次。'),
        actionLabel: '刷新目录',
        onAction: () => _loadCatalog(force: true),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadCatalog(force: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          6,
          AppSpace.page,
          28,
        ),
        itemCount: entries.length + (error == null ? 0 : 1) + 1,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpace.cardGap),
        itemBuilder: (context, index) {
          if (index == 0) return _catalogSummary(entries.length);
          final offset = 1;
          if (error != null && index == offset) {
            return _inlineWarning(error);
          }
          final entry =
              entries[index - offset - (error == null ? 0 : 1)];
          return _MarketCard(
            entry: entry,
            installing: _installing.contains(entry.name),
            removing: _removing.contains(entry.name),
            onInstall: () => _install(entry),
            onRemove: () => _remove(entry),
          );
        },
      ),
    );
  }

  /// M4.1：搜索结果概览行（插件市场里「全部 (10.8k)」那种统计 + 索引来源）。
  Widget _catalogSummary(int count) {
    final palette = context.appPalette;
    final installed = (_catalog?.entries ?? const <MarketEntry>[])
        .where((entry) => entry.installed)
        .length;
    final parts = <String>['$count 个插件', '电脑端插件市场'];
    if (installed > 0) parts.add('已安装 $installed 个');
    if (_marketQuery.isNotEmpty) parts.add('“$_marketQuery”');
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Text(
        parts.join(' · '),
        maxLines: 2,
        style: TextStyle(color: palette.text3, fontSize: 12, height: 1.5),
      ),
    );
  }

  Widget _inlineWarning(String text) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        color: palette.warnSoft,
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 17, color: palette.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: palette.text2,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 卡片
// -----------------------------------------------------------------------------

class _BundleCard extends StatelessWidget {
  const _BundleCard({
    required this.bundle,
    required this.expanded,
    required this.busy,
    required this.childBusy,
    required this.onToggle,
    required this.onExpand,
    required this.onToggleChild,
  });

  final PluginBundle bundle;
  final bool expanded;
  final bool busy;
  final bool Function(PluginInfo plugin) childBusy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onExpand;
  final void Function(PluginInfo plugin, bool enabled) onToggleChild;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: palette.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.extension_rounded,
                    size: 20, color: palette.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bundle.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (bundle.version != null && bundle.version!.isNotEmpty)
                          'v${bundle.version}',
                        '${bundle.plugins.length} 个插件',
                        bundle.enabled ? '已启用' : '未启用',
                      ].join(' · '),
                      style: TextStyle(color: palette.text3, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Switch.adaptive(
                  value: bundle.enabled,
                  onChanged: onToggle,
                ),
            ],
          ),
          if (bundle.description != null && bundle.description!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 6),
              child: Text(
                bundle.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text2,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
          const SizedBox(height: 4),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.code),
            onTap: onExpand,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text(
                    expanded ? '收起子插件' : '查看子插件',
                    style: TextStyle(
                      color: palette.text3,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: palette.text3,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            for (final plugin in bundle.plugins)
              _ChildPluginRow(
                plugin: plugin,
                busy: childBusy(plugin),
                bundleEnabled: bundle.enabled,
                onChanged: (value) => onToggleChild(plugin, value),
              ),
        ],
      ),
    );
  }
}

class _ChildPluginRow extends StatelessWidget {
  const _ChildPluginRow({
    required this.plugin,
    required this.busy,
    required this.bundleEnabled,
    required this.onChanged,
  });

  final PluginInfo plugin;
  final bool busy;
  final bool bundleEnabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final status = plugin.enabled == null
        ? '状态未知'
        : (plugin.isEnabled ? '已启用' : '未启用');
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.lineSoft)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          Icon(Icons.extension_outlined, size: 15, color: palette.text3),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plugin.name.isEmpty ? plugin.id : plugin.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.text2, fontSize: 13),
                ),
                const SizedBox(height: 1),
                Text(
                  plugin.readOnly ? '$status · 由配置固定' : status,
                  style: TextStyle(color: palette.text3, fontSize: 11),
                ),
              ],
            ),
          ),
          if (plugin.enabled == null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '—',
                style: TextStyle(color: palette.text3, fontSize: 12),
              ),
            )
          else if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Switch.adaptive(
              value: plugin.isEnabled,
              onChanged: plugin.readOnly ? null : onChanged,
            ),
        ],
      ),
    );
  }
}

class _LegacyPluginCard extends StatelessWidget {
  const _LegacyPluginCard({
    required this.plugin,
    required this.busy,
    required this.onChanged,
  });

  final PluginInfo plugin;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.extension_rounded,
                size: 18, color: palette.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plugin.name.isEmpty ? plugin.id : plugin.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  plugin.enabled == null
                      ? '状态未知'
                      : plugin.readOnly
                          ? '${plugin.isEnabled ? '已启用' : '未启用'} · 由配置固定'
                          : (plugin.isEnabled ? '已启用' : '未启用'),
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (plugin.enabled == null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text('—',
                  style: TextStyle(color: palette.text3, fontSize: 12)),
            )
          else
            Switch.adaptive(
              value: plugin.isEnabled,
              onChanged: plugin.readOnly ? null : onChanged,
            ),
        ],
      ),
    );
  }
}

class _MarketCard extends StatelessWidget {
  const _MarketCard({
    required this.entry,
    required this.installing,
    required this.removing,
    required this.onInstall,
    required this.onRemove,
  });

  final MarketEntry entry;
  final bool installing;
  final bool removing;
  final VoidCallback onInstall;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final busy = installing || removing;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  entry.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
              if (entry.version != null && entry.version!.isNotEmpty) ...[
                const SizedBox(width: 8),
                _VersionPill(text: 'v${entry.version}'),
              ],
              if (entry.official) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '官方',
                    style: TextStyle(
                      color: palette.accent,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (entry.author != null && entry.author!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  entry.author!,
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
                if (entry.downloadsLabel != null) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.download_rounded, size: 12, color: palette.text3),
                  const SizedBox(width: 2),
                  Text(
                    entry.downloadsLabel!,
                    style: TextStyle(color: palette.text3, fontSize: 11.5),
                  ),
                ],
                if (entry.starsLabel != null) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.star_rounded, size: 12, color: palette.text3),
                  const SizedBox(width: 2),
                  Text(
                    entry.starsLabel!,
                    style: TextStyle(color: palette.text3, fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ],
          if (entry.description != null && entry.description!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              entry.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text2,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ],
          if (entry.tags.isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in entry.tags.take(5))
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: palette.lineSoft,
                      borderRadius:
                          BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(color: palette.text3, fontSize: 10.5),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (entry.installed) ...[
                Text(
                  entry.installedVersion != null &&
                          entry.installedVersion!.isNotEmpty
                      ? '已安装 v${entry.installedVersion}'
                      : '已安装',
                  style: TextStyle(
                    color: palette.success,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: busy ? null : onRemove,
                  style: TextButton.styleFrom(
                    foregroundColor: palette.danger,
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: removing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('卸载'),
                ),
              ] else
                FilledButton(
                  onPressed: busy ? null : onInstall,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  child: installing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('安装'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VersionPill extends StatelessWidget {
  const _VersionPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.lineSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: palette.text2,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
