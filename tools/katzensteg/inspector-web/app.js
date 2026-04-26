async function fetchJson(path, options = {}) {
  const res = await fetch(`/inspect${path}`, options);
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`bad json from ${path}: ${text}`);
  }
}

function fmt(obj) {
  return JSON.stringify(obj, null, 2);
}

async function refresh() {
  try {
    const [status, latest, frames] = await Promise.all([
      fetchJson('/capture/status'),
      fetchJson('/frame/latest'),
      fetchJson('/frames'),
    ]);

    document.getElementById('status').textContent = fmt(status);
    document.getElementById('latest').textContent = fmt(latest);

    const tbody = document.getElementById('framesBody');
    tbody.innerHTML = '';
    for (const frame of [...frames].reverse()) {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${frame.id}</td>
        <td>${frame.present_ns}</td>
        <td>${frame.queue_depth}</td>
        <td>${frame.skipped_presents}</td>
      `;
      tbody.appendChild(tr);
    }
  } catch (err) {
    document.getElementById('status').textContent = String(err);
  }
}

async function action(path) {
  await fetchJson(path);
  await refresh();
}

document.getElementById('startBtn').addEventListener('click', () => action('/capture/start'));
document.getElementById('stopBtn').addEventListener('click', () => action('/capture/stop'));
document.getElementById('clearBtn').addEventListener('click', () => action('/capture/clear'));
document.getElementById('refreshBtn').addEventListener('click', refresh);

setInterval(() => {
  if (document.getElementById('autoRefresh').checked) refresh();
}, 1000);

refresh();
