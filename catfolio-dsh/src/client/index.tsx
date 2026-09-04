/**
 * catfolio-dsh client half — registers the "Portfolio" and "收益对比" view tabs
 * into the harness conversation view ring and injects the scoped stylesheet.
 *
 * The built bundle is consumed by the harness client module system in the
 * lazy-CJS factory format; this source is bundled by scripts/build.mjs.
 */
import { PortfolioView } from "./PortfolioView.js";
import { ReturnsView } from "./ReturnsView.js";
import { AnalyticsView } from "./AnalyticsView.js";
import { SettingsView } from "./SettingsView.js";
import { CATFOLIO_CSS, ANALYTICS_CSS, DEMO_CSS } from "./styles.js";

export const inject = ["slots", "locale"];

const NS = "catfolio";

interface SlotsLike {
  inject(name: string, callback: () => () => void): void;
  register(
    options: {
      name: string;
      id: string;
      order: number;
      locale?: string;
      label?: () => string;
    },
    Component: unknown,
  ): unknown;
}

interface LocaleLike {
  register(namespace: string, dictionaries: { zh: Record<string, string>; en: Record<string, string> }): void;
  bind(namespace: string): (key: string) => string;
}

type ClientCtx = {
  slots: SlotsLike;
  locale: LocaleLike;
  effect(fn: () => unknown, label?: string): unknown;
};

const ZH: Record<string, string> = {
  "view.portfolio": "Portfolio",
  "view.returns": "收益对比",
  "view.analytics": "分析图表",
  "view.settings": "设置",
};

const EN: Record<string, string> = {
  "view.portfolio": "Portfolio",
  "view.returns": "Returns",
  "view.analytics": "Analytics",
  "view.settings": "Settings",
};

export function apply(ctx: ClientCtx): void {
  ctx.effect(() => ctx.locale.register(NS, { zh: ZH, en: EN }), "catfolio-dsh: dictionaries");
  const t = ctx.locale.bind(NS);

  // Scoped stylesheet for both views.
  ctx.effect(() => {
    const style = document.createElement("style");
    style.setAttribute("data-plugin", "catfolio-dsh");
    style.textContent = CATFOLIO_CSS + ANALYTICS_CSS + DEMO_CSS;
    document.head.appendChild(style);
    return () => style.remove();
  }, "catfolio-dsh: styles");

  ctx.slots.inject("conversation.view", () =>
    ctx.slots.register(
      {
        name: "conversation.view",
        id: "catfolio-portfolio",
        order: 20,
        locale: NS,
        label: () => t("view.portfolio"),
      },
      PortfolioView,
    ),
  );

  ctx.slots.inject("conversation.view", () =>
    ctx.slots.register(
      {
        name: "conversation.view",
        id: "catfolio-returns",
        order: 21,
        locale: NS,
        label: () => t("view.returns"),
      },
      ReturnsView,
    ),
  );

  ctx.slots.inject("conversation.view", () =>
    ctx.slots.register(
      {
        name: "conversation.view",
        id: "catfolio-analytics",
        order: 22,
        locale: NS,
        label: () => t("view.analytics"),
      },
      AnalyticsView,
    ),
  );

  ctx.slots.inject("conversation.view", () =>
    ctx.slots.register(
      {
        name: "conversation.view",
        id: "catfolio-settings",
        order: 23,
        locale: NS,
        label: () => t("view.settings"),
      },
      SettingsView,
    ),
  );
}
