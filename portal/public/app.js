(function () {
  // ---- 商品搜尋 ----
  const grid = document.getElementById('product-grid');
  const searchInput = document.getElementById('search-input');

  function renderProducts(list, query) {
    grid.innerHTML = '';
    if (!query) {
      return;
    }
    if (list.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'product-empty';
      empty.textContent = '沒有符合的商品';
      grid.appendChild(empty);
      return;
    }
    for (const p of list) {
      const card = document.createElement('div');
      card.className = 'product-card';
      card.innerHTML = `
        <div class="product-name"></div>
        <div class="product-category"></div>
        <div class="product-price"></div>
      `;
      card.querySelector('.product-name').textContent = p.name;
      card.querySelector('.product-category').textContent = p.category;
      card.querySelector('.product-price').textContent = `NT$ ${p.price.toLocaleString()}`;
      grid.appendChild(card);
    }
  }

  function applySearch() {
    const q = searchInput.value.trim().toLowerCase();
    const filtered = q ? DEMO_PRODUCTS.filter((p) => p.name.toLowerCase().includes(q)) : [];
    renderProducts(filtered, q);
  }

  searchInput.addEventListener('input', applySearch);
  applySearch();

  // ---- 終端機（按鈕觸發開啟/關閉） ----
  const drawer = document.getElementById('terminal-drawer');
  const toggleBtn = document.getElementById('terminal-toggle');
  const closeBtn = document.getElementById('terminal-close');

  let term = null;
  let fitAddon = null;
  let ws = null;
  let started = false;

  function sendResize() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
    }
  }

  function startTerminal() {
    if (started) return;
    started = true;

    term = new Terminal({
      fontFamily: 'Menlo, Consolas, monospace',
      fontSize: 14,
      theme: { background: '#1e1e1e' },
      cursorBlink: true,
    });
    fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(document.getElementById('terminal'));
    fitAddon.fit();

    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${proto}://${location.host}/ws/terminal`);

    ws.addEventListener('open', () => {
      term.writeln('已連線至 target-box ...\r\n');
      sendResize();
    });
    ws.addEventListener('message', (ev) => term.write(ev.data));
    ws.addEventListener('close', () => term.writeln('\r\n[連線已中斷]'));
    ws.addEventListener('error', () => term.writeln('\r\n[連線錯誤]'));

    term.onData((data) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'input', data }));
      }
    });

    window.addEventListener('resize', () => {
      if (drawer.classList.contains('open')) {
        fitAddon.fit();
        sendResize();
      }
    });
  }

  function openTerminal() {
    drawer.classList.add('open');
    startTerminal();
    setTimeout(() => {
      fitAddon && fitAddon.fit();
      sendResize();
      term && term.focus();
    }, 210); // 等待抽屜滑入動畫結束再 fit，避免尺寸計算錯誤
  }

  function closeTerminal() {
    drawer.classList.remove('open');
  }

  toggleBtn.addEventListener('click', openTerminal);
  closeBtn.addEventListener('click', closeTerminal);

  // ---- 提示（依難度顯示不同細節的提示步驟）----
  const hintsToggle = document.getElementById('hints-toggle');
  const hintsModal = document.getElementById('hints-modal');
  const hintsClose = document.getElementById('hints-close');
  const hintsTabs = document.getElementById('hints-tabs');
  const hintsSteps = document.getElementById('hints-steps');

  const HINT_LEVELS = ['easy', 'normal', 'hard'];
  let activeLevel = 'normal';

  function renderHintTabs() {
    hintsTabs.innerHTML = '';
    for (const level of HINT_LEVELS) {
      const tab = document.createElement('button');
      tab.className = 'hints-tab' + (level === activeLevel ? ' active' : '');
      tab.textContent = HINTS[level].label;
      tab.addEventListener('click', () => {
        activeLevel = level;
        renderHintTabs();
        renderHintSteps();
      });
      hintsTabs.appendChild(tab);
    }
  }

  function renderHintSteps() {
    hintsSteps.innerHTML = '';
    for (const step of HINTS[activeLevel].steps) {
      const li = document.createElement('li');
      li.textContent = step;
      hintsSteps.appendChild(li);
    }
  }

  function openHints() {
    renderHintTabs();
    renderHintSteps();
    hintsModal.classList.add('open');
  }

  function closeHints() {
    hintsModal.classList.remove('open');
  }

  hintsToggle.addEventListener('click', openHints);
  hintsClose.addEventListener('click', closeHints);
  hintsModal.addEventListener('click', (ev) => {
    if (ev.target === hintsModal) closeHints();
  });
})();
