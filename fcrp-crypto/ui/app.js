// ============================================================
//  ui/app.js  –  FlameNet Terminal  NUI Bridge
//  Connects flamenet-terminal.html to fcrp-crypto Lua backend.
//
//  NUI Callbacks sent to Lua (fetch POST):
//    closeTerminal  · sendTransaction  · buyCrypto
//    sellCrypto     · copyAddress
//
//  NUI Messages received from Lua (window message):
//    openTerminal   · updateBalance    · updateDashboard
//    updateWallet   · updatePrice      · updateMining
//    miningReward   · transactionResult· exchangeResult
//    updateTransactions · newActivity  · updateBlockchain
// ============================================================

;(function () {
  'use strict';

  // ── ENVIRONMENT ────────────────────────────────────────────
  const IS_FIVEM =
    typeof window.invokeNative !== 'undefined' ||
    navigator.userAgent.toLowerCase().includes('fivem') ||
    window.location.href.startsWith('nui://');

  // GetParentResourceName is injected by FiveM; polyfill for browser dev
  if (typeof GetParentResourceName === 'undefined') {
    window.GetParentResourceName = () => 'fcrp-crypto';
  }

  // ── NUI CALLBACK HELPER ────────────────────────────────────
  // Sends a POST to the Lua RegisterNUICallback handler.
  function nuiCB(name, data, cb) {
    fetch(`https://${GetParentResourceName()}/${name}`, {
      method  : 'POST',
      headers : { 'Content-Type': 'application/json; charset=UTF-8' },
      body    : JSON.stringify(data ?? {}),
    })
      .then(r  => r.json())
      .then(cb ?? (() => {}))
      .catch(e  => console.error('[FlameNet NUI]', name, e));
  }

  // ── RUNTIME STATE ─────────────────────────────────────────
  // Single source of truth; UI reads from here on updates.
  const S = {
    open          : false,
    walletAddress : '—',
    balance       : 0,
    price         : 2500,       // matches Config.BasePrice
    priceChange   : 0,
    hashrate      : 0,
    dailyReward   : 0,
    power         : 0,
    gpuCount      : 0,
    priceHistory  : [],
    gpus          : [],
    transactions  : [],
    blocks        : [],
    activity      : [],
    networkStats  : {},
  };

  // ── VISIBILITY ─────────────────────────────────────────────
  function openUI(data) {
    S.open = true;
    const frame = document.getElementById('tablet-frame');
    if (frame) frame.style.display = 'flex';

    // Apply any data the server bundled directly with the open event
    if (data) {
      if (data.price         !== undefined) applyPrice(data.price, data.priceChange ?? 0);
      if (data.balance       !== undefined) applyBalance(data.balance, data.walletAddress);
      if (data.walletBalance !== undefined) applyBalance(data.walletBalance, data.walletAddress);
      if (data.miningPower   !== undefined) applyMiningHeader(data.miningPower, data.rewards, data.power);
      if (data.priceHistory)               applyPriceHistory(data.priceHistory);
      if (data.transactions)               applyTransactions(data.transactions);
      if (data.gpus)                       applyGPUs(data.gpus);
      if (data.blocks)                     applyBlocks(data.blocks);
      if (data.stats)                      applyNetworkStats(data.stats);
    }
    // Full data arrives shortly via the Lua lib.callback chain in crypto:terminalUI
    // which sends: updateDashboard → updateMining → updateBalance → updateTransactions → updateBlockchain
  }

  function closeUI() {
    S.open = false;
    const frame = document.getElementById('tablet-frame');
    if (frame) frame.style.display = 'none';
    nuiCB('closeTerminal', {});
  }

  // ESC to close
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && S.open) closeUI();
  });

  // ── INCOMING NUI MESSAGE ROUTER ────────────────────────────
  window.addEventListener('message', ({ data }) => {
    if (!data?.action) return;

    switch (data.action) {

      /* ── LIFECYCLE ─────────────────────────────────────── */
      case 'openTerminal':
        openUI(data);
        break;

      case 'closeTerminal': {
        const frame = document.getElementById('tablet-frame');
        if (frame) frame.style.display = 'none';
        S.open = false;
        break;
      }

      /* ── WALLET ────────────────────────────────────────── */
      // From: client/wallet.lua  TriggerClientEvent("crypto:updateBalance", src, balance)
      case 'updateBalance':
        applyBalance(data.balance, data.walletAddress);
        break;

      // From: client/terminal.lua full wallet refresh
      case 'updateWallet':
        applyBalance(data.walletBalance, data.walletAddress);
        if (data.transactions) applyTransactions(data.transactions);
        break;

      /* ── DASHBOARD BUNDLE ──────────────────────────────── */
      // From: client/terminal.lua  SendNUIMessage after crypto:getTerminalData callback
      case 'updateDashboard':
        if (data.price         !== undefined) applyPrice(data.price, data.priceChange ?? 0);
        if (data.walletBalance !== undefined) applyBalance(data.walletBalance, data.walletAddress);
        if (data.miningPower   !== undefined) applyMiningHeader(data.miningPower, data.rewards, data.power);
        if (data.priceHistory)               applyPriceHistory(data.priceHistory);
        break;

      /* ── PRICE ─────────────────────────────────────────── */
      // From: market.lua  TriggerClientEvent("crypto:updatePrice", -1, {price, change, history})
      case 'updatePrice':
        applyPrice(data.price, data.change ?? data.priceChange ?? 0);
        if (data.history) applyPriceHistory(data.history);
        break;

      /* ── MINING ────────────────────────────────────────── */
      // From: client/terminal.lua after getMiningStats callback
      case 'updateMining':
        applyMiningHeader(data.hashrate, data.reward, data.power);
        if (data.gpus) applyGPUs(data.gpus);
        break;

      // From: mining.lua  TriggerClientEvent("crypto:miningReward", src, amount)
      // re-routed through client: SendNUIMessage({action="miningReward", amount=amount})
      case 'miningReward':
        if (data.amount) {
          const amt = parseFloat(data.amount).toFixed(4);
          addActivity('mine', `Mining reward received: +${amt} FTC`, 'just now');
          showNotif(`⛏ +${amt} FTC mining reward`, 'success');
        }
        break;

      /* ── TRANSACTION RESULT ────────────────────────────── */
      // From: client/terminal.lua after crypto:transfer server event responds
      // via a client re-broadcast e.g. TriggerClientEvent("crypto:transactionResult", src, data)
      case 'transactionResult':
        handleTransactionResult(data);
        break;

      /* ── EXCHANGE RESULT ───────────────────────────────── */
      // From: server/exchange.lua  TriggerClientEvent("crypto:notify", src, msg, type)
      // re-mapped in client to exchangeResult for buy/sell
      case 'exchangeResult':
        handleExchangeResult(data);
        break;

      /* ── TRANSACTIONS TABLE ────────────────────────────── */
      // From: client  after fcrypto:getHistory callback returns
      case 'updateTransactions':
        if (data.transactions) applyTransactions(data.transactions);
        break;

      /* ── ACTIVITY FEED ─────────────────────────────────── */
      // From: client/terminal.lua  re-broadcast of server activity pushes
      case 'newActivity':
        addActivity(data.type ?? 'info', data.message, 'just now', data.amount);
        break;

      /* ── BLOCKCHAIN ────────────────────────────────────── */
      // From: client after getTerminalData / getRecentBlocks callbacks
      case 'setWallet': {
        // Fired when crypto:walletCreated relays the real address
        if (data.wallet) applyBalance(S.balance, data.wallet);
        break;
      }

      case 'promptPin': {
        const m = document.getElementById('pinModal');
        if (m) {
          m.classList.add('open');
          setTimeout(() => document.getElementById('pinInput')?.focus(), 50);
        }
        break;
      }

      case 'updateBlockchain':
        if (data.stats)  applyNetworkStats(data.stats);
        if (data.blocks) applyBlocks(data.blocks);
        break;
    }
  });

  // ── APPLY: BALANCE ─────────────────────────────────────────
  function applyBalance(balance, address) {
    if (balance === undefined) return;
    S.balance = parseFloat(balance) || 0;
    const b   = S.balance;
    const usd = (b * S.price).toLocaleString('en-US', { maximumFractionDigits: 2 });

    if (address) {
      S.walletAddress = address;
      // topbar short address
      const ta = document.querySelector('.wallet-addr');
      if (ta) ta.textContent = address.slice(0, 6) + '...' + address.slice(-4);
      // full address display in wallet panel
      document.querySelectorAll('.wallet-addr-full span:first-child').forEach(el => {
        el.textContent = address;
      });
    }

    // Wallet panel hero balance
    const hero = document.querySelector('.wallet-main-balance');
    if (hero) hero.textContent = b.toLocaleString('en-US', { maximumFractionDigits: 4 }) + ' FTC';
    const usdEl = document.querySelector('.wallet-usd');
    if (usdEl) usdEl.textContent = '≈ $' + usd + ' USD';

    // Dashboard stat card labelled "Wallet Balance"
    _statCard('Wallet Balance', b.toLocaleString('en-US', { maximumFractionDigits: 2 }));
  }

  // ── APPLY: PRICE ───────────────────────────────────────────
  function applyPrice(price, change) {
    if (!price) return;
    S.price       = parseFloat(price);
    S.priceChange = parseFloat(change) || 0;

    const fmtP = '$' + S.price.toFixed(2);
    const fmtC = (S.priceChange >= 0 ? '+' : '') + S.priceChange.toFixed(2) + '%';
    const up   = S.priceChange >= 0;

    // Topbar ticker (live-updating)
    const lp = document.getElementById('livePrice');
    const lc = document.getElementById('livePriceChange');
    if (lp) lp.textContent = fmtP;
    if (lc) { lc.textContent = fmtC; lc.className = 'coin-change' + (up ? '' : ' neg'); }

    // Dashboard stat card
    _statCard('FTC Price', '$' + Math.round(S.price).toLocaleString(), fmtC, up);
    // Exchange market bar
    const mp = document.querySelector('.mp-price');
    if (mp) mp.textContent = fmtP;
    const mc = document.querySelector('.mp-change');
    if (mc) { mc.textContent = fmtC + (up ? ' ↑' : ' ↓'); mc.className = 'mp-change ' + (up ? 'up' : 'dn'); }

    // Recalculate open exchange forms
    calcBuy(); calcSell();
  }

  // ── APPLY: MINING HEADER STATS ─────────────────────────────
  function applyMiningHeader(hashrate, dailyReward, power) {
    const MAX_HASH  = 2000;  // 10x industrial GPUs: power=4.0 x 50 MH/s x 10
    const MAX_POWER = 3000;  // 10x industrial GPUs: electricity=3.0 x 100W x 10

    if (hashrate !== undefined) {
      S.hashrate = parseFloat(hashrate) || 0;
      _miningStatCard('Total Hash Rate', S.hashrate.toFixed(0) + ' MH/s');
      _statCard('Mining Power', S.hashrate.toFixed(0) + ' MH/s');
      // Dashboard mining status bar
      const hl = document.getElementById('dashHashLabel');
      const hb = document.getElementById('dashHashBar');
      if (hl) hl.textContent = S.hashrate.toFixed(0) + ' / ' + MAX_HASH + ' MH/s';
      if (hb) hb.style.width = Math.min(100, (S.hashrate / MAX_HASH) * 100).toFixed(1) + '%';
    }

    if (dailyReward !== undefined) {
      S.dailyReward = parseFloat(dailyReward) || 0;
      _statCard('Daily Reward', '+' + S.dailyReward.toFixed(2));
      // Earnings box in dashboard mining status card
      const ftcEl = document.getElementById('dashDailyFTC');
      const usdEl = document.getElementById('dashDailyUSD');
      if (ftcEl) ftcEl.textContent = S.dailyReward.toFixed(4) + ' FTC';
      if (usdEl) usdEl.textContent = '≈ $' + (S.dailyReward * S.price).toLocaleString('en-US', { maximumFractionDigits: 2 }) + ' USD';
    }

    if (power !== undefined) {
      S.power = parseFloat(power) || 0;
      _miningStatCard('Power Draw', S.power.toFixed(0) + ' W');
      // Dashboard power bar
      const pl = document.getElementById('dashPowerLabel');
      const pb = document.getElementById('dashPowerBar');
      if (pl) pl.textContent = S.power.toFixed(0) + ' / ' + MAX_POWER + ' W';
      if (pb) pb.style.width = Math.min(100, (S.power / MAX_POWER) * 100).toFixed(1) + '%';
    }
  }

  // ── APPLY: GPU LIST ────────────────────────────────────────
  function applyGPUs(gpus) {
    if (!Array.isArray(gpus)) return;
    S.gpus    = gpus;
    S.gpuCount = gpus.length;
    _miningStatCard('Active GPUs', gpus.length + ' / 10');

    // Dashboard mining status GPU bar
    const gl = document.getElementById('dashGPULabel');
    const gb = document.getElementById('dashGPUBar');
    if (gl) gl.textContent = gpus.length + ' / 10 GPUs';
    if (gb) gb.style.width = (gpus.length / 10 * 100).toFixed(0) + '%';

    const grid = document.querySelector('#panel-mining .gpu-grid');
    if (!grid) return;

    const MAX = 10;
    let html = '';
    for (let i = 0; i < MAX; i++) {
      const g = gpus[i];
      if (g) {
        const pct = Math.min(100, Math.round(((g.hashrate || 0) / 200) * 100));
        html += `
          <div class="gpu-card">
            <div class="gpu-name">${esc(g.label || g.gpu_type || 'GPU')}
              <span style="color:var(--accent-emerald);font-size:9px;">● ACTIVE</span></div>
            <div class="gpu-bar-wrap"><div class="gpu-bar" style="width:${pct}%"></div></div>
            <div class="gpu-stats">
              <span class="gpu-stat-val"><span>${g.hashrate || 0} MH/s</span></span>
              <span class="gpu-stat-val"><span>${g.power || 0}W</span></span>
            </div>
          </div>`;
      } else {
        html += `
          <div class="gpu-card" style="opacity:0.4;border-style:dashed;">
            <div class="gpu-name" style="color:var(--text-muted)">Slot ${i + 1}
              <span style="font-size:9px;">EMPTY</span></div>
            <div class="gpu-bar-wrap"><div class="gpu-bar" style="width:0%"></div></div>
            <div class="gpu-stats">
              <span class="gpu-stat-val">0 MH/s</span>
              <span class="gpu-stat-val">0W</span>
            </div>
          </div>`;
      }
    }
    grid.innerHTML = html;
  }

  // ── APPLY: PRICE HISTORY → CHARTS ─────────────────────────
  function applyPriceHistory(history) {
    if (!Array.isArray(history) || history.length < 2) return;
    S.priceHistory = history;

    // Server returns array of {price, label} or plain numbers
    const prices = history.map(h => (typeof h === 'object' ? (h.price || 0) : Number(h)));
    const labels = history.map((h, i) => (typeof h === 'object' ? (h.label || `T${i}`) : `T${i}`));

    // drawChart is defined in the HTML's inline <script>
    const pc = document.getElementById('priceChart');
    if (pc && typeof drawChart === 'function')
      drawChart(pc, labels, prices, 'rgba(139,92,246,1)', 'rgba(139,92,246,0.15)', 160);

    const ec = document.getElementById('exchangeChart');
    if (ec && typeof drawChart === 'function')
      drawChart(ec, labels, prices, 'rgba(139,92,246,1)', 'rgba(139,92,246,0.1)', 200);
  }

  // ── APPLY: TRANSACTIONS ────────────────────────────────────
  // Server format (from fcrypto:getHistory / crypto_transactions table):
  //   { type, amount, wallet_from, wallet_to, hash / tx_id, created_at / timestamp, status }
  function applyTransactions(raw) {
    if (!Array.isArray(raw)) return;
    S.transactions = raw;

    const normalised = raw.map(tx => ({
      type   : _normType(tx.type),
      amount : _fmtAmt(tx),
      addr   : _txAddr(tx),
      hash   : tx.hash || tx.tx_id || '—',
      time   : _fmtTs(tx.timestamp || tx.created_at),
      status : tx.status || 'confirmed',
    }));

    // Overwrite the global txData array the HTML inline script uses
    window.txData = normalised;
    if (typeof buildTxTable === 'function') buildTxTable('all');

    // Rebuild wallet panel history list
    _buildWalletTxList(normalised.slice(0, 8));
  }

  function _buildWalletTxList(list) {
    const icons  = { recv: '📥', send: '📤', mine: '⛏', trade: '🔄' };
    const labels = { recv: 'Received', send: 'Sent', mine: 'Mining Reward', trade: 'Exchange' };
    // second card inside wallet panel (history column)
    const col = document.querySelector('#panel-wallet .two-col > div:last-child .card');
    if (!col) return;
    let html = '<div class="section-title">Transaction History</div>';
    list.forEach(tx => {
      const icon  = icons[tx.type]  || '📋';
      const label = labels[tx.type] || tx.type;
      const isPos = tx.amount.startsWith('+');
      html += `
        <div class="tx-row">
          <div class="tx-icon ${tx.type}">${icon}</div>
          <div class="tx-info">
            <div class="tx-type">${esc(label)}</div>
            <div class="tx-addr">${esc(tx.addr)}</div>
          </div>
          <div class="tx-amount">
            <div class="tx-val ${isPos ? 'pos' : 'neg'}">${esc(tx.amount)}</div>
            <div class="tx-time">${esc(tx.time)}</div>
          </div>
        </div>`;
    });
    col.innerHTML = html;
  }

  // ── APPLY: NETWORK STATS ───────────────────────────────────
  function applyNetworkStats(stats) {
    S.networkStats = stats;
    // Block height
    const bh = document.getElementById('blockHeight');
    if (bh && stats.blockHeight) bh.textContent = Number(stats.blockHeight).toLocaleString();
    // Net stat cards (matched by label text)
    document.querySelectorAll('.net-stat').forEach(el => {
      const lbl = el.querySelector('.net-stat-label')?.textContent?.trim();
      const val = el.querySelector('.net-stat-val');
      if (!lbl || !val) return;
      if (lbl === 'Block Height'   && stats.blockHeight)   val.textContent = Number(stats.blockHeight).toLocaleString();
      if (lbl === 'Network Hash'   && stats.networkHash)   val.textContent = parseFloat(stats.networkHash).toFixed(2) + ' TH/s';
      if (lbl === 'Difficulty'     && stats.difficulty)    val.textContent = parseFloat(stats.difficulty).toFixed(2) + 'T';
      if (lbl === 'Active Nodes'   && stats.nodes)         val.textContent = Number(stats.nodes).toLocaleString();
    });
  }

  // ── APPLY: RECENT BLOCKS ───────────────────────────────────
  // Server format (from crypto_blocks table):
  //   { number/block_number, hash, transactions, timestamp/time }
  function applyBlocks(blocks) {
    if (!Array.isArray(blocks)) return;
    S.blocks = blocks;
    const list = document.getElementById('blockList');
    if (!list) return;
    list.innerHTML = blocks.map(b => `
      <div class="block-row">
        <div class="block-num">#${Number(b.number ?? b.block_number ?? 0).toLocaleString()}</div>
        <div class="block-hash">${esc(b.hash || '—')}</div>
        <div class="block-txs">${b.transactions ?? b.tx_count ?? 0} txs</div>
        <div class="block-time">${esc(b.time || _fmtTs(b.timestamp))}</div>
      </div>`).join('');
  }

  // ── APPLY: ACTIVITY FEED ───────────────────────────────────
  function addActivity(type, message, time, amount) {
    const colorMap = {
      mine  : 'var(--accent-violet)',
      recv  : 'var(--accent-emerald)',
      send  : 'var(--accent-red)',
      trade : 'var(--accent-cyan)',
      info  : 'var(--text-muted)',
      mining: 'var(--accent-violet)',
    };
    const color = colorMap[type] || colorMap.info;
    const msg   = amount ? `${message} (${parseFloat(amount).toFixed(4)} FTC)` : message;

    S.activity.unshift({ msg, color, time: time || 'just now' });
    if (S.activity.length > 20) S.activity.pop();

    const feed = document.getElementById('activityFeed');
    if (!feed) return;
    const div  = document.createElement('div');
    div.className = 'activity-item';
    div.innerHTML = `
      <div class="act-dot" style="background:${color}"></div>
      <div>
        <div class="act-msg">${esc(msg)}</div>
        <div class="act-time">${esc(time || 'just now')}</div>
      </div>`;
    feed.prepend(div);
    while (feed.children.length > 20) feed.removeChild(feed.lastChild);
  }

  // ── TRANSACTION RESULT HANDLER ─────────────────────────────
  function handleTransactionResult(data) {
    if (data.success) {
      // Show the actual server message (e.g. "Sent 9 FTC to 0x... (fee: 1)")
      // Fall back to generic only if message is missing
      const msg = data.message || 'Transaction confirmed';
      showNotif('✓ ' + msg, 'success');

      // newBalance arrives via a separate updateBalance message triggered by
      // TriggerServerEvent("crypto:getBalance") in nui_bridge — no need to
      // call applyBalance here unless the server bundled it directly
      if (data.newBalance !== undefined) applyBalance(data.newBalance);

      // Reset send form and close modal
      const sa = document.getElementById('sendAddr');
      const sm = document.getElementById('sendAmount');
      const st = document.getElementById('sendTotal');
      if (sa) sa.value = '';
      if (sm) sm.value = '';
      if (st) st.textContent = '0.000 FTC';
      if (typeof closeModal === 'function') closeModal();
    } else {
      // Show the actual error reason from server (e.g. "Wallet not found.", "Insufficient funds.")
      showNotif('✗ ' + (data.message || 'Transaction failed'), 'error');
      if (typeof closeModal === 'function') closeModal();
    }
  }

  // ── EXCHANGE RESULT HANDLER ────────────────────────────────
  function handleExchangeResult(data) {
    if (data.success) {
      const verb = data.tradeType === 'buy' ? 'BUY' : 'SELL';
      showNotif(`✓ ${verb} executed · ${parseFloat(data.amount || 0).toFixed(4)} FTC`, 'success');
      if (data.newBalance !== undefined) applyBalance(data.newBalance);
    } else {
      showNotif('✗ ' + (data.message || 'Exchange failed'), 'error');
    }
    const b = document.getElementById('buyUSD');
    const s = document.getElementById('sellCRN');
    if (b) b.value = '';
    if (s) s.value = '';
    calcBuy(); calcSell();
  }

  // ── PIN MODAL (wallet creation) ──────────────────────────────
  window.closePinModal = function () {
    const m = document.getElementById('pinModal');
    if (m) m.classList.remove('open');
    const inp = document.getElementById('pinInput');
    if (inp) inp.value = '';
    // Hide the tablet frame and release NUI focus — terminal wasn't open before
    if (!S.open) {
      const frame = document.getElementById('tablet-frame');
      if (frame) frame.style.display = 'none';
      nuiCB('closeTerminal', {});
    }
  };

  window.confirmPin = function () {
    const pin = (document.getElementById('pinInput')?.value || '').trim();
    if (!/^\d{4}$/.test(pin)) {
      showNotif('✗ PIN must be exactly 4 digits', 'error');
      return;
    }
    nuiCB('createPhysicalWallet', { passcode: pin }, function (res) {
      if (res && res.success) {
        closePinModal();
        showNotif('✓ Wallet created!', 'success');
      } else {
        showNotif('✗ ' + (res?.message || 'Wallet creation failed'), 'error');
      }
    });
  };

  // Enter key submits PIN modal
  document.addEventListener('keydown', function (e) {
    const pinModal = document.getElementById('pinModal');
    if (e.key === 'Enter' && pinModal && pinModal.classList.contains('open')) {
      window.confirmPin();
    }
  });

  // ── OVERRIDES: replace HTML inline mock functions ──────────

  // confirmSend – called by the modal "CONFIRM SEND" button
  // Sends NUI callback → client/terminal.lua RegisterNUICallback("sendTransaction")
  // → TriggerServerEvent("crypto:transfer", address, amount)
  window.confirmSend = function () {
    const addr   = document.getElementById('sendAddr')?.value?.trim();
    const amount = parseFloat(document.getElementById('sendAmount')?.value);

    if (!addr || addr.length < 4) {
      showNotif('✗ Enter a valid wallet address', 'error');
      return;
    }
    if (isNaN(amount) || amount <= 0) {
      showNotif('✗ Enter a valid amount', 'error');
      return;
    }

    nuiCB('sendTransaction', { address: addr, amount: amount });
    // Result arrives async via transactionResult message
    if (typeof closeModal === 'function') closeModal();
    showNotif('⏳ Broadcasting transaction…', 'success');
  };

  // executeTrade – called by BUY / SELL buttons
  // buyCrypto  → client/trading.lua → TriggerServerEvent("crypto:buy",  amount)
  // sellCrypto → client/trading.lua → TriggerServerEvent("crypto:sell", amount)
  window.executeTrade = function (type) {
    if (type === 'buy') {
      const usd = parseFloat(document.getElementById('buyUSD')?.value);
      if (isNaN(usd) || usd <= 0) { showNotif('✗ Enter a valid USD amount', 'error'); return; }
      nuiCB('buyCrypto', { amount: usd });
    } else {
      const ftc = parseFloat(document.getElementById('sellCRN')?.value);
      if (isNaN(ftc) || ftc <= 0) { showNotif('✗ Enter a valid FTC amount', 'error'); return; }
      nuiCB('sellCrypto', { amount: ftc });
    }
    showNotif('⏳ Order submitted…', 'success');
  };

  // copyAddr – wallet address copy button
  window.copyAddr = function () {
    if (navigator.clipboard && S.walletAddress !== '—') {
      navigator.clipboard.writeText(S.walletAddress).catch(() => {});
    }
    showNotif('✓ Address copied to clipboard', 'success');
    nuiCB('copyAddress', {});
  };

  // calcBuy / calcSell – use live State.price (not hardcoded PRICE const)
  // ExchangeSpread = 0.03 (3%) from Config
  window.calcBuy = function () {
    const usd  = parseFloat(document.getElementById('buyUSD')?.value) || 0;
    const fee  = usd * 0.03;
    const ftc  = S.price > 0 ? (usd - fee) / S.price : 0;
    const recv = document.getElementById('buyReceive');
    const feeE = document.getElementById('buyFee');
    if (recv) recv.textContent = ftc.toFixed(4) + ' FTC';
    if (feeE) feeE.textContent = '$' + fee.toFixed(2);
  };

  window.calcSell = function () {
    const ftc   = parseFloat(document.getElementById('sellCRN')?.value) || 0;
    const gross = ftc * S.price;
    const fee   = gross * 0.03;
    const net   = gross - fee;
    const recv  = document.getElementById('sellReceive');
    const feeE  = document.getElementById('sellFee');
    if (recv) recv.textContent = '$' + net.toFixed(2);
    if (feeE) feeE.textContent = '$' + fee.toFixed(2);
  };

  // ── DOM HELPERS ────────────────────────────────────────────

  // Update a dashboard stat card by its label text
  function _statCard(labelText, value, subText, isUp) {
    document.querySelectorAll('.stat-card').forEach(card => {
      const lbl = card.querySelector('.stat-label');
      if (!lbl || !lbl.textContent.includes(labelText)) return;
      const val = card.querySelector('.stat-value');
      if (val) val.textContent = value;
      if (subText !== undefined) {
        const sub = card.querySelector('.stat-sub');
        if (sub) sub.innerHTML = `<span class="${isUp ? 'stat-up' : 'stat-down'}">${esc(subText)}</span>`;
      }
    });
  }

  // Update a mining panel stat card
  function _miningStatCard(labelText, value) {
    document.querySelectorAll('.mining-stat').forEach(el => {
      const lbl = el.querySelector('.mining-stat-label');
      if (!lbl || !lbl.textContent.includes(labelText)) return;
      const val = el.querySelector('.mining-stat-val');
      if (val) val.textContent = value;
    });
  }

  // ── FORMAT HELPERS ─────────────────────────────────────────

  // Map DB type strings to UI icon keys
  function _normType(type) {
    if (!type) return 'recv';
    const t = type.toLowerCase();
    if (t === 'mining' || t === 'mining_reward' || t === 'warehouse_mining') return 'mine';
    if (t === 'sell'   || t === 'transfer_out'  || t === 'p2p_transfer' || t === 'transfer') return 'send';
    if (t === 'buy'    || t === 'transfer_in'   || t === 'received')      return 'recv';
    if (t === 'block_tx') return 'trade';
    return 'recv';
  }

  function _fmtAmt(tx) {
    const a = parseFloat(tx.amount) || 0;
    const t = (tx.type || '').toLowerCase();
    const out = t === 'sell' || t === 'transfer_out' || t === 'p2p_transfer' || t === 'transfer';
    return (out ? '-' : '+') + a.toFixed(4);
  }

  // Determine address label for a transaction row
  function _txAddr(tx) {
    const t = (tx.type || '').toLowerCase();
    if (t.includes('mining'))          return 'Mining Pool';
    if (t === 'buy' || t === 'sell')   return 'Exchange';
    if (tx.wallet_to   === 'EXCHANGE') return 'Exchange';
    if (tx.wallet_from === 'EXCHANGE') return 'Exchange';
    if (tx.wallet_from === 'NETWORK')  return 'Network';
    // Prefer the counterparty wallet
    return tx.address || tx.wallet_to || tx.wallet_from || tx.addr || '—';
  }

  function _fmtTs(ts) {
    if (!ts) return '—';
    const d = typeof ts === 'number' ? new Date(ts * 1000) : new Date(ts);
    if (isNaN(d.getTime())) return String(ts);
    return d.toLocaleString('en-GB', {
      day: '2-digit', month: 'short',
      hour: '2-digit', minute: '2-digit',
    });
  }

  function esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ── FIVEM INIT ─────────────────────────────────────────────
  if (IS_FIVEM) {
    // Kill ALL simulated data intervals — server is source of truth
    if (window.__priceInterval)       clearInterval(window.__priceInterval);
    if (window.__blockInterval)       clearInterval(window.__blockInterval);
    if (window.__chartUpdateInterval) clearInterval(window.__chartUpdateInterval);

    // ── BLANK ALL MOCK/PLACEHOLDER DATA ──────────────────────
    // Run after a short tick so the inline script has finished executing
    setTimeout(_clearMockData, 0);

    console.log('[FlameNet] NUI bridge active – waiting for openTerminal');
  } else {
    console.log('[FlameNet] Browser mode – using simulated data from inline script');
  }

  // Wipes every piece of fake/hardcoded data the inline script rendered,
  // replacing it with neutral "–" / "..." loading states.
  function _clearMockData() {

    // ── TOP BAR ──────────────────────────────────────────────
    const lp = document.getElementById('livePrice');
    const lc = document.getElementById('livePriceChange');
    const wa = document.querySelector('.wallet-addr');
    if (lp) lp.textContent = '$—';
    if (lc) { lc.textContent = '—'; lc.className = 'coin-change'; }
    if (wa) wa.textContent = '—';

    // ── DASHBOARD STAT CARDS ─────────────────────────────────
    document.querySelectorAll('.stat-card').forEach(card => {
      const val = card.querySelector('.stat-value');
      const sub = card.querySelector('.stat-sub');
      if (val) val.textContent = '—';
      if (sub) sub.innerHTML = '';
    });

    // ── DASHBOARD MINING STATUS BARS (ID-targeted) ────────────
    ['dashHashLabel','dashPowerLabel','dashGPULabel'].forEach(id => {
      const el = document.getElementById(id); if (el) el.textContent = '—';
    });
    ['dashHashBar','dashPowerBar','dashGPUBar'].forEach(id => {
      const el = document.getElementById(id); if (el) el.style.width = '0%';
    });

    // ── DASHBOARD EARNINGS BOX (ID-targeted) ─────────────────
    const dftc = document.getElementById('dashDailyFTC');
    const dusd = document.getElementById('dashDailyUSD');
    if (dftc) dftc.textContent = '— FTC';
    if (dusd) dusd.textContent = '≈ $— USD';

    // ── PRICE CHARTS – clear canvases ───────────────────────
    ['priceChart','exchangeChart','miningChart','networkChart'].forEach(id => {
      const c = document.getElementById(id);
      if (c) { const ctx = c.getContext('2d'); ctx.clearRect(0,0,c.width,c.height); }
    });

    // ── RECENT ACTIVITY (dashboard left card) ────────────────
    const dashAct = document.querySelector('#panel-dashboard .two-col .card:first-child');
    if (dashAct) {
      dashAct.innerHTML = '<div class="section-title">Recent Activity</div>' +
        '<div style="padding:16px 0;text-align:center;font-size:11px;color:var(--text-muted);">Waiting for server data\u2026</div>';
    }

    // ── WALLET PANEL ─────────────────────────────────────────
    const hero    = document.querySelector('.wallet-main-balance');
    const heroUsd = document.querySelector('.wallet-usd');
    const addrEl  = document.querySelector('.wallet-addr-full span');
    if (hero)    hero.textContent    = '— FTC';
    if (heroUsd) heroUsd.textContent = '≈ $— USD';
    if (addrEl)  addrEl.textContent  = '—';

    const walletTxCard = document.querySelector('#panel-wallet .two-col > div:last-child .card');
    if (walletTxCard) {
      walletTxCard.innerHTML = '<div class="section-title">Transaction History</div>' +
        '<div style="padding:16px 0;text-align:center;font-size:11px;color:var(--text-muted);">Waiting for server data\u2026</div>';
    }

    // ── MINING PANEL ─────────────────────────────────────────
    document.querySelectorAll('#panel-mining .mining-stat .mining-stat-val').forEach(el => el.textContent = '—');
    const gpuGrid = document.querySelector('#panel-mining .gpu-grid');
    if (gpuGrid) {
      let html = '';
      for (let i = 1; i <= 10; i++) {
        html += `<div class="gpu-card" style="opacity:0.4;border-style:dashed;">
          <div class="gpu-name" style="color:var(--text-muted)">Slot ${i} <span style="font-size:9px;">EMPTY</span></div>
          <div class="gpu-bar-wrap"><div class="gpu-bar" style="width:0%"></div></div>
          <div class="gpu-stats"><span class="gpu-stat-val">0 MH/s</span><span class="gpu-stat-val">0W</span></div>
        </div>`;
      }
      gpuGrid.innerHTML = html;
    }

    // ── EXCHANGE PANEL ───────────────────────────────────────
    const mpPrice  = document.querySelector('.mp-price');
    const mpChange = document.querySelector('.mp-change');
    const mktHigh  = document.getElementById('mktHigh');
    const mktLow   = document.getElementById('mktLow');
    const mktVol   = document.getElementById('mktVol');
    if (mpPrice)  mpPrice.textContent  = '$—';
    if (mpChange) { mpChange.textContent = '—'; mpChange.className = 'mp-change'; }
    if (mktHigh)  mktHigh.textContent  = '$—';
    if (mktLow)   mktLow.textContent   = '$—';
    if (mktVol)   mktVol.textContent   = '—';

    // ── TRANSACTIONS TABLE ───────────────────────────────────
    const tbody = document.getElementById('txTableBody');
    if (tbody) {
      tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:20px;color:var(--text-muted);font-size:11px;">Waiting for server data\u2026</td></tr>';
    }

    // ── BLOCKCHAIN PANEL ─────────────────────────────────────
    document.querySelectorAll('.net-stat .net-stat-val').forEach(el => el.textContent = '—');
    const blockHeightEl = document.getElementById('blockHeight');
    if (blockHeightEl) blockHeightEl.textContent = '—';
    const blockList = document.getElementById('blockList');
    if (blockList) {
      blockList.innerHTML = '<div style="padding:16px 0;text-align:center;font-size:11px;color:var(--text-muted);">Waiting for server data\u2026</div>';
    }

    // ── ACTIVITY FEED (right panel) ──────────────────────────
    const feed = document.getElementById('activityFeed');
    if (feed) {
      feed.innerHTML = '<div style="padding:20px 0;text-align:center;font-size:11px;color:var(--text-muted);">Waiting for activity\u2026</div>';
    }
  }

})();