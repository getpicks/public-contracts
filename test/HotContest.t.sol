// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HotContest} from "../src/HotContest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
	uint8 private _decimals;

	constructor(string memory name, uint8 dec) ERC20(name, name) {
		_decimals = dec;
	}

	function decimals() public view override returns (uint8) {
		return _decimals;
	}

	function mint(address to, uint256 amount) external {
		_mint(to, amount);
	}
}

contract MockCreditToken is ERC20 {
	constructor() ERC20("Credit", "CRED") {}

	function decimals() public pure override returns (uint8) {
		return 18;
	}

	function mint(address to, uint256 amount) external {
		_mint(to, amount);
	}

	function burn(uint256 amount) external {
		_burn(msg.sender, amount);
	}
}

contract HotContestTest is Test {
	HotContest public contest;
	MockToken public usdc;
	MockCreditToken public creditToken;

	address public owner = makeAddr("owner");
	address public machine = makeAddr("machine");
	address public userA = makeAddr("userA");
	address public userB = makeAddr("userB");
	address public stranger = makeAddr("stranger");

	function _setCaps(uint16 globalPnlBps, uint16 adminBps) internal {
		vm.prank(owner);
		contest.updateBpsCaps(HotContest.BpsCaps(globalPnlBps, adminBps));
	}

	function setUp() public {
		usdc = new MockToken("USDC", 6);
		creditToken = new MockCreditToken();

		contest = new HotContest(address(usdc), address(creditToken), owner);

		vm.prank(owner);
		contest.addToWhitelist(machine);

		usdc.mint(userA, 1_000_000e6);
		vm.prank(userA);
		usdc.approve(address(contest), type(uint256).max);

		usdc.mint(userB, 1_000_000e6);
		vm.prank(userB);
		usdc.approve(address(contest), type(uint256).max);

		// Fund treasury via deposit() so coin_balance is tracked
		usdc.mint(owner, 10_000_000e6);
		vm.startPrank(owner);
		usdc.approve(address(contest), type(uint256).max);
		contest.deposit(10_000_000e6);
		vm.stopPrank();
	}

	// ─── Constructor ───

	function test_constructor() public view {
		assertEq(contest.COIN_ADDRESS(), address(usdc));
		assertEq(contest.CREDIT_TOKEN_ADDRESS(), address(creditToken));
		assertEq(contest.COIN_DECIMALS(), 6);
		assertEq(contest.owner(), owner);
	}

	function test_constructor_revertsZeroOwner() public {
		vm.expectRevert();
		new HotContest(address(usdc), address(creditToken), address(0));
	}

	function test_constructor_revertsZeroCoinAddress() public {
		vm.expectRevert(HotContest.InvalidInput.selector);
		new HotContest(address(0), address(creditToken), owner);
	}

	function test_constructor_revertsZeroCreditToken() public {
		vm.expectRevert(HotContest.InvalidInput.selector);
		new HotContest(address(usdc), address(0), owner);
	}

	// ─── Whitelist ───

	function test_addToWhitelist() public {
		address newContract = makeAddr("newContract");
		vm.prank(owner);
		contest.addToWhitelist(newContract);
		assertTrue(contest.whitelisted_contracts(newContract));
	}

	function test_removeFromWhitelist() public {
		vm.prank(owner);
		contest.removeFromWhitelist(machine);
		assertFalse(contest.whitelisted_contracts(machine));
	}

	// ─── Deposit (owner) ───

	function test_deposit_tracksBalance() public {
		usdc.mint(owner, 1_000_000e6);
		vm.startPrank(owner);
		usdc.approve(address(contest), type(uint256).max);
		contest.deposit(1_000_000e6);
		vm.stopPrank();
		assertEq(contest.getBalance(), 11_000_000e6);
	}

	function test_deposit_revertsZeroAmount() public {
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.deposit(0);
	}

	function test_deposit_revertsNonOwner() public {
		usdc.mint(stranger, 1e6);
		vm.prank(stranger);
		usdc.approve(address(contest), 1e6);
		vm.prank(stranger);
		vm.expectRevert();
		contest.deposit(1e6);
	}

	// ─── DepositFor ───

	function test_depositFor_coin() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);
		assertEq(usdc.balanceOf(address(contest)), 10_000_100e6);
		assertEq(contest.getBalance(), 10_000_100e6);
	}

	function test_depositFor_credit() public {
		creditToken.mint(userA, 100e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		contest.depositFor(userA, address(creditToken), 100e18);

		assertEq(creditToken.balanceOf(address(contest)), 100e18);
		// Credit inflow is 100e6 coin-equivalent; no outflows → global PNL = 0
		assertEq(contest.getGlobalPnl(), 0);
	}

	function test_depositFor_revertsUnauthorized() public {
		vm.prank(stranger);
		vm.expectRevert(HotContest.Unauthorized.selector);
		contest.depositFor(userA, address(usdc), 100e6);
	}

	function test_depositFor_revertsInvalidToken() public {
		address fakeToken = makeAddr("fake");
		vm.prank(machine);
		vm.expectRevert(HotContest.InvalidToken.selector);
		contest.depositFor(userA, fakeToken, 100e6);
	}

	function test_depositFor_revertsZeroAmount() public {
		vm.prank(machine);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.depositFor(userA, address(usdc), 0);
	}

	// ─── Drain ───

	function test_drain() public {
		vm.prank(machine);
		contest.drain(userA, address(usdc), 100e6);
		assertEq(usdc.balanceOf(userA), 1_000_100e6);
		assertEq(contest.getBalance(), 9_999_900e6);
	}

	function test_drain_revertsUnauthorized() public {
		vm.prank(stranger);
		vm.expectRevert(HotContest.Unauthorized.selector);
		contest.drain(userA, address(usdc), 100e6);
	}

	function test_drain_revertsZeroAmount() public {
		vm.prank(machine);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.drain(userA, address(usdc), 0);
	}

	// ─── Global PNL BPS Cap ───

	function test_drain_revertsGlobalPnlBpsExceeded() public {
		_setCaps(200, 0); // 2% of 10M = 200k limit

		vm.prank(machine);
		contest.drain(userA, address(usdc), 200_000e6); // exactly at the limit

		vm.prank(machine);
		vm.expectRevert(HotContest.GlobalPnlExceeded.selector);
		contest.drain(userA, address(usdc), 1e6);
	}

	function test_drain_globalPnlResetsAfterWindow() public {
		_setCaps(200, 0); // 2% of 10M = 200k limit

		vm.prank(machine);
		contest.drain(userA, address(usdc), 200_000e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.GlobalPnlExceeded.selector);
		contest.drain(userA, address(usdc), 1e6);

		vm.warp(block.timestamp + 14 days);

		// After window expires, balance is 9.8M → 2% = 196k
		vm.prank(machine);
		contest.drain(userA, address(usdc), 190_000e6);
	}

	function test_drain_globalPnlReducedByDeposits() public {
		_setCaps(5000, 0); // 50% cap — high enough not to block

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 1_000_000e6);

		vm.prank(machine);
		contest.drain(userA, address(usdc), 1_500_000e6);

		assertEq(contest.getGlobalPnl(), 500_000e6);
	}

	function test_drain_creditDepositReducesGlobalPnl() public {
		_setCaps(5000, 0); // 50% cap

		creditToken.mint(userA, 1000e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		contest.depositFor(userA, address(creditToken), 1000e18); // 1000 USDC-equivalent inflow

		vm.prank(machine);
		contest.drain(userA, address(usdc), 1500e6);

		assertEq(contest.getGlobalPnl(), 500e6);
	}

	// ─── Admin Withdrawal Limit ───

	function test_withdraw_success() public {
		_setCaps(0, 500); // 5%

		vm.prank(owner);
		contest.withdraw(owner, 500_000e6);

		assertEq(usdc.balanceOf(owner), 500_000e6);
		assertEq(contest.getBalance(), 9_500_000e6);
	}

	function test_withdraw_revertsExceedsDailyCap() public {
		_setCaps(0, 500); // 5%

		vm.prank(owner);
		contest.withdraw(owner, 500_000e6);

		vm.prank(owner);
		vm.expectRevert(HotContest.AdminWithdrawExceeded.selector);
		contest.withdraw(owner, 1e6);
	}

	function test_withdraw_resetsNextDay() public {
		_setCaps(0, 500); // 5%

		vm.prank(owner);
		contest.withdraw(owner, 500_000e6);

		vm.warp(block.timestamp + 1 days);

		// coin_balance is now 9.5M → 5% = 475k
		vm.prank(owner);
		contest.withdraw(owner, 475_000e6);
	}

	function test_withdraw_unlimitedWhenBpsZero() public {
		vm.prank(owner);
		contest.withdraw(owner, 5_000_000e6);
		assertEq(usdc.balanceOf(owner), 5_000_000e6);
	}

	function test_withdraw_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert();
		contest.withdraw(stranger, 100e6);
	}

	// ─── Credit Caps ───

	function test_depositFor_credit_revertsAbsoluteCap() public {
		vm.prank(owner);
		contest.setMaxCreditBalance(100e18); // max 100 credits

		creditToken.mint(userA, 101e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		vm.expectRevert(HotContest.CreditCapExceeded.selector);
		contest.depositFor(userA, address(creditToken), 101e18);
	}

	function test_depositFor_credit_absoluteCapAccumulatesAcrossDeposits() public {
		vm.prank(owner);
		contest.setMaxCreditBalance(100e18);

		creditToken.mint(userA, 200e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		contest.depositFor(userA, address(creditToken), 60e18); // ok: 60 <= 100

		vm.prank(machine);
		vm.expectRevert(HotContest.CreditCapExceeded.selector);
		contest.depositFor(userA, address(creditToken), 41e18); // 60+41=101 > 100
	}

	function test_depositFor_credit_revertsRatioCap() public {
		// coin_balance = 10M USDC, ratio cap 1% = 100k USDC-equivalent credits max
		vm.prank(owner);
		contest.setMaxCreditCoinRatioBps(100); // 1%

		creditToken.mint(userA, 100_001e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		vm.expectRevert(HotContest.CreditRatioExceeded.selector);
		contest.depositFor(userA, address(creditToken), 100_001e18); // > 1% of 10M
	}

	function test_depositFor_credit_ratioCapPassesAtLimit() public {
		vm.prank(owner);
		contest.setMaxCreditCoinRatioBps(100); // 1% of 10M = 100k USDC-eq

		creditToken.mint(userA, 100_000e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		contest.depositFor(userA, address(creditToken), 100_000e18); // exactly at limit
	}

	function test_depositFor_credit_zeroCapsAreUnlimited() public {
		// Both caps default to 0 = unlimited
		creditToken.mint(userA, 1_000_000e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		contest.depositFor(userA, address(creditToken), 1_000_000e18);
	}

	function test_setMaxCreditCoinRatioBps_revertsInvalidBps() public {
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidBps.selector);
		contest.setMaxCreditCoinRatioBps(10001);
	}

	// ─── Snapshot Encoding (zero-balance edge case) ───

	function test_snapshot_zeroBalanceIsCorrectlyEncoded() public {
		// Fresh contest: coin_balance == 0, admin withdraw cap = 10%.
		// We set the snapshot by draining a credit token — this succeeds even with
		// zero coin_balance because coin_balance is not decremented for credit drains.
		// The snapshot is written as coin_balance + 1 = 1 (encodes balance = 0).
		// A subsequent USDC deposit must not overwrite that snapshot, so a same-day
		// admin withdraw must still see a 10%-of-0 = 0 limit and revert.
		HotContest empty = new HotContest(address(usdc), address(creditToken), owner);
		vm.startPrank(owner);
		empty.addToWhitelist(machine);
		empty.updateBpsCaps(HotContest.BpsCaps(0, 1000)); // 10% admin cap
		vm.stopPrank();

		// Give the contract some credit to drain (so safeTransfer doesn't fail)
		creditToken.mint(address(empty), 1e18);

		// Drain credit: sets daily_balance_snapshot to coin_balance=0 (stored as 0+1=1).
		// Credit drains do not decrement coin_balance, so this succeeds with an empty treasury.
		vm.prank(machine);
		empty.drain(userA, address(creditToken), 1e18);

		// Owner deposits USDC same day — coin_balance becomes 1000e6
		usdc.mint(owner, 1000e6);
		vm.startPrank(owner);
		usdc.approve(address(empty), type(uint256).max);
		empty.deposit(1000e6);

		// Snapshot is locked at 0 for the day: 10% of 0 = 0 limit → any withdraw reverts
		vm.expectRevert(HotContest.AdminWithdrawExceeded.selector);
		empty.withdraw(owner, 1e6);
		vm.stopPrank();
	}

	function test_snapshot_notOverwrittenBySameDayDeposit() public {
		// Normal contest with 10M. Admin cap = 10% → limit = 1M for today.
		// After setting the snapshot via a withdraw, a large same-day deposit must
		// not raise the limit — the snapshot is locked for the rest of the day.
		_setCaps(0, 1000); // 10% admin cap

		// First withdraw: sets snapshot at 10M, limit = 1M
		vm.prank(owner);
		contest.withdraw(owner, 1e6); // uses 1e6 of the 1M daily limit

		// Large same-day deposit — coin_balance rises to ~14.999M
		usdc.mint(owner, 5_000_000e6);
		vm.startPrank(owner);
		usdc.approve(address(contest), type(uint256).max);
		contest.deposit(5_000_000e6);

		// Remaining capacity is still based on opening snapshot (10M → 1M limit):
		// 1M - 1e6 already used = 999_999e6 remaining
		contest.withdraw(owner, 999_999e6); // exactly fills remaining capacity

		vm.expectRevert(HotContest.AdminWithdrawExceeded.selector);
		contest.withdraw(owner, 1e6); // over the original 1M limit
		vm.stopPrank();
	}

	// ─── Withdraw Excess Coin ───

	function test_withdrawExcessCoin_sweepsDirectTransfer() public {
		// Simulate accidental direct transfer (bypasses deposit())
		usdc.mint(address(contest), 500e6);

		uint256 before = usdc.balanceOf(owner);
		vm.prank(owner);
		contest.withdrawExcessCoin(owner);

		assertEq(usdc.balanceOf(owner), before + 500e6);
		assertEq(contest.getBalance(), 10_000_000e6); // coin_balance unchanged
	}

	function test_withdrawExcessCoin_doesNotTouchCoinBalance() public {
		usdc.mint(address(contest), 1_000e6);

		vm.prank(owner);
		contest.withdrawExcessCoin(owner);

		// coin_balance still reflects only properly deposited funds
		assertEq(contest.getBalance(), 10_000_000e6);
	}

	function test_withdrawExcessCoin_revertsWhenNoExcess() public {
		// No direct transfers — actual balance equals coin_balance
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.withdrawExcessCoin(owner);
	}

	function test_withdrawExcessCoin_revertsNonOwner() public {
		usdc.mint(address(contest), 1e6);
		vm.prank(stranger);
		vm.expectRevert();
		contest.withdrawExcessCoin(stranger);
	}

	function test_withdrawExcessCoin_revertsZeroAddress() public {
		usdc.mint(address(contest), 1e6);
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.withdrawExcessCoin(address(0));
	}

	function test_withdrawExcessCoin_bypassesDailyCap() public {
		_setCaps(0, 1); // 0.01% admin cap — would normally block any meaningful withdrawal

		usdc.mint(address(contest), 5_000_000e6); // large direct transfer

		vm.prank(owner);
		contest.withdrawExcessCoin(owner); // should not revert despite tiny cap
		assertEq(usdc.balanceOf(owner), 5_000_000e6);
	}

	// ─── Recover Token ───

	function test_recoverToken_sweepsStrandedErc20() public {
		MockToken rando = new MockToken("RANDO", 18);
		rando.mint(address(contest), 999e18);

		vm.prank(owner);
		contest.recoverToken(address(rando), owner);

		assertEq(rando.balanceOf(owner), 999e18);
		assertEq(rando.balanceOf(address(contest)), 0);
	}

	function test_recoverToken_revertsCoinAddress() public {
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidToken.selector);
		contest.recoverToken(address(usdc), owner);
	}

	function test_recoverToken_revertsCreditToken() public {
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidToken.selector);
		contest.recoverToken(address(creditToken), owner);
	}

	function test_recoverToken_revertsZeroBalance() public {
		MockToken rando = new MockToken("RANDO", 18);
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.recoverToken(address(rando), owner);
	}

	function test_recoverToken_revertsNonOwner() public {
		MockToken rando = new MockToken("RANDO", 18);
		rando.mint(address(contest), 1e18);
		vm.prank(stranger);
		vm.expectRevert();
		contest.recoverToken(address(rando), stranger);
	}

	function test_recoverToken_revertsZeroAddress() public {
		MockToken rando = new MockToken("RANDO", 18);
		rando.mint(address(contest), 1e18);
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.recoverToken(address(rando), address(0));
	}

	function test_recoverToken_emitsTokenRecovered() public {
		MockToken rando = new MockToken("RANDO", 18);
		rando.mint(address(contest), 999e18);

		vm.prank(owner);
		vm.expectEmit(true, true, false, true);
		emit HotContest.TokenRecovered(address(rando), owner, 999e18);
		contest.recoverToken(address(rando), owner);
	}

	function test_withdrawExcessCoin_emitsExcessCoinWithdrawn() public {
		usdc.mint(address(contest), 500e6);

		vm.prank(owner);
		vm.expectEmit(true, false, false, true);
		emit HotContest.ExcessCoinWithdrawn(owner, 500e6);
		contest.withdrawExcessCoin(owner);
	}

	// ─── BurnCredit ───

	function test_burnCredit() public {
		creditToken.mint(address(contest), 100e18);

		vm.prank(machine);
		contest.burnCredit(100e18);

		assertEq(creditToken.balanceOf(address(contest)), 0);
	}

	// ─── BPS Caps Config ───

	function test_updateBpsCaps_revertsInvalidBps() public {
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidBps.selector);
		contest.updateBpsCaps(HotContest.BpsCaps(10001, 0));

		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidBps.selector);
		contest.updateBpsCaps(HotContest.BpsCaps(0, 10001));
	}

	function test_updateBpsCaps_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert();
		contest.updateBpsCaps(HotContest.BpsCaps(100, 0));
	}

	function test_updateCaps() public {
		vm.prank(owner);
		contest.updateBpsCaps(HotContest.BpsCaps(200, 500));

		(uint16 a, uint16 b) = contest.bps_caps();
		assertEq(a, 200); // max_global_pnl_bps
		assertEq(b, 500); // admin_daily_withdraw_bps
	}

	// ─── View Functions ───

	function test_getGlobalPnl() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);

		vm.prank(machine);
		contest.drain(userA, address(usdc), 300e6);

		assertEq(contest.getGlobalPnl(), 200e6);
	}

	function test_getGlobalPnl_zeroWhenInflowsExceedOutflows() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 500e6);

		vm.prank(machine);
		contest.drain(userA, address(usdc), 100e6);

		assertEq(contest.getGlobalPnl(), 0);
	}

	function test_getAdminWithdrawnToday() public {
		_setCaps(0, 5000);

		vm.prank(owner);
		contest.withdraw(owner, 100e6);

		assertEq(contest.getAdminWithdrawnToday(), 100e6);
	}

	function test_getBalance() public view {
		assertEq(contest.getBalance(), 10_000_000e6);
	}

	// ─── Rolling Window ───

	function test_globalPnl_bucketsRotateCorrectly() public {
		_setCaps(5000, 0); // 50% — high enough not to block

		vm.prank(machine);
		contest.drain(userA, address(usdc), 200_000e6); // day 0
		assertEq(contest.getGlobalPnl(), 200_000e6);

		vm.warp(block.timestamp + 5 days);
		vm.prank(machine);
		contest.drain(userA, address(usdc), 300_000e6); // day 5
		assertEq(contest.getGlobalPnl(), 500_000e6);

		vm.warp(block.timestamp + 9 days); // day 14 — day 0 bucket expired
		assertEq(contest.getGlobalPnl(), 300_000e6);

		vm.warp(block.timestamp + 5 days); // day 19 — day 5 bucket expired
		assertEq(contest.getGlobalPnl(), 0);
	}

	function test_globalPnl_depositFallsOutAfter14Days() public {
		_setCaps(5000, 0); // 50%

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 1_000_000e6);

		vm.warp(block.timestamp + 14 days);

		// Deposit inflow expired — drain now counts as full PNL
		vm.prank(machine);
		contest.drain(userA, address(usdc), 1_000_000e6);

		assertEq(contest.getGlobalPnl(), 1_000_000e6);
	}

	// ─── No Caps = Unlimited ───

	function test_drain_noCapsAllowsUnlimited() public {
		vm.prank(machine);
		contest.drain(userA, address(usdc), 5_000_000e6);
		assertEq(usdc.balanceOf(userA), 6_000_000e6);
	}

	// ─── ETH ───

	function test_withdrawEth() public {
		vm.deal(address(contest), 1 ether);
		uint256 balBefore = owner.balance;
		vm.prank(owner);
		contest.withdrawEth();
		assertEq(owner.balance, balBefore + 1 ether);
	}

	function test_receiveEth() public {
		vm.deal(address(this), 1 ether);
		(bool success, ) = address(contest).call{value: 1 ether}("");
		assertTrue(success);
	}
}

