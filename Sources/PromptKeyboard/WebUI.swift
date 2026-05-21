import Foundation

enum WebUI {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>提示词键盘</title>
<style>
  :root {
    --bg: #0b0d10;
    --card: #1a1f25;
    --card-press: #2c343d;
    --accent: #4f9eff;
    --text: #e6eaf0;
    --sub: #8893a3;
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text);
    font: 15px/1.4 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
    overscroll-behavior: none;
  }
  body { padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); }
  header { display: flex; align-items: center; justify-content: space-between;
    padding: 12px 14px; position: sticky; top: 0; background: var(--bg);
    border-bottom: 1px solid #21262d;
  }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header .status { font-size: 12px; color: var(--sub); }
  .grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; padding: 12px; }
  @media (min-width: 480px) { .grid { grid-template-columns: repeat(3, 1fr); } }
  .btn { background: var(--card); border: none; color: var(--text);
    padding: 18px 12px; border-radius: 14px; font-size: 16px;
    text-align: center; cursor: pointer; transition: transform .08s, background .12s;
    min-height: 64px; display: flex; flex-direction: column; justify-content: center;
    user-select: none;
  }
  .btn .sub { font-size: 11px; color: var(--sub); margin-top: 4px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .btn:active { background: var(--card-press); transform: scale(0.97); }
  .btn.sent { background: var(--accent); }
  .empty { padding: 40px 20px; text-align: center; color: var(--sub); }
  .toast { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
    background: rgba(0,0,0,0.85); color: #fff; padding: 10px 18px; border-radius: 22px;
    font-size: 13px; opacity: 0; transition: opacity .2s; pointer-events: none;
  }
  .toast.show { opacity: 1; }
</style>
</head>
<body>
<header>
  <h1>提示词键盘</h1>
  <span class="status" id="status">连接中…</span>
</header>
<div class="grid" id="grid"></div>
<div class="toast" id="toast"></div>
<script>
const grid = document.getElementById('grid');
const status = document.getElementById('status');
const toast = document.getElementById('toast');

function showToast(msg) {
  toast.textContent = msg;
  toast.classList.add('show');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => toast.classList.remove('show'), 1500);
}

async function load() {
  try {
    const res = await fetch('/api/prompts', { cache: 'no-store' });
    const data = await res.json();
    render(data.prompts || []);
    status.textContent = '在线 · ' + (data.prompts?.length || 0) + ' 项';
  } catch (e) {
    status.textContent = '离线';
    grid.innerHTML = '<div class="empty">无法连接 Mac 端,请确认 Mac 上 App 正在运行</div>';
  }
}

function render(prompts) {
  if (!prompts.length) {
    grid.innerHTML = '<div class="empty">还没有提示词,在 Mac 端添加</div>';
    return;
  }
  grid.innerHTML = '';
  for (const p of prompts) {
    const b = document.createElement('button');
    b.className = 'btn';
    b.innerHTML = '<div>' + escapeHtml(p.title) + '</div>' +
                  '<div class="sub">' + escapeHtml(p.content.replace(/\n/g, ' · ').slice(0, 40)) + '</div>';
    b.onclick = () => send(p.id, b);
    grid.appendChild(b);
  }
}

async function send(id, btn) {
  if (window.navigator.vibrate) window.navigator.vibrate(10);
  btn.classList.add('sent');
  setTimeout(() => btn.classList.remove('sent'), 300);
  try {
    const res = await fetch('/api/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id })
    });
    if (!res.ok) {
      const text = await res.text();
      showToast('发送失败: ' + text);
    } else {
      showToast('已发送');
    }
  } catch (e) {
    showToast('网络错误');
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

load();
setInterval(load, 5000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) load(); });
</script>
</body>
</html>
"""#
}
