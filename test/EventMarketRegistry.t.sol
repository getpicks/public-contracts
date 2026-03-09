// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EventMarketRegistry} from "../src/EventMarketRegistry.sol";
import {IEventMarketRegistry} from "../src/IEventMarketRegistry.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract EventMarketRegistryTest is Test {
	using MessageHashUtils for bytes32;

	EventMarketRegistry public registry;

	address public owner = makeAddr("owner");
	address public writer = makeAddr("writer");
	address public stranger = makeAddr("stranger");
	uint256 public authorityPk = 0xA11CE;
	address public authority = vm.addr(authorityPk);

	bytes32 internal constant SETTLE_EVENT_TYPEHASH = keccak256("settleEventMarket");
	bytes32 internal constant VOID_EVENT_TYPEHASH = keccak256("voidEventMarket");
	bytes32 internal constant UPDATE_EVENT_MARKET_TYPEHASH = keccak256("updateEventMarket");

	bytes12 internal constant MARKET_ID = bytes12(uint96(1));
	bytes12 internal constant OUTCOME_A = bytes12(uint96(100));

	function setUp() public {
		EventMarketRegistry impl = new EventMarketRegistry();
		bytes memory initData = abi.encodeCall(EventMarketRegistry.initialize, (authority, owner));
		TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
			address(impl), makeAddr("proxyAdmin"), initData
		);
		registry = EventMarketRegistry(address(proxy));

		vm.prank(owner);
		registry.addAuthorizedWriter(writer);
	}

	// ─── Helpers ───

	function _createMarket(bytes12 id, uint40 minSettlementTs) internal {
		vm.prank(writer);
		registry.ensureExists(id, minSettlementTs);
	}

	function _signSettle(
		bytes12 marketId,
		bytes12 outcomeId,
		uint256 deadline
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(SETTLE_EVENT_TYPEHASH, block.chainid, address(registry), marketId, outcomeId, deadline)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, hash);
		return abi.encodePacked(r, s, v);
	}

	function _signVoid(bytes12 marketId, uint256 deadline) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(VOID_EVENT_TYPEHASH, block.chainid, address(registry), marketId, deadline)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, hash);
		return abi.encodePacked(r, s, v);
	}

	function _signUpdate(
		bytes12 marketId,
		uint40 newTs,
		uint256 nonce,
		uint256 deadline
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(UPDATE_EVENT_MARKET_TYPEHASH, block.chainid, address(registry), marketId, newTs, nonce, deadline)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, hash);
		return abi.encodePacked(r, s, v);
	}

	// ─── Initialize ───

	function test_initialize() public view {
		assertEq(registry.owner(), owner);
		assertEq(registry.automated_authority_address(), authority);
	}

	function test_initialize_revertsZeroOwner() public {
		EventMarketRegistry impl = new EventMarketRegistry();
		bytes memory initData = abi.encodeCall(EventMarketRegistry.initialize, (authority, address(0)));
		vm.expectRevert();
		new TransparentUpgradeableProxy(address(impl), makeAddr("admin2"), initData);
	}

	function test_initialize_revertsZeroAuthority() public {
		EventMarketRegistry impl = new EventMarketRegistry();
		bytes memory initData = abi.encodeCall(EventMarketRegistry.initialize, (address(0), owner));
		vm.expectRevert();
		new TransparentUpgradeableProxy(address(impl), makeAddr("admin3"), initData);
	}

	function test_initialize_cannotReinitialize() public {
		vm.expectRevert();
		registry.initialize(authority, owner);
	}

	// ─── ensureExists ───

	function test_ensureExists_createsNewMarket() public {
		uint40 ts = uint40(block.timestamp + 1 hours);

		vm.expectEmit(true, false, false, true);
		emit EventMarketRegistry.EventMarketCreated(MARKET_ID, ts);

		_createMarket(MARKET_ID, ts);

		IEventMarketRegistry.EventMarket memory m = registry.getEventMarket(MARKET_ID);
		assertTrue(m.is_exists);
		assertFalse(m.is_settled);
		assertEq(m.min_settlement_ts, ts);
		assertEq(m.winning_outcome_id, bytes12(0));
	}

	function test_ensureExists_idempotentOnExisting() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		// calling again should not revert
		vm.prank(writer);
		registry.ensureExists(MARKET_ID, ts);
	}

	function test_ensureExists_revertsZeroId() public {
		vm.prank(writer);
		vm.expectRevert(EventMarketRegistry.InvalidInput.selector);
		registry.ensureExists(bytes12(0), uint40(block.timestamp + 1 hours));
	}

	function test_ensureExists_revertsTimestampInPast() public {
		vm.prank(writer);
		vm.expectRevert(EventMarketRegistry.InvalidInput.selector);
		registry.ensureExists(MARKET_ID, uint40(block.timestamp - 1));
	}

	function test_ensureExists_revertsTimestampEqualToNow() public {
		vm.prank(writer);
		vm.expectRevert(EventMarketRegistry.InvalidInput.selector);
		registry.ensureExists(MARKET_ID, uint40(block.timestamp));
	}

	function test_ensureExists_revertsUnauthorizedWriter() public {
		vm.prank(stranger);
		vm.expectRevert(EventMarketRegistry.Unauthorized.selector);
		registry.ensureExists(MARKET_ID, uint40(block.timestamp + 1 hours));
	}

	function test_ensureExists_revertsIfSettled() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		// settle it
		vm.warp(ts);
		uint256 deadline = block.timestamp + 1 hours;
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));

		// try ensureExists on settled market
		vm.prank(writer);
		vm.expectRevert(EventMarketRegistry.EventMarketAlreadySettled.selector);
		registry.ensureExists(MARKET_ID, ts);
	}

	function test_ensureExists_revertsIfBettingWindowClosed() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		// warp past settlement time
		vm.warp(ts);

		vm.prank(writer);
		vm.expectRevert(EventMarketRegistry.BettingWindowClosed.selector);
		registry.ensureExists(MARKET_ID, ts);
	}

	function test_ensureExists_revertsWhenPaused() public {
		vm.prank(owner);
		registry.pause();

		vm.prank(writer);
		vm.expectRevert();
		registry.ensureExists(MARKET_ID, uint40(block.timestamp + 1 hours));
	}

	// ─── settleEventMarket ───

	function test_settle_setsWinningOutcome() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		vm.warp(ts);

		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _signSettle(MARKET_ID, OUTCOME_A, deadline);

		vm.expectEmit(true, true, false, false);
		emit EventMarketRegistry.EventMarketSettled(MARKET_ID, OUTCOME_A);

		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, sig);

		IEventMarketRegistry.EventMarket memory m = registry.getEventMarket(MARKET_ID);
		assertTrue(m.is_settled);
		assertEq(m.winning_outcome_id, OUTCOME_A);
	}

	function test_settle_revertsIfNotExists() public {
		uint256 deadline = block.timestamp + 1 hours;
		vm.expectRevert(EventMarketRegistry.EventMarketDoesNotExist.selector);
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));
	}

	function test_settle_revertsIfAlreadySettled() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		vm.warp(ts);

		uint256 deadline = block.timestamp + 1 hours;
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));

		vm.expectRevert(EventMarketRegistry.EventMarketAlreadySettled.selector);
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));
	}

	function test_settle_revertsTooEarly() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		// don't warp

		uint256 deadline = block.timestamp + 2 hours;
		vm.expectRevert(EventMarketRegistry.TooEarlyToSettle.selector);
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));
	}

	function test_settle_revertsZeroOutcome() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		vm.warp(ts);

		uint256 deadline = block.timestamp + 1 hours;
		vm.expectRevert(EventMarketRegistry.InvalidInput.selector);
		registry.settleEventMarket(MARKET_ID, bytes12(0), deadline, _signSettle(MARKET_ID, bytes12(0), deadline));
	}

	function test_settle_revertsExpiredSignature() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		vm.warp(ts);

		uint256 deadline = block.timestamp - 1; // expired
		vm.expectRevert(EventMarketRegistry.SignatureExpired.selector);
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));
	}

	function test_settle_revertsInvalidSignature() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		vm.warp(ts);

		uint256 deadline = block.timestamp + 1 hours;
		// sign with wrong key
		uint256 wrongPk = 0xBEEF;
		bytes32 hash = keccak256(
			abi.encode(SETTLE_EVENT_TYPEHASH, block.chainid, address(registry), MARKET_ID, OUTCOME_A, deadline)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, hash);
		bytes memory badSig = abi.encodePacked(r, s, v);

		vm.expectRevert(EventMarketRegistry.InvalidSignature.selector);
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, badSig);
	}

	function test_settle_revertsWhenPaused() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		vm.warp(ts);

		vm.prank(owner);
		registry.pause();

		uint256 deadline = block.timestamp + 1 hours;
		vm.expectRevert();
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));
	}

	// ─── voidEventMarket ───

	function test_void_setsVoidedOutcome() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		uint256 deadline = block.timestamp + 1 hours;
		bytes memory sig = _signVoid(MARKET_ID, deadline);

		vm.expectEmit(true, true, false, false);
		emit EventMarketRegistry.EventMarketSettled(MARKET_ID, bytes12(0));

		registry.voidEventMarket(MARKET_ID, deadline, sig);

		IEventMarketRegistry.EventMarket memory m = registry.getEventMarket(MARKET_ID);
		assertTrue(m.is_settled);
		assertEq(m.winning_outcome_id, bytes12(0));
	}

	function test_void_revertsIfNotExists() public {
		uint256 deadline = block.timestamp + 1 hours;
		vm.expectRevert(EventMarketRegistry.EventMarketDoesNotExist.selector);
		registry.voidEventMarket(MARKET_ID, deadline, _signVoid(MARKET_ID, deadline));
	}

	function test_void_revertsIfAlreadySettled() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		uint256 deadline = block.timestamp + 1 hours;
		registry.voidEventMarket(MARKET_ID, deadline, _signVoid(MARKET_ID, deadline));

		vm.expectRevert(EventMarketRegistry.EventMarketAlreadySettled.selector);
		registry.voidEventMarket(MARKET_ID, deadline, _signVoid(MARKET_ID, deadline));
	}

	function test_void_revertsExpiredSignature() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		uint256 deadline = block.timestamp - 1;
		vm.expectRevert(EventMarketRegistry.SignatureExpired.selector);
		registry.voidEventMarket(MARKET_ID, deadline, _signVoid(MARKET_ID, deadline));
	}

	function test_void_canBeCalledBeforeSettlementTime() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		// don't warp — void should work anytime

		uint256 deadline = block.timestamp + 1 hours;
		registry.voidEventMarket(MARKET_ID, deadline, _signVoid(MARKET_ID, deadline));

		IEventMarketRegistry.EventMarket memory m = registry.getEventMarket(MARKET_ID);
		assertTrue(m.is_settled);
	}

	// ─── updateEventMarket ───

	function test_update_changesMinSettlementTs() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		uint40 newTs = uint40(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = registry.automated_authority_nonce();
		bytes memory sig = _signUpdate(MARKET_ID, newTs, nonce, deadline);

		vm.expectEmit(true, false, false, true);
		emit EventMarketRegistry.EventMarketUpdated(MARKET_ID, newTs);

		registry.updateEventMarket(MARKET_ID, newTs, deadline, sig);

		IEventMarketRegistry.EventMarket memory m = registry.getEventMarket(MARKET_ID);
		assertEq(m.min_settlement_ts, newTs);
	}

	function test_update_incrementsNonce() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		assertEq(registry.automated_authority_nonce(), 0);

		uint40 newTs = uint40(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;
		registry.updateEventMarket(MARKET_ID, newTs, deadline, _signUpdate(MARKET_ID, newTs, 0, deadline));

		assertEq(registry.automated_authority_nonce(), 1);

		// second update needs nonce=1
		uint40 newTs2 = uint40(block.timestamp + 3 hours);
		registry.updateEventMarket(MARKET_ID, newTs2, deadline, _signUpdate(MARKET_ID, newTs2, 1, deadline));

		assertEq(registry.automated_authority_nonce(), 2);
	}

	function test_update_revertsWithStaleNonce() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);

		uint40 newTs = uint40(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;
		// do first update (nonce 0 → 1)
		registry.updateEventMarket(MARKET_ID, newTs, deadline, _signUpdate(MARKET_ID, newTs, 0, deadline));

		// try to replay with nonce 0
		vm.expectRevert(EventMarketRegistry.InvalidSignature.selector);
		registry.updateEventMarket(MARKET_ID, newTs, deadline, _signUpdate(MARKET_ID, newTs, 0, deadline));
	}

	function test_update_revertsIfNotExists() public {
		uint256 deadline = block.timestamp + 1 hours;
		uint40 newTs = uint40(block.timestamp + 2 hours);
		vm.expectRevert(EventMarketRegistry.EventMarketDoesNotExist.selector);
		registry.updateEventMarket(MARKET_ID, newTs, deadline, _signUpdate(MARKET_ID, newTs, 0, deadline));
	}

	function test_update_revertsIfSettled() public {
		uint40 ts = uint40(block.timestamp + 1 hours);
		_createMarket(MARKET_ID, ts);
		vm.warp(ts);

		uint256 deadline = block.timestamp + 1 hours;
		registry.settleEventMarket(MARKET_ID, OUTCOME_A, deadline, _signSettle(MARKET_ID, OUTCOME_A, deadline));

		uint40 newTs = uint40(block.timestamp + 2 hours);
		vm.expectRevert(EventMarketRegistry.EventMarketAlreadySettled.selector);
		registry.updateEventMarket(MARKET_ID, newTs, deadline, _signUpdate(MARKET_ID, newTs, 0, deadline));
	}

	// ─── Admin: authorized writers ───

	function test_addAuthorizedWriter() public {
		address newWriter = makeAddr("newWriter");

		vm.expectEmit(true, false, false, false);
		emit EventMarketRegistry.AuthorizedWriterAdded(newWriter);

		vm.prank(owner);
		registry.addAuthorizedWriter(newWriter);

		assertTrue(registry.authorized_writers(newWriter));
	}

	function test_addAuthorizedWriter_revertsZeroAddress() public {
		vm.prank(owner);
		vm.expectRevert(EventMarketRegistry.InvalidInput.selector);
		registry.addAuthorizedWriter(address(0));
	}

	function test_addAuthorizedWriter_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(EventMarketRegistry.OwnableUnauthorizedAccount.selector, stranger));
		registry.addAuthorizedWriter(makeAddr("x"));
	}

	function test_removeAuthorizedWriter() public {
		vm.prank(owner);
		registry.removeAuthorizedWriter(writer);

		assertFalse(registry.authorized_writers(writer));
	}

	// ─── Admin: configuration ───

	function test_updateConfiguration_changesAuthority() public {
		address newAuth = makeAddr("newAuth");

		vm.prank(owner);
		registry.updateConfiguration(newAuth);

		assertEq(registry.automated_authority_address(), newAuth);
	}

	function test_updateConfiguration_skipsZeroAddress() public {
		vm.prank(owner);
		registry.updateConfiguration(address(0));

		assertEq(registry.automated_authority_address(), authority);
	}

	function test_updateConfiguration_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(EventMarketRegistry.OwnableUnauthorizedAccount.selector, stranger));
		registry.updateConfiguration(makeAddr("x"));
	}

	// ─── Admin: pause/unpause ───

	function test_pause_unpause() public {
		vm.prank(owner);
		registry.pause();

		vm.prank(writer);
		vm.expectRevert();
		registry.ensureExists(MARKET_ID, uint40(block.timestamp + 1 hours));

		vm.prank(owner);
		registry.unpause();

		// should work again
		_createMarket(MARKET_ID, uint40(block.timestamp + 1 hours));
		assertTrue(registry.getEventMarket(MARKET_ID).is_exists);
	}

	function test_pause_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(EventMarketRegistry.OwnableUnauthorizedAccount.selector, stranger));
		registry.pause();
	}

	// ─── Admin: ownership ───

	function test_transferOwnership() public {
		address newOwner = makeAddr("newOwner");

		vm.prank(owner);
		registry.transferOwnership(newOwner);

		assertEq(registry.owner(), newOwner);
	}

	function test_transferOwnership_revertsZeroAddress() public {
		vm.prank(owner);
		vm.expectRevert(abi.encodeWithSelector(EventMarketRegistry.OwnableInvalidOwner.selector, address(0)));
		registry.transferOwnership(address(0));
	}

	function test_transferOwnership_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(EventMarketRegistry.OwnableUnauthorizedAccount.selector, stranger));
		registry.transferOwnership(makeAddr("x"));
	}
}
