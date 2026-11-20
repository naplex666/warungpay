// WarungPay — logika frontend (ethers.js v6, tanpa build step)
// Semua nominal tUSD8 memakai 6 desimal.
"use strict";

const TOKEN_DECIMALS = 6;

let provider = null;      // ethers.BrowserProvider
let readProvider = null;  // ethers.JsonRpcProvider (baca publik, tanpa wallet)
let signer = null;
let account = null;
let contract = null;      // WarungPay (signer)
let contractRead = null;  // WarungPay (read-only)
let token = null;         // tUSD8 (signer)
let tokenRead = null;     // tUSD8 (read-only)
let currentInvoice = null;

const $ = (id) => document.getElementById(id);

function log(msg) {
  const el = $("log");
  const ts = new Date().toLocaleTimeString("id-ID");
  el.textContent = `[${ts}] ${msg}\n` + el.textContent;
}

function fmt(amount) {
  try { return ethers.formatUnits(amount, TOKEN_DECIMALS); } catch { return "?"; }
}

function parseAmount(str) {
  return ethers.parseUnits(String(str).trim(), TOKEN_DECIMALS);
}

function shortAddr(a) {
  return a ? a.slice(0, 6) + "…" + a.slice(-4) : "—";
}

function fmtDate(ts) {
  const d = new Date(Number(ts) * 1000);
  return d.toLocaleString("id-ID");
}

function friendlyError(e) {
  const m = (e && (e.reason || e.shortMessage || e.message)) || "Terjadi kesalahan.";
  // Potong pesan revert yang panjang dari ethers.
  return String(m).slice(0, 300);
}

function contractReady() {
  return Boolean(CONTRACT_ADDRESS) && contractRead !== null;
}

function setWriteEnabled(enabled) {
  // Tombol tulis hanya aktif kalau kontrak sudah di-deploy DAN wallet terhubung.
  const ids = ["btnRegister", "btnCreateInvoice", "btnRefreshInvoices", "btnGrantCashier",
    "btnRevokeCashier", "btnWithdraw", "btnSetSplit", "btnSetDailyCap", "btnLookup"];
  for (const id of ids) $(id).disabled = !enabled;
  $("btnCreateInvoiceFor").disabled = !enabled;
  $("btnApprove").disabled = !enabled || !currentInvoice;
  $("btnPay").disabled = true; // aktif setelah allowance cukup
}

// ---------------------------------------------------------------------------
// Tab
// ---------------------------------------------------------------------------
document.querySelectorAll(".tab").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
    btn.classList.add("active");
    $("tab-" + btn.dataset.tab).classList.add("active");
  });
});

// ---------------------------------------------------------------------------
// Koneksi wallet & jaringan
// ---------------------------------------------------------------------------
async function ensureChain() {
  if (!provider) return false;
  const net = await provider.getNetwork();
  const ok = Number(net.chainId) === CHAIN_ID;
  $("wrongChainBanner").hidden = ok;
  const badge = $("chainBadge");
  if (ok) {
    badge.textContent = "Aevum Testnet ✓";
    badge.classList.add("ok");
  } else {
    badge.textContent = `Jaringan salah (chain ${net.chainId})`;
    badge.classList.remove("ok");
  }
  return ok;
}

async function switchToAevum() {
  try {
    await provider.send("wallet_switchEthereumChain", [{ chainId: CHAIN_ID_HEX }]);
    log("Pindah ke Aevum Testnet.");
    await refreshAll();
  } catch (e) {
    if (e && e.code === 4902) {
      try {
        await provider.send("wallet_addEthereumChain", [{
          chainId: CHAIN_ID_HEX,
          chainName: "Aevum Testnet",
          nativeCurrency: { name: "tQDAY", symbol: "tQDAY", decimals: 18 },
          rpcUrls: [RPC_URL],
          blockExplorerUrls: [EXPLORER_URL],
        }]);
        log("Aevum Testnet ditambahkan ke MetaMask.");
        await refreshAll();
      } catch (err) { log("Gagal menambah jaringan: " + friendlyError(err)); }
    } else {
      log("Gagal pindah jaringan: " + friendlyError(e));
    }
  }
}

