# WarungPay — DoraHacks Submission Draft (Aevum Builder Challenge #1)

> DRAFT — dilengkapi setelah deploy + video. Jangan submit sebelum alamat kontrak dan link video terisi.

## Project
**WarungPay** — Invoice Payments untuk warung di Aevum testnet.
Merchant bikin tagihan (jumlah + catatan + expiry) → buyer bayar tUSD8 → kontrak split otomatis **90% merchant / 10% tabungan merchant** → struk on-chain. Kasir dapat session key (cap per tagihan + expiry, revoke instan).

## Team
Solo — pojokkanan29 (@zec3on), Indonesia. Terdaftar sebagai hacker #232.

## Links
- Repo: https://github.com/naplex666/warungpay
- Live demo: https://naplex666.github.io/warungpay/
- Kontrak WarungPay (Aevum testnet 44005): _TBD setelah deploy_
- Explorer: https://explorer-test.qday.info/address/_TBD_
- Video demo: _TBD_
- Token: tUSD8 `0x456569838f1d43009A91ebA4263147Afd7233483` (6 desimal)

## Fitur
- `registerMerchant`, `createInvoice`, `payInvoice` (split 90/10 otomatis, default; `setSplit` 0–50%)
- `savingsOf`, `withdrawSavings` (pull-payment)
- `grantCashier` / `revokeCashier` (cap per tagihan + expiry, revoke instan)
- `setDailyCap` (0 = unlimited)
- Event untuk semua aksi, custom errors, ReentrancyGuard
- UI 2 tab (Merchant / Pembeli), Bahasa Indonesia, ethers.js v6, MetaMask

## Keamanan
- Audit pra-deploy PASS: Slither 0 High / 0 Medium, Aderyn 0 High, forge test 27/27, coverage 100% baris + fungsi, gitleaks bersih. Laporan: `audit-report.md` di repo.

## Cara coba
1. Buka demo, connect MetaMask, tambah chain Aevum testnet (44005).
2. Tab Merchant: daftar → buat tagihan (mis. 1 tUSD8).
3. Tab Pembeli: cari tagihan pakai ID → Approve tUSD8 → Bayar → lihat struk (merchant share + savings share).
