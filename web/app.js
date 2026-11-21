(() => {
  "use strict";

  const SEGMENTS = 20;

  // ================= Provider SVG Icons =================
  const ICONS = {
    codex: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="#18181b" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 3.2c2.1 0 3.9 1.2 4.7 3 1.9.2 3.5 1.7 3.8 3.6.3 1.9-.6 3.8-2.2 4.8.2 1.9-.9 3.8-2.7 4.5-1.8.8-3.9.2-5.1-1.2-1.8.7-3.9.1-5.1-1.4-1.2-1.5-1.2-3.7-.1-5.2-.7-1.8-.1-3.9 1.4-5.1 1.3-1 3-1.3 4.6-.7.2-.2.4-.3.7-.3z"/>
      <circle cx="12" cy="12" r="2.7"/>
    </svg>`,
    claude: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none">
      <g stroke="#d97757" stroke-width="2" stroke-linecap="round">
        <line x1="12" y1="3.5" x2="12" y2="8.5"/>
        <line x1="12" y1="15.5" x2="12" y2="20.5"/>
        <line x1="3.5" y1="12" x2="8.5" y2="12"/>
        <line x1="15.5" y1="12" x2="20.5" y2="12"/>
        <line x1="6" y1="6" x2="9.5" y2="9.5"/>
        <line x1="14.5" y1="14.5" x2="18" y2="18"/>
        <line x1="18" y1="6" x2="14.5" y2="9.5"/>
        <line x1="9.5" y1="14.5" x2="6" y2="18"/>
      </g>
    </svg>`,
    antigravity: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none">
      <path d="M12 3.2L14.3 9.7L20.8 12L14.3 14.3L12 20.8L9.7 14.3L3.2 12L9.7 9.7L12 3.2Z" fill="#7c3aed"/>
    </svg>`,
    cursor: `<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="#2563eb" stroke-width="1.8" stroke-linejoin="round">
      <polygon points="12 3 20 7.5 20 16.5 12 21 4 16.5 4 7.5 12 3"/>
      <polyline points="12 12 20 7.5"/>
      <polyline points="12 12 12 21"/>
      <polyline points="12 12 4 7.5"/>
    </svg>`,
    gemini: `<svg viewBox="0 0 24 24" width="19" height="19" fill="none">
      <path d="M12 3C13.2 8.2 15.8 10.8 21 12C15.8 13.2 13.2 15.8 12 21C10.8 15.8 8.2 13.2 3 12C8.2 10.8 10.8 8.2 12 3Z" fill="#2563eb"/>
    </svg>`,
    deepseek: `<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="#0284c7" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
      <path d="M4 13c2-5 7-7 13-6 2 1 3 3 3 5-1 4-6 6-11 5-2-.4-4-2-5-4z"/>
      <circle cx="15.5" cy="10.5" r="1" fill="#0284c7"/>
    </svg>`,
    copilot: `<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="#18181b" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
      <rect x="4" y="8" width="16" height="10" rx="5"/>
      <circle cx="9.5" cy="13" r="1.4" fill="#18181b"/>
      <circle cx="14.5" cy="13" r="1.4" fill="#18181b"/>
      <path d="M8 8V6a4 4 0 0 1 8 0v2"/>
    </svg>`,
    default: `<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="#4b5563" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="12" cy="12" r="8"/>
      <circle cx="12" cy="12" r="3"/>
    </svg>`
  };

  function iconForProvider(providerID) {
    const key = (providerID || "").toLowerCase();
    if (key.includes("codex") || key.includes("openai")) return ICONS.codex;
    if (key.includes("claude")) return ICONS.claude;
    if (key.includes("antigravity")) return ICONS.antigravity;
    if (key.includes("cursor")) return ICONS.cursor;
    if (key.includes("gemini")) return ICONS.gemini;
    if (key.includes("deepseek")) return ICONS.deepseek;
    if (key.includes("copilot")) return ICONS.copilot;
    return ICONS.default;
  }

  // ================= Exact Replica Showcase Dataset =================
  function createShowcaseAccounts(tiers) {
    const codexTier = tiers.codex;
    const claudeTier = tiers.claude;

    return [
      {
        id: "showcase-codex",
        providerID: "codex",
        name: "Codex",
        subtitle: `GPT-6 Astra · ${codexTier.plan}`,
        ringPercent: 5,
        status: { label: "今日将耗尽", tone: "danger" },
        pillSummary: `Codex 5% · 约 2 天用不了 · ${codexTier.cards} 张卡`,
        windows: [
          {
            id: "codex-5h",
            label: "5 小时窗口 · 今天 12:30",
            remainingPercent: 74,
            barColor: "green",
            resetHint: "今天 12:30 重置"
          },
          {
            id: "codex-week",
            label: "本周总配额 · 周日 19:00 · 约 2 天用不了",
            remainingPercent: 5,
            barColor: "red",
            pacePercent: 71,
            resetCardTarget: true,
            resetHint: "周日 19:00 自然重置"
          }
        ],
        footerNote: "本周剩余 5% · 距自然重置约 2 天",
        resetCards: {
          supported: true,
          count: codexTier.cards,
          suggested: true
        },
        rateInfo: {
          burnRate: "约 16.4% / 天",
          eta: "预计 3.2 小时后触顶",
          source: "Codex OAuth 配额接口（示意）",
          freshness: "刚刚更新 · 实时"
        }
      },
      {
        id: "showcase-claude",
        providerID: "claude",
        name: "Claude 小号 3",
        subtitle: `Opus 5.5 · ${claudeTier.plan}`,
        ringPercent: 45,
        status: { label: "节奏健康", tone: "healthy" },
        pillSummary: `Claude 小号 3 45% · ${claudeTier.cards} 张卡`,
        windows: [
          {
            id: "claude-5h",
            label: "5 小时窗口 · 今天 14:20",
            remainingPercent: 82,
            barColor: "green",
            resetHint: "今天 14:20 重置"
          },
          {
            id: "claude-week",
            label: "本周总配额 · 周一 09:00",
            remainingPercent: 45,
            barColor: "green",
            resetCardTarget: true,
            resetHint: "周一 09:00 自然重置"
          }
        ],
        footerNote: "Opus 5.5 充足 · 距重置还剩 3 天",
        resetCards: {
          supported: true,
          count: claudeTier.cards,
          suggested: false
        },
        rateInfo: {
          burnRate: "约 13.8% / 天",
          eta: "按当前节奏可稳定覆盖至周一重置",
          source: "Claude OAuth Usage（示意）",
          freshness: "刚刚更新 · 实时"
        }
      },
      {
        id: "showcase-antigravity",
        providerID: "antigravity",
        name: "Antigravity",
        subtitle: "Gemini 4 Neon · 全量池",
        ringPercent: 98,
        status: { label: "极度充裕", tone: "healthy" },
        pillSummary: "Antigravity 98%",
        windows: [
          {
            id: "ag-pro",
            label: "Gemini 4 / Pro 池 · 下周四 10:00",
            remainingPercent: 98,
            barColor: "green",
            resetHint: "下周四 10:00 重置"
          },
          {
            id: "ag-flash",
            label: "Flash 极速池 · 持续充盈",
            remainingPercent: 100,
            barColor: "blue",
            resetHint: "滑动窗口自动补给"
          }
        ],
        footerNote: "最佳兜底主力 · 支持 2M 上下文",
        resetCards: {
          supported: false,
          count: 0,
          suggested: false
        },
        rateInfo: {
          burnRate: "约 1.2% / 天",
          eta: "极度充裕，适合作为高负载主力兜底",
          source: "Antigravity 本机配额池（示意）",
          freshness: "刚刚更新 · 实时"
        }
      }
    ];
  }

  // ================= Fallback Built-in Multi-Provider Demo Dataset =================
  function createFallbackFullDemoAccounts() {
    return [
      ...createShowcaseAccounts(state.tiers),
      {
        id: "demo-cursor",
        providerID: "cursor",
        name: "Cursor",
        subtitle: "Pro · 本月快速请求池",
        ringPercent: 64,
        status: { label: "节奏健康", tone: "healthy" },
        pillSummary: "Cursor 64%",
        windows: [
          {
            id: "cursor-fast",
            label: "月度快速额度 · 180 / 500 已用",
            remainingPercent: 64,
            barColor: "green",
            pacePercent: 52,
            resetHint: "12 天后重置"
          }
        ],
        footerNote: "剩余 320 次快速请求 · 预算充裕",
        resetCards: { supported: false, count: 0, suggested: false },
        rateInfo: {
          burnRate: "约 15 次 / 天",
          eta: "预计月底剩余 ~28%",
          source: "Cursor Usage API（演示夹具）",
          freshness: "演示数据"
        }
      },
      {
        id: "demo-deepseek",
        providerID: "deepseek",
        name: "DeepSeek",
        subtitle: "API 余额 · 按量计费",
        ringPercent: 86,
        status: { label: "余额充裕", tone: "healthy" },
        pillSummary: "DeepSeek 86%",
        windows: [
          {
            id: "ds-bal",
            label: "账户可用余额比例 · ¥86.40 剩余",
            remainingPercent: 86,
            barColor: "blue",
            resetHint: "无周期重置"
          }
        ],
        extraMetrics: ["API 余额 ¥86.40", "本月花费 ¥13.60"],
        footerNote: "独立 API 花费轨道 · 与订阅配额分列",
        resetCards: { supported: false, count: 0, suggested: false },
        rateInfo: {
          burnRate: "约 ¥1.10 / 天",
          eta: "按当前速率可用 78 天",
          source: "DeepSeek Balance API（演示夹具）",
          freshness: "演示数据"
        }
      }
    ];
  }

  // ================= Transform AIQuotyCore JSON -> Dashboard View Model =================
  function formatCountdown(isoDate) {
    if (!isoDate) return "";
    const target = new Date(isoDate);
    if (Number.isNaN(target.getTime())) return "";
    const diffSec = Math.round((target.getTime() - Date.now()) / 1000);
    if (diffSec <= 0) return "即将重置";
    const hours = Math.floor(diffSec / 3600);
    const mins = Math.floor((diffSec % 3600) / 60);
    if (hours >= 48) {
      return `约 ${Math.round(hours / 24)} 天后重置`;
    }
    if (hours >= 1) {
      return `${hours} 小时 ${mins} 分后重置`;
    }
    return `${Math.max(1, mins)} 分钟后重置`;
  }

  function mapCoreSnapshotToCard(snap) {
    const account = snap.account || {};
    const rawWindows = Array.isArray(snap.windows) ? snap.windows : [];
    const mappedWindows = rawWindows.map((w, idx) => {
      let remFrac = typeof w.remainingFraction === "number" ? w.remainingFraction : null;
      if (remFrac === null && typeof w.usedFraction === "number") {
        remFrac = Math.max(0, Math.min(1, 1 - w.usedFraction));
      }
      const remPct = remFrac !== null ? Math.round(remFrac * 100) : null;
      const resetText = w.resetKnown ? formatCountdown(w.resetsAt) : "";
      const label = resetText ? `${w.title} · ${resetText}` : w.title;

      let barColor = "green";
      if (remPct !== null) {
        if (remPct <= 15) barColor = "red";
        else if (remPct <= 35) barColor = "amber";
        else if (idx === 1 && (account.providerID || "").includes("antigravity")) barColor = "blue";
      }

      return {
        id: w.id || `${account.id}-w-${idx}`,
        label,
        remainingPercent: remPct ?? 0,
        unknown: remPct === null,
        barColor,
        resetCardTarget: idx === rawWindows.length - 1,
        resetHint: resetText || "重置时间未知",
        sourceLabel: w.source?.label || "",
        freshness: w.freshness || "fresh"
      };
    });

    // Primary remaining percentage: take the minimum known remaining window (bottleneck)
    const knownPcts = mappedWindows.filter((w) => !w.unknown).map((w) => w.remainingPercent);
    const primaryPct = knownPcts.length > 0 ? Math.min(...knownPcts) : 100;

    let status = { label: "节奏健康", tone: "healthy" };
    if (snap.connection === "rateLimited") {
      status = { label: "已限流", tone: "warn" };
    } else if (snap.connection === "error" || snap.lastError) {
      status = { label: "连接异常", tone: "danger" };
    } else if (knownPcts.length === 0) {
      status = { label: "按量 / 日志", tone: "neutral" };
    } else if (primaryPct <= 15) {
      status = { label: "即将耗尽", tone: "danger" };
    } else if (primaryPct <= 35) {
      status = { label: "余量偏紧", tone: "warn" };
    } else if (primaryPct >= 85) {
      status = { label: "极度充裕", tone: "healthy" };
    }

    const extraMetrics = [];
    (snap.spendMetrics || []).forEach((m) => {
      if (m.display) extraMetrics.push(`API 花费 ${m.display}`);
    });
    (snap.localTokenMetrics || []).forEach((m) => {
      if (m.display) extraMetrics.push(`本地日志 ${m.display}`);
    });

    const subtitleParts = [account.planLabel, account.email].filter(Boolean);
    const subtitle = subtitleParts.length > 0 ? subtitleParts.join(" · ") : account.providerID;

    const note = snap.lastError
      ? `异常：${snap.lastError}`
      : (snap.notes && snap.notes[0]) || (knownPcts.length > 0 ? `最低窗口剩余 ${primaryPct}%` : "无订阅配额窗口");

    return {
      id: account.id || `${account.providerID}-${Math.random()}`,
      providerID: account.providerID || "unknown",
      name: account.displayName || account.providerID || "未知账号",
      subtitle,
      ringPercent: knownPcts.length > 0 ? primaryPct : null,
      status,
      pillSummary: knownPcts.length > 0 ? `${account.displayName} ${primaryPct}%` : `${account.displayName} · 仅花费/日志`,
      windows: mappedWindows,
      extraMetrics,
      footerNote: note,
      resetCards: { supported: false, count: 0, suggested: false },
      rateInfo: {
        burnRate: knownPcts.length > 0 ? `当前瓶颈窗口剩余 ${primaryPct}%` : "按量计费 / 本地统计",
        eta: mappedWindows[0]?.resetHint || "暂无重置倒计时",
        source: mappedWindows[0]?.sourceLabel || "AIQuotyCore 本机采集",
        freshness: snap.lastSuccessAt ? `更新于 ${new Date(snap.lastSuccessAt).toLocaleTimeString("zh-CN")}` : "刚刚"
      }
    };
  }

  // ================= Application State =================
  const state = {
    mode: "live", // 'live' | 'demo'
    tiers: {
      codex: { key: "pro", plan: "ChatGPT Pro", cards: 4 },
      claude: { key: "max20x", plan: "Claude Max 20x", cards: 4 }
    },
    resetPreviewIds: new Set(),
    highlightedCardId: null,
    fallbackIndex: 0,
    accounts: [],
    dataSourceLabel: "本机实时采集",
    toastMessage: ""
  };

  // ================= DOM References =================
  const elMiniStrip = document.getElementById("miniStrip");
  const elHealthEyebrow = document.getElementById("healthEyebrow");
  const elHealthHeadline = document.getElementById("healthHeadline");
  const elHealthPills = document.getElementById("healthPills");
  const elBentoGrid = document.getElementById("bentoGrid");
  const elStatusToast = document.getElementById("statusToast");
  const elRefreshBtn = document.getElementById("refreshBtn");
  const elRateModalBackdrop = document.getElementById("rateModalBackdrop");
  const elRateModalTitle = document.getElementById("rateModalTitle");
  const elRateModalSub = document.getElementById("rateModalSub");
  const elRateModalIcon = document.getElementById("rateModalIcon");
  const elRateModalBody = document.getElementById("rateModalBody");
  const elRateModalClose = document.getElementById("rateModalClose");

  // ================= Helpers =================
  function ringColor(pct) {
    if (pct === null || pct === undefined) return "#9ca3af";
    if (pct <= 15) return "#ef4444";
    if (pct <= 35) return "#f59e0b";
    return "#22c55e";
  }

  function renderMiniRing(pct) {
    const r = 6;
    const c = 2 * Math.PI * r;
    const clamped = Math.max(0, Math.min(100, pct ?? 0));
    const offset = c * (1 - clamped / 100);
    const stroke = ringColor(pct);
    return `<svg width="16" height="16" viewBox="0 0 16 16" style="transform:rotate(-90deg);flex-shrink:0">
      <circle cx="8" cy="8" r="${r}" fill="none" stroke="#e5e7eb" stroke-width="2.2"/>
      <circle cx="8" cy="8" r="${r}" fill="none" stroke="${stroke}" stroke-width="2.2" stroke-linecap="round"
        stroke-dasharray="${c.toFixed(2)}" stroke-dashoffset="${offset.toFixed(2)}"/>
    </svg>`;
  }

  function renderCardRing(pct) {
    const r = 18;
    const c = 2 * Math.PI * r;
    const val = pct === null || pct === undefined ? 0 : Math.max(0, Math.min(100, pct));
    const offset = c * (1 - val / 100);
    const stroke = ringColor(pct);
    const display = pct === null || pct === undefined ? "—" : `${val}%`;
    return `<div class="ring-wrap" aria-label="剩余 ${display}">
      <svg class="ring-svg" viewBox="0 0 44 44">
        <circle class="ring-track" cx="22" cy="22" r="${r}"/>
        <circle class="ring-progress" cx="22" cy="22" r="${r}"
          stroke="${stroke}"
          stroke-dasharray="${c.toFixed(2)}"
          stroke-dashoffset="${offset.toFixed(2)}"/>
      </svg>
      <span class="ring-value">${display}</span>
    </div>`;
  }

  function renderSegmentedBar(win, isPreviewActive) {
    const filledCount = win.unknown
      ? 0
      : Math.max(win.remainingPercent > 0 ? 1 : 0, Math.round((win.remainingPercent / 100) * SEGMENTS));
    const showPreview = isPreviewActive && win.resetCardTarget;

    let segmentsHTML = "";
    for (let i = 0; i < SEGMENTS; i++) {
      let cls = "segment";
      if (i < filledCount) {
        cls += ` fill-${win.barColor || "green"}`;
      } else if (showPreview) {
        cls += " is-preview-recover";
      }
      segmentsHTML += `<span class="${cls}"></span>`;
    }

    const paceHTML =
      typeof win.pacePercent === "number"
        ? `<span class="pace-marker" style="left:${win.pacePercent}%" title="当前周期时间进度 ${win.pacePercent}%"></span>`
        : "";

    const valueHTML = win.unknown
      ? `未知`
      : showPreview
        ? `${win.remainingPercent}%<span class="window-preview-arrow"> → 100%</span>`
        : `${win.remainingPercent}%`;

    return `<div class="window-item">
      <div class="window-meta">
        <span class="window-label">${escapeHTML(win.label)}</span>
        <span class="window-value">${valueHTML}</span>
      </div>
      <div class="segment-bar-wrap">
        <div class="segment-bar">${segmentsHTML}</div>
        ${paceHTML}
      </div>
    </div>`;
  }

  function escapeHTML(str) {
    return String(str ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // ================= Render Sections =================
  function renderMiniStrip() {
    const topItems = state.accounts.slice(0, 3);
    const itemsHTML = topItems
      .map(
        (acc) => `<button class="mini-item" data-focus-card="${escapeHTML(acc.id)}">
          ${renderMiniRing(acc.ringPercent)}
          <span class="mini-item-name">${escapeHTML(acc.name)}</span>
          <span class="mini-item-pct">${acc.ringPercent !== null ? acc.ringPercent + "%" : "—"}</span>
        </button>`
      )
      .join("");
    elMiniStrip.innerHTML = `<span class="mini-strip-label">本周剩余</span>${itemsHTML}`;
  }

  function renderHealthBanner() {
    const accounts = state.accounts;
    const critical = accounts.filter((a) => a.status.tone === "danger");
    const healthy = accounts.filter((a) => a.status.tone === "healthy");
    const warn = accounts.filter((a) => a.status.tone === "warn");

    elHealthEyebrow.textContent = `全局额度健康度 · ${accounts.length} 个已接入订阅 · ${state.dataSourceLabel}`;

    if (accounts.length === 0) {
      elHealthHeadline.textContent = "暂未检测到已接入账号";
    } else if (critical.length > 0) {
      const parts = [`${critical.length} 个账号今日将耗尽`];
      if (warn.length > 0) parts.push(`${warn.length} 个偏紧`);
      if (healthy.length > 0) parts.push(`${healthy.length} 个充裕`);
      elHealthHeadline.textContent = parts.join("，");
    } else if (warn.length > 0) {
      elHealthHeadline.textContent = `${warn.length} 个账号余量偏紧，${healthy.length} 个充裕`;
    } else {
      elHealthHeadline.textContent = `全部 ${accounts.length} 个账号额度充裕`;
    }

    elHealthPills.innerHTML = accounts
      .map((acc) => {
        const toneClass =
          acc.status.tone === "danger"
            ? "pill-danger"
            : acc.status.tone === "warn"
              ? "pill-warn"
              : acc.status.tone === "healthy"
                ? "pill-healthy"
                : "pill-neutral";
        return `<button class="health-pill ${toneClass}" data-focus-card="${escapeHTML(acc.id)}">
          ${escapeHTML(acc.pillSummary)}
        </button>`;
      })
      .join("");
  }

  function renderAccountCard(acc) {
    const isPreviewActive = state.resetPreviewIds.has(acc.id);
    const isHighlighted = state.highlightedCardId === acc.id;

    const badgeClass =
      acc.status.tone === "danger"
        ? "pill-danger"
        : acc.status.tone === "warn"
          ? "pill-warn"
          : acc.status.tone === "healthy"
            ? "pill-healthy"
            : "pill-neutral";

    const windowsHTML =
      acc.windows.length > 0
        ? acc.windows.map((w) => renderSegmentedBar(w, isPreviewActive)).join("")
        : `<div class="window-item"><span class="window-label">该服务未上报周期配额窗口，仅追踪下方独立指标。</span></div>`;

    const extraMetricsHTML =
      acc.extraMetrics && acc.extraMetrics.length > 0
        ? `<div class="extra-metrics">${acc.extraMetrics
            .map((m) => `<span class="metric-chip">${escapeHTML(m)}</span>`)
            .join("")}</div>`
        : "";

    let resetBtnHTML = "";
    if (acc.resetCards && acc.resetCards.supported) {
      const btnCls = isPreviewActive
        ? "reset-card-btn is-active"
        : acc.resetCards.suggested
          ? "reset-card-btn is-suggested"
          : "reset-card-btn is-default";
      const label =
        !isPreviewActive && acc.resetCards.suggested
          ? `重置卡 ×${acc.resetCards.count} · 建议用`
          : `重置卡 ×${acc.resetCards.count}`;
      resetBtnHTML = `<button class="${btnCls}" data-toggle-reset="${escapeHTML(acc.id)}" title="点击预览使用重置卡后的恢复效果">
        <svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor" aria-hidden="true">
          <path d="M9.5 1.5L3.8 8.7h4l-1.3 5.8 5.7-7.2h-4l1.3-5.8z"/>
        </svg>
        <span>${label}</span>
      </button>`;
    }

    return `<article class="surface quota-card ${isHighlighted ? "is-highlighted" : ""}" data-card-id="${escapeHTML(acc.id)}">
      <div class="card-header">
        <div class="card-identity">
          <div class="provider-icon">${iconForProvider(acc.providerID)}</div>
          <div class="card-title-block">
            <div class="card-title-row">
              <h2 class="card-name">${escapeHTML(acc.name)}</h2>
              <span class="status-badge ${badgeClass}">${escapeHTML(acc.status.label)}</span>
            </div>
            <p class="card-subtitle">${escapeHTML(acc.subtitle)}</p>
          </div>
        </div>
        ${renderCardRing(acc.ringPercent)}
      </div>

      <div class="windows-list">
        ${windowsHTML}
        ${extraMetricsHTML}
      </div>

      <div class="card-footer">
        <span class="footer-note" title="${escapeHTML(acc.footerNote)}">${escapeHTML(acc.footerNote)}</span>
        <div class="footer-actions">
          ${resetBtnHTML}
          <button class="rate-btn" data-open-rate="${escapeHTML(acc.id)}">
            <svg viewBox="0 0 16 16" width="11.5" height="11.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
              <path d="M13 8a5 5 0 1 1-1.4-3.5L13 6"/>
              <path d="M13 2.8V6H9.8"/>
            </svg>
            <span>速率</span>
          </button>
        </div>
      </div>
    </article>`;
  }

  function renderCompassCard() {
    const accounts = state.accounts;
    const healthyOrbits = accounts.filter((a) => a.status.tone === "healthy");
    const alertOrbits = accounts.filter((a) => a.status.tone === "danger" || a.status.tone === "warn");

    const sortedBackups = [...healthyOrbits].sort((a, b) => (b.ringPercent ?? 0) - (a.ringPercent ?? 0));
    const chosenBackup = sortedBackups.length > 0 ? sortedBackups[state.fallbackIndex % sortedBackups.length] : null;
    const criticalAccount = alertOrbits[0] || null;

    let headline = "全局算力充裕";
    if (accounts.length === 0) {
      headline = "等待接入算力轨道";
    } else if (healthyOrbits.length === 0) {
      headline = "全局算力偏紧";
    }

    let desc = "所有已接入订阅均处于健康水位，可放心执行高并发与长上下文任务。";
    if (criticalAccount && chosenBackup) {
      const cardHint =
        criticalAccount.resetCards && criticalAccount.resetCards.supported
          ? `可直接使用 ${state.tiers.codex.key === "pro" ? "Pro" : "Plus"} 档周重置卡，或`
          : "建议立即";
      desc = `${criticalAccount.name} 临近耗尽：${cardHint}切换 ${chosenBackup.name} ${chosenBackup.ringPercent ?? 100}% 替补。`;
    } else if (criticalAccount) {
      desc = `${criticalAccount.name} 余量告急，建议放缓调用频率或启用备用 API 通道。`;
    }

    return `<article class="surface compass-card" aria-label="AIQuoty · 算力罗盘">
      <div class="compass-header">
        <span class="compass-tag">AIQuoty · 算力罗盘</span>
        <button class="compass-switch-btn" id="switchBackupBtn" title="轮换并高亮推荐的备用算力轨道">
          <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="M2.5 5.5h11M10.5 2.8l3 2.7-3 2.7"/>
            <path d="M13.5 10.5h-11M5.5 7.8l-3 2.7 3 2.7"/>
          </svg>
          <span>切换备用</span>
        </button>
      </div>

      <div class="compass-body">
        <div class="compass-radar" aria-hidden="true">
          <svg viewBox="0 0 110 110">
            <!-- Outer & inner orbital rings -->
            <circle cx="55" cy="55" r="46" fill="none" stroke="#e5e7eb" stroke-width="1.2" stroke-dasharray="3 3"/>
            <circle cx="55" cy="55" r="32" fill="none" stroke="#e9ebf0" stroke-width="1.3"/>
            <circle cx="55" cy="55" r="18" fill="none" stroke="#f1f2f6" stroke-width="1.2"/>
            <!-- Abundant emerald orbital arc -->
            <path class="radar-pulse" d="M 85 45 A 32 32 0 0 1 55 87" fill="none" stroke="#22c55e" stroke-width="2.4" stroke-linecap="round"/>
            <!-- Center compass node -->
            <circle cx="55" cy="55" r="4.2" fill="#8b5cf6" opacity="0.22"/>
            <circle cx="55" cy="55" r="2.6" fill="#7c3aed"/>
            <!-- Orbital dots: blue (Flash/Pro), green (Healthy), rose (Alert) -->
            <circle cx="33" cy="24" r="3.4" fill="#3b82f6"/>
            <circle cx="81" cy="70" r="3.6" fill="#22c55e"/>
            <circle cx="67" cy="40" r="2.8" fill="${alertOrbits.length > 0 ? "#ef4444" : "#22c55e"}"/>
          </svg>
        </div>

        <div class="compass-copy">
          <h2 class="compass-title">${escapeHTML(headline)}</h2>
          <p class="compass-desc">${escapeHTML(desc)}</p>
          <div class="compass-pills">
            <span class="compass-pill pill-healthy">${healthyOrbits.length} 轨充盈</span>
            <span class="compass-pill ${alertOrbits.length > 0 ? "pill-danger" : "pill-neutral"}">${alertOrbits.length} 轨预警</span>
          </div>
        </div>
      </div>

      <div class="compass-footer">
        <span class="compass-footer-left">实时监测 ${accounts.length} 条算力轨道</span>
        <span class="compass-footer-right">本机调度就绪</span>
      </div>
    </article>`;
  }

  function renderToast() {
    if (!state.toastMessage) {
      elStatusToast.hidden = true;
      elStatusToast.textContent = "";
      return;
    }
    elStatusToast.hidden = false;
    elStatusToast.innerHTML = `<span>${escapeHTML(state.toastMessage)}</span>
      <button class="seg-btn" id="dismissToastBtn">知道了</button>`;
    const dismiss = document.getElementById("dismissToastBtn");
    if (dismiss) {
      dismiss.addEventListener("click", () => {
        state.toastMessage = "";
        renderToast();
      });
    }
  }

  function renderAll() {
    renderMiniStrip();
    renderHealthBanner();
    renderToast();

    const cardsHTML = state.accounts.map(renderAccountCard).join("");
    elBentoGrid.innerHTML = cardsHTML + renderCompassCard();

    bindDynamicEvents();
  }

  // ================= Modal =================
  function openRateModal(cardId) {
    const acc = state.accounts.find((a) => a.id === cardId);
    if (!acc) return;
    elRateModalIcon.innerHTML = `<div class="provider-icon">${iconForProvider(acc.providerID)}</div>`;
    elRateModalTitle.textContent = `${acc.name} · 速率与状态`;
    elRateModalSub.textContent = acc.subtitle;

    const info = acc.rateInfo || {};
    const rows = [
      { label: "当前消耗速率", val: info.burnRate || "正常" },
      { label: "重置 / 耗尽预估", val: info.eta || "—" },
      { label: "数据来源", val: info.source || "AIQuotyCore" },
      { label: "新鲜度", val: info.freshness || "实时" }
    ];

    elRateModalBody.innerHTML = rows
      .map(
        (r) => `<div class="rate-row">
          <span class="rate-row-label">${escapeHTML(r.label)}</span>
          <span class="rate-row-val">${escapeHTML(r.val)}</span>
        </div>`
      )
      .join("");

    elRateModalBackdrop.hidden = false;
  }

  function closeRateModal() {
    elRateModalBackdrop.hidden = true;
  }

  // ================= Interactions & Data Loading =================
  function focusCard(cardId) {
    state.highlightedCardId = cardId;
    renderAll();
    const target = elBentoGrid.querySelector(`[data-card-id="${CSS.escape(cardId)}"]`);
    if (target) {
      target.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
    window.setTimeout(() => {
      if (state.highlightedCardId === cardId) {
        state.highlightedCardId = null;
        renderAll();
      }
    }, 1800);
  }

  function bindDynamicEvents() {
    document.querySelectorAll("[data-focus-card]").forEach((btn) => {
      btn.addEventListener("click", () => focusCard(btn.dataset.focusCard));
    });

    document.querySelectorAll("[data-toggle-reset]").forEach((btn) => {
      btn.addEventListener("click", () => {
        const id = btn.dataset.toggleReset;
        if (state.resetPreviewIds.has(id)) {
          state.resetPreviewIds.delete(id);
        } else {
          state.resetPreviewIds.add(id);
        }
        renderAll();
      });
    });

    document.querySelectorAll("[data-open-rate]").forEach((btn) => {
      btn.addEventListener("click", () => openRateModal(btn.dataset.openRate));
    });

    const switchBtn = document.getElementById("switchBackupBtn");
    if (switchBtn) {
      switchBtn.addEventListener("click", () => {
        const healthy = state.accounts
          .filter((a) => a.status.tone === "healthy")
          .sort((a, b) => (b.ringPercent ?? 0) - (a.ringPercent ?? 0));
        if (healthy.length === 0) return;
        state.fallbackIndex = (state.fallbackIndex + 1) % healthy.length;
        const picked = healthy[state.fallbackIndex];
        focusCard(picked.id);
      });
    }
  }

  async function loadMode(mode) {
    state.mode = mode === "demo" ? "demo" : "live";
    state.toastMessage = "";

    document.querySelectorAll(".mode-btn").forEach((btn) => {
      const active = btn.dataset.mode === state.mode;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-selected", String(active));
    });

    elRefreshBtn.classList.add("is-spinning");
    try {
      const endpoint = state.mode === "demo" ? "/api/status?demo=1" : "/api/status";
      const resp = await fetch(endpoint, { cache: "no-store" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const payload = await resp.json();
      const snapshots = Array.isArray(payload.snapshots) ? payload.snapshots : [];
      state.accounts = snapshots.map(mapCoreSnapshotToCard);
      state.dataSourceLabel = state.mode === "demo" ? "AIQuotyCore 全量数据" : "本机实时采集";
      if (state.accounts.length === 0 && state.mode === "live") {
        state.toastMessage = "当前本机尚未探测到已登录的 AI 订阅凭证，可先在 AIQuoty 菜单栏登录后点击「刷新」，或切换到「全量数据」预览。";
      }
    } catch (_err) {
      if (state.mode === "demo") {
        state.accounts = createFallbackFullDemoAccounts();
        state.dataSourceLabel = "内置全量数据";
      } else {
        state.accounts = [];
        state.dataSourceLabel = "未连接本机服务";
        state.toastMessage = "未检测到本机实时服务：请启动 AIQuoty.app 或运行 python3 Scripts/serve_web.py 后刷新。";
      }
    } finally {
      elRefreshBtn.classList.remove("is-spinning");
      renderAll();
    }
  }

  // ================= Static Listeners =================
  document.querySelectorAll(".mode-btn").forEach((btn) => {
    btn.addEventListener("click", () => loadMode(btn.dataset.mode));
  });

  elRefreshBtn.addEventListener("click", () => loadMode(state.mode));
  elRateModalClose.addEventListener("click", closeRateModal);
  elRateModalBackdrop.addEventListener("click", (e) => {
    if (e.target === elRateModalBackdrop) closeRateModal();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeRateModal();
  });

  // Initial render: default to live data
  loadMode("live");
})();