async function connectWallet() {
  if (!window.ethereum) {
    alert("MetaMask tidak ditemukan. Pasang dulu ekstensi MetaMask di browser kamu.");
    log("MetaMask tidak ditemukan di browser ini.");
    return;
  }
  try {
    provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();
    account = await signer.getAddress();
    contract = CONTRACT_ADDRESS ? new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, signer) : null;
    token = new ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, signer);
    $("btnConnect").textContent = shortAddr(account);
    $("balances").hidden = false;
    log("Wallet terhubung: " + account);

    window.ethereum.on("accountsChanged", () => window.location.reload());
    window.ethereum.on("chainChanged", () => window.location.reload());

    await refreshAll();
  } catch (e) {
    log("Gagal menghubungkan wallet: " + friendlyError(e));
  }
}

async function refreshBalances() {
  if (!account) return;
  try {
    const bal = await provider.getBalance(account);
    $("balNative").textContent = ethers.formatEther(bal).slice(0, 8) + " tQDAY";
    const tb = await tokenRead.balanceOf(account);
    $("balToken").textContent = fmt(tb) + " tUSD8";
  } catch (e) {
    log("Gagal membaca saldo: " + friendlyError(e));
  }
}

// ---------------------------------------------------------------------------
// Merchant
// ---------------------------------------------------------------------------
async function refreshMerchant() {
  if (!contractReady() || !account) return;
  try {
    const m = await contractRead.merchants(account);
    const active = m[1];
    $("merchantStatus").textContent = active
      ? `✅ Kamu sudah terdaftar sebagai merchant (${shortAddr(account)}).`
      : "Kamu belum terdaftar sebagai merchant.";
    $("btnRegister").disabled = active;

    const sb = await contractRead.savingsOf(account);
    $("savingsBalance").textContent = fmt(sb);
    const bps = await contractRead.savingsBps(account);
    $("splitCurrent").textContent = (Number(bps) / 100).toFixed(1) + "%";
    const cap = await contractRead.dailyCap(account);
    $("dailyCapCurrent").textContent = Number(cap) === 0 ? "tanpa batas" : fmt(cap) + " tUSD8";
  } catch (e) {
    log("Gagal membaca status merchant: " + friendlyError(e));
  }
}

