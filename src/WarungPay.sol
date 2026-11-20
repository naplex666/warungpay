// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WarungPay — tUSD8 checkout for small shops (warung) on Aevum testnet
/// @notice Track: Invoice Payments (Aevum Builder Challenge #1)
/// @dev Merchant creates invoices; buyers pay in tUSD8. Each payment is split
///      automatically: (100% - savingsBps) goes straight to the merchant,
///      savingsBps goes to the merchant's on-chain savings pot (pull-payment).
///      Cashiers are session keys: capped per invoice, time-limited, instantly
///      revocable. Daily receive caps protect merchants from runaway volume.
contract WarungPay is ReentrancyGuard {
    // ------------------------------------------------------------------------
    // Constants & token
    // ------------------------------------------------------------------------

    /// @notice Payment token (tUSD8, 6 decimals) on Aevum testnet.
    IERC20 public immutable token;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Maximum savings share: 50%.
    uint256 public constant MAX_SAVINGS_BPS = 5_000;
    /// @notice Default savings share: 10% (90% merchant / 10% savings).
    uint256 public constant DEFAULT_SAVINGS_BPS = 1_000;

    // ------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------

    struct Merchant {
        address owner;
        bool active;
    }

    struct Invoice {
        uint256 id;
        address merchant;
        uint256 amount; // in token smallest units (6 decimals for tUSD8)
        string note;
        uint256 expiry; // unix timestamp; 0 = no expiry is NOT allowed (must be future)
        bool paid;
        address payer;
    }

    struct CashierKey {
        uint256 cap; // max invoice amount this cashier may create
        uint256 expiry; // unix timestamp
        bool revoked;
    }

    // ------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------

    mapping(address => Merchant) public merchants;
    mapping(uint256 => Invoice) public invoices;
    /// @notice merchant => cashier => session key
    mapping(address => mapping(address => CashierKey)) public cashierKeys;
    /// @notice merchant => tUSD8 sitting in the savings pot
    mapping(address => uint256) public savingsBalance;
    /// @notice merchant => savings share in basis points (default 1000 = 10%)
    mapping(address => uint256) public savingsBps;
    /// @notice merchant => max tUSD8 received per UTC day (0 = unlimited)
    mapping(address => uint256) public dailyCap;
    /// @notice merchant => day (unix / 1 days) => tUSD8 received that day
    mapping(address => mapping(uint256 => uint256)) public receivedPerDay;

    uint256 public nextInvoiceId = 1;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event MerchantRegistered(address indexed merchant);
    event InvoiceCreated(
        uint256 indexed invoiceId, address indexed merchant, address indexed createdBy, uint256 amount, uint256 expiry
    );
    event InvoicePaid(
        uint256 indexed invoiceId,
        address indexed merchant,
        address indexed payer,
        uint256 amount,
        uint256 merchantShare,
        uint256 savingsShare
    );
    event SavingsWithdrawn(address indexed merchant, uint256 amount);
    event CashierGranted(address indexed merchant, address indexed cashier, uint256 cap, uint256 expiry);
    event CashierRevoked(address indexed merchant, address indexed cashier);
    event SplitUpdated(address indexed merchant, uint256 savingsBps);
    event DailyCapUpdated(address indexed merchant, uint256 dailyCap);

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

    error AlreadyMerchant();
    error NotMerchant();
    error InvalidAmount();
    error InvalidExpiry();
    error InvoiceNotFound();
    error InvoiceAlreadyPaid();
    error InvoiceExpired();
    error CashierNotAuthorized();
    error CashierCapExceeded();
    error CashierKeyExpired();
    error CashierKeyRevoked();
    error DailyCapExceeded();
    error SavingsBpsTooHigh();
    error InsufficientSavings();
    error TransferFailed();

    // ------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------

    modifier onlyMerchant() {
        if (!merchants[msg.sender].active) revert NotMerchant();
        _;
    }

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    constructor(address _token) {
        require(_token != address(0), "token zero address");
        token = IERC20(_token);
    }

    // ------------------------------------------------------------------------
    // Merchant registration & settings
    // ------------------------------------------------------------------------

    /// @notice Register the caller as a merchant (one-time, idempotent guard).
    function registerMerchant() external {
        if (merchants[msg.sender].active) revert AlreadyMerchant();
        merchants[msg.sender] = Merchant({owner: msg.sender, active: true});
        savingsBps[msg.sender] = DEFAULT_SAVINGS_BPS;
        emit MerchantRegistered(msg.sender);
    }

    /// @notice Set the savings share for this merchant (0-50%).
    function setSplit(uint256 _savingsBps) external onlyMerchant {
        if (_savingsBps > MAX_SAVINGS_BPS) revert SavingsBpsTooHigh();
        savingsBps[msg.sender] = _savingsBps;
        emit SplitUpdated(msg.sender, _savingsBps);
    }

    /// @notice Set the max tUSD8 this merchant may receive per UTC day (0 = unlimited).
    function setDailyCap(uint256 _dailyCap) external onlyMerchant {
        dailyCap[msg.sender] = _dailyCap;
        emit DailyCapUpdated(msg.sender, _dailyCap);
    }

    // ------------------------------------------------------------------------
    // Cashier session keys
    // ------------------------------------------------------------------------

    /// @notice Grant a cashier session key: capped per invoice, time-limited.
    function grantCashier(address cashier, uint256 cap, uint256 expiry) external onlyMerchant {
        require(cashier != address(0), "cashier zero address");
        if (cap == 0) revert InvalidAmount();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        cashierKeys[msg.sender][cashier] = CashierKey({cap: cap, expiry: expiry, revoked: false});
        emit CashierGranted(msg.sender, cashier, cap, expiry);
    }

    /// @notice Revoke a cashier session key instantly.
    function revokeCashier(address cashier) external onlyMerchant {
        CashierKey storage key = cashierKeys[msg.sender][cashier];
        if (key.expiry == 0) revert CashierNotAuthorized();
        key.revoked = true;
        emit CashierRevoked(msg.sender, cashier);
    }

    /// @notice True when `cashier` currently holds a live key for `merchant`.
    function isCashier(address merchant, address cashier) public view returns (bool) {
        CashierKey storage key = cashierKeys[merchant][cashier];
        return key.expiry != 0 && !key.revoked && block.timestamp <= key.expiry;
    }

    // ------------------------------------------------------------------------
    // Invoices
    // ------------------------------------------------------------------------

    /// @notice Merchant creates an invoice for themselves.
    function createInvoice(uint256 amount, string calldata note, uint256 expiry) external onlyMerchant returns (uint256) {
        return _createInvoice(msg.sender, msg.sender, amount, note, expiry);
    }

    /// @notice Authorized cashier creates an invoice on behalf of `merchant`.
    /// @dev Enforces the session key: not revoked, not expired, amount <= cap.
    function createInvoiceFor(address merchant, uint256 amount, string calldata note, uint256 expiry)
        external
        returns (uint256)
    {
        CashierKey storage key = cashierKeys[merchant][msg.sender];
        if (key.expiry == 0) revert CashierNotAuthorized();
        if (key.revoked) revert CashierKeyRevoked();
        if (block.timestamp > key.expiry) revert CashierKeyExpired();
        if (amount > key.cap) revert CashierCapExceeded();
        return _createInvoice(merchant, msg.sender, amount, note, expiry);
    }

    function _createInvoice(address merchant, address createdBy, uint256 amount, string calldata note, uint256 expiry)
        internal
        returns (uint256)
    {
        if (!merchants[merchant].active) revert NotMerchant();
        if (amount == 0) revert InvalidAmount();
        if (expiry <= block.timestamp) revert InvalidExpiry();

        uint256 invoiceId = nextInvoiceId++;
        invoices[invoiceId] = Invoice({
            id: invoiceId,
            merchant: merchant,
            amount: amount,
            note: note,
            expiry: expiry,
            paid: false,
            payer: address(0)
        });
        emit InvoiceCreated(invoiceId, merchant, createdBy, amount, expiry);
        return invoiceId;
    }

    /// @notice Pay an invoice in tUSD8. Split: merchant share straight to the
    /// merchant, savings share into the merchant's savings pot.
    /// @dev Buyer must approve the contract for at least `amount` beforehand.
    function payInvoice(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.merchant == address(0)) revert InvoiceNotFound();
        if (inv.paid) revert InvoiceAlreadyPaid();
        if (block.timestamp > inv.expiry) revert InvoiceExpired();

        // Daily receive cap (merchant volume guard), 0 = unlimited.
        uint256 cap = dailyCap[inv.merchant];
        if (cap > 0) {
            uint256 day = block.timestamp / 1 days;
            if (receivedPerDay[inv.merchant][day] + inv.amount > cap) revert DailyCapExceeded();
            receivedPerDay[inv.merchant][day] += inv.amount;
        }

        uint256 savingsShare = (inv.amount * savingsBps[inv.merchant]) / BPS_DENOMINATOR;
        uint256 merchantShare = inv.amount - savingsShare;

        // Effects before interactions.
        inv.paid = true;
        inv.payer = msg.sender;
        if (savingsShare > 0) savingsBalance[inv.merchant] += savingsShare;

        // Interactions: buyer -> merchant (direct), buyer -> contract (savings).
        if (merchantShare > 0) {
            if (!token.transferFrom(msg.sender, inv.merchant, merchantShare)) revert TransferFailed();
        }
        if (savingsShare > 0) {
            if (!token.transferFrom(msg.sender, address(this), savingsShare)) revert TransferFailed();
        }

        emit InvoicePaid(invoiceId, inv.merchant, msg.sender, inv.amount, merchantShare, savingsShare);
    }

    // ------------------------------------------------------------------------
    // Savings (pull-payment)
    // ------------------------------------------------------------------------

    /// @notice Merchant's savings pot balance.
    function savingsOf(address merchant) external view returns (uint256) {
        return savingsBalance[merchant];
    }

    /// @notice Merchant withdraws from their savings pot (pull-payment).
    function withdrawSavings(uint256 amount) external onlyMerchant nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > savingsBalance[msg.sender]) revert InsufficientSavings();
        savingsBalance[msg.sender] -= amount;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit SavingsWithdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    /// @notice Full invoice record (public mapping getter already exposes it,
    /// but this is friendlier for frontends).
    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        return invoices[invoiceId];
    }
}
