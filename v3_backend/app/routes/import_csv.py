"""Page route: CSV portfolio import."""
from fastapi import APIRouter, Request, UploadFile, File
from fastapi.responses import HTMLResponse, JSONResponse
from app.components import render_layout
from app.i18n import get_lang
from app.settings import V2_DIR
from app.csv_import import process_csv_upload
import json

router = APIRouter(tags=["pages"])

_SAMPLE_CSV = """\
Date,Action,Ticker,Quantity,Price,Currency,Name
2023-01-10,BUY,AAPL,10,148.00,USD,Apple Inc.
2023-02-15,BUY,MSFT,8,318.00,USD,Microsoft Corp.
2023-03-20,BUY,NVDA,5,490.00,USD,NVIDIA Corp.
2023-06-01,SELL,AAPL,2,195.00,USD,Apple Inc.
2024-01-08,BUY,LLOY.L,500,45.00,GBX,Lloyds Banking Group"""


@router.get("/import")
def import_page(request: Request):
    lang = get_lang(request)
    content = f"""
<div class="v4-hero">
  <div class="v4-hero-text">
    <h1>导入持仓数据</h1>
    <p>上传任意券商的交易记录 CSV，Catfolio 自动计算加权平均成本和当前持仓。无需 Trading 212 账号。</p>
  </div>
</div>

<div class="grid-2" style="align-items:start;">

  <!-- Upload card -->
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><svg class="hi hi-inline" style="color:var(--accent)" aria-hidden="true" focusable="false"><use href="#hi-file-csv"></use></svg> 上传交易记录</h2>
        <div class="v4-card-subtitle">支持 CSV 格式，列名不区分大小写</div>
      </div>
    </div>

    <div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <div id="dropzone" style="
        border:2px dashed var(--line-strong);
        border-radius:var(--radius-lg);
        padding:var(--sp-3xl) var(--sp-xl);
        text-align:center;
        cursor:pointer;
        transition:border-color 0.15s, background 0.15s;
        margin-bottom:var(--sp-xl);
      " onclick="document.getElementById('csvFile').click()"
         ondragover="event.preventDefault();this.style.borderColor='var(--accent)'"
         ondragleave="this.style.borderColor='var(--line-strong)'"
         ondrop="handleDrop(event)">
        <svg class="hi hi-inline" style="font-size:32px;color:var(--muted);margin-bottom:8px;display:block;" aria-hidden="true" focusable="false"><use href="#hi-cloud-upload"></use></svg>
        <div style="font-weight:600;margin-bottom:4px;">点击选择 CSV 文件</div>
        <div style="font-size:var(--text-sm);color:var(--muted);">或拖拽至此</div>
      </div>
      <input type="file" id="csvFile" accept=".csv,text/csv" style="display:none" onchange="onFileSelected(this)">

      <div id="fileInfo" style="display:none;margin-bottom:var(--sp-base);padding:10px 14px;background:var(--soft);border-radius:var(--radius-md);font-size:var(--text-sm);">
        <svg class="hi hi-inline" style="color:var(--accent)" aria-hidden="true" focusable="false"><use href="#hi-file-csv"></use></svg>
        <span id="fileName"></span>
      </div>

      <button id="uploadBtn" class="btn primary" style="width:100%;justify-content:center;" disabled onclick="uploadCSV()">
        <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-upload"></use></svg> 导入数据
      </button>

      <div id="uploadStatus" style="margin-top:var(--sp-base);font-size:var(--text-sm);display:none;"></div>
    </div>
  </div>

  <!-- Format reference card -->
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><svg class="hi hi-inline" style="color:var(--accent)" aria-hidden="true" focusable="false"><use href="#hi-table"></use></svg> CSV 格式说明</h2>
        <div class="v4-card-subtitle">必填列：Date / Action / Ticker / Quantity / Price</div>
      </div>
    </div>
    <div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <table class="data-table" style="font-size:var(--text-sm);">
        <thead><tr><th>列名</th><th>必填</th><th>说明</th></tr></thead>
        <tbody>
          <tr><td class="font-mono">Date</td><td>✅</td><td>YYYY-MM-DD 或 MM/DD/YYYY</td></tr>
          <tr><td class="font-mono">Action</td><td>✅</td><td>BUY / SELL / DIVIDEND</td></tr>
          <tr><td class="font-mono">Ticker</td><td>✅</td><td>交易代码（如 AAPL, LLOY.L）</td></tr>
          <tr><td class="font-mono">Quantity</td><td>✅</td><td>股数（正数）</td></tr>
          <tr><td class="font-mono">Price</td><td>✅</td><td>每股价格</td></tr>
          <tr><td class="font-mono">Currency</td><td>—</td><td>USD / GBP / GBX / EUR（默认 USD）</td></tr>
          <tr><td class="font-mono">Name</td><td>—</td><td>公司名称</td></tr>
        </tbody>
      </table>

      <div style="margin-top:var(--sp-xl);">
        <div style="font-size:var(--text-sm);font-weight:600;margin-bottom:var(--sp-sm);color:var(--muted);">示例</div>
        <pre style="background:var(--soft);border-radius:var(--radius-md);padding:var(--sp-md);font-size:11px;overflow-x:auto;line-height:1.6;">{_SAMPLE_CSV}</pre>
        <button class="btn" style="font-size:var(--text-sm);margin-top:var(--sp-sm);" onclick="downloadSample()">
          <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-download"></use></svg> 下载示例 CSV
        </button>
      </div>

      <div style="margin-top:var(--sp-xl);padding:var(--sp-md);background:var(--accent-soft);border-radius:var(--radius-md);font-size:var(--text-sm);color:var(--ink-secondary);">
        <svg class="hi hi-inline" style="color:var(--accent)" aria-hidden="true" focusable="false"><use href="#hi-info-circle"></use></svg>
        <strong style="color:var(--ink);">成本计算方式：</strong>加权平均成本法（WAC）。
        列名大小写不限，多余列自动忽略。已平仓（持仓为零）不会显示。
      </div>
    </div>
  </div>

</div>

<!-- Import result -->
<div id="importResult" style="display:none;margin-top:var(--sp-xl);">
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><svg class="hi hi-inline" style="color:var(--positive)" aria-hidden="true" focusable="false"><use href="#hi-check-circle"></use></svg> 导入成功</h2>
        <div class="v4-card-subtitle" id="importSummary"></div>
      </div>
    </div>
    <div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <table class="data-table" id="importTable">
        <thead><tr><th>代码</th><th>名称</th><th>持仓</th><th>平均成本</th><th>货币</th></tr></thead>
        <tbody id="importTbody"></tbody>
      </table>
      <div style="margin-top:var(--sp-xl);display:flex;gap:var(--sp-md);">
        <a href="/" class="btn primary"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-gauge"></use></svg> 前往控制台</a>
        <button class="btn" onclick="document.getElementById('csvFile').click()">
          <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-refresh"></use></svg> 重新导入
        </button>
      </div>
    </div>
  </div>
</div>

<script>const csv = {json.dumps(_SAMPLE_CSV)};</script>
<script src="/static/import_csv.js"></script>
"""
    return HTMLResponse(render_layout(request, "导入持仓数据", content, "/import", lang))


@router.post("/api/import-csv")
async def import_csv_api(file: UploadFile = File(...)):
    try:
        raw = await file.read()
        text = raw.decode("utf-8-sig")  # utf-8-sig strips BOM from Excel exports
    except Exception as exc:
        return JSONResponse({"ok": False, "warnings": [f"Could not read file: {exc}"]})

    result = process_csv_upload(text, V2_DIR)
    return JSONResponse(result)
