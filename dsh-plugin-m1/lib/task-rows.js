/**
 * M3.6：手机端「对话/会话」列表的行处理。
 *
 * 旧实现每行 `updatedAt = tracked.updatedAt || Date.now()`，同一批行会拿到
 * 同一个（或缺失的）时间，排序几乎随机；用户反馈「每次打开对话不是最新的」。
 * 现在统一用每行最后一条事件的时间排序，同名会话追加 HH:mm 后缀避免点错。
 */

export const HH_MM = (ms) => {
  const value = Number(ms);
  if (!Number.isFinite(value) || value <= 0) return '';
  try {
    return new Date(value).toLocaleTimeString('zh-CN', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });
  } catch {
    return '';
  }
};

const lastTimeOf = (row) => {
  const value = Number(row?.lastTime);
  if (Number.isFinite(value) && value > 0) return value;
  const updated = Date.parse(row?.updatedAt ?? '');
  return Number.isFinite(updated) && updated > 0 ? updated : 0;
};

/** 同名标题补「· HH:mm」后缀（只在重名时加，避免列表变啰嗦）。 */
export const labelDuplicateTitles = (rows) => {
  const counts = new Map();
  for (const row of rows) counts.set(row.title, (counts.get(row.title) ?? 0) + 1);
  for (const row of rows) {
    if ((counts.get(row.title) ?? 0) > 1) {
      const stamp = HH_MM(lastTimeOf(row));
      if (stamp) row.title = `${row.title} · ${stamp}`;
    }
  }
  return rows;
};

/** 按最后事件时间倒序，并限制条数；空时间排在最后且保持原有相对顺序。 */
export const sortByLastTime = (rows) => {
  return rows
    .map((row, index) => ({ row, index, time: lastTimeOf(row) }))
    .sort((a, b) => {
      if (b.time !== a.time) return b.time - a.time;
      return a.index - b.index;
    })
    .map((item) => item.row);
};

export const labelAndSortTasks = (rows, limit = 50) => {
  const list = Array.isArray(rows) ? rows : [];
  if (list.length === 0) return [];
  return sortByLastTime(labelDuplicateTitles(list))
    .slice(0, Math.max(1, Number(limit) || 50));
};
