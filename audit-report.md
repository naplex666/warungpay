# Audit Pra-Deploy — WarungPay

- **Tanggal:** 20 Nov 2026
- **Proyek:** WarungPay (Aevum Builder Challenge #1, track Invoice Payments)
- **Kontrak:** `src/WarungPay.sol` (Solidity ^0.8.24, OpenZeppelin ReentrancyGuard + IERC20)
- **Commit yang diaudit:** `8384100` (HEAD saat audit; kontrak di `1b06ae0`)
- **Toolchain:** forge (solc 0.8.24, optimizer 200 runs), Slither 0.11.6, Aderyn 0.6.8, gitleaks 8.30.1
- **Skill:** `auditing-foundry-smart-contract-security` — Steps 1, 2, 4, 6, 7. Mythril di-SKIP (sesuai LOCAL RULES — ZEC).
- **Status deploy:** belum di-deploy (faucet tQDAY/tUSD8 masih 0 — terpisah dari gate ini).

## Gate: ✅ PASS

Tidak ada temuan High/Critical, semua test lolos, tidak ada secret bocor.
Kontrak **boleh deploy ke Aevum testnet** setelah faucet terisi. Perbaikan di bawah
bersifat rekomendasi (Low/Info), bukan blocker.

## 1. Build & Test (Step 1 + 4)

- `forge build`: sukses (solc 0.8.24; hanya warning lint `environment-read-across-mutation` di file test, bukan di kontrak).
- `forge test`: **27/27 PASS, 0 fail** — lifecycle tagihan, split 90/10, expiry, cap kasir, revoke, daily cap, setSplit, withdraw.
- `forge coverage` (`src/WarungPay.sol`):
  - Lines **100%** (78/78), Statements 92,63%, Branches 70% (21/30), Functions **100%** (15/15).
  - Fungsi pemindah dana: `payInvoice` dan `withdrawSavings` tercakup penuh di level baris
    (semua jalur sukses tereksekusi). 9 branch yang belum tercakup semuanya jalur
    revert defensif: `TransferFailed` (butuh mock token yang return false),
    constructor zero-address (tidak ada test), dan beberapa cabang guard yang
    perilakunya sudah diuji lewat test revert bernama (mis. `testGrantCashierZeroCapReverts`).

## 2. Slither (Step 2) — 9 temuan, 0 High / 0 Medium

| # | Detector | Severity | Lokasi | Triase |
|---|----------|----------|--------|--------|
| S1–S5 | `timestamp` (block.timestamp untuk expiry) | Low | grantCashier, isCashier, payInvoice, createInvoiceFor, _createInvoice | **False positive (by design).** Manipulasi timestamp miner ±detik tidak relevan untuk expiry skala hari. |
| S6 | `pragma` (2 versi Solidity) | Info | OZ lib ^0.8.20 vs proyek ^0.8.24 | Kosmetik. |
| S7 | `solc-version` (bug di constraint ^0.8.20) | Info | OZ lib | **False positive.** Compiler aktual ter-pin 0.8.24 di foundry.toml; ketiga bug yang disebut sudah diperbaiki di 0.8.22/0.8.23. |
| S8–S9 | `naming-convention` (`_savingsBps`, `_dailyCap`) | Info | setSplit, setDailyCap | Kosmetik. |

Catatan: Slither exit code 255, tapi analisis selesai penuh
("analyzed (3 contracts with 102 detectors), 9 result(s) found") dan JSON lengkap.

## 3. Aderyn (Step 2) — 0 High, 6 Low

| # | Temuan | Severity | Lokasi | Triase |
|---|--------|----------|--------|--------|
| A1 | Large Numeric Literal (`10_000`) | Low | L22 | Kosmetik. |
| A2 | `nonReentrant` bukan modifier pertama | Low | `withdrawSavings` L275 (`onlyMerchant nonReentrant`) | **Tidak berdampak.** `onlyMerchant` hanya baca storage, tidak ada external call, jadi urutan tidak membuka celah reentrancy. Perbaiki opsional (balik urutan). |
| A3 | PUSH0 Opcode (default EVM Shanghai sejak solc 0.8.20) | Low | L2 | Info. foundry.toml tidak set `evm_version` → default Foundry Cancun; Aevum chain era 2025–26 hampir pasti Shanghai+. Deploy akan mengonfirmasi; rekomendasikan set `evm_version` eksplisit. |
| A4 | Unsafe ERC20 Operation | Low | `payInvoice` L256/259, `withdrawSavings` L279 | **Low, bukan High.** Kode SUDAH cek return value (`if (!token.transferFrom(...)) revert TransferFailed()`). Risiko sisa: token non-standar tanpa return value (→ revert = DoS, bukan pencurian) dan fee-on-transfer (akuntansi tabungan bisa drift). Verifikasi perilaku tUSD8 saat uji deploy; idealnya pakai SafeERC20. |
| A5 | Unspecific Solidity Pragma (`^0.8.24`) | Low | L2 | Info; versi ter-pin di foundry.toml. |
| A6 | Public Function Not Used Internally (`isCashier`) | Low | L179 | Kosmetik (sengaja public untuk UI). |

## 4. Gitleaks (Step 6) — 154 temuan, semua false positive

- 151 di `lib/openzeppelin-contracts/test/*` (fixture test upstream, kode pihak ketiga).
- 2 di `docs/vendor/ethers.umd.min.js` (default token publik dari library ethers).
- 1 di `docs/config.js`: alamat kontrak tUSD8 `0x45656983…` — **alamat publik on-chain, bukan secret**.
- **Tidak ada** private key, mnemonic, atau API key. `git ls-files` tidak menemukan
  file `.env`/keystore/deployer/secret yang ter-track.
- `hidden_files/deployer.json` ada di **luar repo** (`../hidden_files/`), mode 600,
  tidak ter-track git. ✅
- `script/Deploy.s.sol` baca key dari env `PRIVATE_KEY` (tidak hardcode);
  `deploy.sh` baca dari `hidden_files/deployer.json` tanpa print isinya.

## 5. Review manual (ringkas, dari pembacaan kode)

- **Reentrancy:** `payInvoice` + `withdrawSavings` pakai `nonReentrant`; efek
  (paid=true, saldo tabungan) ditulis sebelum interaksi; return value transfer dicek. ✅
- **Access control:** `onlyMerchant` untuk setting; `createInvoiceFor` cek
  revoked/expired/cap kasir; `_createInvoice` cek merchant aktif. ✅
- **Aritmetika:** Solidity 0.8.24 (overflow check bawaan); `savingsShare` round-down,
  `merchantShare = amount - savingsShare` → tidak ada dust/loss. ✅
- **Daily cap:** `receivedPerDay + amount > cap` dicek sebelum transfer; revert
  membatalkan seluruh tx termasuk akuntansi. ✅
- **Lainnya:** tidak ada loop unbounded, tidak ada oracle, tidak ada `delegatecall`/
  upgrade, tidak ada owner/admin (dana tidak bisa dikunci admin); `withdrawSavings`
  pull-payment. ✅

## 6. Perbaikan yang disarankan (bukan blocker — jangan tunda deploy karenanya)

1. (Low) Pakai OpenZeppelin `SafeERC20`, atau verifikasi tUSD8 standar (return bool,
   tanpa fee-on-transfer) saat uji deploy.
2. (Low) Balik urutan modifier `withdrawSavings` jadi `nonReentrant onlyMerchant`.
3. (Info) Set `evm_version = "cancun"` eksplisit di `foundry.toml`.
4. (Info) Tambah test mock-token untuk cabang `TransferFailed` + test constructor
   zero-address (angkat branch coverage).
5. (Info) Tambah `.gitleaksignore` untuk `lib/` dan `docs/vendor/` supaya scan
   berikutnya bersih dari false positive vendored.

## Bukti

- `slither-report.json`, `aderyn-report.json` (di repo ini).
- Test: `forge test` 27/27 PASS. Coverage: `forge coverage --report summary`.
