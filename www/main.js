// ----------------------------------------------------------------
// main.js — flora64 GeoJSON Merge UI
//
// Orchestrates: file picking → WASM worker → blob download
// ----------------------------------------------------------------

/* ---- DOM references ---- */
const dropZone = document.getElementById('dropZone');
const fileInput = document.getElementById('fileInput');
const fileList = document.getElementById('fileList');
const mergeBtn = document.getElementById('mergeBtn');
const clearBtn = document.getElementById('clearBtn');
const progress = document.getElementById('progress');
const progressFill = document.getElementById('progressFill');
const progressText = document.getElementById('progressText');
const result = document.getElementById('result');
const resultText = document.getElementById('resultText');
const downloadBtn = document.getElementById('downloadBtn');
const error = document.getElementById('error');
const errorText = document.getElementById('errorText');
const statusMsg = document.getElementById('statusMsg');
const featureCount = document.getElementById('featureCount');

/* ---- State ---- */
/** @type {{ name: string; size: number; data: ArrayBuffer; webkitRelativePath?: string }[]} */
const files = [];
let wasmModule = null; // compiled WebAssembly.Module

/* ---- WASM pre-load ---- */
(async function loadWasm() {
  setStatus('Loading WASM module…');
  try {
    const res = await fetch('./flora64_merge.wasm');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    wasmModule = await WebAssembly.compileStreaming(res);
    setStatus('Ready');
  } catch (err) {
    showError(`Failed to load WASM: ${err.message}`);
    setStatus('WASM load failed');
  }
})();

/* ---- Drag & drop ---- */
dropZone.addEventListener('dragover', (e) => {
  e.preventDefault();
  dropZone.classList.add('drag-over');
});

dropZone.addEventListener('dragleave', () => {
  dropZone.classList.remove('drag-over');
});

dropZone.addEventListener('drop', (e) => {
  e.preventDefault();
  dropZone.classList.remove('drag-over');
  addFiles(e.dataTransfer.files);
});

fileInput.addEventListener('change', () => {
  addFiles(fileInput.files);
  fileInput.value = '';
});

/* ---- File management ---- */
async function addFiles(fileListLike) {
  const newFiles = [];
  for (const f of fileListLike) {
    if (f.name.endsWith('.geojson') || f.name.endsWith('.json')) {
      newFiles.push(f);
    }
  }
  if (newFiles.length === 0) {
    showError('Please select .geojson or .json files');
    return;
  }

  // Read each file as ArrayBuffer
  for (const f of newFiles) {
    try {
      const data = await f.arrayBuffer();
      files.push({ name: f.name, size: f.size, data, webkitRelativePath: f.webkitRelativePath || '' });
    } catch (err) {
      showError(`Failed to read "${f.name}": ${err.message}`);
    }
  }

  renderFileList();
  updateActions();
}

function removeFile(index) {
  files.splice(index, 1);
  renderFileList();
  updateActions();
}

function clearAll() {
  files.length = 0;
  renderFileList();
  updateActions();
  hideResult();
  hideError();
  hideProgress();
}

/** Format bytes to human-readable size */
function fmtSize(bytes) {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const v = bytes / Math.pow(1024, i);
  return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}

function renderFileList() {
  if (files.length === 0) {
    fileList.innerHTML =
      '<p style="text-align:center;color:var(--text-dim);font-size:0.85rem;padding:1rem 0;">Drop files / folders or click the zone above to pick a folder</p>';
    return;
  }

  fileList.innerHTML = files
    .map(
      (f, i) => {
        const relPath = f.webkitRelativePath || '';
        const showPath = relPath && relPath !== f.name;
        return `
    <div class="file-item">
      <svg class="file-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/>
        <polyline points="14 2 14 8 20 8"/>
      </svg>
      <div class="file-info">
        <div class="file-name">${showPath ? escHtml(relPath) : escHtml(f.name)}</div>
        <div class="file-meta">${fmtSize(f.size)}</div>
      </div>
      <span class="file-status ready">ready</span>
      <button class="file-remove" data-index="${i}" title="Remove file">
        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>`;
      },
    )
    .join('');

  fileList.querySelectorAll('.file-remove').forEach((btn) => {
    btn.addEventListener('click', () => removeFile(Number(btn.dataset.index)));
  });
}

function escHtml(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

/* ---- Action buttons ---- */
function updateActions() {
  const hasFiles = files.length > 0;
  const wasmReady = wasmModule !== null;
  mergeBtn.disabled = !hasFiles || !wasmReady;
  clearBtn.disabled = !hasFiles;
}

clearBtn.addEventListener('click', clearAll);

/* ---- Merge flow ---- */
mergeBtn.addEventListener('click', async () => {
  if (!wasmModule || files.length === 0) return;

  // Reset UI
  hideError();
  hideResult();
  showProgress();
  setProgress(0, 'Preparing…');
  mergeBtn.disabled = true;

  try {
    // Send work to Web Worker
    const worker = new Worker(new URL('./merge.worker.js', import.meta.url), {
      type: 'classic',
    });

    const resultPromise = new Promise((resolve, reject) => {
      worker.onmessage = (e) => {
        const msg = e.data;
        worker.terminate();
        if (msg.type === 'complete') resolve(msg);
        else reject(new Error(msg.error || 'Unknown worker error'));
      };
      worker.onerror = (e) => {
        worker.terminate();
        reject(new Error(e.message));
      };
    });

    setProgress(30, `Merging ${files.length} file${files.length > 1 ? 's' : ''}…`);

    worker.postMessage({
      type: 'merge',
      wasmModule,
      files: files.map((f) => ({
        name: f.name,
        data: f.data,
      })),
    });

    const msg = await resultPromise;

    setProgress(90, 'Finalizing…');

    // Create download
    const blob = new Blob([msg.data], { type: 'application/geo+json' });
    const url = URL.createObjectURL(blob);

    hideProgress();
    showResult(blob.size, msg.fileCount);

    downloadBtn.href = url;
    downloadBtn.download = 'merged.geojson';

    setStatus('Merge complete');
    setFeatureCount(msg.fileCount);
  } catch (err) {
    hideProgress();
    showError(`Merge failed: ${err.message}`);
    setStatus('Error');
  } finally {
    mergeBtn.disabled = false;
  }
});

/* ---- Progress ---- */
function showProgress() {
  progress.hidden = false;
  setProgress(0, '');
}

function hideProgress() {
  progress.hidden = true;
}

function setProgress(pct, text) {
  progressFill.style.width = `${Math.min(pct, 100)}%`;
  if (text) progressText.textContent = text;
}

/* ---- Result ---- */
function showResult(totalBytes, fileCount) {
  result.hidden = false;
  resultText.textContent = `✅ Merged ${fileCount} file${fileCount > 1 ? 's' : ''} (${fmtSize(totalBytes)})`;
}

function hideResult() {
  result.hidden = true;
  downloadBtn.removeAttribute('href');
}

/* ---- Error ---- */
function showError(msg) {
  error.hidden = false;
  errorText.textContent = msg;
  // Auto-hide after 8 s
  setTimeout(() => {
    if (!error.hidden) hideError();
  }, 8000);
}

function hideError() {
  error.hidden = true;
}

/* ---- Status bar ---- */
function setStatus(msg) {
  statusMsg.textContent = msg;
}

function setFeatureCount(count) {
  featureCount.textContent = `${count} file${count !== 1 ? 's' : ''}`;
}
