/**
 * AI analysis over the harness LLM runtime (`ctx.llm`).
 *
 * Instead of requiring a separate Catfolio API key, these builders hand the
 * analytics payloads to the harness's own configured model (DeepSeek by
 * default) through `ctx.llm.stream` + `BlockAssembler`. If the LLM service is
 * unavailable or the call fails, every function falls back to a deterministic
 * demo text so the UI never breaks.
 */
import { BlockAssembler, createUserMessage } from "@deepseek-ai/dsh-llm";
import type { GenerateOptions, StreamChunk } from "@deepseek-ai/dsh-llm";
import type { Snapshot, LabHistory, Json } from "../core/engine.js";
import {
  BENCHMARKS,
  cumulativeVsBenchmark,
  labHistorySummary,
  monthlyReturnHeatmap,
  portfolioSummary,
} from "../core/engine.js";

export interface LlmLike {
  stream(options: GenerateOptions): AsyncIterable<StreamChunk>;
}

function fmtPct(value: unknown, digits = 2): string {
  const number = Number(value ?? 0);
  return `${number >= 0 ? "+" : ""}${(number * 100).toFixed(digits)}%`;
}

/** Multi-benchmark summary: portfolio vs every benchmark, rebased to a common start. */
function multiBenchmarkLines(snapshot: Snapshot, history: LabHistory): { lines: string[]; portfolioFinal: number } {
  const summary = labHistorySummary(snapshot, history);
  const portfolioNav = (summary.nav ?? []) as { date: string; nav: number }[];
  if (!portfolioNav.length) return { lines: [], portfolioFinal: 0 };
  const portfolioBase = portfolioNav[0].nav || 1;
  const portfolioByDate: Record<string, number> = {};
  for (const row of portfolioNav) portfolioByDate[row.date] = row.nav / portfolioBase;
  const prices = history.prices ?? {};
  const lines: string[] = [];
  for (const [symbol, label] of Object.entries(BENCHMARKS)) {
    const rows = prices[symbol] ?? [];
    if (!rows.length) continue;
    const first = Number(rows[0]?.close);
    const last = Number(rows[rows.length - 1]?.close);
    if (!first || !last) continue;
    const finalReturn = last / first - 1;
    const portfolioFinal = portfolioByDate[rows[rows.length - 1].date] ?? null;
    const excess = portfolioFinal !== null ? portfolioFinal - 1 - finalReturn : null;
    const excessText = excess === null ? "—" : `${excess >= 0 ? "+" : ""}${fmtPct(excess)}`;
    lines.push(`  ${symbol} (${label}): 累计收益=${fmtPct(finalReturn)}, 组合超额=${excessText}`);
  }
  const lastDate = portfolioNav[portfolioNav.length - 1].date;
  return { lines, portfolioFinal: (portfolioByDate[lastDate] ?? 1) - 1 };
}

/**
 * Build the same benchmark-explanation prompt the Python app sends to its AI
 * provider, and call the harness LLM with it.
 */
