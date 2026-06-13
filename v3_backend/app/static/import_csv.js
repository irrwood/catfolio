let selectedFile = null;

function onFileSelected(input) {
  if (!input.files[0]) return;
  selectedFile = input.files[0];
  document.getElementById('fileName').textContent = selectedFile.name + ' (' + Math.round(selectedFile.size / 1024) + ' KB)';
  document.getElementById('fileInfo').style.display = 'block';
  document.getElementById('uploadBtn').disabled = false;
  document.getElementById('dropzone').style.borderColor = 'var(--accent)';
}

function handleDrop(e) {
  e.preventDefault();
  document.getElementById('dropzone').style.borderColor = 'var(--line-strong)';
  const file = e.dataTransfer.files[0];
  if (!file) return;
  const dt = new DataTransfer();
  dt.items.add(file);
  const input = document.getElementById('csvFile');
  input.files = dt.files;
  onFileSelected(input);
}

async function uploadCSV() {
  if (!selectedFile) return;
  const btn = document.getElementById('uploadBtn');
  const status = document.getElementById('uploadStatus');
  btn.disabled = true;
  btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 处理中…';
  status.style.display = 'none';

  const form = new FormData();
  form.append('file', selectedFile);
  try {
    const res = await fetch('/api/import-csv', {method: 'POST', body: form});
    const data = await res.json();
    if (data.ok) {
      showResult(data);
    } else {
      status.style.display = 'block';
      status.innerHTML = '<span style="color:var(--negative)"><i class="fa-solid fa-circle-xmark"></i> 导入失败：' +
        (data.warnings || []).join('; ') + '</span>';
      btn.disabled = false;
      btn.innerHTML = '<i class="fa-solid fa-upload"></i> 导入数据';
    }
  } catch(e) {
    status.style.display = 'block';
    status.innerHTML = '<span style="color:var(--negative)"><i class="fa-solid fa-circle-xmark"></i> 请求失败：' + e.message + '</span>';
    btn.disabled = false;
    btn.innerHTML = '<i class="fa-solid fa-upload"></i> 导入数据';
  }
}

function showResult(data) {
  document.getElementById('importResult').style.display = 'block';
  document.getElementById('importSummary').textContent =
    data.holdings_count + ' 个持仓，' + data.transactions_count + ' 条交易记录';
  const tbody = document.getElementById('importTbody');
  tbody.innerHTML = '';
  (data.holdings || []).forEach(h => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td class="font-mono">${h.ticker}</td><td>${h.name || '—'}</td>` +
      `<td class="font-mono">${h.shares}</td><td class="font-mono">${h.avg_cost}</td>` +
      `<td class="font-mono">${h.currency}</td>`;
    tbody.appendChild(tr);
  });
  document.getElementById('uploadBtn').innerHTML = '<i class="fa-solid fa-circle-check"></i> 已导入';
}

function downloadSample() {
  const blob = new Blob([csv], {type: 'text/csv'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'helm_import_sample.csv';
  a.click();
}
