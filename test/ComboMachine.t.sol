// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ComboMachine} from "../src/ComboMachine.sol";
import {IEventMarketRegistry} from "../src/IEventMarketRegistry.sol";
import {EventMarketRegistry} from "../src/EventMarketRegistry.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Mock Tokens ───

contract MockUSDC is ERC20 {
	constructor() ERC20("USDC", "USDC") {}

	function decimals() public pure override returns (uint8) {
		return 6;
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

// ─── Mock Treasury ───

contract MockHotTreasury {
	address public immutable CREDIT_TOKEN_ADDRESS;
	address public immutable COIN_ADDRESS;

	constructor(address _creditToken, address _coin) {
		CREDIT_TOKEN_ADDRESS = _creditToken;
		COIN_ADDRESS = _coin;
	}

	function depositFor(address user, address token, uint256 amount) external {
		ERC20(token).transferFrom(user, address(this), amount);
	}

	function drain(address to, uint256 amount) external {
		ERC20(COIN_ADDRESS).transfer(to, amount);
	}

	function burnCredit(uint256 amount) external {
		MockCreditToken(CREDIT_TOKEN_ADDRESS).burn(amount);
	}
}

// ─── Test Contract ───

contract ComboMachineTest is Test {
	using MessageHashUtils for bytes32;

	ComboMachine public combo;
	EventMarketRegistry public registry;
	MockUSDC public usdc;
	MockCreditToken public creditToken;
	MockHotTreasury public treasury;

	address public contractOwner = makeAddr("owner");
	address public complianceOfficer = makeAddr("compliance");
	address public bettor;
	uint256 public bettorPk = 0xBE770;
	uint256 public authorityPk = 0xA11CE;
	address public authority;
	address public stranger = makeAddr("stranger");

	bytes32 internal constant PLACE_BET_TYPEHASH = keccak256("placeBet");
	bytes32 internal constant SETTLE_BET_TYPEHASH = keccak256("settleBet");
	bytes32 internal constant CANCEL_BET_TYPEHASH = keccak256("cancelBet");
	bytes32 internal constant SETTLE_EVENT_TYPEHASH = keccak256("settleEventMarket");
	bytes32 internal constant VOID_EVENT_TYPEHASH = keccak256("voidEventMarket");

	uint16 internal constant MIN_PICKS = 2;
	uint16 internal constant MAX_PICKS = 6;
	uint256 internal constant MAX_MULTIPLIER = 25000;

	function setUp() public {
		bettor = vm.addr(bettorPk);
		authority = vm.addr(authorityPk);

		// Deploy tokens
		usdc = new MockUSDC();
		creditToken = new MockCreditToken();
		treasury = new MockHotTreasury(address(creditToken), address(usdc));

		// Deploy registry via proxy
		EventMarketRegistry regImpl = new EventMarketRegistry();
		bytes memory regInit = abi.encodeCall(
			EventMarketRegistry.initialize,
			(authority, contractOwner)
		);
		TransparentUpgradeableProxy regProxy = new TransparentUpgradeableProxy(
			address(regImpl),
			makeAddr("regAdmin"),
			regInit
		);
		registry = EventMarketRegistry(address(regProxy));

		// Deploy ComboMachine via proxy
		ComboMachine comboImpl = new ComboMachine();
		bytes memory comboInit = abi.encodeCall(
			ComboMachine.initialize,
			(
				address(usdc),
				authority,
				address(creditToken),
				address(treasury),
				address(registry),
				contractOwner,
				MIN_PICKS,
				MAX_PICKS,
				MAX_MULTIPLIER
			)
		);
		TransparentUpgradeableProxy comboProxy = new TransparentUpgradeableProxy(
			address(comboImpl),
			makeAddr("comboAdmin"),
			comboInit
		);
		combo = ComboMachine(address(comboProxy));

		// Setup: authorize combo as writer in registry
		vm.prank(contractOwner);
		registry.addAuthorizedWriter(address(combo));

		// Setup: add compliance officer
		vm.prank(contractOwner);
		combo.addComplianceOfficer(complianceOfficer);

		// Setup: add default multiplier config (x3, x6, x10, x20, x37.5)
		uint256[] memory mults = new uint256[](5);
		mults[0] = 300; // 2 picks
		mults[1] = 600; // 3 picks
		mults[2] = 1000; // 4 picks
		mults[3] = 2000; // 5 picks
		mults[4] = 3750; // 6 picks
		vm.prank(contractOwner);
		combo.addMultiplierConfig(mults);

		// Fund bettor with USDC and approve treasury
		usdc.mint(bettor, 1_000_000e6);
		vm.prank(bettor);
		usdc.approve(address(treasury), type(uint256).max);

		// Fund treasury with USDC for payouts
		usdc.mint(address(treasury), 10_000_000e6);
	}

	// ─── Helpers ───

	function _picks(
		uint96[] memory marketIds,
		uint96[] memory outcomeIds
	)
		internal
		view
		returns (ComboMachine.Pick[] memory, ComboMachine.LazyCreateEventMarket[] memory)
	{
		ComboMachine.Pick[] memory picks = new ComboMachine.Pick[](marketIds.length);
		ComboMachine.LazyCreateEventMarket[] memory lazys = new ComboMachine.LazyCreateEventMarket[](
			marketIds.length
		);
		for (uint256 i = 0; i < marketIds.length; i++) {
			picks[i] = ComboMachine.Pick({
				event_market_id: bytes12(marketIds[i]),
				outcome_id: bytes12(outcomeIds[i])
			});
			lazys[i] = ComboMachine.LazyCreateEventMarket({
				event_market_id: bytes12(marketIds[i]),
				min_settlement_ts: uint40(block.timestamp + 1 hours)
			});
		}
		return (picks, lazys);
	}

	function _signPlaceBet(
		ComboMachine.Pick[] memory picks,
		ComboMachine.LazyCreateEventMarket[] memory lazys,
		uint128 betSize,
		uint24 configId,
		address owner_,
		uint256 deadline,
		uint256 nonce,
		uint8 tokenType,
		uint256 pk
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(
				PLACE_BET_TYPEHASH,
				block.chainid,
				address(combo),
				owner_,
				picks,
				lazys,
				betSize,
				configId,
				deadline,
				nonce,
				tokenType
			)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
		return abi.encodePacked(r, s, v);
	}

	function _signSettleBet(
		uint256 betId,
		ComboMachine.Pick[] memory picks,
		uint256 deadline
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(SETTLE_BET_TYPEHASH, block.chainid, address(combo), betId, picks, deadline)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, hash);
		return abi.encodePacked(r, s, v);
	}

	function _signSettleEvent(
		bytes12 marketId,
		bytes12 outcomeId,
		uint256 deadline
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(
				SETTLE_EVENT_TYPEHASH,
				block.chainid,
				address(registry),
				marketId,
				outcomeId,
				deadline
			)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, hash);
		return abi.encodePacked(r, s, v);
	}

	function _signVoidEvent(bytes12 marketId, uint256 deadline) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(VOID_EVENT_TYPEHASH, block.chainid, address(registry), marketId, deadline)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityPk, hash);
		return abi.encodePacked(r, s, v);
	}

	function _signCancelBet(
		address owner_,
		uint256 betId,
		ComboMachine.Pick[] memory picks,
		uint256 deadline,
		uint256 nonce,
		uint256 pk
	) internal view returns (bytes memory) {
		bytes32 hash = keccak256(
			abi.encode(
				CANCEL_BET_TYPEHASH,
				block.chainid,
				address(combo),
				owner_,
				betId,
				picks,
				deadline,
				nonce
			)
		).toEthSignedMessageHash();
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
		return abi.encodePacked(r, s, v);
	}

	/// @dev Places a standard 2-pick bet with USDC, returns bet_id
	function _placeDefaultBet()
		internal
		returns (
			uint256 betId,
			ComboMachine.Pick[] memory picks,
			ComboMachine.LazyCreateEventMarket[] memory lazys
		)
	{
		return _placeDefaultBetWithSize(10e18); // 10 USDC in 18 decimals
	}

	function _placeDefaultBetWithSize(
		uint128 betSize
	)
		internal
		returns (
			uint256 betId,
			ComboMachine.Pick[] memory picks,
			ComboMachine.LazyCreateEventMarket[] memory lazys
		)
	{
		uint96[] memory mids = new uint96[](2);
		mids[0] = 1;
		mids[1] = 2;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 100;
		oids[1] = 200;
		(picks, lazys) = _picks(mids, oids);

		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = combo.wallet_nonce(bettor);

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			nonce,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			nonce,
			0,
			bettorPk
		);

		ComboMachine.PlaceBetParams memory params = ComboMachine.PlaceBetParams({
			picks: picks,
			lazy_create_event_markets: lazys,
			bet_size: betSize,
			multipliers_config_id: 0,
			bet_owner: bettor,
			deadline: deadline,
			token_type: 0,
			automated_authority_signature: authSig,
			owner_signature: ownerSig
		});

		combo.placeBet(params);
		betId = combo.getTotalBetsCount() - 1;
	}

	// ─── Initialize ───

	function test_initialize() public view {
		assertEq(combo.owner(), contractOwner);
		assertEq(combo.automated_authority_address(), authority);
		assertEq(combo.event_market_registry_address(), address(registry));
		assertEq(combo.hot_treasury_address(), address(treasury));
		(uint128 minBet, uint128 maxBet) = combo.bet_limits();
		assertEq(minBet, 1000000000000000);
		assertEq(maxBet, 100_000e18);
	}

	// ─── Place Bet ───

	function test_placeBet_success() public {
		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		(uint256 betId, , ) = _placeDefaultBet();

		assertEq(betId, 0);
		assertEq(combo.getTotalBetsCount(), 1);

		// 10 USDC transferred (10e18 internal = 10e6 USDC)
		assertEq(usdc.balanceOf(bettor), bettorBalBefore - 10e6);
		assertEq(combo.wallet_nonce(bettor), 1);
	}

	function test_placeBet_incrementsNonce() public {
		_placeDefaultBet();
		assertEq(combo.wallet_nonce(bettor), 1);

		// second bet needs different market IDs
		uint96[] memory mids = new uint96[](2);
		mids[0] = 3;
		mids[1] = 4;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 300;
		oids[1] = 400;
		(ComboMachine.Pick[] memory picks, ComboMachine.LazyCreateEventMarket[] memory lazys) = _picks(
			mids,
			oids
		);

		uint128 betSize = 10e18;
		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = 1;

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			nonce,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			nonce,
			0,
			bettorPk
		);

		combo.placeBet(
			ComboMachine.PlaceBetParams({
				picks: picks,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 0,
				automated_authority_signature: authSig,
				owner_signature: ownerSig
			})
		);

		assertEq(combo.wallet_nonce(bettor), 2);
	}

	function test_placeBet_revertsBelowMinBetSize() public {
		uint96[] memory mids = new uint96[](2);
		mids[0] = 1;
		mids[1] = 2;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 100;
		oids[1] = 200;
		(ComboMachine.Pick[] memory picks, ComboMachine.LazyCreateEventMarket[] memory lazys) = _picks(
			mids,
			oids
		);

		uint128 betSize = 1; // way below min
		uint256 deadline = block.timestamp + 1 hours;

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			bettorPk
		);

		vm.expectRevert(ComboMachine.InvalidBetSize.selector);
		combo.placeBet(
			ComboMachine.PlaceBetParams({
				picks: picks,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 0,
				automated_authority_signature: authSig,
				owner_signature: ownerSig
			})
		);
	}

	function test_placeBet_revertsAboveMaxBetSize() public {
		uint96[] memory mids = new uint96[](2);
		mids[0] = 1;
		mids[1] = 2;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 100;
		oids[1] = 200;
		(ComboMachine.Pick[] memory picks, ComboMachine.LazyCreateEventMarket[] memory lazys) = _picks(
			mids,
			oids
		);

		uint128 betSize = 200_000e18; // above max of 100k
		uint256 deadline = block.timestamp + 1 hours;

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			bettorPk
		);

		vm.expectRevert(ComboMachine.InvalidBetSize.selector);
		combo.placeBet(
			ComboMachine.PlaceBetParams({
				picks: picks,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 0,
				automated_authority_signature: authSig,
				owner_signature: ownerSig
			})
		);
	}

	function test_placeBet_revertsBlacklistedWallet() public {
		vm.prank(complianceOfficer);
		combo.addToBlacklist(bettor);

		uint96[] memory mids = new uint96[](2);
		mids[0] = 1;
		mids[1] = 2;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 100;
		oids[1] = 200;
		(ComboMachine.Pick[] memory picks, ComboMachine.LazyCreateEventMarket[] memory lazys) = _picks(
			mids,
			oids
		);

		uint128 betSize = 10e18;
		uint256 deadline = block.timestamp + 1 hours;

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			bettorPk
		);

		vm.expectRevert(ComboMachine.Unauthorized.selector);
		combo.placeBet(
			ComboMachine.PlaceBetParams({
				picks: picks,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 0,
				automated_authority_signature: authSig,
				owner_signature: ownerSig
			})
		);
	}

	function test_placeBet_revertsExpiredDeadline() public {
		uint96[] memory mids = new uint96[](2);
		mids[0] = 1;
		mids[1] = 2;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 100;
		oids[1] = 200;
		(ComboMachine.Pick[] memory picks, ComboMachine.LazyCreateEventMarket[] memory lazys) = _picks(
			mids,
			oids
		);

		uint128 betSize = 10e18;
		uint256 deadline = block.timestamp - 1;

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			bettorPk
		);

		vm.expectRevert(ComboMachine.InvalidInput.selector);
		combo.placeBet(
			ComboMachine.PlaceBetParams({
				picks: picks,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 0,
				automated_authority_signature: authSig,
				owner_signature: ownerSig
			})
		);
	}

	function test_placeBet_revertsWhenPaused() public {
		vm.prank(contractOwner);
		combo.pause();

		uint96[] memory mids = new uint96[](2);
		mids[0] = 1;
		mids[1] = 2;
		uint96[] memory oids = new uint96[](2);
		oids[0] = 100;
		oids[1] = 200;
		(ComboMachine.Pick[] memory picks, ComboMachine.LazyCreateEventMarket[] memory lazys) = _picks(
			mids,
			oids
		);

		uint128 betSize = 10e18;
		uint256 deadline = block.timestamp + 1 hours;

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			bettorPk
		);

		vm.expectRevert();
		combo.placeBet(
			ComboMachine.PlaceBetParams({
				picks: picks,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 0,
				automated_authority_signature: authSig,
				owner_signature: ownerSig
			})
		);
	}

	function test_placeBet_revertsTooFewPicks() public {
		// 1 pick, min is 2
		uint96[] memory mids = new uint96[](1);
		mids[0] = 1;
		uint96[] memory oids = new uint96[](1);
		oids[0] = 100;
		(ComboMachine.Pick[] memory picks, ComboMachine.LazyCreateEventMarket[] memory lazys) = _picks(
			mids,
			oids
		);

		uint128 betSize = 10e18;
		uint256 deadline = block.timestamp + 1 hours;

		bytes memory authSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			authorityPk
		);
		bytes memory ownerSig = _signPlaceBet(
			picks,
			lazys,
			betSize,
			0,
			bettor,
			deadline,
			0,
			0,
			bettorPk
		);

		vm.expectRevert(ComboMachine.InvalidPicksCount.selector);
		combo.placeBet(
			ComboMachine.PlaceBetParams({
				picks: picks,
				lazy_create_event_markets: lazys,
				bet_size: betSize,
				multipliers_config_id: 0,
				bet_owner: bettor,
				deadline: deadline,
				token_type: 0,
				automated_authority_signature: authSig,
				owner_signature: ownerSig
			})
		);
	}

	// ─── Settle Bet ───

	function test_settleBet_winningBet() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// Settle both event markets as won
		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;

		registry.settleEventMarket(
			bytes12(uint96(1)),
			bytes12(uint96(100)),
			deadline,
			_signSettleEvent(bytes12(uint96(1)), bytes12(uint96(100)), deadline)
		);
		registry.settleEventMarket(
			bytes12(uint96(2)),
			bytes12(uint96(200)),
			deadline,
			_signSettleEvent(bytes12(uint96(2)), bytes12(uint96(200)), deadline)
		);

		// Settle the bet
		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		bytes memory settleSig = _signSettleBet(betId, picks, deadline);
		combo.settleBet(betId, picks, deadline, settleSig);

		// 10 USDC * 3x = 30 USDC payout (30e18 internal = 30e6 USDC)
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 30e6);

		(, uint8 status, , , , , ) = combo.bets(betId);
		assertEq(status, 5); // STATUS_SETTLED
	}

	function test_settleBet_losingBet() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;

		// First market wins, second market different outcome (loss)
		registry.settleEventMarket(
			bytes12(uint96(1)),
			bytes12(uint96(100)),
			deadline,
			_signSettleEvent(bytes12(uint96(1)), bytes12(uint96(100)), deadline)
		);
		registry.settleEventMarket(
			bytes12(uint96(2)),
			bytes12(uint96(999)),
			deadline,
			_signSettleEvent(bytes12(uint96(2)), bytes12(uint96(999)), deadline)
		);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		combo.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// No payout for losing bet
		assertEq(usdc.balanceOf(bettor), bettorBalBefore);
	}

	function test_settleBet_voidedMarketRefunds() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;

		// First market won, second market voided → only 1 remaining pick < min_picks(2) → refund
		registry.settleEventMarket(
			bytes12(uint96(1)),
			bytes12(uint96(100)),
			deadline,
			_signSettleEvent(bytes12(uint96(1)), bytes12(uint96(100)), deadline)
		);
		registry.voidEventMarket(
			bytes12(uint96(2)),
			deadline,
			_signVoidEvent(bytes12(uint96(2)), deadline)
		);

		uint256 bettorBalBefore = usdc.balanceOf(bettor);
		combo.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// Refund: 10 USDC back (10e6)
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);

		(, uint8 status, , , , , ) = combo.bets(betId);
		assertEq(status, 2); // STATUS_REFUNDED
	}

	function test_settleBet_revertsIfNotAllSettled() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// Only settle one market
		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;
		registry.settleEventMarket(
			bytes12(uint96(1)),
			bytes12(uint96(100)),
			deadline,
			_signSettleEvent(bytes12(uint96(1)), bytes12(uint96(100)), deadline)
		);

		vm.expectRevert(ComboMachine.EventMarketsNotSettled.selector);
		combo.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));
	}

	function test_settleBet_revertsIfAlreadySettled() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp + 1 hours;

		registry.settleEventMarket(
			bytes12(uint96(1)),
			bytes12(uint96(100)),
			deadline,
			_signSettleEvent(bytes12(uint96(1)), bytes12(uint96(100)), deadline)
		);
		registry.settleEventMarket(
			bytes12(uint96(2)),
			bytes12(uint96(200)),
			deadline,
			_signSettleEvent(bytes12(uint96(2)), bytes12(uint96(200)), deadline)
		);

		combo.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));

		// Try settling again
		vm.expectRevert(ComboMachine.BetNotActive.selector);
		combo.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));
	}

	function test_settleBet_revertsExpiredSignature() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		vm.warp(block.timestamp + 2 hours);
		uint256 deadline = block.timestamp - 1; // expired

		vm.expectRevert(ComboMachine.SignatureExpired.selector);
		combo.settleBet(betId, picks, deadline, _signSettleBet(betId, picks, deadline));
	}

	// ─── Enforce Bet Status ───

	function test_enforceBetStatus_freeze() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		combo.enforceBetStatus(betId, 1); // FROZEN

		(, uint8 status, , , , , ) = combo.bets(betId);
		assertEq(status, 1);
	}

	function test_enforceBetStatus_activateFromFrozen() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		combo.enforceBetStatus(betId, 1); // FROZEN

		vm.prank(complianceOfficer);
		combo.enforceBetStatus(betId, 0); // ACTIVE

		(, uint8 status, , , , , ) = combo.bets(betId);
		assertEq(status, 0);
	}

	function test_enforceBetStatus_refund() public {
		(uint256 betId, , ) = _placeDefaultBet();

		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		vm.prank(complianceOfficer);
		combo.enforceBetStatus(betId, 2); // REFUNDED

		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);

		(, uint8 status, , , , , ) = combo.bets(betId);
		assertEq(status, 2);
	}

	function test_enforceBetStatus_cancel_revertsInvalidStatus() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		vm.expectRevert(ComboMachine.InvalidStatus.selector);
		combo.enforceBetStatus(betId, 3); // CANCELED no longer allowed
	}

	function test_enforceBetStatus_seize() public {
		(uint256 betId, , ) = _placeDefaultBet();

		uint256 treasuryBal = usdc.balanceOf(address(treasury));

		vm.prank(complianceOfficer);
		combo.enforceBetStatus(betId, 4); // SEIZED

		// Funds stay in treasury
		assertEq(usdc.balanceOf(address(treasury)), treasuryBal);

		(, uint8 status, , , , , ) = combo.bets(betId);
		assertEq(status, 4);
	}

	function test_enforceBetStatus_revertsUnauthorized() public {
		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(stranger);
		vm.expectRevert(ComboMachine.Unauthorized.selector);
		combo.enforceBetStatus(betId, 1);
	}

	function test_enforceBetStatus_revertsInvalidTransition() public {
		(uint256 betId, , ) = _placeDefaultBet();

		// Can't activate an already active bet
		vm.prank(complianceOfficer);
		vm.expectRevert(ComboMachine.InvalidStatus.selector);
		combo.enforceBetStatus(betId, 0);
	}

	// ─── Enforce Multiplier Config ───

	function test_enforceBetMultiplierConfigId() public {
		// Add second config
		uint256[] memory mults2 = new uint256[](5);
		for (uint i = 0; i < 5; i++) mults2[i] = 100;
		vm.prank(contractOwner);
		combo.addMultiplierConfig(mults2);

		(uint256 betId, , ) = _placeDefaultBet();

		vm.prank(complianceOfficer);
		combo.enforceBetMultiplierConfigId(betId, 1);

		(, , , uint24 configId, , , ) = combo.bets(betId);
		assertEq(configId, 1);
	}

	// ─── Multiplier Config ───

	function test_addMultiplierConfig() public {
		assertEq(combo.getMultiplierConfigsCount(), 1);

		uint256[] memory mults = new uint256[](5);
		for (uint i = 0; i < 5; i++) mults[i] = 200;
		vm.prank(contractOwner);
		combo.addMultiplierConfig(mults);

		assertEq(combo.getMultiplierConfigsCount(), 2);
	}

	function test_addMultiplierConfig_revertsWrongLength() public {
		uint256[] memory mults = new uint256[](3); // expected 5
		for (uint i = 0; i < 3; i++) mults[i] = 200;

		vm.prank(contractOwner);
		vm.expectRevert(ComboMachine.InvalidMultiplierArrayLength.selector);
		combo.addMultiplierConfig(mults);
	}

	function test_addMultiplierConfig_revertsZeroMultiplier() public {
		uint256[] memory mults = new uint256[](5);
		mults[0] = 0; // invalid

		vm.prank(contractOwner);
		vm.expectRevert(ComboMachine.InvalidMultiplier.selector);
		combo.addMultiplierConfig(mults);
	}

	function test_addMultiplierConfig_revertsExceedsMax() public {
		uint256[] memory mults = new uint256[](5);
		for (uint i = 0; i < 5; i++) mults[i] = MAX_MULTIPLIER + 1;

		vm.prank(contractOwner);
		vm.expectRevert(ComboMachine.InvalidMultiplier.selector);
		combo.addMultiplierConfig(mults);
	}

	function test_updateMultiplierConfig() public {
		uint256[] memory mults = new uint256[](5);
		for (uint i = 0; i < 5; i++) mults[i] = 200;

		vm.prank(contractOwner);
		combo.updateMultiplierConfig(0, mults, false);

		bool isActive = combo.multipliers(0);
		assertFalse(isActive);
	}

	// ─── Configuration ───

	function test_updateConfiguration() public {
		address newAuth = makeAddr("newAuth");

		vm.prank(contractOwner);
		combo.updateConfiguration(newAuth, address(0), 5e18, 50_000e18, type(uint16).max);

		assertEq(combo.automated_authority_address(), newAuth);
		(uint128 minBet, uint128 maxBet) = combo.bet_limits();
		assertEq(minBet, 5e18);
		assertEq(maxBet, 50_000e18);
	}

	function test_updateConfiguration_skipsZeros() public {
		vm.prank(contractOwner);
		combo.updateConfiguration(address(0), address(0), 0, 0, type(uint16).max);

		// Nothing changed
		assertEq(combo.automated_authority_address(), authority);
		(uint128 minBet, uint128 maxBet) = combo.bet_limits();
		assertEq(minBet, 1000000000000000);
		assertEq(maxBet, 100_000e18);
	}

	function test_updateConfiguration_revertsNonOwner() public {
		vm.prank(stranger);
		vm.expectRevert(
			abi.encodeWithSelector(ComboMachine.OwnableUnauthorizedAccount.selector, stranger)
		);
		combo.updateConfiguration(makeAddr("x"), address(0), 0, 0, type(uint16).max);
	}

	// ─── Compliance Officers ───

	function test_addRemoveComplianceOfficer() public {
		address officer = makeAddr("newOfficer");

		vm.prank(contractOwner);
		combo.addComplianceOfficer(officer);
		assertTrue(combo.compliance_officers(officer));

		vm.prank(contractOwner);
		combo.removeComplianceOfficer(officer);
		assertFalse(combo.compliance_officers(officer));
	}

	// ─── Blacklist ───

	function test_addRemoveBlacklist() public {
		address wallet = makeAddr("target");

		vm.prank(complianceOfficer);
		combo.addToBlacklist(wallet);
		assertTrue(combo.blacklisted_wallets(wallet));

		vm.prank(complianceOfficer);
		combo.removeFromBlacklist(wallet);
		assertFalse(combo.blacklisted_wallets(wallet));
	}

	// ─── Pause ───

	function test_pause_unpause() public {
		vm.prank(contractOwner);
		combo.pause();

		vm.prank(contractOwner);
		combo.unpause();

		// Can place bet again after unpause
		_placeDefaultBet();
		assertEq(combo.getTotalBetsCount(), 1);
	}

	// ─── Ownership ───

	function test_transferOwnership() public {
		address newOwner = makeAddr("newOwner");
		vm.prank(contractOwner);
		combo.transferOwnership(newOwner);
		assertEq(combo.owner(), newOwner);
	}

	function test_renounceOwnership() public {
		vm.prank(contractOwner);
		combo.renounceOwnership();
		assertEq(combo.owner(), address(0));
	}

	// ─── Cancel Bet ───

	function _createCancelParams(
		uint256 betId,
		ComboMachine.Pick[] memory picks,
		address owner_,
		uint256 ownerPk,
		uint256 deadline
	) internal view returns (ComboMachine.CancelBetParams memory) {
		uint256 nonce = combo.wallet_nonce(owner_);
		bytes memory ownerSig = _signCancelBet(owner_, betId, picks, deadline, nonce, ownerPk);
		bytes memory authSig = _signCancelBet(owner_, betId, picks, deadline, nonce, authorityPk);
		return ComboMachine.CancelBetParams({
			bet_id: betId,
			picks: picks,
			bet_owner: owner_,
			deadline: deadline,
			owner_signature: ownerSig,
			automated_authority_signature: authSig
		});
	}

	function _cancelBetWithSigs(
		uint256 betId,
		ComboMachine.Pick[] memory picks,
		address owner_,
		uint256 ownerPk
	) internal {
		ComboMachine.CancelBetParams memory params = _createCancelParams(
			betId, picks, owner_, ownerPk, block.timestamp + 1 hours
		);
		combo.cancelBet(params);
	}

	/// @dev User cancels active bet before settlement window, receives 90% refund (10% fee)
	function test_cancelBet_success() public {
		// Set 10% cancel fee (1000 bps)
		vm.prank(contractOwner);
		combo.updateConfiguration(address(0), address(0), 0, 0, 1000);

		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		_cancelBetWithSigs(betId, picks, bettor, bettorPk);

		// 10 USDC bet, 10% fee = 1 USDC fee, 9 USDC refund (9e6 in USDC decimals)
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 9e6);

		(, uint8 status, , , , , ) = combo.bets(betId);
		assertEq(status, 3); // STATUS_CANCELED
	}

	/// @dev Cancel with 0% fee returns full amount
	function test_cancelBet_zeroFee() public {
		// cancel_fee_bps defaults to 0
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 bettorBalBefore = usdc.balanceOf(bettor);

		_cancelBetWithSigs(betId, picks, bettor, bettorPk);

		// Full refund
		assertEq(usdc.balanceOf(bettor), bettorBalBefore + 10e6);
	}

	/// @dev Cancel reverts after settlement window opens (block.timestamp >= min_settlement_ts)
	function test_cancelBet_revertsCancelWindowClosed() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 3 hours;
		ComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, bettor, bettorPk, deadline);

		// Warp past min_settlement_ts but before deadline
		vm.warp(block.timestamp + 2 hours);

		vm.expectRevert(ComboMachine.CancelWindowClosed.selector);
		combo.cancelBet(params);
	}

	/// @dev Cancel reverts with invalid owner signature
	function test_cancelBet_revertsInvalidOwnerSignature() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = combo.wallet_nonce(bettor);
		uint256 strangerPk = 0x5678;
		bytes memory ownerSig = _signCancelBet(bettor, betId, picks, deadline, nonce, strangerPk);
		bytes memory authSig = _signCancelBet(bettor, betId, picks, deadline, nonce, authorityPk);

		vm.expectRevert(ComboMachine.InvalidSignature.selector);
		combo.cancelBet(ComboMachine.CancelBetParams({
			bet_id: betId, picks: picks, bet_owner: bettor, deadline: deadline,
			owner_signature: ownerSig, automated_authority_signature: authSig
		}));
	}

	/// @dev Cancel reverts with invalid authority signature
	function test_cancelBet_revertsInvalidAuthoritySignature() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 1 hours;
		uint256 nonce = combo.wallet_nonce(bettor);
		bytes memory ownerSig = _signCancelBet(bettor, betId, picks, deadline, nonce, bettorPk);
		uint256 fakePk = 0x9999;
		bytes memory authSig = _signCancelBet(bettor, betId, picks, deadline, nonce, fakePk);

		vm.expectRevert(ComboMachine.InvalidSignature.selector);
		combo.cancelBet(ComboMachine.CancelBetParams({
			bet_id: betId, picks: picks, bet_owner: bettor, deadline: deadline,
			owner_signature: ownerSig, automated_authority_signature: authSig
		}));
	}

	/// @dev Cancel reverts when bet_owner doesn't match actual bet owner
	function test_cancelBet_revertsNonOwner() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 strangerPk = 0x5678;
		address strangerAddr = vm.addr(strangerPk);

		ComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, strangerAddr, strangerPk, block.timestamp + 1 hours);

		vm.expectRevert(ComboMachine.Unauthorized.selector);
		combo.cancelBet(params);
	}

	/// @dev Cannot cancel non-active bet
	function test_cancelBet_revertsNotActive() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		// Freeze the bet first
		vm.prank(complianceOfficer);
		combo.enforceBetStatus(betId, 1); // FROZEN

		ComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, bettor, bettorPk, block.timestamp + 1 hours);

		vm.expectRevert(ComboMachine.BetNotActive.selector);
		combo.cancelBet(params);
	}

	/// @dev Cancel reverts with wrong picks
	function test_cancelBet_revertsInvalidPicks() public {
		(uint256 betId, , ) = _placeDefaultBet();

		ComboMachine.Pick[] memory wrongPicks = new ComboMachine.Pick[](2);
		wrongPicks[0] = ComboMachine.Pick({
			event_market_id: bytes12(uint96(1)),
			outcome_id: bytes12(uint96(999))
		});
		wrongPicks[1] = ComboMachine.Pick({
			event_market_id: bytes12(uint96(2)),
			outcome_id: bytes12(uint96(999))
		});

		ComboMachine.CancelBetParams memory params = _createCancelParams(betId, wrongPicks, bettor, bettorPk, block.timestamp + 1 hours);

		vm.expectRevert(ComboMachine.InvalidInput.selector);
		combo.cancelBet(params);
	}

	/// @dev Cancel reverts when contract is paused
	function test_cancelBet_revertsWhenPaused() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		ComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, bettor, bettorPk, block.timestamp + 1 hours);

		vm.prank(contractOwner);
		combo.pause();

		vm.expectRevert();
		combo.cancelBet(params);
	}

	/// @dev Cancel reverts when deadline has passed
	function test_cancelBet_revertsExpiredDeadline() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 deadline = block.timestamp + 1 hours;
		ComboMachine.CancelBetParams memory params = _createCancelParams(betId, picks, bettor, bettorPk, deadline);

		// Warp past deadline
		vm.warp(deadline + 1);

		vm.expectRevert(ComboMachine.SignatureExpired.selector);
		combo.cancelBet(params);
	}

	/// @dev Cancel increments wallet nonce
	function test_cancelBet_incrementsNonce() public {
		(uint256 betId, ComboMachine.Pick[] memory picks, ) = _placeDefaultBet();

		uint256 nonceBefore = combo.wallet_nonce(bettor);
		_cancelBetWithSigs(betId, picks, bettor, bettorPk);
		assertEq(combo.wallet_nonce(bettor), nonceBefore + 1);
	}

	/// @dev Cancel fee bps can be updated via updateConfiguration
	function test_cancelFeeBps_updateConfiguration() public {
		vm.prank(contractOwner);
		combo.updateConfiguration(address(0), address(0), 0, 0, 500); // 5%

		assertEq(combo.cancel_fee_bps(), 500);

		// Skip update with type(uint16).max
		vm.prank(contractOwner);
		combo.updateConfiguration(address(0), address(0), 0, 0, type(uint16).max);

		assertEq(combo.cancel_fee_bps(), 500); // unchanged
	}

	// ─── Emergency Withdraw ───

	function test_emergencyWithdrawErc20() public {
		// Send some tokens to combo accidentally
		usdc.mint(address(combo), 100e6);

		vm.prank(contractOwner);
		combo.emergencyWithdrawErc20(address(usdc), 100e6);

		assertEq(usdc.balanceOf(contractOwner), 100e6);
	}
}
