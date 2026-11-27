// 用 App 自己的网络层，对着一台正在运行的 dsh-plugin-m1 跑一遍真实链路。
//
// 它不碰 Flutter 控件，只验证「扫码字符串 → 配对 → WebSocket → 建会话 → 发一句话 → 收到回复」：
//
//   dart run tool/live_pair_check.dart http://127.0.0.1:8787 000000
//
// 第二个参数是电脑端配网页上显示的 6 位匹配码（`$DSH_HOME/dsh-plugin-m1/pairing-code`）。
// 退出码 0 = 全通；1 = 有环节失败（失败原因打印在最后一行）。
import 'dart:async';
import 'dart:io';

import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/pairing_link.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';

Future<void> main(List<String> args) async {
  final base = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8787';
  final code = args.length > 1 ? args[1] : '';
  if (code.isEmpty) {
    stderr.writeln('用法：dart run tool/live_pair_check.dart <baseUrl> <配对码>');
    exit(1);
  }

  final steps = <String>[];
  void pass(String text) {
    steps.add('PASS $text');
    stdout.writeln('PASS $text');
  }

  Never fail(String text) {
    stdout.writeln('FAIL $text');
    exit(1);
  }

  final api = PairingApi();

  try {
    // 1) 扫到的二维码内容 → 地址 + 匹配码（App 里 PairingLink 做的就是这一步）。
    final scanned = PairingLink.tryParse('$base#c=$code');
    if (scanned == null || !scanned.hasCode || scanned.pairingCode != code) {
      fail('扫码解析失败：$base#c=$code');
    }
    pass('扫码解析：${scanned.baseUrl} + 码 ${scanned.pairingCode}');

    // 2) 健康检查。
    final health = await api.health(scanned.baseUrl);
    if (!health.healthy) {
      fail('健康检查不健康：${health.status}');
    }
    if (!health.agentOnline) {
      fail('插件在线但 Agent 不在线（电脑端 ACP 子进程没起来）');
    }
    pass('健康检查：v${health.version} · agentOnline=${health.agentOnline}');

    // 3) 配对拿 token。
    final pair = await api.pair(scanned.baseUrl, pairingCode: scanned.pairingCode!);
    pass('配对成功：deviceId=${pair.deviceId} token=${_mask(pair.token)}');

    // 4) 连 WebSocket。
    final client = RelayClient();
    final events = <RelayEvent>[];
    final eventStream = client.events.listen(events.add);
    await client.connect(scanned.baseUrl, token: pair.token);
    if (!client.isConnected) {
      fail('WebSocket 没连上');
    }
    pass('WebSocket 已连接');

    // 5) 等第一条 device.status（连接即推送）。
    final deviceStatus = await _firstWhere<RelayEvent>(
      client.events,
      (e) => e.type == 'device.status',
      const Duration(seconds: 10),
    );
    final status = DeviceStatusInfo.fromPayload(deviceStatus.payload);
    if (!status.online) {
      fail('device.status 说离线');
    }
    pass('device.status：${status.deviceName} / agent ${status.agentVersion}');

    // 6) 建会话。
    final created = Completer<String>();
    final output = StringBuffer();
    final done = Completer<RelayTaskState>();
    final subscription = client.events.listen((event) {
      switch (event.type) {
        case 'conversation.created':
          final payload = ConversationCreatedInfo.fromPayload(event.payload);
          if (!created.isCompleted) created.complete(payload.conversationId);
        case 'session.update':
          final update = SessionUpdate.fromPayload(event.payload);
          if (update.kind == SessionUpdateKind.output) {
            output.write(update.text);
          }
        case 'task.state':
          final task = TaskStateEvent.fromPayload(event.payload);
          if (_isTerminal(task.state) && !done.isCompleted) done.complete(task.state);
        case 'approval.request':
          // 这个检查只发一句普通提问，不该触发审批；真触发了就拒绝，避免卡住。
          final approval = ApprovalRequestInfo.fromPayload(event.payload);
          client.send('approval.decide', {
            'conversationId': approval.conversationId,
            'approvalId': approval.approvalId,
            'decision': 'denied',
          });
        case 'error':
          final error = RelayErrorInfo.fromPayload(event.payload);
          if (!done.isCompleted) {
            done.completeError(StateError('${error.code}: ${error.message}'));
          }
      }
    });

    if (!client.send('conversation.create', const {})) {
      fail('conversation.create 发送失败');
    }
    final conversationId = await created.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail('30s 内没有收到 conversation.created'),
    );
    pass('会话已创建：$conversationId');

    // 7) 发一句话，等 output + completed。
    if (!client.send('prompt.send', {
      'conversationId': conversationId,
      'text': '只回四个字：连接成功',
    })) {
      fail('prompt.send 发送失败');
    }
    final terminal = await done.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => fail('120s 内任务没有结束（output 目前：$output）'),
    );
    if (terminal != RelayTaskState.completed) {
      fail('任务终态是 ${terminal.wireName}，不是 completed（output：$output）');
    }
    final text = output.toString().trim();
    if (text.isEmpty) {
      fail('任务完成了但没有收到任何 output');
    }
    pass('收到回复：${text.length > 60 ? '${text.substring(0, 60)}…' : text}');

    await subscription.cancel();
    await eventStream.cancel();
    await client.disconnect();
    pass('断开连接');
    stdout.writeln('\nLIVE CHECK PASS (${steps.length})');
    exit(0);
  } on PairingApiException catch (error) {
    fail('配对/健康检查失败：${error.message}');
  } catch (error) {
    fail('异常：$error');
  }
}

String _mask(String token) =>
    token.length <= 8 ? '$token…' : '${token.substring(0, 8)}…';

bool _isTerminal(RelayTaskState state) =>
    state == RelayTaskState.completed ||
    state == RelayTaskState.failed ||
    state == RelayTaskState.cancelled;

Future<T> _firstWhere<T>(
  Stream<T> stream,
  bool Function(T value) test,
  Duration timeout,
) {
  return stream.firstWhere(test).timeout(
    timeout,
    onTimeout: () => throw StateError('等待超时'),
  );
}
