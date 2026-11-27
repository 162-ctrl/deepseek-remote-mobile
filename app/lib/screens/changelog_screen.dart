import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../data/live_store.dart';
import '../services/history_api.dart' show UpdateNote;
import '../services/pairing_api.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';

/// 「功能 → 更新日志」（M4.66）。
///
/// 两路取数：优先问电脑上的插件（`/api/v1/app/notes`，读 `docs/UPDATE_NOTES.md`），
/// 没连电脑时退回随包的 `assets/update_notes.md`——那个文件每次发版跟着
/// `docs/UPDATE_NOTES.md` 一起复制，所以离线也有内容可看，只是可能不是最新。
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({super.key, required this.liveStore});

  final LiveStore liveStore;

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  List<UpdateNote> _notes = const <UpdateNote>[];
  bool _loading = true;
  bool _fromBundle = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    if (widget.liveStore.isConnected) {
      try {
        final notes = await widget.liveStore.loadUpdateNotes();
        if (!mounted) return;
        if (notes.isNotEmpty) {
          setState(() {
            _notes = notes;
            _fromBundle = false;
            _loading = false;
          });
          return;
        }
      } on PairingApiException catch (error) {
        if (!mounted) return;
        _error = error.message;
      } catch (error) {
        if (!mounted) return;
        _error = '$error';
      }
    } else {
      _error = null;
    }
    final bundled = await _loadBundled();
    if (!mounted) return;
    setState(() {
      _notes = bundled;
      _fromBundle = true;
      _loading = false;
    });
  }

  Future<List<UpdateNote>> _loadBundled() async {
    try {
      final text = await rootBundle.loadString('assets/update_notes.md');
      return _parseNotes(text);
    } catch (_) {
      return const <UpdateNote>[];
    }
  }

  /// 与插件 `readUpdateNoteList()` 同一套规则：按 `## ` 分段，标题里取版本号与日期。
  static List<UpdateNote> _parseNotes(String markdown) {
    final notes = <UpdateNote>[];
    String? version;
    String date = '';
    String title = '';
    final body = StringBuffer();
    void flush() {
      if (version == null && body.toString().trim().isEmpty) return;
      notes.add(UpdateNote(
        version: version ?? '',
        title: title,
        body: body.toString().replaceAll(RegExp(r'^>\s?', multiLine: true), '').trim(),
        date: date,
      ));
      body.clear();
    }

    for (final line in const LineSplitter().convert(markdown)) {
      if (line.startsWith('## ')) {
        flush();
        final raw = line.substring(3).trim();
        version = RegExp(r'\d+\.\d+\.\d+(?:\+\d+)?').stringMatch(raw);
        date = RegExp(r'\d{4}-\d{2}-\d{2}').stringMatch(raw) ?? '';
        title = raw
            .replaceAll(version ?? '', '')
            .replaceAll(date, '')
            .replaceAll(RegExp('[（）()]'), '')
            .replaceAll(RegExp(r'^[\s—–-]+'), '')
            .trim();
        continue;
      }
      if (version == null) continue;
      if (line.startsWith('#')) continue;
      body.writeln(line);
    }
    flush();
    return notes;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: palette.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 64,
        titleSpacing: 4,
        title: Text(
          '更新日志',
          style: TextStyle(
            color: palette.text,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: _buildBody(palette),
    );
  }

  Widget _buildBody(AppPalette palette) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_notes.isEmpty) {
      return EmptyState(
        icon: Icons.history_rounded,
        title: '还没有更新日志',
        description: _error ?? '连接电脑后，这里会列出每次发版改了什么。',
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 4, AppSpace.page, 28),
        itemCount: _notes.length + (_fromBundle ? 1 : 0),
        itemBuilder: (context, index) {
          if (_fromBundle && index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
                decoration: BoxDecoration(
                  color: palette.accentSoft,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Text(
                  _error == null
                      ? '这是随 App 打包的版本，连上电脑后会同步最新一份。'
                      : '连不上电脑（$_error），先显示随 App 打包的版本。',
                  style: TextStyle(color: palette.text2, fontSize: 11.5, height: 1.5),
                ),
              ),
            );
          }
          final note = _notes[_fromBundle ? index - 1 : index];
          return _NoteBlock(palette: palette, note: note);
        },
      ),
    );
  }
}

class _NoteBlock extends StatelessWidget {
  const _NoteBlock({required this.palette, required this.note});

  final AppPalette palette;
  final UpdateNote note;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                note.version,
                style: TextStyle(
                  color: palette.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (note.date.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  note.date,
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
              ],
            ],
          ),
          if (note.title.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              note.title,
              style: TextStyle(
                color: palette.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ],
          if (note.body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              note.body,
              style: TextStyle(color: palette.text2, fontSize: 12, height: 1.65),
            ),
          ],
        ],
      ),
    );
  }
}
