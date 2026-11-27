import 'package:flutter/foundation.dart';

/// M4.50：「工作区」页点「新会话」时，给 AI 助手页递的一个小意图。
///
/// 以前工作区页直接 `createConversation()` 就完事：电脑端的 Agent 子进程确实建了
/// 一个空会话，可那个会话既不在电脑端自己的会话列表里、也不在手机这一页的列表里，
/// 用户看到的只有一句 toast，没有任何对话框。
///
/// 现在改成「切到远程电脑档 + 把这个工作区绑成新会话的落点 + 聚焦输入框」：
/// 用户在 AI 助手页发第一条消息，真正的会话和对话框一起出现。
///
/// 两页在 [RootShell] 的 IndexedStack 里并排常驻，没有父子关系，所以沿用
/// [CloudChatIntent] 的单例广播写法。
class RemoteChatRequest {
  const RemoteChatRequest({this.workspacePath});

  /// 新会话要落的目录（电脑端授权根之一）。
  final String? workspacePath;
}

class RemoteChatIntent extends ChangeNotifier {
  RemoteChatIntent._();

  static final RemoteChatIntent instance = RemoteChatIntent._();

  RemoteChatRequest? _request;

  /// 还没被读走的那次请求（调试与测试用）。
  RemoteChatRequest? get pending => _request;

  /// 请求 AI 助手切到远程电脑档，并把新会话绑到 [workspacePath]。
  void open({String? workspacePath}) {
    _request = RemoteChatRequest(workspacePath: workspacePath);
    notifyListeners();
  }

  /// 取走一次请求；取过就清空，避免页面重建时反复重放。
  RemoteChatRequest? take() {
    final request = _request;
    _request = null;
    return request;
  }
}
