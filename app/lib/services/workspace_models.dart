/// M2.6 项目同步（`workspace.list` / `file.read`）的数据模型与错误映射。
///
/// 这两种消息是 WSS 请求-响应，不进入会话消息流，也不参与 seq 去重；
/// LiveStore 用 `requestId` 把回包配对给挂起的 Future。
library;

/// M2.8：单次写入上限（与 Agent 端 `MAX_WRITE_BYTES` 保持一致）。
const int kMaxWorkspaceWriteBytes = 512 * 1024;

/// 目录/文件条目（`workspace.list.result.entries` 的元素）。
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.modifiedAt,
  });

  final String name;

  /// 相对工作区根的路径（如 `app/lib`）。
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modifiedAt;

  factory WorkspaceEntry.fromJson(Map<String, dynamic> json) {
    final rawSize = json['size'];
    final size = rawSize is num
        ? rawSize.toInt()
        : int.tryParse('$rawSize') ?? 0;
    final rawPath = json['path'];
    final rawName = json['name'];
    final name = rawName is String ? rawName : '';
    return WorkspaceEntry(
      name: name.isNotEmpty ? name : _lastSegment(rawPath is String ? rawPath : ''),
      path: rawPath is String ? rawPath : '',
      isDir: json['isDir'] == true,
      size: size < 0 ? 0 : size,
      modifiedAt: json['modifiedAt'] is String
          ? DateTime.tryParse(json['modifiedAt'] as String)
          : null,
    );
  }

  static String _lastSegment(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments =
        normalized.split('/').where((segment) => segment.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }
}

/// 一次目录列举的结果（`workspace.list.result`）。
class WorkspaceListing {
  const WorkspaceListing({
    required this.workspacePath,
    required this.relativePath,
    required this.entries,
    this.truncated = false,
    this.ignoredCount = 0,
  });

  final String workspacePath;
  final String relativePath;
  final List<WorkspaceEntry> entries;

  /// 条目超过 500 条时服务端只返回前 500 条并置 true。
  final bool truncated;

  /// 被忽略的目录（.git/node_modules 等）数量。
  final int ignoredCount;

  factory WorkspaceListing.fromResult(
    Map<String, dynamic> payload, {
    String workspacePath = '',
    String relativePath = '',
  }) {
    final rawEntries = payload['entries'];
    final entries = <WorkspaceEntry>[];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map<String, dynamic>) {
          entries.add(WorkspaceEntry.fromJson(item));
        }
      }
    }
    final rawIgnored = payload['ignoredCount'];
    return WorkspaceListing(
      workspacePath: payload['workspacePath'] is String
          ? payload['workspacePath'] as String
          : workspacePath,
      relativePath: payload['relativePath'] is String
          ? payload['relativePath'] as String
          : relativePath,
      entries: entries,
      truncated: payload['truncated'] == true,
      ignoredCount:
          rawIgnored is num ? rawIgnored.toInt() : 0,
    );
  }

  bool get isEmpty => entries.isEmpty;
}

/// 一次文件读取的结果（`file.read.result`）。
class WorkspaceFileContent {
  const WorkspaceFileContent({
    required this.relativePath,
    required this.content,
    required this.size,
    this.sha256 = '',
    this.truncated = false,
    this.binary = false,
    this.modifiedAt,
    this.workspacePath = '',
  });

  final String workspacePath;
  final String relativePath;
  final String content;

  /// 服务端文件总字节数（截断时仍为完整大小）。
  final int size;
  final String sha256;

  /// 超过 `maxBytes`/1 MiB 时只返回前 N 字节并置 true。
  final bool truncated;

  /// 前 8KB 含 NUL 字节（二进制）时置 true。
  final bool binary;
  final DateTime? modifiedAt;

  factory WorkspaceFileContent.fromResult(Map<String, dynamic> payload) {
    final rawSize = payload['size'];
    final size = rawSize is num ? rawSize.toInt() : 0;
    return WorkspaceFileContent(
      workspacePath:
          payload['workspacePath'] is String ? payload['workspacePath'] as String : '',
      relativePath: payload['relativePath'] is String
          ? payload['relativePath'] as String
          : '',
      content: payload['content'] is String ? payload['content'] as String : '',
      size: size < 0 ? 0 : size,
      sha256: payload['sha256'] is String ? payload['sha256'] as String : '',
      truncated: payload['truncated'] == true,
      binary: payload['binary'] == true,
      modifiedAt: payload['modifiedAt'] is String
          ? DateTime.tryParse(payload['modifiedAt'] as String)
          : null,
    );
  }