// ─── Gas Benchmark ───

contract GasBenchmark is Test {
	HotContest public contest;
	MockToken public usdc;
	MockCreditToken public creditToken;

	address public owner = makeAddr("owner");
	address public machine = makeAddr("machine");
	address public userA = makeAddr("userA");

	function setUp() public {
		usdc = new MockToken("USDC", 6);
		creditToken = new MockCreditToken();
		contest = new HotContest(address(usdc), address(creditToken), owner);

		vm.prank(owner);
		contest.addToWhitelist(machine);

		usdc.mint(userA, 1_000_000e6);
		vm.prank(userA);
		usdc.approve(address(contest), type(uint256).max);

		usdc.mint(owner, 10_000_000e6);
		vm.startPrank(owner);
		usdc.approve(address(contest), type(uint256).max);
		contest.deposit(10_000_000e6);
		vm.stopPrank();
	}

	function test_gas_depositFor_noCaps() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);
	}

	function test_gas_drain_noCaps() public {
		vm.prank(machine);
		contest.drain(userA, address(usdc), 100e6);
	}

	function test_gas_drain_allCaps() public {
		vm.prank(owner);
		contest.updateBpsCaps(HotContest.BpsCaps(200, 500));

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);

		vm.prank(machine);
		contest.drain(userA, address(usdc), 200e6);
	}

	function test_gas_drain_allCaps_warm() public {
		vm.prank(owner);
		contest.updateBpsCaps(HotContest.BpsCaps(200, 500));

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);

		vm.startPrank(machine);
		contest.drain(userA, address(usdc), 50e6);
		contest.drain(userA, address(usdc), 50e6);
		vm.stopPrank();
	}
}