async function loadMyInvoices() {
  if (!contractReady() || !account) return;
  const list = $("invoiceList");
  list.innerHTML = "<p class='muted'>Memuat…</p>";
  try {
    const next = Number(await contractRead.nextInvoiceId());
    const items = [];
    for (let id = next - 1; id >= 1 && items.length < 50; id--) {
      const inv = await contractRead.getInvoice(id);
      if (inv.merchant.toLowerCase() === account.toLowerCase()) items.push(inv);
    }
    if (items.length === 0) {
      list.innerHTML = "<p class='muted'>Belum ada tagihan.</p>";
      return;
    }
    list.innerHTML = items.map((inv) => {
      const paid = inv.paid;
      const expired = !paid && Date.now() / 1000 > Number(inv.expiry);
      return `<div class="list-item">
        <b>#${inv.id}</b> — ${fmt(inv.amount)} tUSD8 — ${paid ? '<span class="paid">LUNAS</span>' : expired ? "kedaluwarsa" : '<span class="unpaid">belum dibayar</span>'}<br>
        ${inv.note ? "📝 " + escapeHtml(inv.note) + "<br>" : ""}
        Berlaku sampai: ${fmtDate(inv.expiry)}${paid ? "<br> Dibayar oleh: " + shortAddr(inv.payer) : ""}
      </div>`;
    }).join("");
    log(`Memuat ${items.length} tagihan milikmu.`);
  } catch (e) {
    list.innerHTML = "<p class='muted'>Gagal memuat tagihan.</p>";
    log("Gagal memuat tagihan: " + friendlyError(e));
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// ---------------------------------------------------------------------------
// Pembeli
// ---------------------------------------------------------------------------
async function lookupInvoice() {
  const id = Number($("lookupId").value);
  if (!id || id < 1) { alert("Masukkan ID tagihan yang valid."); return; }
  if (!contractReady()) return;
  try {
    const inv = await contractRead.getInvoice(id);
    if (inv.merchant === ethers.ZeroAddress) {
      $("invoiceDetail").innerHTML = "<p class='muted'>Tagihan tidak ditemukan.</p>";
      $("payBox").hidden = true;
      currentInvoice = null;
      return;
    }
    currentInvoice = inv;
    const paid = inv.paid;
    const expired = !paid && Date.now() / 1000 > Number(inv.expiry);
    $("invoiceDetail").innerHTML = `<div class="list-item">
      <b>Tagihan #${inv.id}</b> — ${fmt(inv.amount)} tUSD8 — ${paid ? '<span class="paid">LUNAS</span>' : expired ? "kedaluwarsa" : '<span class="unpaid">belum dibayar</span>'}<br>
      Merchant: ${shortAddr(inv.merchant)}<br>
      ${inv.note ? "📝 " + escapeHtml(inv.note) + "<br>" : ""}
      Berlaku sampai: ${fmtDate(inv.expiry)}${paid ? "<br>Dibayar oleh: " + shortAddr(inv.payer) : ""}
    </div>`;
    $("payBox").hidden = paid || expired;
    $("receipt").hidden = true;
    if (!paid && !expired) await refreshAllowance();
    log(`Tagihan #${id} ditemukan: ${fmt(inv.amount)} tUSD8.`);
  } catch (e) {
    log("Gagal mencari tagihan: " + friendlyError(e));
  }
}

async function refreshAllowance() {
  if (!currentInvoice || !account) return;
  try {
    const al = await tokenRead.allowance(account, CONTRACT_ADDRESS);
    $("allowanceText").textContent = fmt(al) + " tUSD8";
    $("btnPay").disabled = al < currentInvoice.amount;
    $("btnApprove").disabled = al >= currentInvoice.amount;
  } catch (e) {
    log("Gagal membaca allowance: " + friendlyError(e));
  }
}

// ---------------------------------------------------------------------------
// Aksi tulis
// ---------------------------------------------------------------------------
async function sendTx(promise, label) {
  log(label + " — mengirim transaksi…");
  const tx = await promise;
  log(label + " — tx terkirim: " + tx.hash);
  const rc = await tx.wait();
  log(label + " — terkonfirmasi di blok " + rc.blockNumber + ".");
  return rc;
}

$("btnConnect").addEventListener("click", connectWallet);
$("btnSwitchChain").addEventListener("click", switchToAevum);

$("btnRegister").addEventListener("click", async () => {
  try {
    await sendTx(contract.registerMerchant(), "Daftar merchant");
    await refreshMerchant();
  } catch (e) { log("Gagal daftar merchant: " + friendlyError(e)); }
});

$("formInvoice").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const amount = parseAmount($("invAmount").value);
    const note = $("invNote").value.trim();
    const expiry = Math.floor(new Date($("invExpiry").value).getTime() / 1000);
    if (expiry <= Date.now() / 1000) { alert("Masa berlaku harus di masa depan."); return; }
    const rc = await sendTx(contract.createInvoice(amount, note, expiry), "Buat tagihan");
    const evt = rc.logs.map((l) => { try { return contract.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === "InvoiceCreated");
    if (evt) log("Tagihan dibuat dengan ID #" + evt.args.invoiceId.toString());
    await loadMyInvoices();
  } catch (e) { log("Gagal membuat tagihan: " + friendlyError(e)); }
});

$("btnRefreshInvoices").addEventListener("click", loadMyInvoices);

$("formCashier").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const addr = $("cashierAddr").value.trim();
    const cap = parseAmount($("cashierCap").value);
    const expiry = Math.floor(new Date($("cashierExpiry").value).getTime() / 1000);
    if (expiry <= Date.now() / 1000) { alert("Masa berlaku harus di masa depan."); return; }
    await sendTx(contract.grantCashier(addr, cap, expiry), "Beri akses kasir " + shortAddr(addr));
  } catch (e) { log("Gagal memberi akses kasir: " + friendlyError(e)); }
});

$("formRevoke").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const addr = $("revokeAddr").value.trim();
    await sendTx(contract.revokeCashier(addr), "Cabut akses kasir " + shortAddr(addr));
  } catch (e) { log("Gagal mencabut kasir: " + friendlyError(e)); }
});

$("formInvoiceFor").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const merchant = $("invForMerchant").value.trim();
    const amount = parseAmount($("invForAmount").value);
    const note = $("invForNote").value.trim();
    const expiry = Math.floor(new Date($("invForExpiry").value).getTime() / 1000);
    if (expiry <= Date.now() / 1000) { alert("Masa berlaku harus di masa depan."); return; }
    const rc = await sendTx(contract.createInvoiceFor(merchant, amount, note, expiry), "Buat tagihan sebagai kasir");
    const evt = rc.logs.map((l) => { try { return contract.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === "InvoiceCreated");
    if (evt) log("Tagihan dibuat dengan ID #" + evt.args.invoiceId.toString());
  } catch (e) { log("Gagal membuat tagihan sebagai kasir: " + friendlyError(e)); }
});

