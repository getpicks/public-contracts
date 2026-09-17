// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {EntryVault} from "../src/EntryVault.sol";
import {PrizeTreasury} from "../src/PrizeTreasury.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VaultFactoryTest is Test {
	VaultFactory internal factory;
	address internal owner = makeAddr("owner");
	address internal stranger = makeAddr("stranger");

	function setUp() public {
		factory = new VaultFactory(owner);
	}

	function test_createVaultPair_deploysDistinctVaultsOwnedByOwner() public {
		vm.prank(owner);
		(uint256 id, address entry_addr, address prize_addr) = factory.createVaultPair();

		assertEq(id, 0);
		assertTrue(entry_addr != address(0));
		assertTrue(prize_addr != address(0));
		assertTrue(entry_addr != prize_addr); // never commingle (spec §7)

		// the factory owns nothing — the deployed vaults are owned by the factory's owner
		assertEq(EntryVault(payable(entry_addr)).owner(), owner);
		assertEq(PrizeTreasury(payable(prize_addr)).owner(), owner);

		(address e, address p, bool active) = factory.getVaultPair(0);
		assertEq(e, entry_addr);
		assertEq(p, prize_addr);
		assertTrue(active);
		assertEq(factory.vaultPairsCount(), 1);
	}

	function test_createVaultPair_incrementsIds() public {
		vm.startPrank(owner);
		(uint256 id0, , ) = factory.createVaultPair();
		(uint256 id1, , ) = factory.createVaultPair();
		vm.stopPrank();
		assertEq(id0, 0);
		assertEq(id1, 1);
		assertEq(factory.vaultPairsCount(), 2);
	}

	function test_createVaultPair_onlyOwner() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.createVaultPair();
	}

	function test_setVaultPairActive_gatesNewLineupsOnly() public {
		vm.startPrank(owner);
		factory.createVaultPair();
		factory.setVaultPairActive(0, false);
		vm.stopPrank();
		(, , bool active) = factory.getVaultPair(0);
		assertFalse(active);
	}

	function test_getVaultPair_revertsOnUnknownId() public {
		vm.expectRevert(VaultFactory.VaultPairDoesNotExist.selector);
		factory.getVaultPair(0);
	}
}
