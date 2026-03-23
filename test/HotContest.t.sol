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

	function _setCaps(uint256 amount, uint16 pnlBps, uint16 drainBps, uint16 adminBps) internal {
		vm.startPrank(owner);
		contest.setMaxPnlAmount(amount);
		contest.updateBpsCaps(HotContest.BpsCaps(pnlBps, drainBps, adminBps));
		vm.stopPrank();
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

		usdc.mint(address(contest), 10_000_000e6);
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

	// ─── DepositFor ───

	function test_depositFor_coin() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);
		assertEq(usdc.balanceOf(address(contest)), 10_000_100e6);
	}

	function test_depositFor_credit() public {
		creditToken.mint(userA, 100e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		contest.depositFor(userA, address(creditToken), 100e18);

		assertEq(creditToken.balanceOf(address(contest)), 100e18);
		assertEq(contest.getUserPnl(userA), 0);
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
		contest.drain(userA, 100e6);
		assertEq(usdc.balanceOf(userA), 1_000_100e6);
	}

	function test_drain_revertsUnauthorized() public {
		vm.prank(stranger);
		vm.expectRevert(HotContest.Unauthorized.selector);
		contest.drain(userA, 100e6);
	}

	function test_drain_revertsZeroAmount() public {
		vm.prank(machine);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.drain(userA, 0);
	}

	// ─── PNL Amount Cap ───

	function test_drain_revertsPnlAmountExceeded() public {
		_setCaps(500e6, 0, 0, 0);

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);

		vm.prank(machine);
		contest.drain(userA, 600e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.PnlAmountExceeded.selector);
		contest.drain(userA, 1e6);
	}

	function test_drain_pnlResetsAfterWindow() public {
		_setCaps(500e6, 0, 0, 0);

		vm.prank(machine);
		contest.drain(userA, 500e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.PnlAmountExceeded.selector);
		contest.drain(userA, 1e6);

		vm.warp(block.timestamp + 14 days);

		vm.prank(machine);
		contest.drain(userA, 500e6);
	}

	function test_drain_depositsReducePnl() public {
		_setCaps(500e6, 0, 0, 0);

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 1000e6);

		vm.prank(machine);
		contest.drain(userA, 1500e6);

		assertEq(contest.getUserPnl(userA), 500e6);
	}

	function test_drain_creditDepositReducesPnl() public {
		_setCaps(500e6, 0, 0, 0);

		creditToken.mint(userA, 1000e18);
		vm.prank(userA);
		creditToken.approve(address(contest), type(uint256).max);

		vm.prank(machine);
		contest.depositFor(userA, address(creditToken), 1000e18);

		vm.prank(machine);
		contest.drain(userA, 1500e6);

		assertEq(contest.getUserPnl(userA), 500e6);
	}

	// ─── PNL BPS Cap ───

	function test_drain_revertsPnlBpsExceeded() public {
		_setCaps(0, 200, 0, 0); // 2%

		vm.prank(machine);
		contest.drain(userA, 200_000e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.PnlBpsExceeded.selector);
		contest.drain(userA, 1e6);
	}

	// ─── Global Daily Drain Cap ───

	function test_drain_revertsDailyDrainExceeded() public {
		_setCaps(0, 0, 1000, 0); // 10%

		vm.prank(machine);
		contest.drain(userA, 1_000_000e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.DailyDrainExceeded.selector);
		contest.drain(userB, 1e6);
	}

	function test_drain_dailyDrainResetsNextDay() public {
		_setCaps(0, 0, 1000, 0); // 10%

		vm.prank(machine);
		contest.drain(userA, 1_000_000e6);

		vm.warp(block.timestamp + 1 days);

		vm.prank(machine);
		contest.drain(userA, 900_000e6);
	}

	function test_drain_dailyDrainAcrossMultipleUsers() public {
		_setCaps(0, 0, 1000, 0); // 10%

		vm.prank(machine);
		contest.drain(userA, 500_000e6);

		vm.prank(machine);
		contest.drain(userB, 450_000e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.DailyDrainExceeded.selector);
		contest.drain(userB, 1e6);
	}

	// ─── Admin Withdrawal Limit ───

	function test_withdraw_success() public {
		_setCaps(0, 0, 0, 500); // 5%

		vm.prank(owner);
		contest.withdraw(owner, 500_000e6);

		assertEq(usdc.balanceOf(owner), 500_000e6);
	}

	function test_withdraw_revertsExceedsDailyCap() public {
		_setCaps(0, 0, 0, 500); // 5%

		vm.prank(owner);
		contest.withdraw(owner, 500_000e6);

		vm.prank(owner);
		vm.expectRevert(HotContest.AdminWithdrawExceeded.selector);
		contest.withdraw(owner, 1e6);
	}

	function test_withdraw_resetsNextDay() public {
		_setCaps(0, 0, 0, 500); // 5%

		vm.prank(owner);
		contest.withdraw(owner, 500_000e6);

		vm.warp(block.timestamp + 1 days);

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

	// ─── Admin Credit PNL ───

	function test_adminCreditPnl_unblocksDrain() public {
		_setCaps(500e6, 0, 0, 0);

		vm.prank(machine);
		contest.drain(userA, 500e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.PnlAmountExceeded.selector);
		contest.drain(userA, 100e6);

		vm.prank(owner);
		contest.adminCreditPnl(userA, 200e6);

		vm.prank(machine);
		contest.drain(userA, 200e6);

		assertEq(contest.getUserPnl(userA), 500e6);
	}

	function test_adminCreditPnl_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert();
		contest.adminCreditPnl(userA, 100e6);
	}

	function test_adminCreditPnl_revertsZeroAmount() public {
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidInput.selector);
		contest.adminCreditPnl(userA, 0);
	}

	function test_updateBpsCaps_revertsInvalidBps() public {
		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidBps.selector);
		contest.updateBpsCaps(HotContest.BpsCaps(10001, 0, 0));

		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidBps.selector);
		contest.updateBpsCaps(HotContest.BpsCaps(0, 10001, 0));

		vm.prank(owner);
		vm.expectRevert(HotContest.InvalidBps.selector);
		contest.updateBpsCaps(HotContest.BpsCaps(0, 0, 10001));
	}

	function test_updateBpsCaps_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert();
		contest.updateBpsCaps(HotContest.BpsCaps(100, 0, 0));
	}

	function test_setMaxPnlAmount_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert();
		contest.setMaxPnlAmount(100e6);
	}

	// ─── BurnCredit ───

	function test_burnCredit() public {
		creditToken.mint(address(contest), 100e18);

		vm.prank(machine);
		contest.burnCredit(100e18);

		assertEq(creditToken.balanceOf(address(contest)), 0);
	}

	// ─── View Functions ───

	function test_getUserPnl() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);

		vm.prank(machine);
		contest.drain(userA, 300e6);

		assertEq(contest.getUserPnl(userA), 200e6);
	}

	function test_getUserPnl_zeroWhenInflowsExceedOutflows() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 500e6);

		vm.prank(machine);
		contest.drain(userA, 100e6);

		assertEq(contest.getUserPnl(userA), 0);
	}

	function test_getGlobalDailyDrain() public {
		_setCaps(0, 0, 5000, 0);

		vm.prank(machine);
		contest.drain(userA, 100e6);

		assertEq(contest.getGlobalDailyDrain(), 100e6);
	}

	function test_getAdminWithdrawnToday() public {
		_setCaps(0, 0, 0, 5000);

		vm.prank(owner);
		contest.withdraw(owner, 100e6);

		assertEq(contest.getAdminWithdrawnToday(), 100e6);
	}

	function test_getBalance() public view {
		assertEq(contest.getBalance(), 10_000_000e6);
	}

	// ─── Caps Config ───

	function test_updateCaps() public {
		vm.prank(owner);
		contest.setMaxPnlAmount(1000e6);
		vm.prank(owner);
		contest.updateBpsCaps(HotContest.BpsCaps(200, 1000, 500));

		assertEq(contest.max_pnl_amount(), 1000e6);
		(uint16 b, uint16 c, uint16 d) = contest.bps_caps();
		assertEq(b, 200);
		assertEq(c, 1000);
		assertEq(d, 500);
	}

	// ─── Rolling Window ───

	function test_rollingWindow_bucketsRotateCorrectly() public {
		_setCaps(2000e6, 0, 0, 0);

		vm.prank(machine);
		contest.drain(userA, 200e6);
		assertEq(contest.getUserPnl(userA), 200e6);

		vm.warp(block.timestamp + 5 days);
		vm.prank(machine);
		contest.drain(userA, 300e6);
		assertEq(contest.getUserPnl(userA), 500e6);

		vm.warp(block.timestamp + 9 days);
		assertEq(contest.getUserPnl(userA), 300e6);

		vm.warp(block.timestamp + 5 days);
		assertEq(contest.getUserPnl(userA), 0);
	}

	function test_rollingWindow_delayedSettlementStillSeeDeposit() public {
		_setCaps(500e6, 0, 0, 0);

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 1000e6);

		vm.warp(block.timestamp + 8 days);
		vm.prank(machine);
		contest.drain(userA, 1000e6);

		assertEq(contest.getUserPnl(userA), 0);
	}

	function test_rollingWindow_settlementAtEdgeOfWindow() public {
		_setCaps(500e6, 0, 0, 0);

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 1000e6);

		vm.warp(block.timestamp + 13 days);
		vm.prank(machine);
		contest.drain(userA, 1500e6);

		assertEq(contest.getUserPnl(userA), 500e6);
	}

	function test_rollingWindow_depositFallsOutAfter14Days() public {
		_setCaps(2000e6, 0, 0, 0);

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 1000e6);

		vm.warp(block.timestamp + 14 days);
		vm.prank(machine);
		contest.drain(userA, 1000e6);

		assertEq(contest.getUserPnl(userA), 1000e6);
	}

	// ─── Both Caps Together ───

	function test_drain_bothCapsWhicheverHitsFirst() public {
		_setCaps(500e6, 100, 0, 0);

		vm.prank(machine);
		contest.drain(userA, 500e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.PnlAmountExceeded.selector);
		contest.drain(userA, 1e6);
	}

	function test_drain_bpsCapsHitsBeforeAmount() public {
		_setCaps(500_000e6, 1, 0, 0);

		vm.prank(machine);
		contest.drain(userA, 1000e6);

		vm.prank(machine);
		vm.expectRevert(HotContest.PnlBpsExceeded.selector);
		contest.drain(userA, 1e6);
	}

	// ─── No Caps = Unlimited ───

	function test_drain_noCapsAllowsUnlimited() public {
		vm.prank(machine);
		contest.drain(userA, 5_000_000e6);
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
		usdc.mint(address(contest), 10_000_000e6);
	}

	function test_gas_depositFor_noCaps() public {
		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);
	}

	function test_gas_drain_noCaps() public {
		vm.prank(machine);
		contest.drain(userA, 100e6);
	}

	function test_gas_drain_allCaps() public {
		vm.prank(owner);
		contest.setMaxPnlAmount(500_000e6);
		vm.prank(owner);
		contest.updateBpsCaps(HotContest.BpsCaps(200, 1000, 500));

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);

		vm.prank(machine);
		contest.drain(userA, 200e6);
	}

	function test_gas_drain_allCaps_warm() public {
		vm.prank(owner);
		contest.setMaxPnlAmount(500_000e6);
		vm.prank(owner);
		contest.updateBpsCaps(HotContest.BpsCaps(200, 1000, 500));

		vm.prank(machine);
		contest.depositFor(userA, address(usdc), 100e6);

		vm.startPrank(machine);
		contest.drain(userA, 50e6);
		contest.drain(userA, 50e6);
		vm.stopPrank();
	}
}