export async function returnsExplanationWithLlm(
  snapshot: Snapshot,
  history: LabHistory,
  llm: LlmLike | undefined,
  provider: string,
  model: string,
): Promise<{ explanation: string; period: string }> {
  const twr = cumulativeVsBenchmark(snapshot, history, "SPY");
  const twrRows = (twr.rows ?? []) as { date: string; benchmark: number }[];
  const range = (twr.date_range ?? {}) as { start?: string; end?: string };
  const twrStartDate = range.start ?? "—";
  const twrEndDate = range.end ?? "—";
  const multi = multiBenchmarkLines(snapshot, history);
  const monthly = monthlyReturnHeatmap(snapshot, history);
  const monthlyRows = ((monthly.rows ?? []) as { month: string; return: number }[]).slice(-12);
  const monthlyLines = monthlyRows.map((m) => `  ${m.month}: ${fmtPct(m.return)}`);

  const prompt = [
    "你是一位投资顾问，擅长把复杂数据用简单的话解释给普通投资者。",
    "",
    "## 收益对比数据",
    `数据区间: ${twrStartDate} 至 ${twrEndDate}`,
    "基准: SPY (标普500)",
    "",
    `组合累计收益: ${fmtPct(multi.portfolioFinal)}`,
    `SPY累计收益: ${twrRows.length ? fmtPct(twrRows[twrRows.length - 1].benchmark) : "—"}`,
    "",
    "## 所有基准对比",
    multi.lines.length ? multi.lines.join("\n") : "  基准数据暂缺",
    "",
    "## 最近12个月月度收益",
    monthlyLines.length ? monthlyLines.join("\n") : "  月度数据暂缺",
    "",
    "## 数据说明",
    '- "TWR" = Time-Weighted Return，剔除了入金出金影响，纯衡量策略表现',
    "- 组合收益是基于当前持仓权重的历史回看，不是真实账户收益",
    "",
    "请用中文简单解释：",
    "1. 组合相比基准表现如何？",
    "2. 跑赢还是跑输？主要在哪些阶段？",
    "3. 组合的收益特征是什么（偏进攻/偏防守/波动大/稳健）？",
    "4. 有什么值得注意的问题？",
    "",
    "用简单的话，像跟朋友聊天一样，3-5句话。不要堆数据，直接给结论。",
  ].join("\n");

  const fallback = {
    explanation:
      "当前处于假数据模式：这是一段固定示例分析，没有读取本机 AI Key，也没有调用外部 AI Provider。" +
      "关闭假数据模式并在设置里配置 AI Key 后，Catfolio 才会根据真实组合生成 AI 分析。",
    period: `${twrStartDate} ~ ${twrEndDate}`,
  };

  if (!llm) return fallback;

  try {
    const assembler = new BlockAssembler();
    const request: GenerateOptions = {
      provider,
      model,
      temperature: 0.4,
      maxTokens: 500,
      system: "你是投资顾问，用简单直白的中文解释数据，不堆砌数字，直接给结论。",
      messages: [
        createUserMessage({
          content: [{ type: "text", text: prompt }],
          source: { kind: "plugin", plugin: "catfolio-dsh" },
        }),
      ],
    };
    for await (const chunk of llm.stream(request)) {
      assembler.push(chunk);
    }
    const blocks = assembler.blocks();
    const text = blocks
      .filter((block): block is { type: "text"; text: string } => block.type === "text")
      .map((block) => block.text)
      .join("")
      .trim();
    if (!text) return fallback;
    return { explanation: text, period: `${twrStartDate} ~ ${twrEndDate}` };
  } catch {
    return fallback;
  }
}

/** Short portfolio briefing used by the Portfolio tab's AI action. */
export async function portfolioBriefingWithLlm(
  snapshot: Snapshot,
  llm: LlmLike | undefined,
  provider: string,
  model: string,
): Promise<string> {
  const summary = portfolioSummary(snapshot) as Json;
  const marketValue = Number(summary.market_value_usd || 0);
  const unrealized = Number(summary.unrealized_usd || 0);
  const cost = Number(summary.total_cost_usd_standard || 0);
  const holdingsCount = snapshot.portfolio.holdings.length;

  const prompt = [
    "你是投资顾问，用简单直白的话总结一个投资组合。",
    "",
    `总市值 $${marketValue.toLocaleString("en-US", { maximumFractionDigits: 0 })}`,
    `未实现盈亏 ${unrealized >= 0 ? "+" : ""}$${unrealized.toLocaleString("en-US", { maximumFractionDigits: 0 })} (${fmtPct(cost ? unrealized / cost : 0, 1)})`,
    `持仓数 ${holdingsCount}`,
    "",
    "请用 2-3 句话总结这个组合的特征和当前状态，用中文，直接给结论。",
  ].join("\n");

  if (!llm) {
    return "当前处于假数据模式：这是一段固定示例分析。关闭假数据模式并配置 AI Provider 后才会生成真实 AI 分析。";
  }
  try {
    const assembler = new BlockAssembler();
    const request: GenerateOptions = {
      provider,
      model,
      temperature: 0.4,
      maxTokens: 300,
      system: "你是投资顾问，用简单直白的中文解释数据，不堆砌数字，直接给结论。",
      messages: [
        createUserMessage({
          content: [{ type: "text", text: prompt }],
          source: { kind: "plugin", plugin: "catfolio-dsh" },
        }),
      ],
    };
    for await (const chunk of llm.stream(request)) {
      assembler.push(chunk);
    }
    const text = assembler
      .blocks()
      .filter((block): block is { type: "text"; text: string } => block.type === "text")
      .map((block) => block.text)
      .join("")
      .trim();
    return text || "（模型未返回内容）";
  } catch {
    return "（AI 解读暂时不可用）";
  }
}