  /// sha256 前 8 位（UI 顶部展示用）。
  String get sha256Short =>
      sha256.length > 8 ? sha256.substring(0, 8) : sha256;
}

/// 一次写入的结果（`file.write.result`，M2.8）。
class WorkspaceWriteResult {
  const WorkspaceWriteResult({
    required this.relativePath,
    required this.size,
    this.workspacePath = '',
    this.sha256 = '',
    this.created = false,
    this.modifiedAt,
  });

  final String workspacePath;
  final String relativePath;

  /// 写入后的文件字节数。
  final int size;

  /// 写入后文件内容的 sha256（用于立即刷新预览/继续编辑）。
  final String sha256;

  /// 本次是否新建了文件。
  final bool created;
  final DateTime? modifiedAt;

  factory WorkspaceWriteResult.fromResult(Map<String, dynamic> payload) {
    final rawSize = payload['size'];
    final size = rawSize is num ? rawSize.toInt() : 0;
    return WorkspaceWriteResult(
      workspacePath: payload['workspacePath'] is String
          ? payload['workspacePath'] as String
          : '',
      relativePath: payload['relativePath'] is String
          ? payload['relativePath'] as String
          : '',
      size: size < 0 ? 0 : size,
      sha256: payload['sha256'] is String ? payload['sha256'] as String : '',
      created: payload['created'] == true,
      modifiedAt: payload['modifiedAt'] is String
          ? DateTime.tryParse(payload['modifiedAt'] as String)
          : null,
    );
  }

  String get sha256Short =>
      sha256.length > 8 ? sha256.substring(0, 8) : sha256;
}

/// `workspace.list` / `file.read` 失败时抛出的可展示异常。
class WorkspaceRequestException implements Exception {
  const WorkspaceRequestException(this.code, [this.message = '']);

  /// 契约错误码：PATH_NOT_ALLOWED / DIR_NOT_FOUND / FILE_NOT_FOUND /
  /// IS_A_DIRECTORY / BINARY_FILE / TOO_LARGE / FILE_EXISTS / CONFLICT /
  /// BAD_REQUEST / INTERNAL / OFFLINE / TIMEOUT。
  final String code;
  final String message;

  /// 中文可行动提示（UI 直接展示）。
  String get friendlyMessage => workspaceErrorLabel(code, message);

  @override
  String toString() => 'WorkspaceRequestException($code): $message';
}

/// 错误码 → 中文提示。
String workspaceErrorLabel(String code, [String? message]) {
  final mapped = workspaceErrorLabels[code];
  if (mapped != null) return mapped;
  if (message != null && message.trim().isNotEmpty) return message.trim();
  return '请求失败（$code）';
}

const Map<String, String> workspaceErrorLabels = <String, String>{
  'OFFLINE': '电脑端未连接，请先连接电脑',
  'TIMEOUT': '请求超时：电脑端没有响应，请重试',
  'PATH_NOT_ALLOWED': '不在授权范围内，无法访问该路径',
  'DIR_NOT_FOUND': '目录不存在或已被移动',
  'NOT_A_DIRECTORY': '这不是一个文件夹',
  'FILE_NOT_FOUND': '文件不存在或已被移动',
  'IS_A_DIRECTORY': '这是一个文件夹，不能当文件操作',
  'BINARY_FILE': '二进制文件不支持预览或编辑',
  'TOO_LARGE': '内容过大（预览上限 1 MiB，写入上限 512 KiB）',
  'INTERNAL': '电脑端处理出错，请稍后重试',
  'BAD_REQUEST': '请求内容不完整，请重试',
  'FILE_EXISTS': '目标文件已存在，请换个名字或先打开它',
  'CONFLICT': '文件已在电脑上被改动，请重新加载后再保存',
};
