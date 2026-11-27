/**
 * dsh-plugin-m1 · 设置页卡片（Client 半）
 *
 * 注册到 `settings.section`：在「设置」里给手机端插件一个真正的入口，
 * 展示中继状态、配对码、手机可用地址、应用内更新版本与授权目录。
 *
 * 数据来自 Host 半注册的同源路由 `GET /deepseek-remote/api/status`，
 * 所以不需要跨端口，也不需要处理 CORS。每 5 秒轮询一次。
 */
window.__ModuleLoader__.load({
  id: 'dsh-plugin-m1',
  factory(require) {
    const React = require('react');
    const h = React.createElement;

    const STR = {
      zh: {
        title: 'DeepSeek 手机端',
        subtitle: '让手机 App 通过配对码连接这台电脑上的 Harness。',
        running: '中继运行中',
        stopped: '中继未运行',
        relay: '连接状态',
        agent: 'Agent',
        agentOnline: '在线',
        agentOffline: '离线',
        apps: '已配对手机',
        port: '监听端口',
        pairing: '配对码',
        pairingHint: '在手机 App 里输入它，或直接扫下面的二维码。',
        scan: '扫码连接',
        scanHint: '手机 App 首页右上角的扫码按钮，对准下面任一二维码即可自动填好地址和配对码。',
        scanLan: 'Tailscale（任何网络）',
        scanTailnet: 'Tailscale 固定地址',
        scanWan: '公网（手机用流量也能连）',
        scanWanPending: '隧道启动中，稍后自动出现',
        openPairPage: '打开配网页',
        copy: '复制',
        copied: '已复制',
        addresses: '手机可用地址',
        publicUrl: '公网地址',
        none: '未开启',
        workspace: '授权目录',
        update: '手机端安装包',
        updateNone: 'dist 里没有找到 APK',
        updateHint: '手机端「我的 → 检查更新」会从这个插件下载。',
        pluginVersion: '插件版本',
        refresh: '刷新',
        loading: '正在读取…',
        failed: '读取失败：',
      },
      en: {
        title: 'DeepSeek Mobile',
        subtitle: 'Pair the phone app with the Harness running on this computer.',
        running: 'Relay running',
        stopped: 'Relay stopped',
        relay: 'Connection',
        agent: 'Agent',
        agentOnline: 'online',
        agentOffline: 'offline',
        apps: 'Paired phones',
        port: 'Port',
        pairing: 'Pairing code',
        pairingHint: 'Type it in the phone app, or scan the QR code below.',
        scan: 'Scan to connect',
        scanHint: 'Tap the scan button on the app home screen and point it at either code.',
        scanLan: 'Tailscale (any network)',
        scanTailnet: 'Fixed Tailscale address',
        scanWan: 'Public (works on mobile data)',
        scanWanPending: 'Tunnel starting, it will appear automatically',
        openPairPage: 'Open pairing page',
        copy: 'Copy',
        copied: 'Copied',
        addresses: 'Phone addresses',
        publicUrl: 'Public URL',
        none: 'off',
        workspace: 'Workspaces',
        update: 'Phone build',
        updateNone: 'No APK found in dist',
        updateHint: 'The phone checks for updates under Me → Check for updates.',
        pluginVersion: 'Plugin version',
        refresh: 'Refresh',
        loading: 'Loading…',
        failed: 'Failed: ',
      },
    };

    function useLocale(ctx) {
      const subscribe = React.useCallback(
        (notify) => {
          const svc = ctx.locale;
          if (svc && typeof svc.subscribe === 'function') return svc.subscribe(notify);
          if (typeof MutationObserver !== 'undefined' && typeof document !== 'undefined' && document.documentElement) {
            const observer = new MutationObserver(notify);
            observer.observe(document.documentElement, { attributes: true, attributeFilter: ['lang'] });
            return () => observer.disconnect();
          }
          return () => {};
        },
        [ctx],
      );
      const snapshot = React.useCallback(() => {
        const svc = ctx.locale;
        const active = svc && typeof svc.getLocale === 'function' ? svc.getLocale().active : '';
        if (active === 'zh' || active === 'en') return active;
        const lang = (typeof document !== 'undefined' && document.documentElement && document.documentElement.lang) || '';
        return lang.indexOf('zh') === 0 ? 'zh' : 'en';
      }, [ctx]);
      return React.useSyncExternalStore(subscribe, snapshot, snapshot);
    }

    function formatBytes(bytes) {
      const value = Number(bytes) || 0;
      if (value >= 1048576) return `${(value / 1048576).toFixed(1)} MB`;
      if (value >= 1024) return `${(value / 1024).toFixed(1)} KB`;
      return `${value} B`;
    }

    const styles = {
      root: {
        display: 'flex',
        flexDirection: 'column',
        gap: '14px',
        padding: '8px 4px 40px',
        color: 'var(--dsw-alias-label-primary)',
        fontSize: '14px',
        lineHeight: 1.55,
      },
      header: { display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: '12px' },
      title: { fontSize: '18px', fontWeight: 700, margin: 0 },
      subtitle: { margin: '4px 0 0', color: 'var(--dsw-alias-label-secondary)', fontSize: '13px' },
      card: {
        border: '1px solid var(--dsw-alias-border-l1)',
        background: 'var(--dsw-alias-bg-layer-1)',
        borderRadius: '14px',
        padding: '14px 16px',
        display: 'flex',
        flexDirection: 'column',
        gap: '10px',
      },
      cardTitle: { fontSize: '13px', fontWeight: 600, color: 'var(--dsw-alias-label-secondary)' },
      pill: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: '6px',
        borderRadius: '999px',
        padding: '3px 10px',
        fontSize: '12px',
        fontWeight: 600,
        background: 'var(--dsw-alias-bg-layer-2)',
        color: 'var(--dsw-alias-label-secondary)',
        whiteSpace: 'nowrap',
      },
      dot: (color) => ({ width: '7px', height: '7px', borderRadius: '999px', background: color }),
      row: { display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: '16px' },
      rowLabel: { color: 'var(--dsw-alias-label-secondary)', fontSize: '13px', flex: '0 0 auto' },
      rowValue: {
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        fontSize: '12.5px',
        textAlign: 'right',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      },
      code: {
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: '12px',
        background: 'var(--dsw-alias-bg-layer-2)',
        border: '1px solid var(--dsw-alias-border-l1)',
        borderRadius: '12px',
        padding: '10px 14px',
      },
      codeText: {
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        fontSize: '22px',
        fontWeight: 700,
        letterSpacing: '6px',
      },
      hint: { margin: 0, color: 'var(--dsw-alias-label-secondary)', fontSize: '12.5px' },
      qrRow: { display: 'flex', flexWrap: 'wrap', gap: '16px' },
      qrCard: { display: 'flex', flexDirection: 'column', gap: '8px', alignItems: 'center' },
      qrLabel: { fontSize: '12.5px', fontWeight: 600, color: 'var(--dsw-alias-label-secondary)' },
      qrBox: {
        width: '152px',
        height: '152px',
        padding: '8px',
        boxSizing: 'border-box',
        background: '#fff',
        border: '1px solid var(--dsw-alias-border-l1)',
        borderRadius: '12px',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      },
      qrSvg: { width: '100%', height: '100%', display: 'block' },
      qrUrl: {
        maxWidth: '152px',
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        fontSize: '10.5px',
        color: 'var(--dsw-alias-label-secondary)',
        textAlign: 'center',
        wordBreak: 'break-all',
      },
      actions: { display: 'flex', flexWrap: 'wrap', gap: '8px' },
      button: {
        appearance: 'none',
        border: '1px solid var(--dsw-alias-border-l2)',
        background: 'transparent',
        color: 'var(--dsw-alias-label-primary)',
        borderRadius: '999px',
        padding: '6px 14px',
        fontSize: '13px',
        cursor: 'pointer',
      },
      primary: {
        appearance: 'none',
        border: '1px solid transparent',
        background: 'var(--dsw-alias-brand-primary)',
        color: '#fff',
        borderRadius: '999px',
        padding: '6px 14px',
        fontSize: '13px',
        fontWeight: 600,
        cursor: 'pointer',
      },
      list: { display: 'flex', flexDirection: 'column', gap: '4px' },
      mono: {
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
        fontSize: '12px',
        color: 'var(--dsw-alias-label-secondary)',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      },
      error: { color: 'var(--dsw-alias-state-error-primary)', fontSize: '12.5px', margin: 0 },
    };

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        function useStatus() {
          const [state, setState] = React.useState({ loading: true, data: null, error: null });
          const load = React.useCallback(async () => {
            try {
              const response = await fetch('/deepseek-remote/api/status', {
                cache: 'no-store',
                headers: { accept: 'application/json' },
              });
              if (!response.ok) throw new Error(`HTTP ${response.status}`);
              setState({ loading: false, data: await response.json(), error: null });
            } catch (error) {
              setState((previous) => ({
                loading: false,
                data: previous.data,
                error: String((error && error.message) || error),
              }));
            }
          }, []);
          React.useEffect(() => {
            void load();
            const timer = setInterval(() => {
              void load();
            }, 5000);
            return () => clearInterval(timer);
          }, [load]);
          return { ...state, reload: load };
        }

        function copyText(text) {
          try {
            if (navigator.clipboard && navigator.clipboard.writeText) {
              void navigator.clipboard.writeText(text);
              return;
            }
          } catch {
            /* 落到下面的兜底 */
          }
          try {
            const el = document.createElement('textarea');
            el.value = text;
            el.style.position = 'fixed';
            el.style.opacity = '0';
            document.body.appendChild(el);
            el.select();
            document.execCommand('copy');
            document.body.removeChild(el);
          } catch {
            /* 复制失败就算了 */
          }
        }

        function SettingsSection() {
          const locale = useLocale(ctx);
          const t = (key) => (STR[locale] || STR.zh)[key];
          const { loading, data, error, reload } = useStatus();
          const [copied, setCopied] = React.useState('');

          const flashCopied = (kind) => {
            setCopied(kind);
            setTimeout(() => setCopied(''), 1600);
          };

          if (loading && !data) {
            return h('div', { style: styles.root }, h('p', { style: styles.hint }, t('loading')));
          }

          const online = Boolean(data && data.agentOnline);
          const port = data && data.port;
          const addresses = (data && data.lanUrls) || [];
          const publicUrl = data && data.publicUrl;
          const workspaces = (data && data.workspaces) || [];
          const update = data && data.appUpdate;
          const qr = data && data.qr;

          // 二维码由 Host 侧用同一份 qrcode.js 画成 SVG，内嵌进来即可，
          // 不依赖外网、也不用跨域取图。
          const qrCell = (label, entry, pendingText) =>
            h(
              'div',
              { key: label, style: styles.qrCard },
              h(
                'div',
                { style: styles.qrBox },
                entry && entry.svg
                  ? h('div', {
                      style: styles.qrSvg,
                      dangerouslySetInnerHTML: { __html: entry.svg },
                    })
                  : h('span', { style: styles.hint }, pendingText || '—'),
              ),
              h('span', { style: styles.qrLabel }, label),
              entry ? h('span', { style: styles.qrUrl }, entry.url) : null,
            );

          return h(
            'div',
            { style: styles.root },
            h(
              'div',
              { style: styles.header },
              h(
                'div',
                null,
                h('h2', { style: styles.title }, t('title')),
                h('p', { style: styles.subtitle }, t('subtitle')),
              ),
              h(
                'span',
                { style: styles.pill },
                h('span', { style: styles.dot(online ? 'var(--dsw-alias-state-success-primary)' : 'var(--dsw-alias-state-idle-primary)') }),
                online ? t('running') : t('stopped'),
              ),
            ),
            error ? h('p', { style: styles.error }, `${t('failed')}${error}`) : null,
            h(
              'section',
              { style: styles.card },
              h('div', { style: styles.cardTitle }, t('relay')),
              h(
                'div',
                { style: styles.row },
                h('span', { style: styles.rowLabel }, t('agent')),
                h(
                  'span',
                  { style: { ...styles.rowValue, color: online ? 'var(--dsw-alias-state-success-primary)' : 'var(--dsw-alias-label-secondary)' } },
                  online ? t('agentOnline') : t('agentOffline'),
                ),
              ),
              h(
                'div',
                { style: styles.row },
                h('span', { style: styles.rowLabel }, t('apps')),
                h('span', { style: styles.rowValue }, String((data && data.apps) ?? 0)),
              ),
              h(
                'div',
                { style: styles.row },
                h('span', { style: styles.rowLabel }, t('port')),
                h('span', { style: styles.rowValue }, port ? String(port) : '—'),
              ),
              h(
                'div',
                { style: styles.row },
                h('span', { style: styles.rowLabel }, t('pluginVersion')),
                h('span', { style: styles.rowValue }, data ? `v${data.pluginVersion}` : '—'),
              ),
            ),
            h(
              'section',
              { style: styles.card },
              h('div', { style: styles.cardTitle }, t('pairing')),
              h(
                'div',
                { style: styles.code },
                h('span', { style: styles.codeText }, (data && data.pairingCode) || '------'),
                h(
                  'button',
                  {
                    type: 'button',
                    style: styles.button,
                    onClick: () => {
                      copyText((data && data.pairingCode) || '');
                      flashCopied('code');
                    },
                  },
                  copied === 'code' ? t('copied') : t('copy'),
                ),
              ),
              h(
                'div',
                { style: styles.actions },
                h(
                  'button',
                  {
                    type: 'button',
                    style: styles.primary,
                    onClick: () => {
                      if (port) window.open(`http://127.0.0.1:${port}/`, '_blank', 'noopener');
                    },
                  },
                  t('openPairPage'),
                ),
                h('button', { type: 'button', style: styles.button, onClick: () => void reload() }, t('refresh')),
              ),
            ),
            h(
              'section',
              { style: styles.card },
              h('div', { style: styles.cardTitle }, t('scan')),
              h('p', { style: styles.hint }, t('scanHint')),
              h(
                'div',
                { style: styles.qrRow },
                qrCell(t('scanLan'), qr && (qr.tailnet || qr.lan)),
                qrCell(t('scanTailnet'), qr && qr.tailnet),
              ),
            ),
            h(
              'section',
              { style: styles.card },
              h('div', { style: styles.cardTitle }, t('addresses')),
              addresses.length === 0
                ? h('p', { style: styles.hint }, t('none'))
                : h(
                    'div',
                    { style: styles.list },
                    addresses.map((url) => h('span', { key: url, style: styles.mono }, url)),
                  ),
              h(
                'p',
                { style: styles.hint },
                '手机端优先用 Tailscale 固定地址；没装 Tailscale 时才会退回局域网地址。',
              ),
            ),
            h(
              'section',
              { style: styles.card },
              h('div', { style: styles.cardTitle }, t('update')),
              h(
                'div',
                { style: styles.row },
                h('span', { style: styles.rowValue }, update ? `v${update.versionName} · ${update.versionCode} · ${formatBytes(update.size)}` : t('updateNone')),
              ),
              h('p', { style: styles.hint }, t('updateHint')),
            ),
            workspaces.length > 0
              ? h(
                  'section',
                  { style: styles.card },
                  h('div', { style: styles.cardTitle }, t('workspace')),
                  h(
                    'div',
                    { style: styles.list },
                    workspaces.slice(0, 6).map((path) => h('span', { key: path, style: styles.mono }, path)),
                  ),
                )
              : null,
          );
        }

        ctx.slots.inject('settings.section', () =>
          ctx.slots.register(
            {
              name: 'settings.section',
              id: 'deepseek-remote',
              order: 40,
              label: () => (ctx.locale && ctx.locale.getLocale && ctx.locale.getLocale().active === 'en' ? 'DeepSeek Mobile' : 'DeepSeek 手机端'),
            },
            SettingsSection,
          ),
        );
      },
    };
  },
});
