// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WarungPay} from "../src/WarungPay.sol";

/// @notice Minimal ERC20 mock (6 decimals, like tUSD8) for local tests.
contract MockUSD8 {
    string public name = "Test USD8";
    string public symbol = "tUSD8";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract WarungPayTest is Test {
    WarungPay public wp;
    MockUSD8 public token;

    address merchant = makeAddr("merchant");
    address cashier = makeAddr("cashier");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    uint256 constant ONE_TUSD8 = 1_000_000; // 1.00 tUSD8 (6 decimals)

    function setUp() public {
        token = new MockUSD8();
        wp = new WarungPay(address(token));
        vm.prank(merchant);
        wp.registerMerchant();
        // Buyer starts with 1,000 tUSD8 and approves WarungPay.
        token.mint(buyer, 1_000 * ONE_TUSD8);
        vm.prank(buyer);
        token.approve(address(wp), type(uint256).max);
    }

    // ------------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------------

    function testRegisterMerchant() public view {
        (address owner, bool active) = wp.merchants(merchant);
        assertEq(owner, merchant);
        assertTrue(active);
        assertEq(wp.savingsBps(merchant), 1_000); // default 10%
    }

    function testRegisterMerchantTwiceReverts() public {
        vm.prank(merchant);
        vm.expectRevert(WarungPay.AlreadyMerchant.selector);
        wp.registerMerchant();
    }

    function testNonMerchantCannotCreateInvoice() public {
        vm.prank(stranger);
        vm.expectRevert(WarungPay.NotMerchant.selector);
        wp.createInvoice(ONE_TUSD8, "nasi goreng", block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------------
    // Invoice lifecycle + split math
    // ------------------------------------------------------------------------

    function testInvoiceLifecycleAndSplit90_10() public {
        vm.prank(merchant);
        uint256 id = wp.createInvoice(ONE_TUSD8, "kopi + indomie", block.timestamp + 1 days);

        uint256 merchantBefore = token.balanceOf(merchant);
        vm.prank(buyer);
        wp.payInvoice(id);

        // 90% -> merchant, 10% -> savings pot.
        assertEq(token.balanceOf(merchant) - merchantBefore, 900_000);
        assertEq(wp.savingsOf(merchant), 100_000);
        assertEq(token.balanceOf(address(wp)), 100_000);

        WarungPay.Invoice memory inv = wp.getInvoice(id);
        assertTrue(inv.paid);
        assertEq(inv.payer, buyer);
        assertEq(inv.amount, ONE_TUSD8);
    }

    function testSplitMathRoundsDownOnOddAmount() public {
        // 1_000_001 * 10% = 100_000.1 -> savings 100_000, merchant 900_001.
        vm.prank(merchant);
        uint256 id = wp.createInvoice(1_000_001, "odd amount", block.timestamp + 1 days);
        uint256 merchantBefore = token.balanceOf(merchant);
        vm.prank(buyer);
        wp.payInvoice(id);
        assertEq(token.balanceOf(merchant) - merchantBefore, 900_001);
        assertEq(wp.savingsOf(merchant), 100_000);
    }

    function testSetSplitChangesSplit() public {
        vm.prank(merchant);
        wp.setSplit(2_000); // 20% savings
        vm.prank(merchant);
        uint256 id = wp.createInvoice(ONE_TUSD8, "split 20%", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id);
        assertEq(wp.savingsOf(merchant), 200_000);
        assertEq(token.balanceOf(merchant), 800_000);
    }

    function testSetSplitZeroMeansNoSavings() public {
        vm.prank(merchant);
        wp.setSplit(0);
        vm.prank(merchant);
        uint256 id = wp.createInvoice(ONE_TUSD8, "no savings", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id);
        assertEq(wp.savingsOf(merchant), 0);
        assertEq(token.balanceOf(merchant), ONE_TUSD8);
    }

    function testSetSplitAbove50Reverts() public {
        vm.prank(merchant);
        vm.expectRevert(WarungPay.SavingsBpsTooHigh.selector);
        wp.setSplit(5_001);
    }

    function testSetSplitExactly50Ok() public {
        vm.prank(merchant);
        wp.setSplit(5_000);
        assertEq(wp.savingsBps(merchant), 5_000);
    }

    function testPayAlreadyPaidReverts() public {
        vm.prank(merchant);
        uint256 id = wp.createInvoice(ONE_TUSD8, "double pay", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id);
        vm.prank(buyer);
        vm.expectRevert(WarungPay.InvoiceAlreadyPaid.selector);
        wp.payInvoice(id);
    }

    function testPayExpiredInvoiceReverts() public {
        vm.prank(merchant);
        uint256 id = wp.createInvoice(ONE_TUSD8, "expired", block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(buyer);
        vm.expectRevert(WarungPay.InvoiceExpired.selector);
        wp.payInvoice(id);
    }

    function testCreateInvoiceWithPastExpiryReverts() public {
        vm.prank(merchant);
        vm.expectRevert(WarungPay.InvalidExpiry.selector);
        wp.createInvoice(ONE_TUSD8, "past", block.timestamp - 1);
    }

    function testCreateInvoiceZeroAmountReverts() public {
        vm.prank(merchant);
        vm.expectRevert(WarungPay.InvalidAmount.selector);
        wp.createInvoice(0, "zero", block.timestamp + 1 days);
    }

    function testPayNonexistentInvoiceReverts() public {
        vm.prank(buyer);
        vm.expectRevert(WarungPay.InvoiceNotFound.selector);
        wp.payInvoice(999);
    }

    // ------------------------------------------------------------------------
    // Cashier session keys
    // ------------------------------------------------------------------------

    function testCashierCreateInvoiceWithinCap() public {
        vm.prank(merchant);
        wp.grantCashier(cashier, 500_000, block.timestamp + 1 days);
        assertTrue(wp.isCashier(merchant, cashier));

        vm.prank(cashier);
        uint256 id = wp.createInvoiceFor(merchant, 400_000, "via kasir", block.timestamp + 1 hours);
        WarungPay.Invoice memory inv = wp.getInvoice(id);
        assertEq(inv.merchant, merchant);
        assertEq(inv.amount, 400_000);
    }

    function testCashierOverCapReverts() public {
        vm.prank(merchant);
        wp.grantCashier(cashier, 500_000, block.timestamp + 1 days);
        vm.prank(cashier);
        vm.expectRevert(WarungPay.CashierCapExceeded.selector);
        wp.createInvoiceFor(merchant, 500_001, "over cap", block.timestamp + 1 hours);
    }

    function testCashierRevokedReverts() public {
        vm.prank(merchant);
        wp.grantCashier(cashier, 500_000, block.timestamp + 1 days);
        vm.prank(merchant);
        wp.revokeCashier(cashier);
        assertFalse(wp.isCashier(merchant, cashier));
        vm.prank(cashier);
        vm.expectRevert(WarungPay.CashierKeyRevoked.selector);
        wp.createInvoiceFor(merchant, 100_000, "revoked", block.timestamp + 1 hours);
    }

    function testCashierExpiredReverts() public {
        vm.prank(merchant);
        wp.grantCashier(cashier, 500_000, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours + 1);
        assertFalse(wp.isCashier(merchant, cashier));
        vm.prank(cashier);
        vm.expectRevert(WarungPay.CashierKeyExpired.selector);
        wp.createInvoiceFor(merchant, 100_000, "expired key", block.timestamp + 1 days);
    }

    function testUnauthorizedCashierReverts() public {
        vm.prank(stranger);
        vm.expectRevert(WarungPay.CashierNotAuthorized.selector);
        wp.createInvoiceFor(merchant, 100_000, "no key", block.timestamp + 1 hours);
    }

    function testGrantCashierZeroCapReverts() public {
        vm.prank(merchant);
        vm.expectRevert(WarungPay.InvalidAmount.selector);
        wp.grantCashier(cashier, 0, block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------------
    // Savings withdrawal (pull-payment)
    // ------------------------------------------------------------------------

    function testWithdrawSavings() public {
        vm.prank(merchant);
        uint256 id = wp.createInvoice(10 * ONE_TUSD8, "big order", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id);
        assertEq(wp.savingsOf(merchant), ONE_TUSD8); // 10% of 10

        vm.prank(merchant);
        wp.withdrawSavings(600_000);
        assertEq(wp.savingsOf(merchant), 400_000);
        assertEq(token.balanceOf(merchant), 9 * ONE_TUSD8 + 600_000);
    }

    function testWithdrawMoreThanBalanceReverts() public {
        vm.prank(merchant);
        uint256 id = wp.createInvoice(ONE_TUSD8, "small", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id);
        vm.prank(merchant);
        vm.expectRevert(WarungPay.InsufficientSavings.selector);
        wp.withdrawSavings(100_001);
    }

    function testWithdrawZeroReverts() public {
        vm.prank(merchant);
        vm.expectRevert(WarungPay.InvalidAmount.selector);
        wp.withdrawSavings(0);
    }

    // ------------------------------------------------------------------------
    // Daily cap
    // ------------------------------------------------------------------------

    function testDailyCapBlocksSecondPaymentSameDay() public {
        vm.prank(merchant);
        wp.setDailyCap(1_500_000); // 1.5 tUSD8 / day

        vm.prank(merchant);
        uint256 id1 = wp.createInvoice(ONE_TUSD8, "first", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id1);

        vm.prank(merchant);
        uint256 id2 = wp.createInvoice(ONE_TUSD8, "second", block.timestamp + 1 days);
        vm.prank(buyer);
        vm.expectRevert(WarungPay.DailyCapExceeded.selector);
        wp.payInvoice(id2);
    }

    function testDailyCapResetsNextDay() public {
        vm.prank(merchant);
        wp.setDailyCap(1_500_000);

        vm.prank(merchant);
        uint256 id1 = wp.createInvoice(ONE_TUSD8, "day 1", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id1);

        vm.warp(block.timestamp + 1 days);

        vm.prank(merchant);
        uint256 id2 = wp.createInvoice(ONE_TUSD8, "day 2", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id2); // must not revert
        assertTrue(wp.getInvoice(id2).paid);
    }

    function testNoDailyCapByDefault() public {
        // No cap set: merchant can receive far more than any cap in one day.
        vm.prank(merchant);
        uint256 id = wp.createInvoice(500 * ONE_TUSD8, "huge", block.timestamp + 1 days);
        vm.prank(buyer);
        wp.payInvoice(id);
        assertTrue(wp.getInvoice(id).paid);
    }

    // ------------------------------------------------------------------------
    // Pay without approval reverts
    // ------------------------------------------------------------------------

    function testPayWithoutApprovalReverts() public {
        address poorBuyer = makeAddr("poorBuyer");
        token.mint(poorBuyer, ONE_TUSD8); // has balance, no approval
        vm.prank(merchant);
        uint256 id = wp.createInvoice(ONE_TUSD8, "no approval", block.timestamp + 1 days);
        vm.prank(poorBuyer);
        vm.expectRevert("insufficient allowance");
        wp.payInvoice(id);
    }
}
