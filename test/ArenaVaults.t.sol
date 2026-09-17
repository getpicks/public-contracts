// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EntryVault} from "../src/EntryVault.sol";
import {PrizeTreasury} from "../src/PrizeTreasury.sol";
import {BaseVault} from "../src/BaseVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockCoin is ERC20 {
	constructor() ERC20("USDC", "USDC") {}

	function decimals() public pure override returns (uint8) {
		return 6;
	}

	function mint(address to, uint256 amount) external {
		_mint(to, amount);
	}
}

contract MockCredit is ERC20 {
	constructor() ERC20("Credit", "CRED") {}

	function mint(address to, uint256 amount) external {
		_mint(to, amount);
	}
}

contract ArenaVaultsTest is Test {
	EntryVault internal entry;
	PrizeTreasury internal prize;
	MockCoin internal coin;
	MockCredit internal credit;

	address internal owner = makeAddr("owner");
	address internal machine = makeAddr("machine"); // whitelisted operator
	address internal user = makeAddr("user");
	address internal creditVault = makeAddr("creditVault");
	address internal stranger = makeAddr("stranger");

	function setUp() public {
		coin = new MockCoin();
		credit = new MockCredit();

		vm.startPrank(owner);
		entry = new EntryVault(owner);
		prize = new PrizeTreasury(owner);

		// token-agnostic: enable the tokens each vault holds, with per-token limits (0 = disabled)
		entry.setTokenPolicy(address(coin), true, 0, 0);
		entry.setTokenPolicy(address(credit), true, 0, 0);
		prize.setTokenPolicy(address(coin), true, 0, 0);

		entry.addToWhitelist(machine);
		prize.addToWhitelist(machine);
		vm.stopPrank();

		coin.mint(address(prize), 1_000e6);
		coin.mint(address(entry), 1_000e6);
		credit.mint(address(entry), 1_000e18);
		coin.mint(user, 1_000e6);
		credit.mint(user, 1_000e18);
		vm.startPrank(user);
		coin.approve(address(entry), type(uint256).max);
		credit.approve(address(entry), type(uint256).max);
		vm.stopPrank();
	}

	// ─── payout: automated path is limited (per token) ───

	function test_payout_onlyWhitelisted() public {
		vm.prank(stranger);
		vm.expectRevert(BaseVault.Unauthorized.selector);
		prize.payout(user, address(coin), 10e6);
	}

	function test_payout_unsupportedTokenReverts() public {
		// prize only supports coin; credit is not enabled there
		vm.prank(machine);
		vm.expectRevert(BaseVault.TokenNotSupported.selector);
		prize.payout(user, address(credit), 1e6);
	}

	function test_payout_respectsPerTokenFloor() public {
		vm.prank(owner);
		prize.setTokenPolicy(address(coin), true, 995e6, 0); // only 5 spendable

		vm.prank(machine);
		vm.expectRevert(BaseVault.MinBalanceFloorBreached.selector);
		prize.payout(user, address(coin), 10e6);

		vm.prank(machine);
		prize.payout(user, address(coin), 5e6); // exactly to the floor is allowed
		assertEq(coin.balanceOf(address(prize)), 995e6);
	}

	function test_payout_respectsPerTokenCap() public {
		vm.prank(owner);
		prize.setTokenPolicy(address(coin), true, 0, 20e6);

		vm.prank(machine);
		vm.expectRevert(BaseVault.DrainPerTxExceeded.selector);
		prize.payout(user, address(coin), 21e6);

		vm.prank(machine);
		prize.payout(user, address(coin), 20e6); // at the cap is allowed
	}

	function test_payout_whenPausedReverts() public {
		vm.prank(owner);
		prize.pause();
		vm.prank(machine);
		vm.expectRevert();
		prize.payout(user, address(coin), 10e6);
	}

	// ─── per-token limits are independent ───

	function test_perTokenLimits_areIndependent() public {
		vm.startPrank(owner);
		entry.setTokenPolicy(address(coin), true, 1_000e6, 0); // coin: floor locks the whole balance
		entry.setTokenPolicy(address(credit), true, 0, 0); // credit: no limits
		vm.stopPrank();

		vm.prank(machine);
		vm.expectRevert(BaseVault.MinBalanceFloorBreached.selector);
		entry.payout(user, address(coin), 10e6);

		// credit ignores the coin limits entirely
		vm.prank(machine);
		entry.payout(user, address(credit), 500e18);
		assertEq(credit.balanceOf(address(entry)), 500e18);
	}

	// ─── fund (owner inflow) ───

	function test_fund_onlyOwner_supportedToken() public {
		coin.mint(owner, 100e6);
		vm.startPrank(owner);
		coin.approve(address(prize), type(uint256).max);
		prize.fund(address(coin), 100e6);
		vm.stopPrank();
		assertEq(coin.balanceOf(address(prize)), 1_100e6);

		vm.prank(stranger);
		vm.expectRevert();
		prize.fund(address(coin), 1e6);
	}

	function test_creditPrizeTreasury_fundsAndPaysCredit() public {
		vm.startPrank(owner);
		PrizeTreasury credit_prize = new PrizeTreasury(owner);
		credit_prize.setTokenPolicy(address(credit), true, 0, 0);
		credit_prize.addToWhitelist(machine);
		credit.mint(owner, 100e18);
		credit.approve(address(credit_prize), type(uint256).max);
		credit_prize.fund(address(credit), 100e18);
		vm.stopPrank();

		vm.prank(machine);
		credit_prize.payout(user, address(credit), 30e18);
		assertEq(credit.balanceOf(user), 1_030e18);
		assertEq(credit.balanceOf(address(credit_prize)), 70e18);
	}

	function test_fund_unsupportedTokenReverts() public {
		credit.mint(owner, 10e18);
		vm.startPrank(owner);
		credit.approve(address(prize), type(uint256).max);
		vm.expectRevert(BaseVault.TokenNotSupported.selector);
		prize.fund(address(credit), 10e18); // credit not supported by prize
		vm.stopPrank();
	}

	// ─── admin methods are EXEMPT from floor + cap ───

	function test_ownerWithdraw_exemptFromLimits() public {
		vm.startPrank(owner);
		prize.setTokenPolicy(address(coin), true, 999e6, 1e6); // machine could barely move anything
		prize.withdraw(address(coin), owner, 900e6); // owner ignores both
		vm.stopPrank();
		assertEq(coin.balanceOf(address(prize)), 100e6);
		assertEq(coin.balanceOf(owner), 900e6);
	}

	function test_ownerWithdraw_anyToken() public {
		vm.prank(owner);
		entry.withdraw(address(credit), owner, 1_000e18);
		assertEq(credit.balanceOf(owner), 1_000e18);
		assertEq(credit.balanceOf(address(entry)), 0);
	}

	// ─── EntryVault deposit ───

	function test_depositFor_pullsCoinAndCredit() public {
		vm.startPrank(machine);
		entry.depositFor(user, address(coin), 10e6);
		entry.depositFor(user, address(credit), 5e18);
		vm.stopPrank();
		assertEq(coin.balanceOf(address(entry)), 1_010e6);
		assertEq(credit.balanceOf(address(entry)), 1_005e18);
	}

	function test_depositFor_unsupportedTokenReverts() public {
		MockCoin other = new MockCoin();
		other.mint(user, 10e6);
		vm.prank(user);
		other.approve(address(entry), type(uint256).max);
		vm.prank(machine);
		vm.expectRevert(BaseVault.TokenNotSupported.selector);
		entry.depositFor(user, address(other), 1e6);
	}

	// ─── recycle is just a generic payout to the credit vault ───

	function test_payout_recycleCreditToCreditVault() public {
		vm.prank(machine);
		entry.payout(creditVault, address(credit), 300e18);
		assertEq(credit.balanceOf(creditVault), 300e18);
		assertEq(credit.balanceOf(address(entry)), 700e18);
	}

	// ─── recover only non-supported tokens ───

	function test_recoverToken_blocksSupported_allowsUnsupported() public {
		vm.startPrank(owner);
		vm.expectRevert(BaseVault.TokenIsSupported.selector);
		entry.recoverToken(address(coin), owner);
		vm.stopPrank();

		MockCoin stray = new MockCoin();
		stray.mint(address(entry), 42e6);
		vm.prank(owner);
		entry.recoverToken(address(stray), owner);
		assertEq(stray.balanceOf(owner), 42e6);
	}

	// ─── §7: PrizeTreasury has NO machine-inflow path ───

	function test_prizeTreasury_hasNoDepositFor() public {
		// depositFor is not part of PrizeTreasury's ABI at all (compile-time guarantee); a raw
		// call to that selector finds no function and reverts — its balance is only ever fund()ed.
		(bool ok,) = address(prize)
			.call(abi.encodeWithSignature("depositFor(address,address,uint256)", user, address(coin), 1e6));
		assertFalse(ok);
	}
}
