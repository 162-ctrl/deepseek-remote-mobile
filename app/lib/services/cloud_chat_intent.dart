import 'package:flutter/foundation.dart';

/// M4.30：从「工作区」打开一条手机对话时，用它把「切到手机档 + 选中这条」这个
/// 意图交给 AI 助手页。
///
/// 这两页在 [RootShell] 的 IndexedStack 里并排常驻，没有直接的父子关系，也不便
/// 为了一个跳转去改导航层，所以用一个极小的单例广播：工作区写入、助手页读走。
class CloudChatIntent extends ChangeNotifier {
  CloudChatIntent._();

  static final CloudChatIntent instance = CloudChatIntent._();

  String? _conversationId;

  /// 还没被读走的那条对话 id（调试与测试用）。
  String? get pending => _conversationId;

  /// 请求 AI 助手切到手机档并打开这条对话。
  void open(String conversationId) {
    if (conversationId.trim().isEmpty) return;
    _conversationId = conversationId;
    notifyListeners();
  }

  /// 取走一次意图；取过就清空，避免页面重建时反复重放同一个跳转。
  String? take() {
    final id = _conversationId;
    _conversationId = null;
    return id;
  }
}
