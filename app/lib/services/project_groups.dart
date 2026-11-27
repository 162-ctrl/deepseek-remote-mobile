/// M4.13：把「工作区页」的卡片按项目分组。
///
/// 电脑上的 DSH 侧边栏是一棵「项目 → 会话」的树：一个项目目录下面挂它自己的会话。
/// 手机端以前是平铺的——每个目录一张卡、每个会话再一张卡，目录一多就分不清哪个
/// 会话属于哪个项目。
///
/// 这里只做纯数据整理（不碰 UI），方便单测：
/// 1. 把任务/存档按工作区路径归到各自的组；
/// 2. 没有会话的目录也留一个空组（M4.11 的「别让整页看起来全没了」）；
/// 3. 组内按最后活动时间从新到旧排，组间按「有运行中 > 有会话 > 有活动时间」排。
library;

/// 一个项目分组：一个工作区目录 + 它下面的会话。
class ProjectGroup<T> {
  ProjectGroup({
    required this.path,
    required this.name,
    this.parent = '',
    List<T>? items,
  }) : items = items ?? <T>[];

  /// 工作区在电脑上的绝对路径，作为分组 ID。
  final String path;

  /// 目录名（末段）。
  final String name;

  /// M4.13：父目录。用在「项目根」判断上——直接用目录分隔符后缀不行，
  /// 因为 Windows 路径 `D:\Projects\示例项目C` 的父目录是 `D:\Projects\项目`。
  final String parent;

  /// 这个项目下的会话，已按最后活动时间从新到旧排好。
  final List<T> items;

  bool get isEmpty => items.isEmpty;

  /// 是否是「项目根」（如 `D:\Projects\项目` 本身）——它自己的会话不归到别的分组里。
  bool get isRootLike => items.isEmpty && parent.isEmpty;
}

/// 路径的末段名（兼容 `\` 与 `/`，忽略末尾分隔符）。
String projectNameOf(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  if (trimmed.isEmpty) return path;
  final parts = trimmed.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? trimmed : parts.last;
}

/// 父目录（`D:\a\b` → `D:\a`；`D:\a` → 空串）。
String parentPathOf(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final index = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  if (index <= 0) return '';
  // 盘符根（`D:`）保留成 `D:\`，但当父目录用没有意义，直接当没有父目录。
  if (index == 2 && trimmed[1] == ':') return '';
  return trimmed.substring(0, index);
}

/// 把一个路径列表整理成项目分组；[itemsOf] 给出每个路径下挂的会话。
///
/// [extraRoots] 是「授权了但没有会话」的目录（M4.11 的空卡片）；
/// [maxOf] 用来给分组定组内/组间顺序——传 null 看作 0。
List<ProjectGroup<T>> groupWorkspacesByProject<T>({
  required Iterable<String> paths,
  required Iterable<T> Function(String path) itemsOf,
  required int Function(T item) maxOf,
  Iterable<String> extraRoots = const <String>[],
}) {
  final order = <String>[];
  final groups = <String, ProjectGroup<T>>{};

  void ensure(String raw) {
    final path = raw.trim();
    if (path.isEmpty) return;
    final key = path.replaceAll('/', '\\').replaceAll(RegExp(r'\\+$'), '');
    final existing = groups[key];
    if (existing != null) return;
    groups[key] = ProjectGroup<T>(
      path: path,
      name: projectNameOf(path),
      parent: parentPathOf(path),
    );
    order.add(key);
  }

  for (final path in paths) {
    ensure(path);
  }
  for (final root in extraRoots) {
    ensure(root);
  }
  for (final key in order) {
    final group = groups[key]!;
    final items = itemsOf(group.path).toList(growable: false);
    group.items
      ..clear()
      ..addAll(items)
      ..sort((a, b) => maxOf(b).compareTo(maxOf(a)));
  }

  final rows = order.map((key) => groups[key]!).toList(growable: false);
  // 组间顺序：有运行中的会话优先（列表里已经按运行数排过），再有会话的，最后空目录；
  // 同一档里靠组内最新活动时间。空目录之间保持原顺序（授权顺序）。
  final indexed = <(int, ProjectGroup<T>)>[
    for (var i = 0; i < rows.length; i++) (i, rows[i]),
  ];
  indexed.sort((a, b) {
    final ga = a.$2;
    final gb = b.$2;
    final aLive = ga.items.isEmpty ? 0 : 1;
    final bLive = gb.items.isEmpty ? 0 : 1;
    if (aLive != bLive) return bLive - aLive;
    final aMax = ga.items.isEmpty ? 0 : maxOf(ga.items.first);
    final bMax = gb.items.isEmpty ? 0 : maxOf(gb.items.first);
    if (aMax != bMax) return bMax - aMax;
    return a.$1 - b.$1;
  });
  return [for (final row in indexed) row.$2];
}
