"""Page route: CSV portfolio import."""
from fastapi import APIRouter, Request, UploadFile, File
from fastapi.responses import HTMLResponse, JSONResponse
from app.components import wrap_v4_layout
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
    <p>上传任意券商的交易记录 CSV，Helm 自动计算加权平均成本和当前持仓。无需 Trading 212 账号。</p>
  </div>
</div>

<div class="grid-2" style="align-items:start;">

  <!-- Upload card -->
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-file-csv" style="color:var(--accent)"></i> 上传交易记录</h2>
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
        <i class="fa-solid fa-cloud-arrow-up" style="font-size:32px;color:var(--muted);margin-bottom:8px;display:block;"></i>
        <div style="font-weight:600;margin-bottom:4px;">点击选择 CSV 文件</div>
        <div style="font-size:var(--text-sm);color:var(--muted);">或拖拽至此</div>
      </div>
      <input type="file" id="csvFile" accept=".csv,text/csv" style="display:none" onchange="onFileSelected(this)">

      <div id="fileInfo" style="display:none;margin-bottom:var(--sp-base);padding:10px 14px;background:var(--soft);border-radius:var(--radius-md);font-size:var(--text-sm);">
        <i class="fa-solid fa-file-csv" style="color:var(--accent)"></i>
        <span id="fileName"></span>
      </div>

      <button id="uploadBtn" class="btn primary" style="width:100%;justify-content:center;" disabled onclick="uploadCSV()">
        <i class="fa-solid fa-upload"></i> 导入数据
      </button>

      <div id="uploadStatus" style="margin-top:var(--sp-base);font-size:var(--text-sm);display:none;"></div>
    </div>
  </div>

  <!-- Format reference card -->
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-table" style="color:var(--accent)"></i> CSV 格式说明</h2>
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
          <i class="fa-solid fa-download"></i> 下载示例 CSV
        </button>
      </div>

      <div style="margin-top:var(--sp-xl);padding:var(--sp-md);background:var(--accent-soft);border-radius:var(--radius-md);font-size:var(--text-sm);color:var(--ink-secondary);">
        <i class="fa-solid fa-circle-info" style="color:var(--accent)"></i>
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
        <h2 class="v4-card-title"><i class="fa-solid fa-circle-check" style="color:var(--positive)"></i> 导入成功</h2>
        <div class="v4-card-subtitle" id="importSummary"></div>
      </div>
    </div>
    <div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <table class="data-table" id="importTable">
        <thead><tr><th>代码</th><th>名称</th><th>持仓</th><th>平均成本</th><th>货币</th></tr></thead>
        <tbody id="importTbody"></tbody>
      </table>
      <div style="margin-top:var(--sp-xl);display:flex;gap:var(--sp-md);">
        <a href="/" class="btn primary"><i class="fa-solid fa-gauge"></i> 前往控制台</a>
        <button class="btn" onclick="document.getElementById('csvFile').click()">
          <i class="fa-solid fa-rotate"></i> 重新导入
        </button>
      </div>
    </div>
  </div>
</div>

<script>
let selectedFile = null;

function onFileSelected(input) {{
  if (!input.files[0]) return;
  selectedFile = input.files[0];
  document.getElementById('fileName').textContent = selectedFile.name + ' (' + Math.round(selectedFile.size / 1024) + ' KB)';
  document.getElementById('fileInfo').style.display = 'block';
  document.getElementById('uploadBtn').disabled = false;
  document.getElementById('dropzone').style.borderColor = 'var(--accent)';
}}

function handleDrop(e) {{
  e.preventDefault();
  document.getElementById('dropzone').style.borderColor = 'var(--line-strong)';
  const file = e.dataTransfer.files[0];
  if (!file) return;
  const dt = new DataTransfer();
  dt.items.add(file);
  const input = document.getElementById('csvFile');
  input.files = dt.files;
  onFileSelected(input);
}}

async function uploadCSV() {{
  if (!selectedFile) return;
  const btn = document.getElementById('uploadBtn');
  const status = document.getElementById('uploadStatus');
  btn.disabled = true;
  btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 处理中…';
  status.style.display = 'none';

  const form = new FormData();
  form.append('file', selectedFile);
  try {{
    const res = await fetch('/api/import-csv', {{method: 'POST', body: form}});
    const data = await res.json();
    if (data.ok) {{
      showResult(data);
    }} else {{
      status.style.display = 'block';
      status.innerHTML = '<span style="color:var(--negative)"><i class="fa-solid fa-circle-xmark"></i> 导入失败：' +
        (data.warnings || []).join('; ') + '</span>';
      btn.disabled = false;
      btn.innerHTML = '<i class="fa-solid fa-upload"></i> 导入数据';
    }}
  }} catch(e) {{
    status.style.display = 'block';
    status.innerHTML = '<span style="color:var(--negative)"><i class="fa-solid fa-circle-xmark"></i> 请求失败：' + e.message + '</span>';
    btn.disabled = false;
    btn.innerHTML = '<i class="fa-solid fa-upload"></i> 导入数据';
  }}
}}

function showResult(data) {{
  document.getElementById('importResult').style.display = 'block';
  document.getElementById('importSummary').textContent =
    data.holdings_count + ' 个持仓，' + data.transactions_count + ' 条交易记录';
  const tbody = document.getElementById('importTbody');
  tbody.innerHTML = '';
  (data.holdings || []).forEach(h => {{
    const tr = document.createElement('tr');
    tr.innerHTML = `<td class="font-mono">${{h.ticker}}</td><td>${{h.name || '—'}}</td>` +
      `<td class="font-mono">${{h.shares}}</td><td class="font-mono">${{h.avg_cost}}</td>` +
      `<td class="font-mono">${{h.currency}}</td>`;
    tbody.appendChild(tr);
  }});
  document.getElementById('uploadBtn').innerHTML = '<i class="fa-solid fa-circle-check"></i> 已导入';
}}

function downloadSample() {{
  const csv = {json.dumps(_SAMPLE_CSV)};
  const blob = new Blob([csv], {{type: 'text/csv'}});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'helm_import_sample.csv';
  a.click();
}}
</script>
"""
    return HTMLResponse(wrap_v4_layout("导入持仓数据", content, "/import", lang))


@router.post("/api/import-csv")
async def import_csv_api(file: UploadFile = File(...)):
    try:
        raw = await file.read()
        text = raw.decode("utf-8-sig")  # utf-8-sig strips BOM from Excel exports
    except Exception as exc:
        return JSONResponse({"ok": False, "warnings": [f"Could not read file: {exc}"]})

    result = process_csv_upload(text, V2_DIR)
    return JSONResponse(result)