$("formWithdraw").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const amount = parseAmount($("withdrawAmount").value);
    await sendTx(contract.withdrawSavings(amount), "Tarik tabungan " + $("withdrawAmount").value + " tUSD8");
    await refreshMerchant();
  } catch (e) { log("Gagal menarik tabungan: " + friendlyError(e)); }
});

$("formSplit").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const pct = parseFloat($("splitPct").value);
    const bps = Math.round(pct * 100);
    await sendTx(contract.setSplit(bps), "Atur split tabungan " + pct + "%");
    await refreshMerchant();
  } catch (e) { log("Gagal mengatur split: " + friendlyError(e)); }
});

$("formDailyCap").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const cap = parseAmount($("dailyCapAmount").value);
    await sendTx(contract.setDailyCap(cap), "Atur batas harian");
    await refreshMerchant();
  } catch (e) { log("Gagal mengatur batas harian: " + friendlyError(e)); }
});

$("formLookup").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  await lookupInvoice();
});

$("btnApprove").addEventListener("click", async () => {
  if (!currentInvoice) return;
  try {
    await sendTx(token.approve(CONTRACT_ADDRESS, currentInvoice.amount), "Approve " + fmt(currentInvoice.amount) + " tUSD8");
    await refreshAllowance();
    await refreshBalances();
  } catch (e) { log("Gagal approve: " + friendlyError(e)); }
});

$("btnPay").addEventListener("click", async () => {
  if (!currentInvoice) return;
  try {
    const rc = await sendTx(contract.payInvoice(currentInvoice.id), "Bayar tagihan #" + currentInvoice.id);
    const evt = rc.logs.map((l) => { try { return contract.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === "InvoicePaid");
    const ms = evt ? fmt(evt.args.merchantShare) : "?";
    const ss = evt ? fmt(evt.args.savingsShare) : "?";
    $("receipt").innerHTML = `<h3>✅ Pembayaran Berhasil — Struk #${currentInvoice.id}</h3>
      Total: ${fmt(currentInvoice.amount)} tUSD8<br>
      Ke merchant: ${ms} tUSD8<br>
      Ke tabungan merchant: ${ss} tUSD8<br>
      Tx: <a href="${EXPLORER_URL}/tx/${rc.hash}" target="_blank" rel="noopener">${rc.hash.slice(0, 18)}…</a>`;
    $("receipt").hidden = false;
    $("payBox").hidden = true;
    await lookupInvoice();
    await refreshBalances();
  } catch (e) { log("Gagal membayar: " + friendlyError(e)); }
});

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------
async function refreshAll() {
  const ok = await ensureChain();
  if (!ok) return;
  await refreshBalances();
  if (contractReady()) {
    setWriteEnabled(true);
    await refreshMerchant();
    await loadMyInvoices();
  }
}

(function init() {
  readProvider = new ethers.JsonRpcProvider(RPC_URL);
  tokenRead = new ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, readProvider);
  if (CONTRACT_ADDRESS) {
    contractRead = new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, readProvider);
    $("noContractBanner").hidden = true;
    log("Kontrak WarungPay: " + CONTRACT_ADDRESS);
  } else {
    $("noContractBanner").hidden = false;
    setWriteEnabled(false);
    log("Kontrak belum di-deploy — mode lihat saja (saldo & koneksi wallet tetap jalan).");
  }
  if (window.ethereum) {
    // Kalau wallet sudah pernah terhubung, pulihkan sesi diam-diam.
    provider = new ethers.BrowserProvider(window.ethereum);
    provider.listAccounts().then(async (accs) => {
      if (accs.length > 0) {
        signer = await provider.getSigner();
        account = await signer.getAddress();
        $("btnConnect").textContent = shortAddr(account);
        $("balances").hidden = false;
        contract = contractRead ? new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, signer) : null;
        token = new ethers.Contract(TOKEN_ADDRESS, ERC20_ABI, signer);
        window.ethereum.on("accountsChanged", () => window.location.reload());
        window.ethereum.on("chainChanged", () => window.location.reload());
        await refreshAll();
      }
    }).catch(() => { /* abaikan, user bisa klik Hubungkan */ });
  } else {
    log("MetaMask tidak terdeteksi. Pasang MetaMask untuk memakai UI ini.");
  }
  // Set nilai default datetime: sekarang + 1 jam.
  const def = new Date(Date.now() + 3600 * 1000);
  const iso = def.toISOString().slice(0, 16);
  $("invExpiry").value = iso;
  $("cashierExpiry").value = iso;
  $("invForExpiry").value = iso;
})();
