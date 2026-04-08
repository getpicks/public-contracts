// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PicksUSD} from "../src/PicksUSD.sol";

contract PicksUSDTest is Test {
	PicksUSD public token;

	uint256 internal authorityKey = 0xA11CE;
	address public authority;
	address public owner = makeAddr("owner");
	address public treasury = makeAddr("treasury");
	address public userA = makeAddr("userA");
	address public userB = makeAddr("userB");
	address public stranger = makeAddr("stranger");

	bytes32 internal constant MINT_TYPEHASH = keccak256("mint");

	function setUp() public {
		authority = vm.addr(authorityKey);
		token = new PicksUSD(authority, owner);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────

	function _sign(
		address to,
		uint256 amount,
		uint256 deadline,
		bytes32 idempotency_key
	) internal view returns (bytes memory) {
		bytes32 message_hash = keccak256(
			abi.encode(MINT_TYPEHASH, block.chainid, address(token), to, amount, deadline, idempotency_key)
		);
		bytes32 eth_hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message_hash));
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, eth_hash);
		return abi.encodePacked(r, s, v);
	}

	function _mint(address to, uint256 amount, bytes32 key) internal {
		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _sign(to, amount, deadline, key);
		token.mint(to, amount, deadline, key, sig);
	}

	// ─── mint: happy path ─────────────────────────────────────────────────────

	function test_mint_happyPath() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		uint256 amount = 1000e18;

		bytes memory sig = _sign(userA, amount, deadline, key);
		token.mint(userA, amount, deadline, key, sig);

		assertEq(token.balanceOf(userA), amount);
		assertTrue(token.used_keys(key));
	}

	function test_mint_emitsEvent() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		uint256 amount = 1000e18;

		bytes memory sig = _sign(userA, amount, deadline, key);

		vm.expectEmit(true, true, false, true);
		emit PicksUSD.Minted(userA, amount, key);
		token.mint(userA, amount, deadline, key, sig);
	}

	function test_mint_differentKeysForSameUser() public {
		bytes32 key1 = keccak256("airdrop-season-1:userA");
		bytes32 key2 = keccak256("bonus-april:userA");

		_mint(userA, 1000e18, key1);
		_mint(userA, 500e18, key2);

		assertEq(token.balanceOf(userA), 1500e18);
	}

	function test_mint_callerDoesNotNeedToBeRecipient() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _sign(userA, 1000e18, deadline, key);

		vm.prank(stranger);
		token.mint(userA, 1000e18, deadline, key, sig);

		assertEq(token.balanceOf(userA), 1000e18);
		assertEq(token.balanceOf(stranger), 0);
	}

	// ─── mint: reverts ────────────────────────────────────────────────────────

	function test_mint_revertsOnDuplicateKey() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		_mint(userA, 1000e18, key);

		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _sign(userA, 1000e18, deadline, key);

		vm.expectRevert(PicksUSD.IdempotencyKeyAlreadyUsed.selector);
		token.mint(userA, 1000e18, deadline, key, sig);
	}

	function test_mint_safeToRetryBeforeSuccess() public {
		// same payload submitted twice — only mints once
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _sign(userA, 1000e18, deadline, key);

		token.mint(userA, 1000e18, deadline, key, sig);

		vm.expectRevert(PicksUSD.IdempotencyKeyAlreadyUsed.selector);
		token.mint(userA, 1000e18, deadline, key, sig);

		assertEq(token.balanceOf(userA), 1000e18);
	}

	function test_mint_revertsOnExpiredDeadline() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp - 1;
		bytes memory sig = _sign(userA, 1000e18, deadline, key);

		vm.expectRevert(PicksUSD.SignatureExpired.selector);
		token.mint(userA, 1000e18, deadline, key, sig);
	}

	function test_mint_revertsOnWrongSigner() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes32 message_hash = keccak256(
			abi.encode(MINT_TYPEHASH, block.chainid, address(token), userA, 1000e18, deadline, key)
		);
		bytes32 eth_hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message_hash));
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, eth_hash);
		bytes memory bad_sig = abi.encodePacked(r, s, v);

		vm.expectRevert(PicksUSD.InvalidSignature.selector);
		token.mint(userA, 1000e18, deadline, key, bad_sig);
	}

	function test_mint_revertsOnZeroAddress() public {
		bytes32 key = keccak256("airdrop-season-1:zero");
		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _sign(address(0), 1000e18, deadline, key);

		vm.expectRevert(PicksUSD.InvalidInput.selector);
		token.mint(address(0), 1000e18, deadline, key, sig);
	}

	function test_mint_revertsOnZeroAmount() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _sign(userA, 0, deadline, key);

		vm.expectRevert(PicksUSD.InvalidInput.selector);
		token.mint(userA, 0, deadline, key, sig);
	}

	function test_mint_revertsOnZeroKey() public {
		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _sign(userA, 1000e18, deadline, bytes32(0));

		vm.expectRevert(PicksUSD.InvalidInput.selector);
		token.mint(userA, 1000e18, deadline, bytes32(0), sig);
	}

	function test_mint_revertsOnWrongChain() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes32 message_hash = keccak256(
			abi.encode(MINT_TYPEHASH, block.chainid + 1, address(token), userA, 1000e18, deadline, key)
		);
		bytes32 eth_hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message_hash));
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, eth_hash);
		bytes memory sig = abi.encodePacked(r, s, v);

		vm.expectRevert(PicksUSD.InvalidSignature.selector);
		token.mint(userA, 1000e18, deadline, key, sig);
	}

	function test_mint_revertsOnWrongContractAddress() public {
		bytes32 key = keccak256("airdrop-season-1:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes32 message_hash = keccak256(
			abi.encode(MINT_TYPEHASH, block.chainid, address(0xDEAD), userA, 1000e18, deadline, key)
		);
		bytes32 eth_hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message_hash));
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, eth_hash);
		bytes memory sig = abi.encodePacked(r, s, v);

		vm.expectRevert(PicksUSD.InvalidSignature.selector);
		token.mint(userA, 1000e18, deadline, key, sig);
	}

	// ─── transfer restrictions ────────────────────────────────────────────────

	function test_transfer_userCannotTransferToAnotherUser() public {
		_mint(userA, 1000e18, keccak256("airdrop:userA"));

		vm.prank(userA);
		vm.expectRevert(PicksUSD.Unauthorized.selector);
		token.transfer(userB, 500e18);
	}

	function test_transfer_whitelistedCanSend() public {
		_mint(treasury, 1000e18, keccak256("airdrop:treasury"));

		vm.prank(owner);
		token.addToWhitelist(treasury);

		vm.prank(treasury);
		token.transfer(userA, 500e18);

		assertEq(token.balanceOf(userA), 500e18);
		assertEq(token.balanceOf(treasury), 500e18);
	}

	function test_transferFrom_userCannotPullTokens() public {
		_mint(userA, 1000e18, keccak256("airdrop:userA"));

		vm.prank(userB);
		vm.expectRevert(PicksUSD.Unauthorized.selector);
		token.transferFrom(userA, userB, 500e18);
	}

	function test_transferFrom_whitelistedCanPullWithoutApproval() public {
		_mint(userA, 1000e18, keccak256("airdrop:userA"));

		vm.prank(owner);
		token.addToWhitelist(treasury);

		vm.prank(treasury);
		token.transferFrom(userA, treasury, 1000e18);

		assertEq(token.balanceOf(userA), 0);
		assertEq(token.balanceOf(treasury), 1000e18);
	}

	function test_allowance_whitelistedHasMaxAllowance() public {
		vm.prank(owner);
		token.addToWhitelist(treasury);

		assertEq(token.allowance(userA, treasury), type(uint256).max);
	}

	function test_allowance_nonWhitelistedHasZero() public view {
		assertEq(token.allowance(userA, stranger), 0);
	}

	function test_approve_reverts() public {
		vm.prank(userA);
		vm.expectRevert(PicksUSD.NotSupported.selector);
		token.approve(treasury, 1000e18);
	}

	function test_transfer_removedFromWhitelistCanNoLongerTransfer() public {
		vm.prank(owner);
		token.addToWhitelist(treasury);

		_mint(treasury, 1000e18, keccak256("airdrop:treasury"));

		vm.prank(owner);
		token.removeFromWhitelist(treasury);

		vm.prank(treasury);
		vm.expectRevert(PicksUSD.Unauthorized.selector);
		token.transfer(userA, 500e18);
	}

	// ─── whitelist management ─────────────────────────────────────────────────

	function test_addToWhitelist_emitsEvent() public {
		vm.prank(owner);
		vm.expectEmit(true, false, false, false);
		emit PicksUSD.AddressWhitelisted(treasury);
		token.addToWhitelist(treasury);
	}

	function test_addToWhitelist_revertsForNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert();
		token.addToWhitelist(treasury);
	}

	function test_addToWhitelist_revertsOnZeroAddress() public {
		vm.prank(owner);
		vm.expectRevert(PicksUSD.InvalidInput.selector);
		token.addToWhitelist(address(0));
	}

	function test_removeFromWhitelist_emitsEvent() public {
		vm.prank(owner);
		token.addToWhitelist(treasury);

		vm.prank(owner);
		vm.expectEmit(true, false, false, false);
		emit PicksUSD.AddressRemovedFromWhitelist(treasury);
		token.removeFromWhitelist(treasury);

		assertFalse(token.whitelisted_addresses(treasury));
	}

	function test_removeFromWhitelist_revertsForNonOwner() public {
		vm.prank(owner);
		token.addToWhitelist(treasury);

		vm.prank(stranger);
		vm.expectRevert();
		token.removeFromWhitelist(treasury);
	}

	// ─── setAutomatedAuthority ────────────────────────────────────────────────

	function test_setAutomatedAuthority_happyPath() public {
		address new_auth = makeAddr("newAuth");

		vm.prank(owner);
		vm.expectEmit(true, true, false, false);
		emit PicksUSD.AutomatedAuthorityUpdated(authority, new_auth);
		token.setAutomatedAuthority(new_auth);

		assertEq(token.automated_authority_address(), new_auth);
	}

	function test_setAutomatedAuthority_revertsForNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert();
		token.setAutomatedAuthority(makeAddr("newAuth"));
	}

	function test_setAutomatedAuthority_revertsOnZeroAddress() public {
		vm.prank(owner);
		vm.expectRevert(PicksUSD.InvalidInput.selector);
		token.setAutomatedAuthority(address(0));
	}

	function test_setAutomatedAuthority_oldSignaturesInvalidAfterRotation() public {
		bytes32 key = keccak256("airdrop:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes memory old_sig = _sign(userA, 1000e18, deadline, key);

		uint256 newKey = 0xB0B;
		address new_auth = vm.addr(newKey);
		vm.prank(owner);
		token.setAutomatedAuthority(new_auth);

		vm.expectRevert(PicksUSD.InvalidSignature.selector);
		token.mint(userA, 1000e18, deadline, key, old_sig);
	}

	function test_setAutomatedAuthority_newSignaturesWorkAfterRotation() public {
		uint256 newKey = 0xB0B;
		address new_auth = vm.addr(newKey);
		vm.prank(owner);
		token.setAutomatedAuthority(new_auth);

		bytes32 key = keccak256("airdrop:userA");
		uint256 deadline = block.timestamp + 1 hours;
		bytes32 message_hash = keccak256(
			abi.encode(MINT_TYPEHASH, block.chainid, address(token), userA, 1000e18, deadline, key)
		);
		bytes32 eth_hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message_hash));
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(newKey, eth_hash);
		bytes memory sig = abi.encodePacked(r, s, v);

		token.mint(userA, 1000e18, deadline, key, sig);
		assertEq(token.balanceOf(userA), 1000e18);
	}

	// ─── batchMint ────────────────────────────────────────────────────────────

	function _buildBatch(
		address[] memory tos,
		uint256[] memory amounts,
		uint256 deadline,
		bytes32[] memory keys
	) internal view returns (bytes[] memory sigs) {
		sigs = new bytes[](tos.length);
		for (uint256 i = 0; i < tos.length; ++i) {
			sigs[i] = _sign(tos[i], amounts[i], deadline, keys[i]);
		}
	}

	function test_batchMint_happyPath() public {
		uint256 deadline = block.timestamp + 1 hours;

		address[] memory tos = new address[](3);
		tos[0] = userA; tos[1] = userB; tos[2] = stranger;

		uint256[] memory amounts = new uint256[](3);
		amounts[0] = 1000e18; amounts[1] = 1000e18; amounts[2] = 1000e18;

		bytes32[] memory keys = new bytes32[](3);
		keys[0] = keccak256("airdrop:userA");
		keys[1] = keccak256("airdrop:userB");
		keys[2] = keccak256("airdrop:stranger");

		bytes[] memory sigs = _buildBatch(tos, amounts, deadline, keys);
		token.batchMint(tos, amounts, deadline, keys, sigs);

		assertEq(token.balanceOf(userA), 1000e18);
		assertEq(token.balanceOf(userB), 1000e18);
		assertEq(token.balanceOf(stranger), 1000e18);
		assertTrue(token.used_keys(keys[0]));
		assertTrue(token.used_keys(keys[1]));
		assertTrue(token.used_keys(keys[2]));
	}

	function test_batchMint_revertsOnArrayLengthMismatch() public {
		uint256 deadline = block.timestamp + 1 hours;

		address[] memory tos = new address[](2);
		tos[0] = userA; tos[1] = userB;

		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 1000e18;

		bytes32[] memory keys = new bytes32[](2);
		keys[0] = keccak256("airdrop:userA");
		keys[1] = keccak256("airdrop:userB");

		bytes[] memory sigs = new bytes[](2);

		vm.expectRevert(PicksUSD.InvalidInput.selector);
		token.batchMint(tos, amounts, deadline, keys, sigs);
	}

	function test_batchMint_revertsOnDuplicateKeyWithinBatch() public {
		uint256 deadline = block.timestamp + 1 hours;

		address[] memory tos = new address[](2);
		tos[0] = userA; tos[1] = userB;

		uint256[] memory amounts = new uint256[](2);
		amounts[0] = 1000e18; amounts[1] = 1000e18;

		bytes32[] memory keys = new bytes32[](2);
		keys[0] = keccak256("airdrop:userA");
		keys[1] = keccak256("airdrop:userA"); // duplicate

		bytes[] memory sigs = _buildBatch(tos, amounts, deadline, keys);

		vm.expectRevert(PicksUSD.IdempotencyKeyAlreadyUsed.selector);
		token.batchMint(tos, amounts, deadline, keys, sigs);
	}

	function test_batchMint_revertsOnAlreadyUsedKey() public {
		bytes32 key = keccak256("airdrop:userA");
		_mint(userA, 1000e18, key);

		uint256 deadline = block.timestamp + 1 hours;

		address[] memory tos = new address[](1);
		tos[0] = userA;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 1000e18;
		bytes32[] memory keys = new bytes32[](1);
		keys[0] = key;
		bytes[] memory sigs = _buildBatch(tos, amounts, deadline, keys);

		vm.expectRevert(PicksUSD.IdempotencyKeyAlreadyUsed.selector);
		token.batchMint(tos, amounts, deadline, keys, sigs);
	}

	function test_batchMint_revertsOnExpiredDeadline() public {
		uint256 deadline = block.timestamp - 1;

		address[] memory tos = new address[](1);
		tos[0] = userA;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 1000e18;
		bytes32[] memory keys = new bytes32[](1);
		keys[0] = keccak256("airdrop:userA");
		bytes[] memory sigs = _buildBatch(tos, amounts, deadline, keys);

		vm.expectRevert(PicksUSD.SignatureExpired.selector);
		token.batchMint(tos, amounts, deadline, keys, sigs);
	}

	function test_batchMint_revertsOnWrongSigner() public {
		uint256 deadline = block.timestamp + 1 hours;

		address[] memory tos = new address[](1);
		tos[0] = userA;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = 1000e18;
		bytes32[] memory keys = new bytes32[](1);
		keys[0] = keccak256("airdrop:userA");

		// sign with wrong key
		bytes32 message_hash = keccak256(
			abi.encode(MINT_TYPEHASH, block.chainid, address(token), userA, 1000e18, deadline, keys[0])
		);
		bytes32 eth_hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message_hash));
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, eth_hash);
		bytes[] memory sigs = new bytes[](1);
		sigs[0] = abi.encodePacked(r, s, v);

		vm.expectRevert(PicksUSD.InvalidSignature.selector);
		token.batchMint(tos, amounts, deadline, keys, sigs);
	}

	// ─── balanceOfBatch ───────────────────────────────────────────────────────

	function test_balanceOfBatch() public {
		_mint(userA, 1000e18, keccak256("airdrop:userA"));
		_mint(userB, 500e18, keccak256("airdrop:userB"));

		address[] memory accounts = new address[](3);
		accounts[0] = userA;
		accounts[1] = userB;
		accounts[2] = stranger;

		uint256[] memory balances = token.balanceOfBatch(accounts);

		assertEq(balances[0], 1000e18);
		assertEq(balances[1], 500e18);
		assertEq(balances[2], 0);
	}

	// ─── metadata ─────────────────────────────────────────────────────────────

	function test_metadata() public view {
		assertEq(token.name(), "USD.P");
		assertEq(token.symbol(), "USD.P");
		assertEq(token.decimals(), 18);
	}
}
