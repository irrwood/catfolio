import fs from "node:fs/promises";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const inputPath = "outputs/portfolio_analysis/portfolio_analysis.json";
const outputDir = "outputs/portfolio_analysis";
const outputPath = `${outputDir}/portfolio_cost_basis.xlsx`;

const data = JSON.parse(await fs.readFile(inputPath, "utf8"));
const workbook = Workbook.create();

function colName(index) {
  let name = "";
  while (index > 0) {
    const rem = (index - 1) % 26;
    name = String.fromCharCode(65 + rem) + name;
    index = Math.floor((index - 1) / 26);
  }
  return name;
}

function addSheet(name, rows) {
  const sheet = workbook.worksheets.add(name);
  if (!rows.length) return sheet;
  const headers = Object.keys(rows[0]);
  const lastCol = colName(headers.length);
  sheet.getRange(`A1:${lastCol}1`).values = [headers];
  sheet.getRange(`A2:${lastCol}${rows.length + 1}`).values = rows.map((row) =>
    headers.map((header) => row[header] ?? "")
  );
  return sheet;
}

const summaryRows = [
  { metric: "统计日期", value: data.summary.as_of, note: "CSV 文件覆盖到该日期" },
  { metric: "源文件数", value: data.summary.source_files, note: "" },
  { metric: "交易流水数", value: data.summary.transactions, note: "" },
  { metric: "当前持有股票数", value: data.summary.open_positions, note: "A/B 合并后按 ticker 去重" },
  { metric: "当前持仓条目数", value: data.summary.open_positions_by_account, note: "按账户+ticker 拆分" },
  { metric: "已清仓条目数", value: data.summary.closed_positions, note: "" },
  ...Object.entries(data.summary.cost_scale_by_currency).map(([currency, item]) => ({
    metric: `持仓成本规模 ${currency}`,
    value: item.cost_native,
    note: `${item.positions} 条账户持仓；GBP 可核算部分 ${item.cost_gbp_available}`,
  })),
  ...Object.entries(data.summary.cost_scale_by_account_gbp_available).map(([account, item]) => ({
    metric: `账户 ${account} GBP 可核算成本`,
    value: item.cost_gbp_available,
    note: `${item.positions} 条账户持仓`,
  })),
  ...Object.entries(data.summary.dividends_by_account_currency).map(([key, value]) => ({
    metric: `股息 ${key}`,
    value,
    note: "文件内股息流水合计",
  })),
];

addSheet("总览", summaryRows);
addSheet("合并持仓成本", data.holdings);
addSheet("按账户持仓成本", data.holdings_by_account);
addSheet("已清仓记录", data.closed_positions);
addSheet(
  "注意事项",
  data.summary.warnings.length
    ? data.summary.warnings.map((warning) => ({ warning }))
    : [{ warning: "没有发现需要提示的流水异常。" }]
);

await fs.mkdir(outputDir, { recursive: true });
const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);
console.log(outputPath);
