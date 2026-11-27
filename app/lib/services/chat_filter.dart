/// M4.16：手机端「对话」正文过滤（客户端保险）。
///
/// 权威过滤在插件 `dsh-plugin-m1/lib/chat-filter.js`（写入端与读取端都做），这里再
/// 兜一道：手机上可能连的是还没升级的旧插件，或者条目来自更早的本地缓存。用户看到的
/// 应该是人说的话，而不是 Host 每轮注入的英文运行时上下文
/// （「Time sampled while preparing turn 3, step 24: …」那种）。
library;

/// 注入消息的固定开头，与插件侧 `INJECTED_USER_PREFIXES` 保持一致。
const List<String> kInjectedUserPrefixes = <String>[
  'Current runtime context',
  'Time sampled while preparing',
  'Browser time zone for this request',
  'Elapsed since the preceding',
  '<system-reminder',
  '<hindsight_knowledge',
  '<hindsight_knowledge_refresh',
  '<available_skills',
  '<acp ',
  '<user_',
  '<user ',
];

/// 出现在开头附近就足以判定为注入的特征串。
const List<String> _kInjectedMarkers = <String>[
  'current runtime-context snapshot',
  'this snapshot supersedes earlier runtime-context snapshots',
  'the following skills are available in this session',
  'a skill is a reusable set of task-specific instructions',
];

/// 只在前 160 个字符里找标记：正文中段引用这些词的用户消息不该被吃掉。
const int _kMarkerScan = 160;

/// 这条用户文本是 Host 注入还是人真的说的话。
bool looksInjectedUserText(String raw) {
  final head = raw.replaceFirst(RegExp(r'^\s+'), '');
  if (head.isEmpty) return true;
  for (final prefix in kInjectedUserPrefixes) {
    if (head.startsWith(prefix)) return true;
  }
  final window = head.length <= _kMarkerScan
      ? head.toLowerCase()
      : head.substring(0, _kMarkerScan).toLowerCase();
  for (final marker in _kInjectedMarkers) {
    if (window.contains(marker)) return true;
  }
  return false;
}
